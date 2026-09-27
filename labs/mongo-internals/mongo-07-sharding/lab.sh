#!/bin/bash
# MongoDB 인터널 7편(샤딩 구조) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# 컨테이너 4대: m07-cfg(config server 레플리카셋 cfg, 1노드), m07-sh1, m07-sh2(샤드 레플리카셋 sh1, sh2, 각 1노드),
# m07-mongos(mongos 두 개: 27017, 27018). 모든 mongod는 27017 포트를 쓴다.
cd "$(dirname "$0")"
LAB=m07
CT=m07-mongos
RSPROMPT=1
source ../lib/labkit.sh

# 샤드/컨피그 서버 primary가 될 때까지 기다린다
wait_rs_primary() { wait_for "$1" 'db.hello().isWritablePrimary' 90; }

step "0. 실습 환경: config server, 샤드 2개, mongos"
lab_clean
for n in cfg sh1 sh2 mongos; do fresh_node $LAB-$n; done
ct <<'EOF'
cat /etc/rocky-release
mongod --version | head -1
mongos --version | head -1
mongosh --version
EOF
start_mongod $LAB-cfg --configsvr --replSet cfg --port 27017
msh $LAB-cfg <<'JS'
rs.initiate({_id: 'cfg', configsvr: true, members: [{_id: 0, host: 'm07-cfg:27017'}]}).ok
JS
for s in sh1 sh2; do
  start_mongod $LAB-$s --shardsvr --replSet $s --port 27017
  msh $LAB-$s <<JS
rs.initiate({_id: '$s', members: [{_id: 0, host: 'm07-$s:27017'}]}).ok
JS
done
wait_rs_primary $LAB-cfg; wait_rs_primary $LAB-sh1; wait_rs_primary $LAB-sh2
ct <<'EOF'
mongos --configdb cfg/m07-cfg:27017 --bind_ip_all --port 27017 --logpath /data/mongos.log --fork | grep -E 'forked|ERROR'
mongos --configdb cfg/m07-cfg:27017 --bind_ip_all --port 27018 --logpath /data/mongos-b.log --fork | grep -E 'forked|ERROR'
EOF
wait_for $LAB-mongos 'db.hello().msg == "isdbgrid"' 60

step "1. 샤드 추가와 config 데이터베이스"
msh <<'JS'
sh.addShard('sh1/m07-sh1:27017').shardAdded
sh.addShard('sh2/m07-sh2:27017').shardAdded
db.getSiblingDB('config').shards.find()
db.getSiblingDB('config').getCollectionNames().filter(n => ['shards', 'databases', 'collections', 'chunks', 'settings', 'changelog', 'version', 'mongos'].includes(n))
db.getSiblingDB('config').mongos.find({}, {_id: 1, mongoVersion: 1})
JS

step "2. range shard key로 샤딩: 빈 컬렉션은 chunk 하나"
msh <<'JS'
db.getSiblingDB('config').settings.find()
db.adminCommand({enableSharding: 'shop', primaryShard: 'sh1'}).ok
sh.shardCollection('shop.orders', {customerId: 1}).collectionsharded
db.getSiblingDB('config').databases.find({_id: 'shop'})
db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}, {key: 1, unique: 1, uuid: 1, timestamp: 1})
const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou}, {_id: 0, min: 1, max: 1, shard: 1, lastmod: 1})
JS

step "3. chunk 크기를 1MB로 줄이고 데이터를 넣으면 balancer가 옮긴다"
msh <<'JS'
db.getSiblingDB('config').settings.updateOne({_id: 'chunksize'}, {$set: {value: 1}}, {upsert: true}).acknowledged
use shop
const pad = 'x'.repeat(200); for (let b = 0; b < 40; b++) { const docs = []; for (let i = 0; i < 2000; i++) { const c = b * 2000 + i; docs.push({customerId: c, status: c % 10 === 0 ? 'cancelled' : 'paid', amount: c % 997, pad: pad}); } db.orders.insertMany(docs); } 'inserted'
db.orders.countDocuments()
sh.balancerCollectionStatus('shop.orders')
JS
wait_for $LAB-mongos 'sh.balancerCollectionStatus("shop.orders").balancerCompliant' 300
msh <<'JS'
sh.balancerCollectionStatus('shop.orders')
use shop
db.orders.aggregate([{$collStats: {storageStats: {}}}, {$project: {_id: 0, shard: 1, count: '$storageStats.count', numOrphanDocs: '$storageStats.numOrphanDocs'}}, {$sort: {shard: 1}}])
const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.aggregate([{$match: {uuid: ou}}, {$group: {_id: '$shard', chunks: {$sum: 1}}}, {$sort: {_id: 1}}])
db.getSiblingDB('config').chunks.find({uuid: ou}, {_id: 0, min: 1, max: 1, shard: 1}).sort({min: 1}).limit(4)
db.getSiblingDB('config').changelog.aggregate([{$match: {ns: 'shop.orders'}}, {$group: {_id: '$what', n: {$sum: 1}}}, {$sort: {_id: 1}}])
db.getSiblingDB('config').changelog.find({ns: 'shop.orders', what: 'moveChunk.commit'}, {_id: 0, time: 1, what: 1, details: 1}).sort({time: 1}).limit(1)
JS

