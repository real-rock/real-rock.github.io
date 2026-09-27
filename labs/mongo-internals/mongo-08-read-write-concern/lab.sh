#!/bin/bash
# MongoDB 인터널 8편(Read/Write Concern) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 3노드 레플리카셋 m08-1(priority 2, 처음 primary), m08-2, m08-3. 끝에 arbiter m08-4를 더해 본다.
# secondary를 kill -STOP으로 15초쯤 멈추는 동안 primary가 물러나거나(Can't see a majority)
# 깨어난 secondary가 곧바로 선거를 시작하지 않도록 electionTimeoutMillis를 30초로 늘렸다.
cd "$(dirname "$0")"
LAB=m08
RSPROMPT=1
source ../lib/labkit.sh

mpid() { docker exec "$1" pgrep -x mongod; }

# m08-2나 m08-3 가운데 primary가 생길 때까지 기다린다(기록하지 않음). NEWP에 이름을 남긴다
wait_new_primary() {
  local i c
  NEWP=""
  for i in $(seq 1 120); do
    for c in $LAB-2 $LAB-3; do
      if docker exec "$c" mongosh --quiet --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
        NEWP=$c; return 0
      fi
    done
    sleep 1
  done
  echo "# wait_new_primary 시간 초과" | log
  return 1
}

step "0. 실습 환경: 3노드 레플리카셋"
fresh_replset rs0 3
msh <<'JS'
rs.initiate({_id: 'rs0', settings: {electionTimeoutMillis: 30000}, members: [{_id: 0, host: 'm08-1:27017', priority: 2}, {_id: 1, host: 'm08-2:27017'}, {_id: 2, host: 'm08-3:27017'}]})
JS
wait_for $LAB-1 'db.hello().isWritablePrimary' 90
wait_for $LAB-1 'rs.status().members.filter(m => m.stateStr == "SECONDARY").length == 2' 90
msh <<'JS'
rs.status().members.map(m => m.name + ' ' + m.stateStr)
JS

step "1. 기본 read/write concern"
msh <<'JS'
db.adminCommand({getDefaultRWConcern: 1})
rs.conf().writeConcernMajorityJournalDefault
rs.conf().settings.electionTimeoutMillis
JS

step "2. write concern을 붙인 쓰기와 응답"
msh <<'JS'
db.t.insertOne({_id: 'majority-1', v: 1}, {writeConcern: {w: 'majority'}})
db.runCommand({insert: 't', documents: [{_id: 'majority-2', v: 2}], writeConcern: {w: 'majority', wtimeout: 5000}})
db.runCommand({insert: 't', documents: [{_id: 'w1-1', v: 3}], writeConcern: {w: 1}})
JS

step "2b. snapshot read: 과거 시점(atClusterTime)으로 읽기"
msh <<'JS'
const t1 = db.runCommand({insert: 'snap', documents: [{_id: 1, v: 'old'}]}).operationTime; t1
db.snap.updateOne({_id: 1}, {$set: {v: 'new'}})
db.snap.find()
db.runCommand({find: 'snap', filter: {_id: 1}, readConcern: {level: 'snapshot', atClusterTime: t1}}).cursor.firstBatch
db.adminCommand({getParameter: 1, minSnapshotHistoryWindowInSeconds: 1}).minSnapshotHistoryWindowInSeconds
JS

step "3. w:1, w:majority, j:true 지연 비교 (같은 실행 안에서의 비교)"
msh <<'JS'
function bench(wc, n) { const t0 = Date.now(); for (let i = 0; i < n; i++) { db.bench.insertOne({i: i}, {writeConcern: wc}); } return (Date.now() - t0) + ' ms / ' + n; }
bench({w: 1}, 300)
bench({w: 1, j: true}, 300)
bench({w: 'majority'}, 300)
bench({w: 3}, 300)
JS

step "4. commit point: replSetGetStatus의 optimes"
msh <<'JS'
const o = db.adminCommand({replSetGetStatus: 1}).optimes; ({lastCommittedOpTime: o.lastCommittedOpTime, readConcernMajorityOpTime: o.readConcernMajorityOpTime, appliedOpTime: o.appliedOpTime, writtenOpTime: o.writtenOpTime, durableOpTime: o.durableOpTime})
JS

