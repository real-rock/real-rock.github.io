#!/bin/bash
# MongoDB 인터널 5편(oplog와 레플리카셋 복제) 실습. 새 컨테이너 3대에서 처음부터 끝까지 실행한다.
# 앞부분은 기본 oplog 크기로, 뒷부분(oplog window)은 --oplogSize 1로 레플리카셋을 새로 만든다.
cd "$(dirname "$0")"
LAB=m05
source ../lib/labkit.sh
RSPROMPT=1

# 컨테이너 안 mongod의 pid
mpid() { docker exec "$1" pgrep -x mongod; }

step "0. 실습 환경: 3노드 레플리카셋"
fresh_replset rs0 3
msh <<'JS'
rs.initiate({_id: "rs0", members: [{_id: 0, host: "m05-1:27017", priority: 2}, {_id: 1, host: "m05-2:27017"}, {_id: 2, host: "m05-3:27017"}]})
JS
wait_for m05-1 'db.hello().isWritablePrimary' 90
wait_for m05-1 'rs.status().members.every(m => m.state === 1 || m.state === 2)' 90
msh <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, syncSourceHost: m.syncSourceHost}))
JS
ct m05-2 <<'EOF'
jq -c 'select(.msg|test("^Initial sync (done|status)|Initial Sync Attempt|Sync source candidate chosen|Starting replication (fetcher|writer|applier)"))|{msg,attr:(.attr|{syncSource,durationMillis}|with_entries(select(.value!=null)))}' /data/mongod.log
EOF

step "1. oplog의 기본 크기"
ct <<'EOF'
jq -c 'select(.msg|test("Creating replication oplog|Oplog size is being rounded"))|{msg,attr}' /data/mongod.log
df -B1 --output=avail /data/db
EOF
msh <<'JS'
rs.printReplicationInfo()
db.getSiblingDB("local").getCollectionInfos({name: "oplog.rs"})[0].options
db.getSiblingDB("local").oplog.rs.stats().wiredTiger.creationString.match(/key_format=\w+|oplogKeyExtractionVersion=\d/g)
db.adminCommand({replSetResizeOplog: 1, size: 100})
JS

step "2. insert, update, delete의 oplog 엔트리"
msh <<'JS'
db.acct.insertOne({_id: 1, owner: "kim", balance: 100, tags: ["new"]})
db.acct.updateOne({_id: 1}, {$inc: {balance: 10}})
db.acct.updateOne({_id: 1}, {$push: {tags: "vip"}, $set: {owner: "lee"}})
db.acct.deleteOne({_id: 1})
var oplog = db.getSiblingDB("local").oplog.rs
oplog.find({ns: /^test\./}).sort({$natural: 1}).toArray()
JS

step "3. 연산자 update는 결과 값으로 기록된다: 다시 적용해도 같다"
msh <<'JS'
db.acct.insertOne({_id: 2, balance: 100})
db.acct.updateOne({_id: 2}, {$inc: {balance: 10}})
var e = db.getSiblingDB("local").oplog.rs.find({ns: "test.acct", op: "u", "o2._id": 2}).sort({$natural: -1}).limit(1).next()
e.o
db.adminCommand({applyOps: [{op: "u", ns: "test.acct", o2: {_id: 2}, o: e.o}]})
db.adminCommand({applyOps: [{op: "u", ns: "test.acct", o2: {_id: 2}, o: e.o}]})
db.acct.findOne({_id: 2})
db.acct.updateOne({_id: 2}, {$inc: {balance: 10}})
db.acct.findOne({_id: 2})
JS

step "4. 여러 도큐먼트를 바꾸는 명령과 트랜잭션"
msh <<'JS'
var start = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
db.acct.insertMany([{_id: 11, g: 1}, {_id: 12, g: 1}, {_id: 13, g: 1}])
db.acct.updateMany({g: 1}, {$set: {g: 2}})
db.acct.deleteMany({g: 2})
var s = db.getMongo().startSession()
s.startTransaction()
s.getDatabase("test").acct.insertOne({_id: 21, balance: 50})
s.getDatabase("test").acct.updateOne({_id: 2}, {$inc: {balance: -50}})
s.commitTransaction()
db.getSiblingDB("local").oplog.rs.find({$or: [{ns: "test.acct"}, {"o.applyOps.ns": "test.acct"}], ts: {$gt: start}}, {op: 1, ns: 1, o: 1, o2: 1, txnNumber: 1, stmtId: 1}).sort({$natural: 1}).toArray()
JS

step "5. secondary의 복제 파이프라인 지표"
msh m05-3 <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, syncSourceHost: m.syncSourceHost}))
var r = db.serverStatus().metrics.repl
r.buffer
r.network
r.apply
r.write
JS

