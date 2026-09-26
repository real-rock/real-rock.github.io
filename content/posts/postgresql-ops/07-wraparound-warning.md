---
title: "PostgreSQL 운영 7: wraparound 경고가 떴다"
date: 2026-09-26T19:31:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "wraparound", "VACUUM", "must be vacuumed within", "not accepting commands", "failsafe"]
weight: 7
summary: "must be vacuumed within 경고가 보이거나 쓰기가 거부될 때, 무엇을 확인하고 어떤 순서로 되살리는가"
description: "경고 단계와 쓰기 거부, 강제 VACUUM 대응"
---

## 개요

애플리케이션의 에러 로그나 서버 로그에 이런 경고가 찍히기 시작합니다.

```text
WARNING:  database "template1" must be vacuumed within 3146471 transactions
HINT:  To avoid transaction ID assignment failures, execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
```

이 경고를 무시하면 어느 순간 모든 쓰기가 멈춥니다. PostgreSQL의 트랜잭션 ID는 32비트라서 약 21억 개마다 한 바퀴를 돌고, 오래된 행을 "얼리지"(freeze) 않은 채 한 바퀴를 돌면 과거의 행이 미래의 것으로 보이게 됩니다. 그런 일을 막으려고 PostgreSQL은 한계에 가까워지면 경고를 보내고, 끝내 새 트랜잭션 ID를 내주지 않습니다. 원리는 [인터널 6편](/posts/postgresql/06-xid-wraparound/)에서 다뤘고, 여기서는 이 경고를 받았을 때 무엇을 보고 어떻게 되살리는지를 다룹니다.

이 글에서 답할 질문은 다음과 같습니다.

- 지금 한계까지 얼마나 남았는지 어떻게 보는가
- 경고 단계와 쓰기 거부 단계에서는 각각 무엇이 되고 무엇이 안 되는가
- freeze가 진행되지 못하는 원인은 어떻게 찾는가
- 쓰기가 거부되었을 때 어떤 순서로 되살리는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

> **실습 방법**: 트랜잭션 ID 20억 개를 실제로 쓰는 대신, 서버를 멈추고 `pg_resetwal -x`로 다음 트랜잭션 ID를 한계 근처로 옮겼습니다. 실습을 위한 조작이며, **운영 서버에서 `pg_resetwal`을 쓰면 데이터를 잃을 수 있습니다.** 그 뒤의 경고, 에러, 복구 과정은 모두 실제 동작입니다.

## 먼저 확인할 것

### 한계까지 얼마나 남았는가

DB별로 가장 오래된, 얼리지 않은 트랜잭션 ID가 `pg_database.datfrozenxid`이고, 그 나이가 `age(datfrozenxid)`입니다. 21억 4748만(2³¹ − 1)에서 이 나이를 빼면 한계까지 남은 양입니다.

```psql
postgres=# SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
postgres-#        2147483647 - age(datfrozenxid) AS until_wraparound
postgres-# FROM pg_database ORDER BY age(datfrozenxid) DESC;
  datname  | datfrozenxid |  xid_age   | until_wraparound
-----------+--------------+------------+------------------
 postgres  |          744 | 2144337177 |          3146470
 template1 |          744 | 2144337177 |          3146470
 template0 |          744 | 2144337177 |          3146470
(3 rows)
```

같은 조회를 정상일 때 하면 이렇습니다.

```psql
postgres=# SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
postgres-#        2147483647 - age(datfrozenxid) AS until_wraparound
postgres-# FROM pg_database ORDER BY age(datfrozenxid) DESC;
  datname  | datfrozenxid | xid_age | until_wraparound
-----------+--------------+---------+------------------
 postgres  |          744 |      12 |       2147483635
 template1 |          744 |      12 |       2147483635
 template0 |          744 |      12 |       2147483635
(3 rows)
```

나이에 따라 PostgreSQL이 하는 일이 달라집니다.

