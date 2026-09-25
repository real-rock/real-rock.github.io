---
title: "PostgreSQL 인터널 8: 체크포인트와 장애 복구 과정"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "체크포인트", "복구", "PITR"]
weight: 8
summary: "장애가 나도 커밋한 데이터가 사라지지 않는 이유, 그리고 복구는 어디서부터 시작하는가"
description: "체크포인트가 하는 일과 장애 후 복구가 진행되는 순서, PITR의 원리"
---

## 개요

[7편](/posts/postgresql/07-wal/)에서 커밋은 WAL이 디스크에 닿을 때까지만 기다리고, 데이터 페이지는 메모리(shared buffers)에 dirty 상태로 남겨 둔다고 했습니다. 그렇다면 두 가지 질문이 생깁니다.

- 데이터 페이지는 언제 디스크에 쓰이는가. 영원히 메모리에만 둘 수는 없습니다.
- 서버가 갑자기 죽으면 WAL을 **어디서부터** 다시 적용해야 하는가. 클러스터를 만든 뒤의 WAL을 전부 다시 적용할 수는 없습니다.

두 질문의 답이 **체크포인트**(checkpoint)입니다. 체크포인트는 "이 위치 이전의 변경은 모두 데이터 파일에 반영되었다"는 표시를 남기는 작업이고, 장애 복구는 마지막 체크포인트가 남긴 그 위치부터 WAL을 다시 적용합니다. 같은 원리를 백업에 적용하면, 원하는 시점까지만 되돌리는 **PITR**(Point-In-Time Recovery)이 됩니다.

이 글에서 답할 질문은 다음과 같습니다.

- 체크포인트는 무엇을 하고, 언제 일어나는가
- 체크포인트의 쓰기를 왜 나눠서 하는가
- 장애 뒤 재시작하면 복구는 어떤 순서로 진행되는가
- PITR은 어떻게 원하는 시점에서 멈추는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 체크포인트가 하는 일

