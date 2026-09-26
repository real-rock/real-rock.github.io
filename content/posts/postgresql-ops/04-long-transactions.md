---
title: "PostgreSQL 운영 4: 긴 트랜잭션과 idle in transaction"
date: 2026-09-26T19:05:00+09:00
draft: true
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "VACUUM", "트랜잭션", "dead but not yet removable", "idle-in-transaction timeout", "transaction timeout"]
weight: 4
summary: "VACUUM이 돌아도 dead tuple이 줄지 않을 때, 무엇이 붙잡고 있는지 찾고 어떻게 막는가"
description: "xmin horizon이 멈추는 원인과 찾는 법"
---

## 개요

UPDATE가 많은 테이블이 계속 커집니다. autovacuum은 분명히 돌고 있고 로그도 남는데 `n_dead_tup`이 줄지 않습니다. 이럴 때 VACUUM은 일을 안 하는 것이 아니라 **못 하는** 것입니다. 어딘가에 오래된 트랜잭션이 있어서, 그 트랜잭션이 아직 볼 수도 있는 옛 버전을 지울 수 없기 때문입니다.

VACUUM이 지울 수 있는 경계를 **xmin horizon**이라고 부릅니다. 지금 살아 있는 트랜잭션과 스냅샷 가운데 가장 오래된 것보다 먼저 지워진 행만 지울 수 있습니다([인터널 4편](/posts/postgresql/04-mvcc/), [5편](/posts/postgresql/05-vacuum/)). 이 경계를 붙잡는 것이 무엇인지 찾는 것이 이 글의 주제입니다.

이 글에서 답할 질문은 다음과 같습니다.

- VACUUM이 dead tuple을 지우지 못하고 있다는 것은 어디서 보이는가
- xmin horizon을 붙잡는 것은 무엇이 있고, 한 번에 어떻게 찾는가
- 세션을 모두 끊었는데도 VACUUM이 지우지 못한다면 무엇을 봐야 하는가
- 이런 트랜잭션이 생기지 않게 하려면 어떤 설정을 거는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

## 먼저 확인할 것

### VACUUM이 지우지 못했다는 표시

실습에서는 트랜잭션 세 개를 열어 둔 채(아래에서 하나씩 봅니다) 1만 행짜리 테이블을 다섯 번 통째로 UPDATE했습니다. VACUUM 결과를 일정하게 보려고 이 테이블의 autovacuum은 끄고 직접 VACUUM합니다.

```psql
postgres=# UPDATE t SET v = v + 1;
UPDATE 10000
...
postgres=# UPDATE t SET v = v + 1;
UPDATE 10000

postgres=# SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
postgres-# FROM pg_stat_user_tables WHERE relname = 't';
 n_live_tup | n_dead_tup |  size
------------+------------+---------
      10000 |      50000 | 2160 kB
(1 row)


postgres=# VACUUM (VERBOSE) t;
INFO:  vacuuming "postgres.public.t"
VACUUM
INFO:  finished vacuuming "postgres.public.t": index scans: 0
pages: 0 removed, 266 remain, 266 scanned (100.00% of total), 0 eagerly scanned
tuples: 0 removed, 60000 remain, 50000 are dead but not yet removable
removable cutoff: 757, which was 7 XIDs old when operation ended
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
visibility map: 0 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
avg read rate: 0.000 MB/s, avg write rate: 0.000 MB/s
buffer usage: 587 hits, 0 reads, 0 dirtied
WAL usage: 1 records, 0 full page images, 307 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s

postgres=# SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
postgres-# FROM pg_stat_user_tables WHERE relname = 't';
 n_live_tup | n_dead_tup |  size
------------+------------+---------
      10000 |      50000 | 2160 kB
(1 row)
```

핵심은 두 줄입니다.

- `tuples: 0 removed, 60000 remain, 50000 are dead but not yet removable`: dead tuple 5만 개가 있는데 **하나도 지우지 못했습니다.**
- `removable cutoff: 757, which was 7 XIDs old when operation ended`: 트랜잭션 ID 757보다 먼저 지워진 행만 지울 수 있다는 뜻입니다. 이 값이 xmin horizon입니다.

