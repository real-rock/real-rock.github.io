---
title: "PostgreSQL 인터널 2: 메모리 구조"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "메모리", "shared_buffers", "work_mem"]
weight: 2
summary: "shared buffers, work_mem, WAL buffers는 어디에 어떻게 쓰이는가"
description: "shared buffers, work_mem, WAL buffers"
---

## 개요

[1편](/posts/postgresql/01-process-architecture/)에서 PostgreSQL이 프로세스 여러 개로 동작하고, 그 프로세스들이 **공유 메모리**라는 작업대를 함께 쓴다는 것을 봤습니다. 이번 글은 그 작업대 위에 무엇이 놓여 있는지, 그리고 backend 프로세스가 **자기만 쓰는 메모리**에는 무엇이 있는지를 살펴봅니다.

이 글에서 답할 질문은 다음과 같습니다.

- shared buffers는 어떤 구조이고, 꽉 차면 어떤 페이지를 내보내는가
- 큰 테이블을 한 번 훑으면 캐시가 다 밀려나지 않을까
- `work_mem`은 무엇에 쓰이고, 넘치면 어떻게 되는가
- WAL buffers는 왜 따로 있는가

| 메모리 | 위치 | 기본값 | 쓰임 |
|---|---|---|---|
| `shared_buffers` | 공유 | 128MB | 테이블과 인덱스 페이지 캐시 |
| `wal_buffers` | 공유 | shared_buffers의 1/32 (최대 16MB) | 디스크에 쓰기 전의 WAL 레코드 |
| `work_mem` | backend 개인 | 4MB | 정렬, 해시 테이블 하나당 사용량 |
| `hash_mem_multiplier` | backend 개인 | 2.0 | 해시 테이블은 `work_mem`의 몇 배까지 쓸지 |
| `maintenance_work_mem` | backend 개인 | 64MB | VACUUM, CREATE INDEX 같은 유지보수 작업 |
| `temp_buffers` | backend 개인 | 8MB | 임시 테이블 전용 페이지 캐시 |

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 한눈에 보기

{{< diagram src="/diagrams/pg-memory-architecture.html" title="PostgreSQL 18 메모리 구조" height="620" caption="PostgreSQL 18 메모리 구조. 가운데가 모든 프로세스가 함께 쓰는 공유 메모리, 왼쪽이 backend마다 따로 있는 개인 메모리입니다." >}}

PostgreSQL의 메모리는 크게 두 종류입니다.

- **공유 메모리**: postmaster가 기동할 때 한 번 만들고 모든 프로세스가 같이 씁니다. 이 메인 영역은 크기가 고정이라 운영 중에는 늘거나 줄지 않습니다(병렬 쿼리처럼 필요할 때만 잡는 동적 공유 메모리는 따로 있습니다). 기본 설정에서 약 150MB이고, 그 대부분이 shared buffers(128MB)입니다.
- **backend 개인 메모리**: 각 backend가 필요할 때 운영체제에서 받아 쓰고, 쿼리나 세션이 끝나면 돌려줍니다. `work_mem`, `temp_buffers`처럼 "한도"를 정하는 설정만 있고, 실제 사용량은 하는 일에 따라 달라집니다.

### shared buffers: 테이블 페이지를 담는 캐시

PostgreSQL은 테이블과 인덱스를 **8kB 페이지** 단위로 읽고 씁니다(`block_size = 8192`). 디스크에서 읽은 페이지는 shared buffers의 한 칸(버퍼)에 올라가고, 다른 backend도 같은 페이지가 필요하면 디스크 대신 이 칸을 읽습니다. 기본값 128MB는 8kB 칸 16384개입니다.

shared buffers는 세 부분으로 이루어져 있습니다.

1. **Buffer Blocks**: 8kB 칸 16384개가 이어진 큰 배열. 실제 페이지 내용이 여기 들어갑니다.
2. **Buffer Descriptors**: 칸마다 하나씩 있는 관리 정보([`BufferDesc`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L258-L271)). CPU 캐시 라인에 맞춰 [64바이트로 채워](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L293-L299) 둡니다. 이 칸에 어느 파일의 몇 번째 블록이 들어 있는지를 나타내는 태그([`BufferTag`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L106-L113): 테이블스페이스, DB, 파일 번호, fork, 블록 번호)와 상태 값을 담습니다.
3. **버퍼 매핑 해시 테이블**: "이 블록이 몇 번 칸에 있나"를 찾는 해시 테이블([`BufTableLookup()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/buf_table.c#L90)).

descriptor의 상태 값은 32비트 정수 하나에 여러 정보를 담아 둡니다([`buf_internals.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L32-L46)). 락 없이 원자적 연산 한 번으로 바꿀 수 있게 하려는 설계입니다.

