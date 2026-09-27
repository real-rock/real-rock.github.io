#!/bin/bash
# MongoDB 인터널 4편(인덱스 구조와 쿼리 플래너의 계획 선택 방식) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# standalone mongod 하나로 충분하다.
cd "$(dirname "$0")"
LAB=m04
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_standalone

step "1. 인덱스도 WiredTiger 테이블: key는 KeyString + RecordId"
msh <<'JS'
db.kdemo.insertMany([{_id: 1, k: 5, u: "a"}, {_id: 2, k: "x", u: "b"}, {_id: 3, k: 5, u: "c"}]).insertedIds
db.kdemo.createIndex({k: 1})
db.kdemo.createIndex({u: 1}, {unique: true})
db.kdemo.stats().wiredTiger.uri
Object.entries(db.kdemo.stats({indexDetails: true}).indexDetails).map(([name, d]) => [name, d.uri])
db.adminCommand({fsync: 1}).ok
JS
ct <<'EOF'
mongosh --quiet --eval 'Object.entries(db.kdemo.stats({indexDetails: true}).indexDetails).map(([n, d]) => n + " " + d.uri.replace("statistics:", "")).join("\n")' > /tmp/idx.txt
mongosh --quiet --eval 'db.kdemo.stats().wiredTiger.uri.replace("statistics:", "")' > /tmp/coll.txt
mongod --dbpath /data/db --shutdown | grep -v '^{'
wt -h /data/db dump -x $(cat /tmp/coll.txt) | sed -n '/^Data/,$p'
while read name uri; do echo "== $name ($uri)"; wt -h /data/db list -v $uri | tr ',' '\n' | grep -E '^app_metadata|^(key|value)_format'; wt -h /data/db dump -x $uri | sed -n '/^Data/,$p' | tail -n +2; done < /tmp/idx.txt
EOF
start_mongod "$CT"

step "2. 후보 계획 경쟁: explain allPlansExecution"
msh <<'JS'
db.ev.insertMany(Array.from({length: 100000}, (_, i) => ({_id: i, a: i < 50000 ? 0 : i, b: i >= 50000 ? 0 : i}))).acknowledged
db.ev.createIndex({a: 1})
db.ev.createIndex({b: 1})
db.ev.countDocuments({a: 0})
db.ev.countDocuments({b: 0})
e = db.ev.find({a: 70000, b: 0}).explain("allPlansExecution")
e.explainVersion
({planCacheShapeHash: e.queryPlanner.planCacheShapeHash, planCacheKey: e.queryPlanner.planCacheKey, rejectedPlans: e.queryPlanner.rejectedPlans.length})
e.queryPlanner.winningPlan
ix = (s) => s.indexName ? s.stage + " " + s.indexName : s.stage + (s.inputStage ? " > " + ix(s.inputStage) : " > [" + s.inputStages.map(ix).join(", ") + "]")
e.executionStats.allPlansExecution.map(p => ({plan: ix(p.executionStages), score: p.score, works: p.executionStages.works, advanced: p.executionStages.advanced, isEOF: p.executionStages.isEOF, totalKeysExamined: p.totalKeysExamined, totalDocsExamined: p.totalDocsExamined}))
JS

step "3. plan cache: 처음에는 inactive, 두 번째에 active"
msh <<'JS'
pc = () => db.ev.aggregate([{$planCacheStats: {}}, {$project: {_id: 0, planCacheShapeHash: 1, planCacheKey: 1, isActive: 1, works: 1, createdFromQuery: 1, index: "$cachedPlan.inputStage.indexName"}}]).toArray()
db.serverStatus().metrics.query.planCache.classic
db.ev.find({a: 70000, b: 0}).toArray()
pc()
db.ev.find({a: 70000, b: 0}).toArray()
pc()
db.ev.find({a: 60000, b: 0}).toArray()
db.serverStatus().metrics.query.planCache.classic
db.ev.find({a: 60000, b: 0}).explain().queryPlanner.winningPlan.isCached
JS

step "4. replanning: 캐시된 계획이 예상 works의 10배를 넘으면"
msh <<'JS'
pc = () => db.ev.aggregate([{$planCacheStats: {}}, {$project: {_id: 0, planCacheShapeHash: 1, planCacheKey: 1, isActive: 1, works: 1, createdFromQuery: 1, index: "$cachedPlan.inputStage.indexName"}}]).toArray()
db.adminCommand({getParameter: 1, internalQueryCacheEvictionRatio: 1}).internalQueryCacheEvictionRatio
db.setLogLevel(1, "query").was.query.verbosity
db.setProfilingLevel(0, {slowms: 0}).slowms
db.ev.find({a: 0, b: 30000}).toArray()
db.setLogLevel(0, "query").was.query.verbosity
db.setProfilingLevel(0, {slowms: 100}).slowms
pc()
db.serverStatus().metrics.query.planCache.classic
JS
ct <<'EOF'
jq -c 'select(.id == 20580) | {msg, attr: {maxWorksBeforeReplan: .attr.maxWorksBeforeReplan, decisionWorks: .attr.decisionWorks, planSummary: .attr.planSummary}}' /data/mongod.log
jq -c 'select(.msg == "Slow query" and .attr.ns == "test.ev" and .attr.replanned) | {planSummary: .attr.planSummary, replanned: .attr.replanned, replanReason: .attr.replanReason, keysExamined: .attr.keysExamined, docsExamined: .attr.docsExamined, planCacheShapeHash: .attr.planCacheShapeHash}' /data/mongod.log
EOF

