---
title: "PostgreSQL 인터널 4: MVCC"
date: 2026-09-24
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "MVCC", "트랜잭션", "스냅샷"]
weight: 4
summary: "PostgreSQL은 어떻게 읽기와 쓰기가 서로를 막지 않게 하는가"
description: "xmin/xmax, 스냅샷, 튜플 가시성 판단"
---

## 개요

두 사람이 같은 은행 계좌를 동시에 본다고 해 봅시다. 한 사람이 잔액을 고치는 중이면, 다른 사람은 고치기 전 값을 봐야 할까요, 고친 뒤 값을 봐야 할까요? 그리고 고치는 동안 읽는 사람을 기다리게 해야 할까요?

PostgreSQL은 이 문제를 **MVCC**(Multi-Version Concurrency Control, 다중 버전 동시성 제어)로 풉니다. 행을 제자리에서 고치지 않고 **새 버전을 하나 더 만듭니다.** 그리고 트랜잭션마다 "어느 시점까지 커밋된 것을 볼지"를 정한 **스냅샷**으로, 여러 버전 가운데 자기에게 보이는 버전 하나를 고릅니다. 그래서 읽는 쪽은 쓰는 쪽을 기다리지 않고, 쓰는 쪽도 읽는 쪽을 기다리지 않습니다.

이 글에서 답할 질문은 다음과 같습니다.

- UPDATE, DELETE를 하면 페이지에서는 실제로 무슨 일이 일어나는가
- 스냅샷은 무엇이고, "보인다"는 것은 정확히 어떻게 판단하는가
- READ COMMITTED와 REPEATABLE READ는 무엇이 다른가
- 두 트랜잭션이 같은 행을 동시에 고치면 어떻게 되는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 트랜잭션 ID와 행의 xmin, xmax

