#!/bin/bash
# PostgreSQL 인터널 9편(스트리밍 복제와 replication slot) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 한 컨테이너 안에 primary(포트 5432)와 standby(포트 5433) 두 클러스터를 띄운다.
cd "$(dirname "$0")"
source ../common/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
cat >> $PGDATA/postgresql.conf <<'CONF'
log_line_prefix = '%m [%p] %b '
cluster_name = 'primary'
CONF
pg_ctl -D $PGDATA -l /home/postgres/primary.log start
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, pad text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, repeat('p', 200) FROM generate_series(1, 200000) g"
EOF

step "1. standby 만들기: pg_basebackup -R"
pg <<'EOF'
pg_basebackup -D /home/postgres/standby -R -C -S standby1 -c fast && echo "base backup ok"
ls /home/postgres/standby/standby.signal
cat /home/postgres/standby/postgresql.auto.conf
cat >> /home/postgres/standby/postgresql.auto.conf <<'CONF'
port = 5433
cluster_name = 'standby1'
CONF
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 1
grep -E "entering standby mode|redo starts|consistent recovery state|ready to accept read-only|started streaming" /home/postgres/standby.log | cut -c1-160
EOF

step "2. 복제를 담당하는 프로세스"
pg <<'EOF'
ps -eo pid,args | grep -E "postgres: (primary|standby1): (walsender|walreceiver|startup)" | grep -v grep
EOF

step "3. pg_stat_replication과 pg_stat_wal_receiver"
pg <<'EOF'
psql -X -p 5432 -x -c "SELECT pid, application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag, sync_state FROM pg_stat_replication"
psql -X -p 5433 -x -c "SELECT pid, status, receive_start_lsn, written_lsn, flushed_lsn, slot_name FROM pg_stat_wal_receiver"
psql -X -p 5432 -At -c "SELECT 'primary: in_recovery=' || pg_is_in_recovery()"
psql -X -p 5433 -At -c "SELECT 'standby: in_recovery=' || pg_is_in_recovery()"
EOF

step "4. primary의 변경이 standby에 보인다, standby는 읽기 전용"
pg <<'EOF'
psql -X -p 5432 -q -c "INSERT INTO acct VALUES (200001, 1, 'from primary')"
psql -X -p 5432 -c "SELECT pg_current_wal_lsn() AS primary_lsn"
sleep 1
psql -X -p 5433 -c "SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed"
psql -X -p 5433 -c "SELECT * FROM acct WHERE id = 200001"
psql -X -p 5433 -c "INSERT INTO acct VALUES (200002, 1, 'from standby')"
EOF

step "5. 전송, 기록, 재생: 재생만 늦추면"
pg <<'EOF'
psql -X -p 5433 -q -c "ALTER SYSTEM SET recovery_min_apply_delay = '5s'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 1
psql -X -p 5432 -q -c "INSERT INTO acct VALUES (200003, 1, 'delayed')"
sleep 1
psql -X -p 5432 -x -c "SELECT pg_current_wal_lsn() AS primary_lsn, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication"
psql -X -p 5433 -c "SELECT count(*) AS delayed_row_visible FROM acct WHERE id = 200003"
sleep 6
psql -X -p 5433 -c "SELECT count(*) AS delayed_row_visible FROM acct WHERE id = 200003"
psql -X -p 5432 -x -c "SELECT replay_lsn, replay_lag FROM pg_stat_replication"
psql -X -p 5433 -q -c "ALTER SYSTEM RESET recovery_min_apply_delay" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "6. 동기 복제: 커밋이 standby를 기다린다"
pg <<'EOF'
psql -X -p 5432 -q -c "ALTER SYSTEM SET synchronous_standby_names = 'standby1'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 1
psql -X -p 5432 -c "SELECT application_name, sync_state FROM pg_stat_replication"
psql -X -p 5432 -c "\timing on" -c "INSERT INTO acct VALUES (200004, 1, 'sync ok')"
pg_ctl -D /home/postgres/standby stop -m fast
EOF
sess_start A "-p 5432"
sess A "INSERT INTO acct VALUES (200005, 1, 'sync wait');" 3
pg <<'EOF'
psql -X -p 5432 -c "SELECT pid, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
psql -X -p 5432 -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
EOF
sess_wait A 1
sess_end A
pg <<'EOF'
psql -X -p 5432 -c "SELECT * FROM acct WHERE id = 200005"
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 1
psql -X -p 5433 -c "SELECT * FROM acct WHERE id = 200005"
psql -X -p 5432 -q -c "ALTER SYSTEM RESET synchronous_standby_names" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "7. standby 쿼리와 WAL 재생의 충돌"
pg <<'EOF'
psql -X -p 5433 -c "SHOW max_standby_streaming_delay" -c "SHOW hot_standby_feedback"
psql -X -p 5433 -q -c "ALTER SYSTEM SET max_standby_streaming_delay = '3s'" -c "SELECT pg_reload_conf()" > /dev/null
EOF
sess_start B "-p 5433"
sess B "SELECT count(*), pg_sleep(20) FROM acct;" 1
pg <<'EOF'
psql -X -p 5432 -q -c "DELETE FROM acct WHERE id > 200000"
psql -X -p 5432 -q -c "VACUUM acct"
EOF
sess_wait B 6
pg <<'EOF'
grep -E "conflict with recovery|recovery conflict" /home/postgres/standby.log | tail -3 | cut -c1-200
psql -X -p 5433 -c "SELECT datname, confl_snapshot FROM pg_stat_database_conflicts WHERE datname = 'postgres'"
psql -X -p 5433 -q -c "ALTER SYSTEM RESET max_standby_streaming_delay" -c "SELECT pg_reload_conf()" > /dev/null
EOF
sess_end B

step "8. replication slot은 standby가 멈춰도 WAL을 붙잡는다"
pg <<'EOF'
psql -X -p 5432 -q -c "ALTER SYSTEM SET max_wal_size = '64MB'" -c "SELECT pg_reload_conf()" > /dev/null
pg_ctl -D /home/postgres/standby stop -m fast
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, pg_size_pretty(safe_wal_size) AS safe_wal_size FROM pg_replication_slots"
for i in 1 2 3; do psql -X -p 5432 -q -c "UPDATE acct SET balance = balance + 1"; done
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots"
du -sh $PGDATA/pg_wal
EOF

step "9. max_slot_wal_keep_size: 너무 많이 붙잡으면 slot을 포기한다"
pg <<'EOF'
psql -X -p 5432 -q -c "ALTER SYSTEM SET max_slot_wal_keep_size = '128MB'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -p 5432 -q -c "UPDATE acct SET balance = balance + 1"
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, invalidation_reason FROM pg_replication_slots"
grep -E "invalidating obsolete replication slot|exceeds the limit" /home/postgres/primary.log | cut -c1-200
du -sh $PGDATA/pg_wal
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 2
grep -E "could not start WAL streaming" /home/postgres/standby.log | tail -1 | cut -c1-200
EOF

step "10. idle_replication_slot_timeout (PG18)"
pg <<'EOF'
psql -X -p 5432 -c "SELECT * FROM pg_create_physical_replication_slot('forgotten', true)"
psql -X -p 5432 -q -c "ALTER SYSTEM SET idle_replication_slot_timeout = '1s'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 2
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, inactive_since IS NOT NULL AS has_inactive_since, wal_status, invalidation_reason FROM pg_replication_slots ORDER BY slot_name"
grep -E "invalidating obsolete replication slot \"forgotten\"" -A1 /home/postgres/primary.log | cut -c1-200
EOF

echo "done" | log
