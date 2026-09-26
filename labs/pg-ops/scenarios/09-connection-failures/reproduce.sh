#!/bin/bash
# PostgreSQL 운영 9편(접속이 안 된다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
USAGE="SELECT usename, application_name AS app, state, count(*)
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3 ORDER BY 4 DESC;"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET max_connections = 20;"
q "ALTER SYSTEM SET reserved_connections = 2;"
q "ALTER SYSTEM SET listen_addresses = '*';"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET log_connections = 'authorization,setup_durations';"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "SELECT name, setting FROM pg_settings
WHERE name IN ('max_connections', 'superuser_reserved_connections', 'reserved_connections', 'log_connections')
ORDER BY name;"
q "CREATE ROLE app LOGIN;"
q "CREATE ROLE monitor LOGIN;"
q "GRANT pg_use_reserved_connections TO monitor;"

step "1. 슬롯이 찬다"
note "애플리케이션이 커넥션을 15개 열어 두고 쓰지 않는다 (커넥션 누수)"
pg <<'SH'
for i in $(seq 1 15); do nohup bash -c 'sleep 900 | psql -X -U app -d postgres -v ON_ERROR_STOP=1 >/dev/null' >/dev/null 2>&1 & done
sleep 2
SH
q "$USAGE"
pg <<'SH'
psql -X -U app -d postgres -c 'SELECT 1'
SH
pg <<'SH'
psql -X -U monitor -d postgres -c 'SELECT 1'
SH
note "monitor도 2개를 열어 두면"
pg <<'SH'
for i in 1 2; do nohup bash -c 'sleep 900 | psql -X -U monitor -d postgres >/dev/null' >/dev/null 2>&1 & done
sleep 1
psql -X -U monitor -d postgres -c 'SELECT 1'
SH
q "SELECT count(*) AS used, current_setting('max_connections') AS max FROM pg_stat_activity WHERE backend_type = 'client backend';"
note "슈퍼유저 슬롯 3개까지 누군가 차지하면"
pg <<'SH'
for i in 1 2 3; do nohup bash -c 'sleep 900 | psql -X -U postgres -d postgres >/dev/null' >/dev/null 2>&1 & done
sleep 1
psql -X -c 'SELECT 1'
SH
pg <<SH
$LOGTAIL | grep -E 'too many clients|reserved for' | tail -n 3
SH

step "2. 들어갈 수 없을 때: OS에서 idle 세션 하나를 끝낸다"
pg <<'SH'
ps -u postgres -o pid,cmd | grep 'postgres: app postgres \[local\] idle' | grep -v grep | head -n 3
SH
pg <<'SH'
kill -TERM $(ps -u postgres -o pid,cmd | grep 'postgres: app postgres \[local\] idle' | grep -v grep | head -n 1 | awk '{print $1}')
sleep 1
SH
q "$USAGE"
q "SELECT pid, usename, state, now() - state_change AS idle_for, backend_start
FROM pg_stat_activity WHERE usename = 'app' ORDER BY backend_start LIMIT 3;"
q "SELECT count(pg_terminate_backend(pid)) AS terminated
FROM pg_stat_activity
WHERE usename IN ('app', 'monitor') AND state = 'idle' AND state_change < now() - interval '5 seconds';"
q "SELECT count(*) AS used FROM pg_stat_activity WHERE backend_type = 'client backend';"

step "3. idle_session_timeout"
q "ALTER ROLE app SET idle_session_timeout = '3s';"
sess_start X "-U app -d postgres"
sess X "SELECT current_user;"
sleep 4
sess X "SELECT 1;"
sess_end X
pg <<SH
$LOGTAIL | grep -E 'idle-session timeout' | tail -n 1
SH
q "ALTER ROLE app RESET idle_session_timeout;"

step "4. pg_hba.conf와 인증"
pg <<'SH'
hostname -i
SH
pg <<'SH'
psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
SH
pg <<SH
$LOGTAIL | grep -A 1 -E 'no pg_hba.conf entry' | tail -n 2
SH
q "SELECT line_number, type, database, user_name, address, auth_method
FROM pg_hba_file_rules ORDER BY line_number;"
pg <<'SH'
echo 'host all app samenet scram-sha-256' >> $PGDATA/pg_hba.conf
SH
q "SELECT pg_reload_conf();"
q "SELECT line_number, type, database, user_name, address, auth_method
FROM pg_hba_file_rules WHERE user_name @> '{app}';"
note "아직 app에 비밀번호가 없다"
pg <<'SH'
PGPASSWORD=wrong psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
SH
pg <<SH
$LOGTAIL | grep -A 1 -E 'password authentication failed' | tail -n 2
SH
note "비밀번호는 컨테이너 안에서 무작위로 만든다"
pg <<'SH'
head -c 18 /dev/urandom | base64 > /var/lib/pgsql/app.pw
echo "ALTER ROLE app PASSWORD :'pw';" | psql -X -q -v pw="$(cat /var/lib/pgsql/app.pw)"
SH
pg <<'SH'
PGPASSWORD=wrong psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT 1'
SH
pg <<SH
$LOGTAIL | grep -A 1 -E 'password authentication failed' | tail -n 2
SH
pg <<'SH'
PGPASSWORD="$(cat /var/lib/pgsql/app.pw)" psql -X -h $(hostname -i) -U app -d postgres -c 'SELECT current_user, inet_server_addr()'
SH
pg <<SH
$LOGTAIL | grep -E 'connection authenticated|connection authorized|connection ready' | tail -n 3
SH

step "5. 커넥션을 맺는 비용"
pg <<'SH'
pgbench -i -s 1 -q postgres 2>&1 | tail -n 1
SH
pg <<'SH'
pgbench -n -S -c 4 -T 5 postgres 2>&1 | grep -E 'number of transactions actually|average connection time|tps'
SH
pg <<'SH'
pgbench -n -S -c 4 -T 5 -C postgres 2>&1 | grep -E 'number of transactions actually|average connection time|tps'
SH

docker rm -f "$CT" >/dev/null 2>&1
