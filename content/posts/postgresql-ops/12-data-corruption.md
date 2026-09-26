---
title: "PostgreSQL 운영 12: 데이터 손상이 의심된다"
date: 2026-09-26T19:56:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "checksum", "amcheck", "invalid page in block", "page verification failed", "checksum verification failed"]
weight: 12
summary: "invalid page 에러가 뜰 때, 손상 범위를 어떻게 파악하고 무엇을 먼저 살리는가"
description: "checksum 오류, amcheck, 손상 범위 파악"
---

## 개요

특정 테이블을 읽을 때마다 `invalid page in block` 에러가 납니다. 다른 테이블은 멀쩡하고, 같은 테이블도 어떤 행은 읽힙니다. 디스크나 스토리지 계층의 문제로 데이터 파일의 일부가 망가진 것입니다. 이럴 때 가장 위험한 것은 서두르는 것입니다. 잘못된 조치 하나가 살릴 수 있던 데이터를 없애거나, 손상을 보이지 않게 덮어 버립니다.

이 글에서 답할 질문은 다음과 같습니다.

- 데이터 checksum은 손상을 어떻게 알려 주는가
- 망가진 것이 어느 테이블, 어느 블록인지 어떻게 전부 찾는가
- 인덱스만 망가졌을 때와 테이블 페이지가 망가졌을 때 각각 어떻게 하는가
- `ignore_checksum_failure`와 `zero_damaged_pages`는 무엇을 하고, 무엇을 잃는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

> **실습 방법**: 서버를 멈춘 상태에서 테이블 두 개(`t`, `w`)와 인덱스 하나(`u_pkey`)의 1번 블록 끝 30바이트를 `X`로 덮어써 손상을 만들었습니다. 실제 손상은 스토리지 장애, 펌웨어 버그, 잘못된 파일 복사 등에서 옵니다.

PostgreSQL 18은 `initdb` 기본값으로 **데이터 checksum**을 켭니다. 페이지를 디스크에 쓸 때 checksum을 계산해 넣고, 읽을 때 다시 계산해 비교합니다([인터널 3편](/posts/postgresql/03-storage-layout/)).

```psql
postgres=# SHOW data_checksums;
 data_checksums
----------------
 on
(1 row)
```

손상시킬 블록 1에는 `t`의 id 59~115가 들어 있습니다.

```psql
postgres=# SELECT (ctid::text::point)[0]::int AS block, count(*), min(id), max(id)
postgres-# FROM t GROUP BY 1 ORDER BY 1 LIMIT 3;
 block | count | min | max
-------+-------+-----+-----
     0 |    58 |   1 |  58
     1 |    57 |  59 | 115
     2 |    55 | 116 | 170
(3 rows)


postgres=# SELECT 't' AS rel, pg_relation_filepath('t') AS path
postgres-# UNION ALL SELECT 'w', pg_relation_filepath('w')
postgres-# UNION ALL SELECT 'u_pkey', pg_relation_filepath('u_pkey');
  rel   |     path
--------+--------------
 t      | base/5/16394
 w      | base/5/16402
 u_pkey | base/5/16416
(3 rows)
```

## 먼저 확인할 것

### 에러와 로그

```psql
postgres=# SELECT count(*) FROM t;
ERROR:  invalid page in block 1 of relation "base/5/16394"

postgres=# SELECT * FROM t WHERE id = 1;
 id |                                                     v
----+------------------------------------------------------------------------------------------------------------
  1 | row-1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
(1 row)


postgres=# SELECT * FROM t WHERE id = 100;
ERROR:  invalid page in block 1 of relation "base/5/16394"

postgres=# SELECT * FROM u WHERE id = 10;
ERROR:  invalid page in block 1 of relation "base/5/16416"

postgres=# SELECT count(*) FROM u;
 count
-------
  1000
(1 row)
```

- 블록 1을 읽어야 하는 쿼리(전체 스캔, id 100)는 `invalid page in block 1 of relation "base/5/16394"`로 실패합니다.
- 블록 0에 있는 id 1은 인덱스로 찾아 **정상으로 읽힙니다.** 손상은 페이지 단위로 국한됩니다.
- `u`는 인덱스 페이지가 망가졌으므로 인덱스를 쓰는 조회는 실패하지만, 인덱스를 쓰지 않는 전체 스캔은 성공합니다.

