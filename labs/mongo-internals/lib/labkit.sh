#!/bin/bash
# MongoDB 인터널 실습 공용 하네스. 이미지는 ../Dockerfile(Rocky Linux 9 + MongoDB 8.0.32 RPM).
# 각 편의 lab.sh가 source해서 쓴다.
#   LAB  : 컨테이너/네트워크 이름 앞머리 (예: m05). 편마다 달라서 여러 실습이 겹치지 않는다
#   CT   : 기본 컨테이너 이름 (기본 ${LAB}-1)
#   OUT  : 결과 로그 파일 (기본 final-run.log)
# 셸 명령은 "$ 명령" 다음에 stdout+stderr와 [exit=N]을 남기고,
# mongosh 명령은 "프롬프트> 명령" 다음에 mongosh가 보여 주는 결과를 남긴다.

LAB=${LAB:?LAB을 정해야 한다 (예: LAB=m01)}
CT=${CT:-$LAB-1}
NET=${NET:-$LAB-net}
OUT=${OUT:-final-run.log}
IMAGE=${IMAGE:-mongo-internals:rocky9-8.0.32}
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMPD=$(mktemp -d)
: > "$OUT"

log()  { tee -a "$OUT"; }
step() { printf '\n######## %s\n\n' "$1" | log; }
note() { printf '# %s\n\n' "$1" | log; }

# 호스트에서 실행
host() {
  { echo "\$ $1"; bash -c "$1" 2>&1; echo "[exit=$?]"; echo; } | log
}

