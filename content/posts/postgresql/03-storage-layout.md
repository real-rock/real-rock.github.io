---
title: "PostgreSQL 인터널 3: 데이터 저장 구조"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "페이지", "튜플", "TOAST"]
weight: 3
summary: "테이블의 행은 디스크에 어떤 모양으로 저장되는가"
description: "페이지 레이아웃, 튜플 구조, TOAST"
---

## 개요

[2편](/posts/postgresql/02-memory-architecture/)에서 shared buffers가 8kB 칸의 배열이라는 것을 봤습니다. 이번 글은 그 칸 하나에 들어가는 **8kB 페이지의 안쪽**을 들여다봅니다. `INSERT` 한 줄이 디스크에서 어떤 바이트가 되는지를 끝까지 따라가는 것이 목표입니다.

이 글에서 답할 질문은 다음과 같습니다.

- 테이블은 디스크의 어떤 파일이고, 파일 안은 어떻게 나뉘어 있는가
- 행(튜플) 하나는 어떤 헤더와 데이터로 이루어져 있는가
- 열 순서만 바꿔도 테이블 크기가 달라지는 이유는 무엇인가
- 100kB짜리 텍스트는 8kB 페이지에 어떻게 들어가는가 (TOAST)

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 빌드해 실행한 결과입니다.

> **용어 정리**
> - **힙(heap)**: PostgreSQL에서 테이블 데이터를 담는 파일 형식을 부르는 이름입니다. 행을 정렬하지 않고 빈 곳에 쌓아 두기 때문에 이렇게 부릅니다.
> - **튜플(tuple)**: 테이블의 행 하나가 페이지에 저장된 모습입니다. 이 글에서는 행과 거의 같은 뜻으로 씁니다.
> - **ctid**: 튜플의 물리적 주소입니다. `(블록 번호, 블록 안의 순번)` 형태입니다.

## 테이블은 파일이다

테이블 하나는 `$PGDATA/base/<DB OID>/<파일 번호>` 경로의 파일 하나입니다. 파일은 8kB 블록(페이지)의 연속이고, 블록 번호 0, 1, 2 ...로 부릅니다. 파일이 1GB(131072블록)를 넘으면 `16430.1`, `16430.2`처럼 다음 파일(세그먼트)로 이어집니다.

같은 테이블에 파일이 몇 개 더 붙습니다. 이를 **fork**라고 합니다.

| fork | 파일 이름 | 쓰임 |
|---|---|---|
| main | `16430` | 실제 데이터 |
| fsm | `16430_fsm` | 페이지마다 빈 공간이 얼마나 있는지(Free Space Map). INSERT가 넣을 곳을 찾을 때 씁니다. |
| vm | `16430_vm` | 페이지의 모든 행이 모두에게 보이는지(Visibility Map). VACUUM과 index-only scan이 씁니다. |

fsm과 vm은 [5편](/posts/postgresql/05-vacuum/)(VACUUM)에서 자세히 다룹니다.

#### 테이블 파일과 fork 확인하기

