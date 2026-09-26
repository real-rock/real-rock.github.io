---
title: "PostgreSQL 운영 3: 쿼리가 갑자기 느려졌다"
date: 2026-09-26T19:00:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "실행 계획", "통계", "statement timeout"]
weight: 3
summary: "코드도 쿼리도 그대로인데 어제까지 빠르던 쿼리가 느려졌다면, 무엇이 바뀐 것인가"
description: "plan 변경, 통계, generic plan, auto_explain"
---

## 개요

배포한 것도 없고 쿼리도 그대로인데 어제까지 수십 ms에 끝나던 쿼리가 오늘은 타임아웃이 납니다. 이럴 때 바뀐 것은 대개 **실행 계획**입니다. PostgreSQL의 플래너는 통계로 행 수를 추정하고 그 추정에 맞는 계획을 고르는데([인터널 10편](/posts/postgresql/10-query-processing/)), 추정이 크게 빗나가면 몇 배에서 몇만 배까지 느린 계획을 고를 수 있습니다.

이 글에서 답할 질문은 다음과 같습니다.

- 쿼리가 느린 것인지, 무언가를 기다리는 것인지 어떻게 구분하는가
- 대량 적재 직후 통계가 데이터를 따라오지 못하면 무슨 일이 생기는가
- prepared statement는 왜 여섯 번째 실행부터 느려질 수 있는가
- psql에서 `EXPLAIN`하면 빠른데 애플리케이션에서는 느린 이유는 무엇인가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습에는 [1편](/posts/postgresql-ops/01-diagnostic-toolkit/)에서 다룬 `pg_stat_statements`와 `auto_explain`을 켜 둡니다. `auto_explain`의 기준은 실습 데이터에 맞춰 20ms로 낮췄습니다.

```psql
postgres=# ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, auto_explain;
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';
ALTER SYSTEM

postgres=# ALTER SYSTEM SET log_min_duration_statement = '1s';
ALTER SYSTEM
postgres=# ALTER SYSTEM SET auto_explain.log_min_duration = '20ms';
ALTER SYSTEM
```

## 먼저 확인할 것

### 기다리는가, 일하는가

느리다는 신고를 받으면 먼저 그 쿼리가 **무언가를 기다리는지** 봅니다. 대량 적재 직후 배치가 돌리는 조인 쿼리가 끝나지 않는 상황입니다.

```psql
postgres=# SELECT pid, state, wait_event_type, wait_event, now() - query_start AS running, left(query, 40) AS query
postgres-# FROM pg_stat_activity WHERE application_name = 'batch';
 pid | state  | wait_event_type | wait_event |     running     |                  query
-----+--------+-----------------+------------+-----------------+------------------------------------------
 236 | active |                 |            | 00:00:02.706459 | SELECT count(*) FROM orders o JOIN shipm
(1 row)
```

`state = active`인데 `wait_event_type`이 비어 있습니다. 락도 I/O도 기다리지 않고 **CPU에서 계속 일하고 있다**는 뜻입니다. 같은 순간 OS에서 보면 그 backend가 CPU 하나를 다 쓰고 있습니다.

```console
$ top -b -n 1 -u postgres | sed -n '7,9p'
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
    236 postgres  20   0  227632  51228  47976 R 100.0   0.2   0:02.90 postgres
```

`wait_event_type`이 `Lock`이면 [2편](/posts/postgresql-ops/02-blocked-sessions/)의 락 대기이고, `IO`면 디스크를 기다리는 것입니다. 여기처럼 아무것도 기다리지 않으면서 오래 도는 쿼리는 실행 계획을 의심합니다.

### 평소와 무엇이 다른가

`pg_stat_statements`에서 그 쿼리의 실행 시간 분포를 봅니다. 평균만 보지 말고 최솟값, 최댓값, 표준편차를 같이 봅니다.