| 나이 | 일어나는 일 | 관련 설정 |
|---|---|---|
| 1억 5천만 | 일반 VACUUM이 테이블 전체를 훑는 aggressive VACUUM으로 바뀜 | `vacuum_freeze_table_age` |
| 2억 | autovacuum이 꺼져 있어도 wraparound 방지 VACUUM을 강제로 시작 | `autovacuum_freeze_max_age` |
| 16억 | VACUUM이 failsafe 모드로 전환(인덱스 정리를 건너뛰고 속도 제한 해제) | `vacuum_failsafe_age` |
| 한계까지 4천만 | 트랜잭션 ID를 받을 때마다 `must be vacuumed within` 경고 | 고정 |
| 한계까지 300만 | 새 트랜잭션 ID 발급 거부 | 고정 |

설정값은 PostgreSQL 18의 기본값입니다.

```psql
postgres=# SELECT name, setting FROM pg_settings
postgres-# WHERE name IN ('autovacuum_freeze_max_age', 'vacuum_freeze_table_age', 'vacuum_failsafe_age')
postgres-# ORDER BY name;
           name            |  setting
---------------------------+------------
 autovacuum_freeze_max_age | 200000000
 vacuum_failsafe_age       | 1600000000
 vacuum_freeze_table_age   | 150000000
(3 rows)
```

**평소에 `age(datfrozenxid)`가 2억 근처에서 오르내리는 것은 정상**입니다. autovacuum이 2억에서 freeze하고 나이를 되돌리기 때문입니다. 2억을 한참 넘어 계속 올라간다면 freeze가 진행되지 못하고 있다는 뜻입니다.

### 무엇이 freeze를 막는가

VACUUM은 [4편](/posts/postgresql-ops/04-long-transactions/)의 xmin horizon보다 오래된 행만 얼릴 수 있습니다. 그러니 나이가 계속 오른다면 먼저 4편의 쿼리로 horizon을 붙잡는 것을 찾습니다.

```psql
postgres=# SELECT 'session' AS kind, pid::text AS id, age(backend_xid) AS xid_age, age(backend_xmin) AS xmin_age
postgres-# FROM pg_stat_activity WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
postgres-# UNION ALL
postgres-# SELECT 'prepared', gid, age(transaction), NULL FROM pg_prepared_xacts
postgres-# UNION ALL
postgres-# SELECT 'slot', slot_name, age(xmin), age(catalog_xmin) FROM pg_replication_slots
postgres-# ORDER BY 3 DESC NULLS LAST;
   kind   |    id    |  xid_age   | xmin_age
----------+----------+------------+----------
 prepared | batch-77 | 2144483638 |
(1 row)
```

이 실습에서는 21억 트랜잭션 전에 만들어진 prepared transaction `batch-77`이 남아 있었습니다. 운영에서도 몇 달 전 트랜잭션 관리자가 남기고 간 prepared transaction, 몇 주째 붙잡힌 replication slot, 며칠씩 열린 세션이 흔한 원인입니다. 그 밖에 autovacuum이 계속 취소되거나(락 충돌), 너무 느려서 큰 테이블을 끝내지 못하는 경우도 있습니다.

테이블 단위로는 `relfrozenxid`의 나이를 봅니다.

```psql
postgres=# SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age
postgres-# FROM pg_class c WHERE c.relkind IN ('r', 't', 'm')
postgres-# ORDER BY age(c.relfrozenxid) DESC LIMIT 3;
       table_name       |  xid_age
------------------------+------------
 pg_statistic           | 2144483649
 pg_type                | 2144483649
 pg_toast.pg_toast_1255 | 2144483649
(3 rows)
```

## 단계별 증상

### 경고 단계: 쓰기는 되지만 경고가 쏟아진다

한계까지 4천만이 남지 않으면, 트랜잭션 ID를 받는 모든 명령에 경고가 붙습니다.

```psql
postgres=# INSERT INTO orders (amount) VALUES (100);
WARNING:  database "template1" must be vacuumed within 3146471 transactions
HINT:  To avoid transaction ID assignment failures, execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
INSERT 0 1
```

INSERT는 성공합니다. 경고는 클라이언트와 서버 로그에 함께 남습니다. 서버 로그에는 DB 이름 대신 OID로 찍히기도 합니다.

