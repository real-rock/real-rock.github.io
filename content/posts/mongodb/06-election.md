---
title: "MongoDB 인터널 6: Primary 선출 과정"
date: 2026-09-27
draft: false
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "선출", "레플리카셋", "failover", "not primary", "Can't see a majority of the set"]
weight: 6
summary: "primary가 죽으면 누가, 어떻게 새 primary가 되고, 그동안 쓰기는 어떻게 되는가"
description: "heartbeat와 election timeout, dry run과 term, 투표 규칙, stepDown과 election handoff, priority takeover, 네트워크 분할"
---

## 개요

[5편](/posts/mongodb/05-oplog-and-replication/)에서 쓰기는 모두 primary 한 대가 받고, secondary는 primary의 oplog를 따라간다는 것을 봤습니다. 그렇다면 primary가 죽으면 어떻게 될까요? 남은 멤버들은 primary가 사라졌다는 것을 스스로 알아차리고, 그중 한 대를 새 primary로 뽑습니다. 이것이 **선출**(election)입니다. 사람이 개입하지 않아도 되는 자동 failover가 레플리카셋을 쓰는 가장 큰 이유입니다.

MongoDB의 선출은 분산 합의 알고리즘 **Raft**의 선출 방식을 따릅니다(레플리카셋 설정의 `protocolVersion: 1`). PostgreSQL은 이런 선출을 서버 안에 두지 않아서 Patroni 같은 외부 도구가 맡는데, MongoDB는 mongod 안에 들어 있습니다.

이 글에서 답할 질문은 다음과 같습니다.

- primary가 사라졌다는 것은 누가, 언제 알아차리는가
- 선거는 어떤 순서로 진행되고, term은 무엇을 막는가
- 멤버는 누구에게 표를 주고, 누구에게는 주지 않는가
- `rs.stepDown()`과 priority는 선출을 어떻게 바꾸는가
- 과반을 잃은 primary는 어떻게 되는가
- failover 동안 애플리케이션의 쓰기는 어떻게 되는가

> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 [r8.0.32](https://github.com/mongodb/mongo/tree/r8.0.32) 태그(커밋 `8f1f561`)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다. 레플리카셋은 컨테이너 3대(`m06-1`, `m06-2`, `m06-3`)로 만들었고, 쓰기를 보내는 클라이언트는 별도 컨테이너(`m06-c`)에서 돌렸습니다.

## term과 과반

선출을 이해하는 데 필요한 개념은 두 가지입니다.

- **term**: 선거를 할 때마다 1씩 커지는 번호입니다. 한 term에는 primary가 많아야 한 대입니다. 멤버는 자기보다 큰 term을 보면 곧바로 그 term으로 올라가고, primary였다면 물러납니다. [5편](/posts/mongodb/05-oplog-and-replication/#oplog-엔트리의-모양)에서 본 oplog 엔트리의 `t` 필드가 이 term입니다. 같은 `ts`라도 term이 다르면 다른 primary가 쓴 엔트리라는 것을 알 수 있습니다.
- **과반**(majority): 투표권이 있는 멤버(`votes: 1`) 수의 절반보다 많은 수입니다. 3대면 2, 5대면 3입니다. 선거에서 이기려면 과반의 표가 필요하고, primary도 과반과 연락이 닿아야 primary로 남습니다. 한 term에 멤버마다 한 표씩이므로 두 후보가 같은 term에 동시에 과반을 얻을 수 없습니다.

선출에 관련된 설정은 레플리카셋 설정(`rs.conf().settings`)에 있습니다([`repl_set_config.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.idl#L96-L125)).

| 설정 | 기본값 | 뜻 |
|---|---|---|
| `heartbeatIntervalMillis` | 2000 | 다른 멤버에게 heartbeat를 보내는 간격 |
| `heartbeatTimeoutSecs` | 10 | heartbeat 하나를 재시도하며 기다리는 최대 시간 |
| `electionTimeoutMillis` | 10000 | primary 소식이 이만큼 끊기면 선거를 시작 |
| `catchUpTimeoutMillis` | -1 (무제한) | 새 primary가 다른 멤버를 따라잡으며 기다리는 최대 시간 |
| `catchUpTakeoverDelayMillis` | 30000 | 새 primary보다 앞선 secondary가 catchup takeover를 하기까지 기다리는 시간 |

멤버마다 설정하는 값으로는 `priority`(기본 1, 0이면 primary가 될 수 없음)와 `votes`(1 또는 0)가 있습니다.

#### 선출 설정과 term

priority를 모두 1로 둔 3노드 레플리카셋을 만들고 설정과 상태를 봅니다.

```mongosh
test> rs.initiate({_id: "rs0", members: [{_id: 0, host: "m06-1:27017"}, {_id: 1, host: "m06-2:27017"}, {_id: 2, host: "m06-3:27017"}]})
{
  ok: 1,
...
}
rs0 [direct: primary] test> rs.conf().protocolVersion
Long('1')
rs0 [direct: primary] test> var s = rs.conf().settings; ({heartbeatIntervalMillis: s.heartbeatIntervalMillis, heartbeatTimeoutSecs: s.heartbeatTimeoutSecs, electionTimeoutMillis: s.electionTimeoutMillis, catchUpTimeoutMillis: s.catchUpTimeoutMillis, catchUpTakeoverDelayMillis: s.catchUpTakeoverDelayMillis})
{
  heartbeatIntervalMillis: 2000,
  heartbeatTimeoutSecs: 10,
  electionTimeoutMillis: 10000,
  catchUpTimeoutMillis: -1,
  catchUpTakeoverDelayMillis: 30000
}
rs0 [direct: primary] test> rs.conf().members.map(m => ({host: m.host, priority: m.priority, votes: m.votes}))
[
  { host: 'm06-1:27017', priority: 1, votes: 1 },
  { host: 'm06-2:27017', priority: 1, votes: 1 },
  { host: 'm06-3:27017', priority: 1, votes: 1 }
]
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, electionDate: m.electionDate}))})
{
  term: Long('1'),
  members: [
    {
      name: 'm06-1:27017',
      stateStr: 'PRIMARY',
      electionDate: ISODate('2026-09-27T13:57:51.000Z')
    },
...
  ]
}
rs0 [direct: primary] test> rs.status().electionCandidateMetrics
{
  lastElectionReason: 'electionTimeout',
  lastElectionDate: ISODate('2026-09-27T13:57:51.910Z'),
  electionTerm: Long('1'),
  lastCommittedOpTimeAtElection: { ts: Timestamp({ t: 1790517460, i: 1 }), t: Long('-1') },
  lastSeenWrittenOpTimeAtElection: { ts: Timestamp({ t: 1790517460, i: 1 }), t: Long('-1') },
  lastSeenOpTimeAtElection: { ts: Timestamp({ t: 1790517460, i: 1 }), t: Long('-1') },
  numVotesNeeded: 2,
  priorityAtElection: 1,
  electionTimeoutMillis: Long('10000'),
  numCatchUpOps: Long('0'),
  newTermStartDate: ISODate('2026-09-27T13:57:51.935Z'),
  wMajorityWriteAvailabilityDate: ISODate('2026-09-27T13:57:52.428Z')
}
```

- 설정은 표의 기본값 그대로입니다.
- 셋을 만든 직후 `m06-1`이 첫 선거에서 이겨 term 1의 primary가 되었습니다. 셋을 만든 시점(`Timestamp({ t: 1790517460 ... })`, 13:57:40)에는 primary가 없었으니, election timeout이 지난 13:57:51에 선거가 시작되었고 이유도 `electionTimeout`입니다.
- `electionCandidateMetrics`는 이 멤버가 **후보로서** 치른 마지막 선거의 기록입니다([`_startRealElection()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp#L300-L331)). 이기는 데 표가 2개 필요했고(`numVotesNeeded`), 새 term의 첫 엔트리를 13:57:51.935에 썼고(`newTermStartDate`), 그 엔트리가 과반에 복제되어 `w: "majority"` 쓰기가 가능해진 것은 0.5초 뒤인 13:57:52.428입니다(`wMajorityWriteAvailabilityDate`). `lastElectionReason`이 가질 수 있는 값은 `electionTimeout`, `priorityTakeover`, `stepUpRequest`, `stepUpRequestSkipDryRun`, `catchupTakeover`, `singleNodePromptElection`입니다([`replication_metrics.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_metrics.idl#L44-L54)). 이 글에서 앞의 셋을 차례로 만나게 됩니다.

