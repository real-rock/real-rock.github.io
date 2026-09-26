---
title: "PostgreSQL 운영 11: 메모리가 모자란다"
date: 2026-09-26T19:53:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "메모리", "work_mem", "terminated by signal 9", "crash of another server process"]
weight: 11
summary: "쿼리 몇 개 때문에 모든 세션이 끊겼다면, 메모리를 누가 얼마나 쓰는지 보고 한도를 어떻게 잡는가"
description: "work_mem, OOM으로 backend가 죽을 때의 크래시 재시작"
---

## 개요

어느 순간 모든 애플리케이션의 DB 연결이 한꺼번에 끊기고, 몇 초 뒤 다시 접속됩니다. 서버 로그에는 `terminated by signal 9: Killed`가 남아 있습니다. 메모리가 모자라 운영체제가 PostgreSQL 프로세스 하나를 강제로 죽였고, 그 때문에 PostgreSQL이 **모든** 세션을 끊고 장애 복구를 한 것입니다. 원인은 대개 `work_mem`을 크게 잡은 쿼리 몇 개가 동시에 돈 것입니다.

이 글에서 답할 질문은 다음과 같습니다.

- `work_mem`은 정확히 무엇의 한도이고, 한 쿼리가 실제로 얼마나 쓸 수 있는가
- 실행 중인 세션이 메모리를 얼마나 쓰는지 어떻게 보는가
- backend 하나가 OOM으로 죽으면 왜 모든 세션이 끊기는가
- `work_mem`을 어떻게 잡아야 하는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

> **실습 환경과 실제 서버의 차이**: 이 실습은 메모리를 768 MB로 제한한 컨테이너에서 돌았습니다. 메모리가 모자라면 서버 전체의 OOM killer가 아니라 **컨테이너(cgroup)의 메모리 제한**이 프로세스를 죽입니다. 누가 죽는지 고르는 방식과 로그는 다르지만, PostgreSQL 쪽에서 일어나는 일(backend가 `SIGKILL`로 죽고 전체가 재시작되는 것)은 같습니다.

```console
$ cat /sys/fs/cgroup/memory.max
805306368
```

실습 테이블은 300만 행, 서로 다른 값 300만 개인 `k` 컬럼으로 GROUP BY합니다. 결과를 일정하게 보려고 병렬 쿼리는 껐습니다.

```psql
postgres=# SELECT name, setting, unit FROM pg_settings
postgres-# WHERE name IN ('shared_buffers', 'work_mem', 'hash_mem_multiplier', 'maintenance_work_mem', 'max_connections')
postgres-# ORDER BY name;
         name         | setting | unit
----------------------+---------+------
 hash_mem_multiplier  | 2       |
 maintenance_work_mem | 65536   | kB
 max_connections      | 100     |
 shared_buffers       | 16384   | 8kB
 work_mem             | 4096    | kB
(5 rows)
postgres=# CREATE TABLE big AS SELECT g AS id, md5(g::text) AS k FROM generate_series(1, 3000000) g;
SELECT 3000000

postgres=# VACUUM ANALYZE big;
VACUUM

postgres=# SELECT pg_size_pretty(pg_table_size('big')) AS big;
  big
--------
 196 MB
(1 row)
```

## 먼저 확인할 것

### work_mem은 연산 하나의 한도다

`work_mem`은 쿼리 하나가 아니라 **정렬이나 해시 연산 하나**가 디스크로 넘치기 전에 쓸 수 있는 메모리입니다. 기본값 4 MB로 GROUP BY를 돌립니다.

```psql
postgres=# SET work_mem = '4MB';
postgres-# EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;
SET
                                 QUERY PLAN
----------------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=2304 read=22720, temp read=18844 written=42391
   ->  HashAggregate (actual rows=3000000.00 loops=1)
         Group Key: big.k
         Batches: 65  Memory Usage: 8217kB  Disk Usage: 191832kB
         Buffers: shared hit=2304 read=22720, temp read=18844 written=42391
         ->  Seq Scan on big (actual rows=3000000.00 loops=1)
               Buffers: shared hit=2304 read=22720
 Planning:
   Buffers: shared hit=105 read=4
 Planning Time: 0.195 ms
 Execution Time: 693.372 ms
(12 rows)
```

