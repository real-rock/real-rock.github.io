#!/bin/bash
# PostgreSQL 인터널 4편(MVCC) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pageinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int)"
psql -X -q -c "INSERT INTO acct VALUES (1, 100), (2, 100)"
EOF

step "1. 모든 행에는 xmin과 xmax가 있다"
pg <<'EOF'
psql -X <<'SQL'
SELECT xmin, xmax, cmin, ctid, * FROM acct;
BEGIN;
SELECT pg_current_xact_id() AS my_xid;
INSERT INTO acct VALUES (3, 100);
INSERT INTO acct VALUES (4, 100);
SELECT xmin, cmin, ctid, * FROM acct WHERE id IN (3, 4);
COMMIT;
SQL
EOF

step "2. UPDATE는 새 버전을 만든다"
pg <<'EOF'
psql -X <<'SQL'
BEGIN;
SELECT pg_current_xact_id() AS my_xid;
UPDATE acct SET balance = 150 WHERE id = 1;
COMMIT;
SELECT xmin, xmax, ctid, * FROM acct WHERE id = 1;
SELECT lp, t_xmin, t_xmax, t_ctid, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
SQL
EOF

step "3. DELETE와 ROLLBACK도 튜플을 지우지 않는다"
pg <<'EOF'
psql -X <<'SQL'
DELETE FROM acct WHERE id = 4;
BEGIN;
SELECT pg_current_xact_id() AS rollback_xid \gset
INSERT INTO acct VALUES (5, 100);
ROLLBACK;
SELECT * FROM acct ORDER BY id;
SELECT lp, t_xmin, t_xmax, t_ctid, t_data
FROM heap_page_items(get_raw_page('acct', 0));
SELECT :'rollback_xid' AS xid, pg_xact_status(:'rollback_xid'::xid8) AS status;
SQL
EOF

step "4. 커밋 여부는 pg_xact에 2비트로 적힌다"
pg <<'EOF'
ls -l $PGDATA/pg_xact
psql -X -c "SELECT x AS xid, pg_xact_status(x::text::xid8) AS status FROM generate_series(754, 758) x"
EOF

step "5. 스냅샷: 아직 커밋 안 된 트랜잭션은 보이지 않는다"
sess_start A
sess_start B
sess A "BEGIN;"
sess A "SELECT pg_current_xact_id() AS a_xid;"
sess A "UPDATE acct SET balance = 999 WHERE id = 2;"
pg <<'EOF'
psql -X -c "INSERT INTO acct VALUES (7, 100) RETURNING xmin AS other_xid"
EOF
sess A "SELECT pg_current_snapshot() AS a_snapshot, balance FROM acct WHERE id = 2;"
sess B "BEGIN;"
sess B "SELECT pg_current_snapshot() AS b_snapshot, balance FROM acct WHERE id = 2;"
sess A "COMMIT;"
sess B "SELECT pg_current_snapshot() AS b_snapshot, balance FROM acct WHERE id = 2;"
sess B "COMMIT;"

step "6. READ COMMITTED와 REPEATABLE READ"
sess B "BEGIN ISOLATION LEVEL REPEATABLE READ;"
sess B "SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;"
sess A "UPDATE acct SET balance = balance + 1000 WHERE id = 3;"
sess B "SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;"
sess B "COMMIT;"
sess B "SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;"

step "7. 같은 행을 동시에 고치면: READ COMMITTED"
sess A "BEGIN;"
sess A "UPDATE acct SET balance = balance + 10 WHERE id = 1 RETURNING balance;"
sess B "BEGIN;"
sess B "UPDATE acct SET balance = balance + 1 WHERE id = 1 RETURNING balance;" 2
pg <<'EOF'
psql -X <<'SQL'
SELECT pid, state, wait_event_type, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() ORDER BY pid;
SELECT locktype, transactionid, mode, granted, pid FROM pg_locks WHERE locktype = 'transactionid' ORDER BY granted DESC, pid;
SQL
EOF
sess A "COMMIT;"
sess_wait B
sess B "COMMIT;"

step "8. 같은 행을 동시에 고치면: REPEATABLE READ"
sess A "BEGIN;"
sess A "UPDATE acct SET balance = balance + 10 WHERE id = 1 RETURNING balance;"
sess B "BEGIN ISOLATION LEVEL REPEATABLE READ;"
sess B "SELECT balance FROM acct WHERE id = 1;"
sess B "UPDATE acct SET balance = balance + 1 WHERE id = 1 RETURNING balance;" 2
sess A "COMMIT;"
sess_wait B
sess B "ROLLBACK;"
sess_end A
sess_end B

step "9. SELECT FOR UPDATE도 xmax에 적힌다"
pg <<'EOF'
psql -X <<'SQL'
BEGIN;
SELECT pg_current_xact_id() AS locker_xid;
SELECT * FROM acct WHERE id = 3 FOR UPDATE;
SELECT xmin, xmax, * FROM acct WHERE id = 3;
SELECT lp, t_xmax, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_ctid = (SELECT ctid FROM acct WHERE id = 3);
COMMIT;
SQL
EOF

step "10. hint bit: 커밋 결과를 처음 확인한 쪽이 적어 둔다"
pg <<'EOF'
psql -X <<'SQL'
INSERT INTO acct VALUES (6, 100);
SELECT lp, t_xmin, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_data = (SELECT t_data FROM heap_page_items(get_raw_page('acct', 0)) ORDER BY lp DESC LIMIT 1);
SELECT * FROM acct WHERE id = 6;
SELECT lp, t_xmin, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_data = (SELECT t_data FROM heap_page_items(get_raw_page('acct', 0)) ORDER BY lp DESC LIMIT 1);
SQL
EOF

echo "done" | log