step "5. plan cache 비우기: planCacheClear와 인덱스 변경"
msh <<'JS'
pc = () => db.ev.aggregate([{$planCacheStats: {}}, {$project: {_id: 0, isActive: 1, works: 1, index: "$cachedPlan.inputStage.indexName"}}]).toArray()
pc()
db.runCommand({planCacheClear: "ev"}).ok
pc()
db.ev.find({a: 70000, b: 0}).toArray().length
pc()
db.ev.createIndex({a: 1, b: 1})
pc()
db.ev.find({a: 70000, b: 0}).explain().queryPlanner.winningPlan.inputStage.indexName
JS

step "6. ESR: Equality, Sort, Range"
msh <<'JS'
db.orders.insertMany(Array.from({length: 200000}, (_, i) => ({_id: i, status: ["new", "paid", "shipped", "done"][i % 4], amount: (i * 7) % 1000, ts: i}))).acknowledged
db.orders.createIndex({status: 1, amount: 1, ts: 1}, {name: "esr_bad"})
db.orders.createIndex({status: 1, ts: 1, amount: 1}, {name: "esr_good"})
db.orders.countDocuments({status: "paid", amount: {$gte: 900}})
st = (s) => s.stage + (s.inputStage ? " > " + st(s.inputStage) : "")
q = () => db.orders.find({status: "paid", amount: {$gte: 900}}).sort({ts: -1}).limit(10)
bad = q().hint("esr_bad").explain("executionStats"); st(bad.executionStats.executionStages)
({nReturned: bad.executionStats.nReturned, totalKeysExamined: bad.executionStats.totalKeysExamined, totalDocsExamined: bad.executionStats.totalDocsExamined})
bad.queryPlanner.winningPlan.inputStage.inputStage.indexBounds
good = q().hint("esr_good").explain("executionStats"); st(good.executionStats.executionStages)
({nReturned: good.executionStats.nReturned, totalKeysExamined: good.executionStats.totalKeysExamined, totalDocsExamined: good.executionStats.totalDocsExamined})
good.queryPlanner.winningPlan.inputStage.inputStage.indexBounds
auto = q().explain("allPlansExecution"); st(auto.queryPlanner.winningPlan)
auto.executionStats.allPlansExecution.map(p => ({plan: st(p.executionStages), score: p.score, works: p.executionStages.works, advanced: p.executionStages.advanced, isEOF: p.executionStages.isEOF, totalKeysExamined: p.totalKeysExamined}))
db.serverStatus().metrics.operation.scanAndOrder
q().hint("esr_bad").toArray().length
db.serverStatus().metrics.operation.scanAndOrder
JS

step "7. 커버링 쿼리: 도큐먼트를 읽지 않는다"
msh <<'JS'
st = (s) => s.stage + (s.inputStage ? " > " + st(s.inputStage) : "")
c1 = db.orders.find({status: "paid", ts: {$gte: 199000}}, {_id: 0, status: 1, ts: 1}).hint("esr_good").explain("executionStats"); st(c1.executionStats.executionStages)
({nReturned: c1.executionStats.nReturned, totalKeysExamined: c1.executionStats.totalKeysExamined, totalDocsExamined: c1.executionStats.totalDocsExamined})
c2 = db.orders.find({status: "paid", ts: {$gte: 199000}}, {status: 1, ts: 1}).hint("esr_good").explain("executionStats"); st(c2.executionStats.executionStages)
({nReturned: c2.executionStats.nReturned, totalKeysExamined: c2.executionStats.totalKeysExamined, totalDocsExamined: c2.executionStats.totalDocsExamined})
JS

step "8. multikey 인덱스"
msh <<'JS'
db.posts.insertMany([{_id: 1, tags: ["db", "mongo"]}, {_id: 2, tags: ["db", "pg"]}, {_id: 3, tags: "misc"}]).acknowledged
db.posts.createIndex({tags: 1})
m = db.posts.find({tags: "db"}).explain("executionStats"); m.executionStats.executionStages.stage
({isMultiKey: m.queryPlanner.winningPlan.inputStage.isMultiKey, multiKeyPaths: m.queryPlanner.winningPlan.inputStage.multiKeyPaths, keysExamined: m.executionStats.totalKeysExamined, nReturned: m.executionStats.nReturned})
db.posts.stats({indexDetails: true}).indexSizes
JS

step "9. 실행 엔진: classic과 SBE"
msh <<'JS'
f = db.orders.find({status: "paid"}).explain(); f.ok
({explainVersion: f.explainVersion, winningPlanKeys: Object.keys(f.queryPlanner.winningPlan)})
g = db.orders.explain().aggregate([{$match: {status: "paid"}}, {$group: {_id: "$amount", n: {$sum: 1}}}]); g.ok
({explainVersion: g.explainVersion, winningPlanKeys: Object.keys(g.queryPlanner.winningPlan), queryPlanStages: g.queryPlanner.winningPlan.queryPlan.stage + " > " + g.queryPlanner.winningPlan.queryPlan.inputStage.stage})
db.adminCommand({getParameter: 1, internalQueryFrameworkControl: 1}).internalQueryFrameworkControl
db.orders.aggregate([{$match: {status: "paid"}}, {$group: {_id: "$amount", n: {$sum: 1}}}]).toArray().length
db.serverStatus().metrics.query.planCache
JS

lab_clean
echo "done" | log