ct $LAB-cfg <<'EOF'
jq -r 'select(.msg | test("alanc")) | .msg' /data/mongod.log | sort | uniq -c
EOF

step "4. orphan: 옮겨 간 range는 원본 샤드에 잠시 남는다"
msh $LAB-sh1 <<'JS'
db.getSiblingDB('config').rangeDeletions.find({}, {_id: 0, nss: 1, range: 1, whenToClean: 1, numOrphanDocs: 1}).limit(3)
db.getSiblingDB('config').rangeDeletions.countDocuments()
db.getSiblingDB('shop').orders.countDocuments()
db.adminCommand({getParameter: 1, orphanCleanupDelaySecs: 1}).orphanCleanupDelaySecs
JS
msh <<'JS'
use shop
db.orders.countDocuments()
JS

step "5. 쿼리 라우팅: shard key로 찾으면 한 샤드, 아니면 모든 샤드"
msh <<'JS'
use shop
function route(e) { const p = e.queryPlanner.winningPlan; return {stage: p.stage, shards: p.shards.map(s => s.shardName)}; }
route(db.orders.find({customerId: 12345}).explain())
route(db.orders.find({status: 'cancelled', amount: 5}).explain())
route(db.orders.find({customerId: {$gte: 100, $lt: 200}}).explain())
route(db.orders.find({customerId: {$gte: 0, $lt: 80000}}).explain())
const x = db.orders.find({status: 'cancelled', amount: 5}).explain('executionStats').executionStats; ({nReturned: x.nReturned, totalDocsExamined: x.totalDocsExamined, shards: x.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned, docsExamined: s.totalDocsExamined}))})
const y = db.orders.find({customerId: 12345}).explain('executionStats').executionStats; ({nReturned: y.nReturned, totalDocsExamined: y.totalDocsExamined, shards: y.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned, docsExamined: s.totalDocsExamined}))})
JS

step "6. 단조 증가 shard key: 새 도큐먼트가 모두 한 샤드로"
msh <<'JS'
use shop
const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou, 'max.customerId': MaxKey}, {_id: 0, min: 1, max: 1, shard: 1})
sh.stopBalancer().ok
const pad = 'x'.repeat(200); for (let b = 40; b < 50; b++) { const docs = []; for (let i = 0; i < 2000; i++) { const c = b * 2000 + i; docs.push({customerId: c, status: 'paid', amount: c % 997, pad: pad}); } db.orders.insertMany(docs); } 'inserted'
const z = db.orders.find({customerId: {$gte: 80000}}).explain('executionStats').executionStats; ({nReturned: z.nReturned, shards: z.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned}))})
JS

step "7. hashed shard key: 빈 컬렉션도 샤드마다 chunk"
msh <<'JS'
sh.shardCollection('shop.users', {userId: 'hashed'}).collectionsharded
const uu = db.getSiblingDB('config').collections.findOne({_id: 'shop.users'}).uuid; db.getSiblingDB('config').chunks.find({uuid: uu}, {_id: 0, min: 1, max: 1, shard: 1})
use shop
for (let b = 0; b < 10; b++) { const docs = []; for (let i = 0; i < 2000; i++) { docs.push({userId: b * 2000 + i, name: 'u' + (b * 2000 + i)}); } db.users.insertMany(docs); } 'inserted'
db.users.getShardDistribution()
function route(e) { const p = e.queryPlanner.winningPlan; return {stage: p.stage, shards: p.shards.map(s => s.shardName)}; }
route(db.users.find({userId: 777}).explain())
route(db.users.find({userId: {$gte: 100, $lt: 110}}).explain())
db.users.find({userId: 777}, {_id: 0}).toArray()
JS

