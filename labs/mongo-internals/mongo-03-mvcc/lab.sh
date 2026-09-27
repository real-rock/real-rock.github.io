#!/bin/bash
# MongoDB 인터널 3편(WiredTiger의 MVCC와 스냅샷) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 멀티 도큐먼트 트랜잭션과 timestamp를 쓰려고 단일 노드 레플리카셋(rs0)으로 띄운다.
cd "$(dirname "$0")"
LAB=m03
source ../lib/labkit.sh

step "0. 실습 환경: 단일 노드 레플리카셋"
fresh_replset rs0 1
msh <<'JS'
rs.initiate({_id: "rs0", members: [{_id: 0, host: "m03-1:27017"}]}).ok
JS
wait_primary 1
RSPROMPT=1
msh <<'JS'
db.acct.insertMany([{_id: 1, balance: 100}, {_id: 2, balance: 100}])
JS

step "1. 스냅샷 격리: 트랜잭션은 시작할 때의 스냅샷을 끝까지 본다"
sess_start A "$CT"
sess_start B "$CT"
sess A 'sA = db.getMongo().startSession(); cA = sA.getDatabase("test").acct;' 1
sess B 'sB = db.getMongo().startSession(); cB = sB.getDatabase("test").acct;' 1
sess A 'sA.startTransaction({readConcern: {level: "snapshot"}})' 1
sess A 'cA.findOne({_id: 1})' 1
sess B 'sB.startTransaction()' 1
sess B 'cB.updateOne({_id: 1}, {$set: {balance: 200}})' 1
sess B 'sB.commitTransaction()' 1
sess B 'sB.getOperationTime()' 1
sess A 'cA.findOne({_id: 1})' 1
msh <<'JS'
db.acct.findOne({_id: 1})
db.getSiblingDB("admin").aggregate([{$currentOp: {idleSessions: true}}, {$match: {"transaction.parameters.autocommit": false}}, {$project: {_id: 0, active: 1, readConcern: "$transaction.parameters.readConcern.level", readTimestamp: "$transaction.readTimestamp", startWallClockTime: "$transaction.startWallClockTime", expiryTime: "$transaction.expiryTime"}}])
JS

step "2. 스냅샷이 붙잡은 옛 버전 위에 쓰면 WriteConflict"
sess A 'try { cA.updateOne({_id: 1}, {$inc: {balance: 1}}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels, errmsg: e.errmsg}) }' 1
sess A 'sA.commitTransaction()' 1

step "3. 두 트랜잭션이 같은 도큐먼트를 고치면 뒤에 쓴 쪽이 바로 실패한다"
msh <<'JS'
db.serverStatus().wiredTiger.transaction["update conflicts"]
JS
sess A 'sA.startTransaction(); cA.updateOne({_id: 2}, {$inc: {balance: 10}})' 1
sess B 'sB.startTransaction(); try { cB.updateOne({_id: 2}, {$inc: {balance: 1}}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels}) }' 1
sess B 'sB.abortTransaction()' 1
sess A 'sA.commitTransaction()' 1
msh <<'JS'
db.acct.findOne({_id: 2})
db.serverStatus().wiredTiger.transaction["update conflicts"]
JS

step "4. 트랜잭션 밖의 쓰기는 서버 안에서 재시도하며 기다린다"
msh <<'JS'
db.serverStatus().metrics.operation.writeConflicts
JS
sess A 'sA.startTransaction(); cA.updateOne({_id: 1}, {$inc: {balance: 1000}})' 1
sess B 'db.acct.updateOne({_id: 1}, {$inc: {balance: 1}})' 3
msh <<'JS'
db.getSiblingDB("admin").aggregate([{$currentOp: {}}, {$match: {ns: "test.acct", op: "update"}}, {$project: {_id: 0, op: 1, secs_running: 1, writeConflicts: 1, numYields: 1, waitingForLock: 1}}])
db.serverStatus().metrics.operation.writeConflicts
JS
sess A 'sA.commitTransaction()' 1
sess_wait B 1
msh <<'JS'
db.acct.findOne({_id: 1})
db.serverStatus().metrics.operation.writeConflicts
JS
ct <<'EOF'
jq -c 'select(.msg == "Slow query" and .attr.ns == "test.acct" and .attr.writeConflicts) | {msg, type: .attr.type, planSummary: .attr.planSummary, writeConflicts: .attr.writeConflicts, numYields: .attr.numYields, durationMillis: .attr.durationMillis}' /data/mongod.log
EOF

