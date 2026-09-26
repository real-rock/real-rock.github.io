---
title: "PostgreSQL 운영 8: standby가 뒤처진다"
date: 2026-09-26T19:35:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "복제", "standby", "conflict with recovery", "recovery still waiting"]
weight: 8
summary: "standby의 데이터가 늦을 때 어디서 늦는지 나눠 보고, 쿼리 취소와 primary bloat 사이에서 무엇을 고르는가"
description: "write/flush/replay lag, hot standby 충돌"
---

## 개요

standby에서 읽는 화면에 방금 쓴 데이터가 안 보인다는 신고가 오거나, 복제 지연 알람이 울립니다. standby는 primary가 보낸 WAL을 받아(write), 디스크에 확정하고(flush), 재생(replay)해야 데이터가 보입니다([인터널 9편](/posts/postgresql/09-streaming-replication/)). 어느 단계에서 늦는지에 따라 원인과 조치가 다릅니다.

이 글에서 답할 질문은 다음과 같습니다.

- 지연이 어느 단계에서 생기는지 어떻게 나눠 보는가
- `replay_lag`만 보면 안 되는 이유는 무엇인가
- standby의 쿼리가 왜 재생을 멈추고, 왜 취소되는가
- `hot_standby_feedback`을 켜면 무엇을 얻고 무엇을 잃는가
- standby가 멈추면 primary에는 무슨 일이 생기는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습에서는 primary와 standby를 따로 띄우고, `pg_basebackup`으로 standby를 만들었습니다. `-R`은 standby 설정(`standby.signal`, `primary_conninfo`)을 써 주고, `-C -S standby1`은 primary에 replication slot을 만듭니다. 명령 출력에서 `primary=#`와 `standby=#`로 어느 서버인지 구분합니다.

```console
$ pg_basebackup -h pgprimary -D $PGDATA -R -X stream -C -S standby1 -c fast
$ ls $PGDATA/standby.signal && grep primary_conninfo $PGDATA/postgresql.auto.conf
/var/lib/pgsql/18/data/standby.signal
primary_conninfo = 'user=postgres passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=pgprimary port=5432 sslmode=prefer sslnegotiation=postgres sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'
```

standby에는 충돌 대기를 기록하는 `log_recovery_conflict_waits`를 켜고, 충돌 시 최대 대기 시간 `max_standby_streaming_delay`를 실습에 맞게 10초로 줄였습니다(기본 30초).

```psql
standby=# SELECT name, setting FROM pg_settings WHERE name IN ('hot_standby_feedback', 'max_standby_streaming_delay', 'log_recovery_conflict_waits') ORDER BY name;
            name             | setting
-----------------------------+---------
 hot_standby_feedback        | off
 log_recovery_conflict_waits | on
 max_standby_streaming_delay | 10000
(3 rows)
```

## 먼저 확인할 것

### primary에서: pg_stat_replication

```psql
primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
     app     |   state   | sent_lsn  | replay_lsn |    write_lag    |    flush_lag    |   replay_lag    | replay_gap
-------------+-----------+-----------+------------+-----------------+-----------------+-----------------+------------
 walreceiver | streaming | 0/4000000 | 0/4000000  | 00:00:00.000029 | 00:00:00.000029 | 00:00:00.000029 | 0 bytes
(1 row)
```

| 컬럼 | 뜻 |
|---|---|
| `sent_lsn` | primary가 보낸 위치 |
| `write_lsn`, `flush_lsn` | standby가 받아 쓴 위치, 디스크에 확정한 위치 |
| `replay_lsn` | standby가 재생을 마친 위치. 여기까지가 standby에서 보임 |
| `write_lag`, `flush_lag`, `replay_lag` | 각 단계까지 걸린 시간 |

`write_lag`가 크면 네트워크나 standby의 수신이, `flush_lag`가 크면 standby의 디스크가, `replay_lag`만 크면 standby의 **재생**이 늦는 것입니다. 실제로 가장 흔한 것은 재생 지연이고, 이 글도 주로 그것을 다룹니다.

### standby에서: 받은 것과 재생한 것