서버 로그에는 checksum 불일치가 함께 남습니다.

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'page verification failed|invalid page' | tail -n 4
2026-09-26 10:56:18.567 UTC [201] postgres@postgres/psql ERROR:  invalid page in block 1 of relation "base/5/16394"
2026-09-26 10:56:18.615 UTC [208] postgres@postgres/psql LOG:  page verification failed, calculated checksum 1188 but expected 7419
2026-09-26 10:56:18.615 UTC [208] postgres@postgres/psql LOG:  invalid page in block 1 of relation "base/5/16416"
2026-09-26 10:56:18.615 UTC [208] postgres@postgres/psql ERROR:  invalid page in block 1 of relation "base/5/16416"
```

`page verification failed, calculated checksum ... but expected ...`가 checksum이 맞지 않았다는 뜻이고, 그 결과가 `invalid page` 에러입니다. 에러에 나오는 `base/5/16394`는 파일 경로라서, 어느 테이블인지는 `pg_relation_filepath()`나 `pg_filenode_relation()`으로 거꾸로 찾습니다. 누적 횟수는 `pg_stat_database`에 있습니다.

```psql
postgres=# SELECT datname, checksum_failures, checksum_last_failure FROM pg_stat_database WHERE datname = 'postgres';
 datname  | checksum_failures |     checksum_last_failure
----------+-------------------+-------------------------------
 postgres |                 3 | 2026-09-26 10:56:18.615407+00
(1 row)
```

`checksum_failures`가 0이 아니면 **그 서버의 스토리지를 의심해야 합니다.** 알람으로 걸어 둘 값입니다.

### 무엇부터 할 것인가

1. **스토리지부터 봅니다.** OS의 커널 로그(`dmesg`, journal)에 I/O 에러가 있는지, 디스크나 RAID 컨트롤러가 경고를 내고 있는지 확인합니다. 원인이 남아 있으면 손상은 계속 늘어납니다.
2. **지금 상태를 보존합니다.** 가능하면 데이터 디렉터리를 통째로 복사해 둡니다. 아래의 복구 조치 가운데 일부는 되돌릴 수 없습니다.
3. **손상 범위를 전부 찾습니다.** 에러가 난 테이블 하나만 망가졌다는 보장은 없습니다.
4. **복구 방법을 고릅니다.** 백업이나 standby가 있다면 그것이 가장 안전합니다.

## 손상 범위 파악

### 온라인: pg_amcheck

`pg_amcheck`(PostgreSQL 14부터)는 contrib 확장 `amcheck`를 이용해 DB의 모든 테이블과 B-tree 인덱스를 검사합니다. 서버를 멈추지 않고 돌릴 수 있습니다.

```console
$ pg_amcheck -d postgres 2>&1 | head -n 20
btree index "postgres.public.u_pkey":
    ERROR:  invalid page in block 1 of relation "base/5/16416"
heap table "postgres.public.t":
    ERROR:  invalid page in block 1 of relation "base/5/16394"
heap table "postgres.public.w":
    ERROR:  invalid page in block 1 of relation "base/5/16402"
