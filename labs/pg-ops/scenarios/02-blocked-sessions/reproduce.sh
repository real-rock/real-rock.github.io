#!/bin/bash
# PostgreSQL 운영 2편(세션들이 멈춰 있다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
TREE="SELECT pid, application_name AS app, state, wait_event_type AS wtype, wait_event,
       pg_blocking_pids(pid) AS blocked_by, left(query, 45) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY xact_start NULLS LAST, pid;"

open_sessions() {
  for s in "$@"; do
    sess_start "$s"
    sess "$s" "SET application_name = 'app_$(echo "$s" | tr 'A-Z' 'a-z')';"
  done
}

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET log_lock_waits = on;"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "SELECT pg_reload_conf();"
q "CREATE TABLE orders (id int PRIMARY KEY, status text);"
q "INSERT INTO orders SELECT g, 'new' FROM generate_series(1, 3) g;"
q "SHOW deadlock_timeout;"

step "1. 행 락: 한 세션이 여러 세션을 막는다"
open_sessions A B C
sess A "BEGIN;"
sess A "UPDATE orders SET status = 'paid' WHERE id = 1;"
sess B "UPDATE orders SET status = 'canceled' WHERE id = 1;" 1
sess C "UPDATE orders SET status = 'shipped' WHERE id = 1;" 2
q "$TREE"
q "SELECT l.pid, a.application_name AS app, l.locktype, l.transactionid AS xid,
       l.page, l.tuple, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.locktype IN ('transactionid', 'tuple') AND a.application_name LIKE 'app_%'
ORDER BY l.granted DESC, l.pid;"
pg <<SH
$LOGTAIL | grep -E 'still waiting|Process holding|STATEMENT'
SH
note "로그의 relation, database는 OID로 찍힌다"
q "SELECT (SELECT oid FROM pg_class WHERE relname = 'orders') AS orders_oid,
       (SELECT oid FROM pg_database WHERE datname = 'postgres') AS postgres_oid;"
note "막고 있는 세션(A)은 idle in transaction이다. pg_cancel_backend는 실행 중인 쿼리가 없으니 소용이 없다"
q "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'app_a';"
sleep 1
q "$TREE"
q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'app_a';"
sleep 1
sess_wait B 1
sess_wait C 1
q "$TREE"
sess A "SELECT 1;"
q "SELECT id, status FROM orders WHERE id = 1;"
sess_end A; sess_end B; sess_end C

step "2. DDL이 만드는 락 큐"
open_sessions A B
sess A "BEGIN;"
sess A "SELECT count(*) FROM orders;"
sess B "ALTER TABLE orders ADD COLUMN note text;" 2
note "평범한 SELECT 5개를 띄운다"
pg <<'SH'
for i in 1 2 3 4 5; do PGAPPNAME=reader nohup psql -X -c "SELECT count(*) FROM orders" > /tmp/reader_$i.out 2>&1 & done
SH
sleep 2
q "$TREE"
q "SELECT l.pid, a.application_name AS app, l.mode, l.granted,
       now() - l.waitstart AS waiting
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.locktype = 'relation' AND l.relation = 'orders'::regclass
ORDER BY l.granted DESC, l.waitstart, l.pid;"
q "SELECT count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting,
       max(now() - query_start) FILTER (WHERE wait_event_type = 'Lock') AS longest_wait
FROM pg_stat_activity
WHERE backend_type = 'client backend';"
pg <<SH
$LOGTAIL | grep -E 'still waiting for AccessShareLock' | head -n 2
SH
note "A가 트랜잭션을 끝내면 줄이 한꺼번에 풀린다"
sess A "ROLLBACK;"
sess_wait B 2
pg <<'SH'
cat /tmp/reader_1.out
SH
sess_end A; sess_end B

step "3. lock_timeout으로 DDL이 줄을 막지 않게 한다"
open_sessions A B
sess A "BEGIN;"
sess A "SELECT count(*) FROM orders;"
sess B "SET lock_timeout = '2s';"
sess B "ALTER TABLE orders ADD COLUMN memo text;" 1
pg <<'SH'
for i in 1 2 3; do PGAPPNAME=reader nohup psql -X -c "SELECT count(*) FROM orders" > /tmp/reader2_$i.out 2>&1 & done
SH
sleep 0.5
q "$TREE"
sess_wait B 3
q "$TREE"
pg <<'SH'
cat /tmp/reader2_1.out
SH
sess A "ROLLBACK;"
note "A가 끝난 뒤 다시 시도하면 바로 성공한다"
sess B "ALTER TABLE orders ADD COLUMN memo text;"
sess_end A; sess_end B

step "4. deadlock"
open_sessions A B
sess A "BEGIN;"
sess A "UPDATE orders SET status = 'a' WHERE id = 1;"
sess B "BEGIN;"
sess B "UPDATE orders SET status = 'b' WHERE id = 2;"
sess A "UPDATE orders SET status = 'a' WHERE id = 2;" 1
sess B "UPDATE orders SET status = 'b' WHERE id = 1;" 2
sess_wait A 1
sess B "COMMIT;"
sess A "COMMIT;"
q "SELECT id, status FROM orders ORDER BY id;"
pg <<SH
$LOGTAIL | grep -A 6 -E 'ERROR:  deadlock detected'
SH
q "SELECT datname, deadlocks FROM pg_stat_database WHERE datname = 'postgres';"
sess_end A; sess_end B

docker rm -f "$CT" >/dev/null 2>&1