```console
$ tail -n 3000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'must be vacuumed within' | head -n 1
2026-09-26 10:29:50.599 UTC [227] WARNING:  database with OID 1 must be vacuumed within 3146471 transactions
```

`HINT`가 해야 할 일을 정확히 알려 줍니다. 그 DB 전체를 VACUUM하고, 오래된 prepared transaction과 slot을 정리하라는 것입니다. **이 단계에서 해결해야 합니다.** 남은 여유는 트랜잭션 수로 셈하므로, 초당 수천 건을 처리하는 서버라면 몇 시간 만에 다음 단계로 넘어갑니다.

### 쓰기 거부: 새 트랜잭션 ID가 나오지 않는다

트랜잭션 ID를 쓰는 부하를 계속 주었습니다.

```console
$ echo 'SELECT pg_current_xact_id();' > /tmp/xid.sql
$ pgbench -n -c 4 -t 40000 -f /tmp/xid.sql postgres 2>&1 | grep -v 'must be vacuumed\|To avoid\|You might' | tail -n 4
latency average = 0.062 ms
initial connection time = 6.072 ms
tps = 64132.910544 (without initial connection time)
pgbench: error: Run was aborted; the above results are incomplete.
```

pgbench가 도중에 중단되었습니다. 이제 쓰기는 모두 거부됩니다.

```psql
postgres=# INSERT INTO orders (amount) VALUES (200);
ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "template1"
HINT:  Execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.

postgres=# SELECT count(*) FROM orders;
 count
-------
     1
(1 row)


postgres=# SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
postgres-#        2147483647 - age(datfrozenxid) AS until_wraparound
postgres-# FROM pg_database ORDER BY age(datfrozenxid) DESC;
  datname  | datfrozenxid |  xid_age   | until_wraparound
-----------+--------------+------------+------------------
 postgres  |          744 | 2144483649 |          2999998
 template1 |          744 | 2144483649 |          2999998
 template0 |          744 | 2144483649 |          2999998
(3 rows)
```

`until_wraparound`가 정확히 300만 남은 곳에서 멈췄습니다. 트랜잭션 ID가 필요 없는 **읽기는 계속 됩니다.** 새 트랜잭션 ID가 필요한 INSERT, UPDATE, DELETE, DDL이 모두 이 에러로 실패하므로 서비스 입장에서는 장애입니다.

## 조치

### 1. freeze를 막는 원인을 없앤다

VACUUM부터 돌리고 싶어지지만, 원인이 남아 있으면 VACUUM이 끝나도 나이가 내려가지 않습니다. 이 실습에서는 prepared transaction을 롤백합니다. [4편](/posts/postgresql-ops/04-long-transactions/)에서 말했듯 커밋할지 롤백할지는 트랜잭션 관리자 쪽에서 확인한 뒤 정합니다. `ROLLBACK PREPARED`는 새 트랜잭션 ID가 필요 없으므로 쓰기가 거부된 상태에서도 실행됩니다.

```psql
postgres=# ROLLBACK PREPARED 'batch-77';
ROLLBACK PREPARED
```

세션이라면 `pg_terminate_backend()`, slot이라면 `pg_drop_replication_slot()`으로 없앱니다.

### 2. 에러 메시지에 나온 DB를 VACUUM한다

VACUUM도 새 트랜잭션 ID가 필요 없으므로 이 상태에서 실행할 수 있습니다. 먼저 테이블 하나를 돌려 봅니다.

```psql
postgres=# VACUUM (VERBOSE) orders;
INFO:  aggressively vacuuming "postgres.public.orders"
WARNING:  bypassing nonessential maintenance of table "postgres.public.orders" as a failsafe after 0 index scans
DETAIL:  The table's relfrozenxid or relminmxid is too far in the past.
HINT:  Consider increasing configuration parameter "maintenance_work_mem" or "autovacuum_work_mem".
You might also need to consider other ways for VACUUM to keep up with the allocation of transaction IDs.
INFO:  finished vacuuming "postgres.public.orders": index scans: 0
pages: 0 removed, 1 remain, 1 scanned (100.00% of total), 0 eagerly scanned
tuples: 0 removed, 1 remain, 0 are dead but not yet removable
removable cutoff: 2144484393, which was 0 XIDs old when operation ended
new relfrozenxid: 2144337920, which is 2144337168 XIDs ahead of previous value
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
visibility map: 1 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
index scan bypassed by failsafe: 0 pages from table (0.00% of total) have 0 dead item identifiers
avg read rate: 0.000 MB/s, avg write rate: 104.866 MB/s
buffer usage: 56 hits, 0 reads, 4 dirtied
WAL usage: 5 records, 4 full page images, 33237 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
VACUUM
WARNING:  database "postgres" must be vacuumed within 2999998 transactions
HINT:  To avoid XID assignment failures, execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
```