[exit=0]
```

에러를 낸 `t`뿐 아니라 아직 아무도 읽지 않은 `w`의 손상까지 찾았습니다. **에러가 보고된 테이블 하나만 보고 판단하면 안 되는 이유**입니다. `amcheck`는 checksum뿐 아니라 인덱스 순서가 맞는지, 튜플 헤더가 말이 되는지 같은 논리적인 손상도 검사합니다([amcheck](https://www.postgresql.org/docs/18/amcheck.html)). 전체를 읽으므로 큰 DB에서는 오래 걸리고 I/O를 일으킵니다.

### 오프라인: pg_checksums

서버를 멈출 수 있다면 `pg_checksums --check`로 데이터 디렉터리의 모든 파일, 모든 블록의 checksum을 확인합니다.

```console
$ pg_ctl -D $PGDATA -w stop -m fast
$ pg_checksums --check -D $PGDATA 2>&1 | tail -n 10
$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
waiting for server to shut down.... done
server stopped
pg_checksums: error: checksum verification failed in file "/var/lib/pgsql/18/data/base/5/16416", block 1: calculated checksum 4A4 but block contains 1CFB
pg_checksums: error: checksum verification failed in file "/var/lib/pgsql/18/data/base/5/16394", block 1: calculated checksum D55D but block contains 1E3C
pg_checksums: error: checksum verification failed in file "/var/lib/pgsql/18/data/base/5/16402", block 1: calculated checksum 7D3C but block contains 84DD
Checksum operation completed
Files scanned:   965
Blocks scanned:  2954
Bad checksums:  3
Data checksum version: 1
waiting for server to start.... done
server started
[exit=0]
```

세 블록을 모두 찾았고, 파일과 블록 번호까지 알려 줍니다. `pg_amcheck`와 달리 테이블뿐 아니라 모든 파일을 보지만, checksum만 확인하므로 논리적인 손상은 찾지 못합니다. checksum이 꺼진 클러스터에서는 쓸 수 없습니다.

## 조치

### 인덱스만 망가졌다면: REINDEX

인덱스는 테이블에서 다시 만들 수 있으므로 가장 쉽습니다.

```psql
postgres=# SELECT bt_index_check('u_pkey');
ERROR:  invalid page in block 1 of relation "base/5/16416"

postgres=# REINDEX INDEX u_pkey;
REINDEX

postgres=# SELECT bt_index_check('u_pkey');
 bt_index_check
----------------

(1 row)


postgres=# SELECT * FROM u WHERE id = 10;
 id |  v
----+------
 10 | u-10
(1 row)
```

`bt_index_check()`가 손상을 확인하고, `REINDEX`로 새로 만들자 검사도 조회도 정상이 되었습니다. 서비스 중이라면 `REINDEX INDEX CONCURRENTLY`를 씁니다([5편](/posts/postgresql-ops/05-table-bloat/)). 단, 테이블 쪽도 망가져 있다면 `REINDEX`가 테이블을 읽다가 실패하므로 테이블부터 해결해야 합니다.

### 테이블 페이지가 망가졌다면: 백업부터

테이블 페이지는 다시 만들 원본이 없습니다. **가장 좋은 방법은 백업이나 standby에서 되살리는 것**입니다.

- **standby가 있다면**: standby는 primary의 파일을 복사한 것이 아니라 WAL을 재생해 만든 자기 파일을 가지고 있습니다. primary의 스토리지에서 생긴 손상이라면 standby의 같은 페이지는 멀쩡할 가능성이 큽니다. standby로 장애 조치(failover)하거나, standby에서 그 테이블을 덤프해 옮깁니다. 먼저 standby에서도 `pg_amcheck`로 확인합니다.
- **백업과 WAL 아카이브가 있다면**: 다른 서버에 시점 복구(PITR)로 손상 전 시점을 되살리고, 필요한 테이블을 덤프해 옮깁니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).

둘 다 없을 때 쓰는 마지막 수단이 아래 두 설정입니다. **둘 다 데이터를 잃거나 망가진 데이터를 받아들이는 방법**이고, 슈퍼유저만 켤 수 있으며, 보존용 사본을 떠 둔 뒤에 씁니다.

### ignore_checksum_failure: checksum을 무시하고 읽는다

checksum이 맞지 않아도 경고만 내고 페이지를 읽습니다. 망가진 페이지의 나머지 행을 꺼낼 수 있습니다.

```psql
postgres=# SET ignore_checksum_failure = on;
postgres-# SELECT count(*) FROM t;
WARNING:  ignoring checksum failure in block 1 of relation "base/5/16394"
SET
 count
-------
  1000
(1 row)


