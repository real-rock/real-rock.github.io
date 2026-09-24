---
title: "PostgreSQL 인터널 7: WAL"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "WAL", "LSN", "full_page_writes"]
weight: 7
summary: "모든 변경은 왜 먼저 WAL에 적히고, WAL 레코드에는 무엇이 들어 있는가"
description: "LSN, full page writes, WAL 레코드 구조"
---

## 개요

지금까지 여러 편에서 WAL이 등장했습니다. dirty 페이지를 내보내기 전에 WAL을 먼저 쓴다([2편](/posts/postgresql/02-memory-architecture/)), 체크섬이 켜져 있으면 hint bit도 WAL을 남긴다([3편](/posts/postgresql/03-storage-layout/)), VACUUM도 WAL을 쓴다([5편](/posts/postgresql/05-vacuum/)). 이번 글에서 WAL을 본격적으로 들여다봅니다.

**WAL(Write-Ahead Log)**은 "데이터 파일을 바꾸기 전에, 무엇을 바꿀지를 먼저 로그에 적는다"는 규칙이자 그 로그입니다. 커밋할 때 데이터 파일은 그대로 두고 WAL만 디스크에 확실히 써 두면, 서버가 갑자기 죽어도 WAL을 다시 재생해서 커밋된 변경을 모두 되살릴 수 있습니다. 데이터 파일은 나중에 여유 있게 쓰면 됩니다.

이 글에서 답할 질문은 다음과 같습니다.

- LSN은 무엇이고, WAL 파일 이름은 어떻게 정해지는가
- UPDATE 한 번은 어떤 WAL 레코드를 남기는가
- full page write는 왜 필요하고, 얼마나 큰가
- 커밋할 때 정확히 무엇을 기다리는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### LSN: WAL 안의 위치

