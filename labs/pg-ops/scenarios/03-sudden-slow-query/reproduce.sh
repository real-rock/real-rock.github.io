#!/bin/bash
# PostgreSQL 운영 3편(쿼리가 갑자기 느려졌다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
JOINQ="SELECT count(*) FROM orders o JOIN shipments s ON s.order_id = o.id
WHERE o.status = 'pending' AND s.state = 'ready';"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, auto_explain;"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET log_min_duration_statement = '1s';"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "ALTER SYSTEM SET auto_explain.log_min_duration = '20ms';"
q "SELECT pg_reload_conf();"
q "CREATE EXTENSION pg_stat_statements;"

step "1. 데이터 준비"
note "orders 100만 행: 대형 고객 1이 40%, 중형 고객 2~11이 3%씩, 소형 고객 2만 명이 나머지"
q "CREATE TABLE orders (id bigint PRIMARY KEY, customer_id int, status text, amount int);"
q "INSERT INTO orders
SELECT g,
       CASE WHEN g % 10 < 4 THEN 1
            WHEN g % 10 < 7 THEN 2 + (g / 10) % 10
            ELSE 12 + (g / 10) % 20000 END,
       'done', g % 997
FROM generate_series(1, 1000000) g;"
q "CREATE TABLE shipments (id bigserial PRIMARY KEY, order_id bigint, state text);"
q "INSERT INTO shipments (order_id, state) SELECT g, 'delivered' FROM generate_series(1, 1000000) g;"
q "CREATE INDEX ON orders (status);"
q "CREATE INDEX ON orders (customer_id);"
q "CREATE INDEX ON shipments (state);"
note "재현을 위해 두 테이블의 autovacuum을 끈다. 실제로는 대량 적재 직후 autoanalyze가 돌기 전에 같은 일이 생긴다"
q "ALTER TABLE orders SET (autovacuum_enabled = false);"
q "ALTER TABLE shipments SET (autovacuum_enabled = false);"
q "ANALYZE orders;"
q "ANALYZE shipments;"

step "2. 대량 적재 직후: 통계가 데이터를 따라오지 못한다"
q "INSERT INTO orders SELECT g, 12 + g % 20000, 'pending', 1 FROM generate_series(1000001, 1100000) g;"
q "INSERT INTO shipments (order_id, state) SELECT g, 'ready' FROM generate_series(1000001, 1100000) g;"
q "SELECT relname, n_live_tup, n_mod_since_analyze, last_analyze, last_autoanalyze
FROM pg_stat_user_tables WHERE relname IN ('orders', 'shipments') ORDER BY relname;"
q "SELECT tablename, attname, most_common_vals, most_common_freqs
FROM pg_stats WHERE attname IN ('status', 'state') ORDER BY tablename;"
q "EXPLAIN $JOINQ"
sess_start A
sess A "SET application_name = 'batch';"
sess A "SET statement_timeout = '10s';"
sess A "\\timing on"
sess A "$JOINQ" 3
q "SELECT pid, state, wait_event_type, wait_event, now() - query_start AS running, left(query, 40) AS query
FROM pg_stat_activity WHERE application_name = 'batch';"
pg <<'SH'
top -b -n 1 -u postgres | sed -n '7,9p'
SH
sess_wait A 8
pg <<SH
$LOGTAIL | grep -A 1 -E 'statement timeout'
SH
q "ANALYZE orders;"
q "ANALYZE shipments;"
q "SELECT tablename, attname, most_common_vals, most_common_freqs
FROM pg_stats WHERE attname IN ('status', 'state') ORDER BY tablename;"
q "EXPLAIN (ANALYZE, BUFFERS) $JOINQ"
sess A "$JOINQ"
sess_end A

step "3. prepared statement: 여섯 번째 실행부터 계획이 바뀐다"
q "SELECT pg_stat_statements_reset() IS NOT NULL AS reset;"
sess_start B
sess B "SET application_name = 'app';"
sess B "\\timing on"
sess B "PREPARE by_cust(int) AS SELECT count(*), sum(amount) FROM orders WHERE customer_id = \$1;"
for c in 2 3 4 5 6; do sess B "EXECUTE by_cust($c);"; done
sess B "SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;"
sess B "EXECUTE by_cust(7);"
sess B "SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;"
note "대형 고객 1"
sess B "EXECUTE by_cust(1);" 2
sess B "EXPLAIN (ANALYZE, BUFFERS) EXECUTE by_cust(1);" 2
note "psql에서 상수로 넣어 확인하면 다른 계획이 나온다"
q "EXPLAIN (ANALYZE, BUFFERS) SELECT count(*), sum(amount) FROM orders WHERE customer_id = 1;"
pg <<SH
$LOGTAIL | grep -A 8 -E 'duration: [0-9.]+ ms  plan:' | tail -n 20
SH
q "SELECT left(query, 60) AS query, calls,
       round(min_exec_time::numeric, 2) AS min_ms, round(max_exec_time::numeric, 2) AS max_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms, round(stddev_exec_time::numeric, 2) AS stddev_ms
FROM pg_stat_statements WHERE query LIKE '%customer_id = \$1%';"

step "4. 조치: plan_cache_mode"
sess B "SET plan_cache_mode = force_custom_plan;"
sess B "EXECUTE by_cust(1);" 2
sess B "EXPLAIN (ANALYZE, BUFFERS) EXECUTE by_cust(1);" 2
sess B "EXECUTE by_cust(2);"
sess B "SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;"
sess_end B

docker rm -f "$CT" >/dev/null 2>&1
