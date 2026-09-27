#!/bin/bash
# MongoDB 인터널 1편(WiredTiger 스토리지 엔진 구조와 캐시) 실습. 새 컨테이너에서 처음부터 끝까지 실행한다.
# m01-1: 기본 설정의 standalone. dbPath 파일, 카탈로그, creationString, 압축, wt 유틸리티, 작은 캐시의 eviction
# m01-2..4: --memory 1g/2g/4g 컨테이너. mongod가 계산한 기본 캐시 크기
cd "$(dirname "$0")"
LAB=m01
source ../lib/labkit.sh

# mongosh로 한 값을 뽑는다(기록하지 않음). 인자: 컨테이너, 식
val() { docker exec "$1" mongosh --quiet --eval "$2"; }

step "0. 실습 환경"
fresh_standalone
ct <<'EOF'
jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log
EOF

step "1. dbPath의 파일"
msh <<'JS'
db.orders.insertMany([{_id: 1, item: "apple", qty: 10}, {_id: 2, item: "banana", qty: 20}, {_id: 3, item: "cherry", qty: 30}])
db.orders.createIndex({item: 1})
JS
ct <<'EOF'
ls -l /data/db
ls -l /data/db/journal
cat /data/db/WiredTiger
bsondump --quiet /data/db/storage.bson
cat /data/db/mongod.lock; echo; pgrep -x mongod
EOF

step "2. 컬렉션 이름과 ident: _mdb_catalog"
msh <<'JS'
db.getSiblingDB("admin").aggregate([{$listCatalog: {}}, {$project: {_id: 0, ns: 1, ident: 1, idxIdent: 1}}])
db.orders.stats().wiredTiger.uri
Object.entries(db.orders.stats({indexDetails: true}).indexDetails).map(([name, d]) => name + " -> " + d.uri)
JS

step "3. WiredTiger 테이블을 만든 설정: creationString"
msh <<'JS'
const pick = (cs) => cs.split(",").filter(kv => /^(type|key_format|value_format|block_compressor|internal_page_max|leaf_page_max|memory_page_max|split_pct|prefix_compression|log)=/.test(kv))
pick(db.orders.stats().wiredTiger.creationString)
pick(db.orders.stats({indexDetails: true}).indexDetails.item_1.creationString)
JS

step "4. 압축 방식별 크기"
msh <<'JS'
db.createCollection("c_snappy")
db.createCollection("c_zstd", {storageEngine: {wiredTiger: {configString: "block_compressor=zstd"}}})
db.createCollection("c_zlib", {storageEngine: {wiredTiger: {configString: "block_compressor=zlib"}}})
db.createCollection("c_none", {storageEngine: {wiredTiger: {configString: "block_compressor=none"}}})
["c_snappy", "c_zstd", "c_zlib", "c_none"].map(c => c + ": " + db[c].stats().wiredTiger.creationString.match(/block_compressor=\w*/)[0])
JS
ct <<'EOF'
cat > /data/load-comp.js <<'JS'
// 같은 문서 10만 개를 네 컬렉션에 똑같이 넣는다(난수 씨앗 고정)
let seed = 42;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648);
const cities = ["Seoul", "Busan", "Incheon", "Daegu", "Daejeon", "Gwangju", "Ulsan", "Suwon"];
const words = ["order", "delivery", "refund", "coupon", "member", "payment", "shipping", "review", "cart", "event",
  "point", "gift", "return", "exchange", "stock", "price", "sale", "brand", "size", "color"];
for (let b = 0; b < 100; b++) {
  const docs = [];
  for (let i = 0; i < 1000; i++) {
    const n = b * 1000 + i;
    docs.push({_id: n, user: "user" + (rnd() % 50000), email: "user" + n + "@example.com",
      city: cities[rnd() % cities.length], status: ["active", "inactive", "pending"][rnd() % 3],
      amount: (rnd() % 1000000) / 100, tags: [words[rnd() % 20], words[rnd() % 20]],
      createdAt: new Date(1780000000000 + rnd() % 31536000000),
      memo: Array.from({length: 15}, () => words[rnd() % 20]).join(" ")});
  }
  for (const c of ["c_snappy", "c_zstd", "c_zlib", "c_none"]) db[c].insertMany(docs);
}
JS
mongosh --quiet /data/load-comp.js
EOF
msh <<'JS'
db.c_snappy.findOne({_id: 7})
db.adminCommand({fsync: 1})
["c_snappy", "c_zstd", "c_zlib", "c_none"].map(c => { const s = db[c].stats(); return {coll: c, count: s.count, size: s.size, storageSize: s.storageSize, ratio: (s.size / s.storageSize).toFixed(2)}; })
JS
ORD=$(val $CT 'db.orders.stats().wiredTiger.uri.split(":").pop()')
IDX=$(val $CT 'db.orders.stats({indexDetails: true}).indexDetails.item_1.uri.split(":").pop()')
IDIDX=$(val $CT 'db.orders.stats({indexDetails: true}).indexDetails._id_.uri.split(":").pop()')
SNAPPY=$(val $CT 'db.c_snappy.stats().wiredTiger.uri.split(":").pop()')
NONE=$(val $CT 'db.c_none.stats().wiredTiger.uri.split(":").pop()')
ZSTD=$(val $CT 'db.c_zstd.stats().wiredTiger.uri.split(":").pop()')
ct <<EOF
ls -l /data/db/$SNAPPY.wt /data/db/$ZSTD.wt /data/db/$NONE.wt
EOF

