---
title: "MongoDB 인터널 7: 샤딩 구조"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "샤딩", "mongos", "chunk", "balancer", "orphans cleanup routine didn't clear yet"]
weight: 7
summary: "MongoDB는 데이터를 여러 샤드에 어떻게 나누고, 쿼리를 어떻게 보내며, 데이터를 어떻게 옮기는가"
description: "mongos와 config server, shard key와 chunk, balancer와 chunk migration, 쿼리 라우팅, shard version과 StaleConfig, orphan과 range deleter"
---

## 개요

[5편](/posts/mongodb/05-oplog-and-replication/)과 [6편](/posts/mongodb/06-election/)의 레플리카셋은 같은 데이터를 여러 멤버가 똑같이 가집니다. 멤버를 늘리면 장애에 강해지고 읽기를 나눌 수 있지만, 쓰기와 데이터 크기는 여전히 primary 한 대의 몫입니다. 한 대가 감당할 수 있는 것보다 데이터가 커지면 **데이터 자체를 나눠** 여러 레플리카셋에 흩어야 합니다. 이것이 **샤딩**이고, 나눈 조각을 각각 맡는 레플리카셋이 **샤드**입니다.

데이터를 나누면 곧바로 새 질문들이 생깁니다. 어떤 도큐먼트가 어느 샤드에 있는지는 누가 기억하는가? 쿼리는 어느 샤드로 보내야 하는가? 한 샤드에 데이터가 몰리면 어떻게 옮기는가? 옮기는 동안의 쓰기와 읽기는 어떻게 되는가? 이 글은 이 질문들을 소스와 실측으로 따라갑니다.

이 글에서 답할 질문은 다음과 같습니다.

- mongos, config server, 샤드는 각각 무엇을 가지고 무엇을 하는가
- shard key와 chunk는 무엇이고, range 샤딩과 hashed 샤딩은 무엇이 다른가
- 쿼리는 어떻게 한 샤드로 가거나(targeted) 모든 샤드로 가는가(scatter-gather)
- balancer는 무엇을 기준으로 chunk를 옮기고, 옮기는 과정(chunk migration)은 어떤 단계를 거치는가
- mongos가 가진 정보가 낡았을 때(stale config) 쿼리는 어떻게 되는가
- 옮긴 뒤 원본 샤드에 남는 도큐먼트(orphan)는 어떻게 되는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 컨테이너 4대로 config server(1노드 레플리카셋 `cfg`), 샤드 2개(각각 1노드 레플리카셋 `sh1`, `sh2`), mongos 2개(한 컨테이너에 포트 27017, 27018)를 띄웠습니다.

## 샤드 클러스터의 세 구성 요소

{{< diagram src="/diagrams/mongo-sharded-cluster.html" title="샤드 클러스터의 구성 요소" height="640" caption="애플리케이션은 mongos에만 접속합니다. mongos는 config server의 메타데이터를 캐시해 쿼리를 보낼 샤드를 정하고, balancer는 config server primary에서 돌며 샤드 사이의 chunk 이동을 지시합니다." >}}

