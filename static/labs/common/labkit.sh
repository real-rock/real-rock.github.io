#!/bin/bash
# PostgreSQL 인터널 실습 공용 하네스.
# 각 챕터의 lab.sh가 source해서 쓴다.
#   CT   : 컨테이너 이름 (기본 pglab)
#   OUT  : 결과 로그 파일 (기본 final-run.log)
# 모든 명령은 "$ 명령" 다음에 stdout+stderr와 [exit=N]을 남긴다.

CT=${CT:-pglab}
OUT=${OUT:-final-run.log}
IMAGE=${IMAGE:-pg-internals:rel18-lab}
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
    echo "$script" | sed 's/^/$ /'
    printf '%s\n' "$script" | docker exec -i "$CT" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# 컨테이너 안에서 root로 실행
pgroot() {
  local script; script=$(cat)
  {
    echo "$script" | sed 's/^/# (root) /'
    printf '%s\n' "$script" | docker exec -i -u root "$CT" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# 새 컨테이너를 띄우고 initdb까지. 인자: 추가 initdb 옵션
fresh_cluster() {
  docker rm -f "$CT" >/dev/null 2>&1
  host "docker run -d --init --name $CT --hostname $CT $IMAGE sleep infinity"
  pg <<EOF
postgres --version
initdb -D \$PGDATA $* > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
EOF
}

# ---- 동시에 여러 psql 세션을 유지하는 도구 ----
# sess_start A        : 세션 A를 백그라운드로 연다 (입력 /tmp/sess_A.in, 출력 /tmp/sess_A.out)
# sess A "SQL"        : 세션 A에 SQL을 보내고, 그 SQL로 새로 생긴 출력만 기록한다
# 출력은 psql -e(에코)라서 실행된 SQL도 함께 보인다.
declare -A SESS_OFF
sess_start() {
  local n=$1; shift
  docker exec "$CT" bash -c ": > /tmp/sess_$n.in; : > /tmp/sess_$n.out"
  docker exec -d "$CT" bash -c "tail -n +1 -f /tmp/sess_$n.in | psql -X -e -v ON_ERROR_STOP=0 $* > /tmp/sess_$n.out 2>&1"
  SESS_OFF[$n]=0
  sleep 1
  printf '# 세션 %s 시작: psql -X -e %s\n\n' "$n" "$*" | log
}
sess() {
  local n=$1 sql=$2 wait=${3:-1}
  printf '%s\n' "$sql" | docker exec -i "$CT" bash -c "cat >> /tmp/sess_$n.in"
  sleep "$wait"
  local total; total=$(docker exec "$CT" bash -c "wc -c < /tmp/sess_$n.out" | tr -d ' ')
  {
    echo "[세션 $n] \$ $sql" | sed '2,$s/^/[세션 '"$n"'] $ /'
    docker exec "$CT" bash -c "tail -c +$(( ${SESS_OFF[$n]} + 1 )) /tmp/sess_$n.out"
    echo
  } | log
  SESS_OFF[$n]=$total
}
sess_end() {
  local n=$1
  docker exec "$CT" bash -c "echo '\\q' >> /tmp/sess_$n.in; sleep 0.5; pkill -f 'tail -n \\+1 -f /tmp/sess_$n.in' || true"
}