step "5. wt 유틸리티로 본 파일 (mongod를 멈춘 뒤)"
ct <<'EOF'
mongod --dbpath /data/db --shutdown | grep -v '^{'
EOF
ct <<'EOF'
wt -h /data/db list | grep '^table:'
EOF
ct <<EOF
wt -h /data/db dump -x table:$ORD | sed -n '/^Data/,\$p'
EOF
ct <<EOF
wt -h /data/db dump -x table:$ORD | sed -n '/^Data/,\$p' | sed -n 3p | xxd -r -p | bsondump --quiet
EOF
ct <<EOF
wt -h /data/db dump -x table:$IDX | sed -n '/^Data/,\$p'
wt -h /data/db dump -x table:$IDIDX | sed -n '/^Data/,\$p'
EOF
ct <<EOF
wt -h /data/db verify -d dump_layout table:$SNAPPY 2>&1 | grep -vE '^\['
wt -h /data/db verify -d dump_layout table:$NONE 2>&1 | grep -vE '^\['
EOF
ct <<EOF
wt -h /data/db verify -d dump_address table:$SNAPPY 2>&1 | head -9 | cut -c1-44
wt -h /data/db verify -d dump_address table:$NONE 2>&1 | head -9 | cut -c1-44
EOF
ct <<EOF
wt -h /data/db stat table:$SNAPPY | grep -E 'btree: (maximum (internal|leaf) page size|number of key/value pairs|row-store (internal|leaf) pages)|block-manager: file size'
EOF

step "6. 메모리의 페이지와 디스크의 블록"
start_mongod "$CT"
msh <<'JS'
function cacheOf(c) { const s = db[c].stats(); return {coll: c, storageSize: s.storageSize, size: s.size, inCache: s.wiredTiger.cache["bytes currently in the cache"], readIntoCache: s.wiredTiger.cache["bytes read into cache"]}; }
cacheOf("c_snappy")
db.c_snappy.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}])
cacheOf("c_snappy")
db.c_none.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}])
cacheOf("c_none")
JS

step "7. 기본 캐시 크기: 메모리 제한이 있는 컨테이너"
fresh_node "$LAB-2" --memory 1g
fresh_node "$LAB-3" --memory 2g
fresh_node "$LAB-4" --memory 4g
for c in "$LAB-2" "$LAB-3" "$LAB-4"; do start_mongod "$c"; done
for c in "$CT" "$LAB-2" "$LAB-3" "$LAB-4"; do
  ct "$c" <<'EOF'
cat /sys/fs/cgroup/memory.max
jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log | grep -oE 'cache_size=[0-9]+M'
EOF
  msh "$c" <<'JS'
const h = db.adminCommand({hostInfo: 1}).system; ({memSizeMB: h.memSizeMB, memLimitMB: h.memLimitMB, cacheMaxBytes: db.serverStatus().wiredTiger.cache["maximum bytes configured"]})
JS
done
docker rm -f "$LAB-2" "$LAB-3" "$LAB-4" >/dev/null

step "8. 작은 캐시(256MB)에서 캐시보다 큰 데이터"
ct <<'EOF'
mongod --dbpath /data/db --shutdown | grep -v '^{'
EOF
start_mongod "$CT" --wiredTigerCacheSizeGB 0.25
ct <<'EOF'
cat > /data/cache.js <<'JS'
function cache() {
  const c = db.serverStatus().wiredTiger.cache, mb = (b) => Math.round(b / 1048576);
  const max = c["maximum bytes configured"];
  return {maxMB: mb(max), inCacheMB: mb(c["bytes currently in the cache"]), usedPct: +(100 * c["bytes currently in the cache"] / max).toFixed(1),
    dirtyMB: mb(c["tracked dirty bytes in the cache"]), dirtyPct: +(100 * c["tracked dirty bytes in the cache"] / max).toFixed(1),
    pagesRead: c["pages read into cache"], pagesWritten: c["pages written from cache"],
    workerEvict: c["evict page attempts by eviction worker threads"], appEvict: c["page evict attempts by application threads"],
    appEvictUsecs: c["application thread time evicting (usecs)"],
    cleanEvicted: c["unmodified pages evicted"], dirtyEvicted: c["modified pages evicted"],
    dirtyTrigger: c["number of times dirty trigger was reached"], evictionTrigger: c["number of times eviction trigger was reached"]};
}
JS
cat > /data/load-ev.js <<'JS'
// 1KB 남짓한 문서 40만 개(약 400MB)를 넣는다
let seed = 7;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648);
let pool = "";
while (pool.length < 1000000) pool += rnd().toString(36);
for (let b = 0; b < 400; b++) {
  const docs = [];
  for (let i = 0; i < 1000; i++)
    docs.push({_id: b * 1000 + i, user: "user" + (rnd() % 100000), amount: rnd() % 100000, memo: pool.substr(rnd() % 990000, 1000)});
  db.ev.insertMany(docs);
}
JS
EOF
msh "$CT" --file /data/cache.js <<'JS'
cache()
JS
ct <<'EOF'
time mongosh --quiet /data/load-ev.js
EOF
msh "$CT" --file /data/cache.js <<'JS'
cache()
const s = db.ev.stats(); ({count: s.count, sizeMB: Math.round(s.size / 1048576), storageSizeMB: Math.round(s.storageSize / 1048576)})
let t = Date.now(); db.ev.updateMany({}, {$inc: {amount: 1}}).modifiedCount + " docs, " + (Date.now() - t) + " ms"
cache()
t = Date.now(); db.ev.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}]).toArray()[0].n + " docs, " + (Date.now() - t) + " ms"
cache()
JS

lab_clean
echo "done" | log
