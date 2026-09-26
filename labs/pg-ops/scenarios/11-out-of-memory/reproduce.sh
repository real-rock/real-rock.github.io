#!/bin/bash
# PostgreSQL 운영 11편(메모리가 모자란다) 실습. 컨테이너 메모리를 768MB로 제한한다(cgroup, swap 없음).
cd "$(dirname "$0")"
export OUT=out/capture.txt
source ../../lib/labkit.sh

LOGTAIL='tail -n 1000 "$(ls -t $PGDATA/log/*.log | head -1)"'
HEAVY="SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;"
# 해시 테이블을 다 만든 뒤 그룹마다 md5를 여러 번 계산해 출력 단계만 몇 초 걸리게 한다 (메모리를 쥔 채로 관찰하려고)
SLOWQ="SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k HAVING md5(md5(md5(md5(md5(md5(k)))))) IS NOT NULL) s;"

step "0. 실습 환경"
fresh_cluster --memory 768m --memory-swap 768m
env_info
pg <<'SH'
cat /sys/fs/cgroup/memory.max
grep -n -i -A 1 'oom' /usr/lib/systemd/system/postgresql-18.service
SH
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
q "ALTER SYSTEM SET max_parallel_workers_per_gather = 0;"
q "SELECT pg_reload_conf();"
q "SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'hash_mem_multiplier', 'maintenance_work_mem', 'max_connections')
ORDER BY name;"
q "CREATE TABLE big AS SELECT g AS id, md5(g::text) AS k FROM generate_series(1, 3000000) g;"
q "VACUUM ANALYZE big;"
q "SELECT pg_size_pretty(pg_table_size('big')) AS big;"

step "1. work_mem은 연산 하나의 한도다"
q "SET work_mem = '4MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) $HEAVY"
q "SET work_mem = '1GB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) $HEAVY"

step "2. 실행 중인 세션의 메모리 보기"
sess_start A
sess A "SET application_name = 'report';"
sess A "SET work_mem = '1GB';"
sess A "\\timing on"
sess A "$SLOWQ" 2
pg <<'SH'
ps -o pid,rss,cmd -p $(psql -XAtc "SELECT pid FROM pg_stat_activity WHERE application_name = 'report'")
cat /sys/fs/cgroup/memory.current
SH
q "SELECT pg_log_backend_memory_contexts(pid) FROM pg_stat_activity WHERE application_name = 'report';"
sess_wait A 8
pg <<SH
$LOGTAIL | grep -E 'Grand total|level: 1; ExecutorState|level: [0-9]+; HashAgg' | tail -n 4
SH
sess_end A

step "3. 동시에 네 개: OOM"
pg <<'SH'
cat /sys/fs/cgroup/memory.events
SH
q "SELECT pg_postmaster_start_time();"
pg <<'SH'
for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=1GB' nohup psql -X -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/heavy_$i.out 2>&1 & done
sleep 25
cat /tmp/heavy_1.out /tmp/heavy_2.out /tmp/heavy_3.out /tmp/heavy_4.out
SH
pg <<'SH'
cat /sys/fs/cgroup/memory.events
SH
pg <<SH
$LOGTAIL | grep -E 'terminated by signal|Failed process|terminating any other|all server processes terminated|not properly shut down|redo done|ready to accept' | tail -n 8
SH
q "SELECT pg_postmaster_start_time(), now();"

step "4. work_mem을 줄이면"
note "64MB: 해시 한도는 64MB x hash_mem_multiplier(2) = 128MB"
pg <<'SH'
for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=64MB' nohup psql -X -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/mid_$i.out 2>&1 & done
sleep 25
grep -h -E 'count|server closed|crash of another' /tmp/mid_1.out /tmp/mid_2.out /tmp/mid_3.out /tmp/mid_4.out
grep oom_kill /sys/fs/cgroup/memory.events
SH
note "16MB"
pg <<'SH'
for i in 1 2 3 4; do PGAPPNAME=report$i PGOPTIONS='-c work_mem=16MB' nohup psql -X -c "\\timing on" -c "SELECT count(*) FROM (SELECT k, count(*) FROM big GROUP BY k) s;" > /tmp/small_$i.out 2>&1 & done
sleep 25
cat /tmp/small_1.out /tmp/small_2.out /tmp/small_3.out /tmp/small_4.out
cat /sys/fs/cgroup/memory.events
SH
q "SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes FROM pg_stat_database WHERE datname = 'postgres';"

docker rm -f "$CT" >/dev/null 2>&1
