#!/bin/bash
# "PostgreSQL extension은 어떻게 동작하는가" 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 이미지: Dockerfile.strace로 만든 pg-internals:rocky9-rel18-strace (strace가 필요하다).
# 준비: 같은 디렉터리에 PostgreSQL 17.11 소스(postgres17-src.tar.gz)가 있어야 한다 (ABI 불일치 실험용).
#   git -C <postgres 저장소> archive --format=tar.gz -o postgres17-src.tar.gz REL_17_11
cd "$(dirname "$0")"
IMAGE=${IMAGE:-pg-internals:rocky9-rel18-strace}
CT=${CT:-pglab-ext}
source ../lib/labkit.sh

# strace로 다른 프로세스에 붙으려면 SYS_PTRACE가 필요하다.
fresh_cluster_ptrace() {
  docker rm -f "$CT" >/dev/null 2>&1
  host "docker run -d --init --cap-add SYS_PTRACE --name $CT --hostname $CT $IMAGE sleep infinity"
  pg <<'EOF'
cat /etc/rocky-release
postgres --version
gcc --version | head -1
initdb -D $PGDATA > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
EOF
}

# 세션 X의 backend PID (세션은 application_name=sessX로 연다)
sess_pid() {
  docker exec "$CT" psql -X -At -c "SELECT pid FROM pg_stat_activity WHERE application_name = 'sess$1'"
}

MAPS_COUNT="SELECT count(*) AS mapped FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so%';"
MAPS_LINES="SELECT l FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so%';"
MAPS_DELETED="SELECT count(*) AS deleted_mappings FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so (deleted)%';"

step "0. 실습 환경"
fresh_cluster_ptrace
host "docker cp src/. $CT:/home/postgres/lab && docker cp postgres17-src.tar.gz $CT:/tmp/postgres17-src.tar.gz"
pgroot <<'EOF'
chown -R postgres:postgres /home/postgres/lab
strace -V | head -1
EOF

step "1. demo_ext 빌드와 심볼 표"
pg <<'EOF'
cd ~/lab/demo_ext
make
file demo_ext.so
nm -D --defined-only demo_ext.so
nm -D --undefined-only demo_ext.so
ldd demo_ext.so
EOF

step "2. postgres 실행 파일이 내보내는 심볼"
pg <<'EOF'
grep -E "^(LDFLAGS_EX_BE|CFLAGS_SL|CFLAGS_SL_MODULE|DLSUFFIX) " $(pg_config --pgxs | sed "s#makefiles/pgxs.mk#Makefile.global#")
file /usr/local/pgsql/bin/postgres
nm -D --defined-only /usr/local/pgsql/bin/postgres | wc -l
nm -D --defined-only /usr/local/pgsql/bin/postgres | grep -wE "cstring_to_text|errstart|ExecutorEnd_hook|ShmemInitStruct|standard_ExecutorEnd|shmem_request_hook|process_shared_preload_libraries_in_progress"
EOF

step "3. PostgreSQL 밖에서 dlopen"
pg <<'EOF'
cd ~/lab
cat dltest.c
gcc -o dltest dltest.c
./dltest ./demo_ext/demo_ext.so
./dltest /usr/local/pgsql/lib/pg_stat_statements.so
EOF

step "4. extension 파일과 설치"
pg <<'EOF'
pg_config --version --pkglibdir --sharedir --includedir-server --pgxs
cd ~/lab/demo_ext
cat demo_ext.control
cat demo_ext--1.0.sql
cat Makefile
cat demo_ext--1.0--1.1.sql
EOF
pgroot <<'EOF'
cd /home/postgres/lab/demo_ext && make install
EOF
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log start
EOF

step "5. CREATE EXTENSION 전 상태 (세션 A)"
sess_start A "application_name=sessA"
sess A "SELECT pg_backend_pid();"
sess A "SELECT name, default_version, installed_version, comment FROM pg_available_extensions WHERE name IN ('demo_ext', 'pg_stat_statements', 'pgcrypto') ORDER BY name;"
sess A "SELECT count(*) AS mapped FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext%';"
sess A "SELECT * FROM pg_get_loaded_modules();"