step "5. secondary 둘을 멈추면: w:1은 성공, w:majority는 wtimeout"
sess_start A $LAB-1
P2=$(mpid $LAB-2); P3=$(mpid $LAB-3)
ctroot $LAB-2 <<EOF
kill -STOP $P2
ps -o pid,stat,comm -p $P2
EOF
ctroot $LAB-3 <<EOF
kill -STOP $P3
ps -o pid,stat,comm -p $P3
EOF
sess A "db.t.insertOne({_id: 'w1-stalled', v: 10}, {writeConcern: {w: 1}})" 1
sess A "db.runCommand({insert: 't', documents: [{_id: 'maj-stalled', v: 11}], writeConcern: {w: 'majority', wtimeout: 2000}})" 4
sess A "db.runCommand({insert: 't', documents: [{_id: 'default-stalled', v: 12}], maxTimeMS: 2000})" 4
sess A "db.t.find({v: {\$gte: 10}}).readConcern('local').toArray()" 1
sess A "db.t.find({v: {\$gte: 10}}).readConcern('majority').toArray()" 1
sess A "const s = db.adminCommand({replSetGetStatus: 1}); ({lastCommittedOpTime: s.optimes.lastCommittedOpTime.ts, appliedOpTime: s.optimes.appliedOpTime.ts, members: s.members.map(m => m.name + ' ' + m.stateStr + ' ' + (m.health === 1 ? 'up' : 'down'))})" 1
sess A "db.runCommand({find: 't', filter: {_id: 'majority-1'}, readConcern: {level: 'linearizable'}, maxTimeMS: 2000})" 4
ctroot $LAB-2 <<EOF
kill -CONT $P2
EOF
ctroot $LAB-3 <<EOF
kill -CONT $P3
EOF
sess_end A
sleep 3
msh <<'JS'
db.t.find({v: {$gte: 10}}).readConcern('majority').toArray()
db.getSiblingDB('local').oplog.rs.find({op: 'n', 'o.msg': 'linearizable read'}, {ts: 1, op: 1, o: 1}).toArray()
db.runCommand({find: 't', filter: {_id: 'majority-1'}, readConcern: {level: 'linearizable'}, maxTimeMS: 2000}).cursor.firstBatch
rs.status().members.map(m => m.name + ' ' + m.stateStr)
JS

