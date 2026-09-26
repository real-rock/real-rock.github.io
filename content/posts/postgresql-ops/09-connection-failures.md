---
title: "PostgreSQL 운영 9: 접속이 안 된다"
date: 2026-09-26T19:39:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "커넥션", "pg_hba.conf", "too many clients already", "no pg_hba.conf entry", "password authentication failed"]
weight: 9
summary: "애플리케이션이 DB에 접속하지 못할 때, 에러 메시지로 원인을 가르고 들어갈 수 없는 상황에서도 되살리는 법"
description: "too many clients, 예약 슬롯, 인증 실패"
---

## 개요

애플리케이션 로그에 접속 에러가 쏟아집니다. 접속 실패는 원인에 따라 메시지가 분명하게 다르므로, **에러 메시지를 정확히 읽는 것**이 가장 빠른 진단입니다. 이 글에서는 흔한 세 가지를 재현합니다. 슬롯이 가득 찬 경우, `pg_hba.conf`에 맞는 규칙이 없는 경우, 인증에 실패한 경우입니다. 그리고 슈퍼유저조차 들어갈 수 없는 상황에서 되살리는 방법과, 커넥션을 새로 맺는 것이 얼마나 비싼지를 봅니다.

이 글에서 답할 질문은 다음과 같습니다.

- 접속 에러 메시지는 각각 무엇을 뜻하는가
- 슬롯이 가득 찼을 때 누가 차지하고 있는지 어떻게 찾고, 들어갈 수조차 없을 때는 어떻게 하는가
- 인증 실패의 진짜 이유는 어디서 보는가
- 커넥션 풀은 왜 필요한가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습에서는 슬롯이 차는 모습을 쉽게 보려고 `max_connections`를 20으로 줄이고, 일반 역할이 쓰지 못하는 예약 슬롯을 두었습니다.

```psql
postgres=# SELECT name, setting FROM pg_settings
postgres-# WHERE name IN ('max_connections', 'superuser_reserved_connections', 'reserved_connections', 'log_connections')
postgres-# ORDER BY name;
              name              |            setting
--------------------------------+-------------------------------
 log_connections                | authorization,setup_durations
 max_connections                | 20
 reserved_connections           | 2
 superuser_reserved_connections | 3
(4 rows)
postgres=# CREATE ROLE app LOGIN;
CREATE ROLE

postgres=# CREATE ROLE monitor LOGIN;
CREATE ROLE

postgres=# GRANT pg_use_reserved_connections TO monitor;
GRANT ROLE
```

| 설정 | 뜻 |
|---|---|
| `max_connections` | 동시에 받을 수 있는 클라이언트 연결 수 |
| `superuser_reserved_connections` | 그 가운데 슈퍼유저만 쓸 수 있는 슬롯(기본 3) |
| `reserved_connections` | 그 가운데 `pg_use_reserved_connections` 역할을 가진 사용자만 쓸 수 있는 슬롯(PostgreSQL 16부터, 기본 0) |

일반 역할은 20 − 3 − 2 = 15개까지 쓸 수 있습니다. 모니터링 계정(`monitor`)에 `pg_use_reserved_connections`를 주어, 애플리케이션이 슬롯을 다 써도 모니터링은 들어올 수 있게 했습니다. `log_connections`는 PostgreSQL 18부터 기록할 단계를 고를 수 있고, `setup_durations`는 접속에 걸린 시간을 남깁니다.

## 먼저 확인할 것: 에러 메시지

| 메시지 | 뜻 | 볼 곳 |
|---|---|---|
| `remaining connection slots are reserved for roles with privileges of the "pg_use_reserved_connections" role` | 일반 역할이 쓸 슬롯이 다 참 | `pg_stat_activity` |
| `remaining connection slots are reserved for roles with the SUPERUSER attribute` | 예약 슬롯까지 다 참 | `pg_stat_activity` |
| `sorry, too many clients already` | 모든 슬롯이 다 참 | OS의 프로세스 목록 |
| `no pg_hba.conf entry for host ...` | 접속 경로에 맞는 규칙이 없음 | `pg_hba_file_rules` |
| `password authentication failed for user ...` | 인증 실패. 진짜 이유는 서버 로그의 `DETAIL` | 서버 로그 |

