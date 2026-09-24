#!/bin/bash
# PostgreSQL 인터널 10편(쿼리 처리 과정과 통계 정보) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
CT=pglab10
source ../common/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
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
EOF

step "1. 단계마다 걸린 시간: 파서, 분석, 리라이터, 플래너, 실행기"
pg <<'EOF'
PGOPTIONS="-c client_min_messages=log -c log_parser_stats=on -c log_planner_stats=on -c log_executor_stats=on" \
  psql -X -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -E "^LOG:|elapsed|^ +status +\||^-+\+|^ [a-z]+ +\|"
EOF

step "2. 오류가 나는 단계로 보는 파서와 분석기의 차이"
pg <<'EOF'
psql -X -c "SELEC * FROM orders"
psql -X -c "SELECT * FROM order_typo"
psql -X -c "SELECT nosuchcol FROM orders"
EOF

step "3. 내부 트리: Query 트리와 계획 트리(PlannedStmt)"
pg <<'EOF'
psql -X -c "SET client_min_messages = log" -c "SET debug_print_rewritten = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
psql -X -c "SET client_min_messages = log" -c "SET debug_print_plan = on" -c "SELECT status, count(*) FROM orders WHERE amount < 100 GROUP BY status" 2>&1 | grep -oE "\{[A-Z_]+" | awk '!seen[$0]++' | tr '\n' ' '; echo
EOF

step "4. 리라이터: 뷰는 원래 테이블로 풀린다"
pg <<'EOF'
psql -X -q -c "CREATE VIEW big_orders AS SELECT id, customer_id, amount FROM orders WHERE amount >= 990"
psql -X -c "EXPLAIN (COSTS OFF) SELECT * FROM big_orders WHERE customer_id = 7"
EOF

step "5. 통계 정보: pg_stats"
pg <<'EOF'
psql -X -x -c "SELECT attname, null_frac, n_distinct, most_common_vals, most_common_freqs, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'status'"
psql -X -x -c "SELECT attname, n_distinct, array_length(most_common_vals::text::int[], 1) AS mcv_count, (SELECT sum(f) FROM unnest(most_common_freqs) f) AS mcv_total_freq, array_length(histogram_bounds, 1) AS histogram_len, (histogram_bounds::text::int[])[1:6] AS histogram_head, correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'amount'"
psql -X -c "SELECT relname, relpages, reltuples FROM pg_class WHERE relname IN ('orders', 'customers') ORDER BY relname"
EOF

step "6. 비용 모델: Seq Scan의 비용을 직접 계산해 보기"
pg <<'EOF'
psql -X -c "SHOW seq_page_cost" -c "SHOW random_page_cost" -c "SHOW cpu_tuple_cost" -c "SHOW cpu_operator_cost"
psql -X -c "EXPLAIN SELECT * FROM orders"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE status = 'returned'"
psql -X -c "SELECT relpages * 1.0 + reltuples * 0.01 AS seqscan_cost, relpages * 1.0 + reltuples * 0.01 + reltuples * 0.0025 AS with_filter_cost FROM pg_class WHERE relname = 'orders'"
EOF

step "7. 추정과 실제: MCV와 히스토그램"
pg <<'EOF'
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'shipped'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE amount < 30"
EOF

step "8. 같은 쿼리, 다른 계획: 선택도에 따라 스캔 방식이 바뀐다"
pg <<'EOF'
psql -X -c "EXPLAIN SELECT * FROM orders WHERE id = 42"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE amount < 30"
psql -X -c "EXPLAIN SELECT * FROM orders WHERE amount < 800"
EOF

step "9. 조인 방식: Nested Loop, Hash Join, Merge Join"
pg <<'EOF'
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, o.amount FROM customers c JOIN orders o ON o.customer_id = c.id WHERE c.id = 42"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name"
psql -X -c "SET enable_hashjoin = off" -c "SET enable_nestloop = off" -c "EXPLAIN (COSTS OFF) SELECT c.name, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.name"
EOF

step "10. 실행기는 필요한 만큼만 당겨 온다"
pg <<'EOF'
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF, COSTS OFF) SELECT * FROM orders LIMIT 5"
EOF

step "11. 통계가 오래되면: 분포가 바뀐 뒤의 추정"
pg <<'EOF'
psql -X -q -c "ALTER TABLE orders SET (autovacuum_enabled = off)"
psql -X -q -c "UPDATE orders SET status = 'returned' WHERE id % 10 = 0"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
psql -X -q -c "ANALYZE orders"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE status = 'returned'"
EOF

step "12. 서로 관련된 컬럼: 확장 통계"
pg <<'EOF'
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR'"
psql -X -q -c "CREATE STATISTICS orders_city_country (dependencies) ON city, country FROM orders" -c "ANALYZE orders"
psql -X -c "SELECT statistics_name, dependencies FROM pg_stats_ext WHERE statistics_name = 'orders_city_country'"
psql -X -c "EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) SELECT * FROM orders WHERE city = 'Seoul' AND country = 'KR'"
EOF

echo "done" | log
