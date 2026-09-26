#!/bin/bash
# 1편 "컨테이너에서는 PID 1이 좀비를 치워야 한다": --init 없이 sleep을 PID 1로 두고 postmaster를 죽이면
# 좀비가 된 postmaster의 PID 때문에 재기동이 거부되는 장면을 재현한다.
cd "$(dirname "$0")"
CT=pglab-noinit OUT=zombie-run.log
source ../lib/labkit.sh

step "0. --init 없이 컨테이너 띄우기"
docker rm -f "$CT" >/dev/null 2>&1
host "docker run -d --name $CT --hostname $CT $IMAGE sleep infinity"
pg <<'EOF'
initdb -D $PGDATA > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "ALTER SYSTEM SET log_line_prefix = '%m [%p] %b '" -c "SELECT pg_reload_conf()" > /dev/null
EOF

step "1. postmaster를 kill -9"
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid)
echo "kill -9 $PM (postmaster)"
kill -9 $PM
sleep 2
ps -eo pid,ppid,stat,cmd | grep -v -e 'ps -eo' -e grep
EOF

step "2. 재기동"
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
sleep 1
tail -n 3 /home/postgres/server.log
EOF

docker rm -f "$CT" >/dev/null 2>&1