```psql
postgres=# SELECT left(query, 60) AS query, calls,
postgres-#        round(min_exec_time::numeric, 2) AS min_ms, round(max_exec_time::numeric, 2) AS max_ms,
postgres-#        round(mean_exec_time::numeric, 2) AS mean_ms, round(stddev_exec_time::numeric, 2) AS stddev_ms
postgres-# FROM pg_stat_statements WHERE query LIKE '%customer_id = $1%';
                            query                             | calls | min_ms | max_ms | mean_ms | stddev_ms
--------------------------------------------------------------+-------+--------+--------+---------+-----------
 EXPLAIN (ANALYZE, BUFFERS) SELECT count(*), sum(amount) FROM |     1 |  19.73 |  19.73 |   19.73 |      0.00
 PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM or |     7 |   6.72 |  34.44 |   17.34 |      9.22
(2 rows)
```

같은 쿼리인데 최소 6.72ms, 최대 34.44ms입니다. 입력값에 따라 처리할 행 수가 다를 수도 있지만, **실행 계획이 바뀌었을 때도** 이렇게 분포가 벌어집니다. 어느 쪽인지는 그때의 실행 계획을 봐야 압니다.

### 그때의 실행 계획

나중에 `EXPLAIN`을 돌리면 **지금의** 계획이 나옵니다. 느렸던 순간의 계획은 `auto_explain`이 로그에 남긴 것을 봅니다. 이 로그를 어떻게 읽는지는 아래 generic plan 사례에서 다룹니다.

## 원인별 진단

### 대량 적재 직후: 통계가 데이터를 따라오지 못한다

주문 100만 행, 배송 100만 행이 있는 테이블을 `ANALYZE`해 두었습니다. 여기에 배치가 새 주문 10만 건과 배송 10만 건을 넣고, 곧바로 두 테이블을 조인합니다.

재현을 위해 두 테이블의 autovacuum을 꺼 두었습니다. 실제로는 적재 직후 autoanalyze가 돌기 전의 몇십 초에서 몇 분 사이에, 또는 아래에서 보듯 autoanalyze 기준에 못 미치는 적재에서 같은 일이 생깁니다.

```psql
postgres=# INSERT INTO orders SELECT g, 12 + g % 20000, 'pending', 1 FROM generate_series(1000001, 1100000) g;
INSERT 0 100000

postgres=# INSERT INTO shipments (order_id, state) SELECT g, 'ready' FROM generate_series(1000001, 1100000) g;
INSERT 0 100000
```

통계가 얼마나 낡았는지는 `pg_stat_user_tables`에서 봅니다.

```psql
postgres=# SELECT relname, n_live_tup, n_mod_since_analyze, last_analyze, last_autoanalyze
postgres-# FROM pg_stat_user_tables WHERE relname IN ('orders', 'shipments') ORDER BY relname;
  relname  | n_live_tup | n_mod_since_analyze |         last_analyze          | last_autoanalyze
-----------+------------+---------------------+-------------------------------+------------------
 orders    |    1100000 |              100000 | 2026-09-26 10:01:27.095322+00 |
 shipments |    1100000 |              100000 | 2026-09-26 10:01:27.164381+00 |
(2 rows)
```

`n_mod_since_analyze`는 마지막 `ANALYZE` 이후 바뀐 행 수입니다. 두 테이블 모두 10만 행이 바뀌었는데 통계는 그 전 상태입니다. 플래너가 쓰는 통계를 보면 이렇습니다.

```psql
postgres=# SELECT tablename, attname, most_common_vals, most_common_freqs
postgres-# FROM pg_stats WHERE attname IN ('status', 'state') ORDER BY tablename;
 tablename | attname | most_common_vals | most_common_freqs
-----------+---------+------------------+-------------------
 orders    | status  | {done}           | {1}
 shipments | state   | {delivered}      | {1}
(2 rows)
```

통계상 `orders.status`에는 `done`밖에 없고, `shipments.state`에는 `delivered`밖에 없습니다. 플래너 입장에서 `status = 'pending'`인 주문과 `state = 'ready'`인 배송은 거의 없습니다.

```psql
postgres=# EXPLAIN SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
postgres-# WHERE o.status = 'pending' AND s.state = 'ready';
                                            QUERY PLAN
---------------------------------------------------------------------------------------------------
 Aggregate  (cost=8.90..8.91 rows=1 width=8)
   ->  Nested Loop  (cost=0.85..8.90 rows=1 width=0)
         Join Filter: (o.id = s.order_id)
         ->  Index Scan using orders_status_idx on orders o  (cost=0.43..4.45 rows=1 width=8)
               Index Cond: (status = 'pending'::text)
         ->  Index Scan using shipments_state_idx on shipments s  (cost=0.43..4.45 rows=1 width=8)
               Index Cond: (state = 'ready'::text)
(7 rows)
```

