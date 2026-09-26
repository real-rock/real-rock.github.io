#!/bin/bash
# PostgreSQL 인터널 6편(트랜잭션 ID wraparound) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# xid_wraparound 테스트 모듈의 consume_xids()로 트랜잭션 ID를 빠르게 소모한다.
cd "$(dirname "$0")"
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
cat >> $PGDATA/postgresql.conf <<'CONF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
log_line_prefix = '%m [%p] %b '
CONF
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION xid_wraparound" -c "CREATE EXTENSION pageinspect"
EOF

step "1. 트랜잭션 ID와 age"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_current_xact_id() AS next_xid;
SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database ORDER BY datname;
SQL
pg_controldata $PGDATA | grep -E "NextXID|oldestXID"
EOF

step "2. freeze: 튜플에 '아주 오래전에 커밋됨' 표시하기"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE f (id int) WITH (autovacuum_enabled = off);
INSERT INTO f SELECT generate_series(1, 3);
SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'f';
SELECT lp, t_xmin, raw_flags, combined_flags
FROM heap_page_items(get_raw_page('f', 0)), LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
VACUUM (FREEZE) f;
SELECT lp, t_xmin, raw_flags, combined_flags
FROM heap_page_items(get_raw_page('f', 0)), LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'f';
SELECT xmin, * FROM f;
SQL
EOF

step "3. xid를 쓰면 age가 늘어난다"
pg <<'EOF'
psql -X -q -c "CREATE TABLE noav (id int) WITH (autovacuum_enabled = off)" -c "INSERT INTO noav VALUES (1)"
psql -X -c "SELECT consume_xids(150000000)"
psql -X -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname IN ('f', 'noav') ORDER BY 1"
EOF

step "4. autovacuum을 꺼도 wraparound 방지 VACUUM은 돈다"
pg <<'EOF'
psql -X -c "SELECT consume_xids(60000000)"
sleep 8
psql -X -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname IN ('f', 'noav') ORDER BY 1"
grep -E 'to prevent wraparound of table "postgres.public.(f|noav)"' /home/postgres/server.log | cut -c1-160
EOF

step "5. 오래된 트랜잭션이 freeze를 막으면"
sess_start A
sess A "BEGIN;"
sess A "SELECT pg_current_xact_id() AS old_xid;"
pg <<'EOF'
vacuumdb --all --quiet
sleep 3
psql -X <<'SQL'
SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database ORDER BY datname;
SELECT min(datfrozenxid::text::bigint) AS oldest_datfrozenxid,
       min(datfrozenxid::text::bigint) + 2147483647 AS wrap_limit,
       min(datfrozenxid::text::bigint) + 2147483647 - 40000000 AS warn_limit,
       min(datfrozenxid::text::bigint) + 2147483647 - 3000000 AS stop_limit
FROM pg_database;
SQL
EOF

step "6. 경고 단계: 4000만 개 남았을 때"
pg <<'EOF'
W=$(psql -X -At -c "SELECT min(datfrozenxid::text::bigint) + 2147483647 - 40000000 + 1000 FROM pg_database")
psql -X -q -c "SELECT consume_xids_until('$W'::xid8)" > /dev/null 2>&1
psql -X -c "INSERT INTO noav VALUES (2)"
EOF

step "7. 정지 단계: 300만 개 남았을 때"
pg <<'EOF'
S=$(psql -X -At -c "SELECT min(datfrozenxid::text::bigint) + 2147483647 - 3000000 + 1000 FROM pg_database")
psql -X -q -c "SELECT consume_xids_until('$S'::xid8)" 2>&1 | tail -3
psql -X -c "INSERT INTO noav VALUES (3)"
psql -X -c "SELECT count(*) FROM noav"
EOF

step "8. 원인을 없애고 VACUUM으로 복구"
sess A "ROLLBACK;"
sess_end A
pg <<'EOF'
sleep 15
psql -X -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY datname"
psql -X -c "INSERT INTO noav VALUES (4)"
grep -cE 'to prevent wraparound' /home/postgres/server.log
grep -E 'bypassing nonessential maintenance' /home/postgres/server.log | head -2 | cut -c1-200
EOF

echo "done" | log