WAL은 클러스터가 만들어진(initdb) 이래 끝없이 이어지는 하나의 바이트 흐름으로 볼 수 있습니다. 그 흐름 안의 위치(바이트 오프셋)가 **LSN(Log Sequence Number)**입니다. 64비트 정수이고([`XLogRecPtr`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogdefs.h#L21)), `0/17E4990`처럼 상위 32비트와 하위 32비트를 16진수로 나눠 씁니다. LSN은 계속 커지기만 하므로, 두 LSN을 빼면 그 사이에 쓴 WAL의 바이트 수가 됩니다.

LSN은 여러 곳에 쓰입니다.

- **페이지 LSN**: 모든 데이터 페이지의 헤더(`pd_lsn`, [3편](/posts/postgresql/03-storage-layout/))에는 그 페이지를 마지막으로 바꾼 WAL 레코드의 끝 위치가 적혀 있습니다. dirty 페이지를 디스크에 쓰기 전에 **그 LSN까지 WAL이 디스크에 있는지** 확인합니다.
- **복제와 복구의 진행 위치**: standby가 어디까지 받았는지, 복구가 어디까지 재생했는지도 LSN으로 표시합니다([8편](/posts/postgresql/08-checkpoint-and-recovery/), [9편](/posts/postgresql/09-streaming-replication/)).

WAL 위치는 세 가지로 나눠 볼 수 있습니다.

| 함수 | 뜻 |
|---|---|
| `pg_current_wal_insert_lsn()` | WAL buffers에 **넣은** 곳까지 |
| `pg_current_wal_lsn()` | 운영체제에 write()로 **넘긴** 곳까지(디스크 도달은 미보장) |
| `pg_current_wal_flush_lsn()` | fsync까지 끝나 **확실히 저장된** 곳까지 |

### WAL 파일(세그먼트)

WAL은 `$PGDATA/pg_wal` 아래에 **16MB짜리 파일(세그먼트)**로 나뉘어 저장됩니다. 파일 이름은 24자리 16진수로, 타임라인 ID 8자리, LSN 상위 32비트 8자리, 그리고 그 4GB 구간 안의 세그먼트 순번 8자리(16MB 세그먼트면 `00`~`FF`)입니다([`XLogFileName()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlog_internal.h#L166-L171)). LSN을 보면 몇 번 파일의 몇 번째 바이트인지 바로 계산할 수 있고, `pg_walfile_name()`이 그 계산을 해 줍니다. 타임라인은 복구나 standby 승격 때 WAL의 "갈래"를 나누는 번호입니다([8편](/posts/postgresql/08-checkpoint-and-recovery/)).

다 쓴 세그먼트는 체크포인트 뒤에 필요가 없어지면, 지우는 대신 **앞으로 쓸 번호의 이름으로 바꿔 재활용**합니다(실습 8). 파일을 새로 만드는 비용을 아끼려는 것입니다.

### WAL 레코드의 구조

변경 하나는 WAL 레코드 하나 이상이 됩니다. 레코드의 전체 배치는 [`xlogrecord.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogrecord.h#L20-L37)에 정의되어 있습니다.

{{< diagram src="/diagrams/pg-wal-record.html" title="WAL 레코드 하나의 구조" height="560" caption="실습 3의 UPDATE 레코드. 고정 헤더 뒤에 건드린 블록마다 블록 헤더가 오고, 헤더가 모두 끝난 뒤 블록 데이터와 main data가 이어집니다." >}}

- **고정 헤더**([`XLogRecord`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogrecord.h#L41-L53), 24바이트): 레코드 전체 길이, 트랜잭션 ID, 바로 앞 레코드의 위치(`xl_prev`), 어떤 종류의 레코드인지(`xl_rmid`, `xl_info`), 레코드 전체의 CRC.
- **블록 헤더**([`XLogRecordBlockHeader`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogrecord.h#L103-L113)): 이 레코드가 건드린 페이지마다 하나씩. 어느 파일의 몇 번 블록인지, 페이지 이미지가 붙어 있는지를 적습니다.
- **이미지 헤더**([`XLogRecordBlockImageHeader`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogrecord.h#L141-L159)): 페이지 전체 이미지가 붙어 있을 때, 그 길이와 **hole**(페이지 가운데 빈 공간, 즉 `pd_lower`와 `pd_upper` 사이)의 위치.
- **블록 데이터와 main data**: 실제 변경 내용. "몇 번 line pointer에 이런 튜플을 넣어라" 같은 정보입니다. 블록에 페이지 이미지가 붙으면 이미지가 이미 새 내용을 담고 있으므로 그 블록의 데이터는 보통 생략합니다([`xloginsert.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xloginsert.c#L629-L634)).

어떤 종류의 레코드인지는 **resource manager(rmgr)**로 나뉩니다([`rmgrlist.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/rmgrlist.h#L28-L49)). 테이블 변경은 `Heap`, `Heap2`, 인덱스는 `Btree`, 커밋은 `Transaction`, 체크포인트나 페이지 이미지는 `XLOG` 식입니다. 장애 복구 때는 rmgr마다 정해진 재생(redo) 함수가 레코드를 해석해 페이지에 다시 적용합니다.

### full page write: 페이지 전체를 남기는 이유

디스크는 8kB 페이지를 한 번에 쓰지 못할 수 있습니다. 운영체제와 디스크의 쓰기 단위(보통 4kB나 512바이트)가 더 작기 때문입니다. 페이지를 쓰는 도중 전원이 나가면 **앞 절반은 새 내용, 뒤 절반은 옛 내용**인 깨진 페이지(torn page)가 남을 수 있습니다. 이 페이지에 "3번 line pointer에 튜플 추가" 같은 작은 WAL 레코드를 적용해 봐야 페이지 자체가 망가져 있으니 소용이 없습니다.

그래서 PostgreSQL은 **체크포인트 뒤에 어떤 페이지를 처음 고칠 때, 그 페이지 전체를 WAL에 함께 남깁니다.** 이것이 **full page write(FPW)**, 또는 **full page image(FPI)**입니다. 복구할 때는 이 이미지로 페이지를 통째로 되살린 뒤, 그 뒤의 레코드를 차례로 적용합니다. 판단 기준은 간단합니다. 페이지의 LSN이 마지막 체크포인트의 REDO 위치보다 작거나 같으면, 즉 체크포인트 뒤로 한 번도 안 바뀌었으면 이미지를 붙입니다([`xloginsert.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xloginsert.c#L620)).

- 이미지를 남길 때 가운데 빈 공간(hole)은 빼고 저장해서 크기를 줄입니다.
- `wal_compression`을 켜면 이미지를 압축합니다(pglz, 그리고 빌드 옵션에 따라 lz4, zstd).
- 체크섬이 켜져 있거나 `wal_log_hints = on`이면, 데이터를 바꾸지 않고 **hint bit만 바꿔도** 체크포인트 뒤 첫 변경이면 이미지를 남깁니다([`XLogSaveBufferForHint()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xloginsert.c#L1065)). hint bit만 바뀐 페이지가 깨지면 체크섬이 맞지 않게 되기 때문입니다.

### 커밋: WAL이 디스크에 닿을 때까지 기다린다

{{< diagram src="/diagrams/pg-wal-commit.html" title="UPDATE 한 건이 커밋되기까지 WAL이 지나는 길" height="540" caption="변경은 메모리에서 끝나고, 커밋은 WAL이 디스크에 닿을 때까지만 기다립니다. 데이터 페이지는 나중에 WAL보다 뒤에 씁니다." >}}

1. backend가 페이지를 고치면서 WAL 레코드를 만들어 [`XLogInsert()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xloginsert.c#L474)로 WAL buffers에 넣습니다. 여러 backend가 동시에 넣을 수 있도록, 먼저 WAL 안의 자리를 예약하고([`ReserveXLogInsertLocation()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L1110)) 그 자리에 복사합니다. 복사는 [WAL 삽입 락 8개](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L151)로 나눠 병렬로 합니다.
2. 페이지 헤더의 LSN을 방금 넣은 레코드의 끝 위치로 올립니다.
3. COMMIT하면 커밋 레코드를 넣고, [`XLogFlush()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L2777)로 그 위치까지 WAL을 디스크에 쓰고 fsync합니다([`RecordTransactionCommit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xact.c#L1498-L1502)). 이게 끝나야 클라이언트에 "커밋 완료"를 돌려줍니다. 데이터 페이지는 아직 메모리에만 있습니다.
4. 나중에 checkpointer나 bgwriter가 dirty 페이지를 쓸 때, 그 페이지 LSN까지 WAL이 디스크에 있는지 확인하고(없으면 먼저 flush) 씁니다([2편](/posts/postgresql/02-memory-architecture/)).

`synchronous_commit = off`로 두면 3단계의 `XLogFlush()`를 아예 건너뛰고 바로 "커밋 완료"를 돌려줍니다. WAL을 쓰고 fsync하는 일은 walwriter가 곧 합니다. (동기 복제를 쓰면 커밋은 standby의 응답도 기다리는데, 이것은 [9편](/posts/postgresql/09-streaming-replication/)에서 다룹니다.) 문서에 따르면 위험 구간은 최대 `wal_writer_delay`(기본 200ms)의 세 배입니다([Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html)). 빠르지만, 그 짧은 사이에 서버가 죽으면 **이미 커밋 완료를 받은 트랜잭션이 사라질 수 있습니다.** 데이터가 깨지지는 않고, 마지막 몇 개의 커밋만 없던 일이 됩니다.

## 직접 확인해 보기

### 실습 환경

[실습 이미지](/labs/pg-lab-image/Dockerfile)로 [lab.sh](/labs/pg-07-wal/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-07-wal/final-run.log)에 있습니다. WAL 레코드를 보는 데는 contrib 확장 [pg_walinspect](https://www.postgresql.org/docs/18/pgwalinspect.html)와 명령줄 도구 [pg_waldump](https://www.postgresql.org/docs/18/pgwaldump.html)를 씁니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
87f1d9a55e21bf2409caa4c229b8377226999b914e1c646f91a60ffc2e9caef0
[exit=0]
```

```bash
postgres --version
initdb -D $PGDATA  > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
```

```text
postgres (PostgreSQL) 18.6
initdb ok
[exit=0]
```

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_walinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, memo text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, 'init' FROM generate_series(1, 1000) g"
psql -X -q -c "CHECKPOINT"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. LSN과 WAL 세그먼트 파일

```bash
psql -X <<'SQL'
SELECT pg_current_wal_insert_lsn() AS insert_lsn, pg_current_wal_lsn() AS write_lsn, pg_current_wal_flush_lsn() AS flush_lsn;
SELECT pg_walfile_name(pg_current_wal_insert_lsn()) AS segment_file,
       pg_walfile_name_offset(pg_current_wal_insert_lsn()) AS file_and_offset;
SHOW wal_segment_size;
SQL
ls -l $PGDATA/pg_wal | head -5
```

```text
 insert_lsn | write_lsn | flush_lsn 
------------+-----------+-----------
 0/17E4990  | 0/17E4990 | 0/17E4990
(1 row)

       segment_file       |          file_and_offset           
--------------------------+------------------------------------
 000000010000000000000001 | (000000010000000000000001,8276368)
(1 row)

 wal_segment_size 
------------------
 16MB
(1 row)

total 16392
-rw------- 1 postgres postgres 16777216 Sep 24 04:03 000000010000000000000001
drwx------ 2 postgres postgres     4096 Sep 24 04:03 archive_status
drwx------ 2 postgres postgres     4096 Sep 24 04:03 summaries
[exit=0]
```

지금 LSN은 `0/17E4990`이고, 쉬고 있는 서버라 insert, write, flush 위치가 모두 같습니다. `0x17E4990` = 25053584는 16MB(16777216) 세그먼트 하나를 넘은 위치라 두 번째 파일, 이름으로는 `000000010000000000000001`의 8276368번째 바이트입니다(타임라인 1, 세그먼트 번호 1). LSN 0을 "무효"라는 뜻으로 쓰기 위해 initdb가 첫 세그먼트(`...0000`)를 건너뛰므로, WAL은 처음부터 `...0001`에서 시작합니다([`xlogdefs.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogdefs.h#L24-L27)).

### 실습 2. INSERT 하나가 남기는 WAL 레코드

행 하나를 두 번 넣고, 각각 WAL을 얼마나 남겼는지 봅니다.

```bash
psql -X <<'SQL'
SELECT pg_current_wal_insert_lsn() AS s1 \gset
INSERT INTO acct VALUES (1001, 100, 'hello');
SELECT pg_current_wal_insert_lsn() AS e1 \gset
INSERT INTO acct VALUES (1002, 100, 'world');
SELECT pg_current_wal_insert_lsn() AS e2 \gset
SELECT 'first' AS insert, pg_wal_lsn_diff(:'e1', :'s1') AS wal_bytes
UNION ALL SELECT 'second', pg_wal_lsn_diff(:'e2', :'e1');
SELECT start_lsn, xid, resource_manager AS rmgr, record_type, record_length AS len, fpi_length AS fpi, description
FROM pg_get_wal_records_info(:'s1', :'e2');
SQL
```

```text
INSERT 0 1
INSERT 0 1
 insert | wal_bytes 
--------+-----------
 first  |      8968
 second |       176
(2 rows)

 start_lsn | xid |    rmgr     | record_type | len  | fpi  |          description          
-----------+-----+-------------+-------------+------+------+-------------------------------
 0/17E4990 | 755 | Heap        | INSERT      | 3422 | 3368 | off: 76, flags: 0x00
 0/17E56F0 | 755 | Btree       | INSERT_LEAF | 5473 | 5420 | off: 269
 0/17E6C70 | 755 | Transaction | COMMIT      |   34 |    0 | 2026-09-24 04:03:59.999411+00
 0/17E6C98 | 756 | Heap        | INSERT      |   69 |    0 | off: 77, flags: 0x00
 0/17E6CE0 | 756 | Btree       | INSERT_LEAF |   64 |    0 | off: 270
 0/17E6D20 | 756 | Transaction | COMMIT      |   34 |    0 | 2026-09-24 04:03:59.999843+00
(6 rows)

[exit=0]
```

같은 INSERT인데 첫 번째는 **8968바이트**, 두 번째는 **176바이트**입니다.

- 첫 번째 INSERT는 실습 환경을 만들 때 한 `CHECKPOINT` 뒤로 이 테이블 페이지와 인덱스 페이지를 처음 고친 것이라, 두 레코드 모두 페이지 이미지를 달고 있습니다(`fpi` 3368, 5420). 레코드 세 개는 힙에 튜플 넣기(`Heap INSERT`), 인덱스에 항목 넣기(`Btree INSERT_LEAF`), 커밋(`Transaction COMMIT`)입니다.
- 두 번째 INSERT는 같은 페이지를 다시 고친 것이라 이미지가 없고, 레코드 크기가 69, 64, 34바이트뿐입니다.
- 레코드 길이를 더한 값(3422 + 5473 + 34)보다 LSN 차이(8968)가 조금 큰 것은, 레코드가 8바이트 단위로 정렬되고 WAL 페이지(8kB)마다 페이지 헤더가 끼기 때문입니다.

같은 레코드를 `pg_waldump`로 보면 이렇습니다.

```bash
S=$(psql -X -At -c "SELECT pg_current_wal_insert_lsn()")
psql -X -q -c "INSERT INTO acct VALUES (1003, 100, 'waldump')"
E=$(psql -X -At -c "SELECT pg_current_wal_insert_lsn()")
echo "S=$S E=$E"
pg_waldump -p $PGDATA/pg_wal -s $S -e $E 2>&1
```

```text
S=0/17EE8A8 E=0/17EE958
rmgr: Heap        len (rec/tot):     71/    71, tx:        757, lsn: 0/017EE8A8, prev 0/017EDDB8, desc: INSERT off: 78, flags: 0x00, blkref #0: rel 1663/5/16391 blk 5
rmgr: Btree       len (rec/tot):     64/    64, tx:        757, lsn: 0/017EE8F0, prev 0/017EE8A8, desc: INSERT_LEAF off: 271, blkref #0: rel 1663/5/16397 blk 4
rmgr: Transaction len (rec/tot):     34/    34, tx:        757, lsn: 0/017EE930, prev 0/017EE8F0, desc: COMMIT 2026-09-24 04:04:00.056391 UTC
[exit=0]
```

각 줄은 레코드 하나입니다. `len (rec/tot)`은 레코드 길이, `tx`는 xid, `lsn`은 위치, `prev`는 바로 앞 레코드의 위치이고, `blkref #0: rel 1663/5/16391 blk 5`는 테이블스페이스 1663, DB 5, 파일 16391의 5번 블록을 건드렸다는 뜻입니다. `prev`를 따라가면 레코드가 한 줄로 이어져 있음을 알 수 있습니다.

### 실습 3. full page write: 체크포인트 뒤 첫 수정

`CHECKPOINT` 직후 `id = 1`을 바꾸고, 이어서 같은 페이지의 `id = 2`를 바꿉니다.

```bash
psql -X <<'SQL'
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s1 \gset
UPDATE acct SET balance = balance + 1 WHERE id = 1;
SELECT pg_current_wal_insert_lsn() AS e1 \gset
UPDATE acct SET balance = balance + 1 WHERE id = 2;
SELECT pg_current_wal_insert_lsn() AS e2 \gset
SELECT 'first update after checkpoint' AS which, resource_manager AS rmgr, record_type, record_length AS len, fpi_length AS fpi, block_ref
FROM pg_get_wal_records_info(:'s1', :'e1')
UNION ALL
SELECT 'second update (same page)', resource_manager, record_type, record_length, fpi_length, block_ref
FROM pg_get_wal_records_info(:'e1', :'e2');
SQL
```

```text
CHECKPOINT
UPDATE 1
UPDATE 1
             which             |    rmgr     |   record_type   | len  | fpi  |                                                           block_ref                                                            
-------------------------------+-------------+-----------------+------+------+--------------------------------------------------------------------------------------------------------------------------------
 first update after checkpoint | XLOG        | FPI_FOR_HINT    | 8213 | 8164 | blkref #0: rel 1663/5/16391 fork main blk 0 (FPW); hole: offset: 764, length: 28
 first update after checkpoint | Heap        | LOCK            |   54 |    0 | blkref #0: rel 1663/5/16391 fork main blk 0
 first update after checkpoint | Heap        | UPDATE          | 3573 | 3500 | blkref #0: rel 1663/5/16391 fork main blk 5 (FPW); hole: offset: 340, length: 4692 blkref #1: rel 1663/5/16391 fork main blk 0
 first update after checkpoint | Btree       | INSERT_LEAF     | 7453 | 7400 | blkref #0: rel 1663/5/16397 fork main blk 1 (FPW); hole: offset: 1496, length: 792
 first update after checkpoint | Transaction | COMMIT          |   34 |    0 | 
 second update (same page)     | Heap2       | PRUNE_ON_ACCESS |   56 |    0 | blkref #0: rel 1663/5/16391 fork main blk 0
 second update (same page)     | Heap        | HOT_UPDATE      |   71 |    0 | blkref #0: rel 1663/5/16391 fork main blk 0
 second update (same page)     | Transaction | COMMIT          |   34 |    0 | 
(8 rows)

[exit=0]
```

체크포인트 뒤의 **첫 UPDATE**가 남긴 레코드입니다.

| 레코드 | 크기 | 무엇인가 |
|---|---|---|
| `XLOG FPI_FOR_HINT` | 8213 | UPDATE할 행을 찾으며 blk 0의 hint bit를 적었고, 체크섬이 켜져 있어 blk 0 전체 이미지를 남김 |
| `Heap LOCK` | 54 | blk 0에 자리가 없어 다른 페이지를 찾는 동안 페이지 락을 잠시 풀어야 하므로, 그사이 옛 버전을 임시로 잠갔다고 기록 |
| `Heap UPDATE` | 3573 | 새 버전이 들어갈 blk 5의 이미지(`FPW`, 3500바이트, hole 4692바이트 제외). 이미지가 새 튜플을 이미 담고 있어 튜플 데이터는 생략되고 main data만 붙음. 옛 버전이 있는 blk 0(`blkref #1`)은 바로 앞 `FPI_FOR_HINT`가 이미 이미지를 남겼으므로 참조만 함 |
| `Btree INSERT_LEAF` | 7453 | 새 버전을 가리킬 인덱스 항목. 인덱스 페이지도 체크포인트 뒤 처음이라 이미지 포함 |

이 UPDATE는 blk 0에 자리가 없어 새 버전을 blk 5에 넣었고, 그래서 HOT가 아닌 일반 UPDATE가 되어 인덱스 항목도 새로 만들었습니다([5편](/posts/postgresql/05-vacuum/)). 행 하나를 바꿨는데 WAL은 약 19kB가 생겼습니다.

반면 **두 번째 UPDATE**는 페이지 정리(`PRUNE_ON_ACCESS`) 56바이트와 `HOT_UPDATE` 71바이트뿐입니다. 첫 UPDATE가 커밋되어 `id = 1`의 옛 버전은 누구에게도 보이지 않게 되었고, 이번에 blk 0을 읽으면서 그 옛 버전을 치웠습니다. 그렇게 생긴 자리에 새 버전이 들어가 같은 페이지 안의 HOT 업데이트가 되었고, 그래서 인덱스는 건드리지 않았습니다. blk 0은 체크포인트 뒤에 이미 한 번 이미지를 남긴 페이지라 이번에는 이미지도 필요 없습니다.

### 실습 4. full_page_writes와 wal_compression이 WAL 양에 주는 영향

설정마다 같은 조건을 만들기 위해 1000행짜리 테이블을 새로 만들고 `VACUUM`한 뒤, `CHECKPOINT` 직후 100행을 바꿉니다. 그 UPDATE가 남긴 WAL 범위만 `pg_get_wal_records_info()`로 집계해, 페이지 이미지(`fpi_bytes`)와 나머지(`other_bytes`)를 나눠 봅니다.

```bash
cat > /home/postgres/fpw.sql <<'SQL'
DROP TABLE IF EXISTS fpw_t;
CREATE TABLE fpw_t (id int PRIMARY KEY, balance int, memo text);
INSERT INTO fpw_t SELECT g, 100, 'init' FROM generate_series(1, 1000) g;
VACUUM fpw_t;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s \gset
UPDATE fpw_t SET balance = balance + 1 WHERE id % 10 = 0;
SELECT pg_current_wal_insert_lsn() AS e \gset
SELECT current_setting('full_page_writes') AS fpw, current_setting('wal_compression') AS compression,
       count(*) AS records, count(*) FILTER (WHERE fpi_length > 0) AS with_fpi,
       sum(fpi_length) AS fpi_bytes, sum(record_length - fpi_length) AS other_bytes,
       pg_wal_lsn_diff(:'e', :'s') AS wal_bytes
FROM pg_get_wal_records_info(:'s', :'e');
SQL
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM SET wal_compression = 'pglz'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM SET wal_compression = 'off'" -c "ALTER SYSTEM SET full_page_writes = 'off'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -f /home/postgres/fpw.sql
psql -X -q -c "ALTER SYSTEM RESET full_page_writes" -c "ALTER SYSTEM RESET wal_compression" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
psql:/home/postgres/fpw.sql:1: NOTICE:  table "fpw_t" does not exist, skipping
 fpw | compression | records | with_fpi | fpi_bytes | other_bytes | wal_bytes 
-----+-------------+---------+----------+-----------+-------------+-----------
 on  | off         |     285 |        9 |     72600 |       19485 |     92648
(1 row)

 fpw | compression | records | with_fpi | fpi_bytes | other_bytes | wal_bytes 
-----+-------------+---------+----------+-----------+-------------+-----------
 on  | pglz        |     285 |        9 |     23866 |       19503 |     43800
(1 row)

 fpw | compression | records | with_fpi | fpi_bytes | other_bytes | wal_bytes 
-----+-------------+---------+----------+-----------+-------------+-----------
 off | off         |     285 |        0 |         0 |       19502 |     19840
(1 row)

[exit=0]
```

| 설정 | WAL 레코드 | 이미지가 붙은 레코드 | 이미지 바이트 | 나머지 바이트 | WAL 크기 |
|---|---|---|---|---|---|
| 기본값 (`full_page_writes = on`) | 285 | 9 | 72600 | 19485 | 92648 |
| `wal_compression = pglz` | 285 | 9 | 23866 | 19503 | 43800 |
| `full_page_writes = off` | 285 | 0 | 0 | 19502 | 19840 |

세 번 모두 레코드 수와 이미지를 뺀 나머지 크기(약 19.5kB)는 같고, 달라진 것은 페이지 이미지뿐입니다. 이미지가 붙은 레코드는 9개뿐인데 WAL의 78%(72600 / 92648)를 차지합니다. pglz로 압축하면 이미지가 1/3로 줄어 WAL 전체가 절반 아래가 되고, 끄면 이미지가 사라져 약 1/5이 됩니다. 다만 `full_page_writes = off`는 torn page가 생겨도 복구할 수 없게 만드므로, 디스크가 원자적으로 8kB를 쓴다고 보장되는 환경(일부 파일 시스템이나 스토리지)이 아니면 쓰면 안 됩니다. 이 실습에서도 확인만 하고 바로 되돌렸습니다.

### 실습 5. 체크섬이 켜져 있으면 SELECT도 WAL을 남긴다

새 행 200개를 넣고 `CHECKPOINT`한 뒤, **읽기만** 합니다.

```bash
psql -X <<'SQL'
SHOW data_checksums;
INSERT INTO acct SELECT g, 100, 'new' FROM generate_series(2001, 2200) g;
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS s \gset
SELECT count(*) FROM acct WHERE id > 2000;
SELECT pg_current_wal_insert_lsn() AS e \gset
SELECT pg_wal_lsn_diff(:'e', :'s') AS wal_bytes_by_select,
       pg_wal_lsn_diff(:'e', pg_current_wal_lsn()) AS not_yet_written;
CHECKPOINT;
SELECT resource_manager AS rmgr, record_type, count(*), sum(fpi_length) AS fpi_bytes
FROM pg_get_wal_records_info(:'s', :'e') GROUP BY 1, 2;
SELECT record_type, fpi_length AS fpi, block_ref FROM pg_get_wal_records_info(:'s', :'e') WHERE fpi_length > 0;
SELECT (ctid::text::point)[0]::int AS blk, count(*) AS new_rows FROM acct WHERE id > 2000 GROUP BY 1 ORDER BY 1;
EXPLAIN (COSTS OFF) SELECT count(*) FROM acct WHERE id > 2000;
SQL
```

```text
 data_checksums 
----------------
 on
(1 row)

INSERT 0 200
CHECKPOINT
 count 
-------
   200
(1 row)

 wal_bytes_by_select | not_yet_written 
---------------------+-----------------
               53728 |           53728
(1 row)

CHECKPOINT
 rmgr  |   record_type   | count | fpi_bytes 
-------+-----------------+-------+-----------
 Heap2 | PRUNE_ON_ACCESS |     1 |         0
 XLOG  | FPI_FOR_HINT    |     7 |     53148
(2 rows)

 record_type  | fpi  |                                     block_ref                                      
--------------+------+------------------------------------------------------------------------------------
 FPI_FOR_HINT | 8168 | blkref #0: rel 1663/5/16391 fork main blk 0 (FPW); hole: offset: 768, length: 24
 FPI_FOR_HINT | 8164 | blkref #0: rel 1663/5/16391 fork main blk 1 (FPW); hole: offset: 764, length: 28
 FPI_FOR_HINT | 8164 | blkref #0: rel 1663/5/16391 fork main blk 2 (FPW); hole: offset: 764, length: 28
 FPI_FOR_HINT | 8164 | blkref #0: rel 1663/5/16391 fork main blk 3 (FPW); hole: offset: 764, length: 28
 FPI_FOR_HINT | 8164 | blkref #0: rel 1663/5/16391 fork main blk 4 (FPW); hole: offset: 764, length: 28
 FPI_FOR_HINT | 8164 | blkref #0: rel 1663/5/16391 fork main blk 5 (FPW); hole: offset: 764, length: 28
 FPI_FOR_HINT | 4160 | blkref #0: rel 1663/5/16391 fork main blk 6 (FPW); hole: offset: 400, length: 4032
(7 rows)

 blk | new_rows 
-----+----------
   5 |      106
   6 |       94
(2 rows)

         QUERY PLAN          
-----------------------------
 Aggregate
   ->  Seq Scan on acct
         Filter: (id > 2000)
(3 rows)

[exit=0]
```

SELECT 한 번이 WAL을 **53728바이트** 남겼습니다. 그 대부분은 `FPI_FOR_HINT` 일곱 개(53148바이트)입니다. 어느 페이지인지는 `block_ref`에 나옵니다. 조건이 `id > 2000`이지만 마지막 `EXPLAIN`에서 보듯 인덱스 대신 테이블 전체(blk 0~6)를 순차 스캔(`Seq Scan`)했고, 그러면서 아직 hint bit가 없던 튜플들에 hint bit를 적었습니다([4편](/posts/postgresql/04-mvcc/)). 새 행이 있는 blk 5, 6만이 아니라, 앞선 실습에서 넣고 바꾼 행이 있는 blk 0~4도 포함됩니다. PG18은 체크섬이 기본으로 켜져 있어([3편](/posts/postgresql/03-storage-layout/)) hint bit만 바뀐 페이지도 체크포인트 뒤 첫 변경이면 이미지를 남깁니다. `PRUNE_ON_ACCESS` 한 개는 앞선 실습의 UPDATE가 남긴 옛 버전을 이 SELECT가 페이지를 읽으면서 정리한 기록입니다([5편](/posts/postgresql/05-vacuum/)).

`not_yet_written`이 53728이라는 점도 눈여겨볼 만합니다. 이 WAL은 SELECT가 끝난 시점에 WAL buffers에만 있었고 아직 운영체제에 넘어가지도 않았습니다. SELECT는 xid가 없어 커밋할 때 flush할 필요가 없기 때문입니다. 그래서 이 글의 실습은 WAL 양을 모두 `pg_current_wal_lsn()`(쓴 위치)이 아니라 `pg_current_wal_insert_lsn()`(넣은 위치)으로 잽니다.

### 실습 6. 커밋은 WAL이 디스크에 닿을 때까지 기다린다

행 하나를 넣는 트랜잭션을 5초 동안 반복하는 pgbench를 `synchronous_commit` on, off로 돌립니다.

```bash
cat > /home/postgres/one.sql <<'SQL'
INSERT INTO acct VALUES (100000 + random() * 1000000000, 1, 'x') ON CONFLICT DO NOTHING;
SQL
psql -X -c "SHOW synchronous_commit"
pgbench -n -c 1 -T 5 -f /home/postgres/one.sql postgres 2>&1 | grep -E "number of transactions actually processed|latency average|tps"
PGOPTIONS='-c synchronous_commit=off' pgbench -n -c 1 -T 5 -f /home/postgres/one.sql postgres 2>&1 | grep -E "number of transactions actually processed|latency average|tps"
```

```text
 synchronous_commit 
--------------------
 on
(1 row)

number of transactions actually processed: 54490
latency average = 0.092 ms
tps = 10895.846981 (without initial connection time)
number of transactions actually processed: 128609
latency average = 0.039 ms
tps = 25722.237278 (without initial connection time)
[exit=0]
```

`synchronous_commit = off`에서 처리량이 약 2.4배(10895 → 25722 tps)가 되었습니다. 커밋마다 WAL을 디스크에 fsync하고 기다리던 시간이 빠졌기 때문입니다. 이 실습은 Docker 안의 가상 디스크라 fsync가 비교적 빠른 편이고, 실제 서버의 차이는 디스크에 따라 훨씬 클 수도 작을 수도 있습니다.

### 실습 7. 어떤 종류의 WAL이 쌓였나

initdb 이후 쌓인 WAL 전체를 resource manager별로 집계합니다.

```bash
psql -X <<'SQL'
SELECT "resource_manager/record_type" AS rmgr, count, round(count_percentage::numeric, 1) AS count_pct,
       pg_size_pretty(combined_size) AS bytes, round(combined_size_percentage::numeric, 1) AS bytes_pct,
       round(fpi_size_percentage::numeric, 1) AS fpi_pct
FROM pg_get_wal_stats('0/1000000', pg_current_wal_lsn())
WHERE count > 0 ORDER BY combined_size DESC;
SQL
```

```text
    rmgr     | count  | count_pct |   bytes    | bytes_pct | fpi_pct 
-------------+--------+-----------+------------+-----------+---------
 Heap        | 374771 |      49.1 | 22 MB      |      46.5 |    14.7
 Btree       | 202472 |      26.5 | 15 MB      |      32.0 |    13.2
 Transaction | 182952 |      24.0 | 6261 kB    |      12.9 |     0.0
 Heap2       |   2814 |       0.4 | 2090 kB    |       4.3 |    31.9
 XLOG        |    393 |       0.1 | 2060 kB    |       4.2 |    40.3
 Standby     |    449 |       0.1 | 25 kB      |       0.1 |     0.0
 Storage     |     28 |       0.0 | 1176 bytes |       0.0 |     0.0
 CLOG        |      6 |       0.0 | 204 bytes  |       0.0 |     0.0
 Database    |      2 |       0.0 | 84 bytes   |       0.0 |     0.0
(9 rows)

[exit=0]
```

pgbench의 INSERT가 대부분이라 `Heap`(튜플), `Btree`(인덱스), `Transaction`(커밋) 순서입니다. `XLOG`는 레코드 수가 393개로 적지만 바이트의 4.2%를 차지합니다. `fpi_pct`는 그 rmgr 안의 비율이 아니라 **전체 페이지 이미지 바이트 중 그 rmgr 몫**인데([`pg_walinspect.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/contrib/pg_walinspect/pg_walinspect.c#L628-L630)), 전체 이미지의 40.3%가 `XLOG` 레코드(주로 `FPI_FOR_HINT`)에서 나왔습니다. 쓰기를 하지 않았는데 생긴 이미지가 가장 큰 몫이라는 뜻입니다. 맨 아래 `Database` 2건은 initdb가 데이터베이스를 만들 때 남긴 기록입니다. WAL이 예상보다 많이 쌓인다면 이렇게 종류별로 나눠 보는 것이 원인을 찾는 첫걸음입니다.

### 실습 8. WAL 세그먼트는 재활용된다

```bash
psql -X -c "SHOW min_wal_size" -c "SHOW max_wal_size"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
psql -X -q -c "CREATE TABLE bulk AS SELECT g AS id, repeat('w', 200) AS pad FROM generate_series(1, 400000) g"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
psql -X -At -c "SELECT pg_walfile_name(pg_current_wal_insert_lsn()) AS current_segment"
ls $PGDATA/pg_wal | grep -v -e archive_status -e summaries | tr '\n' ' '; echo
psql -X -q -c "CHECKPOINT"
psql -X -q -c "CHECKPOINT"
psql -X -c "SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir()"
ls $PGDATA/pg_wal | grep -v -e archive_status -e summaries | tr '\n' ' '; echo
```

```text
 min_wal_size 
--------------
 80MB
(1 row)

 max_wal_size 
--------------
 1GB
(1 row)

 segments | total 
----------+-------
        4 | 64 MB
(1 row)

 segments | total  
----------+--------
       10 | 160 MB
(1 row)

00000001000000000000000A
000000010000000000000001 000000010000000000000002 000000010000000000000003 000000010000000000000004 000000010000000000000005 000000010000000000000006 000000010000000000000007 000000010000000000000008 000000010000000000000009 00000001000000000000000A 
 segments | total  
----------+--------
       10 | 160 MB
(1 row)

00000001000000000000000A 00000001000000000000000B 00000001000000000000000C 00000001000000000000000D 00000001000000000000000E 00000001000000000000000F 000000010000000000000010 000000010000000000000011 000000010000000000000012 000000010000000000000013 
[exit=0]
```

- 대량 INSERT로 WAL이 늘자 세그먼트가 4개에서 10개(160MB)가 되었습니다.
- 체크포인트 뒤 파일 수는 그대로 10개인데, 이름이 `…01`-`…0A`에서 `…0A`-`…13`으로 바뀌었습니다. 다 쓴 `…01`-`…09`를 지우지 않고 **앞으로 쓸 `…0B`-`…13`으로 이름을 바꿔** 준비해 둔 것입니다.
- 이렇게 남겨 두는 양은 `min_wal_size`(80MB)와 최근 WAL 사용량으로 정하고, 체크포인트 사이의 WAL은 대략 `max_wal_size`(1GB)를 넘지 않도록 체크포인트를 앞당깁니다([8편](/posts/postgresql/08-checkpoint-and-recovery/)).

## 운영에서는 이렇게 나타납니다

### 체크포인트 직후 WAL이 치솟는다

실습 3, 4에서 본 것처럼, 체크포인트 직후에는 모든 페이지가 "처음 고치는 페이지"라 페이지 이미지가 쏟아집니다. 쓰기가 많은 시스템에서 체크포인트마다 WAL 생성량이 톱니 모양으로 치솟는 것이 이 때문입니다. 체크포인트 간격(`checkpoint_timeout`, `max_wal_size`)을 늘리면 이미지가 덜 생기고, `wal_compression`을 켜면 크기가 줄어듭니다. 대신 체크포인트 간격이 길수록 장애 복구 시간은 길어집니다([8편](/posts/postgresql/08-checkpoint-and-recovery/)).

### 읽기만 하는데 WAL이 생긴다

대량 적재 직후나 복구 직후에 SELECT만 도는데 WAL이 계속 생긴다면, 실습 5의 hint bit 이미지(`FPI_FOR_HINT`)일 가능성이 큽니다. PG18에서 새로 만든 클러스터는 체크섬이 기본으로 켜져 있으므로 이 현상이 전보다 흔할 수 있습니다. 대량 적재 뒤 `VACUUM`을 한 번 돌려 두면 hint bit와 페이지 정리를 한꺼번에 끝낼 수 있습니다. standby가 있다면 이 WAL이 그대로 복제 트래픽이 된다는 점도 기억해 둘 만합니다.

### synchronous_commit은 트랜잭션 단위로 고를 수 있다

`synchronous_commit`은 세션이나 트랜잭션 단위로 바꿀 수 있습니다. 로그, 통계 수집처럼 마지막 몇 건을 잃어도 괜찮은 쓰기에만 `SET LOCAL synchronous_commit = off`를 쓰면, 중요한 트랜잭션의 안전성은 그대로 두고 전체 처리량을 높일 수 있습니다. 반대로 `fsync = off`는 커밋 손실이 아니라 **데이터 손상**을 일으킬 수 있으므로 운영 환경에서는 절대 쓰면 안 됩니다.

### WAL 디렉터리가 가득 차면 서버가 멈춘다

WAL을 쓸 자리가 없으면 PostgreSQL은 PANIC으로 멈춥니다. 보통은 체크포인트가 오래된 세그먼트를 재활용하므로 `max_wal_size`(soft limit) 이하로 유지되지만, **아카이빙이 실패하거나(`archive_command`), replication slot이 오래된 WAL을 붙잡거나([9편](/posts/postgresql/09-streaming-replication/)), `wal_keep_size`가 크면** 지울 수 없는 WAL이 계속 쌓입니다. 커밋된 트랜잭션을 잃지는 않지만, 공간을 비울 때까지 서버를 다시 켤 수 없습니다([Continuous Archiving](https://www.postgresql.org/docs/18/continuous-archiving.html#BACKUP-ARCHIVING-WAL)). `pg_wal` 디렉터리의 크기와 `pg_stat_archiver`의 `failed_count`를 모니터링해야 합니다.

## 정리

- **WAL**은 데이터 파일보다 먼저 쓰는 변경 기록이고, **LSN**은 그 안의 위치입니다. WAL은 16MB 세그먼트 파일로 나뉘고, 파일 이름은 타임라인과 세그먼트 번호입니다.
- WAL 레코드는 **고정 헤더 → 블록 헤더들 → 블록 데이터 → main data** 구조이고, resource manager별로 종류가 나뉩니다.
- 체크포인트 뒤 페이지를 처음 고칠 때는 torn page에 대비해 **페이지 전체 이미지(FPW)**를 함께 남기고, 이것이 WAL의 대부분을 차지할 수 있습니다. 체크섬이 켜져 있으면 hint bit 변경도 이미지를 남깁니다.
- 커밋은 커밋 레코드까지 WAL이 **디스크에 flush될 때까지** 기다립니다. `synchronous_commit = off`는 이 대기를 없애는 대신 마지막 커밋 몇 건을 잃을 수 있습니다.
- 다 쓴 세그먼트는 지우지 않고 이름을 바꿔 재활용합니다.

다음 글에서는 WAL이 실제로 쓰이는 순간, **체크포인트와 장애 복구 과정**을 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/include/access/xlogrecord.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xlogrecord.h): WAL 레코드 구조
- [src/backend/access/transam/xloginsert.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xloginsert.c): 레코드 조립, full page image 판단
- [src/backend/access/transam/xlog.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c): WAL 삽입, flush
- [src/backend/access/transam/README](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/README): WAL 설계 설명
- [src/include/access/rmgrlist.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/rmgrlist.h): resource manager 목록

PostgreSQL 18 공식 문서

- [Write-Ahead Logging (WAL)](https://www.postgresql.org/docs/18/wal-intro.html)
- [WAL Internals](https://www.postgresql.org/docs/18/wal-internals.html)
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html)
- [WAL 설정](https://www.postgresql.org/docs/18/runtime-config-wal.html)
- [pg_walinspect](https://www.postgresql.org/docs/18/pgwalinspect.html), [pg_waldump](https://www.postgresql.org/docs/18/pgwaldump.html)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-07-wal/lab.sh), [final-run.log](/labs/pg-07-wal/final-run.log)