양쪽 모두 **1행**으로 추정했습니다. 1행과 1행을 조인하는 가장 싼 방법은 nested loop입니다. 바깥쪽 한 행마다 안쪽을 한 번 읽으면 되니까요. 그런데 실제로는 양쪽이 10만 행씩이라, 바깥쪽 10만 행마다 안쪽 10만 행을 읽으며 `Join Filter`를 검사합니다. 100억 번입니다.

```psql
A=# SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
A-# WHERE o.status = 'pending' AND s.state = 'ready';
# 세션 A: 앞 명령의 결과를 기다림
ERROR:  canceling statement due to statement timeout
Time: 10000.218 ms (00:10.000)
```

배치 세션에 걸어 둔 `statement_timeout = '10s'` 덕분에 10초에서 끊겼습니다. 이것이 없었다면 이 쿼리는 CPU 하나를 차지한 채 계속 돌았을 것입니다. 서버 로그에도 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 1 -E 'statement timeout'
2026-09-26 10:01:42.785 UTC [236] postgres@postgres/batch ERROR:  canceling statement due to statement timeout
2026-09-26 10:01:42.785 UTC [236] postgres@postgres/batch STATEMENT:  SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
```

`ANALYZE`로 통계를 새로 모읍니다.

```psql
postgres=# ANALYZE orders;
ANALYZE

postgres=# ANALYZE shipments;
ANALYZE

postgres=# SELECT tablename, attname, most_common_vals, most_common_freqs
postgres-# FROM pg_stats WHERE attname IN ('status', 'state') ORDER BY tablename;
 tablename | attname | most_common_vals  |    most_common_freqs
-----------+---------+-------------------+--------------------------
 orders    | status  | {done,pending}    | {0.91033334,0.089666665}
 shipments | state   | {delivered,ready} | {0.9112333,0.088766664}
(2 rows)
```

이제 `pending`이 약 9%, `ready`가 약 9%라는 것을 압니다.

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
postgres-# WHERE o.status = 'pending' AND s.state = 'ready';
                                                                                   QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=6533.59..6533.60 rows=1 width=8) (actual time=16.348..17.140 rows=1.00 loops=1)
   Buffers: shared hit=1590
   ->  Gather  (cost=6533.37..6533.58 rows=2 width=8) (actual time=16.294..17.138 rows=2.00 loops=1)
         Workers Planned: 1
         Workers Launched: 1
         Buffers: shared hit=1590
         ->  Partial Aggregate  (cost=5533.37..5533.38 rows=1 width=8) (actual time=15.436..15.437 rows=1.00 loops=2)
               Buffers: shared hit=1590
               ->  Parallel Hash Join  (cost=3014.03..5520.50 rows=5150 width=0) (actual time=6.971..14.137 rows=50000.00 loops=2)
                     Hash Cond: (s.order_id = o.id)
                     Buffers: shared hit=1590
                     ->  Parallel Index Scan using shipments_state_idx on shipments s  (cost=0.43..2356.12 rows=57437 width=8) (actual time=0.020..2.557 rows=50000.00 loops=2)
                           Index Cond: (state = 'ready'::text)
                           Index Searches: 1
                           Buffers: shared hit=798
                     ->  Parallel Hash  (cost=2288.37..2288.37 rows=58019 width=8) (actual time=6.609..6.609 rows=50000.00 loops=2)
                           Buckets: 131072  Batches: 1  Memory Usage: 4960kB
                           Buffers: shared hit=792
                           ->  Parallel Index Scan using orders_status_idx on orders o  (cost=0.43..2288.37 rows=58019 width=8) (actual time=0.014..3.291 rows=50000.00 loops=2)
                                 Index Cond: (status = 'pending'::text)
                                 Index Searches: 1
                                 Buffers: shared hit=792
 Planning:
   Buffers: shared hit=269
 Planning Time: 0.343 ms
 Execution Time: 17.181 ms
(26 rows)
```

