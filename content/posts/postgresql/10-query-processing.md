---
title: "PostgreSQL 인터널 10: 쿼리 처리 과정"
date: 2026-09-24
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "쿼리", "플래너", "통계", "EXPLAIN"]
weight: 10
summary: "SQL 한 줄이 결과가 되기까지: 파서, 플래너, 실행기와 통계 정보"
description: "파서, 분석기, 리라이터, 플래너, 실행기와 통계 정보"
---

## 개요

지금까지는 데이터가 **어떻게 저장되고 지켜지는지**를 봤습니다. 마지막 편에서는 반대 방향, 사용자가 보낸 SQL 한 줄이 **어떻게 결과가 되는지**를 봅니다.

SQL은 "무엇을 원하는지"만 말하고 "어떻게 가져올지"는 말하지 않습니다. `WHERE amount < 30`을 만족하는 행을 찾으려면 테이블을 처음부터 끝까지 읽을 수도 있고, 인덱스를 쓸 수도 있습니다. 어느 쪽이 빠른지는 데이터에 따라 다르고, 그것을 정하는 것이 **플래너**입니다. 플래너가 판단 근거로 쓰는 것이 **통계 정보**이고, 통계가 틀리면 계획도 틀립니다. 운영 중 "어제까지 빠르던 쿼리가 갑자기 느려졌다"의 상당수가 여기서 나옵니다.

이 글에서 답할 질문은 다음과 같습니다.

- SQL은 어떤 단계를 거쳐 실행되는가
- 플래너는 여러 실행 방법 중 하나를 어떻게 고르는가
- 통계 정보에는 무엇이 들어 있고, 행 수는 어떻게 추정되는가
- 추정이 틀리는 대표적인 경우와 고치는 방법은 무엇인가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 다섯 단계