autovacuum도 같은 두 줄을 로그에 남깁니다([1편](/posts/postgresql-ops/01-diagnostic-toolkit/)의 `log_autovacuum_min_duration`). `dead but not yet removable`이 계속 크게 찍히고 `removable cutoff`의 `XIDs old`가 계속 커진다면, 무언가가 horizon을 붙잡고 있는 것입니다. 이 실습은 몇 초 동안이라 7이지만, 운영에서 이 값이 수백만, 수억이 되면 6편의 wraparound 문제로 이어집니다.

### horizon을 붙잡는 것을 한 번에 찾기

xmin horizon을 붙잡을 수 있는 것은 크게 세 곳에 있습니다.

| 어디서 보는가 | 무엇이 붙잡는가 |
|---|---|
| `pg_stat_activity` | 세션의 트랜잭션 ID(`backend_xid`)나 스냅샷(`backend_xmin`) |
| `pg_prepared_xacts` | 2단계 커밋의 첫 단계(`PREPARE TRANSACTION`)만 마친 트랜잭션 |
| `pg_replication_slots` | replication slot의 `xmin`(standby의 `hot_standby_feedback`), `catalog_xmin`(논리 복제) |

세 곳을 한 번에 보는 쿼리입니다. 나이(`age`)가 많은 순서로 정렬했습니다.

```psql
postgres=# SELECT 'session' AS kind, pid::text AS id, state,
postgres-#        age(backend_xid) AS xid_age, age(backend_xmin) AS xmin_age, xact_start
postgres-# FROM pg_stat_activity
postgres-# WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
postgres-# UNION ALL
postgres-# SELECT 'prepared', gid, NULL, age(transaction), NULL, prepared
postgres-# FROM pg_prepared_xacts
postgres-# UNION ALL
postgres-# SELECT 'slot', slot_name, NULL, age(xmin), age(catalog_xmin), NULL
postgres-# FROM pg_replication_slots
postgres-# ORDER BY 4 DESC NULLS LAST, 5 DESC NULLS LAST;
   kind   |    id    |        state        | xid_age | xmin_age |          xact_start
----------+----------+---------------------+---------+----------+-------------------------------
 prepared | batch-42 |                     |       7 |          | 2026-09-26 10:07:14.95094+00
 session  | 305      | idle in transaction |       6 |          | 2026-09-26 10:07:23.77488+00
 session  | 224      | idle in transaction |         |        7 | 2026-09-26 10:07:19.093974+00
(3 rows)
```

세 개가 나왔습니다. prepared transaction 하나와 세션 둘입니다. slot은 이 실습에 없습니다. 하나씩 봅니다.

## 원인별 진단

### 세션: 스냅샷을 쥐거나, 트랜잭션 ID를 쥐거나

두 세션은 이렇게 만들었습니다.

```psql
A=# SET application_name = 'report';
SET

A=# BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN

A=# SELECT count(*) FROM t;
 count
-------
 10000
(1 row)
B=# SET application_name = 'worker';
SET

B=# BEGIN;
BEGIN

B=# UPDATE jobs SET state = 'running' WHERE id = 1;
UPDATE 1
```

`pg_stat_activity`에서 두 세션의 차이가 보입니다.

```psql
postgres=# SELECT pid, application_name AS app, state, backend_xid, backend_xmin,
postgres-#        age(backend_xmin) AS xmin_age, now() - xact_start AS xact_age
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start;
 pid |  app   |        state        | backend_xid | backend_xmin | xmin_age |    xact_age
-----+--------+---------------------+-------------+--------------+----------+-----------------
 224 | report | idle in transaction |             |          757 |        7 | 00:00:06.806246
 305 | worker | idle in transaction |         758 |              |          | 00:00:02.12534
(2 rows)
```

