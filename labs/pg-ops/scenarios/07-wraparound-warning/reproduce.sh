#!/bin/bash
# PostgreSQL 운영 7편(wraparound 경고가 떴다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 트랜잭션 ID를 20억 개 소모하는 대신, 서버를 멈추고 pg_resetwal -x로 다음 트랜잭션 ID를 한계 근처로 옮긴다.
# (실습용 조작이다. 운영 서버에서 pg_resetwal을 쓰면 데이터를 잃을 수 있다.)
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 3000 "$(ls -t $PGDATA/log/*.log | head -1)"'
AGES="SELECT datname, datfrozenxid, age(datfrozenxid) AS xid_age,
       2147483647 - age(datfrozenxid) AS until_wraparound
FROM pg_database ORDER BY age(datfrozenxid) DESC;"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET max_prepared_transactions = 10;"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET log_autovacuum_min_duration = 0;"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "CREATE TABLE orders (id bigserial PRIMARY KEY, amount int);"
q "CREATE TABLE jobs (id int PRIMARY KEY, state text);"
q "INSERT INTO jobs VALUES (1, 'new');"
q "SELECT name, setting FROM pg_settings
WHERE name IN ('autovacuum_freeze_max_age', 'vacuum_freeze_table_age', 'vacuum_failsafe_age')
ORDER BY name;"

step "1. 오래 남는 트랜잭션 하나"
sess_start C
sess C "BEGIN;"
sess C "UPDATE jobs SET state = 'running' WHERE id = 1;"
sess C "PREPARE TRANSACTION 'batch-77';"
sess_end C
q "$AGES"

step "2. (실습용) 다음 트랜잭션 ID를 한계 근처로 옮긴다"
pg <<'SH'
pg_ctl -D $PGDATA -w stop -m fast
pg_resetwal -x $((2045 * 1048576)) $PGDATA
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH

step "3. 경고 단계"
q "INSERT INTO orders (amount) VALUES (100);"
q "$AGES"
sleep 5
pg <<SH
$LOGTAIL | grep -E 'must be vacuumed within' | head -n 1
SH

step "4. 쓰기 거부"
pg <<'SH'
echo 'SELECT pg_current_xact_id();' > /tmp/xid.sql
pgbench -n -c 4 -t 40000 -f /tmp/xid.sql postgres 2>&1 | grep -v 'must be vacuumed\|To avoid\|You might' | tail -n 4
SH
q "INSERT INTO orders (amount) VALUES (200);"
q "SELECT count(*) FROM orders;"
q "$AGES"
pg <<SH
$LOGTAIL | grep -E 'not accepting commands' | tail -n 1
SH

step "5. 원인 찾기"
q "SELECT 'session' AS kind, pid::text AS id, age(backend_xid) AS xid_age, age(backend_xmin) AS xmin_age
FROM pg_stat_activity WHERE (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL) AND pid <> pg_backend_pid()
UNION ALL
SELECT 'prepared', gid, age(transaction), NULL FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, age(xmin), age(catalog_xmin) FROM pg_replication_slots
ORDER BY 3 DESC NULLS LAST;"
q "SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age
FROM pg_class c WHERE c.relkind IN ('r', 't', 'm')
ORDER BY age(c.relfrozenxid) DESC LIMIT 3;"

step "6. 조치"
q "ROLLBACK PREPARED 'batch-77';"
q "VACUUM (VERBOSE) orders;"
pg <<'SH'
vacuumdb --all > /tmp/vacuumdb.log 2>&1
grep -E '^vacuumdb:' /tmp/vacuumdb.log
grep -m 1 -A 3 'bypassing nonessential' /tmp/vacuumdb.log
grep -c 'bypassing nonessential' /tmp/vacuumdb.log
SH
q "$AGES"
q "INSERT INTO orders (amount) VALUES (250);"
note "template0은 접속을 받지 않으므로 vacuumdb --all이 건너뛴다. autovacuum이 처리할 때까지 기다린다"
start=$(date +%s)
for i in $(seq 1 60); do
  sleep 5
  a=$(docker exec "$CT" psql -XAtc "SELECT max(age(datfrozenxid)) FROM pg_database")
  [ "$a" -lt 1000000000 ] && break
done
note "기다린 시간: $(( $(date +%s) - start ))초"
pg <<SH
$LOGTAIL | grep -E 'automatic aggressive vacuum to prevent wraparound of table "template0' | head -n 2
SH
q "$AGES"
q "INSERT INTO orders (amount) VALUES (300);"
q "SELECT count(*) FROM orders;"

docker rm -f "$CT" >/dev/null 2>&1
