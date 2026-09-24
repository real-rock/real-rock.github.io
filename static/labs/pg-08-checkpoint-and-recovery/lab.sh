#!/bin/bash
# PostgreSQL 인터널 8편(체크포인트와 장애 복구) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../common/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
cat >> $PGDATA/postgresql.conf <<'CONF'
log_line_prefix = '%m [%p] %b '
CONF
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_walinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, pad text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, repeat('p', 200) FROM generate_series(1, 200000) g"
EOF

step "1. pg_control: 서버가 기억하는 마지막 체크포인트"
pg <<'EOF'
pg_controldata $PGDATA | grep -E "cluster state|Latest checkpoint location|Latest checkpoint's REDO location|Latest checkpoint's REDO WAL file|Time of latest checkpoint"
psql -X -c "SHOW checkpoint_timeout" -c "SHOW max_wal_size" -c "SHOW checkpoint_completion_target" -c "SHOW log_checkpoints"
EOF

step "2. 수동 CHECKPOINT"
pg <<'EOF'
psql -X -q -c "UPDATE acct SET balance = balance + 1 WHERE id <= 50000"
psql -X -c "SELECT num_timed, num_requested, num_done, buffers_written FROM pg_stat_checkpointer"
psql -X -c "SELECT pg_current_wal_insert_lsn() AS before_checkpoint"
psql -X -q -c "CHECKPOINT"
grep -E "checkpoint (starting|complete)" /home/postgres/server.log | tail -2
pg_controldata $PGDATA | grep -E "Latest checkpoint location|Latest checkpoint's REDO location"
psql -X -c "SELECT num_timed, num_requested, num_done, buffers_written FROM pg_stat_checkpointer"
EOF

step "3. WAL 안의 체크포인트 레코드"
pg <<'EOF'
R=$(pg_controldata $PGDATA | awk -F': *' '/REDO location/ {print $2}')
C=$(pg_controldata $PGDATA | awk -F': *' '/Latest checkpoint location/ {print $2}')
echo "REDO=$R CHECKPOINT=$C"
psql -X -c "SELECT start_lsn, resource_manager AS rmgr, record_type, record_length AS len, left(description, 90) AS description FROM pg_get_wal_records_info('$R', pg_current_wal_insert_lsn())"
EOF

step "4. WAL이 많이 쌓여도 체크포인트가 일어난다"
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET max_wal_size = '64MB'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -c "SHOW max_wal_size"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
sleep 2
grep -E "checkpoint starting|checkpoints are occurring too frequently" /home/postgres/server.log | tail -4 | cut -c1-140
psql -X -c "SELECT num_timed, num_requested, num_done FROM pg_stat_checkpointer"
psql -X -q -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "5. 시간 기준 체크포인트는 쓰기를 나눠서 한다"
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET checkpoint_timeout = '30s'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -c "CHECKPOINT"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
for i in $(seq 1 120); do
  grep -A1 "checkpoint starting: time" /home/postgres/server.log | grep -q "checkpoint complete" && break
  sleep 1
done
grep -A1 "checkpoint starting: time" /home/postgres/server.log | head -2 | cut -c1-230
psql -X -q -c "ALTER SYSTEM RESET checkpoint_timeout" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "6. 장애 복구: 마지막 체크포인트부터 WAL을 다시 적용한다"
pg <<'EOF'
psql -X -c "SELECT sum(balance) AS total, count(*) FROM acct"
psql -X -q -c "CHECKPOINT"
psql -X -q -c "UPDATE acct SET balance = balance + 1 WHERE id <= 100000"
psql -X -q -c "INSERT INTO acct VALUES (300001, 777, 'after checkpoint')"
psql -X -c "SELECT pg_current_wal_insert_lsn() AS insert_lsn, pg_current_wal_flush_lsn() AS flush_lsn"
pg_controldata $PGDATA | grep -E "Latest checkpoint's REDO location"
pg_ctl -D $PGDATA stop -m immediate
pg_controldata $PGDATA | grep -E "cluster state"
EOF
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
sed -n '/database system was interrupted/,/database system is ready/p' /home/postgres/server.log | tail -12 | cut -c1-220
psql -X -c "SELECT sum(balance) AS total, count(*) FROM acct"
psql -X -c "SELECT * FROM acct WHERE id = 300001"
pg_controldata $PGDATA | grep -E "cluster state"
EOF

step "7. 복구 시간은 마지막 체크포인트 이후 WAL 양에 비례한다"
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET max_wal_size = '4GB'" -c "ALTER SYSTEM SET checkpoint_timeout = '1h'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -c "CHECKPOINT"
for i in 1 2 3 4 5; do psql -X -q -c "UPDATE acct SET balance = balance + 1"; done
psql -X -c "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), (SELECT redo_lsn FROM pg_control_checkpoint()))) AS wal_since_redo"
pg_ctl -D $PGDATA stop -m immediate
pg_ctl -D $PGDATA -l /home/postgres/server.log start
grep -E "redo starts|redo done" /home/postgres/server.log | tail -2 | cut -c1-200
EOF

step "8. PITR: 백업과 보관한 WAL로 원하는 시점까지만 복구한다"
pg <<'EOF'
mkdir -p /home/postgres/archive
psql -X -q -c "ALTER SYSTEM RESET ALL" -c "ALTER SYSTEM SET archive_mode = on" -c "ALTER SYSTEM SET archive_command = 'cp %p /home/postgres/archive/%f'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart > /dev/null
pg_basebackup -D /home/postgres/backup -c fast && echo "base backup ok"
ls /home/postgres/backup | tr '\n' ' '; echo
cat /home/postgres/backup/backup_label
psql -X -q -c "INSERT INTO acct VALUES (400001, 1, 'before mistake')"
psql -X -c "SELECT pg_create_restore_point('before_drop')"
psql -X -q -c "DROP TABLE acct"
psql -X -q -c "SELECT pg_switch_wal()" > /dev/null
sleep 2
psql -X -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver"
ls /home/postgres/archive
EOF
pg <<'EOF'
cat >> /home/postgres/backup/postgresql.auto.conf <<'CONF'
port = 5433
restore_command = 'cp /home/postgres/archive/%f %p'
recovery_target_name = 'before_drop'
recovery_target_action = 'promote'
CONF
touch /home/postgres/backup/recovery.signal
pg_ctl -D /home/postgres/backup -l /home/postgres/pitr.log start
sleep 2
grep -E "starting point-in-time|redo starts|restored log file|recovery stopping|redo done|selected new timeline|archive recovery complete|ready to accept" /home/postgres/pitr.log | cut -c1-200
psql -X -p 5433 -c "SELECT count(*), max(id) FROM acct"
psql -X -p 5432 -c "SELECT count(*) FROM acct"
ls /home/postgres/backup/pg_wal
cat /home/postgres/backup/pg_wal/00000002.history
EOF

echo "done" | log
