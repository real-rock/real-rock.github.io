---
title: "MongoDB 인터널 1: WiredTiger 스토리지 엔진 구조와 캐시"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "WiredTiger", "캐시", "eviction", "B-tree"]
weight: 1
summary: "MongoDB의 데이터는 실제로 어디에 어떻게 저장되고, 메모리에서는 어떻게 관리되는가"
description: "스토리지 엔진 API, dbPath 파일과 ident, WiredTiger B-tree와 압축, 캐시 크기와 eviction"
---

## 개요

MongoDB에 문서를 넣으면 그 문서는 결국 디스크의 어떤 파일 어딘가에 들어갑니다. 그 사이를 맡는 것이 **스토리지 엔진**이고, MongoDB 3.2부터 기본 엔진은 **WiredTiger**입니다. WiredTiger는 MongoDB가 인수한 별도의 키-값 저장 라이브러리로, mongod 프로세스 안에 링크되어 돌아갑니다. mongod의 나머지 부분(쿼리 실행, 인덱스 관리, 복제)은 WiredTiger에 "이 키에 이 값을 넣어라", "이 키부터 차례로 읽어라"라고 요청할 뿐이고, 파일 형식, 캐시, 트랜잭션, 체크포인트, 저널은 모두 WiredTiger가 처리합니다.

이 연재는 그 WiredTiger부터 시작합니다. 뒤의 편에서 다룰 체크포인트와 저널([2편](/posts/mongodb/02-checkpoint-and-journal/)), 스냅샷과 history store([3편](/posts/mongodb/03-mvcc-and-snapshot/)), 인덱스와 쿼리 플래너([4편](/posts/mongodb/04-index-and-query-planner/))가 모두 여기서 보는 구조 위에 있습니다.

이 글에서 답할 질문은 다음과 같습니다.

- mongod 안에서 WiredTiger는 어디에 있고, 둘은 어떤 인터페이스로 이야기하는가
- dbPath의 파일들은 각각 무엇이고, 컬렉션 이름은 어떻게 파일과 짝지어지는가
- 컬렉션과 인덱스는 WiredTiger 안에서 어떤 키와 값으로 저장되는가
- 압축은 어디에서 일어나고, 메모리의 페이지와 디스크의 블록은 무엇이 다른가
- 캐시 크기는 어떻게 정해지고, 캐시가 차면 무슨 일이 일어나는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다.

## mongod 안에서 WiredTiger의 자리

mongod의 쿼리 계층은 WiredTiger를 직접 부르지 않습니다. 가운데에 **스토리지 엔진 API**라는 C++ 추상 클래스 몇 개가 있고, 쿼리 계층은 이 인터페이스만 압니다.

