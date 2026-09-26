#!/bin/bash
# PostgreSQL 인터널 3편(데이터 저장 구조) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pageinspect"
EOF

step "1. 테이블은 파일이다"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE fruit (id int, name text);
INSERT INTO fruit VALUES (1, 'apple'), (2, 'banana'), (3, 'cherry');
SELECT oid AS db_oid, datname FROM pg_database WHERE datname = current_database();
SELECT 'fruit'::regclass::oid AS table_oid, pg_relation_filenode('fruit') AS filenode,
       pg_relation_filepath('fruit') AS path;
SQL
EOF
pg <<'EOF'
F=$(psql -X -At -c "SELECT pg_relation_filepath('fruit')")
ls -l $PGDATA/$F*
psql -X -q -c "VACUUM fruit"
ls -l $PGDATA/$F*
pg_controldata $PGDATA | grep -E 'Database block size|Blocks per segment|Data page checksum'
EOF

step "2. 페이지 헤더"
pg <<'EOF'
psql -X <<'SQL'
SELECT * FROM page_header(get_raw_page('fruit', 0));
SQL
EOF

step "3. 파일의 실제 바이트"
pg <<'EOF'
psql -X -q -c "CHECKPOINT"
F=$(psql -X -At -c "SELECT pg_relation_filepath('fruit')")
xxd -l 40 $PGDATA/$F
xxd -s 8096 -l 96 $PGDATA/$F
psql -X -c "SELECT checksum AS checksum_in_buffer, page_checksum(get_raw_page('fruit', 0), 0) AS computed, to_hex(page_checksum(get_raw_page('fruit', 0), 0) & 65535) AS computed_hex FROM page_header(get_raw_page('fruit', 0))"
EOF

step "4. line pointer와 튜플 헤더"
pg <<'EOF'
psql -X <<'SQL'
SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask, t_hoff, t_data
FROM heap_page_items(get_raw_page('fruit', 0));
SELECT lp, raw_flags, combined_flags
FROM heap_page_items(get_raw_page('fruit', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
SQL
EOF

step "5. 열 순서와 정렬 패딩"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE pad_bad  (a bool, b bigint, c bool, d bigint);
CREATE TABLE pad_good (b bigint, d bigint, a bool, c bool);
INSERT INTO pad_bad  VALUES (true, 1, true, 2);
INSERT INTO pad_good VALUES (1, 2, true, true);
SELECT 'pad_bad' AS tbl, lp_len, t_hoff, t_data FROM heap_page_items(get_raw_page('pad_bad', 0))
UNION ALL
SELECT 'pad_good', lp_len, t_hoff, t_data FROM heap_page_items(get_raw_page('pad_good', 0));
SELECT attname, typname, typlen, typalign
FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
WHERE attrelid = 'pad_bad'::regclass AND attnum > 0 ORDER BY attnum;
SQL
EOF

step "6. NULL은 비트맵 한 비트"
pg <<'EOF'
psql -X <<'SQL'
INSERT INTO fruit VALUES (4, NULL);
SELECT lp, lp_len, t_hoff, t_bits, t_infomask, t_data
FROM heap_page_items(get_raw_page('fruit', 0)) WHERE lp IN (3, 4);
SQL
EOF

step "7. 한 페이지에 들어가는 행 수와 fillfactor"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE narrow (id int);
INSERT INTO narrow SELECT generate_series(1, 10000);
CREATE TABLE narrow_ff (id int) WITH (fillfactor = 50);
INSERT INTO narrow_ff SELECT generate_series(1, 10000);
SELECT 'narrow' AS tbl, pg_relation_size('narrow') / 8192 AS pages,
       (SELECT count(*) FROM heap_page_items(get_raw_page('narrow', 0))) AS rows_in_page0,
       (SELECT lower || '/' || upper FROM page_header(get_raw_page('narrow', 0))) AS lower_upper
UNION ALL
SELECT 'narrow_ff', pg_relation_size('narrow_ff') / 8192,
       (SELECT count(*) FROM heap_page_items(get_raw_page('narrow_ff', 0))),
       (SELECT lower || '/' || upper FROM page_header(get_raw_page('narrow_ff', 0)));
SQL
EOF

step "8. 큰 값은 TOAST로"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE doc (id int, body text);
SELECT reltoastrelid::regclass AS toast_table FROM pg_class WHERE relname = 'doc';
INSERT INTO doc VALUES
  (1, repeat('a', 100)),
  (2, repeat('a', 100000)),
  (3, (SELECT string_agg(md5(g::text), '') FROM generate_series(1, 3125) g));
SELECT id, octet_length(body) AS original_bytes, pg_column_size(body) AS stored_bytes,
       pg_column_compression(body) AS compression
FROM doc ORDER BY id;
SELECT lp, lp_len FROM heap_page_items(get_raw_page('doc', 0));
SQL
EOF
pg <<'EOF'
T=$(psql -X -At -c "SELECT reltoastrelid::regclass FROM pg_class WHERE relname = 'doc'")
psql -X <<SQL
SELECT chunk_id, count(*) AS chunks, min(chunk_seq) AS first_seq, max(chunk_seq) AS last_seq,
       max(octet_length(chunk_data)) AS max_chunk_bytes, sum(octet_length(chunk_data)) AS total_bytes
FROM $T GROUP BY chunk_id;
SQL
EOF

step "9. TOAST가 시작되는 크기"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE edge (id int, body text);
ALTER TABLE edge ALTER COLUMN body SET STORAGE EXTERNAL;
INSERT INTO edge
SELECT n, left((SELECT string_agg(md5(g::text), '') FROM generate_series(1, 100) g), n)
FROM (VALUES (1990), (2000), (2001), (2010)) v(n);
SELECT e.id AS body_bytes, pg_column_size(e.body) AS stored_bytes, h.lp_len AS tuple_bytes
FROM edge e JOIN heap_page_items(get_raw_page('edge', 0)) h ON h.t_ctid = e.ctid
ORDER BY e.id;
SQL
EOF

step "10. 저장 전략 바꾸기"
pg <<'EOF'
psql -X <<'SQL'
SELECT attname, attstorage FROM pg_attribute WHERE attrelid = 'doc'::regclass AND attnum > 0;
CREATE TABLE doc_ext (id int, body text);
ALTER TABLE doc_ext ALTER COLUMN body SET STORAGE EXTERNAL;
INSERT INTO doc_ext VALUES (2, repeat('a', 100000));
SELECT 'doc (EXTENDED)' AS tbl, pg_column_size(body) AS stored_bytes, pg_column_compression(body) AS compression FROM doc WHERE id = 2
UNION ALL
SELECT 'doc_ext (EXTERNAL)', pg_column_size(body), pg_column_compression(body) FROM doc_ext;
SQL
EOF

echo "done" | log
