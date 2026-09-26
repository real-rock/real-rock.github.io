---
title: "PostgreSQL 운영 2: 세션들이 멈춰 있다"
date: 2026-09-26T18:00:00+09:00
draft: true
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "락", "pg_locks", "deadlock detected", "lock timeout", "terminating connection"]
weight: 2
summary: "세션이 줄줄이 멈췄을 때 누가 막고 있는지 찾고, 어떻게 풀고, 어떻게 막는가"
description: "락 대기, DDL이 만드는 락 큐, deadlock, lock_timeout"
---

## 개요

애플리케이션 응답이 멈추고, 커넥션 풀이 가득 차고, DB 서버의 CPU와 I/O는 오히려 한가합니다. 세션들이 무언가를 **기다리고** 있을 때의 전형적인 모습입니다. 대부분은 락 대기이고, 그 끝에는 락을 쥔 채 아무 일도 하지 않는 세션 하나가 있는 경우가 많습니다.

이 글에서 답할 질문은 다음과 같습니다.

- 멈춘 세션들 가운데 **처음 원인**이 된 세션은 어떻게 찾는가
- 행 락, DDL이 만드는 락 큐, deadlock은 각각 어떻게 보이는가
- `pg_cancel_backend`와 `pg_terminate_backend`는 무엇이 다른가
- 테이블 하나에 컬럼을 추가하려다 서비스 전체를 멈추지 않으려면 어떻게 하는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습에는 [1편](/posts/postgresql-ops/01-diagnostic-toolkit/)에서 켠 `log_lock_waits`와 `log_line_prefix`를 그대로 씁니다.

```psql
postgres=# CREATE TABLE orders (id int PRIMARY KEY, status text);
CREATE TABLE

postgres=# INSERT INTO orders SELECT g, 'new' FROM generate_series(1, 3) g;
INSERT 0 3

postgres=# SHOW deadlock_timeout;
 deadlock_timeout
------------------
 1s
(1 row)
```

## 먼저 확인할 것

세션이 멈췄다는 신고가 오면 가장 먼저 이 쿼리를 돌립니다.

```sql
SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
       pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY xact_start NULLS LAST, pid;
```

보는 순서는 이렇습니다.

1. `wtype`이 `Lock`인 세션이 있는가. 있다면 락 대기입니다. `LWLock`이나 `IO`라면 락이 아니라 내부 자원이나 디스크를 기다리는 것이니 다른 편의 주제입니다.
2. `blocked_by`를 따라 올라갑니다. **자기 `blocked_by`는 비어 있는데 다른 세션의 `blocked_by`에 이름이 오르는 세션**이 뿌리입니다.
3. 뿌리 세션의 `state`를 봅니다. `idle in transaction`이면 트랜잭션을 열어 둔 채 아무것도 하지 않고 있는 것이고, `active`면 무언가를 오래 실행 중인 것입니다.

`ORDER BY xact_start`로 정렬하면 트랜잭션을 가장 먼저 연 세션이 위로 오므로, 뿌리가 대개 첫 줄 근처에 있습니다.