step "6. strace로 보는 CREATE EXTENSION"
APID=$(sess_pid A)
pgroot <<EOF
strace -p $APID -f -tt -e trace=openat,read,mmap,mprotect,close -o /tmp/create_ext.strace > /dev/null 2>&1 &
echo \$! > /tmp/strace.pid
sleep 1
EOF
sess A "CREATE EXTENSION demo_ext;" 2
pgroot <<'EOF'
kill $(cat /tmp/strace.pid); sleep 0.5
wc -l < /tmp/create_ext.strace
cat /tmp/create_ext.strace
EOF
pg <<'EOF'
psql -X -c "SELECT pg_relation_filenode(c.oid) AS filenode, c.relname FROM pg_class c WHERE pg_relation_filenode(c.oid) IN (3079, 1255, 2608, 1259, 1247) ORDER BY 1;"
cat /home/postgres/server.log
EOF

step "7. CREATE EXTENSION 뒤의 매핑과 카탈로그"
sess A "$MAPS_LINES"
sess A "SELECT * FROM pg_get_loaded_modules();"
sess A "SELECT oid, extname, extversion, extrelocatable, extnamespace::regnamespace, extconfig::regclass[] FROM pg_extension;"
sess A "SELECT proname, (SELECT lanname FROM pg_language WHERE oid = prolang) AS lang, probin, prosrc FROM pg_proc WHERE proname IN ('demo_add', 'demo_build', 'demo_local_count', 'demo_shared_count') ORDER BY proname;"
sess A "SELECT classid::regclass, pg_describe_object(classid, objid, objsubid) AS member, deptype FROM pg_depend WHERE refclassid = 'pg_extension'::regclass AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'demo_ext') ORDER BY 1, 2;"

step "8. 라이브러리를 올리다 실패하는 경우"
pgroot <<'EOF'
mkdir -p /usr/src/postgres17 && tar -xzf /tmp/postgres17-src.tar.gz -C /usr/src/postgres17
cd /usr/src/postgres17
./configure --prefix=/usr/local/pgsql17 > /tmp/configure17.log 2>&1 && make -j"$(nproc)" > /tmp/make17.log 2>&1 && make install > /tmp/install17.log 2>&1 && echo "PostgreSQL 17 build ok"
/usr/local/pgsql17/bin/pg_config --version
EOF
pg <<'EOF'
cd ~/lab
make -C nomagic
nm -D --defined-only nomagic/nomagic.so
make -C abi17 PG_CONFIG=/usr/local/pgsql17/bin/pg_config
nm -D --defined-only abi17/abi_demo.so
psql -X <<'SQL'
CREATE FUNCTION nomagic_one() RETURNS int AS '/home/postgres/lab/nomagic/nomagic.so', 'nomagic_one' LANGUAGE C;
CREATE FUNCTION abi_demo_one() RETURNS int AS '/home/postgres/lab/abi17/abi_demo.so', 'abi_demo_one' LANGUAGE C;
CREATE FUNCTION demo_nosuch() RETURNS int AS '$libdir/demo_ext', 'demo_nosuch' LANGUAGE C;
CREATE FUNCTION demo_nolib() RETURNS int AS '$libdir/demo_extx', 'demo_add' LANGUAGE C;
SQL
EOF

step "9. 다른 backend는 처음 부를 때 올린다 (세션 B)"
sess_start B "application_name=sessB"
sess B "SELECT pg_backend_pid();"
sess B "$MAPS_COUNT"
sess B "SELECT * FROM pg_get_loaded_modules();"
sess B "SELECT demo_add(1, 2);"
sess B "$MAPS_COUNT"
pg <<'EOF'
grep -A1 "_PG_init" /home/postgres/server.log
EOF

step "10. hook과 custom GUC"
sess B "SET demo_ext.trace = on;"
sess B "SELECT count(*) FROM pg_class WHERE relkind = 'r';"
sess B "SET demo_ext.tarce = on;"
sess_start C "application_name=sessC"
sess C "SET demo_ext.tarce = on;"
sess C "SHOW demo_ext.tarce;"
sess C "LOAD 'demo_ext';"
sess C "SELECT * FROM pg_get_loaded_modules();"
sess_end C

step "11. 프로세스마다 따로 있는 static 변수"
sess B "SET demo_ext.trace = off;"
sess B "SELECT demo_local_count();"
sess B "SELECT demo_local_count();"
sess B "SELECT demo_shared_count();"
sess A "SELECT demo_local_count();"
sess_end A
sess_end B

