---
title: "MongoDB 인터널 2: 체크포인트와 저널"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "WiredTiger", "체크포인트", "저널", "장애 복구", "unclean shutdown"]
weight: 2
summary: "MongoDB는 캐시의 변경을 언제 파일에 확정하고, 비정상 종료 뒤에는 무엇으로 복구하는가"
description: "60초 체크포인트, journal의 WiredTiger 로그, j 옵션과 journal flush, kill -9 뒤 복구, PostgreSQL WAL과의 차이"
---

## 개요

[1편](/posts/mongodb/01-wiredtiger-architecture/)에서 본 것처럼, WiredTiger의 쓰기는 캐시의 페이지를 고치는 일입니다. 고친 페이지가 파일에 닿는 것은 나중에 eviction이나 체크포인트가 그 페이지를 쓸 때입니다. 그렇다면 쓰기가 성공했다는 응답을 받은 직후 mongod가 죽으면, 캐시에만 있던 변경은 어떻게 될까요.

WiredTiger는 이 문제를 두 가지로 풉니다. 하나는 **체크포인트**입니다. 주기적으로 모든 테이블의 일관된 스냅샷을 파일에 새로 써서, 그 시점까지의 데이터를 확정합니다. 다른 하나는 **저널**(WiredTiger의 로그)입니다. 커밋할 때마다 변경을 로그 레코드로 남겨서, 마지막 체크포인트 뒤의 변경을 다시 만들 수 있게 합니다. 비정상 종료 뒤에는 마지막 체크포인트를 열고 그 뒤의 저널을 다시 적용합니다.

이 글에서 답할 질문은 다음과 같습니다.

- 체크포인트는 언제 돌고, 파일에 무엇을 남기는가
- 저널에는 무엇이 기록되고, 그 기록은 언제 디스크에 닿는가
- write concern의 `j:true`와 `j:false`는 무엇이 다른가
- mongod가 `kill -9`로 죽으면 재기동할 때 무슨 일이 일어나는가
- PostgreSQL의 WAL, 체크포인트와는 무엇이 다른가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 레플리카셋과 비교하는 부분만 멤버 하나짜리 레플리카셋을 따로 띄웠습니다.

## 체크포인트: 파일 안의 일관된 스냅샷