step "5. history store: 기본 300초 창에서는 트랜잭션이 없어도 옛 버전이 쌓인다"
msh <<'JS'
db.adminCommand({getParameter: 1, minSnapshotHistoryWindowInSeconds: 1})
db.bulk.insertMany(Array.from({length: 100000}, (_, i) => ({_id: i, balance: 100, pad: "x".repeat(200)}))).acknowledged
db.bulk.countDocuments()
hs = () => { const w = db.serverStatus().wiredTiger; return {onDiskBytes: w.cache["history store table on-disk size"], insertCalls: w.cache["history store table insert calls"], idsPinned: w.transaction["transaction range of IDs currently pinned"], tsPinnedByReader: w.transaction["transaction range of timestamps pinned by the oldest active read timestamp"]} }
db.adminCommand({fsync: 1}).ok
hs()
db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
db.adminCommand({fsync: 1}).ok
hs()
JS
ct <<'EOF'
ls -l /data/db/WiredTigerHS.wt
EOF

step "6. 창을 0으로 줄이면 쌓이지 않고, 스냅샷을 열어 두면 다시 쌓인다"
msh <<'JS'
hs = () => { const w = db.serverStatus().wiredTiger; return {onDiskBytes: w.cache["history store table on-disk size"], insertCalls: w.cache["history store table insert calls"], idsPinned: w.transaction["transaction range of IDs currently pinned"], tsPinnedByReader: w.transaction["transaction range of timestamps pinned by the oldest active read timestamp"]} }
db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 0}).was
sleep(2000)
db.adminCommand({fsync: 1}).ok
hs()
db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
sleep(2000)
db.adminCommand({fsync: 1}).ok
hs()
JS
sess A 'sA.startTransaction({readConcern: {level: "snapshot"}}); sA.getDatabase("test").bulk.findOne({_id: 7})' 1
msh <<'JS'
hs = () => { const w = db.serverStatus().wiredTiger; return {onDiskBytes: w.cache["history store table on-disk size"], insertCalls: w.cache["history store table insert calls"], idsPinned: w.transaction["transaction range of IDs currently pinned"], tsPinnedByReader: w.transaction["transaction range of timestamps pinned by the oldest active read timestamp"]} }
db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
sleep(2000)
db.adminCommand({fsync: 1}).ok
hs()
db.bulk.findOne({_id: 7})
JS
ct <<'EOF'
ls -l /data/db/WiredTigerHS.wt
EOF
sess A 'sA.getDatabase("test").bulk.findOne({_id: 7})' 1
sess A 'sA.abortTransaction()' 1
msh <<'JS'
hs = () => { const w = db.serverStatus().wiredTiger; return {onDiskBytes: w.cache["history store table on-disk size"], insertCalls: w.cache["history store table insert calls"], idsPinned: w.transaction["transaction range of IDs currently pinned"], tsPinnedByReader: w.transaction["transaction range of timestamps pinned by the oldest active read timestamp"]} }
hs()
db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
sleep(2000)
db.adminCommand({fsync: 1}).ok
hs()
JS
ct <<'EOF'
ls -l /data/db/WiredTigerHS.wt
EOF
sess_end A
sess_end B

