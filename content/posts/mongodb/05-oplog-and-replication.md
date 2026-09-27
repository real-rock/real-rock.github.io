---
title: "MongoDB 인터널 5: oplog와 레플리카셋 복제"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "oplog", "복제", "레플리카셋", "복제 지연", "Too stale to catch up"]
weight: 5
summary: "secondary는 primary의 변경을 어떻게 따라가고, oplog window 밖으로 밀려나면 어떻게 되는가"
description: "oplog 엔트리의 구조와 멱등성, OplogFetcher에서 OplogApplier까지의 복제 파이프라인, 복제 지연, oplog 크기와 window"
---

## 개요

[1편](/posts/mongodb/01-wiredtiger-architecture/)부터 [4편](/posts/mongodb/04-index-and-query-planner/)까지는 mongod 한 대 안에서 일어나는 일이었습니다. 운영에서 mongod를 한 대만 두는 일은 거의 없습니다. 보통 같은 데이터를 가진 mongod 여러 대를 **레플리카셋**(replica set)으로 묶고, 그중 쓰기를 받는 한 대를 **primary**, 나머지를 **secondary**라고 부릅니다.

primary는 데이터를 바꿀 때마다 "무엇을 바꿨는지"를 `local.oplog.rs`라는 컬렉션에 한 줄씩 남기고, secondary는 그 줄을 가져와 자기 데이터에 똑같이 적용합니다. 이 컬렉션이 **oplog**(operation log)입니다. PostgreSQL의 스트리밍 복제([PostgreSQL 인터널 9편](/posts/postgresql/09-streaming-replication/))가 페이지를 어떻게 고쳤는지를 담은 WAL을 그대로 보내는 물리 복제라면, MongoDB의 oplog는 "이 `_id`의 도큐먼트를 이렇게 바꿨다"를 담은 논리적인 기록입니다. 그래서 secondary는 primary와 같은 도큐먼트를 갖지만, 파일의 모양까지 같지는 않습니다.

이 글에서 답할 질문은 다음과 같습니다.

- oplog는 어디에, 어떤 모양으로 저장되고, 기본 크기는 어떻게 정해지는가
- 도큐먼트 변경과 oplog 기록은 어떻게 한 번에 커밋되는가
- `$inc` 같은 연산자 update는 왜 결과 값으로 바뀌어 기록되는가
- secondary는 oplog를 어떤 단계를 거쳐 가져오고 적용하는가
- 복제 지연은 어디서 보이고, `w: 3` 같은 쓰기는 무엇을 기다리는가
- oplog window 밖으로 밀려난 secondary는 어떻게 되는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 레플리카셋은 컨테이너 3대(`m05-1`, `m05-2`, `m05-3`)로 만들었습니다.

## 레플리카셋 만들기

레플리카셋 멤버는 모두 같은 `--replSet` 이름으로 시작하고, 그중 한 대에서 `rs.initiate()`로 멤버 목록을 알려 주면 셋이 만들어집니다. 누가 primary가 될지는 선출로 정해지는데([6편](/posts/mongodb/06-election/)), 이 글에서는 `m05-1`이 늘 primary가 되도록 `priority: 2`를 주었습니다(나머지는 기본값 1).

#### 3노드 레플리카셋

세 컨테이너에서 같은 옵션으로 mongod를 띄웁니다.

```console
$ mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0 | grep -E 'forked|ERROR'
forked process: 33
```

`m05-1`에서 셋을 만들고 멤버 상태를 봅니다.

```mongosh
test> rs.initiate({_id: "rs0", members: [{_id: 0, host: "m05-1:27017", priority: 2}, {_id: 1, host: "m05-2:27017"}, {_id: 2, host: "m05-3:27017"}]})
{
  ok: 1,
...
}
rs0 [direct: primary] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, syncSourceHost: m.syncSourceHost}))
[
  { name: 'm05-1:27017', stateStr: 'PRIMARY', syncSourceHost: '' },
  { name: 'm05-2:27017', stateStr: 'SECONDARY', syncSourceHost: '' },
  { name: 'm05-3:27017', stateStr: 'SECONDARY', syncSourceHost: '' }
]
```