step "12. shared_preload_libraries = demo_ext"
pg <<'EOF'
psql -X -c "ALTER SYSTEM SET shared_preload_libraries = 'demo_ext'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
EOF
PM=$(docker exec "$CT" bash -c 'head -1 $PGDATA/postmaster.pid')
pg <<'EOF'
PM=$(head -1 $PGDATA/postmaster.pid); echo $PM
grep "_PG_init" /home/postgres/server.log | tail -1
EOF
pgroot <<'EOF'
PM=$(head -1 /var/lib/postgresql/data/postmaster.pid)
for p in $PM $(pgrep -P $PM); do printf "%6s %-45s %s\n" $p "$(tr "\0" " " < /proc/$p/cmdline | cut -c1-45)" "$(grep -c demo_ext.so /proc/$p/maps)"; done
EOF

step "13. 새 접속을 만들 때의 postmaster (strace)"
pgroot <<EOF
strace -p $PM -f -e trace=clone,clone3,fork,execve,openat -o /tmp/fork.strace > /dev/null 2>&1 &
echo \$! > /tmp/strace.pid
sleep 1
EOF
sess_start A "application_name=sessA"
sess A "SELECT pg_backend_pid();"
pgroot <<'EOF'
kill $(cat /tmp/strace.pid); sleep 0.5
grep -vE "base/|global/|pg_|\.conf" /tmp/fork.strace
grep -c "demo_ext" /tmp/fork.strace
grep -c "_PG_init" /home/postgres/server.log
EOF

step "14. 공유 메모리의 카운터"
sess A "SELECT * FROM pg_get_loaded_modules();"
sess A "SELECT demo_local_count(), demo_shared_count();"
sess_start B "application_name=sessB"
sess B "SELECT demo_local_count(), demo_shared_count();"
sess B "SELECT demo_local_count(), demo_shared_count();"
sess A "SELECT demo_local_count(), demo_shared_count();"
sess A "SELECT name, size, allocated_size FROM pg_shmem_allocations WHERE name = 'demo_ext';"

step "15. CREATE EXTENSION은 되는데 조회가 안 된다"
sess A "CREATE EXTENSION pg_stat_statements;" 2
sess A "SELECT count(*) FROM pg_stat_statements;"
sess_end A
sess_end B

step "16. shared_preload_libraries를 따옴표 하나로 묶으면"
pg <<'EOF'
psql -X -c "ALTER SYSTEM SET shared_preload_libraries = 'demo_ext, pg_stat_statements'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
tail -2 /home/postgres/server.log
cat $PGDATA/postgresql.auto.conf
postgres -D $PGDATA -C shared_preload_libraries
EOF
pg <<'EOF'
sed -i "/^shared_preload_libraries/d" $PGDATA/postgresql.auto.conf
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -c "ALTER SYSTEM SET shared_preload_libraries = demo_ext, pg_stat_statements"
cat $PGDATA/postgresql.auto.conf
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
psql -X <<'SQL'
SHOW shared_preload_libraries;
SELECT count(*) > 0 AS has_rows FROM pg_stat_statements;
SELECT * FROM pg_get_loaded_modules();
SELECT name, size FROM pg_shmem_allocations WHERE name LIKE 'pg_stat_statements%' OR name = 'demo_ext' ORDER BY name;
SQL
EOF

step "17. postmaster와 backend의 매핑 주소"
sess_start A "application_name=sessA"
sess A "SELECT pg_backend_pid();"
pgroot <<'EOF'
PM=$(head -1 /var/lib/postgresql/data/postmaster.pid)
BE=$(psql -U postgres -X -At -c "SELECT pid FROM pg_stat_activity WHERE application_name = 'sessA'")
echo "postmaster $PM:"; grep pg_stat_statements.so /proc/$PM/maps
echo "backend $BE:"; grep pg_stat_statements.so /proc/$BE/maps
EOF

