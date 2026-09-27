---
title: "MongoDB 인터널 8: Read/Write Concern이 실제로 보장하는 것"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "write concern", "read concern", "rollback", "waiting for replication timed out"]
weight: 8
summary: "쓰기 응답은 무엇을 기다린 뒤에 오고, 읽기는 어느 시점의 데이터를 보는가. 그리고 w:1로 인정받은 쓰기는 어떻게 사라지는가"
description: "write concern 대기와 majority commit point, 8.0의 기본 write concern, read concern별 읽기 시점, causal consistency, rollback과 rollback 파일"
---

## 개요

[5편](/posts/mongodb/05-oplog-and-replication/)에서 secondary는 primary의 oplog를 가져와 적용하며 따라가고, [6편](/posts/mongodb/06-election/)에서 primary가 사라지면 남은 멤버가 새 primary를 뽑는 것을 봤습니다. 복제는 비동기라서, 어느 순간이든 primary에만 있고 secondary에는 아직 없는 쓰기가 있습니다. 그 순간 primary가 바뀌면 그 쓰기는 어떻게 될까요? 그리고 클라이언트는 자기 쓰기가 그런 상태인지 아닌지를 어떻게 알 수 있을까요?

MongoDB는 이 질문을 **write concern**과 **read concern**으로 클라이언트에게 넘깁니다. write concern은 "쓰기 응답을 언제 돌려받을지", read concern은 "읽을 때 어느 시점까지 확정된 데이터를 볼지"를 요청마다 정하는 옵션입니다. 둘 다 서버가 데이터를 다르게 쓰거나 복제하게 만드는 옵션이 아닙니다. **무엇을 기다린 뒤에 응답하고, 어느 스냅샷에서 읽을지**만 바꿉니다. 이 글은 그 "기다림"과 "스냅샷"이 소스에서 무엇인지, 그리고 그 보장을 벗어난 쓰기가 실제로 사라지는 모습(rollback)을 차례로 봅니다.

이 글에서 답할 질문은 다음과 같습니다.

- `w`, `j`, `wtimeout`은 쓰기 응답 전에 각각 무엇을 기다리게 하는가
- "과반에 복제되었다"는 판단(majority commit point)은 어디서, 어떻게 전진하는가
- 8.0의 기본 write concern은 무엇이고, arbiter가 있으면 왜 달라지는가
- read concern `local`, `majority`, `snapshot`, `linearizable`은 각각 어느 시점의 데이터를 읽는가
- causal consistency 세션은 secondary 읽기에서 무엇을 보장하는가
- `w:1`로 인정받은 쓰기가 rollback되면 데이터는 어디로 가는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 컨테이너 3대(`m08-1`, `m08-2`, `m08-3`)로 레플리카셋 `rs0`을 만들었고, 마지막에 arbiter용 컨테이너 1대를 더했습니다.

## write concern: 쓰기 응답을 언제 보내는가

write concern은 세 가지 필드로 이루어집니다.

| 필드 | 뜻 |
|---|---|
| `w` | 몇 멤버에 반영된 뒤 응답할지. 숫자(`1`, `3`), `"majority"`, 또는 태그로 정의한 이름 |
| `j` | 저널([2편](/posts/mongodb/02-checkpoint-and-journal/))에 기록된 뒤를 기준으로 할지 |
| `wtimeout` | 기다리는 시간의 상한(ms). 0이면 끝없이 기다림 |

쓰기 명령은 먼저 로컬에서 끝까지 실행됩니다. 도큐먼트 변경과 oplog 엔트리는 WiredTiger 트랜잭션 하나로 커밋되고([5편](/posts/mongodb/05-oplog-and-replication/)), 그 oplog 엔트리의 위치가 이 쓰기의 **optime**(timestamp + term)입니다. 명령이 끝난 뒤, 응답을 보내기 직전에 [`waitForWriteConcern()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp#L299)이 불립니다(mongod에서의 호출은 [`service_entry_point_mongod.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/service_entry_point_mongod.cpp#L149)). 여기서 하는 일은 두 단계입니다.

1. **디스크 대기**: `j:true`이면 저널 flush를 기다립니다([`write_concern.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp#L360-L378)). 다른 멤버까지 기다리는 write concern이면 flush를 걸어만 두고 넘어갑니다. 복제 대기가 각 멤버의 durable optime(저널까지 기록한 위치)을 따로 추적하기 때문입니다.
2. **복제 대기**: `w:1`처럼 다른 멤버를 기다릴 필요가 없으면 여기서 바로 응답합니다([`write_concern.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp#L394-L397)). 그렇지 않으면 [`ReplicationCoordinatorImpl::awaitReplication()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2342)에 이 optime을 기다리는 waiter를 걸고 잠듭니다.

{{< diagram src="/diagrams/mongo-write-concern-majority.html" title="w:\"majority\" 쓰기 한 번이 기다리는 것" height="640" caption="로컬 커밋은 먼저 끝납니다. 응답은 secondary의 위치 보고로 과반이 그 optime에 닿았다고 판단한 뒤에 나갑니다. 대기 중에 wtimeout이 지나면 쓰기는 남겨 둔 채 writeConcernError만 붙여 응답합니다." >}}

secondary는 oplog를 가져가 쓰고 적용할 때마다 자기 위치(written, applied, durable optime)를 primary에 보고합니다(`replSetUpdatePosition`). 보고가 올 때마다 primary는 대기 중인 waiter를 확인하고, 조건을 만족한 waiter를 깨웁니다. 조건 판단은 [`_doneWaitingForReplication_inlock()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2270)이 합니다.

- **숫자 `w`**: 멤버를 하나씩 보며 그 optime에 닿은 멤버 수를 셉니다([`haveNumNodesReachedOpTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1260)). arbiter는 세지 않습니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1280-L1284)). `j:true`면 durable optime, 아니면 written optime을 비교합니다.
- **`"majority"`**: 멤버를 세지 않고, primary의 **committed snapshot**이 그 optime 이상이 되었는지를 봅니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2295-L2305)). committed snapshot이 무엇인지는 [다음 절](#majority-commit-point-과반이-가진-위치)에서 봅니다.

wtimeout이 먼저 지나면 대기가 `WriteConcernFailed`와 `waiting for replication timed out`으로 끝납니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2400-L2402)). 이 경로 어디에도 이미 커밋된 로컬 쓰기를 되돌리는 코드는 없습니다. **write concern은 응답 시점만 늦출 뿐, 쓰기 자체를 조건부로 만들지 않습니다.** 이 점은 뒤에서 실측으로 확인합니다.

