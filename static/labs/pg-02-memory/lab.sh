#!/bin/bash
# PostgreSQL 인터널 2편(메모리 구조) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
source ../common/labkit.sh

step "0. 실습 환경"
fresh_cluster
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_buffercache"
EOF

step "1. 메모리 관련 기본 설정"
pg <<'EOF'
psql -X <<'SQL'
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN ('shared_buffers', 'wal_buffers', 'work_mem', 'hash_mem_multiplier',
               'maintenance_work_mem', 'temp_buffers', 'block_size', 'shared_memory_size')
ORDER BY name;
SQL
EOF

step "2. 공유 메모리는 무엇으로 채워져 있나"
pg <<'EOF'
psql -X <<'SQL'
SELECT name, pg_size_pretty(allocated_size) AS size
FROM pg_shmem_allocations
ORDER BY allocated_size DESC
LIMIT 10;
SELECT count(*) AS entries, pg_size_pretty(sum(allocated_size)) AS total
FROM pg_shmem_allocations;
SQL
EOF

step "3. 테이블을 읽으면 shared buffers에 페이지가 올라온다"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE small AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 100000) g;
SELECT pg_size_pretty(pg_relation_size('small')) AS size, pg_relation_size('small') / 8192 AS pages;
SELECT pg_buffercache_evict_relation('small');
SELECT * FROM pg_buffercache_summary();
SELECT count(*) FROM small;
SELECT * FROM pg_buffercache_summary();
SELECT count(*) AS buffers_of_small
FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small');
SQL
EOF

step "4. 같은 페이지를 다시 읽으면 hit, 처음 읽으면 read"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_buffercache_evict_relation('small');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
SQL
EOF

step "4-1. read는 디스크일까, 운영체제 캐시일까"
pg <<'EOF'
psql -X <<'SQL'
SET track_io_timing = on;
SET max_parallel_workers_per_gather = 0;
SELECT pg_buffercache_evict_relation('small');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
SQL
grep -E '^(MemTotal|Cached):' /proc/meminfo
EOF

step "5. usage count: 자주 읽는 페이지일수록 오래 살아남는다"
pg <<'EOF'
psql -X <<'SQL'
SELECT pg_buffercache_evict_relation('small');
SELECT count(*) FROM small;
SELECT usagecount, count(*) FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small') GROUP BY 1 ORDER BY 1;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT usagecount, count(*) FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small') GROUP BY 1 ORDER BY 1;
SQL
EOF

step "6. 큰 테이블 순차 스캔은 ring buffer만 쓴다"
pg <<'EOF'
psql -X <<'SQL'
CREATE TABLE big AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 600000) g;
SELECT pg_size_pretty(pg_relation_size('big')) AS size,
       pg_relation_size('big') / 8192 AS pages,
       current_setting('shared_buffers') AS shared_buffers,
       (SELECT setting::int FROM pg_settings WHERE name = 'shared_buffers') / 4 AS bulkread_threshold_pages;
SELECT pg_buffercache_evict_relation('big');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM big;
SELECT count(*) AS buffers_of_big
FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('big');
SQL
EOF
pg <<'EOF'
psql -X <<'SQL'
SELECT current_setting('max_connections')::int
     + current_setting('autovacuum_worker_slots')::int
     + current_setting('max_worker_processes')::int
     + current_setting('max_wal_senders')::int + 2 AS max_backends,
       (SELECT setting::int FROM pg_settings WHERE name = 'shared_buffers')
       / (current_setting('max_connections')::int
          + current_setting('autovacuum_worker_slots')::int
          + current_setting('max_worker_processes')::int
          + current_setting('max_wal_senders')::int + 2 + 38) AS pin_limit_buffers;
SHOW io_combine_limit;
SHOW effective_io_concurrency;
SQL
EOF

step "7. 수정된 페이지(dirty)는 체크포인트가 디스크로 내보낸다"
pg <<'EOF'
psql -X <<'SQL'
CHECKPOINT;
SELECT buffers_dirty FROM pg_buffercache_summary();
UPDATE small SET pad = repeat('y', 100) WHERE id % 10 = 0;
SELECT buffers_dirty FROM pg_buffercache_summary();
SELECT count(*) FILTER (WHERE isdirty) AS dirty_of_small
FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('small');
SELECT buffers_written FROM pg_stat_checkpointer;
CHECKPOINT;
SELECT buffers_dirty FROM pg_buffercache_summary();
SELECT buffers_written FROM pg_stat_checkpointer;
SQL
EOF

step "8. work_mem을 넘는 정렬은 임시 파일로 간다"
pg <<'EOF'
psql -X <<'SQL'
SET log_temp_files = 0;
SET work_mem = '4MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM big ORDER BY pad, id DESC;
SET work_mem = '256MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM big ORDER BY pad, id DESC;
SQL
grep 'temporary file' /home/postgres/server.log | tail -3
EOF

step "9. 해시 테이블은 work_mem x hash_mem_multiplier까지 쓴다"
pg <<'EOF'
psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
SET enable_mergejoin = off;
SET work_mem = '1MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SET work_mem = '64MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SQL
EOF

step "9-1. work_mem은 쿼리 하나가 아니라 노드마다 잡힌다"
pg <<'EOF'
psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
SET enable_hashjoin = off;
SET work_mem = '32MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SQL
EOF

step "10. backend 개인 메모리: 메모리 컨텍스트"
pg <<'EOF'
psql -X <<'SQL'
SELECT name, level, pg_size_pretty(total_bytes) AS total, pg_size_pretty(used_bytes) AS used
FROM pg_backend_memory_contexts
ORDER BY total_bytes DESC
LIMIT 8;
SELECT count(*) AS contexts, pg_size_pretty(sum(total_bytes)) AS total
FROM pg_backend_memory_contexts;
SQL
EOF

step "11. 임시 테이블은 backend 개인 버퍼(temp_buffers)를 쓴다"
pg <<'EOF'
psql -X <<'SQL'
CREATE TEMP TABLE tmp AS SELECT g AS id FROM generate_series(1, 100000) g;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM tmp;
SELECT count(*) AS shared_buffers_used_by_tmp
FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('tmp');
SQL
EOF

step "12. WAL buffers가 작으면 backend가 직접 WAL을 써야 한다"
pg <<'EOF'
psql -X -c "SHOW wal_buffers"
psql -X -q -c "SELECT pg_stat_reset_shared('wal')"
psql -X -q -c "INSERT INTO big SELECT g, repeat('z', 100) FROM generate_series(1, 300000) g"
psql -X -c "SELECT wal_records, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full FROM pg_stat_wal"
EOF
pg <<'EOF'
psql -X -q -c "ALTER SYSTEM SET wal_buffers = '64kB'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast > /dev/null
psql -X -c "SHOW wal_buffers"
psql -X -q -c "SELECT pg_stat_reset_shared('wal')"
psql -X -q -c "INSERT INTO big SELECT g, repeat('z', 100) FROM generate_series(1, 300000) g"
psql -X -c "SELECT wal_records, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full FROM pg_stat_wal"
EOF

echo "done" | log
