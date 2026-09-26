#!/bin/bash
# PostgreSQL 인터널 실습 공용 하네스. 이미지는 ../Dockerfile(Rocky Linux 9).
# 각 챕터의 lab.sh가 source해서 쓴다.
#   CT   : 컨테이너 이름 (기본 pglab)
#   OUT  : 결과 로그 파일 (기본 final-run.log)
# 모든 명령은 "$ 명령" 다음에 stdout+stderr와 [exit=N]을 남긴다.

CT=${CT:-pglab}
OUT=${OUT:-final-run.log}
IMAGE=${IMAGE:-pg-internals:rocky9-rel18}
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
cat /etc/rocky-release
postgres --version
initdb -D \$PGDATA $* > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
EOF
}

# ---- 동시에 여러 psql 세션을 유지하는 도구 ----
# sess_start A        : 세션 A를 백그라운드로 연다 (입력 /tmp/sess_A.in, 출력 /tmp/sess_A.out)
# sess A "SQL" [초]   : 세션 A에 SQL을 보내고, 그 뒤로 새로 생긴 출력만 기록한다
# sess_wait A [초]    : 보내는 것 없이, 앞서 기다리던 명령의 출력이 새로 생겼는지 기록한다
# 세션 출력에는 결과만 남고, 보낸 SQL은 "[세션 X] $ " 줄로 기록된다.
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
  printf '# 세션 %s 시작: psql -X %s\n\n' "$n" "$*" | log
}
sess() {
  local n=$1 sql=$2 wait=${3:-1}
  printf '%s\n' "$sql" | docker exec -i "$CT" bash -c "cat >> /tmp/sess_$n.in"
  sleep "$wait"
  _sess_flush "$n" "$(printf '%s\n' "$sql" | sed "s/^/[세션 $n] \$ /")"
}
sess_wait() {
  local n=$1 wait=${2:-1}
  sleep "$wait"
  _sess_flush "$n" "[세션 $n] (앞 명령의 결과를 기다림)"
}
sess_end() {
  local n=$1
  docker exec "$CT" bash -c "echo '\\q' >> /tmp/sess_$n.in; sleep 0.5; pkill -f 'tail -n \\+1 -f /tmp/sess_$n.in' || true"
}
