#!/bin/bash
# MongoDB 인터널 6편(Primary 선출 과정) 실습. 새 컨테이너 3대(+ 클라이언트 1대)에서 처음부터 끝까지 실행한다.
cd "$(dirname "$0")"
LAB=m06
source ../lib/labkit.sh
RSPROMPT=1

URI="mongodb://m06-1:27017,m06-2:27017,m06-3:27017/test?replicaSet=rs0"
step "0. 실습 환경: 3노드 레플리카셋과 클라이언트"
fresh_replset rs0 3
fresh_node m06-c
msh <<'JS'
rs.initiate({_id: "rs0", members: [{_id: 0, host: "m06-1:27017"}, {_id: 1, host: "m06-2:27017"}, {_id: 2, host: "m06-3:27017"}]})
JS
wait_primary 3
wait_for "$PRIMARY" 'rs.status().members.every(m => m.state === 1 || m.state === 2)' 90
P0=$PRIMARY
echo "# primary: $P0" | log
for n in 1 2 3; do ct m06-$n <<'EOF'
cat > /tmp/elog.jq <<'JQ'
select(.msg | test("Starting an election|dry run|Dry election|Election succeeded|catch-up mode|Transition to primary complete|priority takeover|Stepping down from primary|see a majority|replSetStepUp|Handing off election|kill user operations|Replica set state transition"))
| {t: .t."$date"[11:23], msg, attr: (.attr | {oldState, newState, term, newTerm, when, target} | with_entries(select(.value != null)))}
JQ
EOF
done

step "1. 선출 설정과 term"
msh "$P0" <<'JS'
rs.conf().protocolVersion
var s = rs.conf().settings; ({heartbeatIntervalMillis: s.heartbeatIntervalMillis, heartbeatTimeoutSecs: s.heartbeatTimeoutSecs, electionTimeoutMillis: s.electionTimeoutMillis, catchUpTimeoutMillis: s.catchUpTimeoutMillis, catchUpTakeoverDelayMillis: s.catchUpTakeoverDelayMillis})
rs.conf().members.map(m => ({host: m.host, priority: m.priority, votes: m.votes}))
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, electionDate: m.electionDate}))})
rs.status().electionCandidateMetrics
JS

step "2. rs.stepDown()"
msh "$P0" <<'JS'
db.t.insertOne({before: "stepDown"})
rs.stepDown()
db.t.insertOne({after: "stepDown"})
JS
wait_primary 3
P1=$PRIMARY
echo "# 새 primary: $P1" | log
msh "$P1" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
var m = rs.status().electionCandidateMetrics; ({lastElectionReason: m.lastElectionReason, electionTerm: m.electionTerm, numVotesNeeded: m.numVotesNeeded, priorPrimaryMemberId: m.priorPrimaryMemberId, numCatchUpOps: m.numCatchUpOps})
JS
ct "$P0" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -3
EOF
ct "$P1" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -9
EOF

step "3. primary를 kill -9: electionTimeout 선출"
ct m06-c <<EOF
cat > /tmp/w.js <<'JS'
let i = 0; const end = Date.now() + 40000;
while (Date.now() < end) {
  const t = Date.now();
  try {
    db.getCollection(C).insertOne({i: i});
    const ms = Date.now() - t;
    if (ms > 300) print(new Date().toISOString().slice(11, 23), "i=" + i, "ok after", ms, "ms");
  } catch (e) {
    print(new Date().toISOString().slice(11, 23), "i=" + i, "error after", Date.now() - t, "ms:", e.codeName || e.name, "-", e.message);
  }
  i++; sleep(100);
}
print("done", i, "inserts,", db.getCollection(C).countDocuments(), "docs");
JS
nohup mongosh "$URI" --quiet --eval 'var C = "retry"' --file /tmp/w.js > /tmp/retry.log 2>&1 < /dev/null &
nohup mongosh "$URI&retryWrites=false" --quiet --eval 'var C = "noretry"' --file /tmp/w.js > /tmp/noretry.log 2>&1 < /dev/null &
sleep 3
EOF
PIDK=$(docker exec "$P1" pgrep -x mongod)
ct "$P1" <<EOF
kill -9 $PIDK
date -u +%T.%3N
EOF
sleep 5
wait_primary 3
P2=$PRIMARY
echo "# 새 primary: $P2" | log
msh "$P2" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
rs.status().electionCandidateMetrics
JS
for n in 1 2 3; do c=m06-$n; [ "$c" = "$P1" ] && continue; [ "$c" = "$P2" ] && continue; VOTER=$c; done
msh "$VOTER" <<'JS'
rs.status().electionParticipantMetrics
JS
ct "$P2" <<EOF
jq -c 'select(.msg=="Heartbeat failed after max retries" and .attr.target=="$P1:27017")|{t:.t."\$date"[11:23],msg,attr:{target:.attr.target,error:.attr.error.errmsg}}' /data/mongod.log | head -1
jq -c -f /tmp/elog.jq /data/mongod.log | tail -10
EOF
ct "$VOTER" <<EOF
jq -c 'select(.msg=="Responding to vote request")|{t:.t."\$date",msg,attr:(.attr|{request,response})}' /data/mongod.log | tail -2
EOF
sleep 30
ct m06-c <<'EOF'
cat /tmp/retry.log
cat /tmp/noretry.log
EOF