| 비트 | 이름 | 뜻 |
|---|---|---|
| 18비트 | refcount (pin 수) | 지금 이 칸을 쓰고 있는 프로세스 수. 0이 아니면 내보낼 수 없습니다. |
| 4비트 | usage count | 최근에 얼마나 자주 쓰였는지. 0에서 [5](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L87)까지 올라갑니다. |
| 10비트 | 플래그 | [`BM_DIRTY`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h#L68-L78)(디스크보다 새 내용), `BM_VALID`, `BM_IO_IN_PROGRESS` 등 |

### 페이지 하나를 읽는 과정

backend가 어떤 블록을 읽으려 할 때의 흐름입니다.

{{< diagram src="/diagrams/pg-buffer-read.html" title="backend가 페이지 하나를 읽는 과정" height="540" caption="캐시에 있으면(hit) pin하고 바로 쓰고, 없으면(miss) 비울 칸을 골라 디스크에서 읽어 옵니다." >}}

**hit.** 매핑 해시에서 블록을 찾으면 그 칸을 pin(refcount +1)하고 usage count를 1 올립니다. 이미 5면 그대로 둡니다([`PinBuffer()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L3110-L3131)). 디스크 I/O가 전혀 없습니다.

**miss.** 없으면 새 페이지를 담을 칸을 구해야 합니다([`StrategyGetBuffer()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/freelist.c#L196)). 아래에서 볼 ring buffer를 쓰는 중이면 ring에서 먼저 고르고, 아직 한 번도 쓰지 않은 칸의 목록(freelist)에 남은 칸이 있으면 그 칸을 씁니다. 둘 다 없을 때 **clock sweep**을 돌립니다([`freelist.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/freelist.c#L314-L350)). 서버를 띄운 직후에는 빈 칸이 많아 대부분 freelist에서 해결되고, clock sweep은 캐시가 가득 찬 뒤에 본격적으로 일합니다.

1. 시계 바늘처럼 칸을 하나씩 돌아가며 봅니다.
2. pin된 칸은 건너뜁니다.
3. usage count가 0이 아니면 1 깎고 넘어갑니다.
4. usage count가 0인 칸을 만나면 그 칸을 씁니다.

자주 쓰이는 페이지는 usage count가 높아서 바늘이 여러 바퀴 돌아야 0이 됩니다. 그래서 오래 살아남습니다. 한 번 쓰고 만 페이지는 금방 0이 되어 먼저 밀려납니다. 정확한 LRU(가장 오래 안 쓴 것을 내보내기)는 아니지만 비슷한 효과를 냅니다. LRU처럼 hit할 때마다 전역 목록의 순서를 고칠 필요가 없어서, 여러 backend가 동시에 읽어도 락 경쟁이 적습니다.

고른 칸이 dirty(디스크보다 새 내용)면 먼저 디스크에 써야 합니다. 이때 규칙이 하나 있습니다. **그 페이지의 변경을 기록한 WAL이 먼저 디스크에 있어야 합니다**([`FlushBuffer()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L4355-L4371)가 `XLogFlush()`를 먼저 부릅니다). 이 규칙 덕분에 장애가 나도 WAL로 데이터 파일을 복구할 수 있습니다. [7편](/posts/postgresql/07-wal/)에서 다시 다룹니다.

마지막으로 칸의 태그를 새 블록으로 바꾸고 파일에서 읽어 옵니다. PG18에서 순차 스캔처럼 여러 블록을 미리 읽어 두는 경로는 [1편](/posts/postgresql/01-process-architecture/)에서 본 io worker가 대신 읽습니다. 반면 인덱스로 행 하나를 찾을 때처럼 블록 하나가 당장 필요한 경우에는, 비동기로 넘겨 봐야 기다리기만 하므로 backend가 직접 읽습니다([`bufmgr.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L1241-L1247)).

### ring buffer: 큰 테이블 스캔이 캐시를 망치지 않게

shared buffers가 128MB인데 1GB짜리 테이블을 처음부터 끝까지 한 번 읽으면 어떻게 될까요? 그대로라면 자주 쓰던 페이지까지 모두 밀려납니다. 이를 막으려고 PostgreSQL은 **테이블이 shared buffers의 1/4보다 크면**([`heapam.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/heap/heapam.c#L392-L404)) 순차 스캔에 **ring buffer**라는 작은 전용 영역만 돌려 씁니다. 스캔이 칸 몇 개만 계속 재사용하므로, 나머지 캐시는 그대로 남습니다.

ring의 크기는 작업 종류에 따라 다릅니다([`GetAccessStrategy()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/freelist.c#L541-L606)).

| 작업 | ring 크기 |
|---|---|
| 큰 테이블 순차 스캔 (`BAS_BULKREAD`) | 256kB에서 시작해 I/O 동시성만큼 늘림. 단, 'backend 하나의 pin 한도'와 256kB 중 큰 값을 넘지 않음 |
| `COPY`, `CREATE TABLE AS` 같은 대량 쓰기 (`BAS_BULKWRITE`) | 16MB |
| VACUUM (`BAS_VACUUM`) | `vacuum_buffer_usage_limit` (기본 2MB) |

PG18에서 순차 스캔의 ring 계산이 바뀌었습니다. 비동기 I/O로 여러 블록을 미리 읽어 두려면 칸이 더 필요하기 때문에, 256kB에 `io_combine_limit × effective_io_concurrency`만큼을 더합니다. 대신 backend 하나가 pin할 수 있는 칸 수([`GetPinLimit()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L2514-L2517), [`NBuffers / (MaxBackends + NUM_AUXILIARY_PROCS)`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L4042))를 넘지 못합니다. 실습 6에서 이 값을 직접 계산해 맞춰 봅니다.

또 하나, ring으로 읽은 페이지는 usage count를 [1보다 올리지 않습니다](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L3124-L3131). 한 번 훑고 지나가는 페이지가 캐시에 오래 눌러앉지 않게 하려는 것입니다.

### WAL buffers

테이블을 바꾸는 모든 작업은 WAL 레코드를 남깁니다. 레코드는 바로 디스크에 쓰지 않고 공유 메모리의 **WAL buffers**에 먼저 모읍니다. 커밋할 때, 또는 walwriter가 주기적으로 깨어날 때 디스크로 내보냅니다. 여러 트랜잭션의 WAL을 모아 한 번에 쓰면 디스크 쓰기 횟수가 줄어듭니다.

크기의 기본값은 `-1`이고, 이 경우 [`XLOGChooseNumBuffers()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L4653-L4663)가 **shared_buffers의 1/32**로 정합니다. 최소는 8페이지(64kB), 최대는 WAL 세그먼트 하나(기본 16MB)입니다. 기본 설정(shared_buffers 128MB)에서는 4MB가 됩니다.

WAL buffers가 가득 차서 빈자리가 없으면, WAL을 쓰려던 backend가 **직접** 앞쪽 WAL을 디스크에 써서 자리를 만들어야 합니다. 이 횟수가 `pg_stat_wal.wal_buffers_full`입니다.

### backend 개인 메모리: work_mem과 메모리 컨텍스트

backend는 쿼리를 처리하면서 개인 메모리를 씁니다. PostgreSQL은 이 메모리를 **메모리 컨텍스트**라는 단위로 관리합니다([`mmgr/README`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/mmgr/README#L6-L40)). 컨텍스트는 "이 쿼리를 실행하는 동안", "이 트랜잭션 동안", "세션 내내"처럼 수명별로 나뉘어 있고, 수명이 끝나면 **컨텍스트째 한 번에 해제**합니다. 메모리를 하나하나 `free()`하지 않아도 새지 않게 하는 장치입니다.

그중 가장 큰 영향을 주는 설정이 `work_mem`입니다.

- **정렬**(`ORDER BY`, `DISTINCT`, merge join 준비): 데이터가 `work_mem` 안에 들어가면 메모리에서 quicksort하고, 넘치면 정렬된 조각(run)을 임시 파일에 쓰고 나중에 병합하는 **external merge**로 바꿉니다([`tuplesort.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/sort/tuplesort.c#L9-L45)).
- **해시 테이블**(hash join, hash aggregate): [`work_mem × hash_mem_multiplier`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/nodeHash.c#L3614-L3627)까지 씁니다. 기본값으로는 4MB × 2.0 = 8MB입니다. 넘치면 데이터를 여러 batch로 나눠 임시 파일에 두고 하나씩 처리합니다.

주의할 점은 `work_mem`이 **쿼리 하나의 한도가 아니라 정렬이나 해시 노드 하나의 한도**라는 것입니다. 정렬 두 개와 해시 하나가 있는 쿼리는 `work_mem`의 몇 배를 쓸 수 있고, 그런 쿼리가 동시에 여러 개 돌면 곱절로 늘어납니다(실습 9-1).

`temp_buffers`는 임시 테이블(`CREATE TEMP TABLE`) 전용 캐시입니다. 임시 테이블은 그 세션만 보므로 공유 메모리를 쓸 이유가 없고, backend 개인 메모리의 [local buffer](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/localbuf.c#L1-L10)에 올라갑니다.

## 직접 확인해 보기

### 실습 환경

[1편](/posts/postgresql/01-process-architecture/)과 같은 소스로 만든 이미지에 도구 몇 가지를 더한 [실습 이미지](/labs/pg-lab-image/Dockerfile)를 씁니다. 실습 전체는 [lab.sh](/labs/pg-02-memory/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했고(공용 함수는 [labkit.sh](/labs/common/labkit.sh)), 원본 출력은 [final-run.log](/labs/pg-02-memory/final-run.log)에 있습니다.

- `bash` 블록은 컨테이너 안에서 postgres 사용자로 실행한 명령입니다.
- `text` 블록은 stdout과 stderr를 합친 출력을 그대로 옮긴 것이고, `[exit=N]`은 종료 코드입니다.
- 버퍼 캐시를 비우는 데는 PG18의 `pg_buffercache_evict_relation()`을 썼습니다. 서버를 재시작하지 않고 특정 테이블의 페이지만 shared buffers에서 내보냅니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
122a918323ad4e53b3b4e5700996f2c3664a92f539b385d6fff8116219b0b13a
[exit=0]
```

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_buffercache"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. 메모리 관련 기본 설정

```bash
psql -X <<'SQL'
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN ('shared_buffers', 'wal_buffers', 'work_mem', 'hash_mem_multiplier',
               'maintenance_work_mem', 'temp_buffers', 'block_size', 'shared_memory_size')
ORDER BY name;
SQL
```

```text
         name         | setting | unit |                                       short_desc                                       
----------------------+---------+------+----------------------------------------------------------------------------------------
 block_size           | 8192    |      | Shows the size of a disk block.
 hash_mem_multiplier  | 2       |      | Multiple of "work_mem" to use for hash tables.
 maintenance_work_mem | 65536   | kB   | Sets the maximum memory to be used for maintenance operations.
 shared_buffers       | 16384   | 8kB  | Sets the number of shared memory buffers used by the server.
 shared_memory_size   | 150     | MB   | Shows the size of the server's main shared memory area (rounded up to the nearest MB).
 temp_buffers         | 1024    | 8kB  | Sets the maximum number of temporary buffers used by each session.
 wal_buffers          | 512     | 8kB  | Sets the number of disk-page buffers in shared memory for WAL.
 work_mem             | 4096    | kB   | Sets the maximum memory to be used for query workspaces.
(8 rows)

[exit=0]
```

`shared_buffers`와 `wal_buffers`, `temp_buffers`의 단위는 8kB 페이지입니다. shared_buffers 16384 × 8kB = 128MB, wal_buffers 512 × 8kB = 4MB(128MB의 1/32), temp_buffers 1024 × 8kB = 8MB입니다.

### 실습 2. 공유 메모리는 무엇으로 채워져 있나

`pg_shmem_allocations`는 공유 메모리를 이름별로 얼마나 잡았는지 보여 줍니다.

```bash
psql -X <<'SQL'
SELECT name, pg_size_pretty(allocated_size) AS size
FROM pg_shmem_allocations
ORDER BY allocated_size DESC
LIMIT 10;
SELECT count(*) AS entries, pg_size_pretty(sum(allocated_size)) AS total
FROM pg_shmem_allocations;
SQL
```

```text
        name        |  size   
--------------------+---------
 Buffer Blocks      | 128 MB
 <anonymous>        | 4637 kB
 XLOG Ctl           | 4110 kB
 AioHandleIOV       | 2784 kB
                    | 2222 kB
 AioHandle          | 1566 kB
 AioHandleData      | 1392 kB
 Buffer Descriptors | 1024 kB
 transaction        | 517 kB
 Checkpointer Data  | 512 kB
(10 rows)

 entries | total  
---------+--------
      73 | 150 MB
(1 row)

[exit=0]
```

150MB 가운데 128MB가 `Buffer Blocks`(페이지 칸들)이고, `Buffer Descriptors`가 정확히 1MB입니다. descriptor 하나가 64바이트이므로 16384 × 64B = 1MB입니다. `XLOG Ctl`(4110kB)은 WAL buffers(4MB)에 WAL 관리 구조를 더한 영역입니다. `AioHandle*`로 시작하는 항목들은 PG18의 비동기 I/O가 쓰는 공간입니다. 이름이 빈 줄은 아직 쓰지 않은 여유 공간이고, `<anonymous>`는 이름을 붙이지 않고 잡은 영역들의 합입니다.

### 실습 3. 테이블을 읽으면 shared buffers에 페이지가 올라온다

14MB(1728페이지) 테이블을 만들고, 이 테이블의 페이지를 캐시에서 내보낸 뒤 한 번 읽어 봅니다.

```bash
psql -X <<'SQL'
CREATE TABLE small AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 100000) g;
SELECT pg_size_pretty(pg_relation_size('small')) AS size, pg_relation_size('small') / 8192 AS pages;
SELECT pg_buffercache_evict_relation('small');
SELECT * FROM pg_buffercache_summary();
SELECT count(*) FROM small;
SELECT * FROM pg_buffercache_summary();
SELECT count(*) AS buffers_of_small
FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small');
SQL
```

```text
SELECT 100000
 size  | pages 
-------+-------
 14 MB |  1728
(1 row)

 pg_buffercache_evict_relation 
-------------------------------
 (1728,1725,0)
(1 row)

 buffers_used | buffers_unused | buffers_dirty | buffers_pinned |  usagecount_avg   
--------------+----------------+---------------+----------------+-------------------
          300 |          16084 |            64 |              0 | 3.183333333333333
(1 row)

 count  
--------
 100000
(1 row)

 buffers_used | buffers_unused | buffers_dirty | buffers_pinned |   usagecount_avg   
--------------+----------------+---------------+----------------+--------------------
         2034 |          14350 |          1789 |              0 | 1.3421828908554572
(1 row)

 buffers_of_small 
------------------
             1728
(1 row)

[exit=0]
```

- `pg_buffercache_evict_relation`의 결과 `(1728,1725,0)`은 (내보낸 칸, 그중 먼저 디스크에 쓴 칸, 건너뛴 칸)입니다. 방금 만든 테이블이라 대부분 dirty여서 쓰고 나서 내보냈습니다.
- 테이블을 한 번 읽자 이 테이블의 페이지 1728개가 모두 shared buffers에 올라왔습니다(`buffers_of_small`).
- 읽기만 했는데 `buffers_dirty`가 64에서 1789로 늘었습니다. 새로 만든 행을 처음 읽을 때 PostgreSQL이 "이 행을 만든 트랜잭션은 커밋되었다"는 표시(hint bit)를 페이지에 적어 두기 때문입니다. [4편](/posts/postgresql/04-mvcc/)(MVCC)에서 자세히 다룹니다.

### 실습 4. 처음 읽으면 read, 다시 읽으면 hit

PG18부터는 `EXPLAIN ANALYZE`가 `BUFFERS`를 기본으로 보여 줍니다([`explain_state.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/explain_state.c#L180)).

```bash
psql -X <<'SQL'
SELECT pg_buffercache_evict_relation('small');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
SQL
```

```text
 pg_buffercache_evict_relation 
-------------------------------
 (1728,1725,0)
(1 row)

                                 QUERY PLAN                                  
-----------------------------------------------------------------------------
 Finalize Aggregate (actual rows=1.00 loops=1)
   Buffers: shared read=1728
   ->  Gather (actual rows=2.00 loops=1)
         Workers Planned: 1
         Workers Launched: 1
         Buffers: shared read=1728
         ->  Partial Aggregate (actual rows=1.00 loops=2)
               Buffers: shared read=1728
               ->  Parallel Seq Scan on small (actual rows=50000.00 loops=2)
                     Buffers: shared read=1728
 Planning:
   Buffers: shared hit=27
(12 rows)

                                 QUERY PLAN                                  
-----------------------------------------------------------------------------
 Finalize Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=1728
   ->  Gather (actual rows=2.00 loops=1)
         Workers Planned: 1
         Workers Launched: 1
         Buffers: shared hit=1728
         ->  Partial Aggregate (actual rows=1.00 loops=2)
               Buffers: shared hit=1728
               ->  Parallel Seq Scan on small (actual rows=50000.00 loops=2)
                     Buffers: shared hit=1728
(10 rows)

[exit=0]
```

같은 쿼리인데 첫 번째는 `shared read=1728`, 두 번째는 `shared hit=1728`입니다. read는 shared buffers에 없어서 파일에서 읽어 온 페이지 수, hit는 shared buffers에서 바로 찾은 페이지 수입니다.

### 실습 4-1. read는 디스크에서 읽었을까, 운영체제 캐시에서 읽었을까

```bash
psql -X <<'SQL'
SET track_io_timing = on;
SET max_parallel_workers_per_gather = 0;
SELECT pg_buffercache_evict_relation('small');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM small;
SQL
grep -E '^(MemTotal|Cached):' /proc/meminfo
```

```text
SET
SET
 pg_buffercache_evict_relation 
-------------------------------
 (1728,0,0)
(1 row)

                       QUERY PLAN                        
---------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared read=1728
   I/O Timings: shared read=0.267
   ->  Seq Scan on small (actual rows=100000.00 loops=1)
         Buffers: shared read=1728
         I/O Timings: shared read=0.267
 Planning:
   Buffers: shared hit=24
(8 rows)

MemTotal:       32810480 kB
Cached:          2181352 kB
[exit=0]
```

1728페이지(14MB)를 read했는데 `I/O Timings`는 0.267ms입니다. PG18에서 이 값은 **backend가 읽기를 요청하는 데 쓴 시간과 완료를 기다린 시간의 합**입니다([요청](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L1953-L1967), [대기](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L1691-L1713)). io worker가 미리 읽어 두면 기다리는 시간이 줄어드니, 파일을 읽는 데 실제로 걸린 시간과는 다릅니다. 그래도 14MB에 0.267ms라면 실제 디스크를 거쳤다고 보기는 어렵습니다. 방금 만든 파일이라 **운영체제의 페이지 캐시**(`Cached` 약 2GB)에 남아 있었을 가능성이 큽니다.

PostgreSQL은 파일을 운영체제를 통해 읽습니다(direct I/O를 쓰지 않는 기본 설정). 그래서 같은 페이지가 shared buffers와 운영체제 페이지 캐시에 **두 번** 캐시될 수 있습니다. PostgreSQL 입장의 "read"가 곧 느린 디스크 읽기는 아니라는 점을 기억해 두면 됩니다.

### 실습 5. usage count: 자주 읽는 페이지일수록 오래 살아남는다

```bash
psql -X <<'SQL'
SELECT pg_buffercache_evict_relation('small');
SELECT count(*) FROM small;
SELECT usagecount, count(*) FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small') GROUP BY 1 ORDER BY 1;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT count(*) FROM small;
SELECT usagecount, count(*) FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('small') GROUP BY 1 ORDER BY 1;
SQL
```

```text
 pg_buffercache_evict_relation 
-------------------------------
 (1728,0,0)
(1 row)

 count  
--------
 100000
(1 row)

 usagecount | count 
------------+-------
          1 |  1728
(1 row)

 count  
--------
 100000
(1 row)

 count  
--------
 100000
(1 row)

 count  
--------
 100000
(1 row)

 count  
--------
 100000
(1 row)

 count  
--------
 100000
(1 row)

 usagecount | count 
------------+-------
          5 |  1728
(1 row)

[exit=0]
```

캐시에 처음 올라온 페이지는 usage count가 1입니다. 그 뒤로 다섯 번 더 읽었으니 제한이 없다면 6이어야 하지만, 5에서 멈췄습니다. 최댓값 `BM_MAX_USAGE_COUNT = 5` 그대로입니다. clock sweep의 바늘이 이 칸들을 내보내려면 다섯 바퀴를 더 돌아야 합니다.

### 실습 6. 큰 테이블 순차 스캔은 ring buffer만 쓴다

81MB(10368페이지)짜리 테이블을 만듭니다. shared buffers의 1/4인 4096페이지보다 크므로 ring buffer 대상입니다.

```bash
psql -X <<'SQL'
CREATE TABLE big AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 600000) g;
SELECT pg_size_pretty(pg_relation_size('big')) AS size,
       pg_relation_size('big') / 8192 AS pages,
       current_setting('shared_buffers') AS shared_buffers,
       (SELECT setting::int FROM pg_settings WHERE name = 'shared_buffers') / 4 AS bulkread_threshold_pages;
SELECT pg_buffercache_evict_relation('big');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM big;
SELECT count(*) AS buffers_of_big
FROM pg_buffercache
WHERE relfilenode = pg_relation_filenode('big');
SQL
```

```text
SELECT 600000
 size  | pages | shared_buffers | bulkread_threshold_pages 
-------+-------+----------------+--------------------------
 81 MB | 10368 | 128MB          |                     4096
(1 row)

 pg_buffercache_evict_relation 
-------------------------------
 (2048,2025,0)
(1 row)

                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Finalize Aggregate (actual rows=1.00 loops=1)
   Buffers: shared read=10368 dirtied=10345 written=10086
   ->  Gather (actual rows=3.00 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         Buffers: shared read=10368 dirtied=10345 written=10086
         ->  Partial Aggregate (actual rows=1.00 loops=3)
               Buffers: shared read=10368 dirtied=10345 written=10086
               ->  Parallel Seq Scan on big (actual rows=200000.00 loops=3)
                     Buffers: shared read=10368 dirtied=10345 written=10086
 Planning:
   Buffers: shared hit=12
(12 rows)

 buffers_of_big 
----------------
            282
(1 row)

[exit=0]
```

테이블 전체(10368페이지)를 읽었는데 끝나고 남은 이 테이블의 페이지는 **282개**뿐입니다. 이 숫자를 소스로 계산해 보겠습니다.

```bash
psql -X <<'SQL'
SELECT current_setting('max_connections')::int
     + current_setting('autovacuum_worker_slots')::int
     + current_setting('max_worker_processes')::int
     + current_setting('max_wal_senders')::int + 2 AS max_backends,
       (SELECT setting::int FROM pg_settings WHERE name = 'shared_buffers')
       / (current_setting('max_connections')::int
          + current_setting('autovacuum_worker_slots')::int
          + current_setting('max_worker_processes')::int
          + current_setting('max_wal_senders')::int + 2 + 38) AS pin_limit_buffers;
SHOW io_combine_limit;
SHOW effective_io_concurrency;
SQL
```

```text
 max_backends | pin_limit_buffers 
--------------+-------------------
          136 |                94
(1 row)

 io_combine_limit 
------------------
 128kB
(1 row)

 effective_io_concurrency 
--------------------------
 16
(1 row)

[exit=0]
```

- ring의 최대 크기는 backend 하나가 pin할 수 있는 칸 수입니다. `16384 / (136 + 38)` = **94칸**입니다. 136은 `MaxBackends`(max_connections + autovacuum_worker_slots + max_worker_processes + max_wal_senders + 2. 마지막 2는 autovacuum launcher와 slotsync worker 몫인 [`NUM_SPECIAL_WORKER_PROCS`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/proc.h#L442-L448), [`postinit.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/postinit.c#L560-L561)), 38은 보조 프로세스 수([`NUM_AUXILIARY_PROCS`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/proc.h#L460-L461) = 6 + io worker 최대 32)입니다.
- PG18의 원래 계산은 256kB + 8kB × 16(`io_combine_limit` 128kB = 16블록) × 16(`effective_io_concurrency`) = 2304kB(288칸)이지만, 94칸 한도에 걸려 94칸이 됩니다.
- 실행 계획을 보면 이 스캔은 leader와 worker 2개, 모두 3개 프로세스가 나눠 맡았습니다(`Workers Launched: 2`). 프로세스마다 ring을 따로 두므로 94 × 3 = **282칸**입니다. 측정값과 정확히 같습니다. 같은 실행 계획의 `written=10086`도 10368에서 ring에 마지막까지 남은 282칸을 뺀 값이라, 계산이 서로 맞아떨어집니다.

`Buffers: shared read=10368 dirtied=10345 written=10086`도 눈여겨볼 만합니다. 실습 3과 같은 이유(처음 읽을 때 hint bit를 적음)로 읽은 페이지가 dirty가 되었고, ring의 칸을 다시 쓰려면 dirty 페이지를 먼저 디스크에 써야 해서 **읽기 쿼리가 약 10000페이지를 썼습니다.** 대량 적재 직후의 첫 SELECT가 유난히 느린 이유 중 하나입니다.

### 실습 7. 수정된 페이지(dirty)는 체크포인트가 디스크로 내보낸다

```bash
psql -X <<'SQL'
CHECKPOINT;
SELECT buffers_dirty FROM pg_buffercache_summary();
UPDATE small SET pad = repeat('y', 100) WHERE id % 10 = 0;
SELECT buffers_dirty FROM pg_buffercache_summary();
SELECT count(*) FILTER (WHERE isdirty) AS dirty_of_small
FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('small');
SELECT buffers_written FROM pg_stat_checkpointer;
CHECKPOINT;
SELECT buffers_dirty FROM pg_buffercache_summary();
SELECT buffers_written FROM pg_stat_checkpointer;
SQL
```

```text
CHECKPOINT
 buffers_dirty 
---------------
             0
(1 row)

UPDATE 10000
 buffers_dirty 
---------------
          1899
(1 row)

 dirty_of_small 
----------------
           1899
(1 row)

 buffers_written 
-----------------
             328
(1 row)

CHECKPOINT
 buffers_dirty 
---------------
             0
(1 row)

 buffers_written 
-----------------
            2227
(1 row)

[exit=0]
```

UPDATE로 이 테이블의 칸 1899개가 dirty가 되었습니다. 테이블 페이지(1728)보다 많은 이유는 UPDATE가 새 버전의 행을 쓰느라 테이블 끝에 페이지를 더 붙였기 때문입니다([4편](/posts/postgresql/04-mvcc/)). 빈 공간 지도(FSM, [5편](/posts/postgresql/05-vacuum/)) 같은 부가 파일의 페이지 몇 칸도 여기에 함께 잡힙니다. 이 상태에서는 디스크의 파일이 아직 옛 내용이고, 최신 내용은 메모리와 WAL에만 있습니다. `CHECKPOINT` 뒤에는 dirty가 0이 되었고, checkpointer가 쓴 버퍼 수가 328에서 2227로 정확히 1899 늘었습니다.

### 실습 8. work_mem을 넘는 정렬은 임시 파일로 간다

```bash
psql -X <<'SQL'
SET log_temp_files = 0;
SET work_mem = '4MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM big ORDER BY pad, id DESC;
SET work_mem = '256MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM big ORDER BY pad, id DESC;
SQL
grep 'temporary file' /home/postgres/server.log | tail -3
```

```text
SET
SET
                             QUERY PLAN                              
---------------------------------------------------------------------
 Sort (actual rows=600000.00 loops=1)
   Sort Key: pad, id DESC
   Sort Method: external merge  Disk: 67576kB
   Buffers: shared hit=288 read=10086, temp read=16888 written=16910
   ->  Seq Scan on big (actual rows=600000.00 loops=1)
         Buffers: shared hit=282 read=10086
 Planning:
   Buffers: shared hit=49
(8 rows)

SET
                      QUERY PLAN                       
-------------------------------------------------------
 Sort (actual rows=600000.00 loops=1)
   Sort Key: pad, id DESC
   Sort Method: quicksort  Memory: 99577kB
   Buffers: shared hit=376 read=9992
   ->  Seq Scan on big (actual rows=600000.00 loops=1)
         Buffers: shared hit=376 read=9992
(6 rows)

2026-09-24 03:09:26.736 UTC [140] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp140.0", size 69197824
[exit=0]
```

같은 정렬인데 `work_mem`이 4MB일 때는 `external merge  Disk: 67576kB`, 즉 약 66MB를 임시 파일에 쓰고 병합했습니다. 서버 로그에도 `temporary file: ... size 69197824`가 남았습니다(`log_temp_files = 0`은 모든 임시 파일을 로그에 남기라는 뜻입니다). 256MB로 올리자 `quicksort  Memory: 99577kB`, 즉 약 97MB를 메모리에서 정렬했습니다. 디스크에 쓴 크기(66MB)보다 메모리에서 쓴 크기(97MB)가 큰 이유는 메모리 안에서는 행마다 포인터와 관리 정보가 붙기 때문입니다.

### 실습 9. 해시 테이블은 work_mem × hash_mem_multiplier까지 쓴다

```bash
psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
SET enable_mergejoin = off;
SET work_mem = '1MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SET work_mem = '64MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SQL
```

```text
SET
SET
SET
                                QUERY PLAN                                
--------------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=1037 read=19699, temp read=3526 written=3526
   ->  Hash Join (actual rows=600000.00 loops=1)
         Hash Cond: (b1.id = b2.id)
         Buffers: shared hit=1037 read=19699, temp read=3526 written=3526
         ->  Seq Scan on big b1 (actual rows=600000.00 loops=1)
               Buffers: shared hit=564 read=9804
         ->  Hash (actual rows=600000.00 loops=1)
               Buckets: 65536  Batches: 64  Memory Usage: 840kB
               Buffers: shared hit=473 read=9895, temp written=1700
               ->  Seq Scan on big b2 (actual rows=600000.00 loops=1)
                     Buffers: shared hit=473 read=9895
 Planning:
   Buffers: shared hit=130 read=3
(14 rows)

SET
                              QUERY PLAN                              
----------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=1413 read=19323
   ->  Hash Join (actual rows=600000.00 loops=1)
         Hash Cond: (b1.id = b2.id)
         Buffers: shared hit=1413 read=19323
         ->  Seq Scan on big b1 (actual rows=600000.00 loops=1)
               Buffers: shared hit=752 read=9616
         ->  Hash (actual rows=600000.00 loops=1)
               Buckets: 2097152  Batches: 1  Memory Usage: 37478kB
               Buffers: shared hit=661 read=9707
               ->  Seq Scan on big b2 (actual rows=600000.00 loops=1)
                     Buffers: shared hit=661 read=9707
(12 rows)

[exit=0]
```

`work_mem = 1MB`에서는 해시 테이블 한도가 2MB(× 2.0)라 60만 행이 들어가지 않습니다. 그래서 데이터를 **64개 batch**로 나눠 임시 파일에 두고 하나씩 처리했습니다(`temp read=3526 written=3526`). 64MB로 올리자 `Batches: 1`, 메모리 37MB 안에서 한 번에 처리했고 임시 파일 I/O가 사라졌습니다.

### 실습 9-1. work_mem은 쿼리 하나가 아니라 노드마다 잡힌다

hash join을 끄고 같은 조인을 merge join으로 실행하면, 양쪽 입력을 각각 정렬합니다.

```bash
psql -X <<'SQL'
SET max_parallel_workers_per_gather = 0;
SET enable_hashjoin = off;
SET work_mem = '32MB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM big b1 JOIN big b2 USING (id);
SQL
```

```text
SET
SET
SET
                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared hit=1790 read=18950
   ->  Merge Join (actual rows=600000.00 loops=1)
         Merge Cond: (b1.id = b2.id)
         Buffers: shared hit=1790 read=18950
         ->  Sort (actual rows=600000.00 loops=1)
               Sort Key: b1.id
               Sort Method: quicksort  Memory: 24577kB
               Buffers: shared hit=850 read=9522
               ->  Seq Scan on big b1 (actual rows=600000.00 loops=1)
                     Buffers: shared hit=846 read=9522
         ->  Materialize (actual rows=600000.00 loops=1)
               Storage: Memory  Maximum Storage: 17kB
               Buffers: shared hit=940 read=9428
               ->  Sort (actual rows=600000.00 loops=1)
                     Sort Key: b2.id
                     Sort Method: quicksort  Memory: 24577kB
                     Buffers: shared hit=940 read=9428
                     ->  Seq Scan on big b2 (actual rows=600000.00 loops=1)
                           Buffers: shared hit=940 read=9428
 Planning:
   Buffers: shared hit=139
(22 rows)

[exit=0]
```

`work_mem`을 32MB로 두었습니다. 정렬 노드가 두 개이고 각각 `Memory: 24577kB`(약 24MB)를 썼습니다. 정렬 하나하나는 한도(32MB) 안이지만, 쿼리 하나로 보면 **약 48MB**로 `work_mem`보다 많이 썼습니다. 한도는 노드마다 따로 적용되므로, 정렬이나 해시가 더 많은 쿼리라면 `work_mem`의 몇 배까지 갈 수 있습니다.

### 실습 10. backend 개인 메모리: 메모리 컨텍스트

```bash
psql -X <<'SQL'
SELECT name, level, pg_size_pretty(total_bytes) AS total, pg_size_pretty(used_bytes) AS used
FROM pg_backend_memory_contexts
ORDER BY total_bytes DESC
LIMIT 8;
SELECT count(*) AS contexts, pg_size_pretty(sum(total_bytes)) AS total
FROM pg_backend_memory_contexts;
SQL
```

```text
          name           | level | total  |   used    
-------------------------+-------+--------+-----------
 CacheMemoryContext      |     2 | 512 kB | 449 kB
 Timezones               |     2 | 102 kB | 99 kB
 TopMemoryContext        |     1 | 97 kB  | 91 kB
 MessageContext          |     2 | 64 kB  | 32 kB
 WAL record construction |     2 | 49 kB  | 42 kB
 ExecutorState           |     4 | 48 kB  | 39 kB
 TupleSort main          |     5 | 32 kB  | 25 kB
 TransactionAbortContext |     2 | 32 kB  | 240 bytes
(8 rows)

 contexts |  total  
----------+---------
      124 | 1495 kB
(1 row)

[exit=0]
```

이 쿼리를 실행한 backend에는 메모리 컨텍스트가 124개 있고 모두 합쳐 약 1.5MB입니다. 가장 큰 `CacheMemoryContext`(512kB)는 테이블 정의, 함수 정보 같은 카탈로그 캐시입니다. 세션이 여러 테이블을 건드릴수록 커지고 세션이 끝날 때까지 유지됩니다. `ExecutorState`와 `TupleSort main`은 지금 실행 중인 바로 이 쿼리(ORDER BY가 있음)의 실행 상태와 정렬용 메모리로, 쿼리가 끝나면 컨텍스트째 해제됩니다.

### 실습 11. 임시 테이블은 temp_buffers를 쓴다

```bash
psql -X <<'SQL'
CREATE TEMP TABLE tmp AS SELECT g AS id FROM generate_series(1, 100000) g;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM tmp;
SELECT count(*) AS shared_buffers_used_by_tmp
FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('tmp');
SQL
```

```text
SELECT 100000
                      QUERY PLAN                       
-------------------------------------------------------
 Aggregate (actual rows=1.00 loops=1)
   Buffers: local hit=448
   ->  Seq Scan on tmp (actual rows=100000.00 loops=1)
         Buffers: local hit=448
 Planning:
   Buffers: shared hit=22
(6 rows)

 shared_buffers_used_by_tmp 
----------------------------
                          0
(1 row)

[exit=0]
```

`Buffers: local hit=448`로, 임시 테이블 페이지는 shared가 아니라 **local** 버퍼에서 읽었습니다. shared buffers에서 이 테이블의 페이지를 찾아보면 0개입니다.

### 실습 12. WAL buffers가 꽉 차면

WAL buffers 기본값(4MB)과 최소에 가까운 64kB에서 같은 대량 INSERT(약 46MB의 WAL)를 실행해 비교합니다.

```bash
psql -X -c "SHOW wal_buffers"
psql -X -q -c "SELECT pg_stat_reset_shared('wal')"
psql -X -q -c "INSERT INTO big SELECT g, repeat('z', 100) FROM generate_series(1, 300000) g"
psql -X -c "SELECT wal_records, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full FROM pg_stat_wal"
```

```text
 wal_buffers 
-------------
 4MB
(1 row)

 pg_stat_reset_shared 
----------------------
 
(1 row)

 wal_records | wal_bytes | wal_buffers_full 
-------------+-----------+------------------
      300003 | 46 MB     |             5368
(1 row)

[exit=0]
```

```bash
psql -X -q -c "ALTER SYSTEM SET wal_buffers = '64kB'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast > /dev/null
psql -X -c "SHOW wal_buffers"
psql -X -q -c "SELECT pg_stat_reset_shared('wal')"
psql -X -q -c "INSERT INTO big SELECT g, repeat('z', 100) FROM generate_series(1, 300000) g"
psql -X -c "SELECT wal_records, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full FROM pg_stat_wal"
```

```text
 wal_buffers 
-------------
 64kB
(1 row)

 pg_stat_reset_shared 
----------------------
 
(1 row)

 wal_records | wal_bytes | wal_buffers_full 
-------------+-----------+------------------
      300004 | 46 MB     |             5874
(1 row)

[exit=0]
```

두 경우 모두 `wal_buffers_full`이 5천 번대입니다(5368, 5874). 트랜잭션 하나가 46MB의 WAL을 쏟아내면 4MB든 64kB든 버퍼는 금방 차고, backend가 직접 WAL을 써서 자리를 만들어야 합니다. 이 실습에서 차이는 약 9%였습니다. WAL buffers의 크기는 대량 적재 한 건보다, **짧은 트랜잭션이 동시에 많이 커밋될 때** WAL을 모아 쓰는 효과에서 더 중요합니다. 이 실습만으로 그 효과를 보여 주지는 못했으므로, 부하 테스트는 WAL을 다루는 [7편](/posts/postgresql/07-wal/)에서 이어 가겠습니다.

## 운영에서는 이렇게 나타납니다

### shared_buffers를 무작정 키우면 안 되는 이유

shared buffers가 클수록 hit가 늘어나는 것은 맞습니다. 하지만 실습 4-1에서 본 것처럼 PostgreSQL은 운영체제 페이지 캐시 위에서 동작합니다. shared buffers를 너무 크게 잡으면 운영체제가 쓸 캐시가 줄어들고, 같은 페이지를 두 곳에 들고 있는 낭비도 커집니다. 또 shared buffers는 기동할 때 한 번에 잡는 고정 영역이라, 크게 잡을수록 기동할 때 확보할 메모리와 체크포인트 때 내보낼 dirty 페이지 양이 늘어납니다. PostgreSQL 문서는 전용 서버에서 **메모리의 25% 정도에서 시작**하고, 40%를 넘기면 이득이 적다고 안내합니다([shared_buffers](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-SHARED-BUFFERS)). 실제 값은 `pg_buffercache`와 hit 비율을 보면서 조정합니다.

### work_mem이 메모리 폭증을 부르는 경우

`work_mem`은 정렬이나 해시 노드 하나의 한도입니다(실습 9-1). 대략적인 최악의 사용량은 다음과 같습니다.

> 동시 실행 쿼리 수 × 쿼리당 정렬, 해시 노드 수 × `work_mem` (해시는 × `hash_mem_multiplier`)

`work_mem`을 전역으로 256MB로 올려 두고 커넥션 200개가 복잡한 리포트 쿼리를 동시에 돌리면, 이론상 수십 GB가 필요해질 수 있습니다. 메모리가 모자라면 리눅스 OOM killer가 backend를 죽이고, [1편](/posts/postgresql/01-process-architecture/)에서 본 것처럼 **서버 전체가 재시작**합니다. 그래서 전역 값은 보수적으로 두고, 큰 정렬이 필요한 배치나 리포트 세션에서만 `SET work_mem`으로 올리는 방식을 권합니다.

### 정렬이 디스크로 넘어가는 순간 찾기

`log_temp_files`를 켜 두면 임시 파일을 만든 쿼리가 서버 로그에 남습니다. 0이면 모든 임시 파일, 예를 들어 `10MB`로 두면 10MB 이상인 것만 남습니다.

```text
2026-09-24 03:09:26.736 UTC [140] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp140.0", size 69197824
```

`EXPLAIN (ANALYZE)`에서 `Sort Method: external merge`나 `Batches:`가 1보다 큰 해시가 보이면 `work_mem`이 부족하다는 신호입니다. 이런 쿼리만 골라 세션 단위로 `work_mem`을 올리면, 전역 메모리 위험 없이 성능을 높일 수 있습니다.

### 대량 적재 직후 첫 조회가 느리다

실습 3과 6에서 본 것처럼, 새로 쓴 행을 처음 읽는 쿼리는 hint bit를 적느라 페이지를 dirty로 만들고, 큰 테이블이면 ring buffer 때문에 그 페이지를 곧바로 디스크에 씁니다. 대량 적재 뒤에 `VACUUM`(또는 `VACUUM (FREEZE)`)을 한 번 돌려 두면 이 작업이 미리 끝나서, 사용자 쿼리가 그 비용을 떠안지 않습니다. VACUUM은 [5편](/posts/postgresql/05-vacuum/)에서 다룹니다.

## 정리

- 공유 메모리의 대부분은 shared buffers입니다. 8kB 칸 배열(Buffer Blocks), 칸마다 하나씩 있는 descriptor, 블록을 칸 번호로 바꾸는 매핑 해시로 이루어져 있습니다.
- 캐시가 가득 차면 **clock sweep**이 usage count(최대 5)를 깎아 가며 내보낼 칸을 고릅니다. dirty 칸을 내보낼 때는 WAL을 먼저 디스크에 씁니다.
- shared buffers의 1/4보다 큰 테이블을 순차 스캔하면 **ring buffer**만 씁니다. PG18에서는 ring 크기가 I/O 동시성에 따라 커지지만 pin 한도를 넘지 못하고, 병렬 스캔이면 프로세스마다 ring을 따로 둡니다.
- WAL buffers는 기본적으로 shared buffers의 1/32(최대 16MB)입니다.
- `work_mem`은 **정렬이나 해시 노드 하나의 한도**이고, 넘치면 임시 파일을 씁니다. 해시는 `hash_mem_multiplier`배까지 씁니다.
- backend 개인 메모리는 메모리 컨텍스트 단위로 관리되고, 수명이 끝난 컨텍스트는 통째로 해제됩니다.

다음 글에서는 shared buffers의 한 칸에 들어가는 **8kB 페이지의 안쪽**, 즉 페이지 레이아웃, 튜플 구조, 그리고 큰 값을 따로 보관하는 TOAST를 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/include/storage/buf_internals.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/buf_internals.h): `BufferDesc`, 버퍼 상태 비트
- [src/backend/storage/buffer/freelist.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/freelist.c): clock sweep, ring buffer
- [src/backend/storage/buffer/bufmgr.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c): 버퍼 읽기, pin, 쓰기
- [src/backend/storage/buffer/README](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/README): 버퍼 관리 설계 설명
- [src/backend/utils/mmgr/README](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/mmgr/README): 메모리 컨텍스트
- [src/backend/utils/sort/tuplesort.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/sort/tuplesort.c): 정렬과 external merge

PostgreSQL 18 공식 문서

- [Resource Consumption: Memory](https://www.postgresql.org/docs/18/runtime-config-resource.html#RUNTIME-CONFIG-RESOURCE-MEMORY)
- [pg_buffercache](https://www.postgresql.org/docs/18/pgbuffercache.html)
- [pg_shmem_allocations](https://www.postgresql.org/docs/18/view-pg-shmem-allocations.html)
- [pg_backend_memory_contexts](https://www.postgresql.org/docs/18/view-pg-backend-memory-contexts.html)
- [pg_stat_wal](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-WAL-VIEW)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-02-memory/lab.sh), [final-run.log](/labs/pg-02-memory/final-run.log)