`Batches: 65`, `Disk Usage: 191832kB`는 메모리에 다 들어가지 않아 65번에 나눠 디스크를 쓰며 처리했다는 뜻입니다. 그런데 `Memory Usage`가 **8217kB**, 4 MB의 두 배입니다. 해시 연산은 `work_mem` × `hash_mem_multiplier`(기본 2)까지 쓸 수 있기 때문입니다([hash_mem_multiplier](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-HASH-MEM-MULTIPLIER)). `work_mem`을 1 GB로 올립니다.

```psql
postgres=# SET work_mem = '1GB';
postgres-# EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;
SET
                          QUERY PLAN
--------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=2398 read=22626
   ->  HashAggregate (actual rows=3000000.00 loops=1)
         Group Key: big.k
         Batches: 1  Memory Usage: 237593kB
         Buffers: shared hit=2398 read=22626
         ->  Seq Scan on big (actual rows=3000000.00 loops=1)
               Buffers: shared hit=2398 read=22626
 Planning:
   Buffers: shared hit=109
 Planning Time: 0.169 ms
 Execution Time: 656.771 ms
(12 rows)
```

이번에는 `Batches: 1`, **232 MB**(237593 kB)를 메모리에서 썼습니다. 한도를 올리면 필요한 만큼 씁니다. 이 실습에서는 임시 파일이 운영체제 캐시에 남아 있어서 두 경우의 실행 시간 차이가 거의 없었습니다. 실제 디스크를 거쳐야 한다면 디스크로 넘치는 쪽이 느려집니다.

쿼리 하나가 쓸 수 있는 메모리는 이렇게 곱해집니다.

- 쿼리 안의 **정렬·해시 노드 수**만큼(조인과 집계가 여럿이면 각각)
- 해시 노드는 **`hash_mem_multiplier`배**
- 병렬 쿼리면 **worker 수만큼**(각 worker가 따로 한도를 가짐)
- 그리고 이런 쿼리를 동시에 실행하는 **세션 수만큼**

### 실행 중인 세션의 메모리 보기

`work_mem`을 1 GB로 둔 세션이 같은 GROUP BY를 실행하는 동안 봅니다. 해시 테이블을 다 만든 뒤 출력 단계만 몇 초 걸리도록 조건을 붙였습니다.

```psql
A=# SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k HAVING md5(md5(md5(md5(md5(md5(k)))))) IS NOT NULL) s;
```

OS에서는 프로세스의 RSS를, 컨테이너 전체로는 cgroup의 사용량을 봅니다.

```console
$ ps -o pid,rss,cmd -p $(psql -XAtc "SELECT pid FROM pg_stat_activity WHERE application_name = 'report'")
$ cat /sys/fs/cgroup/memory.current
    PID   RSS CMD
    132 134908 postgres: postgres postgres [local] SELECT
699432960
```

RSS 132 MB(134908 kB)에는 이 backend가 건드린 shared buffers도 들어 있어서 정확한 개인 메모리 사용량이 아닙니다([인터널 1편](/posts/postgresql/01-process-architecture/)). cgroup 사용량(약 667 MB)에는 운영체제 캐시도 들어 있습니다. PostgreSQL 안에서 보려면 `pg_log_backend_memory_contexts()`로 그 backend의 메모리 컨텍스트를 서버 로그에 남기게 합니다(PostgreSQL 14부터).

```psql
postgres=# SELECT pg_log_backend_memory_contexts(pid) FROM pg_stat_activity WHERE application_name = 'report';
 pg_log_backend_memory_contexts
--------------------------------
 t
(1 row)


# 세션 A: 앞 명령의 결과를 기다림
  count
---------
 3000000
(1 row)

Time: 6000.451 ms (00:06.000)
```

```console
$ tail -n 1000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'Grand total|level: 1; ExecutorState|level: [0-9]+; HashAgg' | tail -n 4
2026-09-26 10:52:35.436 UTC [132] postgres@postgres/report LOG:  level: 5; HashAgg table context: 58720144 total in 17 blocks; 7620496 free; 51099648 used
2026-09-26 10:52:35.436 UTC [132] postgres@postgres/report LOG:  level: 5; HashAgg meta context: 67117104 total in 2 blocks; 4456 free (0 chunks); 67112648 used
2026-09-26 10:52:35.436 UTC [132] postgres@postgres/report LOG:  Grand total: 127374888 bytes in 276 blocks; 8061392 free (305 chunks); 119313496 used
```