페이지 내용을 보는 데는 contrib 확장인 [pageinspect](https://www.postgresql.org/docs/18/pageinspect.html)를 씁니다. initdb에는 체크섬 옵션을 따로 주지 않았습니다.

```console
$ initdb -D $PGDATA  > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
initdb ok
$ pg_ctl -D $PGDATA -l /home/postgres/server.log start
waiting for server to start.... done
server started
```

```psql
postgres=# CREATE EXTENSION pageinspect;
postgres=# CREATE TABLE fruit (id int, name text);
CREATE TABLE
postgres=# INSERT INTO fruit VALUES (1, 'apple'), (2, 'banana'), (3, 'cherry');
INSERT 0 3
postgres=# SELECT oid AS db_oid, datname FROM pg_database WHERE datname = current_database();
 db_oid | datname  
--------+----------
      5 | postgres
(1 row)

postgres=# SELECT 'fruit'::regclass::oid AS table_oid, pg_relation_filenode('fruit') AS filenode,
postgres-#        pg_relation_filepath('fruit') AS path;
 table_oid | filenode |     path     
-----------+----------+--------------
     16430 |    16430 | base/5/16430
(1 row)
```

```console
$ ls -l $PGDATA/base/5/16430*
-rw------- 1 postgres postgres 8192 Sep 24 03:06 /var/lib/postgresql/data/base/5/16430
```

```psql
postgres=# VACUUM fruit;
```

```console
$ ls -l $PGDATA/base/5/16430*
-rw------- 1 postgres postgres  8192 Sep 24 03:06 /var/lib/postgresql/data/base/5/16430
-rw------- 1 postgres postgres 24576 Sep 24 03:06 /var/lib/postgresql/data/base/5/16430_fsm
-rw------- 1 postgres postgres  8192 Sep 24 03:06 /var/lib/postgresql/data/base/5/16430_vm
$ pg_controldata $PGDATA | grep -E 'Database block size|Blocks per segment|Data page checksum'
Database block size:                  8192
Blocks per segment of large relation: 131072
Data page checksum version:           1
```

- DB `postgres`의 OID는 5, 테이블 `fruit`의 파일 번호는 16430이라 경로는 `base/5/16430`입니다.
- 처음에는 main fork 파일(8kB, 1페이지) 하나뿐입니다. `VACUUM` 뒤에 `_fsm`(3페이지)과 `_vm`(1페이지)이 생겼습니다.
- `Blocks per segment of large relation: 131072`는 131072블록 × 8kB = 1GB마다 파일을 나눈다는 뜻입니다.
- `Data page checksum version: 1`은 데이터 체크섬이 켜져 있다는 뜻입니다. **PG18부터 initdb가 체크섬을 기본으로 켭니다**([`initdb.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/bin/initdb/initdb.c#L167)). 이전 버전에서는 `--data-checksums`를 따로 줘야 했습니다.

## 8kB 페이지의 구조

모든 페이지는 같은 틀을 씁니다. [`bufpage.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/bufpage.h#L24-L45)의 주석 그림이 그 틀입니다(공백만 정리했습니다).

```plaintext
+----------------+---------------------------------+
| PageHeaderData | linp1 linp2 linp3 ...           |
+-----------+----+---------------------------------+
| ... linpN |                                      |
+-----------+--------------------------------------+
|           ^ pd_lower                             |
|                                                  |
|             v pd_upper                           |
+-------------+------------------------------------+
|             | tupleN ...                         |
+-------------+------------------+-----------------+
|       ... tuple3 tuple2 tuple1 | "special space" |
+--------------------------------+-----------------+
                                 ^ pd_special
```

- **페이지 헤더**(24바이트, [`PageHeaderData`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/bufpage.h#L159-L172)): 이 페이지를 마지막으로 바꾼 WAL 위치(`pd_lsn`), 체크섬, 빈 공간의 시작과 끝(`pd_lower`, `pd_upper`) 등을 담습니다.
- **line pointer 배열**: 헤더 바로 뒤에서 시작해 페이지 끝(높은 주소) 쪽으로 자랍니다. 하나에 4바이트이고, 튜플이 페이지의 몇 번째 바이트에서 시작해 몇 바이트인지를 적습니다([`ItemIdData`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/itemid.h#L25-L30): `lp_off` 15비트, `lp_flags` 2비트, `lp_len` 15비트).
- **튜플**: 페이지 끝에서부터 거꾸로 쌓입니다.
- **빈 공간**: `pd_lower`와 `pd_upper` 사이입니다. 둘이 만나면 페이지가 가득 찬 것입니다.
- **special space**: 인덱스 페이지가 자기 정보를 두는 곳입니다. 힙 페이지에서는 크기가 0입니다.

line pointer를 한 단계 거치는 이유가 있습니다. 행의 주소(ctid)는 바이트 위치가 아니라 `(블록 번호, line pointer 번호)`입니다. 그래서 페이지 안에서 튜플을 옮겨 빈 공간을 정리해도 line pointer의 `lp_off`만 고치면 되고, 인덱스가 가리키는 주소는 바뀌지 않습니다.

`lp_flags`는 line pointer의 상태를 나타냅니다([`itemid.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/itemid.h#L38-L41)).

| 값 | 이름 | 뜻 |
|---|---|---|
| 0 | `LP_UNUSED` | 비어 있어 다시 쓸 수 있음 |
| 1 | `LP_NORMAL` | 정상 튜플을 가리킴 |
| 2 | `LP_REDIRECT` | HOT 업데이트로 다른 line pointer로 넘겨 줌 ([5편](/posts/postgresql/05-vacuum/)) |
| 3 | `LP_DEAD` | 죽은 튜플. 공간 회수 대기 |

#### pageinspect로 페이지 헤더 읽기

```psql
postgres=# SELECT * FROM page_header(get_raw_page('fruit', 0));
    lsn    | checksum | flags | lower | upper | special | pagesize | version | prune_xid 
-----------+----------+-------+-------+-------+---------+----------+---------+-----------
 0/17E5C60 |        0 |     4 |    36 |  8072 |    8192 |     8192 |       4 |         0
(1 row)
```

| 값 | 해석 |
|---|---|
| `lower = 36` | 헤더 24바이트 + line pointer 3개 × 4바이트 |
| `upper = 8072` | 튜플 3개가 페이지 끝(8192)에서부터 8072까지 차지 |
| `special = 8192` | 힙 페이지라 special space가 없음 |
| `flags = 4` | [`PD_ALL_VISIBLE`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/bufpage.h#L188-L190). 앞에서 실행한 VACUUM이 "이 페이지의 모든 행은 모두에게 보인다"고 표시함 |
| `checksum = 0` | 체크섬이 켜져 있는데 0입니다. 다음 실습에서 이유를 봅니다. |

#### 파일의 실제 바이트

`CHECKPOINT`로 이 페이지를 디스크에 쓰게 한 뒤, 파일의 앞 40바이트와 끝부분을 16진수로 봅니다.

```psql
postgres=# CHECKPOINT;
```

```console
$ xxd -l 40 $PGDATA/base/5/16430
00000000: 0000 0000 605c 7e01 17d0 0400 2400 881f  ....`\~.....$...
00000010: 0020 0420 0000 0000 d89f 4400 b09f 4600  . . ......D...F.
00000020: 889f 4600 0000 0000                      ..F.....
$ xxd -s 8096 -l 96 $PGDATA/base/5/16430
00001fa0: 0300 0000 0f63 6865 7272 7900 0000 0000  .....cherry.....
00001fb0: f202 0000 0000 0000 0000 0000 0000 0000  ................
00001fc0: 0200 0200 0209 1800 0200 0000 0f62 616e  .............ban
00001fd0: 616e 6100 0000 0000 f202 0000 0000 0000  ana.............
00001fe0: 0000 0000 0000 0000 0100 0200 0209 1800  ................
00001ff0: 0100 0000 0d61 7070 6c65 0000 0000 0000  .....apple......
```

```psql
postgres=# SELECT checksum AS checksum_in_buffer, page_checksum(get_raw_page('fruit', 0), 0) AS computed, to_hex(page_checksum(get_raw_page('fruit', 0), 0) & 65535) AS computed_hex FROM page_header(get_raw_page('fruit', 0));
 checksum_in_buffer | computed | computed_hex 
--------------------+----------+--------------
                  0 |   -12265 | d017
(1 row)
```

앞 40바이트를 필드별로 끊어 읽으면 pageinspect가 보여 준 값과 그대로 맞습니다. 데이터 파일은 CPU의 바이트 순서를 그대로 쓰는데, 일반적인 x86-64와 ARM64 환경은 리틀엔디언이라 여러 바이트짜리 숫자는 뒤집어 읽습니다.

| 바이트 | 필드 | 값 |
|---|---|---|
| `0000 0000 605c 7e01` | `pd_lsn` | 상위 0, 하위 0x017e5c60 → `0/17E5C60` |
| `17d0` | `pd_checksum` | 0xd017 |
| `0400` | `pd_flags` | 4 (`PD_ALL_VISIBLE`) |
| `2400` | `pd_lower` | 0x24 = 36 |
| `881f` | `pd_upper` | 0x1f88 = 8072 |
| `0020` | `pd_special` | 0x2000 = 8192 |
| `0420` | `pd_pagesize_version` | 0x2004 = 8192 + 버전 4 |
| `0000 0000` | `pd_prune_xid` | 0 |
| `d89f 4400` | line pointer 1 | 0x00449fd8 → 하위 15비트 `lp_off` 8152, 다음 2비트 `lp_flags` 1(`LP_NORMAL`), 상위 15비트 `lp_len` 34 |

**체크섬의 비밀.** 디스크의 `pd_checksum`은 0xd017인데, shared buffers에 있는 페이지(`checksum_in_buffer`)는 0입니다. 이 페이지는 메모리에서 처음 만들어진 뒤 디스크에서 다시 읽은 적이 없기 때문입니다(디스크에서 읽어 온 페이지라면 그때의 체크섬 값이 남아 있습니다). PostgreSQL은 체크섬을 **디스크에 쓰는 순간 페이지 복사본에 계산해 넣고**, 메모리의 페이지에는 적지 않습니다([`bufmgr.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L4386), [`PageSetChecksumCopy()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/page/bufpage.c#L1509)). 메모리에 있는 동안에는 여러 번 바뀌어도 체크섬을 다시 계산하지 않아도 되고, 디스크의 페이지가 깨졌는지는 읽어 올 때 확인합니다. pageinspect로 계산한 값(`computed_hex = d017`)이 디스크의 값과 같습니다.

파일 끝부분은 `apple` 튜플(8152 = 0x1fd8부터)입니다. `f202 0000`은 `t_xmin` 0x2f2 = 754, 이어서 `t_xmax` 0과 `t_cid` 0, `t_ctid`(0,1), `0200`은 열 2개, `0209`는 `t_infomask` 0x0902, `18`은 `t_hoff` 24입니다. 한 바이트를 건너뛴 뒤 `0100 0000`이 `id = 1`, `0d`가 varlena 1바이트 헤더(0x0d = 6 << 1 | 1, 헤더 자신 1바이트를 포함한 길이 6), `61 70 70 6c 65`가 `apple`입니다.

## 튜플 하나의 구조

튜플은 **23바이트 헤더**와 데이터로 이루어집니다([`HeapTupleHeaderData`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/htup_details.h#L153-L181)).

| 필드 | 크기 | 뜻 |
|---|---|---|
| `t_xmin` | 4 | 이 튜플을 만든 트랜잭션 ID ([`HeapTupleFields`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/htup_details.h#L122-L132)) |
| `t_xmax` | 4 | 이 튜플을 지웠거나 잠근 트랜잭션 ID. 아직 아무도 안 건드렸으면 0 |
| `t_cid` | 4 | 같은 트랜잭션 안에서 몇 번째 명령이 만들었는지 |
| `t_ctid` | 6 | 이 튜플의 주소, 또는 UPDATE로 생긴 새 버전의 주소 |
| `t_infomask2` | 2 | 열 개수(하위 11비트)와 HOT 관련 플래그 |
| `t_infomask` | 2 | NULL이 있는지, 가변 길이 열이 있는지, xmin/xmax가 커밋되었는지 등 ([`htup_details.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/htup_details.h#L190-L219)) |
| `t_hoff` | 1 | 헤더 전체 크기. 데이터가 시작하는 위치 |

`t_xmin`, `t_xmax`는 [4편](/posts/postgresql/04-mvcc/)(MVCC)의 주인공입니다. "누가 만들었고 누가 지웠는지"가 행마다 헤더에 적혀 있기 때문에, PostgreSQL은 행을 제자리에서 고치지 않고도 트랜잭션마다 다른 버전을 보여 줄 수 있습니다.

#### line pointer와 튜플 헤더

```psql
postgres=# SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask, t_hoff, t_data
postgres-# FROM heap_page_items(get_raw_page('fruit', 0));
 lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_ctid | t_infomask2 | t_infomask | t_hoff |          t_data          
----+--------+----------+--------+--------+--------+--------+-------------+------------+--------+--------------------------
  1 |   8152 |        1 |     34 |    754 |      0 | (0,1)  |           2 |       2306 |     24 | \x010000000d6170706c65
  2 |   8112 |        1 |     35 |    754 |      0 | (0,2)  |           2 |       2306 |     24 | \x020000000f62616e616e61
  3 |   8072 |        1 |     35 |    754 |      0 | (0,3)  |           2 |       2306 |     24 | \x030000000f636865727279
(3 rows)

postgres=# SELECT lp, raw_flags, combined_flags
postgres-# FROM heap_page_items(get_raw_page('fruit', 0)),
postgres-#      LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
 lp |                        raw_flags                         | combined_flags 
----+----------------------------------------------------------+----------------
  1 | {HEAP_HASVARWIDTH,HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID} | {}
  2 | {HEAP_HASVARWIDTH,HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID} | {}
  3 | {HEAP_HASVARWIDTH,HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID} | {}
(3 rows)
```

- `lp_len 34`는 헤더 24 + `int` 4 + varlena 헤더 1 + `apple` 5입니다. `banana`, `cherry`는 한 글자가 더 길어 35입니다.
- 튜플 1은 8152에서 34바이트이지만, 튜플 2는 8152 − 40 = 8112에서 시작합니다. 35바이트를 8의 배수로 올리면 40이기 때문입니다.
- `t_xmin`은 세 행 모두 754입니다. 한 번의 INSERT(트랜잭션 754)로 넣었기 때문입니다. `t_ctid`는 자기 자신을 가리킵니다.
- `t_infomask` 2306 = 0x0902는 `HEAP_HASVARWIDTH`(가변 길이 열 있음), `HEAP_XMIN_COMMITTED`(만든 트랜잭션이 커밋됨), `HEAP_XMAX_INVALID`(지운 트랜잭션 없음)입니다. `HEAP_XMAX_INVALID`는 INSERT할 때 이미 켜집니다([`heapam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c#L2314-L2316)). 반면 `HEAP_XMIN_COMMITTED`는 나중에 누군가 "이 행을 만든 트랜잭션이 커밋되었다"는 것을 확인하고 적어 넣은 표시로, 이런 비트를 **hint bit**라고 부릅니다. 여기서는 [앞에서](#테이블-파일과-fork-확인하기) 실행한 `VACUUM`이 적었습니다. 일반 조회도 행을 처음 읽을 때 이 비트를 적는데, [2편](/posts/postgresql/02-memory-architecture/)에서 읽기만 했는데 페이지가 dirty가 된 이유가 이것입니다.

#### 운영에서는: 체크섬이 켜진 PG18 클러스터

PG18부터 새로 만드는 클러스터는 체크섬이 기본으로 켜집니다. 체크섬이 있으면 디스크에서 읽은 페이지가 깨졌을 때 [`invalid page in block ...`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L7361) 오류로 바로 알 수 있습니다. 대신 페이지를 쓸 때마다 체크섬을 계산하는 CPU 비용이 조금 들고, 더 눈에 띄는 비용은 WAL입니다. 체크섬이 켜져 있으면 hint bit만 바꿔도, 체크포인트 뒤 그 페이지를 처음 고칠 때 페이지 전체 이미지(full-page image)를 WAL에 남깁니다([`XLogHintBitIsNeeded()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlog.h#L120)). 읽기 위주 작업에서도 WAL이 늘 수 있다는 뜻입니다([7편](/posts/postgresql/07-wal/)). 기존 클러스터(체크섬 꺼짐)를 `pg_upgrade`로 올릴 때는 새 클러스터도 체크섬 설정이 같아야 하므로([`controldata.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/bin/pg_upgrade/controldata.c#L745-L750)), 18에서 initdb할 때 `--no-data-checksums`를 주거나 기존 클러스터에서 서버를 내린 상태에서 `pg_checksums --enable`로 먼저 켜야 합니다(모든 데이터 파일을 다시 쓰므로 시간이 걸립니다).

### NULL 비트맵

헤더 뒤에는 NULL 비트맵이 올 수 있습니다. 한 열이라도 NULL이면 열 개수만큼의 비트를 두고, 값이 있으면 1, NULL이면 0을 적습니다. NULL인 열은 데이터 영역에 아무 바이트도 차지하지 않습니다. 비트맵은 열 8개까지는 23바이트 헤더 뒤의 빈 1바이트에 들어가서 추가 비용이 없고, 열이 그보다 많으면 헤더가 8바이트 단위로 늘어납니다.

#### NULL은 비트맵 한 비트

```psql
postgres=# INSERT INTO fruit VALUES (4, NULL);
INSERT 0 1
postgres=# SELECT lp, lp_len, t_hoff, t_bits, t_infomask, t_data
postgres-# FROM heap_page_items(get_raw_page('fruit', 0)) WHERE lp IN (3, 4);
 lp | lp_len | t_hoff |  t_bits  | t_infomask |          t_data          
----+--------+--------+----------+------------+--------------------------
  3 |     35 |     24 |          |       2306 | \x030000000f636865727279
  4 |     28 |     24 | 10000000 |       2049 | \x04000000
(2 rows)
```

`name`이 NULL인 4번 행은 `t_bits = 10000000`(첫 열 있음, 두 번째 열 NULL)이고 데이터는 `id` 4바이트뿐이라 `lp_len`이 28입니다. NULL 비트맵 1바이트는 23바이트 헤더 뒤의 빈 1바이트에 들어가서 `t_hoff`는 그대로 24입니다. `t_infomask` 2049 = 0x0801은 `HEAP_HASNULL` + `HEAP_XMAX_INVALID`입니다. 아직 아무도 이 행을 읽지 않아서 `HEAP_XMIN_COMMITTED` hint bit는 없습니다.

## 데이터 영역과 정렬(alignment)

데이터 영역에는 열 값이 정의 순서대로 들어갑니다. 이때 CPU가 빠르게 읽을 수 있도록 **타입마다 시작 위치를 정렬**합니다. `bigint`(8바이트)는 8의 배수 위치에서, `int`(4바이트)는 4의 배수 위치에서 시작해야 합니다. 앞 열이 그 위치에서 끝나지 않으면 빈 바이트(padding)를 채워 넣습니다. 튜플 전체도 8바이트 단위(MAXALIGN)로 맞춰 페이지에 놓입니다. 23바이트 헤더가 실제로 24바이트를 차지하는 것도 이 때문입니다(`t_hoff = 24`).

#### 열 순서와 정렬 패딩

같은 네 열(bool 둘, bigint 둘)을 순서만 바꿔 두 테이블을 만듭니다.

```psql
postgres=# CREATE TABLE pad_bad  (a bool, b bigint, c bool, d bigint);
CREATE TABLE
postgres=# CREATE TABLE pad_good (b bigint, d bigint, a bool, c bool);
CREATE TABLE
postgres=# INSERT INTO pad_bad  VALUES (true, 1, true, 2);
INSERT 0 1
postgres=# INSERT INTO pad_good VALUES (1, 2, true, true);
INSERT 0 1
postgres=# SELECT 'pad_bad' AS tbl, lp_len, t_hoff, t_data FROM heap_page_items(get_raw_page('pad_bad', 0))
postgres-# UNION ALL
postgres-# SELECT 'pad_good', lp_len, t_hoff, t_data FROM heap_page_items(get_raw_page('pad_good', 0));
   tbl    | lp_len | t_hoff |                               t_data                               
----------+--------+--------+--------------------------------------------------------------------
 pad_bad  |     56 |     24 | \x0100000000000000010000000000000001000000000000000200000000000000
 pad_good |     42 |     24 | \x010000000000000002000000000000000101
(2 rows)

postgres=# SELECT attname, typname, typlen, typalign
postgres-# FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
postgres-# WHERE attrelid = 'pad_bad'::regclass AND attnum > 0 ORDER BY attnum;
 attname | typname | typlen | typalign 
---------+---------+--------+----------
 a       | bool    |      1 | c
 b       | int8    |      8 | d
 c       | bool    |      1 | c
 d       | int8    |      8 | d
(4 rows)
```

`pad_bad`는 `bool, bigint, bool, bigint` 순서라 bool(1바이트) 뒤마다 7바이트 패딩이 들어가서 데이터가 32바이트, 튜플이 56바이트입니다. `t_data`에 `01` 뒤로 `00`이 일곱 개씩 이어지는 것이 그 패딩입니다. 큰 타입을 앞에 둔 `pad_good`은 데이터 18바이트, 튜플 42바이트입니다. 튜플 길이로는 14바이트 차이지만, 튜플은 페이지에 8바이트 단위로 놓이므로 실제로 차지하는 크기는 56 대 48바이트이고, line pointer까지 더하면 60 대 52바이트입니다. 행 하나에 8바이트, 약 13% 차이입니다. 행이 수억 개인 테이블이라면 무시할 수 없는 크기입니다.

#### 운영에서는: 열 순서로 테이블 크기가 달라진다

위 실습처럼 고정 길이 타입을 큰 것부터(`bigint`, `timestamp` → `int` → `smallint` → `bool`) 앞에 두고 가변 길이 타입(`text` 등)을 뒤에 두면 패딩이 줄어듭니다. 이미 만든 테이블의 열 순서는 바꿀 수 없으므로, 수억 행이 쌓일 테이블이라면 설계할 때 한 번 따져 볼 만합니다. 반대로 행이 적은 테이블이라면 가독성을 위해 논리적인 순서를 두는 편이 낫습니다.

#### 한 페이지에 들어가는 행 수와 fillfactor

헤더와 정렬에 드는 비용은 한 페이지에 들어가는 행 수에도 그대로 드러납니다. `int` 열 하나짜리 테이블에 1만 행을 넣고, fillfactor 50으로 만든 테이블과 비교합니다.

```psql
postgres=# CREATE TABLE narrow (id int);
CREATE TABLE
postgres=# INSERT INTO narrow SELECT generate_series(1, 10000);
INSERT 0 10000
postgres=# CREATE TABLE narrow_ff (id int) WITH (fillfactor = 50);
CREATE TABLE
postgres=# INSERT INTO narrow_ff SELECT generate_series(1, 10000);
INSERT 0 10000
postgres=# SELECT 'narrow' AS tbl, pg_relation_size('narrow') / 8192 AS pages,
postgres-#        (SELECT count(*) FROM heap_page_items(get_raw_page('narrow', 0))) AS rows_in_page0,
postgres-#        (SELECT lower || '/' || upper FROM page_header(get_raw_page('narrow', 0))) AS lower_upper
postgres-# UNION ALL
postgres-# SELECT 'narrow_ff', pg_relation_size('narrow_ff') / 8192,
postgres-#        (SELECT count(*) FROM heap_page_items(get_raw_page('narrow_ff', 0))),
postgres-#        (SELECT lower || '/' || upper FROM page_header(get_raw_page('narrow_ff', 0)));
    tbl    | pages | rows_in_page0 | lower_upper 
-----------+-------+---------------+-------------
 narrow    |    45 |           226 | 928/960
 narrow_ff |    89 |           113 | 476/4576
(2 rows)
```

- 행 하나는 헤더 24 + 데이터 4 = 28바이트, 8의 배수로 올려 32바이트에 line pointer 4바이트를 더해 36바이트입니다. (8192 − 24) ÷ 36 = 226.9라 페이지당 226행이 들어갑니다. `lower = 24 + 226 × 4 = 928`, `upper = 8192 − 226 × 32 = 960`으로 계산과 정확히 맞습니다. 남은 32바이트로는 한 행(36바이트)을 더 넣을 수 없습니다.
- `fillfactor = 50`은 INSERT할 때 페이지를 절반까지만 채우라는 뜻입니다. 페이지당 113행, 페이지 수는 두 배(45 → 89)입니다. 남겨 둔 공간은 나중에 UPDATE가 새 버전을 **같은 페이지에** 넣는 데 씁니다(HOT 업데이트, [5편](/posts/postgresql/05-vacuum/)).

#### 운영에서는: 행 하나에도 23바이트 이상의 비용이 든다

PostgreSQL의 행은 데이터 말고도 헤더 24바이트(정렬 포함)와 line pointer 4바이트를 씁니다. 위 실습에서 `int` 하나만 있는 행이 36바이트를 차지한 것이 그 예입니다. 작은 행이 아주 많은 테이블(로그, 이벤트 등)은 데이터 크기로 짐작한 것보다 디스크를 훨씬 많이 씁니다. 용량을 추정할 때는 이 고정 비용을 함께 계산해야 합니다.

### 가변 길이 값: varlena

가변 길이 값(`text`, `bytea` 등)은 **varlena** 형식으로 저장됩니다. 앞에 길이를 적는 헤더가 붙는데, 값이 126바이트 이하면 1바이트, 그보다 크면 4바이트 헤더를 씁니다([`varatt.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/varatt.h#L255-L262)). 짧은 값이 많은 테이블에서 공간을 아끼려는 설계입니다.

아래 그림은 앞에서 만든 `fruit` 테이블의 첫 페이지를 행이 3개일 때 그대로 그린 것입니다.

{{< diagram src="/diagrams/pg-page-layout.html" title="8kB 힙 페이지 한 장" height="600" caption="실습 fruit 테이블 블록 0. 괄호 안 숫자는 페이지 안의 바이트 위치입니다. line pointer는 앞에서, 튜플은 페이지 끝에서부터 채워집니다." >}}

## TOAST: 페이지보다 큰 값을 저장하는 방법

튜플은 한 페이지 안에 들어가야 합니다. 그러면 100kB짜리 텍스트는 어떻게 저장할까요? PostgreSQL은 큰 값을 **TOAST**(The Oversized-Attribute Storage Technique)로 처리합니다.

튜플이 [`TOAST_TUPLE_THRESHOLD`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/heaptoast.h#L46-L50)를 넘으면([`heapam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c#L2336)), [`heap_toast_insert_or_update()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heaptoast.c#L179-L271)가 튜플을 줄입니다. 이 값은 "한 페이지에 튜플 4개가 들어가는 크기"로 정의되어 있고, 8kB 페이지에서는 **2032바이트**입니다.

{{< diagram src="/diagrams/pg-toast-decision.html" title="행 하나를 저장할 때 TOAST가 결정되는 과정" height="560" caption="먼저 압축하고, 그래도 크면 큰 값부터 TOAST 테이블로 옮깁니다." >}}

줄이는 순서는 네 단계입니다.

1. 저장 전략이 **EXTENDED**인 값을 큰 것부터 압축합니다. 압축해도 값 하나가 목표 크기(2032바이트에서 튜플 헤더를 뺀 데이터 크기)보다 크면 바로 TOAST 테이블로 옮깁니다. **EXTERNAL**인 값은 압축하지 않고, 크면 이 단계에서 바로 옮깁니다.
2. 아직 크면, EXTENDED나 EXTERNAL인 값을 큰 것부터 TOAST 테이블로 옮깁니다.
3. 아직 크면, **MAIN**인 값을 압축합니다.
4. 그래도 크면 MAIN인 값도 옮깁니다. 이때는 목표를 페이지 하나 크기로 넓혀서, MAIN은 정말 어쩔 수 없을 때만 옮깁니다.

옮긴 값은 테이블마다 따로 있는 **TOAST 테이블**(`pg_toast.pg_toast_<OID>`)에 1996바이트짜리 조각([`TOAST_MAX_CHUNK_SIZE`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/heaptoast.h#L84-L89))으로 나뉘어 들어가고, 원래 튜플에는 18바이트짜리 포인터([`TOAST_POINTER_SIZE`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/detoast.h#L31), [`varatt_external`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/varatt.h#L32-L39))만 남습니다.

#### 큰 값은 TOAST로

`text` 열에 세 가지 값을 넣습니다. 짧은 값(100바이트), 압축이 잘 되는 긴 값(`a` 10만 개), 압축이 안 되는 긴 값(md5 해시를 이어 붙인 10만 바이트)입니다.

```psql
postgres=# CREATE TABLE doc (id int, body text);
CREATE TABLE
postgres=# SELECT reltoastrelid::regclass AS toast_table FROM pg_class WHERE relname = 'doc';
       toast_table       
-------------------------
 pg_toast.pg_toast_16447
(1 row)

postgres=# INSERT INTO doc VALUES
postgres-#   (1, repeat('a', 100)),
postgres-#   (2, repeat('a', 100000)),
postgres-#   (3, (SELECT string_agg(md5(g::text), '') FROM generate_series(1, 3125) g));
INSERT 0 3
postgres=# SELECT id, octet_length(body) AS original_bytes, pg_column_size(body) AS stored_bytes,
postgres-#        pg_column_compression(body) AS compression
postgres-# FROM doc ORDER BY id;
 id | original_bytes | stored_bytes | compression 
----+----------------+--------------+-------------
  1 |            100 |          101 | 
  2 |         100000 |         1156 | pglz
  3 |         100000 |       100000 | 
(3 rows)

postgres=# SELECT lp, lp_len FROM heap_page_items(get_raw_page('doc', 0));
 lp | lp_len 
----+--------
  1 |    129
  2 |   1184
  3 |     46
(3 rows)

postgres=# SELECT chunk_id, count(*) AS chunks, min(chunk_seq) AS first_seq, max(chunk_seq) AS last_seq,
postgres-#        max(octet_length(chunk_data)) AS max_chunk_bytes, sum(octet_length(chunk_data)) AS total_bytes
postgres-# FROM pg_toast.pg_toast_16447 GROUP BY chunk_id;
 chunk_id | chunks | first_seq | last_seq | max_chunk_bytes | total_bytes 
----------+--------+-----------+----------+-----------------+-------------
    16452 |     51 |         0 |       50 |            1996 |      100000
(1 row)
```

| id | 원래 크기 | 저장 크기 | 튜플 크기 | 어떻게 저장되었나 |
|---|---|---|---|---|
| 1 | 100 | 101 | 129 | 그대로. varlena 1바이트 헤더 |
| 2 | 100000 | 1156 | 1184 | pglz로 압축하니 2032 아래로 줄어 **압축본을 페이지 안에** 저장 |
| 3 | 100000 | 100000 | 46 | 압축이 안 되어 **TOAST 테이블로** 이동. 튜플에는 18바이트 포인터만 |

3번 값은 TOAST 테이블에 51조각(`chunk_seq` 0-50)으로 들어갔고, 조각 하나의 최대 크기는 정확히 1996바이트입니다. 튜플 크기 46 = 헤더 24 + `id` 4 + 포인터 18입니다.

`stored_bytes`(`pg_column_size`)를 읽을 때 주의할 점이 있습니다. TOAST로 나간 값이면 포인터 크기(18)가 아니라 **TOAST 테이블에 저장된 크기를 varlena 헤더 없이** 돌려줍니다([`detoast.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/common/detoast.c#L606-L616)). 3번 행이 100000으로 나온 이유이고, [다음 실습](#toast가-시작되는-정확한-크기)에서 2001바이트 값이 2005가 아닌 2001로 나오는 이유도 같습니다.

#### TOAST가 시작되는 정확한 크기

압축을 끄고(`STORAGE EXTERNAL`) 1990, 2000, 2001, 2010바이트 값을 넣어 경계를 찾습니다.

```psql
postgres=# CREATE TABLE edge (id int, body text);
CREATE TABLE
postgres=# ALTER TABLE edge ALTER COLUMN body SET STORAGE EXTERNAL;
ALTER TABLE
postgres=# INSERT INTO edge
postgres-# SELECT n, left((SELECT string_agg(md5(g::text), '') FROM generate_series(1, 100) g), n)
postgres-# FROM (VALUES (1990), (2000), (2001), (2010)) v(n);
INSERT 0 4
postgres=# SELECT e.id AS body_bytes, pg_column_size(e.body) AS stored_bytes, h.lp_len AS tuple_bytes
postgres-# FROM edge e JOIN heap_page_items(get_raw_page('edge', 0)) h ON h.t_ctid = e.ctid
postgres-# ORDER BY e.id;
 body_bytes | stored_bytes | tuple_bytes 
------------+--------------+-------------
       1990 |         1994 |        2022
       2000 |         2004 |        2032
       2001 |         2001 |          46
       2010 |         2010 |          46
(4 rows)
```

값이 2000바이트면 varlena 헤더 4바이트를 더해 2004바이트, 튜플은 2032바이트로 페이지 안에 저장되었습니다. **1바이트만 늘린 2001바이트부터 튜플이 46바이트로 줄었습니다.** TOAST 테이블로 옮겨졌다는 뜻입니다. 튜플이 2032바이트를 **넘어야** TOAST가 시작된다는 소스 조건(`t_len > TOAST_TUPLE_THRESHOLD`)과 정확히 맞습니다.

### 열마다 다른 저장 전략

열마다 저장 전략(`attstorage`)이 있습니다([`pg_type.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/catalog/pg_type.h#L182-L189)).

| 전략 | 압축 | 밖으로 옮김 | 기본값인 타입 |
|---|---|---|---|
| `p` PLAIN | 안 함 | 안 함 | `int`, `bigint` 같은 고정 길이 타입 |
| `x` EXTENDED | 함 | 함 | `text`, `bytea`, `jsonb` 등 대부분의 가변 길이 타입 |
| `e` EXTERNAL | 안 함 | 함 | (직접 지정) |
| `m` MAIN | 함 | 최후의 수단 | `numeric` 등 |

압축 방식은 `default_toast_compression`으로 정하고 기본값은 pglz입니다([`TOAST_PGLZ_COMPRESSION`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/common/toast_compression.c#L26)). `lz4`도 쓸 수 있지만 빌드할 때 `--with-lz4`가 필요합니다. 이 글의 실습 서버는 lz4 없이 빌드해서 pglz만 씁니다.

#### 저장 전략 바꾸기

```psql
postgres=# SELECT attname, attstorage FROM pg_attribute WHERE attrelid = 'doc'::regclass AND attnum > 0;
 attname | attstorage 
---------+------------
 id      | p
 body    | x
(2 rows)

postgres=# CREATE TABLE doc_ext (id int, body text);
CREATE TABLE
postgres=# ALTER TABLE doc_ext ALTER COLUMN body SET STORAGE EXTERNAL;
ALTER TABLE
postgres=# INSERT INTO doc_ext VALUES (2, repeat('a', 100000));
INSERT 0 1
postgres=# SELECT 'doc (EXTENDED)' AS tbl, pg_column_size(body) AS stored_bytes, pg_column_compression(body) AS compression FROM doc WHERE id = 2
postgres-# UNION ALL
postgres-# SELECT 'doc_ext (EXTERNAL)', pg_column_size(body), pg_column_compression(body) FROM doc_ext;
        tbl         | stored_bytes | compression 
--------------------+--------------+-------------
 doc (EXTENDED)     |         1156 | pglz
 doc_ext (EXTERNAL) |       100000 | 
(2 rows)
```

같은 값(`a` 10만 개)이 기본 전략(EXTENDED)에서는 압축되어 1156바이트였지만, EXTERNAL로 바꾸면 압축 없이 10만 바이트 그대로 TOAST 테이블에 들어갑니다. 공간은 더 쓰지만 대신 `substr()`처럼 값의 일부만 읽을 때 필요한 조각만 가져올 수 있습니다([TOAST 문서](https://www.postgresql.org/docs/18/storage-toast.html)). 압축된 값은 원하는 위치까지 앞에서부터 풀어야 합니다. pglz는 필요한 앞부분 조각만 가져와 풀 수 있지만 값의 뒤쪽을 읽을수록 더 많이 풀어야 합니다. lz4는 항상 전체를 가져옵니다([`detoast.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/common/detoast.c#L236-L262)).

#### 운영에서는: 큰 값을 자주 바꾸면 TOAST 테이블이 커진다

TOAST로 나간 값을 UPDATE하면 TOAST 테이블에도 새 조각이 생기고 옛 조각은 dead tuple이 됩니다. 큰 `jsonb`나 `text`를 자주 고치는 테이블은 본 테이블보다 TOAST 테이블이 훨씬 커지는 일이 흔합니다. 테이블 크기를 볼 때는 `pg_relation_size()`(main fork만)가 아니라 `pg_total_relation_size()`(TOAST와 인덱스 포함)나 `pg_table_size()`를 봐야 합니다. TOAST 테이블도 VACUUM 대상입니다.

또한 `SELECT *`는 TOAST로 나간 큰 값을 매번 모아서 읽어 옵니다. 큰 열이 필요 없는 조회라면 열을 골라 쓰는 것만으로 I/O가 크게 줄어듭니다.

## 정리

- 테이블은 `base/<DB OID>/<파일 번호>` 파일이고, 1GB마다 세그먼트로 나뉘며, fsm과 vm fork 파일이 따로 붙습니다.
- 8kB 페이지는 **헤더(24바이트) → line pointer 배열(앞에서부터) → 빈 공간 → 튜플(끝에서부터)** 구조입니다. 행의 주소 ctid는 (블록, line pointer 번호)입니다.
- 튜플은 23바이트 헤더(`t_xmin`, `t_xmax`, `t_ctid`, `t_infomask` 등)와 데이터로 이루어지고, 데이터는 타입별 정렬 규칙에 따라 패딩이 들어갑니다. NULL인 값은 데이터 영역을 쓰지 않고 비트맵에 한 비트로만 표시됩니다(비트맵은 열 8개까지 헤더의 빈 1바이트에 들어갑니다).
- 튜플이 **2032바이트를 넘으면** TOAST가 먼저 압축하고, 그래도 크면 값을 1996바이트 조각으로 TOAST 테이블에 옮기고 18바이트 포인터만 남깁니다.
- PG18부터 데이터 체크섬이 기본으로 켜지고, 체크섬은 페이지를 디스크에 쓸 때 계산됩니다.

다음 글에서는 튜플 헤더의 `t_xmin`과 `t_xmax`가 실제로 어떻게 쓰이는지, 즉 **MVCC와 스냅샷, 가시성 판단**을 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/include/storage/bufpage.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/bufpage.h): 페이지 레이아웃, `PageHeaderData`
- [src/include/storage/itemid.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/itemid.h): line pointer
- [src/include/access/htup_details.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/htup_details.h): 튜플 헤더, infomask 비트
- [src/include/access/heaptoast.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/heaptoast.h), [src/backend/access/heap/heaptoast.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heaptoast.c): TOAST 임계값과 처리 순서
- [src/include/varatt.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/varatt.h): varlena 헤더, TOAST 포인터

PostgreSQL 18 공식 문서

- [Database Page Layout](https://www.postgresql.org/docs/18/storage-page-layout.html)
- [Database File Layout](https://www.postgresql.org/docs/18/storage-file-layout.html)
- [TOAST](https://www.postgresql.org/docs/18/storage-toast.html)
- [pageinspect](https://www.postgresql.org/docs/18/pageinspect.html)