## 원인별 진단

### 슬롯이 찬다

애플리케이션이 커넥션을 15개 열어 두고 쓰지 않는 상황입니다. 커넥션 풀 설정이 잘못되었거나 코드가 커넥션을 반납하지 않을 때 이렇게 됩니다.

```psql
postgres=# SELECT usename, application_name AS app, state, count(*)
postgres-# FROM pg_stat_activity WHERE backend_type = 'client backend'
postgres-# GROUP BY 1, 2, 3 ORDER BY 4 DESC;
 usename  | app  | state  | count
----------+------+--------+-------
 app      | psql | idle   |    15
 postgres | psql | active |     1
(2 rows)
```

이제 애플리케이션 계정은 들어올 수 없습니다.

```console
$ psql -X -U app -d postgres -c 'SELECT 1'
psql: error: connection to server on socket "/run/postgresql/.s.PGSQL.5432" failed: FATAL:  remaining connection slots are reserved for roles with privileges of the "pg_use_reserved_connections" role
[exit=2]
```

모니터링 계정은 예약 슬롯으로 들어옵니다.

```console
$ psql -X -U monitor -d postgres -c 'SELECT 1'
 ?column?
----------
        1
(1 row)

[exit=0]
```

모니터링 계정도 2개를 열어 두면 그 예약 슬롯도 찹니다.

```console
$ for i in 1 2; do nohup bash -c 'sleep 900 | psql -X -U monitor -d postgres >/dev/null' >/dev/null 2>&1 & done
$ sleep 1
$ psql -X -U monitor -d postgres -c 'SELECT 1'
psql: error: connection to server on socket "/run/postgresql/.s.PGSQL.5432" failed: FATAL:  remaining connection slots are reserved for roles with the SUPERUSER attribute
[exit=2]
```

```psql
postgres=# SELECT count(*) AS used, current_setting('max_connections') AS max FROM pg_stat_activity WHERE backend_type = 'client backend';
 used | max
------+-----
   18 | 20
(1 row)
```

마지막으로 슈퍼유저 슬롯 3개까지 누군가 차지하면, 슈퍼유저도 들어올 수 없습니다.

```console
$ for i in 1 2 3; do nohup bash -c 'sleep 900 | psql -X -U postgres -d postgres >/dev/null' >/dev/null 2>&1 & done
$ sleep 1
$ psql -X -c 'SELECT 1'
psql: error: connection to server on socket "/run/postgresql/.s.PGSQL.5432" failed: FATAL:  sorry, too many clients already
[exit=2]
```

서버 로그에는 단계마다 거절이 남습니다. `application_name`은 접속이 끝나기 전이라 `[unknown]`으로 찍힙니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'too many clients|reserved for' | tail -n 3
2026-09-26 10:39:00.646 UTC [210] app@postgres/[unknown] FATAL:  remaining connection slots are reserved for roles with privileges of the "pg_use_reserved_connections" role
2026-09-26 10:39:01.777 UTC [235] monitor@postgres/[unknown] FATAL:  remaining connection slots are reserved for roles with the SUPERUSER attribute
2026-09-26 10:39:02.940 UTC [263] postgres@postgres/[unknown] FATAL:  sorry, too many clients already
[exit=0]
```

**`sorry, too many clients already`는 가장 나쁜 상태입니다.** SQL로 원인을 볼 수도, 세션을 끊을 수도 없습니다. 이 메시지의 SQLSTATE는 `53300`입니다.

### pg_hba.conf에 맞는 규칙이 없다

같은 서버에 TCP로 접속해 봅니다.

```console
$ hostname -i
172.17.0.4
[exit=0]

$ psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
psql: error: connection to server at "172.17.0.4", port 5432 failed: FATAL:  no pg_hba.conf entry for host "172.17.0.4", user "app", database "postgres", no encryption
[exit=2]
```

에러가 host, user, database, 암호화 여부를 모두 알려 줍니다. `pg_hba.conf`는 위에서부터 차례로 보며 **첫 번째로 맞는 규칙**을 쓰고, 맞는 규칙이 없으면 이 에러를 냅니다. 지금 적용된 규칙은 `pg_hba_file_rules` 뷰로 봅니다.

```psql
postgres=# SELECT line_number, type, database, user_name, address, auth_method
postgres-# FROM pg_hba_file_rules ORDER BY line_number;
 line_number | type  |   database    | user_name |  address  | auth_method
-------------+-------+---------------+-----------+-----------+-------------
         117 | local | {all}         | {all}     |           | trust
         119 | host  | {all}         | {all}     | 127.0.0.1 | trust
         121 | host  | {all}         | {all}     | ::1       | trust
         124 | local | {replication} | {all}     |           | trust
         125 | host  | {replication} | {all}     | 127.0.0.1 | trust
         126 | host  | {replication} | {all}     | ::1       | trust
(6 rows)
```

로컬 소켓과 127.0.0.1, ::1만 허용되어 있습니다(initdb 기본값인 trust). 172.17.0.4에서 오는 연결에 맞는 규칙이 없습니다. 규칙을 추가하고 설정을 다시 읽습니다. `pg_hba.conf`는 재시작 없이 `pg_reload_conf()`로 반영됩니다.

```console
$ echo 'host all app samenet scram-sha-256' >> $PGDATA/pg_hba.conf
```

```psql
postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)


postgres=# SELECT line_number, type, database, user_name, address, auth_method
postgres-# FROM pg_hba_file_rules WHERE user_name @> '{app}';
 line_number | type | database | user_name | address |  auth_method
-------------+------+----------+-----------+---------+---------------
         127 | host | {all}    | {app}     | samenet | scram-sha-256
(1 row)
```

`pg_hba_file_rules`는 파일을 다시 읽어 보여 주므로 **reload하기 전에** 파일의 문법 오류를 확인하는 데도 씁니다. 잘못된 줄은 `error` 컬럼에 표시됩니다.

### 인증 실패: 진짜 이유는 서버 로그에

이제 규칙은 맞지만 인증에 실패합니다.

```console
$ PGPASSWORD=wrong psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
psql: error: connection to server at "172.17.0.4", port 5432 failed: FATAL:  password authentication failed for user "app"
[exit=2]
```

클라이언트는 `password authentication failed`만 받습니다. 공격자에게 정보를 주지 않으려고 이유를 말하지 않기 때문입니다. **이유는 서버 로그의 `DETAIL`에** 있습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 1 -E 'password authentication failed' | tail -n 2
2026-09-26 10:39:12.974 UTC [483] app@postgres/[unknown] FATAL:  password authentication failed for user "app"
2026-09-26 10:39:12.974 UTC [483] app@postgres/[unknown] DETAIL:  User "app" has no password assigned.
```

비밀번호가 아예 설정되지 않은 계정이었습니다. 비밀번호를 설정한 뒤 틀린 비밀번호로 접속하면 `DETAIL`이 달라집니다.

```console
$ PGPASSWORD=wrong psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
psql: error: connection to server at "172.17.0.4", port 5432 failed: FATAL:  password authentication failed for user "app"
[exit=2]

$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 1 -E 'password authentication failed' | tail -n 2
2026-09-26 10:39:13.154 UTC [516] app@postgres/[unknown] FATAL:  password authentication failed for user "app"
2026-09-26 10:39:13.154 UTC [516] app@postgres/[unknown] DETAIL:  Connection matched file "/var/lib/pgsql/18/data/pg_hba.conf" line 127: "host all app samenet scram-sha-256"
[exit=0]
```

