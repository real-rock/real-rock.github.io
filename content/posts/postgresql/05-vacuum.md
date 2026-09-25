---
title: "PostgreSQL 인터널 5: VACUUM과 Autovacuum"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "VACUUM", "autovacuum", "MVCC"]
weight: 5
summary: "dead tuple은 누가 언제 어떻게 정리하는가"
description: "dead tuple, FSM, Visibility Map"
---

## 개요

[4편](/posts/postgresql/04-mvcc/)에서 PostgreSQL이 행을 제자리에서 고치지 않고 새 버전을 만든다는 것을 봤습니다. 그러면 옛 버전(dead tuple)은 언제 사라질까요? 자동으로 사라지지 않습니다. 누군가 치워야 하고, 그 일을 하는 것이 **VACUUM**입니다.

이 글에서 답할 질문은 다음과 같습니다.

- VACUUM은 정확히 무엇을 지우고, 몇 단계로 일하는가
- VACUUM을 해도 테이블 파일이 줄어들지 않는 이유는 무엇인가
- Free Space Map과 Visibility Map은 무엇에 쓰이는가
- dead tuple이 쌓였는데도 VACUUM이 지우지 못하는 경우는 언제인가
- autovacuum은 언제 도는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 빌드해 실행한 결과입니다.

## VACUUM이 하는 일

VACUUM(정확히는 `VACUUM FULL`이 아닌 일반 VACUUM)은 읽기와 쓰기를 막지 않고 다른 쿼리와 동시에 돌면서 다음 일을 합니다. 다만 `SHARE UPDATE EXCLUSIVE` 락을 잡으므로, 같은 테이블의 DDL이나 다른 VACUUM과는 동시에 돌지 않습니다.

1. **dead tuple 공간 회수**: 아무도 볼 수 없게 된 옛 버전을 지우고 그 자리를 새 행이 쓸 수 있게 합니다.
2. **Visibility Map 갱신**: "이 페이지의 모든 행은 모두에게 보인다"를 표시합니다.
3. **Free Space Map 갱신**: 페이지마다 빈 공간이 얼마나 있는지 기록합니다.
4. **freeze**: 오래된 트랜잭션 ID를 "얼려서" 번호가 한 바퀴 돌아도 문제가 없게 합니다([6편](/posts/postgresql/06-xid-wraparound/)).
5. **통계 갱신**: `pg_class`의 페이지 수, 행 수 추정값을 고칩니다.

### 세 단계: 힙 스캔, 인덱스 정리, 힙 정리

[`vacuumlazy.c` 맨 위 주석](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L6-L38)이 이 과정을 세 단계로 설명합니다.

{{< diagram src="/diagrams/pg-vacuum-phases.html" title="VACUUM 한 번이 하는 일" height="560" caption="1단계에서 힙을 훑으며 지울 주소를 모으고, 2단계에서 인덱스를 먼저 정리한 뒤, 3단계에서 힙의 자리를 비웁니다." >}}

- **1단계, 힙 스캔**([`lazy_scan_heap()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L1200)): 테이블을 앞에서부터 읽습니다. Visibility Map에서 "모두 보임"으로 표시된 페이지는 대체로 건너뜁니다(aggressive VACUUM, 아래의 eager scanning, 짧은 구간은 읽는 예외가 있습니다). 읽은 페이지마다 dead tuple을 지우고(pruning), 그 line pointer를 `LP_DEAD`로 바꾼 뒤 주소(TID)를 메모리에 모읍니다. 모을 수 있는 양은 `maintenance_work_mem`까지이고, autovacuum은 `autovacuum_work_mem`(기본값 -1이면 `maintenance_work_mem`)까지입니다. PG17부터는 이 TID를 radix tree 기반의 TidStore에 담아 예전보다 훨씬 적은 메모리로 많은 TID를 모읍니다.
- **2단계, 인덱스 정리**: 모은 TID를 가리키는 인덱스 항목을 모든 인덱스에서 지웁니다.
- **3단계, 힙 정리**([`lazy_vacuum_heap_rel()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L2734)): 힙 페이지를 다시 방문해 `LP_DEAD`를 `LP_UNUSED`로 바꿉니다. 이제 그 line pointer를 새 행이 쓸 수 있습니다.

2단계가 3단계보다 먼저인 이유가 있습니다. 인덱스가 아직 그 TID를 가리키는데 line pointer를 먼저 재사용하면, 인덱스가 전혀 다른 새 행을 가리키게 됩니다. 그래서 인덱스를 먼저 비우고 나서야 힙의 자리를 돌려줍니다. TID를 담을 메모리가 가득 차면 1단계를 잠시 멈추고 2, 3단계를 한 번 돌린 뒤 이어서 스캔합니다.

#### UPDATE를 하면 dead tuple이 쌓인다

