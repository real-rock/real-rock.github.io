---
title: "MongoDB 인터널 4: 인덱스 구조와 쿼리 플래너의 계획 선택 방식"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "인덱스", "쿼리 플래너", "plan cache", "explain", "cached plan was less efficient than expected"]
weight: 4
summary: "인덱스는 디스크에 어떻게 저장되고, MongoDB는 여러 실행 계획 중 하나를 어떻게 고르는가"
description: "KeyString과 RecordId, 후보 계획의 trial 실행과 점수, plan cache의 inactive/active와 replan, ESR, 커버링 쿼리, classic과 SBE"
---

## 개요

[1편](/posts/mongodb/01-wiredtiger-architecture/)에서 컬렉션과 인덱스는 각각 WiredTiger 테이블 파일 하나라고 했고, [3편](/posts/mongodb/03-mvcc-and-snapshot/)에서는 그 테이블 안에서 버전이 어떻게 관리되는지 봤습니다. 이번에는 인덱스 파일 안에 실제로 무엇이 들어 있는지, 그리고 쿼리가 들어왔을 때 MongoDB가 여러 인덱스 가운데 무엇을 쓸지 어떻게 정하는지를 봅니다.

MongoDB의 쿼리 플래너는 PostgreSQL처럼 통계로 비용을 추정하지 않습니다([PG 10편](/posts/postgresql/10-query-processing/)). 쓸 수 있는 계획이 여럿이면 **모두 조금씩 실제로 실행해 보고**, 가장 일을 잘한 계획을 고릅니다. 그리고 그 결과를 **plan cache**에 기록해 같은 모양의 쿼리에 다시 씁니다. 이 방식은 통계가 없어도 되지만, 데이터 분포가 값마다 크게 다르면 캐시된 계획이 어떤 값에서는 나쁜 계획이 되는 문제가 있습니다. 운영에서 "어제까지 빠르던 쿼리가 갑자기 느려졌다"의 흔한 원인입니다.

이 글에서 답할 질문은 다음과 같습니다.

- 인덱스 파일에는 key와 value로 무엇이 저장되는가. unique 인덱스와 `_id` 인덱스는 무엇이 다른가
- 쿼리 하나가 실행 계획을 얻기까지 어떤 단계를 거치는가
- 후보 계획끼리의 경쟁(trial)은 언제 끝나고, 점수는 어떻게 매기는가
- plan cache 엔트리는 언제 만들어지고, 언제 쓰이고, 언제 버려지는가
- ESR 규칙과 커버링 쿼리는 explain에서 어떻게 드러나는가
- 8.0에서 classic 엔진과 SBE 중 무엇이 쓰이는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 이 글의 실습은 standalone mongod 하나로 했습니다.

## 인덱스는 KeyString을 key로 하는 WiredTiger 테이블

인덱스를 만들면 MongoDB는 WiredTiger 테이블을 하나 만들고, key와 value를 모두 바이트열(`key_format=u`, `value_format=u`)로 둡니다([`wiredtiger_index.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L248-L249)). key에 들어가는 바이트열이 **KeyString**입니다. 인덱스 키의 BSON 값을 타입 순서와 값 순서가 그대로 **바이트 비교 순서**가 되도록 인코딩한 것이라, WiredTiger는 BSON을 모른 채 `memcmp`만으로 B-tree를 정렬할 수 있습니다. 값마다 첫 바이트가 타입(CType)을 나타냅니다([`key_string.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L89-L105)). MinKey(10) < null(20) < 숫자(30번대) < 문자열(60) < 객체(70) < ... < MaxKey(240) 순서라서 서로 다른 타입이 섞여도 BSON 비교 규칙대로 정렬됩니다.

