---
title: "PostgreSQL 인터널 6: 트랜잭션 ID wraparound"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "wraparound", "freeze", "VACUUM"]
weight: 6
summary: "32비트 트랜잭션 ID가 한 바퀴 돌면 무슨 일이 생기고, PostgreSQL은 어떻게 막는가"
description: "왜 생기고 어떻게 막는가"
---

## 개요

[4편](/posts/postgresql/04-mvcc/)에서 PostgreSQL이 행마다 "만든 트랜잭션 ID(xmin)"를 적어 두고, 그 번호를 비교해 행이 보이는지 판단한다는 것을 봤습니다. 그런데 이 번호는 **32비트**입니다. 약 42억 개를 쓰고 나면 다시 처음으로 돌아옵니다. 초당 1만 건의 쓰기 트랜잭션이 도는 시스템이라면 약 2.5일이면 21억 개, 즉 비교에 쓸 수 있는 범위의 절반을 씁니다.

번호가 한 바퀴 돌면, 아주 오래전에 커밋된 행이 갑자기 "미래의 트랜잭션이 만든 행"으로 보여 사라질 수 있습니다. 이것이 **트랜잭션 ID wraparound**입니다. PostgreSQL은 이를 막으려고 오래된 행을 **freeze**(동결)하고, 그래도 위험하면 단계적으로 경고를 내다가 마지막에는 **새 트랜잭션을 거부**합니다. 이 글에서는 그 전 과정을 실제로 재현합니다.

이 글에서 답할 질문은 다음과 같습니다.

- 32비트 번호로 어떻게 "앞, 뒤"를 비교하는가
- freeze는 튜플에 무엇을 하는가
- `age()`는 무엇을 재고, 어떤 값에서 무슨 일이 일어나는가
- 쓰기가 멈추면 어떻게 복구하는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 원형으로 비교하는 트랜잭션 ID