- `report`(REPEATABLE READ)는 읽기만 했으므로 트랜잭션 ID(`backend_xid`)가 없습니다. 대신 트랜잭션이 끝날 때까지 **같은 스냅샷**을 써야 하므로, 스냅샷의 xmin(`backend_xmin` 757)을 붙잡고 있습니다. 보고서나 덤프처럼 오래 읽는 작업이 이런 모양입니다.
- `worker`는 행을 고쳤으므로 트랜잭션 ID 758을 받았고, 커밋이나 롤백을 할 때까지 이 ID가 살아 있습니다.

둘 다 `idle in transaction`입니다. 아무 일도 하지 않으면서 horizon을 붙잡고 있습니다. `active` 상태로 몇 시간째 도는 쿼리도 같은 방식으로 `backend_xmin`을 붙잡습니다.

### prepared transaction: 세션이 없는데 남아 있다

두 세션을 끊습니다.

```psql
postgres=# SELECT pid, application_name, pg_terminate_backend(pid)
postgres-# FROM pg_stat_activity WHERE application_name IN ('report', 'worker');
 pid | application_name | pg_terminate_backend
-----+------------------+----------------------
 224 | report           | t
 305 | worker           | t
(2 rows)


postgres=# VACUUM (VERBOSE) t;
INFO:  vacuuming "postgres.public.t"
INFO:  finished vacuuming "postgres.public.t": index scans: 0
pages: 0 removed, 266 remain, 266 scanned (100.00% of total), 0 eagerly scanned
tuples: 0 removed, 60000 remain, 50000 are dead but not yet removable
removable cutoff: 757, which was 7 XIDs old when operation ended
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
visibility map: 0 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
avg read rate: 0.000 MB/s, avg write rate: 0.000 MB/s
buffer usage: 578 hits, 0 reads, 0 dirtied
WAL usage: 0 records, 0 full page images, 0 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
VACUUM
```

**여전히 5만 개를 지우지 못했습니다.** `removable cutoff`도 757 그대로입니다. 세션은 하나도 남아 있지 않습니다.

```psql
postgres=# SELECT count(*) AS sessions FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();
 sessions
----------
        0
(1 row)
```

`pg_stat_activity`만 보고 있으면 여기서 막힙니다. 앞의 쿼리를 다시 돌리면 남은 것이 보입니다.

```psql
postgres=# SELECT 'session' AS kind, pid::text AS id, state,
postgres-#        age(backend_xid) AS xid_age, age(backend_xmin) AS xmin_age, xact_start
postgres-# FROM pg_stat_activity
postgres-# WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
postgres-# UNION ALL
postgres-# SELECT 'prepared', gid, NULL, age(transaction), NULL, prepared
postgres-# FROM pg_prepared_xacts
postgres-# UNION ALL
postgres-# SELECT 'slot', slot_name, NULL, age(xmin), age(catalog_xmin), NULL
postgres-# FROM pg_replication_slots
postgres-# ORDER BY 4 DESC NULLS LAST, 5 DESC NULLS LAST;
   kind   |    id    | state | xid_age | xmin_age |          xact_start
----------+----------+-------+---------+----------+------------------------------
 prepared | batch-42 |       |       7 |          | 2026-09-26 10:07:14.95094+00
(1 row)


postgres=# SELECT gid, prepared, owner, database, age(transaction) AS xid_age FROM pg_prepared_xacts;
   gid    |           prepared           |  owner   | database | xid_age
----------+------------------------------+----------+----------+---------
 batch-42 | 2026-09-26 10:07:14.95094+00 | postgres | postgres |       7
(1 row)
```

`batch-42`는 이렇게 만들었습니다. 트랜잭션 안에서 행을 고치고 `PREPARE TRANSACTION`까지 한 뒤 세션을 닫았습니다.

```psql
C=# BEGIN;
BEGIN

C=# UPDATE jobs SET state = 'running' WHERE id = 3;
UPDATE 1

C=# PREPARE TRANSACTION 'batch-42';
PREPARE TRANSACTION
```

