#!/bin/bash
# PostgreSQL 운영 1편(진단 도구상자) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

# 가장 최근 서버 로그에서 패턴에 맞는 줄을 보여 준다
LOGTAIL='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'

step "0. 실습 환경"
fresh_cluster
env_info

step "1. 설치 직후의 로그 관련 설정"
q "SELECT name, setting, boot_val, source FROM pg_settings
WHERE name IN ('logging_collector', 'log_directory', 'log_filename',
               'log_rotation_age', 'log_rotation_size', 'log_truncate_on_rotation',
               'log_line_prefix', 'log_lock_waits', 'log_autovacuum_min_duration',
               'log_checkpoints', 'log_temp_files', 'log_min_duration_statement',
               'track_io_timing', 'shared_preload_libraries', 'deadlock_timeout')
ORDER BY source, name;"
pg <<'SH'
ls -l $PGDATA/log
SH

step "2. 진단용 설정 켜기"
q "ALTER SYSTEM SET log_lock_waits = on;"
q "ALTER SYSTEM SET log_temp_files = 0;"
q "ALTER SYSTEM SET log_min_duration_statement = '500ms';"
q "ALTER SYSTEM SET log_autovacuum_min_duration = 0;"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET track_io_timing = on;"
note "흔한 실수: 목록 전체를 따옴표 하나로 묶는다"
q "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements, auto_explain';"
note "실습에서 autovacuum 로그를 빨리 보려고 naptime을 줄인다 (운영 권장값 아님)"
q "ALTER SYSTEM SET autovacuum_naptime = '10s';"
q "SELECT pg_reload_conf();"
q "SELECT name, setting, pending_restart FROM pg_settings
WHERE name IN ('log_lock_waits', 'log_temp_files', 'shared_preload_libraries')
ORDER BY name;"
pg <<'SH'
grep shared_preload_libraries $PGDATA/postgresql.auto.conf
SH
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
pg <<'SH'
tail -n 3 /var/lib/pgsql/startup.log
SH
note "서버가 뜨지 않으니 ALTER SYSTEM을 쓸 수 없다. postgresql.auto.conf에서 그 줄을 지우고 띄운다"
pg <<'SH'
sed -i '/^shared_preload_libraries/d' $PGDATA/postgresql.auto.conf
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH
note "목록은 따옴표 없이 쉼표로 나열한다"
q "ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements, auto_explain;"
pg <<'SH'
grep shared_preload_libraries $PGDATA/postgresql.auto.conf
SH
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "ALTER SYSTEM SET auto_explain.log_min_duration = '500ms';"
q "SELECT pg_reload_conf();"
q "CREATE EXTENSION pg_stat_statements;"
q "SELECT name, setting, pending_restart FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'track_io_timing', 'auto_explain.log_min_duration', 'log_line_prefix')
ORDER BY name;"
pg <<'SH'
cat $PGDATA/postgresql.auto.conf
SH

step "3. pg_stat_activity: 누가 무엇을 기다리는가"
q "CREATE TABLE t (id int PRIMARY KEY, v int);"
q "INSERT INTO t VALUES (1, 0), (2, 0);"
sess_start A "-v application_name=app_a"
sess_start B "-v application_name=app_b"
sess A "SET application_name = 'app_a';"
sess B "SET application_name = 'app_b';"
sess A "BEGIN;"
sess A "UPDATE t SET v = v + 1 WHERE id = 1;"
sess B "UPDATE t SET v = v + 10 WHERE id = 1;" 3
q "SELECT pid, application_name AS app, state, wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by, left(query, 40) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY pid;"
q "SELECT pid, now() - xact_start AS xact_age, now() - state_change AS in_state
FROM pg_stat_activity
WHERE application_name IN ('app_a', 'app_b')
ORDER BY pid;"
pg <<'SH'
ps -u postgres -o pid,cmd | grep 'postgres:' | grep -v grep
SH
pg <<SH
$LOGTAIL | grep -E 'still waiting|Process holding|Wait queue|STATEMENT'
SH
sess A "ROLLBACK;"
sess_wait B 1
pg <<SH
$LOGTAIL | grep -E 'acquired'
SH
sess_end A
sess_end B

step "4. pgbench 부하와 pg_stat_statements"
pg <<'SH'
pgbench -i -s 10 -q postgres 2>&1 | tail -n 3
SH
q "SELECT pg_stat_statements_reset() IS NOT NULL AS reset;"
pg <<'SH'
nohup pgbench -c 8 -j 2 -T 30 postgres > /var/lib/pgsql/bench.log 2>&1 &
SH
sleep 8
note "부하 중 wait event 표본 (세 번)"
for i in 1 2 3; do
  q "SELECT wait_event_type, wait_event, state, count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
GROUP BY 1, 2, 3 ORDER BY 4 DESC;"
  sleep 1
done
note "부하 중 OS 지표"
pg <<'SH'
top -b -n 1 -u postgres | head -n 20
SH
pg <<'SH'
iostat -x 1 3
SH
pg <<'SH'
free -m
df -h $PGDATA
SH
sleep 20
pg <<'SH'
cat /var/lib/pgsql/bench.log
SH
q "SELECT left(query, 60) AS query, calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 3) AS mean_ms,
       rows, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;"

step "5. temp file, 느린 쿼리, auto_explain"
q "SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM pgbench_accounts ORDER BY filler, aid;"
pg <<SH
$LOGTAIL | grep -A 3 -E 'temporary file' | tail -n 12
SH
note "500ms를 넘기는 쿼리: 느린 쿼리 로그와 auto_explain"
q "SET max_parallel_workers_per_gather = 0;
SELECT count(DISTINCT md5(filler || aid)) FROM pgbench_accounts;"
pg <<SH
$LOGTAIL | grep -A 14 -E 'duration: [0-9.]+ ms' | tail -n 30
SH
q "SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database WHERE datname = 'postgres';"

step "6. pg_stat_io"
q "SELECT backend_type, object, context, reads, pg_size_pretty(read_bytes) AS read,
       round(read_time::numeric, 1) AS read_ms, writes, extends, hits, evictions
FROM pg_stat_io
WHERE reads > 0 OR writes > 0 OR extends > 0
ORDER BY coalesce(reads, 0) + coalesce(writes, 0) + coalesce(extends, 0) DESC
LIMIT 10;"

step "7. autovacuum과 checkpoint 로그"
sleep 15
q "CHECKPOINT;"
pg <<SH
$LOGTAIL | grep -A 8 -E 'automatic (vacuum|analyze) of table' | tail -n 30
SH
pg <<SH
$LOGTAIL | grep -E 'checkpoint (starting|complete)' | tail -n 4
SH
q "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, autovacuum_count
FROM pg_stat_user_tables ORDER BY relname;"

docker rm -f "$CT" >/dev/null 2>&1