xid는 32비트 부호 없는 정수입니다. 0, 1, 2는 특별한 값이고([`transam.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/transam.h#L31-L34)), 보통 트랜잭션은 3부터 번호를 받습니다.

| 값 | 이름 | 뜻 |
|---|---|---|
| 0 | `InvalidTransactionId` | 없음 |
| 1 | `BootstrapTransactionId` | initdb가 쓰는 번호 |
| 2 | `FrozenTransactionId` | "어떤 트랜잭션보다도 먼저" (예전 방식의 freeze) |
| 3 이상 | 일반 xid | 1씩 증가하다 2³²에서 다시 3으로 |

두 xid 중 어느 쪽이 먼저인지는 단순한 크기 비교가 아니라 **차이를 부호 있는 32비트로 보고** 판단합니다([`TransactionIdPrecedes()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/transam.c#L280-L293)).

```c
diff = (int32) (id1 - id2);
return (diff < 0);
```

xid를 시계 문자판처럼 원 위에 놓고, 어느 xid에서 보든 **앞쪽 약 21억 개는 과거, 뒤쪽 약 21억 개는 미래**로 보는 것입니다. 번호가 한 바퀴 돌아도 비교는 계속됩니다. 문제는 **21억 개보다 더 오래된 xid**입니다. 그런 xid는 원의 반대편, 즉 "미래"로 보입니다. 행의 `xmin`이 미래면 그 행은 아직 만들어지지 않은 것으로 판단되어 보이지 않습니다. 데이터가 사라진 것처럼 보이는 것입니다.

### freeze: "이 행은 누구보다도 먼저 만들어졌다"

해결책은 충분히 오래된 행에 "**이 행은 모든 트랜잭션보다 먼저 만들어졌다**"고 표시해서 xmin 비교를 아예 하지 않게 하는 것입니다. 이것이 **freeze**입니다. 9.4 이전에는 xmin 자체를 `FrozenTransactionId`(2)로 바꿨지만, 9.4부터는 xmin 값은 그대로 두고 `t_infomask`에 [`HEAP_XMIN_FROZEN`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/htup_details.h#L206)(`HEAP_XMIN_COMMITTED`와 `HEAP_XMIN_INVALID`를 함께 켠 조합)을 적습니다(실습 2). 원래 xmin이 남아 있으면 장애 분석에 도움이 되기 때문입니다.

freeze는 VACUUM이 합니다([`heap_prepare_freeze_tuple()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c#L7318)). VACUUM이 all-frozen이 아닌 페이지를 빠짐없이 스캔했을 때, 테이블에 남은 가장 오래된 얼리지 않은 xid를 `pg_class.relfrozenxid`에 적습니다. "이보다 오래된 xid는 이 테이블에 더는 없다"는 경계입니다. 데이터베이스 단위로는 모든 테이블의 relfrozenxid 가운데 가장 오래된 값이 `pg_database.datfrozenxid`입니다.

`age(xid)`는 현재 xid에서 그 xid까지의 거리입니다. `age(relfrozenxid)`는 "이 테이블에서 아직 얼려지지 않았을 수 있는 가장 오래된 xid가 몇 트랜잭션 전인가"이고, 이 값이 21억에 가까워질수록 위험합니다.

### age에 따라 차례로 작동하는 방어선

{{< diagram src="/diagrams/pg-xid-age.html" title="테이블의 xid age가 커질 때 차례로 작동하는 방어선" height="560" caption="age가 커질수록 VACUUM이 더 적극적으로 얼리고, 끝내 막히면 경고를 내다가 새 xid 발급을 거부합니다." >}}

| 기준 | 기본값 | 일어나는 일 |
|---|---|---|
| `vacuum_freeze_min_age` | 5000만 | VACUUM이 스캔한 페이지에서 이보다 오래된 xid를 얼림(일반 VACUUM은 all-visible 페이지를 건너뛸 수 있음) |
| `vacuum_freeze_table_age` | 1.5억 | 이보다 오래되면 **aggressive VACUUM**: VM에서 all-visible이어도 all-frozen이 아닌 페이지는 모두 읽음([`vacuum.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/vacuum.c#L1242-L1249)) |
| `autovacuum_freeze_max_age` | 2억 | 이보다 오래되면 **테이블 단위로 autovacuum을 꺼 둔 테이블도**([`autovacuum.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/autovacuum.c#L3061-L3076)), **서버 전체에서 `autovacuum = off`여도**([`varsup.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/varsup.c#L144-L145)에서 launcher를 깨움) 강제로 VACUUM |
| `vacuum_failsafe_age` | 16억 | VACUUM이 인덱스 정리, 테이블 끝 잘라 내기, 비용 지연(cost delay), ring buffer 같은 "당장 필요 없는 일"을 건너뛰고 freeze만 서두름([`lazy_check_wraparound_failsafe()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L2964)) |
| 한계 − 4000만 | (고정) | 새 xid를 줄 때마다 **WARNING** |
| 한계 − 300만 | (고정) | **새 xid 발급 거부**. 쓰기 불가, 읽기만 가능 |

여기서 "한계"는 가장 오래된 `datfrozenxid` + 2³¹ − 1(`MaxTransactionId >> 1`, 약 21억)이고, 경고와 정지 지점도 여기서 계산합니다([`SetTransactionIdLimit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/varsup.c#L389-L419)). 새 xid를 줄 때마다 이 값과 비교해 경고하거나 거부하는 곳이 [`GetNewTransactionId()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/varsup.c#L123-L186)입니다. VACUUM 자체는 새 xid가 필요 없어서 정지 상태에서도 돕니다. 마지막 300만 개는 관리자가 단일 사용자 모드에서 필요 없는 테이블을 TRUNCATE하거나 DROP해서 VACUUM할 양을 줄일 수 있게 남겨 둔 여유입니다([문서](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)).

### freeze가 막히는 경우

VACUUM은 [5편](/posts/postgresql/05-vacuum/)에서 본 `removable cutoff`보다 오래된 행만 얼릴 수 있습니다. 누군가 오래된 스냅샷이나 xid를 들고 있으면, 그보다 뒤의 행은 "아직 누군가에게는 진행 중일 수 있는 트랜잭션이 만든 행"이라 얼릴 수 없습니다. 그래서 wraparound는 대부분 **VACUUM이 게을러서가 아니라, VACUUM이 일을 할 수 없게 막혀서** 일어납니다. 흔한 원인은 5편에서 본 것과 같습니다. 오래 열린 트랜잭션, 버려진 replication slot, 끝내지 않은 prepared transaction입니다.

## 직접 확인해 보기

### 실습 환경

[실습 이미지](/labs/pg-lab-image/Dockerfile)로 [lab.sh](/labs/pg-06-wraparound/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-06-wraparound/final-run.log)에 있습니다.

실제 서비스에서 xid 21억 개를 쓰려면 며칠에서 몇 달이 걸립니다. 실습에서는 PostgreSQL 소스에 포함된 테스트 모듈 [`xid_wraparound`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/test/modules/xid_wraparound/xid_wraparound.c#L80-L95)의 `consume_xids()`로 xid를 몇 초 만에 소모합니다. 이 함수는 최상위 xid를 받은 트랜잭션 안에서 xid를 하위 트랜잭션용으로 소모하므로, 소모하는 동안에는 그 트랜잭션 자체가 오래 열린 트랜잭션처럼 동작합니다. autovacuum이 빨리 반응하도록 `autovacuum_naptime`은 1초로 줄였습니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
c9db99ab70d5eff859e76c1b525214b0a262b5129f7767c902f0d4487797d15c
[exit=0]
```

```bash
cat >> $PGDATA/postgresql.conf <<'CONF'
autovacuum_naptime = 1s
log_autovacuum_min_duration = 0
log_line_prefix = '%m [%p] %b '
CONF
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION xid_wraparound" -c "CREATE EXTENSION pageinspect"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. 트랜잭션 ID와 age

```bash
psql -X <<'SQL'
SELECT pg_current_xact_id() AS next_xid;
SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database ORDER BY datname;
SQL
pg_controldata $PGDATA | grep -E "NextXID|oldestXID"
```

```text
 next_xid 
----------
      754
(1 row)

  datname  | datfrozenxid | age 
-----------+--------------+-----
 postgres  |          744 |  11
 template0 |          744 |  11
 template1 |          744 |  11
(3 rows)

Latest checkpoint's NextXID:          0:752
Latest checkpoint's oldestXID:        744
Latest checkpoint's oldestXID's DB:   1
[exit=0]
```

막 만든 클러스터라 다음 xid는 754이고, 모든 DB의 `datfrozenxid`가 744, age는 11입니다. `pg_controldata`의 `oldestXID`도 744입니다. 서버가 기억하는 "가장 오래된 얼리지 않은 xid"입니다.

### 실습 2. freeze: 튜플에 "아주 오래전에 커밋됨" 표시하기

```bash
psql -X <<'SQL'
CREATE TABLE f (id int) WITH (autovacuum_enabled = off);
INSERT INTO f SELECT generate_series(1, 3);
SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'f';
SELECT lp, t_xmin, raw_flags, combined_flags
FROM heap_page_items(get_raw_page('f', 0)), LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
VACUUM (FREEZE) f;
SELECT lp, t_xmin, raw_flags, combined_flags
FROM heap_page_items(get_raw_page('f', 0)), LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'f';
SELECT xmin, * FROM f;
SQL
```

```text
CREATE TABLE
INSERT 0 3
 relfrozenxid | age 
--------------+-----
          755 |   2
(1 row)

 lp | t_xmin |      raw_flags      | combined_flags 
----+--------+---------------------+----------------
  1 |    756 | {HEAP_XMAX_INVALID} | {}
  2 |    756 | {HEAP_XMAX_INVALID} | {}
  3 |    756 | {HEAP_XMAX_INVALID} | {}
(3 rows)

VACUUM
 lp | t_xmin |                         raw_flags                         |   combined_flags   
----+--------+-----------------------------------------------------------+--------------------
  1 |    756 | {HEAP_XMIN_COMMITTED,HEAP_XMIN_INVALID,HEAP_XMAX_INVALID} | {HEAP_XMIN_FROZEN}
  2 |    756 | {HEAP_XMIN_COMMITTED,HEAP_XMIN_INVALID,HEAP_XMAX_INVALID} | {HEAP_XMIN_FROZEN}
  3 |    756 | {HEAP_XMIN_COMMITTED,HEAP_XMIN_INVALID,HEAP_XMAX_INVALID} | {HEAP_XMIN_FROZEN}
(3 rows)

 relfrozenxid | age 
--------------+-----
          757 |   0
(1 row)

 xmin | id 
------+----
  756 |  1
  756 |  2
  756 |  3
(3 rows)

[exit=0]
```

- freeze 전: 세 행 모두 `t_xmin = 756`이고 `HEAP_XMAX_INVALID`만 있습니다.
- `VACUUM (FREEZE)` 뒤: `t_xmin`은 **756 그대로**인데, `HEAP_XMIN_COMMITTED`와 `HEAP_XMIN_INVALID`가 함께 켜져 `combined_flags`가 `HEAP_XMIN_FROZEN`이 되었습니다. 원래는 동시에 켜질 수 없는 두 비트(커밋됨, 무효)의 조합을 "얼려짐"이라는 뜻으로 씁니다.
- `relfrozenxid`가 757로 올라가 age가 0이 되었습니다. SQL로 본 `xmin`은 여전히 756입니다.

### 실습 3. xid를 쓰면 age가 늘어난다

```bash
psql -X -q -c "CREATE TABLE noav (id int) WITH (autovacuum_enabled = off)" -c "INSERT INTO noav VALUES (1)"
psql -X -c "SELECT consume_xids(150000000)"
psql -X -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname IN ('f', 'noav') ORDER BY 1"
```

```text
NOTICE:  consumed 10000050 / 150000000 XIDs, latest 0:10000809
NOTICE:  consumed 20000859 / 150000000 XIDs, latest 0:20001618
NOTICE:  consumed 30001668 / 150000000 XIDs, latest 0:30002427
NOTICE:  consumed 40002477 / 150000000 XIDs, latest 0:40003236
NOTICE:  consumed 50003209 / 150000000 XIDs, latest 0:50003968
NOTICE:  consumed 60003276 / 150000000 XIDs, latest 0:60004035
NOTICE:  consumed 70003977 / 150000000 XIDs, latest 0:70004736
NOTICE:  consumed 80004075 / 150000000 XIDs, latest 0:80004834
NOTICE:  consumed 90004745 / 150000000 XIDs, latest 0:90005504
NOTICE:  consumed 100004874 / 150000000 XIDs, latest 0:100005633
NOTICE:  consumed 110005513 / 150000000 XIDs, latest 0:110006272
NOTICE:  consumed 120005673 / 150000000 XIDs, latest 0:120006432
NOTICE:  consumed 130006281 / 150000000 XIDs, latest 0:130007040
NOTICE:  consumed 140006472 / 150000000 XIDs, latest 0:140007231
 consume_xids 
--------------
    150000759
(1 row)

 relname |    age    
---------+-----------
 f       | 150000003
 noav    | 150000003
(2 rows)

[exit=0]
```

xid 1.5억 개를 쓰자 두 테이블의 age가 1.5억이 되었습니다. 테이블 안의 행은 하나도 바뀌지 않았는데 age만 올라갔습니다. **age는 테이블이 얼마나 바뀌었는지가 아니라, 마지막 freeze 이후 클러스터 전체가 xid를 얼마나 썼는지**를 잽니다.

### 실습 4. autovacuum을 꺼도 wraparound 방지 VACUUM은 돈다

두 테이블 모두 테이블 단위로 `autovacuum_enabled = off`를 주고 만들었습니다. 6000만 개를 더 써서 age가 2억(`autovacuum_freeze_max_age`)을 넘게 해 봅니다.

```bash
psql -X -c "SELECT consume_xids(60000000)"
sleep 8
psql -X -c "SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname IN ('f', 'noav') ORDER BY 1"
grep -E 'to prevent wraparound of table "postgres.public.(f|noav)"' /home/postgres/server.log | cut -c1-160
```

```text
NOTICE:  consumed 10000718 / 60000000 XIDs, latest 0:160001478
NOTICE:  consumed 20001527 / 60000000 XIDs, latest 0:170002287
NOTICE:  consumed 30002056 / 60000000 XIDs, latest 0:180002816
NOTICE:  consumed 40002326 / 60000000 XIDs, latest 0:190003086
NOTICE:  consumed 50002824 / 60000000 XIDs, latest 0:200003584
 consume_xids 
--------------
    210000760
(1 row)

 relname |   age    
---------+----------
 f       | 60000011
 noav    | 60000011
(2 rows)

2026-09-24 03:37:36.768 UTC [89] autovacuum worker LOG:  automatic aggressive vacuum to prevent wraparound of table "postgres.public.f": index scans: 0
2026-09-24 03:37:36.770 UTC [89] autovacuum worker LOG:  automatic aggressive vacuum to prevent wraparound of table "postgres.public.noav": index scans: 0
[exit=0]
```

로그에 `automatic aggressive vacuum to prevent wraparound of table`이 찍혔습니다. **autovacuum을 끈 테이블인데도 VACUUM이 돌았습니다.** age가 2억을 넘으면 `autovacuum_enabled` 설정과 상관없이 강제로 돕니다. 그 뒤 age는 6000만으로 줄었습니다. 0이 아닌 이유는 이 VACUUM이 도는 동안 xid를 소모하던 트랜잭션이 열려 있어서 그보다 뒤로는 얼릴 수 없었기 때문입니다. 다음 xid 210000771에서 60000011을 빼면 150000760으로, 실습 4에서 소모를 시작한 트랜잭션의 xid와 같습니다.

### 실습 5. 오래된 트랜잭션이 freeze를 막으면

세션 A가 트랜잭션을 열고 xid를 받은 채 **아무것도 하지 않습니다.** 그리고 `vacuumdb --all`로 얼릴 수 있는 만큼 모두 얼려 둔 뒤, 한계값을 계산합니다.

```sql
-- 세션 A
BEGIN;
```

```text
BEGIN
```

```sql
-- 세션 A
SELECT pg_current_xact_id() AS old_xid;
```

```text
  old_xid  
-----------
 210000772
(1 row)
```

```bash
vacuumdb --all --quiet
sleep 3
psql -X <<'SQL'
SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database ORDER BY datname;
SELECT min(datfrozenxid::text::bigint) AS oldest_datfrozenxid,
       min(datfrozenxid::text::bigint) + 2147483647 AS wrap_limit,
       min(datfrozenxid::text::bigint) + 2147483647 - 40000000 AS warn_limit,
       min(datfrozenxid::text::bigint) + 2147483647 - 3000000 AS stop_limit
FROM pg_database;
SQL
```

```text
  datname  | datfrozenxid | age 
-----------+--------------+-----
 postgres  |    210000772 |   1
 template0 |    210000772 |   1
 template1 |    210000772 |   1
(3 rows)

 oldest_datfrozenxid | wrap_limit | warn_limit | stop_limit 
---------------------+------------+------------+------------
           210000772 | 2357484419 | 2317484419 | 2354484419
(1 row)

[exit=0]
```

모든 DB의 `datfrozenxid`가 **세션 A의 xid(210000772)에서 멈췄습니다.** VACUUM을 해도 A보다 뒤로는 얼릴 수 없기 때문입니다. 이 값에서 계산한 한계는 다음과 같습니다.

| 지점 | xid |
|---|---|
| wraparound 한계 (210000772 + 2³¹ − 1) | 2357484419 |
| 경고 시작 (한계 − 4000만) | 2317484419 |
| 쓰기 정지 (한계 − 300만) | 2354484419 |

### 실습 6. 경고 단계: 한계까지 4000만 개 남았을 때

경고 지점을 1000개 넘을 때까지 xid를 쓴 뒤, 평범한 INSERT를 합니다.

```bash
W=$(psql -X -At -c "SELECT min(datfrozenxid::text::bigint) + 2147483647 - 40000000 + 1000 FROM pg_database")
psql -X -q -c "SELECT consume_xids_until('$W'::xid8)" > /dev/null 2>&1
psql -X -c "INSERT INTO noav VALUES (2)"
```

```text
WARNING:  database "postgres" must be vacuumed within 39998999 transactions
HINT:  To avoid transaction ID assignment failures, execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
INSERT 0 1
[exit=0]
```

INSERT는 성공했지만 **WARNING**이 붙었습니다. "postgres DB를 39998999 트랜잭션 안에 VACUUM하라"는 뜻입니다. 경고 지점(4000만 전)을 약 1000개 지난 뒤라 남은 수가 4000만보다 조금 적습니다. HINT는 DB 전체 VACUUM과 함께 오래된 prepared transaction과 버려진 replication slot을 확인하라고 알려 줍니다. 이 단계부터 **새 xid를 받는 모든 트랜잭션**에 이 경고가 붙습니다.

### 실습 7. 정지 단계: 한계까지 300만 개 남았을 때

```bash
S=$(psql -X -At -c "SELECT min(datfrozenxid::text::bigint) + 2147483647 - 3000000 + 1000 FROM pg_database")
psql -X -q -c "SELECT consume_xids_until('$S'::xid8)" 2>&1 | tail -3
psql -X -c "INSERT INTO noav VALUES (3)"
psql -X -c "SELECT count(*) FROM noav"
```

```text
ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "postgres"
HINT:  Execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "postgres"
HINT:  Execute a database-wide VACUUM in that database.
You might also need to commit or roll back old prepared transactions, or drop stale replication slots.
 count 
-------
     2
(1 row)

[exit=0]
```

정지 지점에 이르자 xid 소모가 멈췄고, 이어서 INSERT도 **ERROR**로 거부되었습니다. `database is not accepting commands that assign new transaction IDs`. 새 xid가 필요한 명령, 즉 쓰기는 모두 거부됩니다. 반면 `SELECT count(*)`는 xid가 필요 없어서 정상적으로 동작합니다. **서비스로 보면 읽기 전용 장애**입니다.

### 실습 8. 원인을 없애고 VACUUM으로 복구

세션 A를 끝내면 freeze를 막던 것이 사라집니다.

```sql
-- 세션 A
ROLLBACK;
```

```text
ROLLBACK
```

```bash
sleep 15
psql -X -c "SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY datname"
psql -X -c "INSERT INTO noav VALUES (4)"
grep -cE 'to prevent wraparound' /home/postgres/server.log
grep -E 'bypassing nonessential maintenance' /home/postgres/server.log | head -2 | cut -c1-200
```

```text
  datname  |   age    
-----------+----------
 postgres  | 36998999
 template0 | 36998997
 template1 | 36998997
(3 rows)

INSERT 0 1
2499
2026-09-24 03:37:55.403 UTC [227] autovacuum worker WARNING:  bypassing nonessential maintenance of table "postgres.pg_catalog.pg_partitioned_table" as a failsafe after 0 index scans
2026-09-24 03:37:55.403 UTC [227] autovacuum worker WARNING:  bypassing nonessential maintenance of table "postgres.pg_catalog.pg_range" as a failsafe after 0 index scans
[exit=0]
```

A를 롤백하고 15초 뒤, autovacuum이 모든 DB를 얼려 age가 2억 아래(약 3700만)로 내려왔고, INSERT가 다시 성공했습니다. 0이 아니라 3700만인 이유는 postgres DB에서는 실습 6에서 넣은 행(xid 약 23.17억)이 `vacuum_freeze_min_age`(5000만)보다 젊어서 얼리지 않았고, 그 xid가 relfrozenxid로 남았기 때문입니다. 로그의 2499줄은 서버를 시작한 뒤 쌓인 wraparound 방지 VACUUM 기록 전체입니다. A가 freeze를 막는 동안 autovacuum이 1초마다 같은 테이블들을 계속 시도했기 때문에 이렇게 많습니다. `bypassing nonessential maintenance ... as a failsafe`는 age가 16억(`vacuum_failsafe_age`)을 넘은 뒤부터 VACUUM이 failsafe로 전환해 필수가 아닌 일을 건너뛰었다는 기록입니다(로그에서 가장 이른 두 줄).

예전 버전에서는 이 상태에서 서버를 내리고 단일 사용자 모드로 VACUUM해야 했지만, 지금은 그럴 필요가 없고 오히려 피해야 한다고 [문서](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)가 안내합니다. 정지 상태에서도 VACUUM은 새 xid 없이 돌 수 있으므로, 원인을 없앤 뒤 **평소 모드에서 VACUUM을 돌리면** 됩니다. ERROR의 HINT에도 "Execute a database-wide VACUUM"이라고 나옵니다.

아래 그림은 실습 5-8을 순서대로 정리한 것입니다.

{{< diagram src="/diagrams/pg-wraparound-lab.html" title="오래된 트랜잭션 하나가 wraparound 정지까지 가는 과정" height="560" caption="세션 A가 붙잡은 xid에서 datfrozenxid가 멈추고, xid가 한계에 다가가 경고와 정지가 일어난 뒤, A를 끝내자 VACUUM이 복구합니다." >}}

## 운영에서는 이렇게 나타납니다

### age를 모니터링한다

wraparound는 갑자기 오지 않습니다. 몇 주, 몇 달에 걸쳐 age가 올라가는 것이 보입니다. 다음 두 쿼리를 모니터링에 넣어 두면 됩니다.

```sql
-- DB별
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;

-- 테이블별 (age가 큰 순)
SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY 2 DESC LIMIT 10;
```

age가 `autovacuum_freeze_max_age`(2억)를 넘는 것 자체는 정상입니다. 강제 VACUUM이 곧 처리합니다. **2억을 한참 넘었는데 줄지 않는다면** 무언가가 freeze를 막고 있다는 신호입니다. 알람은 보통 5억, 10억 같은 단계로 겁니다.

### "to prevent wraparound" VACUUM을 취소하지 말 것

`pg_stat_activity`에서 `autovacuum: VACUUM public.orders (to prevent wraparound)` 같은 세션을 보면, 부하가 걸린다고 취소하고 싶어집니다. 하지만 이 VACUUM은 취소해도 곧 다시 시작되고, 그사이 age는 계속 오릅니다. 게다가 일반 autovacuum과 달리 이 VACUUM은 다른 세션과 락이 충돌해도 자동으로 취소되지 않으므로([`proc.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/lmgr/proc.c#L1530-L1536)), DDL이 이 VACUUM 뒤에서 기다리는 일이 생깁니다. 이 VACUUM이 오래 걸리지 않게 하려면 평소 VACUUM이 제때 돌아 freeze할 양을 미리 줄여 두는 것이 가장 좋습니다. [5편](/posts/postgresql/05-vacuum/)에서 본 PG18의 eager scanning도 이 부담을 나누려는 기능입니다.

### 경고가 뜨면

WARNING이 보이면 이미 한계까지 4000만 개 남은 상태입니다. 초당 1000 트랜잭션이면 약 10시간 뒤에 쓰기가 멈춥니다(정지 지점까지 3700만 개). 순서대로 확인합니다.

1. 오래된 트랜잭션: `pg_stat_activity`에서 `backend_xid`, `backend_xmin`의 age가 큰 세션을 찾아 끝냅니다.
2. prepared transaction: `pg_prepared_xacts`에 오래된 것이 있으면 `COMMIT PREPARED` 또는 `ROLLBACK PREPARED`합니다.
3. replication slot: `pg_replication_slots`에서 `xmin`, `catalog_xmin`이 오래된 비활성 슬롯을 지웁니다([9편](/posts/postgresql/09-streaming-replication/)).
4. 그다음 superuser로 `VACUUM (VERBOSE)`를 돌립니다. 가장 age가 큰 테이블부터 해도 됩니다. 이때 `FREEZE`나 `FULL` 옵션은 필요한 것보다 많은 일을 하므로 쓰지 않습니다([문서](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)).

원인을 없애지 않고 VACUUM만 돌리면, 실습 5-7처럼 VACUUM이 끝나도 datfrozenxid가 움직이지 않습니다.

### MultiXact에도 같은 한계가 있다

[4편](/posts/postgresql/04-mvcc/)에서 본 MultiXact ID(여러 트랜잭션이 같은 행을 함께 잠글 때 쓰는 ID)도 32비트이고, 같은 구조의 wraparound 방어(`autovacuum_multixact_freeze_max_age`, `mxid_age()`)가 있습니다. `SELECT ... FOR SHARE`나 외래 키 검사를 많이 쓰는 시스템이라면 `mxid_age(datminmxid)`도 함께 모니터링해야 합니다.

## 정리

- xid는 32비트이고 원형으로 비교하므로, 어느 xid에서 보든 약 21억 개 앞까지만 "과거"로 판단할 수 있습니다. 그보다 오래된 xmin은 미래로 보여 행이 사라진 것처럼 됩니다.
- **freeze**는 충분히 오래된 행에 `HEAP_XMIN_FROZEN`을 적어 xmin 비교에서 빼는 것입니다. xmin 값은 남습니다.
- `relfrozenxid`와 `datfrozenxid`는 "이보다 오래된 행은 모두 얼려졌다"는 경계이고, `age()`로 그 거리를 봅니다.
- age에 따라 aggressive VACUUM(1.5억), 강제 autovacuum(2억, autovacuum을 꺼도 실행), failsafe(16억), 경고(한계 − 4000만), 쓰기 정지(한계 − 300만)가 차례로 작동합니다.
- wraparound는 보통 오래된 트랜잭션, prepared transaction, replication slot이 freeze를 막아서 생깁니다. 원인을 없앤 뒤 VACUUM하면 평소 모드에서 복구됩니다.

다음 글에서는 지금까지 여러 번 등장한 **WAL**을 본격적으로 살펴봅니다. LSN과 WAL 레코드의 구조, full page writes입니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/access/transam/transam.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/transam.c): xid 비교
- [src/backend/access/transam/varsup.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/varsup.c): xid 발급, 경고와 정지 한계
- [src/backend/commands/vacuum.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/vacuum.c): freeze 기준, aggressive 판단
- [src/backend/access/heap/heapam.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c): 튜플 freeze
- [src/test/modules/xid_wraparound](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/test/modules/xid_wraparound/xid_wraparound.c): 실습에 쓴 xid 소모 모듈

PostgreSQL 18 공식 문서

- [Preventing Transaction ID Wraparound Failures](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)
- [Transactions and Identifiers](https://www.postgresql.org/docs/18/transaction-id.html)
- [Vacuuming 설정](https://www.postgresql.org/docs/18/runtime-config-vacuum.html)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-06-wraparound/lab.sh), [final-run.log](/labs/pg-06-wraparound/final-run.log)