해시 집계가 쓰는 컨텍스트(`HashAgg table context`, `HashAgg meta context`)와 backend 전체의 합계(`Grand total`, 사용량 119313496바이트))가 남았습니다. 자기 세션이라면 `pg_backend_memory_contexts` 뷰로 바로 조회할 수 있습니다. 어느 세션이 메모리를 많이 쓰는지 의심될 때 이렇게 확인합니다.

## 원인: 동시에 돌면 곱해진다

`work_mem` 1 GB로 같은 쿼리를 네 세션에서 동시에 돌립니다. 하나가 230 MB 안팎을 쓰므로 넷이면 컨테이너 한도(768 MB)를 넘습니다.

```console
$ cat /sys/fs/cgroup/memory.events
low 0
high 0
max 15
oom 0
oom_kill 0
oom_group_kill 0
sock_throttled 0
[exit=0]
```

```psql
postgres=# SELECT pg_postmaster_start_time();
   pg_postmaster_start_time
------------------------------
 2026-09-26 10:52:22.35438+00
(1 row)
```

```console
$ for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=1GB' nohup psql -X -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/heavy_$i.out 2>&1 & done
$ sleep 25
$ cat /tmp/heavy_1.out /tmp/heavy_2.out /tmp/heavy_3.out /tmp/heavy_4.out
WARNING:  terminating connection because of crash of another server process
DETAIL:  The postmaster has commanded this server process to roll back the current transaction and exit, because another server process exited abnormally and possibly corrupted shared memory.
HINT:  In a moment you should be able to reconnect to the database and repeat your command.
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
[exit=0]
```

네 세션 모두 연결이 끊겼습니다. 일부는 `terminating connection because of crash of another server process`라는 경고를 받았습니다. 자기 잘못이 아니라 **다른 프로세스가 죽어서** 끊긴다는 뜻입니다. cgroup은 OOM으로 프로세스를 죽인 횟수를 셉니다.

```console
$ cat /sys/fs/cgroup/memory.events
low 0
high 0
max 1505
oom 13
oom_kill 3
oom_group_kill 0
sock_throttled 0
[exit=0]
```

서버 로그를 보면 순서가 분명합니다.

```console
$ tail -n 1000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'terminated by signal|Failed process|terminating any other|all server processes terminated|not properly shut down|redo done|ready to accept' | tail -n 8
2026-09-26 10:52:22.358 UTC [26] LOG:  database system is ready to accept connections
2026-09-26 10:52:44.770 UTC [26] LOG:  client backend (PID 299) was terminated by signal 9: Killed
2026-09-26 10:52:44.770 UTC [26] DETAIL:  Failed process was running: SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;
2026-09-26 10:52:44.770 UTC [26] LOG:  terminating any other active server processes
2026-09-26 10:52:44.777 UTC [26] LOG:  all server processes terminated; reinitializing
2026-09-26 10:52:44.818 UTC [305] LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-26 10:52:45.628 UTC [305] LOG:  redo done at 0/12C9CD40 system usage: CPU: user: 0.59 s, system: 0.20 s, elapsed: 0.80 s
2026-09-26 10:52:45.770 UTC [26] LOG:  database system is ready to accept connections
```

1. backend 하나(PID 299)가 `signal 9: Killed`로 죽었습니다. `DETAIL`에 그 backend가 실행하던 쿼리가 남습니다.
2. postmaster는 **다른 모든 프로세스를 끝냅니다.** backend가 `SIGKILL`로 죽으면 공유 메모리를 어떤 상태로 남겼는지 알 수 없으므로, 공유 메모리를 쓰는 모든 프로세스를 믿을 수 없다고 보기 때문입니다([인터널 1편](/posts/postgresql/01-process-architecture/)).
3. 공유 메모리를 다시 만들고 장애 복구(WAL 재생)를 한 뒤 1초 안에 다시 접속을 받습니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).

postmaster 자체는 죽지 않았으므로 시작 시각은 그대로입니다.

```psql
postgres=# SELECT pg_postmaster_start_time(), now();
   pg_postmaster_start_time   |             now
------------------------------+------------------------------
 2026-09-26 10:52:22.35438+00 | 2026-09-26 10:53:09.60796+00
(1 row)
```

