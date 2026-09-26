#!/bin/bash
# PostgreSQL 운영 10편(주기적으로 I/O가 튄다) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 2000 "$(ls -t $PGDATA/log/*.log | head -1)"'
RESET="SELECT pg_stat_reset_shared('checkpointer'), pg_stat_reset_shared('wal'),
       pg_stat_reset_shared('io'), pg_stat_reset_shared('bgwriter'), pg_stat_reset();"
STATS="SELECT c.num_timed, c.num_requested, c.num_done, c.buffers_written,
       round(c.write_time) AS write_ms, round(c.sync_time) AS sync_ms,
       w.wal_fpi, pg_size_pretty(w.wal_bytes) AS wal,
       d.xact_commit, pg_size_pretty(w.wal_bytes / d.xact_commit) AS wal_per_xact
FROM pg_stat_checkpointer c, pg_stat_wal w, pg_stat_database d
WHERE d.datname = 'postgres';"
IO="SELECT backend_type, writes, fsyncs
FROM pg_stat_io
WHERE object = 'relation' AND context = 'normal' AND writes > 0
ORDER BY writes DESC;"

step "0. 실습 환경"
fresh_cluster
env_info
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET track_io_timing = on;"
q "SELECT pg_reload_conf();"
pg <<'SH'
pgbench -i -s 50 -q postgres 2>&1 | tail -n 1
SH
q "SELECT name, setting, unit FROM pg_settings
WHERE name IN ('max_wal_size', 'min_wal_size', 'checkpoint_timeout', 'checkpoint_completion_target',
               'checkpoint_warning', 'full_page_writes', 'log_checkpoints')
ORDER BY name;"

step "1. max_wal_size가 작을 때"
q "ALTER SYSTEM SET max_wal_size = '64MB';"
q "SELECT pg_reload_conf();"
q "CHECKPOINT;"
q "$RESET"
pg <<'SH'
pgbench -n -c 8 -j 2 -T 60 -P 5 postgres 2>&1 | grep -E '^progress|^tps|latency average'
SH
q "$STATS"
q "$IO"
pg <<SH
$LOGTAIL | grep -c 'checkpoint starting: wal'
SH
pg <<SH
$LOGTAIL | grep -A 1 -E 'checkpoints are occurring too frequently' | tail -n 2
SH
pg <<SH
$LOGTAIL | grep -E 'checkpoint (starting|complete)' | tail -n 2
SH

step "2. max_wal_size가 충분할 때"
q "ALTER SYSTEM SET max_wal_size = '4GB';"
q "SELECT pg_reload_conf();"
q "CHECKPOINT;"
q "$RESET"
pg <<'SH'
pgbench -n -c 8 -j 2 -T 60 -P 5 postgres 2>&1 | grep -E '^progress|^tps|latency average'
SH
q "$STATS"
q "$IO"
q "SELECT pg_size_pretty(sum(size)) AS pg_wal FROM pg_ls_waldir();"

step "3. 시간 기준 체크포인트의 분산"
q "CHECKPOINT;"
q "ALTER SYSTEM SET checkpoint_timeout = '30s';"
q "SELECT pg_reload_conf();"
pg <<'SH'
pgbench -n -c 8 -j 2 -T 70 -P 5 postgres 2>&1 | grep -E '^progress|^tps'
SH
pg <<SH
$LOGTAIL | grep -E 'checkpoint (starting|complete)' | tail -n 4
SH

docker rm -f "$CT" >/dev/null 2>&1