`bypassing nonessential maintenance ... as a failsafe`는 나이가 `vacuum_failsafe_age`(16억)를 넘어 VACUUM이 **failsafe 모드**로 들어갔다는 뜻입니다. freeze를 최대한 빨리 끝내려고 인덱스 정리 같은 부수적인 일을 건너뛰고, 속도 제한(cost delay)도 풉니다. 경고처럼 보이지만 지금 상황에서는 바라던 동작입니다. 건너뛴 정리는 나중에 평소의 VACUUM이 합니다.

테이블 하나를 얼려도 DB의 `datfrozenxid`는 **모든 테이블 중 가장 오래된 값**이라 그대로입니다. DB 전체를 VACUUM합니다.

```console
$ vacuumdb --all > /tmp/vacuumdb.log 2>&1
$ grep -E '^vacuumdb:' /tmp/vacuumdb.log
$ grep -m 1 -A 3 'bypassing nonessential' /tmp/vacuumdb.log
$ grep -c 'bypassing nonessential' /tmp/vacuumdb.log
vacuumdb: vacuuming database "postgres"
vacuumdb: vacuuming database "template1"
WARNING:  bypassing nonessential maintenance of table "postgres.pg_catalog.pg_proc" as a failsafe after 0 index scans
DETAIL:  The table's relfrozenxid or relminmxid is too far in the past.
HINT:  Consider increasing configuration parameter "maintenance_work_mem" or "autovacuum_work_mem".
You might also need to consider other ways for VACUUM to keep up with the allocation of transaction IDs.
216
```

`vacuumdb --all`은 접속할 수 있는 모든 DB를 VACUUM합니다. 시스템 카탈로그까지 216개 테이블에서 failsafe가 켜졌습니다.

```psql
postgres=# SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
postgres-#        2147483647 - age(datfrozenxid) AS until_wraparound
postgres-# FROM pg_database ORDER BY age(datfrozenxid) DESC;
  datname  | datfrozenxid |  xid_age   | until_wraparound
-----------+--------------+------------+------------------
 template0 |          744 | 2144483649 |          2999998
 postgres  |   2144337920 |     146473 |       2147337174
 template1 |   2144484393 |          0 |       2147483647
(3 rows)


postgres=# INSERT INTO orders (amount) VALUES (250);
ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "template0"
HINT:  Execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
```

`postgres`와 `template1`은 되살아났지만 **여전히 쓰기가 거부됩니다.** 이번에는 `template0`이 이유입니다. 새 트랜잭션 ID 발급 한계는 모든 DB 가운데 가장 오래된 `datfrozenxid`로 정해지기 때문입니다.

### 3. template0은 autovacuum이 처리한다

`template0`은 접속을 받지 않는 DB(`datallowconn = false`)라서 `vacuumdb --all`이 건너뜁니다. 쓰기가 거부된 상태에서는 접속을 허용하도록 바꾸는 `ALTER DATABASE`도 새 트랜잭션 ID가 필요해서 실행할 수 없습니다. 이런 DB는 autovacuum이 wraparound 방지 VACUUM으로 처리합니다.

```console
$ tail -n 3000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'automatic aggressive vacuum to prevent wraparound of table "template0' | head -n 2
2026-09-26 10:30:26.142 UTC [387] LOG:  automatic aggressive vacuum to prevent wraparound of table "template0.pg_catalog.pg_statistic": index scans: 0
2026-09-26 10:30:26.143 UTC [387] LOG:  automatic aggressive vacuum to prevent wraparound of table "template0.pg_catalog.pg_type": index scans: 0
```