추정이 5만 8천 행 안팎으로 실제(한 worker당 5만 행)와 비슷해졌고, 계획은 hash join으로 바뀌었습니다. 같은 쿼리가 17ms에 끝납니다.

```psql
A=# SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
A-# WHERE o.status = 'pending' AND s.state = 'ready';
 count
--------
 100000
(1 row)

Time: 30.682 ms
```

**10초 타임아웃과 30ms의 차이가 통계 하나에서 나왔습니다.**

#### autovacuum이 켜져 있어도 생긴다

autovacuum은 마지막 `ANALYZE` 이후 바뀐 행 수가 `autovacuum_analyze_threshold`(기본 50) + `autovacuum_analyze_scale_factor`(기본 0.1) × 행 수를 넘으면 테이블을 `ANALYZE`합니다([Automatic Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-STATISTICS)). 100만 행 테이블이면 100,050행이 바뀌어야 합니다. 이 실습에서 넣은 10만 행은 **기준에 50행 모자랍니다.** autovacuum이 켜져 있었어도 이 적재로는 autoanalyze가 돌지 않았다는 뜻입니다. 테이블이 클수록 기준도 커지므로, 큰 테이블에 "전체의 10% 미만이지만 새로운 값으로만 이루어진" 데이터가 들어오면 통계는 한참 동안 그 값을 모릅니다.

### prepared statement: 여섯 번째 실행부터 계획이 바뀐다

두 번째 사례는 "psql에서 돌리면 빠른데 애플리케이션에서만 느리다"는 신고로 시작하는 경우가 많습니다. 주문 100만 행의 고객 분포는 이렇게 만들었습니다.

- 고객 1: 40만 행(40%)
- 고객 2~11: 3만 행씩(각 3%)
- 고객 12~20011: 15행씩

애플리케이션처럼 prepared statement로 고객별 합계를 구합니다. 고객 2~6을 차례로 조회합니다.

```psql
B=# PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM orders WHERE customer_id = $1;
PREPARE
Time: 0.823 ms

B=# EXECUTE by_cust(2);
 count |   sum
-------+----------
 30000 | 14936400
(1 row)

Time: 26.800 ms
...
B=# EXECUTE by_cust(6);
 count |   sum
-------+----------
 30000 | 14940000
(1 row)

Time: 7.095 ms

B=# SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;
  name   | generic_plans | custom_plans
---------+---------------+--------------
 by_cust |             0 |            5
(1 row)

Time: 1.384 ms
```

다섯 번 모두 custom plan으로 실행되었습니다. 여섯 번째로 고객 7을 조회하면 달라집니다.

```psql
B=# EXECUTE by_cust(7);
 count |   sum
-------+----------
 30000 | 14940900
(1 row)

Time: 19.671 ms

B=# SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;
  name   | generic_plans | custom_plans
---------+---------------+--------------
 by_cust |             1 |            5
(1 row)

Time: 0.641 ms
```

`generic_plans`가 1이 되었습니다. 이제 이 세션에서 `by_cust`는 **generic plan**을 씁니다. 그리고 대형 고객 1을 조회합니다.

```psql
B=# EXECUTE by_cust(1);
 count  |    sum
--------+-----------
 400000 | 199198818
(1 row)

Time: 34.710 ms

B=# EXPLAIN (ANALYZE, BUFFERS) EXECUTE by_cust(1);
                                                                    QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate  (cost=378.70..378.71 rows=1 width=16) (actual time=45.930..45.931 rows=1.00 loops=1)
   Buffers: shared hit=6709
   ->  Index Scan using orders_customer_id_idx on orders  (cost=0.43..378.18 rows=104 width=4) (actual time=0.043..26.661 rows=400000.00 loops=1)
         Index Cond: (customer_id = $1)
         Index Searches: 1
         Buffers: shared hit=6709
 Planning Time: 0.023 ms
 Execution Time: 46.001 ms
(8 rows)

Time: 46.294 ms
```

`Index Cond: (customer_id = $1)`처럼 값 대신 `$1`이 보이면 generic plan입니다. 플래너는 이 계획을 만들 때 `$1`이 무엇일지 모르므로 "평균적인 고객"을 가정해 104행으로 추정했습니다. 실제로는 40만 행을 인덱스로 하나씩 찾았습니다.