페이지와 지도를 들여다보는 데는 contrib 확장 [pageinspect](https://www.postgresql.org/docs/18/pageinspect.html), [pg_visibility](https://www.postgresql.org/docs/18/pgvisibility.html), [pg_freespacemap](https://www.postgresql.org/docs/18/pgfreespacemap.html)을 씁니다. 실습 테이블은 autovacuum이 끼어들지 않도록 `autovacuum_enabled = off`로 만듭니다. 통계(`pg_stat_user_tables`)는 약간 늦게 반영되므로, 변경 뒤에는 2초 기다렸다가 조회합니다.

```console
$ pg_ctl -D $PGDATA -l /home/postgres/server.log start
waiting for server to start.... done
server started
```

```psql
postgres=# CREATE EXTENSION pageinspect;
postgres=# CREATE EXTENSION pg_visibility;
postgres=# CREATE EXTENSION pg_freespacemap;
postgres=# CREATE TABLE t (id int PRIMARY KEY, v int, pad text) WITH (autovacuum_enabled = off);
postgres=# INSERT INTO t SELECT g, 0, repeat('x', 100) FROM generate_series(1, 20000) g;
```

```console
$ sleep 2
```

```psql
postgres=# VACUUM (ANALYZE) t;
postgres=# SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
  size   | pages 
---------+-------
 2760 kB |   345
(1 row)

postgres=# UPDATE t SET v = v + 1;
UPDATE 20000
postgres=# SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
  size   | pages 
---------+-------
 5520 kB |   690
(1 row)
```

```console
$ sleep 2
```

```psql
postgres=# SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't';
 n_live_tup | n_dead_tup 
------------+------------
      20000 |      20000
(1 row)
```

2만 행 전체를 한 번 UPDATE하자 테이블이 345페이지에서 690페이지로 **정확히 두 배**가 되었습니다. 새 버전 2만 개가 새로 쓰였고, 옛 버전 2만 개(`n_dead_tup`)는 그대로 남았기 때문입니다.

#### VACUUM이 dead tuple을 정리한다

```psql
postgres=# VACUUM (VERBOSE, PROCESS_TOAST false) t;
INFO:  vacuuming "postgres.public.t"
INFO:  finished vacuuming "postgres.public.t": index scans: 1
pages: 0 removed, 690 remain, 690 scanned (100.00% of total), 0 eagerly scanned
tuples: 20000 removed, 20000 remain, 0 are dead but not yet removable
removable cutoff: 759, which was 0 XIDs old when operation ended
new relfrozenxid: 758, which is 2 XIDs ahead of previous value
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
visibility map: 690 pages set all-visible, 344 pages set all-frozen (0 were all-visible)
index scan needed: 345 pages from table (50.00% of total) had 20000 dead item identifiers removed
index "t_pkey": pages: 112 in total, 0 newly deleted, 0 currently deleted, 0 reusable
avg read rate: 0.000 MB/s, avg write rate: 0.000 MB/s
buffer usage: 1898 hits, 0 reads, 0 dirtied
WAL usage: 1492 records, 0 full page images, 257943 bytes, 0 buffers full
system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
VACUUM
```

```console
$ sleep 2
```

```psql
postgres=# SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
  size   | pages 
---------+-------
 5520 kB |   690
(1 row)

postgres=# SELECT n_live_tup, n_dead_tup, vacuum_count FROM pg_stat_user_tables WHERE relname = 't';
 n_live_tup | n_dead_tup | vacuum_count 
------------+------------+--------------
      20000 |          0 |            2
(1 row)

postgres=# SELECT count(*) AS pages, pg_size_pretty(sum(avail)) AS free_space FROM pg_freespace('t');
 pages | free_space 
-------+------------
   690 | 2761 kB
(1 row)
```

VACUUM VERBOSE 출력을 한 줄씩 읽어 보겠습니다.

| 출력 | 뜻 |
|---|---|
| `index scans: 1` | 인덱스 정리(2단계)를 한 번 했음 |
| `tuples: 20000 removed` | dead tuple 2만 개를 지움 |
| `removable cutoff: 759` | 이 xid보다 먼저 지워진 튜플만 지울 수 있음. 지금은 다른 트랜잭션이 없어 가장 최신 값 |
| `visibility map: 690 pages set all-visible, 344 pages set all-frozen` | 모든 페이지를 all-visible로 표시함. 옛 버전이 있던 앞쪽 345페이지 가운데 완전히 비워진 344페이지는 얼릴 튜플이 없으니 all-frozen까지 켜졌음. 나머지 1페이지에는 UPDATE의 새 버전 일부가 함께 들어가 있어서 제외 |
| `index scan needed: ... had 20000 dead item identifiers removed` | 힙 345페이지의 `LP_DEAD` line pointer 2만 개. 이들을 가리키는 인덱스 항목을 지운 뒤 `LP_UNUSED`로 바꿈 |
| `WAL usage: 1492 records` | VACUUM도 WAL을 남김 |

그런데 VACUUM 뒤에도 **테이블 크기는 690페이지 그대로**입니다. 지운 자리는 FSM에 빈 공간(2761kB, 테이블의 절반)으로 기록되었을 뿐, 파일은 줄지 않았습니다.

#### 비운 공간은 다시 쓴다

```psql
postgres=# INSERT INTO t SELECT g, 0, repeat('x', 100) FROM generate_series(20001, 30000) g;
INSERT 0 10000
postgres=# SELECT pg_size_pretty(pg_relation_size('t')) AS size, pg_relation_size('t') / 8192 AS pages;
  size   | pages 
---------+-------
 5520 kB |   690
(1 row)
```

1만 행을 새로 넣었는데 테이블은 **690페이지에서 늘지 않았습니다.** INSERT가 FSM에서 빈 공간이 있는 페이지를 찾아 그 자리에 넣었기 때문입니다. VACUUM의 목적은 파일을 줄이는 것이 아니라 **공간을 재사용할 수 있게 만드는 것**입니다.

## Free Space Map과 Visibility Map

VACUUM이 관리하는 지도 두 개가 있습니다. 둘 다 테이블 옆의 별도 fork 파일입니다([3편](/posts/postgresql/03-storage-layout/)).

| 지도 | 파일 | 한 페이지당 | 쓰는 곳 |
|---|---|---|---|
| Free Space Map (FSM) | `_fsm` | 1바이트 ([`freespace/README`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/freespace/README#L15-L30)) | INSERT와 UPDATE가 새 행을 넣을 페이지를 찾을 때 |
| Visibility Map (VM) | `_vm` | 2비트 ([`visibilitymapdefs.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/visibilitymapdefs.h#L17-L21)) | VACUUM이 건너뛸 페이지를 고를 때, index-only scan이 힙을 읽지 않아도 될지 판단할 때 |

VM의 두 비트는 다음과 같습니다.

- **all-visible**: 이 페이지의 모든 튜플이 모든 트랜잭션에게 보입니다. dead tuple도, 커밋 안 된 튜플도 없습니다.
- **all-frozen**: 이 페이지의 모든 튜플이 얼려져 있습니다([6편](/posts/postgresql/06-xid-wraparound/)). wraparound를 막는 VACUUM이 이 페이지를 건너뛸 수 있습니다.

페이지의 튜플이 하나라도 바뀌면 그 페이지의 비트는 바로 지워지고, 다음 VACUUM이 다시 켭니다. **index-only scan**은 인덱스에 필요한 열이 다 있어도, 행이 보이는지 확인하려면 원래 힙을 읽어야 합니다. 그런데 VM이 all-visible이면 그 확인을 건너뛸 수 있습니다.

#### Visibility Map과 index-only scan

`id <= 5000`인 행을 바꿔 그 페이지들의 VM 비트를 지운 뒤, 인덱스만 읽으면 되는 쿼리를 실행합니다.

```psql
postgres=# SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 't';
 n_tup_hot_upd 
---------------
             0
(1 row)

postgres=# UPDATE t SET v = v + 1 WHERE id <= 5000;
UPDATE 5000
postgres=# SELECT pg_sleep(2);
 pg_sleep 
----------
 
(1 row)

postgres=# SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 't';
 n_tup_hot_upd 
---------------
            10
(1 row)

postgres=# SELECT * FROM pg_visibility_map_summary('t');
 all_visible | all_frozen 
-------------+------------
         342 |         84
(1 row)

postgres=# SET enable_seqscan = off;
SET
postgres=# SET enable_bitmapscan = off;
SET
postgres=# EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT count(id) FROM t WHERE id <= 5000;
                              QUERY PLAN                               
-----------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   ->  Index Only Scan using t_pkey on t (actual rows=5000.00 loops=1)
         Index Cond: (id <= 5000)
         Heap Fetches: 9990
         Index Searches: 1
(5 rows)

postgres=# VACUUM t;
VACUUM
postgres=# SELECT * FROM pg_visibility_map_summary('t');
 all_visible | all_frozen 
-------------+------------
         690 |        170
(1 row)

postgres=# EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT count(id) FROM t WHERE id <= 5000;
                              QUERY PLAN                               
-----------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   ->  Index Only Scan using t_pkey on t (actual rows=5000.00 loops=1)
         Index Cond: (id <= 5000)
         Heap Fetches: 0
         Index Searches: 1
(5 rows)
```

- VACUUM 전: all-visible 페이지가 342개뿐이라 `Heap Fetches: 9990`입니다. 인덱스에 있는 `id`만 필요한데도, 행이 보이는지 확인하려고 힙을 9990번 읽었습니다. 5000행인데 9990번인 이유는 인덱스에 옛 버전 항목 5000개와 새 버전 항목 4990개가 모두 있었기 때문입니다. 10건은 같은 페이지 안의 [HOT 업데이트](#pruning과-hot-vacuum-없이도-조금씩-치운다)(`n_tup_hot_upd`가 0에서 10으로 늘어남)라서 인덱스 항목이 새로 생기지 않았습니다.
- VACUUM 후: 690페이지가 모두 all-visible이 되자 `Heap Fetches: 0`입니다. 힙을 전혀 읽지 않았습니다.

## line pointer의 일생

[3편](/posts/postgresql/03-storage-layout/)에서 본 line pointer의 네 가지 상태가 여기서 모두 쓰입니다.

{{< diagram src="/diagrams/pg-line-pointer.html" title="line pointer 하나의 일생" height="560" caption="살아 있던 튜플은 dead tuple이 되고, pruning이 LP_DEAD로, VACUUM이 LP_UNUSED로 바꾼 뒤 다시 쓰입니다." >}}

"지워졌지만 옛 스냅샷엔 보임" 단계가 중요합니다. DELETE나 UPDATE가 커밋되어도, 그보다 먼저 시작한 스냅샷은 여전히 옛 버전을 볼 수 있습니다([4편](/posts/postgresql/04-mvcc/)). VACUUM은 **지금 살아 있는 모든 스냅샷 가운데 가장 오래된 것**보다 먼저 지워진 튜플만 지울 수 있습니다. 이 경계를 VACUUM 출력에서는 `removable cutoff`라고 부르고 소스에서는 [`GetOldestNonRemovableTransactionId()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/procarray.c#L2005)가 계산합니다. 오래 열린 트랜잭션 하나가 테이블 전체의 정리를 막을 수 있는 이유입니다.

#### 긴 트랜잭션이 있으면 지우지 못한다

세션 A가 REPEATABLE READ 트랜잭션을 열어 둔 상태에서, 다른 세션 B가 5000행을 지우고 VACUUM합니다. 프롬프트의 `A`, `B`가 각 세션입니다.

```psql
A=# BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN
A=*# SELECT count(*) FROM t;
 count 
-------
 30000
(1 row)

A=*# SELECT pg_current_snapshot();
 pg_current_snapshot 
---------------------
 766:766:
(1 row)

B=# DELETE FROM t WHERE id > 25000;
DELETE 5000
```

```console
$ psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) t" 2>&1 | grep -E 'tuples:|removable cutoff'
tuples: 0 removed, 26842 remain, 5000 are dead but not yet removable
removable cutoff: 766, which was 1 XIDs old when operation ended
```

```psql
B=# SELECT pid, state, backend_xmin, now() - xact_start > interval '0' AS in_xact FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid();
 pid |        state        | backend_xmin | in_xact 
-----+---------------------+--------------+---------
 119 | idle in transaction |          766 | t
(1 row)
```

`tuples: 0 removed, ... 5000 are dead but not yet removable`. **5000개가 dead지만 지울 수 없다**는 뜻입니다(`remain`은 건너뛴 페이지의 행 수를 추정해 더한 값이라 실제 행 수와 조금 다릅니다). 세션 A의 스냅샷(`backend_xmin = 766`)은 DELETE 전의 데이터를 볼 수 있어야 하므로, VACUUM의 `removable cutoff`도 766에 묶였습니다.

```psql
A=*# COMMIT;
COMMIT
```

```console
$ psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) t" 2>&1 | grep -E 'tuples:|removable cutoff'
tuples: 5000 removed, 19106 remain, 0 are dead but not yet removable
removable cutoff: 767, which was 0 XIDs old when operation ended
```

A가 커밋하자 `removable cutoff`가 767로 넘어가고, 같은 VACUUM이 이번에는 5000개를 모두 지웠습니다.

#### 운영에서는: dead but not yet removable

VACUUM 로그에 `are dead but not yet removable`이 크게 찍히면, 무언가가 `removable cutoff`를 붙잡고 있다는 뜻입니다. 흔한 원인은 다음과 같습니다.

- 오래 열린 트랜잭션, 특히 `idle in transaction` 세션: `pg_stat_activity`의 `backend_xmin`이 오래된 세션을 찾습니다.
- 사용하지 않는 replication slot: 물리 슬롯은 `hot_standby_feedback`을 쓸 때 `xmin`이 모든 테이블의 정리를 붙잡고, 논리 슬롯은 `catalog_xmin`이 시스템 카탈로그의 정리를 붙잡습니다([9편](/posts/postgresql/09-streaming-replication/)).
- standby의 `hot_standby_feedback = on`과 standby에서 도는 긴 쿼리([9편](/posts/postgresql/09-streaming-replication/)).
- 준비만 해 두고 끝내지 않은 prepared transaction(`pg_prepared_xacts`).

이 경우 VACUUM을 아무리 돌려도 dead tuple이 줄지 않으므로, 원인을 먼저 없애야 합니다.

## pruning과 HOT: VACUUM 없이도 조금씩 치운다

VACUUM만 dead tuple을 지우는 것은 아닙니다. 일반 쿼리가 페이지를 읽다가, 그 페이지에 지울 수 있는 옛 버전이 있다는 표시(`pd_prune_xid`)가 있고 빈 공간이 부족해 보이면(fillfactor 목표 또는 페이지의 10% 미만) 그 자리에서 페이지 안의 dead tuple을 정리합니다. 이를 **pruning**이라고 합니다([`heap_page_prune_opt()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/pruneheap.c#L193-L260)). pruning은 튜플 공간을 비우고, 인덱스가 가리키는 line pointer는 `LP_DEAD`로 남겨 둡니다. 인덱스는 건드리지 않으므로 line pointer를 완전히 돌려주는 일(`LP_UNUSED`)은 VACUUM이 해야 합니다.

**HOT(Heap-Only Tuple) 업데이트**는 여기서 한 걸음 더 나갑니다. UPDATE가 인덱스 열을 바꾸지 않고 새 버전이 **같은 페이지**에 들어가면, 인덱스에 새 항목을 만들지 않고 옛 버전에서 새 버전으로 체인만 잇습니다. 인덱스는 체인의 첫 줄만 가리킵니다. 나중에 옛 버전들을 정리할 때 첫 줄은 `LP_REDIRECT`로 남아 살아 있는 버전을 가리키고, 중간 버전은 인덱스가 가리키지 않으므로 바로 `LP_UNUSED`가 됩니다. 인덱스를 고치지 않으니 UPDATE도, VACUUM도 가벼워집니다. [3편](/posts/postgresql/03-storage-layout/)에서 본 `fillfactor`로 페이지에 여유를 남기는 것도 HOT가 일어날 자리를 확보하기 위해서입니다.

#### HOT 업데이트와 pruning

인덱스 열(`id`)이 아닌 `v`만 세 번 바꿉니다.

```psql
postgres=# CREATE TABLE hot (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = off);
CREATE TABLE
postgres=# INSERT INTO hot VALUES (1, 0);
INSERT 0 1
postgres=# UPDATE hot SET v = 1 WHERE id = 1;
UPDATE 1
postgres=# UPDATE hot SET v = 2 WHERE id = 1;
UPDATE 1
postgres=# UPDATE hot SET v = 3 WHERE id = 1;
UPDATE 1
postgres=# SELECT lp, lp_flags, lp_off, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('hot', 0));
 lp | lp_flags | lp_off | t_xmin | t_xmax | t_ctid 
----+----------+--------+--------+--------+--------
  1 |        1 |   8160 |    762 |    763 | (0,2)
  2 |        1 |   8128 |    763 |    764 | (0,3)
  3 |        1 |   8096 |    764 |    765 | (0,4)
  4 |        1 |   8064 |    765 |      0 | (0,4)
(4 rows)
```

```console
$ sleep 2
```

```psql
postgres=# SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname = 'hot';
 n_tup_upd | n_tup_hot_upd 
-----------+---------------
         3 |             3
(1 row)

postgres=# VACUUM hot;
VACUUM
postgres=# SELECT lp, lp_flags, lp_off, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('hot', 0));
 lp | lp_flags | lp_off | t_xmin | t_xmax | t_ctid 
----+----------+--------+--------+--------+--------
  1 |        2 |      4 |        |        | 
  2 |        0 |      0 |        |        | 
  3 |        0 |      0 |        |        | 
  4 |        1 |   8160 |    765 |      0 | (0,4)
(4 rows)
```

- UPDATE 세 번이 모두 HOT였습니다(`n_tup_hot_upd = 3`). 같은 페이지에 버전 네 개가 `t_ctid`로 이어진 체인(lp 1 → 2 → 3 → 4)이 생겼고, 인덱스는 lp 1만 가리킵니다.
- VACUUM 뒤 lp 1은 `lp_flags = 2`(`LP_REDIRECT`)가 되었습니다. `lp_off = 4`는 이 경우 바이트 위치가 아니라 **넘겨줄 line pointer 번호**, 즉 lp 4입니다. 인덱스가 lp 1을 찾아오면 lp 4의 살아 있는 버전으로 넘겨줍니다.
- 중간 버전 lp 2, 3은 `LP_UNUSED`(0)가 되어 바로 다시 쓸 수 있습니다. 살아 있는 버전 lp 4는 페이지 끝(8160)으로 옮겨졌습니다. 페이지 안 빈 공간을 한데 모은(정리한) 결과입니다.

#### 운영에서는: HOT를 살리는 테이블 설계

UPDATE가 많은 테이블이라면 HOT 비율(`n_tup_hot_upd / n_tup_upd`)을 확인해 볼 만합니다. HOT가 안 되는 이유는 보통 두 가지입니다. **자주 바뀌는 열에 인덱스가 걸려 있거나**, **페이지에 새 버전을 넣을 공간이 없어서**입니다. 쓰지 않는 인덱스를 지우고, 자주 바뀌는 테이블은 `fillfactor`를 90 이하로 낮춰 두면 HOT 비율이 올라갑니다.

## 테이블 파일은 끝부분만 줄어든다

세 단계가 끝나면, 테이블 **끝부분**에 완전히 빈 페이지가 충분히 많을 때(1000페이지 이상 또는 테이블의 1/16 이상, [`REL_TRUNCATE_MINIMUM`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L166-L170)) 그만큼 파일을 잘라 냅니다. 이때는 잠깐 `ACCESS EXCLUSIVE` 락이 필요한데, 바로 잡을 수 없거나 기다리는 쿼리가 생기면 포기합니다([`lazy_truncate_heap()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L3224)). 이 동작은 `vacuum_truncate` 설정(PG18에서 전역 설정으로 추가)이나 `VACUUM (TRUNCATE false)`로 끌 수 있습니다. 중간에 있는 빈 페이지는 잘라 내지 않습니다. **일반 VACUUM으로 테이블 파일이 좀처럼 줄지 않는 이유**가 이것입니다. 비운 공간은 [앞에서 본 것처럼](#비운-공간은-다시-쓴다) 새 행이 다시 씁니다.

#### 테이블 끝의 빈 페이지는 잘라 낸다

```psql
postgres=# CREATE TABLE tail (id int, pad text) WITH (autovacuum_enabled = off);
postgres=# INSERT INTO tail SELECT g, repeat('x', 100) FROM generate_series(1, 20000) g;
postgres=# SELECT pg_relation_size('tail') / 8192 AS pages;
 pages 
-------
   345
(1 row)

postgres=# DELETE FROM tail WHERE id > 10000;
```

```console
$ psql -X -c "VACUUM (VERBOSE, PROCESS_TOAST false) tail" 2>&1 | grep -E 'pages:|tuples:'
pages: 172 removed, 173 remain, 345 scanned (100.00% of total), 0 eagerly scanned
tuples: 10000 removed, 10000 remain, 0 are dead but not yet removable
```

```psql
postgres=# SELECT pg_relation_size('tail') / 8192 AS pages;
 pages 
-------
   173
(1 row)
```

앞쪽 1만 행은 두고 **뒤쪽 1만 행**을 지웠더니, 뒤쪽 172페이지가 통째로 비었습니다. VACUUM이 이를 잘라 내 파일이 345페이지에서 173페이지로 줄었습니다(`pages: 172 removed`). 옛 버전이 앞쪽 페이지에 있던 [앞의 VACUUM](#vacuum이-dead-tuple을-정리한다)과 달리, 빈 페이지가 파일 끝에 몰려 있었기 때문입니다.

#### VACUUM FULL은 테이블을 새로 쓴다

```psql
postgres=# DELETE FROM t WHERE id % 2 = 0;
DELETE 12500
postgres=# VACUUM t;
VACUUM
postgres=# SELECT pg_relation_filenode('t') AS filenode, pg_size_pretty(pg_relation_size('t')) AS size;
 filenode |  size   
----------+---------
    16442 | 5520 kB
(1 row)

postgres=# VACUUM FULL t;
VACUUM
postgres=# SELECT pg_relation_filenode('t') AS filenode, pg_size_pretty(pg_relation_size('t')) AS size;
 filenode |  size   
----------+---------
    16461 | 1728 kB
(1 row)
```

절반을 지우고 일반 VACUUM을 해도 5520kB 그대로였지만, `VACUUM FULL` 뒤에는 1728kB로 줄었습니다. 파일 번호(filenode)가 16442에서 16461로 바뀐 것에서 보듯, VACUUM FULL은 아직 지울 수 없는 행까지 포함해 필요한 행만 **새 파일에 다시 쓰고** 옛 파일을 버립니다([`rebuild_relation()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/cluster.c#L629)). 그동안 테이블에 `ACCESS EXCLUSIVE` 락을 잡으므로 **읽기까지 모두 막힙니다.** 또 새 파일을 다 쓸 때까지 옛 파일도 남아 있으므로 테이블 크기만큼의 여유 디스크가 필요합니다. 운영 중인 큰 테이블에는 신중하게 써야 합니다.

#### 운영에서는: 테이블이 줄지 않는다(bloat)

위에서 본 것처럼 일반 VACUUM은 파일을 거의 줄이지 않습니다. dead tuple이 많이 쌓인 뒤에 VACUUM하면 그만큼의 빈 공간이 파일 안에 남는데, 이것을 **bloat**라고 부릅니다. 빈 공간은 새 행이 다시 쓰므로 그 자체로 문제는 아니지만, 테이블을 끝까지 읽는 쿼리(순차 스캔)는 빈 페이지까지 모두 읽어야 해서 느려집니다. bloat가 너무 커지면 다음 방법으로 파일을 줄입니다.

- `VACUUM FULL`: 확실하지만 테이블 전체를 막습니다.
- [`pg_repack`](https://github.com/reorg/pg_repack) 같은 확장: 시작과 끝에만 짧게 락을 잡고 온라인으로 다시 씁니다. 기본 키나 UNIQUE 인덱스가 필요합니다.

가장 좋은 방법은 bloat가 커지기 전에 autovacuum이 자주, 제때 돌게 하는 것입니다.

## autovacuum

VACUUM을 사람이 매번 돌릴 수는 없으므로, [1편](/posts/postgresql/01-process-architecture/)에서 본 autovacuum launcher가 주기적으로(`autovacuum_naptime`, 기본 1분) 테이블을 살피고 필요하면 worker를 띄웁니다. 테이블이 VACUUM 대상이 되는 조건은 다음과 같습니다([`autovacuum.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/autovacuum.c#L3122-L3127)).

> dead tuple 수 > `autovacuum_vacuum_threshold`(50) + `autovacuum_vacuum_scale_factor`(0.2) × 행 수

단, 이 값은 `autovacuum_vacuum_max_threshold`(기본 1억)를 넘지 않습니다. 이 상한은 **PG18에서 새로 생겼습니다.** 예전에는 10억 행 테이블이면 dead tuple이 2억 개 쌓여야 autovacuum이 돌았는데, 이제 1억 개에서 돕니다.

INSERT만 있는 테이블도 대상이 됩니다(freeze와 VM 갱신이 필요하기 때문입니다).

> 마지막 VACUUM 이후 INSERT 수 > `autovacuum_vacuum_insert_threshold`(1000) + `autovacuum_vacuum_insert_scale_factor`(0.2) × 행 수 × **아직 freeze 안 된 페이지 비율**

마지막 항(freeze 안 된 비율)도 **PG18에서 추가되었습니다.** 이 비율을 곱하면 기준값이 **낮아집니다.** 대부분 이미 얼려진 큰 테이블이라면 행 수 전체가 아니라 아직 얼리지 않은 부분만 기준으로 삼으므로, INSERT 기반 VACUUM이 예전보다 자주, 제때 돌게 됩니다. 이미 얼려진 페이지는 VM 덕분에 어차피 건너뜁니다.

#### autovacuum은 언제 도는가

`autovacuum_naptime`을 1초로 줄이고, 1만 행 테이블에서 dead tuple을 기준값 아래와 위로 만들어 봅니다.

```psql
postgres=# ALTER SYSTEM SET autovacuum_naptime = '1s';
postgres=# ALTER SYSTEM SET log_autovacuum_min_duration = 0;
postgres=# SELECT pg_reload_conf();
 pg_reload_conf 
----------------
 t
(1 row)

postgres=# CREATE TABLE av (id int PRIMARY KEY, v int);
postgres=# INSERT INTO av SELECT g, 0 FROM generate_series(1, 10000) g;
```

```console
$ sleep 5
```

```psql
postgres=# SELECT relname, reltuples FROM pg_class WHERE relname = 'av';
 relname | reltuples 
---------+-----------
 av      |     10000
(1 row)

postgres=# SELECT current_setting('autovacuum_vacuum_threshold')::int
postgres-#      + current_setting('autovacuum_vacuum_scale_factor')::float * reltuples AS vacuum_threshold
postgres-# FROM pg_class WHERE relname = 'av';
 vacuum_threshold 
------------------
             2050
(1 row)

postgres=# SELECT n_dead_tup, autovacuum_count, last_autovacuum IS NOT NULL AS vacuumed FROM pg_stat_user_tables WHERE relname = 'av';
 n_dead_tup | autovacuum_count | vacuumed 
------------+------------------+----------
          0 |                1 | t
(1 row)

postgres=# UPDATE av SET v = 1 WHERE id <= 1500;
UPDATE 1500
```

```console
$ sleep 4
```

```psql
postgres=# SELECT n_dead_tup, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'av';
 n_dead_tup | autovacuum_count 
------------+------------------
       1500 |                1
(1 row)

postgres=# UPDATE av SET v = 2 WHERE id <= 1500;
```

```console
$ sleep 4
```

```psql
postgres=# SELECT n_dead_tup, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'av';
 n_dead_tup | autovacuum_count 
------------+------------------
          0 |                2
(1 row)
```

```console
$ grep -A8 'automatic vacuum of table "postgres.public.av"' /home/postgres/server.log | grep -E 'automatic vacuum|tuples:|index scan'
2026-09-24 03:40:42.396 UTC [274] LOG:  automatic vacuum of table "postgres.public.av": index scans: 0
	tuples: 0 removed, 10000 remain, 0 are dead but not yet removable
	index scan not needed: 0 pages from table (0.00% of total) had 0 dead item identifiers removed
2026-09-24 03:40:51.454 UTC [300] LOG:  automatic vacuum of table "postgres.public.av": index scans: 1
	tuples: 1500 removed, 8893 remain, 0 are dead but not yet removable
	index scan needed: 14 pages from table (24.14% of total) had 3000 dead item identifiers removed
```

- 이 테이블의 VACUUM 기준값은 50 + 0.2 × 10000 = **2050**입니다.
- 1만 행을 넣은 직후 autovacuum이 이미 한 번 돌았습니다(`autovacuum_count = 1`). 로그의 첫 번째 `tuples: 0 removed` 기록입니다. 이때는 아직 행 수 추정값이 없어서 0으로 취급하므로([`autovacuum.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/autovacuum.c#L3101-L3102)), INSERT 기준값이 1000이었고 1만 행이 이를 넘었습니다.
- 1500행을 바꿔 dead tuple이 1500개(기준 2050 미만)일 때는 4초를 기다려도 돌지 않았습니다.
- 1500행을 한 번 더 바꿔 누적 3000개가 되자 autovacuum이 돌았습니다(`autovacuum_count = 2`).

두 번째 기록을 보면 `tuples: 1500 removed`인데 `3000 dead item identifiers removed`입니다. 두 번째 UPDATE는 바꿀 행을 인덱스로 찾아 읽었는데, 이때 첫 UPDATE의 옛 버전이 있던 페이지를 **읽으면서 pruning해**([`heapam_handler.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam_handler.c#L136-L141)) 1500개를 `LP_DEAD`로 만들어 두었습니다. VACUUM은 나머지 1500개만 직접 지웠고, 인덱스 항목은 둘 다 지워야 하므로 3000개입니다.

#### 운영에서는: 큰 테이블은 autovacuum이 늦게 돈다

기준값이 `50 + 0.2 × 행 수`이므로, 1억 행 테이블은 dead tuple이 2000만 개 쌓여야 autovacuum이 돕니다. PG18의 `autovacuum_vacuum_max_threshold`(1억)로도 이 정도 테이블에는 효과가 없습니다. 자주 바뀌는 큰 테이블에는 테이블 단위로 기준을 낮춥니다.

```sql
ALTER TABLE big_orders SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 10000);
```

autovacuum이 도는지, 얼마나 자주 도는지는 `pg_stat_user_tables`의 `last_autovacuum`, `autovacuum_count`, `n_dead_tup`으로 확인하고, `log_autovacuum_min_duration`을 켜 두면 위 실습처럼 실행 기록이 로그에 남습니다.

### PG18의 그 밖의 VACUUM 변화

autovacuum 기준 외에 PG18에서 바뀐 점은 다음과 같습니다.

- **eager scanning**([`vacuumlazy.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c#L48-L78)): 일반 VACUUM도 all-visible이지만 아직 얼리지 않은 페이지를 조금씩 미리 읽어 freeze합니다. 나중의 대규모 freeze 작업([6편](/posts/postgresql/06-xid-wraparound/))을 나눠 하려는 것입니다. `vacuum_max_eager_freeze_failure_rate`(기본 0.03)로 조절하고, VACUUM VERBOSE 출력의 `eagerly scanned`가 그 페이지 수입니다.
- **`autovacuum_worker_slots`**(기본 16): autovacuum worker 자리를 미리 잡아 두는 값입니다. 이제 `autovacuum_max_workers`는 재시작 없이 이 범위 안에서 바꿀 수 있습니다.

## 정리

- VACUUM은 **힙 스캔(pruning, TID 수집) → 인덱스 정리 → 힙 정리(`LP_DEAD` → `LP_UNUSED`)** 순서로 일하고, 이 순서는 인덱스가 재사용된 자리를 잘못 가리키지 않게 하려는 것입니다.
- 일반 VACUUM은 공간을 **재사용 가능하게** 만들 뿐, 파일 끝의 빈 페이지가 아니면 파일을 줄이지 않습니다. 줄이려면 `VACUUM FULL`(전체 락)이나 `pg_repack`이 필요합니다.
- VACUUM은 가장 오래된 스냅샷(`removable cutoff`)보다 먼저 지워진 튜플만 지울 수 있어서, 긴 트랜잭션 하나가 정리를 막습니다.
- 쿼리도 페이지가 차면 그 자리에서 pruning하고, HOT 업데이트는 인덱스를 건드리지 않고 같은 페이지 안에서 버전을 잇습니다.
- FSM은 빈 공간을, VM은 all-visible, all-frozen을 페이지마다 기록합니다. VM 덕분에 VACUUM은 페이지를 건너뛰고, index-only scan은 힙을 읽지 않습니다.
- autovacuum은 `50 + 0.2 × 행 수`를 넘는 dead tuple, 또는 INSERT 기준을 넘으면 돕니다. PG18에서 상한(`autovacuum_vacuum_max_threshold`)과 freeze 비율 반영, eager scanning이 추가되었습니다.

다음 글에서는 VACUUM의 또 다른 임무인 **freeze**와 이를 게을리하면 생기는 **트랜잭션 ID wraparound**를 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/access/heap/vacuumlazy.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/vacuumlazy.c): VACUUM 단계, eager scanning, truncate
- [src/backend/access/heap/pruneheap.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/pruneheap.c): pruning과 HOT 체인 정리
- [src/backend/access/heap/README.HOT](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/README.HOT): HOT 설계
- [src/backend/storage/freespace/README](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/freespace/README): FSM 구조
- [src/backend/access/heap/visibilitymap.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/visibilitymap.c): Visibility Map
- [src/backend/postmaster/autovacuum.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/autovacuum.c): autovacuum 대상 판단

PostgreSQL 18 공식 문서

- [Routine Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html)
- [VACUUM](https://www.postgresql.org/docs/18/sql-vacuum.html)
- [Automatic Vacuuming 설정](https://www.postgresql.org/docs/18/runtime-config-vacuum.html)
- [Heap-Only Tuples (HOT)](https://www.postgresql.org/docs/18/storage-hot.html)
- [Visibility Map](https://www.postgresql.org/docs/18/storage-vm.html), [Free Space Map](https://www.postgresql.org/docs/18/storage-fsm.html)
