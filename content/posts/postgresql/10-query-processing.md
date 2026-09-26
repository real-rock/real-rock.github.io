---
title: "PostgreSQL 인터널 10: 쿼리 처리 과정"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "쿼리", "플래너", "통계", "EXPLAIN"]
weight: 10
summary: "SQL 한 줄이 결과가 되기까지: 파서, 플래너, 실행기와 통계 정보"
description: "파서, 분석기, 리라이터, 플래너, 실행기와 통계 정보"
---

## 개요

지금까지는 데이터가 **어떻게 저장되고 지켜지는지**를 봤습니다. 마지막 편에서는 반대 방향, 사용자가 보낸 SQL 한 줄이 **어떻게 결과가 되는지**를 봅니다.

SQL은 "무엇을 원하는지"만 말하고 "어떻게 가져올지"는 말하지 않습니다. `WHERE amount < 30`을 만족하는 행을 찾으려면 테이블을 처음부터 끝까지 읽을 수도 있고, 인덱스를 쓸 수도 있습니다. 어느 쪽이 빠른지는 데이터에 따라 다르고, 이를 정하는 것이 **플래너**입니다. 플래너가 판단 근거로 쓰는 것이 **통계 정보**이고, 통계가 틀리면 계획도 틀립니다. 운영 중 "어제까지 빠르던 쿼리가 갑자기 느려졌다"의 상당수가 여기서 나옵니다.

이 글에서 답할 질문은 다음과 같습니다.

- SQL은 어떤 단계를 거쳐 실행되는가
- 플래너는 여러 실행 방법 중 하나를 어떻게 고르는가
- 통계 정보에는 무엇이 들어 있고, 행 수는 어떻게 추정되는가
- 추정이 틀리는 대표적인 경우와 고치는 방법은 무엇인가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Rocky Linux 9.8에서 빌드해 실행한 결과입니다.

## 다섯 단계