step "4. 죽은 멤버를 다시 켜면 secondary로 돌아온다"
ct "$P1" <<'EOF'
mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0 | grep -E 'forked|ERROR'
EOF
wait_for "$P2" 'rs.status().members.every(m => m.state === 1 || m.state === 2)' 90
msh "$P2" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
JS

step "5. priority takeover"
T=$P1
TI=$(( ${T#m06-} - 1 ))
echo "# priority 3을 줄 멤버: $T (members[$TI])" | log
msh "$P2" <<JS
var c = rs.conf(); c.members[$TI].priority = 3; rs.reconfig(c).ok
JS
wait_for "$T" 'db.hello().isWritablePrimary' 90
msh "$T" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
var m = rs.status().electionCandidateMetrics; ({lastElectionReason: m.lastElectionReason, electionTerm: m.electionTerm, priorityAtElection: m.priorityAtElection})
JS
ct "$T" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -10
EOF
ct "$P2" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -3
EOF

step "6. 네트워크 분할: primary를 떼어 낸다"
P3=$T
ct m06-c <<EOF
nohup mongosh "$URI" --quiet --eval 'var C = "retry2"' --file /tmp/w.js > /tmp/retry2.log 2>&1 < /dev/null &
nohup mongosh "$URI&retryWrites=false" --quiet --eval 'var C = "noretry2"' --file /tmp/w.js > /tmp/noretry2.log 2>&1 < /dev/null &
sleep 3
EOF
host "docker network disconnect m06-net $P3 && docker exec m06-c date -u +%T.%3N"
sleep 15
msh "$P3" <<'JS'
var st = rs.status(); ({term: st.term, myState: st.myState, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
db.t.insertOne({from: "isolated"})
JS
ct "$P3" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -4
EOF
for n in 1 2 3; do c=m06-$n; [ "$c" = "$P3" ] && continue; OTHER=$c; break; done
wait_primary 3
P4=$PRIMARY
echo "# 나머지 쪽의 primary: $P4" | log
msh "$P4" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
rs.status().electionCandidateMetrics.lastElectionReason
JS
host "docker network connect m06-net $P3 && docker exec m06-c date -u +%T.%3N"
wait_for "$P4" 'rs.status().members.every(m => m.health === 1)' 60
sleep 3
msh "$P4" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
JS
wait_for "$P3" 'db.hello().isWritablePrimary' 90
msh "$P3" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
rs.status().electionCandidateMetrics.lastElectionReason
JS
ct "$P3" <<'EOF'
jq -c -f /tmp/elog.jq /data/mongod.log | tail -12
jq -c 'select(.msg|test("[Rr]ollback"))|{t:.t."$date"[11:23],msg}' /data/mongod.log | head -5
EOF
sleep 20
ct m06-c <<'EOF'
cat /tmp/retry2.log
cat /tmp/noretry2.log
EOF

step "7. 과반이 없으면 primary도 없다"
LEFT=$P3
for n in 1 2 3; do c=m06-$n; [ "$c" = "$LEFT" ] && continue; ct "$c" <<'EOF'
mongod --dbpath /data/db --shutdown | tail -1
EOF
done
sleep 15
msh "$LEFT" <<'JS'
var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
db.t.insertOne({x: "no majority"})
db.t.countDocuments()
JS
ct "$LEFT" <<EOF
jq -c -f /tmp/elog.jq /data/mongod.log | tail -4
jq -c 'select(.msg=="Not starting an election, since we are not electable")|{t:.t."\$date",msg,attr}' /data/mongod.log | tail -1
EOF

lab_clean
