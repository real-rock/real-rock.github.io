---
title: "MongoDB 인터널 3: WiredTiger의 MVCC와 스냅샷"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "WiredTiger", "MVCC", "history store", "WriteConflict", "SnapshotTooOld"]
weight: 3
summary: "동시에 읽고 쓸 때 WiredTiger는 어떤 버전을 보여 주고, 옛 버전은 어디에 두는가"
description: "update chain, 트랜잭션 스냅샷과 timestamp, WriteConflict, history store, minSnapshotHistoryWindowInSeconds, transactionLifetimeLimitSeconds"
---

## 개요

[1편](/posts/mongodb/01-wiredtiger-architecture/)에서 컬렉션은 WiredTiger의 B-tree 파일 하나이고, 페이지는 캐시에서 고쳐졌다가 eviction이나 [체크포인트](/posts/mongodb/02-checkpoint-and-journal/) 때 디스크에 쓰인다고 했습니다. 그렇다면 한 세션이 도큐먼트를 고치는 동안 다른 세션이 같은 도큐먼트를 읽으면 무엇을 볼까요? 트랜잭션 안에서 읽은 값은 트랜잭션이 끝날 때까지 그대로일까요?

WiredTiger도 PostgreSQL처럼 **MVCC**(Multi-Version Concurrency Control)로 이 문제를 풉니다. 도큐먼트를 고치면 제자리에서 덮어쓰지 않고 **새 버전을 하나 더** 만들고, 읽는 쪽은 자기 **스냅샷**에 보이는 버전을 고릅니다. 다만 버전을 두는 곳이 PostgreSQL과 다릅니다. [PostgreSQL](/posts/postgresql/04-mvcc/)은 옛 버전을 테이블 파일에 그대로 남기고 나중에 VACUUM으로 치우지만, WiredTiger는 옛 버전을 **메모리의 update chain**에 두고, 페이지를 디스크에 쓸 때 아직 필요한 옛 버전만 **history store**라는 별도 테이블로 옮깁니다. 데이터 파일에는 최신 버전만 들어갑니다.

이 글에서 답할 질문은 다음과 같습니다.

- 도큐먼트를 고치면 메모리에서는 무슨 일이 일어나는가
- 트랜잭션의 스냅샷은 무엇으로 이루어지고, "보인다"는 어떻게 판단하는가
- MongoDB는 WiredTiger에 어떤 timestamp를 넘기고, 그것은 가시성에 어떻게 쓰이는가
- 두 트랜잭션이 같은 도큐먼트를 고치면 왜 기다리지 않고 WriteConflict가 나는가
- 옛 버전은 언제 history store로 가고, 무엇이 그것을 붙잡아 두는가
- `minSnapshotHistoryWindowInSeconds`와 `transactionLifetimeLimitSeconds`는 무엇을 제한하는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 멀티 도큐먼트 트랜잭션과 timestamp를 쓰려고 컨테이너 1대에 단일 노드 레플리카셋(`rs0`)을 띄웠습니다.

## update chain: 새 버전은 체인 맨 앞에 붙는다