이번에는 **어느 `pg_hba.conf` 규칙에 걸렸는지**(127번째 줄)를 알려 줍니다. 규칙이 의도와 다른 줄에 걸리는 문제를 찾을 때 유용합니다. 맞는 비밀번호로는 들어옵니다.

```console
$ PGPASSWORD="$(cat /var/lib/pgsql/app.pw)" psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT current_user, inet_server_addr()'
 current_user | inet_server_addr
--------------+------------------
 app          | 172.17.0.4
(1 row)

[exit=0]
```

`log_connections`의 `setup_durations`로 접속 단계별 시간이 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'connection authenticated|connection authorized|connection ready' | tail -n 3
2026-09-26 10:39:13.091 UTC [507] postgres@postgres/psql LOG:  connection ready: setup total=1.195 ms, fork=0.241 ms, authentication=0.099 ms
2026-09-26 10:39:13.274 UTC [538] app@postgres/[unknown] LOG:  connection authorized: user=app database=postgres application_name=psql
2026-09-26 10:39:13.274 UTC [538] app@postgres/psql LOG:  connection ready: setup total=4.464 ms, fork=0.236 ms, authentication=3.265 ms
```

trust로 들어온 로컬 접속은 인증에 0.099 ms, scram-sha-256으로 들어온 TCP 접속은 3.265 ms가 걸렸습니다. SCRAM은 비밀번호 해시를 일부러 여러 번 반복 계산하기 때문에 느립니다. 커넥션 하나로는 작은 차이지만, 커넥션을 쉴 새 없이 새로 맺는 애플리케이션이라면 쌓입니다.

## 조치

### 들어갈 수 없을 때: OS에서 idle 세션 하나를 끝낸다

슬롯이 모두 찼다면 DB 서버의 OS에서 backend 프로세스를 봅니다. 프로세스 제목에 사용자와 상태가 있습니다([인터널 1편](/posts/postgresql/01-process-architecture/)).

```console
$ ps -u postgres -o pid,cmd | grep 'postgres: app postgres \[local\] idle' | grep -v grep | head -n 3
    179 postgres: app postgres [local] idle
    180 postgres: app postgres [local] idle
    181 postgres: app postgres [local] idle
[exit=0]

$ kill -TERM $(ps -u postgres -o pid,cmd | grep 'postgres: app postgres \[local\] idle' | grep -v grep | head -n 1 | awk '{print $1}')
$ sleep 1
[exit=0]
```

idle 상태인 애플리케이션 backend 하나에 **SIGTERM**을 보냈습니다. `SIGTERM`은 `pg_terminate_backend()`와 같은 신호라서 그 세션만 깔끔하게 끝납니다. **`kill -9`(`SIGKILL`)는 절대 쓰지 않습니다.** backend 하나가 비정상 종료하면 postmaster가 공유 메모리를 믿을 수 없다고 보고 모든 세션을 끊고 장애 복구를 합니다([인터널 1편](/posts/postgresql/01-process-architecture/)). 슬롯 하나가 생겼으니 SQL로 들어가 누가 차지하고 있는지 봅니다.

```psql
postgres=# SELECT usename, application_name AS app, state, count(*)
postgres-# FROM pg_stat_activity WHERE backend_type = 'client backend'
postgres-# GROUP BY 1, 2, 3 ORDER BY 4 DESC;
 usename  | app  | state  | count
----------+------+--------+-------
 app      | psql | idle   |    14
 postgres | psql | idle   |     3
 monitor  | psql | idle   |     2
 postgres | psql | active |     1
(4 rows)


postgres=# SELECT pid, usename, state, now() - state_change AS idle_for, backend_start
postgres-# FROM pg_stat_activity WHERE usename = 'app' ORDER BY backend_start LIMIT 3;
 pid | usename | state |    idle_for     |         backend_start
