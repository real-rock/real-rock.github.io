#!/bin/bash
# MongoDB 인터널 2편(체크포인트와 저널) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# m02-1: standalone. 60초 체크포인트, 저널 파일, j 옵션, kill -9 뒤 복구
# m02-2: 멤버 하나짜리 레플리카셋. 사용자 컬렉션은 저널(WT log)에 쓰지 않는다
cd "$(dirname "$0")"
LAB=m02
source ../lib/labkit.sh

val() { docker exec "$1" mongosh --quiet --eval "$2"; }

step "0. 실습 환경"
fresh_standalone
ct <<'EOF'
jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log | grep -oE 'log=\([^)]*\)'
ls -l /data/db/journal
EOF
msh <<'JS'
db.adminCommand({getParameter: 1, syncdelay: 1, journalCommitInterval: 1})
JS

step "1. 60초마다 도는 체크포인트"
ct <<'EOF'
setsid nohup mongosh --quiet --eval 'for (let i = 0; i < 130; i++) { db.tick.insertOne({i: i, at: new Date()}); sleep(1000); }' > /dev/null 2>&1 &
EOF
sleep 135
ct <<'EOF'
jq -r 'select(.msg == "WiredTiger message" and (.attr.message.msg | test("saving checkpoint snapshot"))) | .t."$date" + "  " + .attr.message.msg' /data/mongod.log
EOF
msh <<'JS'
function ckpt() { const c = db.serverStatus().wiredTiger.checkpoint; return {succeeded: c["total succeed number of checkpoints"], startedByApi: c["number of checkpoints started by api"], skippedClean: c["checkpoints skipped because database was clean"], mostRecentMs: c["most recent time (msecs)"], maxMs: c["max time (msecs)"]}; }
ckpt()
db.tick.countDocuments()
JS
ct <<'EOF'
grep -oE 'WiredTigerCheckpoint\.[0-9]+' /data/db/WiredTiger.turtle
EOF
sleep 65
msh <<'JS'
function ckpt() { const c = db.serverStatus().wiredTiger.checkpoint; return {succeeded: c["total succeed number of checkpoints"], startedByApi: c["number of checkpoints started by api"], skippedClean: c["checkpoints skipped because database was clean"], mostRecentMs: c["most recent time (msecs)"], maxMs: c["max time (msecs)"]}; }
ckpt()
JS
ct <<'EOF'
jq -r 'select(.msg == "WiredTiger message" and (.attr.message.msg | test("saving checkpoint snapshot"))) | .t."$date"' /data/mongod.log | tail -2
grep -oE 'WiredTigerCheckpoint\.[0-9]+' /data/db/WiredTiger.turtle
EOF

step "2. 저널 파일이 늘고 줄어드는 모습"
ct <<'EOF'
cat > /data/load.js <<'JS'
// 1KB 남짓한 문서 25만 개(약 250MB)를 넣는다
let seed = 7;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648);
let pool = "";
while (pool.length < 1000000) pool += rnd().toString(36);
for (let b = 0; b < 250; b++) {
  const docs = [];
  for (let i = 0; i < 1000; i++)
    docs.push({_id: b * 1000 + i, amount: rnd() % 100000, memo: pool.substr(rnd() % 990000, 1000)});
  db.bulk.insertMany(docs);
}
JS
EOF
msh <<'JS'
function logstat() { const l = db.serverStatus().wiredTiger.log, b = db.serverStatus().wiredTiger["block-manager"]; return {logBytesWritten: l["log bytes written"], logSyncs: l["log sync operations"], maxLogFileSize: l["maximum log file size"], preallocUsed: l["pre-allocated log files used"], ckptBytesWritten: b["bytes written for checkpoint"]}; }
logstat()
JS
ct <<'EOF'
mongosh --quiet /data/load.js
ls -l /data/db/journal
EOF
msh <<'JS'
function logstat() { const l = db.serverStatus().wiredTiger.log, b = db.serverStatus().wiredTiger["block-manager"]; return {logBytesWritten: l["log bytes written"], logSyncs: l["log sync operations"], maxLogFileSize: l["maximum log file size"], preallocUsed: l["pre-allocated log files used"], ckptBytesWritten: b["bytes written for checkpoint"]}; }
logstat()
db.adminCommand({fsync: 1})
logstat()
JS
sleep 2
ct <<'EOF'
ls -l /data/db/journal
EOF

