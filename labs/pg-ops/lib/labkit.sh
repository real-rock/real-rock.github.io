#!/bin/bash
# PostgreSQL 운영 실습 공용 하네스. 각 시나리오의 reproduce.sh가 source해서 쓴다.
#   CT    : 컨테이너 이름 (기본 pgops)
#   IMAGE : 이미지 (기본 pg-ops:rocky9-pg18)
#   OUT   : 캡처 파일 (필수)
# 셸 명령은 "$ 명령", SQL은 "postgres=# SQL", 세션 SQL은 "A=# SQL"로 기록하고 그 뒤에 출력을 남긴다.

CT=${CT:-pgops}
IMAGE=${IMAGE:-pg-ops:rocky9-pg18}
: "${OUT:?OUT(캡처 파일)을 정해야 한다}"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

log()  { tee -a "$OUT"; }
step() { printf '\n######## %s\n\n' "$1" | log; }
note() { printf '# %s\n\n' "$1" | log; }

# 호스트에서 실행
host() {
  { echo "\$ $1"; bash -c "$1" 2>&1; echo "[exit=$?]"; echo; } | log
}

# 컨테이너 안(postgres 사용자)에서 실행. 표준입력으로 스크립트를 받는다.
pg() {
  local script; script=$(cat)
  {
    printf '%s\n' "$script" | sed 's/^/$ /'
    printf '%s\n' "$script" | docker exec -i "$CT" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# 컨테이너 안에서 root로 실행
pgroot() {
  local script; script=$(cat)
  {
    printf '%s\n' "$script" | sed 's/^/# (root) /'
    printf '%s\n' "$script" | docker exec -i -u root "$CT" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# SQL 한 문장을 psql 프롬프트와 함께 기록하고 실행한다. 인자: SQL [psql 옵션...]
# 프롬프트 이름은 PROMPT(기본 postgres)로 바꿀 수 있다. 서버가 여럿일 때 "primary=# ", "standby=# "처럼 구분한다.
q() {
  local sql=$1; shift
  {
    printf '%s\n' "$sql" | awk -v p="${PROMPT:-postgres}" 'NR==1 { print p "=# " $0; next } { print p "-# " $0 }'
    docker exec "$CT" psql -X "$@" -c "$sql" 2>&1
    echo
  } | log
}

# 새 컨테이너를 띄우고 initdb, 서버 기동까지. 인자는 docker run 옵션으로 넘긴다 (예: --memory 512m)
fresh_cluster() {
  docker rm -f "$CT" >/dev/null 2>&1
  host "docker run -d --init --name $CT --hostname $CT $* $IMAGE sleep infinity"
  pg <<'SH'
initdb -D $PGDATA > /var/lib/pgsql/initdb.log 2>&1 && echo "initdb ok"
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH
}

env_info() {
  pg <<'SH'
cat /etc/rocky-release
rpm -q postgresql18-server postgresql18-contrib
postgres --version
uname -r
SH
}

# ---- 동시에 여러 psql 세션을 유지하는 도구 ----
# sess_start A        : 세션 A를 백그라운드로 연다 (입력 /tmp/sess_A.in, 출력 /tmp/sess_A.out)
# sess A "SQL" [초]   : 세션 A에 SQL을 보내고, 그 뒤로 새로 생긴 출력만 기록한다
# sess_wait A [초]    : 보내는 것 없이, 앞서 기다리던 명령의 출력이 새로 생겼는지 기록한다
# sess_end A          : 세션 A를 닫는다
# 보낸 SQL은 "A=# SQL" 줄로 기록된다. 세션 psql은 표준입력으로 돌기 때문에 에러에 "psql:<stdin>:N: " 접두어가 붙는다.
# (macOS 기본 bash 3.2는 연관 배열이 없어서 세션별 오프셋을 변수 이름으로 나눈다)
_sess_flush() {
  local n=$1 label=$2 var="SESS_OFF_$1" total
  total=$(docker exec "$CT" bash -c "wc -c < /tmp/sess_$n.out" | tr -d ' ')
  {
    printf '%s\n' "$label"
    docker exec "$CT" bash -c "tail -c +$(( ${!var} + 1 )) /tmp/sess_$n.out | head -c $(( total - ${!var} ))"
    echo
  } | log
  eval "$var=$total"
}
sess_start() {
  local n=$1; shift
  docker exec "$CT" bash -c ": > /tmp/sess_$n.in; : > /tmp/sess_$n.out"
  docker exec -d "$CT" bash -c "tail -n +1 -f /tmp/sess_$n.in | psql -X $* > /tmp/sess_$n.out 2>&1"
  eval "SESS_OFF_$n=0"
  sleep 1
  note "세션 $n 시작: psql -X $*"
}
sess() {
  local n=$1 sql=$2 wait=${3:-1}
  printf '%s\n' "$sql" | docker exec -i "$CT" bash -c "cat >> /tmp/sess_$n.in"
  sleep "$wait"
  _sess_flush "$n" "$(printf '%s\n' "$sql" | awk -v n="$n" 'NR==1 { print n "=# " $0; next } { print n "-# " $0 }')"
}
sess_wait() {
  local n=$1 wait=${2:-1}
  sleep "$wait"
  _sess_flush "$n" "# 세션 $n: 앞 명령의 결과를 기다림"
}
sess_end() {
  local n=$1
  docker exec "$CT" bash -c "echo '\\q' >> /tmp/sess_$n.in; sleep 0.5; pkill -f 'tail -n \\+1 -f /tmp/sess_$n.in' || true"
}