**모니터링에서 "서버가 재시작되지 않았다"고 보이더라도, 모든 세션이 끊기고 진행 중이던 트랜잭션이 모두 롤백된 사건**입니다. 로그의 `terminated by signal`, `all server processes terminated; reinitializing`을 알람으로 걸어 두어야 알 수 있습니다. 또 장애 복구를 하면 `pg_stat_*` 누적 통계가 초기화되므로, 이전 추세와 비교할 때 이 시점을 표시해 둬야 합니다.

## 조치

### work_mem을 동시 실행 수에 맞춰 잡는다

같은 네 쿼리를 `work_mem` 16 MB로 돌립니다.

```console
$ for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=16MB' nohup psql -X -c "\\timing on" -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/small_$i.out 2>&1 & done
$ sleep 25
$ cat /tmp/small_1.out /tmp/small_2.out /tmp/small_3.out /tmp/small_4.out
$ cat /sys/fs/cgroup/memory.events
Timing is on.
  count
---------
 3000000
(1 row)

Time: 1215.095 ms (00:01.215)
Timing is on.
  count
---------
 3000000
(1 row)

Time: 1256.357 ms (00:01.256)
Timing is on.
  count
---------
 3000000
(1 row)

Time: 1253.183 ms (00:01.253)
Timing is on.
  count
---------
 3000000
(1 row)

Time: 1232.279 ms (00:01.232)
low 0
high 0
max 4855
oom 20
oom_kill 5
oom_group_kill 0
sock_throttled 0
[exit=0]
```

```psql
postgres=# SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes FROM pg_stat_database WHERE datname = 'postgres';
 datname  | temp_files | temp_bytes
----------+------------+------------
 postgres |          4 | 569 MB
(1 row)
```

네 쿼리가 모두 1.2초 안팎에 끝났고, 대신 임시 파일 569 MB를 썼습니다. `oom_kill`은 늘지 않았습니다. 1단계의 EXPLAIN도 임시 파일을 썼는데 여기에는 4개만 남은 것은, 앞의 장애 복구로 누적 통계가 초기화되었기 때문입니다. **느려지는 쿼리 몇 개와, 모든 세션이 끊기는 장애**를 맞바꾼 것입니다.

16 MB 전에 64 MB로도 돌려 봤는데, 그때도 OOM이 났습니다.

```console
$ for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=64MB' nohup psql -X -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/mid_$i.out 2>&1 & done
$ sleep 25
$ grep -h -E 'count|server closed|crash of another' /tmp/mid_1.out /tmp/mid_2.out /tmp/mid_3.out /tmp/mid_4.out
$ grep oom_kill /sys/fs/cgroup/memory.events
WARNING:  terminating connection because of crash of another server process
server closed the connection unexpectedly
WARNING:  terminating connection because of crash of another server process
server closed the connection unexpectedly
server closed the connection unexpectedly
server closed the connection unexpectedly
oom_kill 5
[exit=0]
```

`oom_kill`이 3에서 5로 늘었습니다. 해시 노드 한도가 64 MB × 2 = 128 MB이고, 넷이면 512 MB에 shared buffers 128 MB와 운영체제 몫이 더해져 768 MB에 닿기 때문입니다. **`hash_mem_multiplier`를 빼고 계산하면 틀립니다.**

`work_mem`을 정하는 방법은 이렇습니다.

1. 서버 메모리에서 shared buffers와 운영체제 몫(캐시 포함)을 뺀 나머지가 쿼리들이 쓸 수 있는 메모리입니다.
2. 그것을 **동시에 무거운 쿼리를 돌릴 수 있는 세션 수**와 쿼리당 정렬·해시 노드 수로 나눕니다. `max_connections` 전부가 동시에 큰 쿼리를 돌리지는 않지만, 최악을 가정할수록 안전합니다.
3. 전역 값은 작게 두고, 큰 메모리가 필요한 작업(배치, 보고서)은 **그 계정이나 세션에서만** 올립니다.

```sql
ALTER ROLE report SET work_mem = '256MB';
-- 또는 작업 안에서만
SET LOCAL work_mem = '256MB';
```

`maintenance_work_mem`(VACUUM, CREATE INDEX)과 autovacuum worker 수도 같은 계산에 넣습니다.

### OOM killer가 postmaster를 고르지 않게