```psql
standby=# SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed,
standby-#        pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS gap,
standby-#        now() - pg_last_xact_replay_timestamp() AS since_last_replay;
 received  | replayed  |   gap   | since_last_replay
-----------+-----------+---------+-------------------
 0/4000000 | 0/4000000 | 0 bytes |
(1 row)
standby=# SELECT status, sender_host, written_lsn, flushed_lsn FROM pg_stat_wal_receiver;
  status   | sender_host | written_lsn | flushed_lsn
-----------+-------------+-------------+-------------
 streaming | pgprimary   |             | 0/4000000
(1 row)
```

`pg_last_wal_receive_lsn()`과 `pg_last_wal_replay_lsn()`의 차이가 받았지만 아직 재생하지 못한 양입니다. `pg_last_xact_replay_timestamp()`는 마지막으로 재생한 트랜잭션이 primary에서 커밋된 시각입니다. 다만 primary에 쓰기가 없으면 재생할 것도 없으므로 이 값은 지연이 없어도 커집니다. 그래서 **바이트 차이와 함께 봐야** 합니다.

## 원인별 진단

### standby의 긴 쿼리가 재생을 멈춘다

standby에서 보고서 쿼리가 40초 동안 돌고 있습니다.

```psql
R=# SET application_name = 'report';
SET

R=# \timing on
Timing is on.

R=# SELECT count(*), pg_sleep(40) FROM acc;
```

그 사이 primary에서 같은 테이블의 행을 모두 고치고 VACUUM합니다.

```psql
primary=# UPDATE acc SET v = v + 1;
UPDATE 100000

primary=# VACUUM acc;
VACUUM
```

primary의 VACUUM이 지운 옛 버전은 WAL을 통해 standby에서도 지워져야 합니다. 그런데 standby의 보고서 쿼리는 스냅샷을 쥐고 있어서 그 옛 버전을 아직 볼 수도 있습니다. standby는 이 WAL을 재생하지 못하고 기다립니다. 이것이 **hot standby 충돌**(recovery conflict)입니다. 4초 뒤의 모습입니다.

```psql
primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
     app     |   state   | sent_lsn  | replay_lsn |   write_lag    |    flush_lag    |   replay_lag    | replay_gap
-------------+-----------+-----------+------------+----------------+-----------------+-----------------+------------
 walreceiver | streaming | 0/5B82970 | 0/5A829A0  | 00:00:00.00016 | 00:00:00.000472 | 00:00:00.206355 | 1024 kB
(1 row)
standby=# SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed,
standby-#        pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS gap,
standby-#        now() - pg_last_xact_replay_timestamp() AS since_last_replay;
 received  | replayed  |   gap   | since_last_replay
-----------+-----------+---------+-------------------
 0/5B82970 | 0/5A829A0 | 1024 kB | 00:00:04.236133
(1 row)
```

standby에서는 받은 WAL 가운데 1024 kB를 재생하지 못했고, 마지막 재생이 4.2초 전입니다. 그런데 primary의 `replay_lag`는 **0.2초**입니다. lag 시간 값은 standby가 재생을 진행하며 보고할 때 갱신되므로, **재생이 멈춘 동안에는 실제보다 작게 보입니다.** `replay_lag`만 보고 알람을 걸면 이런 순간을 놓칩니다. `sent_lsn`과 `replay_lsn`의 바이트 차이(`replay_gap`)를 같이 감시해야 합니다.

standby 로그에는 재생이 기다리기 시작했다는 기록이 남습니다(`log_recovery_conflict_waits`).

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'recovery still waiting|conflict' | tail -n 3
2026-09-26 10:34:48.936 UTC [34] LOG:  recovery still waiting after 1034.610 ms: recovery conflict on snapshot
```

`max_standby_streaming_delay`(10초)가 지나면 standby는 기다리기를 멈추고 **쿼리를 취소**합니다.

```psql
# 세션 R: 앞 명령의 결과를 기다림
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
Time: 11643.173 ms (00:11.643)
```

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'recovery conflict|canceling statement|finished waiting' | tail -n 4
2026-09-26 10:34:48.936 UTC [34] LOG:  recovery still waiting after 1034.610 ms: recovery conflict on snapshot
2026-09-26 10:34:58.712 UTC [72] postgres@postgres/report ERROR:  canceling statement due to conflict with recovery
2026-09-26 10:34:58.718 UTC [34] LOG:  recovery finished waiting after 10816.743 ms: recovery conflict on snapshot
```

