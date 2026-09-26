---
title: "PostgreSQL 운영 1: 진단 도구상자"
date: 2026-09-26T08:00:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "모니터링", "pg_stat_statements", "still waiting for", "could not access file", "temporary file"]
weight: 1
summary: "장애가 났을 때 원인을 찾으려면 무엇을 미리 켜 두고, 어디부터 봐야 하는가"
description: "미리 켜 둘 로그 설정, pg_stat_activity와 wait event, pg_stat_statements, pg_stat_io"
---

## 개요

장애가 나면 가장 먼저 부딪히는 문제는 "지금 무슨 일이 일어나고 있는지 볼 수단이 없다"는 것입니다. 로그에 아무것도 남지 않았거나, 필요한 확장이 설치되어 있지 않거나, 설치하려면 재시작이 필요한 경우가 많습니다. 이 연재의 나머지 편은 모두 여기서 준비하는 도구를 가져다 씁니다.

이 글에서 답할 질문은 다음과 같습니다.

- PGDG 패키지로 설치한 직후에는 무엇이 기록되고 무엇이 기록되지 않는가
- 장애 전에 미리 켜 둘 설정은 무엇이고, 켤 때 어떤 실수로 서버가 뜨지 않게 되는가
- `pg_stat_activity`의 state와 wait event로 "누가 무엇을 기다리는지" 어떻게 읽는가
- `pg_stat_statements`, 서버 로그, `auto_explain`, `pg_stat_io`는 각각 무엇을 알려 주는가
- 같은 순간 OS에서는 무엇을 봐야 하는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

## 설치 직후 무엇이 기록되는가

`pg_settings`의 `boot_val`은 PostgreSQL에 컴파일된 기본값이고, `source`는 지금 값이 어디서 왔는지입니다. 둘을 같이 보면 설치 패키지가 무엇을 바꿔 놓았는지 알 수 있습니다.

```psql
postgres=# SELECT name, setting, boot_val, source FROM pg_settings
postgres-# WHERE name IN ('logging_collector', 'log_directory', 'log_filename',
postgres-#                'log_rotation_age', 'log_rotation_size', 'log_truncate_on_rotation',
postgres-#                'log_line_prefix', 'log_lock_waits', 'log_autovacuum_min_duration',
postgres-#                'log_checkpoints', 'log_temp_files', 'log_min_duration_statement',
postgres-#                'track_io_timing', 'shared_preload_libraries', 'deadlock_timeout')
postgres-# ORDER BY source, name;
            name             |      setting      |            boot_val            |       source
-----------------------------+-------------------+--------------------------------+--------------------
 log_directory               | log               | log                            | configuration file
 log_filename                | postgresql-%a.log | postgresql-%Y-%m-%d_%H%M%S.log | configuration file
 logging_collector           | on                | off                            | configuration file
 log_line_prefix             | %m [%p]           | %m [%p]                        | configuration file
 log_rotation_age            | 1440              | 1440                           | configuration file
 log_rotation_size           | 0                 | 10240                          | configuration file
 log_truncate_on_rotation    | on                | off                            | configuration file
 deadlock_timeout            | 1000              | 1000                           | default
 log_autovacuum_min_duration | 600000            | 600000                         | default
 log_checkpoints             | on                | on                             | default
 log_lock_waits              | off               | off                            | default
 log_min_duration_statement  | -1                | -1                             | default
 log_temp_files              | -1                | -1                             | default
 shared_preload_libraries    |                   |                                | default
 track_io_timing             | off               | off                            | default
(15 rows)
```

`source`가 `configuration file`인 값은 initdb가 만든 `postgresql.conf`에 적혀 있는 값입니다. PGDG 패키지는 로그를 이렇게 바꿔 둡니다.