postgres=# SET ignore_checksum_failure = on;
postgres-# CREATE TABLE t_rescue AS SELECT * FROM t;
SET
SELECT 1000
```

1000행을 모두 읽어 `t_rescue`로 복사했습니다. 그런데 복사한 데이터를 보면 이렇습니다.

```psql
postgres=# SELECT id, right(v, 35) AS tail FROM t_rescue WHERE id IN (58, 59, 60) ORDER BY id;
 id |                tail
----+-------------------------------------
 58 | aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 59 | XXXXXXXXXXXXXXXXXXXXXXXXXaaaaaaaaaa
 60 | aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
(3 rows)
```

**id 59의 값 끝이 `X`로 바뀌어 있습니다.** checksum을 무시했으니 망가진 바이트도 그대로 읽힌 것입니다. 이 실습은 텍스트 값의 일부만 덮어썼기 때문에 이 정도로 끝났지만, 튜플 헤더나 길이 정보가 망가졌다면 엉뚱한 값을 읽거나 에러가 나거나 backend가 죽을 수도 있습니다. 문서도 이 설정이 서버를 죽이거나 손상을 퍼뜨리거나 숨길 수 있다고 경고합니다([ignore_checksum_failure](https://www.postgresql.org/docs/18/runtime-config-developer.html#GUC-IGNORE-CHECKSUM-FAILURE)). **구조한 데이터는 반드시 검증**합니다. 망가진 블록에 있던 행(여기서는 id 59~115)을 골라 애플리케이션 쪽 기록이나 다른 원천과 대조합니다.

이 설정은 디스크의 페이지를 고치지 않습니다. 재시작한 뒤 다시 읽으면 여전히 손상이 보입니다.

```psql
postgres=# SELECT count(*) FROM t;
ERROR:  invalid page in block 1 of relation "base/5/16394"

postgres=# SELECT id, right(v, 35) AS tail FROM t WHERE id = 59;
ERROR:  invalid page in block 1 of relation "base/5/16394"
```

```console
$ pg_amcheck -d postgres 2>&1 | head -n 10
heap table "postgres.public.t":
    ERROR:  invalid page in block 1 of relation "base/5/16394"
heap table "postgres.public.w":
    ERROR:  invalid page in block 1 of relation "base/5/16402"
[exit=0]
```

### zero_damaged_pages: 망가진 페이지를 버린다

checksum이 맞지 않는 페이지를 만나면 그 페이지를 0으로 채우고, 빈 페이지로 취급해 넘어갑니다. 아무도 건드리지 않은 `w`에 써 봅니다.

```psql
postgres=# SET zero_damaged_pages = on;
postgres-# SELECT count(*) FROM w;
WARNING:  invalid page in block 1 of relation "base/5/16402"; zeroing out page
SET
 count
-------
   943
(1 row)
```

```console
$ tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'zeroing out page' | tail -n 1
2026-09-26 10:56:20.078 UTC [362] postgres@postgres/psql WARNING:  invalid page in block 1 of relation "base/5/16402"; zeroing out page
```

1000행이던 테이블이 943행이 되었습니다. VACUUM 뒤에는 검사에도 걸리지 않습니다.

```psql
postgres=# SELECT count(*) FROM w;
 count
-------
   943
(1 row)


postgres=# VACUUM w;
VACUUM

postgres=# SELECT * FROM verify_heapam('w');
 blkno | offnum | attnum | msg
-------+--------+--------+-----
(0 rows)


postgres=# SELECT count(*) AS missing, min(g) AS first_id, max(g) AS last_id
postgres-# FROM generate_series(1, 1000) g WHERE NOT EXISTS (SELECT 1 FROM w WHERE w.id = g);
 missing | first_id | last_id
---------+----------+---------
      57 |       59 |     115
