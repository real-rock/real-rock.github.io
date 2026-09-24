#!/bin/bash
# PostgreSQL 인터널 7편(WAL) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../common/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_walinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, memo text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, 'init' FROM generate_series(1, 1000) g"
psql -X -q -c "CHECKPOINT"
EOF

step "1. LSN과 WAL 세그먼트 파일"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_current_wal_insert_lsn() AS insert_lsn, pg_current_wal_lsn() AS write_lsn, pg_current_wal_flush_lsn() AS flush_lsn;
SELECT pg_walfile_name(pg_current_wal_insert_lsn()) AS segment_file,
       pg_walfile_name_offset(pg_current_wal_insert_lsn()) AS file_and_offset;
SHOW wal_segment_size;
SQL
ls -l $PGDATA/pg_wal | head -5
EOF

step "2. INSERT 하나가 남기는 WAL 레코드"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_current_wal_insert_lsn() AS s1 \gset
INSERT INTO acct VALUES (1001, 100, 'hello');
SELECT pg_current_wal_insert_lsn() AS e1 \gset
INSERT INTO acct VALUES (1002, 100, 'world');
SELECT pg_current_wal_insert_lsn() AS e2 \gset
SELECT 'first' AS insert, pg_wal_lsn_diff(:'e1', :'s1') AS wal_bytes
UNION ALL SELECT 'second', pg_wal_lsn_diff(:'e2', :'e1');
SELECT start_lsn, xid, resource_manager AS rmgr, record_type, record_length AS len, fpi_length AS fpi, description
FROM pg_get_wal_records_info(:'s1', :'e2');
SQL
EOF
pg <<'EOF'
S=$(psql -X -At -c "SELECT pg_current_wal_insert_lsn()")
psql -X -q -c "INSERT INTO acct VALUES (1003, 100, 'waldump')"
E=$(psql -X -At -c "SELECT pg_current_wal_insert_lsn()")
echo "S=$S E=$E"
pg_waldump -p $PGDATA/pg_wal -s $S -e $E 2>&1
EOF

step "3. full page write: 체크포인트 뒤 첫 수정은 페이지 전체를 남긴다"
pg <<'EOF'
psql -X <<'SQL'
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s1 \gset
UPDATE acct SET balance = balance + 1 WHERE id = 1;
SELECT pg_current_wal_insert_lsn() AS e1 \gset
UPDATE acct SET balance = balance + 1 WHERE id = 2;
SELECT pg_current_wal_insert_lsn() AS e2 \gset
SELECT 'first update after checkpoint' AS which, resource_manager AS rmgr, record_type, record_length AS len, fpi_length AS fpi, block_ref
FROM pg_get_wal_records_info(:'s1', :'e1')
UNION ALL
SELECT 'second update (same page)', resource_manager, record_type, record_length, fpi_length, block_ref
FROM pg_get_wal_records_info(:'e1', :'e2');
SQL
EOF

step "4. full_page_writes와 wal_compression이 WAL 양에 주는 영향"
pg <<'EOF'
cat > /home/postgres/fpw.sql <<'SQL'
DROP TABLE IF EXISTS fpw_t;
CREATE TABLE fpw_t (id int PRIMARY KEY, balance int, memo text);
INSERT INTO fpw_t SELECT g, 100, 'init' FROM generate_series(1, 1000) g;
VACUUM fpw_t;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s \gset
UPDATE fpw_t SET balance = balance + 1 WHERE id % 10 = 0;
SELECT pg_current_wal_insert_lsn() AS e \gset
SELECT current_setting('full_page_writes') AS fpw, current_setting('wal_compression') AS compression,
       count(*) AS records, count(*) FILTER (WHERE fpi_length > 0) AS with_fpi,
       sum(fpi_length) AS fpi_bytes, sum(record_length - fpi_length) AS other_bytes,
       pg_wal_lsn_diff(:'e', :'s') AS wal_bytes
FROM pg_get_wal_records_info(:'s', :'e');
SQL
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM SET wal_compression = 'pglz'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM SET wal_compression = 'off'" -c "ALTER SYSTEM SET full_page_writes = 'off'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM RESET full_page_writes" -c "ALTER SYSTEM RESET wal_compression" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "5. 체크섬이 켜져 있으면 SELECT도 WAL을 남길 수 있다"
pg <<'EOF'
psql -X <<'SQL'
SHOW data_checksums;
INSERT INTO acct SELECT g, 100, 'new' FROM generate_series(2001, 2200) g;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s \gset
SELECT count(*) FROM acct WHERE id > 2000;
SELECT pg_current_wal_insert_lsn() AS e \gset
SELECT pg_wal_lsn_diff(:'e', :'s') AS wal_bytes_by_select,
       pg_wal_lsn_diff(:'e', pg_current_wal_lsn()) AS not_yet_written;
CHECKPOINT;
SELECT resource_manager AS rmgr, record_type, count(*), sum(fpi_length) AS fpi_bytes
FROM pg_get_wal_records_info(:'s', :'e') GROUP BY 1, 2;
SELECT record_type, fpi_length AS fpi, block_ref FROM pg_get_wal_records_info(:'s', :'e') WHERE fpi_length > 0;
SELECT (ctid::text::point)[0]::int AS blk, count(*) AS new_rows FROM acct WHERE id > 2000 GROUP BY 1 ORDER BY 1;
EXPLAIN (COSTS OFF) SELECT count(*) FROM acct WHERE id > 2000;
SQL
EOF

step "6. 커밋은 WAL이 디스크에 닿을 때까지 기다린다"
pg <<'EOF'
cat > /home/postgres/one.sql <<'SQL'
INSERT INTO acct VALUES (100000 + random() * 1000000000, 1, 'x') ON CONFLICT DO NOTHING;
SQL
psql -X -c "SHOW synchronous_commit"
pgbench -n -c 1 -T 5 -f /home/postgres/one.sql postgres 2>&1 | grep -E "number of transactions actually processed|latency average|tps"
PGOPTIONS='-c synchronous_commit=off' pgbench -n -c 1 -T 5 -f /home/postgres/one.sql postgres 2>&1 | grep -E "number of transactions actually processed|latency average|tps"
EOF

step "7. 어떤 종류의 WAL이 쌓였나: resource manager별 통계"
pg <<'EOF'
psql -X <<'SQL'
SELECT "resource_manager/record_type" AS rmgr, count, round(count_percentage::numeric, 1) AS count_pct,
       pg_size_pretty(combined_size) AS bytes, round(combined_size_percentage::numeric, 1) AS bytes_pct,
       round(fpi_size_percentage::numeric, 1) AS fpi_pct
FROM pg_get_wal_stats('0/1000000', pg_current_wal_lsn())
WHERE count > 0 ORDER BY combined_size DESC;
SQL
EOF

step "8. WAL 세그먼트는 재활용된다"
pg <<'EOF'
psql -X -c "SHOW min_wal_size" -c "SHOW max_wal_size"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
psql -X -q -c "CREATE TABLE bulk AS SELECT g AS id, repeat('w', 200) AS pad FROM generate_series(1, 400000) g"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
psql -X -At -c "SELECT pg_walfile_name(pg_current_wal_insert_lsn()) AS current_segment"
ls $PGDATA/pg_wal | grep -v -e archive_status -e summaries | tr '\n' ' '; echo
psql -X -q -c "CHECKPOINT"
psql -X -q -c "CHECKPOINT"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
ls $PGDATA/pg_wal | grep -v -e archive_status -e summaries | tr '\n' ' '; echo
EOF

echo "done" | log
