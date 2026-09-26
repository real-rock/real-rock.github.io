#!/bin/bash
# PostgreSQL 인터널 5편(VACUUM과 autovacuum) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pageinspect" -c "CREATE EXTENSION pg_visibility" -c "CREATE EXTENSION pg_freespacemap"
psql -X -q -c "CREATE TABLE t (id int PRIMARY KEY, v int, pad text) WITH (autovacuum_enabled = off)"
psql -X -q -c "INSERT INTO t SELECT g, 0, repeat('x', 100) FROM generate_series(1, 20000) g"
sleep 2
psql -X -q -c "VACUUM (ANALYZE) t"
EOF

step "1. UPDATE를 하면 dead tuple이 쌓인다"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
UPDATE t SET v = v + 1;
SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
SQL
sleep 2
psql -X -c "SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't'"
EOF

step "2. VACUUM이 dead tuple을 정리한다"
pg <<'EOF'
psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) t" 2>&1
sleep 2
psql -X <<'SQL'
SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
SELECT n_live_tup, n_dead_tup, vacuum_count FROM pg_stat_user_tables WHERE relname = 't';
SELECT count(*) AS pages, pg_size_pretty(sum(avail)) AS free_space FROM pg_freespace('t');
SQL
EOF

step "3. 비운 공간은 다시 쓴다"
pg <<'EOF'
psql -X <<'SQL'
INSERT INTO t SELECT g, 0, repeat('x', 100) FROM generate_series(20001, 30000) g;
SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
SQL
EOF

step "4. Visibility Map과 index-only scan"
pg <<'EOF'
psql -X <<'SQL'
SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 't';
UPDATE t SET v = v + 1 WHERE id <= 5000;
SELECT pg_sleep(2);
SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 't';
SELECT * FROM pg_visibility_map_summary('t');
SET enable_seqscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT count(id) FROM t WHERE id <= 5000;
VACUUM t;
SELECT * FROM pg_visibility_map_summary('t');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT count(id) FROM t WHERE id <= 5000;
SQL
EOF

step "5. HOT 업데이트와 pruning"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE hot (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = off);
INSERT INTO hot VALUES (1, 0);
UPDATE hot SET v = 1 WHERE id = 1;
UPDATE hot SET v = 2 WHERE id = 1;
UPDATE hot SET v = 3 WHERE id = 1;
SELECT lp, lp_flags, lp_off, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('hot', 0));
SQL
sleep 2
psql -X <<'SQL'
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'hot';
VACUUM hot;
SELECT lp, lp_flags, lp_off, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('hot', 0));
SQL
EOF

step "6. 긴 트랜잭션이 있으면 지우지 못한다"
sess_start A
sess A "BEGIN ISOLATION LEVEL REPEATABLE READ;"
sess A "SELECT count(*) FROM t;"
sess A "SELECT pg_current_snapshot();"
pg <<'EOF'
psql -X -c "DELETE FROM t WHERE id > 25000"
psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) t" 2>&1 | grep -E 'tuples:|removable cutoff'
psql -X -c "SELECT pid, state, backend_xmin, now() - xact_start > interval '0' AS in_xact FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid()"
EOF
sess A "COMMIT;"
sess_end A
pg <<'EOF'
psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) t" 2>&1 | grep -E 'tuples:|removable cutoff'
EOF

step "6-1. 테이블 끝의 빈 페이지는 잘라 낸다"
pg <<'EOF'
psql -X -q -c "CREATE TABLE tail (id int, pad text) WITH (autovacuum_enabled = off)"
psql -X -q -c "INSERT INTO tail SELECT g, repeat('x', 100) FROM generate_series(1, 20000) g"
psql -X -c "SELECT pg_relation_size('tail') / 8192 AS pages"
psql -X -q -c "DELETE FROM tail WHERE id > 10000"
psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) tail" 2>&1 | grep -E 'pages:|tuples:'
psql -X -c "SELECT pg_relation_size('tail') / 8192 AS pages"
EOF

step "7. VACUUM FULL은 테이블을 새로 쓴다"
pg <<'EOF'
psql -X <<'SQL'
DELETE FROM t WHERE id % 2 = 0;
VACUUM t;
SELECT pg_relation_filenode('t') AS filenode, pg_size_pretty(pg_relation_size('t')) AS size;
VACUUM FULL t;
SELECT pg_relation_filenode('t') AS filenode, pg_size_pretty(pg_relation_size('t')) AS size;
SQL
EOF

step "8. autovacuum은 언제 도는가"
pg <<'EOF'
psql -X -q <<'SQL'
ALTER SYSTEM SET autovacuum_naptime = '1s';
ALTER SYSTEM SET log_autovacuum_min_duration = 0;
SELECT pg_reload_conf();
CREATE TABLE av (id int PRIMARY KEY, v int);
INSERT INTO av SELECT g, 0 FROM generate_series(1, 10000) g;
SQL
sleep 5
psql -X <<'SQL'
SELECT relname, reltuples FROM pg_class WHERE relname = 'av';
SELECT current_setting('autovacuum_vacuum_threshold')::int
     + current_setting('autovacuum_vacuum_scale_factor')::float * reltuples AS vacuum_threshold
FROM pg_class WHERE relname = 'av';
SELECT n_dead_tup, autovacuum_count, last_autovacuum IS NOT NULL AS vacuumed FROM pg_stat_user_tables WHERE relname = 'av';
UPDATE av SET v = 1 WHERE id <= 1500;
SQL
sleep 4
psql -X -c "SELECT n_dead_tup, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'av'"
psql -X -q -c "UPDATE av SET v = 2 WHERE id <= 1500"
sleep 4
psql -X -c "SELECT n_dead_tup, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'av'"
grep -A8 'automatic vacuum of table "postgres.public.av"' /home/postgres/server.log | grep -E 'automatic vacuum|tuples:|index scan'
EOF

echo "done" | log