같은 쿼리를 psql에서 **상수로** 넣어 확인하면 전혀 다른 계획이 나옵니다.

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS) SELECT count(*), sum(amount) FROM orders WHERE customer_id = 1;
                                                                 QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=14575.83..14575.84 rows=1 width=16) (actual time=18.435..19.389 rows=1.00 loops=1)
   Buffers: shared hit=7007
   ->  Gather  (cost=14575.61..14575.82 rows=2 width=16) (actual time=18.378..19.385 rows=3.00 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         Buffers: shared hit=7007
         ->  Partial Aggregate  (cost=13575.61..13575.62 rows=1 width=16) (actual time=17.176..17.176 rows=1.00 loops=3)
               Buffers: shared hit=7007
               ->  Parallel Seq Scan on orders  (cost=0.00..12736.17 rows=167888 width=4) (actual time=0.008..12.608 rows=133333.33 loops=3)
                     Filter: (customer_id = 1)
                     Rows Removed by Filter: 233333
                     Buffers: shared hit=7007
 Planning:
   Buffers: shared hit=103
 Planning Time: 0.239 ms
 Execution Time: 19.441 ms
(16 rows)
```

값이 `1`인 것을 아니까 프로세스당 16만 8천 행(프로세스 3개)을 추정하고 병렬 순차 스캔을 골랐습니다. 이 실습에서는 19ms 대 46ms, 두 배 남짓입니다. 행 40만 개를 인덱스로 하나씩 찾는 계획이라 데이터가 캐시에 없으면 차이는 더 벌어집니다. **psql에서 상수를 넣어 `EXPLAIN`하면 애플리케이션이 실제로 쓰는 계획을 볼 수 없다**는 것이 핵심입니다.

#### 왜 여섯 번째인가

prepared statement는 처음 다섯 번은 매번 입력값을 넣어 계획을 새로 세웁니다(custom plan). 그다음부터는 입력값과 상관없는 generic plan의 추정 비용을 custom plan들의 평균 비용과 비교해, generic plan이 크게 비싸지 않으면 generic plan을 계속 씁니다([PREPARE](https://www.postgresql.org/docs/18/sql-prepare.html#SQL-PREPARE-NOTES)). 계획을 세우는 비용을 아끼려는 장치입니다.

문제는 generic plan의 추정입니다. `customer_id = $1`의 행 수는 값을 모르므로 대략 "전체 행 수 ÷ 서로 다른 값의 수"로 추정합니다. 고객이 2만 명 넘게 있으니 104행이 나왔고, 이는 고객 2~6의 custom plan(각 3만 행)보다 싸 보였습니다. 그래서 generic plan이 채택되었고, 대형 고객 1에게는 최악의 계획이 되었습니다. 분포가 치우친 컬럼에서 이런 일이 생깁니다.

애플리케이션 드라이버가 서버 쪽 prepared statement를 쓰면 같은 일이 생깁니다. 드라이버가 prepared statement를 쓰는지, 몇 번째 실행부터 쓰는지는 드라이버 설정에 따라 다르므로 확인해 둡니다.

#### auto_explain 로그에서 구분하기

`auto_explain`은 prepared statement의 계획을 입력값과 함께 남깁니다.

```text
2026-09-26 10:01:51.084 UTC [447] postgres@postgres/app LOG:  duration: 25.169 ms  plan:
	Query Text: PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM orders WHERE customer_id = $1;
	Query Parameters: $1 = '2'
	Aggregate  (cost=7971.08..7971.09 rows=1 width=16)
	  ->  Bitmap Heap Scan on orders  (cost=398.78..7809.56 rows=32303 width=4)
	        Recheck Cond: (customer_id = 2)
	        ->  Bitmap Index Scan on orders_customer_id_idx  (cost=0.00..390.70 rows=32303 width=0)
	              Index Cond: (customer_id = 2)
2026-09-26 10:02:00.107 UTC [447] postgres@postgres/app LOG:  duration: 34.445 ms  plan:
	Query Text: PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM orders WHERE customer_id = $1;
	Query Parameters: $1 = '1'
	Aggregate  (cost=378.70..378.71 rows=1 width=16)
	  ->  Index Scan using orders_customer_id_idx on orders  (cost=0.43..378.18 rows=104 width=4)
	        Index Cond: (customer_id = $1)
2026-09-26 10:02:03.120 UTC [447] postgres@postgres/app LOG:  duration: 45.933 ms  plan:
	Query Text: PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM orders WHERE customer_id = $1;
	Query Parameters: $1 = '1'
	Aggregate  (cost=378.70..378.71 rows=1 width=16)
	  ->  Index Scan using orders_customer_id_idx on orders  (cost=0.43..378.18 rows=104 width=4)
	        Index Cond: (customer_id = $1)
```

- 첫 번째(`$1 = '2'`)는 custom plan입니다. 조건에 `customer_id = 2`처럼 **값이 박혀** 있고, 3만 2천 행을 추정해 bitmap scan을 골랐습니다.
- 나머지 둘(`$1 = '1'`)은 generic plan입니다. 조건이 `customer_id = $1`이고 추정은 104행입니다.

**느린 쿼리 로그에서 계획의 조건에 `$1`이 보이고 추정 행 수가 실제와 크게 다르면 generic plan을 의심합니다.** `Query Parameters`로 어떤 값에서 느렸는지도 알 수 있습니다.

## 조치

### 통계: ANALYZE

통계가 낡은 것이 원인이면 해당 테이블을 `ANALYZE`합니다. `ANALYZE`는 테이블 전체가 아니라 표본만 읽고, 읽기와 쓰기를 막지 않습니다.

근본적으로는 이렇게 합니다.

- **대량 적재를 하는 배치는 적재 직후 스스로 `ANALYZE`를 실행**합니다. autoanalyze를 기다리지 않습니다.
- 큰 테이블은 테이블 단위로 `autovacuum_analyze_scale_factor`를 낮추거나 `autovacuum_analyze_threshold`를 조정합니다(`ALTER TABLE ... SET (...)`). 이 조정은 5편에서 VACUUM 쪽 설정과 함께 다룹니다.

### 계획의 폭주를 끊는 안전장치: statement_timeout

통계를 아무리 관리해도 추정은 빗나갈 수 있습니다. 위 실습에서 서버를 지킨 것은 `statement_timeout`이었습니다. 배치나 애플리케이션 계정에 `ALTER ROLE ... SET statement_timeout`으로 그 작업이 넘을 리 없는 시간을 걸어 두면, 잘못된 계획이 CPU를 몇 시간씩 차지하는 일을 막을 수 있습니다. 서버 전체에 거는 것은 긴 관리 작업까지 끊기므로 권하지 않습니다([statement_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-STATEMENT-TIMEOUT)).

### generic plan: plan_cache_mode

`plan_cache_mode = force_custom_plan`이면 prepared statement도 매번 입력값으로 계획을 세웁니다.

```psql
B=# SET plan_cache_mode = force_custom_plan;
SET
Time: 0.479 ms

B=# EXECUTE by_cust(1);
 count  |    sum
--------+-----------
 400000 | 199198818
(1 row)

Time: 14.115 ms

B=# EXPLAIN (ANALYZE, BUFFERS) EXECUTE by_cust(1);
                                                                 QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=14575.83..14575.84 rows=1 width=16) (actual time=18.611..19.685 rows=1.00 loops=1)
   Buffers: shared hit=7007
   ->  Gather  (cost=14575.61..14575.82 rows=2 width=16) (actual time=18.553..19.681 rows=3.00 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         Buffers: shared hit=7007
         ->  Partial Aggregate  (cost=13575.61..13575.62 rows=1 width=16) (actual time=17.297..17.297 rows=1.00 loops=3)
               Buffers: shared hit=7007
               ->  Parallel Seq Scan on orders  (cost=0.00..12736.17 rows=167888 width=4) (actual time=0.008..12.643 rows=133333.33 loops=3)
                     Filter: (customer_id = 1)
                     Rows Removed by Filter: 233333
                     Buffers: shared hit=7007
 Planning Time: 0.067 ms
 Execution Time: 19.704 ms
(14 rows)

Time: 19.936 ms

B=# EXECUTE by_cust(2);
 count |   sum
-------+----------
 30000 | 14936400
(1 row)

Time: 5.853 ms

B=# SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;
  name   | generic_plans | custom_plans
---------+---------------+--------------
 by_cust |             3 |            8
```

같은 세션, 같은 prepared statement인데 이제 고객 1에게는 병렬 순차 스캔을, 고객 2에게는 그에 맞는 계획을 씁니다. `custom_plans`만 늘어나고 `generic_plans`는 3에서 멈췄습니다.

대가는 매 실행마다 계획을 세우는 비용입니다. 이 쿼리의 계획 시간은 0.067ms로 실행 시간에 비하면 무시할 만합니다. 계획이 복잡한 쿼리를 초당 수천 번 실행한다면 이 비용이 커질 수 있으므로, 서버 전체보다 **문제가 되는 계정이나 DB에만** 거는 편이 좋습니다.

```sql
ALTER ROLE app SET plan_cache_mode = force_custom_plan;
-- 또는 DB 단위
ALTER DATABASE appdb SET plan_cache_mode = force_custom_plan;
```

새로 접속하는 세션부터 적용되므로, 커넥션 풀을 쓰는 애플리케이션은 커넥션을 새로 맺어야 반영됩니다.

## 재발 방지

- **통계 신선도 감시**: `pg_stat_user_tables`의 `n_mod_since_analyze`와 `last_analyze`, `last_autoanalyze`를 주기적으로 봅니다. 큰 테이블에서 `n_mod_since_analyze`가 크게 쌓인 채 오래 머물면 그 테이블의 쿼리 계획이 위험합니다.
- **실행 시간 분포 감시**: `pg_stat_statements`의 `max_exec_time`과 `stddev_exec_time`이 평균보다 크게 튀는 쿼리를 찾습니다. 주기적으로 스냅샷을 떠 두면 "언제부터" 느려졌는지도 알 수 있습니다.
- **auto_explain을 켜 둔다**: 느렸던 순간의 계획은 여기에만 남습니다. 기준은 서비스의 느린 쿼리 기준과 맞춥니다.
- **배치의 적재 단계 끝에 `ANALYZE`**, 배치와 애플리케이션 계정에 `statement_timeout`.
- **분포가 치우친 컬럼을 조건으로 쓰는 prepared statement**는 generic plan 전환을 염두에 두고, 필요하면 그 계정에 `plan_cache_mode`를 겁니다.

## 정리

- 오래 도는 쿼리가 `wait_event` 없이 `active`면 CPU에서 일하는 중이고, 실행 계획을 의심합니다.
- 대량 적재 직후에는 통계가 새 값을 모릅니다. 1행으로 추정한 nested loop가 실제로는 10만 × 10만이 되어 `canceling statement due to statement timeout`으로 끝났고, `ANALYZE` 뒤에는 17ms에 끝났습니다.
- autoanalyze 기준은 행 수의 10%라서, 큰 테이블에는 기준에 못 미치는 적재로도 통계가 한참 낡을 수 있습니다. 적재한 쪽에서 `ANALYZE`합니다.
- prepared statement는 여섯 번째 실행부터 generic plan으로 바뀔 수 있고, 분포가 치우친 컬럼에서는 특정 값에 나쁜 계획이 됩니다. 계획의 조건에 `$1`이 보이면 generic plan입니다.
- psql에서 상수로 `EXPLAIN`하면 애플리케이션이 쓰는 계획이 아닐 수 있습니다. `auto_explain` 로그나 같은 세션의 `EXPLAIN EXECUTE`로 확인합니다.

## 참고 자료

- [Using EXPLAIN](https://www.postgresql.org/docs/18/using-explain.html)
- [Statistics Used by the Planner](https://www.postgresql.org/docs/18/planner-stats.html)
- [Updating Planner Statistics](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-STATISTICS)
- [PREPARE](https://www.postgresql.org/docs/18/sql-prepare.html), [plan_cache_mode](https://www.postgresql.org/docs/18/runtime-config-query.html#GUC-PLAN-CACHE-MODE)
- [statement_timeout](https://www.postgresql.org/docs/18/runtime-config-client.html#GUC-STATEMENT-TIMEOUT)
- [auto_explain](https://www.postgresql.org/docs/18/auto-explain.html), [pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html)
- PostgreSQL 인터널 [10편 쿼리 처리 과정](/posts/postgresql/10-query-processing/)

