#!/bin/bash
# PostgreSQL 운영 6편(디스크가 찬다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 데이터 디렉터리는 600MB로 제한한 tmpfs(/pgfs)에 둔다. 서버 로그와 WAL 아카이브는 그 밖(/var/lib/pgsql)에 둔다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 600 "$(ls -t /var/lib/pgsql/log/*.log | head -1)"'
USAGE="SELECT pg_size_pretty(pg_database_size('postgres')) AS db,
       (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS pg_wal,
       (SELECT count(*) FROM pg_ls_waldir()) AS wal_files;"

step "0. 실습 환경"
fresh_cluster --tmpfs /pgfs:rw,size=600m,uid=26,gid=26,mode=0755 -e PGDATA=/pgfs/data
env_info
pg <<'SH'
df -h /pgfs
SH
pg <<'SH'
mkdir -p /var/lib/pgsql/log /var/lib/pgsql/archive
SH
q "ALTER SYSTEM SET log_directory = '/var/lib/pgsql/log';"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET archive_mode = on;"
note "아카이브 대상이 망가진 상황을 흉내 낸다: 명령이 항상 실패한다"
q "ALTER SYSTEM SET archive_command = 'false';"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH

step "1. 아카이브 실패: WAL이 지워지지 않는다"
pg <<'SH'
pgbench -i -s 10 -q postgres 2>&1 | tail -n 1
SH
q "CHECKPOINT;"
q "$USAGE"
q "SELECT archived_count, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;"
pg <<'SH'
ls $PGDATA/pg_wal/archive_status | head -n 3
ls $PGDATA/pg_wal/archive_status | grep -c '\.ready$'
SH
pg <<SH
$LOGTAIL | grep -A 1 -E 'archive command failed' | tail -n 2
SH
pg <<'SH'
df -h /pgfs
SH
note "아카이브 대상을 고친다"
q "ALTER SYSTEM SET archive_command = 'test ! -f /var/lib/pgsql/archive/%f && cp %p /var/lib/pgsql/archive/%f';"
q "SELECT pg_reload_conf();"
sleep 5
q "SELECT archived_count, failed_count, last_archived_wal FROM pg_stat_archiver;"
q "CHECKPOINT;"
q "$USAGE"
pg <<'SH'
df -h /pgfs
SH

step "2. 쓰지 않는 replication slot: WAL이 계속 쌓인다"
q "SELECT pg_create_physical_replication_slot('standby1', true);"
q "SELECT slot_name, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots;"
q "SHOW max_slot_wal_keep_size;"
pg <<'SH'
pgbench -n -c 4 -T 20 postgres 2>&1 | grep -E 'processed|tps'
SH
q "CHECKPOINT;"
q "$USAGE"
q "SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained,
       wal_status
FROM pg_replication_slots;"
pg <<'SH'
df -h /pgfs
SH

step "3. 디스크가 가득 찬다"
note "비상용 여유 공간: 미리 50MB짜리 파일을 만들어 둔다"
pg <<'SH'
dd if=/dev/zero of=/pgfs/ballast bs=1M count=50 status=none && ls -lh /pgfs/ballast
SH
pg <<'SH'
timeout 300 pgbench -n -c 4 -T 280 postgres 2>&1 | tail -n 6
SH
pg <<'SH'
df -h /pgfs
SH
pg <<SH
$LOGTAIL | grep -E 'PANIC|No space left|terminated by signal|terminating any other|reinitializing|interrupted|aborting startup|shut down|redo' | tail -n 20
SH
pg <<'SH'
pg_ctl -D $PGDATA status
SH

step "4. 복구: 비상 공간을 풀고, 원인을 없앤다"
pg <<'SH'
rm /pgfs/ballast
df -h /pgfs
SH
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH
pg <<SH
$LOGTAIL | grep -E 'redo|ready to accept' | tail -n 4
SH
q "SELECT slot_name, active, wal_status FROM pg_replication_slots;"
q "SELECT pg_drop_replication_slot('standby1');"
q "CHECKPOINT;"
q "$USAGE"
pg <<'SH'
df -h /pgfs
SH

step "5. temp file: 쿼리만 실패한다"
q "SET temp_file_limit = '20MB';
SELECT count(*) FROM (SELECT * FROM pgbench_accounts ORDER BY filler, aid OFFSET 0) s;"
note "제한이 없으면 디스크가 찰 때까지 쓴다. 여유 공간을 30MB만 남기고 해 본다"
pg <<'SH'
avail=$(df --output=avail -m /pgfs | tail -n 1); dd if=/dev/zero of=/pgfs/filler bs=1M count=$((avail - 30)) status=none; df -h /pgfs
SH
q "SET max_parallel_workers_per_gather = 0;
SELECT count(*) FROM (SELECT * FROM pgbench_accounts ORDER BY filler, aid OFFSET 0) s;"
q "SELECT 1 AS still_alive;"
pg <<'SH'
rm /pgfs/filler
SH

docker rm -f "$CT" >/dev/null 2>&1