## 장애 감지: heartbeat와 election timeout

모든 멤버는 다른 모든 멤버에게 2초마다 heartbeat를 보냅니다. 응답에는 상대의 상태(PRIMARY, SECONDARY 등), term, oplog 위치가 들어 있습니다. heartbeat가 실패하면 그 heartbeat를 시작한 지 `heartbeatTimeoutSecs`(10초)가 지나지 않은 동안 곧바로 다시 보내고, 재시도 횟수(`kMaxHeartbeatRetries`, 2번)를 다 쓰면 `Heartbeat failed after max retries`를 남깁니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1098-L1115)). 상대 프로세스가 죽어 연결이 곧바로 거절되면 이 실패가 1~2초 안에 나오고, 네트워크가 끊겨 응답이 오지 않으면 10초 제한까지 기다린 뒤에 나옵니다.

선거를 시작하는 것은 heartbeat 실패 자체가 아니라 **election timeout 타이머**입니다. secondary는 primary로부터 소식(heartbeat 응답, 복제 배치)을 들을 때마다 타이머를 `electionTimeoutMillis` 뒤로 다시 맞춥니다([`_cancelAndRescheduleElectionTimeout_inlock()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp#L1291-L1329)). primary가 죽으면 소식이 끊기고 타이머가 만료되어 선거가 시작됩니다. 이때 만료 시각에 `electionTimeoutMillis`의 최대 15%까지 무작위 시간을 더합니다(`scheduleAtWithJitter`, 비율은 `replElectionTimeoutOffsetLimitFraction` 기본 0.15, [`repl_server_parameters.idl`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_server_parameters.idl#L387-L395)). 모든 secondary가 같은 순간에 후보로 나서 표가 갈리는 일을 줄이기 위해서입니다. 기본값이면 primary 소식이 끊긴 뒤 10~11.5초 사이에 선거가 시작됩니다.

primary 쪽에서도 같은 감시가 돌아갑니다. primary는 `electionTimeoutMillis` 동안 소식이 없는 멤버를 down으로 표시하고, 그 결과 과반과 연락이 닿지 않으면 스스로 물러납니다([`checkMemberTimeouts()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1361-L1378)). 다른 쪽에서 새 primary가 뽑힐 즈음 옛 primary도 물러나므로, 두 primary가 동시에 쓰기를 받는 시간이 길어지지 않습니다. [뒤의 네트워크 분할 실습](#네트워크-분할)에서 이 동작을 봅니다.

## 선거 절차: dry run, term, 투표

타이머가 만료된 secondary는 [`_startElectSelfIfEligibleV1()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp#L1349)에서 선거를 시작합니다.

{{< diagram src="/diagrams/mongo-election-timeout.html" title="primary가 죽은 뒤 새 primary가 뽑히기까지" height="700" caption="primary 소식이 끊기면 election timeout 타이머가 만료되고, 후보는 dry run으로 이길 수 있는지 먼저 확인한 뒤 term을 올려 진짜 투표를 요청합니다. 과반의 표를 얻으면 catch-up과 drain을 거쳐 쓰기를 받기 시작합니다." >}}

1. **후보가 될 수 있는지 확인**: 다음 가운데 하나라도 해당하면 선거에 나서지 않습니다([`_getMyUnelectableReason()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2616-L2656)). 데이터가 없음, 과반이 살아 있는 것으로 보이지 않음(`CannotSeeMajority`), arbiter임, priority가 0, stepdown 뒤 대기 기간 중, SECONDARY 상태가 아님.
2. **dry run**: term을 올리지 않은 채 "지금 선거를 하면 표를 주겠는가"를 `replSetRequestVotes`(`dryRun: true`)로 묻습니다([`ElectionState::start()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp#L232-L258)). 과반이 "예"라고 할 때만 다음 단계로 갑니다. Raft 논문에서 pre-vote라고 부르는 단계입니다. 이 단계가 없으면, 네트워크에서 잠깐 떨어졌던 멤버가 혼자 선거를 거듭하며 term을 계속 올리다가, 돌아왔을 때 그 큰 term 때문에 멀쩡한 primary를 물러나게 만들 수 있습니다.
3. **진짜 선거**: term을 1 올리고, 자기에게 한 표를 준 뒤, 그 사실(LastVote)을 `local.replset.election` 컬렉션에 기록하고 나서 투표를 요청합니다([`_startRealElection()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp#L300), [`_writeLastVoteForMyElection()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp#L358)). 투표 기록을 디스크에 남기는 것은, 투표한 뒤 재시작한 멤버가 같은 term에 다른 후보에게 또 표를 주지 않게 하기 위해서입니다.
4. **과반을 얻으면** `Election succeeded, assuming primary role`을 남기고 primary로 전환합니다([`replication_coordinator_impl_elect_v1.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp#L468-L470)). 전환 과정은 [뒤에서](#새-primary의-catch-up과-drain) 봅니다.

투표 요청을 받은 멤버는 [`processReplSetRequestVotes()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L3623)에서 아래 순서로 검사해, 걸리는 것이 하나라도 있으면 거절합니다.

| 거절 조건 | 이유 |
|---|---|
| 후보의 설정(config version, term)이 내 것보다 오래됨 | 오래된 멤버 목록으로 과반을 세면 안 된다 |
| 후보의 term이 내 term보다 작음 | 이미 지나간 선거다 |
| 레플리카셋 이름이 다름 | |
| 후보의 lastWritten optime이 내 것보다 뒤처짐 | 내가 가진 엔트리를 후보가 갖고 있지 않다 |
| (진짜 선거에서) 이 term에 이미 다른 후보에게 투표함 | 한 term에 한 표 |
| 내가 arbiter인데, priority가 같거나 높은 정상 primary가 보임 | arbiter 때문에 primary가 오락가락하는 것을 막는다 |

네 번째 조건이 중요합니다. 과반의 멤버에게 복제된 엔트리(majority commit된 쓰기)는, 과반 가운데 적어도 한 멤버가 그 엔트리를 갖고 있으므로 그 엔트리가 없는 후보는 그 멤버의 표를 얻지 못합니다. 그래서 **새 primary는 늘 majority commit된 쓰기를 모두 갖고 있습니다.** 8.0에서는 이 비교에 lastWritten(자기 oplog에 쓴 위치, [5편](/posts/mongodb/05-oplog-and-replication/#secondary가-oplog를-따라가는-과정))을 씁니다. 반대로 과반에 닿지 못한 쓰기는 새 primary에 없을 수 있고, 그 쓰기는 옛 primary가 돌아올 때 rollback됩니다([8편](/posts/mongodb/08-read-write-concern/)).

#### primary를 kill -9로 죽이면

[뒤의 stepDown 실습](#rsstepdown으로-넘기기)을 거쳐 지금 primary는 `m06-2`입니다. 클라이언트 컨테이너에서 쓰기를 0.1초마다 보내는 스크립트를 두 벌 띄워 둡니다. 하나는 드라이버 기본값(retryable write 켜짐), 하나는 `retryWrites=false`이고, 0.3초 넘게 걸리거나 실패한 쓰기만 출력합니다.

```console
$ nohup mongosh "mongodb://m06-1:27017,m06-2:27017,m06-3:27017/test?replicaSet=rs0" --quiet --eval 'var C = "retry"' --file /tmp/w.js > /tmp/retry.log 2>&1 < /dev/null &
$ nohup mongosh "mongodb://m06-1:27017,m06-2:27017,m06-3:27017/test?replicaSet=rs0&retryWrites=false" --quiet --eval 'var C = "noretry"' --file /tmp/w.js > /tmp/noretry.log 2>&1 < /dev/null &
```

`/tmp/w.js`는 이렇습니다.

```js
let i = 0; const end = Date.now() + 40000;
while (Date.now() < end) {
  const t = Date.now();
  try {
    db.getCollection(C).insertOne({i: i});
    const ms = Date.now() - t;
    if (ms > 300) print(new Date().toISOString().slice(11, 23), "i=" + i, "ok after", ms, "ms");
  } catch (e) {
    print(new Date().toISOString().slice(11, 23), "i=" + i, "error after", Date.now() - t, "ms:", e.codeName || e.name, "-", e.message);
  }
  i++; sleep(100);
}
print("done", i, "inserts,", db.getCollection(C).countDocuments(), "docs");
```

3초 뒤 primary `m06-2`의 mongod를 `SIGKILL`로 죽입니다.

```console
$ kill -9 17
$ date -u +%T.%3N
13:58:02.135
```

남은 두 멤버의 상태를 새 primary `m06-3`에서 봅니다.

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
{
  term: Long('3'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY', health: 1 },
    {
      name: 'm06-2:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    },
    { name: 'm06-3:27017', stateStr: 'PRIMARY', health: 1 }
  ]
}
rs0 [direct: primary] test> rs.status().electionCandidateMetrics
{
  lastElectionReason: 'electionTimeout',
  lastElectionDate: ISODate('2026-09-27T13:58:12.997Z'),
  electionTerm: Long('3'),
...
  numVotesNeeded: 2,
  priorityAtElection: 1,
  electionTimeoutMillis: Long('10000'),
  numCatchUpOps: Long('0'),
  newTermStartDate: ISODate('2026-09-27T13:58:13.008Z'),
  wMajorityWriteAvailabilityDate: ISODate('2026-09-27T13:58:13.016Z')
}
```

선출 과정은 로그로 봅니다. 선출 관련 메시지만 짧게 뽑는 jq 필터를 파일로 만들어 두었습니다.

```console
$ cat > /tmp/elog.jq <<'JQ'
> select(.msg | test("Starting an election|dry run|Dry election|Election succeeded|catch-up mode|Transition to primary complete|priority takeover|Stepping down from primary|see a majority|replSetStepUp|Handing off election|kill user operations|Replica set state transition"))
> | {t: .t."$date"[11:23], msg, attr: (.attr | {oldState, newState, term, newTerm, when, target} | with_entries(select(.value != null)))}
> JQ
```

후보 `m06-3`의 로그입니다.

```console
$ jq -c 'select(.msg=="Heartbeat failed after max retries" and .attr.target=="m06-2:27017")|{t:.t."$date"[11:23],msg,attr:{target:.attr.target,error:.attr.error.errmsg}}' /data/mongod.log | head -1
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -10
{"t":"13:58:03.793","msg":"Heartbeat failed after max retries","attr":{"target":"m06-2:27017","error":"Error connecting to m06-2:27017 (172.21.0.3:27017) :: caused by :: onInvoke :: caused by :: Connection refused"}}
...
{"t":"13:58:12.995","msg":"Starting an election, since we've seen no PRIMARY in election timeout period","attr":{}}
{"t":"13:58:12.995","msg":"Conducting a dry run election to see if we could be elected","attr":{}}
{"t":"13:58:12.997","msg":"Dry election run succeeded, running for election","attr":{"newTerm":3}}
{"t":"13:58:13.004","msg":"Election succeeded, assuming primary role","attr":{"term":3}}
{"t":"13:58:13.004","msg":"Replica set state transition","attr":{"oldState":"SECONDARY","newState":"PRIMARY"}}
{"t":"13:58:13.004","msg":"Entering primary catch-up mode","attr":{}}
{"t":"13:58:13.006","msg":"Exited primary catch-up mode","attr":{}}
{"t":"13:58:13.007","msg":"Starting to kill user operations","attr":{}}
{"t":"13:58:13.008","msg":"Transition to primary complete; database writes are now permitted","attr":{"term":3}}
```

투표한 `m06-1`의 로그와 `electionParticipantMetrics`입니다.

```console
$ jq -c 'select(.msg=="Responding to vote request")|{t:.t."$date",msg,attr:(.attr|{request,response})}' /data/mongod.log | tail -2
{"t":"2026-09-27T13:58:12.996+00:00","msg":"Responding to vote request","attr":{"request":"{ replSetRequestVotes: 1, setName: \"rs0\", dryRun: true, term: 2, candidateIndex: 2, configVersion: 1, configTerm: 2, lastWrittenOpTime: { ts: Timestamp(1790517482, 2), t: 2 }, lastAppliedOpTime: { ts: Timestamp(1790517482, 2), t: 2 } }","response":"{ term: 2, voteGranted: true, reason: \"\" }"}}
{"t":"2026-09-27T13:58:13.003+00:00","msg":"Responding to vote request","attr":{"request":"{ replSetRequestVotes: 1, setName: \"rs0\", dryRun: false, term: 3, candidateIndex: 2, configVersion: 1, configTerm: 2, lastWrittenOpTime: { ts: Timestamp(1790517482, 2), t: 2 }, lastAppliedOpTime: { ts: Timestamp(1790517482, 2), t: 2 } }","response":"{ term: 3, voteGranted: true, reason: \"\" }"}}
```

```mongosh
rs0 [direct: secondary] test> rs.status().electionParticipantMetrics
{
  votedForCandidate: true,
  electionTerm: Long('3'),
  lastVoteDate: ISODate('2026-09-27T13:58:13.003Z'),
  electionCandidateMemberId: 2,
  voteReason: '',
  lastWrittenOpTimeAtElection: { ts: Timestamp({ t: 1790517482, i: 2 }), t: Long('2') },
  maxWrittenOpTimeInSet: { ts: Timestamp({ t: 1790517482, i: 2 }), t: Long('2') },
...
  priorityAtElection: 1,
  newTermStartDate: ISODate('2026-09-27T13:58:13.008Z'),
  newTermAppliedDate: ISODate('2026-09-27T13:58:13.015Z')
}
```

시간 순서로 정리하면 다음과 같습니다.

| 시각 | 일 |
|---|---|
| 13:58:02.135 | primary `m06-2` 강제 종료 |
| 13:58:03.793 | `m06-3`의 heartbeat가 `Connection refused`로 실패 |
| 13:58:12.995 | election timeout 만료, 선거 시작과 dry run (종료 뒤 10.86초) |
| 13:58:12.996 | `m06-1`이 dry run(term 2)에 찬성 |
| 13:58:12.997 | dry run 통과, term 3으로 진짜 선거 |
| 13:58:13.003 | `m06-1`이 term 3에서 찬성 |
| 13:58:13.004 | 과반(자기 표 + `m06-1`) 획득, PRIMARY로 전환 |
| 13:58:13.008 | 새 term의 첫 엔트리 기록, 쓰기 허용 |

- heartbeat는 종료 1.7초 뒤에 이미 실패했지만, 선거는 그보다 9초 뒤에 시작되었습니다. 선거를 여는 것은 heartbeat 실패가 아니라 election timeout이기 때문입니다. 마지막으로 primary 소식을 들은 때부터 10초에 무작위 오프셋을 더한 시각입니다.
- dry run은 `dryRun: true, term: 2`, 즉 **지금 term 그대로** 표를 물었고, 진짜 선거는 `dryRun: false, term: 3`입니다. 투표자는 두 요청 모두에 `voteGranted: true`를 주었습니다. 후보의 `lastWrittenOpTime`이 투표자의 것(`lastWrittenOpTimeAtElection`)과 같아 뒤처지지 않았기 때문입니다.
- 표 계산은 밀리초 단위로 끝났습니다. failover 시간의 대부분은 **감지**, 즉 election timeout을 기다리는 시간입니다.

#### 그동안 드라이버는 기다렸다

```console
$ cat /tmp/retry.log
$ cat /tmp/noretry.log
13:58:13.016 i=28 ok after 10812 ms
done 271 inserts, 271 docs
13:58:13.016 i=28 ok after 10815 ms
done 271 inserts, 271 docs
```

두 클라이언트 모두 28번째 쓰기가 10.8초 걸렸고, 오류는 없었습니다. 13:58:13.016에 끝났으니, 새 primary가 쓰기를 허용한(13:58:13.008) 직후입니다. retryable write를 끈 쪽도 오류가 나지 않은 것은, 이 쓰기가 **보내지기 전에** primary가 사라졌기 때문입니다. `kill -9`로 프로세스가 죽으면 운영체제가 연결을 바로 끊으므로, 드라이버는 primary가 사라졌음을 곧바로 알고 다음 쓰기를 보낼 primary가 생길 때까지 기다렸습니다(드라이버의 server selection 대기). retryable write가 차이를 만드는 것은 쓰기를 **보낸 뒤 응답을 받기 전에** 문제가 생긴 경우입니다. [네트워크 분할 실습](#분할-중에-보낸-쓰기)에서 그 경우를 봅니다.

## 새 primary의 catch-up과 drain

선거에서 이겼다고 바로 쓰기를 받지는 않습니다. 앞의 로그에서 `Election succeeded`와 `Transition to primary complete` 사이에 두 단계가 있었습니다.

- **catch-up**: 새 primary는 heartbeat로 알게 된 다른 멤버의 위치 가운데 자기보다 앞선 것이 있으면, 그 위치까지 oplog를 받아 옵니다([`CatchupState::start_inlock()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L5140)). 과반에 닿지 못했지만 어떤 secondary에는 있는 엔트리를 살려서, 옛 primary가 돌아왔을 때 rollback될 양을 줄이기 위해서입니다. 기다리는 한도가 `catchUpTimeoutMillis`(기본 무제한)입니다. 실습에서는 모두 같은 위치였으므로 `Entering`에서 `Exited`까지 2ms였고 `numCatchUpOps: 0`입니다. 새 primary가 끝내 따라잡지 못하는 동안 더 앞선 secondary가 있으면, 그 secondary가 `catchUpTakeoverDelayMillis`(30초) 뒤에 **catchup takeover** 선거를 엽니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1709-L1726), [`_amIFreshEnoughForCatchupTakeover()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1826)).
- **drain**: secondary일 때 받아 두고 아직 적용하지 않은 oplog(apply buffer, [5편](/posts/mongodb/05-oplog-and-replication/#secondary가-oplog를-따라가는-과정))를 모두 적용합니다. 그다음 `{msg: "new primary"}`를 담은 no-op 엔트리를 새 term으로 oplog에 쓰고([`onTransitionToPrimary()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_external_state_impl.cpp#L625-L666)), 쓰기를 허용합니다(`Transition to primary complete; database writes are now permitted`). `electionCandidateMetrics.newTermStartDate`가 이 엔트리를 쓴 시각이고, secondary 쪽 `electionParticipantMetrics.newTermAppliedDate`는 그 엔트리를 적용한 시각입니다.

## rs.stepDown()

계획된 작업(버전 업그레이드, 서버 점검)으로 primary를 바꿀 때는 죽이지 않고 `rs.stepDown()`(`replSetStepDown` 명령)을 씁니다. [`ReplicationCoordinatorImpl::stepDown()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L3111)은 이렇게 진행합니다.

1. 복제 상태 전환 락(RSTL)을 exclusive로 잡고 **새 쓰기를 막습니다.** 진행 중인 쓰기는 중단시킵니다(`Starting to kill user operations`).
2. 과반의 멤버가 자기 마지막 위치까지 왔고, 그중 **선출될 수 있는 secondary가 하나라도** 따라왔는지 봅니다([`isSafeToStepDown()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2914-L2948)). 아니면 락을 잠시 풀어 secondary가 oplog를 읽어 가게 하고, `secondaryCatchUpPeriodSecs`(기본 10초, [`repl_set_commands.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_commands.cpp#L610-L619))까지 기다립니다. 그래도 안 되면 `No electable secondaries caught up` 오류로 stepdown을 포기합니다([`tryToStartStepDown()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2857-L2890)). 따라온 secondary가 있을 때만 물러나므로, stepdown으로는 majority commit된 쓰기를 잃지 않습니다.
3. SECONDARY로 내려가고, `stepDownSecs`(기본 60초) 동안은 선거에 나서지 않습니다.
4. **election handoff**: 따라온 secondary 가운데 priority가 가장 높은 멤버에게 `replSetStepUp`(`skipDryRun: true`)을 보내, election timeout을 기다리지 않고 바로 선거를 열게 합니다([`_performElectionHandoff()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp#L3296-L3308), [`chooseElectionHandoffCandidate()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2950), `enableElectionHandoff` 기본 true). 옛 primary가 방금 물러나며 "따라온 것"을 확인했으므로 dry run을 건너뜁니다.

#### rs.stepDown()으로 넘기기

primary `m06-1`에서 한 건 쓰고 물러납니다.

```mongosh
rs0 [direct: primary] test> db.t.insertOne({before: "stepDown"})
{
  acknowledged: true,
  insertedId: ObjectId('6ab920e160932de5a5fdfe24')
}
rs0 [direct: primary] test> rs.stepDown()
{
  ok: 1,
...
}
rs0 [direct: secondary] test> db.t.insertOne({after: "stepDown"})
Uncaught:
MongoServerSelectionError: not primary
Caused by: 
MongoServerError[NotWritablePrimary]: not primary
```

새 primary `m06-2`에서:

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
{
  term: Long('2'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY' },
    { name: 'm06-2:27017', stateStr: 'PRIMARY' },
    { name: 'm06-3:27017', stateStr: 'SECONDARY' }
  ]
}
rs0 [direct: primary] test> var m = rs.status().electionCandidateMetrics; ({lastElectionReason: m.lastElectionReason, electionTerm: m.electionTerm, numVotesNeeded: m.numVotesNeeded, priorPrimaryMemberId: m.priorPrimaryMemberId, numCatchUpOps: m.numCatchUpOps})
{
  lastElectionReason: 'stepUpRequestSkipDryRun',
  electionTerm: Long('2'),
  numVotesNeeded: 2,
  priorPrimaryMemberId: 0,
  numCatchUpOps: Long('0')
}
```

옛 primary `m06-1`의 로그와 새 primary `m06-2`의 로그입니다.

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -3
{"t":"13:57:53.768","msg":"Starting to kill user operations","attr":{}}
{"t":"13:57:53.769","msg":"Replica set state transition","attr":{"oldState":"PRIMARY","newState":"SECONDARY"}}
{"t":"13:57:53.769","msg":"Handing off election","attr":{"target":"m06-2:27017"}}
```

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -9
{"t":"13:57:53.769","msg":"Received replSetStepUp request","attr":{}}
{"t":"13:57:53.769","msg":"Starting an election due to step up request","attr":{}}
{"t":"13:57:53.769","msg":"Skipping dry run and running for election","attr":{"newTerm":2}}
{"t":"13:57:53.770","msg":"Election succeeded, assuming primary role","attr":{"term":2}}
{"t":"13:57:53.770","msg":"Replica set state transition","attr":{"oldState":"SECONDARY","newState":"PRIMARY"}}
{"t":"13:57:53.770","msg":"Entering primary catch-up mode","attr":{}}
{"t":"13:57:53.770","msg":"Exited primary catch-up mode","attr":{}}
{"t":"13:57:53.770","msg":"Starting to kill user operations","attr":{}}
{"t":"13:57:53.771","msg":"Transition to primary complete; database writes are now permitted","attr":{"term":2}}
```

- stepdown 직후 같은 연결로 쓰기를 시도하자 `not primary`(`NotWritablePrimary`) 오류가 났습니다. mongosh가 이 멤버에 직접 접속해 있어서 다른 멤버로 옮겨 가지 않았기 때문입니다. 프롬프트도 `[direct: secondary]`로 바뀌었습니다.
- `m06-1`이 사용자 작업을 끊고 SECONDARY로 내려간 뒤 `m06-2`에게 선거를 넘겼습니다(`Handing off election`).
- `m06-2`는 `replSetStepUp`을 받아 dry run 없이(`Skipping dry run`) term 2 선거를 열어 이겼습니다. 선출 이유가 `stepUpRequestSkipDryRun`, 이전 primary가 member id 0(`m06-1`)입니다. 옛 primary가 물러나기 시작한 13:57:53.768부터 새 primary가 쓰기를 허용한 13:57:53.771까지 **3ms**입니다. election timeout을 기다린 [`kill -9`의 경우](#primary를-kill--9로-죽이면)와 비교하면 차이가 분명합니다.

## priority와 takeover

priority는 "누가 primary가 되면 좋은가"를 정합니다. priority 0인 멤버는 primary가 될 수 없고(표는 줄 수 있음), `votes: 0`인 멤버는 표를 주지 않습니다.

priority가 높은 secondary가 heartbeat로 자기보다 priority가 낮은 primary를 보면 **priority takeover**를 예약합니다([`topology_coordinator.cpp`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1727-L1762)). 예약 시각은 `(priority 순위 + 1) × electionTimeoutMillis`에 무작위 오프셋을 더한 뒤입니다([`getPriorityTakeoverDelay()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.cpp#L752-L756), [예약](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp#L488-L507)). 가장 높은 priority(순위 0)면 10초 남짓, 두 번째면 20초 남짓입니다. 여러 멤버의 priority가 primary보다 높을 때 가장 높은 멤버가 먼저 나서게 하는 장치입니다. 그리고 primary의 최신 위치에서 `priorityTakeoverFreshnessWindowSeconds`(기본 2초) 안으로 따라와 있어야 실제로 선거에 나섭니다([`_amIFreshEnoughForPriorityTakeover()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1796-L1824)). 뒤처진 멤버가 primary를 빼앗아 쓰기를 잃는 일을 막기 위해서입니다. takeover 선거에서 이긴 새 primary의 term이 옛 primary의 term보다 크므로, 옛 primary는 그 term을 보는 순간 물러납니다.

#### priority를 올리면

[kill -9](#primary를-kill--9로-죽이면)로 죽였던 `m06-2`를 다시 켜면 SECONDARY로 돌아옵니다. 그다음 primary `m06-3`에서 `m06-2`의 priority를 3으로 올립니다.

```console
$ mongod --dbpath /data/db --logpath /data/mongod.log --bind_ip_all --fork --replSet rs0 | grep -E 'forked|ERROR'
forked process: 483
```

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
{
  term: Long('3'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY' },
    { name: 'm06-2:27017', stateStr: 'SECONDARY' },
    { name: 'm06-3:27017', stateStr: 'PRIMARY' }
  ]
}
rs0 [direct: primary] test> var c = rs.conf(); c.members[1].priority = 3; rs.reconfig(c).ok
1
```

잠시 뒤 `m06-2`에서:

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
{
  term: Long('4'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY' },
    { name: 'm06-2:27017', stateStr: 'PRIMARY' },
    { name: 'm06-3:27017', stateStr: 'SECONDARY' }
  ]
}
rs0 [direct: primary] test> var m = rs.status().electionCandidateMetrics; ({lastElectionReason: m.lastElectionReason, electionTerm: m.electionTerm, priorityAtElection: m.priorityAtElection})
{
  lastElectionReason: 'priorityTakeover',
  electionTerm: Long('4'),
  priorityAtElection: 3
}
```

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -10
{"t":"13:58:57.791","msg":"Canceling priority takeover callback","attr":{}}
{"t":"13:58:57.791","msg":"Starting an election for a priority takeover","attr":{}}
{"t":"13:58:57.791","msg":"Conducting a dry run election to see if we could be elected","attr":{}}
{"t":"13:58:57.792","msg":"Dry election run succeeded, running for election","attr":{"newTerm":4}}
{"t":"13:58:57.796","msg":"Election succeeded, assuming primary role","attr":{"term":4}}
...
{"t":"13:58:57.801","msg":"Transition to primary complete; database writes are now permitted","attr":{"term":4}}
```

옛 primary `m06-3`에서:

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -3
{"t":"13:58:57.795","msg":"Stepping down from primary, because a new term has begun","attr":{"term":4}}
{"t":"13:58:57.795","msg":"Starting to kill user operations","attr":{}}
{"t":"13:58:57.795","msg":"Replica set state transition","attr":{"oldState":"PRIMARY","newState":"SECONDARY"}}
```

- 아무 장애도 없는데 `m06-2`가 `Starting an election for a priority takeover`로 선거를 열어 term 4의 primary가 되었습니다(`lastElectionReason: 'priorityTakeover'`, `priorityAtElection: 3`). priority takeover도 dry run을 거칩니다.
- 옛 primary `m06-3`는 새 term 4를 보고 `Stepping down from primary, because a new term has begun`으로 물러났습니다. term이 "누가 최신 primary인가"를 정하는 장치로 쓰인 장면입니다.

## 네트워크 분할

primary가 죽지 않고 **네트워크에서만 떨어지면** 어떻게 될까요? 떨어진 primary는 살아 있으니 쓰기를 받으려 하고, 나머지 쪽은 primary 소식이 끊겼으니 새 primary를 뽑습니다. 잠깐이지만 primary가 둘이 될 수 있습니다. MongoDB는 두 장치로 이 시간을 짧게 만듭니다.

- 떨어진 primary는 electionTimeout 동안 과반의 소식을 듣지 못하면 스스로 물러납니다([앞에서 본](#장애-감지-heartbeat와-election-timeout) `checkMemberTimeouts()`).
- 나머지 쪽이 새 term으로 primary를 뽑으므로, 떨어졌던 primary가 돌아오면 더 큰 term을 보고 물러납니다.

두 장치가 모두 electionTimeout을 기준으로 움직이므로 겹치는 시간은 길지 않지만 0은 아닙니다. 그 사이 옛 primary가 받은 `w: 1` 쓰기는 과반에 닿지 못하고, 돌아왔을 때 rollback됩니다. rollback과 이를 막는 `w: "majority"`는 [8편](/posts/mongodb/08-read-write-concern/)에서 다룹니다.

#### primary를 네트워크에서 떼어 내면

앞의 두 클라이언트 스크립트를 다시 띄워 두고, primary `m06-2`의 컨테이너를 레플리카셋 네트워크에서 떼어 냈습니다(13:59:02.458). 15초 뒤 떨어진 `m06-2`에서:

```mongosh
rs0 [direct: secondary] test> var st = rs.status(); ({term: st.term, myState: st.myState, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
{
  term: Long('4'),
  myState: 2,
  members: [
    {
      name: 'm06-1:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    },
    { name: 'm06-2:27017', stateStr: 'SECONDARY', health: 1 },
    {
      name: 'm06-3:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    }
  ]
}
rs0 [direct: secondary] test> db.t.insertOne({from: "isolated"})
MongoServerError[NotWritablePrimary]: not primary
```

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -4
{"t":"13:59:12.308","msg":"Can't see a majority of the set, relinquishing primary","attr":{}}
{"t":"13:59:12.308","msg":"Stepping down from primary in response to heartbeat","attr":{}}
{"t":"13:59:12.309","msg":"Starting to kill user operations","attr":{}}
{"t":"13:59:12.310","msg":"Replica set state transition","attr":{"oldState":"PRIMARY","newState":"SECONDARY"}}
```

나머지 쪽 `m06-3`에서:

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
{
  term: Long('5'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY', health: 1 },
    {
      name: 'm06-2:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    },
    { name: 'm06-3:27017', stateStr: 'PRIMARY', health: 1 }
  ]
}
rs0 [direct: primary] test> rs.status().electionCandidateMetrics.lastElectionReason
electionTimeout
```

- 떨어진 `m06-2`는 떼어 낸 지 9.85초 뒤(13:59:12.308) **`Can't see a majority of the set, relinquishing primary`**를 남기고 SECONDARY로 내려갔습니다. 두 멤버가 모두 `(not reachable/healthy)`이니 자기 한 표로는 과반이 되지 않습니다. 이제 이 멤버에 직접 쓰려 하면 `not primary`입니다. term은 4 그대로입니다. 과반이 보이지 않으니 선거에도 나서지 않습니다.
- 나머지 두 멤버는 서로 과반(2)을 이루므로, election timeout 뒤 `m06-3`가 term 5의 primary가 되었습니다.

13:59:19.221에 `m06-2`를 네트워크에 다시 붙였습니다.

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
{
  term: Long('5'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY' },
    { name: 'm06-2:27017', stateStr: 'SECONDARY' },
    { name: 'm06-3:27017', stateStr: 'PRIMARY' }
  ]
}
```

잠시 뒤 `m06-2`에서:

```mongosh
rs0 [direct: primary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr}))})
{
  term: Long('6'),
  members: [
    { name: 'm06-1:27017', stateStr: 'SECONDARY' },
    { name: 'm06-2:27017', stateStr: 'PRIMARY' },
    { name: 'm06-3:27017', stateStr: 'SECONDARY' }
  ]
}
rs0 [direct: primary] test> rs.status().electionCandidateMetrics.lastElectionReason
priorityTakeover
```

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -12
{"t":"13:59:12.310","msg":"Replica set state transition","attr":{"oldState":"PRIMARY","newState":"SECONDARY"}}
{"t":"13:59:19.378","msg":"Scheduling priority takeover","attr":{"when":{"$date":"2026-09-27T13:59:30.602Z"}}}
{"t":"13:59:30.602","msg":"Canceling priority takeover callback","attr":{}}
{"t":"13:59:30.602","msg":"Starting an election for a priority takeover","attr":{}}
{"t":"13:59:30.602","msg":"Conducting a dry run election to see if we could be elected","attr":{}}
{"t":"13:59:30.603","msg":"Dry election run succeeded, running for election","attr":{"newTerm":6}}
{"t":"13:59:30.607","msg":"Election succeeded, assuming primary role","attr":{"term":6}}
...
{"t":"13:59:30.612","msg":"Transition to primary complete; database writes are now permitted","attr":{"term":6}}
```

- 다시 붙은 `m06-2`는 먼저 term 5의 SECONDARY로 합류했습니다.
- 그런데 `m06-2`의 priority는 앞에서 3으로 올려 두었습니다. 다시 붙은 지 0.16초 만에(13:59:19.378) heartbeat로 priority 1인 primary `m06-3`를 보고 priority takeover를 예약했습니다. 예약 시각 13:59:30.602는 11.2초 뒤로, priority 순위 0에 해당하는 10초에 무작위 오프셋 1.2초가 더해진 값입니다. 그 시각에 선거를 열어 term 6의 primary로 돌아왔습니다.
- 떨어져 있는 동안 `m06-2`에는 새로 들어간 쓰기가 없었으므로(아래 클라이언트의 쓰기도 도착하지 않았습니다) 이번에는 rollback이 일어나지 않았습니다.

#### 분할 중에 보낸 쓰기

```console
$ cat /tmp/retry2.log
$ cat /tmp/noretry2.log
13:59:29.029 i=27 ok after 26652 ms
done 124 inserts, 124 docs
13:59:29.021 i=27 error after 26645 ms: NotWritablePrimary - not primary
done 124 inserts, 123 docs
```

이번에는 두 클라이언트의 결과가 달랐습니다.

- 두 클라이언트 모두 27번째 쓰기가 26.6초 동안 끝나지 않았습니다. 이 쓰기를 시작한 13:59:02.37 무렵은 네트워크를 떼어 낸 순간과 겹칩니다. `kill -9`와 달리 네트워크 분할에서는 연결이 끊겼다는 신호가 오지 않으므로, 드라이버는 이미 보낸 요청의 응답을 계속 기다렸습니다.
- 응답은 네트워크를 다시 붙이고 10초쯤 지난 13:59:29에 왔습니다. 그사이 `m06-2`는 SECONDARY가 되었으므로 `not primary`로 거절했습니다. 분할 동안 전달되지 못한 요청이 재연결 뒤 TCP 재전송으로 뒤늦게 도착한 것으로 보입니다.
- `retryWrites=false` 클라이언트는 이 `NotWritablePrimary` 오류를 그대로 받았고, 124번 가운데 123건만 저장되었습니다. 기본 설정 클라이언트는 같은 오류를 받자 드라이버가 새 primary로 **한 번 더 보내** 성공했고(`ok after 26652 ms`), 124건이 모두 저장되었습니다.

retryable write는 쓰기마다 세션 ID와 트랜잭션 번호를 붙여 보내므로([5편](/posts/mongodb/05-oplog-and-replication/#insert-update-delete를-하나씩)의 `lsid`, `txnNumber`), 첫 시도가 사실은 적용되었더라도 두 번째 시도에서 서버가 "이미 한 쓰기"를 알아보고 다시 실행하지 않습니다. 그래서 드라이버가 안심하고 한 번 재시도할 수 있습니다. 여러 도큐먼트를 바꾸는 `updateMany`, `deleteMany`는 retryable write가 아니므로 이 보호를 받지 못합니다.

## 과반이 없으면 primary도 없다

#### 두 멤버를 끄면

primary `m06-2`만 남기고 나머지 두 멤버를 정상 종료합니다.

```console
$ mongod --dbpath /data/db --shutdown | tail -1
Killing process with pid: 33
```

15초 뒤 `m06-2`에서:

```mongosh
rs0 [direct: secondary] test> var st = rs.status(); ({term: st.term, members: st.members.map(m => ({name: m.name, stateStr: m.stateStr, health: m.health}))})
{
  term: Long('6'),
  members: [
    {
      name: 'm06-1:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    },
    { name: 'm06-2:27017', stateStr: 'SECONDARY', health: 1 },
    {
      name: 'm06-3:27017',
      stateStr: '(not reachable/healthy)',
      health: 0
    }
  ]
}
rs0 [direct: secondary] test> db.t.insertOne({x: "no majority"})
MongoServerError[NotWritablePrimary]: not primary
rs0 [direct: secondary] test> db.t.countDocuments()
1
```

```console
$ jq -c -f /tmp/elog.jq /data/mongod.log | tail -4
$ jq -c 'select(.msg=="Not starting an election, since we are not electable")|{t:.t."$date",msg,attr}' /data/mongod.log | tail -1
{"t":"14:00:25.649","msg":"Can't see a majority of the set, relinquishing primary","attr":{}}
{"t":"14:00:25.649","msg":"Stepping down from primary in response to heartbeat","attr":{}}
{"t":"14:00:25.650","msg":"Starting to kill user operations","attr":{}}
{"t":"14:00:25.650","msg":"Replica set state transition","attr":{"oldState":"PRIMARY","newState":"SECONDARY"}}
{"t":"2026-09-27T14:00:36.427+00:00","msg":"Not starting an election, since we are not electable","attr":{"reason":"Not standing for election because I cannot see a majority (mask 0x1)"}}
```

- 멤버가 멀쩡히 살아 있어도, 과반과 연락이 닿지 않으면 primary는 물러납니다(`Can't see a majority of the set`). 이후 election timeout이 돌아와도 **`Not standing for election because I cannot see a majority`**로 선거에 나서지 않습니다([`_getMyUnelectableReason()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L2624-L2626), 과반 판단은 [`_aMajoritySeemsToBeUp()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp#L1766-L1777)).
- 그래서 쓰기는 `not primary`로 거절되지만, 읽기(`countDocuments()`)는 SECONDARY에서도 됩니다. 과반을 잃은 레플리카셋은 **읽기 전용**이 됩니다.
- 한 대만 남은 쪽이 primary를 계속 하면 안 되는 이유는 [네트워크 분할](#네트워크-분할)과 같습니다. 남은 한 대는 "다른 둘이 죽었는지, 나만 떨어졌는지" 구별할 수 없습니다. 다른 둘이 살아서 새 primary를 뽑았을 수도 있으므로, 과반이 보이지 않으면 물러나는 것이 안전한 쪽입니다.

## 운영에서는 이렇게 나타납니다

**failover 동안 쓰기가 멈추는 시간.** [kill -9 실습](#primary를-kill--9로-죽이면)에서 쓰기가 10.8초 멈췄고, 거의 전부가 election timeout을 기다린 시간이었습니다. 계획된 작업에서는 primary를 그냥 끄지 말고 먼저 `rs.stepDown()`을 해야 하는 이유입니다. [stepDown 실습](#rsstepdown으로-넘기기)에서 primary가 바뀌는 데 3ms가 걸렸습니다. 서버를 재시작하는 순서는 secondary부터 하나씩, 마지막에 primary를 stepDown한 뒤 재시작입니다.

**retryable write는 켜 두고, 그래도 오류 처리는 합니다.** 최근 드라이버는 기본으로 `retryWrites=true`입니다. [분할 실습](#분할-중에-보낸-쓰기)처럼 응답을 못 받은 쓰기를 한 번 재시도해 주지만 딱 한 번이고, `updateMany`, `deleteMany`는 대상이 아닙니다. 재시도해도 새 primary가 아직 없으면 오류가 납니다. 애플리케이션은 `NotWritablePrimary`나 네트워크 오류를 "잠시 뒤 다시"로 처리할 수 있어야 합니다. failover 중에 쓰기가 멈춰 있는 시간(실습에서 10~27초)이 애플리케이션의 타임아웃보다 길면, 사용자에게는 오류로 보입니다.

**`electionTimeoutMillis` 조정은 트레이드오프입니다.** 줄이면 장애 감지와 failover가 빨라지지만, 네트워크가 잠깐 흔들리거나 primary가 GC, 디스크 지연으로 몇 초 멈춘 것만으로도 선거가 열립니다. 불필요한 선거는 쓰기를 짧게 끊고 진행 중인 작업을 중단시키며([`Starting to kill user operations`](#rsstepdown으로-넘기기)), `w: 1` 쓰기의 rollback 위험도 만듭니다. 늘리면 반대입니다. 기본값 10초를 바꾸려면 네트워크 지연과 서버의 멈춤 시간을 측정한 근거가 있어야 합니다.

**멤버 수는 홀수로.** 과반은 투표 멤버 수의 절반 초과이므로, 4대면 과반이 3이라 3대와 마찬가지로 한 대만 잃을 수 있습니다. 데이터 센터 두 곳에 2대씩 나누면 어느 쪽도 과반이 아니어서, 두 곳 사이의 네트워크가 끊기면 양쪽 모두 primary가 없습니다. 세 번째 위치에 멤버 하나(가능하면 데이터를 가진 멤버, 여의치 않으면 arbiter)를 둡니다. arbiter는 투표만 하고 데이터가 없습니다. primary, secondary, arbiter 구성(PSA)에서 secondary가 죽으면 선출은 되지만, majority commit에 필요한 수는 데이터를 가진 투표 멤버 수로 제한되고([`_calculateMajorities()`](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.cpp#L627-L636)) primary 혼자로는 채워지지 않아 `w: "majority"` 쓰기가 끝나지 않습니다([5편](/posts/mongodb/05-oplog-and-replication/#secondary가-oplog를-따라가는-과정)의 commit point). 이 글에서는 arbiter 구성을 실측하지 않았습니다.

**데이터 센터 배치와 priority.** 평소에는 주 데이터 센터의 멤버가 primary가 되도록 그쪽 멤버의 priority를 높이고, 재해 복구용 원격 멤버는 낮은 priority(또는 0)로 둡니다. [priority 실습](#priority를-올리면)처럼 priority가 높은 멤버는 돌아오는 즉시(약 10초 뒤) primary를 되찾습니다. 장애에서 막 복구된 멤버가 곧바로 primary가 되는 것이 부담스럽다면 이 동작도 고려해야 합니다.

## 정리

- MongoDB의 선출은 Raft 방식(`protocolVersion: 1`)입니다. **term**마다 primary는 많아야 하나이고, 선거에서 이기려면 투표 멤버 **과반**의 표가 필요합니다.
- 멤버는 2초마다 heartbeat를 주고받습니다. secondary는 primary 소식이 `electionTimeoutMillis`(10초)와 최대 15%의 무작위 시간 동안 끊기면 선거를 엽니다. 실습에서 primary를 죽인 뒤 선거가 시작되기까지 10.86초, 표를 모아 쓰기를 허용하기까지는 13ms가 더 걸렸습니다.
- 후보는 먼저 term을 올리지 않은 **dry run**으로 이길 수 있는지 확인하고, term을 올려 자기 표를 기록한 뒤 진짜 투표를 요청합니다. 투표자는 lastWritten이 자기보다 뒤처진 후보나 이미 표를 준 term의 다른 후보에게는 표를 주지 않습니다. 그래서 새 primary는 majority commit된 쓰기를 모두 갖습니다.
- 새 primary는 catch-up과 drain을 거쳐 `new primary` 엔트리를 쓴 뒤 쓰기를 받습니다.
- `rs.stepDown()`은 따라온 secondary가 있을 때만 물러나고, election handoff로 dry run 없이 곧바로 선거를 넘깁니다(`stepUpRequestSkipDryRun`, 실습에서 3ms). priority가 높은 secondary는 **priority takeover**로 primary를 가져갑니다.
- 과반과 연락이 끊긴 primary는 **`Can't see a majority of the set`**으로 스스로 물러나고, 과반이 없는 쪽에는 primary가 없습니다. 쓰기는 `not primary`로 거절됩니다.
- 응답을 받지 못한 쓰기는 retryable write가 한 번 재시도해 줍니다.

다음 글에서는 레플리카셋 여러 개를 묶어 데이터를 나눠 담는 **샤딩 구조**를 살펴봅니다.

## 참고 자료

소스 코드 (`r8.0.32` 커밋 `8f1f561` 기준)

- [src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp): dry run과 진짜 선거, LastVote 기록
- [src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp): heartbeat 처리, election timeout, takeover 예약
- [src/mongo/db/repl/topology_coordinator.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/topology_coordinator.cpp): 투표 규칙, 선출 자격, takeover 판단, stepdown 조건, 과반을 잃었을 때의 stepdown
- [src/mongo/db/repl/replication_coordinator_impl.cpp](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_coordinator_impl.cpp): `stepDown`, election handoff, catch-up과 drain
- [src/mongo/db/repl/repl_set_config.idl](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/repl_set_config.idl): 선출 관련 설정의 기본값
- [src/mongo/db/repl/replication_metrics.idl](https://github.com/mongodb/mongo/blob/8f1f561d203201f9f19e832374813f46cfe0dc29/src/mongo/db/repl/replication_metrics.idl): `electionCandidateMetrics`, `electionParticipantMetrics`

MongoDB 8.0 공식 문서

- [Replica Set Elections](https://www.mongodb.com/docs/v8.0/core/replica-set-elections/)
- [Retryable Writes](https://www.mongodb.com/docs/v8.0/core/retryable-writes/)
- [rs.stepDown()](https://www.mongodb.com/docs/v8.0/reference/method/rs.stepDown/)

논문

- Diego Ongaro, John Ousterhout, [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) (Raft)