인덱스 종류에 따라 key와 value의 모양이 다릅니다. 테이블 메타데이터의 `app_metadata=(formatVersion=N)`에 형식이 적힙니다([`generateAppMetadataString()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L176-L200), 번호는 [`wiredtiger_index.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.h#L78-L83)).

| 인덱스 | formatVersion | key | value |
|---|---|---|---|
| 일반 인덱스 | 8 | KeyString(인덱스 키) + RecordId | 비어 있음(필요할 때만 TypeBits) |
| unique 인덱스(`_id` 제외) | 14 | KeyString(인덱스 키) + RecordId | 비어 있음(필요할 때만 TypeBits) |
| `_id` 인덱스 | 8 | KeyString(`_id`)만 | RecordId(+ TypeBits) |

일반 인덱스는 같은 키 값이 여러 도큐먼트에 있을 수 있으므로 key 뒤에 **RecordId**(컬렉션 테이블의 key, [1편](/posts/mongodb/01-wiredtiger-architecture/))를 붙여 항목마다 key를 유일하게 만듭니다([`WiredTigerIndexStandard::_insert()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L1997)). unique 인덱스도 지금 형식(formatVersion 14)에서는 같은 모양입니다. 예전 형식(11, 13)은 key에 RecordId를 붙이지 않았습니다. 중복 검사는 넣기 전에 RecordId를 뗀 접두어로 기존 key가 있는지 찾아서 합니다([`WiredTigerIndexUnique::_insert()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L1731), [`_keyExists()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L526)). key를 서로 다르게 두면 같은 값을 잠깐 동시에 가진 두 항목(예: 한 도큐먼트가 값을 놓고 다른 도큐먼트가 그 값을 가져가는 경우)이 WiredTiger key 하나를 두고 [쓰기 충돌](/posts/mongodb/03-mvcc-and-snapshot/#쓰기-충돌-기다리지-않고-바로-실패한다)을 일으키지 않습니다. `_id` 인덱스만은 여전히 RecordId를 value에 둡니다([`WiredTigerIdIndex::_insert()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp#L1630-L1650)).

RecordId는 KeyString 끝에 붙어도 뒤에서부터 길이를 알 수 있게 인코딩합니다. 첫 바이트의 위 3비트와 마지막 바이트의 아래 3비트에 "사이에 낀 바이트 수"를 적고 나머지 비트에 값을 넣습니다([`_appendRecordIdLong()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L664)).

#### wt로 본 인덱스 파일

도큐먼트 세 개에 일반 인덱스 `k_1`과 unique 인덱스 `u_1`을 만들고, 각 인덱스의 테이블 이름을 확인합니다.

```mongosh
test> db.kdemo.insertMany([{_id: 1, k: 5, u: "a"}, {_id: 2, k: "x", u: "b"}, {_id: 3, k: 5, u: "c"}]).insertedIds
{ '0': 1, '1': 2, '2': 3 }
test> db.kdemo.createIndex({k: 1})
k_1
test> db.kdemo.createIndex({u: 1}, {unique: true})
u_1
test> db.kdemo.stats().wiredTiger.uri
statistics:table:collection-7-13461233652411929628
test> Object.entries(db.kdemo.stats({indexDetails: true}).indexDetails).map(([name, d]) => [name, d.uri])
[
  [ '_id_', 'statistics:table:index-8-13461233652411929628' ],
  [ 'k_1', 'statistics:table:index-9-13461233652411929628' ],
  [ 'u_1', 'statistics:table:index-11-13461233652411929628' ]
]
test> db.adminCommand({fsync: 1}).ok
1
```

mongod를 정상 종료하고 `wt dump -x`로 컬렉션과 인덱스 세 개를 16진수로 봅니다. key 줄과 value 줄이 번갈아 나오고, value가 비어 있으면 빈 줄입니다.

```console
$ mongosh --quiet --eval 'Object.entries(db.kdemo.stats({indexDetails: true}).indexDetails).map(([n, d]) => n + " " + d.uri.replace("statistics:", "")).join("\n")' > /tmp/idx.txt
$ mongosh --quiet --eval 'db.kdemo.stats().wiredTiger.uri.replace("statistics:", "")' > /tmp/coll.txt
$ mongod --dbpath /data/db --shutdown | grep -v '^{'
$ wt -h /data/db dump -x $(cat /tmp/coll.txt) | sed -n '/^Data/,$p'
$ while read name uri; do echo "== $name ($uri)"; wt -h /data/db list -v $uri | tr ',' '\n' | grep -E '^app_metadata|^(key|value)_format'; wt -h /data/db dump -x $uri | sed -n '/^Data/,$p' | tail -n +2; done < /tmp/idx.txt
Killing process with pid: 33
Data
81
1e000000105f69640001000000106b000500000002750002000000610000
82
20000000105f69640002000000026b0002000000780002750002000000620000
83
1e000000105f69640003000000106b000500000002750002000000630000
== _id_ (table:index-8-13461233652411929628)
app_metadata=(formatVersion=8)
key_format=u
value_format=u
2b0204
0008
2b0404
0010
2b0604
0018
== k_1 (table:index-9-13461233652411929628)
app_metadata=(formatVersion=8)
key_format=u
value_format=u
2b0a040008

2b0a040018

3c7800040010

== u_1 (table:index-11-13461233652411929628)
app_metadata=(formatVersion=14)
key_format=u
value_format=u
3c6100040008

3c6200040010

3c6300040018
```

- 컬렉션 테이블의 key `81`, `82`, `83`은 RecordId 1, 2, 3입니다(정수 key를 WiredTiger 방식으로 패킹한 값, [3편](/posts/mongodb/03-mvcc-and-snapshot/#wt로-본-history-store-데이터-파일에는-최신-버전만-있다)). value는 BSON 도큐먼트입니다.
- `_id_` 인덱스의 첫 항목은 key `2b 02 04`, value `00 08`입니다. `0x2b`(43)는 "1바이트로 표현되는 양의 정수" 타입([`kNumericPositive1ByteInt`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L123)), `0x02`는 값 1을 왼쪽으로 한 비트 민 것(맨 아래 비트는 소수부가 있는지 표시, [`_appendInteger()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L1410)), `0x04`는 끝 표시([`kEnd`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp#L337))입니다. RecordId 1은 value `00 08`로, 사이 바이트 0개(첫 바이트 위 3비트와 마지막 바이트 아래 3비트가 0)에 값 1이 `0x08`(1 << 3)로 들어갔습니다.
- `k_1`은 key가 `2b 0a 04` + `00 08`입니다. `0x0a`는 5 << 1이고, 뒤에 RecordId 1이 붙었습니다. `k: 5`인 도큐먼트가 둘(RecordId 1과 3)이라 앞부분이 같고 RecordId(`0008`, `0018`)만 다른 key 두 개가 됩니다. 문자열 `"x"`는 `3c`(문자열 타입 60) + `78`('x') + `00`(문자열 끝) + `04`이고 RecordId 2(`0010`)가 붙었습니다. 숫자 key가 문자열 key보다 앞에 정렬된 것도 보입니다. value는 모두 비어 있습니다.
- unique 인덱스 `u_1`은 `formatVersion=14`이지만 key 모양은 `k_1`과 같이 KeyString + RecordId입니다. `_id_`만 RecordId가 value 쪽에 있습니다.

인덱스 항목에는 키 값과 RecordId만 있으므로, 인덱스에 없는 필드가 필요하면 RecordId로 컬렉션 테이블을 한 번 더 찾아야 합니다. 이것이 explain의 `FETCH` 단계이고, 이 단계를 없앤 것이 [커버링 쿼리](#커버링-쿼리-fetch가-없는-계획)입니다.

## 쿼리 하나가 실행 계획을 얻기까지

find 명령 하나가 classic 엔진에서 실행 계획을 얻는 과정은 [`PrepareExecutionHelper::prepare()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp#L436-L543)에 순서대로 있습니다.

1. **CanonicalQuery**: 필터, 정렬, projection을 파싱하고 정규화합니다([`CanonicalQuery::make()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/canonical_query.cpp#L108), 정규화는 [`canonical_query.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/canonical_query.cpp#L184)). 여기서 상수 값을 뺀 **쿼리 모양(shape)** 이 정해집니다. `{a: 70000, b: 0}`과 `{a: 0, b: 30000}`은 같은 shape입니다.
2. `_id` 동등 조건 하나뿐인 쿼리처럼 특별한 경우는 계획 경쟁 없이 바로 실행합니다.
3. **plan cache 조회**: shape와 사용 가능한 인덱스로 만든 `planCacheKey`로 캐시를 찾습니다([`get_executor.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp#L484)). **active** 엔트리가 있을 때만 씁니다([`getCacheEntryIfActive()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp#L765-L767)).
4. **QueryPlanner::plan**: 캐시에서 못 찾으면 쓸 수 있는 인덱스마다 후보 계획(QuerySolution)을 열거합니다([`QueryPlanner::plan()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_planner.cpp#L1267), 인덱스 조합 열거는 [`PlanEnumerator`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_planner.cpp#L1565)). 후보는 최대 64개입니다([`internalQueryPlannerMaxIndexedSolutions`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L341-L346)).
5. 후보가 하나면 바로 실행하고, 여럿이면 **MultiPlanStage**가 모두를 조금씩 실행해 승자를 고른 뒤 plan cache에 기록합니다.

{{< diagram src="/diagrams/mongo-query-planning.html" title="find 한 번이 실행 계획을 얻는 과정" height="620" caption="active 캐시 엔트리가 있으면 그 계획을 쓰되 예상 works의 10배 안에 끝나는지 지켜보고, 없으면 후보를 열거해 trial로 경쟁시킨 뒤 승자를 캐시에 기록합니다." >}}

## 후보 계획 경쟁: trial과 점수

MultiPlanStage는 후보들의 `work()`를 한 번씩 번갈아 부릅니다([`MultiPlanStage::pickBestPlan()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/multi_plan.cpp#L221), 루프는 [`multi_plan.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/multi_plan.cpp#L240-L257)). `work()` 한 번은 인덱스 key 하나 읽기, 도큐먼트 하나 가져오기처럼 작은 일 한 단위이고, 이것이 explain의 `works`입니다. trial은 다음 중 하나가 되면 끝납니다.

- 어느 후보가 **결과 101개**를 내면([`internalQueryPlanEvaluationMaxResults`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L142-L147)). `limit`이 더 작으면 그 값([`getTrialPeriodNumToReturn()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/trial_period_utils.cpp#L57-L68))
- 어느 후보가 **EOF**(결과를 다 냄)에 닿으면
- 후보마다 `work()`를 **10000번과 컬렉션 도큐먼트 수의 30% 중 큰 값**만큼 부르면([`getTrialPeriodMaxWorks()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/trial_period_utils.cpp#L44-L55), 기본값은 [`query_knobs.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L87-L121))

그다음 후보마다 점수를 매깁니다([`PlanScorer::calculateScore()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker.h#L105-L163), [`pickBestPlan()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker_util.h#L185-L250)).

```plaintext
score = 1 (baseScore)
      + advanced / works (productivity, classic)
      + ε (FETCH가 없으면) + ε (blocking SORT가 없으면) + ε (index intersection이 아니면)
      + 1 (trial 안에 EOF에 닿았으면)
ε = min(1 / (10 × advanced), 0.0001)
```

productivity는 root 단계가 결과를 낸 횟수(`advanced`)를 `works`로 나눈 값입니다([`DefaultPlanScorer`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker.cpp#L135-L139)). "일한 만큼 결과를 냈는가"라는 뜻입니다. 세 가지 ε 보너스는 productivity가 같을 때 순서를 가르는 작은 값이고([`kBonusEpsilon`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker.h#L89)), EOF 보너스 1은 trial 안에 일을 끝낸 계획을 확실히 앞세웁니다([`plan_ranker_util.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker_util.h#L192), [`plan_ranker_util.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker_util.h#L245-L248)). 그래도 동점이면 읽은 도큐먼트 수가 적은 계획, 인덱스 접두어를 더 많이 쓴 계획에 보너스를 더 줍니다([`plan_ranker_util.h`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker_util.h#L278-L287)).

#### explain("allPlansExecution")으로 본 trial

`a`와 `b`에 각각 인덱스가 있는 10만 건짜리 컬렉션을 만듭니다. 앞 절반(`_id` 0~49999)은 `a`가 0이고 `b`는 `_id`와 같고, 뒤 절반은 `b`가 0이고 `a`가 `_id`와 같습니다. 즉 `a: 0`과 `b: 0`은 각각 5만 건쯤이고, 나머지 값은 한 건씩입니다.

```mongosh
test> db.ev.insertMany(Array.from({length: 100000}, (_, i) => ({_id: i, a: i < 50000 ? 0 : i, b: i >= 50000 ? 0 : i}))).acknowledged
true
test> db.ev.createIndex({a: 1})
a_1
test> db.ev.createIndex({b: 1})
b_1
test> db.ev.countDocuments({a: 0})
50000
test> db.ev.countDocuments({b: 0})
50001
```

`{a: 70000, b: 0}`의 explain을 봅니다. `a: 70000`은 한 건이고 `b: 0`은 5만 건입니다.

```mongosh
test> e = db.ev.find({a: 70000, b: 0}).explain("allPlansExecution")
{
  explainVersion: '1',
  queryPlanner: {
    namespace: 'test.ev',
    parsedQuery: {
      '$and': [ { a: { '$eq': 70000 } }, { b: { '$eq': 0 } } ]
    },
    indexFilterSet: false,
    queryHash: 'CB8DF112',
    planCacheShapeHash: 'CB8DF112',
    planCacheKey: 'CF147625',
...
test> ({planCacheShapeHash: e.queryPlanner.planCacheShapeHash, planCacheKey: e.queryPlanner.planCacheKey, rejectedPlans: e.queryPlanner.rejectedPlans.length})
{
  planCacheShapeHash: 'CB8DF112',
  planCacheKey: 'CF147625',
  rejectedPlans: 2
}
test> e.queryPlanner.winningPlan
{
  isCached: false,
  stage: 'FETCH',
  filter: { b: { '$eq': 0 } },
  inputStage: {
    stage: 'IXSCAN',
    keyPattern: { a: 1 },
    indexName: 'a_1',
    isMultiKey: false,
    multiKeyPaths: { a: [] },
    isUnique: false,
    isSparse: false,
    isPartial: false,
    indexVersion: 2,
    direction: 'forward',
    indexBounds: { a: [ '[70000, 70000]' ] }
  }
}
```

- `explainVersion: '1'`은 classic 엔진으로 실행했다는 뜻입니다([뒤에서](#classic-엔진과-sbe) 봅니다).
- `planCacheShapeHash`는 쿼리 shape의 해시이고, `planCacheKey`는 shape에 "지금 쓸 수 있는 인덱스"까지 더한 해시로 plan cache를 찾는 key입니다. `queryHash`는 8.0에서 `planCacheShapeHash`로 이름이 바뀌면서 호환을 위해 남아 있는 같은 값입니다.
- 승자는 `a_1`을 `[70000, 70000]` 범위로 읽고(IXSCAN), 도큐먼트를 가져와(FETCH) `b: 0`을 걸러 내는 계획입니다. 탈락한 후보(`rejectedPlans`)는 둘입니다.

후보별 trial 결과를 간추립니다. 8.0의 explain에는 후보마다 `score`도 나옵니다.

```mongosh
test> ix = (s) => s.indexName ? s.stage + " " + s.indexName : s.stage + (s.inputStage ? " > " + ix(s.inputStage) : " > [" + s.inputStages.map(ix).join(", ") + "]")
[Function: ix]
test> e.executionStats.allPlansExecution.map(p => ({plan: ix(p.executionStages), score: p.score, works: p.executionStages.works, advanced: p.executionStages.advanced, isEOF: p.executionStages.isEOF, totalKeysExamined: p.totalKeysExamined, totalDocsExamined: p.totalDocsExamined}))
[
  {
    plan: 'FETCH > IXSCAN a_1',
    score: 2.5002,
    works: 2,
    advanced: 1,
    isEOF: 1,
    totalKeysExamined: 1,
    totalDocsExamined: 1
  },
  {
    plan: 'FETCH > IXSCAN b_1',
    score: 1.0002,
    works: 2,
    advanced: 0,
    isEOF: 0,
    totalKeysExamined: 2,
    totalDocsExamined: 2
  },
  {
    plan: 'FETCH > AND_SORTED > [IXSCAN a_1, IXSCAN b_1]',
    score: 1.0001,
    works: 2,
    advanced: 0,
    isEOF: 0,
    totalKeysExamined: 2,
    totalDocsExamined: 0
  }
]
```

- 후보는 `a_1`만 쓰는 계획, `b_1`만 쓰는 계획, 두 인덱스를 함께 읽어 RecordId가 겹치는 것만 남기는 index intersection(`AND_SORTED`) 계획 셋입니다.
- `a_1` 계획은 두 번째 `work()`에서 결과 하나를 내고 EOF에 닿았습니다. trial은 여기서 끝났으므로 세 후보 모두 `works: 2`입니다.
- 점수를 공식대로 풀면 `a_1` 계획은 1 + 1/2 + ε(SORT 없음) + ε(intersection 아님) + 1(EOF) = 2.5002입니다. FETCH가 있어서 FETCH 보너스는 없습니다. `b_1` 계획은 결과를 못 냈으므로 1 + 0 + 2ε = 1.0002이고, intersection 계획은 SORT 보너스만 받아 1.0001입니다.
- `b_1` 계획은 `b: 0`인 5만 건을 다 읽어야 끝날 계획이었지만, trial은 2번의 `work()`만에 그것을 가려냈습니다. 통계 없이 "실제로 조금 돌려 보는" 방식의 장점입니다.

## plan cache: inactive로 시작해 active가 된다

trial에서 이긴 계획은 plan cache에 기록됩니다. 엔트리는 컬렉션마다 따로 있고 메모리에만 있습니다(mongod를 재시작하면 비워짐). 크기는 기본으로 서버 메모리의 5%까지입니다([`planCacheSize`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L287-L297)). 엔트리에는 계획과 함께 승자가 trial에서 쓴 **works**가 적힙니다. 이 값이 뒤의 replan 기준이 됩니다.

새 엔트리는 곧바로 쓰이지 않습니다. 엔트리 상태는 [`getNewEntryState()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_cache.h#L762-L838)가 정합니다.

| 상황 | 결과 |
|---|---|
| 엔트리가 없음 | **inactive** 엔트리를 만들고 works를 기록 |
| inactive 엔트리가 있고, 이번 trial의 works ≤ 기록된 works | **active**로 바꿈 |
| inactive 엔트리가 있고, 이번 works > 기록된 works | inactive로 두고 기록된 works를 2배로 키움([`internalQueryCacheWorksGrowthCoefficient`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L266-L272)) |
| active 엔트리가 있음 | 이번 works가 더 작거나 같을 때만 교체 |

inactive 엔트리는 조회 때 없는 것으로 취급되므로([`getCacheEntryIfActive()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp#L765-L767)), 같은 shape의 쿼리가 한 번 더 와서 trial을 다시 하고, 그때도 기록보다 적게 일해야 active가 됩니다. 한 번 운 좋게 싸게 끝난 값 때문에 나쁜 계획이 캐시에 박히는 것을 줄이려는 장치입니다.

#### 같은 쿼리를 두 번 실행하면

`$planCacheStats`로 엔트리를 보는 함수 `pc()`를 만들고, `serverStatus`의 plan cache 카운터도 함께 봅니다.

```mongosh
test> pc = () => db.ev.aggregate([{$planCacheStats: {}}, {$project: {_id: 0, planCacheShapeHash: 1, planCacheKey: 1, isActive: 1, works: 1, createdFromQuery: 1, index: "$cachedPlan.inputStage.indexName"}}]).toArray()
[Function: pc]
test> db.serverStatus().metrics.query.planCache.classic
{
  hits: Long('0'),
  misses: Long('2'),
  replanned: Long('0'),
  skipped: Long('6')
}
test> db.ev.find({a: 70000, b: 0}).toArray()
[ { _id: 70000, a: 70000, b: 0 } ]
test> pc()
[
  {
    planCacheShapeHash: 'CB8DF112',
    planCacheKey: 'CF147625',
    isActive: false,
    works: Long('2'),
    createdFromQuery: { query: { a: 70000, b: 0 }, sort: {}, projection: {} },
    index: 'a_1'
  }
]
test> db.ev.find({a: 70000, b: 0}).toArray()
[ { _id: 70000, a: 70000, b: 0 } ]
test> pc()
[
  {
    planCacheShapeHash: 'CB8DF112',
    planCacheKey: 'CF147625',
    isActive: true,
    works: Long('2'),
    createdFromQuery: { query: { a: 70000, b: 0 }, sort: {}, projection: {} },
    index: 'a_1'
  }
]
test> db.ev.find({a: 60000, b: 0}).toArray()
[ { _id: 60000, a: 60000, b: 0 } ]
test> db.serverStatus().metrics.query.planCache.classic
{
  hits: Long('1'),
  misses: Long('4'),
  replanned: Long('0'),
  skipped: Long('6')
}
test> db.ev.find({a: 60000, b: 0}).explain().queryPlanner.winningPlan.isCached
true
```

- 첫 실행 뒤 엔트리가 생겼지만 `isActive: false`, `works: 2`입니다.
- 두 번째 실행도 trial을 다시 했고, 이번 works(2)가 기록값(2) 이하라 `isActive: true`가 되었습니다. 두 실행 모두 캐시를 쓰지 못했으므로 `misses`가 2에서 4로 늘었습니다.
- 값만 바꾼 `{a: 60000, b: 0}`은 같은 shape이라 active 엔트리를 그대로 썼습니다(`hits` 1). explain에서도 `isCached: true`가 보입니다.

## replanning: 캐시된 계획이 예상보다 10배 넘게 일하면

active 엔트리를 쓰는 쿼리는 trial 없이 바로 캐시된 계획을 실행하지만, 무조건 믿지는 않습니다. **CachedPlanStage**가 처음 일부를 실행하면서 works를 세고, 결과 101개(또는 limit)나 EOF에 닿기 전에 **기록된 works × 10**을 넘기면 엔트리를 inactive로 돌리고 처음부터 다시 계획합니다([`cached_plan.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/cached_plan.cpp#L102-L105), 비활성화는 [`CachedPlanStage::replan()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/cached_plan.cpp#L231-L236)). 10은 [`internalQueryCacheEvictionRatio`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L254-L260)의 기본값입니다.

#### 데이터 분포가 다른 값으로 같은 shape을 실행하면

지금 캐시에는 `a_1` 계획이 `works: 2`로 active입니다. 같은 shape이지만 이번에는 `a: 0`(5만 건)이고 `b: 30000`(한 건)인 쿼리를 보냅니다. replan 과정을 로그로 보려고 query 컴포넌트의 로그 수준을 1로, 모든 쿼리를 slow query 로그에 남기도록 `slowms`를 0으로 잠깐 바꿨습니다.

```mongosh
test> db.adminCommand({getParameter: 1, internalQueryCacheEvictionRatio: 1}).internalQueryCacheEvictionRatio
10
test> db.setLogLevel(1, "query").was.query.verbosity
-1
test> db.setProfilingLevel(0, {slowms: 0}).slowms
100
test> db.ev.find({a: 0, b: 30000}).toArray()
[ { _id: 30000, a: 0, b: 30000 } ]
test> db.setLogLevel(0, "query").was.query.verbosity
1
test> db.setProfilingLevel(0, {slowms: 100}).slowms
0
test> pc()
[
  {
    planCacheShapeHash: 'CB8DF112',
    planCacheKey: 'CF147625',
    isActive: true,
    works: Long('2'),
    createdFromQuery: { query: { a: 0, b: 30000 }, sort: {}, projection: {} },
    index: 'b_1'
  }
]
test> db.serverStatus().metrics.query.planCache.classic
{
  hits: Long('2'),
  misses: Long('4'),
  replanned: Long('1'),
  skipped: Long('8')
}
```

```console
$ jq -c 'select(.id == 20580) | {msg, attr: {maxWorksBeforeReplan: .attr.maxWorksBeforeReplan, decisionWorks: .attr.decisionWorks, planSummary: .attr.planSummary}}' /data/mongod.log
$ jq -c 'select(.msg == "Slow query" and .attr.ns == "test.ev" and .attr.replanned) | {planSummary: .attr.planSummary, replanned: .attr.replanned, replanReason: .attr.replanReason, keysExamined: .attr.keysExamined, docsExamined: .attr.docsExamined, planCacheShapeHash: .attr.planCacheShapeHash}' /data/mongod.log
{"msg":"Evicting cache entry and replanning query","attr":{"maxWorksBeforeReplan":20,"decisionWorks":2,"planSummary":"IXSCAN { a: 1 }"}}
{"planSummary":"IXSCAN { b: 1 }","replanned":true,"replanReason":"cached plan was less efficient than expected: expected trial execution to take 2 works but it took at least 20 works","keysExamined":1,"docsExamined":1,"planCacheShapeHash":"CB8DF112"}
```

- 캐시를 찾았으므로 `hits`가 1 늘었고, 캐시된 `a_1` 계획이 `a: 0`인 5만 건을 읽기 시작했습니다. 기록된 works가 2라 한도는 20입니다(`maxWorksBeforeReplan: 20`, `decisionWorks: 2`). 20번 일해도 결과가 나오지 않자 `Evicting cache entry and replanning query`를 남기고 다시 계획했습니다.
- 다시 한 trial에서는 `b_1`이 이겼고, 엔트리가 `b_1` 계획으로 바뀌었습니다. `createdFromQuery`도 이번 쿼리입니다. replan할 때 옛 엔트리를 inactive로 돌리고, 새 trial 결과(works 2)가 기록값(2) 이하라 곧바로 active가 되었습니다.
- slow query 로그에 `replanned: true`와 이유(`cached plan was less efficient than expected: expected trial execution to take 2 works but it took at least 20 works`, [`cached_plan.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/cached_plan.cpp#L195-L198))가 남고, `planSummary`는 최종으로 실행한 `IXSCAN { b: 1 }`입니다. `keysExamined`, `docsExamined`는 최종 계획의 값이라 1씩입니다.
- `replanned` 카운터가 1이 되었습니다.

replan은 쿼리마다 캐시를 되돌리는 장치입니다. 위의 두 쿼리가 번갈아 들어오면 엔트리가 `a_1`과 `b_1` 사이를 계속 오가며 매번 replan 비용을 치를 수 있습니다. 또 한도는 "기록된 works의 10배"라서, 기록된 works가 큰 엔트리에서는 나쁜 계획이 그만큼 오래 실행된 뒤에야 replan됩니다.

## plan cache가 비워지는 때

plan cache 엔트리는 다음 때 사라집니다.

- `planCacheClear` 명령(또는 `db.collection.getPlanCache().clear()`)
- 인덱스를 새로 만들거나([`multi_index_block.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/catalog/multi_index_block.cpp#L1165)) 지울 때([`index_catalog_impl.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/catalog/index_catalog_impl.cpp#L1492), [`updatePlanCacheIndexEntries()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/collection_query_info.cpp#L322-L325)). 인덱스가 바뀌면 후보 자체가 달라지기 때문입니다
- 인덱스가 처음으로 multikey가 될 때([`clearQueryCacheForSetMultikey()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/collection_query_info.cpp#L314-L320))
- mongod 재시작, 그리고 크기 한도를 넘을 때 오래 안 쓴 엔트리부터

#### planCacheClear와 인덱스 추가

```mongosh
test> pc = () => db.ev.aggregate([{$planCacheStats: {}}, {$project: {_id: 0, isActive: 1, works: 1, index: "$cachedPlan.inputStage.indexName"}}]).toArray()
[Function: pc]
test> pc()
[ { isActive: true, works: Long('2'), index: 'b_1' } ]
test> db.runCommand({planCacheClear: "ev"}).ok
1
test> pc()
[]
test> db.ev.find({a: 70000, b: 0}).toArray().length
1
test> pc()
[ { isActive: false, works: Long('2'), index: 'a_1' } ]
test> db.ev.createIndex({a: 1, b: 1})
a_1_b_1
test> pc()
[]
test> db.ev.find({a: 70000, b: 0}).explain().queryPlanner.winningPlan.inputStage.indexName
a_1_b_1
```

- `planCacheClear`로 엔트리가 없어졌고, 다음 실행이 다시 inactive 엔트리를 만들었습니다.
- 인덱스 `{a: 1, b: 1}`을 만들자 그 엔트리도 사라졌습니다. 새 인덱스로 두 조건을 모두 인덱스 범위로 처리할 수 있게 되어, 이제는 `a_1_b_1`이 승자입니다.

## ESR: Equality, Sort, Range

복합 인덱스의 필드 순서는 **동등 조건(Equality) → 정렬(Sort) → 범위 조건(Range)** 으로 두라는 것이 ESR 규칙입니다. 이유는 인덱스 범위(`indexBounds`)가 어떻게 만들어지는지를 보면 알 수 있습니다. 인덱스는 앞 필드부터 정렬되어 있으므로, 앞 필드가 동등 조건으로 한 값에 고정되면 그 안에서 다음 필드 순서대로 key가 나옵니다. 그런데 범위 조건 필드가 정렬 필드보다 앞에 있으면, 범위 안의 여러 값마다 정렬 필드가 따로 정렬되어 있어서 전체로는 정렬 순서가 아닙니다. 그러면 결과를 모아 따로 정렬하는 **SORT 단계**(blocking sort)가 필요합니다.

#### 같은 쿼리, 필드 순서만 다른 두 인덱스

20만 건의 `orders`에 `status`(4가지 값), `amount`(0~999), `ts`(증가값)를 넣고, 필드 순서만 다른 인덱스 둘을 만듭니다. 쿼리는 `status` 동등, `amount` 범위, `ts` 역순 정렬, 10건입니다.

```mongosh
test> db.orders.insertMany(Array.from({length: 200000}, (_, i) => ({_id: i, status: ["new", "paid", "shipped", "done"][i % 4], amount: (i * 7) % 1000, ts: i}))).acknowledged
true
test> db.orders.createIndex({status: 1, amount: 1, ts: 1}, {name: "esr_bad"})
esr_bad
test> db.orders.createIndex({status: 1, ts: 1, amount: 1}, {name: "esr_good"})
esr_good
test> db.orders.countDocuments({status: "paid", amount: {$gte: 900}})
5000
test> st = (s) => s.stage + (s.inputStage ? " > " + st(s.inputStage) : "")
[Function: st]
test> q = () => db.orders.find({status: "paid", amount: {$gte: 900}}).sort({ts: -1}).limit(10)
[Function: q]
test> bad = q().hint("esr_bad").explain("executionStats"); st(bad.executionStats.executionStages)
FETCH > SORT > IXSCAN
test> ({nReturned: bad.executionStats.nReturned, totalKeysExamined: bad.executionStats.totalKeysExamined, totalDocsExamined: bad.executionStats.totalDocsExamined})
{ nReturned: 10, totalKeysExamined: 5000, totalDocsExamined: 10 }
test> bad.queryPlanner.winningPlan.inputStage.inputStage.indexBounds
{
  status: [ '["paid", "paid"]' ],
  amount: [ '[900, inf.0]' ],
  ts: [ '[MinKey, MaxKey]' ]
}
test> good = q().hint("esr_good").explain("executionStats"); st(good.executionStats.executionStages)
LIMIT > FETCH > IXSCAN
test> ({nReturned: good.executionStats.nReturned, totalKeysExamined: good.executionStats.totalKeysExamined, totalDocsExamined: good.executionStats.totalDocsExamined})
{ nReturned: 10, totalKeysExamined: 74, totalDocsExamined: 10 }
test> good.queryPlanner.winningPlan.inputStage.inputStage.indexBounds
{
  status: [ '["paid", "paid"]' ],
  ts: [ '[MaxKey, MinKey]' ],
  amount: [ '[inf.0, 900]' ]
}
```

- `esr_bad`(E, R, S 순서)는 `status: "paid"`와 `amount >= 900` 범위를 인덱스로 좁혀 key 5000개를 모두 읽고, `ts`로 정렬하는 SORT 단계에서 상위 10개를 골라 그 10건만 가져왔습니다(FETCH가 SORT 위에 있습니다). 결과가 10건이어도 조건에 맞는 key를 **전부** 읽어야 정렬할 수 있습니다.
- `esr_good`(E, S, R 순서)은 `status: "paid"` 안에서 `ts` 역순(`[MaxKey, MinKey]`)으로 key를 읽으면서 `amount` 조건은 key에서 바로 걸렀습니다. 이미 정렬된 순서라 SORT가 없고, 조건에 맞는 key 10개를 찾자마자 멈춰 key 74개만 읽었습니다.
- `esr_good`의 `amount` 범위가 `[inf.0, 900]`처럼 뒤집혀 보이는 것은 인덱스를 역방향으로 읽기 때문입니다. 범위 필드가 정렬 필드 뒤에 있어 경계로 쓰이지 못하고, key마다 검사하는 조건이 됩니다. 그래서 limit이 없고 조건에 맞는 key가 드물다면 `esr_good`이 더 많은 key를 읽을 수도 있습니다. ESR은 "정렬을 인덱스로 해결하는 것이 대개 더 싸다"는 경험칙이고, 결과 수와 limit에 따라 결과가 달라질 수 있습니다.

hint 없이 플래너에게 맡기면 두 인덱스가 후보로 경쟁합니다.

```mongosh
test> auto = q().explain("allPlansExecution"); st(auto.queryPlanner.winningPlan)
LIMIT > FETCH > IXSCAN
test> auto.executionStats.allPlansExecution.map(p => ({plan: st(p.executionStages), score: p.score, works: p.executionStages.works, advanced: p.executionStages.advanced, isEOF: p.executionStages.isEOF, totalKeysExamined: p.totalKeysExamined}))
[
  {
    plan: 'LIMIT > FETCH > IXSCAN',
    score: 2.135335135135135,
    works: 74,
    advanced: 10,
    isEOF: 1,
    totalKeysExamined: 74
  },
  {
    plan: 'FETCH > SORT > IXSCAN',
    score: 1.0001,
    works: 74,
    advanced: 0,
    isEOF: 0,
    totalKeysExamined: 74
  }
]
test> db.serverStatus().metrics.operation.scanAndOrder
Long('0')
test> q().hint("esr_bad").toArray().length
10
test> db.serverStatus().metrics.operation.scanAndOrder
Long('1')
```

- `esr_good` 계획이 74번 일해 10건을 내고 limit에 닿아 EOF가 되었습니다. 점수는 1 + 10/74 + 2ε + 1 = 2.1353입니다.
- 같은 74번 동안 `esr_bad` 계획은 SORT가 입력을 다 받기 전에는 아무것도 내놓지 못하므로 `advanced: 0`이었습니다. blocking 단계가 있는 계획은 trial에서 불리합니다. 이 쿼리처럼 정렬과 limit이 있는 경우에는 그것이 맞는 판단입니다.
- blocking SORT로 실행한 쿼리가 끝날 때마다 `metrics.operation.scanAndOrder`가 1씩 늡니다. `esr_bad`로 한 번 실행하자 0에서 1이 되었습니다. 인덱스로 정렬하지 못하는 쿼리가 얼마나 도는지 보는 지표입니다. blocking SORT가 쓰는 메모리가 100MB([`internalQueryMaxBlockingSortMemoryUsageBytes`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L455-L463))를 넘으면 디스크의 임시 파일을 쓰고, `allowDiskUse: false`면 오류로 끝납니다.

## 커버링 쿼리: FETCH가 없는 계획

필요한 필드가 모두 인덱스 key 안에 있으면 컬렉션 테이블을 찾아갈 필요가 없습니다. 이런 쿼리를 **커버링 쿼리**라고 하고, explain에 `FETCH` 대신 `PROJECTION_COVERED`가 나옵니다. `_id`는 따로 빼지 않으면 결과에 포함되므로, `_id`가 인덱스에 없다면 projection에서 `_id: 0`으로 빼야 커버됩니다.

#### _id를 빼면 커버된다

```mongosh
test> st = (s) => s.stage + (s.inputStage ? " > " + st(s.inputStage) : "")
[Function: st]
test> c1 = db.orders.find({status: "paid", ts: {$gte: 199000}}, {_id: 0, status: 1, ts: 1}).hint("esr_good").explain("executionStats"); st(c1.executionStats.executionStages)
PROJECTION_COVERED > IXSCAN
test> ({nReturned: c1.executionStats.nReturned, totalKeysExamined: c1.executionStats.totalKeysExamined, totalDocsExamined: c1.executionStats.totalDocsExamined})
{ nReturned: 250, totalKeysExamined: 250, totalDocsExamined: 0 }
test> c2 = db.orders.find({status: "paid", ts: {$gte: 199000}}, {status: 1, ts: 1}).hint("esr_good").explain("executionStats"); st(c2.executionStats.executionStages)
PROJECTION_SIMPLE > FETCH > IXSCAN
test> ({nReturned: c2.executionStats.nReturned, totalKeysExamined: c2.executionStats.totalKeysExamined, totalDocsExamined: c2.executionStats.totalDocsExamined})
{ nReturned: 250, totalKeysExamined: 250, totalDocsExamined: 250 }
```

- `_id: 0`을 준 쿼리는 `PROJECTION_COVERED > IXSCAN`이고 `totalDocsExamined: 0`입니다. 250건을 돌려주면서 도큐먼트는 하나도 읽지 않았습니다.
- `_id`를 빼지 않은 쿼리는 `FETCH`가 끼어 도큐먼트 250개를 읽었습니다. 인덱스 key에는 `_id`가 없기 때문입니다(앞의 wt 실습에서 본 것처럼 key에는 인덱스 필드와 RecordId뿐입니다).

## multikey 인덱스

배열 필드에 인덱스를 만들면 배열 원소마다 인덱스 항목이 하나씩 생깁니다. 이런 인덱스를 **multikey** 인덱스라고 하고, 어떤 경로가 배열이었는지를 인덱스 메타데이터에 기록합니다. multikey 경로에서는 플래너가 쓸 수 있는 범위 결합 방식이 제한되고(한 도큐먼트가 여러 key를 가지므로), 커버링도 되지 않습니다.

#### isMultiKey와 multiKeyPaths

```mongosh
test> db.posts.insertMany([{_id: 1, tags: ["db", "mongo"]}, {_id: 2, tags: ["db", "pg"]}, {_id: 3, tags: "misc"}]).acknowledged
true
test> db.posts.createIndex({tags: 1})
tags_1
test> m = db.posts.find({tags: "db"}).explain("executionStats"); m.executionStats.executionStages.stage
FETCH
test> ({isMultiKey: m.queryPlanner.winningPlan.inputStage.isMultiKey, multiKeyPaths: m.queryPlanner.winningPlan.inputStage.multiKeyPaths, keysExamined: m.executionStats.totalKeysExamined, nReturned: m.executionStats.nReturned})
{
  isMultiKey: true,
  multiKeyPaths: { tags: [ 'tags' ] },
  keysExamined: 2,
  nReturned: 2
}
test> db.posts.stats({indexDetails: true}).indexSizes
{ _id_: 4096, tags_1: 20480 }
```

- 도큐먼트 두 개에 `tags`가 배열이라 `isMultiKey: true`이고, `multiKeyPaths`에 배열이었던 경로 `tags`가 적혔습니다. `{tags: "db"}`는 `"db"` key 두 개를 읽어 두 도큐먼트를 찾았습니다.
- 도큐먼트 3개에 원소는 5개이므로 `tags_1`에는 항목이 5개 있습니다. 인덱스가 처음으로 multikey가 되는 순간 그 컬렉션의 plan cache도 비워집니다([앞 절](#plan-cache가-비워지는-때)).

## classic 엔진과 SBE

MongoDB에는 실행 엔진이 둘 있습니다. 앞에서 본 PlanStage 트리(IXSCAN, FETCH, SORT...)를 `work()`로 한 단계씩 돌리는 **classic** 엔진과, 슬롯 기반으로 컴파일한 실행 트리를 쓰는 **SBE**(Slot-Based Execution) 엔진입니다. 8.0.32의 기본 설정(`internalQueryFrameworkControl: trySbeRestricted`, [`query_knobs.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl#L1195-L1202))에서는 **집계 파이프라인 앞부분의 `$group`, `$lookup` 등을 find 계층으로 내려보낼 수 있는 쿼리만** SBE로 실행하고, 그 밖의 find는 classic으로 실행합니다([`shouldUseRegularSbe()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp#L1324-L1330)). 어느 쪽이 쓰였는지는 explain의 `explainVersion`으로 알 수 있습니다.

#### explainVersion 1과 2

```mongosh
test> f = db.orders.find({status: "paid"}).explain(); f.ok
1
test> ({explainVersion: f.explainVersion, winningPlanKeys: Object.keys(f.queryPlanner.winningPlan)})
{
  explainVersion: '1',
  winningPlanKeys: [ 'isCached', 'stage', 'inputStage' ]
}
test> g = db.orders.explain().aggregate([{$match: {status: "paid"}}, {$group: {_id: "$amount", n: {$sum: 1}}}]); g.ok
1
test> ({explainVersion: g.explainVersion, winningPlanKeys: Object.keys(g.queryPlanner.winningPlan), queryPlanStages: g.queryPlanner.winningPlan.queryPlan.stage + " > " + g.queryPlanner.winningPlan.queryPlan.inputStage.stage})
{
  explainVersion: '2',
  winningPlanKeys: [ 'isCached', 'queryPlan', 'slotBasedPlan' ],
  queryPlanStages: 'GROUP > PROJECTION_COVERED'
}
test> db.adminCommand({getParameter: 1, internalQueryFrameworkControl: 1}).internalQueryFrameworkControl
trySbeRestricted
test> db.orders.aggregate([{$match: {status: "paid"}}, {$group: {_id: "$amount", n: {$sum: 1}}}]).toArray().length
250
test> db.serverStatus().metrics.query.planCache
{
  totalQueryShapes: Long('1'),
  totalSizeEstimateBytes: Long('2875'),
  classic: {
    hits: Long('2'),
    misses: Long('7'),
    replanned: Long('1'),
    skipped: Long('24')
  },
  sbe: {
    hits: Long('0'),
    misses: Long('0'),
    replanned: Long('0'),
    skipped: Long('0')
  }
}
```

- 단순한 find는 `explainVersion: '1'`(classic)이고, `winningPlan`이 바로 `stage`/`inputStage` 트리입니다.
- `$group`이 있는 집계는 `explainVersion: '2'`(SBE)이고, `winningPlan` 아래에 계획의 모양을 보여 주는 `queryPlan`(`GROUP > PROJECTION_COVERED`)과 실제 SBE 실행 트리인 `slotBasedPlan`이 따로 있습니다. `$group`이 find 계층으로 내려가 GROUP 단계가 되었고, `status`와 `amount`만 쓰므로 인덱스만으로 커버되었습니다(`PROJECTION_COVERED`).
- SBE로 실행했지만 `sbe` 쪽 plan cache 카운터는 모두 0입니다. 8.0에서 SBE 전용 plan cache는 `featureFlagSbeFull`이 켜져 있을 때만 쓰이고([`classic_plan_cache.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/classic_plan_cache.cpp#L160-L166)), 기본 설정에서는 SBE로 실행하는 쿼리도 계획 선택은 classic의 multi-planner와 classic plan cache를 씁니다. explain을 읽을 때는 `explainVersion`부터 보고, 2라면 `queryPlanner.winningPlan.queryPlan`을 보면 됩니다.

## 운영에서는 이렇게 나타납니다

#### 갑자기 느려진 쿼리: 계획이 바뀌었는지부터 본다

코드도 데이터 양도 그대로인데 특정 쿼리가 갑자기 느려졌다면, plan cache에 다른 계획이 들어갔을 가능성을 먼저 봅니다. [replan 실습](#데이터-분포가-다른-값으로-같은-shape을-실행하면)처럼 같은 shape의 쿼리라도 값에 따라 좋은 인덱스가 다르면, 어느 값으로 먼저 trial을 했느냐에 따라 캐시에 들어가는 계획이 달라집니다. 확인 순서는 이렇습니다.

1. slow query 로그의 `planSummary`로 실제로 쓴 인덱스를 봅니다. 평소와 다른 인덱스이거나 `COLLSCAN`이면 계획이 바뀐 것입니다. `keysExamined`, `docsExamined`가 `nreturned`보다 훨씬 크면 비효율적인 계획입니다. `replanned: true`와 `replanReason`이 있으면 replan이 일어난 쿼리입니다.
2. 같은 로그의 `planCacheShapeHash`(`queryHash`)로 `$planCacheStats`에서 엔트리를 찾아 `cachedPlan`, `works`, `isActive`, `createdFromQuery`를 봅니다. `createdFromQuery`는 그 엔트리를 만든 쿼리의 실제 값이라, 어떤 값 때문에 이 계획이 캐시되었는지 알려 줍니다.
3. `explain("allPlansExecution")`로 후보별 `score`, `works`, `advanced`를 비교합니다.
4. `serverStatus().metrics.query.planCache.classic.replanned`가 계속 늘면 계획이 자주 뒤바뀌고 있는 것입니다.

당장의 조치는 `planCacheClear`로 해당 컬렉션의 캐시를 비우는 것이지만, 같은 일이 다시 생길 수 있습니다. 근본적으로는 두 조건을 함께 쓰는 복합 인덱스처럼 값에 덜 민감한 인덱스를 만들거나(앞의 `{a: 1, b: 1}`처럼), 쿼리에 `hint`를 줍니다. 애플리케이션 코드를 바꿀 수 없다면 8.0부터는 `setQuerySettings`로 쿼리 shape에 쓸 인덱스를 서버에서 지정할 수 있습니다(기존의 index filter, `planCacheSetFilter`는 8.0에서 deprecated). hint를 준 쿼리는 계획 경쟁을 하지 않으므로 classic plan cache에 기록되지도 않습니다([`classic_plan_cache.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/classic_plan_cache.cpp#L160-L172)).

#### explain은 이 순서로 읽는다

1. `explainVersion`: 1이면 classic, 2면 SBE. 2라면 `winningPlan.queryPlan`을 봅니다.
2. `winningPlan`의 단계: `COLLSCAN`인지, `IXSCAN`의 `indexName`과 `indexBounds`가 기대한 범위인지, `SORT`가 있는지, `FETCH` 뒤에 `filter`가 남아 있는지.
3. `executionStats`의 `nReturned`, `totalKeysExamined`, `totalDocsExamined`: 셋이 비슷할수록 좋습니다. `totalKeysExamined`가 `nReturned`보다 훨씬 크면 인덱스 범위가 넓은 것이고, `totalDocsExamined`가 크면 FETCH 뒤에서 많이 버리는 것입니다.
4. 후보가 여럿이었다면 `allPlansExecution`의 `score`와 `works`, `rejectedPlans`.

#### 인덱스는 많을수록 좋지 않다

인덱스 하나는 WiredTiger 테이블 하나입니다. 도큐먼트를 넣거나 인덱스 필드를 고칠 때마다 모든 관련 인덱스 테이블에 key를 넣고 지워야 하고, 각 테이블이 캐시와 디스크를 차지합니다. multikey 인덱스는 배열 원소 수만큼 항목이 생깁니다. 인덱스가 많으면 플래너가 경쟁시킬 후보도 늘어 trial 비용과 잘못 고를 가능성도 커집니다. `$indexStats`로 인덱스별 사용 횟수(`accesses.ops`)를 보고, 오랫동안 쓰이지 않은 인덱스는 먼저 숨겨서(`hideIndex`) 영향을 확인한 뒤 지우는 방법을 씁니다.

## 정리

- 인덱스는 key가 **KeyString**(타입 순서까지 바이트 비교로 정렬되는 인코딩)인 WiredTiger 테이블입니다. 일반 인덱스와 unique 인덱스는 key 끝에 RecordId를 붙이고, `_id` 인덱스만 RecordId를 value에 둡니다. 인덱스에 없는 필드가 필요하면 RecordId로 컬렉션을 한 번 더 읽습니다(FETCH).
- 쿼리는 CanonicalQuery로 정규화되어 shape가 정해지고, active plan cache 엔트리가 있으면 그 계획을, 없으면 QueryPlanner가 열거한 후보를 **실제로 조금씩 실행해** 고릅니다.
- trial은 결과 101개, EOF, 또는 후보마다 max(10000, 도큐먼트 수의 30%)번의 `work()`에서 끝나고, 점수는 1 + advanced/works + 작은 보너스 + EOF 보너스 1입니다.
- plan cache 엔트리는 inactive로 시작해, 같은 shape의 다음 trial에서 기록된 works 이하로 끝나면 active가 됩니다. 캐시된 계획이 기록된 works의 10배를 넘기면 replan합니다. 인덱스를 만들거나 지우면 캐시가 비워집니다.
- ESR 순서의 복합 인덱스는 blocking SORT 없이 정렬된 순서로 읽고 limit에서 일찍 멈출 수 있습니다. 필요한 필드가 모두 인덱스에 있으면 FETCH 없는 커버링 쿼리가 됩니다.
- 8.0 기본 설정에서 SBE는 `$group`, `$lookup` 등을 내려보낼 수 있는 집계에만 쓰이고, 그 밖의 find는 classic입니다. `explainVersion`으로 구분합니다.

다음 글에서는 단일 서버를 벗어나, 쓰기가 **oplog**를 통해 레플리카셋의 다른 멤버로 전달되는 과정을 살펴봅니다.

## 참고 자료

소스 코드 (r8.0.32, 커밋 `8f1f561` 기준)

- [src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/wiredtiger/wiredtiger_index.cpp): 인덱스 테이블 형식, 항목 삽입
- [src/mongo/db/storage/key_string.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/storage/key_string.cpp): KeyString 인코딩
- [src/mongo/db/query/get_executor.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/get_executor.cpp): 실행 계획을 얻는 과정, 엔진 선택
- [src/mongo/db/query/query_planner.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_planner.cpp): 후보 계획 열거
- [src/mongo/db/exec/multi_plan.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/multi_plan.cpp), [src/mongo/db/query/plan_ranker.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker.h), [plan_ranker_util.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_ranker_util.h): trial과 점수
- [src/mongo/db/query/plan_cache.h](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/plan_cache.h), [src/mongo/db/exec/cached_plan.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/exec/cached_plan.cpp): plan cache 엔트리 상태, replan
- [src/mongo/db/query/query_knobs.idl](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/query/query_knobs.idl): 쿼리 관련 파라미터 기본값

MongoDB 8.0 공식 문서

- [Query Plans](https://www.mongodb.com/docs/v8.0/core/query-plans/)
- [Explain Results](https://www.mongodb.com/docs/v8.0/reference/explain-results/)
- [The ESR (Equality, Sort, Range) Guideline](https://www.mongodb.com/docs/v8.0/tutorial/equality-sort-range-guideline/)
- [$planCacheStats](https://www.mongodb.com/docs/v8.0/reference/operator/aggregation/planCacheStats/)
- [setQuerySettings](https://www.mongodb.com/docs/v8.0/reference/command/setQuerySettings/)