체크포인트는 checkpointer 프로세스([1편](/posts/postgresql/01-process-architecture/))가 [`CreateCheckPoint()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L6923)로 수행합니다.

{{< diagram src="/diagrams/pg-checkpoint-steps.html" title="체크포인트 한 번이 하는 일" height="600" caption="먼저 REDO 위치를 WAL에 표시하고, 그 이전에 바뀐 페이지를 모두 디스크에 쓴 뒤, 완료 기록을 남기고 pg_control을 갱신합니다." >}}

1. **REDO 위치 표시**: WAL에 `CHECKPOINT_REDO` 레코드를 넣습니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7095)). 이 레코드의 시작 위치가 이번 체크포인트의 **REDO 위치**입니다. 이 순간부터 페이지를 처음 고치는 변경은 다시 페이지 이미지(FPI)를 남깁니다([7편](/posts/postgresql/07-wal/)).
2. **쓰기**: SLRU(CLOG, multixact 등 [4편](/posts/postgresql/04-mvcc/)), 그리고 shared buffers의 dirty 페이지를 데이터 파일에 씁니다([`CheckPointGuts()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7546)). 쓸 대상은 **체크포인트를 시작한 순간 dirty였던 페이지**입니다([`BufferSync()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L3422)에서 `BM_CHECKPOINT_NEEDED` 표시). 쓰는 동안 다른 세션이 계속 페이지를 바꿔도 괜찮습니다. 그 변경은 REDO 위치 뒤의 WAL에 있으므로 복구가 다시 적용해 줍니다. 파일 순서, 블록 순서로 정렬해서 쓰기 때문에 디스크 입장에서는 비교적 순차적인 쓰기가 됩니다([`bufmgr.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c#L3453)).
3. **fsync**: 쓴 파일들을 모두 fsync해서 실제로 디스크에 닿게 합니다([`ProcessSyncRequests()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7567)).
4. **완료 기록**: `CHECKPOINT_ONLINE` 레코드를 넣고 flush합니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7249-L7252)). 이 레코드 안에 1단계의 REDO 위치, 다음 xid, 다음 OID 같은 정보가 들어 있습니다.
5. **pg_control 갱신**: `$PGDATA/global/pg_control` 파일에 "마지막 체크포인트 레코드는 여기"라고 적습니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7289-L7302)). pg_control은 내용이 512바이트도 안 되는 작은 파일(파일 크기 8kB)로, 서버가 켜질 때 가장 먼저 읽는 곳입니다([`pg_control.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/catalog/pg_control.h#L247-L256)).
6. **옛 WAL 정리**: 이제 REDO 위치 이전의 WAL은 장애 복구에 필요 없으므로, 그 세그먼트를 지우거나 이름을 바꿔 재활용합니다. 단 `wal_keep_size`, replication slot([9편](/posts/postgresql/09-streaming-replication/))이 요구하는 몫과 아직 보관(archive)되지 않은 세그먼트는 남깁니다([`RemoveOldXlogFiles()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L3857), [7편 실습 8](/posts/postgresql/07-wal/)).

REDO 레코드와 완료 레코드를 따로 두는 이유는, 체크포인트가 몇 분씩 걸리는 동안에도 다른 세션이 WAL을 계속 쓸 수 있게 하기 위해서입니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L6902-L6917)). 서버를 정상 종료할 때 하는 **shutdown 체크포인트**는 그동안 다른 WAL이 끼어들 수 없으므로 `CHECKPOINT_SHUTDOWN` 레코드 하나가 REDO 위치이자 완료 기록입니다.

### 체크포인트는 언제 일어나는가

| 원인 | 로그의 표시 | 설명 |
|---|---|---|
| 시간 | `time` | 마지막 체크포인트 시작 뒤 `checkpoint_timeout`(기본 5분)이 지남. 그동안 WAL 변화가 없으면 건너뜀 |
| WAL 양 | `wal` | REDO 위치 이후 WAL이 `max_wal_size`(기본 1GB)에서 계산한 양만큼 쌓임 |
| 명령 | `immediate force wait` 등 | `CHECKPOINT` 명령, `pg_basebackup` 시작, 정상 종료 등 |
| 복구 끝 | `end-of-recovery` | 장애 복구를 마친 직후 |

checkpointer는 주기적으로 깨어나 경과 시간을 보고 `time` 체크포인트를 시작합니다([`checkpointer.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/checkpointer.c#L388-L396)). `wal` 체크포인트는 WAL을 디스크에 쓰는 프로세스(주로 backend, walwriter)가 WAL 세그먼트 하나를 다 쓸 때마다 확인해서 요청합니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L2498-L2502)).

`max_wal_size`는 "WAL이 이만큼 쌓이면 체크포인트"라는 뜻이 아닙니다. 체크포인트가 진행되는 동안에도 WAL이 쌓이므로, PostgreSQL은 `max_wal_size / (1 + checkpoint_completion_target)`만큼 쌓이면 체크포인트를 시작합니다([`CalculateCheckpointSegments()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L2170-L2194)). 기본값(1GB, 0.9)이면 1024MB / 1.9 = 약 539MB, 세그먼트로는 33개이고, 실제로는 REDO 위치의 세그먼트에서 32개를 더 채운 순간([`XLogCheckpointNeeded()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L2279-L2289)), 대략 512MB쯤에서 요청됩니다.

### 쓰기를 나눠서 한다: checkpoint_completion_target

dirty 페이지 수천, 수만 개를 한꺼번에 쓰면 그동안 디스크가 포화되어 다른 쿼리가 느려집니다. 그래서 `time`, `wal` 체크포인트는 쓰기를 다음 체크포인트까지 남은 시간의 `checkpoint_completion_target`(기본 0.9) 비율에 걸쳐 나눠서 합니다. 페이지를 하나 쓸 때마다 진행률을 확인해서 예정보다 앞서 있으면 잠깐 쉽니다([`CheckpointWriteDelay()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/checkpointer.c#L772), [`IsCheckpointOnSchedule()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/checkpointer.c#L842)). 진행률은 시간 기준과 WAL 양 기준을 모두 보고 더 급한 쪽에 맞춥니다.

반면 `CHECKPOINT` 명령이나 복구 끝의 체크포인트는 `immediate` 플래그가 붙어 쉬지 않고 최대한 빨리 씁니다.

### 장애 복구 과정

서버가 정상 종료하지 못하고 죽은 뒤(전원 차단, 커널 OOM killer, `pg_ctl stop -m immediate` 등) 다시 켜면 다음 순서로 복구합니다.

{{< diagram src="/diagrams/pg-crash-recovery.html" title="비정상 종료 뒤 재시작: 장애 복구가 진행되는 순서" height="640" caption="pg_control에서 마지막 체크포인트를 찾고, 그 REDO 위치부터 WAL 끝까지 다시 적용한 뒤, 체크포인트를 한 번 하고 접속을 받습니다." >}}

1. postmaster가 startup 프로세스를 띄우고, startup은 [`StartupXLOG()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L5463)를 실행합니다.
2. pg_control의 상태가 정상 종료(`shut down`)가 아니라 `in production`이면, 정상 종료하지 못했다는 뜻입니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L5539-L5542)).
3. pg_control이 가리키는 마지막 체크포인트 레코드를 읽어 REDO 위치를 얻습니다([`xlogrecovery.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c#L796-L800)).
4. REDO 위치부터 WAL 레코드를 차례로 읽어, 레코드 종류(rmgr)마다 정해진 재생 함수로 적용합니다([`xlogrecovery.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c#L2026)).
5. 더 읽을 수 있는 올바른 레코드가 없으면(길이가 0이거나 CRC가 맞지 않으면) 거기가 WAL의 끝이라고 보고 재생을 멈춥니다.
6. 체크포인트를 한 번 해서(`end-of-recovery`) 복구한 결과를 디스크에 확정하고([`PerformRecoveryXLogAction()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L6318)), 접속을 받기 시작합니다.

4단계에서 같은 변경을 두 번 적용하지 않는 장치가 **페이지 LSN**입니다. 레코드가 건드리는 페이지를 읽었을 때,

- 레코드에 페이지 이미지가 있으면 그 이미지로 페이지를 통째로 덮습니다([`xlogutils.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogutils.c#L403)). torn page도 이렇게 되살아납니다.
- 이미지가 없으면 페이지 LSN과 레코드 LSN을 비교해서 페이지가 이미 이 레코드 이후의 상태라면 건너뜁니다([`xlogutils.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogutils.c#L444-L445)). 체크포인트 도중이나 그 뒤에 이미 디스크에 쓰인 페이지가 여기에 해당합니다.

그래서 복구는 몇 번을 다시 해도 같은 결과가 나옵니다. 복구 도중 다시 죽어도 처음부터 다시 하면 됩니다.

복구 시간은 **REDO 위치 이후의 WAL 양**에 비례합니다. 체크포인트를 자주 하면 복구는 빨라지지만 페이지 이미지와 쓰기가 늘고, 드물게 하면 반대입니다. `checkpoint_timeout`과 `max_wal_size`가 이 균형을 정합니다.

### PITR: 백업과 WAL로 원하는 시점까지

장애 복구는 "마지막 체크포인트 + 그 뒤의 WAL"로 데이터를 되살립니다. 같은 원리를 넓히면 이렇게 됩니다.

- **베이스 백업**: 데이터 디렉터리 전체의 복사본입니다(`pg_basebackup`). 서버가 도는 중에 복사하므로 파일마다 시점이 제각각인데, 괜찮습니다. 백업을 시작할 때 체크포인트를 하고 그 REDO 위치를 `backup_label` 파일에 적어 두기 때문에, 복원할 때 그 위치부터 WAL을 적용해 **백업이 끝난 위치까지** 재생하면 일관된 상태가 됩니다. 그래서 PITR로 멈출 지점은 백업이 끝난 시점보다 뒤여야 합니다([`read_backup_label()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c#L1242)).
- **WAL 보관(archiving)**: `archive_mode = on`이면 archiver 프로세스가 다 쓴 세그먼트를 `archive_command`로 다른 곳에 복사합니다. 체크포인트가 옛 WAL을 지워도 보관본은 남습니다.
- **복원**: 백업을 풀고 `recovery.signal` 파일을 만든 뒤 켜면, `restore_command`로 보관한 WAL을 하나씩 가져와 적용합니다. `recovery_target_time`, `recovery_target_lsn`, `recovery_target_name` 등으로 멈출 지점을 정하면 거기서 멈춥니다([`recoveryStopsAfter()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c#L2763)).

복원한 서버가 멈춘 지점부터 새 WAL을 쓰기 시작하면, 원래 서버가 그 뒤로 쓴 WAL과 번호가 겹칩니다. 그래서 복구를 끝낼 때 **새 타임라인 ID**를 골라([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L5986)) 이후 WAL 파일 이름의 앞 8자리를 바꾸고, 어디서 갈라졌는지를 `.history` 파일에 남깁니다([Timelines](https://www.postgresql.org/docs/18/continuous-archiving.html#BACKUP-TIMELINES)). standby를 승격할 때도 같은 일이 일어납니다([9편](/posts/postgresql/09-streaming-replication/)).

## 직접 확인해 보기

### 실습 환경

[실습 이미지](/labs/pg-lab-image/Dockerfile)로 [lab.sh](/labs/pg-08-checkpoint-and-recovery/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-08-checkpoint-and-recovery/final-run.log)에 있습니다. 서버 로그에 프로세스 종류가 나오도록 `log_line_prefix`에 `%b`를 넣었고, `log_checkpoints`는 PG15부터 기본으로 켜져 있어 체크포인트마다 로그가 남습니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
55c972d387088fdc3925bb59dcd12f8e65b972878059a1043438b4a2d5c03304
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
cat >> $PGDATA/postgresql.conf <<'CONF'
log_line_prefix = '%m [%p] %b '
CONF
pg_ctl -D $PGDATA -l /home/postgres/server.log start
psql -X -q -c "CREATE EXTENSION pg_walinspect"
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, pad text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, repeat('p', 200) FROM generate_series(1, 200000) g"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. pg_control: 서버가 기억하는 마지막 체크포인트

```bash
pg_controldata $PGDATA | grep -E "cluster state|Latest checkpoint location|Latest checkpoint's REDO location|Latest checkpoint's REDO WAL file|Time of latest checkpoint"
psql -X -c "SHOW checkpoint_timeout" -c "SHOW max_wal_size" -c "SHOW checkpoint_completion_target" -c "SHOW log_checkpoints"
```

```text
Database cluster state:               in production
Latest checkpoint location:           0/1758C08
Latest checkpoint's REDO location:    0/1758C08
Latest checkpoint's REDO WAL file:    000000010000000000000001
Time of latest checkpoint:            Thu Sep 24 04:11:56 2026
 checkpoint_timeout 
--------------------
 5min
(1 row)

 max_wal_size 
--------------
 1GB
(1 row)

 checkpoint_completion_target 
------------------------------
 0.9
(1 row)

 log_checkpoints 
-----------------
 on
(1 row)

[exit=0]
```

`pg_controldata`는 pg_control 파일의 내용을 보여 줍니다. 지금 마지막 체크포인트는 initdb가 끝나며 한 **shutdown 체크포인트**라, 체크포인트 레코드 위치와 REDO 위치가 `0/1758C08`로 같습니다. 기본값은 `checkpoint_timeout` 5분, `max_wal_size` 1GB, `checkpoint_completion_target` 0.9입니다.

### 실습 2. 수동 CHECKPOINT

5만 행을 바꾼 뒤 `CHECKPOINT`를 실행합니다. 실습 환경을 만들며 20만 행을 넣은 뒤로 체크포인트가 한 번도 없었으므로, 그 INSERT로 dirty가 된 페이지도 아직 메모리에만 있습니다.

```bash
psql -X -q -c "UPDATE acct SET balance = balance + 1 WHERE id <= 50000"
psql -X -c "SELECT num_timed, num_requested, num_done, buffers_written FROM pg_stat_checkpointer"
psql -X -c "SELECT pg_current_wal_insert_lsn() AS before_checkpoint"
psql -X -q -c "CHECKPOINT"
grep -E "checkpoint (starting|complete)" /home/postgres/server.log | tail -2
pg_controldata $PGDATA | grep -E "Latest checkpoint location|Latest checkpoint's REDO location"
psql -X -c "SELECT num_timed, num_requested, num_done, buffers_written FROM pg_stat_checkpointer"
```

```text
 num_timed | num_requested | num_done | buffers_written 
-----------+---------------+----------+-----------------
         0 |             0 |        0 |               0
(1 row)

 before_checkpoint 
-------------------
 0/6C91478
(1 row)

2026-09-24 04:11:57.320 UTC [42] checkpointer LOG:  checkpoint starting: immediate force wait
2026-09-24 04:11:57.367 UTC [42] checkpointer LOG:  checkpoint complete: wrote 8337 buffers (50.9%), wrote 3 SLRU buffers; 0 WAL file(s) added, 0 removed, 5 recycled; write=0.012 s, sync=0.024 s, total=0.048 s; sync files=52, longest=0.013 s, average=0.001 s; distance=87266 kB, estimate=87266 kB; lsn=0/6C914D0, redo lsn=0/6C91478
Latest checkpoint location:           0/6C914D0
Latest checkpoint's REDO location:    0/6C91478
 num_timed | num_requested | num_done | buffers_written 
-----------+---------------+----------+-----------------
         0 |             1 |        1 |            8337
(1 row)

[exit=0]
```

로그 두 줄이 체크포인트의 시작과 끝입니다.

- `immediate force wait`: 쉬지 않고 쓰며(`immediate`), 지난 체크포인트 뒤 WAL 변화가 없어도 건너뛰지 않고(`force`), 요청한 쪽이 끝날 때까지 기다렸다(`wait`)는 뜻입니다. `CHECKPOINT` 명령이 이 세 플래그를 붙입니다.
- `wrote 8337 buffers (50.9%)`: shared buffers 16384개(128MB) 가운데 dirty였던 8337개를 썼습니다. 대부분은 20만 행 INSERT로 생긴 페이지이고, 5만 행 UPDATE분이 더해졌습니다. `pg_stat_checkpointer`의 `buffers_written`도 0에서 8337이 되었습니다.
- `write=0.012 s, sync=0.024 s`: 쓰기와 fsync에 걸린 시간입니다. write 단계는 운영체제 페이지 캐시에 넘기는 것이라 금방 끝나고, 실제로 디스크에 닿게 하는 것은 sync 단계입니다.
- `5 recycled`: REDO 이전의 WAL 세그먼트 5개를 재활용했습니다.
- `distance=87266 kB`: 이전 체크포인트의 REDO부터 이번 REDO까지의 WAL 양입니다. `estimate`는 이 값의 이동 평균으로, 다음 체크포인트까지 쓸 세그먼트를 얼마나 남겨 둘지 정하는 데 씁니다.

`CHECKPOINT` 직전의 insert 위치 `0/6C91478`이 그대로 새 REDO 위치가 되었고, 체크포인트 레코드는 그 뒤 `0/6C914D0`에 있습니다.

### 실습 3. WAL 안의 체크포인트 레코드

pg_control이 가리키는 두 위치의 레코드를 WAL에서 직접 봅니다.

```bash
R=$(pg_controldata $PGDATA | awk -F': *' '/REDO location/ {print $2}')
C=$(pg_controldata $PGDATA | awk -F': *' '/Latest checkpoint location/ {print $2}')
echo "REDO=$R CHECKPOINT=$C"
psql -X -c "SELECT start_lsn, resource_manager AS rmgr, record_type, record_length AS len, left(description, 90) AS description FROM pg_get_wal_records_info('$R', pg_current_wal_insert_lsn())"
```

```text
REDO=0/6C91478 CHECKPOINT=0/6C914D0
 start_lsn |  rmgr   |    record_type    | len |                                        description                                         
-----------+---------+-------------------+-----+--------------------------------------------------------------------------------------------
 0/6C91478 | XLOG    | CHECKPOINT_REDO   |  30 | wal_level replica
 0/6C91498 | Standby | RUNNING_XACTS     |  50 | nextXid 756 latestCompletedXid 755 oldestRunningXid 756
 0/6C914D0 | XLOG    | CHECKPOINT_ONLINE | 114 | redo 0/6C91478; tli 1; prev tli 1; fpw true; wal_level replica; xid 0:756; oid 24576; mult
(3 rows)

[exit=0]
```

REDO 위치 `0/6C91478`에 `CHECKPOINT_REDO`가 있고, 완료 기록 `CHECKPOINT_ONLINE`은 `0/6C914D0`에 있습니다. 완료 기록의 설명에 있는 `redo 0/6C91478`이 REDO 위치를 다시 가리킵니다. 둘 사이의 `RUNNING_XACTS`는 체크포인트가 완료 기록 직전에 standby를 위해 남기는 "지금 실행 중인 트랜잭션 목록"입니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7239), [9편](/posts/postgresql/09-streaming-replication/)).

이번에는 다른 세션이 없어 레코드가 셋뿐이지만, 바쁜 서버라면 체크포인트가 페이지를 쓰는 동안 생긴 모든 변경 레코드가 REDO와 완료 기록 사이에 들어갑니다. 완료 기록에는 `xid 0:756`(다음에 줄 xid), `oid 24576`(다음에 줄 OID) 같은 값도 담겨 있어서 복구를 마친 서버가 번호를 이어서 쓸 수 있습니다.

### 실습 4. WAL이 많이 쌓여도 체크포인트가 일어난다

`max_wal_size`를 64MB로 줄이고, 20만 행 전체를 두 번 바꿉니다.

```bash
psql -X -q -c "ALTER SYSTEM SET max_wal_size = '64MB'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -c "SHOW max_wal_size"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
sleep 2
grep -E "checkpoint starting|checkpoints are occurring too frequently" /home/postgres/server.log | tail -4 | cut -c1-140
psql -X -c "SELECT num_timed, num_requested, num_done FROM pg_stat_checkpointer"
psql -X -q -c "ALTER SYSTEM RESET max_wal_size" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
 max_wal_size 
--------------
 64MB
(1 row)

2026-09-24 04:11:58.436 UTC [42] checkpointer LOG:  checkpoints are occurring too frequently (0 seconds apart)
2026-09-24 04:11:58.436 UTC [42] checkpointer LOG:  checkpoint starting: wal
2026-09-24 04:11:58.595 UTC [42] checkpointer LOG:  checkpoints are occurring too frequently (0 seconds apart)
2026-09-24 04:11:58.595 UTC [42] checkpointer LOG:  checkpoint starting: wal
 num_timed | num_requested | num_done 
-----------+---------------+----------
         0 |             9 |        8
(1 row)

[exit=0]
```

UPDATE가 WAL을 많이 만드는 동안 `wal` 체크포인트가 연달아 일어났습니다. `max_wal_size`가 64MB면 64MB / 1.9 = 약 34MB라 세그먼트 2개로 내림되고, REDO 위치가 있는 세그먼트 다음 세그먼트 하나만 채워도 체크포인트가 요청됩니다. REDO 뒤 16~32MB마다 체크포인트를 하는 셈이라, 앞 체크포인트가 끝나자마자 다음이 시작되고 간격이 `checkpoint_warning`(30초)보다 짧아 `occurring too frequently` 경고가 붙었습니다.

`num_requested` 9는 실습 2의 명령 1번과 이번 `wal` 8번입니다. `num_requested`는 체크포인트를 시작할 때, `num_done`은 끝날 때 늘어나는데, 마지막 하나는 UPDATE가 끝나 WAL이 더 늘지 않자 시간 기준 일정에 맞춰 천천히 쓰는 중이라 `num_done`이 8입니다.

### 실습 5. 시간 기준 체크포인트는 쓰기를 나눠서 한다

`checkpoint_timeout`을 허용되는 최솟값인 30초로 줄이고, 전체 행을 바꾼 뒤 다음 `time` 체크포인트가 끝날 때까지 기다립니다.

```bash
psql -X -q -c "ALTER SYSTEM SET checkpoint_timeout = '30s'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -c "CHECKPOINT"
psql -X -q -c "UPDATE acct SET balance = balance + 1"
for i in $(seq 1 120); do
  grep -A1 "checkpoint starting: time" /home/postgres/server.log | grep -q "checkpoint complete" && break
  sleep 1
done
grep -A1 "checkpoint starting: time" /home/postgres/server.log | head -2 | cut -c1-230
psql -X -q -c "ALTER SYSTEM RESET checkpoint_timeout" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
2026-09-24 04:12:30.769 UTC [42] checkpointer LOG:  checkpoint starting: time
2026-09-24 04:12:57.043 UTC [42] checkpointer LOG:  checkpoint complete: wrote 6666 buffers (40.7%), wrote 1 SLRU buffers; 0 WAL file(s) added, 0 removed, 11 recycled; write=26.234 s, sync=0.024 s, total=26.274 s; sync files=5, lo
[exit=0]
```

`time` 체크포인트가 04:12:30.769에 시작해 04:12:57.043에 끝났고, `write=26.234 s`입니다. `checkpoint_timeout` 30초 × `checkpoint_completion_target` 0.9 = 27초에 맞춰 6666개 페이지를 나눠 쓴 것입니다. 진행 시간은 초 단위로 자른 시작 시각(04:12:30)부터 재므로 27초 뒤인 04:12:57 무렵에 끝났고, 그래서 write가 27초보다 조금 짧게 나왔습니다. 실습 2의 immediate 체크포인트가 8337개를 0.012초에 쓴 것과 비교하면, 비슷한 양을 일부러 천천히 썼다는 것을 알 수 있습니다. 기본값(5분)이라면 약 4분 30초에 걸쳐 씁니다.

### 실습 6. 장애 복구: 마지막 체크포인트부터 WAL을 다시 적용한다

합계를 확인하고 `CHECKPOINT`한 뒤, 10만 행에 1씩 더하고(합계 +100000) 행 하나(balance 777)를 넣습니다. 그리고 `pg_ctl stop -m immediate`로 서버를 **체크포인트 없이 즉시** 죽입니다. 전원이 나간 것과 비슷한 상황입니다.

```bash
psql -X -c "SELECT sum(balance) AS total, count(*) FROM acct"
psql -X -q -c "CHECKPOINT"
psql -X -q -c "UPDATE acct SET balance = balance + 1 WHERE id <= 100000"
psql -X -q -c "INSERT INTO acct VALUES (300001, 777, 'after checkpoint')"
psql -X -c "SELECT pg_current_wal_insert_lsn() AS insert_lsn, pg_current_wal_flush_lsn() AS flush_lsn"
pg_controldata $PGDATA | grep -E "Latest checkpoint's REDO location"
pg_ctl -D $PGDATA stop -m immediate
pg_controldata $PGDATA | grep -E "cluster state"
```

```text
  total   | count  
----------+--------
 20650000 | 200000
(1 row)

 insert_lsn | flush_lsn  
------------+------------
 0/30E51AC0 | 0/30E51AC0
(1 row)

Latest checkpoint's REDO location:    0/2CDA3468
waiting for server to shut down.... done
server stopped
Database cluster state:               in production
[exit=0]
```

죽기 직전 insert 위치와 flush 위치가 모두 `0/30E51AC0`입니다. 마지막 INSERT가 커밋하면서 WAL을 이 위치까지 flush했기 때문입니다([7편](/posts/postgresql/07-wal/)). 마지막 체크포인트의 REDO 위치는 `0/2CDA3468`입니다. 죽인 뒤에도 pg_control의 상태는 `in production`으로 남았습니다. 정상 종료였다면 shutdown 체크포인트를 하고 상태를 `shut down`으로 바꿨을 것입니다.

다시 켭니다.

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
sed -n '/database system was interrupted/,/database system is ready/p' /home/postgres/server.log | tail -12 | cut -c1-220
psql -X -c "SELECT sum(balance) AS total, count(*) FROM acct"
psql -X -c "SELECT * FROM acct WHERE id = 300001"
pg_controldata $PGDATA | grep -E "cluster state"
```

```text
waiting for server to start.... done
server started
2026-09-24 04:12:58.535 UTC [347] startup LOG:  database system was interrupted; last known up at 2026-09-24 04:12:58 UTC
2026-09-24 04:12:58.561 UTC [347] startup LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-24 04:12:58.562 UTC [347] startup LOG:  redo starts at 0/2CDA3468
2026-09-24 04:12:58.643 UTC [347] startup LOG:  invalid record length at 0/30E51AC0: expected at least 24, got 0
2026-09-24 04:12:58.643 UTC [347] startup LOG:  redo done at 0/30E51A98 system usage: CPU: user: 0.06 s, system: 0.01 s, elapsed: 0.08 s
2026-09-24 04:12:58.644 UTC [345] checkpointer LOG:  checkpoint starting: end-of-recovery immediate wait
2026-09-24 04:12:58.681 UTC [345] checkpointer LOG:  checkpoint complete: wrote 6615 buffers (40.4%), wrote 3 SLRU buffers; 0 WAL file(s) added, 4 removed, 0 recycled; write=0.011 s, sync=0.013 s, total=0.038 s; sync fil
2026-09-24 04:12:58.683 UTC [341] postmaster LOG:  database system is ready to accept connections
  total   | count  
----------+--------
 20750777 | 200001
(1 row)

   id   | balance |       pad        
--------+---------+------------------
 300001 |     777 | after checkpoint
(1 row)

Database cluster state:               in production
[exit=0]
```

startup 프로세스의 로그가 복구 과정을 그대로 보여 줍니다.

- `was interrupted`, `not properly shut down`: pg_control의 상태를 보고 복구를 시작했습니다.
- `redo starts at 0/2CDA3468`: pg_control이 가리키는 REDO 위치부터 재생합니다.
- `invalid record length at 0/30E51AC0`: 죽기 전 flush 위치와 정확히 같은 곳에서 더 읽을 레코드가 없어 멈췄습니다. `redo done at 0/30E51A98`은 마지막으로 적용한 레코드(마지막 INSERT의 커밋 레코드)의 시작 위치입니다.
- REDO부터 약 65MB의 WAL을 0.08초에 재생했고, 이어서 `end-of-recovery` 체크포인트를 한 뒤 접속을 받기 시작했습니다.

합계는 20650000에서 정확히 100000 + 777만큼 늘어난 20750777이고, 체크포인트 뒤에 넣은 행도 있습니다. 데이터 파일에는 아직 반영되지 않았던 변경이 WAL에서 모두 되살아났습니다.

### 실습 7. 복구 시간은 마지막 체크포인트 이후 WAL 양에 비례한다

체크포인트가 저절로 일어나지 않도록 `max_wal_size`를 4GB, `checkpoint_timeout`을 1시간으로 늘리고, 전체 행 UPDATE를 다섯 번 한 뒤 죽입니다.

```bash
psql -X -q -c "ALTER SYSTEM SET max_wal_size = '4GB'" -c "ALTER SYSTEM SET checkpoint_timeout = '1h'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -q -c "CHECKPOINT"
for i in 1 2 3 4 5; do psql -X -q -c "UPDATE acct SET balance = balance + 1"; done
psql -X -c "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), (SELECT redo_lsn FROM pg_control_checkpoint()))) AS wal_since_redo"
pg_ctl -D $PGDATA stop -m immediate
pg_ctl -D $PGDATA -l /home/postgres/server.log start
grep -E "redo starts|redo done" /home/postgres/server.log | tail -2 | cut -c1-200
```

```text
 wal_since_redo 
----------------
 453 MB
(1 row)

waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
2026-09-24 04:13:01.721 UTC [394] startup LOG:  redo starts at 0/33DCE5B8
2026-09-24 04:13:02.570 UTC [394] startup LOG:  redo done at 0/50320F30 system usage: CPU: user: 0.75 s, system: 0.09 s, elapsed: 0.84 s
[exit=0]
```

REDO 이후 WAL 453MB를 재생하는 데 0.84초 걸렸습니다. 실습 6(약 65MB, 0.08초)보다 WAL이 약 7배이고 시간은 약 10배입니다. 재생은 startup 프로세스 하나가 순서대로 합니다. 이 실습은 테이블이 작아 페이지가 모두 메모리에 있으므로 빠르지만, 실제 서버에서는 재생할 페이지를 디스크에서 읽어야 하므로 훨씬 오래 걸릴 수 있습니다. 어느 쪽이든 복구 시간은 REDO 이후 WAL 양에 따라 늘어납니다.

### 실습 8. PITR: 실수로 지운 테이블 되살리기

WAL 보관을 켜고 베이스 백업을 뜬 뒤, 행 하나를 더 넣고 **복원 지점**(restore point)을 만든 다음, 실수로 테이블을 지웠다고 해 봅니다.

```bash
mkdir -p /home/postgres/archive
psql -X -q -c "ALTER SYSTEM RESET ALL" -c "ALTER SYSTEM SET archive_mode = on" -c "ALTER SYSTEM SET archive_command = 'cp %p /home/postgres/archive/%f'"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart > /dev/null
pg_basebackup -D /home/postgres/backup -c fast && echo "base backup ok"
ls /home/postgres/backup | tr '\n' ' '; echo
cat /home/postgres/backup/backup_label
psql -X -q -c "INSERT INTO acct VALUES (400001, 1, 'before mistake')"
psql -X -c "SELECT pg_create_restore_point('before_drop')"
psql -X -q -c "DROP TABLE acct"
psql -X -q -c "SELECT pg_switch_wal()" > /dev/null
sleep 2
psql -X -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver"
ls /home/postgres/archive
```

```text
base backup ok
PG_VERSION backup_label backup_manifest base global pg_commit_ts pg_dynshmem pg_hba.conf pg_ident.conf pg_logical pg_multixact pg_notify pg_replslot pg_serial pg_snapshots pg_stat pg_stat_tmp pg_subtrans pg_tblspc pg_twophase pg_wal pg_xact postgresql.auto.conf postgresql.conf 
START WAL LOCATION: 0/51000028 (file 000000010000000000000051)
CHECKPOINT LOCATION: 0/51000080
BACKUP METHOD: streamed
BACKUP FROM: primary
START TIME: 2026-09-24 04:13:03 UTC
LABEL: pg_basebackup base backup
START TIMELINE: 1
 pg_create_restore_point 
-------------------------
 0/52001CD0
(1 row)

 archived_count |    last_archived_wal     | failed_count 
----------------+--------------------------+--------------
              4 | 000000010000000000000052 |            0
(1 row)

000000010000000000000050
000000010000000000000051
000000010000000000000051.00000028.backup
000000010000000000000052
[exit=0]
```

- `pg_basebackup -c fast`는 백업을 시작하며 체크포인트를 하고 데이터 디렉터리 전체를 복사했습니다. `backup_label`의 `START WAL LOCATION: 0/51000028`이 이 백업을 복원할 때 WAL 적용을 시작할 REDO 위치입니다.
- `pg_create_restore_point('before_drop')`는 WAL에 이름 붙은 표시 레코드를 남기고, 그 레코드의 끝 위치 `0/52001CD0`을 돌려줍니다.
- `pg_switch_wal()`로 현재 세그먼트를 마감해서 archiver가 보관하게 했습니다. 보관소에는 세그먼트 3개와, 백업 시작과 끝 위치를 적은 `.backup` 파일이 있습니다(`archived_count` 4). 원래 서버의 `acct` 테이블은 이제 없습니다.

백업 디렉터리를 복원용 서버(포트 5433)로 켜서, 복원 지점까지만 복구합니다.

```bash
cat >> /home/postgres/backup/postgresql.auto.conf <<'CONF'
port = 5433
restore_command = 'cp /home/postgres/archive/%f %p'
recovery_target_name = 'before_drop'
recovery_target_action = 'promote'
CONF
touch /home/postgres/backup/recovery.signal
pg_ctl -D /home/postgres/backup -l /home/postgres/pitr.log start
sleep 2
grep -E "starting point-in-time|redo starts|restored log file|recovery stopping|redo done|selected new timeline|archive recovery complete|ready to accept" /home/postgres/pitr.log | cut -c1-200
psql -X -p 5433 -c "SELECT count(*), max(id) FROM acct"
psql -X -p 5432 -c "SELECT count(*) FROM acct"
ls /home/postgres/backup/pg_wal
cat /home/postgres/backup/pg_wal/00000002.history
```

```text
waiting for server to start.... done
server started
2026-09-24 04:13:06.105 UTC [466] startup LOG:  restored log file "000000010000000000000051" from archive
2026-09-24 04:13:06.119 UTC [466] startup LOG:  starting point-in-time recovery to "before_drop"
2026-09-24 04:13:06.122 UTC [466] startup LOG:  redo starts at 0/51000028
2026-09-24 04:13:06.124 UTC [466] startup LOG:  restored log file "000000010000000000000052" from archive
2026-09-24 04:13:06.137 UTC [460] postmaster LOG:  database system is ready to accept read-only connections
2026-09-24 04:13:06.137 UTC [466] startup LOG:  recovery stopping at restore point "before_drop", time 2026-09-24 04:13:03.921572+00
2026-09-24 04:13:06.137 UTC [466] startup LOG:  redo done at 0/52001C68 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.01 s
2026-09-24 04:13:06.139 UTC [466] startup LOG:  restored log file "000000010000000000000052" from archive
2026-09-24 04:13:06.155 UTC [466] startup LOG:  selected new timeline ID: 2
2026-09-24 04:13:06.176 UTC [466] startup LOG:  archive recovery complete
2026-09-24 04:13:06.180 UTC [460] postmaster LOG:  database system is ready to accept connections
 count  |  max   
--------+--------
 200002 | 400001
(1 row)

ERROR:  relation "acct" does not exist
LINE 1: SELECT count(*) FROM acct
                             ^
000000010000000000000052
00000002.history
000000020000000000000052
000000020000000000000053
000000020000000000000054
000000020000000000000055
000000020000000000000056
000000020000000000000057
archive_status
summaries
1	0/52001CD0	at restore point "before_drop"
[exit=0]
```

- `restored log file ... from archive`: `restore_command`로 보관소에서 세그먼트를 하나씩 가져왔습니다.
- `redo starts at 0/51000028`: `backup_label`의 시작 위치부터 재생합니다. 백업을 복원할 때는 pg_control이 아니라 backup_label이 기준입니다.
- `ready to accept read-only connections`: 백업이 일관된 상태에 도달한 뒤라, 복구 중에도 읽기 접속을 받을 수 있게 되었습니다(`hot_standby` 기본값 on).
- `recovery stopping at restore point "before_drop"`: 복원 지점 레코드를 만나 멈췄습니다. `redo done at 0/52001C68`은 마지막으로 적용한 레코드, 즉 복원 지점 레코드 자신의 시작 위치입니다. `pg_create_restore_point()`가 돌려준 `0/52001CD0`은 이 레코드의 끝이고, 타임라인도 여기서 갈라집니다. `DROP TABLE`은 그 뒤에 있으므로 적용되지 않았습니다.
- `selected new timeline ID: 2`: `recovery_target_action = 'promote'`라서 멈춘 뒤 바로 일반 서버로 승격했고(기본값 `pause`는 멈춘 채로 확인을 기다립니다), 여기서부터 새 타임라인입니다. 이후 WAL 파일 이름이 `00000002`로 시작하고, `00000002.history`에는 "타임라인 1의 `0/52001CD0`, 복원 지점에서 갈라짐"이 적혀 있습니다.

복원한 서버에는 `acct`가 200002행, 마지막에 넣은 400001번 행까지 있고, 원래 서버에서는 여전히 테이블이 없습니다. 이 복원 서버에서 테이블을 `pg_dump`로 꺼내 원래 서버에 다시 넣는 식으로 실수를 되돌릴 수 있습니다.

## 운영에서는 이렇게 나타납니다

### checkpoints are occurring too frequently

실습 4의 이 경고는 `wal` 체크포인트가 `checkpoint_warning`(기본 30초)보다 짧은 간격으로 일어날 때 나옵니다([`checkpointer.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/checkpointer.c#L454-L462)). 대량 적재나 배치 UPDATE 때 자주 보입니다. 체크포인트가 잦으면 체크포인트 직후마다 페이지 이미지가 쏟아지고([7편](/posts/postgresql/07-wal/)), 쓰기를 나눌 시간도 없어 디스크 I/O가 튑니다. 보통은 로그의 힌트대로 `max_wal_size`를 늘려 해결합니다. `pg_stat_checkpointer`에서 `num_requested`가 `num_timed`보다 훨씬 많다면 같은 신호입니다.

### 체크포인트 동안 쿼리가 느려진다

`checkpoint_completion_target`을 낮게 두면 짧은 시간에 쓰기가 몰립니다. 기본값 0.9를 그대로 두는 편이 대부분 낫습니다. 또 로그의 `sync=` 시간이 길다면 운영체제 페이지 캐시에 쌓인 쓰기가 fsync 순간 한꺼번에 나가는 것이므로, 쓰기 자체를 줄이거나 디스크 성능을 봐야 합니다.

### 재시작이 오래 걸린다

장애 뒤 재시작이 오래 걸린다면 REDO 위치 이후 WAL이 많이 쌓여 있었다는 뜻입니다. `max_wal_size`를 아주 크게, `checkpoint_timeout`을 아주 길게 잡았다면 복구에 필요한 WAL도 그만큼 늘어납니다. 복구 중에는 로그에 `redo in progress, elapsed time: ...` 진행 메시지가 주기적으로 나오므로(`log_startup_progress_interval`, 기본 10초) 얼마나 남았는지 가늠할 수 있습니다.

### PITR은 연습해 둬야 한다

PITR에는 베이스 백업과, 그 백업 이후 **끊김 없는** WAL 보관본이 모두 필요합니다. `pg_stat_archiver`의 `failed_count`를 모니터링하고 복원 절차는 실제로 한 번 해 봐야 합니다. 실습처럼 위험한 작업 전에 `pg_create_restore_point()`로 이름을 붙여 두면 멈출 지점을 찾기 쉽습니다.

## 정리

- **체크포인트**는 REDO 위치를 WAL에 표시하고, 그 전에 dirty였던 페이지를 모두 디스크에 쓴 뒤, 완료 기록과 pg_control을 남기는 작업입니다. 그 뒤로 REDO 이전의 WAL은 장애 복구에 필요 없어집니다.
- 체크포인트는 `checkpoint_timeout`이 지나거나, WAL이 `max_wal_size`에서 계산한 양만큼 쌓이거나, 명령으로 일어납니다. 앞의 두 경우는 쓰기를 `checkpoint_completion_target`에 맞춰 나눠서 합니다.
- **장애 복구**는 pg_control에서 마지막 체크포인트를 찾아, 그 REDO 위치부터 디스크에 남아 있는 유효한 WAL의 끝까지 다시 적용합니다. 페이지 LSN 덕분에 이미 반영된 변경은 건너뜁니다.
- 복구 시간은 REDO 위치 이후 WAL 양에 비례합니다.
- **PITR**은 베이스 백업에서 출발해 보관한 WAL을 원하는 지점까지만 적용하고, 새 타임라인으로 갈라집니다.

다음 글에서는 WAL을 다른 서버로 계속 보내는 **스트리밍 복제와 replication slot**을 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/access/transam/xlog.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c): `CreateCheckPoint()`, `StartupXLOG()`
- [src/backend/postmaster/checkpointer.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/checkpointer.c): 체크포인트 시작 조건과 쓰기 분산
- [src/backend/storage/buffer/bufmgr.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/buffer/bufmgr.c): `BufferSync()`
- [src/backend/access/transam/xlogrecovery.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c): WAL 재생, 복구 목표
- [src/backend/access/transam/xlogutils.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogutils.c): 재생 시 페이지 LSN 비교

PostgreSQL 18 공식 문서

- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html)
- [체크포인트 설정](https://www.postgresql.org/docs/18/runtime-config-wal.html#GUC-CHECKPOINT-TIMEOUT)
- [Continuous Archiving and Point-in-Time Recovery (PITR)](https://www.postgresql.org/docs/18/continuous-archiving.html)
- [pg_stat_checkpointer](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-CHECKPOINTER-VIEW)
- [pg_controldata](https://www.postgresql.org/docs/18/app-pgcontroldata.html), [pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-08-checkpoint-and-recovery/lab.sh), [final-run.log](/labs/pg-08-checkpoint-and-recovery/final-run.log)