step "6. 복제 지연 만들기: secondary 하나를 멈춘다"
P3=$(mpid m05-3)
ct m05-3 <<EOF
kill -STOP $P3
ps -o pid,stat,cmd -p $P3
date -u +%T.%3N
EOF
msh <<'JS'
new Date()
for (let i = 0; i < 1000; i++) db.lag.insertOne({i: i, pad: "x".repeat(200)})
sleep(3000)
db.lag.insertOne({i: "last"})
rs.printSecondaryReplicationInfo()
rs.status().members.map(m => ({name: m.name, optimeDate: m.optimeDate, lastAppliedWallTime: m.lastAppliedWallTime}))
db.lag.insertOne({i: "w3"}, {writeConcern: {w: 3, wtimeout: 3000}})
db.lag.insertOne({i: "wmaj"}, {writeConcern: {w: "majority", wtimeout: 3000}})
JS
sleep 10
msh <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health, optimeDate: m.optimeDate, lastHeartbeatMessage: m.lastHeartbeatMessage}))
JS

step "7. 멈춘 secondary를 다시 움직이면 따라잡는다"
ct m05-3 <<EOF
kill -CONT $P3
ps -o pid,stat,cmd -p $P3
EOF
sleep 5
msh <<'JS'
rs.printSecondaryReplicationInfo()
JS
msh m05-3 <<'JS'
db.lag.countDocuments()
var r = db.serverStatus().metrics.repl
r.apply
r.buffer.apply
JS

step "8. 작은 oplog: --oplogSize 1로 새로 만든다"
fresh_replset rs0 3 --oplogSize 1
msh <<'JS'
rs.initiate({_id: "rs0", members: [{_id: 0, host: "m05-1:27017", priority: 2}, {_id: 1, host: "m05-2:27017"}, {_id: 2, host: "m05-3:27017"}]})
JS
wait_for m05-1 'db.hello().isWritablePrimary' 90
wait_for m05-1 'rs.status().members.every(m => m.state === 1 || m.state === 2)' 90
msh <<'JS'
rs.printReplicationInfo()
JS

step "9. oplog는 마지막 체크포인트 이전만 지운다"
msh <<'JS'
for (let i = 0; i < 3000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
var st = db.getSiblingDB("local").oplog.rs.stats(); ({size: st.size, maxSize: st.maxSize, count: st.count})
var t0 = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
while (rs.status().lastStableRecoveryTimestamp.t <= t0.t) sleep(1000)
for (let i = 0; i < 1000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
sleep(2000)
var st = db.getSiblingDB("local").oplog.rs.stats(); ({size: st.size, maxSize: st.maxSize, count: st.count})
rs.printReplicationInfo()
JS
ct <<'EOF'
jq -c 'select(.msg=="WiredTiger record store oplog truncation finished")|{t:.t."$date",attr}' /data/mongod.log | tail -2
EOF

step "10. 멈춘 secondary가 oplog window 밖으로 밀려난다"
P3=$(mpid m05-3)
ct m05-3 <<EOF
kill -STOP $P3
date -u +%T.%3N
EOF
msh <<'JS'
for (let i = 0; i < 3000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
var t0 = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
var m2 = new Mongo("m05-2:27017")
while (rs.status().lastStableRecoveryTimestamp.t <= t0.t || m2.getDB("admin").runCommand({replSetGetStatus: 1}).lastStableRecoveryTimestamp.t <= t0.t) sleep(1000)
for (let i = 0; i < 1000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
sleep(2000)
db.getSiblingDB("local").oplog.rs.find().sort({$natural: 1}).limit(1).next().ts
m2.getDB("local").oplog.rs.find().sort({$natural: 1}).limit(1).next().ts
JS
ct m05-3 <<EOF
kill -CONT $P3
EOF
wait_for m05-1 'rs.status().members[2].state === 3' 90
msh <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, optimeDate: m.optimeDate}))
JS
ct m05-3 <<'EOF'
jq -c 'select(.msg|test("too stale|Too stale"))|{t:.t."$date",s,msg,attr}' /data/mongod.log
EOF
msh m05-3 <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, infoMessage: m.infoMessage}))
JS

step "11. initial sync로 다시 만든다"
ct m05-3 <<'EOF'
mongod --dbpath /data/db --shutdown | tail -1
mkdir /data/db2
mongod --dbpath /data/db2 --logpath /data/mongod2.log --bind_ip_all --fork --replSet rs0 --oplogSize 1 | grep -E 'forked|ERROR'
EOF
wait_for m05-1 'rs.status().members[2].state === 2' 120
ct m05-3 <<'EOF'
jq -c 'select(.msg|test("^Starting initial sync attempt|^Setting begin applying|^Finished cloning data|^Initial sync done"))|{t:.t."$date",msg,attr}' /data/mongod2.log
EOF
msh <<'JS'
rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, optimeDate: m.optimeDate}))
JS

lab_clean