`j`를 지정하지 않은 `"majority"`는 레플리카셋 설정의 `writeConcernMajorityJournalDefault`(기본 true)를 따라 저널 기준으로 판단합니다([`_populateUnsetWriteConcernOptionsSyncMode()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L6554-L6565)).

#### 실습용 3노드 레플리카셋

멤버 3개짜리 레플리카셋을 만듭니다. 실습에서 특정 멤버를 primary로 두기 위해 `m08-1`에 priority 2를 줬습니다. 그리고 `electionTimeoutMillis`를 기본 10초에서 30초로 늘렸습니다. 뒤에서 secondary 두 개를 15초쯤 멈추는데, 기본값이면 그 사이 primary가 과반을 볼 수 없다며 스스로 물러나기 때문입니다([6편](/posts/mongodb/06-election/)).

```mongosh
test> rs.initiate({_id: 'rs0', settings: {electionTimeoutMillis: 30000}, members: [{_id: 0, host: 'm08-1:27017', priority: 2}, {_id: 1, host: 'm08-2:27017'}, {_id: 2, host: 'm08-3:27017'}]})
{
  ok: 1,
...
}
rs0 [direct: primary] test> rs.status().members.map(m => m.name + ' ' + m.stateStr)
[
  'm08-1:27017 PRIMARY',
  'm08-2:27017 SECONDARY',
  'm08-3:27017 SECONDARY'
]
```

#### 기본 read/write concern

클라이언트가 아무것도 지정하지 않으면 어떤 값이 쓰이는지는 `getDefaultRWConcern`으로 봅니다.

```mongosh
rs0 [direct: primary] test> db.adminCommand({getDefaultRWConcern: 1})
{
  defaultReadConcern: { level: 'local' },
  defaultWriteConcern: { w: 'majority', wtimeout: 0 },
  defaultWriteConcernSource: 'implicit',
  defaultReadConcernSource: 'implicit',
...
}
rs0 [direct: primary] test> rs.conf().writeConcernMajorityJournalDefault
true
rs0 [direct: primary] test> rs.conf().settings.electionTimeoutMillis
30000
```

- 기본 write concern은 `{ w: 'majority', wtimeout: 0 }`, 기본 read concern은 `local`입니다. `Source: 'implicit'`는 누가 정한 값이 아니라 서버가 레플리카셋 구성을 보고 계산한 값이라는 뜻입니다. 이 계산은 [arbiter를 다룰 때](#기본-write-concern과-arbiter) 다시 봅니다.
- `wtimeout: 0`은 **끝없이 기다린다**는 뜻입니다. 과반이 응답하지 않으면 기본 설정의 쓰기는 응답하지 않습니다. 이것도 뒤에서 확인합니다.

#### write concern을 붙인 쓰기의 응답

```mongosh
rs0 [direct: primary] test> db.t.insertOne({_id: 'majority-1', v: 1}, {writeConcern: {w: 'majority'}})
{ acknowledged: true, insertedId: 'majority-1' }
rs0 [direct: primary] test> db.runCommand({insert: 't', documents: [{_id: 'majority-2', v: 2}], writeConcern: {w: 'majority', wtimeout: 5000}})
{
  n: 1,
  electionId: ObjectId('7fffffff0000000000000001'),
  opTime: { ts: Timestamp({ t: 1790513570, i: 1 }), t: Long('1') },
  ok: 1,
  '$clusterTime': {
    clusterTime: Timestamp({ t: 1790513570, i: 1 }),
...
  },
  operationTime: Timestamp({ t: 1790513570, i: 1 })
}
```

`insertOne`은 드라이버가 응답을 요약해 보여 주고, `runCommand`는 서버 응답을 그대로 보여 줍니다. `opTime`이 이 쓰기의 oplog 위치이고, `t: Long('1')`은 term 1(첫 primary의 임기)이라는 뜻입니다. `electionId`도 term을 담고 있습니다(`...0001`). `operationTime`과 `$clusterTime`은 [causal consistency](#causal-consistency-내가-쓴-것을-secondary에서-읽기)에서 씁니다.

#### w:1, j:true, w:"majority"의 지연

한 세션에서 각 write concern으로 300건씩 순서대로 넣고 전체 시간을 쟀습니다. 다른 실습이 같은 호스트에서 돌고 있었으므로 절대값에는 의미가 없고, 같은 실행 안에서의 비교로만 봐야 합니다.

```mongosh
rs0 [direct: primary] test> function bench(wc, n) { const t0 = Date.now(); for (let i = 0; i < n; i++) { db.bench.insertOne({i: i}, {writeConcern: wc}); } return (Date.now() - t0) + ' ms / ' + n; }
[Function: bench]
rs0 [direct: primary] test> bench({w: 1}, 300)
207 ms / 300
rs0 [direct: primary] test> bench({w: 1, j: true}, 300)
216 ms / 300
rs0 [direct: primary] test> bench({w: 'majority'}, 300)
246 ms / 300
rs0 [direct: primary] test> bench({w: 3}, 300)
235 ms / 300
```

`w:1`이 가장 빠르고 `w:"majority"`가 가장 느리지만, 차이는 건당 0.1ms 안팎입니다. 세 컨테이너가 한 호스트의 가상 네트워크에 있어서 왕복 시간이 거의 없기 때문입니다. 실제 서버 사이에서는 `w:"majority"`의 지연이 "가장 가까운 secondary까지의 왕복 + 그 secondary의 저널 기록"만큼 늘어납니다. 3노드에서 과반은 primary 자신을 포함한 2개이므로, 느린 secondary 하나는 기다리지 않습니다.

## majority commit point: 과반이 가진 위치

`"majority"`를 판단하는 기준은 primary의 **majority commit point**(`lastCommittedOpTime`)입니다. "voting 멤버의 과반이 이 optime까지 가지고 있다"는 위치이고, primary가 secondary의 보고를 받을 때마다 [`TopologyCoordinator::updateLastCommittedOpTimeAndWallTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L3040)으로 다시 계산합니다.

1. voting 멤버마다 위치를 하나씩 모읍니다. `writeConcernMajorityJournalDefault`가 true면 durable optime, 아니면 written optime입니다.
2. 오름차순으로 정렬하고, 뒤에서 `writeMajority`번째 값을 고릅니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L3072-L3077)). 3노드에서 `writeMajority`는 2이므로 두 번째로 앞선 멤버의 위치가 commit point입니다. primary는 보통 가장 앞서 있으니, 가장 빠른 secondary의 위치와 같아집니다.
3. `writeMajority`는 `min(과반 투표 수, 데이터를 가진 voting 멤버 수)`입니다([`ReplSetConfig::_calculateMajorities()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.cpp#L627-L636)). arbiter는 투표는 하지만 데이터가 없어서 이 값을 줄입니다.

commit point가 전진하면 primary는 이것을 스토리지로 내려보냅니다([`_setStableTimestampForStorage()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L5911)).

- **stable optime**은 commit point와 "이보다 앞에는 더 커밋될 쓰기가 없는 위치"(oplog hole이 없는 위치) 가운데 작은 쪽입니다([`_recalculateStableOpTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L5837)). 즉 stable optime은 majority commit point를 넘지 않습니다.
- 이 stable optime이 **committed snapshot**이 되고([`_updateCommittedSnapshot()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L6453)), WiredTiger의 **stable timestamp**로도 설정됩니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L5965-L5967)). [2편](/posts/mongodb/02-checkpoint-and-journal/)의 체크포인트가 기록하는 시점과 [3편](/posts/mongodb/03-mvcc-and-snapshot/)의 timestamp가 여기서 이어집니다.
- committed snapshot이 바뀌면 그것을 기다리던 write concern waiter와 read concern 대기를 깨웁니다.

정리하면 `w:"majority"` 쓰기의 응답은 "이 쓰기가 committed snapshot에 들어갔다", 즉 "과반의 저널에 들어가 되돌려질 수 없는 위치를 넘었다"는 뜻입니다.

#### replSetGetStatus로 보는 위치들

```mongosh
rs0 [direct: primary] test> const o = db.adminCommand({replSetGetStatus: 1}).optimes; ({lastCommittedOpTime: o.lastCommittedOpTime, readConcernMajorityOpTime: o.readConcernMajorityOpTime, appliedOpTime: o.appliedOpTime, writtenOpTime: o.writtenOpTime, durableOpTime: o.durableOpTime})
{
  lastCommittedOpTime: { ts: Timestamp({ t: 1790513571, i: 1150 }), t: Long('1') },
  readConcernMajorityOpTime: { ts: Timestamp({ t: 1790513571, i: 1150 }), t: Long('1') },
  appliedOpTime: { ts: Timestamp({ t: 1790513571, i: 1150 }), t: Long('1') },
  writtenOpTime: { ts: Timestamp({ t: 1790513571, i: 1150 }), t: Long('1') },
  durableOpTime: { ts: Timestamp({ t: 1790513571, i: 1150 }), t: Long('1') }
}
```

| 필드 | 뜻 |
|---|---|
| `lastCommittedOpTime` | majority commit point |
| `readConcernMajorityOpTime` | committed snapshot. read concern `majority`가 읽는 시점 |
| `writtenOpTime` | 이 멤버가 oplog에 쓴 위치 |
| `appliedOpTime` | 이 멤버가 적용까지 끝낸 위치 |
| `durableOpTime` | 이 멤버가 저널까지 기록한 위치 |

바로 앞에서 넣은 1200건 뒤로 쓰기가 없어서 다섯 위치가 모두 같습니다. secondary가 모두 따라와 있으면 commit point는 primary의 위치와 거의 붙어 다닙니다. 이 둘이 벌어지는 모습은 secondary를 멈춰 보면 볼 수 있습니다.

#### secondary 둘을 멈추면: w:1은 성공, w:"majority"는 wtimeout

primary에 mongosh 세션 A를 열어 둔 채로, `m08-2`와 `m08-3`의 mongod에 `SIGSTOP`을 보냅니다. 프로세스는 살아 있지만 아무 일도 하지 않으므로 heartbeat에도, oplog 요청에도 응답하지 않습니다.

```console
$ kill -STOP 18
$ ps -o pid,stat,comm -p 18
    PID STAT COMMAND
     18 Tl   mongod
```

(`m08-2`의 mongod PID가 18, `m08-3`은 17이고 `m08-3`에도 같은 명령을 보냈습니다. `STAT`의 `T`가 멈춘 상태입니다.)

세션 A에서 `w:1`, `w:"majority"`(wtimeout 2초), 그리고 write concern을 지정하지 않은 쓰기(`maxTimeMS` 2초)를 차례로 보냅니다.