step "18. 라이브러리 파일을 바꾸면 (preload한 경우)"
sess A "SELECT pg_backend_pid(), demo_build();"
pg <<'EOF'
cd ~/lab/demo_ext
ls -li /usr/local/pgsql/lib/demo_ext.so
sed -i "s/^default_version = .*/default_version = '1.1'/" demo_ext.control
sed -i "s/^DATA = .*/DATA = demo_ext--1.0.sql demo_ext--1.0--1.1.sql/" Makefile
cat demo_ext.control
cat Makefile
make clean > /dev/null
make PG_CPPFLAGS=-DDEMO_V11 > /dev/null && echo "built 1.1"
EOF
pgroot <<'EOF'
cd /home/postgres/lab/demo_ext && make install
ls -li /usr/local/pgsql/lib/demo_ext.so
nm -D --defined-only /usr/local/pgsql/lib/demo_ext.so | grep -w demo_sub
EOF
sess A "$MAPS_LINES"
sess A "SELECT demo_build();"
sess A "SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name = 'demo_ext';"
sess A "SELECT * FROM pg_extension_update_paths('demo_ext');"
sess A "ALTER EXTENSION demo_ext UPDATE;" 2
sess_start B "application_name=sessB"
sess B "SELECT pg_backend_pid(), demo_build();"
sess B "$MAPS_DELETED"
sess B "ALTER EXTENSION demo_ext UPDATE;" 2
sess_end A
sess_end B
pg <<'EOF'
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
grep _PG_init /home/postgres/server.log | tail -1
psql -X <<'SQL'
SELECT demo_build();
SELECT * FROM pg_get_loaded_modules() WHERE module_name = 'demo_ext';
ALTER EXTENSION demo_ext UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'demo_ext';
SELECT demo_sub(10, 3);
SQL
EOF

step "19. 라이브러리 파일을 바꾸면 (preload하지 않은 경우)"
pg <<'EOF'
psql -X -c "ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
cd ~/lab/demo_ext && make clean > /dev/null && make PG_CPPFLAGS='-DDEMO_V11 -DDEMO_BUILD_TAG="\" hotfix\""' > /dev/null && echo "built hotfix"
EOF
pgroot <<'EOF'
cd /home/postgres/lab/demo_ext && make install > /dev/null && ls -li /usr/local/pgsql/lib/demo_ext.so
EOF
sess_start A "application_name=sessA"
sess A "SELECT pg_backend_pid(), demo_build();"
pg <<'EOF'
cd ~/lab/demo_ext && make clean > /dev/null && make PG_CPPFLAGS='-DDEMO_V11 -DDEMO_BUILD_TAG="\" hotfix2\""' > /dev/null && echo "built hotfix2"
EOF
pgroot <<'EOF'
cd /home/postgres/lab/demo_ext && make install
ls -li /usr/local/pgsql/lib/demo_ext.so
EOF
sess A "SELECT demo_build();"
sess A "$MAPS_DELETED"
sess_start B "application_name=sessB"
sess B "SELECT pg_backend_pid(), demo_build();"
sess_end A
sess_end B

step "20. 올라와 있는 .so를 cp로 덮어쓰면"
pg <<'EOF'
cd ~/lab/demo_ext && make clean > /dev/null && make PG_CPPFLAGS='-DDEMO_V11 -DDEMO_BUILD_TAG="\" hotfix3 with a longer tag\""' > /dev/null && cp demo_ext.so /tmp/demo_ext.hotfix3.so && echo "built hotfix3"
EOF
sess_start A "application_name=sessA"
sess A "SELECT pg_backend_pid(), demo_build(), demo_add(1, 2);"
pgroot <<'EOF'
ls -li /usr/local/pgsql/lib/demo_ext.so
cp /tmp/demo_ext.hotfix3.so /usr/local/pgsql/lib/demo_ext.so
ls -li /usr/local/pgsql/lib/demo_ext.so
EOF
sess A "SELECT demo_build();"
sess A "SELECT demo_add(1, 2);"
sess_end A
# 이후 실습을 위해 1.1을 정상적으로 다시 설치한다
pg <<'EOF'
cd ~/lab/demo_ext && make clean > /dev/null && make PG_CPPFLAGS=-DDEMO_V11 > /dev/null && echo "built 1.1"
EOF
pgroot <<'EOF'
cd /home/postgres/lab/demo_ext && make install > /dev/null && strings /usr/local/pgsql/lib/demo_ext.so | grep "^demo_ext.so"
EOF

step "21. 버전을 건너뛰는 설치"
pg <<'EOF'
createdb verdb
psql -X -d verdb <<'SQL'
SET client_min_messages = debug1;
CREATE EXTENSION demo_ext;
RESET client_min_messages;
SELECT extversion FROM pg_extension WHERE extname = 'demo_ext';
SQL
EOF

