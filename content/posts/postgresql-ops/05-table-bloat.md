---
title: "PostgreSQL 운영 5: 테이블과 인덱스가 계속 커진다"
date: 2026-09-26T19:20:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "bloat", "autovacuum", "automatic vacuum of table"]
weight: 5
summary: "행 수는 그대로인데 테이블과 인덱스가 커질 때, 얼마나 부풀었는지 재고 어떻게 줄이는가"
description: "bloat 측정, autovacuum 튜닝, REINDEX CONCURRENTLY"
---

## 개요

행 수는 거의 그대로인데 테이블 파일이 몇 배로 커지고, 같은 쿼리가 읽는 페이지 수가 늘어납니다. PostgreSQL에서 UPDATE와 DELETE는 옛 버전을 남기고([인터널 4편](/posts/postgresql/04-mvcc/)), 그 자리는 VACUUM이 비워야 다시 쓸 수 있습니다([인터널 5편](/posts/postgresql/05-vacuum/)). 비우는 속도가 쌓이는 속도를 따라가지 못하거나, [4편](/posts/postgresql-ops/04-long-transactions/)처럼 비우지 못하는 동안 파일은 커지고, 한 번 커진 파일은 VACUUM으로 줄지 않습니다. 이렇게 부풀어 오른 상태를 **bloat**라고 부릅니다.

이 글에서 답할 질문은 다음과 같습니다.

- 테이블과 인덱스가 얼마나 부풀었는지 어떻게 재는가
- VACUUM을 했는데 왜 파일이 줄지 않는가
- 부푼 인덱스와 테이블은 어떻게 줄이고, 그 대가는 무엇인가
- autovacuum이 제때 돌게 하려면 무엇을 조정하는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

## 먼저 확인할 것

### 크기와 dead tuple 수

100만 행짜리 `items` 테이블을 만들고 `status` 컬럼에 인덱스를 걸었습니다. 부푸는 과정을 보려고 이 테이블의 autovacuum은 꺼 둡니다.

```psql
postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 237 MB     | 21 MB | 6312 kB
(1 row)
```

여기에 테이블 전체를 세 번 UPDATE합니다. 배치 작업이 상태 값을 차례로 바꾸는 상황입니다.

```psql
postgres=# UPDATE items SET status = 'paid';
UPDATE 1000000

postgres=# UPDATE items SET status = 'shipped';
UPDATE 1000000

postgres=# UPDATE items SET status = 'done';
UPDATE 1000000

postgres=# SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'items';
 n_live_tup | n_dead_tup
------------+------------
    1000000 |    3000000
(1 row)


postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 947 MB     | 43 MB | 25 MB
(1 row)
```

행은 여전히 100만 개인데 테이블은 237 MB에서 947 MB로 4배가 되었습니다. 기본 키 인덱스도 21 MB에서 43 MB로 커졌습니다. `status`는 인덱스가 걸린 컬럼이라 이 UPDATE는 HOT가 될 수 없고, 새 버전마다 **모든 인덱스**에 새 항목이 들어가기 때문입니다([인터널 3편](/posts/postgresql/03-storage-layout/)).

`pg_stat_user_tables`의 `n_dead_tup`은 추정값이라 빠르게 볼 수 있지만, 실제로 공간이 얼마나 비어 있는지는 알려 주지 않습니다.

### pgstattuple로 정확히 재기

contrib 확장 `pgstattuple`은 테이블을 실제로 읽어 살아 있는 튜플, dead tuple, 빈 공간의 비율을 알려 줍니다.

```psql
postgres=# SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
postgres-#        round(free_percent::numeric, 1) AS free_pct, pg_size_pretty(table_len) AS table_len
postgres-# FROM pgstattuple('items');
 tuple_count | dead_tuple_count | dead_pct | free_pct | table_len
-------------+------------------+----------+----------+-----------
     1000000 |          1000000 |     24.2 |     49.8 | 947 MB
(1 row)
```

- `dead_pct` 24.2%: dead tuple이 차지하는 공간
- `free_pct` 49.8%: 이미 비어 있어 새 행이 쓸 수 있는 공간