-----+---------+-------+-----------------+-------------------------------
 181 | app     | idle  | 00:00:05.783947 | 2026-09-26 10:38:58.506671+00
 180 | app     | idle  | 00:00:05.784385 | 2026-09-26 10:38:58.507287+00
 182 | app     | idle  | 00:00:05.783392 | 2026-09-26 10:38:58.507389+00
(3 rows)
```

애플리케이션 계정의 idle 세션 14개가 대부분입니다. `client_addr`과 `application_name`으로 어느 서버의 어느 애플리케이션인지 확인하고, 그쪽 담당자와 함께 정리합니다. 급하면 오래 idle인 세션을 한꺼번에 끊습니다.

```psql
postgres=# SELECT count(pg_terminate_backend(pid)) AS terminated
postgres-# FROM pg_stat_activity
postgres-# WHERE usename IN ('app', 'monitor') AND state = 'idle' AND state_change < now() - interval '5 seconds';
 terminated
------------
         14
(1 row)


postgres=# SELECT count(*) AS used FROM pg_stat_activity WHERE backend_type = 'client backend';
 used
------
    6
(1 row)
```

끊긴 세션을 쓰던 애플리케이션은 다음 요청에서 에러를 받으므로, 커넥션 풀이 끊긴 연결을 감지하고 다시 맺는지 확인해야 합니다.

### idle 세션을 자동으로 끊는다: idle_session_timeout

애플리케이션 계정에 `idle_session_timeout`을 걸면, 트랜잭션 밖에서 아무것도 하지 않는 세션을 서버가 끊습니다.

```psql
postgres=# ALTER ROLE app SET idle_session_timeout = '3s';
ALTER ROLE

# 세션 X 시작: psql -X -U app -d postgres

X=# SELECT current_user;
 current_user
--------------
 app
(1 row)