step "22. C 함수의 crash"
sess_start B "application_name=sessB"
sess B "SELECT pg_backend_pid();"
sess B "BEGIN;"
sess B "INSERT INTO demo_note VALUES (1, 'written before the crash, not committed');"
pg <<'EOF'
psql -X <<'SQL'
CREATE FUNCTION demo_crash() RETURNS void AS '$libdir/demo_ext', 'demo_crash' LANGUAGE C;
SELECT pg_backend_pid();
SELECT demo_crash();
SQL
sleep 2
EOF
sess B "COMMIT;"
sess_end B
pg <<'EOF'
cat /home/postgres/server.log
psql -X -c "SELECT count(*) FROM demo_note" -c "DROP FUNCTION demo_crash()"
EOF

step "23. session_preload_libraries"
pg <<'EOF'
psql -X -c "ALTER SYSTEM SET session_preload_libraries = demo_ext" -c "SELECT pg_reload_conf()"
sleep 1
psql -X -c "SELECT pg_backend_pid()" -c "SELECT * FROM pg_get_loaded_modules() WHERE module_name = 'demo_ext'"
grep -E 'parameter "session_preload_libraries" changed to "demo_ext"|_PG_init' /home/postgres/server.log | tail -2
psql -X -c "ALTER SYSTEM RESET session_preload_libraries" -c "SELECT pg_reload_conf()"
EOF

step "24. trusted extension"
pg <<'EOF'
cat /usr/local/pgsql/share/extension/hstore.control
psql -X <<'SQL'
SELECT e.name, e.default_version, v.superuser, v.trusted FROM pg_available_extensions e JOIN pg_available_extension_versions v ON v.name = e.name AND v.version = e.default_version WHERE e.name IN ('demo_ext', 'hstore', 'pg_stat_statements') ORDER BY 1;
SELECT count(*) FILTER (WHERE v.trusted) AS trusted, count(*) AS total FROM pg_available_extensions e JOIN pg_available_extension_versions v ON v.name = e.name AND v.version = e.default_version;
CREATE ROLE app LOGIN;
CREATE DATABASE appdb;
GRANT CREATE ON DATABASE appdb TO app;
\c appdb
GRANT CREATE ON SCHEMA public TO app;
SQL
psql -X -U app -d appdb <<'SQL'
SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user;
CREATE EXTENSION demo_ext;
CREATE EXTENSION hstore;
SELECT extname, extowner::regrole FROM pg_extension WHERE extname = 'hstore';
SELECT proname, proowner::regrole FROM pg_proc WHERE proname = 'hstore_in';
SELECT 'a=>1, b=>2'::hstore -> 'b' AS b;
SQL
EOF

step "25. extension_control_path (PG18)"
pg <<'EOF'
cd ~/lab/pathdemo && make > /dev/null && echo "built pathdemo"
EOF
pgroot <<'EOF'
cd /home/postgres/lab/pathdemo && make install DESTDIR=/opt/pathdemo
EOF
pg <<'EOF'
psql -X <<'SQL'
SELECT name, setting, context FROM pg_settings WHERE name IN ('extension_control_path', 'dynamic_library_path');
CREATE EXTENSION pathdemo;
SET extension_control_path = '$system:/opt/pathdemo/usr/local/pgsql/share';
SELECT name, default_version, comment FROM pg_available_extensions WHERE name = 'pathdemo';
CREATE EXTENSION pathdemo;
SET dynamic_library_path = '$libdir:/opt/pathdemo/usr/local/pgsql/lib';
CREATE EXTENSION pathdemo;
SELECT pathdemo_hello();
SELECT probin FROM pg_proc WHERE proname = 'pathdemo_hello';
SQL
psql -X <<'SQL'
SELECT pathdemo_hello();
SELECT extname, extversion FROM pg_extension WHERE extname = 'pathdemo';
SELECT name, installed_version FROM pg_available_extensions WHERE name = 'pathdemo';
SQL
EOF

step "26. pg_dump와 DROP EXTENSION"
pg <<'EOF'
psql -X <<'SQL'
INSERT INTO demo_note VALUES (1, 'kept by pg_dump');
\dx+ demo_ext
DROP FUNCTION demo_add(integer, integer);
SQL
pg_dump -d postgres | grep -vE "^--|^$|^SET |^SELECT pg_catalog.set_config|^\\\\(un)?restrict"
createdb restoredb
pg_dump -d postgres | grep -n "CREATE EXTENSION"
pg_dump -d postgres | psql -X -q -d restoredb 2>&1 | head -8
psql -X -d restoredb <<'SQL'
INSERT INTO demo_note VALUES (2, 'important');
DROP EXTENSION demo_ext;
SELECT to_regclass('demo_note');
SQL
EOF

step "끝"
host "docker rm -f $CT"