step "7. wt로 본 history store: 데이터 파일에는 최신 버전만 있다"
msh <<'JS'
db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 300}).was
db.runCommand({insert: "ver", documents: [{_id: 1, v: "v1-first"}]}).operationTime
db.runCommand({update: "ver", updates: [{q: {_id: 1}, u: {$set: {v: "v2-second"}}}]}).operationTime
db.runCommand({update: "ver", updates: [{q: {_id: 1}, u: {$set: {v: "v3-third"}}}]}).operationTime
db.adminCommand({fsync: 1}).ok
db.ver.stats().wiredTiger.uri
JS
ct <<'EOF'
URI=$(mongosh --quiet --eval 'db.ver.stats().wiredTiger.uri.replace("statistics:table:", "")')
mongod --dbpath /data/db --shutdown | grep -v '^{'
ID=$(wt -h /data/db list -v file:$URI.wt | tr ',' '\n' | grep '^id=' | cut -d= -f2)
echo "file:$URI.wt id=$ID"
wt -h /data/db list -v file:WiredTigerHS.wt | tr ',' '\n' | grep -E '^(key|value)_format='
wt -h /data/db dump -p file:$URI.wt | sed -n '/^Data/,$p'
wt -h /data/db dump -p file:WiredTigerHS.wt | sed -n '/^Data/,$p' | grep -A1 "^$ID,"
for ts in $(wt -h /data/db dump -p file:WiredTigerHS.wt | grep "^$ID," | cut -d, -f3); do echo "$ts = Timestamp($((ts >> 32)), $((ts & 0xffffffff)))"; done
EOF
start_mongod "$CT" --replSet rs0
wait_primary 1

step "8. 과거 시점 읽기(atClusterTime)와 SnapshotTooOld"
msh <<'JS'
T = db.runCommand({update: "acct", updates: [{q: {_id: 1}, u: {$set: {balance: 0}}}]}).operationTime
db.acct.updateOne({_id: 1}, {$set: {balance: -1}}).modifiedCount
db.runCommand({find: "acct", filter: {_id: 1}, readConcern: {level: "snapshot", atClusterTime: T}}).cursor.firstBatch
db.acct.findOne({_id: 1})
db.serverStatus().wiredTiger["snapshot-window-settings"]
db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 5}).was
sleep(12000)
db.acct.updateOne({_id: 2}, {$inc: {balance: 1}}).modifiedCount
sleep(1000)
db.serverStatus().wiredTiger["snapshot-window-settings"]
db.runCommand({find: "acct", filter: {_id: 1}, readConcern: {level: "snapshot", atClusterTime: T}})
db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 300}).was
JS

step "9. transactionLifetimeLimitSeconds: 오래 열린 트랜잭션은 서버가 abort한다"
sess_start C "$CT"
msh <<'JS'
db.adminCommand({getParameter: 1, transactionLifetimeLimitSeconds: 1})
db.adminCommand({setParameter: 1, transactionLifetimeLimitSeconds: 5}).was
JS
sess C 'sC = db.getMongo().startSession(); cC = sC.getDatabase("test").acct;' 1
sess C 'sC.startTransaction(); cC.insertOne({_id: 3, balance: 1})' 1
msh <<'JS'
db.serverStatus().transactions.currentOpen
JS
sess C 'sleep(8000)' 9
sess C 'cC.insertOne({_id: 4, balance: 1})' 1
sess C 'try { cC.insertOne({_id: 5, balance: 1}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels}) }' 1
sess C 'sC.commitTransaction()' 1
msh <<'JS'
db.acct.find({_id: {$gte: 3}}).toArray()
db.serverStatus().metrics.abortExpiredTransactions
db.adminCommand({setParameter: 1, transactionLifetimeLimitSeconds: 60}).was
JS
ct <<'EOF'
jq -c 'select(.id == 20707) | {msg, txnNumber: .attr.txnNumberAndRetryCounter.txnNumber}' /data/mongod.log
EOF
sess_end C

lab_clean
echo "done" | log