WiredTiger의 체크포인트는 "지금까지 캐시에서 고친 페이지를 파일에 쓴다"보다 조금 더 강한 약속입니다. 체크포인트 하나는 **모든 테이블을 한 시점에서 본 일관된 스냅샷**이고, 파일에는 체크포인트 단위로 완성된 B-tree가 들어 있습니다. [1편](/posts/mongodb/01-wiredtiger-architecture/#b-tree의-모양-internal-페이지와-leaf-페이지)에서 `wt verify`가 보여 준 `ckpt_name: WiredTigerCheckpoint.1`이 그 체크포인트의 이름입니다.

체크포인트 하나는 대략 이런 순서로 만들어집니다([`__txn_checkpoint()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_ckpt.c#L1100)).

1. 로그에 체크포인트 시작 레코드를 남깁니다([`txn_ckpt.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_ckpt.c#L1262)). 이 위치가 나중에 복구를 시작할 LSN(`ckpt_lsn`)입니다.
2. 체크포인트 트랜잭션의 스냅샷을 잡고, 테이블마다 그 스냅샷에서 보이는 내용으로 dirty 페이지를 reconciliation해서 **파일의 빈 자리에 새 블록으로** 씁니다. 제자리에 덮어쓰지 않습니다. 쓴 파일은 fsync합니다([`txn_ckpt.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_ckpt.c#L1363)).
3. 테이블마다 새 root 페이지의 주소를 메타데이터 테이블(`WiredTiger.wt`)에 적고, 메타데이터 테이블 자신도 체크포인트합니다.
4. 메타데이터의 새 root 주소를 `WiredTiger.turtle.set`에 쓰고 fsync한 뒤 `WiredTiger.turtle`로 이름을 바꿉니다([`__wti_turtle_update()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/meta/meta_turtle.c#L680-L721)). 이름 바꾸기는 원자적이므로, 이 순간 새 체크포인트가 확정됩니다.
5. 이전 체크포인트만 쓰던 블록을 재사용할 수 있는 빈 자리로 돌립니다. 새 체크포인트의 위치가 안정된 저장소에 적히기 **전에** 옛 블록을 재사용하면, 그 사이 죽었을 때 옛 체크포인트까지 망가지기 때문에 이 순서를 지킵니다([`__ckpt_process()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/block/block_ckpt.c#L547-L559)).

turtle 파일이 메타데이터의 체크포인트를 가리키고, 메타데이터가 각 테이블의 체크포인트를 가리키는 구조라서, 어느 순간에 죽더라도 파일에는 "완성된 마지막 체크포인트"가 온전히 남아 있습니다. 쓰다 만 새 블록은 아무도 가리키지 않는 빈 공간일 뿐입니다.

체크포인트를 부르는 것은 mongod의 **Checkpointer** 스레드입니다. `storage.syncPeriodSecs`(서버 파라미터 `syncdelay`, 기본 60초, [`storage_options.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_options.h#L106-L114))만큼 잠들었다가 깨어나 체크포인트를 하고, 끝나면 다시 60초를 잡니다([`Checkpointer::run()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/checkpointer.cpp#L102-L139)). 그래서 정확한 간격은 "60초 + 체크포인트에 걸린 시간"입니다. standalone에는 stable timestamp가 없어서 타임스탬프를 쓰지 않는 체크포인트(`use_timestamp=false`)를 하고, 레플리카셋에서는 과반수에 복제된 지점(stable timestamp)까지의 체크포인트를 합니다([`WiredTigerKVEngine::_checkpoint()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L2099-L2122)). 레플리카셋 쪽은 [5편](/posts/mongodb/05-oplog-and-replication/)과 [8편](/posts/mongodb/08-read-write-concern/)에서 다시 봅니다.

#### 기본 설정

기본 설정으로 standalone mongod를 띄우고 저널 설정과 파라미터를 봅니다.

```console
$ jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log | grep -oE 'log=\([^)]*\)'
log=(enabled=true,remove=true,path=journal,compressor=snappy)
log=(wait=0)
$ ls -l /data/db/journal
total 204800
-rw------- 1 mongod mongod 104857600 Sep 27 21:42 WiredTigerLog.0000000001
-rw------- 1 mongod mongod 104857600 Sep 27 21:42 WiredTigerPreplog.0000000001
```

```mongosh
test> db.adminCommand({getParameter: 1, syncdelay: 1, journalCommitInterval: 1})
{ journalCommitInterval: 100, syncdelay: 60, ok: 1 }
```

- 첫 줄이 저널 설정입니다. 둘째 줄 `log=(wait=0)`은 정규식에 `statistics_log=(wait=0)`의 뒷부분이 함께 걸린 것으로, 저널과는 관계없습니다.
- 체크포인트 주기 `syncdelay`는 60초, 저널을 fsync하는 주기 `journalCommitInterval`(`storage.journal.commitIntervalMs`)은 100ms입니다.
- 아무것도 쓰지 않았는데 `journal`에 100MB 파일이 둘 있습니다. `WiredTigerLog.0000000001`이 지금 쓰는 로그 파일이고, `WiredTigerPreplog.0000000001`은 다음에 쓸 파일을 미리 잡아 둔 것입니다([`api_data.py`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L995-L997)의 `prealloc`, 파일 크기는 [`file_max`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L1026-L1029) 기본 100MB).

#### 60초마다 도는 체크포인트

백그라운드에서 1초에 한 건씩 130초 동안 쓰게 해 두고, 2분쯤 뒤에 로그를 봅니다. mongod는 체크포인트마다 WiredTiger의 `saving checkpoint snapshot` 메시지를 남깁니다(`verbose=[checkpoint_progress:1]`, [`meta_ckpt.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/meta/meta_ckpt.c#L1743)).

```console
$ setsid nohup mongosh --quiet --eval 'for (let i = 0; i < 130; i++) { db.tick.insertOne({i: i, at: new Date()}); sleep(1000); }' > /dev/null 2>&1 &
$ jq -r 'select(.msg == "WiredTiger message" and (.attr.message.msg | test("saving checkpoint snapshot"))) | .t."$date" + "  " + .attr.message.msg' /data/mongod.log
2026-09-27T21:43:42.896+00:00  saving checkpoint snapshot min: 99, snapshot max: 99 snapshot count: 0, oldest timestamp: (0, 0) , meta checkpoint timestamp: (0, 0) base write gen: 1
2026-09-27T21:44:42.916+00:00  saving checkpoint snapshot min: 161, snapshot max: 161 snapshot count: 0, oldest timestamp: (0, 0) , meta checkpoint timestamp: (0, 0) base write gen: 1
```

```mongosh
test> function ckpt() { const c = db.serverStatus().wiredTiger.checkpoint; return {succeeded: c["total succeed number of checkpoints"], startedByApi: c["number of checkpoints started by api"], skippedClean: c["checkpoints skipped because database was clean"], mostRecentMs: c["most recent time (msecs)"], maxMs: c["max time (msecs)"]}; }
[Function: ckpt]
test> ckpt()
{
  succeeded: 2,
  startedByApi: 2,
  skippedClean: 0,
  mostRecentMs: 11,
  maxMs: 16
}
test> db.tick.countDocuments()
130
```

```console
$ grep -oE 'WiredTigerCheckpoint\.[0-9]+' /data/db/WiredTiger.turtle
WiredTigerCheckpoint.2
```

1분을 더 기다린 뒤 다시 봅니다.

```mongosh
test> ckpt()
{
  succeeded: 3,
  startedByApi: 3,
  skippedClean: 0,
  mostRecentMs: 10,
  maxMs: 16
}
```

```console
$ jq -r 'select(.msg == "WiredTiger message" and (.attr.message.msg | test("saving checkpoint snapshot"))) | .t."$date"' /data/mongod.log | tail -2
2026-09-27T21:44:42.916+00:00
2026-09-27T21:45:42.935+00:00
$ grep -oE 'WiredTigerCheckpoint\.[0-9]+' /data/db/WiredTiger.turtle
WiredTigerCheckpoint.3
```

- 체크포인트 시각이 21:43:42.896, 21:44:42.916, 21:45:42.935로 **60초와 약 20ms** 간격입니다. 앞 체크포인트가 끝난 뒤부터 60초를 세기 때문에 체크포인트에 걸린 시간만큼 조금씩 밀립니다.
- `serverStatus().wiredTiger.checkpoint`의 성공 횟수가 2에서 3으로 늘었고, 모두 mongod가 WiredTiger API로 부른 것(`startedByApi`)입니다. 쓰는 양이 적어서 체크포인트 하나에 10~16ms가 걸렸습니다.
- turtle 파일이 가리키는 메타데이터의 체크포인트 이름도 `WiredTigerCheckpoint.2`에서 `.3`으로 바뀌었습니다. 체크포인트마다 turtle이 새로 쓰입니다.
- 메시지의 `oldest timestamp: (0, 0)`, `meta checkpoint timestamp: (0, 0)`은 standalone이라 타임스탬프 없이 체크포인트했다는 뜻입니다.

## 저널: 체크포인트 뒤의 변경을 담는 로그

체크포인트가 60초마다라면, 그 사이의 변경은 저널이 지킵니다. MongoDB의 저널은 WiredTiger의 로그 기능 그대로이고, mongod가 `log=(enabled=true,path=journal,...)`로 켭니다. 저널은 페이지가 아니라 **트랜잭션의 변경 내용**을 기록합니다. 트랜잭션이 커밋할 때, 그 트랜잭션이 테이블마다 넣거나 고친 키와 값을 로그 레코드 하나로 만들어 로그에 씁니다([`__wt_txn_log_commit()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_log.c#L308-L321)). 커밋하지 않은 변경은 로그에 없습니다.

로그 레코드가 디스크에 닿기까지는 세 단계가 있습니다.

| 단계 | 누가 | 언제 |
|---|---|---|
| 로그 버퍼(slot)에 복사 | 커밋하는 스레드 | 커밋할 때. MongoDB는 `transaction_sync`를 켜지 않으므로(기본 `enabled=false`, [`api_data.py`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L1348-L1354)) 여기서 커밋이 끝남 |
| 파일에 `write()` | WiredTiger log server 스레드 등 | 버퍼가 차거나, log server가 50ms~1초 간격으로 깨어나 밀어낼 때([`conn_log.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/conn/conn_log.c#L1105-L1106), [`__log_server()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/conn/conn_log.c#L918-L928)), 또는 fsync를 요청받을 때 |
| `fsync` | mongod의 JournalFlusher 스레드 | `journalCommitInterval`(100ms)마다, 또는 `j:true` 쓰기가 요청할 때 |

JournalFlusher는 매번 [`waitUntilDurable()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/control/journal_flusher.cpp#L129-L135)을 부르고 `journalCommitInterval`만큼 기다리는 일을 반복합니다([`journal_flusher.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/control/journal_flusher.cpp#L170-L189)). `waitUntilDurable()`은 결국 WiredTiger의 `log_flush("sync=on")`입니다([`wiredtiger_session_cache.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_session_cache.cpp#L361)). 이 값은 1~500ms 사이로 실행 중에도 바꿀 수 있습니다([`storage_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_parameters.idl#L52-L60)).

로그 파일은 100MB가 차면 미리 잡아 둔 다음 파일로 넘어갑니다. 지난 파일은 그 안의 레코드가 모두 마지막 체크포인트보다 앞일 때, 즉 복구에 더는 필요 없을 때 log server가 지웁니다([`__compute_min_lognum()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/conn/conn_log.c#L385-L398)). 저널 파일을 지우는 것은 체크포인트입니다.

#### 250MB를 넣으면 저널 파일이 는다

1KB 남짓한 문서 25만 개를 넣기 전후로 로그 통계를 봅니다. `bytes written for checkpoint`는 체크포인트가 데이터 파일에 쓴 양입니다.

```js
// /data/load.js: 1KB 남짓한 문서 25만 개(약 250MB)를 넣는다
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
```

```mongosh
test> function logstat() { const l = db.serverStatus().wiredTiger.log, b = db.serverStatus().wiredTiger["block-manager"]; return {logBytesWritten: l["log bytes written"], logSyncs: l["log sync operations"], maxLogFileSize: l["maximum log file size"], preallocUsed: l["pre-allocated log files used"], ckptBytesWritten: b["bytes written for checkpoint"]}; }
[Function: logstat]
test> logstat()
{
  logBytesWritten: 50688,
  logSyncs: 154,
  maxLogFileSize: 104857600,
  preallocUsed: 0,
  ckptBytesWritten: 327680
}
```

```console
$ mongosh --quiet /data/load.js
$ ls -l /data/db/journal
total 306796
-rw------- 1 mongod mongod 104605952 Sep 27 21:46 WiredTigerLog.0000000001
-rw------- 1 mongod mongod 104690048 Sep 27 21:46 WiredTigerLog.0000000002
-rw------- 1 mongod mongod 104857600 Sep 27 21:46 WiredTigerLog.0000000003
```

```mongosh
test> logstat()
{
  logBytesWritten: 224924160,
  logSyncs: 165,
  maxLogFileSize: 104857600,
  preallocUsed: 2,
  ckptBytesWritten: 327680
}
```

- 저널에 약 225MB(`logBytesWritten` 224924160)가 쓰였고, 로그 파일이 3개로 늘었습니다. 미리 잡아 둔 파일을 2개 썼습니다(`preallocUsed: 2`). 1번과 2번 파일이 100MB보다 조금 작은 것은, 다 쓴 로그 파일을 닫을 때 마지막으로 쓴 위치 뒤의 빈 부분을 잘라 내기 때문입니다([`conn_log.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/conn/conn_log.c#L652-L658)).
- 아직 체크포인트 전이라 `ckptBytesWritten`은 그대로입니다. 이 순간 25만 개 문서는 캐시(와 eviction이 쓴 블록)와 저널에만 있고, 파일의 체크포인트에는 없습니다.

이제 `fsync` 명령으로 체크포인트를 바로 부릅니다. WiredTiger에서 `fsync`는 체크포인트를 강제하는 명령입니다([`flushAllFiles()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L1008-L1010), [`wiredtiger_session_cache.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_session_cache.cpp#L314-L320)).

```mongosh
test> db.adminCommand({fsync: 1})
{ numFiles: 1, ok: 1 }
test> logstat()
{
  logBytesWritten: 224926848,
  logSyncs: 170,
  maxLogFileSize: 104857600,
  preallocUsed: 2,
  ckptBytesWritten: 249569280
}
```

```console
$ ls -l /data/db/journal
total 204800
-rw------- 1 mongod mongod 104857600 Sep 27 21:46 WiredTigerLog.0000000003
-rw------- 1 mongod mongod 104857600 Sep 27 21:46 WiredTigerPreplog.0000000003
```

- 체크포인트 한 번에 데이터 파일로 약 250MB(327680 → 249569280)가 쓰였습니다. 같은 데이터가 저널에 한 번(snappy로 압축된 로그 레코드로), 체크포인트로 데이터 파일에 또 한 번 쓰인 것입니다.
- 체크포인트 뒤 2초 안에 1번과 2번 로그 파일이 지워졌습니다. 그 안의 레코드는 모두 새 체크포인트 앞이라 복구에 필요 없기 때문입니다. 지금 쓰는 3번과, 다음을 위해 새로 잡은 `WiredTigerPreplog.0000000003`만 남았습니다.

#### 레플리카셋에서는 사용자 컬렉션을 저널에 쓰지 않는다

여기까지는 standalone의 동작입니다. 레플리카셋에서는 사용자 컬렉션의 변경을 저널에 쓰지 않습니다. 멤버 하나짜리 레플리카셋을 따로 띄워 테이블 설정을 봅니다.

```mongosh
test> rs.initiate().ok
1
test> db.acct.insertOne({_id: 1, balance: 100}).acknowledged
true
test> db.acct.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
log=(enabled=false)
test> db.getSiblingDB("local").oplog.rs.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
log=(enabled=true)
test> db.getSiblingDB("local").system.replset.stats().wiredTiger.creationString.match(/log=\([^)]*\)/)[0]
log=(enabled=true)
```

사용자 컬렉션 `acct`는 `log=(enabled=false)`이고, `local` 데이터베이스의 oplog와 레플리카셋 설정은 `log=(enabled=true)`입니다. 레플리카셋이면 복제되는 컬렉션은 테이블 로깅을 끕니다([`WiredTigerUtil::useTableLogging()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp#L1056-L1079), 설정은 [`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L695-L699)). 모든 쓰기는 oplog에도 기록되므로, 비정상 종료 뒤에는 마지막 stable 체크포인트를 열고 **oplog를 다시 적용**해 사용자 데이터를 복구합니다. 같은 변경을 저널과 oplog에 두 번 쓰지 않는 셈입니다. 이 경로는 [5편](/posts/mongodb/05-oplog-and-replication/)에서 다룹니다. 이 글의 나머지는 standalone 기준입니다.

## j 옵션: 응답 전에 저널 fsync를 기다리는가

write concern의 `j`는 "응답하기 전에 이 쓰기가 저널에서 fsync될 때까지 기다리라"는 뜻입니다. `j:true`인 `w:1` 쓰기는 JournalFlusher에게 지금 flush하라고 요청하고, 그 flush가 끝날 때까지 기다립니다([`write_concern.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp#L360-L377)). `j`를 주지 않은 `w:1` 쓰기는 `SyncMode::NONE`이 되어 기다리지 않습니다([`replication_coordinator_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L6557-L6562)). 이때 쓰기는 로그 버퍼에 들어간 채로 응답을 받고, 다음 JournalFlusher 차례(최대 100ms 뒤)에 디스크에 닿습니다. 아래 그림이 이 과정입니다.

{{< diagram src="/diagrams/mongo-write-durability.html" title="쓰기 한 건이 디스크에 닿기까지" height="700" caption="j:false는 로그 버퍼에 들어간 뒤 바로 응답하고, j:true는 JournalFlusher의 fsync를 기다린 뒤 응답합니다. 데이터 파일의 체크포인트는 60초마다 따로 확정됩니다." >}}

#### log sync 횟수로 본 j:true와 j:false

`serverStatus().wiredTiger.log`의 `log sync operations`는 로그 파일을 fsync한 횟수입니다. 아무것도 쓰지 않을 때, `j:false`로 계속 쓸 때, `j:false`와 `j:true`로 500건씩 몰아 쓸 때 이 값이 얼마나 느는지 봅니다.

```mongosh
test> function syncs() { return db.serverStatus().wiredTiger.log["log sync operations"]; }
[Function: syncs]
test> let a = syncs(); sleep(5000); "idle 5s: log syncs +" + (syncs() - a)
idle 5s: log syncs +0
test> a = syncs(); let t = Date.now(), n = 0; while (Date.now() - t < 5000) { db.jt.insertOne({n: n++}, {writeConcern: {w: 1, j: false}}); sleep(10); } n + " inserts (j:false) in 5s: log syncs +" + (syncs() - a)
324 inserts (j:false) in 5s: log syncs +50
test> a = syncs(); t = Date.now(); for (let i = 0; i < 500; i++) db.jt.insertOne({i: i}, {writeConcern: {w: 1, j: false}}); "500 inserts j:false: " + (Date.now() - t) + " ms, log syncs +" + (syncs() - a)
500 inserts j:false: 145 ms, log syncs +2
test> a = syncs(); t = Date.now(); for (let i = 0; i < 500; i++) db.jt.insertOne({i: i}, {writeConcern: {w: 1, j: true}}); "500 inserts j:true: " + (Date.now() - t) + " ms, log syncs +" + (syncs() - a)
500 inserts j:true: 174 ms, log syncs +500
```

- 아무것도 쓰지 않은 5초 동안 fsync는 0번입니다. JournalFlusher는 100ms마다 깨어나지만 새 레코드가 없으면 fsync하지 않습니다.
- `j:false`로 10ms마다 쓰면 5초에 fsync가 50번, 즉 **100ms에 한 번**입니다. 쓰기 324건이 50번의 fsync에 묶여 디스크에 닿았습니다. 이것이 `journalCommitInterval`의 뜻입니다.
- `j:false` 500건은 145ms 동안 fsync가 2번뿐이고, `j:true` 500건은 **쓰기마다 한 번씩 500번** fsync했습니다. 쓰기가 하나씩 차례로 들어와서 fsync를 묶을 다른 쓰기가 없었기 때문입니다. 동시에 여러 연결이 `j:true`로 쓰면 한 번의 fsync가 그 사이에 들어온 쓰기를 함께 처리합니다.
- 시간은 145ms와 174ms로 차이가 작습니다. 이 실습 환경(Docker Desktop VM)의 fsync가 매우 빠르기 때문으로, 실제 디스크에서는 fsync 한 번이 수 ms가 걸리기도 합니다. 여러 실습이 함께 돈 환경이라 이 시간은 이 실행 안에서의 비교로만 봐야 합니다.

`journalCommitInterval`을 500ms로 늘리면 fsync 간격도 그대로 늘어납니다.

```mongosh
test> db.adminCommand({setParameter: 1, journalCommitInterval: 500})
{ was: 100, ok: 1 }
test> a = syncs(); t = Date.now(); n = 0; while (Date.now() - t < 5000) { db.jt.insertOne({n: n++}, {writeConcern: {w: 1, j: false}}); sleep(10); } n + " inserts (j:false, journalCommitInterval 500) in 5s: log syncs +" + (syncs() - a)
332 inserts (j:false, journalCommitInterval 500) in 5s: log syncs +10
test> db.adminCommand({setParameter: 1, journalCommitInterval: 100})
{ was: 500, ok: 1 }
```

같은 쓰기에 fsync가 10번, 500ms에 한 번입니다. 간격을 늘리면 fsync는 줄지만, `j:false` 쓰기가 응답을 받은 뒤 디스크에 닿지 않은 채 머무는 시간이 그만큼 길어집니다.

## 비정상 종료와 복구

mongod를 다시 띄울 때 WiredTiger는 `wiredtiger_open()` 안에서 복구를 합니다([`__wt_txn_recover()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_recover.c#L899)).

1. turtle 파일에서 메타데이터의 마지막 체크포인트를 열고, 그 체크포인트가 시작된 로그 위치(`ckpt_lsn`)를 얻습니다.
2. 그 위치부터 로그를 읽어 먼저 메타데이터에 대한 레코드를 적용하고([`txn_recover.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_recover.c#L1006-L1016)), 그다음 모든 테이블의 레코드를 적용합니다(`Main recovery loop`, [`txn_recover.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_recover.c#L1066-L1069)). 레코드마다 그 테이블의 체크포인트 LSN보다 뒤인 것만 적용합니다([`txn_recover.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_recover.c#L80)).
3. 타임스탬프를 쓰는 테이블은 stable timestamp로 되돌리고(rollback to stable, standalone에서는 할 일이 없음), 체크포인트를 한 번 해서 복구 결과를 확정합니다.

mongod 쪽에서는 `mongod.lock`이 비어 있지 않으면 비정상 종료로 판단하고 경고를 남깁니다([`storage_engine_init.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_engine_init.cpp#L306), [`wiredtiger_init.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_init.cpp#L88-L89)).

#### 체크포인트 뒤에 쓰고 kill -9

컬렉션 `acct`에 문서 1000개(balance 100)를 넣고 `fsync`로 체크포인트를 합니다. 그 뒤에 `j:true`로 3건(balance 200)을 넣고 한 건을 고칩니다.

```mongosh
test> db.acct.insertMany(Array.from({length: 1000}, (_, i) => ({_id: i, balance: 100}))).insertedIds[999]
999
test> db.adminCommand({fsync: 1})
{ numFiles: 1, ok: 1 }
test> for (let i = 1000; i < 1003; i++) db.acct.insertOne({_id: i, balance: 200}, {writeConcern: {w: 1, j: true}}); db.acct.countDocuments()
1003
test> db.acct.updateOne({_id: 1}, {$inc: {balance: 5}}, {writeConcern: {w: 1, j: true}})
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
```

이어서 `j:false`로 100건(balance 300)을 넣고, 그 mongosh가 끝나자마자 mongod를 `kill -9`로 죽입니다. 죽은 직후의 dbPath를 복사해 두고 들여다봅니다.

```console
$ mongosh --quiet --eval 'for (let i = 2000; i < 2100; i++) db.acct.insertOne({_id: i, balance: 300}, {writeConcern: {w: 1, j: false}}); print(db.acct.countDocuments())' && kill -9 $(pgrep -x mongod)
1103
$ sleep 1; pgrep -x mongod || echo "mongod is gone"
mongod is gone
$ cp -a /data/db /tmp/crash-copy
```

`j:false` 100건은 모두 성공 응답을 받았고, 죽기 직전의 `countDocuments()`는 1103입니다.

#### 파일에는 마지막 체크포인트까지만 있다

복사본을 `wt`로 읽기 전용(`-r`)으로 엽니다. `wt`는 저널 경로를 모르므로 로그를 적용하지 않고, 파일에 있는 체크포인트만 봅니다.

```console
$ wt -r -h /tmp/crash-copy list -v file:collection-13-4293686799854559489.wt | tr ',' '\n' | grep -E '^(id|checkpoint)='
id=17
checkpoint=(WiredTigerCheckpoint.1=(addr="018281e47f2f0c1a8381e4ebfdf67c8481e4bdc8df7b808080e23fc0dfc0"
$ wt -r -h /tmp/crash-copy list -c file:collection-13-4293686799854559489.wt
file:collection-13-4293686799854559489.wt
	 WiredTigerCheckpoint.1: Sun Sep 27 21:46:26 2026 (size 12 KB)
		file-size: 24 KB, checkpoint-size: 8 KB

		          offset, size, checksum
		root    : 12288, 4096, 2133797978 (0x7f2f2c5a)
		alloc   : 16384, 4096, 3959297724 (0xebfe16bc)
		discard : 0, 0, 0 (0)
		avail   : 20480, 4096, 3184066491 (0xbdc8ffbb)
$ wt -r -h /tmp/crash-copy dump table:collection-13-4293686799854559489 | sed -n '/^Data/,$p' | sed -n '2~2p' | wc -l
1000
```

- 메타데이터에 적힌 `acct` 컬렉션 파일의 설정에는 WiredTiger 안의 파일 번호(`id=17`)와 체크포인트 `WiredTigerCheckpoint.1`의 root 주소(`addr`)가 있습니다. 메타데이터가 곧 "이 파일의 체크포인트는 여기"라는 기록입니다.
- `list -c`는 그 체크포인트의 내용입니다. root 페이지의 위치 외에, 이 체크포인트가 할당한 블록(`alloc`), 버린 블록(`discard`), 쓸 수 있는 빈 자리(`avail`)의 목록이 각각 블록 하나로 저장되어 있습니다. [앞에서](#체크포인트-파일-안의-일관된-스냅샷) 본 "새 체크포인트가 확정된 뒤에야 옛 블록을 재사용한다"를 이 목록으로 관리합니다.
- 체크포인트 기준으로 덤프하면 문서가 **1000개**입니다. 체크포인트 뒤에 넣은 `j:true` 3건도, `j:false` 100건도 파일에는 없습니다. 이 파일만으로 복구하면 체크포인트 시점으로 돌아갑니다.

#### 저널에는 그 뒤가 있다

같은 복사본의 저널을 `wt printlog`로 읽습니다. `printlog`는 로그를 dbPath에서 찾으므로 복사본의 로그 파일을 dbPath로 옮기고, 로그 레코드가 snappy로 압축되어 있으니 압축 방식을 `WiredTiger.config`에 적어 줍니다. 커밋 레코드와 체크포인트 레코드만 골라, 레코드마다 어느 파일(fileid)에 몇 번 쓰는지로 줄였습니다.

```console
$ mv /tmp/crash-copy/journal/WiredTigerLog.* /tmp/crash-copy/
$ echo 'log=(compressor=snappy)' > /tmp/crash-copy/WiredTiger.config
$ wt -h /tmp/crash-copy printlog -u > /tmp/printlog.json
$ jq -c '.[] | select(.type == "checkpoint" or .type == "commit") | {lsn, type, txnid, ops: ([.ops[]? | "\(.optype) fileid=\(.fileid)"] | group_by(.) | map("\(.[0]) x\(length)"))}' /tmp/printlog.json | tail -8
{"lsn":[3,15858048],"type":"commit","txnid":2856,"ops":["row_put fileid=17 x500","row_put fileid=18 x500"]}
{"lsn":[3,15865088],"type":"commit","txnid":2857,"ops":["row_put fileid=2 x3"]}
{"lsn":[3,15865472],"type":"commit","txnid":2858,"ops":["row_put fileid=0 x8"]}
{"lsn":[3,15867648],"type":"checkpoint","txnid":null,"ops":[]}
{"lsn":[3,15867776],"type":"commit","txnid":2859,"ops":["row_put fileid=17 x1","row_put fileid=18 x1"]}
{"lsn":[3,15867904],"type":"commit","txnid":2860,"ops":["row_put fileid=17 x1","row_put fileid=18 x1"]}
{"lsn":[3,15868032],"type":"commit","txnid":2861,"ops":["row_put fileid=17 x1","row_put fileid=18 x1"]}
{"lsn":[3,15868160],"type":"commit","txnid":2862,"ops":["row_put fileid=17 x1"]}
$ wt -r -h /tmp/crash-copy list -v file:index-14-4293686799854559489.wt | tr ',' '\n' | grep -E '^id='
id=18
```

fileid 17은 `acct` 컬렉션, 18은 그 `_id` 인덱스(`index-14`)입니다. 0은 WiredTiger 메타데이터 테이블입니다. 레코드를 순서대로 읽으면 이렇습니다.

- `txnid 2856`: `insertMany` 1000건 가운데 뒤의 500건입니다. `insertMany`는 500건씩 묶어 한 트랜잭션으로 넣으므로([`write_ops_exec.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/ops/write_ops_exec.cpp#L1220), 기본값 [`storage_options.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_options.h#L148)) 컬렉션에 500번, `_id` 인덱스에 500번 `row_put`이 한 레코드에 들어 있습니다. 로그 레코드는 페이지가 아니라 **키와 값**이고, 커밋할 때 트랜잭션 하나가 레코드 하나가 됩니다.
- `txnid 2858`의 메타데이터 쓰기 8번과 `checkpoint` 레코드는 `fsync`가 부른 체크포인트입니다.
- 체크포인트 뒤의 `txnid 2859`~`2861`은 `j:true`로 넣은 3건입니다. 각각 컬렉션과 `_id` 인덱스에 한 번씩 씁니다. `txnid 2862`는 `balance`를 고친 `updateOne`으로, 인덱스 키가 바뀌지 않아 컬렉션에만 씁니다.
- `j:false`로 넣은 100건은 **저널에 없습니다.** 로그의 마지막 레코드가 `updateOne`입니다.

#### 재기동: 마지막 체크포인트 + 저널

원래 dbPath로 mongod를 다시 띄우고 복구 로그를 봅니다. WiredTiger의 복구 메시지는 `WTRECOV` 컴포넌트로 남습니다.

```console
$ mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork  | grep -E 'forked|ERROR'
forked process: 626
$ jq -c 'select(.id == 22271 or .id == 22302 or .id == 4795906 or .c == "WTRECOV") | {t: .t."$date", c, msg: (.attr.message.msg // .msg), attr: (if .c == "WTRECOV" then null else .attr end)} | del(..|nulls)' /data/mongod.log | sed -n '/unclean shutdown/,$p'
{"t":"2026-09-27T21:46:29.681+00:00","c":"STORAGE","msg":"Detected unclean shutdown - Lock file is not empty","attr":{"lockFile":"/data/db/mongod.lock"}}
{"t":"2026-09-27T21:46:29.681+00:00","c":"STORAGE","msg":"Recovering data from the last clean checkpoint."}
{"t":"2026-09-27T21:46:29.863+00:00","c":"WTRECOV","msg":"Recovering log 3 through 4"}
{"t":"2026-09-27T21:46:29.870+00:00","c":"WTRECOV","msg":"Recovering log 4 through 4"}
{"t":"2026-09-27T21:46:29.881+00:00","c":"WTRECOV","msg":"Main recovery loop: starting at 3/15865344 to 4/256"}
{"t":"2026-09-27T21:46:29.881+00:00","c":"WTRECOV","msg":"Recovering log 3 through 4"}
{"t":"2026-09-27T21:46:29.889+00:00","c":"WTRECOV","msg":"Recovering log 4 through 4"}
{"t":"2026-09-27T21:46:29.898+00:00","c":"WTRECOV","msg":"recovery log replay has successfully finished and ran for 35 milliseconds"}
{"t":"2026-09-27T21:46:29.898+00:00","c":"WTRECOV","msg":"Set global recovery timestamp: (0, 0)"}
{"t":"2026-09-27T21:46:29.898+00:00","c":"WTRECOV","msg":"Set global oldest timestamp: (0, 0)"}
{"t":"2026-09-27T21:46:29.899+00:00","c":"WTRECOV","msg":"recovery rollback to stable has successfully finished and ran for 0 milliseconds"}
{"t":"2026-09-27T21:46:29.902+00:00","c":"WTRECOV","msg":"recovery checkpoint has successfully finished and ran for 2 milliseconds"}
{"t":"2026-09-27T21:46:29.902+00:00","c":"WTRECOV","msg":"recovery was completed successfully and took 39ms, including 35ms for the log replay, 0ms for the rollback to stable, and 2ms for the checkpoint."}
{"t":"2026-09-27T21:46:29.902+00:00","c":"WTRECOV","msg":"recovery was completed successfully and took 39ms, including 35ms for the log replay, 0ms for the rollback to stable, and 2ms for the checkpoint."}
{"t":"2026-09-27T21:46:29.902+00:00","c":"STORAGE","msg":"WiredTiger opened","attr":{"durationMillis":221}}
```

```mongosh
test> db.acct.countDocuments({balance: 100}) + " / " + db.acct.countDocuments({balance: 200}) + " / " + db.acct.countDocuments({balance: 300})
999 / 3 / 0
test> db.acct.findOne({_id: 1})
{ _id: 1, balance: 105 }
```

- mongod가 `mongod.lock`이 비어 있지 않은 것을 보고 비정상 종료를 알아챘습니다(`Detected unclean shutdown`).
- WiredTiger는 `Main recovery loop: starting at 3/15865344`, 즉 로그 파일 3번의 15865344 위치부터 재생했습니다. 앞의 `printlog`에서 체크포인트 레코드는 15867648에 있었는데, 재생은 그보다 앞에서 시작합니다. 체크포인트 레코드에 적힌 `ckpt_lsn`은 체크포인트를 **시작한** 위치이고, 체크포인트가 도는 동안 커밋된 변경도 있을 수 있기 때문입니다. 이미 체크포인트에 들어간 변경은 테이블별 체크포인트 LSN과 비교해 건너뜁니다.
- 재생은 35ms, 복구 전체는 39ms가 걸렸습니다. 재생할 것이 체크포인트 뒤의 레코드 몇 개뿐이었기 때문입니다. 마지막에 복구 체크포인트를 한 번 하고 `WiredTiger opened`로 끝났습니다.
- 복구 뒤 데이터는 balance 100이 999건(1건은 105로 바뀜), 200이 3건, **300이 0건**입니다. 체크포인트(1000건) 위에 저널의 `j:true` 쓰기 4건이 재생되었고, 저널에 없던 `j:false` 100건은 사라졌습니다.

`j:false` 100건은 클라이언트가 성공 응답을 받았고, 죽기 직전의 mongod에서는 조회도 되었습니다. 그런데도 사라진 것은 레코드가 아직 **mongod 프로세스 메모리의 로그 버퍼**에 있었기 때문입니다. 커밋은 레코드를 버퍼에 넣고 끝나고, 파일에 `write()`하는 것은 log server가 깨어날 때(50ms~1초 간격)나 JournalFlusher가 fsync할 때(100ms마다)입니다. 100건을 넣고 곧바로 죽였더니 그 틈에 걸린 것입니다. `write()`까지 된 레코드라면 프로세스가 죽어도 운영체제 페이지 캐시에 남아 살아남지만, 서버 전원이 나가면 fsync하지 않은 레코드는 그것도 장담할 수 없습니다. 이 실습에서는 운영체제 장애를 재현하지 않았습니다. 어느 쪽이든 `j:false` 쓰기는 **응답을 받은 뒤 최대 `journalCommitInterval`만큼의 쓰기를 잃을 수 있다**는 것이 이 실험의 결론입니다. 반대로 `j:true` 쓰기는 fsync가 끝난 뒤에 응답했으므로 모두 복구되었습니다.

## PostgreSQL의 WAL, 체크포인트와 비교

PostgreSQL 연재의 [WAL](/posts/postgresql/07-wal/)과 [체크포인트와 장애 복구](/posts/postgresql/08-checkpoint-and-recovery/)와 나란히 놓으면 차이가 분명합니다.

| | PostgreSQL | WiredTiger (MongoDB standalone) |
|---|---|---|
| 로그의 내용 | 페이지에 대한 변경(블록 번호와 그 안의 변경) | 트랜잭션이 테이블에 쓴 키와 값 |
| 로그를 쓰는 때 | 페이지를 고칠 때마다 WAL 레코드를 만들고, 커밋할 때 flush | 커밋할 때 트랜잭션 하나를 레코드 하나로. 커밋 안 된 변경은 로그에 없음 |
| 데이터 파일 | 8kB 페이지를 제자리에 덮어씀 | 빈 자리에 새 블록을 쓰고, 옛 체크포인트의 블록은 새 체크포인트가 확정된 뒤 재사용 |
| full page write | 필요. 덮어쓰다 만 페이지(torn page)를 되살리려고 체크포인트 뒤 첫 변경 때 페이지 전체를 WAL에 씀 | 없음. 체크포인트가 가리키는 블록은 덮어쓰지 않으므로 반쯤 쓴 블록이 체크포인트에 섞이지 않음 |
| 체크포인트 | REDO 시작점을 정하고 그때까지의 dirty 페이지를 씀. 데이터 파일은 체크포인트 사이에도 계속 바뀜 | 체크포인트 자체가 모든 테이블의 일관된 스냅샷. turtle 파일 교체로 확정 |
| 복구 | REDO 위치부터 WAL을 재생해 페이지를 고침 | 마지막 체크포인트를 열고, `ckpt_lsn`부터 커밋 레코드를 키와 값으로 다시 적용 |
| 로그 보존 | 체크포인트의 REDO 위치 이전 WAL을 지우거나 재활용 | 체크포인트 LSN 이전의 로그 파일을 지움 |

PostgreSQL에서는 체크포인트가 "여기부터 재생하면 된다"는 표시이고 데이터 파일은 체크포인트 사이에도 계속 덮어쓰입니다. 그래서 복구의 기준은 WAL이고, 페이지가 찢어진 경우를 대비한 full page write가 필요합니다. WiredTiger는 파일 안의 체크포인트가 그 자체로 완결된 데이터베이스이고, eviction이 체크포인트 사이에 dirty 페이지를 써도 새 블록에 쓸 뿐 체크포인트의 블록은 건드리지 않습니다. 저널은 체크포인트 **뒤**만 채우면 되므로, 커밋된 변경의 키와 값만 담아도 충분합니다.

## 운영에서는 이렇게 나타납니다

#### 체크포인트마다 쓰기 I/O가 몰린다

[앞의 실습](#250mb를-넣으면-저널-파일이-는다)에서 체크포인트 한 번이 250MB를 데이터 파일에 썼습니다. 쓰기가 많은 서버에서는 60초 동안 쌓인 dirty 페이지를 체크포인트가 한꺼번에 쓰므로, 디스크 쓰기 지표가 60초 주기로 튀는 모습이 보입니다. `serverStatus().wiredTiger.checkpoint`의 `most recent time (msecs)`와 `max time (msecs)`로 체크포인트 하나에 걸리는 시간을 보고, 이 값이 주기(60초)에 가까워지면 체크포인트가 끝나자마자 다음 체크포인트가 도는 셈이라 디스크가 쓰기 양을 감당하지 못하고 있다는 뜻입니다. 이때 dirty 페이지가 캐시에 오래 남으면 [1편](/posts/mongodb/01-wiredtiger-architecture/#eviction-캐시에서-페이지를-내보내기)의 dirty trigger(20%)에 닿아 요청 스레드까지 eviction을 하게 됩니다. `syncdelay`를 바꾸는 것은 권장되지 않는 설정이고([`storage_options.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_options.h#L106-L111)), 보통은 디스크의 쓰기 성능을 먼저 봅니다.

#### 저널은 별도 디스크에 둘 수 있다

`j:true` 쓰기와 JournalFlusher의 fsync는 저널 디렉터리의 fsync 지연에 그대로 묶입니다. 체크포인트의 대량 쓰기와 저널 fsync가 같은 디스크에서 경쟁하면 체크포인트 동안 `j:true` 쓰기가 느려질 수 있습니다. 이때 `journal` 디렉터리를 다른 디스크에 심볼릭 링크로 두는 방법이 있습니다. 다만 스냅샷 방식 백업은 데이터 파일과 저널을 같은 순간에 떠야 하므로, 디스크를 나누면 백업 절차도 함께 확인해야 합니다.

#### 저널 파일이 줄지 않는다면

로그 파일은 체크포인트가 끝나야 지워집니다. 쓰기가 많은 동안 `journal` 디렉터리에 100MB 파일이 여러 개 생기는 것은 정상이고, 다음 체크포인트 뒤에 줄어듭니다. 저널 파일이 계속 쌓이기만 한다면 체크포인트가 끝나지 못하고 있는지(`most recent time`, 로그의 `saving checkpoint snapshot` 시각), 백업 커서가 열려 있어 로그 삭제가 막혀 있는지를 봅니다.

#### 비정상 종료 뒤 재기동 시간

standalone의 복구는 마지막 체크포인트 뒤의 저널만 재생하므로, 재생할 양은 많아야 체크포인트 주기 동안의 쓰기입니다. 실습에서는 39ms였지만, 쓰기가 많은 서버라면 1분치 저널을 재생해야 합니다. 체크포인트가 느려 주기가 길어진 상태에서 죽으면 재생할 양도 그만큼 늘어납니다. 재기동 로그에서 `Main recovery loop`와 `recovery was completed successfully and took ...` 사이의 시간이 복구 시간입니다. 레플리카셋 멤버는 여기에 oplog 재적용 시간이 더해집니다([5편](/posts/mongodb/05-oplog-and-replication/)).

#### j 옵션을 고르는 기준

`w:1`에 `j`를 주지 않으면 응답은 로그 버퍼에 들어간 순간에 옵니다. 실습처럼 mongod가 죽으면 응답을 받은 쓰기 가운데 최대 `journalCommitInterval`(100ms)만큼이 사라질 수 있습니다. 한 건도 잃으면 안 되는 쓰기라면 `j:true`를 써야 하고, 대가는 쓰기마다 fsync를 기다리는 지연입니다. 레플리카셋에서 `w:"majority"`는 `writeConcernMajorityJournalDefault`(기본 true)에 따라 저널까지 기다리므로 `j`를 따로 줄 필요가 없습니다. 복제와 함께 본 write concern의 보장은 [8편](/posts/mongodb/08-read-write-concern/)에서 정리합니다.

## 정리

- WiredTiger의 **체크포인트**는 모든 테이블의 일관된 스냅샷입니다. dirty 페이지를 새 블록에 쓰고, 메타데이터와 turtle 파일을 바꿔 확정합니다. mongod의 Checkpointer가 앞 체크포인트가 끝난 뒤 `syncdelay`(60초)마다 부릅니다.
- **저널**은 WiredTiger의 로그로, 커밋마다 트랜잭션이 쓴 키와 값을 레코드로 남깁니다. 100MB 파일을 미리 잡아 쓰고, 체크포인트 뒤 필요 없어진 파일은 지웁니다.
- 로그 레코드는 커밋 때 버퍼에 들어가고, JournalFlusher가 `journalCommitInterval`(100ms)마다 fsync합니다. `j:true`는 그 fsync를 바로 요청하고 기다립니다.
- 비정상 종료 뒤에는 마지막 체크포인트를 열고 `ckpt_lsn`부터 저널을 재생합니다. 실습에서 `j:true` 쓰기는 모두 복구되었고, 죽기 직전의 `j:false` 쓰기 100건은 저널에 닿지 못해 사라졌습니다.
- 레플리카셋에서는 사용자 컬렉션을 저널에 쓰지 않고, oplog로 복구합니다.
- PostgreSQL과 달리 데이터 파일을 제자리에 덮어쓰지 않으므로 full page write가 없고, 저널은 체크포인트 뒤의 논리적 변경만 담습니다.

다음 글에서는 캐시의 페이지에 달린 update 목록으로 돌아가, WiredTiger가 여러 버전을 어떻게 관리하는지 **MVCC와 스냅샷**을 봅니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/db/storage/checkpointer.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/checkpointer.cpp): 체크포인트 스레드
- [src/mongo/db/storage/control/journal_flusher.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/control/journal_flusher.cpp): 저널 fsync 스레드
- [src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp): 로그 설정, `_checkpoint`
- [src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp): `useTableLogging`
- [src/mongo/db/write_concern.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/write_concern.cpp): `j` 옵션 처리
- [src/third_party/wiredtiger/src/txn/txn_ckpt.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_ckpt.c), [src/block/block_ckpt.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/block/block_ckpt.c), [src/meta/meta_turtle.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/meta/meta_turtle.c): 체크포인트, 블록 재사용, turtle
- [src/third_party/wiredtiger/src/txn/txn_log.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_log.c), [src/conn/conn_log.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/conn/conn_log.c): 커밋 로그 레코드, log server, 로그 파일 삭제
- [src/third_party/wiredtiger/src/txn/txn_recover.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/txn/txn_recover.c): 복구

MongoDB 8.0 공식 문서

- [Journaling](https://www.mongodb.com/docs/v8.0/core/journaling/)
- [Write Concern](https://www.mongodb.com/docs/v8.0/reference/write-concern/)
- [WiredTiger Storage Engine](https://www.mongodb.com/docs/v8.0/core/wiredtiger/)