(1 row)
```

**블록 1에 있던 57행(id 59~115)이 사라졌습니다.** 테이블은 정상처럼 보이지만 그 행들은 돌아오지 않습니다. 페이지를 0으로 채운 상태가 디스크에 쓰이면 되돌릴 방법도 없습니다([zero_damaged_pages](https://www.postgresql.org/docs/18/runtime-config-developer.html#GUC-ZERO-DAMAGED-PAGES)). 그래서 쓰기 전에 보존용 사본을 떠 두고, 가능하면 먼저 `ignore_checksum_failure`로 살릴 수 있는 행을 꺼내 둡니다.

| 방법 | 되살아나는 것 | 잃는 것 | 쓸 때 |
|---|---|---|---|
| `REINDEX` | 인덱스 전체 | 없음 | 인덱스만 망가졌을 때 |
| standby·백업 | 손상 전 데이터 | 백업 이후 변경(PITR이면 최소) | 테이블 페이지 손상, 가장 먼저 검토 |
| `ignore_checksum_failure` | 망가진 페이지의 행 대부분 | 망가진 값이 섞일 수 있음 | 백업이 없을 때 데이터를 꺼내는 용도 |
| `zero_damaged_pages` | 테이블을 다시 읽을 수 있게 됨 | 그 페이지의 모든 행 | 마지막 수단 |

어느 방법으로 살렸든, 조치 뒤에는 `pg_amcheck`를 다시 돌려 남은 손상이 없는지 확인하고, 원인이 된 스토리지 문제가 해결되었는지 확인합니다.

## 재발 방지

- **checksum을 켜 둡니다.** PostgreSQL 18은 기본으로 켜지만, 업그레이드로 넘어온 옛 클러스터는 꺼져 있을 수 있습니다. `SHOW data_checksums`로 확인하고, 꺼져 있다면 서버를 멈추고 `pg_checksums --enable`로 켤 수 있습니다.
- **`pg_stat_database.checksum_failures` 알람**: 0에서 바뀌면 즉시 조사합니다.
- **정기 검사**: 부하가 적은 시간에 `pg_amcheck`를 돌리거나, 백업을 복원한 서버에서 검사합니다. 손상은 읽기 전까지 드러나지 않으므로, 오래 읽지 않는 데이터일수록 늦게 발견됩니다.
- **백업을 복원해 봅니다.** 손상이 났을 때 가장 믿을 만한 방법은 백업이고, 복원해 본 적 없는 백업은 믿을 수 없습니다.
- **스토리지 설정**: `fsync = off`나 쓰기 캐시를 보장하지 않는 스토리지 설정은 장애 때 손상의 원인이 됩니다. `fsync`와 `full_page_writes`는 끄지 않습니다([인터널 7편](/posts/postgresql/07-wal/)).

## 정리

- checksum이 맞지 않으면 로그에 `page verification failed`, 쿼리에 `invalid page in block N of relation ...`가 나옵니다. 손상은 페이지 단위로 국한되어, 다른 페이지의 행은 읽힙니다.
- 에러가 난 테이블 하나만 보지 말고, `pg_amcheck`(온라인)나 `pg_checksums --check`(오프라인)로 전체 범위를 찾습니다.
- 인덱스는 `REINDEX`로 다시 만듭니다. 테이블 페이지는 standby나 백업에서 되살리는 것이 가장 먼저입니다.
- `ignore_checksum_failure`는 망가진 페이지를 읽게 해 주지만 망가진 값도 함께 읽힙니다. 구조한 데이터는 검증합니다.
- `zero_damaged_pages`는 그 페이지의 행을 모두 버립니다. 이 실습에서는 57행이 사라졌습니다. 보존용 사본을 떠 둔 뒤 마지막 수단으로 씁니다.

## 참고 자료

- [amcheck](https://www.postgresql.org/docs/18/amcheck.html), [pg_amcheck](https://www.postgresql.org/docs/18/app-pgamcheck.html)
- [pg_checksums](https://www.postgresql.org/docs/18/app-pgchecksums.html)
- [Data Checksums](https://www.postgresql.org/docs/18/checksums.html)
- [Developer Options](https://www.postgresql.org/docs/18/runtime-config-developer.html): `ignore_checksum_failure`, `zero_damaged_pages`
- [pg_stat_database](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW)
- PostgreSQL 인터널 [3편 데이터 저장 구조](/posts/postgresql/03-storage-layout/), [7편 WAL](/posts/postgresql/07-wal/), [8편 체크포인트와 장애 복구](/posts/postgresql/08-checkpoint-and-recovery/)