step "6. causal consistency: 멈춘 secondary에서 afterClusterTime 읽기"
msh $LAB-3 <<'JS'
db.fsyncLock()
JS
msh <<'JS'
const r = db.runCommand({insert: 't', documents: [{_id: 'causal-1', v: 20}], writeConcern: {w: 'majority'}}); r
r.operationTime
JS
OPTIME=$(docker exec $LAB-1 mongosh --quiet --eval "const e = db.getSiblingDB('local').oplog.rs.find({'o._id': 'causal-1'}).sort({\$natural: -1}).limit(1).next(); print(e.ts.t + ',' + e.ts.i)")
msh $LAB-3 <<JS
db.t.find({_id: 'causal-1'}).readConcern('local').toArray()
db.t.find({_id: 'causal-1'}).readConcern('majority').toArray()
db.runCommand({find: 't', filter: {_id: 'causal-1'}, readConcern: {level: 'majority', afterClusterTime: Timestamp({t: ${OPTIME%,*}, i: ${OPTIME#*,}})}, maxTimeMS: 3000})
JS
sess_start B $LAB-3
sess B "db.runCommand({find: 't', filter: {_id: 'causal-1'}, readConcern: {level: 'majority', afterClusterTime: Timestamp({t: ${OPTIME%,*}, i: ${OPTIME#*,}})}}).cursor.firstBatch" 3
msh $LAB-3 <<'JS'
db.fsyncUnlock()
JS
sess_wait B 2
sess_end B

step "7. causal consistency 세션: 드라이버가 afterClusterTime을 붙인다"
for c in $LAB-2 $LAB-3; do
  docker exec $c mongosh --quiet --eval 'db.setProfilingLevel(0, {slowms: -1})' >/dev/null
done
note "m08-2, m08-3의 slowms를 -1로 두어 받은 명령을 모두 로그에 남긴다"
msh $LAB-1 "mongodb://m08-1:27017,m08-2:27017,m08-3:27017/test?replicaSet=rs0" <<'JS'
const s = db.getMongo().startSession({causalConsistency: true}); const sdb = s.getDatabase('test')
sdb.t.insertOne({_id: 'causal-2', v: 21})
s.getOperationTime()
sdb.t.find({_id: 'causal-2'}).readPref('secondary').readConcern('majority').toArray()
JS
for c in $LAB-2 $LAB-3; do
ct $c <<'EOF'
jq -c 'select(.msg == "Slow query" and .attr.command.find == "t" and .attr.command.filter._id == "causal-2") | {readConcern: .attr.command.readConcern, readPreference: .attr.command["$readPreference"]}' /data/mongod.log
EOF
done
for c in $LAB-2 $LAB-3; do
  docker exec $c mongosh --quiet --eval 'db.setProfilingLevel(0, {slowms: 100})' >/dev/null
done

step "8. rollback 준비: priority를 되돌리고 m08-1을 primary로"
msh <<'JS'
const cfg = rs.conf(); cfg.members[0].priority = 1; rs.reconfig(cfg).ok
db.t.insertOne({_id: 'before-partition', v: 30}, {writeConcern: {w: 'majority'}})
rs.status().members.map(m => m.name + ' ' + m.stateStr)
JS

step "9. primary를 네트워크에서 떼어 내고 w:1로 쓰기"
host "docker network disconnect $NET $LAB-1"
msh <<'JS'
db.hello().isWritablePrimary
db.t.insertOne({_id: 'lost-w1', v: 31}, {writeConcern: {w: 1}})
db.t.updateOne({_id: 'before-partition'}, {$set: {v: 300}}, {writeConcern: {w: 1}})
db.t.insertOne({_id: 'lost-majority-timeout', v: 32}, {writeConcern: {w: 'majority', wtimeout: 2000}})
db.t.find({v: {$gte: 30}}).toArray()
JS

step "10. 나머지 둘이 새 primary를 뽑고, 새 primary에 다른 쓰기"
wait_new_primary
echo "# 새 primary: $NEWP" | log
msh $NEWP <<'JS'
db.hello().isWritablePrimary
db.t.insertOne({_id: 'after-failover', v: 40}, {writeConcern: {w: 'majority'}})
db.t.find({v: {$gte: 30}}).toArray()
rs.status().members.map(m => m.name + ' ' + m.stateStr)
JS
wait_for $LAB-1 '!db.hello().isWritablePrimary' 90
ct $LAB-1 <<'EOF'
jq -c 'select(.msg | test("relinquishing primary|Stepping down from primary|Can.t see a majority")) | {t: .t."$date", msg}' /data/mongod.log
EOF

step "11. 옛 primary를 다시 붙이면: ROLLBACK을 거쳐 SECONDARY"
host "docker network connect $NET $LAB-1"
wait_for $LAB-1 'db.hello().secondary' 120
sleep 2
ct $LAB-1 <<'EOF'
jq -c 'select(.c == "ROLLBACK" or (.msg | test("Transition to ROLLBACK|Starting rollback|rollback"))) | {t: .t."$date", msg}' /data/mongod.log
EOF
ct $LAB-1 <<'EOF'
jq -c 'select(.msg == "Starting rollback due to fetcher error") | .attr' /data/mongod.log
EOF
ct $LAB-1 <<'EOF'
jq -c 'select(.msg == "Rollback common point" or .msg == "Operations reverted by rollback" or .msg == "Preparing to write deleted documents to a rollback file") | {msg, attr}' /data/mongod.log
EOF
ct $LAB-1 <<'EOF'
jq -c 'select(.msg == "Rollback summary") | .attr | {startTime, endTime, syncSource, rbid, lastOptimeRolledBack, commonPoint, lastWallClockTimeRolledBack, firstOpWallClockTimeAfterCommonPoint, truncateTimestamp, stableTimestamp, rollbackDataFileDirectory, rollbackCommandCounts, totalEntriesRolledBackIncludingNoops}' /data/mongod.log
EOF
ct $LAB-1 <<'EOF'
find /data/db/rollback -type f
bsondump --quiet $(find /data/db/rollback -name 'removed.*.bson')
EOF
msh $LAB-1 <<'JS'
rs.status().members.map(m => m.name + ' ' + m.stateStr)
db.t.find({v: {$gte: 30}}).readPref('secondaryPreferred').toArray()
JS

step "12. arbiter를 더하면 기본 write concern이 달라진다"
fresh_node $LAB-4
start_mongod $LAB-4 --replSet rs0
wait_new_primary
P=$NEWP
wait_for $LAB-1 'db.hello().isWritablePrimary || db.hello().secondary' 30
msh $P <<'JS'
rs.addArb('m08-4:27017')
db.adminCommand({setDefaultRWConcern: 1, defaultWriteConcern: {w: 'majority'}, writeConcern: {w: 'majority'}})
rs.addArb('m08-4:27017').ok
db.adminCommand({getDefaultRWConcern: 1})
JS

lab_clean