클라이언트가 보낸 SQL 문자열은 backend([1편](/posts/postgresql/01-process-architecture/)) 안에서 다섯 단계를 거칩니다. 전체 흐름은 [`exec_simple_query()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1012)에 그대로 드러나 있습니다.

{{< diagram src="/diagrams/pg-query-path.html" title="SQL 한 줄이 결과가 되기까지" height="600" caption="문자열이 파스 트리, Query 트리, 계획 트리로 바뀌고, 실행기가 계획 트리를 돌며 결과 행을 만듭니다." >}}

1. **파서(parser)**: 문자열을 문법 규칙([`gram.y`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/gram.y))에 맞춰 **파스 트리**로 바꿉니다([`raw_parser()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/parser.c#L42), [`postgres.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1065)의 `pg_parse_query()`를 거쳐 불립니다). 이 단계는 문법만 보고 카탈로그는 보지 않습니다. `orders`라는 테이블이 정말 있는지는 아직 모릅니다.
2. **분석기(analyzer)**: 시스템 카탈로그를 보며 이름을 실제 객체로 바꿉니다. `orders`가 어떤 OID의 테이블인지, `amount`가 몇 번째 컬럼이고 타입이 무엇인지, `<`가 어떤 연산자 함수인지 정해서 **Query 트리**를 만듭니다([`transformStmt()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/analyze.c#L312)). 없는 테이블이나 컬럼은 [여기서 오류가 납니다](#오류가-나는-단계로-보는-파서와-분석기의-차이).
3. **리라이터(rewriter)**: 규칙(rule)을 적용합니다. 가장 흔한 것은 **뷰**입니다. 뷰는 "이 이름을 이 SELECT로 바꿔라"라는 규칙으로 저장되어 있어, 리라이터가 뷰 이름을 그 정의(SELECT)의 서브쿼리로 바꿉니다([`QueryRewrite()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/rewrite/rewriteHandler.c#L4635), [`ApplyRetrieveRule()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/rewrite/rewriteHandler.c#L1746)). 플래너는 이 서브쿼리를 바깥 쿼리로 끌어올려(pull-up) 합치므로, 결국 뷰가 아니라 원래 테이블을 보고 계획을 세웁니다([뷰가 풀리는 모습](#리라이터-뷰는-원래-테이블로-풀린다)). 2번과 3번은 [`pg_analyze_and_rewrite_fixedparams()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1190)에서 함께 불립니다.
4. **플래너(planner)**: Query 트리를 실행할 수 있는 여러 방법(**경로, path**)을 만들고, 통계로 비용을 추정해 가장 싼 것을 **계획 트리**로 만듭니다([`planner()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/plan/planner.c#L310), [`create_plan()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/plan/createplan.c#L337)). `EXPLAIN`이 보여 주는 것이 이 계획 트리입니다.
5. **실행기(executor)**: 계획 트리를 실행합니다([`standard_ExecutorRun()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/execMain.c#L307)). 맨 위 노드에게 "행 하나 줘"라고 요청하면, 그 노드가 자기 아래 노드에게 다시 요청하는 식으로 행이 한 개씩 위로 올라옵니다([`ExecProcNode()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/executor/executor.h#L310)). 위에서 더 필요 없다고 하면 [아래 노드도 거기서 멈춥니다](#실행기는-필요한-만큼만-당겨-온다). 다만 정렬(Sort), 해시(Hash), 해시 집계(HashAggregate) 노드는 첫 행을 내기 전에 아래 입력을 모두 읽어야 하고, Bitmap Index Scan은 행 대신 비트맵을 통째로 넘깁니다. `EXPLAIN`의 비용 앞쪽 숫자(startup cost)가 이렇게 첫 행을 내기까지의 비용입니다.

#### 단계마다 걸린 시간

고객 1000명과 주문 10만 건을 만듭니다. 주문 상태(`status`)는 일부러 치우치게 했고(`delivered` 80%, `shipped` 15%, `cancelled` 4.9%, `returned` 0.1%), 금액(`amount`)은 0~999에 고르게 퍼지되 행의 물리적 순서와는 무관하게 흩어 놓았습니다. 도시(`city`)와 나라(`country`)는 도시가 정해지면 나라가 정해지는 관계입니다.

```console
$ pg_ctl -D $PGDATA -l /home/postgres/server.log start
waiting for server to start.... done
server started
```

```psql
postgres=# CREATE TABLE customers (id int PRIMARY KEY, name text);
postgres=# INSERT INTO customers SELECT g, 'customer ' || g FROM generate_series(1, 1000) g;
postgres=# CREATE TABLE orders (
postgres-#   id int PRIMARY KEY, customer_id int, status text, amount int, city text, country text);
postgres=# INSERT INTO orders
postgres-# SELECT g, g % 1000 + 1,
postgres-#        CASE WHEN g % 1000 < 800 THEN 'delivered' WHEN g % 1000 < 950 THEN 'shipped'
postgres-#             WHEN g % 1000 < 999 THEN 'cancelled' ELSE 'returned' END,
postgres-#        (g * 7919) % 1000,
postgres-#        (ARRAY['Seoul','Busan','Tokyo','Osaka','Paris','Lyon','Berlin','Munich','Rome','Milan'])[g % 10 + 1],
postgres-#        (ARRAY['KR','KR','JP','JP','FR','FR','DE','DE','IT','IT'])[g % 10 + 1]
postgres-# FROM generate_series(1, 100000) g;
postgres=# CREATE INDEX orders_customer_idx ON orders (customer_id);
postgres=# CREATE INDEX orders_amount_idx ON orders (amount);
postgres=# ANALYZE;
```

`log_parser_stats`, `log_planner_stats`, `log_executor_stats`를 켜면 단계마다 걸린 시간이 로그로 나옵니다. `client_min_messages = log`로 두어 psql 화면에서 바로 봅니다.

```console
$ PGOPTIONS="-c client_min_messages=log -c log_parser_stats=on -c log_planner_stats=on -c log_executor_stats=on" \
>   psql -X -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -E "^LOG:|elapsed|^ +status +\||^-+\+|^ [a-z]+ +\|"
LOG:  PARSER STATISTICS
!	0.000017 s user, 0.000017 s system, 0.000033 s elapsed
LOG:  PARSE ANALYSIS STATISTICS
!	0.000115 s user, 0.000115 s system, 0.000230 s elapsed
LOG:  REWRITER STATISTICS
!	0.000003 s user, 0.000003 s system, 0.000005 s elapsed
LOG:  PLANNER STATISTICS
!	0.000099 s user, 0.000099 s system, 0.000198 s elapsed
LOG:  EXECUTOR STATISTICS
!	0.000000 s user, 0.001685 s system, 0.001686 s elapsed
  status   | count 
-----------+-------
 returned  |   100
 cancelled |   400
 shipped   |  1400
 delivered |  8100
```

`PARSER` → `PARSE ANALYSIS` → `REWRITER` → `PLANNER` → `EXECUTOR` 순서로, 위에서 본 다섯 단계가 그대로 나옵니다. 이 쿼리에서는(`elapsed` 기준) 파싱이 0.000033초, 분석이 0.000230초, 계획이 0.000198초였고, 실제로 행을 읽고 집계한 실행이 0.001686초로 가장 깁니다. 분석이 계획만큼 걸린 것은 새 연결의 첫 쿼리라 카탈로그 캐시를 채우는 시간이 들어갔기 때문입니다. 쿼리가 복잡해지면(조인이 많으면) 계획 시간도 크게 늘어납니다.

#### 오류가 나는 단계로 보는 파서와 분석기의 차이

```psql
postgres=# SELEC * FROM orders;
ERROR:  syntax error at or near "SELEC"
LINE 1: SELEC * FROM orders
        ^
postgres=# SELECT * FROM order_typo;
ERROR:  relation "order_typo" does not exist
LINE 1: SELECT * FROM order_typo
                      ^
postgres=# SELECT nosuchcol FROM orders;
ERROR:  column "nosuchcol" does not exist
LINE 1: SELECT nosuchcol FROM orders
               ^
```

- `SELEC`는 문법에 맞지 않으므로 **파서**가 `syntax error`를 냅니다.
- `SELECT * FROM order_typo`는 문법은 맞습니다. 파서는 통과하고, 카탈로그에서 이름을 찾는 **분석기**가 `relation ... does not exist`를 냅니다. 없는 컬럼도 마찬가지입니다.

#### 내부 트리: Query와 PlannedStmt

`debug_print_rewritten`, `debug_print_plan`을 켜면 리라이터를 거친 Query 트리와 계획 트리 전체가 출력됩니다. 매우 길어서 트리에 나오는 노드 이름만 처음 나온 순서대로 뽑았습니다.

```console
$ psql -X -c "SET client_min_messages = log" -c "SET debug_print_rewritten = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
{QUERY {RANGETBLENTRY {ALIAS {VAR {RTEPERMISSIONINFO {FROMEXPR {RANGETBLREF {OPEXPR {CONST {TARGETENTRY {AGGREF {SORTGROUPCLAUSE 
$ psql -X -c "SET client_min_messages = log" -c "SET debug_print_plan = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
{PLANNEDSTMT {AGG {TARGETENTRY {VAR {AGGREF {BITMAPHEAPSCAN {BITMAPINDEXSCAN {OPEXPR {CONST {RANGETBLENTRY {ALIAS {RTEPERMISSIONINFO 
```

- **Query 트리**(첫 줄)에는 SQL의 구성 요소가 그대로 들어 있습니다. `RANGETBLENTRY`는 FROM의 `orders`(그리고 PG18부터 생긴 GROUP BY용 항목), `VAR`는 컬럼 참조, `OPEXPR`과 `CONST`는 `amount < 100`, `TARGETENTRY`와 `AGGREF`는 SELECT 목록의 `count(*)`, `SORTGROUPCLAUSE`는 GROUP BY입니다. "어떻게" 읽을지는 아직 들어 있지 않습니다.
- **계획 트리**(둘째 줄)에는 `PLANNEDSTMT` 아래에 `AGG`(집계), `BITMAPHEAPSCAN`, `BITMAPINDEXSCAN`(읽는 방법)이 있습니다. 플래너가 "`amount` 인덱스로 비트맵을 만들어 읽고 집계한다"는 방법을 정한 것입니다. `EXPLAIN`은 이 트리를 사람이 읽기 좋게 보여 주는 명령입니다.

#### 리라이터: 뷰는 원래 테이블로 풀린다

```psql
postgres=# CREATE VIEW big_orders AS SELECT id, customer_id, amount FROM orders WHERE amount >= 990;
postgres=# EXPLAIN (COSTS OFF) SELECT * FROM big_orders WHERE customer_id = 7;
                       QUERY PLAN                        
---------------------------------------------------------
 Bitmap Heap Scan on orders
   Recheck Cond: ((customer_id = 7) AND (amount >= 990))
   ->  BitmapAnd
         ->  Bitmap Index Scan on orders_customer_idx
               Index Cond: (customer_id = 7)
         ->  Bitmap Index Scan on orders_amount_idx
               Index Cond: (amount >= 990)
(7 rows)
```

뷰 `big_orders`를 조회했는데 계획에는 뷰가 없고 `orders`만 나옵니다. 리라이터가 뷰를 그 정의의 서브쿼리로 바꾸고, 플래너가 그 서브쿼리를 바깥 쿼리로 끌어올려, 뷰 안의 조건(`amount >= 990`)과 바깥 조건(`customer_id = 7`)이 한 쿼리가 되었습니다. 플래너는 두 조건을 합쳐 두 인덱스의 비트맵을 AND(`BitmapAnd`)해서 읽는 계획을 세웠습니다.

#### 실행기는 필요한 만큼만 당겨 온다

`EXPLAIN (ANALYZE)`는 실제로 실행해서 `rows=`(추정) 옆에 `actual rows=`(실제)를 보여 줍니다. PG18에서는 `EXPLAIN ANALYZE`에 `BUFFERS`가 기본으로 붙는데([2편](/posts/postgresql/02-memory-architecture/)), 여기서는 출력을 짧게 하려고 `BUFFERS OFF`, `TIMING OFF`를 붙였습니다.

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT * FROM orders LIMIT 5;
                     QUERY PLAN                      
-----------------------------------------------------
 Limit (actual rows=5.00 loops=1)
   ->  Seq Scan on orders (actual rows=5.00 loops=1)
 Planning Time: 0.128 ms
 Execution Time: 0.014 ms
(4 rows)
```

테이블은 10만 행이지만 `Seq Scan`의 `actual rows`가 5입니다. 실행기는 맨 위 `Limit` 노드가 아래 `Seq Scan`에게 행을 하나씩 달라고 하는 구조라, `Limit`이 5행을 받고 더 요청하지 않자 `Seq Scan`도 거기서 멈췄습니다([`ExecLimit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/nodeLimit.c#L40)).

## 플래너: 경로를 만들고 비용을 비교한다

{{< diagram src="/diagrams/pg-planner-estimate.html" title="플래너가 스캔 방법 하나를 고르는 과정" height="600" caption="조건의 선택도를 컬럼 통계로 추정하고 튜플 수를 곱해 행 수를 구한 뒤, 경로 후보마다 비용을 계산해 가장 싼 것을 고릅니다." >}}

테이블 하나를 읽는 방법만 해도 여러 가지입니다([`set_plain_rel_pathlist()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/allpaths.c#L772)).

| 스캔 | 방법 | 유리할 때 |
|---|---|---|
| Seq Scan | 테이블 전체를 처음부터 순서대로 읽음 | 많은 행을 가져올 때 |
| Index Scan | 인덱스에서 찾은 순서대로 테이블 페이지를 하나씩 읽음 | 아주 적은 행, 또는 인덱스 순서와 테이블 순서가 비슷할 때 |
| Bitmap Scan | 인덱스로 해당 페이지 목록(비트맵)을 먼저 만들고, 페이지 순서대로 읽음 | 그 중간, 또는 여러 인덱스를 AND/OR로 합칠 때([뷰 예시](#리라이터-뷰는-원래-테이블로-풀린다)) |
| Index Only Scan | 인덱스만 읽고 테이블은 건너뜀(visibility map이 all-visible인 페이지, [5편](/posts/postgresql/05-vacuum/)) | 필요한 컬럼이 모두 인덱스에 있을 때 |

### 비용 계산

플래너는 경로마다 **비용**(cost)을 계산합니다. 비용의 단위는 "페이지 하나를 순차로 읽는 비용 = 1"(`seq_page_cost`)이고, 나머지는 이를 기준으로 한 상대값입니다.

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `seq_page_cost` | 1 | 페이지 하나를 순차로 읽기 |
| `random_page_cost` | 4 | 페이지 하나를 임의 위치에서 읽기 |
| `cpu_tuple_cost` | 0.01 | 행 하나를 처리하기 |
| `cpu_operator_cost` | 0.0025 | 연산자(비교 등) 하나를 계산하기 |

예를 들어 Seq Scan의 비용은 `페이지 수 × seq_page_cost + 행 수 × (cpu_tuple_cost + 조건마다 cpu_operator_cost)`입니다(정확히는 조건마다 연산자 함수의 비용 계수 × `cpu_operator_cost`이고, `=`, `<` 같은 기본 연산자는 계수가 1, [`cost_seqscan()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/costsize.c#L323-L330)). 아래에서 이 식으로 계산한 값이 `EXPLAIN`의 숫자와 정확히 맞는 것을 확인합니다.

#### Seq Scan의 비용을 직접 계산해 보기

```psql
postgres=# SHOW seq_page_cost;
 seq_page_cost 
---------------
 1
(1 row)

postgres=# SHOW random_page_cost;
 random_page_cost 
------------------
 4
(1 row)

postgres=# SHOW cpu_tuple_cost;
 cpu_tuple_cost 
----------------
 0.01
(1 row)

postgres=# SHOW cpu_operator_cost;
 cpu_operator_cost 
-------------------
 0.0025
(1 row)

postgres=# EXPLAIN SELECT * FROM orders;
                          QUERY PLAN                           
---------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1805.00 rows=100000 width=30)
(1 row)

postgres=# EXPLAIN SELECT * FROM orders WHERE status = 'returned';
                         QUERY PLAN                         
------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=123 width=30)
   Filter: (status = 'returned'::text)
(2 rows)

postgres=# SELECT relpages * 1.0 + reltuples * 0.01 AS seqscan_cost, relpages * 1.0 + reltuples * 0.01 + reltuples * 0.0025 AS with_filter_cost FROM pg_class WHERE relname = 'orders';
 seqscan_cost | with_filter_cost 
--------------+------------------
         1805 |             2055
(1 row)
```

`EXPLAIN`의 `cost=0.00..1805.00`에서 앞의 숫자는 첫 행을 내기까지의 비용, 뒤의 숫자는 마지막 행까지의 총비용입니다. 계산해 보면,

- 조건 없음: 805페이지 × 1(`seq_page_cost`) + 100000행 × 0.01(`cpu_tuple_cost`) = **1805**
- 조건 하나: 여기에 100000행 × 0.0025(`cpu_operator_cost`, `status = 'returned'` 비교 한 번) = **2055**

마지막 쿼리로 계산한 값이 `EXPLAIN`과 정확히 같습니다. `ANALYZE` 직후라 `pg_class`의 값과 지금 테이블 크기가 같기 때문입니다(달라지는 경우는 [뒤에서](#분포가-바뀐-뒤의-추정) 봅니다). 비용은 이렇게 "몇 페이지를 읽고, 몇 행을 처리하는가"를 설정값으로 곱해 더한 것입니다. 조건이 붙어도 Seq Scan은 전체 행을 읽고 비교해야 하므로 총비용이 오히려 늘어납니다. 반면 `rows=`는 100000에서 123으로 줄었는데, 이것이 [행 수 추정](#통계-정보-행-수-추정의-근거)입니다.

### 조인 순서와 방식

테이블이 둘 이상이면 **조인 순서**와 **조인 방식**도 골라야 합니다.

| 조인 | 방법 | 유리할 때 |
|---|---|---|
| Nested Loop | 바깥 행 하나마다 안쪽을 찾음(보통 인덱스로) | 바깥 행이 적을 때 |
| Hash Join | 작은 쪽으로 해시 테이블을 만들고 큰 쪽을 훑으며 찾음 | 큰 테이블끼리, 해시할 쪽이 `work_mem`에 들어갈 때 |
| Merge Join | 양쪽을 조인 키 순서로 정렬해 나란히 훑음 | 양쪽이 이미 정렬되어 있을 때 |

Hash Join과 Merge Join은 등호(`=`) 조인에서만 쓸 수 있고, `a.x < b.y` 같은 조인은 Nested Loop만 가능합니다.

#### Nested Loop, Hash Join, Merge Join

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, o.amount FROM customers c JOIN orders o ON o.customer_id = c.id WHERE c.id = 42;
                                    QUERY PLAN                                     
-----------------------------------------------------------------------------------
 Nested Loop (actual rows=100.00 loops=1)
   ->  Index Scan using customers_pkey on customers c (actual rows=1.00 loops=1)
         Index Cond: (id = 42)
         Index Searches: 1
   ->  Bitmap Heap Scan on orders o (actual rows=100.00 loops=1)
         Recheck Cond: (customer_id = 42)
         Heap Blocks: exact=100
         ->  Bitmap Index Scan on orders_customer_idx (actual rows=100.00 loops=1)
               Index Cond: (customer_id = 42)
               Index Searches: 1
 Planning Time: 0.210 ms
 Execution Time: 0.351 ms
(12 rows)

postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name;
                               QUERY PLAN                                
-------------------------------------------------------------------------
 HashAggregate (actual rows=1000.00 loops=1)
   Group Key: c.name
   Batches: 1  Memory Usage: 121kB
   ->  Hash Join (actual rows=100000.00 loops=1)
         Hash Cond: (o.customer_id = c.id)
         ->  Seq Scan on orders o (actual rows=100000.00 loops=1)
         ->  Hash (actual rows=1000.00 loops=1)
               Buckets: 1024  Batches: 1  Memory Usage: 59kB
               ->  Seq Scan on customers c (actual rows=1000.00 loops=1)
 Planning Time: 0.252 ms
 Execution Time: 12.893 ms
(11 rows)

postgres=# SET enable_hashjoin = off;
SET
postgres=# SET enable_nestloop = off;
SET
postgres=# EXPLAIN (COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name;
                          QUERY PLAN                          
--------------------------------------------------------------
 HashAggregate
   Group Key: c.name
   ->  Merge Join
         Merge Cond: (c.id = o.customer_id)
         ->  Index Scan using customers_pkey on customers c
         ->  Index Scan using orders_customer_idx on orders o
(6 rows)
```

- 고객 한 명(`c.id = 42`)의 주문: 바깥쪽이 1행이라 **Nested Loop**입니다. 고객 1행마다(`loops=1`) 안쪽에서 인덱스로 주문을 찾습니다. 안쪽 조건이 `customer_id = 42`인 것은, 플래너가 `c.id = 42`와 `o.customer_id = c.id`에서 `o.customer_id = 42`를 스스로 끌어냈기 때문입니다.
- 모든 고객의 주문 합계: 10만 행 전체를 조인하므로 **Hash Join**입니다. 작은 `customers`(1000행)로 해시 테이블을 만들고(`Hash`, 59kB), `orders`를 한 번 훑으며 찾습니다.
- Hash Join과 Nested Loop를 끄면 **Merge Join**이 나옵니다. 두 인덱스(`customers_pkey`, `orders_customer_idx`)를 조인 키 순서로 읽어 나란히 맞춰 갑니다. 플래너가 처음에 이것을 고르지 않은 것은 이 경우 Hash Join보다 비싸다고 계산했기 때문입니다.

#### 운영에서는: enable_* 설정은 진단용이다

위 실습에서 쓴 `enable_hashjoin = off` 같은 설정은 "그 방법을 절대 쓰지 말라"가 아닙니다. PG18의 플래너는 경로마다 꺼진 방법을 쓴 노드 수(`disabled_nodes`)를 세어, 그 수가 적은 계획을 먼저 고르고 그다음에 비용을 비교합니다([`costsize.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/costsize.c#L357)). 다른 방법이 없으면 여전히 쓰이고, 이때 `EXPLAIN`에 `Disabled: true`가 표시됩니다. 다른 계획이 실제로 더 빠른지 확인하는 진단 도구로는 좋지만, 운영 설정으로 전역에 두면 데이터가 바뀌었을 때 더 나은 계획을 막습니다. 근본 원인인 추정 오류를 고치는 편이 낫습니다.

## 통계 정보: 행 수 추정의 근거

비용 계산에서 가장 중요한 입력은 "이 조건을 만족하는 행이 몇 개인가"입니다. 1개라면 인덱스가, 절반이라면 Seq Scan이 낫습니다. 플래너는 이것을 두 가지 통계로 추정합니다.

- **테이블 통계** (`pg_class`): 페이지 수 `relpages`, 행 수 `reltuples`. 계획할 때는 지금 실제 페이지 수를 보고, `reltuples / relpages`(페이지당 행 밀도)에 그 페이지 수를 곱해 행 수를 추정합니다([`tableam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/table/tableam.c#L711-L747)).
- **컬럼 통계** (`pg_statistic`, 읽기 쉬운 뷰는 `pg_stats`): 컬럼마다 NULL 비율(`null_frac`), 서로 다른 값의 수(`n_distinct`), **가장 흔한 값과 그 비율(MCV, `most_common_vals`, `most_common_freqs`)**, 나머지 값의 분포를 같은 개수씩 나눈 **히스토그램(`histogram_bounds`)**, 물리적 순서와 값 순서의 상관관계(`correlation`)가 들어 있습니다.

통계는 `ANALYZE`가 만듭니다. 테이블 전체가 아니라 **표본**을 읽습니다. 표본 크기는 `300 × default_statistics_target`(기본 100), 즉 30000행입니다([`analyze.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/analyze.c#L1940)).

#### pg_stats로 보는 통계 정보

```psql
postgres=# SELECT attname, null_frac, n_distinct, most_common_vals, most_common_freqs, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'status' \gx
-[ RECORD 1 ]-----+-------------------------------------------------
attname           | status
null_frac         | 0
n_distinct        | 4
most_common_vals  | {delivered,shipped,cancelled,returned}
most_common_freqs | {0.79906666,0.15003334,0.049666665,0.0012333334}
correlation       | 0.66688544

postgres=# SELECT attname, n_distinct, array_length(most_common_vals::text::int[], 1) AS mcv_count, (SELECT sum(f) FROM unnest(most_common_freqs) f) AS mcv_total_freq, array_length(histogram_bounds, 1) AS histogram_len, (histogram_bounds::text::int[])[1:6] AS histogram_head, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'amount' \gx
-[ RECORD 1 ]--+------------------
attname        | amount
n_distinct     | 1000
mcv_count      | 19
mcv_total_freq | 0.02666667
histogram_len  | 101
histogram_head | {0,9,19,29,39,48}
correlation    | -0.0008968399

postgres=# SELECT relname, relpages, reltuples FROM pg_class WHERE relname IN ('orders', 'customers') ORDER BY relname;
  relname  | relpages | reltuples 
-----------+----------+-----------
 customers |        7 |      1000
 orders    |      805 |    100000
(2 rows)
```

- `status`: 서로 다른 값이 4개(`n_distinct`)라 네 값이 모두 MCV에 들어 있고, 비율이 `0.79906666, 0.15003334, 0.049666665, 0.0012333334`입니다. 실제 비율(0.8, 0.15, 0.049, 0.001)과 조금씩 다른 것은 3만 행 표본으로 셌기 때문입니다. 비율은 표본에서 센 개수를 표본 크기로 나눈 값이라, `returned`의 0.0012333334는 표본 30000행 중 37행이었다는 뜻입니다. 표본은 매번 무작위로 뽑으므로 `ANALYZE`를 다시 하면 이 값들도 조금씩 달라집니다.
- `amount`: 서로 다른 값이 1000개이고 실제로는 모두 같은 비율(0.1%)이지만, 표본에서 우연히 조금 더 많이 나온 값 19개가 MCV로 남았습니다(`mcv_count`, 합계 비율 0.02666667, 값 하나에 평균 약 0.0014). ANALYZE는 표본 빈도가 평균보다 뚜렷하게 높은 값만 MCV로 남깁니다. 나머지 값의 분포는 히스토그램 경계값 101개(`histogram_len`)로 나타내고, 경계값 사이 100개 구간에는 MCV를 뺀 나머지 행이 같은 비율(1%)씩 들어갑니다. `correlation`이 0에 가까운 것은 `amount` 값의 순서와 행이 저장된 물리적 순서가 무관하다는 뜻입니다.
- 테이블 통계는 `orders`가 805페이지, 100000행입니다.

### 선택도와 행 수 추정

`WHERE status = 'shipped'`처럼 같다 조건이면 MCV에서 그 값의 비율을 찾고([`var_eq_const()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c#L303)), `WHERE amount < 30`처럼 범위 조건이면 히스토그램의 몇 번째 구간까지인지로 비율을 구합니다([`ineq_histogram_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c#L1050)). 이 비율이 **선택도**(selectivity)이고, 행 수 추정은 `선택도 × 행 수`입니다.

#### 추정과 실제: MCV와 히스토그램

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'shipped';
                                         QUERY PLAN                                          
---------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=15003 width=30) (actual rows=15000.00 loops=1)
   Filter: (status = 'shipped'::text)
   Rows Removed by Filter: 85000
 Planning Time: 0.149 ms
 Execution Time: 2.904 ms
(5 rows)

postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned';
                                       QUERY PLAN                                        
-----------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=123 width=30) (actual rows=100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 99900
 Planning Time: 0.125 ms
 Execution Time: 2.643 ms
(5 rows)

postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE amount < 30;
                                                    QUERY PLAN                                                    
------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on orders  (cost=34.91..876.38 rows=2918 width=30) (actual rows=3000.00 loops=1)
   Recheck Cond: (amount < 30)
   Heap Blocks: exact=805
   ->  Bitmap Index Scan on orders_amount_idx  (cost=0.00..34.18 rows=2918 width=0) (actual rows=3000.00 loops=1)
         Index Cond: (amount < 30)
         Index Searches: 1
 Planning Time: 0.140 ms
 Execution Time: 0.709 ms
(8 rows)
```

| 조건 | 추정 근거 | 추정 | 실제 |
|---|---|---|---|
| `status = 'shipped'` | MCV 비율 0.15003334 × 100000 | 15003 | 15000 |
| `status = 'returned'` | MCV 비율 0.0012333334 × 100000 | 123 | 100 |
| `amount < 30` | 히스토그램에서 30이 들어가는 위치(약 3.1%)에 MCV를 뺀 나머지 비율(1 − 0.02666667)을 곱함 | 2918 | 3000 |

추정은 통계 값을 그대로 곱한 것입니다. `amount < 30`을 풀어 보면, 30은 히스토그램의 넷째 구간(29~39)의 10% 지점이라 (3 + 0.1) / 100 = 0.031이고, `<`라서 30과 같은 값의 몫(MCV가 아닌 값 하나의 비율, 1 / (1000 − 19))을 빼면 0.02998, 여기에 히스토그램이 대표하는 비율(1 − 0.02666667)을 곱하면 0.02918, 즉 2918행입니다. 30 미만인 MCV 값이 있었다면 그 비율이 더해졌을 텐데, 계산이 `EXPLAIN`과 맞으므로 이번 표본에서는 없었던 셈입니다([`scalarineqsel()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c#L588)). 표본 오차 때문에 조금씩 어긋나지만(`returned`는 100행을 123행으로 봤습니다), 이 정도 차이는 계획을 바꾸지 않습니다. 문제가 되는 것은 [통계가 오래되었거나](#통계가-오래되면) [컬럼끼리 관련이 있어서](#조건이-여러-개일-때) 몇 배, 몇십 배씩 틀릴 때입니다.

`amount < 30`은 Bitmap Heap Scan인데, `Heap Blocks: exact=805`로 테이블의 모든 페이지를 읽었습니다. `amount`가 물리적 순서와 무관하게 흩어져 있어(`correlation` 약 0) 3000행이 모든 페이지에 퍼져 있기 때문입니다. 모든 페이지를 읽을 것으로 보면 페이지 비용은 Seq Scan과 같은 `seq_page_cost`로 계산되고, 조건을 검사할 행이 3000개뿐이라 CPU 비용이 적습니다. 그래서 Seq Scan(2055)보다 싸다(876.38)고 계산했습니다.

#### 선택도에 따라 스캔 방식이 바뀐다

```psql
postgres=# EXPLAIN SELECT * FROM orders WHERE id = 42;
                                QUERY PLAN                                 
---------------------------------------------------------------------------
 Index Scan using orders_pkey on orders  (cost=0.29..8.31 rows=1 width=30)
   Index Cond: (id = 42)
(2 rows)

postgres=# EXPLAIN SELECT * FROM orders WHERE amount < 30;
                                     QUERY PLAN                                     
------------------------------------------------------------------------------------
 Bitmap Heap Scan on orders  (cost=34.91..876.38 rows=2918 width=30)
   Recheck Cond: (amount < 30)
   ->  Bitmap Index Scan on orders_amount_idx  (cost=0.00..34.18 rows=2918 width=0)
         Index Cond: (amount < 30)
(4 rows)

postgres=# EXPLAIN SELECT * FROM orders WHERE amount < 800;
                          QUERY PLAN                          
--------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=80297 width=30)
   Filter: (amount < 800)
(2 rows)
```

- `id = 42`: 1행으로 추정되어 **Index Scan**입니다. 인덱스에서 찾아 테이블 페이지 하나만 읽습니다(비용 8.31).
- `amount < 30`: 약 3000행이라 **Bitmap Scan**입니다.
- `amount < 800`: 약 8만 행이라 **Seq Scan**입니다. 테이블의 80%를 가져올 때는 인덱스를 거치는 것이 더 비쌉니다.

같은 테이블, 같은 인덱스라도 추정 행 수에 따라 계획이 달라집니다. 그래서 추정이 틀리면 계획도 틀립니다.

#### 운영에서는: 인덱스가 있는데 사용되지 않는다

위 실습처럼 조건이 테이블의 상당 부분을 가져오면 Seq Scan이 실제로 더 빠르고, 플래너도 그쪽을 고릅니다. 인덱스를 쓰지 않는 것이 이상하다면, 먼저 추정 행 수가 맞는지 봅니다. 추정이 맞는데도 Seq Scan이라면 대부분 올바른 선택입니다. SSD처럼 임의 읽기가 빠른 저장 장치에서는 `random_page_cost`를 기본값 4보다 낮추는(예: 1.1) 경우가 많습니다. 이 밖에 컬럼에 함수를 씌우거나(`WHERE lower(email) = ...`) 타입이 맞지 않으면 인덱스를 쓸 수 없는데, 이때는 표현식 인덱스를 만들거나 타입을 맞춥니다.

### 통계가 오래되면

autovacuum이 변경량에 따라 자동으로 `ANALYZE`를 돌리지만([5편](/posts/postgresql/05-vacuum/)), 그 사이에 데이터 분포가 크게 바뀌면 통계는 옛 모습 그대로입니다.

#### 분포가 바뀐 뒤의 추정

autovacuum이 끼어들지 않게 이 테이블만 끄고, 주문 1만 건의 상태를 `returned`로 바꾼 뒤 바로 조회합니다.

```psql
postgres=# ALTER TABLE orders SET (autovacuum_enabled = off);
postgres=# UPDATE orders SET status = 'returned' WHERE id % 10 = 0;
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned';
                                        QUERY PLAN                                         
-------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2266.89 rows=136 width=30) (actual rows=10100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 89900
 Planning Time: 0.145 ms
 Execution Time: 3.653 ms
(5 rows)

postgres=# ANALYZE orders;
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned';
                                         QUERY PLAN                                          
---------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2138.00 rows=10140 width=29) (actual rows=10100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 89900
 Planning Time: 0.127 ms
 Execution Time: 2.658 ms
(5 rows)
```

- `ANALYZE` 전: 추정 **136행**, 실제 **10100행**으로 약 74배 차이입니다. 통계의 MCV는 여전히 "`returned`는 약 0.12%(0.0012333334)"라고 말하고 있기 때문입니다. 플래너는 UPDATE로 늘어난 페이지 수에 예전 밀도(페이지당 행 수)를 곱해 행 수를 약 11만으로 봤습니다(0.0012333334 × 약 110300 ≈ 136, 비용도 2055에서 2266.89로 늘었습니다). 실제로 살아 있는 행은 10만 그대로이고, 늘어난 페이지는 UPDATE가 남긴 옛 버전([4편](/posts/postgresql/04-mvcc/)) 때문입니다. 어느 쪽이든 값의 분포는 `ANALYZE` 때 그대로입니다.
- `ANALYZE` 뒤: 추정 **10140행**으로 실제와 거의 같아졌습니다.

이 쿼리는 어차피 Seq Scan이라 계획이 바뀌지 않았지만, 조인 안에서 이런 오차가 생기면 "136행이니 Nested Loop로 136번만 돌면 된다"는 계획이 실제로는 1만 번을 돌게 됩니다.

### 조건이 여러 개일 때

조건이 여러 개면 기본적으로 **서로 독립이라고 가정하고 곱합니다**([`clauselist_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/clausesel.c#L100)). 이 가정이 틀리는 경우를 위해 **확장 통계**(`CREATE STATISTICS`)가 있습니다.

#### 서로 관련된 컬럼: 확장 통계

```psql
postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR';
                                         QUERY PLAN                                         
--------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2388.00 rows=2032 width=29) (actual rows=10000.00 loops=1)
   Filter: ((city = 'Seoul'::text) AND (country = 'KR'::text))
   Rows Removed by Filter: 90000
 Planning Time: 0.141 ms
 Execution Time: 3.725 ms
(5 rows)

postgres=# CREATE STATISTICS orders_city_country (dependencies) ON city, country FROM orders;
postgres=# ANALYZE orders;
postgres=# SELECT statistics_name, dependencies FROM pg_stats_ext WHERE statistics_name = 'orders_city_country';
   statistics_name   |     dependencies     
---------------------+----------------------
 orders_city_country | {"5 => 6": 1.000000}
(1 row)

postgres=# EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR';
                                         QUERY PLAN                                          
---------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2388.00 rows=10090 width=29) (actual rows=10000.00 loops=1)
   Filter: ((city = 'Seoul'::text) AND (country = 'KR'::text))
   Rows Removed by Filter: 90000
 Planning Time: 0.105 ms
 Execution Time: 3.537 ms
(5 rows)
```

- 확장 통계 전: 추정 **2032행**, 실제 **10000행**입니다. 플래너는 `city = 'Seoul'`(10%)과 `country = 'KR'`(20%)이 독립이라고 보고 10% × 20% = 2%를 곱했습니다. 하지만 Seoul이면 반드시 KR이므로 실제는 10%입니다.
- `CREATE STATISTICS ... (dependencies)`와 `ANALYZE` 뒤, `pg_stats_ext`에 `"5 => 6": 1.000000`이 생겼습니다. 5번 컬럼(`city`)이 정해지면 6번 컬럼(`country`)이 100% 정해진다는 뜻입니다([`dependencies_clauselist_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/statistics/dependencies.c#L1370)).
- 추정이 **10090행**으로 실제와 거의 같아졌습니다.

확장 통계는 자동으로 만들어지지 않습니다. 주소(시, 구), 상품(카테고리, 하위 카테고리)처럼 함께 조건에 쓰이면서 서로 관련된 컬럼이 있다면 직접 만들어 줘야 합니다. `dependencies` 말고도 컬럼 조합의 서로 다른 값 수(`ndistinct`), 조합별 MCV(`mcv`)를 만들 수 있습니다.

#### 운영에서는: 추정 행 수와 실제 행 수가 크게 다를 때

느린 쿼리를 볼 때는 먼저 `EXPLAIN (ANALYZE)`에서 노드마다 `rows=`(추정)와 `actual rows=`(실제)를 비교합니다. 몇 배 이상 차이 나는 노드가 있다면, 그 위의 계획은 잘못된 전제 위에 세워졌을 가능성이 큽니다. 예를 들어 [앞의 예](#분포가-바뀐-뒤의-추정)처럼 136행으로 추정한 곳이 실제로 1만 행이면, 플래너는 1만 번 반복될 Nested Loop를 싸다고 판단할 수 있습니다. 원인은 대개 셋 중 하나입니다.

- **통계가 오래됨**: 대량 적재나 일괄 UPDATE 직후. `ANALYZE`로 해결됩니다. 배치 작업 끝에 `ANALYZE`를 넣어 두는 것이 좋습니다.
- **표본이 작음**: 값이 아주 많거나 분포가 복잡한 컬럼. `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 1000`으로 그 컬럼의 MCV와 히스토그램 크기를 늘릴 수 있습니다. 표본 크기는 테이블 단위로 가장 큰 값을 따르므로, 그 테이블의 `ANALYZE` 표본도 300 × 1000 = 30만 행으로 커집니다.
- **컬럼 사이의 관계**: 위 실습처럼 독립 가정이 틀린 경우. `CREATE STATISTICS`로 해결합니다.

## 정리

- SQL은 **파서**(문법) → **분석기**(이름을 실제 객체로) → **리라이터**(뷰 펼치기) → **플래너**(가장 싼 계획) → **실행기**(행을 한 개씩 당기기)를 거칩니다.
- 플래너는 스캔 방법, 조인 순서와 방식의 후보마다 **비용**을 계산해 가장 싼 것을 고릅니다. 비용은 페이지 읽기와 행 처리 횟수로 계산하는 상대값입니다.
- 비용 계산의 핵심 입력은 **추정 행 수**이고, `pg_class`의 테이블 통계와 `pg_stats`의 컬럼 통계(MCV, 히스토그램)로 추정합니다. 통계는 `ANALYZE`가 표본으로 만듭니다.
- 조건이 여러 개면 독립이라고 가정하고 선택도를 곱합니다. 컬럼 사이에 관계가 있으면 **확장 통계**로 알려 줘야 합니다.
- 느린 쿼리를 보면 `EXPLAIN (ANALYZE)`에서 추정과 실제 행 수의 차이부터 찾습니다.

이것으로 PostgreSQL 인터널 시리즈를 마칩니다. 프로세스와 메모리에서 시작해, 데이터가 페이지에 저장되고([3편](/posts/postgresql/03-storage-layout/)), 여러 버전으로 동시에 읽히고([4편](/posts/postgresql/04-mvcc/)), 정리되고([5편](/posts/postgresql/05-vacuum/), [6편](/posts/postgresql/06-xid-wraparound/)), WAL로 지켜지고([7편](/posts/postgresql/07-wal/), [8편](/posts/postgresql/08-checkpoint-and-recovery/)), 다른 서버로 복제되고([9편](/posts/postgresql/09-streaming-replication/)), 마지막으로 쿼리로 꺼내지는(10편) 과정을 소스 코드와 실제 실행 결과로 따라가 봤습니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/tcop/postgres.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c): `exec_simple_query()`
- [src/backend/parser/](https://github.com/postgres/postgres/tree/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser): 파서, 분석기
- [src/backend/rewrite/rewriteHandler.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/rewrite/rewriteHandler.c): 리라이터
- [src/backend/optimizer/README](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/README): 플래너 설계 설명
- [src/backend/optimizer/path/costsize.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/costsize.c): 비용 계산
- [src/backend/utils/adt/selfuncs.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c): 선택도 추정
- [src/backend/commands/analyze.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/analyze.c): `ANALYZE`

PostgreSQL 18 공식 문서

- [The Path of a Query](https://www.postgresql.org/docs/18/query-path.html)
- [Using EXPLAIN](https://www.postgresql.org/docs/18/using-explain.html)
- [Statistics Used by the Planner](https://www.postgresql.org/docs/18/planner-stats.html), [Row Estimation Examples](https://www.postgresql.org/docs/18/row-estimation-examples.html)
- [Planner Cost Constants](https://www.postgresql.org/docs/18/runtime-config-query.html#RUNTIME-CONFIG-QUERY-CONSTANTS)
- [pg_stats](https://www.postgresql.org/docs/18/view-pg-stats.html)