재생은 10.8초 기다린 뒤 다시 진행했고, 보고서 쿼리는 11.6초 만에 에러로 끝났습니다. 곧 지연도 풀립니다.

```psql
primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
     app     |   state   | sent_lsn  | replay_lsn |    write_lag    |    flush_lag    |   replay_lag    | replay_gap
-------------+-----------+-----------+------------+-----------------+-----------------+-----------------+------------
 walreceiver | streaming | 0/5B829A8 | 0/5B829A8  | 00:00:00.000452 | 00:00:00.001044 | 00:00:01.961063 | 0 bytes
(1 row)
standby=# SELECT datname, confl_snapshot, confl_lock, confl_bufferpin, confl_deadlock FROM pg_stat_database_conflicts WHERE datname = 'postgres';
 datname  | confl_snapshot | confl_lock | confl_bufferpin | confl_deadlock
----------+----------------+------------+-----------------+----------------
 postgres |              1 |          0 |               0 |              0
(1 row)
```

`pg_stat_database_conflicts`의 `confl_snapshot`이 이번 취소를 셉니다. 충돌은 원인별로 따로 셉니다. `confl_snapshot`은 이번처럼 VACUUM이 지운 행 때문에, `confl_lock`은 primary의 `AccessExclusiveLock`(DROP, TRUNCATE 등) 때문에 생긴 충돌입니다.

standby에서 긴 쿼리를 돌리는 한 둘 중 하나를 골라야 합니다. **재생을 기다리게 해서 지연을 감수하거나, 쿼리를 취소하거나.** `max_standby_streaming_delay`가 그 경계입니다. 크게 잡으면 쿼리는 덜 취소되지만 지연이 그만큼 길어질 수 있고, `-1`이면 쿼리가 끝날 때까지 무한정 기다립니다.

### hot_standby_feedback: 취소 대신 primary가 대가를 치른다

세 번째 선택지가 `hot_standby_feedback`입니다. standby가 "나는 이 트랜잭션 ID 이후의 행을 아직 볼 수 있다"고 primary에 알려 주면, primary의 VACUUM이 그 행을 지우지 않으므로 충돌 자체가 생기지 않습니다.

```psql
standby=# ALTER SYSTEM SET hot_standby_feedback = on;
ALTER SYSTEM

standby=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)
```

같은 보고서 쿼리를 이번에는 20초 돌립니다.

```psql
R=# SELECT count(*), pg_sleep(20) FROM acc;
```

```psql
primary=# SELECT application_name AS app, backend_xmin FROM pg_stat_replication;
     app     | backend_xmin
-------------+--------------
 walreceiver |
(1 row)


primary=# SELECT slot_name, active, xmin, age(xmin) AS xmin_age FROM pg_replication_slots;
 slot_name | active | xmin | xmin_age
-----------+--------+------+----------
 standby1  | t      |  755 |        0
(1 row)
```

slot을 쓰는 standby의 피드백은 `pg_stat_replication.backend_xmin`이 아니라 **slot의 xmin**에 기록됩니다. primary에서 같은 UPDATE와 VACUUM을 합니다.

```psql
primary=# UPDATE acc SET v = v + 1;
UPDATE 100000

primary=# VACUUM (VERBOSE) acc;
INFO:  vacuuming "postgres.public.acc"
INFO:  finished vacuuming "postgres.public.acc": index scans: 0
pages: 0 removed, 885 remain, 885 scanned (100.00% of total), 0 eagerly scanned
tuples: 0 removed, 200000 remain, 100000 are dead but not yet removable
removable cutoff: 755, which was 1 XIDs old when operation ended
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
visibility map: 0 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
avg read rate: 0.000 MB/s, avg write rate: 0.000 MB/s
buffer usage: 1825 hits, 0 reads, 0 dirtied
WAL usage: 1 records, 0 full page images, 258 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
VACUUM

primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
     app     |   state   | sent_lsn  | replay_lsn |    write_lag    |    flush_lag    |   replay_lag    | replay_gap
-------------+-----------+-----------+------------+-----------------+-----------------+-----------------+------------
 walreceiver | streaming | 0/6F9E910 | 0/6F9E910  | 00:00:00.000104 | 00:00:00.000306 | 00:00:00.002368 | 0 bytes
(1 row)
```