`n_dead_tup`은 300만인데 `pgstattuple`이 센 dead tuple은 100만입니다. 나머지 200만은 UPDATE가 페이지를 읽는 도중 **pruning**으로 이미 튜플 공간을 비우고 line pointer만 남긴 것입니다([인터널 5편](/posts/postgresql/05-vacuum/)). 그 공간이 `free_pct`에 들어 있습니다.

`pgstattuple`은 테이블 전체를 읽으므로 큰 테이블에서는 오래 걸리고 I/O를 일으킵니다. 대략적인 값으로 충분하면 Visibility Map을 이용해 일부만 읽는 `pgstattuple_approx`를 씁니다([pgstattuple](https://www.postgresql.org/docs/18/pgstattuple.html)).

인덱스는 `pgstatindex`로 봅니다.

```psql
postgres=# SELECT 'items_status_idx' AS index, leaf_pages, round(avg_leaf_density::numeric, 1) AS avg_leaf_density,
postgres-#        pg_size_pretty(index_size) AS size
postgres-# FROM pgstatindex('items_status_idx');
      index       | leaf_pages | avg_leaf_density |  size
------------------+------------+------------------+---------
 items_status_idx |        783 |             96.1 | 6312 kB
(1 row)
```

막 만든 인덱스라 리프 페이지가 96.1% 차 있습니다.

## 원인별 진단

### VACUUM은 공간을 비우지만 파일을 줄이지 않는다

VACUUM을 돌립니다.

```psql
postgres=# VACUUM (VERBOSE) items;
INFO:  vacuuming "postgres.public.items"
INFO:  launched 1 parallel vacuum worker for index vacuuming (planned: 1)
INFO:  finished vacuuming "postgres.public.items": index scans: 1
pages: 0 removed, 121212 remain, 121212 scanned (100.00% of total), 0 eagerly scanned
tuples: 1000000 removed, 1000000 remain, 0 are dead but not yet removable
removable cutoff: 772, which was 0 XIDs old when operation ended
new relfrozenxid: 771, which is 15 XIDs ahead of previous value
frozen: 2 pages from table (0.00% of total) had 33 tuples frozen
visibility map: 121212 pages set all-visible, 90909 pages set all-frozen (0 were all-visible)
index scan needed: 90910 pages from table (75.00% of total) had 3000000 dead item identifiers removed
index "items_pkey": pages: 5486 in total, 0 newly deleted, 0 currently deleted, 0 reusable
index "items_status_idx": pages: 3151 in total, 2358 newly deleted, 2358 currently deleted, 0 reusable
avg read rate: 2486.773 MB/s, avg write rate: 1741.955 MB/s
buffer usage: 156210 hits, 204743 reads, 143420 dirtied
WAL usage: 254976 records, 129073 full page images, 306909696 bytes, 15297 buffers full
system usage: CPU: user: 0.37 s, system: 0.15 s, elapsed: 0.64 s
...
VACUUM
```

`1000000 removed`로 dead tuple을 모두 지웠고, 인덱스에서도 dead 항목 300만 개(`3000000 dead item identifiers removed`)를 지웠습니다. 그런데 크기는 그대로입니다.

```psql
postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 947 MB     | 43 MB | 25 MB
(1 row)


postgres=# SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
postgres-#        round(free_percent::numeric, 1) AS free_pct, pg_size_pretty(table_len) AS table_len
postgres-# FROM pgstattuple('items');
 tuple_count | dead_tuple_count | dead_pct | free_pct | table_len
-------------+------------------+----------+----------+-----------
     1000000 |                0 |      0.0 |     75.1 | 947 MB
(1 row)
```

**947 MB 그대로이고, 그 가운데 75.1%가 빈 공간입니다.** VACUUM은 테이블 끝부분에 연속으로 빈 페이지가 충분히 있을 때만 파일을 잘라 내고, 중간의 빈 공간은 새 행이 다시 쓰도록 표시만 합니다([인터널 5편](/posts/postgresql/05-vacuum/)). 실제로 50만 행을 새로 넣어도 테이블은 커지지 않습니다.

```psql
postgres=# INSERT INTO items SELECT g, 'new', repeat('x', 200) FROM generate_series(1000001, 1500000) g;
INSERT 0 500000

postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 947 MB     | 54 MB | 28 MB
(1 row)


postgres=# SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
postgres-#        round(free_percent::numeric, 1) AS free_pct, pg_size_pretty(table_len) AS table_len
postgres-# FROM pgstattuple('items');
 tuple_count | dead_tuple_count | dead_pct | free_pct | table_len
-------------+------------------+----------+----------+-----------
     1500000 |                0 |      0.0 |     62.8 | 947 MB
(1 row)
```

`free_pct`가 75.1%에서 62.8%로 줄었을 뿐 테이블은 947 MB 그대로입니다. 그러니 **bloat 자체가 곧 장애는 아닙니다.** 빈 공간이 재사용되고 있다면 파일이 더 커지지는 않습니다. 문제가 되는 것은 다음과 같은 경우입니다.

- 디스크가 모자라거나(6편), 백업과 복제로 옮기는 양이 부담이 될 때
- 순차 스캔이 빈 페이지까지 읽어야 해서 느려질 때
- 빈 공간이 계속 늘어나 파일이 계속 커질 때. 이것은 VACUUM이 제때 돌지 못하거나 [4편](/posts/postgresql-ops/04-long-transactions/)처럼 지우지 못하고 있다는 뜻입니다.

### 인덱스는 따로 부푼다

VACUUM 뒤의 `status` 인덱스를 봅니다.

```psql
postgres=# SELECT 'items_status_idx' AS index, leaf_pages, round(avg_leaf_density::numeric, 1) AS avg_leaf_density,
postgres-#        pg_size_pretty(index_size) AS size
postgres-# FROM pgstatindex('items_status_idx');
      index       | leaf_pages | avg_leaf_density | size
------------------+------------+------------------+-------
 items_status_idx |        785 |             95.9 | 25 MB
(1 row)
```

리프 밀도는 95.9%로 좋아 보이지만 크기는 25 MB입니다. 리프 페이지 785개면 6 MB 남짓입니다. VACUUM 출력의 `index "items_status_idx": pages: 3151 in total, 2358 newly deleted`가 설명해 줍니다. 완전히 빈 페이지 2358개를 인덱스 구조에서 떼어 냈지만(재사용 대기), 파일에서는 그대로 공간을 차지합니다. `pgstatindex`의 `avg_leaf_density`는 남은 리프 페이지만 보므로, **인덱스 bloat는 밀도와 함께 크기(`size`)를 봐야** 합니다.

`items_pkey`는 `0 newly deleted`입니다. 기본 키 값은 행마다 달라서 페이지가 완전히 비는 일이 드물고, 대신 페이지마다 조금씩 빈 자리가 남습니다. 이런 인덱스는 VACUUM이 페이지를 떼어 내지도 못합니다.

## 조치

### 인덱스: REINDEX CONCURRENTLY

부푼 인덱스는 새로 만들어 바꾸는 것이 가장 확실합니다.

```psql
postgres=# REINDEX INDEX CONCURRENTLY items_status_idx;
REINDEX

postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 947 MB     | 54 MB | 10176 kB
(1 row)


postgres=# SELECT 'items_status_idx' AS index, leaf_pages, round(avg_leaf_density::numeric, 1) AS avg_leaf_density,
postgres-#        pg_size_pretty(index_size) AS size
postgres-# FROM pgstatindex('items_status_idx');
      index       | leaf_pages | avg_leaf_density |   size
------------------+------------+------------------+----------
 items_status_idx |       1263 |             90.0 | 10176 kB
(1 row)
```

`status` 인덱스가 28 MB에서 10 MB로 줄었습니다(그 사이 50만 행이 늘어서 처음의 6 MB보다 큽니다). `CONCURRENTLY`를 붙이면 새 인덱스를 옆에 만든 뒤 바꿔 끼우므로, 그동안 테이블의 읽기와 쓰기를 막지 않습니다. 대신 일반 `REINDEX`보다 오래 걸리고, 새 인덱스를 만드는 동안 디스크를 그만큼 더 씁니다. 도중에 실패하면 `_ccnew`가 붙은 INVALID 인덱스가 남으니 확인하고 지워야 합니다([REINDEX](https://www.postgresql.org/docs/18/sql-reindex.html)).

### 테이블: VACUUM FULL과 그 대가

테이블 파일 자체를 줄이려면 `VACUUM FULL`로 테이블을 새 파일에 다시 씁니다.

```psql
A=# VACUUM FULL items;
VACUUM
Time: 627.885 ms

postgres=# SELECT pg_size_pretty(pg_table_size('items')) AS table_size,
postgres-#        pg_size_pretty(pg_relation_size('items_pkey')) AS pkey,
postgres-#        pg_size_pretty(pg_relation_size('items_status_idx')) AS status_idx;
 table_size | pkey  | status_idx
------------+-------+------------
 237 MB     | 21 MB | 6792 kB
(1 row)


postgres=# SELECT tuple_count, dead_tuple_count, round(dead_tuple_percent::numeric, 1) AS dead_pct,
postgres-#        round(free_percent::numeric, 1) AS free_pct, pg_size_pretty(table_len) AS table_len
postgres-# FROM pgstattuple('items');
 tuple_count | dead_tuple_count | dead_pct | free_pct | table_len
-------------+------------------+----------+----------+-----------
     1000000 |                0 |      0.0 |      1.4 | 237 MB
(1 row)

```

947 MB가 237 MB로 돌아왔고 인덱스도 함께 새로 만들어졌습니다. 이 테이블은 0.6초 만에 끝났지만, 문제는 **그동안 무슨 일이 생기는가**입니다. 919 MB짜리 테이블로 다시 해 봅니다.

```psql
A=# VACUUM FULL big;

B=# SELECT count(*) FROM big WHERE id = 1;

postgres=# SELECT pid, application_name AS app, state, wait_event_type, wait_event, left(query, 40) AS query
postgres-# FROM pg_stat_activity WHERE application_name IN ('maint', 'app') ORDER BY pid;
 pid |  app  | state  | wait_event_type | wait_event |                 query
-----+-------+--------+-----------------+------------+----------------------------------------
 295 | maint | active | LWLock          | WALWrite   | VACUUM FULL big;
 355 | app   | active | Lock            | relation   | SELECT count(*) FROM big WHERE id = 1;
(2 rows)


postgres=# SELECT pid, command, phase, heap_tuples_scanned, heap_tuples_written
postgres-# FROM pg_stat_progress_cluster;
 pid |   command   |       phase       | heap_tuples_scanned | heap_tuples_written
-----+-------------+-------------------+---------------------+---------------------
 295 | VACUUM FULL | seq scanning heap |             1431808 |             1431808
(1 row)


postgres=# SELECT l.pid, a.application_name AS app, l.mode, l.granted
postgres-# FROM pg_locks l JOIN pg_stat_activity a USING (pid)
postgres-# WHERE l.locktype = 'relation' AND l.relation = 'big'::regclass ORDER BY l.granted DESC;
 pid |  app  |        mode         | granted
-----+-------+---------------------+---------
 295 | maint | AccessExclusiveLock | t
 355 | app   | AccessShareLock     | f
(2 rows)

```

`VACUUM FULL`은 테이블에 **AccessExclusiveLock**을 겁니다. id 하나를 찾는 SELECT조차 `Lock`/`relation`을 기다립니다. `pg_stat_progress_cluster`로 어디까지 진행했는지 볼 수 있습니다.

```psql
# 세션 A: 앞 명령의 결과를 기다림
VACUUM
Time: 3951.015 ms (00:03.951)

# 세션 B: 앞 명령의 결과를 기다림
 count
-------
     1
(1 row)

Time: 3479.863 ms (00:03.480)
```

VACUUM FULL은 3.95초, 그동안 기다린 SELECT는 3.48초가 걸렸습니다. 테이블이 수십 GB라면 이 시간이 수십 분이 되고, [2편](/posts/postgresql-ops/02-blocked-sessions/)의 DDL 락 큐처럼 뒤에 오는 모든 쿼리가 줄을 섭니다. 또 새 파일을 다 쓸 때까지 옛 파일을 지우지 않으므로 **테이블 크기만큼의 여유 공간**이 필요합니다. 디스크가 모자라서 줄이려던 것이라면 VACUUM FULL 자체가 실패할 수 있습니다.

정리하면 다음과 같습니다.

| 방법 | 줄어드는 것 | 락 | 추가 공간 |
|---|---|---|---|
| `VACUUM` | 파일은 그대로, 빈 공간을 재사용 가능하게 | 읽기·쓰기를 막지 않음 | 없음 |
| `REINDEX CONCURRENTLY` | 인덱스 | 읽기·쓰기를 막지 않음 | 인덱스 크기만큼 |
| `VACUUM FULL` | 테이블과 인덱스 | `AccessExclusiveLock`, 읽기도 막음 | 테이블+인덱스 크기만큼 |

`VACUUM FULL`은 점검 시간에 하거나, 서비스를 멈출 수 없다면 코어 밖의 도구(예: 트리거와 복사로 테이블을 다시 쓰는 도구)를 검토합니다. 이 연재는 코어 기능만 다루므로 여기서는 소개하지 않습니다. 어느 쪽이든 **다시 부풀지 않게 하는 것**이 먼저입니다.

## 재발 방지: autovacuum이 제때 돌게 한다

autovacuum은 dead tuple 수가 기준을 넘으면 테이블을 VACUUM합니다. PostgreSQL 18의 기본값은 이렇습니다.

```psql
postgres=# SELECT name, setting FROM pg_settings
postgres-# WHERE name IN ('autovacuum_vacuum_threshold', 'autovacuum_vacuum_scale_factor',
postgres-#                'autovacuum_vacuum_max_threshold', 'autovacuum_vacuum_insert_threshold',
postgres-#                'autovacuum_vacuum_insert_scale_factor')
postgres-# ORDER BY name;
                 name                  |  setting
---------------------------------------+-----------
 autovacuum_vacuum_insert_scale_factor | 0.2
 autovacuum_vacuum_insert_threshold    | 1000
 autovacuum_vacuum_max_threshold       | 100000000
 autovacuum_vacuum_scale_factor        | 0.2
 autovacuum_vacuum_threshold           | 50
(5 rows)

```

기준은 `autovacuum_vacuum_threshold`(50) + `autovacuum_vacuum_scale_factor`(0.2) × 행 수이고, PostgreSQL 18부터는 이 값이 `autovacuum_vacuum_max_threshold`(1억)를 넘지 않습니다([Automatic Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html#AUTOVACUUM)). INSERT만 많은 테이블은 `autovacuum_vacuum_insert_*` 기준으로 따로 판단합니다.

100만 행 테이블이면 20만 개 넘게 쌓여야 돕니다. 15만 행을 UPDATE해 봅니다. 실습에서는 `autovacuum_naptime`을 5초로 줄여 두었습니다.

```psql
postgres=# CREATE TABLE events (id int PRIMARY KEY, state text);
CREATE TABLE

postgres=# INSERT INTO events SELECT g, 'new' FROM generate_series(1, 1000000) g;
INSERT 0 1000000

postgres=# VACUUM ANALYZE events;
VACUUM

postgres=# UPDATE events SET state = 'seen' WHERE id <= 150000;
UPDATE 150000

postgres=# SELECT s.relname, s.n_live_tup, s.n_dead_tup,
postgres-#        50 + 0.2 * c.reltuples AS vacuum_threshold, s.last_autovacuum
postgres-# FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
postgres-# WHERE s.relname = 'events';
 relname | n_live_tup | n_dead_tup | vacuum_threshold | last_autovacuum
---------+------------+------------+------------------+-----------------
 events  |    1000000 |     150000 |           200050 |
(1 row)

postgres=# SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'events';
 relname | n_dead_tup | last_autovacuum | autovacuum_count
---------+------------+-----------------+------------------
 events  |     150000 |                 |                0
(1 row)

```

15초가 지나도 돌지 않았습니다. 테이블의 15%가 dead tuple인데도 기준(20만 50)에 못 미치기 때문입니다. 행이 1억 개인 테이블이라면 2천만 개가 쌓여야 합니다. 큰 테이블일수록 기준이 커지므로 **테이블 단위로 scale factor를 낮춥니다.**

```psql
postgres=# ALTER TABLE events SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE

postgres=# SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'events';
 relname | n_dead_tup |        last_autovacuum        | autovacuum_count
---------+------------+-------------------------------+------------------
 events  |          0 | 2026-09-26 10:19:50.168624+00 |                1
(1 row)

```

5%(5만 50)로 낮추자 몇 초 안에 autovacuum이 돌았고 로그에도 남았습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 4 -E 'automatic vacuum of table "postgres.public.events"'
2026-09-26 10:19:50.168 UTC [646] LOG:  automatic vacuum of table "postgres.public.events": index scans: 1
	pages: 0 removed, 5236 remain, 1476 scanned (28.19% of total), 0 eagerly scanned
	tuples: 150000 removed, 868345 remain, 0 are dead but not yet removable
	removable cutoff: 789, which was 0 XIDs old when operation ended
	frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
```

그 밖에 확인할 것은 다음과 같습니다.

- **autovacuum이 돌지만 느린 경우**: autovacuum은 I/O를 조절하느라 일정량을 읽고 쉽니다(`autovacuum_vacuum_cost_limit`, `autovacuum_vacuum_cost_delay`). 큰 테이블 몇 개가 계속 dead tuple을 쌓는다면 이 값이나 `autovacuum_max_workers`를 조정합니다. `pg_stat_progress_vacuum`으로 진행 상황을 봅니다.
- **돌아도 지우지 못하는 경우**: 로그의 `dead but not yet removable`이 크면 [4편](/posts/postgresql-ops/04-long-transactions/)의 원인부터 해결합니다.
- **UPDATE 패턴**: 자주 바뀌는 컬럼에 꼭 필요하지 않은 인덱스가 걸려 있으면 HOT가 막혀 모든 인덱스가 함께 부풉니다. `fillfactor`로 페이지에 여유를 두면 HOT가 일어날 자리가 생깁니다([인터널 3편](/posts/postgresql/03-storage-layout/)).

**감시할 값**: `pg_stat_user_tables`의 `n_dead_tup`과 `last_autovacuum`, 테이블·인덱스 크기의 추세, 큰 테이블은 주기적인 `pgstattuple_approx`.

## 정리

- UPDATE와 DELETE는 옛 버전을 남기고, 비우는 속도가 따라가지 못하면 테이블과 인덱스가 부풉니다. 인덱스가 걸린 컬럼을 바꾸는 UPDATE는 모든 인덱스를 함께 부풀립니다.
- `pgstattuple`로 dead tuple과 빈 공간의 비율을, `pgstatindex`로 인덱스 밀도를 봅니다. 인덱스는 밀도와 함께 크기를 봐야 합니다.
- VACUUM은 공간을 비워 재사용하게 할 뿐 파일을 줄이지 않습니다. 빈 공간이 재사용되고 있다면 bloat 자체는 급한 문제가 아닙니다.
- 인덱스는 `REINDEX CONCURRENTLY`로 서비스를 막지 않고 줄입니다. `VACUUM FULL`은 테이블을 줄이지만 `AccessExclusiveLock`으로 읽기까지 막고, 테이블 크기만큼의 여유 공간이 필요합니다.
- autovacuum 기준은 행 수의 20%라서 큰 테이블은 dead tuple이 많이 쌓인 뒤에야 돕니다. 테이블 단위로 `autovacuum_vacuum_scale_factor`를 낮춥니다.

## 참고 자료

- [Routine Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html)
- [pgstattuple](https://www.postgresql.org/docs/18/pgstattuple.html)
- [REINDEX](https://www.postgresql.org/docs/18/sql-reindex.html), [VACUUM](https://www.postgresql.org/docs/18/sql-vacuum.html)
- [Progress Reporting](https://www.postgresql.org/docs/18/progress-reporting.html): `pg_stat_progress_vacuum`, `pg_stat_progress_cluster`
- PostgreSQL 인터널 [3편 데이터 저장 구조](/posts/postgresql/03-storage-layout/), [4편 MVCC](/posts/postgresql/04-mvcc/), [5편 VACUUM](/posts/postgresql/05-vacuum/)