# 컨테이너 안(mongod 사용자)에서 실행. 표준입력으로 스크립트를 받는다. 인자: [컨테이너]
ct() {
  local c=${1:-$CT} script; script=$(cat)
  {
    [ "$c" != "$CT" ] && echo "# ($c)"
    echo "$script" | sed 's/^/$ /'
    printf '%s\n' "$script" | docker exec -i "$c" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# 컨테이너 안에서 root로 실행. 인자: [컨테이너]
ctroot() {
  local c=${1:-$CT} script; script=$(cat)
  {
    echo "$script" | sed "s/^/# ($c root) /"
    printf '%s\n' "$script" | docker exec -i -u root "$c" bash -s 2>&1
    echo "[exit=$?]"; echo
  } | log
}

# ---- mongosh ----
# 프롬프트를 마커로 바꾸는 rc 파일. RSPROMPT=1이면 레플리카셋 멤버 상태를 프롬프트에 넣는다
# (mongosh 기본 프롬프트 "rs0 [direct: primary] test>"와 같은 모양. 프롬프트마다 hello를 한 번 더 보낸다)
_rcfile() {
  cat <<'JS'
prompt = function () {
  let p = '';
  if (typeof LAB_RSPROMPT !== 'undefined') {
    try {
      const h = db.getSiblingDB('admin').runCommand({ hello: 1 });
      if (h.msg === 'isdbgrid') p = '[direct: mongos] ';
      else if (h.setName) p = h.setName + ' [direct: ' + (h.isWritablePrimary ? 'primary' : h.secondary ? 'secondary' : h.arbiterOnly ? 'arbiter' : 'other') + '] ';
    } catch (e) {}
  }
  return '\n@@PROMPT@@' + p + db.getName() + '>@@\n';
};
JS
  [ "${RSPROMPT:-0}" = 1 ] && echo 'var LAB_RSPROMPT = 1;'
}

# mongosh 대화형 세션처럼 실행한다. 표준입력으로 명령을 받는다. 인자: [컨테이너] [mongosh 인자...]
# 빈 줄과 "//"로 시작하는 줄은 보내지 않는다(보내면 프롬프트가 하나 더 생겨 짝이 어긋난다).
msh() {
  local c=${1:-$CT}; shift
  local stmts=$TMPD/stmts raw=$TMPD/raw
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*//' > "$stmts"
  _rcfile | docker exec -i "$c" bash -c 'cat > /tmp/labrc.js'
  docker exec -i "$c" mongosh --quiet --shell --file /tmp/labrc.js "$@" < "$stmts" > "$raw" 2>&1
  {
    [ "$c" != "$CT" ] && echo "# ($c) mongosh $*"
    python3 "$LIB/replfmt.py" "$stmts" "$raw"
    echo
  } | log
}

# ---- 동시에 여러 mongosh 세션을 유지하는 도구 ----
# sess_start A [컨테이너] [mongosh 인자...] : 세션 A를 백그라운드로 연다
# sess A "명령" [초]   : 세션 A에 명령을 보내고, 그 뒤로 새로 생긴 출력만 기록한다
# sess_wait A [초]     : 보내는 것 없이, 앞서 보낸 명령의 출력이 새로 생겼는지 기록한다
# 세션 출력은 "[세션 A] 프롬프트> 명령" 줄 다음에 결과가 온다.
# (macOS 기본 bash 3.2는 연관 배열이 없어서 세션별 상태를 변수 이름으로 나눈다)
sess_start() {
  local n=$1 c=${2:-$CT}; shift; shift
  eval "SESS_CT_$n=$c SESS_SHOWN_$n=0"
  : > "$TMPD/sess_$n.stmts"
  _rcfile | docker exec -i "$c" bash -c 'cat > /tmp/labrc.js'
  docker exec "$c" bash -c ": > /tmp/sess_$n.in; : > /tmp/sess_$n.out"
  docker exec -d "$c" bash -c "tail -n +1 -f /tmp/sess_$n.in | mongosh --quiet --shell --file /tmp/labrc.js $* > /tmp/sess_$n.out 2>&1"
  sleep 2
  printf '# 세션 %s 시작 (%s): mongosh %s\n\n' "$n" "$c" "$*" | log
}
_sess_flush() {
  local n=$1 cv="SESS_CT_$1" sv="SESS_SHOWN_$1" lines total
  docker exec "${!cv}" cat "/tmp/sess_$n.out" > "$TMPD/sess_$n.raw"
  python3 "$LIB/replfmt.py" "$TMPD/sess_$n.stmts" "$TMPD/sess_$n.raw" "$n" > "$TMPD/sess_$n.fmt"
  total=$(wc -l < "$TMPD/sess_$n.fmt" | tr -d ' ')
  { tail -n +$(( ${!sv} + 1 )) "$TMPD/sess_$n.fmt"; echo; } | log
  eval "$sv=$total"
}
sess() {
  local n=$1 cmd=$2 wait=${3:-1} cv="SESS_CT_$1"
  printf '%s\n' "$cmd" >> "$TMPD/sess_$n.stmts"
  printf '%s\n' "$cmd" | docker exec -i "${!cv}" bash -c "cat >> /tmp/sess_$n.in"
  sleep "$wait"
  _sess_flush "$n"
}
sess_wait() {
  local n=$1 wait=${2:-1}
  sleep "$wait"
  printf '[세션 %s] (앞 명령의 결과를 기다림)\n' "$n" | log
  _sess_flush "$n"
}
sess_end() {
  local n=$1 cv="SESS_CT_$1"
  docker exec "${!cv}" bash -c "echo 'exit' >> /tmp/sess_$n.in; sleep 0.5; pkill -f 'tail -n \\+1 -f /tmp/sess_$n.in' || true"
}

# ---- 컨테이너와 mongod ----
# 이 실습(LAB)의 컨테이너와 네트워크를 모두 지운다
lab_clean() {
  local id
  for id in $(docker ps -aq --filter "name=^${LAB}-"); do docker rm -f "$id" >/dev/null 2>&1; done
  docker network rm "$NET" >/dev/null 2>&1
  true
}

# 새 컨테이너를 띄운다. 인자: 이름 [docker run 추가 옵션...]
# 같은 네트워크의 다른 컨테이너는 이름(=hostname)으로 찾는다.
fresh_node() {
  local name=$1; shift
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  docker rm -f "$name" >/dev/null 2>&1
  host "docker run -d --init --name $name --hostname $name --network $NET $* $IMAGE sleep infinity"
}

# mongod를 띄운다. 인자: 컨테이너 [mongod 추가 옵션...]. 로그는 /data/mongod.log(JSON 한 줄에 하나)
start_mongod() {
  local c=$1; shift
  ct "$c" <<EOF
mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork $* | grep -E 'forked|ERROR'
EOF
}

# 첫 컨테이너 하나에 standalone mongod까지. 인자: [mongod 추가 옵션...]
fresh_standalone() {
  lab_clean
  fresh_node "$CT"
  ct <<'EOF'
cat /etc/rocky-release
mongod --version | head -1
mongosh --version
EOF
  start_mongod "$CT" "$@"
}

# 레플리카셋. 인자: 셋 이름, 멤버 수 [mongod 추가 옵션...]. 컨테이너는 ${LAB}-1..N, 모두 27017 포트.
# rs.initiate는 하지 않는다(편마다 멤버 설정이 달라서). RS_MEMBERS에 host 목록을 남긴다.
fresh_replset() {
  local set=$1 n=$2 i; shift; shift
  lab_clean
  RS_MEMBERS=""
  for i in $(seq 1 "$n"); do
    fresh_node "$LAB-$i"
    RS_MEMBERS="$RS_MEMBERS $LAB-$i:27017"
  done
  ct <<'EOF'
cat /etc/rocky-release
mongod --version | head -1
mongosh --version
EOF
  for i in $(seq 1 "$n"); do
    start_mongod "$LAB-$i" --replSet "$set" "$@"
  done
}

# 조건이 참이 될 때까지 기다린다(기록하지 않음). 인자: 컨테이너, mongosh 식, [최대 초]
wait_for() {
  local c=$1 expr=$2 max=${3:-60} i
  for i in $(seq 1 "$max"); do
    docker exec "$c" mongosh --quiet --eval "quit(($expr) ? 0 : 1)" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "# wait_for 시간 초과: $c: $expr" | log
  return 1
}

trap 'rm -rf "$TMPD"' EXIT

# 레플리카셋 멤버 중 primary가 생길 때까지 기다리고 그 컨테이너 이름을 PRIMARY에 넣는다(기록하지 않음).
# 인자: 멤버 수 [최대 초]
wait_primary() {
  local n=$1 max=${2:-60} i j
  PRIMARY=""
  for i in $(seq 1 "$max"); do
    for j in $(seq 1 "$n"); do
      if docker exec "$LAB-$j" mongosh --quiet --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
        PRIMARY=$LAB-$j; return 0
      fi
    done
    sleep 1
  done
  echo "# wait_primary 시간 초과" | log
  return 1
}