step "3. j:true와 j:false"
msh <<'JS'
function syncs() { return db.serverStatus().wiredTiger.log["log sync operations"]; }
let a = syncs(); sleep(5000); "idle 5s: log syncs +" + (syncs() - a)
a = syncs(); let t = Date.now(), n = 0; while (Date.now() - t < 5000) { db.jt.insertOne({n: n++}, {writeConcern: {w: 1, j: false}}); sleep(10); } n + " inserts (j:false) in 5s: log syncs +" + (syncs() - a)
a = syncs(); t = Date.now(); for (let i = 0; i < 500; i++) db.jt.insertOne({i: i}, {writeConcern: {w: 1, j: false}}); "500 inserts j:false: " + (Date.now() - t) + " ms, log syncs +" + (syncs() - a)
a = syncs(); t = Date.now(); for (let i = 0; i < 500; i++) db.jt.insertOne({i: i}, {writeConcern: {w: 1, j: true}}); "500 inserts j:true: " + (Date.now() - t) + " ms, log syncs +" + (syncs() - a)
db.adminCommand({setParameter: 1, journalCommitInterval: 500})
a = syncs(); t = Date.now(); n = 0; while (Date.now() - t < 5000) { db.jt.insertOne({n: n++}, {writeConcern: {w: 1, j: false}}); sleep(10); } n + " inserts (j:false, journalCommitInterval 500) in 5s: log syncs +" + (syncs() - a)
db.adminCommand({setParameter: 1, journalCommitInterval: 100})
JS

step "4. kill -9: 체크포인트 뒤의 쓰기는 저널에만 있다"
msh <<'JS'
db.acct.insertMany(Array.from({length: 1000}, (_, i) => ({_id: i, balance: 100}))).insertedIds[999]
db.adminCommand({fsync: 1})
for (let i = 1000; i < 1003; i++) db.acct.insertOne({_id: i, balance: 200}, {writeConcern: {w: 1, j: true}}); db.acct.countDocuments()
db.acct.updateOne({_id: 1}, {$inc: {balance: 5}}, {writeConcern: {w: 1, j: true}})
JS
ACCT=$(val $CT 'db.acct.stats().wiredTiger.uri.split(":").pop()')
ACCT_ID=$(val $CT 'db.acct.stats({indexDetails: true}).indexDetails._id_.uri.split(":").pop()')
ct <<'EOF'
mongosh --quiet --eval 'for (let i = 2000; i < 2100; i++) db.acct.insertOne({_id: i, balance: 300}, {writeConcern: {w: 1, j: false}}); print(db.acct.countDocuments())' && kill -9 $(pgrep -x mongod)
sleep 1; pgrep -x mongod || echo "mongod is gone"
cp -a /data/db /tmp/crash-copy
EOF
ct <<EOF
wt -r -h /tmp/crash-copy list -v file:$ACCT.wt | tr ',' '\n' | grep -E '^(id|checkpoint)='
wt -r -h /tmp/crash-copy list -c file:$ACCT.wt
wt -r -h /tmp/crash-copy dump table:$ACCT | sed -n '/^Data/,\$p' | sed -n '2~2p' | wc -l
EOF
ct <<'EOF'
mv /tmp/crash-copy/journal/WiredTigerLog.* /tmp/crash-copy/
echo 'log=(compressor=snappy)' > /tmp/crash-copy/WiredTiger.config
wt -h /tmp/crash-copy printlog -u > /tmp/printlog.json
jq -c '.[] | select(.type == "checkpoint" or .type == "commit") | {lsn, type, txnid, ops: ([.ops[]? | "\(.optype) fileid=\(.fileid)"] | group_by(.) | map("\(.[0]) x\(length)"))}' /tmp/printlog.json | tail -8
EOF
ct <<EOF
wt -r -h /tmp/crash-copy list -v file:$ACCT_ID.wt | tr ',' '\n' | grep -E '^id='
EOF

step "5. 재기동: 마지막 체크포인트 + 저널 재생"
start_mongod "$CT"
ct <<'EOF'
jq -c 'select(.id == 22271 or .id == 22302 or .id == 4795906 or .c == "WTRECOV") | {t: .t."$date", c, msg: (.attr.message.msg // .msg), attr: (if .c == "WTRECOV" then null else .attr end)} | del(..|nulls)' /data/mongod.log | sed -n '/unclean shutdown/,$p'
EOF
msh <<'JS'
db.acct.countDocuments({balance: 100}) + " / " + db.acct.countDocuments({balance: 200}) + " / " + db.acct.countDocuments({balance: 300})
db.acct.findOne({_id: 1})
JS

step "6. 레플리카셋에서는 사용자 컬렉션을 저널에 쓰지 않는다"
fresh_node "$LAB-2"
start_mongod "$LAB-2" --replSet rs0
msh "$LAB-2" <<'JS'
rs.initiate().ok
JS
wait_for "$LAB-2" 'db.hello().isWritablePrimary' 30
msh "$LAB-2" <<'JS'
db.acct.insertOne({_id: 1, balance: 100}).acknowledged
db.acct.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
db.getSiblingDB("local").oplog.rs.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
db.getSiblingDB("local").system.replset.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
JS

lab_clean
echo "done" | log