클라이언트가 보낸 SQL 문자열은 backend([1편](/posts/postgresql/01-process-architecture/)) 안에서 다섯 단계를 거칩니다. 전체 흐름은 [`exec_simple_query()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1012)에 그대로 드러나 있습니다.

{{< diagram src="/diagrams/pg-query-path.html" title="SQL 한 줄이 결과가 되기까지" height="600" caption="문자열이 파스 트리, Query 트리, 계획 트리로 바뀌고, 실행기가 계획 트리를 돌며 결과 행을 만듭니다." >}}

1. **파서(parser)**: 문자열을 문법 규칙([`gram.y`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/gram.y))에 맞춰 **파스 트리**로 바꿉니다([`raw_parser()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/parser.c#L42), [`postgres.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1065)의 `pg_parse_query()`를 거쳐 불립니다). 이 단계는 문법만 보고 카탈로그는 보지 않습니다. `orders`라는 테이블이 정말 있는지는 아직 모릅니다.
2. **분석기(analyzer)**: 시스템 카탈로그를 보며 이름을 실제 객체로 바꿉니다. `orders`가 어떤 OID의 테이블인지, `amount`가 몇 번째 컬럼이고 타입이 무엇인지, `<`가 어떤 연산자 함수인지 정해서 **Query 트리**를 만듭니다([`transformStmt()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/parser/analyze.c#L312)). 없는 테이블이나 컬럼은 여기서 오류가 납니다(실습 2).
3. **리라이터(rewriter)**: 규칙(rule)을 적용합니다. 가장 흔한 것은 **뷰**입니다. 뷰는 "이 이름을 이 SELECT로 바꿔라"는 규칙으로 저장되어 있어, 리라이터가 뷰 이름을 그 정의(SELECT)의 서브쿼리로 바꿉니다([`QueryRewrite()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/rewrite/rewriteHandler.c#L4635), [`ApplyRetrieveRule()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/rewrite/rewriteHandler.c#L1746)). 플래너는 이 서브쿼리를 바깥 쿼리로 끌어올려(pull-up) 합치므로, 결국 뷰가 아니라 원래 테이블을 보고 계획을 세웁니다(실습 4). 2번과 3번은 [`pg_analyze_and_rewrite_fixedparams()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L1190)에서 함께 불립니다.
4. **플래너(planner)**: Query 트리를 실행할 수 있는 여러 방법(**경로, path**)을 만들고, 통계로 비용을 추정해 가장 싼 것을 **계획 트리**로 만듭니다([`planner()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/plan/planner.c#L310), [`create_plan()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/plan/createplan.c#L337)). `EXPLAIN`이 보여 주는 것이 이 계획 트리입니다.
5. **실행기(executor)**: 계획 트리를 실행합니다([`standard_ExecutorRun()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/execMain.c#L307)). 맨 위 노드에게 "행 하나 줘"라고 요청하면, 그 노드가 자기 아래 노드에게 다시 요청하는 식으로 행이 한 개씩 위로 올라옵니다([`ExecProcNode()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/executor/executor.h#L310)). 위에서 더 필요 없다고 하면 아래 노드도 거기서 멈춥니다(실습 10). 다만 정렬(Sort), 해시(Hash), 해시 집계(HashAggregate) 노드는 첫 행을 내기 전에 아래 입력을 모두 읽어야 하고, Bitmap Index Scan은 행 대신 비트맵을 통째로 넘깁니다. `EXPLAIN`의 비용 앞쪽 숫자(startup cost)가 이렇게 첫 행을 내기까지의 비용입니다.

### 플래너: 경로를 만들고 비용을 비교한다

{{< diagram src="/diagrams/pg-planner-estimate.html" title="플래너가 스캔 방법 하나를 고르는 과정" height="600" caption="조건의 선택도를 컬럼 통계로 추정하고 튜플 수를 곱해 행 수를 구한 뒤, 경로 후보마다 비용을 계산해 가장 싼 것을 고릅니다." >}}

테이블 하나를 읽는 방법만 해도 여러 가지입니다([`set_plain_rel_pathlist()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/allpaths.c#L772)).

| 스캔 | 방법 | 유리할 때 |
|---|---|---|
| Seq Scan | 테이블 전체를 처음부터 순서대로 읽음 | 많은 행을 가져올 때 |
| Index Scan | 인덱스에서 찾은 순서대로 테이블 페이지를 하나씩 읽음 | 아주 적은 행, 또는 인덱스 순서와 테이블 순서가 비슷할 때 |
| Bitmap Scan | 인덱스로 해당 페이지 목록(비트맵)을 먼저 만들고, 페이지 순서대로 읽음 | 그 중간, 또는 여러 인덱스를 AND/OR로 합칠 때(실습 4) |
| Index Only Scan | 인덱스만 읽고 테이블은 건너뜀(visibility map이 all-visible인 페이지, [5편](/posts/postgresql/05-vacuum/)) | 필요한 컬럼이 모두 인덱스에 있을 때 |

플래너는 경로마다 **비용(cost)**을 계산합니다. 비용의 단위는 "페이지 하나를 순차로 읽는 비용 = 1"(`seq_page_cost`)이고, 나머지는 그에 대한 상대값입니다.

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `seq_page_cost` | 1 | 페이지 하나를 순차로 읽기 |
| `random_page_cost` | 4 | 페이지 하나를 임의 위치에서 읽기 |
| `cpu_tuple_cost` | 0.01 | 행 하나를 처리하기 |
| `cpu_operator_cost` | 0.0025 | 연산자(비교 등) 하나를 계산하기 |

예를 들어 Seq Scan의 비용은 `페이지 수 × seq_page_cost + 행 수 × (cpu_tuple_cost + 조건마다 cpu_operator_cost)`입니다(정확히는 조건마다 연산자 함수의 비용 계수 × `cpu_operator_cost`이고, `=`, `<` 같은 기본 연산자는 계수가 1, [`cost_seqscan()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/costsize.c#L323-L330)). 실습 6에서 이 식으로 계산한 값이 `EXPLAIN`의 숫자와 정확히 맞는 것을 확인합니다.

테이블이 둘 이상이면 **조인 순서**와 **조인 방식**도 골라야 합니다.

| 조인 | 방법 | 유리할 때 |
|---|---|---|
| Nested Loop | 바깥 행 하나마다 안쪽을 찾음(보통 인덱스로) | 바깥 행이 적을 때 |
| Hash Join | 작은 쪽으로 해시 테이블을 만들고 큰 쪽을 훑으며 찾음 | 큰 테이블끼리, 해시할 쪽이 `work_mem`에 들어갈 때 |
| Merge Join | 양쪽을 조인 키 순서로 정렬해 나란히 훑음 | 양쪽이 이미 정렬되어 있을 때 |

Hash Join과 Merge Join은 등호(`=`) 조인에서만 쓸 수 있고, `a.x < b.y` 같은 조인은 Nested Loop만 가능합니다.

### 통계 정보: 행 수 추정의 근거

비용 계산에서 가장 중요한 입력은 "이 조건을 만족하는 행이 몇 개인가"입니다. 1개라면 인덱스가, 절반이라면 Seq Scan이 낫습니다. 플래너는 이것을 두 가지 통계로 추정합니다.

- **테이블 통계** (`pg_class`): 페이지 수 `relpages`, 행 수 `reltuples`. 계획할 때는 지금 실제 페이지 수를 보고, `reltuples / relpages`(페이지당 행 밀도)에 그 페이지 수를 곱해 행 수를 추정합니다([`tableam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/table/tableam.c#L711-L747)).
- **컬럼 통계** (`pg_statistic`, 읽기 쉬운 뷰는 `pg_stats`): 컬럼마다 NULL 비율(`null_frac`), 서로 다른 값의 수(`n_distinct`), **가장 흔한 값과 그 비율(MCV, `most_common_vals`, `most_common_freqs`)**, 나머지 값의 분포를 같은 개수씩 나눈 **히스토그램(`histogram_bounds`)**, 물리적 순서와 값 순서의 상관관계(`correlation`)가 들어 있습니다.

`WHERE status = 'shipped'`처럼 같다 조건이면 MCV에서 그 값의 비율을 찾고([`var_eq_const()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c#L303)), `WHERE amount < 30`처럼 범위 조건이면 히스토그램의 몇 번째 구간까지인지로 비율을 구합니다([`ineq_histogram_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/adt/selfuncs.c#L1050)). 이 비율이 **선택도(selectivity)**이고, 행 수 추정은 `선택도 × 행 수`입니다. 조건이 여러 개면 기본적으로 **서로 독립이라고 가정하고 곱합니다**([`clauselist_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/clausesel.c#L100)). 이 가정이 틀리는 경우를 위해 **확장 통계**(`CREATE STATISTICS`)가 있습니다(실습 12).

통계는 `ANALYZE`가 만듭니다. 테이블 전체가 아니라 **표본**을 읽습니다. 표본 크기는 `300 × default_statistics_target`(기본 100), 즉 30000행입니다([`analyze.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/analyze.c#L1940)). autovacuum이 변경량에 따라 자동으로 `ANALYZE`를 돌리지만([5편](/posts/postgresql/05-vacuum/)), 그 사이에 데이터 분포가 크게 바뀌면 통계는 옛 모습 그대로입니다(실습 11).

## 직접 확인해 보기

### 실습 환경

[실습 이미지](/labs/pg-lab-image/Dockerfile)로 [lab.sh](/labs/pg-10-query-processing/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-10-query-processing/final-run.log)에 있습니다.

고객 1000명과 주문 10만 건을 만듭니다. 주문 상태(`status`)는 일부러 치우치게 했고(`delivered` 80%, `shipped` 15%, `cancelled` 4.9%, `returned` 0.1%), 금액(`amount`)은 0~999에 고르게 퍼지되 행의 물리적 순서와는 무관하게 흩어 놓았습니다. 도시(`city`)와 나라(`country`)는 도시가 정해지면 나라가 정해지는 관계입니다.

```bash
docker run -d --init --name pglab10 --hostname pglab10 pg-internals:rel18-lab sleep infinity
```

```text
7a738452e35a029c815ce441f26d8e8729333d02955590d4cbad6ca5e5ccf293
[exit=0]
```

```bash
postgres --version
initdb -D $PGDATA  > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
```

```text
postgres (PostgreSQL) 18.6
initdb ok
[exit=0]
```

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q <<'SQL'
CREATE TABLE customers (id int PRIMARY KEY, name text);
INSERT INTO customers SELECT g, 'customer ' || g FROM generate_series(1, 1000) g;
CREATE TABLE orders (
  id int PRIMARY KEY, customer_id int, status text, amount int, city text, country text);
INSERT INTO orders
SELECT g, g % 1000 + 1,
       CASE WHEN g % 1000 < 800 THEN 'delivered' WHEN g % 1000 < 950 THEN 'shipped'
            WHEN g % 1000 < 999 THEN 'cancelled' ELSE 'returned' END,
       (g * 7919) % 1000,
       (ARRAY['Seoul','Busan','Tokyo','Osaka','Paris','Lyon','Berlin','Munich','Rome','Milan'])[g % 10 + 1],
       (ARRAY['KR','KR','JP','JP','FR','FR','DE','DE','IT','IT'])[g % 10 + 1]
FROM generate_series(1, 100000) g;
CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_amount_idx ON orders (amount);
ANALYZE;
SQL
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. 단계마다 걸린 시간

`log_parser_stats`, `log_planner_stats`, `log_executor_stats`를 켜면 단계마다 걸린 시간이 로그로 나옵니다. `client_min_messages = log`로 두어 psql 화면에서 바로 봅니다.

```bash
PGOPTIONS="-c client_min_messages=log -c log_parser_stats=on -c log_planner_stats=on -c log_executor_stats=on" \
  psql -X -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -E "^LOG:|elapsed|^ +status +\||^-+\+|^ [a-z]+ +\|"
```

```text
LOG:  PARSER STATISTICS
!	0.000028 s user, 0.000000 s system, 0.000028 s elapsed
LOG:  PARSE ANALYSIS STATISTICS
!	0.000239 s user, 0.000000 s system, 0.000239 s elapsed
LOG:  REWRITER STATISTICS
!	0.000005 s user, 0.000000 s system, 0.000005 s elapsed
LOG:  PLANNER STATISTICS
!	0.000200 s user, 0.000000 s system, 0.000200 s elapsed
LOG:  EXECUTOR STATISTICS
!	0.001856 s user, 0.000000 s system, 0.001856 s elapsed
  status   | count 
-----------+-------
 returned  |   100
 cancelled |   400
 shipped   |  1400
 delivered |  8100
[exit=0]
```

`PARSER` → `PARSE ANALYSIS` → `REWRITER` → `PLANNER` → `EXECUTOR` 순서로, 위에서 본 다섯 단계가 그대로 나옵니다. 이 쿼리에서는 파싱이 0.000028초, 분석이 0.000239초, 계획이 0.000200초였고, 실제로 행을 읽고 집계한 실행이 0.001856초로 가장 깁니다. 분석이 계획만큼 걸린 것은 새 연결의 첫 쿼리라 카탈로그 캐시를 채우는 시간이 들어갔기 때문입니다. 쿼리가 복잡해지면(조인이 많으면) 계획 시간도 크게 늘어납니다.

### 실습 2. 오류가 나는 단계로 보는 파서와 분석기의 차이

```bash
psql -X -c "SELEC * FROM orders"
psql -X -c "SELECT * FROM order_typo"
psql -X -c "SELECT nosuchcol FROM orders"
```

```text
ERROR:  syntax error at or near "SELEC"
LINE 1: SELEC * FROM orders
        ^
ERROR:  relation "order_typo" does not exist
LINE 1: SELECT * FROM order_typo
                      ^
ERROR:  column "nosuchcol" does not exist
LINE 1: SELECT nosuchcol FROM orders
               ^
[exit=1]
```

- `SELEC`는 문법에 맞지 않으므로 **파서**가 `syntax error`를 냅니다.
- `SELECT * FROM order_typo`는 문법은 맞습니다. 파서는 통과하고, 카탈로그에서 이름을 찾는 **분석기**가 `relation ... does not exist`를 냅니다. 없는 컬럼도 마찬가지입니다.

### 실습 3. 내부 트리: Query와 PlannedStmt

`debug_print_rewritten`, `debug_print_plan`을 켜면 리라이터를 거친 Query 트리와 계획 트리 전체가 출력됩니다. 매우 길어서, 트리에 나오는 노드 이름만 처음 나온 순서대로 뽑았습니다.

```bash
psql -X -c "SET client_min_messages = log" -c "SET debug_print_rewritten = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
psql -X -c "SET client_min_messages = log" -c "SET debug_print_plan = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
```

```text
{QUERY {RANGETBLENTRY {ALIAS {VAR {RTEPERMISSIONINFO {FROMEXPR {RANGETBLREF {OPEXPR {CONST {TARGETENTRY {AGGREF {SORTGROUPCLAUSE 
{PLANNEDSTMT {AGG {TARGETENTRY {VAR {AGGREF {BITMAPHEAPSCAN {BITMAPINDEXSCAN {OPEXPR {CONST {RANGETBLENTRY {ALIAS {RTEPERMISSIONINFO 
[exit=0]
```

- **Query 트리**(첫 줄)에는 SQL의 구성 요소가 그대로 들어 있습니다. `RANGETBLENTRY`는 FROM의 `orders`(그리고 PG18부터 생긴 GROUP BY용 항목), `VAR`는 컬럼 참조, `OPEXPR`과 `CONST`는 `amount < 100`, `TARGETENTRY`와 `AGGREF`는 SELECT 목록의 `count(*)`, `SORTGROUPCLAUSE`는 GROUP BY입니다. "어떻게"에 대한 정보는 아직 없습니다.
- **계획 트리**(둘째 줄)는 `PLANNEDSTMT` 아래에 `AGG`(집계), `BITMAPHEAPSCAN`, `BITMAPINDEXSCAN`(읽는 방법)이 있습니다. 플래너가 "`amount` 인덱스로 비트맵을 만들어 읽고 집계한다"는 방법을 정한 것입니다. `EXPLAIN`은 이 트리를 사람이 읽기 좋게 보여 주는 명령입니다.

### 실습 4. 리라이터: 뷰는 원래 테이블로 풀린다

```bash
psql -X -q -c "CREATE VIEW big_orders AS SELECT id, customer_id, amount FROM orders WHERE amount >= 990"
psql -X -c "EXPLAIN (COSTS OFF) SELECT * FROM big_orders WHERE customer_id = 7"
```

```text
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

[exit=0]
```

뷰 `big_orders`를 조회했는데 계획에는 뷰가 없고 `orders`만 나옵니다. 리라이터가 뷰를 그 정의의 서브쿼리로 바꾸고, 플래너가 그 서브쿼리를 바깥 쿼리로 끌어올려, 뷰 안의 조건(`amount >= 990`)과 바깥 조건(`customer_id = 7`)이 한 쿼리가 되었습니다. 플래너는 두 조건을 합쳐, 두 인덱스의 비트맵을 AND(`BitmapAnd`)해서 읽는 계획을 세웠습니다.

### 실습 5. 통계 정보: pg_stats

```bash
psql -X -x -c "SELECT attname, null_frac, n_distinct, most_common_vals, most_common_freqs, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'status'"
psql -X -x -c "SELECT attname, n_distinct, array_length(most_common_vals::text::int[], 1) AS mcv_count, (SELECT sum(f) FROM unnest(most_common_freqs) f) AS mcv_total_freq, array_length(histogram_bounds, 1) AS histogram_len, (histogram_bounds::text::int[])[1:6] AS histogram_head, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'amount'"
psql -X -c "SELECT relname, relpages, reltuples FROM pg_class WHERE relname IN ('orders', 'customers') ORDER BY relname"
```

```text
-[ RECORD 1 ]-----+---------------------------------------
attname           | status
null_frac         | 0
n_distinct        | 4
most_common_vals  | {delivered,shipped,cancelled,returned}
most_common_freqs | {0.7984667,0.1502,0.050333332,0.001}
correlation       | 0.66393787

-[ RECORD 1 ]--+-------------------
attname        | amount
n_distinct     | 1000
mcv_count      | 3
mcv_total_freq | 0.0043
histogram_len  | 101
histogram_head | {0,10,20,31,41,50}
correlation    | 0.0046508736

  relname  | relpages | reltuples 
-----------+----------+-----------
 customers |        7 |      1000
 orders    |      805 |    100000
(2 rows)

[exit=0]
```

- `status`: 서로 다른 값이 4개(`n_distinct`)라 네 값이 모두 MCV에 들어 있고, 비율이 `0.7984667, 0.1502, 0.050333332, 0.001`입니다. 실제 비율(0.8, 0.15, 0.049, 0.001)과 조금씩 다른 것은 3만 행 표본으로 셌기 때문입니다. 비율은 표본에서 센 개수를 표본 크기로 나눈 값이라, `returned`의 0.001은 표본 30000행 중 30행이었다는 뜻입니다. 표본은 매번 무작위로 뽑으므로 `ANALYZE`를 다시 하면 이 값들도 조금씩 달라집니다.
- `amount`: 서로 다른 값이 1000개이고 실제로는 모두 같은 비율(0.1%)이지만, 표본에서 우연히 조금 더 많이 나온 값 3개가 MCV로 남았습니다(`mcv_count`, 합계 비율 0.0043). ANALYZE는 표본 빈도가 평균보다 뚜렷하게 높은 값만 MCV로 남깁니다. 나머지 값의 분포는 히스토그램 경계값 101개(`histogram_len`)로 나타내고, 경계값 사이 100개 구간에는 MCV를 뺀 나머지 행이 같은 비율(1%)씩 들어갑니다. `correlation`이 0에 가까운 것은 `amount` 값의 순서와 행이 저장된 물리적 순서가 무관하다는 뜻입니다.
- 테이블 통계는 `orders`가 805페이지, 100000행입니다.

### 실습 6. 비용 모델: Seq Scan의 비용을 직접 계산해 보기

```bash
psql -X -c "SHOW seq_page_cost" -c "SHOW random_page_cost" -c "SHOW cpu_tuple_cost" -c "SHOW cpu_operator_cost"
psql -X -c "EXPLAIN SELECT * FROM orders"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE status = 'returned'"
psql -X -c "SELECT relpages * 1.0 + reltuples * 0.01 AS seqscan_cost, relpages * 1.0 + reltuples * 0.01 + reltuples * 0.0025 AS with_filter_cost FROM pg_class WHERE relname = 'orders'"
```

```text
 seq_page_cost 
---------------
 1
(1 row)

 random_page_cost 
------------------
 4
(1 row)

 cpu_tuple_cost 
----------------
 0.01
(1 row)

 cpu_operator_cost 
-------------------
 0.0025
(1 row)

                          QUERY PLAN                           
---------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1805.00 rows=100000 width=30)
(1 row)

                         QUERY PLAN                         
------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=100 width=30)
   Filter: (status = 'returned'::text)
(2 rows)

 seqscan_cost | with_filter_cost 
--------------+------------------
         1805 |             2055
(1 row)

[exit=0]
```

`EXPLAIN`의 `cost=0.00..1805.00`에서 앞의 숫자는 첫 행을 내기까지의 비용, 뒤의 숫자는 마지막 행까지의 총비용입니다. 계산해 보면,

- 조건 없음: 805페이지 × 1(`seq_page_cost`) + 100000행 × 0.01(`cpu_tuple_cost`) = **1805**
- 조건 하나: 여기에 100000행 × 0.0025(`cpu_operator_cost`, `status = 'returned'` 비교 한 번) = **2055**

마지막 쿼리로 계산한 값이 `EXPLAIN`과 정확히 같습니다. `ANALYZE` 직후라 `pg_class`의 값과 지금 테이블 크기가 같기 때문입니다(달라지는 경우는 실습 11). 비용은 이렇게 "몇 페이지를 읽고, 몇 행을 처리하는가"를 설정값으로 곱해 더한 것입니다. 조건이 붙어도 Seq Scan은 전체 행을 읽고 비교해야 하므로 총비용이 오히려 늘어납니다. 반면 `rows=`는 100000에서 100으로 줄었는데, 이것이 다음 실습의 행 수 추정입니다.

### 실습 7. 추정과 실제: MCV와 히스토그램

`EXPLAIN (ANALYZE)`는 실제로 실행해서 `rows=`(추정) 옆에 `actual rows=`(실제)를 보여 줍니다. PG18은 `EXPLAIN ANALYZE`에 `BUFFERS`가 기본으로 붙는데([2편](/posts/postgresql/02-memory-architecture/)), 여기서는 출력을 짧게 하려고 `BUFFERS OFF`, `TIMING OFF`를 붙였습니다.

```bash
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'shipped'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE amount < 30"
```

```text
                                         QUERY PLAN                                          
---------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=15020 width=30) (actual rows=15000.00 loops=1)
   Filter: (status = 'shipped'::text)
   Rows Removed by Filter: 85000
 Planning Time: 0.142 ms
 Execution Time: 3.255 ms
(5 rows)

                                       QUERY PLAN                                        
-----------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=100 width=30) (actual rows=100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 99900
 Planning Time: 0.126 ms
 Execution Time: 2.829 ms
(5 rows)

                                                    QUERY PLAN                                                    
------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on orders  (cost=35.08..876.83 rows=2940 width=30) (actual rows=3000.00 loops=1)
   Recheck Cond: (amount < 30)
   Heap Blocks: exact=805
   ->  Bitmap Index Scan on orders_amount_idx  (cost=0.00..34.34 rows=2940 width=0) (actual rows=3000.00 loops=1)
         Index Cond: (amount < 30)
         Index Searches: 1
 Planning Time: 0.131 ms
 Execution Time: 0.718 ms
(8 rows)

[exit=0]
```

| 조건 | 추정 근거 | 추정 | 실제 |
|---|---|---|---|
| `status = 'shipped'` | MCV 비율 0.1502 × 100000 | 15020 | 15000 |
| `status = 'returned'` | MCV 비율 0.001 × 100000 | 100 | 100 |
| `amount < 30` | 히스토그램에서 30이 들어가는 위치(약 3%, MCV 몫만큼 조금 줄어듦) | 2940 | 3000 |

추정은 통계 값을 그대로 곱한 것입니다. 표본 오차 때문에 조금씩 어긋나지만, 이 정도 차이는 계획을 바꾸지 않습니다. 문제가 되는 것은 몇 배, 몇십 배씩 틀릴 때입니다(실습 11, 12).

`amount < 30`은 Bitmap Heap Scan인데, `Heap Blocks: exact=805`로 테이블의 모든 페이지를 읽었습니다. `amount`가 물리적 순서와 무관하게 흩어져 있어(`correlation` 약 0) 3000행이 모든 페이지에 퍼져 있기 때문입니다. 모든 페이지를 읽을 것으로 보면 페이지 비용은 Seq Scan과 같은 `seq_page_cost`로 계산되고, 조건을 검사할 행이 3000개뿐이라 CPU 비용이 적습니다. 그래서 Seq Scan(2055)보다 싸다(876.83)고 계산했습니다.

### 실습 8. 선택도에 따라 스캔 방식이 바뀐다

```bash
psql -X -c "EXPLAIN SELECT * FROM orders WHERE id = 42"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE amount < 30"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE amount < 800"
```

```text
                                QUERY PLAN                                 
---------------------------------------------------------------------------
 Index Scan using orders_pkey on orders  (cost=0.29..8.31 rows=1 width=30)
   Index Cond: (id = 42)
(2 rows)

                                     QUERY PLAN                                     
------------------------------------------------------------------------------------
 Bitmap Heap Scan on orders  (cost=35.08..876.83 rows=2940 width=30)
   Recheck Cond: (amount < 30)
   ->  Bitmap Index Scan on orders_amount_idx  (cost=0.00..34.34 rows=2940 width=0)
         Index Cond: (amount < 30)
(4 rows)

                          QUERY PLAN                          
--------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2055.00 rows=79887 width=30)
   Filter: (amount < 800)
(2 rows)

[exit=0]
```

- `id = 42`: 1행으로 추정되어 **Index Scan**입니다. 인덱스에서 찾아 테이블 페이지 하나만 읽습니다(비용 8.31).
- `amount < 30`: 약 3000행이라 **Bitmap Scan**입니다.
- `amount < 800`: 약 8만 행이라 **Seq Scan**입니다. 테이블의 80%를 가져올 때는 인덱스를 거치는 것이 더 비쌉니다.

같은 테이블, 같은 인덱스라도 추정 행 수에 따라 계획이 달라집니다. 그래서 추정이 틀리면 계획도 틀립니다.

### 실습 9. 조인 방식

```bash
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, o.amount FROM customers c JOIN orders o ON o.customer_id = c.id WHERE c.id = 42"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name"
psql -X -c "SET enable_hashjoin = off" -c "SET enable_nestloop = off" -c "EXPLAIN (COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name"
```

```text
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
 Planning Time: 0.198 ms
 Execution Time: 0.326 ms
(12 rows)

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
 Planning Time: 0.278 ms
 Execution Time: 13.215 ms
(11 rows)

SET
SET
                          QUERY PLAN                          
--------------------------------------------------------------
 HashAggregate
   Group Key: c.name
   ->  Merge Join
         Merge Cond: (c.id = o.customer_id)
         ->  Index Scan using customers_pkey on customers c
         ->  Index Scan using orders_customer_idx on orders o
(6 rows)

[exit=0]
```

- 고객 한 명(`c.id = 42`)의 주문: 바깥쪽이 1행이라 **Nested Loop**입니다. 고객 1행마다(`loops=1`) 안쪽에서 인덱스로 주문을 찾습니다. 안쪽 조건이 `customer_id = 42`인 것은, 플래너가 `c.id = 42`와 `o.customer_id = c.id`에서 `o.customer_id = 42`를 스스로 끌어냈기 때문입니다.
- 모든 고객의 주문 합계: 10만 행 전체를 조인하므로 **Hash Join**입니다. 작은 `customers`(1000행)로 해시 테이블을 만들고(`Hash`, 59kB), `orders`를 한 번 훑으며 찾습니다.
- Hash Join과 Nested Loop를 끄면 **Merge Join**이 나옵니다. 두 인덱스(`customers_pkey`, `orders_customer_idx`)를 조인 키 순서로 읽어 나란히 맞춰 갑니다. 플래너가 처음에 이것을 고르지 않은 것은 이 경우 Hash Join보다 비싸다고 계산했기 때문입니다.

### 실습 10. 실행기는 필요한 만큼만 당겨 온다

```bash
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT * FROM orders LIMIT 5"
```

```text
                     QUERY PLAN                      
-----------------------------------------------------
 Limit (actual rows=5.00 loops=1)
   ->  Seq Scan on orders (actual rows=5.00 loops=1)
 Planning Time: 0.131 ms
 Execution Time: 0.012 ms
(4 rows)

[exit=0]
```

테이블은 10만 행이지만 `Seq Scan`의 `actual rows`가 5입니다. 실행기는 맨 위 `Limit` 노드가 아래 `Seq Scan`에게 행을 하나씩 달라고 하는 구조라, `Limit`이 5행을 받고 더 요청하지 않자 `Seq Scan`도 거기서 멈췄습니다([`ExecLimit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/nodeLimit.c#L40)).

### 실습 11. 통계가 오래되면: 분포가 바뀐 뒤의 추정

autovacuum이 끼어들지 않게 이 테이블만 끄고, 주문 1만 건의 상태를 `returned`로 바꾼 뒤 바로 조회합니다.

```bash
psql -X -q -c "ALTER TABLE orders SET (autovacuum_enabled = off)"
psql -X -q -c "UPDATE orders SET status = 'returned' WHERE id % 10 = 0"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
psql -X -q -c "ANALYZE orders"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
```

```text
                                        QUERY PLAN                                         
-------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2266.89 rows=110 width=30) (actual rows=10100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 89900
 Planning Time: 0.126 ms
 Execution Time: 3.744 ms
(5 rows)

                                         QUERY PLAN                                          
---------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2138.00 rows=10143 width=30) (actual rows=10100.00 loops=1)
   Filter: (status = 'returned'::text)
   Rows Removed by Filter: 89900
 Planning Time: 0.120 ms
 Execution Time: 2.631 ms
(5 rows)

[exit=0]
```

- `ANALYZE` 전: 추정 **110행**, 실제 **10100행**으로 약 92배 차이입니다. 통계의 MCV는 여전히 "`returned`는 0.1%"라고 말하고 있기 때문입니다. 플래너는 UPDATE로 늘어난 페이지 수에 예전 밀도(페이지당 행 수)를 곱해 행 수를 약 11만으로 봤습니다(비용도 2055에서 2266.89로 늘었습니다). 실제로 살아 있는 행은 10만 그대로이고, 늘어난 페이지는 UPDATE가 남긴 옛 버전([4편](/posts/postgresql/04-mvcc/)) 때문입니다. 어느 쪽이든 값의 분포는 `ANALYZE` 때 그대로입니다.
- `ANALYZE` 뒤: 추정 **10143행**으로 실제와 거의 같아졌습니다.

이 쿼리는 어차피 Seq Scan이라 계획이 바뀌지 않았지만, 조인 안에서 이런 오차가 생기면 "110행이니 Nested Loop로 110번만 돌면 된다"는 계획이 실제로는 1만 번을 돌게 됩니다.

### 실습 12. 서로 관련된 컬럼: 확장 통계

```bash
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR'"
psql -X -q -c "CREATE STATISTICS orders_city_country (dependencies) ON city, country FROM orders" -c "ANALYZE orders"
psql -X -c "SELECT statistics_name, dependencies FROM pg_stats_ext WHERE statistics_name = 'orders_city_country'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR'"
```

```text
                                         QUERY PLAN                                         
--------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2388.00 rows=2014 width=30) (actual rows=10000.00 loops=1)
   Filter: ((city = 'Seoul'::text) AND (country = 'KR'::text))
   Rows Removed by Filter: 90000
 Planning Time: 0.144 ms
 Execution Time: 3.971 ms
(5 rows)

   statistics_name   |     dependencies     
---------------------+----------------------
 orders_city_country | {"5 => 6": 1.000000}
(1 row)

                                         QUERY PLAN                                         
--------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..2388.00 rows=9950 width=29) (actual rows=10000.00 loops=1)
   Filter: ((city = 'Seoul'::text) AND (country = 'KR'::text))
   Rows Removed by Filter: 90000
 Planning Time: 0.140 ms
 Execution Time: 4.298 ms
(5 rows)

[exit=0]
```

- 확장 통계 전: 추정 **2014행**, 실제 **10000행**입니다. 플래너는 `city = 'Seoul'`(10%)과 `country = 'KR'`(20%)이 독립이라고 보고 10% × 20% = 2%를 곱했습니다. 하지만 Seoul이면 반드시 KR이므로 실제는 10%입니다.
- `CREATE STATISTICS ... (dependencies)`와 `ANALYZE` 뒤, `pg_stats_ext`에 `"5 => 6": 1.000000`이 생겼습니다. 5번 컬럼(`city`)이 정해지면 6번 컬럼(`country`)이 100% 정해진다는 뜻입니다([`dependencies_clauselist_selectivity()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/statistics/dependencies.c#L1370)).
- 추정이 **9950행**으로 실제와 거의 같아졌습니다.

확장 통계는 자동으로 만들어지지 않습니다. 주소(시, 구), 상품(카테고리, 하위 카테고리)처럼 함께 조건에 쓰이면서 서로 관련된 컬럼이 있다면 직접 만들어 줘야 합니다. `dependencies` 말고도 컬럼 조합의 서로 다른 값 수(`ndistinct`), 조합별 MCV(`mcv`)를 만들 수 있습니다.

## 운영에서는 이렇게 나타납니다

### 추정 행 수와 실제 행 수가 크게 다를 때

느린 쿼리를 볼 때는 먼저 `EXPLAIN (ANALYZE)`에서 노드마다 `rows=`(추정)와 `actual rows=`(실제)를 비교합니다. 몇 배 이상 차이 나는 노드가 있다면, 그 위의 계획은 잘못된 전제 위에 세워졌을 가능성이 큽니다. 예를 들어 실습 11처럼 110행으로 추정한 곳이 실제로 1만 행이면, 플래너는 1만 번 반복될 Nested Loop를 싸다고 판단할 수 있습니다. 원인은 대개 셋 중 하나입니다.

- **통계가 오래됨**: 대량 적재나 일괄 UPDATE 직후. `ANALYZE`로 해결됩니다. 배치 작업 끝에 `ANALYZE`를 넣어 두는 것이 좋습니다.
- **표본이 작음**: 값이 아주 많거나 분포가 복잡한 컬럼. `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 1000`으로 그 컬럼의 MCV와 히스토그램 크기를 늘릴 수 있습니다. 표본 크기는 테이블 단위로 가장 큰 값을 따르므로, 그 테이블의 `ANALYZE` 표본도 300 × 1000 = 30만 행으로 커집니다.
- **컬럼 사이의 관계**: 실습 12처럼 독립 가정이 틀린 경우. `CREATE STATISTICS`로 해결합니다.

### 인덱스가 있는데 사용되지 않는다

실습 8처럼 조건이 테이블의 상당 부분을 가져오면 Seq Scan이 실제로 더 빠르고, 플래너는 그것을 고릅니다. 인덱스를 쓰지 않는 것이 이상하다면, 먼저 추정 행 수가 맞는지 봅니다. 추정이 맞는데도 Seq Scan이라면 대부분 올바른 선택입니다. SSD처럼 임의 읽기가 빠른 저장 장치에서는 `random_page_cost`를 기본값 4보다 낮추는(예: 1.1) 경우가 많습니다. 이 밖에 컬럼에 함수를 씌우거나(`WHERE lower(email) = ...`) 타입이 맞지 않으면 인덱스를 쓸 수 없는데, 이때는 표현식 인덱스를 만들거나 타입을 맞춥니다.

### enable_* 설정은 진단용이다

`enable_hashjoin = off` 같은 설정(실습 9)은 "그 방법을 절대 쓰지 말라"가 아닙니다. PG18의 플래너는 경로마다 꺼진 방법을 쓴 노드 수(`disabled_nodes`)를 세어, 그 수가 적은 계획을 먼저 고르고 그다음에 비용을 비교합니다([`costsize.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/optimizer/path/costsize.c#L357)). 다른 방법이 없으면 여전히 쓰이고, 이때 `EXPLAIN`에 `Disabled: true`가 표시됩니다. 다른 계획이 실제로 더 빠른지 확인하는 진단 도구로는 좋지만, 운영 설정으로 전역에 두면 데이터가 바뀌었을 때 더 나은 계획을 막습니다. 근본 원인인 추정 오류를 고치는 편이 낫습니다.

## 정리

- SQL은 **파서**(문법) → **분석기**(이름을 실제 객체로) → **리라이터**(뷰 펼치기) → **플래너**(가장 싼 계획) → **실행기**(행을 한 개씩 당기기)를 거칩니다.
- 플래너는 스캔 방법, 조인 순서와 방식의 후보마다 **비용**을 계산해 가장 싼 것을 고릅니다. 비용은 페이지 읽기와 행 처리 횟수로 계산하는 상대값입니다.
- 비용 계산의 핵심 입력은 **추정 행 수**이고, `pg_class`의 테이블 통계와 `pg_stats`의 컬럼 통계(MCV, 히스토그램)로 추정합니다. 통계는 `ANALYZE`가 표본으로 만듭니다.
- 조건이 여러 개면 독립이라고 가정하고 선택도를 곱합니다. 컬럼 사이에 관계가 있으면 **확장 통계**로 알려 줘야 합니다.
- 느린 쿼리를 보면 `EXPLAIN (ANALYZE)`에서 추정과 실제 행 수의 차이부터 찾습니다.

이것으로 PostgreSQL 인터널 시리즈를 마칩니다. 프로세스와 메모리에서 시작해, 데이터가 페이지에 저장되고(3편), 여러 버전으로 동시에 읽히고(4편), 정리되고(5편, 6편), WAL로 지켜지고(7편, 8편), 다른 서버로 복제되고(9편), 마지막으로 쿼리로 꺼내지는(10편) 과정을 소스 코드와 실제 실행 결과로 따라가 봤습니다.

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

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-10-query-processing/lab.sh), [final-run.log](/labs/pg-10-query-processing/final-run.log)