```mongosh
A rs0 [direct: primary] test> db.t.insertOne({_id: 'w1-stalled', v: 10}, {writeConcern: {w: 1}})
{ acknowledged: true, insertedId: 'w1-stalled' }

A rs0 [direct: primary] test> db.runCommand({insert: 't', documents: [{_id: 'maj-stalled', v: 11}], writeConcern: {w: 'majority', wtimeout: 2000}})
Uncaught:
MongoWriteConcernError[WriteConcernFailed]: waiting for replication timed out
Additional information: {
  wtimeout: true,
  writeConcern: { w: 'majority', wtimeout: 2000, provenance: 'clientSupplied' }
}
Result: {
  n: 1,
  electionId: ObjectId('7fffffff0000000000000001'),
  opTime: { ts: Timestamp({ t: 1790513576, i: 1 }), t: 1 },
  writeConcernError: {
    code: 64,
    codeName: 'WriteConcernFailed',
    errmsg: 'waiting for replication timed out',
    errInfo: {
      wtimeout: true,
      writeConcern: { w: 'majority', wtimeout: 2000, provenance: 'clientSupplied' }
    }
  },
  ok: 1,
...
}

A rs0 [direct: primary] test> db.runCommand({insert: 't', documents: [{_id: 'default-stalled', v: 12}], maxTimeMS: 2000})
Uncaught:
MongoWriteConcernError[MaxTimeMSExpired]: operation exceeded time limit
Additional information: {
  writeConcern: { w: 'majority', wtimeout: 0, provenance: 'implicitDefault' }
}
Result: {
  n: 1,
...
  writeConcernError: {
    code: 50,
    codeName: 'MaxTimeMSExpired',
    errmsg: 'operation exceeded time limit',
...
  ok: 1,
...
}
```

- `w:1`은 secondary와 상관없이 곧바로 성공했습니다. primary의 로컬 커밋만 기다리기 때문입니다.
- `w:"majority", wtimeout: 2000`은 2초 뒤 `writeConcernError`(`code: 64`, `WriteConcernFailed`, `waiting for replication timed out`)로 끝났습니다. 그런데 같은 응답에 `n: 1`, `ok: 1`, `opTime`이 있습니다. **명령은 성공했고 도큐먼트는 들어갔으며, 기다림만 실패했다**는 뜻입니다. mongosh는 이 응답을 오류로 던지지만 서버 응답 자체는 `ok: 1`입니다.
- write concern을 지정하지 않은 쓰기는 `provenance: 'implicitDefault'`, 즉 기본값 `{ w: 'majority', wtimeout: 0 }`으로 기다렸습니다. wtimeout이 0이라 스스로는 끝나지 않고, `maxTimeMS`(2초)가 지나서야 `MaxTimeMSExpired`로 끝났습니다. 이것도 `n: 1`입니다. `maxTimeMS`가 없었다면 이 쓰기는 secondary가 돌아올 때까지 응답하지 않았을 것입니다. 대기 시간 초과를 `WriteConcernFailed`로 바꾸는 것은 wtimeout이 opCtx의 deadline보다 먼저 올 때뿐입니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2397-L2402)).

같은 세션에서 read concern만 바꿔 읽고, 위치를 확인합니다.

```mongosh
A rs0 [direct: primary] test> db.t.find({v: {$gte: 10}}).readConcern('local').toArray()
[
  { _id: 'w1-stalled', v: 10 },
  { _id: 'maj-stalled', v: 11 },
  { _id: 'default-stalled', v: 12 }
]

A rs0 [direct: primary] test> db.t.find({v: {$gte: 10}}).readConcern('majority').toArray()
[]

A rs0 [direct: primary] test> const s = db.adminCommand({replSetGetStatus: 1}); ({lastCommittedOpTime: s.optimes.lastCommittedOpTime.ts, appliedOpTime: s.optimes.appliedOpTime.ts, members: s.members.map(m => m.name + ' ' + m.stateStr + ' ' + (m.health === 1 ? 'up' : 'down'))})
{
  lastCommittedOpTime: Timestamp({ t: 1790513571, i: 1150 }),
  appliedOpTime: Timestamp({ t: 1790513580, i: 1 }),
  members: [
    'm08-1:27017 PRIMARY up',
    'm08-2:27017 (not reachable/healthy) down',
    'm08-3:27017 (not reachable/healthy) down'
  ]
}
```

- `local`로 읽으면 세 도큐먼트가 모두 보입니다. primary에는 분명히 들어가 있습니다.
- `majority`로 읽으면 하나도 보이지 않습니다. `lastCommittedOpTime`이 secondary를 멈추기 전의 위치(`1790513571, i: 1150`, 앞에서 본 값과 같음)에 멈춰 있고, primary의 `appliedOpTime`만 `1790513580`까지 나갔습니다. majority 읽기는 commit point의 스냅샷을 읽으므로, 그 뒤에 들어온 세 도큐먼트는 아직 없는 것으로 보입니다.
- 두 secondary는 heartbeat에 응답하지 않아 `(not reachable/healthy)`로 보입니다.

secondary를 깨우고(`kill -CONT`) 3초 뒤 다시 읽습니다.

```mongosh
rs0 [direct: primary] test> db.t.find({v: {$gte: 10}}).readConcern('majority').toArray()
[
  { _id: 'w1-stalled', v: 10 },
  { _id: 'maj-stalled', v: 11 },
  { _id: 'default-stalled', v: 12 }
]
rs0 [direct: primary] test> rs.status().members.map(m => m.name + ' ' + m.stateStr)
[
  'm08-1:27017 PRIMARY',
  'm08-2:27017 SECONDARY',
  'm08-3:27017 SECONDARY'
]
```

secondary가 밀린 oplog를 받아 가자 commit point가 전진했고, 세 도큐먼트가 모두 majority 읽기에 보입니다. `WriteConcernFailed`를 받은 `maj-stalled`와 `MaxTimeMSExpired`를 받은 `default-stalled`도 그대로 남아 있습니다.

#### 운영에서는: writeConcernError는 "실패"가 아니라 "모름"이다

