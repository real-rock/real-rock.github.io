#!/bin/bash
# PostgreSQL 운영 4편(긴 트랜잭션과 idle in transaction) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
HOLDERS="SELECT 'session' AS kind, pid::text AS id, state,
       age(backend_xid) AS xid_age, age(backend_xmin) AS xmin_age, xact_start
FROM pg_stat_activity
WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
UNION ALL
SELECT 'prepared', gid, NULL, age(transaction), NULL, prepared
FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, NULL, age(xmin), age(catalog_xmin), NULL
FROM pg_replication_slots
ORDER BY 4 DESC NULLS LAST, 5 DESC NULLS LAST;"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET max_prepared_transactions = 10;"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "CREATE TABLE t (id int PRIMARY KEY, v int);"
q "INSERT INTO t SELECT g, 0 FROM generate_series(1, 10000) g;"
q "CREATE TABLE jobs (id int PRIMARY KEY, state text);"
q "INSERT INTO jobs VALUES (1, 'new'), (2, 'new'), (3, 'new');"
note "VACUUM 결과를 일정하게 보려고 t의 autovacuum을 끄고 직접 VACUUM한다"
q "ALTER TABLE t SET (autovacuum_enabled = false);"
q "VACUUM t;"

step "1. 트랜잭션 세 개를 열어 둔다"
note "C: 2단계 커밋의 첫 단계(PREPARE TRANSACTION)까지만 하고 세션을 닫는다"
sess_start C
sess C "BEGIN;"
sess C "UPDATE jobs SET state = 'running' WHERE id = 3;"
sess C "PREPARE TRANSACTION 'batch-42';"
sess_end C
note "A: REPEATABLE READ로 읽기만 하고 멈춘다"
sess_start A
sess A "SET application_name = 'report';"
sess A "BEGIN ISOLATION LEVEL REPEATABLE READ;"
sess A "SELECT count(*) FROM t;"
note "B: 행 하나를 고치고 멈춘다"
sess_start B
sess B "SET application_name = 'worker';"
sess B "BEGIN;"
sess B "UPDATE jobs SET state = 'running' WHERE id = 1;"

step "2. 증상: VACUUM이 dead tuple을 지우지 못한다"
for i in 1 2 3 4 5; do q "UPDATE t SET v = v + 1;"; done
q "SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
FROM pg_stat_user_tables WHERE relname = 't';"
q "VACUUM (VERBOSE) t;"
q "SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
FROM pg_stat_user_tables WHERE relname = 't';"

step "3. 누가 xmin horizon을 붙잡고 있는가"
q "SELECT pid, application_name AS app, state, backend_xid, backend_xmin,
       age(backend_xmin) AS xmin_age, now() - xact_start AS xact_age
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY xact_start;"
q "$HOLDERS"

step "4. 세션을 끊는다"
q "SELECT pid, application_name, pg_terminate_backend(pid)
FROM pg_stat_activity WHERE application_name IN ('report', 'worker');"
sleep 1
q "VACUUM (VERBOSE) t;"
note "세션은 모두 끊었는데 여전히 지우지 못한다"
q "SELECT count(*) AS sessions FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();"
q "$HOLDERS"
q "SELECT gid, prepared, owner, database, age(transaction) AS xid_age FROM pg_prepared_xacts;"
note "prepared transaction은 재시작해도 남는다"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "SELECT gid, prepared, age(transaction) AS xid_age FROM pg_prepared_xacts;"
q "SELECT locktype, relation::regclass, mode, granted, virtualtransaction
FROM pg_locks WHERE virtualtransaction LIKE '-1/%';"
q "ROLLBACK PREPARED 'batch-42';"
q "VACUUM (VERBOSE) t;"
q "SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('t')) AS size
FROM pg_stat_user_tables WHERE relname = 't';"

step "5. 예방: idle_in_transaction_session_timeout, transaction_timeout"
sess_start D
sess D "SET application_name = 'forgetful';"
sess D "SET idle_in_transaction_session_timeout = '3s';"
sess D "BEGIN;"
sess D "SELECT count(*) FROM t;"
sleep 4
sess D "SELECT 1;"
sess_end D
sess_start E
sess E "SET application_name = 'slowbatch';"
sess E "SET transaction_timeout = '3s';"
sess E "BEGIN;"
sess E "SELECT pg_sleep(1);" 2
sess E "SELECT pg_sleep(5);" 4
sess E "SELECT 1;"
sess_end E
pg <<SH
$LOGTAIL | grep -E 'idle-in-transaction timeout|transaction timeout'
SH
q "SELECT name, setting, unit FROM pg_settings
WHERE name IN ('idle_in_transaction_session_timeout', 'transaction_timeout', 'statement_timeout', 'idle_session_timeout')
ORDER BY name;"

docker rm -f "$CT" >/dev/null 2>&1