`PREPARE TRANSACTION`은 2단계 커밋(two-phase commit)의 첫 단계입니다. 트랜잭션을 세션에서 떼어 디스크에 기록해 두고, 나중에 어느 세션에서든 `COMMIT PREPARED`나 `ROLLBACK PREPARED`로 마무리하게 합니다([PREPARE TRANSACTION](https://www.postgresql.org/docs/18/sql-prepare-transaction.html)). 여러 DB에 걸친 트랜잭션을 조율하는 트랜잭션 관리자가 쓰는 기능인데, 관리자가 죽거나 버그로 두 번째 단계를 보내지 않으면 이렇게 **주인 없는 트랜잭션**이 남습니다.

이 트랜잭션은 서버를 재시작해도 사라지지 않습니다.

```psql
postgres=# SELECT gid, prepared, age(transaction) AS xid_age FROM pg_prepared_xacts;
   gid    |           prepared           | xid_age
----------+------------------------------+---------
 batch-42 | 2026-09-26 10:07:14.95094+00 |       7
(1 row)


postgres=# SELECT locktype, relation::regclass, mode, granted, virtualtransaction
postgres-# FROM pg_locks WHERE virtualtransaction LIKE '-1/%';
   locktype    | relation  |       mode       | granted | virtualtransaction
---------------+-----------+------------------+---------+--------------------
 relation      | jobs_pkey | RowExclusiveLock | t       | -1/757
 transactionid |           | ExclusiveLock    | t       | -1/757
 relation      | jobs      | RowExclusiveLock | t       | -1/757
(3 rows)
```

재시작 뒤에도 남아 있고, 고친 행의 락도 그대로 쥐고 있습니다. `virtualtransaction`이 `-1/`로 시작하는 락이 prepared transaction의 락입니다. 이 트랜잭션이 고친 `jobs`의 3번 행을 다른 세션이 고치려 하면 [2편](/posts/postgresql-ops/02-blocked-sessions/)처럼 기다리게 되는데, 기다리게 만든 세션은 어디에도 없습니다.

`max_prepared_transactions`의 기본값은 0이라서, 이 기능을 쓰려고 일부러 켠 서버에서만 생기는 문제입니다. 실습에서도 10으로 켜고 재시작했습니다.

### replication slot과 standby

이 실습에는 없지만 세 번째 후보입니다. standby가 `hot_standby_feedback = on`으로 붙어 있으면, standby에서 오래 도는 쿼리의 xmin이 primary의 slot `xmin`으로 전달되어 primary의 VACUUM을 막습니다. 논리 복제 slot은 `catalog_xmin`으로 시스템 카탈로그의 정리를 막습니다. 구독자가 사라진 slot이 남아 있으면 horizon이 계속 붙잡힙니다. 이 경우는 8편에서 standby와 함께 다룹니다([인터널 9편](/posts/postgresql/09-streaming-replication/)).

## 조치

찾은 원인에 따라 다음과 같이 합니다.

| 원인 | 조치 | 주의 |
|---|---|---|
| 세션 | `pg_terminate_backend(pid)` | 그 트랜잭션은 롤백됩니다([2편](/posts/postgresql-ops/02-blocked-sessions/)) |
| prepared transaction | `ROLLBACK PREPARED 'gid'` 또는 `COMMIT PREPARED 'gid'` | 어느 쪽이 맞는지는 그 트랜잭션을 만든 시스템이 알고 있습니다 |
| replication slot | 쓰지 않는 slot이면 `pg_drop_replication_slot('이름')` | 그 slot을 쓰는 standby나 구독자는 다시 구성해야 합니다 |

prepared transaction은 **커밋할지 롤백할지를 DBA가 마음대로 정하면 안 됩니다.** 다른 DB에서는 같은 트랜잭션이 이미 커밋되었을 수 있습니다. `gid`(여기서는 `batch-42`)와 `prepared` 시각, `owner`, `database`를 가지고 트랜잭션 관리자 쪽에서 결과를 확인한 뒤 맞는 쪽으로 마무리합니다. 이 실습에서는 롤백합니다.

```psql
postgres=# ROLLBACK PREPARED 'batch-42';
ROLLBACK PREPARED

postgres=# VACUUM (VERBOSE) t;
INFO:  vacuuming "postgres.public.t"
INFO:  finished vacuuming "postgres.public.t": index scans: 1
pages: 0 removed, 266 remain, 266 scanned (100.00% of total), 0 eagerly scanned
tuples: 50000 removed, 10000 remain, 0 are dead but not yet removable
removable cutoff: 764, which was 0 XIDs old when operation ended
new relfrozenxid: 763, which is 10 XIDs ahead of previous value
frozen: 1 pages from table (0.38% of total) had 172 tuples frozen
visibility map: 266 pages set all-visible, 222 pages set all-frozen (0 were all-visible)
index scan needed: 222 pages from table (83.46% of total) had 50000 dead item identifiers removed
index "t_pkey": pages: 111 in total, 0 newly deleted, 0 currently deleted, 0 reusable
avg read rate: 1356.368 MB/s, avg write rate: 1342.983 MB/s
buffer usage: 318 hits, 608 reads, 602 dirtied
WAL usage: 824 records, 380 full page images, 953157 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
VACUUM

postgres=# SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
postgres-# FROM pg_stat_user_tables WHERE relname = 't';
 n_live_tup | n_dead_tup |  size
------------+------------+---------
      10000 |          0 | 2160 kB
(1 row)
```

이제 `50000 removed`, `0 are dead but not yet removable`입니다. `removable cutoff`도 764로 올라갔습니다.

그런데 테이블 크기는 **2160 kB 그대로**입니다. VACUUM은 dead tuple이 차지하던 공간을 새 행이 다시 쓸 수 있게 할 뿐, 파일을 줄이지는 않습니다. horizon이 오래 붙잡혀 있던 동안 부풀어 오른 테이블을 되돌리는 방법은 5편에서 다룹니다.

## 재발 방지

### 타임아웃

PostgreSQL에는 이런 트랜잭션을 자동으로 끊는 설정이 있지만, 모두 기본으로 꺼져 있습니다.

```psql
postgres=# SELECT name, setting, unit FROM pg_settings
postgres-# WHERE name IN ('idle_in_transaction_session_timeout', 'transaction_timeout', 'statement_timeout', 'idle_session_timeout')
postgres-# ORDER BY name;
                name                 | setting | unit
-------------------------------------+---------+------
 idle_in_transaction_session_timeout | 0       | ms
 idle_session_timeout                | 0       | ms
 statement_timeout                   | 0       | ms
 transaction_timeout                 | 0       | ms
(4 rows)
```

`idle_in_transaction_session_timeout`은 트랜잭션 안에서 아무것도 하지 않고 기다린 시간이 이 값을 넘으면 세션을 끊습니다.

```psql
D=# SET idle_in_transaction_session_timeout = '3s';
SET

D=# BEGIN;
BEGIN

D=# SELECT count(*) FROM t;
 count
-------
 10000
(1 row)


D=# SELECT 1;
FATAL:  terminating connection due to idle-in-transaction timeout
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

트랜잭션을 연 채 3초 넘게 가만히 있자 세션이 끊겼습니다. 클라이언트는 다음 명령을 보낼 때에야 알게 됩니다.

**`transaction_timeout`**(PostgreSQL 17부터)은 트랜잭션이 시작된 뒤의 전체 시간을 봅니다. idle이든 쿼리 실행 중이든 상관없습니다.

```psql
E=# SET transaction_timeout = '3s';
SET

E=# BEGIN;
BEGIN

E=# SELECT pg_sleep(1);
 pg_sleep
----------

(1 row)


E=# SELECT pg_sleep(5);
FATAL:  terminating connection due to transaction timeout
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

1초짜리 쿼리는 통과했지만, 트랜잭션 시작부터 3초가 지나자 5초짜리 쿼리를 실행하던 도중에 세션이 끊겼습니다. 두 경우 모두 서버 로그에 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'idle-in-transaction timeout|transaction timeout'
2026-09-26 10:07:35.956 UTC [544] postgres@postgres/forgetful FATAL:  terminating connection due to idle-in-transaction timeout
2026-09-26 10:07:46.483 UTC [677] postgres@postgres/slowbatch FATAL:  terminating connection due to transaction timeout
```

| 설정 | 무엇을 재는가 | 넘으면 |
|---|---|---|
| `statement_timeout` | 문장 하나의 실행 시간 | 그 문장만 취소 |
| `idle_in_transaction_session_timeout` | 트랜잭션 안에서 idle로 있는 시간 | 세션 종료 |
| `transaction_timeout` | 트랜잭션 전체 시간 | 세션 종료 |
| `idle_session_timeout` | 트랜잭션 밖에서 idle로 있는 시간 | 세션 종료 |

`statement_timeout`은 idle 상태의 트랜잭션을 잡지 못합니다. 이 글의 `report`, `worker` 같은 세션은 실행 중인 문장이 없기 때문입니다. `idle_session_timeout`은 트랜잭션 밖의 idle 세션을 끊으므로 horizon과는 관계가 없고, 커넥션 풀이 유지하는 연결을 끊어 버릴 수 있어 조심해서 씁니다.

서버 전체에 걸기보다는 **애플리케이션 계정에** 겁니다. 백업이나 관리 작업 계정까지 끊기면 곤란하기 때문입니다.

```sql
ALTER ROLE app SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app SET transaction_timeout = '10min';
```

값은 그 애플리케이션의 가장 긴 정상 트랜잭션보다 넉넉하게 잡습니다. 새로 접속하는 세션부터 적용됩니다.

### 모니터링

앞의 "한 번에 찾기" 쿼리에서 가장 큰 나이를 주기적으로 수집하고 알람을 겁니다.

- 세션의 `age(backend_xmin)`, `age(backend_xid)`, `now() - xact_start`
- `pg_prepared_xacts`의 행 수와 `prepared` 시각. 2단계 커밋을 쓰지 않는다면 `max_prepared_transactions = 0`으로 두고, 쓴다면 몇 분 넘게 남아 있는 행이 있으면 알람을 보냅니다.
- `pg_replication_slots`의 `age(xmin)`, `age(catalog_xmin)`, 그리고 `active = false`인 slot

autovacuum 로그의 `dead but not yet removable`과 `removable cutoff ... XIDs old`도 같은 신호입니다.

## 정리

- VACUUM 결과의 `dead but not yet removable`과 `removable cutoff ... XIDs old`가 커지면 무언가가 xmin horizon을 붙잡고 있습니다.
- 붙잡는 것은 세 곳에 있습니다. `pg_stat_activity`(세션), `pg_prepared_xacts`(prepared transaction), `pg_replication_slots`(slot). 세 곳을 한 번에 봅니다.
- REPEATABLE READ로 읽기만 한 세션은 `backend_xmin`을, 행을 고친 세션은 `backend_xid`를 쥡니다. 둘 다 `idle in transaction`으로 보입니다.
- prepared transaction은 세션이 없어도, 재시작해도 남고 락도 쥐고 있습니다. 세션을 다 끊어도 VACUUM이 지우지 못하면 `pg_prepared_xacts`를 봅니다. 커밋할지 롤백할지는 트랜잭션 관리자 쪽에서 확인합니다.
- `idle_in_transaction_session_timeout`과 `transaction_timeout`을 애플리케이션 계정에 걸어 둡니다. 둘 다 기본으로 꺼져 있습니다.

## 참고 자료

- [Routine Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html)
- [pg_stat_activity](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW), [pg_prepared_xacts](https://www.postgresql.org/docs/18/view-pg-prepared-xacts.html), [pg_replication_slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html)
- [PREPARE TRANSACTION](https://www.postgresql.org/docs/18/sql-prepare-transaction.html), [ROLLBACK PREPARED](https://www.postgresql.org/docs/18/sql-rollback-prepared.html)
- [Client Connection Defaults](https://www.postgresql.org/docs/18/runtime-config-client.html): `statement_timeout`, `idle_in_transaction_session_timeout`, `transaction_timeout`, `idle_session_timeout`
- PostgreSQL 인터널 [4편 MVCC](/posts/postgresql/04-mvcc/), [5편 VACUUM](/posts/postgresql/05-vacuum/), [9편 스트리밍 복제](/posts/postgresql/09-streaming-replication/)