실제 서버에서 서버 전체의 OOM killer가 개입하면, 가장 메모리를 많이 쓰는 프로세스를 고릅니다. 운이 나쁘면 postmaster가 죽고, 그러면 재시작이 아니라 서버가 **내려갑니다.** PostgreSQL 문서는 두 가지를 권합니다([Linux Memory Overcommit](https://www.postgresql.org/docs/18/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT)).

- **`vm.overcommit_memory = 2`**: 커널이 메모리를 약속 이상으로 내주지 않게 해서, 메모리가 모자라면 OOM killer 대신 할당 요청이 실패하게 합니다. 이때 PostgreSQL은 그 쿼리만 `out of memory` 에러로 끝냅니다. 이 실습은 컨테이너라 커널 설정을 바꿀 수 없어 재현하지 못했습니다.
- **postmaster의 OOM 점수 조정**: postmaster의 `oom_score_adj`를 -1000으로 두어 OOM killer의 대상에서 빼고, backend는 기본값(0)으로 되돌립니다. PGDG 패키지의 systemd 서비스 파일이 이 설정을 담고 있습니다.

```console
$ grep -n -i -A 1 'oom' /usr/lib/systemd/system/postgresql-18.service
36:# Disable OOM kill on postgres main process
37:OOMScoreAdjust=-1000
38:Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
39:Environment=PG_OOM_ADJUST_VALUE=0
```

systemd로 띄우면 적용되므로, `pg_ctl`로 직접 띄우는 스크립트를 쓰고 있다면 이 설정이 빠져 있지 않은지 확인합니다.

## 재발 방지

- **로그 알람**: `terminated by signal 9`, `all server processes terminated; reinitializing`. 이 두 줄은 모든 세션이 끊겼다는 뜻입니다.
- **OS 쪽 기록**: 서버라면 커널 로그(`dmesg`, journal)의 OOM killer 기록, 컨테이너라면 cgroup의 `memory.events`(`oom_kill`).
- **메모리 사용 추세**: 서버의 가용 메모리, 큰 쿼리가 몰리는 시간대. 의심되는 세션은 `pg_log_backend_memory_contexts()`.
- **임시 파일**: `work_mem`을 줄이면 임시 파일이 늘어납니다. `log_temp_files`와 `pg_stat_database.temp_bytes`로 보고, 디스크는 [6편](/posts/postgresql-ops/06-disk-full/)의 `temp_file_limit`로 보호합니다.
- **커넥션 수**: 동시에 무거운 쿼리를 돌리는 세션 수를 커넥션 풀 크기로 제한합니다([9편](/posts/postgresql-ops/09-connection-failures/)).

## 정리

- `work_mem`은 정렬·해시 연산 하나의 한도이고, 해시는 `hash_mem_multiplier`(기본 2)배까지 씁니다. 노드 수, 병렬 worker 수, 동시 세션 수만큼 곱해집니다.
- 실행 중인 세션의 메모리는 `pg_log_backend_memory_contexts()`로 서버 로그에 남겨 봅니다. RSS에는 shared buffers가 섞여 있습니다.
- backend 하나가 OOM으로 `signal 9`를 받으면 postmaster가 모든 세션을 끊고 장애 복구를 합니다. 다른 세션은 `crash of another server process`를 받고, 누적 통계는 초기화됩니다.
- `work_mem`은 전역으로 작게, 필요한 계정·세션에서만 크게 잡습니다. 계산할 때 `hash_mem_multiplier`를 빼먹지 않습니다.
- 실제 서버에서는 `vm.overcommit_memory = 2`와 postmaster의 OOM 점수 조정으로 OOM killer의 개입을 막습니다.

## 참고 자료

- [Resource Consumption](https://www.postgresql.org/docs/18/runtime-config-resource.html): `work_mem`, `hash_mem_multiplier`, `maintenance_work_mem`
- [Linux Memory Overcommit](https://www.postgresql.org/docs/18/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT)
- [pg_log_backend_memory_contexts](https://www.postgresql.org/docs/18/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL), [pg_backend_memory_contexts](https://www.postgresql.org/docs/18/view-pg-backend-memory-contexts.html)
- PostgreSQL 인터널 [1편 프로세스 구조](/posts/postgresql/01-process-architecture/), [2편 메모리 구조](/posts/postgresql/02-memory-architecture/), [8편 체크포인트와 장애 복구](/posts/postgresql/08-checkpoint-and-recovery/)