step "8. 수동 chunk 이동(moveRange)과 migration 단계"
note "mongos B(27018)가 shop.orders의 routing table을 먼저 캐시해 둔다"
MAXCHUNK=$(docker exec $CT mongosh --quiet --eval "const u = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; const c = db.getSiblingDB('config').chunks.findOne({uuid: u, 'max.customerId': MaxKey}); print(c.shard + ' ' + c.min.customerId)")
FROM=${MAXCHUNK% *}; M=${MAXCHUNK#* }
if [ "$FROM" = sh1 ]; then TO=sh2; else TO=sh1; fi
echo "# MaxKey chunk: $FROM, min customerId $M -> $TO" | log
msh $CT --port 27018 <<JS
use shop
db.orders.countDocuments({customerId: {\$gte: $M, \$lt: $((M + 100))}})
db.adminCommand({getShardVersion: 'shop.orders'}).version
JS
note "옮겨 왔던 range를 곧바로 되돌려 보내면: 원래 샤드에 orphan이 남아 있어 실패한다"
msh <<JS
db.adminCommand({moveRange: 'shop.orders', min: {customerId: MinKey}, toShard: '$FROM'})
JS
ct $LAB-$FROM <<'EOF'
jq -c 'select(.c == "MIGRATE") | {t: .t."$date", msg}' /data/mongod.log | tail -4
EOF
for s in sh1 sh2; do docker exec $LAB-$s mongosh --quiet --eval 'db.adminCommand({serverStatus: 1}).shardingStatistics.countStaleConfigErrors' > $TMPD/stale_$s; done
note "한 번도 $TO에 없던 range를 옮긴다 (max를 주지 않으면 원본 샤드가 chunk 크기로 잘라 정한다)"
msh <<JS
db.adminCommand({moveRange: 'shop.orders', min: {customerId: $M}, toShard: '$TO', waitForDelete: true}).ok
const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou, 'min.customerId': {\$gte: $M}}, {_id: 0, min: 1, max: 1, shard: 1, lastmod: 1}).sort({min: 1})
db.getSiblingDB('config').changelog.find({ns: 'shop.orders', what: 'moveChunk.from'}, {_id: 0, what: 1, details: 1}).sort({time: -1}).limit(1)
JS
ct $LAB-$FROM <<'EOF'
jq -c 'select(.c == "MIGRATE" or .c == "RANGEDEL") | {t: .t."$date", c, msg}' /data/mongod.log | tail -12
jq -c 'select(.msg == "Migration finished") | .attr' /data/mongod.log | tail -1
EOF
ct $LAB-$TO <<'EOF'
jq -c 'select(.c == "MIGRATE") | {t: .t."$date", msg}' /data/mongod.log | tail -5
EOF
MX=$(docker exec $CT mongosh --quiet --eval "const u = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; print(db.getSiblingDB('config').chunks.findOne({uuid: u, 'min.customerId': $M}).max.customerId + ' ' + db.getSiblingDB('config').chunks.findOne({uuid: u, 'min.customerId': MinKey}).max.customerId)")
MX1=${MX% *}; MX0=${MX#* }
msh $LAB-$FROM <<JS
db.getSiblingDB('shop').orders.countDocuments({customerId: {\$gte: $M, \$lt: $MX1}})
db.getSiblingDB('shop').orders.countDocuments({customerId: {\$lt: $MX0}})
db.getSiblingDB('config').rangeDeletions.countDocuments()
JS

step "9. stale config: 다른 mongos는 옛 routing table로 보낸 뒤 고친다"
msh $CT --port 27018 <<JS
db.adminCommand({getShardVersion: 'shop.orders'}).version
use shop
db.orders.countDocuments({customerId: {\$gte: $M, \$lt: $((M + 100))}})
db.adminCommand({getShardVersion: 'shop.orders'}).version
JS
for s in sh1 sh2; do
  after=$(docker exec $LAB-$s mongosh --quiet --eval 'db.adminCommand({serverStatus: 1}).shardingStatistics.countStaleConfigErrors')
  echo "# $s countStaleConfigErrors: $(cat $TMPD/stale_$s) -> $after" | log
done
ct <<'EOF'
jq -c 'select(.msg == "Refreshed cached collection" and .attr.namespace == "shop.orders") | {t: .t."$date", msg, newVersion: (.attr.newVersion | capture("v: (?<v>Timestamp\\([0-9, ]+\\))").v), durationMillis: .attr.durationMillis}' /data/mongos-b.log
EOF

step "10. 8.0: 샤딩하지 않은 컬렉션을 다른 샤드로 옮기기(moveCollection)"
msh $LAB-cfg <<'JS'
db.adminCommand({setParameter: 1, reshardingMinimumOperationDurationMillis: 0}).ok
JS
msh <<'JS'
use shop
db.logs.insertMany([{m: 'a'}, {m: 'b'}, {m: 'c'}]).acknowledged
db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'})
db.adminCommand({moveCollection: 'shop.logs', toShard: 'sh2'}).ok
db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'}, {_id: 1, key: 1, unsplittable: 1})
const lu = db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'}).uuid; db.getSiblingDB('config').chunks.find({uuid: lu}, {_id: 0, min: 1, max: 1, shard: 1})
db.logs.countDocuments()
JS

lab_clean
