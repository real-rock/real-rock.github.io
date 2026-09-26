#!/bin/bash
# PostgreSQL 인터널 1편(프로세스 구조) 실습을 새 컨테이너에서 처음부터 끝까지 실행한다.
# 각 명령은 "$ 명령" 다음에 stdout+stderr와 종료 코드를 그대로 남긴다.
cd "$(dirname "$0")"
OUT=final-run.log
: > "$OUT"

log() { tee -a "$OUT"; }
step() { printf '\n######## %s\n\n' "$1" | log; }

# 호스트에서 실행하는 명령
host() {
  { echo "\$ $1"; bash -c "$1" 2>&1; echo "[exit=$?]"; echo; } | log
}

# 컨테이너 안(postgres 사용자)에서 실행하는 명령. 표준입력으로 스크립트를 받는다.
pg() {
  local script; script=$(cat)
  {
    echo "$script" | sed 's/^/$ /'
    printf '%s\n' "$script" | docker exec -i pglab bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

step "0. 실습 환경"
docker rm -f pglab >/dev/null 2>&1
host "docker run -d --init --name pglab --hostname pglab pg-internals:rocky9-rel18 sleep infinity"
pg <<'EOF'
cat /etc/rocky-release
postgres --version
initdb -D $PGDATA > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
EOF

step "1. 서버 시작 직후의 프로세스 트리"
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
EOF
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
EOF
pg <<'EOF'
head -1 $PGDATA/postmaster.pid
cat /home/postgres/server.log
EOF

step "2. pg_stat_activity의 backend_type"
pg <<'EOF'
psql -X -c "SELECT pid, backend_type FROM pg_stat_activity ORDER BY pid"
EOF

step "3. 접속할 때마다 backend가 하나씩 생긴다"
pg <<'EOF'
psql -X -q <<'SQL'
ALTER SYSTEM SET log_line_prefix = '%m [%p] %b ';
ALTER SYSTEM SET log_connections = 'receipt,authentication,authorization,setup_durations';
ALTER SYSTEM SET log_disconnections = on;
SELECT pg_reload_conf();
SQL
EOF
host "docker exec -d pglab bash -c 'sleep 3600 | psql -X -q -h 127.0.0.1'"
host "docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'"
host "docker exec -d pglab bash -c 'psql -X -c \"SELECT pg_sleep(3600)\"'"
sleep 2
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
EOF
pg <<'EOF'
psql -X -c "SELECT pid, backend_type, client_addr, state, query FROM pg_stat_activity WHERE backend_type = 'client backend' ORDER BY pid"
EOF
pg <<'EOF'
grep -E 'connection (received|authenticated|authorized|ready)' /home/postgres/server.log | head -8
EOF

step "4. io worker 수를 재시작 없이 바꾸기"
pg <<'EOF'
psql -X -c "SHOW io_method" -c "SHOW io_workers"
EOF
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET io_workers = 5" -c "SELECT pg_reload_conf()"
sleep 1
ps -u postgres -o pid,ppid,cmd | grep 'io worker' | grep -v grep
EOF
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM RESET io_workers" -c "SELECT pg_reload_conf()"
sleep 1
ps -u postgres -o pid,ppid,cmd | grep 'io worker' | grep -v grep
EOF

step "5. autovacuum launcher가 worker를 요청하는 모습"
pg <<'EOF'
psql -X -q <<'SQL'
ALTER SYSTEM SET autovacuum_naptime = '1s';
ALTER SYSTEM SET log_autovacuum_min_duration = 0;
SELECT pg_reload_conf();
CREATE TABLE av_test AS SELECT g AS id, 0 AS v FROM generate_series(1, 200000) g;
UPDATE av_test SET v = 1;
SQL
for i in $(seq 1 1000); do
  ps -u postgres -o pid,ppid,cmd | grep 'autovacuum worker' | grep -v grep && break
  sleep 0.01
done
sleep 3
grep -E 'autovacuum worker LOG:  automatic (vacuum|analyze) of table "postgres.public.av_test"' /home/postgres/server.log | cut -c1-120
EOF
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM RESET autovacuum_naptime" -c "ALTER SYSTEM RESET log_autovacuum_min_duration" -c "SELECT pg_reload_conf()"
EOF

step "6. max_connections를 넘으면: 먼저 fork하고 나중에 거절한다"
host "docker exec pglab pkill -f 'sleep 3600'"
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET max_connections = 5" -c "ALTER SYSTEM SET superuser_reserved_connections = 0"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
EOF
for i in 1 2 3 4 5; do docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'; done
echo "\$ for i in 1 2 3 4 5; do docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'; done" | log
sleep 2
pg <<'EOF'
psql -X -c "SELECT 1"
EOF
pg <<'EOF'
grep -B1 'too many clients' /home/postgres/server.log
EOF
host "docker exec pglab pkill -f 'sleep 3600'"
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM RESET max_connections" -c "ALTER SYSTEM RESET superuser_reserved_connections"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
EOF

step "7. 정상 종료(pg_terminate_backend)와 비정상 종료(kill -9)"
host "docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'"
host "docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'"
host "docker exec -d pglab bash -c 'psql -X -c \"SELECT pg_sleep(3600)\" > /home/postgres/neighbor.out 2>&1'"
sleep 2
pg <<'EOF'
psql -X -q -c "CREATE TABLE t AS SELECT generate_series(1, 1000) AS id"
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
EOF
pg <<'EOF'
VICTIM=$(pgrep -f 'postgres: postgres postgres \[local\] idle' | head -1)
echo "pg_terminate_backend($VICTIM)"
psql -X -c "SELECT pg_terminate_backend($VICTIM)"
sleep 1
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
grep "\[$VICTIM\]" /home/postgres/server.log | tail -2
EOF
pg <<'EOF'
VICTIM=$(pgrep -f 'postgres: postgres postgres \[local\] idle' | head -1)
echo "kill -9 $VICTIM"
kill -9 $VICTIM
sleep 2
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
EOF
pg <<'EOF'
sed -n '/terminated by signal 9/,$p' /home/postgres/server.log
EOF
pg <<'EOF'
cat /home/postgres/neighbor.out
EOF
pg <<'EOF'
psql -X -c "SELECT count(*) FROM t"
EOF

step "8. 일반 backend가 walsender로 바뀌는 경우"
host "docker exec pglab pkill -f 'sleep 3600'"
host "docker exec -d pglab bash -c 'mkdir -p /home/postgres/wal && pg_receivewal -D /home/postgres/wal'"
sleep 2
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
ps -o pid,ppid,cmd -C pg_receivewal
EOF
pg <<'EOF'
WS=$(pgrep -f 'postgres: walsender')
grep "\[$WS\]" /home/postgres/server.log
psql -X -c "SELECT pid, backend_type, application_name, state FROM pg_stat_activity WHERE backend_type = 'walsender'"
EOF
host "docker exec pglab pkill pg_receivewal"

step "9. 공유 메모리는 모든 프로세스에 같은 주소로 붙어 있다"
pg <<'EOF'
psql -X -c "SHOW shared_buffers" -c "SHOW shared_memory_size" -c "SHOW shared_memory_type"
EOF
pg <<'EOF'
psql -X -q -c "CREATE TABLE big AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 150000) g"
psql -X -c "SELECT pg_size_pretty(pg_relation_size('big'))"
EOF
host "docker exec -d pglab bash -c '(echo \"SELECT count(*) FROM big;\"; sleep 3600) | psql -X -q > /dev/null'"
host "docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'"
sleep 2
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid)
for p in $PM $(pgrep -f 'postgres: postgres postgres \[local\] idle'); do
  echo "== PID $p  $(ps -o cmd= -p $p)"
  grep ' rw-s ' /proc/$p/maps | awk '{print "   ", $1, $6, $7}'
done
EOF
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid)
for p in $PM $(pgrep -f 'postgres: postgres postgres \[local\] idle'); do
  echo "== PID $p  $(ps -o cmd= -p $p)"
  grep -E '^(VmRSS|RssAnon|RssShmem)' /proc/$p/status
done
EOF

step "10. 설정에 따라 생기는 프로세스: logger, archiver"
host "docker exec pglab pkill -f 'sleep 3600'"
pg <<'EOF'
mkdir -p /home/postgres/archive
psql -X -q <<'SQL'
ALTER SYSTEM SET logging_collector = on;
ALTER SYSTEM SET archive_mode = on;
ALTER SYSTEM SET archive_command = 'cp %p /home/postgres/archive/%f';
SQL
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
sleep 1
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
EOF
pg <<'EOF'
psql -X -c "SELECT pid, backend_type FROM pg_stat_activity ORDER BY pid"
EOF

step "11. postmaster가 죽으면"
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid)
echo "kill -9 $PM (postmaster)"
kill -9 $PM
sleep 2
ps -u postgres -o pid,ppid,stat,cmd | grep -v -e 'ps -u' -e 'sleep infinity'
EOF
pg <<'EOF'
psql -X -c "SELECT 1"
EOF
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
sleep 1
tail -n 8 $PGDATA/log/$(ls -t $PGDATA/log | head -1)
EOF

echo "done" | log