| 인터페이스 | 역할 | WiredTiger 구현 |
|---|---|---|
| [`KVEngine`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/kv/kv_engine.h#L56) | 엔진 전체. 테이블 만들기, 지우기, 체크포인트 | [`WiredTigerKVEngine`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.h#L204) |
| [`RecordStore`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/record_store.h#L315) | 컬렉션. RecordId → 문서(BSON) | [`WiredTigerRecordStore`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.h#L97) |
| [`SortedDataInterface`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/sorted_data_interface.h#L56) | 인덱스. 정렬된 키 → RecordId | [`WiredTigerIndex`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.h#L91) |
| `RecoveryUnit` | 한 작업의 트랜잭션 | `WiredTigerRecoveryUnit` |

WiredTiger 쪽 구현은 이 요청을 WiredTiger의 C API 호출로 바꿉니다. WiredTiger에서 연결 하나는 `WT_CONNECTION`, 작업하는 스레드마다 쓰는 문맥은 `WT_SESSION`, 테이블 하나를 읽고 쓰는 손잡이는 `WT_CURSOR`입니다. 예를 들어 컬렉션에 문서를 넣는 [`WiredTigerRecordStore::_insertRecords()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L1140)는 결국 커서에 키(RecordId)와 값(BSON)을 넣고 `insert`를 부릅니다([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L1251-L1254)). 한 작업의 쓰기들은 `WiredTigerRecoveryUnit`이 연 WiredTiger 트랜잭션([`_txnOpen()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_recovery_unit.cpp#L498)) 안에서 일어나고, 트랜잭션이 커밋될 때 한꺼번에 보이게 됩니다. 트랜잭션과 스냅샷은 [3편](/posts/mongodb/03-mvcc-and-snapshot/)에서 자세히 봅니다.

{{< diagram src="/diagrams/mongo-storage-layers.html" title="mongod 안의 WiredTiger" height="620" caption="쿼리 계층은 스토리지 엔진 API만 알고, WiredTiger 구현이 이를 커서 호출로 바꿉니다. 커서가 다루는 것은 캐시의 B-tree 페이지이고, 파일에는 압축된 블록만 갑니다." >}}

그림의 아래 줄이 이 글의 나머지 내용입니다. 커서는 파일을 직접 읽고 쓰지 않습니다. WiredTiger **캐시**에 올라온 B-tree 페이지를 찾아 읽거나 고치고, 페이지가 캐시에 없으면 그때 파일에서 읽어 옵니다. 캐시의 페이지를 파일에 쓰는 것은 나중에 eviction이나 체크포인트가 합니다.

#### mongod가 WiredTiger를 여는 설정

mongod는 시작할 때 설정 문자열 하나를 만들어 `wiredtiger_open()`을 부르고, 그 문자열을 `Opening WiredTiger` 로그로 남깁니다([`WiredTigerKVEngine` 생성자](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L514)). 메모리 제한이 없는 컨테이너에서 기본 설정으로 띄운 mongod의 로그입니다.

```console
$ jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log
create,cache_size=15508M,session_max=33000,eviction=(threads_min=4,threads_max=4),config_base=false,statistics=(fast),log=(enabled=true,remove=true,path=journal,compressor=snappy),builtin_extension_config=(zstd=(compression_level=6)),file_manager=(close_idle_time=600,close_scan_interval=10,close_handle_minimum=2000),statistics_log=(wait=0),json_output=(error,message),verbose=[recovery_progress:1,checkpoint_progress:1,compact_progress:1,backup:0,checkpoint:0,compact:0,evict:0,history_store:0,recovery:0,rts:0,salvage:0,tiered:0,timestamp:0,transaction:0,verify:0,log:0],prefetch=(available=true,default=false),
```

이 글과 다음 글에 나오는 설정이 거의 다 여기 있습니다.

- `cache_size=15508M`: WiredTiger 캐시 크기입니다. 이 값이 어떻게 나왔는지는 [아래](#캐시-크기는-어떻게-정해지는가)에서 계산해 봅니다.
- `eviction=(threads_min=4,threads_max=4)`: 캐시에서 페이지를 내보내는 eviction worker 스레드를 4개로 고정합니다([`wiredtiger_kv_engine.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L381-L383)). WiredTiger 자체의 기본값은 최소 1개, 최대 8개입니다([`api_data.py`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L649-L658)).
- `log=(enabled=true,remove=true,path=journal,compressor=snappy)`: WiredTiger의 로그가 곧 MongoDB의 **저널**입니다. `journal` 디렉터리에 쓰고, 필요 없어진 파일은 지우고, snappy로 압축합니다([`wiredtiger_kv_engine.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L409-L410)). [2편](/posts/mongodb/02-checkpoint-and-journal/)의 주제입니다.
- `statistics=(fast)`: `serverStatus`와 `collStats`의 `wiredTiger` 섹션이 이 통계입니다. `fast`는 트리 전체를 훑어야 하는 통계는 모으지 않는 모드입니다.
- `file_manager=(close_idle_time=600,...)`: 600초 동안 쓰지 않은 파일 핸들은 닫습니다. [운영 이야기](#운영에서는-이렇게-나타납니다)에서 다시 봅니다.
- `verbose=[...checkpoint_progress:1...]`: 체크포인트와 복구 진행 메시지를 로그에 남깁니다. 2편에서 이 메시지로 체크포인트 주기를 봅니다.

## dbPath: 컬렉션과 인덱스마다 파일이 하나씩

WiredTiger에서 테이블 하나는 파일 하나입니다. MongoDB는 컬렉션 하나를 테이블 하나로, 인덱스 하나를 또 다른 테이블 하나로 만듭니다. 그래서 컬렉션 하나에 인덱스가 둘이면 파일이 셋입니다.

#### 컬렉션과 인덱스를 만든 뒤의 dbPath

빈 dbPath로 mongod를 띄우고, `orders` 컬렉션에 문서 셋과 `item` 인덱스를 만듭니다.

```mongosh
test> db.orders.insertMany([{_id: 1, item: "apple", qty: 10}, {_id: 2, item: "banana", qty: 20}, {_id: 3, item: "cherry", qty: 30}])
{ acknowledged: true, insertedIds: { '0': 1, '1': 2, '2': 3 } }
test> db.orders.createIndex({item: 1})
item_1
```

```console
$ ls -l /data/db
total 104
-rw------- 1 mongod mongod    50 Sep 27 21:41 WiredTiger
-rw------- 1 mongod mongod    21 Sep 27 21:41 WiredTiger.lock
-rw------- 1 mongod mongod  1165 Sep 27 21:41 WiredTiger.turtle
-rw------- 1 mongod mongod  4096 Sep 27 21:41 WiredTiger.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 WiredTigerHS.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 _mdb_catalog.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 collection-0-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 collection-2-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 collection-4-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 collection-7-7164268511808313993.wt
drwx------ 2 mongod mongod  4096 Sep 27 21:41 diagnostic.data
-rw------- 1 mongod mongod  4096 Sep 27 21:41 index-1-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 index-3-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 index-5-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 index-6-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 index-8-7164268511808313993.wt
-rw------- 1 mongod mongod 20480 Sep 27 21:41 index-9-7164268511808313993.wt
-rw------- 1 mongod mongod  4096 Sep 27 21:41 internal-10-7164268511808313993.wt
drwx------ 2 mongod mongod  4096 Sep 27 21:41 journal
-rw------- 1 mongod mongod     3 Sep 27 21:41 mongod.lock
-rw------- 1 mongod mongod  4096 Sep 27 21:41 sizeStorer.wt
-rw------- 1 mongod mongod   114 Sep 27 21:41 storage.bson
$ ls -l /data/db/journal
total 204800
-rw------- 1 mongod mongod 104857600 Sep 27 21:41 WiredTigerLog.0000000001
-rw------- 1 mongod mongod 104857600 Sep 27 21:41 WiredTigerPreplog.0000000001
$ cat /data/db/WiredTiger
WiredTiger
WiredTiger 11.3.0: (November 16, 2023)
$ bsondump --quiet /data/db/storage.bson
{"storage":{"engine":"wiredTiger","options":{"directoryPerDB":false,"directoryForIndexes":false,"groupCollections":false}}}
$ cat /data/db/mongod.lock; echo; pgrep -x mongod
33

33
```

사용자가 만든 것은 컬렉션 하나와 인덱스 하나인데, 파일은 훨씬 많습니다. 하나씩 보면 다음과 같습니다.

| 파일 | 누가 쓰나 | 내용 |
|---|---|---|
| `collection-*.wt` | MongoDB | 컬렉션 하나. `admin.system.version`, `local.startup_log`, `config.system.sessions` 같은 내부 컬렉션도 각각 파일이 있음 |
| `index-*.wt` | MongoDB | 인덱스 하나. `_id` 인덱스도 파일 하나 |
| `_mdb_catalog.wt` | MongoDB | 컬렉션 이름과 옵션, 인덱스 정의, 그리고 각각의 **ident**(파일 이름) |
| `sizeStorer.wt` | MongoDB | 컬렉션마다 문서 수와 데이터 크기. `count()`를 매번 세지 않으려고 따로 저장([`WiredTigerSizeStorer::flush()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_size_storer.cpp#L139)) |
| `storage.bson` | MongoDB | 이 dbPath를 만든 엔진 이름과 옵션([`storage_engine_metadata.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/storage_engine_metadata.cpp#L80)). 다른 엔진으로 띄우는 실수를 막음 |
| `mongod.lock` | MongoDB | 실행 중인 mongod의 pid. 정상 종료하면 비워짐 |
| `WiredTiger.wt` | WiredTiger | WiredTiger의 **메타데이터** 테이블. 모든 테이블의 설정과 체크포인트 위치 |
| `WiredTiger.turtle` | WiredTiger | 메타데이터 테이블 자신의 설정과 체크포인트 위치. 복구가 여기서 시작 |
| `WiredTiger`, `WiredTiger.lock` | WiredTiger | 버전 문자열, 다른 프로세스가 같은 디렉터리를 여는 것을 막는 잠금 |
| `WiredTigerHS.wt` | WiredTiger | history store. 옛 버전의 값을 캐시 밖으로 내보낼 때 쓰는 테이블([3편](/posts/mongodb/03-mvcc-and-snapshot/)) |
| `journal/WiredTigerLog.*` | WiredTiger | 저널(WiredTiger 로그). 100MB짜리 파일로 미리 잡아 두고 씀([2편](/posts/mongodb/02-checkpoint-and-journal/)) |
| `diagnostic.data/` | MongoDB | FTDC. `serverStatus` 등을 주기적으로 모아 둔 진단 데이터 |

`internal-10-...wt`는 `createIndex`가 인덱스를 만드는 동안 들어오는 쓰기를 모아 두는 임시 테이블입니다([`IndexBuildInterceptor`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/index/index_build_interceptor.cpp#L95)). 빌드가 끝나면 지워져서, 뒤에서 `wt list`로 볼 때는 없습니다. `mongod.lock`에 적힌 33은 `pgrep`으로 찾은 mongod의 pid와 같습니다.

파일 이름(ident)은 `collection-<번호>-<난수>` 모양입니다. 번호는 mongod가 이번에 켜진 뒤 ident를 만들 때마다 1씩 늘고, 뒤의 난수는 mongod가 켜질 때 한 번 뽑습니다([`DurableCatalog::generateUniqueIdent()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/durable_catalog.cpp#L189-L200), [`_newRand()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/durable_catalog.cpp#L177-L179)). 그래서 mongod를 다시 켠 뒤에 만든 컬렉션은 난수 부분이 다른 파일 이름을 받습니다. 이름에 네임스페이스가 들어가지 않으므로 컬렉션 이름을 바꿔도(`renameCollection`) 파일은 그대로입니다.

## _mdb_catalog: 이름과 ident를 짝짓는 카탈로그

그렇다면 `test.orders`가 `collection-7-...`이라는 것은 어디에 적혀 있을까요. `_mdb_catalog.wt`입니다. 이것도 평범한 WiredTiger 테이블이고, 컬렉션마다 문서 하나가 들어 있습니다. 문서에는 네임스페이스(`ns`), 컬렉션 옵션과 인덱스 정의(`md`), 컬렉션의 ident(`ident`), 인덱스 이름별 ident(`idxIdent`)가 들어 있습니다([`durable_catalog.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/durable_catalog.cpp#L314-L335)). mongod는 시작할 때 이 테이블을 처음부터 끝까지 읽어 메모리에 카탈로그를 만듭니다([`DurableCatalog::init()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/durable_catalog.cpp#L202)).

#### $listCatalog로 본 카탈로그

`$listCatalog` 집계 단계는 이 카탈로그를 그대로 보여 줍니다.

```mongosh
test> db.getSiblingDB("admin").aggregate([{$listCatalog: {}}, {$project: {_id: 0, ns: 1, ident: 1, idxIdent: 1}}])
[
  {
    idxIdent: { _id_: 'index-1-7164268511808313993' },
    ns: 'admin.system.version',
    ident: 'collection-0-7164268511808313993'
  },
  {
    idxIdent: { _id_: 'index-3-7164268511808313993' },
    ns: 'local.startup_log',
    ident: 'collection-2-7164268511808313993'
  },
  {
    idxIdent: {
      _id_: 'index-5-7164268511808313993',
      lsidTTLIndex: 'index-6-7164268511808313993'
    },
    ns: 'config.system.sessions',
    ident: 'collection-4-7164268511808313993'
  },
  {
    idxIdent: {
      _id_: 'index-8-7164268511808313993',
      item_1: 'index-9-7164268511808313993'
    },
    ns: 'test.orders',
    ident: 'collection-7-7164268511808313993'
  }
]
test> db.orders.stats().wiredTiger.uri
statistics:table:collection-7-7164268511808313993
test> Object.entries(db.orders.stats({indexDetails: true}).indexDetails).map(([name, d]) => name + " -> " + d.uri)
[
  '_id_ -> statistics:table:index-8-7164268511808313993',
  'item_1 -> statistics:table:index-9-7164268511808313993'
]
```

- 앞의 `ls`에 있던 `collection-*`과 `index-*` 파일이 하나도 빠짐없이 네 컬렉션에 짝지어집니다. `test.orders`는 `collection-7`이고, 인덱스 `_id_`와 `item_1`은 `index-8`, `index-9`입니다.
- `collStats`의 `wiredTiger.uri`도 같은 ident를 알려 줍니다. `table:collection-7-...`이 WiredTiger 안의 테이블 이름이고, 파일은 그 뒤에 `.wt`를 붙인 것입니다.

카탈로그 자체도 WiredTiger 테이블이므로, WiredTiger에게 `_mdb_catalog`는 다른 컬렉션과 다를 것이 없습니다. "이 ident가 어떤 컬렉션인가"는 MongoDB만 아는 정보이고, WiredTiger의 메타데이터(`WiredTiger.wt`)에는 "이 테이블은 이런 설정의 B-tree이고 파일은 여기다"만 있습니다.

## 컬렉션은 RecordId를 키로 하는 B-tree

WiredTiger 테이블은 키와 값의 쌍을 키 순서로 정렬해 담는 **B-tree**입니다. 테이블을 만들 때 키와 값의 형식, 페이지 크기, 압축 방식을 정하고, MongoDB는 이 설정 문자열을 직접 만듭니다. 컬렉션은 [`WiredTigerRecordStore::generateCreateString()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L614), 인덱스는 [`WiredTigerIndex::generateCreateString()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L204)이 만듭니다. 만들 때 쓴 설정은 `collStats`의 `creationString`으로 볼 수 있습니다.

#### creationString: 컬렉션과 인덱스의 테이블 설정

`creationString`은 WiredTiger의 모든 설정 항목을 펼쳐 놓아서 길기 때문에, 필요한 항목만 골라 봅니다.

```mongosh
test> const pick = (cs) => cs.split(",").filter(kv => /^(type|key_format|value_format|block_compressor|internal_page_max|leaf_page_max|memory_page_max|split_pct|prefix_compression|log)=/.test(kv))
test> pick(db.orders.stats().wiredTiger.creationString)
[
  'block_compressor=snappy',
  'internal_page_max=4KB',
  'key_format=q',
  'leaf_page_max=32KB',
  'log=(enabled=true)',
  'memory_page_max=10m',
  'prefix_compression=false',
  'split_pct=90',
  'type=file',
  'value_format=u'
]
test> pick(db.orders.stats({indexDetails: true}).indexDetails.item_1.creationString)
[
  'block_compressor=',
  'internal_page_max=16k',
  'key_format=u',
  'leaf_page_max=16k',
  'log=(enabled=true)',
  'memory_page_max=5MB',
  'prefix_compression=true',
  'split_pct=90',
  'type=file',
  'value_format=u'
]
```

| 항목 | 컬렉션 | 인덱스 | 뜻 |
|---|---|---|---|
| `key_format` | `q` (64비트 정수) | `u` (바이트열) | 컬렉션의 키는 RecordId, 인덱스의 키는 KeyString으로 인코딩한 인덱스 키 |
| `value_format` | `u` | `u` | 컬렉션의 값은 BSON 문서 그대로. 인덱스의 값은 비어 있거나 RecordId |
| `block_compressor` | `snappy` | 없음 | 컬렉션은 기본 snappy([`wiredtiger_global_options.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_global_options.idl#L125-L133)). 인덱스는 블록 압축 대신 prefix 압축 |
| `leaf_page_max`, `internal_page_max` | 32KB, 4KB | 16k, 16k | 디스크에 쓰는 페이지의 최대 크기. 인덱스는 키(최대 1024바이트)가 넘치지 않도록 16KB([`wiredtiger_index.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L213-L216)) |
| `memory_page_max` | 10m | 5MB | 메모리에서 페이지가 이만큼 커지면 강제로 나눔. 컬렉션은 MongoDB가 10MB로 정함([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L627-L629)) |
| `split_pct` | 90 | 90 | 페이지를 나눌 때 앞쪽을 90%까지 채움. 컬렉션은 대부분 뒤에 붙이는 쓰기라서 높게 잡음([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L630-L632)) |
| `log` | `(enabled=true)` | `(enabled=true)` | 이 테이블의 변경을 저널에 쓰는가. standalone은 모두 쓰고, 레플리카셋은 사용자 컬렉션을 쓰지 않음([2편](/posts/mongodb/02-checkpoint-and-journal/)) |

**RecordId**는 컬렉션 안에서 문서를 가리키는 64비트 정수로, 문서를 넣을 때 1씩 늘려 붙입니다. `_id`와는 별개입니다. 컬렉션 테이블의 키가 RecordId이므로 컬렉션 파일은 **넣은 순서대로** 정렬되어 있고, `_id`로 찾으려면 `_id` 인덱스에서 RecordId를 얻은 뒤 컬렉션 테이블을 한 번 더 찾아야 합니다. (클러스터드 컬렉션은 예외로, `_id` 자체를 키로 쓰는 `key_format=u` 테이블을 만듭니다([`wiredtiger_record_store.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp#L679-L685)).)

#### wt 유틸리티로 본 컬렉션 테이블

WiredTiger 소스에 들어 있는 `wt` 유틸리티로 파일을 직접 열어 봅니다. 실행 중인 mongod의 파일을 다른 프로세스가 열면 안 되므로, mongod를 정상 종료한 뒤에 엽니다. `mongod --shutdown`은 pid 파일의 프로세스에 종료 신호를 보내고 끝나기를 기다립니다.

```console
$ mongod --dbpath /data/db --shutdown | grep -v '^{'
Killing process with pid: 33
$ wt -h /data/db list | grep '^table:'
table:_mdb_catalog
table:collection-0-7164268511808313993
table:collection-11-7164268511808313993
table:collection-13-7164268511808313993
table:collection-15-7164268511808313993
table:collection-17-7164268511808313993
table:collection-2-7164268511808313993
table:collection-4-7164268511808313993
table:collection-7-7164268511808313993
table:index-1-7164268511808313993
table:index-12-7164268511808313993
table:index-14-7164268511808313993
table:index-16-7164268511808313993
table:index-18-7164268511808313993
table:index-3-7164268511808313993
table:index-5-7164268511808313993
table:index-6-7164268511808313993
table:index-8-7164268511808313993
table:index-9-7164268511808313993
table:sizeStorer
```

`wt list`는 WiredTiger 메타데이터에 있는 테이블 목록입니다. `collection-11`부터 `collection-17`까지와 짝이 되는 인덱스는 [뒤에서](#압축-디스크에-쓰는-블록만-압축된다) 압축을 비교하려고 만든 컬렉션 넷입니다. 인덱스 빌드용 임시 테이블 `internal-10`은 이미 없습니다. WiredTiger에게는 `_mdb_catalog`와 `sizeStorer`도 그냥 테이블 가운데 하나입니다.

`orders` 컬렉션 테이블을 16진수로 덤프합니다.

```console
$ wt -h /data/db dump -x table:collection-7-7164268511808313993 | sed -n '/^Data/,$p'
Data
81
27000000105f69640001000000026974656d00060000006170706c650010717479000a00000000
82
28000000105f69640002000000026974656d000700000062616e616e610010717479001400000000
83
28000000105f69640003000000026974656d00070000006368657272790010717479001e00000000
$ wt -h /data/db dump -x table:collection-7-7164268511808313993 | sed -n '/^Data/,$p' | sed -n 3p | xxd -r -p | bsondump --quiet
{"_id":{"$numberInt":"1"},"item":"apple","qty":{"$numberInt":"10"}}
```

- 키와 값이 한 줄씩 번갈아 나옵니다. 키 `81`, `82`, `83`은 RecordId 1, 2, 3을 WiredTiger의 정수 포맷으로 담은 것입니다. 0부터 63까지의 양수는 `0x80`에 값을 더한 한 바이트로 씁니다([`intpack_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/intpack_inline.h#L196-L197)).
- 값은 BSON 문서 그대로입니다. 첫 4바이트 `27000000`은 BSON의 전체 길이(리틀엔디언 0x27 = 39바이트)이고, 이어서 `10`(int32 타입) `5f696400`(`_id`)... 이 이어집니다. 첫 값을 바이트로 되돌려 `bsondump`에 넣으면 넣었던 문서가 그대로 나옵니다.

MongoDB는 문서를 WiredTiger에 넘길 때 아무것도 덧붙이지 않습니다. 이 덤프는 파일에 기록된 **마지막 체크포인트** 기준의 내용이고, 파일 안의 실제 바이트는 압축된 블록입니다. `wt`가 블록을 읽어 압축을 풀고 B-tree를 따라가며 보여 준 결과입니다.

#### 인덱스의 키: KeyString

인덱스 테이블의 키는 인덱스 키를 **KeyString**으로 인코딩한 바이트열입니다. KeyString은 어떤 BSON 값이든 바이트 단위 비교(`memcmp`)만으로 MongoDB의 정렬 순서가 나오도록 만든 형식이라서, WiredTiger는 키가 문자열인지 숫자인지 몰라도 정렬할 수 있습니다.

```console
$ wt -h /data/db dump -x table:index-9-7164268511808313993 | sed -n '/^Data/,$p'
Data
3c6170706c6500040008

3c62616e616e6100040010

3c63686572727900040018

$ wt -h /data/db dump -x table:index-8-7164268511808313993 | sed -n '/^Data/,$p'
Data
2b0204
0008
2b0404
0010
2b0604
0018
```

`item_1` 인덱스(`index-9`)의 첫 키 `3c6170706c6500040008`을 나눠 보면 이렇습니다.

| 바이트 | 뜻 |
|---|---|
| `3c` | 타입 바이트. 문자열 계열(`kStringLike = 60`, [`key_string.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L93)) |
| `6170706c65` `00` | `apple`과 끝 표시 |
| `04` | 키의 끝(`kEnd`, [`key_string.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L337)) |
| `0008` | RecordId 1. 첫 바이트의 위 3비트와 끝 바이트의 아래 3비트에 가운데 바이트 수를 적는 형식으로, 1은 `00 08`이 됨([`_appendRecordIdLong()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L664)) |

- `item_1` 같은 일반 인덱스는 **키 뒤에 RecordId를 붙이고 값은 비워 둡니다**([`WiredTigerIndexStandard::_insert()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L1997), 값은 [`wiredtiger_index.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L2017-L2023)). 같은 키가 여러 문서에 있어도 RecordId가 달라서 B-tree의 키는 모두 다릅니다. 덤프에서 키 다음 줄이 빈 줄인 것이 빈 값입니다.
- `_id_` 인덱스(`index-8`)는 반대로 키에는 `_id` 값만(`2b 02 04`: 1바이트 양의 정수 타입 `kNumericPositive1ByteInt`, 값, 끝), **값에 RecordId**(`0008`)를 담습니다([`WiredTigerIdIndex::_insert()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L1630-L1653)). 키가 유일해야 하는 인덱스라서 키가 겹치면 WiredTiger가 바로 중복 키 오류를 돌려줄 수 있습니다.

인덱스를 따라 문서를 찾는 과정은 결국 "인덱스 B-tree에서 KeyString으로 찾아 RecordId를 얻고, 컬렉션 B-tree에서 그 RecordId로 문서를 얻는" 두 번의 B-tree 탐색입니다. 쿼리 플래너가 이 비용을 어떻게 따지는지는 [4편](/posts/mongodb/04-index-and-query-planner/)에서 봅니다.

#### B-tree의 모양: internal 페이지와 leaf 페이지

문서가 셋뿐이면 페이지 하나로 끝나므로, 문서 10만 개(BSON으로 약 27MB)를 넣은 컬렉션 둘을 봅니다. 하나(`collection-11`)는 기본 snappy 압축, 다른 하나(`collection-17`)는 압축 없이 만들었습니다. `wt verify -d dump_layout`은 트리의 층마다 페이지 수를 보여 줍니다.

```console
$ wt -h /data/db verify -d dump_layout table:collection-11-7164268511808313993 2>&1 | grep -vE '^\['
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
file:collection-11-7164268511808313993.wt, ckpt_name: WiredTigerCheckpoint.1
Root:
	> addr: [0: 10199040-10203136, 4096, 3539864155]
Internal page tree-depth (total 4):
	001: 1
	002: 3
Leaf page tree-depth (total 580):
	003: 580
$ wt -h /data/db verify -d dump_layout table:collection-17-7164268511808313993 2>&1 | grep -vE '^\['
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
file:collection-17-7164268511808313993.wt, ckpt_name: WiredTigerCheckpoint.1
Root:
	> addr: [0: 28393472-28397568, 4096, 2100132084]
Internal page tree-depth (total 6):
	001: 1
	002: 5
Leaf page tree-depth (total 991):
	003: 991
```

- 두 트리 모두 깊이가 3입니다. 1층에 root internal 페이지 하나, 2층에 internal 페이지 몇 개, 3층에 leaf 페이지가 있습니다. 문서(키와 값)는 모두 leaf 페이지에 있고, internal 페이지에는 "이 키부터는 저 자식 페이지로"라는 안내만 있습니다.
- `ckpt_name: WiredTigerCheckpoint.1`은 이 트리가 체크포인트 1번의 모습이라는 뜻입니다. 파일에는 체크포인트 단위로 완성된 트리가 들어 있습니다. [2편](/posts/mongodb/02-checkpoint-and-journal/)에서 자세히 봅니다.
- `Root: addr: [0: 10199040-10203136, 4096, ...]`은 root 페이지가 파일의 10199040바이트 위치에서 4096바이트 크기로 있다는 뜻입니다. 마지막 숫자는 블록의 체크섬입니다.
- 같은 문서인데 압축한 쪽은 leaf가 580개, 압축하지 않은 쪽은 991개입니다. 이 차이는 바로 아래에서 봅니다.

`dump_address`로 페이지 하나하나의 블록 주소를 보면 차이가 보입니다.

```console
$ wt -h /data/db verify -d dump_address table:collection-11-7164268511808313993 2>&1 | head -9 | cut -c1-44
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
file:collection-11-7164268511808313993.wt, c
Root:
	> addr: [0: 10199040-10203136, 4096, 353986
[NoAddr] -/-,-/- row-store internal write ge
[0: 10186752-10190848, 4096, 4021143610] new
[0: 4096-40960, 36864, 1162190748] newest_du
[0: 40960-77824, 36864, 3643813452] newest_d
[0: 77824-114688, 36864, 3315467987] newest_
$ wt -h /data/db verify -d dump_address table:collection-17-7164268511808313993 2>&1 | head -9 | cut -c1-44
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
file:collection-17-7164268511808313993.wt, c
Root:
	> addr: [0: 28393472-28397568, 4096, 210013
[NoAddr] -/-,-/- row-store internal write ge
[0: 28372992-28377088, 4096, 3467847535] new
[0: 4096-32768, 28672, 2770148487] newest_du
[0: 32768-61440, 28672, 1153302453] newest_d
[0: 61440-90112, 28672, 553415368] newest_du
```

```console
$ wt -h /data/db stat table:collection-11-7164268511808313993 | grep -E 'btree: (maximum (internal|leaf) page size|number of key/value pairs|row-store (internal|leaf) pages)|block-manager: file size'
block-manager: file size in bytes=10M (10211328)
btree: maximum internal page size=4096
btree: maximum leaf page size=32768
btree: number of key/value pairs=100000
btree: row-store internal pages=4
btree: row-store leaf pages=580
```

- 트리를 훑는 순서대로 root(메모리에서 연 것이라 `[NoAddr]`), 2층 internal 페이지(4096바이트 블록), 그 아래 leaf들이 나옵니다.
- 압축하지 않은 컬렉션의 leaf 블록은 28672바이트입니다. `leaf_page_max`(32KB)를 넘지 않도록 페이지를 나누고, 블록은 `allocation_size`(4KB)의 배수로 잡습니다.
- snappy로 압축한 컬렉션의 leaf 블록은 **36864바이트**로, 오히려 `leaf_page_max`보다 큽니다. 압축을 쓰는 테이블은 WiredTiger가 "압축하기 전 페이지"를 `memory_page_image_max`(기본은 페이지 최대 크기의 4배, [`bt_handle.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/btree/bt_handle.c#L959-L963))까지 키우고([`bt_handle.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/btree/bt_handle.c#L515-L518)), 실제로 압축된 크기를 보며 그 기준을 계속 조정합니다([`rec_write.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_write.c#L2191-L2198)). 압축된 블록이 `leaf_page_max` 근처가 되도록 겨냥하는 것이라, 압축한 쪽은 leaf 하나에 더 많은 문서가 들어가 leaf 수가 580개로 줄었습니다.

정리하면 **디스크의 블록은 가변 크기**입니다. 페이지마다 압축된 크기가 달라서, 블록은 4KB 단위로 잡히지만 크기가 제각각입니다. PostgreSQL처럼 모든 페이지가 8kB로 같고 파일 안의 자리가 고정되어 있지 않습니다([PG 3편](/posts/postgresql/03-storage-layout/)). WiredTiger는 페이지를 쓸 때마다 파일의 빈 자리에 새 블록을 잡고, 부모 페이지에 새 주소를 적습니다. 이 "제자리에 덮어쓰지 않는" 방식이 체크포인트의 바탕이 됩니다([2편](/posts/mongodb/02-checkpoint-and-journal/)).

## 압축: 디스크에 쓰는 블록만 압축된다

WiredTiger의 압축은 **블록 압축**입니다. 캐시의 페이지를 디스크에 쓸 때 페이지 이미지 전체를 압축해서 블록으로 쓰고, 읽을 때 압축을 풀어 캐시에 올립니다. 문서 하나하나를 압축하는 것이 아니고, 캐시 안의 페이지는 압축이 풀린 상태입니다. 압축 방식은 컬렉션을 만들 때 정하고, 기본값은 `storage.wiredTiger.collectionConfig.blockCompressor`(snappy)입니다. 컬렉션마다 `storageEngine.wiredTiger.configString`으로 다르게 정할 수도 있습니다.

#### 같은 문서 10만 개, 압축 방식만 다르게

압축 방식만 다른 컬렉션 넷을 만들고, 같은 난수 씨앗으로 만든 같은 문서 10만 개를 넣습니다.

```mongosh
test> db.createCollection("c_snappy")
{ ok: 1 }
test> db.createCollection("c_zstd", {storageEngine: {wiredTiger: {configString: "block_compressor=zstd"}}})
{ ok: 1 }
test> db.createCollection("c_zlib", {storageEngine: {wiredTiger: {configString: "block_compressor=zlib"}}})
{ ok: 1 }
test> db.createCollection("c_none", {storageEngine: {wiredTiger: {configString: "block_compressor=none"}}})
{ ok: 1 }
test> ["c_snappy", "c_zstd", "c_zlib", "c_none"].map(c => c + ": " + db[c].stats().wiredTiger.creationString.match(/block_compressor=\w*/)[0])
[
  'c_snappy: block_compressor=snappy',
  'c_zstd: block_compressor=zstd',
  'c_zlib: block_compressor=zlib',
  'c_none: block_compressor=none'
]
```

넣은 문서는 이런 모양입니다. 필드 이름이 문서마다 반복되고, `memo`는 단어 20개 가운데서 골라 만든 문장이라 실제 서비스 데이터처럼 어느 정도 압축이 됩니다.

```mongosh
test> db.c_snappy.findOne({_id: 7})
{
  _id: 7,
  user: 'user18224',
  email: 'user7@example.com',
  city: 'Seoul',
  status: 'inactive',
  amount: 6594.56,
  tags: [ 'member', 'cart' ],
  createdAt: ISODate('2026-06-16T23:31:02.336Z'),
  memo: 'order order cart sale return cart order sale order order sale order return sale return'
}
```

`fsync` 명령으로 체크포인트를 한 번 해서 캐시의 내용을 파일에 모두 쓴 뒤 크기를 비교합니다.

```mongosh
test> db.adminCommand({fsync: 1})
{ numFiles: 1, ok: 1 }
test> ["c_snappy", "c_zstd", "c_zlib", "c_none"].map(c => { const s = db[c].stats(); return {coll: c, count: s.count, size: s.size, storageSize: s.storageSize, ratio: (s.size / s.storageSize).toFixed(2)}; })
[
  {
    coll: 'c_snappy',
    count: 100000,
    size: 27461165,
    storageSize: 10211328,
    ratio: '2.69'
  },
  {
    coll: 'c_zstd',
    count: 100000,
    size: 27461165,
    storageSize: 4886528,
    ratio: '5.62'
  },
  {
    coll: 'c_zlib',
    count: 100000,
    size: 27461165,
    storageSize: 4882432,
    ratio: '5.62'
  },
  {
    coll: 'c_none',
    count: 100000,
    size: 27461165,
    storageSize: 28405760,
    ratio: '0.97'
  }
]
```

```console
$ ls -l /data/db/collection-11-7164268511808313993.wt /data/db/collection-13-7164268511808313993.wt /data/db/collection-17-7164268511808313993.wt
-rw------- 1 mongod mongod 10211328 Sep 27 21:41 /data/db/collection-11-7164268511808313993.wt
-rw------- 1 mongod mongod  4886528 Sep 27 21:41 /data/db/collection-13-7164268511808313993.wt
-rw------- 1 mongod mongod 28405760 Sep 27 21:41 /data/db/collection-17-7164268511808313993.wt
```

| 압축 | `size` (BSON 합계) | `storageSize` (파일) | 비율 |
|---|---|---|---|
| snappy (기본) | 27461165 | 10211328 | 2.69 |
| zstd | 27461165 | 4886528 | 5.62 |
| zlib | 27461165 | 4882432 | 5.62 |
| none | 27461165 | 28405760 | 0.97 |

- `size`는 문서(BSON) 크기의 합이라 네 컬렉션이 같습니다. MongoDB가 `sizeStorer`에 따로 세어 두는 값입니다. `storageSize`는 파일 크기이고, `ls -l`의 크기와 같습니다.
- 이 데이터에서는 zstd와 zlib가 snappy보다 두 배쯤 더 줄였습니다. zstd의 압축 수준은 mongod가 `builtin_extension_config=(zstd=(compression_level=6))`으로 넘긴 6입니다([`wiredtiger_global_options.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_global_options.idl#L76-L84)). 압축률은 데이터에 따라 크게 달라지니 이 비율을 일반화하면 안 됩니다.
- 압축하지 않은 쪽은 파일이 BSON 합계보다 **큽니다**(0.97). 블록 헤더, internal 페이지, 4KB 단위로 잡은 블록의 빈 공간 때문입니다.

snappy는 압축률보다 속도를 택한 기본값이고, zstd는 CPU를 조금 더 쓰는 대신 디스크와 I/O를 줄입니다. 압축은 블록을 쓰고 읽을 때만 일어나므로, 캐시 안에서 자주 쓰이는 데이터에는 압축 방식이 영향을 주지 않습니다. 영향을 받는 것은 캐시로 읽어 올 때(압축 풀기)와 eviction, 체크포인트로 쓸 때(압축)입니다.

## 캐시: 메모리의 페이지는 디스크의 블록과 다르다

캐시에 올라온 페이지는 디스크 블록을 그대로 옮긴 것이 아닙니다. WiredTiger는 블록을 읽어 압축을 풀고([`__page_read()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/btree/bt_read.c#L92)), 그 이미지 위에 키를 빨리 찾기 위한 배열 같은 메모리 구조를 붙입니다. 페이지를 고치면 이미지 자체는 건드리지 않고, 바뀐 키마다 **update 목록**을 달고, 새로 들어온 키는 **insert 목록**에 달아 둡니다. 그래서 캐시의 페이지는 "디스크에서 읽은 이미지 + 그 뒤에 쌓인 변경"입니다. 같은 키의 여러 버전이 update 목록에 함께 있을 수 있고, 이것이 [3편](/posts/mongodb/03-mvcc-and-snapshot/)에서 볼 MVCC의 바탕입니다.

변경이 달린 페이지를 **dirty 페이지**라고 합니다. dirty 페이지를 디스크에 쓰려면 이미지와 변경을 합쳐 새 페이지 이미지를 만들어야 하고, 이 과정을 **reconciliation**이라고 합니다([`__wt_reconcile()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_write.c#L30)). 페이지가 너무 크면 이때 여러 블록으로 나뉘고(split), 압축된 뒤 파일의 새 자리에 쓰입니다.

| | 캐시의 페이지 | 디스크의 블록 |
|---|---|---|
| 형태 | 압축 풀린 이미지 + 메모리 구조 + update/insert 목록 | reconciliation으로 만든 이미지를 압축한 것 |
| 크기 | `memory_page_max`(컬렉션 10MB)까지 커질 수 있음 | 4KB 단위, 페이지마다 다름 |
| 버전 | 한 키의 여러 버전이 함께 있을 수 있음 | 쓸 때 고른 버전(과 시간 정보) |
| 위치 | 부모 페이지가 메모리 주소로 가리킴 | 부모 페이지가 파일 주소(offset, size, checksum)로 가리킴 |

#### 읽으면 압축이 풀린 채로 캐시에 올라온다

mongod를 다시 띄워 캐시가 빈 상태에서, 컬렉션의 문서를 전부 읽는 집계를 돌리고 컬렉션별 캐시 통계를 봅니다.

```mongosh
test> function cacheOf(c) { const s = db[c].stats(); return {coll: c, storageSize: s.storageSize, size: s.size, inCache: s.wiredTiger.cache["bytes currently in the cache"], readIntoCache: s.wiredTiger.cache["bytes read into cache"]}; }
[Function: cacheOf]
test> cacheOf("c_snappy")
{
  coll: 'c_snappy',
  storageSize: 10211328,
  size: 27461165,
  inCache: 383,
  readIntoCache: 9059
}
test> db.c_snappy.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}])
[ { _id: null, n: 100000, total: 494173742.55 } ]
test> cacheOf("c_snappy")
{
  coll: 'c_snappy',
  storageSize: 10211328,
  size: 27461165,
  inCache: 31422776,
  readIntoCache: 28220035
}
test> db.c_none.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}])
[ { _id: null, n: 100000, total: 494173742.55 } ]
test> cacheOf("c_none")
{
  coll: 'c_none',
  storageSize: 28405760,
  size: 27461165,
  inCache: 31511577,
  readIntoCache: 28249003
}
```

- 재시작 직후 `c_snappy`는 캐시에 383바이트뿐입니다. 컬렉션을 열 때 읽은 root 페이지 정도입니다.
- 전체를 읽은 뒤 캐시에 올라온 양(`bytes read into cache`)은 28220035바이트로, 파일 크기(10211328)가 아니라 **압축을 푼 크기**입니다. 캐시에 지금 있는 양(`bytes currently in the cache`)은 31422776바이트로 더 큽니다. 페이지 이미지에 메모리 구조가 붙고, WiredTiger가 메모리 할당기의 오버헤드로 8%를 더 얹어 세기 때문입니다([`cache_overhead`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L532-L537)).
- 압축하지 않은 `c_none`도 캐시에서는 거의 같은 크기(31511577)입니다. 압축 방식은 디스크 크기를 바꿀 뿐, **캐시에 필요한 메모리는 바꾸지 않습니다.**

WiredTiger 캐시 밖에는 운영체제의 페이지 캐시가 따로 있습니다. `.wt` 파일을 읽으면 압축된 블록이 운영체제 페이지 캐시에 남고, 압축이 풀린 페이지는 WiredTiger 캐시에 들어갑니다. 같은 데이터가 두 형태로 메모리에 있을 수 있는 셈입니다. 기본 캐시가 메모리의 절반 정도인 것도, 나머지를 연결과 쿼리 실행, 그리고 이 운영체제 캐시에 남겨 두기 위해서입니다([WiredTiger Storage Engine](https://www.mongodb.com/docs/v8.0/core/wiredtiger/) 문서). WiredTiger 캐시에서 밀려난 페이지라도 압축된 블록이 운영체제 캐시에 있으면 디스크를 읽지 않고 다시 올릴 수 있습니다. PostgreSQL이 shared_buffers와 운영체제 캐시를 함께 쓰는 것과 비슷하지만([PG 2편](/posts/postgresql/02-memory-architecture/)), WiredTiger 쪽은 두 캐시의 형태가 다릅니다.

## 캐시 크기는 어떻게 정해지는가

`--wiredTigerCacheSizeGB`(`storage.wiredTiger.engineConfig.cacheSizeGB`)를 주지 않으면 mongod가 크기를 계산합니다([`WiredTigerUtil::getCacheSizeMB()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp#L669-L698)).

```cpp
// Set a minimum of 256MB, otherwise use 50% of available memory over 1GB.
cacheSizeMB = std::max((memSizeMB - 1024) * 0.5, 256.0);
```

여기서 `memSizeMB`는 [`ProcessInfo::getMemSizeMB()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/util/processinfo.h#L101-L103)로, 시스템 메모리가 아니라 `memLimit`입니다. `memLimit`은 cgroup v2의 `/sys/fs/cgroup/memory.max`(v1이면 `memory.limit_in_bytes`)를 읽어 시스템 메모리와 비교해 작은 쪽을 씁니다([`getMemorySizeLimit()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/util/processinfo_linux.cpp#L775-L788)). 그래서 컨테이너에 메모리 제한을 걸면 캐시도 그 제한을 기준으로 잡힙니다. 크기를 직접 주면 그 값을 그대로 쓰고, 메모리의 80%를 넘으면 시작할 때 경고만 남깁니다([`wiredtiger_init.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_init.cpp#L124-L133)).

#### 메모리 제한이 다른 컨테이너 넷

제한이 없는 컨테이너와, 1GB, 2GB, 4GB로 제한한 컨테이너에서 각각 기본 설정으로 mongod를 띄웠습니다. 제한이 없는 컨테이너부터 봅니다.

```console
$ cat /sys/fs/cgroup/memory.max
max
$ jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log | grep -oE 'cache_size=[0-9]+M'
cache_size=15508M
```

```mongosh
test> const h = db.adminCommand({hostInfo: 1}).system; ({memSizeMB: h.memSizeMB, memLimitMB: h.memLimitMB, cacheMaxBytes: db.serverStatus().wiredTiger.cache["maximum bytes configured"]})
{
  memSizeMB: Long('32041'),
  memLimitMB: Long('32041'),
  cacheMaxBytes: Long('16261316608')
}
```

1GB로 제한한 컨테이너입니다.

```console
$ cat /sys/fs/cgroup/memory.max
1073741824
$ jq -r 'select(.msg == "Opening WiredTiger") | .attr.config' /data/mongod.log | grep -oE 'cache_size=[0-9]+M'
cache_size=256M
```

```mongosh
test> const h = db.adminCommand({hostInfo: 1}).system; ({memSizeMB: h.memSizeMB, memLimitMB: h.memLimitMB, cacheMaxBytes: db.serverStatus().wiredTiger.cache["maximum bytes configured"]})
{
  memSizeMB: Long('32041'),
  memLimitMB: Long('1024'),
  cacheMaxBytes: 268435456
}
```

2GB와 4GB로 제한한 컨테이너의 결과까지 모으면 다음과 같습니다.

| 컨테이너 | `memory.max` | `memSizeMB` | `memLimitMB` | 계산 | `cache_size` |
|---|---|---|---|---|---|
| 제한 없음 | `max` | 32041 | 32041 | (32041 − 1024) × 0.5 | 15508M |
| 1GB | 1073741824 | 32041 | 1024 | max(0, 256) | 256M |
| 2GB | 2147483648 | 32041 | 2048 | (2048 − 1024) × 0.5 | 512M |
| 4GB | 4294967296 | 32041 | 4096 | (4096 − 1024) × 0.5 | 1536M |

- `hostInfo`의 `memSizeMB`는 어느 컨테이너에서나 호스트(Docker VM)의 메모리 32041MB이고, `memLimitMB`만 cgroup 제한을 따라갑니다. 캐시는 `memLimitMB`로 계산합니다.
- 1GB 컨테이너는 공식대로면 0MB지만 최솟값 256MB가 적용되었습니다. 메모리 1GB 가운데 256MB가 WiredTiger 캐시이고, 나머지로 연결, 쿼리 실행, 운영체제 캐시를 감당해야 합니다.
- `serverStatus`의 `maximum bytes configured`는 `cache_size`를 바이트로 바꾼 값입니다(15508 × 1048576 = 16261316608).

캐시 크기는 실행 중에도 `wiredTigerEngineRuntimeConfig` 파라미터로 바꿀 수 있지만(`cache_size=...`), 재시작하면 설정 파일의 값으로 돌아갑니다.

## eviction: 캐시에서 페이지를 내보내기

캐시가 차면 페이지를 내보내야 새 페이지를 올릴 수 있습니다. 이것이 **eviction**입니다. 깨끗한(clean) 페이지는 메모리에서 버리기만 하면 되고, dirty 페이지는 reconciliation으로 디스크에 쓴 뒤에 버립니다. 언제 누가 eviction을 하는지는 캐시에 대한 비율 네 쌍으로 정합니다. MongoDB는 이 값들을 설정 문자열에 넣지 않으므로(`gWiredTigerEvictionDirtyTargetGB` 같은 숨은 파라미터를 줄 때만 넣습니다, [`wiredtiger_kv_engine.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp#L385-L393)) WiredTiger의 기본값이 쓰입니다([`api_data.py`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py#L690-L728)).

| 대상 | target: eviction 스레드가 시작 | trigger: 애플리케이션 스레드도 참여 |
|---|---|---|
| 캐시 전체 사용량 | `eviction_target` 80% | `eviction_trigger` 95% |
| dirty 데이터 | `eviction_dirty_target` 5% | `eviction_dirty_trigger` 20% |
| update 목록의 크기 | `eviction_updates_target` (dirty target의 절반) | `eviction_updates_trigger` (dirty trigger의 절반) |

- **eviction server**가 캐시 상태를 보고 할 일을 정하고([`__evict_update_work()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/evict/evict_lru.c#L604)), 트리를 훑어 내보낼 후보를 큐에 넣습니다([`__evict_server()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/evict/evict_lru.c#L403)). 큐의 페이지를 실제로 내보내는 것은 eviction worker 스레드(mongod에서는 4개)입니다. target을 넘은 동안 이 스레드들이 일합니다.
- trigger를 넘으면 백그라운드 스레드만으로는 부족하다고 보고, 캐시에 접근하는 **애플리케이션 스레드**(mongod에서는 요청을 처리하던 스레드)가 자기 일을 하기 전에 eviction을 거듭니다([`__wt_cache_eviction_check()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/cache_inline.h#L597), [`__wt_eviction_needed()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/cache_inline.h#L402)). 쿼리를 처리하던 스레드가 페이지를 디스크에 쓰는 일까지 하게 되니, 그만큼 응답이 늦어집니다.
- eviction server가 trigger를 넘은 것을 볼 때마다 `number of times eviction trigger was reached`, `number of times dirty trigger was reached` 통계가 1씩 늘어납니다([`evict_lru.c`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/evict/evict_lru.c#L651-L661)).

#### 256MB 캐시에 400MB 넣기

mongod를 `--wiredTigerCacheSizeGB 0.25`로 다시 띄우고, 1KB 남짓한 문서 40만 개(약 400MB)를 넣습니다. 캐시 통계는 아래 함수 하나로 모아 봅니다. 바이트 값은 MB로, 캐시 사용량과 dirty 양은 캐시 크기에 대한 비율로 바꿨습니다.

```js
// /data/cache.js
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
```

```js
// /data/load-ev.js: 1KB 남짓한 문서 40만 개(약 400MB)를 넣는다
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
```

```mongosh
test> cache()
{
  maxMB: 256,
  inCacheMB: 0,
  usedPct: 0,
  dirtyMB: 0,
  dirtyPct: 0,
  pagesRead: 23,
  pagesWritten: 3,
  workerEvict: 0,
  appEvict: 0,
  appEvictUsecs: 0,
  cleanEvicted: 0,
  dirtyEvicted: 0,
  dirtyTrigger: 0,
  evictionTrigger: 0
}
```

```console
$ time mongosh --quiet /data/load-ev.js

real	0m2.046s
user	0m1.521s
sys	0m0.176s
```

```mongosh
test> cache()
{
  maxMB: 256,
  inCacheMB: 180,
  usedPct: 70.4,
  dirtyMB: 1,
  dirtyPct: 0.5,
  pagesRead: 32,
  pagesWritten: 8979,
  workerEvict: 688,
  appEvict: 63,
  appEvictUsecs: 17973,
  cleanEvicted: 601,
  dirtyEvicted: 248,
  dirtyTrigger: 0,
  evictionTrigger: 0
}
test> const s = db.ev.stats(); ({count: s.count, sizeMB: Math.round(s.size / 1048576), storageSizeMB: Math.round(s.storageSize / 1048576)})
{ count: 400000, sizeMB: 403, storageSizeMB: 336 }
```

- 403MB를 넣었는데 캐시에는 180MB(70.4%)만 있습니다. 캐시보다 큰 데이터는 넣는 동안 계속 캐시 밖으로 나갔다는 뜻입니다.
- `pagesWritten` 8979: 넣은 페이지를 디스크에 쓴 횟수입니다. dirty가 0.5%로 낮은 것은 쓴 페이지가 금방 디스크로 나가 clean이 되었기 때문입니다.
- eviction worker가 688번, 애플리케이션 스레드가 63번 페이지를 내보내려 했습니다. 문서를 넣던 요청 스레드가 eviction에 쓴 시간이 모두 17973µs(약 18ms)입니다. 이번 적재에서는 대부분 worker가 감당했고, 트리거 도달 횟수도 0입니다.

#### 모든 문서를 고치면 dirty가 늘어난다

이번에는 400MB 전체를 한 번씩 고칩니다. 캐시에 없는 페이지는 읽어 와야 하고, 고친 페이지는 dirty가 되므로 eviction이 dirty 페이지를 써서 내보내야 합니다.

```mongosh
test> let t = Date.now(); db.ev.updateMany({}, {$inc: {amount: 1}}).modifiedCount + " docs, " + (Date.now() - t) + " ms"
400000 docs, 967 ms
test> cache()
{
  maxMB: 256,
  inCacheMB: 206,
  usedPct: 80.6,
  dirtyMB: 11,
  dirtyPct: 4.3,
  pagesRead: 5128,
  pagesWritten: 22401,
  workerEvict: 10952,
  appEvict: 68,
  appEvictUsecs: 18383,
  cleanEvicted: 2395,
  dirtyEvicted: 8770,
  dirtyTrigger: 9,
  evictionTrigger: 0
}
```

- 캐시 사용량이 80.6%로, `eviction_target`(80%) 바로 위에 머물러 있습니다. worker 스레드가 80% 근처를 지키도록 계속 내보낸 결과입니다.
- 내보낸 페이지 가운데 dirty 페이지(`dirtyEvicted`)가 8770개로, 앞 단계의 248개에서 크게 늘었습니다. `pagesWritten`도 8979에서 22401로 늘었습니다. 고친 페이지는 디스크에 써야 내보낼 수 있기 때문입니다.
- `dirtyTrigger`가 9입니다. 업데이트 도중 dirty가 `eviction_dirty_trigger`(20%)를 넘은 적이 9번 있었다는 뜻입니다. 끝난 뒤 찍은 순간 값(4.3%)만 봐서는 알 수 없는 일입니다.
- 애플리케이션 스레드의 eviction은 68번, 18383µs로 앞 단계에서 거의 늘지 않았습니다. 요청 스레드는 트랜잭션 도중(쓰기를 해서 트랜잭션 ID를 받은 뒤 등)에는 dirty trigger를 보지 않고 캐시 전체의 trigger만 봅니다([`cache_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/cache_inline.h#L438-L444), [`cache_inline.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/cache_inline.h#L641-L644)). 이번 실행에서는 요청이 `updateMany` 하나뿐이라 worker 네 개가 대부분을 처리했습니다. 동시에 들어오는 요청이 많은 서버라면 이 몫이 요청 스레드로 넘어올 수 있습니다.

#### 캐시보다 큰 컬렉션 훑기

마지막으로 400MB 전체를 읽기만 합니다.

```mongosh
test> t = Date.now(); db.ev.aggregate([{$group: {_id: null, n: {$sum: 1}, total: {$sum: "$amount"}}}]).toArray()[0].n + " docs, " + (Date.now() - t) + " ms"
400000 docs, 143 ms
test> cache()
{
  maxMB: 256,
  inCacheMB: 199,
  usedPct: 77.8,
  dirtyMB: 11,
  dirtyPct: 4.3,
  pagesRead: 15308,
  pagesWritten: 22401,
  workerEvict: 21297,
  appEvict: 72,
  appEvictUsecs: 18388,
  cleanEvicted: 12701,
  dirtyEvicted: 8770,
  dirtyTrigger: 9,
  evictionTrigger: 1
}
```

- 읽기만 했으므로 `pagesWritten`(22401)과 `dirtyEvicted`(8770)는 그대로이고, `cleanEvicted`만 2395에서 12701로 늘었습니다. 읽어 온 페이지는 clean이라 쓰지 않고 버립니다.
- `pagesRead`가 5128에서 15308로 약 1만 페이지 늘었습니다. 캐시에 다 들어가지 않는 컬렉션을 훑으면, 앞에서 읽은 페이지를 내보내면서 뒤의 페이지를 읽어 오게 됩니다. 이 스캔이 끝난 뒤 캐시에 남은 것은 컬렉션의 뒷부분입니다. 다른 쿼리가 자주 쓰던 페이지도 이때 함께 밀려났을 수 있습니다.
- `evictionTrigger`가 1이 되었습니다. 스캔 도중 캐시 사용량이 한 번 95%를 넘은 것입니다.

이 실습의 수치(소요 시간 포함)는 다른 실습이 함께 돌던 한 대의 Docker VM에서, 운영체제 페이지 캐시에 파일이 다 들어 있는 상태로 잰 것입니다. 실제 디스크에서 읽어야 하는 서버라면 eviction과 캐시 miss의 비용은 훨씬 큽니다.

## 운영에서는 이렇게 나타납니다

#### 캐시 사용률과 dirty 비율을 본다

앞의 실습처럼, 캐시가 데이터보다 작으면 캐시 사용률은 80% 근처에서 머물고 이것은 정상입니다. 봐야 할 것은 **trigger를 넘는 상황**입니다. `serverStatus().wiredTiger.cache`에서 다음 값을 주기적으로 모읍니다.

| 지표 | 계산 | 주의할 수준 |
|---|---|---|
| 캐시 사용률 | `bytes currently in the cache` / `maximum bytes configured` | 80%에 머무는 것은 정상, 95%(eviction trigger)에 닿으면 요청 스레드가 eviction에 참여 |
| dirty 비율 | `tracked dirty bytes in the cache` / `maximum bytes configured` | 5%를 넘으면 worker가 dirty 페이지를 쓰기 시작, 20%(dirty trigger)에 닿으면 요청 스레드 참여 |
| 요청 스레드의 eviction | `page evict attempts by application threads`, `application thread time evicting (usecs)` | 늘어나는 속도. 이 시간이 곧 요청의 지연 |
| trigger 도달 횟수 | `number of times eviction trigger was reached`, `number of times dirty trigger was reached` | 순간 값으로는 놓치는 짧은 초과를 잡음 |
| 캐시 miss | `pages read into cache`, `application threads page read from disk to cache time (usecs)` | 작업 집합이 캐시보다 큰지 |

순간 값은 [앞 실습](#모든-문서를-고치면-dirty가-늘어난다)의 dirty 4.3%처럼 이미 지나간 초과를 보여 주지 않으므로, 누적 카운터의 증가량을 함께 봐야 합니다. 요청 스레드의 eviction 시간이 늘어나는 시점과 느린 쿼리 로그가 늘어나는 시점이 겹친다면 캐시 압박이 원인일 가능성이 큽니다.

#### 컨테이너의 메모리 제한과 캐시 크기

mongod는 cgroup의 메모리 제한을 읽어 캐시를 잡습니다. 반대로 말하면, 제한 없이 큰 호스트에 컨테이너 여러 개를 띄우면 mongod마다 **호스트 메모리의 절반**을 캐시로 잡으려 합니다. `hostInfo`의 `memLimitMB`와 `Opening WiredTiger` 로그의 `cache_size`로 실제 값을 확인하고, 한 호스트에 여러 인스턴스를 둘 때는 `cacheSizeGB`를 직접 정해야 합니다. WiredTiger 캐시는 mongod가 쓰는 메모리의 전부가 아닙니다. 연결마다 쓰는 메모리, 집계와 정렬의 작업 메모리, 인덱스 빌드가 따로 있고, 압축된 블록을 담는 운영체제 캐시도 필요합니다. 1GB 컨테이너처럼 제한이 작으면 최솟값 256MB가 적용되어, 캐시가 공식보다 크게 잡힙니다.

#### 컬렉션과 인덱스가 많으면 파일이 많다

컬렉션 하나에 인덱스가 다섯이면 파일이 여섯입니다. 컬렉션이 수만 개인 멀티테넌트 구조에서는 dbPath에 파일이 수십만 개가 되고, 파일 핸들과 WiredTiger의 data handle도 그만큼 필요합니다. mongod는 600초 동안 쓰지 않은 핸들을 닫고(`file_manager=(close_idle_time=600,...)`), 핸들이 2000개 이상일 때만 닫기를 시도합니다(`close_handle_minimum=2000`). 파일이 많으면 체크포인트가 훑어야 할 테이블도 많아지고([2편](/posts/mongodb/02-checkpoint-and-journal/)), 시작할 때 `_mdb_catalog`를 읽어 모든 테이블을 확인하는 시간도 길어집니다. 운영체제의 파일 디스크립터 제한(`ulimit -n`)은 이 수를 넉넉히 감당하도록 잡아야 합니다.

#### 압축 방식은 디스크와 CPU의 교환

압축은 블록 단위라서 캐시에 필요한 메모리를 줄이지 않고, 디스크 용량과 읽기 I/O를 줄입니다. 데이터가 캐시보다 훨씬 크고 디스크 I/O가 병목이라면 zstd로 얻는 것이 많고, 캐시 안에서 대부분 처리되는 작업이라면 차이가 작습니다. 압축 방식은 컬렉션을 만들 때 정해지므로, 기존 컬렉션을 바꾸려면 새 컬렉션을 만들어 옮기거나 새 멤버를 초기 동기화로 만들어야 합니다.

## 정리

- mongod의 쿼리 계층은 `KVEngine`, `RecordStore`, `SortedDataInterface`라는 스토리지 엔진 API만 알고, WiredTiger 구현이 이를 `WT_SESSION`과 `WT_CURSOR` 호출로 바꿉니다.
- 컬렉션과 인덱스는 각각 WiredTiger 테이블 하나, 파일 하나입니다. 파일 이름(ident)과 컬렉션 이름의 짝은 `_mdb_catalog.wt`에 있고, WiredTiger 자신의 메타데이터는 `WiredTiger.wt`와 `WiredTiger.turtle`에 있습니다.
- 컬렉션 테이블은 RecordId → BSON, 일반 인덱스는 KeyString+RecordId → 빈 값, `_id` 인덱스는 KeyString → RecordId인 B-tree입니다.
- 디스크의 블록은 압축된 가변 크기이고, 캐시의 페이지는 압축이 풀린 이미지에 update 목록이 붙은 것입니다. 압축은 디스크 크기만 바꿉니다.
- 기본 캐시 크기는 max((메모리 − 1GB) × 50%, 256MB)이고, 메모리는 cgroup 제한을 따릅니다.
- 캐시 사용량이 80%, dirty가 5%를 넘으면 eviction 스레드가, 95%와 20%를 넘으면 요청 스레드까지 페이지를 내보냅니다.

다음 글에서는 캐시의 변경이 파일에 확정되는 **체크포인트**와, 그 사이의 변경을 지키는 **저널**을 봅니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/db/storage/kv/kv_engine.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/kv/kv_engine.h), [record_store.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/record_store.h), [sorted_data_interface.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/sorted_data_interface.h): 스토리지 엔진 API
- [src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_kv_engine.cpp): `wiredtiger_open` 설정
- [src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_record_store.cpp), [wiredtiger_index.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp): 컬렉션과 인덱스의 테이블 설정, 키와 값
- [src/mongo/db/storage/key_string.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp): KeyString 인코딩
- [src/mongo/db/storage/durable_catalog.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/durable_catalog.cpp): `_mdb_catalog`, ident
- [src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_util.cpp), [src/mongo/util/processinfo_linux.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/util/processinfo_linux.cpp): 캐시 크기 계산, cgroup 메모리 제한
- [src/third_party/wiredtiger/dist/api_data.py](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/dist/api_data.py): WiredTiger 설정 기본값
- [src/third_party/wiredtiger/src/evict/evict_lru.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/evict/evict_lru.c), [src/include/cache_inline.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/include/cache_inline.h): eviction
- [src/third_party/wiredtiger/src/reconcile/rec_write.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/reconcile/rec_write.c), [src/btree/bt_handle.c](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/third_party/wiredtiger/src/btree/bt_handle.c): reconciliation, 압축 전 페이지 크기 조정

MongoDB 8.0 공식 문서

- [WiredTiger Storage Engine](https://www.mongodb.com/docs/v8.0/core/wiredtiger/)
- [serverStatus](https://www.mongodb.com/docs/v8.0/reference/command/serverStatus/)
- [Configuration File Options](https://www.mongodb.com/docs/v8.0/reference/configuration-options/)
