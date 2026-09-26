#!/bin/bash
# PostgreSQL 운영 5편(테이블과 인덱스가 계속 커진다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
SIZES="SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
       pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
       pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;"
TUPLE="SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
       round(free_percent::numeric, 1) AS free_pct, pg_size_pretty(table_len) AS table_len
FROM pgstattuple('items');"
INDEX="SELECT 'items_status_idx' AS index, leaf_pages, round(avg_leaf_density::numeric, 1) AS avg_leaf_density,
       pg_size_pretty(index_size) AS size
FROM pgstatindex('items_status_idx');"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET log_autovacuum_min_duration = 0;"
note "실습에서 autovacuum이 빨리 돌도록 naptime을 줄인다 (운영 권장값 아님)"
q "ALTER SYSTEM SET autovacuum_naptime = '5s';"
q "SELECT pg_reload_conf();"
q "CREATE EXTENSION pgstattuple;"

step "1. 테이블 준비"
q "CREATE TABLE items (id int PRIMARY KEY, status text, payload text);"
q "CREATE INDEX items_status_idx ON items (status);"
note "bloat가 쌓이는 과정을 보려고 이 테이블의 autovacuum을 끈다"
q "ALTER TABLE items SET (autovacuum_enabled = false);"
q "INSERT INTO items SELECT g, 'new', repeat('x', 200) FROM generate_series(1, 1000000) g;"
q "VACUUM ANALYZE items;"
q "$SIZES"
q "$TUPLE"
q "$INDEX"

step "2. 대량 UPDATE로 부풀리기"
q "UPDATE items SET status = 'paid';"
q "UPDATE items SET status = 'shipped';"
q "UPDATE items SET status = 'done';"
q "SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'items';"
q "$SIZES"
q "$TUPLE"

step "3. VACUUM은 공간을 비우지만 파일을 줄이지 않는다"
q "VACUUM (VERBOSE) items;"
q "$SIZES"
q "$TUPLE"
q "$INDEX"
note "비운 자리는 새 행이 다시 쓴다"
q "INSERT INTO items SELECT g, 'new', repeat('x', 200) FROM generate_series(1000001, 1500000) g;"
q "$SIZES"
q "$TUPLE"

step "4. REINDEX CONCURRENTLY"
q "REINDEX INDEX CONCURRENTLY items_status_idx;"
q "$SIZES"
q "$INDEX"

step "5. VACUUM FULL은 테이블을 막는다"
q "DELETE FROM items WHERE id > 1000000;"
q "VACUUM items;"
q "$TUPLE"
sess_start A
sess A "SET application_name = 'maint';"
sess A "\\timing on"
sess_start B
sess B "SET application_name = 'app';"
sess B "\\timing on"
sess A "VACUUM FULL items;" 3
q "$SIZES"
q "$TUPLE"
note "VACUUM FULL이 도는 동안 다른 세션은 그 테이블을 읽지도 못한다. 더 큰 테이블로 본다"
q "CREATE TABLE big (id int PRIMARY KEY, payload text);"
q "INSERT INTO big SELECT g, repeat('x', 200) FROM generate_series(1, 4000000) g;"
q "SELECT pg_size_pretty(pg_table_size('big')) AS big_size;"
sess A "VACUUM FULL big;" 0.5
sess B "SELECT count(*) FROM big WHERE id = 1;" 0.5
q "SELECT pid, application_name AS app, state, wait_event_type, wait_event, left(query, 40) AS query
FROM pg_stat_activity WHERE application_name IN ('maint', 'app') ORDER BY pid;"
q "SELECT pid, command, phase, heap_tuples_scanned, heap_tuples_written
FROM pg_stat_progress_cluster;"
q "SELECT l.pid, a.application_name AS app, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.locktype = 'relation' AND l.relation = 'big'::regclass ORDER BY l.granted DESC;"
sess_wait A 15
sess_wait B 1
sess_end A; sess_end B

step "6. autovacuum 기준"
q "SELECT name, setting FROM pg_settings
WHERE name IN ('autovacuum_vacuum_threshold', 'autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_max_threshold', 'autovacuum_vacuum_insert_threshold',
               'autovacuum_vacuum_insert_scale_factor')
ORDER BY name;"
q "CREATE TABLE events (id int PRIMARY KEY, state text);"
q "INSERT INTO events SELECT g, 'new' FROM generate_series(1, 1000000) g;"
q "VACUUM ANALYZE events;"
q "UPDATE events SET state = 'seen' WHERE id <= 150000;"
q "SELECT s.relname, s.n_live_tup, s.n_dead_tup,
       50 + 0.2 * c.reltuples AS vacuum_threshold, s.last_autovacuum
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
WHERE s.relname = 'events';"
sleep 15
note "15초 뒤: dead tuple이 기준(20%)에 못 미쳐 autovacuum이 돌지 않았다"
q "SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'events';"
q "ALTER TABLE events SET (autovacuum_vacuum_scale_factor = 0.05);"
sleep 15
q "SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'events';"
pg <<SH
$LOGTAIL | grep -A 4 -E 'automatic vacuum of table "postgres.public.events"'
SH

docker rm -f "$CT" >/dev/null 2>&1
