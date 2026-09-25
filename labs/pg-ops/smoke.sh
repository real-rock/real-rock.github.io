#!/bin/bash
# 실습 이미지가 운영 연재의 전제를 만족하는지 확인한다. 하나라도 어긋나면 exit 1.
cd "$(dirname "$0")"
export CT=pgops-smoke OUT=out/smoke.txt
source lib/labkit.sh

fresh_cluster
env_info

fail=0
sql() { docker exec "$CT" psql -XAtc "$1" 2>&1; }
assert_eq() {  # 설명 기대값 실제값
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

assert_eq "Rocky Linux 9"    1    "$(docker exec "$CT" grep -c 'release 9' /etc/rocky-release 2>&1)"
assert_eq "server major 18"  18   "$(sql 'SHOW server_version_num' | cut -c1-2)"
assert_eq "data_checksums"   on   "$(sql 'SHOW data_checksums')"
for e in pg_stat_statements pgstattuple amcheck pg_buffercache pageinspect; do sql "CREATE EXTENSION $e" >/dev/null; done
assert_eq "contrib extensions" 5  "$(sql "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_stat_statements','pgstattuple','amcheck','pg_buffercache','pageinspect')")"
assert_eq "auto_explain"     LOAD "$(sql "LOAD 'auto_explain'")"
assert_eq "pgbench 18"       1    "$(docker exec "$CT" pgbench --version 2>&1 | grep -c 'PostgreSQL) 18')"

docker rm -f "$CT" >/dev/null 2>&1
exit $fail