```psql
postgres=# SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
postgres-#        2147483647 - age(datfrozenxid) AS until_wraparound
postgres-# FROM pg_database ORDER BY age(datfrozenxid) DESC;
  datname  | datfrozenxid | xid_age | until_wraparound
-----------+--------------+---------+------------------
 postgres  |   2144337920 |  146473 |       2147337174
 template1 |   2144484393 |       0 |       2147483647
 template0 |   2144484393 |       0 |       2147483647
(3 rows)


postgres=# INSERT INTO orders (amount) VALUES (300);
INSERT 0 1

postgres=# SELECT count(*) FROM orders;
 count
-------
     2
(1 row)
```

26초 만에 autovacuum이 `template0`을 처리했고 쓰기가 돌아왔습니다. autovacuum은 wraparound 방지 VACUUM을 DB 하나씩 차례로 하므로, DB가 많고 크면 기다리는 시간이 길어집니다. 쓰기 거부 상태에서 할 수 있는 일은 **원인을 없애고, 접속 가능한 DB를 직접 VACUUM하고, 나머지는 autovacuum에 맡기는 것**입니다. autovacuum을 꺼 두었더라도 wraparound 방지 VACUUM은 돕니다.

예전 버전의 문서에는 서버를 단일 사용자 모드로 띄워 VACUUM하라는 안내가 있었지만, 지금 문서는 대부분의 경우 필요 없고 가능한 한 피하라고 말합니다([Preventing Transaction ID Wraparound Failures](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)). 이 실습도 서버를 멈추지 않고 되살렸습니다.

## 재발 방지

- **`age(datfrozenxid)` 감시**: DB별로 수집하고, 예를 들어 5억에서 경고, 10억에서 위험 알람을 겁니다. 평소 2억 근처를 오가는지, 계속 오르는지를 추세로 봅니다. 테이블 단위로는 `age(relfrozenxid)`가 큰 순서로 봅니다.
- **horizon 감시**: [4편](/posts/postgresql-ops/04-long-transactions/)의 쿼리로 오래된 세션, prepared transaction, slot을 감시합니다. wraparound 장애의 대부분은 여기서 시작합니다.
- **autovacuum이 wraparound 방지 VACUUM을 끝낼 수 있게**: 큰 테이블의 wraparound 방지 VACUUM이 락 충돌로 계속 취소되거나 너무 느리지 않은지 autovacuum 로그(`automatic aggressive vacuum to prevent wraparound`)로 확인합니다.
- **경고를 알람으로**: 서버 로그의 `must be vacuumed within`은 즉시 대응할 알람으로 걸어 둡니다. 경고 단계에서 해결하면 쓰기 거부까지 가지 않습니다.

## 정리

- `age(datfrozenxid)`로 한계까지 남은 양을 봅니다. 2억 근처는 정상이고, 계속 오르면 freeze가 막힌 것입니다.
- 한계까지 4천만이 남으면 `must be vacuumed within` 경고가, 300만이 남으면 `database is not accepting commands that assign new transaction IDs` 에러와 함께 쓰기 거부가 시작됩니다. 읽기는 계속 됩니다.
- freeze를 막는 원인(오래된 세션, prepared transaction, slot)을 먼저 없앱니다.
- 에러에 나온 DB를 VACUUM합니다. failsafe 경고는 VACUUM이 서두르고 있다는 뜻입니다.
- `vacuumdb --all`은 `template0`을 건너뜁니다. `template0`은 autovacuum이 처리하고, 가장 오래된 DB가 처리되어야 쓰기가 돌아옵니다.

## 참고 자료

- [Preventing Transaction ID Wraparound Failures](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)
- [vacuumdb](https://www.postgresql.org/docs/18/app-vacuumdb.html)
- [pg_resetwal](https://www.postgresql.org/docs/18/app-pgresetwal.html)
- PostgreSQL 인터널 [6편 트랜잭션 ID wraparound](/posts/postgresql/06-xid-wraparound/)

