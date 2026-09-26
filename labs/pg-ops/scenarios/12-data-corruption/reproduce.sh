#!/bin/bash
# PostgreSQL 운영 12편(데이터 손상이 의심된다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 서버를 멈춘 상태에서 dd로 테이블 페이지와 인덱스 페이지의 일부 바이트를 덮어써 손상을 만든다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "SELECT pg_reload_conf();"
q "SHOW data_checksums;"
q "CREATE EXTENSION amcheck;"
q "CREATE TABLE t (id int PRIMARY KEY, v text);"
q "INSERT INTO t SELECT g, 'row-' || g || '-' || repeat('a', 100) FROM generate_series(1, 1000) g;"
q "CREATE TABLE w (id int PRIMARY KEY, v text);"
q "INSERT INTO w SELECT g, 'row-' || g || '-' || repeat('a', 100) FROM generate_series(1, 1000) g;"
q "CREATE TABLE u (id int PRIMARY KEY, v text);"
q "INSERT INTO u SELECT g, 'u-' || g FROM generate_series(1, 1000) g;"
q "SELECT (ctid::text::point)[0]::int AS block, count(*), min(id), max(id)
FROM t GROUP BY 1 ORDER BY 1 LIMIT 3;"
q "SELECT 't' AS rel, pg_relation_filepath('t') AS path
UNION ALL SELECT 'w', pg_relation_filepath('w')
UNION ALL SELECT 'u_pkey', pg_relation_filepath('u_pkey');"
q "SELECT count(*) FROM t;"

step "1. (실습용) 서버를 멈추고 페이지 일부를 덮어쓴다"
pg <<'SH'
psql -XAtc "SELECT pg_relation_filepath('t')" > /tmp/t_path
psql -XAtc "SELECT pg_relation_filepath('w')" > /tmp/w_path
psql -XAtc "SELECT pg_relation_filepath('u_pkey')" > /tmp/u_pkey_path
psql -Xqc "CHECKPOINT"
pg_ctl -D $PGDATA -w stop -m fast
SH
pg <<'SH'
printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' | dd of=$PGDATA/$(cat /tmp/t_path) bs=1 seek=$((8192 * 1 + 8192 - 40)) conv=notrunc status=none
printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' | dd of=$PGDATA/$(cat /tmp/w_path) bs=1 seek=$((8192 * 1 + 8192 - 40)) conv=notrunc status=none
printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' | dd of=$PGDATA/$(cat /tmp/u_pkey_path) bs=1 seek=$((8192 * 1 + 8192 - 40)) conv=notrunc status=none
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH

step "2. 증상"
q "SELECT count(*) FROM t;"
q "SELECT * FROM t WHERE id = 1;"
q "SELECT * FROM t WHERE id = 100;"
q "SELECT * FROM u WHERE id = 10;"
q "SELECT count(*) FROM u;"
pg <<SH
$LOGTAIL | grep -E 'page verification failed|invalid page' | tail -n 4
SH
q "SELECT datname, checksum_failures, checksum_last_failure FROM pg_stat_database WHERE datname = 'postgres';"

step "3. 손상 범위 파악"
pg <<'SH'
pg_amcheck -d postgres 2>&1 | head -n 20
SH
pg <<'SH'
pg_ctl -D $PGDATA -w stop -m fast
pg_checksums --check -D $PGDATA 2>&1 | tail -n 10
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH

step "4. 인덱스만 망가졌다면: REINDEX"
q "SELECT bt_index_check('u_pkey');"
q "REINDEX INDEX u_pkey;"
q "SELECT bt_index_check('u_pkey');"
q "SELECT * FROM u WHERE id = 10;"

step "5. 테이블 페이지: 살릴 수 있는 것을 먼저 꺼낸다 (ignore_checksum_failure)"
q "SET ignore_checksum_failure = on;
SELECT count(*) FROM t;"
q "SET ignore_checksum_failure = on;
CREATE TABLE t_rescue AS SELECT * FROM t;"
q "SELECT id, right(v, 35) AS tail FROM t_rescue WHERE id IN (58, 59, 60) ORDER BY id;"
note "재시작한 뒤 t를 다시 읽는다"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "SELECT count(*) FROM t;"
q "SELECT id, right(v, 35) AS tail FROM t WHERE id = 59;"
pg <<'SH'
pg_amcheck -d postgres 2>&1 | head -n 10
SH

step "6. 테이블 페이지: 망가진 페이지를 버린다 (zero_damaged_pages)"
q "SET zero_damaged_pages = on;
SELECT count(*) FROM w;"
pg <<SH
$LOGTAIL | grep -E 'zeroing out page' | tail -n 1
SH
q "SELECT count(*) FROM w;"
q "VACUUM w;"
q "SELECT * FROM verify_heapam('w');"
q "SELECT count(*) AS missing, min(g) AS first_id, max(g) AS last_id
FROM generate_series(1, 1000) g WHERE NOT EXISTS (SELECT 1 FROM w WHERE w.id = g);"

docker rm -f "$CT" >/dev/null 2>&1