지연은 없습니다. 대신 primary의 VACUUM이 `100000 are dead but not yet removable`로 **하나도 지우지 못했습니다.** `removable cutoff: 755`는 slot의 `xmin`과 같습니다. standby의 쿼리가 primary의 xmin horizon을 붙잡은 것으로, [4편](/posts/postgresql-ops/04-long-transactions/)에서 "찾는 쿼리"에 slot을 넣은 이유가 이것입니다.

```psql
# 세션 R: 앞 명령의 결과를 기다림
 count  | pg_sleep
--------+----------
 100000 |
(1 row)

Time: 20028.378 ms (00:20.028)
```

보고서 쿼리는 취소되지 않고 20초를 다 채웠습니다.

| 설정 | standby 쿼리 | 재생 지연 | primary |
|---|---|---|---|
| `max_standby_streaming_delay` 작게 | 자주 취소 | 짧음 | 영향 없음 |
| `max_standby_streaming_delay` 크게 | 덜 취소 | 길어질 수 있음 | 영향 없음 |
| `hot_standby_feedback = on` | 스냅샷 충돌로는 취소 안 됨 | 짧음 | dead tuple 정리가 밀려 bloat, wraparound 위험 |

`hot_standby_feedback`을 켰다면 standby에서 몇 시간씩 도는 쿼리가 primary 전체의 VACUUM을 막을 수 있다는 것을 기억해야 합니다. standby 쪽에도 `statement_timeout`이나 [4편](/posts/postgresql-ops/04-long-transactions/)의 타임아웃을 걸어 둡니다.

### standby가 멈추면 slot이 WAL을 붙잡는다

standby를 멈춥니다.

```console
$ pg_ctl -D $PGDATA -w stop -m fast
waiting for server to shut down.... done
server stopped
[exit=0]
```

```psql
primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
 app | state | sent_lsn | replay_lsn | write_lag | flush_lag | replay_lag | replay_gap
-----+-------+----------+------------+-----------+-----------+------------+------------
(0 rows)
```

`pg_stat_replication`에서 standby가 사라졌습니다. **이 뷰는 연결된 standby만 보여 주므로, 지연 알람을 이 뷰의 lag 값에만 걸면 standby가 끊겼을 때 오히려 조용해집니다.** 그동안 primary에 쓰기가 계속되면 slot이 WAL을 붙잡습니다.

```console
$ pgbench -i -s 10 -q postgres 2>&1 | tail -n 1
done in 0.50 s (drop tables 0.00 s, create tables 0.01 s, client-side generate 0.36 s, vacuum 0.03 s, primary keys 0.10 s).
```

```psql
primary=# SELECT slot_name, active, restart_lsn,
primary-#        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
primary-# FROM pg_replication_slots;
 slot_name | active | restart_lsn | retained
-----------+--------+-------------+----------
 standby1  | f      | 0/6FEEFC8   | 123 MB
(1 row)
```

`active = f`, `retained` 123 MB입니다. 이 상태가 오래가면 [6편](/posts/postgresql-ops/06-disk-full/)처럼 primary의 디스크가 찹니다. standby를 다시 띄우면 붙잡혀 있던 WAL부터 받아 따라잡습니다.

```console
$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
waiting for server to start.... done
server started
[exit=0]
```

```psql
primary=# SELECT application_name AS app, state, sent_lsn, replay_lsn,
primary-#        write_lag, flush_lag, replay_lag,
primary-#        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
primary-# FROM pg_stat_replication;
     app     |   state   | sent_lsn  | replay_lsn |    write_lag    |    flush_lag    |   replay_lag    | replay_gap
-------------+-----------+-----------+------------+-----------------+-----------------+-----------------+------------
 walreceiver | streaming | 0/EB0ED18 | 0/EB0ED18  | 00:00:00.136627 | 00:00:00.138404 | 00:00:00.213931 | 0 bytes
(1 row)
```