wtimeout이나 `maxTimeMS`로 끝난 쓰기는 **들어갔을 수도, 나중에 rollback될 수도 있는 상태**입니다. 위 실습처럼 secondary가 돌아오면 남고, [뒤에서 볼 것처럼](#rollback-w1로-인정받은-쓰기가-사라지는-과정) 그 전에 primary가 바뀌면 사라집니다. 그래서 `writeConcernError`를 받았을 때 같은 쓰기를 그냥 다시 보내면 중복이 생길 수 있습니다. 재시도하는 쓰기는 고유 `_id`나 upsert처럼 두 번 실행해도 결과가 같게 만들거나, 드라이버의 retryable writes(세션의 `txnNumber`로 같은 쓰기를 한 번만 적용)에 맡겨야 합니다.

## 기본 write concern과 arbiter

기본 write concern은 레플리카셋 구성으로 정해집니다([`ReadWriteConcernDefaults`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_write_concern_defaults.cpp#L292-L305)). 운영자가 `setDefaultRWConcern`으로 정한 값(cluster-wide write concern, CWWC)이 있으면 그것을 쓰고(`Source: 'global'`), 없으면 다음 규칙으로 계산합니다(`'implicit'`).

```cpp
bool ReplSetConfig::isImplicitDefaultWriteConcernMajority() const {
    auto arbiters = _totalVotingMembers - _writableVotingMembersCount;
    return arbiters == 0 || _writableVotingMembersCount > _majorityVoteCount;
}
```

[`isImplicitDefaultWriteConcernMajority()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.cpp#L781-L787)의 뜻은 이렇습니다. voting arbiter가 없으면 `w:"majority"`입니다. arbiter가 있으면, 데이터를 가진 voting 멤버 수가 과반 투표 수보다 **클 때만** `w:"majority"`이고 아니면 `w:1`입니다. 소스 주석이 이유를 말해 줍니다. arbiter 덕에 primary는 뽑혀 있는데 majority 쓰기는 끝나지 않는 상황을 막기 위해서입니다.

| 구성 | voting / 데이터 voting / 과반 | 기본 write concern |
|---|---|---|
| PSS (3노드) | 3 / 3 / 2 | `w:"majority"` |
| PSA | 3 / 2 / 2 | `w:1` |
| PSSA | 4 / 3 / 3 | `w:1` |
| PSSSA | 5 / 4 / 3 | `w:"majority"` |

PSA에서 secondary 하나가 죽으면 primary와 arbiter로 과반 투표는 되지만, 데이터를 가진 멤버는 primary뿐이라 majority 쓰기가 끝날 수 없습니다. 그래서 이런 구성의 기본값은 `w:1`이 됩니다.

#### arbiter를 더하면 reconfig가 거부된다

실습 마지막(아래 rollback 실습이 끝나 `m08-3`이 primary인 상태)에 arbiter를 하나 더해 PSS를 PSSA로 바꿔 봤습니다.

```mongosh
rs0 [direct: primary] test> rs.addArb('m08-4:27017')
MongoServerError[NewReplicaSetConfigurationIncompatible]: Reconfig attempted to install a config that would change the implicit default write concern. Use the setDefaultRWConcern command to set a cluster-wide write concern and try the reconfig again.
rs0 [direct: primary] test> db.adminCommand({setDefaultRWConcern: 1, defaultWriteConcern: {w: 'majority'}, writeConcern: {w: 'majority'}})
{
  defaultReadConcern: { level: 'local' },
  defaultWriteConcern: { w: 'majority', wtimeout: 0 },
  updateOpTime: Timestamp({ t: 1790513642, i: 1 }),
...
  defaultWriteConcernSource: 'global',
  defaultReadConcernSource: 'implicit',
...
}
rs0 [direct: primary] test> rs.addArb('m08-4:27017').ok
1
```

- PSSA의 기본값은 표처럼 `w:1`입니다. reconfig가 implicit default를 `w:"majority"`에서 `w:1`로 바꾸게 되자 서버가 `NewReplicaSetConfigurationIncompatible`로 거부했습니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L4157-L4170)). 구성 변경 하나로 애플리케이션의 쓰기 보장이 조용히 약해지는 일을 막는 장치입니다.
- `setDefaultRWConcern`으로 CWWC를 명시하자 `defaultWriteConcernSource`가 `'global'`이 되었고, 같은 `rs.addArb`가 성공했습니다. 이제 기본값은 구성과 상관없이 `w:"majority"`입니다.

단, 이 PSSA 구성에서 `writeMajority`는 `min(3, 3) = 3`이므로 `w:"majority"`가 데이터를 가진 세 멤버를 **모두** 기다립니다. secondary 하나만 멈춰도 기본 설정의 쓰기가 멈춥니다. arbiter를 더할 때는 이 대가를 알고 결정해야 합니다.

## read concern: 어느 스냅샷에서 읽는가

read concern은 읽기가 **어느 시점의 스냅샷**을 볼지 정합니다. [3편](/posts/mongodb/03-mvcc-and-snapshot/)에서 본 WiredTiger의 timestamp 읽기(`read_timestamp`)를 어떤 값으로 여느냐의 차이입니다. 결정은 [`waitForReadConcernImpl()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp#L326)에서 합니다.

| level | 읽는 시점 | 되돌려질 수 있는가 |
|---|---|---|
| `local` (기본값) | 이 멤버의 최신 데이터 | 예 (rollback되면 사라짐) |
| `available` | `local`과 같음. 샤드에서 orphan 도큐먼트 필터링을 하지 않음 | 예 |
| `majority` | committed snapshot | 아니오 |
| `snapshot` | 지정한 `atClusterTime`, 없으면 committed snapshot | 아니오 |
| `linearizable` | 최신 데이터를 읽은 뒤, 과반 확인까지 기다림 (primary만) | 아니오 |

- **`majority`**: 읽기의 read source를 `kMajorityCommitted`로 정하고([`read_concern_mongod.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp#L479)), WiredTiger 트랜잭션을 committed snapshot의 timestamp로 엽니다([`beginTransactionOnCommittedSnapshot()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_snapshot_manager.cpp#L91-L121)). 과반 확인을 **기다리는** 것이 아니라, 이미 과반이 확인된 과거 시점을 **읽는** 것입니다. 그래서 앞 실습에서 secondary가 멈췄을 때도 오류 없이 곧바로 옛 데이터(빈 결과)를 돌려줬습니다.
- **`available`**: 레플리카셋에서는 `local`과 같습니다. 샤드에서는 컬렉션을 샤딩되지 않은 것처럼 다뤄 shard version 확인과 orphan 필터링을 건너뜁니다([`collection_sharding_runtime.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/collection_sharding_runtime.cpp#L485-L487)). orphan은 [7편](/posts/mongodb/07-sharding/)에서 다룹니다.
- **`snapshot`**: 트랜잭션 밖에서는 `atClusterTime`으로 준 시점, 없으면 committed snapshot의 시점을 읽습니다([`read_concern_mongod.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp#L439-L449)). 여러 번 읽어도 같은 시점을 보게 하려고 씁니다.
- **`linearizable`**: 아래에서 따로 봅니다.

`local`은 secondary에서 읽으면 그 secondary가 적용한 곳까지를 봅니다. 복제가 늦으면 옛 데이터를 보고, primary가 rollback되면 방금 본 데이터가 사라질 수도 있습니다.

#### snapshot: 과거 시점으로 읽기

```mongosh
rs0 [direct: primary] test> const t1 = db.runCommand({insert: 'snap', documents: [{_id: 1, v: 'old'}]}).operationTime; t1
Timestamp({ t: 1790513570, i: 4 })
rs0 [direct: primary] test> db.snap.updateOne({_id: 1}, {$set: {v: 'new'}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
rs0 [direct: primary] test> db.snap.find()
[ { _id: 1, v: 'new' } ]
rs0 [direct: primary] test> db.runCommand({find: 'snap', filter: {_id: 1}, readConcern: {level: 'snapshot', atClusterTime: t1}}).cursor.firstBatch
[ { _id: 1, v: 'old' } ]
rs0 [direct: primary] test> db.adminCommand({getParameter: 1, minSnapshotHistoryWindowInSeconds: 1}).minSnapshotHistoryWindowInSeconds
300
```

insert의 `operationTime`(`t1`)을 기억해 두고 값을 `new`로 바꾼 뒤, `atClusterTime: t1`로 읽자 바꾸기 전 값 `old`가 나왔습니다. WiredTiger가 도큐먼트의 옛 버전을 timestamp와 함께 보관하고 있어서 가능합니다([3편](/posts/mongodb/03-mvcc-and-snapshot/)). 얼마나 먼 과거까지 읽을 수 있는지는 `minSnapshotHistoryWindowInSeconds`(기본 300초, [`snapshot_window_options.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/snapshot_window_options.idl#L36-L42))가 정합니다. 서버는 committed snapshot보다 이 시간만큼 앞선 버전까지 지우지 않고 남깁니다.

### linearizable: 읽은 뒤에 과반에 물어본다

`majority` 읽기는 되돌려지지 않는 데이터를 보장하지만, **가장 최신**이라는 보장은 없습니다. 특히 네트워크에서 고립된 옛 primary는 자기가 아직 primary라고 믿는 동안 옛 데이터를 돌려줄 수 있습니다. `linearizable`은 이것을 막습니다. primary에서만 되고, 읽기를 끝낸 뒤 oplog에 noop 엔트리(`{msg: 'linearizable read'}`)를 하나 쓰고 그 엔트리가 과반에 복제될 때까지 기다립니다([`waitForLinearizableReadConcernImpl()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp#L542-L597)). 과반이 받아 줬다면 읽는 순간에 이 멤버가 진짜 primary였다는 뜻입니다. 이 대기에는 따로 시간 제한이 없어서([`service_entry_point_mongod.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/service_entry_point_mongod.cpp#L232)), `maxTimeMS`와 함께 쓰라고 문서가 권합니다.

#### secondary가 멈춘 동안의 linearizable 읽기

앞의 실습에서 secondary 둘이 멈춘 동안, 같은 세션 A에서 linearizable 읽기를 했습니다.

```mongosh
A rs0 [direct: primary] test> db.runCommand({find: 't', filter: {_id: 'majority-1'}, readConcern: {level: 'linearizable'}, maxTimeMS: 2000})
MongoServerError[MaxTimeMSExpired]: operation exceeded time limit
```

secondary를 깨운 뒤 oplog를 보고, 같은 읽기를 다시 합니다.

```mongosh
rs0 [direct: primary] test> db.getSiblingDB('local').oplog.rs.find({op: 'n', 'o.msg': 'linearizable read'}, {ts: 1, op: 1, o: 1}).toArray()
[
  {
    op: 'n',
    o: { msg: 'linearizable read' },
    ts: Timestamp({ t: 1790513588, i: 1 })
  }
]
rs0 [direct: primary] test> db.runCommand({find: 't', filter: {_id: 'majority-1'}, readConcern: {level: 'linearizable'}, maxTimeMS: 2000}).cursor.firstBatch
[ { _id: 'majority-1', v: 1 } ]
```

- 도큐먼트는 이미 읽었지만 과반 확인이 오지 않아 2초 뒤 `MaxTimeMSExpired`로 끝났습니다. 결과는 돌려주지 않았습니다.
- oplog에는 그 읽기가 남긴 noop 엔트리(`op: 'n'`)가 secondary를 멈춘 동안의 timestamp(`1790513588`)로 남아 있습니다. **linearizable 읽기는 매번 oplog 쓰기 한 번과 과반 왕복 한 번을 치릅니다.**
- secondary가 돌아온 뒤에는 같은 읽기가 곧바로 성공합니다.

## causal consistency: 내가 쓴 것을 secondary에서 읽기

primary에 쓰고 곧바로 secondary에서 읽으면, secondary가 아직 그 쓰기를 적용하지 않았을 수 있습니다. **causal consistency**는 "내가 앞서 쓰거나 읽은 것보다 이전 상태는 보지 않는다"는 보장이고, 두 가지 시간으로 구현합니다.

- **`$clusterTime`**: 클러스터 전체의 논리 시계입니다. 모든 응답에 붙어 오고, 클라이언트는 받은 것 중 가장 큰 값을 다음 요청에 붙입니다.
- **`operationTime`**: 이 명령이 만든(쓰기) 또는 본(읽기) 데이터의 시점입니다. 쓰기면 그 oplog 엔트리의 timestamp, 읽기면 read concern에 따라 committed snapshot이나 마지막 적용 위치입니다([`computeOperationTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/service_entry_point_common.cpp#L333-L355)).

causal consistency 세션을 쓰면 드라이버가 세션의 마지막 `operationTime`을 기억했다가, 다음 읽기에 `readConcern: {afterClusterTime: <그 시점>}`을 붙입니다. 이 읽기를 받은 멤버는 자기가 그 시점까지 따라올 때까지 **기다렸다가** 읽습니다([`_waitUntilClusterTimeForRead()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2058-L2087)). level이 `majority`면 committed snapshot이 그 시점에 닿기를 기다리고([`waitUntilMajorityOpTime()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2006-L2040)), `local`이면 적용을 끝낸 위치(applied optime)가 닿기를 기다립니다. 샤드 클러스터에서는 멤버의 oplog가 그 clusterTime보다 뒤처져 있으면 primary에 noop을 쓰게 해 시계를 밀어 주는데, 샤딩이 아닌 레플리카셋에서는 이 단계를 건너뜁니다([`makeNoopWriteIfNeeded()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp#L155-L193)).

#### 적용이 멈춘 secondary에서 afterClusterTime으로 읽기

지연을 만들기 위해 `m08-3`에서 `db.fsyncLock()`을 겁니다. fsyncLock은 백업용 명령으로, 전역 공유 잠금을 잡아 쓰기를 모두 막습니다([`fsync.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/commands/fsync.cpp#L455)). 읽기는 되지만 oplog 적용도 쓰기라서 멈춥니다. primary와 `m08-2`로 과반이 되므로 majority 쓰기는 계속 됩니다.

```mongosh
rs0 [direct: secondary] test> db.fsyncLock()
{
  info: 'now locked against writes, use db.fsyncUnlock() to unlock',
  lockCount: Long('1'),
...
}
```

primary에서 `w:"majority"`로 씁니다.

```mongosh
rs0 [direct: primary] test> const r = db.runCommand({insert: 't', documents: [{_id: 'causal-1', v: 20}], writeConcern: {w: 'majority'}}); r
{
  n: 1,
  electionId: ObjectId('7fffffff0000000000000001'),
  opTime: { ts: Timestamp({ t: 1790513597, i: 1 }), t: Long('1') },
  ok: 1,
...
  operationTime: Timestamp({ t: 1790513597, i: 1 })
}
```

이 쓰기의 `operationTime`은 `Timestamp({ t: 1790513597, i: 1 })`입니다. 이제 `m08-3`에 접속해서 읽습니다.

```mongosh
rs0 [direct: secondary] test> db.t.find({_id: 'causal-1'}).readConcern('local').toArray()
[]
rs0 [direct: secondary] test> db.t.find({_id: 'causal-1'}).readConcern('majority').toArray()
[]
rs0 [direct: secondary] test> db.runCommand({find: 't', filter: {_id: 'causal-1'}, readConcern: {level: 'majority', afterClusterTime: Timestamp({t: 1790513597, i: 1})}, maxTimeMS: 3000})
MongoServerError[MaxTimeMSExpired]: Error waiting for snapshot not less than { ts: Timestamp(1790513597, 1), t: -1 }, current relevant optime is { ts: Timestamp(1790513596, 1), t: 1 }. :: caused by :: operation exceeded time limit
```

- `local`과 `majority`는 둘 다 빈 결과를 곧바로 돌려줍니다. 이미 과반에 커밋된 쓰기인데도 이 secondary에는 아직 없습니다. `majority` 읽기라도 **그 멤버의** committed snapshot을 읽을 뿐, 클러스터의 최신 commit point를 보장하지 않습니다. 이것이 secondary의 stale read입니다.
- `afterClusterTime`을 붙이자 곧바로 돌려주지 않고 기다리다가 3초 뒤 `MaxTimeMSExpired`로 끝났습니다. 메시지가 기다린 내용을 그대로 말해 줍니다. 요청한 시점 `Timestamp(1790513597, 1)` 이상의 스냅샷을 기다렸는데, 이 멤버의 committed snapshot은 fsyncLock을 건 시점인 `Timestamp(1790513596, 1)`에 머물러 있습니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L2036-L2038)). `t: -1`은 clusterTime에는 term이 없어서 붙은 값입니다.

이번에는 `m08-3`의 세션 B에서 `maxTimeMS` 없이 같은 읽기를 보내고, 다른 접속에서 잠금을 풉니다.

```mongosh
B rs0 [direct: secondary] test> db.runCommand({find: 't', filter: {_id: 'causal-1'}, readConcern: {level: 'majority', afterClusterTime: Timestamp({t: 1790513597, i: 1})}}).cursor.firstBatch
rs0 [direct: secondary] test> db.fsyncUnlock()
{
  info: 'fsyncUnlock completed',
  lockCount: Long('0'),
...
}
```

잠금을 풀자 세션 B에 결과가 돌아왔습니다.

```mongosh
[ { _id: 'causal-1', v: 20 } ]
```

세션 B의 읽기는 3초 동안 응답 없이 기다리다가, `m08-3`이 oplog를 적용해 committed snapshot이 그 시점을 넘자마자 방금 쓴 도큐먼트를 돌려줬습니다. 옛 데이터를 돌려주는 대신 기다리는 것, 이것이 causal consistency가 secondary 읽기에 주는 보장입니다.

#### 드라이버는 afterClusterTime을 알아서 붙인다

실제 애플리케이션은 `afterClusterTime`을 직접 쓰지 않습니다. 레플리카셋 전체에 접속한 mongosh에서 causal consistency 세션을 열고, 쓰고, secondary에서 읽었습니다. 두 secondary는 받은 명령을 모두 로그에 남기도록 `slowms`를 -1로 두었습니다.

```mongosh
rs0 [direct: primary] test> const s = db.getMongo().startSession({causalConsistency: true}); const sdb = s.getDatabase('test')
rs0 [direct: primary] test> sdb.t.insertOne({_id: 'causal-2', v: 21})
{ acknowledged: true, insertedId: 'causal-2' }
rs0 [direct: primary] test> s.getOperationTime()
Timestamp({ t: 1790513609, i: 1 })
rs0 [direct: primary] test> sdb.t.find({_id: 'causal-2'}).readPref('secondary').readConcern('majority').toArray()
[ { _id: 'causal-2', v: 21 } ]
```

읽기를 받은 secondary(`m08-2`)의 로그에서 그 find 명령을 봅니다.

```console
$ jq -c 'select(.msg == "Slow query" and .attr.command.find == "t" and .attr.command.filter._id == "causal-2") | {readConcern: .attr.command.readConcern, readPreference: .attr.command["$readPreference"]}' /data/mongod.log
{"readConcern":{"level":"majority","afterClusterTime":{"$timestamp":{"t":1790513609,"i":1}}},"readPreference":{"mode":"secondary"}}
```

코드에서는 `readConcern('majority')`만 지정했는데, 서버가 받은 명령에는 `afterClusterTime`이 insert의 `operationTime`(`1790513609, i: 1`)과 같은 값으로 붙어 있습니다. 세션이 마지막 `operationTime`을 기억했다가 드라이버가 붙여 준 것입니다. 같은 세션 안에서만 보장되므로, 요청마다 새 세션을 쓰거나 세션 없이 읽으면 이 보장은 없습니다. 또 쓰기와 읽기가 모두 `majority`일 때만 장애가 나도 이 순서가 깨지지 않습니다. `w:1` 쓰기는 rollback될 수 있기 때문입니다.

## rollback: w:1로 인정받은 쓰기가 사라지는 과정

`w:1` 쓰기는 primary에만 있어도 성공 응답을 받습니다. 그 쓰기가 과반에 복제되기 전에 primary가 바뀌면, 새 primary의 oplog에는 그 쓰기가 없고 다른 쓰기가 이어집니다. 옛 primary가 돌아오면 두 oplog가 **갈라진** 것을 발견하고, 자기에게만 있는 부분을 되돌려야 새 primary를 따라갈 수 있습니다. 이것이 **rollback**입니다.

8.0의 WiredTiger 환경에서 rollback은 **Recover To Timestamp** 방식입니다([`RollbackImpl::runRollback()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp#L253)). oplog 엔트리를 하나씩 거꾸로 되돌리는 것이 아니라, 스토리지 전체를 과반이 확인한 시점(stable timestamp)으로 한 번에 되돌린 뒤 거기서부터 다시 따라갑니다.

{{< diagram src="/diagrams/mongo-rollback-steps.html" title="옛 primary가 되돌리는 순서 (Recover To Timestamp)" height="560" caption="갈라짐을 감지하면 공통 지점을 찾고, 지워질 도큐먼트를 rollback 파일에 남긴 뒤 WiredTiger를 stable timestamp로 되돌립니다. 공통 지점 뒤의 oplog를 잘라 내고 다시 적용한 다음 SECONDARY로 돌아갑니다." >}}

1. **갈라짐 감지**: oplog fetcher가 sync source에서 가져온 첫 엔트리가 자기 마지막 엔트리와 이어지지 않으면 `OplogStartMissing`으로 멈추고([`oplog_fetcher.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/oplog_fetcher.cpp#L1194-L1198)), 복제 스레드가 rollback을 시작합니다([`bgsync.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/bgsync.cpp#L736-L739)).
2. **ROLLBACK 상태, 공통 지점**: 멤버 상태를 ROLLBACK으로 바꾸고, 자기 oplog와 sync source의 oplog를 뒤에서부터 비교해 마지막으로 같았던 엔트리(common point)를 찾습니다. 공통 지점 뒤가 너무 길면(`rollbackTimeLimitSecs`, 기본 1일, [`rollback_impl.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.idl#L44-L55)) 되돌리기를 거부합니다([`_checkAgainstTimeLimit()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp#L1261)).
3. **rollback 파일**: 공통 지점 뒤에 insert나 update된 도큐먼트(rollback이 지우거나 옛 버전으로 바꿀 도큐먼트)의 **현재 버전**을 `<dbPath>/rollback/<컬렉션 UUID>/removed.<시각>.bson`에 씁니다([`_writeRollbackFileForNamespace()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp#L1360-L1405)). `createRollbackDataFiles`(기본 true, [`rollback_impl.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.idl#L33-L42))로 끌 수 있습니다.
4. **stable timestamp로 복구**: WiredTiger의 `rollback_to_stable`을 불러 모든 테이블을 stable timestamp 시점으로 되돌립니다([`WiredTigerKVEngine::recoverToStableTimestamp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2472-L2514)). stable timestamp는 majority commit point를 넘지 않으므로([앞 절](#majority-commit-point-과반이-가진-위치)), 과반에 커밋된 쓰기는 이 단계에서 사라지지 않습니다.
5. **oplog 정리, 재적용**: 공통 지점 뒤의 oplog를 잘라 내도록 표시하고([`rollback_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp#L721-L737)), stable timestamp부터 공통 지점까지의 oplog를 다시 적용합니다([`rollback_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp#L746)). 이 과정은 [2편](/posts/mongodb/02-checkpoint-and-journal/)의 재시작 복구와 같은 코드입니다. 그 뒤 SECONDARY로 돌아가 새 primary의 oplog를 따라갑니다.

#### primary를 떼어 내고 w:1로 쓰기

먼저 `m08-1`의 priority를 1로 되돌려(재연결 뒤 priority 때문에 다시 primary가 되는 것을 막으려고) 세 멤버를 같게 하고, majority로 도큐먼트 하나를 넣어 둡니다.

```mongosh
rs0 [direct: primary] test> const cfg = rs.conf(); cfg.members[0].priority = 1; rs.reconfig(cfg).ok
1
rs0 [direct: primary] test> db.t.insertOne({_id: 'before-partition', v: 30}, {writeConcern: {w: 'majority'}})
{ acknowledged: true, insertedId: 'before-partition' }
```

그리고 `m08-1`을 네트워크에서 떼어 냈습니다. `m08-1`은 다른 멤버와 통신할 수 없지만, 그 안에서 접속한 mongosh는 계속 씁니다. `m08-1`은 아직 자기가 primary라고 알고 있습니다.

```mongosh
rs0 [direct: primary] test> db.hello().isWritablePrimary
true
rs0 [direct: primary] test> db.t.insertOne({_id: 'lost-w1', v: 31}, {writeConcern: {w: 1}})
{ acknowledged: true, insertedId: 'lost-w1' }
rs0 [direct: primary] test> db.t.updateOne({_id: 'before-partition'}, {$set: {v: 300}}, {writeConcern: {w: 1}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
rs0 [direct: primary] test> db.t.insertOne({_id: 'lost-majority-timeout', v: 32}, {writeConcern: {w: 'majority', wtimeout: 2000}})
Uncaught:
MongoWriteConcernError[WriteConcernFailed]: waiting for replication timed out
...
rs0 [direct: primary] test> db.t.find({v: {$gte: 30}}).toArray()
[
  { _id: 'before-partition', v: 300 },
  { _id: 'lost-w1', v: 31 },
  { _id: 'lost-majority-timeout', v: 32 }
]
```

`w:1` insert와 update는 성공 응답을 받았습니다. 클라이언트 입장에서 이 두 쓰기는 끝난 일입니다. `w:"majority"`로 보낸 세 번째 쓰기는 wtimeout을 받았지만, 앞에서 본 것처럼 도큐먼트는 들어가 있습니다.

#### 나머지 둘이 새 primary를 뽑는다

`electionTimeoutMillis`(30초)가 지나자 `m08-2`와 `m08-3`이 선거를 해 `m08-3`이 primary가 되었습니다. 새 primary에서는 다른 쓰기를 합니다.

```mongosh
rs0 [direct: primary] test> db.t.insertOne({_id: 'after-failover', v: 40}, {writeConcern: {w: 'majority'}})
{ acknowledged: true, insertedId: 'after-failover' }
rs0 [direct: primary] test> db.t.find({v: {$gte: 30}}).toArray()
[
  { _id: 'before-partition', v: 30 },
  { _id: 'after-failover', v: 40 }
]
rs0 [direct: primary] test> rs.status().members.map(m => m.name + ' ' + m.stateStr)
[
  'm08-1:27017 (not reachable/healthy)',
  'm08-2:27017 SECONDARY',
  'm08-3:27017 PRIMARY'
]
```

새 primary의 데이터에는 `m08-1`이 고립된 뒤 한 쓰기가 하나도 없습니다. `before-partition`은 30이고, `lost-w1`과 `lost-majority-timeout`은 없습니다. 같은 시각 `m08-1`도 과반을 볼 수 없다며 스스로 물러났습니다([`checkMemberTimeouts()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1361-L1378)).

```console
$ jq -c 'select(.msg | test("relinquishing primary|Stepping down from primary|Can.t see a majority")) | {t: .t."$date", msg}' /data/mongod.log
{"t":"2026-09-27T12:54:00.859+00:00","msg":"Can't see a majority of the set, relinquishing primary"}
{"t":"2026-09-27T12:54:00.859+00:00","msg":"Stepping down from primary in response to heartbeat"}
```

고립 직후의 쓰기(아래 rollback 요약의 `firstOpWallClockTimeAfterCommonPoint`, `12:53:31`)부터 약 30초 뒤입니다. 이 30초 동안 `m08-1`에는 primary가 둘인 것처럼 보이는 창이 있었고, 그 사이의 `w:1` 쓰기가 모두 성공 응답을 받았습니다.

#### 옛 primary를 다시 붙이면: ROLLBACK을 거쳐 SECONDARY

`m08-1`을 네트워크에 다시 붙이자, 몇 초 안에 SECONDARY가 되었습니다. `m08-1`의 로그에서 rollback 관련 메시지만 뽑습니다.

```console
$ jq -c 'select(.c == "ROLLBACK" or (.msg | test("Transition to ROLLBACK|Starting rollback|rollback"))) | {t: .t."$date", msg}' /data/mongod.log
...
{"t":"2026-09-27T12:54:03.881+00:00","msg":"Starting rollback due to fetcher error"}
{"t":"2026-09-27T12:54:03.881+00:00","msg":"Scheduling rollback"}
{"t":"2026-09-27T12:54:03.881+00:00","msg":"Transition to ROLLBACK"}
{"t":"2026-09-27T12:54:03.881+00:00","msg":"Finding common point"}
{"t":"2026-09-27T12:54:03.884+00:00","msg":"Rollback common point"}
{"t":"2026-09-27T12:54:03.884+00:00","msg":"Incremented the rollback ID"}
...
{"t":"2026-09-27T12:54:03.884+00:00","msg":"Finding record store counts"}
{"t":"2026-09-27T12:54:03.884+00:00","msg":"Preparing to write deleted documents to a rollback file"}
{"t":"2026-09-27T12:54:03.986+00:00","msg":"Rolling back to the stable timestamp"}
{"t":"2026-09-27T12:54:04.007+00:00","msg":"Rolling back to the stable timestamp completed by storage engine"}
{"t":"2026-09-27T12:54:04.014+00:00","msg":"Operations reverted by rollback"}
{"t":"2026-09-27T12:54:04.018+00:00","msg":"Marking to truncate all oplog entries with timestamps greater than common point"}
{"t":"2026-09-27T12:54:04.019+00:00","msg":"Not updating committed snapshot because we are in rollback"}
{"t":"2026-09-27T12:54:04.019+00:00","msg":"Triggering the rollback op observer"}
{"t":"2026-09-27T12:54:04.019+00:00","msg":"Rollback complete"}
{"t":"2026-09-27T12:54:04.019+00:00","msg":"Rollback summary"}
{"t":"2026-09-27T12:54:04.019+00:00","msg":"Transition to SECONDARY"}
```

위 그림의 단계가 순서대로 나옵니다. 전체가 약 140ms 걸렸습니다. 되돌릴 쓰기가 몇 개뿐이었기 때문입니다. rollback을 시작한 이유와 주요 단계의 내용을 봅니다.

```console
$ jq -c 'select(.msg == "Starting rollback due to fetcher error") | .attr' /data/mongod.log
{"error":"OplogStartMissing: the sync source's oplog and our oplog have diverged, going into rollback. our last optime fetched: { ts: Timestamp(1790513637, 1), t: 1 }. optime of first document in batch: { ts: Timestamp(1790513641, 2), t: 2 }. sync source's first optime: { ts: Timestamp(1790513535, 1), t: -1 }","lastCommittedOpTime":{"ts":{"$timestamp":{"t":1790513610,"i":2}},"t":1}}
$ jq -c 'select(.msg == "Rollback common point" or .msg == "Operations reverted by rollback" or .msg == "Preparing to write deleted documents to a rollback file") | {msg, attr}' /data/mongod.log
{"msg":"Rollback common point","attr":{"commonPointOpTime":{"ts":{"$timestamp":{"t":1790513610,"i":2}},"t":1}}}
{"msg":"Preparing to write deleted documents to a rollback file","attr":{"namespace":"test.t","uuid":"e16a3931-c0ef-487c-a251-1a236d215b48","file":"/data/db/rollback/e16a3931-c0ef-487c-a251-1a236d215b48/removed.2026-09-27T12-54-03.0.bson"}}
{"msg":"Operations reverted by rollback","attr":{"insert":2,"update":1,"delete":0,"insertGlobalIndexKey":0,"deleteGlobalIndexKey":0}}
```

- 갈라짐의 증거는 term입니다. `m08-1`의 마지막 엔트리는 term 1(`t: 1`)인데, sync source가 보낸 첫 엔트리는 term 2(`t: 2`)입니다. 새 primary가 term 2에서 쓴 oplog가 `m08-1`의 마지막 엔트리에서 이어지지 않으므로 oplog가 갈라졌다고 판단했습니다.
- 공통 지점은 `Timestamp(1790513610, 2)`, term 1입니다. 고립 전 마지막으로 과반에 복제된 쓰기(`before-partition`)입니다. `lastCommittedOpTime`도 같은 값이라, `m08-1`이 알고 있던 commit point까지는 그대로 남습니다.
- rollback 파일은 `test.t` 컬렉션의 UUID 디렉터리에 하나 생겼고, 되돌린 연산은 insert 2개와 update 1개입니다.

```console
$ jq -c 'select(.msg == "Rollback summary") | .attr | {startTime, endTime, syncSource, rbid, lastOptimeRolledBack, commonPoint, lastWallClockTimeRolledBack, firstOpWallClockTimeAfterCommonPoint, truncateTimestamp, stableTimestamp, rollbackDataFileDirectory, rollbackCommandCounts, totalEntriesRolledBackIncludingNoops}' /data/mongod.log
{"startTime":{"$date":"2026-09-27T12:54:03.881Z"},"endTime":{"$date":"2026-09-27T12:54:04.019Z"},"syncSource":"m08-2:27017","rbid":2,"lastOptimeRolledBack":{"ts":{"$timestamp":{"t":1790513637,"i":1}},"t":1},"commonPoint":{"ts":{"$timestamp":{"t":1790513610,"i":2}},"t":1},"lastWallClockTimeRolledBack":{"$date":"2026-09-27T12:53:57.392Z"},"firstOpWallClockTimeAfterCommonPoint":{"$date":"2026-09-27T12:53:31.368Z"},"truncateTimestamp":{"$timestamp":{"t":1790513610,"i":2}},"stableTimestamp":{"$timestamp":{"t":1790513610,"i":2}},"rollbackDataFileDirectory":"/data/db/rollback/e16a3931-c0ef-487c-a251-1a236d215b48","rollbackCommandCounts":{"update":1,"insert":2},"totalEntriesRolledBackIncludingNoops":5}
```

- `stableTimestamp`, `commonPoint`, `truncateTimestamp`가 모두 `1790513610, 2`입니다. 고립되기 직전에 commit point가 공통 지점까지 와 있었으므로 stable timestamp로 되돌리는 것만으로 공통 지점에 도착했고, 다시 적용할 oplog가 없었습니다.
- 되돌린 oplog 엔트리는 모두 5개(`totalEntriesRolledBackIncludingNoops`)이고 그중 명령은 3개입니다. 나머지 2개는 noop 엔트리입니다. primary는 쓰기가 없어도 10초마다 `periodic noop`을 oplog에 씁니다([`noop_writer.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/noop_writer.cpp#L76)). 마지막으로 되돌린 엔트리의 시각(`12:53:57`)이 쓰기 뒤 약 26초이므로, 고립된 동안 쓴 noop으로 보입니다.
- `rbid`(rollback ID)가 2가 되었습니다. 이 멤버가 rollback을 한 번 했다는 표시로, sync source를 고를 때 등에 쓰입니다.
- `syncSource`는 새 primary `m08-3`이 아니라 `m08-2`입니다. rollback의 기준은 primary가 아니라 이 멤버가 따라가는 sync source입니다.

#### rollback 파일과 살아남은 데이터

```console
$ find /data/db/rollback -type f
$ bsondump --quiet $(find /data/db/rollback -name 'removed.*.bson')
/data/db/rollback/e16a3931-c0ef-487c-a251-1a236d215b48/removed.2026-09-27T12-54-03.0.bson
{"_id":"lost-w1","v":{"$numberInt":"31"}}
{"_id":"lost-majority-timeout","v":{"$numberInt":"32"}}
{"_id":"before-partition","v":{"$numberInt":"300"}}
```

```mongosh
rs0 [direct: secondary] test> rs.status().members.map(m => m.name + ' ' + m.stateStr)
[
  'm08-1:27017 SECONDARY',
  'm08-2:27017 SECONDARY',
  'm08-3:27017 PRIMARY'
]
rs0 [direct: secondary] test> db.t.find({v: {$gte: 30}}).readPref('secondaryPreferred').toArray()
[
  { _id: 'before-partition', v: 30 },
  { _id: 'after-failover', v: 40 }
]
```

- rollback 파일에는 되돌려진 도큐먼트가 **되돌리기 직전의 모습**으로 들어 있습니다. insert된 `lost-w1`, `lost-majority-timeout`뿐 아니라, update로 300이 되었던 `before-partition`도 `v: 300`으로 남았습니다. 파일은 "지워지기 전 버전"을 모으는 것이지 "되돌린 연산의 목록"이 아닙니다.
- `m08-1`에는 이제 새 primary와 같은 데이터가 있습니다. `before-partition`은 majority로 쓴 원래 값 30으로 돌아왔고, 새 primary에서 쓴 `after-failover`가 있습니다. 성공 응답을 받은 `w:1` 쓰기 두 개는 사라졌습니다.
- majority로 쓴 `before-partition`의 insert는 살아남았고, wtimeout을 받은 `lost-majority-timeout`은 사라졌습니다. 앞에서 secondary가 돌아왔을 때는 wtimeout 쓰기가 남았으니, **wtimeout을 받은 쓰기의 운명은 그 뒤에 무슨 일이 일어나느냐에 달려 있습니다.**

## 운영에서는 이렇게 나타납니다

#### w:1 쓰기는 장애 한 번에 사라질 수 있다

rollback 실습의 `lost-w1`은 클라이언트가 성공 응답을 받았는데도 사라졌습니다. primary가 네트워크에서 고립되거나, 쓰기 직후 죽고 secondary가 선출되면 같은 일이 일어납니다. 8.0에서 PSS 구성의 기본값은 `w:"majority"`이지만, 드라이버 연결 문자열(`w=1`)이나 코드에서 `w:1`을 지정한 애플리케이션은 여전히 많습니다. "빠르니까" 지정한 `w:1`이 무엇을 포기하는지는 위 실습이 보여 줍니다. PostgreSQL의 비동기 복제에서 failover 뒤 마지막 커밋이 standby에 없는 것과 같은 성격입니다([PostgreSQL 인터널 9편](/posts/postgresql/09-streaming-replication/)). 차이는 MongoDB는 옛 primary가 돌아오면 그 쓰기를 파일로 꺼내 둔다는 점입니다.

#### 기본 write concern은 멈출 수 있다

기본값 `{ w: 'majority', wtimeout: 0 }`은 과반이 응답하지 않으면 끝나지 않습니다. 위 실습에서 `maxTimeMS`가 없었다면 `default-stalled` 쓰기는 secondary가 돌아올 때까지 응답하지 않았을 것입니다. secondary 둘이 동시에 느려지는 일(같은 스토리지 장애, 같은 시각의 백업)은 드물지 않습니다. 애플리케이션의 연결 풀이 이런 쓰기로 가득 차면 서비스 전체가 멈춘 것처럼 보입니다. 쓰기마다 `wtimeout`이나 `maxTimeMS`를 두고, 그 오류를 [writeConcernError의 뜻](#운영에서는-writeconcernerror는-실패가-아니라-모름이다)대로 처리해야 합니다.

#### secondary 읽기는 옛 데이터를 돌려준다

readPreference `secondary`나 `secondaryPreferred`로 읽으면, 실습의 `m08-3`처럼 적용이 늦은 멤버가 `local`은 물론 `majority`에서도 방금 쓴 데이터를 돌려주지 않습니다. 오류가 아니라 **빈 결과**가 오므로 알아채기 어렵습니다. "방금 저장한 것이 안 보인다"는 문의가 secondary 읽기에서 자주 나오는 이유입니다. 같은 사용자의 쓰기 뒤 읽기가 중요하면 causal consistency 세션을 쓰고, 오래된 멤버를 아예 피하려면 readPreference의 `maxStalenessSeconds`를 씁니다. 지연이 얼마인지는 [5편](/posts/mongodb/05-oplog-and-replication/)의 복제 지연 지표로 봅니다.

#### majority commit point가 멈추면 캐시가 찬다

commit point가 멈추면 stable timestamp도 멈춥니다. WiredTiger는 stable timestamp 이후의 변경을 체크포인트로 확정하지 못하고, 그 사이 도큐먼트의 옛 버전을 캐시와 history store에 계속 붙잡아야 합니다([3편](/posts/mongodb/03-mvcc-and-snapshot/)). 가장 흔한 경우가 PSA 구성에서 secondary가 오래 내려간 상황입니다. primary와 arbiter로 쓰기는 계속 받지만(기본값이 `w:1`이므로) commit point는 전진하지 않고, primary의 캐시 사용량과 `WiredTigerHS.wt`가 계속 커집니다. `replSetGetStatus`의 `optimes.lastCommittedOpTime`이 `appliedOpTime`보다 한참 뒤처져 있으면 이 상태입니다. secondary를 빨리 되살리거나, 오래 걸리면 그 멤버를 `votes: 0`으로 바꿔 과반 계산에서 빼는 것이 대응입니다.

#### rollback 파일은 누군가 처리해야 한다

rollback이 일어나면 `<dbPath>/rollback/<UUID>/removed.*.bson`이 생기고, 서버는 이 파일을 다시 쓰지 않습니다. 로그에서 `Rollback summary`나 `Transition to ROLLBACK`을 감시하고, 파일이 생기면 `bsondump`로 내용을 확인한 뒤 되살릴지 판단해야 합니다. 되살린다면 새 primary의 현재 데이터와 비교해야 합니다. 실습의 `before-partition`처럼 파일 속 버전(`v: 300`)과 현재 버전(`v: 30`)이 다르고, 그 사이 다른 쓰기가 있었을 수도 있기 때문입니다. rollback 파일이 쌓이는 것을 원하지 않는다고 `createRollbackDataFiles`를 끄는 것은 되살릴 방법을 버리는 것이므로 권하지 않습니다.

## 정리

- write concern은 로컬 커밋 **뒤에** 응답을 얼마나 늦출지 정합니다. `w:"majority"`는 committed snapshot이 그 쓰기의 optime을 넘을 때까지 기다리고, wtimeout이나 `maxTimeMS`가 먼저 오면 쓰기는 남긴 채 `writeConcernError`만 돌려줍니다.
- **majority commit point**는 voting 멤버의 위치를 정렬해 과반 번째 값을 고른 것이고, 이것이 committed snapshot과 WiredTiger stable timestamp가 됩니다.
- 8.0의 기본 write concern은 PSS에서 `w:"majority"`, arbiter 때문에 과반 쓰기가 막힐 수 있는 구성에서는 `w:1`입니다. 이 값을 바꾸는 reconfig는 CWWC 없이는 거부됩니다.
- read concern `majority`는 committed snapshot을 **읽고**, `linearizable`은 읽은 뒤 noop 쓰기로 과반을 **확인하며**, `snapshot`은 지정한 과거 시점을 읽습니다.
- causal consistency 세션은 `operationTime`을 기억해 다음 읽기에 `afterClusterTime`을 붙이고, 뒤처진 멤버는 그 시점까지 기다린 뒤 읽습니다.
- 과반에 복제되지 않은 쓰기는 primary가 바뀌면 **rollback**됩니다. 옛 primary는 stable timestamp로 되돌린 뒤 새 primary를 따라가고, 되돌린 도큐먼트는 `rollback/` 디렉터리의 BSON 파일로 남깁니다.

이 글로 MongoDB 인터널 연재를 마칩니다. WiredTiger의 캐시와 체크포인트에서 시작해 스냅샷과 timestamp, 인덱스와 플래너, oplog와 선출, 샤딩을 거쳐, 마지막으로 그 모든 것 위에서 클라이언트가 받는 보장까지 왔습니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/db/write_concern.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp): `waitForWriteConcern`
- [src/mongo/db/repl/replication_coordinator_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp): `awaitReplication`, committed snapshot, stable timestamp, read concern 대기
- [src/mongo/db/repl/topology_coordinator.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp): majority commit point 계산
- [src/mongo/db/repl/repl_set_config.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.cpp): write majority, implicit default write concern
- [src/mongo/db/read_write_concern_defaults.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_write_concern_defaults.cpp): 기본 read/write concern
- [src/mongo/db/read_concern_mongod.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/read_concern_mongod.cpp): read concern별 read source, linearizable
- [src/mongo/db/storage/wiredtiger/wiredtiger_snapshot_manager.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_snapshot_manager.cpp): committed snapshot으로 트랜잭션 열기
- [src/mongo/db/repl/rollback_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/rollback_impl.cpp): Recover To Timestamp rollback, rollback 파일

MongoDB 8.0 공식 문서

- [Write Concern](https://www.mongodb.com/docs/v8.0/reference/write-concern/)
- [Read Concern](https://www.mongodb.com/docs/v8.0/reference/read-concern/)
- [Causal Consistency and Read and Write Concerns](https://www.mongodb.com/docs/v8.0/core/causal-consistency-read-write-concerns/)
- [Rollbacks During Replica Set Failover](https://www.mongodb.com/docs/v8.0/core/replica-set-rollbacks/)
- [setDefaultRWConcern](https://www.mongodb.com/docs/v8.0/reference/command/setDefaultRWConcern/)