트랜잭션이 처음으로 xid가 필요해질 때(데이터를 바꾸거나, `FOR UPDATE`로 행을 잠그거나, `pg_current_xact_id()`를 부를 때) PostgreSQL은 32비트 **트랜잭션 ID(xid)**를 하나 발급합니다([`GetNewTransactionId()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/varsup.c#L77)). 그 전까지, 그리고 읽기만 하는 트랜잭션은 xid 없이 가상 ID만 가집니다. xid는 1씩 커지므로, 번호가 작을수록 먼저 xid를 받은(처음으로 쓰기를 한) 트랜잭션입니다. 트랜잭션을 시작한 순서와는 다를 수 있습니다([문서](https://www.postgresql.org/docs/18/transaction-id.html)).

[3편](/posts/postgresql/03-storage-layout/)에서 본 튜플 헤더에는 이 xid가 두 개 적혀 있습니다.

| 필드 | 뜻 | SQL로 볼 때 |
|---|---|---|
| `t_xmin` | 이 버전을 만든 트랜잭션 | 숨은 열 `xmin` |
| `t_xmax` | 이 버전을 지웠거나(UPDATE, DELETE) 잠근(`FOR UPDATE`) 트랜잭션. 없으면 0 | 숨은 열 `xmax` |

그러면 명령마다 이렇게 됩니다.

| 명령 | 페이지에서 일어나는 일 |
|---|---|
| INSERT | 새 튜플을 쓰고 `xmin` = 내 xid |
| DELETE | 기존 튜플의 `xmax` = 내 xid. 튜플은 그대로 남음 |
| UPDATE | 기존 튜플의 `xmax` = 내 xid, `t_ctid`가 새 버전을 가리킴. 새 튜플을 쓰고 `xmin` = 내 xid |
| ROLLBACK | 아무것도 되돌리지 않음. 내 xid가 "롤백됨"으로 기록될 뿐 |

마지막 줄이 중요합니다. PostgreSQL의 ROLLBACK은 페이지를 되돌리지 않습니다. 대신 **각 트랜잭션이 커밋되었는지 롤백되었는지를 따로 기록**해 두고, 튜플을 읽을 때마다 그 기록을 봅니다. 이 기록이 `$PGDATA/pg_xact` 디렉터리입니다. 트랜잭션 하나당 [2비트](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/clog.c#L62-L64)로 [네 가지 상태](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/clog.h#L27-L30)(진행 중, 커밋, 롤백, 하위 트랜잭션 커밋)를 적으므로, 8kB 페이지 하나에 트랜잭션 32768개의 상태가 들어갑니다.

지워지거나 옛 버전이 된 튜플(**dead tuple**)은 아무도 볼 일이 없어진 뒤 VACUUM이 정리합니다. [5편](/posts/postgresql/05-vacuum/)에서 다룹니다.

### 스냅샷: "어느 시점까지를 볼 것인가"

스냅샷은 "지금 이 순간 어떤 트랜잭션이 끝났고 어떤 트랜잭션이 아직 진행 중인가"를 찍어 둔 것입니다([`SnapshotData`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/utils/snapshot.h#L138-L165)). 핵심 필드는 세 개이고, `pg_current_snapshot()`은 이를 `xmin:xmax:xip목록` 형식으로 보여 줍니다.

| 필드 | 뜻 |
|---|---|
| `xmin` | 이보다 작은 xid는 모두 끝났음 (커밋이든 롤백이든) |
| `xmax` | 스냅샷을 찍을 때까지 끝난 xid 가운데 가장 큰 값 + 1([`procarray.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/procarray.c#L2247-L2249)). 이 값 이상인 xid는 **아직 끝나지 않은 것으로 취급** |
| `xip` | `xmin` 이상 `xmax` 미만 가운데 **스냅샷을 찍을 때 진행 중이던** xid 목록 |

스냅샷은 공유 메모리의 실행 중 트랜잭션 목록(ProcArray)을 훑어서 만듭니다([`GetSnapshotData()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/procarray.c#L2175)). 자기 자신의 xid는 `xip`에 넣지 않습니다([`procarray.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/procarray.c#L2288-L2294)). 자기가 한 일은 스냅샷이 아니라 "나 자신인가"를 따로 검사해서 판단하기 때문입니다. 어떤 xid가 "내 스냅샷 기준으로 진행 중인가"는 [`XidInMVCCSnapshot()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/time/snapmgr.c#L1905-L1920)이 판단합니다. `xmin`보다 작으면 끝난 것, `xmax` 이상이면 진행 중, 그 사이면 `xip`에 있는지 봅니다.

여기서 핵심은 **진행 중으로 취급된 트랜잭션이 한 일은 보이지 않는다**는 것입니다. 스냅샷을 찍은 뒤에 그 트랜잭션이 커밋해도, 이 스냅샷을 쓰는 동안은 여전히 보이지 않습니다.

### 가시성 판단: 이 튜플은 나에게 보이는가

튜플을 읽을 때마다 [`HeapTupleSatisfiesMVCC()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L960)가 내 스냅샷으로 그 튜플이 보이는지 판단합니다. 단순하게 줄이면 이렇습니다.

{{< diagram src="/diagrams/pg-mvcc-visibility.html" title="튜플 하나가 내 스냅샷에서 보이는지 판단하는 과정" height="560" caption="xmin으로 '이미 태어났는가'를, xmax로 '아직 살아 있는가'를 봅니다." >}}

1. **만든 트랜잭션(xmin)이 내 스냅샷 기준으로 진행 중이면** 안 보입니다([`heapam_visibility.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L1063-L1064)).
2. **만든 트랜잭션이 롤백되었으면** 안 보입니다. 커밋되었는지는 튜플의 hint bit를 먼저 보고, 없으면 pg_xact를 찾아봅니다([`TransactionIdDidCommit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L1065)).
3. **지운 트랜잭션(xmax)이 없거나, 잠금만 했으면** 보입니다([`heapam_visibility.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L1086-L1090)).
4. **지운 트랜잭션이 내 스냅샷 기준으로 진행 중이거나 롤백되었으면** 아직 보입니다. 커밋되었으면 안 보입니다.

그림에서 뺀 경우가 하나 있습니다. xmin이나 xmax가 **나 자신**이면 스냅샷 대신 명령 번호(`cmin`, `cmax`)로 판단합니다. 같은 트랜잭션 안에서 방금 넣은 행은 다음 명령부터 보이고 같은 명령 안에서는 보이지 않습니다. 반대로 내가 지운 행은 지우기 전에 시작한 명령에는 계속 보입니다([`heapam_visibility.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L1119-L1126)).

pg_xact를 매번 찾아보면 느리므로, 보통은 커밋 여부를 처음 확인한 쪽이 결과를 튜플의 `t_infomask`에 **hint bit**로 적어 둡니다([`SetHintBits()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c#L114-L128)). 비동기 커밋 직후처럼 커밋 WAL이 아직 디스크에 없으면 적지 않고 넘어가는 예외도 있습니다. 다음부터는 튜플만 보고 바로 판단할 수 있습니다. [2편](/posts/postgresql/02-memory-architecture/)에서 SELECT만 했는데 페이지가 dirty가 된 이유가 이것입니다.

### 격리 수준은 "스냅샷을 언제 찍느냐"의 차이

PostgreSQL의 격리 수준 차이는 대부분 **스냅샷을 얼마나 자주 새로 찍느냐**로 설명됩니다([`GetTransactionSnapshot()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/time/snapmgr.c#L271-L345)).

| 격리 수준 | 스냅샷 | 결과 |
|---|---|---|
| READ COMMITTED (기본값) | **명령마다** 새로 찍음 | 같은 트랜잭션 안에서도 명령마다 그 사이 커밋된 변경이 보임 |
| REPEATABLE READ | 트랜잭션의 **첫 명령에서 한 번** 찍고 끝까지 씀 | 트랜잭션 내내 같은 데이터가 보임 |
| SERIALIZABLE | REPEATABLE READ처럼 한 번 찍고, 직렬로 실행한 것과 결과가 다를 수 있는 패턴을 감지해 오류를 냄 | |

### 같은 행을 동시에 고치면

읽기는 스냅샷 덕분에 서로 막지 않지만, **같은 행을 두 트랜잭션이 동시에 고치는 것**은 막아야 합니다. A가 행을 고치고 아직 커밋하지 않았는데 B도 같은 행을 고치려 하면, B는 그 행의 `xmax`에 적힌 A의 xid를 보고 **A가 끝날 때까지 기다립니다**([`XactLockTableWait()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/lmgr/lmgr.c#L663)). xid를 발급받은 트랜잭션은 그 순간 자기 xid에 대한 잠금을 잡고([`xact.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xact.c#L729)), 끝날 때 풉니다. B는 A의 xid 잠금을 기다리는 것입니다.

A가 커밋한 뒤 B가 어떻게 하는지는 격리 수준에 따라 다릅니다([`ExecUpdate()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/nodeModifyTable.c#L2595-L2629)).

- **READ COMMITTED**: A가 만든 새 버전을 다시 읽어 WHERE 조건을 다시 확인하고(EvalPlanQual), 여전히 맞으면 **새 버전 위에** 자기 UPDATE를 합니다. 조건이 더는 맞지 않으면 그 행은 건너뜁니다.
- **REPEATABLE READ**: B의 스냅샷에서는 A의 변경이 보이지 않는데, 그 위에 덮어쓰면 A의 변경을 잃게 됩니다. 그래서 `could not serialize access due to concurrent update` 오류를 냅니다. 애플리케이션이 트랜잭션을 처음부터 다시 시도해야 합니다. A가 커밋하지 않고 롤백했다면 B는 오류 없이 진행합니다.

## 직접 확인해 보기

### 실습 환경

[2편부터 쓰는 실습 이미지](/labs/pg-lab-image/Dockerfile)로, [lab.sh](/labs/pg-04-mvcc/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-04-mvcc/final-run.log)에 있습니다.

실습 5부터는 psql 세션 두 개(A, B)를 동시에 열어 둡니다. `-- 세션 A`로 시작하는 SQL 블록은 세션 A에 보낸 명령이고, 그 아래 `text` 블록이 그 세션에 찍힌 출력입니다. 명령은 적힌 순서대로 번갈아 보냈습니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
181f017031b84d5ede97f7a48cf117b51c9008d9904a5190391066612d1f6439
[exit=0]
```

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pageinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int)"
psql -X -q -c "INSERT INTO acct VALUES (1, 100), (2, 100)"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. 모든 행에는 xmin과 xmax가 있다

```bash
psql -X <<'SQL'
SELECT xmin, xmax, cmin, ctid, * FROM acct;
BEGIN;
SELECT pg_current_xact_id() AS my_xid;
INSERT INTO acct VALUES (3, 100);
INSERT INTO acct VALUES (4, 100);
SELECT xmin, cmin, ctid, * FROM acct WHERE id IN (3, 4);
COMMIT;
SQL
```

```text
 xmin | xmax | cmin | ctid  | id | balance 
------+------+------+-------+----+---------
  754 |    0 |    0 | (0,1) |  1 |     100
  754 |    0 |    0 | (0,2) |  2 |     100
(2 rows)

BEGIN
 my_xid 
--------
    755
(1 row)

INSERT 0 1
INSERT 0 1
 xmin | cmin | ctid  | id | balance 
------+------+-------+----+---------
  755 |    0 | (0,3) |  3 |     100
  755 |    1 | (0,4) |  4 |     100
(2 rows)

COMMIT
[exit=0]
```

- 처음 넣은 두 행은 `xmin = 754`입니다. 트랜잭션 754가 만들었다는 뜻입니다.
- 트랜잭션 755 안에서 INSERT를 두 번 하자 두 행 모두 `xmin = 755`이고, `cmin`이 0과 1로 다릅니다. 같은 트랜잭션 안에서 데이터를 바꾼 명령 가운데 몇 번째가 만들었는지입니다(앞의 `SELECT`처럼 읽기만 한 명령은 번호를 쓰지 않습니다).

### 실습 2. UPDATE는 새 버전을 만든다

```bash
psql -X <<'SQL'
BEGIN;
SELECT pg_current_xact_id() AS my_xid;
UPDATE acct SET balance = 150 WHERE id = 1;
COMMIT;
SELECT xmin, xmax, ctid, * FROM acct WHERE id = 1;
SELECT lp, t_xmin, t_xmax, t_ctid, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
SQL
```

```text
BEGIN
 my_xid 
--------
    756
(1 row)

UPDATE 1
COMMIT
 xmin | xmax | ctid  | id | balance 
------+------+-------+----+---------
  756 |    0 | (0,5) |  1 |     150
(1 row)

 lp | t_xmin | t_xmax | t_ctid |                              raw_flags                               
----+--------+--------+--------+----------------------------------------------------------------------
  1 |    754 |    756 | (0,5)  | {HEAP_XMIN_COMMITTED,HEAP_XMAX_COMMITTED,HEAP_HOT_UPDATED}
  2 |    754 |      0 | (0,2)  | {HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID}
  3 |    755 |      0 | (0,3)  | {HEAP_XMAX_INVALID}
  4 |    755 |      0 | (0,4)  | {HEAP_XMAX_INVALID}
  5 |    756 |      0 | (0,5)  | {HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID,HEAP_UPDATED,HEAP_ONLY_TUPLE}
(5 rows)

[exit=0]
```

`id = 1`의 잔액을 150으로 바꾸자, SQL로는 행이 하나지만 페이지에는 **두 버전**이 있습니다.

- lp 1(옛 버전): `t_xmax = 756`, `t_ctid = (0,5)`. 트랜잭션 756이 지웠고, 새 버전은 5번에 있다는 뜻입니다.
- lp 5(새 버전): `t_xmin = 756`. `HEAP_UPDATED`는 UPDATE로 생긴 버전이라는 표시입니다.
- 옛 버전의 `HEAP_HOT_UPDATED`와 새 버전의 `HEAP_ONLY_TUPLE`은 이 UPDATE가 **HOT**(Heap-Only Tuple) 업데이트였다는 뜻입니다. 새 버전이 같은 페이지에 들어갔고 인덱스 열(`id`)이 바뀌지 않아서, 인덱스를 고치지 않고 버전 체인만 이었습니다. [5편](/posts/postgresql/05-vacuum/)에서 자세히 다룹니다.

### 실습 3. DELETE와 ROLLBACK도 튜플을 지우지 않는다

```bash
psql -X <<'SQL'
DELETE FROM acct WHERE id = 4;
BEGIN;
SELECT pg_current_xact_id() AS rollback_xid \gset
INSERT INTO acct VALUES (5, 100);
ROLLBACK;
SELECT * FROM acct ORDER BY id;
SELECT lp, t_xmin, t_xmax, t_ctid, t_data
FROM heap_page_items(get_raw_page('acct', 0));
SELECT :'rollback_xid' AS xid, pg_xact_status(:'rollback_xid'::xid8) AS status;
SQL
```

```text
DELETE 1
BEGIN
INSERT 0 1
ROLLBACK
 id | balance 
----+---------
  1 |     150
  2 |     100
  3 |     100
(3 rows)

 lp | t_xmin | t_xmax | t_ctid |       t_data       
----+--------+--------+--------+--------------------
  1 |    754 |    756 | (0,5)  | \x0100000064000000
  2 |    754 |      0 | (0,2)  | \x0200000064000000
  3 |    755 |      0 | (0,3)  | \x0300000064000000
  4 |    755 |    757 | (0,4)  | \x0400000064000000
  5 |    756 |      0 | (0,5)  | \x0100000096000000
  6 |    758 |      0 | (0,6)  | \x0500000064000000
(6 rows)

 xid | status  
-----+---------
 758 | aborted
(1 row)

[exit=0]
```

- DELETE한 `id = 4`(lp 4)는 페이지에 그대로 있고 `t_xmax = 757`만 적혔습니다.
- INSERT 후 ROLLBACK한 `id = 5`(lp 6, `t_xmin = 758`)도 페이지에 남아 있습니다. SQL로 조회하면 둘 다 보이지 않습니다. lp 4는 지운 트랜잭션 757이 커밋되었기 때문이고, lp 6은 만든 트랜잭션 758이 롤백되었기(`pg_xact_status(758)` = `aborted`) 때문입니다.
- 결국 이 페이지에는 튜플 6개가 있지만 보이는 행은 3개입니다. 나머지 3개(lp 1, 4, 6)가 dead tuple입니다.

### 실습 4. 커밋 여부는 pg_xact에 2비트로 적힌다

```bash
ls -l $PGDATA/pg_xact
psql -X -c "SELECT x AS xid, pg_xact_status(x::text::xid8) AS status FROM generate_series(754, 758) x"
```

```text
total 8
-rw------- 1 postgres postgres 8192 Sep 24 03:29 0000
 xid |  status   
-----+-----------
 754 | committed
 755 | committed
 756 | committed
 757 | committed
 758 | aborted
(5 rows)

[exit=0]
```

pg_xact 파일 `0000` 하나가 8kB로, 지금까지의 트랜잭션 상태가 모두 여기 들어 있습니다. 754-757은 커밋, 758은 롤백입니다.

### 실습 5. 스냅샷: 아직 커밋 안 된 변경은 보이지 않는다

세션 A가 트랜잭션을 열고 `id = 2`를 999로 바꿉니다. 그 사이 다른 트랜잭션 하나(760)가 커밋합니다.

```sql
-- 세션 A
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 A
SELECT pg_current_xact_id() AS a_xid;
```

```text
 a_xid 
-------
   759
(1 row)
```

```sql
-- 세션 A
UPDATE acct SET balance = 999 WHERE id = 2;
```

```text
UPDATE 1
```

그 사이 다른 세션에서 트랜잭션 하나를 커밋합니다(자동 커밋, xid 760).

```bash
psql -X -c "INSERT INTO acct VALUES (7, 100) RETURNING xmin AS other_xid"
```

```text
 other_xid 
-----------
       760
(1 row)

INSERT 0 1
[exit=0]
```

```sql
-- 세션 A
SELECT pg_current_snapshot() AS a_snapshot, balance FROM acct WHERE id = 2;
```

```text
 a_snapshot | balance 
------------+---------
 759:761:   |     999
(1 row)
```

이 상태에서 세션 B가 READ COMMITTED 트랜잭션을 열고 같은 행을 읽습니다.

```sql
-- 세션 B
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 B
SELECT pg_current_snapshot() AS b_snapshot, balance FROM acct WHERE id = 2;
```

```text
 b_snapshot  | balance 
-------------+---------
 759:761:759 |     100
(1 row)
```

B의 스냅샷은 `759:761:759`입니다.

- `xmin = 759`: 759보다 작은 xid는 모두 끝났습니다.
- `xmax = 761`: 마지막으로 끝난 트랜잭션이 760이라 761입니다. 761 이상은 끝나지 않은 것으로 봅니다.
- `xip = 759`: 그 사이의 759(세션 A)는 **아직 진행 중**입니다. 760은 이미 커밋해서 목록에 없습니다.

`id = 2`의 새 버전은 `xmin = 759`인데 759가 진행 중이므로 보이지 않고, 옛 버전(`xmax = 759`)은 지운 트랜잭션이 진행 중이므로 아직 보입니다. 그래서 B는 100을 봅니다. A는 자기가 만든 버전이라 999를 봅니다. A의 스냅샷 `759:761:`에 759가 없는 것은 자기 xid를 xip에 넣지 않기 때문입니다.

```sql
-- 세션 A
COMMIT;
```

```text
COMMIT
```

```sql
-- 세션 B
SELECT pg_current_snapshot() AS b_snapshot, balance FROM acct WHERE id = 2;
```

```text
 b_snapshot | balance 
------------+---------
 761:761:   |     999
(1 row)
```

```sql
-- 세션 B
COMMIT;
```

```text
COMMIT
```

A가 커밋한 뒤 B가 **같은 트랜잭션 안에서** 다시 읽자, 스냅샷이 `761:761:`(진행 중 없음)로 바뀌었고 999가 보입니다. READ COMMITTED는 **명령마다 스냅샷을 새로 찍기** 때문입니다. 아래 그림은 이 과정을 순서대로 그린 것입니다.

{{< diagram src="/diagrams/pg-mvcc-snapshot.html" title="두 세션의 스냅샷 (실습 5)" height="560" caption="B의 첫 스냅샷에는 A(759)가 진행 중으로 들어 있어 옛 버전을 보고, A가 커밋한 뒤의 새 스냅샷에서는 새 버전을 봅니다." >}}

### 실습 6. READ COMMITTED와 REPEATABLE READ

세션 B가 REPEATABLE READ로 트랜잭션을 시작해 잔액 합계를 봅니다. 그 사이 세션 A(자동 커밋)가 `id = 3`에 1000을 더합니다.

```sql
-- 세션 B
BEGIN ISOLATION LEVEL REPEATABLE READ;
```

```text
BEGIN
```

```sql
-- 세션 B
SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;
```

```text
 b_snapshot | sum  
------------+------
 761:761:   | 1349
(1 row)
```

```sql
-- 세션 A
UPDATE acct SET balance = balance + 1000 WHERE id = 3;
```

```text
UPDATE 1
```

```sql
-- 세션 B
SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;
```

```text
 b_snapshot | sum  
------------+------
 761:761:   | 1349
(1 row)
```

```sql
-- 세션 B
COMMIT;
```

```text
COMMIT
```

```sql
-- 세션 B
SELECT pg_current_snapshot() AS b_snapshot, sum(balance) FROM acct;
```

```text
 b_snapshot | sum  
------------+------
 762:762:   | 2349
(1 row)
```

A가 1000을 더해 커밋했는데도, B의 트랜잭션 안에서는 합계가 계속 1349이고 스냅샷도 `761:761:` 그대로입니다. 첫 명령에서 찍은 스냅샷을 트랜잭션 끝까지 쓰기 때문입니다. B가 트랜잭션을 끝내고 새로 조회하자 새 스냅샷(`762:762:`)으로 2349가 보입니다.

### 실습 7. 같은 행을 동시에 고치면: READ COMMITTED

세션 A가 `id = 1`에 10을 더하고 커밋하지 않은 채로, 세션 B가 같은 행에 1을 더하려 합니다.

```sql
-- 세션 A
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 A
UPDATE acct SET balance = balance + 10 WHERE id = 1 RETURNING balance;
```

```text
 balance 
---------
     160
(1 row)

UPDATE 1
```

```sql
-- 세션 B
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 B
UPDATE acct SET balance = balance + 1 WHERE id = 1 RETURNING balance;
```

```text

```

B의 UPDATE가 끝나지 않고 멈췄습니다. 다른 세션에서 상태를 봅니다.

```bash
psql -X <<'SQL'
SELECT pid, state, wait_event_type, wait_event, left(query, 60) AS query
FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() ORDER BY pid;
SELECT locktype, transactionid, mode, granted, pid FROM pg_locks WHERE locktype = 'transactionid' ORDER BY granted DESC, pid;
SQL
```

```text
 pid |        state        | wait_event_type |  wait_event   |                            query                             
-----+---------------------+-----------------+---------------+--------------------------------------------------------------
 100 | idle in transaction | Client          | ClientRead    | UPDATE acct SET balance = balance + 10 WHERE id = 1 RETURNIN
 115 | active              | Lock            | transactionid | UPDATE acct SET balance = balance + 1 WHERE id = 1 RETURNING
(2 rows)

   locktype    | transactionid |     mode      | granted | pid 
---------------+---------------+---------------+---------+-----
 transactionid |           762 | ExclusiveLock | t       | 100
 transactionid |           763 | ExclusiveLock | t       | 115
 transactionid |           762 | ShareLock     | f       | 115
(3 rows)

[exit=0]
```

- B(pid 115)는 `wait_event = transactionid`, 즉 다른 트랜잭션이 끝나기를 기다리고 있습니다.
- `pg_locks`를 보면 A(pid 100)는 자기 xid 762에 대한 `ExclusiveLock`을 갖고 있고, B는 **762에 대한 `ShareLock`을 요청했지만 받지 못한(`granted = f`)** 상태입니다. 모든 트랜잭션이 자기 xid를 잠가 두기 때문에, 그 잠금을 요청하는 것이 곧 "그 트랜잭션이 끝날 때까지 기다리겠다"는 뜻이 됩니다.

```sql
-- 세션 A
COMMIT;
```

```text
COMMIT
```

```sql
-- 세션 B
-- (앞에서 기다리던 명령의 결과)
```

```text
 balance 
---------
     161
(1 row)

UPDATE 1
```

```sql
-- 세션 B
COMMIT;
```

```text
COMMIT
```

A가 커밋하자 B의 UPDATE가 끝났고, 결과는 **161**입니다. B는 A가 만든 새 버전(160)을 다시 읽어 조건을 확인한 뒤 그 위에 1을 더했습니다. 두 변경이 모두 반영되었습니다.

### 실습 8. 같은 행을 동시에 고치면: REPEATABLE READ

같은 상황에서 B를 REPEATABLE READ로 바꿉니다.

```sql
-- 세션 A
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 A
UPDATE acct SET balance = balance + 10 WHERE id = 1 RETURNING balance;
```

```text
 balance 
---------
     171
(1 row)

UPDATE 1
```

```sql
-- 세션 B
BEGIN ISOLATION LEVEL REPEATABLE READ;
```

```text
BEGIN
```

```sql
-- 세션 B
SELECT balance FROM acct WHERE id = 1;
```

```text
 balance 
---------
     161
(1 row)
```

```sql
-- 세션 B
UPDATE acct SET balance = balance + 1 WHERE id = 1 RETURNING balance;
```

```text

```

```sql
-- 세션 A
COMMIT;
```

```text
COMMIT
```

```sql
-- 세션 B
-- (앞에서 기다리던 명령의 결과)
```

```text
ERROR:  could not serialize access due to concurrent update
```

```sql
-- 세션 B
ROLLBACK;
```

```text
ROLLBACK
```

B의 스냅샷에서 `id = 1`은 161입니다. A가 171로 바꾸고 커밋하자, B의 UPDATE는 기다리던 끝에 **`could not serialize access due to concurrent update`** 오류로 끝났습니다. B가 161을 기준으로 1을 더해 162를 쓰면 A의 변경이 사라지기 때문입니다. 이 트랜잭션은 롤백하고 처음부터 다시 해야 합니다.

### 실습 9. SELECT FOR UPDATE도 xmax에 적힌다

```bash
psql -X <<'SQL'
BEGIN;
SELECT pg_current_xact_id() AS locker_xid;
SELECT * FROM acct WHERE id = 3 FOR UPDATE;
SELECT xmin, xmax, * FROM acct WHERE id = 3;
SELECT lp, t_xmax, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_ctid = (SELECT ctid FROM acct WHERE id = 3);
COMMIT;
SQL
```

```text
BEGIN
 locker_xid 
------------
        766
(1 row)

 id | balance 
----+---------
  3 |    1100
(1 row)

 xmin | xmax | id | balance 
------+------+----+---------
  761 |  766 |  3 |    1100
(1 row)

 lp | t_xmax |                                                  raw_flags                                                   
----+--------+--------------------------------------------------------------------------------------------------------------
  3 |    761 | {HEAP_XMIN_COMMITTED,HEAP_XMAX_COMMITTED,HEAP_HOT_UPDATED}
  9 |    766 | {HEAP_XMAX_EXCL_LOCK,HEAP_XMAX_LOCK_ONLY,HEAP_XMIN_COMMITTED,HEAP_UPDATED,HEAP_KEYS_UPDATED,HEAP_ONLY_TUPLE}
(2 rows)

COMMIT
[exit=0]
```

`FOR UPDATE`로 행을 잠그기만 했는데 `xmax`가 766(잠근 트랜잭션)이 되었습니다. PostgreSQL에는 행 잠금을 담는 별도 표가 없고, **잠금도 튜플의 `xmax`에 적습니다.** 여러 트랜잭션이 같은 행을 함께 잠그면(`FOR SHARE` 등) `xmax` 자리에 여러 xid를 묶은 MultiXact ID가 들어갑니다. 대신 `HEAP_XMAX_LOCK_ONLY`로 "지운 것이 아니라 잠그기만 했다"고 표시합니다. 가시성 판단 3단계에서 "잠금만 했으면 보인다"가 이 경우입니다. `HEAP_KEYS_UPDATED`는 여기서 `FOR UPDATE`와 한 단계 약한 `FOR NO KEY UPDATE`를 구분하는 표시로, 가장 강한 잠금인 `FOR UPDATE`일 때 켭니다([`heapam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c#L5603-L5605)). 조회 결과에 나온 lp 3은 실습 6의 UPDATE로 옛 버전이 된 튜플입니다.

### 실습 10. hint bit: 커밋 결과를 처음 확인한 쪽이 적어 둔다

```bash
psql -X <<'SQL'
INSERT INTO acct VALUES (6, 100);
SELECT lp, t_xmin, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_data = (SELECT t_data FROM heap_page_items(get_raw_page('acct', 0)) ORDER BY lp DESC LIMIT 1);
SELECT * FROM acct WHERE id = 6;
SELECT lp, t_xmin, raw_flags
FROM heap_page_items(get_raw_page('acct', 0)),
     LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2)
WHERE t_data = (SELECT t_data FROM heap_page_items(get_raw_page('acct', 0)) ORDER BY lp DESC LIMIT 1);
SQL
```

```text
INSERT 0 1
 lp | t_xmin |      raw_flags      
----+--------+---------------------
 13 |    767 | {HEAP_XMAX_INVALID}
(1 row)

 id | balance 
----+---------
  6 |     100
(1 row)

 lp | t_xmin |                raw_flags                
----+--------+-----------------------------------------
 13 |    767 | {HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID}
(1 row)

[exit=0]
```

INSERT 직후의 새 튜플에는 `HEAP_XMAX_INVALID`만 있습니다. SELECT로 한 번 읽자 `HEAP_XMIN_COMMITTED`가 생겼습니다. 이 SELECT가 pg_xact에서 767의 커밋을 확인하고 적어 둔 hint bit입니다. 다음에 이 튜플을 읽는 쪽은 pg_xact를 찾아보지 않아도 됩니다.

## 운영에서는 이렇게 나타납니다

### 긴 트랜잭션이 dead tuple 정리를 막는다

dead tuple은 **아무도 볼 가능성이 없어진 뒤에야** VACUUM이 지울 수 있습니다. 실습 6처럼 REPEATABLE READ 트랜잭션 하나가 오래 열려 있으면, 그 스냅샷이 볼 수도 있는 옛 버전들은 모두 남아야 합니다. READ COMMITTED라도 트랜잭션 안에서 쓰기를 한 번 하고 커밋하지 않은 채 멈춘 세션(`idle in transaction`)이 있으면 같은 문제가 생깁니다. 그 세션의 xid가 끝나지 않았으니, 그 뒤에 생긴 dead tuple은 "아직 누군가 볼 수 있는" 것으로 남습니다. 오래된 트랜잭션은 다음처럼 찾습니다.

```sql
SELECT pid, state, xact_start, backend_xid, backend_xmin, age(backend_xmin) AS xmin_age, left(query, 40)
FROM pg_stat_activity
WHERE (backend_xmin IS NOT NULL OR backend_xid IS NOT NULL) AND pid <> pg_backend_pid()
ORDER BY xact_start;
```

`idle_in_transaction_session_timeout`으로 이런 세션을 자동으로 끊을 수 있습니다. VACUUM이 무엇을 기준으로 지울 수 있는지 판단하는지는 [5편](/posts/postgresql/05-vacuum/)에서 자세히 봅니다.

### UPDATE가 많은 테이블은 커진다

실습 2처럼 UPDATE는 행을 하나 더 만듭니다. 같은 행을 자주 바꾸는 테이블(재고, 카운터, 세션 상태 등)은 dead tuple이 빠르게 쌓이고, VACUUM이 따라가지 못하면 테이블과 인덱스가 커집니다(bloat). 이것이 PostgreSQL MVCC의 대가이고, VACUUM이 반드시 필요한 이유입니다.

### 락 대기는 트랜잭션 ID 대기로 보인다

실습 7처럼 행 잠금을 기다리는 세션은 `pg_stat_activity`에서 `wait_event_type = Lock`, `wait_event = transactionid`로 보입니다. 누가 막고 있는지는 `pg_blocking_pids()`로 바로 찾을 수 있습니다.

```sql
SELECT pid, pg_blocking_pids(pid) AS blocked_by, wait_event, left(query, 40)
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

막고 있는 쪽이 `idle in transaction`이라면, 애플리케이션이 트랜잭션을 열어 둔 채 다른 일(외부 API 호출 등)을 하고 있을 가능성이 큽니다.

### REPEATABLE READ를 쓴다면 재시도가 필수

REPEATABLE READ와 SERIALIZABLE에서는 실습 8의 직렬화 오류(SQLSTATE `40001`)가 정상 동작의 일부입니다. 이 격리 수준을 쓰는 애플리케이션은 `40001`을 받으면 **트랜잭션 전체를 처음부터 다시 실행**하도록 만들어야 합니다. 오류가 난 문장만 다시 실행하는 것으로는 안 됩니다.

## 정리

- PostgreSQL은 행을 제자리에서 고치지 않습니다. INSERT는 `xmin`을, DELETE는 `xmax`를 적고, UPDATE는 옛 버전에 `xmax`를 적고 새 버전을 만듭니다. ROLLBACK은 페이지를 되돌리지 않고 pg_xact에 "롤백됨"을 적습니다.
- **스냅샷**(`xmin:xmax:xip`)은 "어떤 트랜잭션이 끝났는가"를 찍어 둔 것이고, 스냅샷 기준으로 진행 중인 트랜잭션의 변경은 보이지 않습니다.
- 튜플이 보이는지는 xmin(태어났는가)과 xmax(아직 살아 있는가)를 스냅샷과 pg_xact로 판단하고, 결과를 hint bit로 적어 둡니다.
- READ COMMITTED는 명령마다, REPEATABLE READ는 트랜잭션에 한 번 스냅샷을 찍습니다.
- 같은 행을 동시에 고치면 뒤의 트랜잭션이 앞 트랜잭션의 xid 잠금을 기다리고, READ COMMITTED는 새 버전 위에서 다시 시도하며, REPEATABLE READ는 직렬화 오류를 냅니다.
- 행 잠금(`FOR UPDATE`)도 `xmax`에 적힙니다.

다음 글에서는 이렇게 쌓인 dead tuple을 정리하는 **VACUUM과 autovacuum**, 그리고 그 과정에서 쓰이는 FSM과 Visibility Map을 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/access/heap/heapam_visibility.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_visibility.c): 가시성 판단, hint bit
- [src/include/utils/snapshot.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/utils/snapshot.h): `SnapshotData`
- [src/backend/utils/time/snapmgr.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/time/snapmgr.c): 트랜잭션 스냅샷, `XidInMVCCSnapshot`
- [src/backend/storage/ipc/procarray.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/procarray.c): `GetSnapshotData`
- [src/backend/access/transam/clog.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/clog.c): pg_xact
- [src/backend/executor/nodeModifyTable.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/nodeModifyTable.c): 동시 UPDATE 처리

PostgreSQL 18 공식 문서

- [Concurrency Control](https://www.postgresql.org/docs/18/mvcc.html)
- [Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html)
- [Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html)
- [System Columns](https://www.postgresql.org/docs/18/ddl-system-columns.html)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-04-mvcc/lab.sh), [final-run.log](/labs/pg-04-mvcc/final-run.log)