이 실습에서는 123 MB를 1초 안에 따라잡았습니다. 끊긴 시간이 길어 WAL이 수십 GB 쌓였다면 따라잡는 데도 그만큼 걸리고, 그동안 standby의 데이터는 오래된 상태입니다.

## 조치

| 증상 | 확인 | 조치 |
|---|---|---|
| `write_lag`, `flush_lag`가 큼 | 네트워크 대역폭, standby 디스크 I/O | 네트워크·디스크 증설, WAL 양 줄이기(대량 작업 분산) |
| `replay_lag`와 `replay_gap`이 큼, 충돌 대기 로그 | standby 로그의 `recovery still waiting`, `pg_stat_database_conflicts` | standby의 긴 쿼리 정리, `max_standby_streaming_delay` 조정 |
| 충돌 없이 재생만 느림 | standby의 CPU, I/O | standby 자원 확인. 재생은 프로세스 하나가 순서대로 하므로 쓰기가 많으면 따라가지 못할 수 있음 |
| standby 쿼리가 자주 취소됨 | `canceling statement due to conflict with recovery` | 쿼리를 짧게, 지연 허용치 조정, 또는 `hot_standby_feedback`(primary 영향 감수) |
| standby가 끊김 | `pg_stat_replication`에 없음, slot `active = f` | standby 복구. 오래 걸리면 `max_slot_wal_keep_size`로 primary 보호([6편](/posts/postgresql-ops/06-disk-full/)) |

## 재발 방지

- **바이트 지연을 감시**합니다. primary에서 `pg_wal_lsn_diff(sent_lsn, replay_lsn)`, standby에서 `pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())`. 시간 값(`replay_lag`)은 재생이 멈추면 늦게 반응합니다.
- **연결 여부를 따로 감시**합니다. `pg_stat_replication`의 행 수, slot의 `active`, `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)`.
- **충돌을 기록**합니다. standby에 `log_recovery_conflict_waits = on`, `pg_stat_database_conflicts` 수집.
- **standby 쿼리에도 타임아웃**을 겁니다. 특히 `hot_standby_feedback = on`이면 standby의 긴 쿼리가 primary를 부풀립니다.
- 보고서처럼 오래 도는 쿼리를 standby에 보낸다면, 그 standby는 지연 허용치를 크게 잡고 장애 조치(failover) 대상과 분리하는 것도 방법입니다.

## 정리

- 지연은 write, flush, replay 단계로 나눠 봅니다. 대부분은 replay 지연입니다.
- `replay_lag`는 재생이 멈춘 동안 실제보다 작게 보입니다. 바이트 차이(`replay_gap`)와 standby의 받은/재생한 위치를 같이 봅니다.
- standby의 긴 쿼리는 primary의 VACUUM이 지운 행을 볼 수 있으므로 재생을 멈춥니다. `max_standby_streaming_delay`가 지나면 쿼리가 `canceling statement due to conflict with recovery`로 취소됩니다.
- `hot_standby_feedback = on`이면 취소되지 않는 대신 primary의 VACUUM이 `dead but not yet removable`로 막힙니다.
- standby가 끊기면 `pg_stat_replication`에서 사라지고 slot이 WAL을 붙잡습니다. 연결 여부와 slot을 따로 감시합니다.

## 참고 자료

- [Log-Shipping Standby Servers](https://www.postgresql.org/docs/18/warm-standby.html)
- [Hot Standby](https://www.postgresql.org/docs/18/hot-standby.html): 쿼리 충돌 처리
- [pg_stat_replication](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW), [pg_stat_database_conflicts](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-CONFLICTS-VIEW)
- [Replication 설정](https://www.postgresql.org/docs/18/runtime-config-replication.html): `max_standby_streaming_delay`, `hot_standby_feedback`
- [pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
- PostgreSQL 인터널 [9편 스트리밍 복제와 Replication Slot](/posts/postgresql/09-streaming-replication/)