WiredTiger의 leaf page는 디스크에서 읽어 온 이미지(각 행의 key와 value)를 그대로 두고, 그 뒤에 일어난 변경을 행마다 **`WT_UPDATE` 구조체의 연결 리스트**로 붙여 둡니다([`WT_UPDATE`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/btmem.h#L1386)). 이것이 **update chain**입니다. 주요 필드는 다음과 같습니다.

| 필드 | 뜻 |
|---|---|
| `txnid` | 이 버전을 만든 WiredTiger 트랜잭션 ID. abort되면 `WT_TXN_ABORTED`로 바뀜 |
| `start_ts`, `durable_ts` | 이 버전의 commit timestamp와 durable timestamp([`btmem.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/btmem.h#L1396-L1397)) |
| `next` | 한 단계 옛 버전([`btmem.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/btmem.h#L1406)) |
| `type` | 전체 값(`STANDARD`), 일부만 바꾼 값(`MODIFY`), 삭제(`TOMBSTONE`) 등([`btmem.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/btmem.h#L1410-L1414)) |
| `data[]` | 값 자체. MongoDB에서는 BSON 도큐먼트 |

수정할 때 WiredTiger는 새 `WT_UPDATE`를 만들어 `txnid`에 자기 트랜잭션 ID를 적고([`__wt_txn_modify()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L511)), 체인의 **머리에** compare-and-swap으로 끼워 넣습니다([`__wt_update_serial()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/serial_inline.h#L269)). 그래서 체인은 항상 **새 버전이 앞**, 옛 버전이 뒤입니다. 끼워 넣기 직전에 쓰기 충돌 검사를 하는데, 이것은 [뒤에서](#쓰기-충돌-기다리지-않고-바로-실패한다) 봅니다. 읽는 쪽은 체인을 앞에서부터 따라가며 자기에게 보이는 첫 버전을 고르고, 체인에서 못 찾으면 디스크 이미지의 값을, 그것도 보이지 않으면 history store를 찾습니다.

PostgreSQL의 튜플처럼 버전마다 "만든 트랜잭션"이 적혀 있다는 점은 같지만, "지운 트랜잭션(xmax)"은 따로 없습니다. 다음 버전의 시작이 곧 앞 버전의 끝입니다. 페이지를 디스크에 쓸 때는 이 관계가 버전마다 **time window**(시작 timestamp와 끝 timestamp)로 기록되는데, 이것은 [history store 실습](#wt로-본-history-store-데이터-파일에는-최신-버전만-있다)에서 직접 봅니다.

{{< diagram src="/diagrams/mongo-update-chain.html" title="update chain과 history store" height="600" caption="한 도큐먼트를 두 번 고치면 메모리의 update chain에 버전이 셋 생깁니다(새 버전이 앞). 페이지를 디스크에 쓸 때 최신 버전은 데이터 파일로, 아직 누군가 볼 수 있는 옛 버전은 WiredTigerHS.wt로 갑니다. 그림의 값은 뒤의 wt 실습에서 본 것입니다." >}}

## 스냅샷: 트랜잭션 ID로 본 "이미 끝난 것"

WiredTiger 트랜잭션은 데이터를 처음 바꿀 때 64비트 트랜잭션 ID를 받습니다. 읽기를 시작할 때는 **스냅샷**을 만드는데, 스냅샷은 PostgreSQL의 `xmin:xmax:xip`와 거의 같은 구조입니다([`WT_TXN_SNAPSHOT`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn.h#L267-L277)).

| 필드 | 뜻 |
|---|---|
| `snap_max` | 스냅샷을 만들 때의 전역 "다음 트랜잭션 ID". 이 값 이상인 ID는 **보이지 않음** |
| `snap_min` | 동시에 실행 중이던 트랜잭션 중 가장 작은 ID. 이보다 작은 ID는 **보임** |
| `snapshot[]`, `snapshot_count` | 그 사이에서 스냅샷을 만들 때 **실행 중이던** 트랜잭션 ID 목록. 목록에 있으면 보이지 않음 |

스냅샷은 모든 세션의 공유 트랜잭션 상태 배열을 훑어서 만듭니다([`__txn_get_snapshot_int()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn.c#L202), 훑는 부분은 [`txn.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn.c#L259-L300)). 자기 ID는 목록에 넣지 않습니다. 자기가 만든 버전은 스냅샷과 상관없이 항상 보이기 때문입니다. 가장 작은 ID는 세션의 `pinned_id`로 공개되고, 모든 세션의 `pinned_id` 중 최솟값이 전역 `oldest_id`가 됩니다. 이 값보다 오래된 트랜잭션이 만든 버전은 "모두에게 보이는" 버전이라 더 옛 버전을 버려도 됩니다([`__txn_visible_all_id()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L682-L720)).

ID만 보고 판단하는 부분은 [`__wt_txn_visible_id_snapshot()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L894)입니다. `snap_max` 이상이면 안 보이고, `snap_min`보다 작으면 보이고, 그 사이면 목록을 이진 탐색합니다. 그 앞에서 [`__txn_visible_id()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L925)가 abort된 버전은 아무에게도 안 보이고([`txn_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L936-L937)), 내 버전은 항상 보인다는 것을 먼저 처리합니다. PostgreSQL처럼 커밋 여부를 따로 기록한 파일(pg_xact)을 찾아볼 필요가 없습니다. abort하면 체인에 있는 버전의 `txnid`가 곧바로 `WT_TXN_ABORTED`로 바뀌기 때문입니다.

## timestamp: MongoDB가 WiredTiger에 넘기는 시각

트랜잭션 ID만으로도 스냅샷 격리는 되지만, MongoDB는 여기에 **timestamp**를 하나 더 얹습니다. 레플리카셋에서는 모든 쓰기가 oplog 엔트리가 되고 엔트리마다 `Timestamp(초, 증가값)`이 붙는데, MongoDB는 그 값을 그대로 WiredTiger 트랜잭션의 **commit timestamp**로 넘깁니다([`WiredTigerRecoveryUnit::_txnClose()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_recovery_unit.cpp#L358)). WiredTiger는 이것을 버전의 `start_ts`에 적습니다([`__wt_txn_op_set_timestamp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L466)). 그래서 데이터의 각 버전이 **oplog의 어느 지점에서 생겼는지** 알 수 있고, "oplog의 이 지점까지 반영된 상태"를 읽을 수 있습니다. [5편](/posts/mongodb/05-oplog-and-replication/)의 복제와 [8편](/posts/mongodb/08-read-write-concern/)의 read concern이 이 위에 서 있습니다.

읽는 쪽은 **read timestamp**를 정할 수 있습니다. read timestamp가 있으면 트랜잭션 ID 검사를 통과한 버전이라도 `start_ts`가 read timestamp 이하여야 보입니다([`__wt_txn_timestamp_visible()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L959-L985)). 두 검사를 합친 것이 [`__wt_txn_visible()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L1016)입니다.

{{< diagram src="/diagrams/mongo-wt-visibility.html" title="읽기가 update chain에서 버전 하나를 고르는 과정" height="600" caption="체인의 버전을 새것부터 하나씩 트랜잭션 ID와 timestamp로 검사하고, 처음 보이는 버전을 읽습니다. 체인이 끝나면 디스크 이미지의 값, 그다음 history store를 찾습니다." >}}

MongoDB 트랜잭션이 read timestamp를 쓰는지는 read concern에 따라 다릅니다([`_setReadSnapshot()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/transaction/transaction_participant.cpp#L1294-L1326)).

| 트랜잭션의 readConcern | read timestamp |
|---|---|
| `snapshot` | 구멍 없는(all durable) 시점의 timestamp. 그 시점까지의 oplog로 재구성할 수 있는 상태를 읽음 |
| `atClusterTime` 지정 | 지정한 timestamp |
| `local`, `majority` (기본은 `local`) | 없음(`kNoTimestamp`). 트랜잭션 ID 스냅샷만으로 가장 최근 상태를 읽음 |

어느 경우든 트랜잭션의 첫 명령에서 스냅샷을 한 번 만들고 커밋이나 abort까지 그대로 씁니다. PostgreSQL로 치면 REPEATABLE READ에 가깝습니다.

#### 스냅샷 격리: 트랜잭션은 시작할 때의 스냅샷을 끝까지 본다

mongosh 세션 두 개를 열어 두고 번갈아 명령을 보냅니다. `A`, `B`는 세션 이름이고, 이름이 없는 프롬프트는 잠깐 따로 접속한 세션입니다. 컬렉션 `acct`에는 `{_id: 1, balance: 100}`과 `{_id: 2, balance: 100}`을 넣어 두었습니다.

```mongosh
A rs0 [direct: primary] test> sA = db.getMongo().startSession(); cA = sA.getDatabase("test").acct;
test.acct
B rs0 [direct: primary] test> sB = db.getMongo().startSession(); cB = sB.getDatabase("test").acct;
test.acct
A rs0 [direct: primary] test> sA.startTransaction({readConcern: {level: "snapshot"}})
A rs0 [direct: primary] test> cA.findOne({_id: 1})
{ _id: 1, balance: 100 }
B rs0 [direct: primary] test> sB.startTransaction()
B rs0 [direct: primary] test> cB.updateOne({_id: 1}, {$set: {balance: 200}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
B rs0 [direct: primary] test> sB.commitTransaction()
B rs0 [direct: primary] test> sB.getOperationTime()
Timestamp({ t: 1790513779, i: 1 })
A rs0 [direct: primary] test> cA.findOne({_id: 1})
{ _id: 1, balance: 100 }
```

A가 트랜잭션에서 `balance: 100`을 읽은 뒤, B가 200으로 바꾸고 커밋했습니다. 그런데 A가 같은 트랜잭션 안에서 다시 읽어도 여전히 100입니다. 다른 연결에서 보면 이렇습니다.

```mongosh
rs0 [direct: primary] test> db.acct.findOne({_id: 1})
{ _id: 1, balance: 200 }
rs0 [direct: primary] test> db.getSiblingDB("admin").aggregate([{$currentOp: {idleSessions: true}}, {$match: {"transaction.parameters.autocommit": false}}, {$project: {_id: 0, active: 1, readConcern: "$transaction.parameters.readConcern.level", readTimestamp: "$transaction.readTimestamp", startWallClockTime: "$transaction.startWallClockTime", expiryTime: "$transaction.expiryTime"}}])
[
  {
    active: false,
    readConcern: 'snapshot',
    readTimestamp: Timestamp({ t: 1790513767, i: 2 }),
    startWallClockTime: '2026-09-27T12:56:15.681+00:00',
    expiryTime: '2026-09-27T12:57:15.681+00:00'
  }
]
```

- 트랜잭션 밖에서 읽으면 새 값 200이 보입니다.
- `$currentOp`에 `idleSessions: true`를 주면 명령을 실행하고 있지 않은(`active: false`) 트랜잭션도 보입니다. A의 트랜잭션은 `readTimestamp`가 `Timestamp(1790513767, 2)`이고, B의 커밋은 `Timestamp(1790513779, 1)`입니다. B의 버전은 `start_ts`가 A의 read timestamp보다 크므로 timestamp 검사에서 걸립니다. A가 트랜잭션을 시작할 때 B가 아직 트랜잭션 ID를 받지 않았으니 ID로 보아도 `snap_max` 이상이라 보이지 않습니다.
- read timestamp는 벽시계 시각이 아니라 그 순간까지 커밋된 마지막 쓰기의 timestamp입니다. A가 트랜잭션을 시작한 것은 12:56:15인데 read timestamp의 초 값(1790513767)은 그보다 8초 앞입니다. 그동안 이 서버에는 쓰기가 없었기 때문입니다.
- `expiryTime`은 시작 시각에 정확히 60초를 더한 값입니다. [뒤에서](#transactionlifetimelimitseconds-60초가-지나면-서버가-abort한다) 볼 `transactionLifetimeLimitSeconds`의 기본값입니다.

## 쓰기 충돌: 기다리지 않고 바로 실패한다

PostgreSQL에서는 다른 트랜잭션이 고치고 있는 행을 고치려 하면 그 트랜잭션이 끝날 때까지 **기다립니다**([PG 4편](/posts/postgresql/04-mvcc/#같은-행을-동시에-고치면)). WiredTiger에는 행 잠금이 없습니다. 대신 체인 머리에 새 버전을 끼워 넣기 직전에 [`__txn_modify_block()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L1658)이 체인의 버전을 앞에서부터 보며, **abort되지 않았는데 내 스냅샷에서 보이지 않는 버전**이 하나라도 있으면 곧바로 실패를 돌려줍니다([`txn_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L1678-L1686), [`txn_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L1739-L1740)). 이유 문자열은 `conflict between concurrent operations`이고([`txn.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn.h#L25)), 반환 코드는 `WT_ROLLBACK`입니다. 보이지 않는 버전은 두 가지입니다.

- 아직 커밋하지 않은 다른 트랜잭션의 버전
- 커밋은 되었지만 내 스냅샷을 만든 뒤에 커밋된 버전

어느 쪽이든 그 위에 덮어쓰면 상대의 변경을 잃거나 내가 보지 못한 값을 덮게 됩니다. 이 규칙을 **first-updater-wins**라고 부르기도 합니다. MongoDB는 `WT_ROLLBACK`을 `WriteConflict` 예외로 바꿉니다([`wiredtiger_util.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp#L215-L242), [`throwWriteConflictException()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/concurrency/exception_util.h#L111-L116)). 그다음 처리는 트랜잭션 안인지 밖인지에 따라 갈립니다.

#### 스냅샷이 붙잡은 옛 버전 위에 쓰면 WriteConflict

앞의 실습에서 A의 트랜잭션은 아직 열려 있습니다. A의 스냅샷에서는 `_id: 1`이 100이지만, 체인 머리에는 B가 커밋한 200이 있습니다. A가 이 도큐먼트를 고쳐 봅니다.

```mongosh
A rs0 [direct: primary] test> try { cA.updateOne({_id: 1}, {$inc: {balance: 1}}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels, errmsg: e.errmsg}) }
{
  codeName: 'WriteConflict',
  errorLabels: [
    'TransientTransactionError'
  ],
  errmsg: 'Caused by :: Write conflict during plan execution and yielding is disabled. :: Please retry your operation or multi-document transaction.'
}
A rs0 [direct: primary] test> sA.commitTransaction()
MongoServerError[NoSuchTransaction]: Transaction with { txnNumber: 1 } has been aborted.
```

- 오류 코드는 `WriteConflict`(112), 레이블은 `TransientTransactionError`입니다. `WriteConflict`는 이 레이블을 받는 오류 코드 목록에 들어 있습니다([`isTransientTransactionError()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/error_labels.cpp#L269-L286)). "트랜잭션을 처음부터 다시 하면 성공할 수 있다"는 뜻입니다.
- 메시지의 `yielding is disabled`는 트랜잭션 안에서는 서버가 스냅샷을 놓고 다시 시도할 수 없다는 뜻입니다. 쿼리 실행기는 yield할 수 없는 실행에서 충돌이 나면 복구하지 않고 이 문구로 던집니다(일반 경로의 [`_handleNeedYield()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_executor_impl.cpp#L525-L529), `_id` 조회 같은 express 경로의 [`DoNotRecoverPolicy`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_executor_express.cpp#L72-L78)). 스냅샷을 새로 만들면 트랜잭션이 앞에서 읽은 것과 일관성이 깨지기 때문입니다.
- 오류가 난 트랜잭션은 서버에서 이미 abort되었습니다. 커밋하려 하면 `has been aborted`가 돌아옵니다.

#### 두 트랜잭션이 같은 도큐먼트를 고치면 뒤에 쓴 쪽이 바로 실패한다

이번에는 A가 `_id: 2`를 고치고 커밋하지 않은 상태에서 B가 같은 도큐먼트를 고칩니다. WiredTiger의 충돌 횟수(`update conflicts`)도 앞뒤로 봅니다.

```mongosh
rs0 [direct: primary] test> db.serverStatus().wiredTiger.transaction["update conflicts"]
1
A rs0 [direct: primary] test> sA.startTransaction(); cA.updateOne({_id: 2}, {$inc: {balance: 10}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
B rs0 [direct: primary] test> sB.startTransaction(); try { cB.updateOne({_id: 2}, {$inc: {balance: 1}}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels}) }
{
  codeName: 'WriteConflict',
  errorLabels: [
    'TransientTransactionError'
  ]
}
B rs0 [direct: primary] test> sB.abortTransaction()
A rs0 [direct: primary] test> sA.commitTransaction()
rs0 [direct: primary] test> db.acct.findOne({_id: 2})
{ _id: 2, balance: 110 }
rs0 [direct: primary] test> db.serverStatus().wiredTiger.transaction["update conflicts"]
2
```

- B의 update는 A를 기다리지 않고 **즉시** `WriteConflict`로 끝났습니다. 체인 머리에 있는 A의 버전이 아직 커밋되지 않아 B에게 보이지 않기 때문입니다. PostgreSQL이라면 B가 A의 커밋이나 롤백을 기다렸을 상황입니다.
- A는 문제없이 커밋했고 결과는 110입니다. B의 +1은 반영되지 않았으므로, 애플리케이션이 B의 트랜잭션을 처음부터 다시 해야 합니다.
- `update conflicts`가 1에서 2로 늘었습니다. 처음의 1은 바로 앞 실습에서 A가 받은 충돌입니다. 이 지표는 WiredTiger가 충돌을 돌려줄 때마다 늘어납니다.

#### 트랜잭션 밖의 쓰기는 서버 안에서 재시도하며 기다린다

트랜잭션 밖의 단일 쓰기는 사정이 다릅니다. 이런 쓰기는 도큐먼트 하나를 고치는 WiredTiger 트랜잭션 하나라서, 충돌이 나면 서버가 스냅샷을 버리고 **처음부터 다시 시도**해도 잃을 것이 없습니다. 서버는 이 재시도를 횟수 제한 없이 하고, 횟수에 따라 쉬는 시간을 늘립니다. 처음 4번은 바로, 10번째까지는 1ms, 100번째까지는 5ms, 200번째까지는 10ms, 그 뒤로는 100ms씩 쉽니다([`logAndBackoffImpl()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/util/log_and_backoff.cpp#L40-L52), express 경로의 호출은 [`plan_executor_express.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_executor_express.cpp#L434), 일반적인 재시도 루프는 [`writeConflictRetry()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/concurrency/exception_util.h#L152)).

A가 트랜잭션에서 `_id: 1`을 고쳐 두고, B가 트랜잭션 없이 같은 도큐먼트를 고칩니다.

```mongosh
rs0 [direct: primary] test> db.serverStatus().metrics.operation.writeConflicts
Long('2')
A rs0 [direct: primary] test> sA.startTransaction(); cA.updateOne({_id: 1}, {$inc: {balance: 1000}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
B rs0 [direct: primary] test> db.acct.updateOne({_id: 1}, {$inc: {balance: 1}})
```

B의 명령이 돌아오지 않습니다. 3초 뒤 다른 연결에서 봅니다.

```mongosh
rs0 [direct: primary] test> db.getSiblingDB("admin").aggregate([{$currentOp: {}}, {$match: {ns: "test.acct", op: "update"}}, {$project: {_id: 0, op: 1, secs_running: 1, writeConflicts: 1, numYields: 1, waitingForLock: 1}}])
[
  {
    secs_running: Long('2'),
    op: 'update',
    writeConflicts: Long('208'),
    numYields: 207,
    waitingForLock: false
  }
]
rs0 [direct: primary] test> db.serverStatus().metrics.operation.writeConflicts
Long('2')
```

A가 커밋하자 B의 update가 끝났습니다.

```mongosh
A rs0 [direct: primary] test> sA.commitTransaction()
B rs0 [direct: primary] test> db.acct.updateOne({_id: 1}, {$inc: {balance: 1}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
rs0 [direct: primary] test> db.acct.findOne({_id: 1})
{ _id: 1, balance: 1201 }
rs0 [direct: primary] test> db.serverStatus().metrics.operation.writeConflicts
Long('213')
```

```console
$ jq -c 'select(.msg == "Slow query" and .attr.ns == "test.acct" and .attr.writeConflicts) | {msg, type: .attr.type, planSummary: .attr.planSummary, writeConflicts: .attr.writeConflicts, numYields: .attr.numYields, durationMillis: .attr.durationMillis}' /data/mongod.log
{"msg":"Slow query","type":"update","planSummary":"EXPRESS_IXSCAN { _id: 1 },EXPRESS_UPDATE","writeConflicts":211,"numYields":211,"durationMillis":3012}
```

- 겉으로는 B가 A를 기다린 것처럼 보이지만, `waitingForLock: false`입니다. 잠금을 기다린 것이 아니라 2초 동안 **208번 충돌하고 다시 시도**하고 있었습니다(`writeConflicts: 208`). 매번 yield하고 스냅샷을 새로 잡았으므로 `numYields`도 거의 같이 늘었습니다.
- A가 커밋한 뒤의 시도에서는 A의 버전이 보이므로 그 위에 +1을 했습니다. 결과는 1201입니다(200 + 1000 + 1). 트랜잭션끼리와 달리 B의 변경이 사라지지 않았습니다.
- `serverStatus`의 `metrics.operation.writeConflicts`는 B가 재시도하는 동안에는 2 그대로였다가, 끝난 뒤 213이 되었습니다. 이 카운터는 연산이 **끝날 때** 그 연산의 충돌 횟수를 더합니다([`curop_metrics.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/curop_metrics.cpp#L147)). 진행 중인 충돌은 `$currentOp`으로 봐야 합니다.
- slow query 로그에도 `writeConflicts: 211`이 남았습니다. `$currentOp`을 본 뒤 A가 커밋하기까지 몇 번 더 충돌했습니다.

#### 운영에서는: 느린 단일 쓰기의 원인이 트랜잭션일 수 있다

트랜잭션 밖의 단순한 `updateOne`이 수 초씩 걸리고 slow query 로그에 `writeConflicts`가 수백으로 찍힌다면, 같은 도큐먼트를 잡고 있는 **열린 트랜잭션**이나 같은 도큐먼트(카운터, 상태 도큐먼트 등)에 몰리는 쓰기를 의심합니다. `$currentOp`에서 `writeConflicts`가 빠르게 늘고 `waitingForLock`은 `false`인 연산이 이 경우입니다. 반대로 트랜잭션을 쓰는 애플리케이션은 `TransientTransactionError` 레이블이 붙은 오류를 받으면 트랜잭션 전체를 다시 실행해야 합니다. 드라이버의 `withTransaction()`(callback API)은 이 재시도를 대신 해 줍니다.

## history store: 옛 버전은 페이지를 쓸 때 옮겨진다

update chain은 메모리에만 있습니다. 페이지를 디스크에 쓰는 일(**reconciliation**)은 eviction과 체크포인트 때 일어나는데([1편](/posts/mongodb/01-wiredtiger-architecture/), [2편](/posts/mongodb/02-checkpoint-and-journal/)), 이때 WiredTiger는 행마다 디스크 이미지에 쓸 버전 하나를 고르고([`__rec_upd_select()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_visibility.c#L585)), 그보다 옛 버전을 남길지 판단합니다([`__rec_need_save_upd()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_visibility.c#L293)). 고른 버전이 이미 **모두에게 보이는**(globally visible) 버전이면 그 뒤의 옛 버전은 아무도 볼 일이 없으니 버립니다([`rec_visibility.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_visibility.c#L321-L327)). 아직 누군가 옛 버전을 볼 수 있으면 그 버전들을 **history store**에 넣습니다([`__rec_hs_wrapup()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_write.c#L2696), [`__wt_hs_insert_updates()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/history/hs_rec.c#L342)).

history store는 dbPath의 `WiredTigerHS.wt` 파일 하나에 담긴 WiredTiger 테이블입니다([`meta.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/meta.h#L36)). 모든 컬렉션과 인덱스의 옛 버전이 이 테이블 하나에 모입니다. 읽는 쪽이 체인과 디스크 이미지에서 보이는 버전을 찾지 못하면 여기를 찾습니다([`txn_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L1386-L1390)).

"모두에게 보인다"는 두 조건을 모두 만족하는 것입니다([`__wt_txn_visible_all()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h#L750-L777)).

- 버전을 만든 트랜잭션 ID가 전역 `oldest_id`보다 작다. 즉 그 버전을 못 보는 스냅샷이 남아 있지 않다.
- 버전의 timestamp가 **pinned timestamp** 이하다. pinned timestamp는 **oldest timestamp**와, 실행 중인 트랜잭션들의 read timestamp 중 가장 작은 값입니다([`__wti_txn_get_pinned_timestamp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_timestamp.c#L85-L125)).

**oldest timestamp**는 MongoDB가 WiredTiger에 "이보다 옛 시점으로는 읽지 않겠다"고 알려 주는 값입니다. 레플리카셋에서 MongoDB는 **stable timestamp**(majority로 커밋된 지점, 체크포인트의 기준)가 움직일 때마다([`setStableTimestamp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2281), [`wiredtiger_kv_engine.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2332)) oldest timestamp를 **stable보다 `minSnapshotHistoryWindowInSeconds`초 뒤**로 맞춥니다([`setOldestTimestampFromStable()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2335), 계산은 [`_calculateHistoryLagFromStableTimestamp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2408-L2427)). 이 파라미터의 기본값은 300초입니다([`snapshot_window_options.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/snapshot_window_options.idl#L36-L42)). stable timestamp가 무엇이고 어떻게 움직이는지는 [5편](/posts/mongodb/05-oplog-and-replication/)과 [8편](/posts/mongodb/08-read-write-concern/)에서 다룹니다.

정리하면 history store에 옛 버전을 붙잡아 두는 것은 둘입니다.

| 붙잡는 것 | 효과 |
|---|---|
| `minSnapshotHistoryWindowInSeconds`(기본 300초) | 최근 300초 안에 생긴 옛 버전은 **트랜잭션이 없어도** 남김. `atClusterTime`으로 과거를 읽을 수 있게 하려는 것 |
| 오래 열린 스냅샷(트랜잭션, snapshot 읽기) | 그 스냅샷의 트랜잭션 ID와 read timestamp가 `oldest_id`와 pinned timestamp를 붙잡아, 그 뒤의 옛 버전을 모두 남김 |

#### 기본 300초 창에서는 트랜잭션이 없어도 옛 버전이 쌓인다

200바이트짜리 도큐먼트 10만 개를 넣고, history store 지표를 보는 함수 `hs()`를 만듭니다. `onDiskBytes`는 history store 파일 크기, `insertCalls`는 history store에 버전을 넣은 누적 횟수입니다. `idsPinned`와 `tsPinnedByReader`는 [뒤에서](#창을-0으로-줄이면-쌓이지-않고-스냅샷을-열어-두면-다시-쌓인다) 봅니다. `fsync`는 체크포인트를 바로 하게 해서 reconciliation을 일으키려고 불렀습니다.

```mongosh
rs0 [direct: primary] test> db.adminCommand({getParameter: 1, minSnapshotHistoryWindowInSeconds: 1})
{
  minSnapshotHistoryWindowInSeconds: 300,
  ok: 1,
...
}
rs0 [direct: primary] test> db.bulk.insertMany(Array.from({length: 100000}, (_, i) => ({_id: i, balance: 100, pad: "x".repeat(200)}))).acknowledged
true
rs0 [direct: primary] test> db.bulk.countDocuments()
100000
rs0 [direct: primary] test> hs = () => { const w = db.serverStatus().wiredTiger; return {onDiskBytes: w.cache["history store table on-disk size"], insertCalls: w.cache["history store table insert calls"], idsPinned: w.transaction["transaction range of IDs currently pinned"], tsPinnedByReader: w.transaction["transaction range of timestamps pinned by the oldest active read timestamp"]} }
[Function: hs]
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 24576,
  insertCalls: 209,
  idsPinned: 0,
  tsPinnedByReader: 0
}
rs0 [direct: primary] test> db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
100000
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 3420160,
  insertCalls: 100209,
  idsPinned: 0,
  tsPinnedByReader: 0
}
```

```console
$ ls -l /data/db/WiredTigerHS.wt
-rw------- 1 mongod mongod 3420160 Sep 27 12:56 /data/db/WiredTigerHS.wt
```

- 열려 있는 트랜잭션은 없는데도, 10만 개를 한 번씩 고치고 체크포인트하자 `insertCalls`가 정확히 100000 늘었습니다. 도큐먼트마다 고치기 전 버전(`balance: 100`)이 history store로 갔습니다.
- history store 파일은 24576바이트에서 3420160바이트(약 3.3MB)가 되었습니다. `onDiskBytes`와 `ls`의 크기가 같습니다.
- 이 옛 버전들은 방금 생겼으므로 oldest timestamp(stable보다 300초 전)보다 새롭습니다. 그래서 "모두에게 보이는" 버전이 아니고, 체크포인트가 디스크 이미지에 새 버전을 쓰면서 옛 버전을 history store로 옮겼습니다.

#### 창을 0으로 줄이면 쌓이지 않고, 스냅샷을 열어 두면 다시 쌓인다

`minSnapshotHistoryWindowInSeconds`를 0으로 줄여 oldest timestamp가 stable timestamp를 바로 따라가게 한 뒤 같은 update를 합니다.

```mongosh
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 0}).was
300
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 3420160,
  insertCalls: 100209,
  idsPinned: 1,
  tsPinnedByReader: 0
}
rs0 [direct: primary] test> db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
100000
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 3420160,
  insertCalls: 119691,
  idsPinned: 0,
  tsPinnedByReader: 0
}
```

이번에는 파일 크기가 3420160바이트 그대로이고, `insertCalls`도 19482만 늘어 도큐먼트 수의 5분의 1 정도입니다. 이제 세션 A가 snapshot 트랜잭션을 열어 `_id: 7`을 읽어 두고, 다른 연결에서 같은 update를 합니다.

```mongosh
A rs0 [direct: primary] test> sA.startTransaction({readConcern: {level: "snapshot"}}); sA.getDatabase("test").bulk.findOne({_id: 7})
{
  _id: 7,
  balance: 102,
  pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
}
rs0 [direct: primary] test> db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
100000
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 6504448,
  insertCalls: 300214,
  idsPinned: 100006,
  tsPinnedByReader: Long('17179869184')
}
rs0 [direct: primary] test> db.bulk.findOne({_id: 7})
{
  _id: 7,
  balance: 103,
...
}
A rs0 [direct: primary] test> sA.getDatabase("test").bulk.findOne({_id: 7})
{
  _id: 7,
  balance: 102,
...
}
```

```console
$ ls -l /data/db/WiredTigerHS.wt
-rw------- 1 mongod mongod 6504448 Sep 27 12:56 /data/db/WiredTigerHS.wt
```

- 창이 0인데도 A의 스냅샷 하나 때문에 `insertCalls`가 180523 늘고 파일이 6504448바이트(약 6.2MB)로 커졌습니다. A가 볼 수 있는 `balance: 102` 버전을 버릴 수 없어서, 10만 개의 옛 버전이 다시 history store로 갔습니다. 늘어난 횟수가 도큐먼트 수보다 많은데, 이 지표는 옮긴 버전 수가 아니라 history store 테이블에 insert를 부른 횟수라서 둘이 꼭 같지는 않습니다. 이 실습에서는 그 내역까지 나눠 보지 않았습니다.
- `idsPinned`(`transaction range of IDs currently pinned`)는 전역 "다음 트랜잭션 ID"와 `oldest_id`의 차이입니다([`__wt_txn_stats_update()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn.c#L2513-L2514)). `updateMany`는 도큐먼트마다 WiredTiger 트랜잭션을 따로 쓰므로 트랜잭션 ID가 10만 개 넘게 지나갔는데, A의 스냅샷이 `oldest_id`를 붙잡아 차이가 100006이 되었습니다.
- `tsPinnedByReader`는 durable timestamp와 가장 오래된 read timestamp의 차이입니다([`txn.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn.c#L2527-L2535)). timestamp는 위 32비트가 초, 아래 32비트가 증가값이라, 17179869184 = 4 × 2³²는 "4초"입니다. A의 read timestamp가 최신 쓰기보다 4초 뒤에 머물러 있습니다.
- 트랜잭션 밖에서는 103, A에서는 여전히 102가 보입니다.

A가 트랜잭션을 끝낸 뒤 같은 update를 한 번 더 합니다.

```mongosh
A rs0 [direct: primary] test> sA.abortTransaction()
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 6504448,
  insertCalls: 300214,
  idsPinned: 0,
  tsPinnedByReader: 0
}
rs0 [direct: primary] test> db.bulk.updateMany({}, {$inc: {balance: 1}}).modifiedCount
100000
rs0 [direct: primary] test> sleep(2000)
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> hs()
{
  onDiskBytes: 6504448,
  insertCalls: 300214,
  idsPinned: 0,
  tsPinnedByReader: 0
}
```

- 트랜잭션을 끝내자 두 pinned 지표가 곧바로 0이 되었고, 이번 update는 history store에 하나도 넣지 않았습니다(`insertCalls` 그대로).
- 파일 크기는 6504448바이트에서 줄지 않았습니다. history store에서 쓸모없어진 버전은 이후 reconciliation이 지우지만, 비워진 공간은 파일 안에서 다시 쓰일 뿐 파일이 곧바로 줄지는 않습니다.

세 번의 update를 나란히 놓으면 이렇습니다.

| 조건 | `insertCalls` 증가 | 파일 크기 |
|---|---|---|
| 창 300초, 트랜잭션 없음 | 100000 | 24576 → 3420160 |
| 창 0초, 트랜잭션 없음 | 19482 | 3420160 그대로 |
| 창 0초, snapshot 트랜잭션 열림 | 180523 | 3420160 → 6504448 |
| 창 0초, 트랜잭션 끝낸 뒤 | 0 | 6504448 그대로 |

#### wt로 본 history store: 데이터 파일에는 최신 버전만 있다

작은 컬렉션 `ver`에 도큐먼트 하나를 넣고 두 번 고쳐, 각 쓰기의 timestamp(`operationTime`)를 기록해 둡니다. 창은 다시 300초로 돌렸습니다.

```mongosh
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 300}).was
0
rs0 [direct: primary] test> db.runCommand({insert: "ver", documents: [{_id: 1, v: "v1-first"}]}).operationTime
Timestamp({ t: 1790513815, i: 2 })
rs0 [direct: primary] test> db.runCommand({update: "ver", updates: [{q: {_id: 1}, u: {$set: {v: "v2-second"}}}]}).operationTime
Timestamp({ t: 1790513815, i: 3 })
rs0 [direct: primary] test> db.runCommand({update: "ver", updates: [{q: {_id: 1}, u: {$set: {v: "v3-third"}}}]}).operationTime
Timestamp({ t: 1790513815, i: 4 })
rs0 [direct: primary] test> db.adminCommand({fsync: 1}).ok
1
rs0 [direct: primary] test> db.ver.stats().wiredTiger.uri
statistics:table:collection-42-10313453530085067927
```

mongod를 정상 종료하고 `wt` 유틸리티로 컬렉션 파일과 history store 파일을 그대로 읽습니다. `dump -p`는 key와 value를 테이블 형식(`key_format`, `value_format`)대로 풀어서 보여 줍니다.

```console
$ URI=$(mongosh --quiet --eval 'db.ver.stats().wiredTiger.uri.replace("statistics:table:", "")')
$ mongod --dbpath /data/db --shutdown | grep -v '^{'
$ ID=$(wt -h /data/db list -v file:$URI.wt | tr ',' '\n' | grep '^id=' | cut -d= -f2)
$ echo "file:$URI.wt id=$ID"
$ wt -h /data/db list -v file:WiredTigerHS.wt | tr ',' '\n' | grep -E '^(key|value)_format='
$ wt -h /data/db dump -p file:$URI.wt | sed -n '/^Data/,$p'
$ wt -h /data/db dump -p file:WiredTigerHS.wt | sed -n '/^Data/,$p' | grep -A1 "^$ID,"
$ for ts in $(wt -h /data/db dump -p file:WiredTigerHS.wt | grep "^$ID," | cut -d, -f3); do echo "$ts = Timestamp($((ts >> 32)), $((ts & 0xffffffff)))"; done
Killing process with pid: 32
file:collection-42-10313453530085067927.wt id=46
key_format=IuQQ
value_format=QQQu
Data
1
\1e\00\00\00\10_id\00\01\00\00\00\02v\00\09\00\00\00v3-third\00\00
46,\81,7690198278461194242,0
7690198278461194243,7690198278461194242,3,\1e\00\00\00\10_id\00\01\00\00\00\02v\00\09\00\00\00v1-first\00\00
46,\81,7690198278461194243,0
7690198278461194244,7690198278461194243,3,\1f\00\00\00\10_id\00\01\00\00\00\02v\00\0a\00\00\00v2-second\00\00
7690198278461194242 = Timestamp(1790513815, 2)
7690198278461194243 = Timestamp(1790513815, 3)
```

- 컬렉션 파일(`collection-42-...wt`)에는 key `1`(RecordId)에 BSON 도큐먼트 하나, `v3-third`만 있습니다. **데이터 파일에는 최신 버전만** 들어갑니다.
- history store의 key 형식은 `IuQQ`입니다. 순서대로 원래 테이블의 btree ID(메타데이터의 `id=46`), 원래 key(RecordId 1을 WiredTiger 방식으로 패킹한 `\81`), 이 버전의 시작 timestamp, 같은 timestamp 안의 순번입니다. value 형식 `QQQu`는 끝 timestamp, durable timestamp, 버전 종류(`3` = `WT_UPDATE_STANDARD`, 전체 값), 값 자체입니다.
- 행이 둘이고 각각 `v1-first`, `v2-second`입니다. 시작 timestamp를 풀면 `Timestamp(1790513815, 2)`, `Timestamp(1790513815, 3)`으로, 앞에서 기록한 insert와 첫 update의 `operationTime`과 같습니다. `v1-first`의 끝 timestamp(...243)는 `v2-second`의 시작과 같고, `v2-second`의 끝(...244)은 `v3-third`를 쓴 `Timestamp(1790513815, 4)`입니다. 앞에서 말한 time window가 이것입니다. 버전마다 "언제부터 언제까지 유효했는가"를 적어 두어, 과거의 어느 read timestamp로 읽든 맞는 버전 하나를 고를 수 있습니다.

## 과거 시점 읽기와 SnapshotTooOld

history store에 옛 버전이 있으니, read timestamp를 과거로 주면 과거 상태를 읽을 수 있습니다. readConcern `snapshot`에 `atClusterTime`을 주면 됩니다. 단 그 시점이 oldest timestamp보다 옛날이면 WiredTiger가 read timestamp 설정을 거부하고, MongoDB는 `SnapshotTooOld`를 돌려줍니다([`wiredtiger_recovery_unit.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_recovery_unit.cpp#L569-L574)).

#### atClusterTime으로 읽고, 창을 줄여 SnapshotTooOld 만들기

mongod를 다시 띄운 뒤, `_id: 1`을 0으로 바꾼 시점 `T`를 기록하고 다시 -1로 바꿉니다. 재시작했으므로 창은 기본값 300초입니다.

```mongosh
rs0 [direct: primary] test> T = db.runCommand({update: "acct", updates: [{q: {_id: 1}, u: {$set: {balance: 0}}}]}).operationTime
Timestamp({ t: 1790513819, i: 1 })
rs0 [direct: primary] test> db.acct.updateOne({_id: 1}, {$set: {balance: -1}}).modifiedCount
1
rs0 [direct: primary] test> db.runCommand({find: "acct", filter: {_id: 1}, readConcern: {level: "snapshot", atClusterTime: T}}).cursor.firstBatch
[ { _id: 1, balance: 0 } ]
rs0 [direct: primary] test> db.acct.findOne({_id: 1})
{ _id: 1, balance: -1 }
rs0 [direct: primary] test> db.serverStatus().wiredTiger["snapshot-window-settings"]
{
  'total number of SnapshotTooOld errors': Long('0'),
  'minimum target snapshot window size in seconds': 300,
  'current available snapshot window size in seconds': 7,
  'latest majority snapshot timestamp available': 'Sep 27 12:56:59:2',
  'oldest majority snapshot timestamp available': 'Sep 27 12:56:52:4404',
  'pinned timestamp requests': 0,
  'min pinned timestamp': Timestamp({ t: 4294967295, i: 4294967295 })
}
```

- `atClusterTime: T`로 읽으면 이미 덮어쓴 값 0이 보입니다. 최신 값은 -1입니다.
- `snapshot-window-settings`에서 `oldest majority snapshot timestamp available`이 oldest timestamp, `latest ...`가 stable timestamp에 해당하는 값입니다. 목표 창은 300초지만 재시작한 지 얼마 되지 않아 지금 읽을 수 있는 창(`current available snapshot window size`)은 7초뿐입니다. oldest timestamp는 앞으로만 움직이므로, 재시작 전의 과거는 이미 읽을 수 없습니다.

창을 5초로 줄이고 12초 기다린 뒤, stable timestamp가 움직이도록 쓰기를 하나 하고 다시 `T`로 읽습니다.

```mongosh
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 5}).was
300
rs0 [direct: primary] test> sleep(12000)
rs0 [direct: primary] test> db.acct.updateOne({_id: 2}, {$inc: {balance: 1}}).modifiedCount
1
rs0 [direct: primary] test> sleep(1000)
rs0 [direct: primary] test> db.serverStatus().wiredTiger["snapshot-window-settings"]
{
  'total number of SnapshotTooOld errors': Long('0'),
  'minimum target snapshot window size in seconds': 5,
  'current available snapshot window size in seconds': 5,
  'latest majority snapshot timestamp available': 'Sep 27 12:57:11:1',
  'oldest majority snapshot timestamp available': 'Sep 27 12:57:06:1',
  'pinned timestamp requests': 0,
  'min pinned timestamp': Timestamp({ t: 4294967295, i: 4294967295 })
}
rs0 [direct: primary] test> db.runCommand({find: "acct", filter: {_id: 1}, readConcern: {level: "snapshot", atClusterTime: T}})
MongoServerError[SnapshotTooOld]: Read timestamp Timestamp(1790513819, 1) is older than the oldest available timestamp.
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, minSnapshotHistoryWindowInSeconds: 300}).was
5
```

- oldest timestamp가 stable보다 정확히 5초 뒤(12:57:06 ~ 12:57:11)로 올라갔고, `T`(12:56:59 무렵)는 그보다 옛날이 되었습니다.
- 같은 읽기가 `SnapshotTooOld`로 실패했습니다. 메시지대로 read timestamp가 "가장 오래된 읽을 수 있는 timestamp"보다 옛날입니다.
- 창을 줄인 뒤 곧바로가 아니라 쓰기를 한 뒤에 oldest가 움직인 것은, oldest timestamp를 stable timestamp가 바뀔 때 함께 계산하기 때문입니다. 한가한 레플리카셋에서도 primary는 주기적으로 no-op을 oplog에 쓰므로 결국 움직입니다.

창이 넓을수록 과거 읽기가 쉬워지지만, 그만큼 옛 버전을 history store에 더 오래 두어야 합니다. 기본 300초는 샤드 클러스터에서 여러 샤드가 같은 cluster time으로 읽는 경우 등을 위한 여유입니다.

## transactionLifetimeLimitSeconds: 60초가 지나면 서버가 abort한다

앞에서 본 것처럼 열린 트랜잭션 하나가 그 뒤의 옛 버전을 전부 붙잡습니다. 트랜잭션이 끝나지 않으면 history store와 캐시가 한없이 커질 수 있으므로, MongoDB는 트랜잭션에 수명을 둡니다. `transactionLifetimeLimitSeconds`의 기본값은 60초이고, 설명에 "스토리지 캐시 압박이 시스템을 멈추게 하는 것을 막으려고"라고 적혀 있습니다([`transaction_participant.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/transaction/transaction_participant.idl#L49-L60)). 수명을 넘긴 트랜잭션은 백그라운드 작업 `abortExpiredTransactions`가 찾아 abort합니다([`killAllExpiredTransactions()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/session/kill_sessions_local.cpp#L145-L178)). 이 작업은 수명의 절반마다(최소 1초, 최대 60초) 돕니다([`getPeriod()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/periodic_runner_job_abort_expired_transactions.cpp#L63-L71)). 그래서 실제로 abort되는 시점은 수명보다 최대 그 주기만큼 늦을 수 있습니다.

#### 수명을 5초로 줄여 트랜잭션이 abort되는 모습

```mongosh
rs0 [direct: primary] test> db.adminCommand({getParameter: 1, transactionLifetimeLimitSeconds: 1})
{
  transactionLifetimeLimitSeconds: 60,
  ok: 1,
...
}
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, transactionLifetimeLimitSeconds: 5}).was
60
C rs0 [direct: primary] test> sC = db.getMongo().startSession(); cC = sC.getDatabase("test").acct;
test.acct
C rs0 [direct: primary] test> sC.startTransaction(); cC.insertOne({_id: 3, balance: 1})
{ acknowledged: true, insertedId: 3 }
rs0 [direct: primary] test> db.serverStatus().transactions.currentOpen
Long('1')
C rs0 [direct: primary] test> sleep(8000)
C rs0 [direct: primary] test> cC.insertOne({_id: 4, balance: 1})
MongoServerError[NoSuchTransaction]: Transaction with { txnNumber: 1 } has been aborted.
C rs0 [direct: primary] test> try { cC.insertOne({_id: 5, balance: 1}) } catch (e) { printjson({codeName: e.codeName, errorLabels: e.errorLabels}) }
{
  codeName: 'NoSuchTransaction',
  errorLabels: [
    'TransientTransactionError'
  ]
}
C rs0 [direct: primary] test> sC.commitTransaction()
MongoServerError[NoSuchTransaction]: Transaction with { txnNumber: 1 } has been aborted.
rs0 [direct: primary] test> db.acct.find({_id: {$gte: 3}}).toArray()
[]
rs0 [direct: primary] test> db.serverStatus().metrics.abortExpiredTransactions
{
  passes: Long('8'),
  successfulKills: Long('1'),
  timedOutKills: Long('0')
}
rs0 [direct: primary] test> db.adminCommand({setParameter: 1, transactionLifetimeLimitSeconds: 60}).was
5
```

```console
$ jq -c 'select(.id == 20707) | {msg, txnNumber: .attr.txnNumberAndRetryCounter.txnNumber}' /data/mongod.log
{"msg":"Aborting transaction because it has been running for longer than 'transactionLifetimeLimitSeconds'","txnNumber":1}
```

- 세션 C가 트랜잭션에서 insert를 하고 8초 동안 아무것도 하지 않았습니다. 그 사이 서버가 트랜잭션을 abort했고, mongod 로그에 `Aborting transaction because it has been running for longer than 'transactionLifetimeLimitSeconds'`가 남았습니다.
- 세션 C는 abort된 줄 모르고 있다가 다음 명령에서 `NoSuchTransaction`(`has been aborted`)을 받습니다. 이 오류에도 `TransientTransactionError` 레이블이 붙습니다. 트랜잭션을 처음부터 다시 하라는 뜻입니다.
- 먼저 넣은 `_id: 3`도 abort와 함께 사라졌습니다. `abortExpiredTransactions.successfulKills`가 1입니다.
- 수명은 트랜잭션이 **명령을 실행하지 않고 쉬는 시간까지 포함한** 전체 시간입니다. 앞의 `$currentOp`에서 본 `expiryTime`이 시작 시각 + 60초였던 것도 이 때문입니다.

## PostgreSQL MVCC와 비교

| | PostgreSQL | WiredTiger(MongoDB) |
|---|---|---|
| 옛 버전을 두는 곳 | 테이블 파일(힙) 안, 새 버전 옆 | 메모리의 update chain. 페이지를 쓸 때 필요한 것만 `WiredTigerHS.wt` |
| 데이터 파일의 내용 | 살아 있는 버전과 dead tuple이 섞여 있음 | 최신 버전만 |
| 옛 버전 정리 | VACUUM이 나중에 따로 | 페이지를 쓸 때 버리거나 history store로 옮김. history store는 쓸모없어진 뒤 정리 |
| 커밋 여부 | pg_xact 조회, hint bit | abort 시 체인의 `txnid`를 `WT_TXN_ABORTED`로 바꿈 |
| 스냅샷 | `xmin:xmax:xip` | `snap_min`, `snap_max`, 동시 트랜잭션 목록 + read timestamp |
| 같은 행을 동시에 수정 | 앞 트랜잭션이 끝날 때까지 대기 | 즉시 `WriteConflict`. 트랜잭션 밖이면 서버가 재시도 |
| 긴 트랜잭션의 대가 | 테이블 bloat, VACUUM 지연 | 캐시 압박, history store 증가. 60초 제한으로 abort |

긴 트랜잭션이 옛 버전 정리를 막는다는 점은 같습니다. 다른 점은 그 비용이 PostgreSQL에서는 테이블 파일이 커지는 것(bloat)으로, WiredTiger에서는 **캐시와 history store**가 커지는 것으로 나타난다는 것입니다. 그리고 MongoDB는 트랜잭션에 기본 60초의 수명을 두어 이 비용에 상한을 둡니다.

## 운영에서는 이렇게 나타납니다

#### 긴 트랜잭션과 긴 snapshot 쿼리가 캐시를 압박한다

열린 스냅샷은 그 뒤에 고쳐진 모든 도큐먼트의 옛 버전을 붙잡습니다. 이 옛 버전은 먼저 캐시의 update chain에 쌓이고, 페이지를 내보낼 때는 history store로 옮겨야 하므로 eviction이 느려집니다. 쓰기가 많은 시스템에서 오래 열린 트랜잭션이나 `readConcern: "snapshot"`으로 오래 도는 집계가 있으면 캐시의 dirty 비율이 올라가고 애플리케이션 스레드가 eviction을 돕게 되어([1편](/posts/mongodb/01-wiredtiger-architecture/)) 전체 지연이 늘어납니다. 먼저 볼 지표는 다음과 같습니다.

- `serverStatus().wiredTiger.transaction`의 `transaction range of IDs currently pinned`, `transaction range of timestamps pinned by the oldest active read timestamp`: 값이 크게 벌어져 있으면 오래된 스냅샷이 있습니다.
- `serverStatus().wiredTiger.cache`의 `history store table on-disk size`, `history store table insert calls`, `bytes belonging to the history store table in the cache`
- `$currentOp`에 `idleSessions: true`를 주고 `transaction.timeOpenMicros`나 `startWallClockTime`이 오래된 트랜잭션을 찾습니다. `active: false`인데 오래 열린 트랜잭션은 애플리케이션이 트랜잭션을 연 채 다른 일을 하고 있을 가능성이 큽니다.

트랜잭션이 아니어도 `minSnapshotHistoryWindowInSeconds` 동안의 옛 버전은 남는다는 점도 기억해 둡니다. 전체 도큐먼트를 한 번에 고치는 배치 작업은 트랜잭션이 없어도 [실습에서 본 것처럼](#기본-300초-창에서는-트랜잭션이-없어도-옛-버전이-쌓인다) 고친 양만큼 history store를 키웁니다. 이 파라미터를 줄이면 캐시와 디스크 부담은 줄지만 `atClusterTime` 읽기와 샤드 간 snapshot 읽기가 `SnapshotTooOld`로 실패하기 쉬워집니다.

#### WriteConflict는 재시도로 대응한다

트랜잭션 안의 `WriteConflict`는 정상 동작의 일부입니다. 오류에 `TransientTransactionError` 레이블이 있으면 트랜잭션 전체를 다시 실행합니다. 드라이버의 `withTransaction()`을 쓰면 이 재시도와, 커밋 결과를 알 수 없을 때의 `UnknownTransactionCommitResult` 재시도를 대신 해 줍니다. 충돌이 잦다면 같은 도큐먼트에 쓰기가 몰리는 설계(전역 카운터 하나, 상태 도큐먼트 하나를 여러 요청이 고치는 구조)를 먼저 의심합니다. 트랜잭션 밖의 쓰기는 서버가 알아서 재시도하지만, [실습처럼](#트랜잭션-밖의-쓰기는-서버-안에서-재시도하며-기다린다) 그 시간이 그대로 지연이 되고 slow query 로그의 `writeConflicts`로만 드러납니다.

#### 60초 제한과 트랜잭션 크기

`has been aborted` 또는 `NoSuchTransaction`이 간헐적으로 나오면, 트랜잭션 안에서 외부 호출이나 사용자 입력을 기다리느라 60초를 넘긴 것이 아닌지 봅니다. mongod 로그의 `Aborting transaction because it has been running for longer than 'transactionLifetimeLimitSeconds'`와 `metrics.abortExpiredTransactions.successfulKills`로 확인할 수 있습니다. `transactionLifetimeLimitSeconds`를 늘리는 것은 대개 답이 아닙니다. 그만큼 옛 버전을 오래 붙잡게 되기 때문입니다. 트랜잭션은 짧게, 도큐먼트 수를 적게(공식 문서는 한 트랜잭션에서 1,000개 이하의 도큐먼트를 고치기를 권합니다) 유지하고, 큰 일괄 작업은 여러 트랜잭션으로 나눕니다. 트랜잭션이 고친 버전은 커밋 전까지 캐시에 머물러야 하므로, 캐시에 비해 너무 큰 트랜잭션은 `TransactionTooLargeForCache` 같은 오류로 끝나기도 합니다([`wiredtiger_util.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp#L215-L242)).

## 정리

- WiredTiger는 도큐먼트를 고칠 때마다 `WT_UPDATE`를 update chain 맨 앞에 붙입니다. 버전마다 만든 트랜잭션 ID와 commit timestamp가 적힙니다.
- 스냅샷은 `snap_min`, `snap_max`, 동시 트랜잭션 목록으로 이루어지고, MongoDB는 여기에 oplog 순서와 같은 **read timestamp**를 더합니다. 트랜잭션은 첫 명령에서 만든 스냅샷을 끝까지 씁니다.
- 내 스냅샷에서 보이지 않는 버전 위에 쓰려 하면 WiredTiger는 기다리지 않고 바로 실패하고, MongoDB는 이것을 `WriteConflict`로 바꿉니다. 트랜잭션 안이면 `TransientTransactionError`로 돌려주고, 트랜잭션 밖이면 서버가 뒤로 물러나며 재시도합니다.
- 페이지를 디스크에 쓸 때 데이터 파일에는 최신 버전만 쓰고, 아직 누군가 볼 수 있는 옛 버전은 `WiredTigerHS.wt`(history store)에 time window와 함께 넣습니다.
- 옛 버전을 붙잡는 것은 oldest timestamp(stable보다 `minSnapshotHistoryWindowInSeconds`, 기본 300초 뒤)와 오래 열린 스냅샷입니다. 창보다 옛 시점을 읽으면 `SnapshotTooOld`입니다.
- `transactionLifetimeLimitSeconds`(기본 60초)가 지난 트랜잭션은 서버가 abort합니다.

다음 글에서는 컬렉션 옆의 또 다른 WiredTiger 테이블인 **인덱스**의 구조와, 쿼리 플래너가 여러 인덱스 가운데 하나를 고르는 방식을 살펴봅니다.

## 참고 자료

소스 코드 (r8.0.32, 커밋 `8f1f561` 기준)

- [src/third_party/wiredtiger/src/include/btmem.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/btmem.h): `WT_UPDATE`
- [src/third_party/wiredtiger/src/include/txn.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn.h), [src/third_party/wiredtiger/src/txn/txn.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn.c): 트랜잭션, 스냅샷
- [src/third_party/wiredtiger/src/include/txn_inline.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/txn_inline.h): 가시성 판단, 쓰기 충돌 검사
- [src/third_party/wiredtiger/src/txn/txn_timestamp.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_timestamp.c): oldest, stable, pinned timestamp
- [src/third_party/wiredtiger/src/reconcile/rec_visibility.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_visibility.c), [src/third_party/wiredtiger/src/history/hs_rec.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/history/hs_rec.c): reconciliation, history store
- [src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp), [wiredtiger_recovery_unit.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_recovery_unit.cpp): MongoDB가 timestamp를 넘기는 곳
- [src/mongo/db/transaction/transaction_participant.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/transaction/transaction_participant.cpp): 트랜잭션의 read source
- [src/mongo/db/concurrency/exception_util.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/concurrency/exception_util.h): `WriteConflict`와 재시도

MongoDB 8.0 공식 문서

- [Transactions](https://www.mongodb.com/docs/v8.0/core/transactions/), [Production Considerations](https://www.mongodb.com/docs/v8.0/core/transactions-production-consideration/)
- [Read Concern "snapshot"](https://www.mongodb.com/docs/v8.0/reference/read-concern-snapshot/)
- [minSnapshotHistoryWindowInSeconds, transactionLifetimeLimitSeconds](https://www.mongodb.com/docs/v8.0/reference/parameters/)