`rs.initiate()` 전에는 프롬프트가 `test>`였다가, 셋이 만들어지고 `m05-1`이 primary가 되자 `rs0 [direct: primary] test>`로 바뀌었습니다. 나머지 둘은 SECONDARY입니다. `syncSourceHost`(각 멤버가 어디서 oplog를 받아 오는지)가 아직 비어 있는 것은, primary가 다른 멤버의 상태를 2초마다 오가는 heartbeat로 알게 되는데 그 정보가 아직 도착하지 않았기 때문입니다. 잠시 뒤에 보면 두 secondary 모두 `m05-1:27017`에서 받아 오고 있습니다([뒤에서 확인](#secondary의-파이프라인-지표)).

`m05-2`의 로그에서 secondary가 되기까지의 과정을 추립니다.

```console
$ jq -c 'select(.msg|test("^Initial sync (done|status)|Initial Sync Attempt|Sync source candidate chosen|Starting replication (fetcher|writer|applier)"))|{msg,attr:(.attr|{syncSource,durationMillis}|with_entries(select(.value!=null)))}' /data/mongod.log
{"msg":"Sync source candidate chosen","attr":{"syncSource":"m05-3:27017"}}
{"msg":"Initial sync status and statistics","attr":{}}
{"msg":"Initial sync done","attr":{}}
{"msg":"Starting replication fetcher thread","attr":{}}
{"msg":"Starting replication writer thread","attr":{}}
{"msg":"Starting replication applier thread","attr":{}}
{"msg":"Sync source candidate chosen","attr":{"syncSource":"m05-1:27017"}}
```

- 새 멤버는 먼저 **initial sync**로 데이터 전체를 복사합니다([뒤에서 다룹니다](#initial-sync로-다시-만든다)). 이때 `m05-2`는 같이 막 시작한 `m05-3`을 복사 원본으로 골랐습니다. 빈 셋이라 누구에게서 받아도 결과는 같습니다.
- initial sync가 끝나면 평상시 복제를 맡는 세 스레드, **fetcher**, **writer**, **applier**를 띄우고, 이번에는 primary인 `m05-1`을 sync source로 골랐습니다. 세 스레드가 하는 일이 이 글의 중심입니다.

## oplog는 ts 순서의 capped 컬렉션이다

oplog는 `local` 데이터베이스의 `oplog.rs` 컬렉션입니다. `local`은 복제되지 않는 데이터베이스라, 멤버마다 자기 oplog를 따로 갖습니다. oplog에는 두 가지 특징이 있습니다.

- **capped 컬렉션**입니다. 정한 크기를 넘으면 가장 오래된 엔트리부터 지웁니다. 그래서 oplog가 담고 있는 기간, 즉 **oplog window**는 쓰기 양에 따라 달라집니다.
- WiredTiger 테이블의 key가 엔트리의 `ts`(timestamp)입니다. 보통 컬렉션은 mongod가 매기는 증가 번호(RecordId)를 key로 쓰는데, oplog는 엔트리의 `ts`를 그대로 RecordId로 씁니다([`keyForOptime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L1165)). B-tree([1편](/posts/mongodb/01-wiredtiger-architecture/))가 key 순서로 정렬되어 있으니 oplog는 늘 `ts` 순서이고, "이 `ts`부터 읽어라"를 인덱스 없이 key 탐색으로 처리합니다. 그래서 oplog에는 `_id` 인덱스도 없습니다.

기본 크기는 [`getNewOplogSizeBytes()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L644)가 정합니다.

| 조건 | 크기 |
|---|---|
| `--oplogSize`(`replication.oplogSizeMB`)를 준 경우 | 그 값. 0보다 크기만 하면 된다([`mongod_options.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/mongod_options.cpp#L179-L195)) |
| 디스크 스토리지(보통의 경우) | dbPath가 있는 파일시스템 **여유 공간의 5%**, 최소 990MB, 최대 50GB([`oplog.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L684-L704)) |
| in-memory 스토리지 | 물리 메모리의 5%, 최소 50MB |
| macOS 빌드 | 192MB 고정 |

크기는 oplog를 **처음 만들 때 한 번** 계산합니다. 디스크가 나중에 커지거나 줄어도 저절로 바뀌지 않고, 이미 oplog가 있는데 다른 `--oplogSize`로 시작하면 오류로 멈춥니다([`createOplog()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L725-L737)). 운영 중에 바꾸려면 `replSetResizeOplog` 명령을 씁니다.

#### 기본 oplog 크기

primary의 로그에서 oplog를 만들 때의 메시지와, 지금 파일시스템의 여유 공간을 봅니다.

```console
$ jq -c 'select(.msg|test("Creating replication oplog|Oplog size is being rounded"))|{msg,attr}' /data/mongod.log
$ df -B1 --output=avail /data/db
{"msg":"Creating replication oplog","attr":{"oplogSizeMB":32730}}
       Avail
686415142912
```

```mongosh
rs0 [direct: primary] test> rs.printReplicationInfo()
actual oplog size
'32730.94140625 MB'
---
configured oplog size
'32730.94140625 MB'
---
log length start to end
'10 secs (0 hrs)'
...
rs0 [direct: primary] test> db.getSiblingDB("local").getCollectionInfos({name: "oplog.rs"})[0].options
{ capped: true, size: Long('34320879616'), autoIndexId: false }
rs0 [direct: primary] test> db.getSiblingDB("local").oplog.rs.stats().wiredTiger.creationString.match(/key_format=\w+|oplogKeyExtractionVersion=\d/g)
[ 'oplogKeyExtractionVersion=1', 'key_format=q' ]
rs0 [direct: primary] test> db.adminCommand({replSetResizeOplog: 1, size: 100})
MongoServerError[BadValue]: BSON field 'size' value must be >= 990, actual value '100'
```

- 여유 공간이 약 686GB이고, 그 5%인 약 34.3GB가 oplog 크기가 되었습니다(`size: 34320879616`, 32730MB). 50GB 상한에 걸리지 않았습니다. 실습 컨테이너의 디스크가 커서 생긴 숫자라, 여유 공간이 다른 서버에서는 다른 값이 나옵니다.
- `log length start to end`가 oplog window입니다. 셋을 만든 지 10초라 아직 10초 분량만 있습니다. 크기(34GB)와 window(시간)는 별개이고, 운영에서 봐야 하는 것은 window 쪽입니다.
- 컬렉션 옵션은 `capped: true`, `autoIndexId: false`(`_id` 인덱스 없음)입니다. WiredTiger 테이블은 `key_format=q`(64비트 정수 key, 여기에 `ts`가 들어감)로 만들어졌고, `oplogKeyExtractionVersion=1`이 이 테이블이 oplog라는 표시입니다([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L691)).
- `replSetResizeOplog`는 990MB보다 작게 줄일 수 없습니다([`resize_oplog.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/commands/resize_oplog.idl#L49)). 시작 옵션 `--oplogSize`는 이런 하한이 없어서, [뒤의 실습](#oplog-window)에서는 `--oplogSize 1`로 1MB짜리 oplog를 만들어 씁니다.

## oplog 엔트리의 모양

엔트리 하나는 BSON 도큐먼트 하나입니다. 자주 보는 필드는 다음과 같습니다.

| 필드 | 뜻 |
|---|---|
| `op` | 종류. `i`(insert), `u`(update), `d`(delete), `c`(명령: 컬렉션 생성, `applyOps` 등), `n`(no-op) ([`oplog.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L438-L450)) |
| `ns`, `ui` | 대상 네임스페이스(`db.collection`)와 컬렉션 UUID. 적용할 때는 UUID로 컬렉션을 찾는다 |
| `o` | 내용. insert는 도큐먼트 전체, update는 변경분, delete는 `_id` |
| `o2` | update에서 바꿀 도큐먼트를 찾는 조건(`_id`). insert에도 도큐먼트 key가 들어간다 |
| `ts` | 이 엔트리의 timestamp. oplog 안에서 유일하고 순서를 정한다 |
| `t` | 이 엔트리를 쓴 primary의 term([6편](/posts/mongodb/06-election/)) |
| `v` | oplog 엔트리 형식 버전(2) |
| `wall` | primary의 벽시계 시각. 복제 지연을 계산할 때 쓴다 |
| `lsid`, `txnNumber`, `stmtId`, `prevOpTime` | 세션과 트랜잭션 번호. retryable write와 트랜잭션에서만 붙는다 |

#### insert, update, delete를 하나씩

`acct` 컬렉션에 도큐먼트 하나를 넣고, `$inc`로 한 번, `$push`와 `$set`으로 한 번 고친 뒤 지웁니다. 그리고 oplog에서 `test` 데이터베이스의 엔트리를 들어간 순서대로 봅니다.

```mongosh
rs0 [direct: primary] test> db.acct.insertOne({_id: 1, owner: "kim", balance: 100, tags: ["new"]})
{ acknowledged: true, insertedId: 1 }
rs0 [direct: primary] test> db.acct.updateOne({_id: 1}, {$inc: {balance: 10}})
rs0 [direct: primary] test> db.acct.updateOne({_id: 1}, {$push: {tags: "vip"}, $set: {owner: "lee"}})
rs0 [direct: primary] test> db.acct.deleteOne({_id: 1})
{ acknowledged: true, deletedCount: 1 }
rs0 [direct: primary] test> var oplog = db.getSiblingDB("local").oplog.rs
rs0 [direct: primary] test> oplog.find({ns: /^test\./}).sort({$natural: 1}).toArray()
[
  {
    op: 'c',
    ns: 'test.$cmd',
    ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
    o: { create: 'acct', idIndex: { v: 2, key: { _id: 1 }, name: '_id_' } },
    ts: Timestamp({ t: 1790515993, i: 1 }),
    t: Long('1'),
    v: Long('2'),
    wall: ISODate('2026-09-27T13:33:13.959Z')
  },
  {
    lsid: {
      id: UUID('b118290d-8a6a-4978-98bd-e837a248813e'),
      uid: Binary.createFromBase64('47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=', 0)
    },
    txnNumber: Long('1'),
    op: 'i',
    ns: 'test.acct',
    ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
    o: { _id: 1, owner: 'kim', balance: 100, tags: [ 'new' ] },
    o2: { _id: 1 },
    stmtId: 0,
    ts: Timestamp({ t: 1790515993, i: 2 }),
    t: Long('1'),
    v: Long('2'),
    wall: ISODate('2026-09-27T13:33:13.959Z'),
    prevOpTime: { ts: Timestamp({ t: 0, i: 0 }), t: Long('-1') }
  },
  {
...
    txnNumber: Long('2'),
    op: 'u',
    ns: 'test.acct',
    ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
    o: { '$v': 2, diff: { u: { balance: 110 } } },
    o2: { _id: 1 },
    stmtId: 0,
    ts: Timestamp({ t: 1790515993, i: 3 }),
...
  },
  {
...
    txnNumber: Long('3'),
    op: 'u',
    ns: 'test.acct',
    ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
    o: {
      '$v': 2,
      diff: { u: { owner: 'lee' }, stags: { a: true, u1: 'vip' } }
    },
    o2: { _id: 1 },
    stmtId: 0,
    ts: Timestamp({ t: 1790515993, i: 4 }),
...
  },
  {
...
    txnNumber: Long('4'),
    op: 'd',
    ns: 'test.acct',
    ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
    o: { _id: 1 },
    stmtId: 0,
    ts: Timestamp({ t: 1790515993, i: 5 }),
...
  }
]
```

- 첫 insert가 컬렉션을 암묵적으로 만들었으므로, 그 앞에 `op: 'c'`, `o: { create: 'acct', ... }` 엔트리가 먼저 있습니다. 명령 엔트리의 `ns`는 `test.$cmd`입니다. 이 엔트리의 `ui`가 새 컬렉션의 UUID이고, 뒤의 엔트리는 모두 같은 `ui`를 가리킵니다.
- `ts`는 `{t: 초, i: 그 초 안의 순번}`입니다. 같은 1790515993초 안에서 `i`가 1부터 5까지 1씩 늘었습니다. `t: Long('1')`은 셋을 만든 뒤 첫 term이라는 뜻입니다.
- insert의 `o`는 도큐먼트 전체, delete의 `o`는 `_id`뿐입니다. 지우는 쪽은 무엇을 지울지만 알면 됩니다.
- update의 `o`에는 명령에 쓴 `$inc`나 `$push`가 없습니다. 대신 `$v: 2`와 `diff`가 있습니다. 바로 다음 절에서 봅니다.
- 모든 CRUD 엔트리에 `lsid`, `txnNumber`, `stmtId`가 붙었습니다. mongosh는 기본으로 **retryable write**를 켜서 쓰기마다 세션 ID와 증가하는 트랜잭션 번호를 보내고, 서버는 이 번호를 oplog에 남겨 둡니다. 연결이 끊겨 드라이버가 같은 쓰기를 다시 보내도, 새 primary가 자기 oplog(와 `config.transactions`)를 보고 "이미 한 쓰기"라는 것을 알아 두 번 실행하지 않습니다([6편](/posts/mongodb/06-election/)의 retryable write와 이어지는 내용입니다).

### 쓰기와 oplog 기록은 같은 트랜잭션으로 커밋된다

도큐먼트를 바꾸고 oplog에 한 줄 쓰는 일이 따로 커밋된다면, 그 사이에 mongod가 죽었을 때 "데이터는 바뀌었는데 oplog에는 없는" 상태가 생기고, 그 변경은 secondary에 영영 가지 않습니다. MongoDB는 두 쓰기를 **같은 WiredTiger 트랜잭션**에 넣어 이런 틈을 없앱니다.

1. insert, update, delete 경로는 컬렉션과 인덱스를 고친 뒤 같은 `WriteUnitOfWork`(mongod가 WiredTiger 트랜잭션을 감싼 단위) 안에서 **OpObserver**를 부릅니다([`OpObserverImpl::onInserts()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp#L724), [`onUpdate()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp#L892), [`onDelete()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp#L1081)).
2. OpObserver는 [`logOp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L525)로 oplog 엔트리를 씁니다. 여기서 여는 `WriteUnitOfWork`는 바깥 것 안에 중첩되므로 따로 커밋되지 않고 바깥 트랜잭션과 함께 커밋됩니다([`oplog.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L580)).
3. 엔트리의 `ts`는 [`LocalOplogInfo::getNextOpTimes()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/catalog/local_oplog_info.cpp#L96)가 mutex 안에서 cluster time을 한 칸 올려 예약합니다. 그래서 `ts`는 겹치지 않고 늘 증가합니다. 이 값은 oplog의 RecordId가 되고, 같은 값이 WiredTiger 트랜잭션의 commit timestamp로도 설정됩니다([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L1246-L1249)).

결과적으로 도큐먼트의 새 버전과 oplog 엔트리는 **같은 timestamp로 함께 보이거나, 함께 없습니다**. [3편](/posts/mongodb/03-mvcc-and-snapshot/)에서 본 timestamp 기반 스냅샷이 여기서 쓰입니다. "timestamp T 시점의 데이터"와 "T까지의 oplog"가 늘 짝이 맞으므로, secondary는 T까지 적용했다고 말할 수 있고, 장애 복구([2편](/posts/mongodb/02-checkpoint-and-journal/))도 체크포인트 timestamp 뒤의 oplog만 다시 적용하면 됩니다.

## 연산자 update는 결과 값으로 기록된다

앞의 출력에서 `$inc: {balance: 10}`은 oplog에 `diff: { u: { balance: 110 } }`, 즉 "balance를 110으로 설정"으로 기록되었습니다. `$push: {tags: "vip"}`와 `$set`은 `diff: { u: { owner: 'lee' }, stags: { a: true, u1: 'vip' } }`로 바뀌었습니다. `u`는 필드 값 설정, `s`로 시작하는 `stags`는 `tags` 필드 안쪽의 변경(sub-diff), 그 안의 `a: true`는 배열이라는 표시, `u1`은 "1번 원소를 `'vip'`로"입니다([`document_diff_serialization.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/update/document_diff_serialization.h#L72-L79)). `$v: 2`는 이런 delta 형식이라는 표시로, 4.7에서 도입되었고 5.1부터 모든 update가 이 형식으로 기록됩니다([`update_oplog_entry_version.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/update/update_oplog_entry_version.h#L48-L61)). update를 실행하면서 무엇이 바뀌었는지를 [`V2LogBuilder`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/update/v2_log_builder.h#L54)가 모아 이 형식으로 만듭니다.

왜 `$inc`를 그대로 적지 않을까요? oplog 엔트리는 **여러 번 적용되어도 결과가 같아야**(멱등, idempotent) 하기 때문입니다. secondary가 같은 엔트리를 다시 적용하는 일은 드물지 않습니다.

- initial sync는 데이터를 복사하는 동안 쌓인 oplog를 복사가 끝난 뒤 적용합니다. 복사한 도큐먼트에 이미 반영된 변경을 한 번 더 적용하게 됩니다.
- 장애 뒤 재시작하면 마지막 체크포인트 이후의 oplog를 다시 적용하는데([2편](/posts/mongodb/02-checkpoint-and-journal/)), 어디까지 이미 반영됐는지를 엔트리 하나 단위로 알 수는 없습니다.

`$inc: 10`을 두 번 적용하면 120이 되지만, "110으로 설정"은 몇 번 적용해도 110입니다. 비슷한 이유로 secondary는 insert할 도큐먼트가 이미 있으면 오류로 멈추지 않고 그 `_id`에 대한 update(upsert)로 바꿔 적용합니다([`applyOperation_inlock()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp#L1794-L1826)).

#### 같은 엔트리를 두 번 적용해도 결과는 같다

`applyOps`는 oplog 엔트리 모양의 연산을 그대로 적용하는 관리 명령입니다(일반 애플리케이션이 쓸 명령은 아니고, 여기서는 확인용으로만 씁니다). `$inc`로 만든 oplog 엔트리의 `o`를 꺼내 두 번 적용하고, 마지막에 같은 `$inc`를 명령으로 한 번 더 실행해 비교합니다.

```mongosh
rs0 [direct: primary] test> db.acct.insertOne({_id: 2, balance: 100})
{ acknowledged: true, insertedId: 2 }
rs0 [direct: primary] test> db.acct.updateOne({_id: 2}, {$inc: {balance: 10}})
rs0 [direct: primary] test> var e = db.getSiblingDB("local").oplog.rs.find({ns: "test.acct", op: "u", "o2._id": 2}).sort({$natural: -1}).limit(1).next()
rs0 [direct: primary] test> e.o
{ '$v': 2, diff: { u: { balance: 110 } } }
rs0 [direct: primary] test> db.adminCommand({applyOps: [{op: "u", ns: "test.acct", o2: {_id: 2}, o: e.o}]})
{
  applied: 1,
  results: [ true ],
  ok: 1,
...
}
rs0 [direct: primary] test> db.adminCommand({applyOps: [{op: "u", ns: "test.acct", o2: {_id: 2}, o: e.o}]})
{
  applied: 1,
  results: [ true ],
  ok: 1,
...
}
rs0 [direct: primary] test> db.acct.findOne({_id: 2})
{ _id: 2, balance: 110 }
rs0 [direct: primary] test> db.acct.updateOne({_id: 2}, {$inc: {balance: 10}})
rs0 [direct: primary] test> db.acct.findOne({_id: 2})
{ _id: 2, balance: 120 }
```

oplog 엔트리를 두 번 적용한 뒤에도 잔액은 110 그대로입니다. 같은 `$inc`를 명령으로 다시 실행하자 120이 되었습니다. 명령은 "현재 값에서 10 더하기"이고, oplog 엔트리는 "그 결과가 110"이라는 사실입니다.

## 여러 도큐먼트를 바꾸는 명령과 트랜잭션

명령 하나가 도큐먼트 여러 개를 바꿀 때 oplog에 몇 줄이 남는지는 명령마다 다릅니다.

#### insertMany, updateMany, deleteMany, 트랜잭션

도큐먼트 3개를 `insertMany`로 넣고, `updateMany`로 고치고, `deleteMany`로 지웁니다. 그리고 트랜잭션 하나로 insert와 update를 함께 합니다. 시작 전의 마지막 `ts`를 `start`에 적어 두고 그 뒤의 엔트리만 봅니다.

```mongosh
rs0 [direct: primary] test> var start = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
rs0 [direct: primary] test> db.acct.insertMany([{_id: 11, g: 1}, {_id: 12, g: 1}, {_id: 13, g: 1}])
{ acknowledged: true, insertedIds: { '0': 11, '1': 12, '2': 13 } }
rs0 [direct: primary] test> db.acct.updateMany({g: 1}, {$set: {g: 2}})
rs0 [direct: primary] test> db.acct.deleteMany({g: 2})
{ acknowledged: true, deletedCount: 3 }
rs0 [direct: primary] test> var s = db.getMongo().startSession()
rs0 [direct: primary] test> s.startTransaction()
rs0 [direct: primary] test> s.getDatabase("test").acct.insertOne({_id: 21, balance: 50})
{ acknowledged: true, insertedId: 21 }
rs0 [direct: primary] test> s.getDatabase("test").acct.updateOne({_id: 2}, {$inc: {balance: -50}})
rs0 [direct: primary] test> s.commitTransaction()
rs0 [direct: primary] test> db.getSiblingDB("local").oplog.rs.find({$or: [{ns: "test.acct"}, {"o.applyOps.ns": "test.acct"}], ts: {$gt: start}}, {op: 1, ns: 1, o: 1, o2: 1, txnNumber: 1, stmtId: 1}).sort({$natural: 1}).toArray()
[
  {
    txnNumber: Long('1'),
    op: 'c',
    ns: 'admin.$cmd',
    o: {
      applyOps: [
        {
          op: 'i',
          ns: 'test.acct',
          ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
          o: { _id: 11, g: 1 },
          o2: { _id: 11 },
          stmtId: 0
        },
...
      ]
    }
  },
  {
    op: 'u',
    ns: 'test.acct',
    o: { '$v': 2, diff: { u: { g: 2 } } },
    o2: { _id: 11 }
  },
  {
    op: 'u',
    ns: 'test.acct',
    o: { '$v': 2, diff: { u: { g: 2 } } },
    o2: { _id: 12 }
  },
  {
    op: 'u',
    ns: 'test.acct',
    o: { '$v': 2, diff: { u: { g: 2 } } },
    o2: { _id: 13 }
  },
  {
    op: 'c',
    ns: 'admin.$cmd',
    o: {
      applyOps: [
        {
          op: 'd',
          ns: 'test.acct',
          ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
          o: { _id: 13 }
        },
...
      ]
    }
  },
  {
    txnNumber: Long('2'),
    op: 'c',
    ns: 'admin.$cmd',
    o: {
      applyOps: [
        {
          op: 'i',
          ns: 'test.acct',
          ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
          o: { _id: 21, balance: 50 },
          o2: { _id: 21 }
        },
        {
          op: 'u',
          ns: 'test.acct',
          ui: UUID('d975692c-f17f-4b5c-92a5-c412735d92d7'),
          o: { '$v': 2, diff: { u: { balance: 70 } } },
          o2: { _id: 2 }
        }
      ]
    }
  }
]
```

| 명령 | oplog에 남은 것 | 근거 |
|---|---|---|
| `insertMany` (3건) | `applyOps` 엔트리 **1개** 안에 insert 3개 | 8.0에서 켜진 `featureFlagReplicateVectoredInsertsTransactionally`. 트랜잭션이 아닌 여러 건 insert를 한 WUOW로 묶어 `applyOps`로 기록([`write_ops_exec.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/ops/write_ops_exec.cpp#L381-L389), [플래그](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L1014-L1021)) |
| `updateMany` (3건) | `u` 엔트리 **3개**, 도큐먼트마다 하나 | 묶는 경로가 없다 |
| `deleteMany` (3건) | `applyOps` 엔트리 **1개** 안에 delete 3개 | batched delete. `batchUserMultiDeletes`(기본 true)가 켜져 있고 트랜잭션, retryable write가 아니면 여러 delete를 묶는다([`delete_request.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/ops/delete_request.idl#L42-L48), [`planner_interface.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/classic_runtime_planner/planner_interface.cpp#L98-L106)) |
| 트랜잭션 | 커밋할 때 `applyOps` 엔트리 1개에 트랜잭션 안의 모든 연산 | 트랜잭션이 16MB를 넘으면 여러 엔트리로 나뉘어 `prevOpTime`으로 이어진다 |

- `applyOps`로 묶인 연산은 secondary에서도 한 번에 적용됩니다. 트랜잭션 엔트리 안의 update도 `$inc: -50`이 아니라 결과 값 `balance: 70`입니다(앞 실습에서 120이었던 잔액에서 50을 뺐습니다).
- `updateMany` 엔트리에는 `txnNumber`가 없습니다. 여러 도큐먼트를 바꾸는 update는 retryable write 대상이 아니기 때문입니다. 트랜잭션 엔트리의 `txnNumber: Long('2')`는 이 mongosh 세션에서 `insertMany`(1) 다음 두 번째로 쓴 트랜잭션 번호입니다.

#### 운영에서는: updateMany 한 번이 oplog를 채운다

`updateMany({}, {$set: {flag: true}})`처럼 도큐먼트 1000만 건을 고치는 명령은 명령 하나지만 oplog에는 1000만 줄이 남습니다. 그만큼 oplog window가 한꺼번에 줄어들고, secondary는 그 1000만 줄을 모두 받아 적용해야 하므로 복제 지연이 생깁니다. 대량 변경은 `_id` 범위로 나눠 천천히 실행하고, 실행하는 동안 [oplog window](#oplog-window)와 [복제 지연](#복제-지연)을 지켜봅니다. `deleteMany`는 묶여서 기록되지만, 지우는 도큐먼트 수만큼의 연산이 들어 있는 것은 같습니다.

## secondary가 oplog를 따라가는 과정

secondary는 oplog를 받아서 바로 컬렉션에 적용하지 않고 몇 단계를 거칩니다. 8.0에서 이 구조가 한 번 바뀌었습니다. 예전에는 applier가 "자기 oplog에 쓰기"와 "컬렉션에 적용"을 한 배치로 같이 했는데, 8.0에서는 oplog를 쓰는 **OplogWriter**가 따로 떨어져 나와 applier보다 먼저 달립니다(`featureFlagReduceMajorityWriteLatency`, 기본 켜짐이고 FCV와 무관, [`repl_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L1008-L1012)). 앞의 로그에서 본 `Starting replication writer thread`가 이 스레드입니다([`startSteadyStateReplication()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_external_state_impl.cpp#L260)).

{{< diagram src="/diagrams/mongo-replication-pipeline.html" title="secondary 복제 파이프라인: oplog 엔트리가 가는 길" height="640" caption="primary에서 도큐먼트 변경과 같은 트랜잭션으로 기록된 oplog 엔트리를, secondary의 OplogFetcher가 가져오고 OplogWriter가 자기 oplog에 쓴 뒤 OplogApplier가 컬렉션에 적용합니다. 각 단계의 위치는 Reporter가 replSetUpdatePosition으로 보고합니다." >}}

1. **sync source 고르기**: 누구에게서 받을지를 [`TopologyCoordinator::chooseNewSyncSource()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L279)가 정합니다. 자기보다 앞서 있고, primary보다 `maxSyncSourceLagSecs`(기본 30초, [`repl_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L377-L382)) 넘게 뒤처지지 않은 멤버 가운데 ping이 가장 짧은 멤버를 고릅니다([`_chooseNearbySyncSource()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L335)). secondary가 다른 secondary에게서 받는 것을 **chaining**이라고 하고 기본으로 허용됩니다(`settings.chainingAllowed`). 다만 8.0.32에서는 두 후보의 ping 차이가 `changeSyncSourceThresholdMillis` 안이면 같은 데이터센터로 보고 primary를 고릅니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L394-L410)). 한 데이터센터 안에서는 대개 primary에서 직접 받고, chaining은 멀리 떨어진 데이터센터의 secondary가 가까운 secondary에게서 받을 때 주로 생깁니다.
2. **OplogFetcher**: sync source의 `local.oplog.rs`에 `{ts: {$gte: 마지막으로 받은 ts}}`로 `find`를 보냅니다([`_makeFindCmdRequest()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp#L641)). tailable, awaitData 커서라 끝에 닿아도 닫히지 않고 새 엔트리를 기다리며, 기다리는 시간은 `electionTimeoutMillis`의 절반(기본 5초)입니다([`calculateAwaitDataTimeout()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp#L154)). `oplogFetcherUsesExhaust`(기본 true, [`repl_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L152-L160))라 exhaust 커서로 열어서, sync source가 getMore 요청을 기다리지 않고 새 배치를 계속 밀어 보냅니다. 첫 배치의 첫 엔트리는 **내가 마지막으로 받은 엔트리와 같아야** 합니다. 다르면 두 oplog가 갈라졌다는 뜻이라 rollback([8편](/posts/mongodb/08-read-write-concern/))으로 가거나, sync source의 oplog가 이미 그 지점을 지웠으면 "too stale"이 됩니다([`_checkRemoteOplogStart()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp#L1059), [`_checkTooStaleToSyncFromSource()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp#L1149)).
3. **write buffer → OplogWriter**: 받은 엔트리는 메모리의 write buffer(최대 256MB, [`replication_coordinator_external_state_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_external_state_impl.cpp#L170-L178))에 쌓이고, OplogWriter가 배치로 꺼내 자기 `local.oplog.rs`에 씁니다. 쓴 뒤 **lastWritten**을 올리고 저널 flush를 요청하며, flush가 끝나면 **lastDurable**이 올라갑니다([`OplogWriterImpl::_run()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_writer_impl.cpp#L174), [`finalizeOplogBatch()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_writer_impl.cpp#L330)). 그다음 같은 엔트리를 apply buffer(최대 100MB 또는 1만 개)로 넘깁니다.
4. **apply buffer → OplogApplier**: applier는 엔트리를 배치로 모읍니다. 배치 하나는 최대 `replBatchLimitOperations`(5000개), `replBatchLimitBytes`(100MB)이고([`repl_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L283-L303)), 컬렉션 생성 같은 명령 엔트리는 혼자 한 배치가 됩니다([`_getBatchActionForEntry()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_batcher.cpp#L266)). 배치 안의 엔트리는 **네임스페이스와 `_id`의 해시**로 writer thread에 나눠 병렬로 적용합니다([`getOplogEntryHash()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_utils.cpp#L227-L241)). 같은 도큐먼트에 대한 연산은 늘 같은 스레드로 가서 순서가 지켜지고, 다른 도큐먼트는 동시에 적용됩니다. capped 컬렉션은 넣은 순서를 지켜야 하므로 `_id` 없이 네임스페이스로만 나눕니다([`processCrudOp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_utils.cpp#L122-L151)). writer thread 수는 `replWriterThreadCount`(기본 16)와 CPU 코어 수의 2배 가운데 작은 값입니다([`getThreadCountForReplWorkerPool()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_worker_pool_thread_count.cpp#L52-L55)). 배치가 모두 끝나면 **lastApplied**를 배치의 마지막 엔트리로 올립니다([`_applyOplogBatch()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_impl.cpp#L627)). 배치 중간 상태는 다른 쪽에 보이지 않고, 배치 단위로 한꺼번에 보입니다.
5. **위치 보고**: 세 위치는 `replSetUpdatePosition` 명령으로 sync source에 보고합니다. 이 명령에는 자기 위치뿐 아니라 자기에게서 받아 가는 멤버들의 위치도 함께 실리므로([`prepareReplSetUpdatePositionCommand()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2272)), chaining을 해도 primary는 모든 멤버의 위치를 압니다.

| 위치 | 뜻 | 쓰는 곳 |
|---|---|---|
| lastWritten | 자기 oplog에 쓴 곳까지 | `j: false`인 majority 쓰기 |
| lastDurable | 자기 oplog가 저널까지 flush된 곳까지 | majority commit point(기본) |
| lastApplied | 컬렉션에 적용까지 끝난 곳까지 | 읽기에 보이는 곳, `rs.status()`의 `optime` |

primary는 투표권이 있는 멤버들의 lastDurable(`writeConcernMajorityJournalDefault`를 끈 셋이면 lastWritten)을 정렬해 과반이 도달한 위치를 **majority commit point**로 삼습니다([`updateLastCommittedOpTimeAndWallTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L3040-L3077)). 8.0에서 OplogWriter를 따로 둔 이유가 여기 있습니다. secondary가 컬렉션에 적용하기 전이라도 oplog가 디스크에 닿기만 하면 majority 쓰기를 확인해 줄 수 있어서, `w: "majority"` 쓰기가 기다리는 시간이 줄어듭니다. 이 위치들이 읽기와 쓰기에 무엇을 보장하는지는 [8편](/posts/mongodb/08-read-write-concern/)에서 다룹니다.

#### secondary의 파이프라인 지표

`m05-3`에 접속해 멤버 상태와 `serverStatus().metrics.repl`을 봅니다.

```mongosh
rs0 [direct: secondary] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, syncSourceHost: m.syncSourceHost}))
[
  { name: 'm05-1:27017', stateStr: 'PRIMARY', syncSourceHost: '' },
  {
    name: 'm05-2:27017',
    stateStr: 'SECONDARY',
    syncSourceHost: 'm05-1:27017'
  },
  {
    name: 'm05-3:27017',
    stateStr: 'SECONDARY',
    syncSourceHost: 'm05-1:27017'
  }
]
rs0 [direct: secondary] test> var r = db.serverStatus().metrics.repl
rs0 [direct: secondary] test> r.buffer
{
  write: {
    count: Long('0'),
    sizeBytes: Long('0'),
    maxSizeBytes: Long('268435456')
  },
  apply: {
    count: Long('0'),
    sizeBytes: Long('0'),
    maxSizeBytes: Long('104857600'),
    maxCount: Long('10000')
  }
}
rs0 [direct: secondary] test> r.network
{
  bytes: Long('7667'),
  getmores: { num: 27, totalMillis: 2781, numEmptyBatches: Long('13') },
...
  oplogFetcherHighestFetchedOptime: { ts: Timestamp({ t: 1790515995, i: 6 }), t: Long('1') },
  oplogFetcherLagSeconds: Long('0'),
...
  replSetUpdatePosition: { num: Long('53') }
}
rs0 [direct: secondary] test> r.apply
{
  attemptsToBecomeSecondary: Long('1'),
  batchSize: Long('29'),
  batches: { num: 26, totalMillis: 30 },
  ops: Long('43')
}
rs0 [direct: secondary] test> r.write
{ batchSize: Long('29'), batches: { num: 13, totalMillis: 0 } }
```

- 이제 두 secondary 모두 `syncSourceHost: 'm05-1:27017'`, primary에서 직접 받고 있습니다.
- `buffer.write`와 `buffer.apply`가 앞의 3, 4단계의 두 버퍼입니다. 최대 크기가 소스의 256MB(`268435456`)와 100MB, 1만 개 그대로입니다. 둘 다 `count: 0`이라 밀린 엔트리가 없습니다. 복제가 밀리면 이 `count`와 `sizeBytes`가 먼저 올라갑니다.
- `network`는 OplogFetcher의 지표입니다. getMore 27번 가운데 13번이 빈 배치였습니다. 새 쓰기가 없어 awaitData 시간만큼 기다렸다가 빈손으로 돌아온 것입니다. `replSetUpdatePosition.num`은 위치를 보고한 횟수입니다.
- `write.batchSize`와 `apply.batchSize`는 배치로 처리한 엔트리의 누적 개수이고(둘 다 29), `batches.num`은 배치 수입니다. 같은 엔트리를 writer는 13번, applier는 26번에 나눠 처리했습니다. 두 단계가 따로 배치를 만든다는 것이 보입니다. `apply.ops`는 적용한 개별 연산 수로, `applyOps` 안의 연산처럼 엔트리 하나에서 여러 연산이 나오기도 해서 엔트리 수와 같지 않습니다.

## 복제 지연

secondary가 따라오지 못하면 primary와 secondary의 위치에 차이가 생깁니다. 이것이 **복제 지연**(replication lag)입니다. 흔한 원인은 secondary의 디스크나 CPU가 primary보다 약한 경우, secondary에서 무거운 읽기가 돌아 적용이 늦어지는 경우, 네트워크가 느린 경우, 그리고 [앞에서 본](#운영에서는-updatemany-한-번이-oplog를-채운다) 대량 쓰기입니다.

지연을 일부러 만들기 위해 `m05-3`의 mongod를 `SIGSTOP`으로 멈춥니다. 프로세스는 살아 있지만 아무 일도 하지 않으므로, 느려서 따라오지 못하는 secondary와 비슷한 상태가 됩니다.

#### secondary 하나를 멈추면

```console
$ kill -STOP 17
$ ps -o pid,stat,cmd -p 17
$ date -u +%T.%3N
    PID STAT CMD
     17 Tl   mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0
13:33:15.865
```

프로세스 상태가 `T`(stopped)입니다. primary에서 도큐먼트 1000개를 넣고, 3초 쉬고, 하나를 더 넣은 뒤 지연을 봅니다.

```mongosh
rs0 [direct: primary] test> new Date()
ISODate('2026-09-27T13:33:16.172Z')
rs0 [direct: primary] test> for (let i = 0; i < 1000; i++) db.lag.insertOne({i: i, pad: "x".repeat(200)})
rs0 [direct: primary] test> sleep(3000)
rs0 [direct: primary] test> db.lag.insertOne({i: "last"})
rs0 [direct: primary] test> rs.printSecondaryReplicationInfo()
source: m05-2:27017
{
  syncedTo: 'Sun Sep 27 2026 13:33:16 GMT+0000 (Coordinated Universal Time)',
  replLag: '3 secs (0 hrs) behind the primary '
}
---
source: m05-3:27017
{
  syncedTo: 'Sun Sep 27 2026 13:33:15 GMT+0000 (Coordinated Universal Time)',
  replLag: '4 secs (0 hrs) behind the primary '
}
rs0 [direct: primary] test> rs.status().members.map(m => ({name: m.name, optimeDate: m.optimeDate, lastAppliedWallTime: m.lastAppliedWallTime}))
[
  {
    name: 'm05-1:27017',
    optimeDate: ISODate('2026-09-27T13:33:19.000Z'),
    lastAppliedWallTime: ISODate('2026-09-27T13:33:19.949Z')
  },
  {
    name: 'm05-2:27017',
    optimeDate: ISODate('2026-09-27T13:33:16.000Z'),
    lastAppliedWallTime: ISODate('2026-09-27T13:33:19.949Z')
  },
  {
    name: 'm05-3:27017',
    optimeDate: ISODate('2026-09-27T13:33:15.000Z'),
    lastAppliedWallTime: ISODate('2026-09-27T13:33:15.088Z')
  }
]
```

`rs.printSecondaryReplicationInfo()`에 따르면 멈춘 `m05-3`는 4초, 멀쩡한 `m05-2`도 3초 뒤처져 있습니다. 그런데 `m05-2`가 정말 뒤처졌을까요?

- `rs.status()`의 `optimeDate`는 **heartbeat**로 받은 위치입니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2135-L2143)). heartbeat는 2초마다 오가므로 최대 몇 초 전의 값이고, 게다가 초 단위로 잘립니다. `rs.printSecondaryReplicationInfo()`는 이 값으로 지연을 계산합니다.
- `lastAppliedWallTime`은 `replSetUpdatePosition`으로 받은 위치의 벽시계 시각입니다. `m05-2`는 13:33:19.949로 primary와 같습니다. `m05-2`는 이미 마지막 엔트리까지 적용했고, `printSecondaryReplicationInfo()`의 "3 secs"는 heartbeat가 늦게 알려 준 값이었습니다.
- `m05-3`는 두 값이 모두 13:33:15에 멈춰 있습니다. 멈춘 시각(13:33:15.865) 직전입니다. 정말로 뒤처진 멤버입니다.

이 상태에서 쓰기 확인 수준(write concern)을 바꿔 가며 씁니다.

```mongosh
rs0 [direct: primary] test> db.lag.insertOne({i: "w3"}, {writeConcern: {w: 3, wtimeout: 3000}})
Uncaught:
MongoWriteConcernError[WriteConcernFailed]: waiting for replication timed out
Additional information: {
  wtimeout: true,
  writeConcern: { w: 3, wtimeout: 3000, provenance: 'clientSupplied' }
}
Result: {
  n: 1,
...
  writeConcernError: {
    code: 64,
    codeName: 'WriteConcernFailed',
    errmsg: 'waiting for replication timed out',
...
}
rs0 [direct: primary] test> db.lag.insertOne({i: "wmaj"}, {writeConcern: {w: "majority", wtimeout: 3000}})
{
  acknowledged: true,
  insertedId: ObjectId('6ab91b236e3ef956ff05513f')
}
```

- `w: 3`는 세 멤버 모두가 이 쓰기를 받았다고 보고할 때까지 기다리라는 뜻입니다. `m05-3`가 멈춰 있으니 3초(`wtimeout`) 뒤 **`waiting for replication timed out`** 오류가 났습니다. 그런데 결과의 `n: 1`이 말하듯 **쓰기 자체는 primary에서 이미 끝났습니다.** write concern 오류는 "원하는 만큼 복제됐는지 확인하지 못했다"는 뜻이지 "쓰기가 취소됐다"는 뜻이 아닙니다. 이 점에서 [PostgreSQL 동기 복제](/posts/postgresql/09-streaming-replication/#동기-복제-커밋이-standby를-기다린다)를 기다리다 취소했을 때와 같습니다.
- `w: "majority"`는 세 멤버 가운데 두 멤버면 되므로 `m05-2`만으로 바로 끝났습니다. 멤버 하나가 멈춰도 majority 쓰기는 계속됩니다.

10초를 더 기다린 뒤 멤버 상태를 봅니다.

```mongosh
rs0 [direct: primary] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health, optimeDate: m.optimeDate, lastHeartbeatMessage: m.lastHeartbeatMessage}))
[
...
  {
    name: 'm05-3:27017',
    stateStr: '(not reachable/healthy)',
    health: 0,
    optimeDate: ISODate('1970-01-01T00:00:00.000Z'),
    lastHeartbeatMessage: 'no response within election timeout period'
  }
]
```

heartbeat에 `electionTimeoutMillis`(10초) 동안 응답하지 않자, primary는 `m05-3`를 `health: 0`, `(not reachable/healthy)`로 표시했습니다. 이때부터는 위치도 모른다는 뜻으로 `optimeDate`가 1970년(0)이 됩니다. 멈춘 것이 primary였다면 이 시점에 선출이 시작됩니다([6편](/posts/mongodb/06-election/)).

#### 다시 움직이면 따라잡는다

```console
$ kill -CONT 17
$ ps -o pid,stat,cmd -p 17
    PID STAT CMD
     17 Rl   mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0
```

5초 뒤:

```mongosh
rs0 [direct: primary] test> rs.printSecondaryReplicationInfo()
...
source: m05-3:27017
{
  syncedTo: 'Sun Sep 27 2026 13:33:23 GMT+0000 (Coordinated Universal Time)',
  replLag: '0 secs (0 hrs) behind the primary '
}
```

`m05-3`에서:

```mongosh
rs0 [direct: secondary] test> db.lag.countDocuments()
1003
rs0 [direct: secondary] test> var r = db.serverStatus().metrics.repl
rs0 [direct: secondary] test> r.apply
{
  attemptsToBecomeSecondary: Long('1'),
  batchSize: Long('1033'),
  batches: { num: 30, totalMillis: 45 },
  ops: Long('2050')
}
```

- 5초 만에 지연이 0초가 되었고, 멈춘 동안 들어간 1003건(1000 + `last`, `w3`, `wmaj`)이 모두 있습니다.
- 멈추기 전 [지표](#secondary의-파이프라인-지표)와 비교하면 `batchSize`가 29에서 1033으로 1004 늘었는데 `batches.num`은 26에서 30으로 4번 늘었을 뿐입니다. 밀린 엔트리 1000여 개를 배치 몇 번에 몰아서 적용했습니다. 평소에는 새 엔트리가 조금씩 와서 배치가 작지만, 밀리면 배치가 커져 따라잡는 속도가 빨라집니다.

primary는 oplog에 남아 있는 한 secondary가 얼마나 멈춰 있었든 그 지점부터 이어서 보내 줍니다. PostgreSQL처럼 replication slot을 만들 필요는 없습니다. 대신 **oplog에 남아 있는 동안만**이라는 조건이 붙습니다.

#### 운영에서는: 복제 지연을 볼 때

- `rs.printSecondaryReplicationInfo()`와 `rs.status()`의 `optimeDate`는 heartbeat 기준이라 몇 초의 오차가 있습니다. 위 실습처럼 멀쩡한 secondary도 2~3초 뒤처져 보일 수 있으므로, 몇 초 수준의 지연 알람은 오탐이 됩니다. 초 단위보다 정밀하게 보려면 `lastAppliedWallTime`이나 secondary 쪽의 `metrics.repl`을 봅니다.
- 지연이 생기면 어느 단계가 막혔는지 나눠 봅니다. secondary의 `metrics.repl.buffer.write.count`가 크면 OplogWriter(자기 oplog 쓰기, 저널 flush)가, `buffer.apply.count`가 크면 applier(컬렉션과 인덱스 적용)가 따라가지 못하는 것입니다. 버퍼가 비어 있는데도 뒤처져 있다면 받아 오는 쪽(네트워크, sync source)을 봅니다.
- `w`에 숫자를 쓰면 멤버 하나만 멈춰도 쓰기가 `wtimeout`까지 기다립니다. `wtimeout`을 주지 않으면 **끝없이** 기다립니다. 보통은 `w: "majority"`를 씁니다.

## oplog window

oplog는 capped 컬렉션이라 정한 크기를 넘으면 오래된 엔트리를 지웁니다. 지우는 일은 **OplogCapMaintainerThread**가 따로 맡습니다([`oplog_cap_maintainer_thread.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/oplog_cap_maintainer_thread.cpp#L169)). 엔트리를 하나씩 지우지 않고, oplog를 **truncate marker**라는 구간(기본 크기의 1/10 정도, 최소 10개, [`oplog_truncate_marker_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/oplog_truncate_marker_parameters.idl#L50-L56))으로 나눠 두었다가 가장 오래된 구간을 통째로 잘라 냅니다([`reclaimOplog()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L1019)).

그런데 크기를 넘었다고 언제나 자를 수 있는 것은 아닙니다. 잘라도 되는 한계(**pinned oplog**)가 있고, 가장 오래된 구간이 이 한계를 넘으면 자르지 않습니다([`_hasExcessMarkers()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L450-L482), [`getPinnedOplog()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2634-L2663)).

- **마지막 stable 체크포인트가 필요로 하는 oplog**: 장애 복구는 체크포인트부터 oplog를 다시 적용하므로([2편](/posts/mongodb/02-checkpoint-and-journal/)), 그 체크포인트 이후의 oplog는 지울 수 없습니다. 이 값은 체크포인트를 끝낼 때마다 갱신됩니다([`wiredtiger_kv_engine.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2113-L2127)).
- **stable timestamp**: majority commit point를 넘지 않는 선에서 정해지는 timestamp입니다([3편](/posts/mongodb/03-mvcc-and-snapshot/)). rollback은 여기서부터 oplog를 다시 적용하므로 그 뒤를 지우지 않습니다([`getOplogNeededForRollback()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2598)). 과반이 받지 못한 엔트리는 지워지지 않는다는 뜻입니다.
- 백업 커서가 열려 있으면 그 시점, `oplogMinRetentionHours`를 정했으면 그 시간.

그래서 oplog는 설정한 크기를 잠깐씩 넘을 수 있습니다. 반대로 이 보호는 **과반**까지만입니다. 과반에 들지 못한 뒤처진 secondary를 위해 oplog를 남겨 두지는 않습니다.

#### 작은 oplog로 확인하기

레플리카셋을 `--oplogSize 1`(1MB)로 새로 만들고, 1KB짜리 도큐먼트 3000개를 넣습니다.

```console
$ mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0 --oplogSize 1 | grep -E 'forked|ERROR'
forked process: 33
```

```mongosh
rs0 [direct: primary] test> rs.printReplicationInfo()
actual oplog size
'1 MB'
---
configured oplog size
'1 MB'
...
rs0 [direct: primary] test> for (let i = 0; i < 3000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
rs0 [direct: primary] test> var st = db.getSiblingDB("local").oplog.rs.stats(); ({size: st.size, maxSize: st.maxSize, count: st.count})
{ size: 3969425, maxSize: 1048576, count: 3017 }
```

설정은 1MB(`maxSize: 1048576`)인데 oplog는 약 3.8MB, 엔트리 3017개입니다. 아직 한 줄도 지우지 않았습니다. 셋을 만든 뒤 아직 주기 체크포인트(기본 60초, [2편](/posts/mongodb/02-checkpoint-and-journal/))가 한 번도 돌지 않아, 셋을 만들 때 찍은 체크포인트 이후의 oplog가 모두 "복구에 필요한 oplog"로 묶여 있기 때문입니다. 마지막 stable 체크포인트(`lastStableRecoveryTimestamp`)가 지금 oplog 끝을 지날 때까지 기다렸다가 1000개를 더 넣습니다.

```mongosh
rs0 [direct: primary] test> var t0 = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
rs0 [direct: primary] test> while (rs.status().lastStableRecoveryTimestamp.t <= t0.t) sleep(1000)
rs0 [direct: primary] test> for (let i = 0; i < 1000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> var st = db.getSiblingDB("local").oplog.rs.stats(); ({size: st.size, maxSize: st.maxSize, count: st.count})
{ size: 1379155, maxSize: 1048576, count: 1046 }
rs0 [direct: primary] test> rs.printReplicationInfo()
actual oplog size
'1.3152647018432617 MB'
---
configured oplog size
'1 MB'
---
log length start to end
'47 secs (0.01 hrs)'
---
oplog first event time
'Sun Sep 27 2026 13:33:56 GMT+0000 (Coordinated Universal Time)'
---
oplog last event time
'Sun Sep 27 2026 13:34:43 GMT+0000 (Coordinated Universal Time)'
...
```

```console
$ jq -c 'select(.msg=="WiredTiger record store oplog truncation finished")|{t:.t."$date",attr}' /data/mongod.log | tail -2
{"t":"2026-09-27T13:34:42.977+00:00","attr":{"pinnedOplogTimestamp":{"$timestamp":{"t":1790516072,"i":1}},"numRecords":723,"dataSize":952149,"durationMillis":0}}
{"t":"2026-09-27T13:34:43.043+00:00","attr":{"pinnedOplogTimestamp":{"$timestamp":{"t":1790516072,"i":1}},"numRecords":723,"dataSize":952149,"durationMillis":0}}
```

- 체크포인트가 지나간 뒤 새 쓰기로 truncate marker가 생기자, 그제야 잘라 내기가 일어났습니다(`oplog truncation finished`). `pinnedOplogTimestamp`는 이때 잘라도 되는 한계였고, 잘라 낸 뒤 남은 엔트리가 723개, 약 0.9MB입니다. 그 뒤에 들어간 엔트리까지 합쳐 지금은 1046개, 1.3MB입니다.
- window는 47초가 되었습니다. 이 oplog는 지금 쓰기 속도로 47초 분량만 담고 있습니다. **47초 넘게 뒤처진 secondary는 이 primary에서 이어 받을 수 없다**는 뜻입니다.

#### window 밖으로 밀려난 secondary

`m05-3`를 다시 멈추고, 이번에는 window를 넘길 만큼 씁니다. primary와 `m05-2` 두 멤버 모두 체크포인트가 지나간 뒤 한 번 더 써서, 두 멤버의 oplog가 모두 잘리게 합니다. 멤버마다 oplog를 따로 자르기 때문에, 한쪽이라도 필요한 엔트리를 갖고 있으면 `m05-3`는 그쪽에서 받아 따라잡을 수 있습니다.

```console
$ kill -STOP 17
$ date -u +%T.%3N
13:34:45.690
```

```mongosh
rs0 [direct: primary] test> for (let i = 0; i < 3000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
rs0 [direct: primary] test> var t0 = db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(1).next().ts
rs0 [direct: primary] test> var m2 = new Mongo("m05-2:27017")
rs0 [direct: primary] test> while (rs.status().lastStableRecoveryTimestamp.t <= t0.t || m2.getDB("admin").runCommand({replSetGetStatus: 1}).lastStableRecoveryTimestamp.t <= t0.t) sleep(1000)
rs0 [direct: primary] test> for (let i = 0; i < 1000; i++) db.big.insertOne({i: i, pad: "x".repeat(1000)})
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> db.getSiblingDB("local").oplog.rs.find().sort({$natural: 1}).limit(1).next().ts
Timestamp({ t: 1790516088, i: 64 })
rs0 [direct: primary] test> m2.getDB("local").oplog.rs.find().sort({$natural: 1}).limit(1).next().ts
Timestamp({ t: 1790516088, i: 64 })
```

두 멤버의 oplog 첫 엔트리가 모두 1790516088초(13:34:48)가 되었습니다. `m05-3`를 다시 움직이고, `m05-3`가 RECOVERING이 될 때까지 기다립니다.

```console
$ kill -CONT 17
```

```mongosh
rs0 [direct: primary] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, optimeDate: m.optimeDate}))
[
...
  {
    name: 'm05-3:27017',
    stateStr: 'RECOVERING',
    optimeDate: ISODate('2026-09-27T13:34:47.000Z')
  }
]
```

```console
$ jq -c 'select(.msg|test("too stale|Too stale"))|{t:.t."$date",s,msg,attr}' /data/mongod.log
{"t":"2026-09-27T13:35:46.952+00:00","s":"W","msg":"Oplog fetcher discovered we are too stale to sync from sync source. Denylisting sync source","attr":{"syncSource":"m05-1:27017","denylistDurationMillis":60000}}
{"t":"2026-09-27T13:35:46.953+00:00","s":"I","msg":"We are too stale to use candidate as a sync source. Denylisting this sync source because our last fetched timestamp is before their earliest timestamp","attr":{"candidate":"m05-2:27017","lastOpTimeFetchedTimestamp":{"$timestamp":{"t":1790516087,"i":299}},"remoteEarliestOpTimeTimestamp":{"$timestamp":{"t":1790516088,"i":64}},"denylistDurationMinutes":1,"denylistUntil":{"$date":"2026-09-27T13:36:46.953Z"}}}
{"t":"2026-09-27T13:35:46.953+00:00","s":"E","msg":"Too stale to catch up. Entering maintenance mode. See http://dochub.mongodb.org/core/resyncingaverystalereplicasetmember","attr":{"lastOpTimeFetched":{"ts":{"$timestamp":{"t":1790516087,"i":299}},"t":1},"earliestOpTimeSeen":{"ts":{"$timestamp":{"t":1790516088,"i":64}},"t":1}}}
```

```mongosh
rs0 [direct: other] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, infoMessage: m.infoMessage}))
[
  { name: 'm05-1:27017', stateStr: 'PRIMARY', infoMessage: '' },
  { name: 'm05-2:27017', stateStr: 'SECONDARY', infoMessage: '' },
  {
    name: 'm05-3:27017',
    stateStr: 'RECOVERING',
    infoMessage: 'Could not find member to sync from'
  }
]
```

`m05-3`의 로그가 세 단계를 그대로 보여 줍니다.

1. OplogFetcher가 sync source `m05-1`에 이어 받기를 요청했는데, 첫 엔트리가 자기가 마지막으로 받은 엔트리와 달랐고 `m05-1`의 가장 오래된 엔트리가 그보다 뒤였습니다. `discovered we are too stale`로 `m05-1`을 60초 동안 후보에서 뺍니다(denylist).
2. 다른 후보 `m05-2`를 봤지만, 마지막으로 받은 엔트리 `1790516087, 299`가 `m05-2`의 가장 오래된 엔트리 `1790516088, 64`보다 앞이라 역시 뺍니다.
3. 받을 수 있는 멤버가 하나도 없자 **`Too stale to catch up. Entering maintenance mode.`**를 오류(`"s":"E"`)로 남기고 maintenance mode를 켜 RECOVERING 상태로 들어갑니다([`bgsync.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/bgsync.cpp#L389-L438)). 프롬프트의 `[direct: other]`가 이 상태입니다. RECOVERING 멤버는 읽기를 받지 않고, sync source를 찾지 못했다는 `Could not find member to sync from`을 계속 띄웁니다.

로그의 `lastOpTimeFetched`는 1790516087초(13:34:47)인데, `m05-3`를 멈춘 것은 13:34:45.690였습니다. 멈춘 뒤 1초 넘게 더 받은 셈입니다. OplogFetcher가 exhaust 커서를 쓰기 때문으로 보입니다. sync source는 getMore를 기다리지 않고 배치를 계속 보내므로, 멈춘 프로세스가 읽지 않은 배치가 소켓 버퍼에 쌓여 있다가 다시 움직였을 때 읽힌 것입니다. 이렇게 받은 엔트리도 그 뒤의 엔트리가 이미 잘려 나간 뒤라 소용이 없었습니다.

RECOVERING은 저절로 풀리지 않습니다. 필요한 엔트리가 어느 멤버에도 없으니 기다려도 따라잡을 방법이 없습니다.

#### initial sync로 다시 만든다

이런 멤버는 데이터를 처음부터 다시 받는 **initial sync**로 되살립니다. 보통은 mongod를 멈추고 dbPath를 비운 뒤 다시 시작합니다. 여기서는 빈 디렉터리 `/data/db2`로 시작했습니다.

```console
$ mongod --dbpath /data/db --shutdown | tail -1
$ mkdir /data/db2
$ mongod --dbpath /data/db2 --logpath /data/mongod2.log --bind_ip_all --fork --replSet rs0 --oplogSize 1 | grep -E 'forked|ERROR'
Killing process with pid: 17
forked process: 230
$ jq -c 'select(.msg|test("^Starting initial sync attempt|^Setting begin applying|^Finished cloning data|^Initial sync done"))|{t:.t."$date",msg,attr}' /data/mongod2.log
{"t":"2026-09-27T13:35:52.950+00:00","msg":"Starting initial sync attempt","attr":{"initialSyncAttempt":1,"initialSyncMaxAttempts":10}}
{"t":"2026-09-27T13:35:53.038+00:00","msg":"Finished cloning data. Beginning oplog replay","attr":{"databaseClonerFinishStatus":"OK"}}
{"t":"2026-09-27T13:35:53.041+00:00","msg":"Initial sync done","attr":{"durationSeconds":0}}
```

```mongosh
rs0 [direct: primary] test> rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr, optimeDate: m.optimeDate}))
[
...
  {
    name: 'm05-3:27017',
    stateStr: 'SECONDARY',
    optimeDate: ISODate('2026-09-27T13:35:44.000Z')
  }
]
```

initial sync는 다음 순서로 진행합니다([`initial_syncer.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/initial_syncer.cpp)).

1. sync source를 고르고, 그 멤버의 oplog 끝 위치를 적어 둡니다.
2. 모든 데이터베이스와 컬렉션, 인덱스를 복사합니다(`Finished cloning data`). 복사하는 동안에도 쓰기는 계속되므로, 그동안의 oplog도 함께 받아 둡니다.
3. 복사가 끝나면 받아 둔 oplog를 적용합니다(`Beginning oplog replay`). 복사한 도큐먼트에는 이미 반영된 변경이 있을 수 있는데, [oplog가 멱등](#연산자-update는-결과-값으로-기록된다)하므로 다시 적용해도 괜찮습니다.

실습 데이터가 작아 1초도 걸리지 않았지만(`durationSeconds: 0`), 실제로는 데이터 크기에 비례해 몇 시간씩 걸립니다. 그리고 복사하는 동안 쌓이는 oplog가 sync source의 oplog window 안에 있어야 하므로, window가 복사 시간보다 짧으면 initial sync도 실패합니다.

## 운영에서는 이렇게 나타납니다

**oplog window가 곧 장애 허용 시간입니다.** secondary를 정비하거나 장애로 잃었을 때, oplog window 안에 돌아오면 이어서 따라잡고, 넘기면 [initial sync](#initial-sync로-다시-만든다)를 해야 합니다. `rs.printReplicationInfo()`의 `log length start to end`를 주기적으로 모니터링하고, 정비 작업에 필요한 시간(보통 수 시간)보다 넉넉한지 확인합니다. 쓰기가 가장 많은 시간대에 window가 가장 짧아진다는 점, 그리고 [대량 `updateMany`](#운영에서는-updatemany-한-번이-oplog를-채운다) 한 번이 window를 한꺼번에 줄인다는 점을 기억해 둡니다. window가 모자라면 `replSetResizeOplog`로 크기를 늘리거나 `oplogMinRetentionHours`로 최소 보존 시간을 정합니다. 둘 다 멤버마다 따로 설정해야 합니다(`local`은 복제되지 않습니다).

**복제 지연은 heartbeat 오차를 감안하고 봅니다.** [앞의 실습](#secondary-하나를-멈추면)처럼 heartbeat 기준 값은 2~3초 뒤처져 보일 수 있습니다. 알람 임계값은 수십 초 이상으로 잡고, 지연이 커지면 secondary의 `metrics.repl.buffer`로 막힌 단계를 나눕니다. secondary에서 읽기(`readPreference: secondary`)를 받는다면 지연만큼 오래된 데이터를 읽는다는 것도 애플리케이션이 알아야 합니다.

**`w` 숫자 지정과 `wtimeout`.** `w: 3`처럼 멤버 수를 적으면 멤버 하나의 장애가 곧 쓰기 대기로 이어집니다. `wtimeout`으로 끝난 쓰기는 **취소된 것이 아니라** primary에 이미 적용되어 있습니다. 재시도 로직을 만들 때 이 점을 반영해야 합니다.

**인덱스 빌드도 oplog로 복제됩니다.** primary에서 인덱스를 만들면 `startIndexBuild`와 `commitIndexBuild` 엔트리가 oplog에 남고([`OpObserverImpl::onStartIndexBuild()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp#L439), [`onCommitIndexBuild()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp#L511)), secondary도 `startIndexBuild`를 받으면 자기 인덱스를 따로 만들기 시작합니다. 큰 컬렉션의 인덱스 빌드는 모든 멤버의 CPU와 I/O를 함께 씁니다. 이 글에서는 실측하지 않았습니다.

**initial sync가 필요한 경우.** window 밖으로 밀려나 RECOVERING이 된 멤버, 디스크를 교체했거나 데이터가 깨진 멤버, 새로 추가하는 멤버입니다. initial sync는 sync source에 전체 읽기 부하를 주고, 끝날 때까지 그 멤버는 과반 계산에 도움이 되지 않습니다. 데이터가 크면 파일시스템 스냅샷이나 백업으로 dbPath를 채운 뒤 oplog로 따라잡게 하는 방법이 더 빠릅니다.

PostgreSQL 스트리밍 복제와 비교하면 다음과 같습니다.

| | PostgreSQL 스트리밍 복제 | MongoDB 레플리카셋 |
|---|---|---|
| 보내는 것 | WAL(페이지 변경, 물리) | oplog 엔트리(도큐먼트 변경, 논리) |
| 기록 보존 | `max_wal_size`, replication slot이 붙잡음 | oplog 크기(capped). 과반이 받지 못한 부분만 보호 |
| 뒤처진 복제본 | slot이 있으면 WAL을 무한정 붙잡아 primary 디스크를 채움 | window 밖으로 밀려나면 RECOVERING, initial sync 필요 |
| 적용 | startup 프로세스 하나가 순서대로 | writer thread 여러 개가 `_id` 해시로 병렬 |
| 복제본의 쓰기 | 불가 | 불가(primary만 쓰기) |

PostgreSQL은 standby를 위해 primary의 디스크를 희생할 수 있고(slot), MongoDB는 기본으로 primary를 지키고 뒤처진 secondary를 포기합니다. 어느 쪽이든 "복제본이 얼마나 오래 떨어져 있어도 되는가"를 정해 두는 것이 운영자의 일입니다.

## 정리

- **oplog**는 `local.oplog.rs` capped 컬렉션이고, WiredTiger 테이블의 key가 엔트리의 `ts`라 늘 시간 순서입니다. 기본 크기는 디스크 여유 공간의 5%(990MB~50GB)이며 oplog를 처음 만들 때 정해집니다.
- 도큐먼트 변경과 oplog 엔트리는 OpObserver를 거쳐 **같은 WiredTiger 트랜잭션, 같은 timestamp**로 커밋됩니다.
- oplog 엔트리는 **멱등**해야 하므로, `$inc`나 `$push`는 결과 값을 담은 `$v: 2` delta로 기록됩니다. `insertMany`와 `deleteMany`는 `applyOps` 하나로 묶이고, `updateMany`는 도큐먼트마다 한 줄입니다.
- secondary는 **OplogFetcher**로 받아 **OplogWriter**가 자기 oplog에 쓰고(lastWritten, lastDurable) **OplogApplier**가 `_id` 해시로 병렬 적용합니다(lastApplied). 8.0에서는 oplog가 디스크에 닿기만 하면 majority 쓰기를 확인해 줄 수 있습니다.
- 복제 지연은 heartbeat 기준 `optimeDate`로 보면 몇 초의 오차가 있습니다. `w: 3`처럼 멤버 수를 적은 쓰기는 멤버 하나만 멈춰도 `waiting for replication timed out`이 나지만, 쓰기 자체는 이미 끝나 있습니다.
- oplog는 마지막 체크포인트와 majority commit point 이전만 잘라 냅니다. window 밖으로 밀려난 secondary는 `Too stale to catch up`으로 RECOVERING이 되고, initial sync로 다시 만들어야 합니다.

다음 글에서는 primary가 사라졌을 때 남은 멤버들이 새 primary를 뽑는 **선출 과정**을 살펴봅니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/db/repl/oplog.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog.cpp): oplog 생성과 크기, `logOp`, oplog 엔트리 적용
- [src/mongo/db/op_observer/op_observer_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/op_observer/op_observer_impl.cpp): 쓰기마다 oplog 엔트리를 만드는 OpObserver
- [src/mongo/db/update/v2_log_builder.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/update/v2_log_builder.h), [document_diff_serialization.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/update/document_diff_serialization.h): `$v: 2` delta 형식
- [src/mongo/db/repl/oplog_fetcher.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp): OplogFetcher, too stale 판단
- [src/mongo/db/repl/oplog_writer_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_writer_impl.cpp): 8.0의 OplogWriter
- [src/mongo/db/repl/oplog_applier_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_impl.cpp), [oplog_applier_utils.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_applier_utils.cpp): 배치 적용과 writer thread 분배
- [src/mongo/db/repl/topology_coordinator.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp): sync source 선택, 위치 보고, majority commit point
- [src/mongo/db/repl/bgsync.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/bgsync.cpp): too stale일 때 RECOVERING으로 전환
- [src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp): oplog 테이블, truncate marker, oplog 잘라 내기

MongoDB 8.0 공식 문서

- [Replica Set Oplog](https://www.mongodb.com/docs/v8.0/core/replica-set-oplog/)
- [Replica Set Data Synchronization](https://www.mongodb.com/docs/v8.0/core/replica-set-sync/)
- [Resync a Member of a Self-Managed Replica Set](https://www.mongodb.com/docs/v8.0/tutorial/resync-replica-set-member/)