`pg_blocking_pids()`는 편리하지만 호출할 때마다 락 관리자를 잠깐 잠그므로, 수백 개 세션에 대해 초 단위로 반복 호출하는 모니터링에 넣는 것은 피하라고 문서가 권합니다([pg_blocking_pids](https://www.postgresql.org/docs/18/functions-info.html#FUNCTIONS-INFO-SESSION)). 장애 조사처럼 가끔 돌리는 용도라면 문제없습니다.

## 원인별 진단

### 행 락: 커밋하지 않은 세션 하나가 줄을 세운다

세 세션이 같은 행을 고칩니다. A는 고친 뒤 커밋하지 않고 멈춰 있습니다.

```psql
A=# BEGIN;
BEGIN

A=# UPDATE orders SET status = 'paid' WHERE id = 1;
UPDATE 1

B=# UPDATE orders SET status = 'canceled' WHERE id = 1;

C=# UPDATE orders SET status = 'shipped' WHERE id = 1;
```

B와 C의 UPDATE는 끝나지 않습니다.

```psql
postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app  |        state        | wtype  |  wait_event   | blocked_by |                     query
-----+-------+---------------------+--------+---------------+------------+-----------------------------------------------
 104 | app_a | idle in transaction | Client | ClientRead    | {}         | UPDATE orders SET status = 'paid' WHERE id =
 141 | app_b | active              | Lock   | transactionid | {104}      | UPDATE orders SET status = 'canceled' WHERE i
 178 | app_c | active              | Lock   | tuple         | {141}      | UPDATE orders SET status = 'shipped' WHERE id
(3 rows)
```

- A는 `idle in transaction`입니다. 아무 쿼리도 실행하지 않지만 id = 1 행의 락을 쥐고 있습니다.
- B는 `Lock`/`transactionid`, 즉 **A의 트랜잭션이 끝나기를** 기다립니다(`blocked_by {104}`).
- C는 A가 아니라 **B에게** 막혀 있고(`blocked_by {141}`), 기다리는 대상도 `tuple`입니다.

C가 왜 B를 기다리는지는 `pg_locks`에서 보입니다.

```psql
postgres=# SELECT l.pid, a.application_name AS app, l.locktype, l.transactionid AS xid,
postgres-#        l.page, l.tuple, l.mode, l.granted
postgres-# FROM pg_locks l JOIN pg_stat_activity a USING (pid)
postgres-# WHERE l.locktype IN ('transactionid', 'tuple') AND a.application_name LIKE 'app_%'
postgres-# ORDER BY l.granted DESC, l.pid;
 pid |  app  |   locktype    | xid | page | tuple |     mode      | granted
-----+-------+---------------+-----+------+-------+---------------+---------
 104 | app_a | transactionid | 754 |      |       | ExclusiveLock | t
 141 | app_b | tuple         |     |    0 |     1 | ExclusiveLock | t
 141 | app_b | transactionid | 755 |      |       | ExclusiveLock | t
 178 | app_c | transactionid | 756 |      |       | ExclusiveLock | t
 141 | app_b | transactionid | 754 |      |       | ShareLock     | f
 178 | app_c | tuple         |     |    0 |     1 | ExclusiveLock | f
(6 rows)
```

모든 트랜잭션은 자기 트랜잭션 ID에 `ExclusiveLock`을 걸어 둡니다. 행을 고치려다 다른 트랜잭션이 이미 고친 행을 만나면, 그 트랜잭션 ID에 `ShareLock`을 요청해서 끝나기를 기다립니다(B의 `754 ShareLock f`). 이 방식은 [인터널 4편](/posts/postgresql/04-mvcc/)에서 다뤘습니다.

같은 행을 여러 세션이 기다릴 때는 순서를 정하는 장치가 하나 더 있습니다. 가장 먼저 온 B가 그 행의 **튜플 락**(`tuple`, 페이지 0의 1번 튜플)을 잡고 줄 맨 앞에 서고, 뒤에 온 C는 그 튜플 락을 기다립니다. 그래서 C의 `blocked_by`에는 B가 나옵니다. 행 하나에 대기자가 열 명이면 한 명은 `transactionid`, 나머지 아홉 명은 `tuple`을 기다리는 모습으로 보입니다.

서버 로그에도 두 가지 대기가 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'still waiting|Process holding|STATEMENT'
2026-09-26 09:49:39.566 UTC [141] postgres@postgres/app_b LOG:  process 141 still waiting for ShareLock on transaction 754 after 1000.154 ms
2026-09-26 09:49:39.566 UTC [141] postgres@postgres/app_b DETAIL:  Process holding the lock: 104. Wait queue: 141.
2026-09-26 09:49:39.566 UTC [141] postgres@postgres/app_b STATEMENT:  UPDATE orders SET status = 'canceled' WHERE id = 1;
2026-09-26 09:49:40.864 UTC [178] postgres@postgres/app_c LOG:  process 178 still waiting for ExclusiveLock on tuple (0,1) of relation 16384 of database 5 after 1000.504 ms
2026-09-26 09:49:40.864 UTC [178] postgres@postgres/app_c DETAIL:  Process holding the lock: 141. Wait queue: 178.
2026-09-26 09:49:40.864 UTC [178] postgres@postgres/app_c STATEMENT:  UPDATE orders SET status = 'shipped' WHERE id = 1;
```

튜플 락 대기는 테이블과 DB를 OID로 적습니다.

```psql
postgres=# SELECT (SELECT oid FROM pg_class WHERE relname = 'orders') AS orders_oid,
postgres-#        (SELECT oid FROM pg_database WHERE datname = 'postgres') AS postgres_oid;
 orders_oid | postgres_oid
------------+--------------
      16384 |            5
(1 row)
```

`relation 16384 of database 5`는 `postgres` DB의 `orders` 테이블입니다.

### DDL 락 큐: 컬럼 하나 추가하다 서비스가 멈춘다

운영에서 가장 흔하고 피해가 큰 경우입니다. 세션 A가 트랜잭션 안에서 `orders`를 읽고 커밋하지 않은 채 멈춰 있습니다. 여기에 B가 컬럼을 추가합니다.

```psql
A=# BEGIN;
BEGIN

A=# SELECT count(*) FROM orders;
 count
-------
     3
(1 row)


B=# ALTER TABLE orders ADD COLUMN note text;
```

A는 읽기만 했으므로 `AccessShareLock`만 쥐고 있습니다. 읽기끼리는 서로 막지 않지만, `ALTER TABLE ... ADD COLUMN`은 테이블에 **AccessExclusiveLock**을 요청하고, 이 락은 읽기를 포함한 모든 락과 충돌합니다. 그래서 B는 A가 끝나기를 기다립니다. 여기까지는 B 하나만 멈춘 것입니다.

문제는 그 뒤에 들어오는 평범한 SELECT입니다.

```console
$ for i in 1 2 3 4 5; do PGAPPNAME=reader nohup psql -X -c "SELECT count(*) FROM orders" > /tmp/reader_$i.out 2>&1 & done
```

```psql
postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app   |        state        | wtype  | wait_event | blocked_by |                  query
-----+--------+---------------------+--------+------------+------------+------------------------------------------
 445 | app_a  | idle in transaction | Client | ClientRead | {}         | SELECT count(*) FROM orders;
 482 | app_b  | active              | Lock   | relation   | {445}      | ALTER TABLE orders ADD COLUMN note text;
 582 | reader | active              | Lock   | relation   | {482}      | SELECT count(*) FROM orders
 583 | reader | active              | Lock   | relation   | {482}      | SELECT count(*) FROM orders
 584 | reader | active              | Lock   | relation   | {482}      | SELECT count(*) FROM orders
 585 | reader | active              | Lock   | relation   | {482}      | SELECT count(*) FROM orders
 586 | reader | active              | Lock   | relation   | {482}      | SELECT count(*) FROM orders
(7 rows)
```

**SELECT 다섯 개가 모두 멈췄습니다.** 그런데 막고 있는 것은 A가 아니라 B(`blocked_by {482}`)입니다. SELECT가 요청하는 `AccessShareLock`은 A가 쥔 락과는 충돌하지 않지만, 줄 앞에서 기다리는 B의 `AccessExclusiveLock`과는 충돌합니다. PostgreSQL은 먼저 줄을 선 요청을 앞지르지 못하게 하므로, 새 SELECT도 B 뒤에 섭니다. 문서는 이것을 락을 쥐고 막는 "hard block"과 구분해 **soft block**이라고 부릅니다([pg_blocking_pids](https://www.postgresql.org/docs/18/functions-info.html#FUNCTIONS-INFO-SESSION)).

`pg_locks`로 줄의 모양이 그대로 보입니다.

```psql
postgres=# SELECT l.pid, a.application_name AS app, l.mode, l.granted,
postgres-#        now() - l.waitstart AS waiting
postgres-# FROM pg_locks l JOIN pg_stat_activity a USING (pid)
postgres-# WHERE l.locktype = 'relation' AND l.relation = 'orders'::regclass
postgres-# ORDER BY l.granted DESC, l.waitstart, l.pid;
 pid |  app   |        mode         | granted |     waiting
-----+--------+---------------------+---------+-----------------
 445 | app_a  | AccessShareLock     | t       |
 482 | app_b  | AccessExclusiveLock | f       | 00:00:03.994895
 582 | reader | AccessShareLock     | f       | 00:00:02.147873
 583 | reader | AccessShareLock     | f       | 00:00:02.147817
 584 | reader | AccessShareLock     | f       | 00:00:02.147746
 585 | reader | AccessShareLock     | f       | 00:00:02.147622
 586 | reader | AccessShareLock     | f       | 00:00:02.147417
(7 rows)
```

`granted = t`인 것은 A 하나뿐이고, 나머지는 `waitstart` 순서대로 줄을 섰습니다. 이 테이블을 읽는 모든 요청이 이 줄에 합류하므로, 몇 초 만에 커넥션 풀이 가득 차고 서비스 전체가 멈춘 것처럼 보입니다. 서버 로그에는 평범한 SELECT가 `AccessShareLock`을 기다린다는 줄이 쌓입니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'still waiting for AccessShareLock' | head -n 2
2026-09-26 09:49:59.638 UTC [583] postgres@postgres/reader LOG:  process 583 still waiting for AccessShareLock on relation 16384 of database 5 after 1001.405 ms at character 22
2026-09-26 09:49:59.638 UTC [585] postgres@postgres/reader LOG:  process 585 still waiting for AccessShareLock on relation 16384 of database 5 after 1001.535 ms at character 22
```

**SELECT가 `AccessShareLock`을 1초 넘게 기다린다는 로그**는 거의 언제나 누군가 `AccessExclusiveLock`을 기다리며 줄 앞을 막고 있다는 신호입니다. 같은 테이블에 대한 `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `VACUUM FULL`, `CLUSTER`, `LOCK TABLE`을 찾아보고, 그 앞에서 트랜잭션을 열어 둔 세션을 찾습니다.

A가 트랜잭션을 끝내면 줄은 한꺼번에 풀립니다.

```psql
A=# ROLLBACK;
ROLLBACK

# 세션 B: 앞 명령의 결과를 기다림
ALTER TABLE
```

```console
$ cat /tmp/reader_1.out
 count
-------
     3
(1 row)
```

### deadlock: 서로가 서로를 기다린다

A는 1번 행을, B는 2번 행을 고친 뒤, 서로 상대의 행을 고치려 합니다.

```psql
A=# BEGIN;
BEGIN

A=# UPDATE orders SET status = 'a' WHERE id = 1;
UPDATE 1

B=# BEGIN;
BEGIN

B=# UPDATE orders SET status = 'b' WHERE id = 2;
UPDATE 1

A=# UPDATE orders SET status = 'a' WHERE id = 2;

B=# UPDATE orders SET status = 'b' WHERE id = 1;
ERROR:  deadlock detected
DETAIL:  Process 1002 waits for ShareLock on transaction 760; blocked by process 965.
Process 965 waits for ShareLock on transaction 772; blocked by process 1002.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,6) in relation "orders"
```

A의 두 번째 UPDATE는 B를 기다리고, B의 두 번째 UPDATE는 A를 기다립니다. 둘 다 영원히 기다릴 상황입니다. PostgreSQL은 락을 `deadlock_timeout`(기본 1초)만큼 기다린 세션에서 대기 관계에 순환이 있는지 검사하고, 순환이 있으면 한쪽 트랜잭션을 에러로 끝냅니다. 어느 쪽이 끝날지는 미리 알기 어렵다고 문서가 말합니다([Deadlocks](https://www.postgresql.org/docs/18/explicit-locking.html#LOCKING-DEADLOCKS)).

B가 에러를 받는 순간 A가 풀립니다.

```psql
# 세션 A: 앞 명령의 결과를 기다림
UPDATE 1

B=# COMMIT;
ROLLBACK

A=# COMMIT;
COMMIT

postgres=# SELECT id, status FROM orders ORDER BY id;
 id | status
----+--------
  1 | a
  2 | a
  3 | new
(3 rows)
```

B의 트랜잭션은 이미 실패했으므로 `COMMIT`을 보내도 `ROLLBACK`으로 끝납니다. 애플리케이션은 deadlock 에러를 받으면 트랜잭션을 **처음부터 다시** 실행해야 합니다.

클라이언트가 받은 에러에는 PID와 트랜잭션 ID만 있고, `HINT`가 말하듯 각 프로세스가 실행하던 쿼리는 서버 로그에만 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 6 -E 'ERROR:  deadlock detected'
2026-09-26 09:50:34.438 UTC [1002] postgres@postgres/app_b ERROR:  deadlock detected
2026-09-26 09:50:34.438 UTC [1002] postgres@postgres/app_b DETAIL:  Process 1002 waits for ShareLock on transaction 760; blocked by process 965.
	Process 965 waits for ShareLock on transaction 772; blocked by process 1002.
	Process 1002: UPDATE orders SET status = 'b' WHERE id = 1;
	Process 965: UPDATE orders SET status = 'a' WHERE id = 2;
2026-09-26 09:50:34.438 UTC [1002] postgres@postgres/app_b HINT:  See server log for query details.
2026-09-26 09:50:34.438 UTC [1002] postgres@postgres/app_b CONTEXT:  while updating tuple (0,6) in relation "orders"
```

`Process 1002: ...`, `Process 965: ...` 두 줄이 deadlock의 양쪽 쿼리입니다. deadlock이 났다는 신고를 받으면 이 두 줄부터 찾습니다. 누적 횟수는 `pg_stat_database`에 있습니다.

```psql
postgres=# SELECT datname, deadlocks FROM pg_stat_database WHERE datname = 'postgres';
 datname  | deadlocks
----------+-----------
 postgres |         1
(1 row)
```

## 조치

### pg_cancel_backend는 idle in transaction을 풀지 못한다

행 락 상황으로 돌아갑니다. 뿌리인 A는 `idle in transaction`입니다. 먼저 `pg_cancel_backend`를 보냅니다.

```psql
postgres=# SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'app_a';
 pg_cancel_backend
-------------------
 t
(1 row)


postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app  |        state        | wtype  |  wait_event   | blocked_by |                     query
-----+-------+---------------------+--------+---------------+------------+-----------------------------------------------
 104 | app_a | idle in transaction | Client | ClientRead    | {}         | UPDATE orders SET status = 'paid' WHERE id =
 141 | app_b | active              | Lock   | transactionid | {104}      | UPDATE orders SET status = 'canceled' WHERE i
 178 | app_c | active              | Lock   | tuple         | {141}      | UPDATE orders SET status = 'shipped' WHERE id
(3 rows)
```

함수는 `t`를 돌려주지만 **아무것도 바뀌지 않았습니다.** `pg_cancel_backend`는 세션이 **실행 중인 쿼리**를 취소하는데, A는 실행 중인 쿼리가 없습니다. 트랜잭션은 그대로 열려 있고 락도 그대로입니다. `active` 상태로 오래 도는 쿼리가 뿌리라면 `pg_cancel_backend`가 먼저 시도할 방법이지만, `idle in transaction`에는 소용이 없습니다.

세션 자체를 끊어야 합니다.

```psql
postgres=# SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'app_a';
 pg_terminate_backend
----------------------
 t
(1 row)


# 세션 B: 앞 명령의 결과를 기다림
UPDATE 1

# 세션 C: 앞 명령의 결과를 기다림
UPDATE 1

postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app  | state | wtype  | wait_event | blocked_by |                     query
-----+-------+-------+--------+------------+------------+-----------------------------------------------
 141 | app_b | idle  | Client | ClientRead | {}         | UPDATE orders SET status = 'canceled' WHERE i
 178 | app_c | idle  | Client | ClientRead | {}         | UPDATE orders SET status = 'shipped' WHERE id
(2 rows)
```

A가 끊기자 B와 C가 차례로 끝났습니다. A 쪽 클라이언트는 다음 명령을 보낼 때에야 연결이 끊겼다는 것을 압니다.

```psql
A=# SELECT 1;
FATAL:  terminating connection due to administrator command
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

`pg_terminate_backend`는 그 세션의 트랜잭션을 **롤백**합니다. A가 고쳐 둔 `'paid'`는 사라지고, B와 C의 UPDATE가 차례로 반영되었습니다.

```psql
postgres=# SELECT id, status FROM orders WHERE id = 1;
 id | status
----+---------
  1 | shipped
(1 row)
```

그러니 세션을 끊기 전에 그 세션이 무슨 일을 하던 중인지(`query`, `xact_start`, `application_name`, `client_addr`) 확인하고 기록해 두어야 합니다. 배치 작업이 몇 시간째 돌던 트랜잭션이라면 끊는 순간 그 작업 전체가 롤백됩니다.

| 함수 | 하는 일 | 효과가 있는 경우 | 클라이언트가 받는 것 |
|---|---|---|---|
| `pg_cancel_backend(pid)` | 실행 중인 쿼리 취소 | `active` 상태의 오래 걸리는 쿼리 | 쿼리만 에러로 끝나고 세션은 유지 |
| `pg_terminate_backend(pid)` | 세션 종료, 트랜잭션 롤백 | `idle in transaction` 포함 모든 경우 | `FATAL: terminating connection due to administrator command` |

### DDL에는 lock_timeout을 건다

DDL 락 큐는 DDL이 **오래 기다리기 때문에** 생깁니다. DDL이 금방 포기하면 줄도 금방 풀립니다. 같은 상황을 `lock_timeout = '2s'`로 다시 만듭니다.

```psql
A=# BEGIN;
BEGIN

A=# SELECT count(*) FROM orders;
 count
-------
     3
(1 row)


B=# SET lock_timeout = '2s';
SET

B=# ALTER TABLE orders ADD COLUMN memo text;
```

```console
$ for i in 1 2 3; do PGAPPNAME=reader nohup psql -X -c "SELECT count(*) FROM orders" > /tmp/reader2_$i.out 2>&1 & done
```

```psql
postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app   |        state        | wtype  | wait_event | blocked_by |                  query
-----+--------+---------------------+--------+------------+------------+------------------------------------------
 695 | app_a  | idle in transaction | Client | ClientRead | {}         | SELECT count(*) FROM orders;
 732 | app_b  | active              | Lock   | relation   | {695}      | ALTER TABLE orders ADD COLUMN memo text;
 853 | reader | active              | Lock   | relation   | {732}      | SELECT count(*) FROM orders
 852 | reader | active              | Lock   | relation   | {732}      | SELECT count(*) FROM orders
 854 | reader | active              | Lock   | relation   | {732}      | SELECT count(*) FROM orders
(5 rows)
```

2초 동안은 앞과 똑같이 SELECT가 B 뒤에 줄을 섭니다. 2초가 지나면 B가 포기합니다.

```psql
# 세션 B: 앞 명령의 결과를 기다림
ERROR:  canceling statement due to lock timeout

postgres=# SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
postgres-#        pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
postgres-# ORDER BY xact_start NULLS LAST, pid;
 pid |  app  |        state        | wtype  | wait_event | blocked_by |                  query
-----+-------+---------------------+--------+------------+------------+------------------------------------------
 695 | app_a | idle in transaction | Client | ClientRead | {}         | SELECT count(*) FROM orders;
 732 | app_b | idle                | Client | ClientRead | {}         | ALTER TABLE orders ADD COLUMN memo text;
(2 rows)
```

```console
$ cat /tmp/reader2_1.out
 count
-------
     3
(1 row)
```

B는 `canceling statement due to lock timeout`으로 끝났고, 줄 서 있던 SELECT는 모두 결과를 받았습니다. A는 여전히 `idle in transaction`이지만 이제 아무도 막지 않습니다. 서비스는 2초 동안만 느려졌다가 돌아옵니다. A가 끝난 뒤 다시 시도하면 DDL은 바로 성공합니다.

```psql
A=# ROLLBACK;
ROLLBACK

# A가 끝난 뒤 다시 시도하면 바로 성공한다

B=# ALTER TABLE orders ADD COLUMN memo text;
ALTER TABLE
```

운영에서 DDL을 실행할 때는 이렇게 합니다.

1. `SET lock_timeout`을 서비스가 견딜 수 있는 시간(수백 ms에서 수 초)으로 겁니다. `lock_timeout`은 락을 **얻으려고 기다리는 시간**에만 적용되고, 락을 얻은 뒤 실행하는 시간에는 적용되지 않습니다([lock_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-LOCK-TIMEOUT)).
2. 실패하면 잠시 쉬었다가 다시 시도합니다. 스크립트나 마이그레이션 도구에서 재시도 루프로 감쌉니다.
3. 계속 실패하면 위의 "먼저 확인할 것" 쿼리로 줄 앞을 막는 세션을 찾습니다.

`lock_timeout`을 서버 전체에 거는 것은 권하지 않습니다. 일반 쿼리까지 락 대기 중에 에러가 나기 시작합니다. DDL을 실행하는 세션에서만 겁니다.

### deadlock은 순서를 맞추고 재시도한다

deadlock은 PostgreSQL이 알아서 풀어 주므로 "조치"라기보다 애플리케이션을 고칠 일입니다.

- 여러 행을 고치는 트랜잭션은 **항상 같은 순서**(예: 기본 키 순서)로 행을 고칩니다. 위 실습에서 A와 B가 둘 다 1번, 2번 순서로 고쳤다면 B는 1번에서 기다렸다가 A가 끝난 뒤 진행했을 것입니다.
- 트랜잭션 초반에 `SELECT ... FOR UPDATE ... ORDER BY id`로 필요한 행을 한꺼번에 순서대로 잠그는 방법도 있습니다.
- deadlock 에러(SQLSTATE `40P01`)는 재시도하면 대개 성공합니다. 애플리케이션에 재시도 로직을 둡니다.

## 재발 방지

**알람 쿼리.** 락을 기다리는 세션 수와 가장 오래 기다린 시간을 주기적으로 수집합니다. DDL 락 큐 상황에서 이 쿼리는 이렇게 나왔습니다.

```psql
postgres=# SELECT count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting,
postgres-#        max(now() - query_start) FILTER (WHERE wait_event_type = 'Lock') AS longest_wait
postgres-# FROM pg_stat_activity
postgres-# WHERE backend_type = 'client backend';
 waiting |  longest_wait
---------+-----------------
       6 | 00:00:04.054387
(1 row)
```

`waiting`이 평소보다 크거나 `longest_wait`가 수 초를 넘으면 알람을 보내고, 그때 "먼저 확인할 것" 쿼리를 돌립니다. 이 쿼리는 `pg_blocking_pids()`를 부르지 않으므로 자주 돌려도 부담이 적습니다.

**로그.** `log_lock_waits = on`이면 `deadlock_timeout`보다 오래 기다린 락이 모두 기록됩니다([1편](/posts/postgresql-ops/01-diagnostic-toolkit/)). 장애가 지나간 뒤 원인을 찾을 수 있는 곳은 이 로그뿐입니다.

**idle in transaction 막기.** 이 글의 세 사례 모두 뿌리는 트랜잭션을 열어 둔 채 멈춘 세션이었습니다. `idle_in_transaction_session_timeout`으로 이런 세션을 자동으로 끊을 수 있고, 이 설정과 오래 열린 트랜잭션의 다른 피해는 4편에서 다룹니다.

**에러 코드별 대응.**

| 에러 | SQLSTATE | 의미 | 애플리케이션 대응 |
|---|---|---|---|
| `deadlock detected` | `40P01` | deadlock으로 트랜잭션이 취소됨 | 트랜잭션 전체 재시도 |
| `canceling statement due to lock timeout` | `55P03` | `lock_timeout` 초과 | 잠시 뒤 재시도 |
| `terminating connection due to administrator command` | `57P01` | 관리자가 세션을 끊음 | 재접속, 작업 재실행 여부 판단 |

## 정리

- 세션이 멈추면 `pg_stat_activity`의 `wait_event_type`과 `pg_blocking_pids()`로 줄을 따라 올라가 **자기는 막히지 않고 남을 막는 세션**을 찾습니다. 대개 `idle in transaction`입니다.
- 같은 행을 여러 세션이 기다리면 맨 앞 하나만 `transactionid`를, 나머지는 `tuple`을 기다립니다.
- `AccessExclusiveLock`을 기다리는 DDL은 뒤에 오는 평범한 SELECT까지 막습니다(soft block). SELECT가 `AccessShareLock`을 기다린다는 로그가 그 신호입니다.
- `pg_cancel_backend`는 `idle in transaction`을 풀지 못합니다. `pg_terminate_backend`는 풀지만 그 트랜잭션을 롤백합니다.
- DDL에는 세션 단위로 `lock_timeout`을 걸고 재시도합니다.
- deadlock은 PostgreSQL이 한쪽을 에러로 끝내 풀어 줍니다. 양쪽 쿼리는 서버 로그에 남고, 애플리케이션은 순서를 맞추고 재시도합니다.

## 참고 자료

- [Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html): 테이블 락 충돌 표, 행 락, deadlock
- [pg_locks](https://www.postgresql.org/docs/18/view-pg-locks.html)
- [pg_blocking_pids와 세션 정보 함수](https://www.postgresql.org/docs/18/functions-info.html#FUNCTIONS-INFO-SESSION)
- [Server Signaling Functions](https://www.postgresql.org/docs/18/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL): `pg_cancel_backend`, `pg_terminate_backend`
- [lock_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-LOCK-TIMEOUT), [deadlock_timeout](https://www.postgresql.org/docs/18/runtime-config-locks.html#GUC-DEADLOCK-TIMEOUT)
- [PostgreSQL Error Codes](https://www.postgresql.org/docs/18/errcodes-appendix.html)
- PostgreSQL 인터널 [4편 MVCC](/posts/postgresql/04-mvcc/)