- **mongos**: 라우터입니다. 데이터를 저장하지 않고, 애플리케이션의 요청을 받아 어느 샤드로 보낼지 정한 뒤 결과를 모아 돌려줍니다. 판단에 쓰는 것은 config server에서 가져와 메모리에 캐시한 **routing table**입니다(`CatalogCache`, [`CatalogCache::getCollectionRoutingInfo()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/catalog_cache.cpp#L479)). mongos는 상태가 없어서 여러 개를 띄워 부하를 나누고, 하나가 죽어도 다른 mongos로 접속하면 됩니다.
- **config server**: 클러스터의 메타데이터를 가진 레플리카셋입니다(CSRS, Config Server Replica Set). `--configsvr`로 띄우며, 어떤 샤드가 있고(`config.shards`), 어떤 컬렉션이 어떤 키로 샤딩되었으며(`config.collections`), 키의 어느 범위가 어느 샤드에 있는지(`config.chunks`)를 `config` 데이터베이스에 저장합니다. **balancer**도 config server의 primary에서 돕니다.
- **샤드**: 실제 데이터를 가진 레플리카셋입니다. `--shardsvr`로 띄우고, 자기가 맡은 범위의 도큐먼트만 가집니다. 각 샤드도 자기 컬렉션의 메타데이터(어느 범위를 자기가 가졌는지)를 캐시해 두고, mongos가 보낸 요청이 최신 정보에 기반한 것인지 확인합니다.

#### 클러스터 만들기와 config 데이터베이스

config server와 두 샤드를 각각 1노드 레플리카셋으로 띄우고 `rs.initiate`한 뒤, mongos를 띄웁니다. mongos에는 config server의 주소만 줍니다.

```console
$ mongos --configdb cfg/m07-cfg:27017 --bind_ip_all --port 27017 --logpath /data/mongos.log --fork | grep -E 'forked|ERROR'
$ mongos --configdb cfg/m07-cfg:27017 --bind_ip_all --port 27018 --logpath /data/mongos-b.log --fork | grep -E 'forked|ERROR'
forked process: 35
forked process: 76
```

두 번째 mongos(27018)는 뒤에서 [stale config](#shard-version과-stale-config)를 보려고 띄웠습니다. 이제 첫 mongos에 접속해 샤드를 등록합니다. 프롬프트의 `[direct: mongos]`는 mongos에 접속했다는 표시입니다.

```mongosh
[direct: mongos] test> sh.addShard('sh1/m07-sh1:27017').shardAdded
sh1
[direct: mongos] test> sh.addShard('sh2/m07-sh2:27017').shardAdded
sh2
[direct: mongos] test> db.getSiblingDB('config').shards.find()
[
  {
    _id: 'sh1',
    host: 'sh1/m07-sh1:27017',
    state: 1,
    topologyTime: Timestamp({ t: 1790514860, i: 10 }),
    replSetConfigVersion: Long('-1')
  },
  {
    _id: 'sh2',
    host: 'sh2/m07-sh2:27017',
    state: 1,
    topologyTime: Timestamp({ t: 1790514860, i: 28 }),
    replSetConfigVersion: Long('-1')
  }
]
[direct: mongos] test> db.getSiblingDB('config').mongos.find({}, {_id: 1, mongoVersion: 1})
[
  { _id: 'm07-mongos:27017', mongoVersion: '8.0.32' },
  { _id: 'm07-mongos:27018', mongoVersion: '8.0.32' }
]
```

- 샤드는 `레플리카셋 이름/멤버 주소` 형식으로 등록되고, 레플리카셋 이름이 샤드 ID(`sh1`, `sh2`)가 됩니다. mongos는 이 주소로 샤드의 레플리카셋 전체를 찾아가므로 샤드의 primary가 바뀌어도 따라갑니다.
- `config.mongos`에는 떠 있는 mongos가 스스로 등록되어 있습니다. mongos는 데이터를 갖지 않지만 자기 존재는 config server에 알립니다.

`config` 데이터베이스에서 이 글에 나오는 컬렉션은 다음과 같습니다.

| 컬렉션 | 내용 |
|---|---|
| `config.shards` | 샤드 목록과 주소 |
| `config.databases` | 데이터베이스마다 primary shard(샤딩하지 않은 컬렉션이 기본으로 놓이는 샤드) |
| `config.collections` | 샤딩된(또는 추적되는) 컬렉션의 shard key, UUID |
| `config.chunks` | chunk마다 범위(`min`, `max`), 소유 샤드, 버전(`lastmod`) |
| `config.settings` | chunk 크기, balancer 설정 |
| `config.changelog` | shardCollection, chunk 이동 같은 메타데이터 변경 기록 |

## shard key와 chunk

컬렉션을 샤딩할 때 **shard key**를 하나 정합니다. shard key는 도큐먼트의 필드(또는 여러 필드)이고, 클러스터는 이 키의 값 공간을 연속된 구간으로 잘라 샤드에 나눠 줍니다. 그 구간 하나가 **chunk**입니다. chunk는 `[min, max)` 반열린 구간이고, 전체 chunk를 이어 붙이면 `MinKey`부터 `MaxKey`까지 빈틈없이 덮습니다. 어떤 도큐먼트가 어느 샤드에 있는지는 "그 도큐먼트의 shard key 값이 어느 chunk에 속하는가"로 정해집니다.

chunk는 **메타데이터의 단위**이지 저장의 단위가 아닙니다. 샤드 안에서 한 컬렉션은 chunk와 상관없이 WiredTiger 테이블 하나([1편](/posts/mongodb/01-wiredtiger-architecture/))이고, chunk는 config server의 `config.chunks`에 있는 도큐먼트 한 줄일 뿐입니다. 그래서 chunk를 "옮긴다"는 것은 그 범위의 도큐먼트를 다른 샤드의 테이블로 복사하고, `config.chunks`의 소유 샤드를 바꾸는 일입니다.

#### range shard key로 샤딩하기

`shop` 데이터베이스의 primary shard를 `sh1`로 정하고, `orders` 컬렉션을 `customerId`로 샤딩합니다.

```mongosh
[direct: mongos] test> db.getSiblingDB('config').settings.find()
[direct: mongos] test> db.adminCommand({enableSharding: 'shop', primaryShard: 'sh1'}).ok
1
[direct: mongos] test> sh.shardCollection('shop.orders', {customerId: 1}).collectionsharded
shop.orders
[direct: mongos] test> db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}, {key: 1, unique: 1, uuid: 1, timestamp: 1})
{
  _id: 'shop.orders',
  timestamp: Timestamp({ t: 1790514860, i: 64 }),
  uuid: UUID('a25230b3-f5d2-467e-955e-8f77b5680469'),
  key: { customerId: 1 },
  unique: false
}
[direct: mongos] test> const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou}, {_id: 0, min: 1, max: 1, shard: 1, lastmod: 1})
[
  {
    min: { customerId: MinKey() },
    max: { customerId: MaxKey() },
    shard: 'sh1',
    lastmod: Timestamp({ t: 1, i: 0 })
  }
]
```

- `config.settings`가 비어 있습니다. 설정하지 않은 값은 기본값을 씁니다. 8.0의 기본 chunk 크기는 128MB입니다([`balancer_configuration.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/balancer_configuration.cpp#L136)).
- `config.collections`에 shard key `{ customerId: 1 }`(오름차순 range 키)와 컬렉션 UUID가 기록되었습니다. `config.chunks`는 이름이 아니라 이 UUID로 컬렉션을 가리킵니다.
- 빈 컬렉션을 range 키로 샤딩하면 `MinKey`부터 `MaxKey`까지 전체를 덮는 **chunk 하나**가 primary shard `sh1`에 생깁니다([`SingleChunkOnPrimarySplitPolicy`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/config/initial_split_policy.cpp#L389-L407)). 첫 chunk를 어떻게 만들지 고르는 곳을 보면([`create_collection_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/create_collection_coordinator.cpp#L202-L221)), 빈 컬렉션을 미리 나누는 경우는 hashed 키와 zone뿐이고, 나머지는 데이터가 이미 있든 없든 chunk 하나로 시작합니다. 나누는 일은 뒤에서 볼 balancer가 합니다.
- `lastmod: Timestamp({ t: 1, i: 0 })`은 chunk 버전 `1|0`입니다. 이 버전은 [shard version](#shard-version과-stale-config)에서 다시 봅니다.

### range와 hashed

shard key에는 두 방식이 있습니다.

| 방식 | chunk가 나누는 것 | 장점 | 단점 |
|---|---|---|---|
| range (`{k: 1}`) | 키 값 자체의 범위 | 범위 쿼리가 소수의 샤드로 감 | 단조 증가 키면 새 쓰기가 한 샤드로 몰림 |
| hashed (`{k: 'hashed'}`) | 키 값의 64비트 해시의 범위 | 쓰기가 샤드에 고르게 퍼짐 | 범위 쿼리는 모든 샤드로 감 |

hashed 키로 빈 컬렉션을 샤딩하면, 해시 공간을 샤드 수만큼 미리 나눠 샤드마다 chunk를 하나씩 줍니다([`initial_split_policy.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/config/initial_split_policy.cpp#L442-L450)). 해시 값은 데이터를 보지 않아도 고르게 퍼질 것을 알기 때문입니다(8.0 이전 FCV에서는 샤드마다 2개).

#### hashed shard key: 빈 컬렉션도 샤드마다 chunk

```mongosh
[direct: mongos] test> sh.shardCollection('shop.users', {userId: 'hashed'}).collectionsharded
shop.users
[direct: mongos] test> const uu = db.getSiblingDB('config').collections.findOne({_id: 'shop.users'}).uuid; db.getSiblingDB('config').chunks.find({uuid: uu}, {_id: 0, min: 1, max: 1, shard: 1})
[
  { min: { userId: MinKey() }, max: { userId: Long('0') }, shard: 'sh2' },
  { min: { userId: Long('0') }, max: { userId: MaxKey() }, shard: 'sh1' }
]
[direct: mongos] test> use shop
switched to db shop
[direct: mongos] shop> for (let b = 0; b < 10; b++) { const docs = []; for (let i = 0; i < 2000; i++) { docs.push({userId: b * 2000 + i, name: 'u' + (b * 2000 + i)}); } db.users.insertMany(docs); } 'inserted'
inserted
[direct: mongos] shop> db.users.getShardDistribution()
Shard sh1 at sh1/m07-sh1:27017
{
  data: '485KiB',
  docs: 9860,
  chunks: 1,
...
}
---
Shard sh2 at sh2/m07-sh2:27017
{
  data: '499KiB',
  docs: 10140,
  chunks: 1,
...
}
...
```

- chunk 경계가 `Long('0')`입니다. 키 값이 아니라 해시 값(부호 있는 64비트 정수)의 공간을 음수 절반(`sh2`)과 양수 절반(`sh1`)으로 나눴습니다.
- `userId`를 0부터 19999까지 **순서대로** 넣었는데도 9860건과 10140건으로 거의 반씩 나뉘었습니다. 연속된 값이라도 해시하면 흩어지기 때문입니다.

## 쿼리 라우팅: targeted와 scatter-gather

mongos는 쿼리 조건에서 shard key에 대한 조건을 뽑아, routing table에서 그 값이나 범위가 걸리는 chunk를 찾고, 그 chunk들을 가진 샤드에만 쿼리를 보냅니다. 조건에 shard key가 없으면 어느 샤드에 있을지 알 수 없으므로 **모든 샤드**에 보내고 결과를 합칩니다(scatter-gather, broadcast). explain의 최상위 stage 이름이 이 결정을 보여 줍니다([`ClusterExplain::getStageNameForReadOp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/commands/cluster_explain.cpp#L216-L224)).

| stage | 뜻 |
|---|---|
| `SINGLE_SHARD` | 샤드 하나에만 보냄 |
| `SHARD_MERGE` | 여러 샤드에 보내고 결과를 합침 |
| `SHARD_MERGE_SORT` | 여러 샤드에 보내고 정렬을 유지하며 합침 |

아래 실습은 `orders`에 8만 건을 넣고 balancer가 chunk를 나눠 옮긴 [뒤의 상태](#balancer-데이터-크기를-맞춘다)에서 한 것입니다. 이때 `customerId`가 37840보다 작은 범위는 `sh2`에, 나머지는 `sh1`에 있었습니다.

#### shard key로 찾으면 한 샤드, 아니면 모든 샤드

```mongosh
[direct: mongos] shop> function route(e) { const p = e.queryPlanner.winningPlan; return {stage: p.stage, shards: p.shards.map(s => s.shardName)}; }
[Function: route]
[direct: mongos] shop> route(db.orders.find({customerId: 12345}).explain())
{ stage: 'SINGLE_SHARD', shards: [ 'sh2' ] }
[direct: mongos] shop> route(db.orders.find({status: 'cancelled', amount: 5}).explain())
{ stage: 'SHARD_MERGE', shards: [ 'sh1', 'sh2' ] }
[direct: mongos] shop> route(db.orders.find({customerId: {$gte: 100, $lt: 200}}).explain())
{ stage: 'SINGLE_SHARD', shards: [ 'sh2' ] }
[direct: mongos] shop> route(db.orders.find({customerId: {$gte: 0, $lt: 80000}}).explain())
{ stage: 'SHARD_MERGE', shards: [ 'sh1', 'sh2' ] }
```

- shard key 값 하나(`customerId: 12345`)는 chunk 하나에 속하므로 `SINGLE_SHARD`로 `sh2`에만 갑니다.
- shard key가 없는 조건(`status`, `amount`)은 모든 샤드로 갑니다.
- range 키에서는 범위 조건도 그 범위가 걸치는 chunk의 샤드로만 갑니다. 100~199는 `sh2` 한 곳, 0~79999는 두 샤드 모두입니다.

hashed 컬렉션에서는 같은 범위 조건이라도 달라집니다.

```mongosh
[direct: mongos] shop> route(db.users.find({userId: 777}).explain())
{ stage: 'SINGLE_SHARD', shards: [ 'sh2' ] }
[direct: mongos] shop> route(db.users.find({userId: {$gte: 100, $lt: 110}}).explain())
{ stage: 'SHARD_MERGE', shards: [ 'sh1', 'sh2' ] }
```

`userId: 777` 같은 동등 조건은 해시해서 chunk를 찾으면 되니 한 샤드로 가지만, `100 <= userId < 110`처럼 10개짜리 좁은 범위도 해시 값으로는 어디든 흩어져 있을 수 있어 모든 샤드로 갑니다.

#### scatter-gather의 비용

```mongosh
[direct: mongos] shop> const x = db.orders.find({status: 'cancelled', amount: 5}).explain('executionStats').executionStats; ({nReturned: x.nReturned, totalDocsExamined: x.totalDocsExamined, shards: x.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned, docsExamined: s.totalDocsExamined}))})
{
  nReturned: 8,
  totalDocsExamined: 117840,
  shards: [
    { shard: 'sh2', nReturned: 4, docsExamined: 37840 },
    { shard: 'sh1', nReturned: 4, docsExamined: 80000 }
  ]
}
[direct: mongos] shop> const y = db.orders.find({customerId: 12345}).explain('executionStats').executionStats; ({nReturned: y.nReturned, totalDocsExamined: y.totalDocsExamined, shards: y.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned, docsExamined: s.totalDocsExamined}))})
{
  nReturned: 1,
  totalDocsExamined: 1,
  shards: [ { shard: 'sh2', nReturned: 1, docsExamined: 1 } ]
}
```

- `status` 쿼리는 8건을 돌려주려고 두 샤드가 각자 컬렉션 전체를 훑었습니다(인덱스가 없으므로 [4편](/posts/mongodb/04-index-and-query-planner/)의 COLLSCAN). 합계 `totalDocsExamined`가 117840으로, 컬렉션의 8만 건보다 많습니다. `sh1`이 80000건을 읽은 것은, 이미 `sh2`로 옮겨 간 37840건이 [orphan](#orphan과-range-deleter)으로 `sh1`에 아직 남아 있어서입니다. 샤드는 이 도큐먼트를 읽기는 하지만, 자기 소유가 아니므로 결과에서는 걸러 냅니다(`SHARDING_FILTER` stage, [`shard_filter.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/shard_filter.cpp#L55)).
- `customerId` 쿼리는 한 샤드에서 1건만 읽었습니다(`_id`가 아니어도 shard key에는 인덱스가 반드시 있습니다).

scatter-gather는 샤드 수만큼 일을 늘립니다. 샤드가 10개면 결과가 몇 건이든 10개 샤드가 모두 쿼리를 실행하고, mongos는 가장 느린 샤드의 응답까지 기다립니다.

## balancer: 데이터 크기를 맞춘다

8.0에는 쓰기 도중 chunk를 크기에 맞춰 자르는 과정이 없습니다. chunk 하나가 아무리 커져도 그대로 있다가, balancer가 샤드 사이의 **데이터 크기 차이**를 보고 옮길 때 잘립니다.

balancer는 config server primary에서 도는 스레드입니다([`Balancer::_mainThread()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer.cpp#L1000)). 한 라운드가 끝나면 기본 10초 쉬고([`balancer.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer.cpp#L133)) 다음 라운드를 돕니다. 라운드마다 샤딩된 컬렉션별로 샤드의 데이터 크기를 모으고, [`BalancerPolicy::_singleZoneBalanceBasedOnDataSize()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp#L726)로 옮길지 정합니다.

1. 가장 많이 가진 샤드(from)와 가장 적게 가진 샤드(to)를 고릅니다.
2. from이 이상적인 크기(전체 / 샤드 수)보다 크고 to가 그보다 작을 때만([`balancer_policy.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp#L768-L775)),
3. 두 샤드의 차이가 **chunk 크기의 3배 이상**이면 옮깁니다([`balancer_policy.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp#L777-L780)). 기본 chunk 크기 128MB에서는 384MB입니다.
4. from의 chunk 가운데 jumbo가 아닌 것의 `min`만 정해 `moveRange`를 요청합니다. `max`는 비워 둡니다([`balancer_policy.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp#L788-L800)). 원본 샤드가 `min`부터 chunk 크기만큼 되는 지점을 찾아 `max`로 삼습니다([`computeOtherBound()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L132-L146)). 옮길 때 chunk가 잘리는 것이 이 단계입니다.

샤드별 데이터 크기는 샤드가 보고하는 값이고, 컬렉션 크기에서 orphan 도큐먼트를 뺀 값입니다([`shardsvr_get_stats_for_balancing_command.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/shardsvr_get_stats_for_balancing_command.cpp#L139-L150)).

#### chunk 크기를 1MB로 줄이고 데이터를 넣으면

실습에서는 기본 128MB로는 이동을 보기 어려워 `config.settings`의 chunk 크기를 1MB로 줄였습니다. 그리고 `orders`에 도큐먼트 8만 건을 `customerId` 0부터 순서대로 넣었습니다.

```mongosh
[direct: mongos] test> db.getSiblingDB('config').settings.updateOne({_id: 'chunksize'}, {$set: {value: 1}}, {upsert: true}).acknowledged
true
[direct: mongos] test> use shop
switched to db shop
[direct: mongos] shop> const pad = 'x'.repeat(200); for (let b = 0; b < 40; b++) { const docs = []; for (let i = 0; i < 2000; i++) { const c = b * 2000 + i; docs.push({customerId: c, status: c % 10 === 0 ? 'cancelled' : 'paid', amount: c % 997, pad: pad}); } db.orders.insertMany(docs); } 'inserted'
inserted
[direct: mongos] shop> db.orders.countDocuments()
80000
[direct: mongos] shop> sh.balancerCollectionStatus('shop.orders')
{
  chunkSize: 1,
  balancerCompliant: false,
  firstComplianceViolation: 'chunksImbalance',
...
}
```

넣은 직후 `balancerCollectionStatus`는 `balancerCompliant: false`, 이유는 `chunksImbalance`입니다. 모든 데이터가 `sh1`의 chunk 하나에 있으니 당연합니다. 약 15초 뒤 `balancerCompliant: true`가 되었습니다. 그때의 상태입니다.

```mongosh
[direct: mongos] shop> db.orders.aggregate([{$collStats: {storageStats: {}}}, {$project: {_id: 0, shard: 1, count: '$storageStats.count', numOrphanDocs: '$storageStats.numOrphanDocs'}}, {$sort: {shard: 1}}])
[
  { shard: 'sh1', count: 80000, numOrphanDocs: 37840 },
  { shard: 'sh2', count: 37840, numOrphanDocs: 0 }
]
[direct: mongos] shop> const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.aggregate([{$match: {uuid: ou}}, {$group: {_id: '$shard', chunks: {$sum: 1}}}, {$sort: {_id: 1}}])
[ { _id: 'sh1', chunks: 1 }, { _id: 'sh2', chunks: 10 } ]
[direct: mongos] shop> db.getSiblingDB('config').chunks.find({uuid: ou}, {_id: 0, min: 1, max: 1, shard: 1}).sort({min: 1}).limit(4)
[
  {
    min: { customerId: MinKey() },
    max: { customerId: 3784 },
    shard: 'sh2'
  },
  { min: { customerId: 3784 }, max: { customerId: 7568 }, shard: 'sh2' },
  { min: { customerId: 7568 }, max: { customerId: 11352 }, shard: 'sh2' },
  {
    min: { customerId: 11352 },
    max: { customerId: 15136 },
    shard: 'sh2'
  }
]
```

- balancer가 `sh1`의 chunk 앞쪽부터 3784건(약 1MB)씩 10번 잘라 `sh2`로 옮겼습니다. `sh2`에는 1MB짜리 chunk 10개(37840건), `sh1`에는 나머지 42160건이 든 chunk 하나가 남았습니다.
- 아래 `moveChunk.commit`에서 보듯 한 번에 3784건, 1050063바이트를 옮겼으므로 도큐먼트 하나가 약 277바이트입니다. 이 값으로 계산하면 `sh2`가 약 10.5MB, `sh1`이 약 11.7MB(42160건)이고, 차이가 3MB(chunk 크기의 3배)보다 작아 balancer가 멈췄습니다. balancer는 "chunk 수"가 아니라 "데이터 크기"를 맞춘다는 것이 chunk 수 1 대 10에서 보입니다.
- `sh1`의 `count`가 아직 80000이고 그중 37840이 `numOrphanDocs`입니다. 옮긴 도큐먼트가 원본에서 아직 지워지지 않았습니다. [뒤에서](#orphan과-range-deleter) 봅니다.

```mongosh
[direct: mongos] shop> db.getSiblingDB('config').changelog.aggregate([{$match: {ns: 'shop.orders'}}, {$group: {_id: '$what', n: {$sum: 1}}}, {$sort: {_id: 1}}])
[
  { _id: 'moveChunk.commit', n: 10 },
  { _id: 'moveChunk.from', n: 10 },
  { _id: 'moveChunk.start', n: 10 },
  { _id: 'moveChunk.to', n: 10 },
  { _id: 'shardCollection.end', n: 1 },
  { _id: 'shardCollection.start', n: 1 }
]
[direct: mongos] shop> db.getSiblingDB('config').changelog.find({ns: 'shop.orders', what: 'moveChunk.commit'}, {_id: 0, time: 1, what: 1, details: 1}).sort({time: 1}).limit(1)
[
  {
    time: ISODate('2026-09-27T13:14:25.547Z'),
    what: 'moveChunk.commit',
    details: {
      min: { customerId: MinKey() },
      max: { customerId: 3784 },
      from: 'sh1',
      to: 'sh2',
      counts: {
        cloned: Long('3784'),
        clonedBytes: Long('1050063'),
        catchup: Long('0'),
        steady: Long('0')
      }
...
]
```

`config.changelog`에는 이동마다 `moveChunk.start`, `.to`, `.from`, `.commit`이 하나씩, 모두 10번 남았습니다. 첫 이동은 3784건, 1050063바이트(1MB 남짓)를 복제했습니다. `catchup`과 `steady`가 0인 것은 복제하는 동안 그 범위에 새 쓰기가 없었다는 뜻입니다.

balancer가 config server에서 돈다는 것은 config server의 로그로도 보입니다.

```console
$ jq -r 'select(.msg | test("alanc")) | .msg' /data/mongod.log | sort | uniq -c
      1 Balancer command scheduler start requested
      1 Balancer scheduler recovery complete. Switching to regular execution
      1 Balancer scheduler thread started
      1 Balancer worker thread initialised. Entering main loop.
      1 CSRS balancer is starting
      1 Performing balancer warning checks
```

## chunk migration: 옮기는 동안에도 쓰기는 계속된다

balancer든 사용자든 chunk 이동은 원본 샤드에 `moveRange` 명령을 보내는 것으로 시작하고, 원본 샤드가 절차를 이끕니다([`shardsvr_move_range_command.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/shardsvr_move_range_command.cpp#L263-L270)).

```cpp
MigrationSourceManager migrationSourceManager(
    opCtx, std::move(request), std::move(writeConcern), donorConnStr, recipientHost);

migrationSourceManager.startClone();
migrationSourceManager.awaitToCatchUp();
migrationSourceManager.enterCriticalSection();
migrationSourceManager.commitChunkOnRecipient();
migrationSourceManager.commitChunkMetadataOnConfig();
```

{{< diagram src="/diagrams/mongo-chunk-migration.html" title="chunk migration (moveRange) 한 번의 단계" height="560" caption="받는 샤드가 도큐먼트를 끌어가 복제하는 동안 원본은 쓰기를 계속 받습니다. 쓰기를 막는 것은 마지막 변경분을 넘기고 config server에 commit하는 짧은 critical section뿐이고, 원본에 남은 도큐먼트는 나중에 range deleter가 지웁니다." >}}

1. **범위 확정, 복제 시작** ([`startClone()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L402)): 옮길 범위를 정하고 받는 샤드에 복제를 시작하라고 알립니다. 이때부터 원본은 그 범위에 들어오는 쓰기를 따로 기록해 둡니다.
2. **도큐먼트 복제**: 받는 샤드가 원본에 `_migrateClone`을 보내 범위 안의 도큐먼트를 배치로 끌어가 자기 컬렉션에 넣습니다.
3. **변경분 따라잡기** ([`awaitToCatchUp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L501)): 복제하는 동안 생긴 변경을 받는 샤드가 `_transferMods`로 가져가 적용합니다. 남은 변경이 충분히 적어질 때까지 반복합니다.
4. **critical section** ([`enterCriticalSection()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L518)): 원본이 그 컬렉션의 쓰기를 막고(읽기는 commit 직전까지 허용), 마지막 변경분을 넘깁니다.
5. **commit** ([`commitChunkMetadataOnConfig()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L603)): config server가 `config.chunks`의 소유 샤드를 바꾸고, 옮긴 chunk의 버전을 **major + 1**로 올립니다([`commitChunkMigration()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/config/sharding_catalog_manager_chunk_operations.cpp#L1613-L1623)). 이것으로 critical section이 끝나고, 막혔던 쓰기는 새 소유 샤드로 다시 라우팅됩니다.
6. **정리**: 원본에 남은 도큐먼트를 지우는 작업(range deletion)을 예약합니다.

쓰기가 막히는 시간은 4~5단계뿐입니다. 도큐먼트 복제는 쓰기와 동시에 진행됩니다.

#### 수동 moveRange와 migration 로그

balancer를 멈춘 상태에서 `sh1`의 마지막 chunk(`customerId` 37840 이상)를 `sh2`로 직접 옮깁니다. `max`는 주지 않고 `waitForDelete: true`로 원본 정리까지 기다리게 했습니다.

```mongosh
[direct: mongos] test> db.adminCommand({moveRange: 'shop.orders', min: {customerId: 37840}, toShard: 'sh2', waitForDelete: true}).ok
1
[direct: mongos] test> const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou, 'min.customerId': {$gte: 37840}}, {_id: 0, min: 1, max: 1, shard: 1, lastmod: 1}).sort({min: 1})
[
  {
    min: { customerId: 37840 },
    max: { customerId: 41624 },
    shard: 'sh2',
    lastmod: Timestamp({ t: 12, i: 0 })
  },
  {
    min: { customerId: 41624 },
    max: { customerId: MaxKey() },
    shard: 'sh1',
    lastmod: Timestamp({ t: 12, i: 1 })
  }
]
[direct: mongos] test> db.getSiblingDB('config').changelog.find({ns: 'shop.orders', what: 'moveChunk.from'}, {_id: 0, what: 1, details: 1}).sort({time: -1}).limit(1)
[
  {
    what: 'moveChunk.from',
    details: {
      'step 1 of 6': 0,
      'step 2 of 6': 2,
      'step 3 of 6': 9,
      'step 4 of 6': 104,
      'step 5 of 6': 15,
      'step 6 of 6': 54,
      min: { customerId: 37840 },
      max: { customerId: 41624 },
      to: 'sh2',
      from: 'sh1',
      note: 'success'
    }
  }
]
```

- `[37840, MaxKey)` chunk가 `[37840, 41624)`와 `[41624, MaxKey)`로 잘렸고, 앞쪽 3784건만 `sh2`로 갔습니다. `max`를 주지 않자 원본이 chunk 크기(1MB)로 경계를 정한 것입니다.
- 옮긴 chunk의 버전이 `12|0`, 원본에 남은 chunk가 `12|1`입니다. 그 전 최대 버전이 `11|x`(balancer 이동 10번)였으므로 major가 하나 올라갔습니다.
- `moveChunk.from`의 단계별 시간(ms)은 원본 샤드가 잰 것입니다. `step 4`(복제와 따라잡기, [`awaitToCatchUp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp#L501-L513)까지)가 104ms로 가장 길고, 쓰기를 막는 critical section과 받는 샤드의 commit(`step 5`)은 15ms였습니다. `step 6`(config commit과 `waitForDelete` 대기)이 54ms입니다.

원본 샤드(`sh1`)의 로그입니다.

```console
$ jq -c 'select(.c == "MIGRATE" or .c == "RANGEDEL") | {t: .t."$date", c, msg}' /data/mongod.log | tail -12
...
{"t":"2026-09-27T13:14:55.613+00:00","c":"MIGRATE","msg":"Starting chunk migration donation"}
{"t":"2026-09-27T13:14:55.730+00:00","c":"MIGRATE","msg":"Migration successfully entered critical section"}
{"t":"2026-09-27T13:14:55.750+00:00","c":"MIGRATE","msg":"Migration succeeded and updated collection placement version"}
{"t":"2026-09-27T13:14:55.750+00:00","c":"MIGRATE","msg":"Exiting commit critical section"}
{"t":"2026-09-27T13:14:55.750+00:00","c":"MIGRATE","msg":"Finished critical section"}
{"t":"2026-09-27T13:14:55.750+00:00","c":"MIGRATE","msg":"MigrationCoordinator delivering decision to self and to recipient"}
{"t":"2026-09-27T13:14:55.761+00:00","c":"MIGRATE","msg":"Waiting for migration cleanup after chunk commit"}
{"t":"2026-09-27T13:14:55.802+00:00","c":"MIGRATE","msg":"Unregistering donate chunk"}
$ jq -c 'select(.msg == "Migration finished") | .attr' /data/mongod.log | tail -1
{"migrationId":"1b6d9bd6-a654-4816-b64c-98d0be8f1eed","totalTimeMillis":187,"docsCloned":3784,"bytesCloned":1050063,"cloneTime":111}
```

받는 샤드(`sh2`)의 로그입니다.

```console
$ jq -c 'select(.c == "MIGRATE") | {t: .t."$date", msg}' /data/mongod.log | tail -5
{"t":"2026-09-27T13:14:55.730+00:00","msg":"Chunk data replicated successfully."}
{"t":"2026-09-27T13:14:55.744+00:00","msg":"Migration commit succeeded flushing to secondaries"}
{"t":"2026-09-27T13:14:55.746+00:00","msg":"Entered migration recipient critical section"}
{"t":"2026-09-27T13:14:55.751+00:00","msg":"Exited migration recipient critical section"}
{"t":"2026-09-27T13:14:55.755+00:00","msg":"clearReceiveChunk"}
```

- 원본은 `.613`에 시작해 `.730`에 critical section에 들어갔고, `.750`에 config commit과 placement version 갱신까지 끝냈습니다. critical section은 약 20ms였습니다. 그 사이 받는 샤드는 `.730`에 복제를 마치고(`Chunk data replicated successfully.`), 자기 쪽 critical section을 `.746`~`.751`에 거쳤습니다.
- `Waiting for migration cleanup after chunk commit`은 `waitForDelete: true` 때문에 원본의 도큐먼트 삭제를 기다린 것입니다. 약 40ms 뒤 끝났습니다.
- `Migration finished`의 요약: 전체 187ms, 3784건, 1050063바이트, 복제에 111ms.

## shard version과 stale config

mongos는 routing table을 캐시해 두고 쓰므로, 다른 mongos나 balancer가 chunk를 옮기면 그 캐시가 낡습니다. MongoDB는 캐시를 매번 확인하는 대신 **버전**으로 낡은 것을 알아챕니다.

- chunk마다 버전(`lastmod`, `major|minor`)이 있고, 샤드의 **placement version**은 그 샤드가 가진 chunk 중 가장 높은 버전입니다. 이동하면 major가, 분할과 병합이면 minor가 오릅니다.
- mongos는 샤드에 요청을 보낼 때 자기 routing table 기준의 그 샤드 버전(**shard version**)을 붙입니다.
- 샤드는 받은 버전을 자기가 아는 버전과 비교해([`_getMetadataWithVersionCheckAt()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/collection_sharding_runtime.cpp#L554-L579)), 맞지 않으면 `StaleConfig` 오류를 돌려줍니다. migration의 critical section 중에도 같은 오류로 요청을 잠시 돌려보냅니다([`collection_sharding_runtime.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/collection_sharding_runtime.cpp#L505-L522)).
- mongos는 `StaleConfig`를 받으면 그 컬렉션의 캐시를 무효화하고([`CollectionRouterCommon::_onException()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/router_role.cpp#L165-L181)), config server에서 새 routing table을 받아 **요청을 다시 보냅니다**. 재시도는 최대 10번입니다([`catalog_cache.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/catalog_cache.h#L66)).

애플리케이션은 이 과정을 보지 못합니다. 응답이 조금 늦어질 뿐입니다.

#### 옛 routing table을 가진 mongos

두 번째 mongos(B, 포트 27018)는 앞의 `moveRange` 전에 `orders`를 한 번 조회해 routing table을 캐시해 두었습니다. 이 mongos의 프롬프트 앞에 `B`를 붙입니다.

```mongosh
B [direct: mongos] shop> db.orders.countDocuments({customerId: {$gte: 37840, $lt: 37940}})
100
B [direct: mongos] shop> db.adminCommand({getShardVersion: 'shop.orders'}).version
Timestamp({ t: 11, i: 1 })
```

그 뒤 첫 mongos로 `[37840, 41624)`를 `sh2`로 옮겼습니다(앞 절의 `moveRange`). 이제 B에서 같은 범위를 다시 조회합니다.

```mongosh
B [direct: mongos] test> db.adminCommand({getShardVersion: 'shop.orders'}).version
Timestamp({ t: 11, i: 1 })
B [direct: mongos] shop> db.orders.countDocuments({customerId: {$gte: 37840, $lt: 37940}})
100
B [direct: mongos] shop> db.adminCommand({getShardVersion: 'shop.orders'}).version
Timestamp({ t: 12, i: 1 })
```

```text
# sh1 countStaleConfigErrors: Long('1') -> Long('2')
# sh2 countStaleConfigErrors: Long('0') -> Long('0')
```

```console
$ jq -c 'select(.msg == "Refreshed cached collection" and .attr.namespace == "shop.orders") | {t: .t."$date", msg, newVersion: (.attr.newVersion | capture("v: (?<v>Timestamp\\([0-9, ]+\\))").v), durationMillis: .attr.durationMillis}' /data/mongos-b.log
{"t":"2026-09-27T13:14:44.177+00:00","msg":"Refreshed cached collection","newVersion":"Timestamp(11, 1)","durationMillis":0}
{"t":"2026-09-27T13:14:56.974+00:00","msg":"Refreshed cached collection","newVersion":"Timestamp(12, 1)","durationMillis":0}
```

- 이동 뒤에도 B의 캐시는 `11|1`에 머물러 있었습니다. mongos는 다른 곳에서 일어난 이동을 스스로 알아채지 않습니다.
- 조회 결과는 정확히 100건이었습니다. B는 옛 routing table대로 이 범위를 `sh1`에 보냈고, `sh1`은 버전이 맞지 않아 `StaleConfig`로 돌려보냈습니다. `sh1`의 `serverStatus().shardingStatistics.countStaleConfigErrors`가 1 늘었습니다(`sh2`는 그대로).
- B의 로그에는 routing table을 두 번 받은 기록이 있습니다. 첫 조회 때 `11|1`, `StaleConfig`를 받은 뒤 `12|1`입니다. 새 버전으로 `sh2`에 다시 보낸 결과가 100건이었습니다.

## orphan과 range deleter

chunk를 옮긴 뒤 원본 샤드에 남은 도큐먼트를 **orphan**이라고 합니다. 원본은 commit 직후 바로 지우지 않고, 삭제 작업을 `config.rangeDeletions`에 기록해 두었다가 `orphanCleanupDelaySecs`(기본 900초, [`sharding_runtime_d_params.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/sharding_runtime_d_params.idl#L161-L167)) 뒤에 **range deleter**가 지웁니다([`range_deleter_service.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/range_deleter_service.cpp#L597)). 이동 직전에 시작된 쿼리가 원본에서 아직 그 도큐먼트를 읽고 있을 수 있기 때문입니다. `waitForDelete`를 주면 이 지연 없이 곧바로 지웁니다([`migration_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_coordinator.cpp#L152-L153)).

orphan은 mongos를 거친 쿼리에는 보이지 않습니다. 샤드가 자기 소유 범위가 아닌 도큐먼트를 결과에서 거르기 때문입니다. 샤드에 직접 접속하면 보입니다.

#### balancer 이동 뒤의 원본 샤드

balancer가 10번 옮긴 직후 `sh1`에 직접 접속해 봤습니다(프롬프트의 `sh1 [direct: primary]`).

```mongosh
sh1 [direct: primary] test> db.getSiblingDB('config').rangeDeletions.find({}, {_id: 0, nss: 1, range: 1, whenToClean: 1, numOrphanDocs: 1}).limit(3)
[
  {
    nss: 'shop.orders',
    range: { min: { customerId: MinKey() }, max: { customerId: 3784 } },
    whenToClean: 'delayed',
    numOrphanDocs: Long('3784')
  },
...
]
sh1 [direct: primary] test> db.getSiblingDB('config').rangeDeletions.countDocuments()
10
sh1 [direct: primary] test> db.getSiblingDB('shop').orders.countDocuments()
80000
sh1 [direct: primary] test> db.adminCommand({getParameter: 1, orphanCleanupDelaySecs: 1}).orphanCleanupDelaySecs
900
```

```mongosh
[direct: mongos] shop> db.orders.countDocuments()
80000
```

- 이동 10번마다 삭제 작업이 하나씩, `whenToClean: 'delayed'`로 예약되어 있습니다. `numOrphanDocs`가 범위마다 3784입니다.
- `sh1`에 직접 세면 80000건입니다. 이미 `sh2`로 넘어간 37840건이 여기 그대로 있습니다. mongos로 세면 전체가 정확히 80000건입니다. orphan은 걸러졌습니다.

#### waitForDelete로 옮긴 범위는 바로 지워진다

앞의 수동 `moveRange`(`waitForDelete: true`) 뒤에 다시 `sh1`에 직접 접속해 봤습니다.

```mongosh
sh1 [direct: primary] test> db.getSiblingDB('shop').orders.countDocuments({customerId: {$gte: 37840, $lt: 41624}})
0
sh1 [direct: primary] test> db.getSiblingDB('shop').orders.countDocuments({customerId: {$lt: 3784}})
3784
sh1 [direct: primary] test> db.getSiblingDB('config').rangeDeletions.countDocuments()
10
```

`waitForDelete`로 옮긴 `[37840, 41624)`는 `sh1`에서 이미 0건이지만, balancer가 옮긴 `[MinKey, 3784)`는 3784건이 아직 남아 있습니다. `rangeDeletions`도 balancer 이동분 10개가 그대로입니다. 900초가 지나야 지워집니다.

#### orphan이 남은 범위는 되돌려 보낼 수 없다

orphan이 남아 있는 동안 그 범위를 원래 샤드로 되돌려 보내면 어떻게 될까요? balancer가 `sh2`로 옮긴 `[MinKey, 3784)`를 곧바로 `sh1`로 옮겨 봤습니다.

```mongosh
[direct: mongos] test> db.adminCommand({moveRange: 'shop.orders', min: {customerId: MinKey}, toShard: 'sh1'})
MongoServerError[OperationFailed]: Command request failed on source shard. :: caused by :: Data transfer error: migrate failed: ExceededTimeLimit: Migration failed because the orphans cleanup routine didn't clear yet a portion of the range being migrated that was previously owned by the recipient shard.
```

받는 쪽이 될 `sh1`의 로그입니다.

```console
$ jq -c 'select(.c == "MIGRATE") | {t: .t."$date", msg}' /data/mongod.log | tail -4
{"t":"2026-09-27T13:14:44.681+00:00","msg":"Migration paused because the requested range overlaps with a range already scheduled for deletion"}
{"t":"2026-09-27T13:14:44.681+00:00","msg":"Waiting for deletion of orphans"}
{"t":"2026-09-27T13:14:54.682+00:00","msg":"Error during migration"}
{"t":"2026-09-27T13:14:54.682+00:00","msg":"clearReceiveChunk"}
```

`sh1`에는 그 범위의 orphan이 아직 있고 삭제가 예약되어 있습니다. 받는 샤드는 같은 범위의 orphan이 지워질 때까지 이동을 멈추고 기다리는데([`migration_destination_manager.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_destination_manager.cpp#L1422)), 그 대기의 상한 `receiveChunkWaitForRangeDeleterTimeoutMS`(기본 10초, [`sharding_runtime_d_params.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/sharding_runtime_d_params.idl#L99-L110))가 지나자 이동이 실패했습니다. 로그의 `.681`과 `.682`가 정확히 10초 차이입니다. 옛 orphan과 새로 받을 도큐먼트가 섞이는 것을 막으려는 동작입니다.

## shard key를 잘못 고르면: 단조 증가 키

`customerId`처럼 계속 커지기만 하는 값(자동 증가 번호, 시각, ObjectId)을 range shard key로 쓰면, 새 도큐먼트는 모두 가장 큰 chunk(`MaxKey`까지 덮는 chunk)로 들어갑니다. 그 chunk는 한 샤드에만 있습니다.

#### 새 도큐먼트가 모두 한 샤드로

balancer를 멈추고, `customerId` 80000부터 99999까지 2만 건을 더 넣었습니다.

```mongosh
[direct: mongos] shop> const ou = db.getSiblingDB('config').collections.findOne({_id: 'shop.orders'}).uuid; db.getSiblingDB('config').chunks.find({uuid: ou, 'max.customerId': MaxKey}, {_id: 0, min: 1, max: 1, shard: 1})
[
  {
    min: { customerId: 37840 },
    max: { customerId: MaxKey() },
    shard: 'sh1'
  }
]
[direct: mongos] shop> sh.stopBalancer().ok
1
[direct: mongos] shop> const pad = 'x'.repeat(200); for (let b = 40; b < 50; b++) { const docs = []; for (let i = 0; i < 2000; i++) { const c = b * 2000 + i; docs.push({customerId: c, status: 'paid', amount: c % 997, pad: pad}); } db.orders.insertMany(docs); } 'inserted'
inserted
[direct: mongos] shop> const z = db.orders.find({customerId: {$gte: 80000}}).explain('executionStats').executionStats; ({nReturned: z.nReturned, shards: z.executionStages.shards.map(s => ({shard: s.shardName, nReturned: s.nReturned}))})
{ nReturned: 20000, shards: [ { shard: 'sh1', nReturned: 20000 } ] }
```

새로 넣은 2만 건이 모두 `sh1`에 있습니다. 샤드가 몇 개든 쓰기는 이 한 샤드가 다 받고, balancer가 나중에 나눠 옮깁니다. 즉 쓰기를 한 번 받고, 옮기면서 한 번 더 복제합니다. 그리고 앞 절의 `moveRange` 결과에서 보듯, 이 2만 건이 더해져 약 5만 8천 건이 된 `[41624, MaxKey)`는 chunk 크기(1MB)를 한참 넘었는데도 chunk 하나로 남아 있었습니다. 쓰기가 chunk를 자르지 않는다는 것이 여기서도 보입니다.

## 8.0: 샤딩하지 않은 컬렉션도 옮길 수 있다

샤드 클러스터에서 샤딩하지 않은 컬렉션은 데이터베이스의 primary shard에 놓입니다. 8.0에는 이런 컬렉션을 다른 샤드로 옮기는 `moveCollection`이 생겼습니다([`cluster_move_collection_cmd.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/commands/cluster_move_collection_cmd.cpp)). 내부적으로는 컬렉션 전체를 새 샤드에 다시 만드는 resharding 기능을 씁니다. 같은 기반으로 shard key를 바꾸는 `reshardCollection`, 샤딩을 해제하는 `unshardCollection`도 있습니다.

#### moveCollection

resharding 작업에는 최소 소요 시간(`reshardingMinimumOperationDurationMillis`, 기본 5분, [`resharding_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/resharding/resharding_server_parameters.idl#L189-L202))이 있어서, 실습에서는 config server에서 이 값을 0으로 낮췄습니다.

```mongosh
cfg [direct: primary] test> db.adminCommand({setParameter: 1, reshardingMinimumOperationDurationMillis: 0}).ok
1
```

```mongosh
[direct: mongos] shop> db.logs.insertMany([{m: 'a'}, {m: 'b'}, {m: 'c'}]).acknowledged
true
[direct: mongos] shop> db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'})
null
[direct: mongos] shop> db.adminCommand({moveCollection: 'shop.logs', toShard: 'sh2'}).ok
1
[direct: mongos] shop> db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'}, {_id: 1, key: 1, unsplittable: 1})
{ _id: 'shop.logs', key: { _id: 1 }, unsplittable: true }
[direct: mongos] shop> const lu = db.getSiblingDB('config').collections.findOne({_id: 'shop.logs'}).uuid; db.getSiblingDB('config').chunks.find({uuid: lu}, {_id: 0, min: 1, max: 1, shard: 1})
[ { min: { _id: MinKey() }, max: { _id: MaxKey() }, shard: 'sh2' } ]
[direct: mongos] shop> db.logs.countDocuments()
3
```

- 옮기기 전 `shop.logs`는 `config.collections`에 없었습니다. primary shard에 있는 샤딩하지 않은 컬렉션은 config server가 따로 추적하지 않습니다.
- 옮긴 뒤에는 `unsplittable: true`, 키 `{ _id: 1 }`로 등록되었고, `MinKey`~`MaxKey` chunk 하나가 `sh2`에 있습니다. "chunk 하나로 고정된 컬렉션"으로 추적해 primary shard가 아닌 샤드에 둘 수 있게 된 것입니다.

## 운영에서는 이렇게 나타납니다

#### shard key는 쿼리와 쓰기 분포를 함께 보고 고른다

shard key는 모든 쿼리 라우팅과 데이터 분포를 정합니다. 가장 흔한 실수는 [위 실습](#새-도큐먼트가-모두-한-샤드로)처럼 단조 증가 값을 range 키로 쓰는 것입니다. 쓰기가 한 샤드에 몰리는 **hot shard**가 생기고, balancer는 그 샤드에서 계속 데이터를 퍼 나르느라 바쁩니다. 반대로 hashed 키는 쓰기를 고르게 퍼뜨리지만 범위 쿼리를 모두 scatter-gather로 만듭니다. 자주 쓰는 쿼리가 어떤 조건으로 찾는지, 새 쓰기의 키 값이 어떻게 분포하는지를 함께 보고, 필요하면 `{tenantId: 1, createdAt: 1}`처럼 분산을 주는 앞 필드와 범위 쿼리용 뒤 필드를 묶은 복합 키를 씁니다. 8.0에서는 잘못 고른 키를 `reshardCollection`으로 바꿀 수 있지만, 컬렉션 전체를 다시 쓰는 무거운 작업입니다.

#### scatter-gather 쿼리는 샤드를 늘릴수록 비싸진다

shard key 조건이 없는 쿼리는 모든 샤드에서 실행됩니다. [위 실습](#scatter-gather의-비용)처럼 8건을 찾으려고 모든 샤드가 전체를 읽을 수도 있고, 샤드를 늘리면 이런 쿼리의 총 비용은 오히려 늘어납니다. 느린 쿼리 로그와 explain에서 `SHARD_MERGE`인 쿼리와 그 `shards` 목록을 확인하고, 자주 쓰는 쿼리라면 shard key를 조건에 넣거나 각 샤드에서 쓸 인덱스를 만듭니다.

#### balancer window와 migration 부하

chunk 이동은 복제와 삭제를 하는 만큼 원본과 받는 샤드 모두에 I/O를 더하고, critical section 동안 그 컬렉션의 쓰기를 잠깐 막습니다. 부하가 큰 시간대를 피하려면 `config.settings`의 balancer 설정에 `activeWindow`(balancer가 도는 시간대)를 정할 수 있습니다([`balancer_configuration.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/balancer_configuration.cpp#L103)). 백업처럼 메타데이터가 바뀌면 안 되는 작업 중에는 `sh.stopBalancer()`로 멈춥니다. 이동 이력은 `config.changelog`의 `moveChunk.*`에, 각 이동의 단계별 시간은 `moveChunk.from`의 `step N of 6`에 남으니, 이동이 느리거나 실패할 때 먼저 봅니다.

#### jumbo chunk

같은 shard key 값을 가진 도큐먼트는 반드시 한 chunk에 있어야 합니다. 그래서 값 하나에 도큐먼트가 몰려 chunk 크기를 넘으면 그 chunk는 잘 수도, 옮길 수도 없는 **jumbo chunk**가 됩니다. balancer는 jumbo chunk를 건너뛰므로([`balancer_policy.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp#L788-L793)) 그 샤드는 계속 무거운 채로 남습니다. 카디널리티가 낮은 필드(상태, 국가 코드 등)만으로 shard key를 만들면 생깁니다. `config.chunks`에 `jumbo: true`가 있는지 확인하고, 근본적으로는 카디널리티를 높이는 필드를 더한 키로 바꿔야 합니다.

#### orphan이 보이는 곳

orphan은 mongos를 거치면 보이지 않지만, 샤드에 직접 접속한 조회, 샤드별 `count`나 `$collStats`의 `count`, 샤드 단위 백업에는 들어 있습니다. [위 실습](#balancer-이동-뒤의-원본-샤드)에서 `sh1`에 직접 세면 8만 건이었던 것처럼, 이동 직후 샤드별 크기를 합치면 실제보다 큽니다. 또 이동 직후 같은 범위를 되돌리는 이동은 orphan이 지워질 때까지(기본 15분) [실패합니다](#orphan이-남은-범위는-되돌려-보낼-수-없다). read concern `available`은 샤드의 orphan 필터링을 건너뛰므로 orphan이 결과에 섞일 수 있습니다([8편](/posts/mongodb/08-read-write-concern/), [`collection_sharding_runtime.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/collection_sharding_runtime.cpp#L485-L487)).

## 정리

- 샤드 클러스터는 라우터 **mongos**, 메타데이터를 가진 **config server** 레플리카셋, 데이터를 나눠 가진 **샤드** 레플리카셋으로 이루어집니다. mongos는 config server의 routing table을 캐시해 요청을 보낼 샤드를 정합니다.
- **shard key**의 값 공간을 `[min, max)` 구간인 **chunk**로 나누고, chunk마다 소유 샤드를 `config.chunks`에 적습니다. range 키는 값 그대로, hashed 키는 해시 값으로 나눕니다.
- shard key 조건이 있으면 해당 chunk의 샤드로만(`SINGLE_SHARD`), 없으면 모든 샤드로(`SHARD_MERGE`) 쿼리가 갑니다.
- 8.0의 **balancer**는 config server primary에서 돌며 샤드 사이 데이터 크기 차이가 chunk 크기의 3배를 넘으면 `moveRange`를 요청하고, 원본 샤드가 chunk 크기만큼 잘라 옮깁니다. 쓰기가 chunk를 자르지는 않습니다.
- **chunk migration**은 복제, 따라잡기, 짧은 critical section, config commit(major 버전 + 1) 순으로 진행되고, 쓰기는 critical section 동안만 막힙니다.
- 낡은 routing table로 보낸 요청은 샤드가 **StaleConfig**로 돌려보내고, mongos가 캐시를 새로 받아 다시 보냅니다.
- 옮긴 뒤 원본에 남는 **orphan**은 기본 15분 뒤 range deleter가 지웁니다. 그동안 직접 조회와 되돌리는 이동에 영향을 줍니다.

다음 글에서는 레플리카셋과 샤드 위에서 클라이언트가 받는 보장, **read concern과 write concern**이 실제로 무엇을 기다리고 무엇을 읽는지를 살펴봅니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/s/catalog_cache.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/catalog_cache.cpp): mongos의 routing table 캐시
- [src/mongo/s/router_role.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/router_role.cpp): StaleConfig를 받은 뒤의 재시도
- [src/mongo/s/commands/cluster_explain.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/s/commands/cluster_explain.cpp): `SINGLE_SHARD`, `SHARD_MERGE`
- [src/mongo/db/s/balancer/balancer.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer.cpp), [balancer_policy.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/balancer/balancer_policy.cpp): balancer 라운드와 이동 기준
- [src/mongo/db/s/migration_source_manager.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_source_manager.cpp): 원본 샤드의 migration 단계
- [src/mongo/db/s/migration_destination_manager.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/migration_destination_manager.cpp): 받는 샤드의 migration
- [src/mongo/db/s/config/sharding_catalog_manager_chunk_operations.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/config/sharding_catalog_manager_chunk_operations.cpp): chunk 이동 commit과 버전
- [src/mongo/db/s/collection_sharding_runtime.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/collection_sharding_runtime.cpp): 샤드의 shard version 확인
- [src/mongo/db/s/range_deleter_service.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/range_deleter_service.cpp): orphan 삭제
- [src/mongo/db/s/config/initial_split_policy.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/s/config/initial_split_policy.cpp): shardCollection 때의 첫 chunk

MongoDB 8.0 공식 문서

- [Sharding](https://www.mongodb.com/docs/v8.0/sharding/)
- [Shard Keys](https://www.mongodb.com/docs/v8.0/core/sharding-shard-key/)
- [Sharded Cluster Balancer](https://www.mongodb.com/docs/v8.0/core/sharding-balancer-administration/)
- [moveCollection](https://www.mongodb.com/docs/v8.0/reference/command/moveCollection/)