X=# SELECT 1;
FATAL:  terminating connection due to idle-session timeout
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'idle-session timeout' | tail -n 1
2026-09-26 10:39:09.537 UTC [348] app@postgres/psql FATAL:  terminating connection due to idle-session timeout
```

커넥션 풀은 일부러 idle 연결을 유지하므로, 이 값은 **풀의 idle 타임아웃보다 길게** 잡아야 합니다. 그렇지 않으면 풀이 들고 있는 연결을 서버가 계속 끊어 에러가 납니다. 풀이 없는 배치나 개발자 접속 계정에 거는 것이 안전합니다.

### 예약 슬롯을 설계해 둔다

- `superuser_reserved_connections`(기본 3)는 DBA가 들어올 자리입니다. 애플리케이션이나 모니터링을 슈퍼유저로 접속시키면 이 자리까지 차지하므로, 슈퍼유저 계정은 사람만 씁니다.
- `reserved_connections`와 `pg_use_reserved_connections`로 모니터링·운영 도구의 자리를 따로 둡니다. 장애 중에 모니터링이 끊기면 상황을 볼 수 없습니다.

## 커넥션은 비싸다: 풀을 쓴다

같은 조회를 커넥션을 유지한 채 할 때와, 매번 새로 맺을 때(`pgbench -C`)를 비교합니다.

```console
$ pgbench -n -S -c 4 -T 5 postgres 2>&1 | grep -E 'number of transactions actually|average connection time|tps'
number of transactions actually processed: 388940
tps = 77846.384789 (without initial connection time)
```

```console
$ pgbench -n -S -c 4 -T 5 -C postgres 2>&1 | grep -E 'number of transactions actually|average connection time|tps'
number of transactions actually processed: 5706
average connection time = 0.869 ms
tps = 1141.107114 (including reconnection times)
```

**초당 7만 7천 건과 1천 1백 건, 약 70배 차이**입니다. PostgreSQL은 커넥션마다 backend 프로세스를 새로 띄우고(`fork`), 인증하고, 캐시를 새로 채웁니다([인터널 1편](/posts/postgresql/01-process-architecture/)). 이 실습은 trust 인증의 로컬 접속이었으니, TLS와 SCRAM 인증까지 더해지는 실제 환경에서는 차이가 더 큽니다.

그래서 애플리케이션은 커넥션 풀을 씁니다. `max_connections`를 무작정 늘리는 것은 해결책이 아닙니다. backend마다 메모리를 쓰고([11편](/posts/postgresql-ops/11-out-of-memory/)), 동시에 일하는 프로세스가 CPU 코어 수를 훨씬 넘으면 오히려 전체 처리량이 떨어집니다. 애플리케이션 서버마다 풀 크기를 정하고, **(애플리케이션 서버 수 × 풀 최대 크기) + 예약 슬롯**이 `max_connections`를 넘지 않게 맞춥니다. 애플리케이션 서버가 수십 대라면 별도의 커넥션 풀러를 앞에 두는 구성도 흔한데, 이 연재는 코어 기능만 다루므로 여기서는 다루지 않습니다.

## 재발 방지

- **슬롯 사용률 감시**: `pg_stat_activity`의 client backend 수 ÷ `max_connections`. 사용자·애플리케이션·상태별로 나눠 수집하면 누수를 일찍 찾습니다.
- **idle 세션 감시**: `state = 'idle'`이고 `state_change`가 오래된 세션 수.
- **접속 실패 감시**: 서버 로그의 `too many clients`, `reserved for`, `no pg_hba.conf entry`, `password authentication failed` 건수. 인증 실패가 갑자기 늘면 비밀번호 변경 누락이나 공격을 의심합니다.
- **`log_connections`**: PostgreSQL 18에서는 필요한 단계만 고를 수 있습니다. 접속이 아주 많은 서버라면 로그 양을 보고 정합니다.
- **예약 슬롯**: 모니터링 계정에 `pg_use_reserved_connections`, 슈퍼유저는 사람만.

## 정리

- 접속 에러는 메시지가 원인을 말해 줍니다. 슬롯 부족은 `reserved for ...`에서 `too many clients already`로 단계가 올라가고, 경로 문제는 `no pg_hba.conf entry`, 인증 문제는 `password authentication failed`입니다.
- 인증 실패의 진짜 이유(비밀번호 없음, 어느 규칙에 걸렸는지)는 서버 로그의 `DETAIL`에만 있습니다.
- 슈퍼유저조차 들어갈 수 없으면 OS에서 idle backend 하나에 `SIGTERM`을 보내 자리를 만듭니다. `kill -9`는 쓰지 않습니다.
- 모니터링용 예약 슬롯(`reserved_connections`)을 두고, 슈퍼유저 계정은 사람만 씁니다.
- 커넥션을 매번 새로 맺으면 이 실습에서 처리량이 약 70배 떨어졌습니다. 커넥션 풀을 쓰고, 풀 크기의 합이 `max_connections`를 넘지 않게 합니다.

## 참고 자료

- [Connections and Authentication](https://www.postgresql.org/docs/18/runtime-config-connection.html): `max_connections`, `reserved_connections`, `superuser_reserved_connections`
- [The pg_hba.conf File](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html), [pg_hba_file_rules](https://www.postgresql.org/docs/18/view-pg-hba-file-rules.html)
- [Password Authentication](https://www.postgresql.org/docs/18/auth-password.html)
- [log_connections](https://www.postgresql.org/docs/18/runtime-config-logging.html#GUC-LOG-CONNECTIONS), [idle_session_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-IDLE-SESSION-TIMEOUT)
- [Predefined Roles](https://www.postgresql.org/docs/18/predefined-roles.html): `pg_use_reserved_connections`
- PostgreSQL 인터널 [1편 프로세스 구조](/posts/postgresql/01-process-architecture/)