- `logging_collector = on`: 서버 로그를 데이터 디렉터리 아래 `log/` 파일로 모읍니다. 컴파일 기본값은 `off`라서 소스로 설치하면 로그가 표준 에러로 나갑니다.
- `log_filename = postgresql-%a.log`, `log_rotation_age = 1440`(하루), `log_truncate_on_rotation = on`: 요일 이름 파일에 하루씩 쓰고, 일주일 뒤 같은 요일이 오면 그 파일을 비우고 다시 씁니다. 문서가 "일주일치 로그를 요일별 파일로 보관"하는 예로 드는 조합입니다([log_truncate_on_rotation](https://www.postgresql.org/docs/18/runtime-config-logging.html#GUC-LOG-TRUNCATE-ON-ROTATION)).
- `log_rotation_size = 0`: 크기로는 파일을 바꾸지 않습니다.

```console
$ ls -l $PGDATA/log
total 4
-rw------- 1 postgres postgres 693 Sep 25 23:06 postgresql-Fri.log
```

**로그는 일주일만 남습니다.** 장애를 8일 뒤에 조사하면 그날의 로그는 이미 덮어쓰였습니다. 오래 보관해야 한다면 로그 파일을 따로 수집해 두거나 `log_filename`을 날짜 형식으로 바꿔야 합니다.

`source`가 `default`인 쪽이 더 중요합니다. 장애를 진단할 때 필요한 정보가 기본값으로는 대부분 꺼져 있습니다.

| 설정 | 기본값 | 꺼져 있으면 잃는 것 |
|---|---|---|
| `log_lock_waits` | `off` | 락을 오래 기다린 세션과 락을 쥔 세션 |
| `log_temp_files` | `-1` | 메모리가 모자라 디스크로 넘친 정렬, 해시 |
| `log_min_duration_statement` | `-1` | 느린 쿼리 |
| `log_autovacuum_min_duration` | `600000`(10분) | 10분 안에 끝난 autovacuum의 기록 |
| `track_io_timing` | `off` | `EXPLAIN (BUFFERS)`와 통계 뷰의 I/O 시간 |
| `shared_preload_libraries` | 비어 있음 | `pg_stat_statements`, `auto_explain` |

`log_checkpoints`만 기본으로 켜져 있습니다. 로그 한 줄의 앞머리(`log_line_prefix`)는 `%m [%p]`, 즉 시각과 PID뿐이라 어느 사용자, 어느 DB, 어느 애플리케이션에서 나온 로그인지 알 수 없습니다.

## 진단용 설정 켜기

대부분은 `ALTER SYSTEM`과 설정 다시 읽기(`pg_reload_conf()`)로 바로 켜집니다.

```psql
postgres=# ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_temp_files = 0;
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_min_duration_statement = '500ms';
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_autovacuum_min_duration = 0;
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';
ALTER SYSTEM

postgres=# ALTER SYSTEM SET track_io_timing = on;
ALTER SYSTEM
```

`log_line_prefix`에 `%u@%d/%a`(사용자, DB, `application_name`)를 넣었습니다. 앞의 `%q`는 세션이 없는 프로세스(체크포인터, autovacuum 등)의 로그에서는 여기서부터를 찍지 말라는 표시입니다([log_line_prefix](https://www.postgresql.org/docs/18/runtime-config-logging.html#GUC-LOG-LINE-PREFIX)).

`track_io_timing`은 I/O마다 시간을 재므로, 시계를 읽는 비용이 비싼 플랫폼에서는 부담이 될 수 있습니다. 켜기 전에 `pg_test_timing`으로 그 비용을 재 보라고 문서가 권합니다([track_io_timing](https://www.postgresql.org/docs/18/runtime-config-statistics.html#GUC-TRACK-IO-TIMING)).

### 흔한 실수: shared_preload_libraries를 따옴표 하나로 묶기

`pg_stat_statements`와 `auto_explain`은 서버가 기동할 때 올라와야 하므로 `shared_preload_libraries`에 넣고 **재시작**해야 합니다. 여기서 많이 하는 실수가 목록 전체를 따옴표 하나로 묶는 것입니다.

```psql
postgres=# ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements, auto_explain';
ALTER SYSTEM
```

명령은 성공합니다. 이 설정은 재시작해야 바뀌므로 지금 값은 비어 있고, `pending_restart`만 `t`가 됩니다.

```psql
postgres=# SELECT name, setting, pending_restart FROM pg_settings
postgres-# WHERE name IN ('log_lock_waits', 'log_temp_files', 'shared_preload_libraries')
postgres-# ORDER BY name;
           name           | setting | pending_restart
--------------------------+---------+-----------------
 log_lock_waits           | on      | f
 log_temp_files           | 0       | f
 shared_preload_libraries |         | t
(3 rows)
```

파일에 무엇이 적혔는지 보면 문제가 드러납니다.

```console
$ grep shared_preload_libraries $PGDATA/postgresql.auto.conf
shared_preload_libraries = '"pg_stat_statements, auto_explain"'
```

따옴표로 묶은 값 전체가 큰따옴표에 싸여 **이름이 `pg_stat_statements, auto_explain`인 라이브러리 하나**가 되었습니다. 이 상태로 재시작하면 서버가 뜨지 않습니다.

```console
$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
waiting for server to shut down.... done
server stopped
waiting for server to start.... stopped waiting
pg_ctl: could not start server
Examine the log output.
$ tail -n 3 /var/lib/pgsql/startup.log
2026-09-25 23:06:35.414 UTC [26] HINT:  Future log output will appear in directory "log".
2026-09-25 23:06:36.468 UTC [145] FATAL:  could not access file "pg_stat_statements, auto_explain": No such file or directory
2026-09-25 23:06:36.468 UTC [145] LOG:  database system is shut down
```

에러 메시지 `could not access file "pg_stat_statements, auto_explain"`에 쉼표가 들어 있는 것이 단서입니다. 서버가 멈춘 상태에서는 `ALTER SYSTEM`을 쓸 수 없으므로, `postgresql.auto.conf`를 직접 고쳐야 합니다. 파일 머리에 "직접 고치지 말라"고 적혀 있지만, 서버가 뜨지 않을 때는 이것이 유일한 방법입니다.

```console
$ sed -i '/^shared_preload_libraries/d' $PGDATA/postgresql.auto.conf
$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
waiting for server to start.... done
server started
```

목록 값은 따옴표 없이 쉼표로 나열합니다.

```psql
postgres=# ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, auto_explain;
ALTER SYSTEM
```

```console
$ grep shared_preload_libraries $PGDATA/postgresql.auto.conf
shared_preload_libraries = 'pg_stat_statements, auto_explain'
$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
```

이번에는 `'pg_stat_statements, auto_explain'`으로, 두 이름이 쉼표로 나뉜 목록이 되었습니다. 운영 서버에서 이 실수를 하면 **다음 재시작 때** 서버가 내려간 채로 올라오지 않습니다. 설정을 바꾼 사람과 재시작하는 사람이 다를 수도 있으니, `shared_preload_libraries`를 바꾼 뒤에는 `postgresql.auto.conf`의 줄을 눈으로 확인하는 습관을 들이는 편이 안전합니다.

재시작한 뒤 `auto_explain`의 기준 시간을 정하고, `pg_stat_statements`를 쓸 DB에 확장을 만듭니다.

```psql
postgres=# ALTER SYSTEM SET auto_explain.log_min_duration = '500ms';
ALTER SYSTEM

postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)


postgres=# CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION

postgres=# SELECT name, setting, pending_restart FROM pg_settings
postgres-# WHERE name IN ('shared_preload_libraries', 'track_io_timing', 'auto_explain.log_min_duration', 'log_line_prefix')
postgres-# ORDER BY name;
             name              |             setting              | pending_restart
-------------------------------+----------------------------------+-----------------
 auto_explain.log_min_duration | 500                              | f
 log_line_prefix               | %m [%p] %q%u@%d/%a               | f
 shared_preload_libraries      | pg_stat_statements, auto_explain | f
 track_io_timing               | on                               | f
(4 rows)
```

지금까지 바꾼 설정은 모두 `postgresql.auto.conf`에 모입니다.

```console
$ cat $PGDATA/postgresql.auto.conf
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
log_lock_waits = 'on'
log_temp_files = '0'
log_min_duration_statement = '500ms'
log_autovacuum_min_duration = '0'
log_line_prefix = '%m [%p] %q%u@%d/%a '
track_io_timing = 'on'
autovacuum_naptime = '10s'
shared_preload_libraries = 'pg_stat_statements, auto_explain'
auto_explain.log_min_duration = '500ms'
```

`autovacuum_naptime = '10s'`는 실습에서 autovacuum 로그를 빨리 보려고 줄인 값입니다. 운영 서버에 그대로 옮길 값이 아닙니다.

## pg_stat_activity: 누가 무엇을 기다리는가

장애가 났을 때 가장 먼저 보는 곳입니다. 세션 두 개로 흔한 상황을 만듭니다. 세션 A가 행을 고치고 커밋하지 않은 채 멈춰 있고, 세션 B가 같은 행을 고치려 합니다.

```psql
postgres=# CREATE TABLE t (id int PRIMARY KEY, v int);
CREATE TABLE

postgres=# INSERT INTO t VALUES (1, 0), (2, 0);
INSERT 0 2
A=# BEGIN;
BEGIN

A=# UPDATE t SET v = v + 1 WHERE id = 1;
UPDATE 1

B=# UPDATE t SET v = v + 10 WHERE id = 1;
```

세션 B의 UPDATE는 끝나지 않습니다. 다른 세션에서 `pg_stat_activity`를 보면 이렇습니다.

```psql
postgres=# SELECT pid, application_name AS app, state, wait_event_type, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 40) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY pid;
 pid |  app  |        state        | wait_event_type |  wait_event   | blocked_by |                 query
-----+-------+---------------------+-----------------+---------------+------------+---------------------------------------
 268 | app_a | idle in transaction | Client          | ClientRead    | {}         | UPDATE t SET v = v + 1 WHERE id = 1;
 283 | app_b | active              | Lock            | transactionid | {268}      | UPDATE t SET v = v + 10 WHERE id = 1;
(2 rows)
```

읽는 법은 다음과 같습니다.

- **`state`**: `active`는 쿼리를 실행 중, `idle`은 다음 명령을 기다리는 중, `idle in transaction`은 **트랜잭션을 연 채로** 다음 명령을 기다리는 중입니다. 세션 A는 쿼리를 실행하고 있지 않은데도 락을 쥐고 있습니다. `query`는 그 세션이 **마지막으로** 실행한 쿼리라서, 세션 A가 이미 끝낸 UPDATE가 보입니다.
- **`wait_event_type`/`wait_event`**: 지금 무엇을 기다리는지입니다. 세션 A의 `Client`/`ClientRead`는 클라이언트가 다음 명령을 보내기를 기다리는 것이고, 세션 B의 `Lock`/`transactionid`는 **다른 트랜잭션이 끝나기를** 기다리는 것입니다([wait event 표](https://www.postgresql.org/docs/18/monitoring-stats.html#WAIT-EVENT-TABLE)). 행 락을 기다리면 행이 아니라 그 행을 고친 트랜잭션의 ID를 기다리는 것으로 보이는데, 이유는 [인터널 4편](/posts/postgresql/04-mvcc/)에서 다뤘습니다.
- **`pg_blocking_pids()`**: 이 세션을 막고 있는 PID 목록입니다. 세션 B는 `{268}`, 즉 세션 A에게 막혀 있습니다.

얼마나 오래 그 상태였는지도 같은 뷰에서 봅니다.

```psql
postgres=# SELECT pid, now() - xact_start AS xact_age, now() - state_change AS in_state
postgres-# FROM pg_stat_activity
postgres-# WHERE application_name IN ('app_a', 'app_b')
postgres-# ORDER BY pid;
 pid |    xact_age     |    in_state
-----+-----------------+-----------------
 268 | 00:00:05.193128 | 00:00:04.185379
 283 | 00:00:03.051489 | 00:00:03.051486
(2 rows)
```

`xact_start`는 트랜잭션이 시작된 시각, `state_change`는 지금 상태가 된 시각입니다. `idle in transaction`인 세션의 `in_state`가 길다면, 애플리케이션이 트랜잭션을 열어 둔 채 다른 일을 하고 있다는 뜻입니다. 이런 세션을 찾고 막는 방법은 4편에서 다룹니다.

### ps로도 보인다

DB에 접속할 수 없을 만큼 상황이 나쁠 때는 OS에서 봅니다. backend 프로세스는 자기 상태를 프로세스 제목에 씁니다([인터널 1편](/posts/postgresql/01-process-architecture/)).

```console
$ ps -u postgres -o pid,cmd | grep 'postgres:' | grep -v grep
    195 postgres: logger
    196 postgres: io worker 0
    197 postgres: io worker 1
    198 postgres: io worker 2
    199 postgres: checkpointer
    200 postgres: background writer
    202 postgres: walwriter
    203 postgres: autovacuum launcher
    204 postgres: logical replication launcher
    268 postgres: postgres postgres [local] idle in transaction
    283 postgres: postgres postgres [local] UPDATE waiting
```

`idle in transaction`과 `UPDATE waiting`이 그대로 보입니다. `io worker`는 PostgreSQL 18의 기본 `io_method = worker`가 띄우는 비동기 I/O 프로세스입니다.

### 서버 로그: log_lock_waits

`log_lock_waits`를 켰으므로, 세션 B가 `deadlock_timeout`(1초)보다 오래 기다리자 로그가 남았습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'still waiting|Process holding|Wait queue|STATEMENT'
2026-09-25 23:06:45.880 UTC [283] postgres@postgres/app_b LOG:  process 283 still waiting for ShareLock on transaction 766 after 1000.715 ms
2026-09-25 23:06:45.880 UTC [283] postgres@postgres/app_b DETAIL:  Process holding the lock: 268. Wait queue: 283.
2026-09-25 23:06:45.880 UTC [283] postgres@postgres/app_b STATEMENT:  UPDATE t SET v = v + 10 WHERE id = 1;
```

누가(`Process holding the lock: 268`) 누구를(`Wait queue: 283`) 막았는지, 막힌 쪽의 쿼리가 무엇인지가 한 번에 남습니다. `pg_stat_activity`는 지금 이 순간만 보여 주므로, 장애가 지나간 뒤에 원인을 찾을 수 있는 곳은 이 로그뿐입니다. 이제 세션 A를 끝냅니다.

```psql
A=# ROLLBACK;
ROLLBACK

# 세션 B: 앞 명령의 결과를 기다림
UPDATE 1
```

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'acquired'
2026-09-25 23:06:48.754 UTC [283] postgres@postgres/app_b LOG:  process 283 acquired ShareLock on transaction 766 after 3874.166 ms
```

락을 얻을 때도 몇 ms를 기다렸는지 한 줄이 남습니다. 같은 UPDATE는 `log_min_duration_statement`(500ms)도 넘겼으므로 느린 쿼리로도 기록됩니다.

```text
...
	  ->  Index Scan using t_pkey on t  (cost=0.15..8.17 rows=1 width=10)
	        Index Cond: (id = 1)
2026-09-25 23:06:48.756 UTC [283] postgres@postgres/app_b LOG:  duration: 3876.695 ms  statement: UPDATE t SET v = v + 10 WHERE id = 1;
```

앞의 두 줄은 `auto_explain`이 남긴 이 UPDATE의 실행 계획 끝부분입니다. 기본 키 인덱스로 한 행을 찾는 계획이라 느릴 이유가 없습니다. **느린 쿼리 로그에 단순한 쿼리가 보이면 실행 계획보다 락 대기를 먼저 의심하고**, 같은 시각의 `still waiting for` 로그를 찾아봅니다.

## pg_stat_statements: 무엇이 시간을 가장 많이 쓰는가

`pg_stat_activity`가 지금 이 순간이라면, `pg_stat_statements`는 누적입니다. 쿼리를 상수만 뺀 모양으로 묶어서 호출 수, 실행 시간, 읽은 블록 수를 쌓습니다([pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html)). `pgbench`로 부하를 30초 줍니다.

```console
$ pgbench -i -s 10 -q postgres 2>&1 | tail -n 3
vacuuming...
creating primary keys...
done in 0.46 s (drop tables 0.00 s, create tables 0.00 s, client-side generate 0.33 s, vacuum 0.03 s, primary keys 0.09 s).
```

```psql
postgres=# SELECT pg_stat_statements_reset() IS NOT NULL AS reset;
 reset
-------
 t
(1 row)
```

부하가 도는 동안 `pg_stat_activity`를 wait event별로 묶어 세 번 찍었습니다.

```psql
postgres=# SELECT wait_event_type, wait_event, state, count(*)
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# GROUP BY 1, 2, 3 ORDER BY 4 DESC;
 wait_event_type |  wait_event   | state  | count
-----------------+---------------+--------+-------
 Client          | ClientRead    | active |     2
 IO              | DataFileWrite | active |     2
 Lock            | transactionid | active |     2
 IO              | WalSync       | active |     1
 LWLock          | WALWrite      | active |     1
(5 rows)
...
postgres=# SELECT wait_event_type, wait_event, state, count(*)
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# GROUP BY 1, 2, 3 ORDER BY 4 DESC;
 wait_event_type |  wait_event   |        state        | count
-----------------+---------------+---------------------+-------
 Lock            | transactionid | active              |     2
 LWLock          | WALWrite      | active              |     2
 Client          | ClientRead    | idle                |     1
 IO              | WalSync       | active              |     1
 Lock            | transactionid | idle in transaction |     1
                 |               | active              |     1
(6 rows)
```

한 번 찍은 것은 한 순간의 표본일 뿐이라, 이렇게 몇 번 반복해 찍어서 **자주 보이는 wait event**를 찾는 것이 요령입니다. 여기서는 `Lock`/`transactionid`(다른 트랜잭션을 기다림)와 WAL 쓰기(`LWLock`/`WALWrite`, `IO`/`WalSync`)가 계속 보입니다. `wait_event`가 비어 있는 `active`는 CPU에서 실제로 일하는 중입니다.

```console
$ cat /var/lib/pgsql/bench.log
pgbench (18.6)
starting vacuum...end.
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 10
query mode: simple
number of clients: 8
number of threads: 2
maximum number of tries: 1
duration: 30 s
number of transactions actually processed: 397987
number of failed transactions: 0 (0.000%)
latency average = 0.603 ms
initial connection time = 4.039 ms
tps = 13267.572474 (without initial connection time)
```

```psql
postgres=# SELECT left(query, 60) AS query, calls,
postgres-#        round(total_exec_time::numeric, 1) AS total_ms,
postgres-#        round(mean_exec_time::numeric, 3) AS mean_ms,
postgres-#        rows, shared_blks_hit, shared_blks_read
postgres-# FROM pg_stat_statements
postgres-# ORDER BY total_exec_time DESC
postgres-# LIMIT 5;
                            query                             | calls  | total_ms | mean_ms |  rows  | shared_blks_hit | shared_blks_read
--------------------------------------------------------------+--------+----------+---------+--------+-----------------+------------------
 UPDATE pgbench_branches SET bbalance = bbalance + $1 WHERE b | 397987 |  30506.9 |   0.077 | 397987 |         2527835 |               55
 UPDATE pgbench_tellers SET tbalance = tbalance + $1 WHERE ti | 397987 |   6478.7 |   0.016 | 397987 |         2092643 |               64
 UPDATE pgbench_accounts SET abalance = abalance + $1 WHERE a | 397987 |   3602.5 |   0.009 | 397987 |         2463974 |            93994
 SELECT abalance FROM pgbench_accounts WHERE aid = $1         | 397987 |   1079.7 |   0.003 | 397987 |         1618963 |                0
 INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VA | 397987 |    832.5 |   0.002 | 397987 |          403349 |                9
(5 rows)
```

`total_ms`로 정렬하면 **서버 시간을 가장 많이 쓴 쿼리**가 위로 옵니다. 1위인 `pgbench_branches` UPDATE는 한 번에 0.077ms밖에 안 걸리지만 전체 시간의 대부분을 차지합니다. scale 10이라 `pgbench_branches`에는 행이 10개뿐이고, 클라이언트 8개가 이 10개 행을 번갈아 고치니 서로의 트랜잭션을 기다리게 됩니다. `pg_stat_statements`의 실행 시간에는 이렇게 **행 락을 기다린 시간도 들어갑니다**. 앞의 wait event 표본에서 `Lock`/`transactionid`가 계속 보인 것과 맞아떨어집니다.

`shared_blks_read`는 shared buffers에 없어서 읽어 온 블록 수입니다. 100만 행짜리 `pgbench_accounts`만 read가 큰 것은 shared buffers(기본 128MB)에 다 들어가지 않기 때문입니다([인터널 2편](/posts/postgresql/02-memory-architecture/)).

장애 조사에서는 보통 "평소와 비교해 무엇이 달라졌는가"가 궁금하므로, 이 뷰를 주기적으로 떠서 저장해 두어야 쓸모가 커집니다. 여기서는 실습을 위해 부하 직전에 `pg_stat_statements_reset()`으로 비웠습니다.

## 서버 로그: temp file, 느린 쿼리, auto_explain

### temp file

`work_mem`보다 큰 정렬이나 해시는 디스크의 임시 파일로 넘칩니다. `EXPLAIN (ANALYZE, BUFFERS)`로 보면 이렇습니다.

```psql
postgres=# SET work_mem = '4MB';
postgres-# EXPLAIN (ANALYZE, BUFFERS)
postgres-# SELECT * FROM pgbench_accounts ORDER BY filler, aid;
SET
                                                                    QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------
 Gather Merge  (cost=83949.87..200888.86 rows=1004057 width=97) (actual time=138.771..241.890 rows=1000000.00 loops=1)
   Workers Planned: 2
   Workers Launched: 2
   Buffers: shared hit=10153 read=6759 dirtied=6782 written=5663, temp read=13097 written=13131
   I/O Timings: shared read=2.250 write=8.489, temp read=5.687 write=20.195
   ->  Sort  (cost=82949.85..83995.74 rows=418357 width=97) (actual time=134.849..157.217 rows=333333.33 loops=3)
         Sort Key: filler, aid
         Sort Method: external merge  Disk: 36704kB
         Buffers: shared hit=10153 read=6759 dirtied=6782 written=5663, temp read=13097 written=13131
         I/O Timings: shared read=2.250 write=8.489, temp read=5.687 write=20.195
         Worker 0:  Sort Method: external merge  Disk: 35064kB
         Worker 1:  Sort Method: external merge  Disk: 33008kB
         ->  Parallel Seq Scan on pgbench_accounts  (cost=0.00..21007.57 rows=418357 width=97) (actual time=0.058..37.077 rows=333333.33 loops=3)
               Buffers: shared hit=10065 read=6759 dirtied=6782 written=5663
               I/O Timings: shared read=2.250 write=8.489
 Planning:
   Buffers: shared hit=72 read=13 dirtied=1
   I/O Timings: shared read=0.068
 Planning Time: 0.225 ms
 Execution Time: 264.048 ms
(20 rows)
```

`Sort Method: external merge  Disk: 36704kB`가 디스크로 넘쳤다는 표시입니다. 병렬 worker 두 개도 각자 정렬해서 각자 넘쳤습니다. `track_io_timing`을 켰으므로 `I/O Timings`에 임시 파일을 읽고 쓴 시간(`temp read`, `temp write`)도 나옵니다.

`log_temp_files = 0`이면 임시 파일이 지워질 때마다 크기가 한 줄씩 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 3 -E 'temporary file' | tail -n 12
2026-09-25 23:07:26.271 UTC [600] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp600.0", size 33800192
2026-09-25 23:07:26.271 UTC [600] STATEMENT:  SET work_mem = '4MB';
	EXPLAIN (ANALYZE, BUFFERS)
	SELECT * FROM pgbench_accounts ORDER BY filler, aid;
2026-09-25 23:07:26.272 UTC [601] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp601.0", size 35905536
2026-09-25 23:07:26.272 UTC [601] STATEMENT:  SET work_mem = '4MB';
	EXPLAIN (ANALYZE, BUFFERS)
	SELECT * FROM pgbench_accounts ORDER BY filler, aid;
2026-09-25 23:07:26.276 UTC [599] postgres@postgres/psql LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp599.0", size 37584896
2026-09-25 23:07:26.276 UTC [599] postgres@postgres/psql STATEMENT:  SET work_mem = '4MB';
	EXPLAIN (ANALYZE, BUFFERS)
	SELECT * FROM pgbench_accounts ORDER BY filler, aid;
```

프로세스마다 한 줄씩, 세 줄입니다. 앞머리에 `postgres@postgres/psql`이 붙은 것은 세션의 backend이고, 붙지 않은 두 줄은 병렬 worker입니다. `log_line_prefix`의 `%q` 뒤를 찍지 않는 프로세스로 취급된 것입니다. 누적 값은 `pg_stat_database`에 있습니다.

```psql
postgres=# SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
postgres-# FROM pg_stat_database WHERE datname = 'postgres';
 datname  | temp_files | temp_bytes
----------+------------+------------
 postgres |          8 | 251 MB
(1 row)
```

8개에는 `pgbench -i`가 기본 키를 만들 때 쓴 임시 파일도 들어 있습니다. 임시 파일이 디스크를 채우는 문제는 6편에서 다룹니다.

### 느린 쿼리와 auto_explain

500ms를 넘기는 쿼리를 하나 돌립니다.

```psql
postgres=# SET max_parallel_workers_per_gather = 0;
postgres-# SELECT count(DISTINCT md5(filler || aid)) FROM pgbench_accounts;
SET
  count
---------
 1000000
(1 row)
```

로그에는 세 가지가 남았습니다.

```text
2026-09-25 23:07:28.031 UTC [620] postgres@postgres/psql LOG:  duration: 1624.034 ms  plan:
	Query Text: SET max_parallel_workers_per_gather = 0;
	SELECT count(DISTINCT md5(filler || aid)) FROM pgbench_accounts;
	Aggregate  (cost=247483.05..247483.06 rows=1 width=8)
	  ->  Sort  (cost=229912.05..232422.19 rows=1004057 width=89)
	        Sort Key: (md5(((filler)::text || (aid)::text)))
	        ->  Seq Scan on pgbench_accounts  (cost=0.00..26864.57 rows=1004057 width=89)
2026-09-25 23:07:28.039 UTC [620] postgres@postgres/psql LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp620.0", size 135331840
2026-09-25 23:07:28.039 UTC [620] postgres@postgres/psql STATEMENT:  SET max_parallel_workers_per_gather = 0;
	SELECT count(DISTINCT md5(filler || aid)) FROM pgbench_accounts;
2026-09-25 23:07:28.039 UTC [620] postgres@postgres/psql LOG:  duration: 1632.938 ms  statement: SET max_parallel_workers_per_gather = 0;
	SELECT count(DISTINCT md5(filler || aid)) FROM pgbench_accounts;
```

- `duration: ... plan:`은 `auto_explain`이 남긴 **그때의 실행 계획**입니다. 나중에 같은 쿼리를 `EXPLAIN`하면 통계나 설정이 달라져 다른 계획이 나올 수 있으므로, 느렸던 그 순간의 계획이 남는 것이 중요합니다.
- `temporary file:`은 이 정렬이 약 130MB(135331840바이트)를 디스크에 썼다는 기록입니다.
- `duration: ... statement:`는 `log_min_duration_statement`가 남긴 느린 쿼리 기록입니다.

`Query Text`에 `SET`까지 붙은 것은 psql로 두 문장을 한 번에 보냈기 때문입니다. `auto_explain`은 기본으로 실제 행 수나 시간 없이 계획만 남깁니다. `auto_explain.log_analyze`를 켜면 실제 값도 남지만, 기준 시간을 넘지 않는 쿼리까지 모두 노드별 시간을 재게 되어 성능에 큰 부담이 될 수 있다고 문서가 경고합니다([auto_explain](https://www.postgresql.org/docs/18/auto-explain.html)).

## pg_stat_io: I/O를 누가 어디서 했는가

PostgreSQL 16부터 생긴 `pg_stat_io`는 I/O를 **프로세스 종류(`backend_type`) × 대상(`object`) × 용도(`context`)**로 나눠 셉니다. 18에서는 바이트 수(`read_bytes` 등)와 WAL I/O(`object = wal`)도 들어왔습니다.

```psql
postgres=# SELECT backend_type, object, context, reads, pg_size_pretty(read_bytes) AS read,
postgres-#        round(read_time::numeric, 1) AS read_ms, writes, extends, hits, evictions
postgres-# FROM pg_stat_io
postgres-# WHERE reads > 0 OR writes > 0 OR extends > 0
postgres-# ORDER BY coalesce(reads, 0) + coalesce(writes, 0) + coalesce(extends, 0) DESC
postgres-# LIMIT 10;
    backend_type    |  object  |  context  | reads |  read   | read_ms | writes | extends |  hits   | evictions
--------------------+----------+-----------+-------+---------+---------+--------+---------+---------+-----------
 client backend     | wal      | normal    |     0 | 0 bytes |     0.0 | 235168 |         |         |
 client backend     | relation | normal    | 94906 | 743 MB  |   248.5 |  68505 |    3163 | 9133655 |     84417
 autovacuum worker  | relation | vacuum    | 12943 | 191 MB  |    45.9 |  16739 |       0 |   55412 |      2026
 background writer  | relation | normal    |       |         |         |  16432 |         |         |
 client backend     | relation | bulkwrite |     0 | 0 bytes |     0.0 |  14404 |     261 |   16135 |         0
 background worker  | relation | bulkread  |  3352 | 88 MB   |     1.7 |   3778 |         |    7560 |      4260
 client backend     | relation | bulkread  |  4096 | 105 MB  |     1.3 |   1921 |         |   17750 |      2332
 standalone backend | relation | normal    |   479 | 4336 kB |     0.0 |   1037 |     597 |   91773 |         0
 autovacuum worker  | relation | normal    |   630 | 6312 kB |     5.7 |    347 |      13 |   31120 |       573
 client backend     | relation | vacuum    |   904 | 113 MB  |     0.3 |      0 |       0 |    2113 |         0
(10 rows)
```

- `client backend` / `wal` / `normal`의 writes가 가장 많습니다. pgbench의 커밋마다 WAL을 쓰기 때문입니다([인터널 7편](/posts/postgresql/07-wal/)).
- `client backend` / `relation` / `normal`의 **writes가 68505로, background writer(16432)보다 많습니다.** backend가 새 페이지를 읽을 자리를 만들려고 dirty 페이지를 직접 내보낸 것입니다(`evictions` 84417). 문서는 client backend의 write가 많으면 shared buffers나 checkpointer 설정이 맞지 않을 수 있다고 설명합니다([pg_stat_io](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-IO-VIEW)). 기본 128MB shared buffers에 이 부하는 버겁다는 뜻입니다. 이 문제는 10편에서 다시 봅니다.
- `bulkread`, `bulkwrite`, `vacuum`은 큰 테이블 순차 스캔, `COPY` 같은 대량 쓰기, VACUUM이 shared buffers를 다 차지하지 않도록 작은 링 버퍼를 따로 쓰는 경우입니다. `standalone backend`는 initdb입니다.

`read_ms`는 `track_io_timing`을 켰기 때문에 채워진 값입니다. 꺼져 있으면 0으로 남습니다.

## autovacuum과 checkpoint 로그

`log_autovacuum_min_duration = 0`이면 autovacuum이 돌 때마다 무엇을 했는지 남습니다.

```text
2026-09-25 23:07:27.537 UTC [621] LOG:  automatic vacuum of table "postgres.public.pgbench_tellers": index scans: 0
	pages: 0 removed, 96 remain, 13 scanned (13.54% of total), 0 eagerly scanned
	tuples: 956 removed, 186 remain, 0 are dead but not yet removable
	removable cutoff: 398780, which was 2 XIDs old when operation ended
	new relfrozenxid: 398214, which is 44329 XIDs ahead of previous value
	frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
	visibility map: 12 pages set all-visible, 0 pages set all-frozen (0 were all-visible)
	index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
	I/O timings: read: 0.018 ms, write: 0.000 ms
```

여기서 가장 자주 보게 될 줄은 `0 are dead but not yet removable`입니다. 이 값이 크면 dead tuple이 있는데도 지우지 못했다는 뜻이고, 대개 오래 열린 트랜잭션이 원인입니다([인터널 5편](/posts/postgresql/05-vacuum/)). 4편과 5편에서 이 줄을 다시 씁니다.

테이블별 누적은 `pg_stat_user_tables`에서 봅니다.

```psql
postgres=# SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, autovacuum_count
postgres-# FROM pg_stat_user_tables ORDER BY relname;
     relname      | n_live_tup | n_dead_tup |        last_autovacuum        | autovacuum_count
------------------+------------+------------+-------------------------------+------------------
 pgbench_accounts |     998447 |       9653 | 2026-09-25 23:06:59.944923+00 |                1
 pgbench_branches |         10 |          0 | 2026-09-25 23:07:27.394921+00 |                4
 pgbench_history  |     397987 |          0 | 2026-09-25 23:07:18.860528+00 |                3
 pgbench_tellers  |        100 |          0 | 2026-09-25 23:07:27.537528+00 |                4
 t                |          2 |          2 |                               |                0
(5 rows)
```

`t` 테이블은 dead tuple이 2개 있지만 autovacuum이 한 번도 돌지 않았습니다. 기준이 "50 + 행 수의 20%"라서 행 2개짜리 테이블은 대상이 되지 않습니다. 이 기준을 조정하는 방법은 5편에서 다룹니다.

체크포인트는 기본으로 기록됩니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'checkpoint (starting|complete)' | tail -n 4
2026-09-25 23:07:43.322 UTC [199] LOG:  checkpoint starting: immediate force wait
2026-09-25 23:07:43.436 UTC [199] LOG:  checkpoint complete: wrote 11616 buffers (70.9%), wrote 46 SLRU buffers; 0 WAL file(s) added, 0 removed, 18 recycled; write=0.031 s, sync=0.063 s, total=0.115 s; sync files=94, longest=0.050 s, average=0.001 s; distance=302508 kB, estimate=302508 kB; lsn=0/13EC6398, redo lsn=0/13EC6340
```

`immediate force wait`는 `CHECKPOINT` 명령으로 직접 요청했다는 뜻입니다. 평소에는 `time`(`checkpoint_timeout`)이나 `wal`(`max_wal_size`)이 적힙니다. `wal`이 자주 보이면 체크포인트가 너무 잦은 것이고, 10편의 주제입니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).

## OS에서 먼저 볼 것

같은 부하를 OS에서 보면 이렇습니다.

```console
$ top -b -n 1 -u postgres | head -n 20
top - 23:07:03 up 56 min,  0 users,  load average: 1.54, 1.42, 0.96
Tasks:  24 total,   6 running,  18 sleeping,   0 stopped,   0 zombie
%Cpu(s): 12.6 us, 13.1 sy,  0.0 ni, 66.0 id,  4.9 wa,  0.0 hi,  3.4 si,  0.0 st
MiB Mem :  32041.5 total,  19607.3 free,   2081.9 used,  11360.8 buff/cache
MiB Swap:   1024.0 total,   1024.0 free,      0.0 used.  29959.6 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
    517 postgres  20   0   87976   5360   4316 R 106.7   0.0   0:11.63 pgbench
    520 postgres  20   0  227492 155116 151940 S  40.0   0.5   0:04.00 postgres
    521 postgres  20   0  227500 155180 152000 D  40.0   0.5   0:04.00 postgres
    526 postgres  20   0  227492 155012 151836 R  40.0   0.5   0:03.80 postgres
    522 postgres  20   0  227492 155136 151964 R  33.3   0.5   0:03.92 postgres
    523 postgres  20   0  227492 155116 151940 R  33.3   0.5   0:03.97 postgres
    524 postgres  20   0  227492 155196 152040 R  33.3   0.5   0:03.84 postgres
    525 postgres  20   0  227492 155192 152020 S  33.3   0.5   0:03.88 postgres
    527 postgres  20   0  227500 155152 151976 S  33.3   0.5   0:03.79 postgres
```

backend 하나하나가 CPU를 30~40%씩 쓰고, pgbench 자체가 CPU 하나를 다 씁니다. backend의 `RES`가 150MB 남짓인데 대부분이 `SHR`, 즉 shared buffers를 같이 쓰는 몫입니다. 이 값을 프로세스 수만큼 더하면 메모리 사용량이 부풀려집니다([인터널 1편](/posts/postgresql/01-process-architecture/)).

```console
$ iostat -x 1 3
Linux 7.0.12-linuxkit (pgops) 	09/25/2026 	_aarch64_	(14 CPU)

avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           1.72    0.10    1.56    0.38    0.00   96.23

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
vda              2.17     26.31     3.15  59.21    0.12    12.11  813.42  10206.07    99.52  10.90    0.40    12.55   20.32 232857.35     0.00   0.00    0.06 11460.95  388.66    0.07    0.35   3.85
vdb              0.22    102.59     0.00   0.27    0.35   460.19    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          12.86    0.00   16.50    4.87    0.00   65.77

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
vda              0.00      0.00     0.00   0.00    0.00     0.00 15213.00  66416.00     0.00   0.00    0.05     4.37    0.00      0.00     0.00   0.00    0.00     0.00 7606.00    0.05    1.13  69.50
vdb              0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00


avg-cpu:  %user   %nice %system %iowait  %steal   %idle
          12.19    0.00   16.33    5.01    0.00   66.47

Device            r/s     rkB/s   rrqm/s  %rrqm r_await rareq-sz     w/s     wkB/s   wrqm/s  %wrqm w_await wareq-sz     d/s     dkB/s   drqm/s  %drqm d_await dareq-sz     f/s f_await  aqu-sz  %util
vda              0.00      0.00     0.00   0.00    0.00     0.00 15329.00  94000.00    37.00   0.24    0.14     6.13    0.00      0.00     0.00   0.00    0.00     0.00 7346.00    0.05    2.60  73.30
vdb              0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00      0.00     0.00   0.00    0.00     0.00    0.00    0.00    0.00   0.00
```

`iostat`의 첫 번째 출력은 부팅 이후 평균이라 무시하고 두 번째부터 봅니다. 초당 쓰기 15,000번 남짓에 flush 요청(`f/s`)이 7,000번 넘게 들어옵니다. 커밋마다 WAL을 디스크에 확정하는(fsync) 요청입니다.

```console
$ free -m
               total        used        free      shared  buff/cache   available
Mem:           32041        2088       19581         631       11379       29952
Swap:           1023           0        1023
$ df -h $PGDATA
Filesystem      Size  Used Avail Use% Mounted on
overlay         911G  218G  647G  26% /
```

> **실습 환경과 실제 서버의 차이**: 이 실습은 Docker Desktop의 Linux VM 위 컨테이너에서 돌았습니다. `top`, `free`의 메모리는 VM 전체(32GB)이고, `iostat`의 `vda`는 VM의 가상 디스크이며, `df`의 `overlay`는 컨테이너 파일 시스템입니다. 수치의 크기는 실제 서버와 다르게 읽어야 하고, 여기서는 어떤 지표를 어떤 순서로 보는지만 가져가면 됩니다.

## 장애가 나면 이 순서로 본다

1. **`pg_stat_activity`**: `state`, `wait_event_type`/`wait_event`, `pg_blocking_pids()`, `xact_start`. 무엇을 기다리는 세션이 많은지 몇 번 반복해 찍습니다.
2. **서버 로그** (`$PGDATA/log/postgresql-요일.log`): 같은 시각의 `ERROR`, `FATAL`, `still waiting for`, `duration:`, `temporary file:`, autovacuum과 checkpoint 기록.
3. **`pg_stat_statements`**: 평소와 비교해 시간을 많이 쓰는 쿼리.
4. **OS**: `ps`의 프로세스 제목, `top`, `iostat -x`, `free`, `df`.

## 미리 켜 둘 설정

| 설정 | 이 글에서 쓴 값 | 필요한 조치 | 메모 |
|---|---|---|---|
| `log_lock_waits` | `on` | reload | `deadlock_timeout`보다 오래 기다리면 기록 |
| `log_temp_files` | `0` | reload | 로그가 너무 많으면 kB 단위 기준을 준다 |
| `log_min_duration_statement` | `500ms` | reload | 서비스 특성에 맞게. 너무 낮으면 로그가 폭증 |
| `log_autovacuum_min_duration` | `0` | reload | 기본 10분이면 대부분의 autovacuum이 기록되지 않음 |
| `log_line_prefix` | `%m [%p] %q%u@%d/%a ` | reload | 사용자, DB, 애플리케이션을 남김 |
| `track_io_timing` | `on` | reload | 켜기 전에 `pg_test_timing`으로 비용 확인 |
| `shared_preload_libraries` | `pg_stat_statements, auto_explain` | **restart** | 따옴표로 묶지 말 것. 바꾼 뒤 `postgresql.auto.conf` 확인 |
| `auto_explain.log_min_duration` | `500ms` | reload | `log_analyze`는 부담이 큼 |

`shared_preload_libraries`만 재시작이 필요하므로, **새 서버를 만들 때** 넣어 두는 것이 가장 좋습니다. 장애가 난 뒤에는 이 설정 하나 때문에 재시작할 여유가 없는 경우가 많습니다.

## 정리

- PGDG 패키지는 `logging_collector`를 켜고 요일별 파일로 로그를 남깁니다. 로그는 일주일 뒤 덮어쓰입니다.
- 락 대기, temp file, 느린 쿼리, 짧은 autovacuum, I/O 시간은 기본으로 기록되지 않습니다. 장애 전에 켜 둬야 합니다.
- `shared_preload_libraries`를 `'a, b'`처럼 따옴표 하나로 묶으면 이름이 `a, b`인 라이브러리 하나가 되고, 다음 재시작 때 `could not access file` 에러로 서버가 뜨지 않습니다. 목록은 따옴표 없이 쉼표로 나열합니다.
- `pg_stat_activity`는 지금 이 순간을, 서버 로그는 지나간 일을, `pg_stat_statements`는 누적을 보여 줍니다. 셋을 같이 봐야 원인이 좁혀집니다.
- 느린 쿼리 로그에 단순한 쿼리가 보이면 락 대기를 먼저 의심합니다.

## 참고 자료

- [Error Reporting and Logging](https://www.postgresql.org/docs/18/runtime-config-logging.html)
- [The Cumulative Statistics System](https://www.postgresql.org/docs/18/monitoring-stats.html): `pg_stat_activity`, wait event, `pg_stat_io`
- [pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html)
- [auto_explain](https://www.postgresql.org/docs/18/auto-explain.html)
- [ALTER SYSTEM](https://www.postgresql.org/docs/18/sql-altersystem.html)
- [shared_preload_libraries](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-SHARED-PRELOAD-LIBRARIES)
- [pg_test_timing](https://www.postgresql.org/docs/18/pgtesttiming.html)
- PostgreSQL 인터널 [1편 프로세스 구조](/posts/postgresql/01-process-architecture/), [2편 메모리 구조](/posts/postgresql/02-memory-architecture/), [4편 MVCC](/posts/postgresql/04-mvcc/), [5편 VACUUM](/posts/postgresql/05-vacuum/), [7편 WAL](/posts/postgresql/07-wal/), [8편 체크포인트](/posts/postgresql/08-checkpoint-and-recovery/)

