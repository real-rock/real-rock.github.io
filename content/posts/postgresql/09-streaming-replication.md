---
title: "PostgreSQL 인터널 9: 스트리밍 복제와 Replication Slot"
date: 2026-09-24
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "복제", "replication slot", "standby"]
weight: 9
summary: "standby는 primary의 변경을 어떻게 따라가고, replication slot은 왜 디스크를 채우는가"
description: "walsender와 walreceiver, 동기 복제, hot standby 충돌, replication slot"
---

## 개요

[8편](/posts/postgresql/08-checkpoint-and-recovery/)에서 장애 복구는 "마지막 체크포인트부터 WAL을 다시 적용"하는 일이었고, PITR은 백업에 보관한 WAL을 적용하는 일이었습니다. 이 생각을 한 걸음 더 밀면 **스트리밍 복제**가 됩니다. 백업에서 출발한 서버가 복구를 끝내지 않고, primary가 새로 만드는 WAL을 네트워크로 계속 받아 **영원히 복구하는 상태**로 남는 것입니다. 이 서버가 **standby**입니다.

standby는 primary와 똑같은 WAL을 똑같이 재생하므로, 페이지 단위까지 같은 데이터를 갖게 됩니다. 이것을 **물리 복제(physical replication)**라고 합니다. (테이블의 행 변경을 논리적으로 풀어서 보내는 논리 복제도 있지만, 이 글에서는 다루지 않습니다.)

이 글에서 답할 질문은 다음과 같습니다.

- WAL은 어떤 프로세스를 거쳐 standby에 도착하고 재생되는가
- 복제 지연은 어디서 생기고, 어떻게 읽는가
- 동기 복제에서 커밋은 무엇을 기다리는가
- standby의 읽기 쿼리는 왜 취소되기도 하는가
- replication slot은 왜 필요하고, 왜 디스크를 가득 채우기도 하는가

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16). 소스 링크는 모두 이 커밋에 고정했고, 실습 출력은 이 소스를 Docker에서 빌드해 실행한 결과입니다.

## 동작 원리

### 복제를 담당하는 세 프로세스

{{< diagram src="/diagrams/pg-replication-architecture.html" title="스트리밍 복제: WAL이 primary에서 standby로 가는 길" height="640" caption="walsender가 primary의 WAL을 보내고, walreceiver가 받아 standby 디스크에 쓰고, startup이 재생합니다. 같은 연결로 standby가 처리한 위치를 거꾸로 보고합니다. slot이 붙잡은 WAL을 실제로 지우거나 남기는 것은 primary의 체크포인트입니다." >}}

- **walsender** (primary): standby가 복제 연결을 맺으면 postmaster가 띄우는 backend의 한 종류입니다([1편](/posts/postgresql/01-process-architecture/)). 보낼 WAL이 아직 WAL buffers(공유 메모리)에 남아 있으면 거기서, 없으면 `pg_wal` 파일에서 읽어 보냅니다(버퍼에서 먼저 읽는 것은 PG17부터, [`XLogSendPhysical()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L3140)). 보내는 것은 primary에서 **flush까지 끝난** WAL뿐입니다([`walsender.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L3244)). 아직 primary 디스크에도 없는 WAL을 standby가 먼저 갖는 일은 없습니다.
- **walreceiver** (standby): primary에 접속해서 WAL을 받아 standby의 `pg_wal`에 쓰고([`XLogWalRcvWrite()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walreceiver.c#L976)) fsync합니다([`XLogWalRcvFlush()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walreceiver.c#L1071)). 그리고 어디까지 썼고(write), 디스크에 확정했고(flush), 재생했는지(apply)를 같은 연결로 primary에 보고합니다([`XLogWalRcvSendReply()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walreceiver.c#L1178)).
- **startup** (standby): [8편](/posts/postgresql/08-checkpoint-and-recovery/)의 장애 복구를 하던 그 프로세스입니다. standby에서는 복구를 끝내지 않고, walreceiver가 fsync까지 끝낸 WAL을 이어서 재생합니다.

standby는 `standby.signal` 파일이 있는 데이터 디렉터리로 시작하며, `primary_conninfo`에 적힌 primary로 접속합니다. `pg_basebackup -R`이 이 두 가지를 만들어 줍니다(실습 1). `hot_standby`(기본 on)이면 재생하는 동안에도 읽기 전용 쿼리를 받습니다.

### 전송, 기록, 재생: 지연은 세 군데서 생긴다

primary의 walsender는 standby의 보고를 받아 `pg_stat_replication`에 보여 줍니다([`ProcessStandbyReplyMessage()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L2445)).

| 컬럼 | 뜻 |
|---|---|
| `sent_lsn` | walsender가 보낸 곳까지 |
| `write_lsn` | standby가 운영체제에 write한 곳까지 |
| `flush_lsn` | standby가 fsync까지 끝낸 곳까지 |
| `replay_lsn` | standby가 재생한 곳까지 |
| `write_lag`, `flush_lag`, `replay_lag` | primary가 WAL을 flush한 뒤, standby가 그 위치를 write, flush, 재생했다는 보고를 받기까지 걸린 시간 |

`primary의 현재 위치 - sent_lsn`이 크면 walsender가 보내는 쪽이, `sent_lsn - write_lsn`이 크면 네트워크나 standby의 수신이, `write_lsn - flush_lsn`이 크면 standby의 fsync가, `flush_lsn - replay_lsn`이 크면 standby의 재생(startup)이 병목입니다. 이렇게 나눠 보면 "복제가 느리다"의 원인을 좁힐 수 있습니다. 비동기 standby에서 `replay_lag`는 "primary에서 커밋한 뒤 standby 쿼리에 보이기까지"의 시간에 가깝습니다([pg_stat_replication](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW)).

### 동기 복제: 커밋이 standby를 기다린다

기본은 **비동기 복제**입니다. primary의 커밋은 자기 WAL만 flush하고 끝나며, standby는 조금 늦게 따라옵니다. primary가 그 사이에 죽고 standby를 승격하면, 마지막 몇 커밋이 standby에 없을 수 있습니다.

`synchronous_standby_names`에 standby 이름을 적으면 **동기 복제**가 됩니다.

{{< diagram src="/diagrams/pg-sync-commit.html" title="동기 복제에서 COMMIT 한 번이 기다리는 것" height="640" caption="먼저 primary의 WAL을 flush하고, standby가 같은 위치까지 flush했다는 보고가 올 때까지 기다린 뒤에 커밋 완료를 돌려줍니다." >}}

1. 커밋 레코드를 primary에서 flush합니다. 여기까지는 비동기와 같고, 이 flush가 walsender도 깨웁니다. **이 순간 WAL과 커밋 로그에는 이미 커밋으로 기록되어 되돌릴 수 없습니다.** 다만 대기가 끝나기 전까지 다른 세션에는 아직 보이지 않습니다([`xact.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xact.c#L1548-L1557)).
2. backend는 동기 복제 대기열에 들어가 기다립니다([`SyncRepWaitForLSN()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/syncrep.c#L148), 호출은 [`xact.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xact.c#L1557)).
3. standby가 그 위치까지 처리했다고 보고하면 walsender가 대기열의 backend를 깨웁니다([`walsender.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L2537)).

무엇을 기다릴지는 `synchronous_commit`이 정합니다([`xact.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/access/xact.h#L69-L80)).

| `synchronous_commit` | standby에서 기다리는 것 |
|---|---|
| `remote_write` | write (운영체제까지) |
| `on` (기본값) | flush (디스크까지) |
| `remote_apply` | 재생까지. 커밋 직후 standby에서 읽어도 보임 |
| `local`, `off` | standby를 기다리지 않음 |

1단계에서 이미 로컬 커밋이 끝났다는 점이 중요합니다. 기다리던 중에 취소하면 커밋이 되돌려지는 것이 아니라, **"로컬에서는 커밋되었지만 standby에는 아직 없을 수 있다"는 경고**와 함께 대기만 끝납니다([`syncrep.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/syncrep.c#L317-L323), 실습 6). 또 standby가 하나뿐인데 그 standby가 멈추면 primary의 모든 커밋이 멈춥니다. 그래서 동기 복제는 보통 standby를 둘 이상 두고 `ANY 1 (s1, s2)`처럼 지정합니다.

### hot standby 충돌

standby의 읽기 쿼리는 자기 스냅숏([4편](/posts/postgresql/04-mvcc/))으로 옛 행 버전을 보고 있을 수 있습니다. 그런데 primary에서 VACUUM(이나 페이지 정리, [5편](/posts/postgresql/05-vacuum/))이 그 버전을 지우면, 그 정리 기록이 WAL로 standby에 옵니다. standby의 startup은 이 기록을 재생해야 하는데, 재생하면 쿼리가 보던 행이 사라집니다.

startup은 충돌하는 WAL을 **받은 시각부터** `max_standby_streaming_delay`(기본 30초)가 지날 때까지 쿼리가 끝나기를 기다리고, 그래도 안 끝나면 쿼리를 취소하고 재생을 계속합니다([`GetStandbyLimitTime()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/standby.c#L201), [`ResolveRecoveryConflictWithSnapshot()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/standby.c#L468)). 재생을 무한정 멈출 수는 없기 때문입니다. `hot_standby_feedback = on`으로 두면 standby가 자기 쿼리의 xmin을 primary에 알려서 primary의 VACUUM이 그 버전을 지우지 않게 할 수 있습니다([`ProcessStandbyHSFeedbackMessage()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L2633)). 대신 standby의 긴 쿼리가 primary의 VACUUM을 막아 primary에 bloat가 생깁니다([5편](/posts/postgresql/05-vacuum/)).

### replication slot: WAL을 붙잡아 두는 약속

primary는 체크포인트 때 REDO 위치 이전의 WAL을 지웁니다([8편](/posts/postgresql/08-checkpoint-and-recovery/)). standby가 잠시 끊겼다가 돌아왔는데 그동안 필요한 WAL이 지워졌다면, standby는 더 따라갈 수 없고 백업부터 다시 만들어야 합니다.

**replication slot**은 "이 standby가 아직 받지 못한 WAL은 지우지 말라"는 약속입니다. slot에는 standby가 flush했다고 보고한 위치가 `restart_lsn`으로 기록되고([`PhysicalConfirmReceivedLocation()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L2412)), 체크포인트는 모든 slot의 `restart_lsn` 가운데 가장 오래된 것 이후의 WAL을 남깁니다([`KeepLogSeg()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7991-L8001)). slot은 standby가 끊겨 있어도 유지됩니다.

문제는 standby가 **영영 돌아오지 않을 때**입니다. slot이 WAL을 계속 붙잡아 `pg_wal`이 끝없이 커지고, 결국 디스크가 가득 차면 primary가 멈춥니다([7편](/posts/postgresql/07-wal/)). 이를 막는 설정이 두 가지 있습니다.

- **`max_slot_wal_keep_size`**: slot이 붙잡을 수 있는 WAL의 상한입니다(기본 -1, 무제한). 넘으면 체크포인트가 그 slot을 **무효화(invalidate)**하고 WAL을 지웁니다(보존 상한 계산은 [`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L8012-L8020), 무효화는 [`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7356-L7358)).
- **`idle_replication_slot_timeout`** (PG18 신규): 이 시간보다 오래 쓰이지 않은 slot을 체크포인트 때 무효화합니다(기본 0, 끔). WAL을 예약한(`restart_lsn`이 있는) slot만 대상입니다.

slot의 상태는 `pg_replication_slots.wal_status`로 봅니다([`GetWALAvailability()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7907)).

| `wal_status` | 뜻 |
|---|---|
| `reserved` | 필요한 WAL이 `max_wal_size` 안에 있음 |
| `extended` | `max_wal_size`를 넘었지만 slot 때문에 남겨 두고 있음 |
| `unreserved` | 다음 체크포인트에 지워질 수 있음 |
| `lost` | 필요한 WAL이 이미 지워졌거나 slot이 무효화됨. 이 slot으로는 복제를 이어갈 수 없음 |

## 직접 확인해 보기

### 실습 환경

[실습 이미지](/labs/pg-lab-image/Dockerfile)로 [lab.sh](/labs/pg-09-streaming-replication/lab.sh)가 새 컨테이너에서 처음부터 끝까지 실행했습니다(공용 함수는 [labkit.sh](/labs/common/labkit.sh)). 원본 출력은 [final-run.log](/labs/pg-09-streaming-replication/final-run.log)에 있습니다. 한 컨테이너 안에 primary(포트 5432)와 standby(포트 5433) 두 클러스터를 띄우고, 프로세스 이름에 어느 쪽인지 나오도록 `cluster_name`을 붙였습니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18-lab sleep infinity
```

```text
8cd799cbc7c8eb369c85839e846248854f810bda9d714c3b7a381cf41f124323
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
cluster_name = 'primary'
CONF
pg_ctl -D $PGDATA -l /home/postgres/primary.log start
psql -X -q -c "CREATE TABLE acct (id int PRIMARY KEY, balance int, pad text)"
psql -X -q -c "INSERT INTO acct SELECT g, 100, repeat('p', 200) FROM generate_series(1, 200000) g"
```

```text
waiting for server to start.... done
server started
[exit=0]
```

### 실습 1. standby 만들기: pg_basebackup -R

```bash
pg_basebackup -D /home/postgres/standby -R -C -S standby1 -c fast && echo "base backup ok"
ls /home/postgres/standby/standby.signal
cat /home/postgres/standby/postgresql.auto.conf
cat >> /home/postgres/standby/postgresql.auto.conf <<'CONF'
port = 5433
cluster_name = 'standby1'
CONF
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 1
grep -E "entering standby mode|redo starts|consistent recovery state|ready to accept read-only|started streaming" /home/postgres/standby.log | cut -c1-160
```

```text
base backup ok
/home/postgres/standby/standby.signal
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'user=postgres passfile=''/home/postgres/.pgpass'' channel_binding=disable port=5432 sslmode=disable sslnegotiation=postgres sslcompression=0 sslcertmode=disable sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=disable krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'
primary_slot_name = 'standby1'
waiting for server to start.... done
server started
2026-09-24 04:29:34.369 UTC [74] startup LOG:  entering standby mode
2026-09-24 04:29:34.372 UTC [74] startup LOG:  redo starts at 0/6000028
2026-09-24 04:29:34.372 UTC [74] startup LOG:  consistent recovery state reached at 0/6000120
2026-09-24 04:29:34.372 UTC [68] postmaster LOG:  database system is ready to accept read-only connections
2026-09-24 04:29:34.374 UTC [75] walreceiver LOG:  started streaming WAL from primary at 0/7000000 on timeline 1
[exit=0]
```

- `pg_basebackup -R -C -S standby1`은 베이스 백업을 뜨면서([8편](/posts/postgresql/08-checkpoint-and-recovery/)) primary에 `standby1`이라는 slot을 만들고(`-C -S`), standby로 시작하는 데 필요한 설정을 적어 줍니다(`-R`).
- `standby.signal` 파일이 있으면 서버는 복구를 끝내지 않고 standby로 남습니다. `postgresql.auto.conf`에는 primary 접속 정보(`primary_conninfo`)와 쓸 slot 이름(`primary_slot_name`)이 들어갔습니다.
- standby 로그를 보면 `entering standby mode`로 시작해 백업의 REDO 위치부터 재생하고(`redo starts at 0/6000028`), 백업이 끝난 위치에서 일관된 상태가 되자(`consistent recovery state reached`) 읽기 접속을 받기 시작합니다. 그리고 walreceiver가 `0/7000000`부터 스트리밍을 시작했습니다.

### 실습 2. 복제를 담당하는 프로세스

```bash
ps -eo pid,args | grep -E "postgres: (primary|standby1): (walsender|walreceiver|startup)" | grep -v grep
```

```text
     74 postgres: standby1: startup waiting for 000000010000000000000007
     75 postgres: standby1: walreceiver 
     76 postgres: primary: walsender postgres [local] START_REPLICATION
[exit=0]
```

primary에는 `walsender`가, standby에는 `walreceiver`와 `startup`이 있습니다. walsender는 복제 명령 `START_REPLICATION`을 처리하는 중이고, startup은 다음 WAL 파일(`...07`)이 오기를 기다리고 있습니다.

### 실습 3. pg_stat_replication과 pg_stat_wal_receiver

```bash
psql -X -p 5432 -x -c "SELECT pid, application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag, sync_state FROM pg_stat_replication"
psql -X -p 5433 -x -c "SELECT pid, status, receive_start_lsn, written_lsn, flushed_lsn, slot_name FROM pg_stat_wal_receiver"
psql -X -p 5432 -At -c "SELECT 'primary: in_recovery=' || pg_is_in_recovery()"
psql -X -p 5433 -At -c "SELECT 'standby: in_recovery=' || pg_is_in_recovery()"
```

```text
-[ RECORD 1 ]----+----------------
pid              | 76
application_name | standby1
state            | streaming
sent_lsn         | 0/7000000
write_lsn        | 0/7000000
flush_lsn        | 0/7000000
replay_lsn       | 0/7000000
write_lag        | 00:00:00.000024
flush_lag        | 00:00:00.000024
replay_lag       | 00:00:00.000024
sync_state       | async

-[ RECORD 1 ]-----+----------
pid               | 75
status            | streaming
receive_start_lsn | 0/7000000
written_lsn       | 
flushed_lsn       | 0/7000000
slot_name         | standby1

primary: in_recovery=false
standby: in_recovery=true
[exit=0]
```

- primary 쪽 `pg_stat_replication`에는 standby 하나가 `streaming` 상태, `async`(비동기)로 보입니다. 네 위치가 모두 `0/7000000`으로 같아 완전히 따라온 상태입니다.
- standby 쪽 `pg_stat_wal_receiver`는 같은 연결을 반대편에서 본 것이고, `standby1` slot을 쓰고 있습니다. `written_lsn`이 비어 있는 것은 스트리밍을 시작한 뒤 아직 새로 받아 쓴 WAL이 없기 때문입니다.
- `pg_is_in_recovery()`가 standby에서 `true`입니다. standby는 계속 복구 중인 서버입니다.

### 실습 4. primary의 변경이 standby에 보인다

```bash
psql -X -p 5432 -q -c "INSERT INTO acct VALUES (200001, 1, 'from primary')"
psql -X -p 5432 -c "SELECT pg_current_wal_lsn() AS primary_lsn"
sleep 1
psql -X -p 5433 -c "SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed"
psql -X -p 5433 -c "SELECT * FROM acct WHERE id = 200001"
psql -X -p 5433 -c "INSERT INTO acct VALUES (200002, 1, 'from standby')"
```

```text
 primary_lsn 
-------------
 0/7002148
(1 row)

 received  | replayed  
-----------+-----------
 0/7002148 | 0/7002148
(1 row)

   id   | balance |     pad      
--------+---------+--------------
 200001 |       1 | from primary
(1 row)

ERROR:  cannot execute INSERT in a read-only transaction
[exit=1]
```

primary에서 넣은 행이 1초 뒤 standby에 보이고, standby가 받은 위치와 재생한 위치가 primary의 위치 `0/7002148`과 같습니다. standby에 쓰려고 하면 `read-only transaction` 오류가 납니다.

### 실습 5. 전송, 기록, 재생: 재생만 늦추면

standby에 `recovery_min_apply_delay = '5s'`를 걸어, WAL은 받되 커밋 레코드의 재생을 5초 늦춥니다([`recoveryApplyDelay()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlogrecovery.c#L3019)).

```bash
psql -X -p 5433 -q -c "ALTER SYSTEM SET recovery_min_apply_delay = '5s'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 1
psql -X -p 5432 -q -c "INSERT INTO acct VALUES (200003, 1, 'delayed')"
sleep 1
psql -X -p 5432 -x -c "SELECT pg_current_wal_lsn() AS primary_lsn, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication"
psql -X -p 5433 -c "SELECT count(*) AS delayed_row_visible FROM acct WHERE id = 200003"
sleep 6
psql -X -p 5433 -c "SELECT count(*) AS delayed_row_visible FROM acct WHERE id = 200003"
psql -X -p 5432 -x -c "SELECT replay_lsn, replay_lag FROM pg_stat_replication"
psql -X -p 5433 -q -c "ALTER SYSTEM RESET recovery_min_apply_delay" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
-[ RECORD 1 ]----------------
primary_lsn | 0/70021F8
sent_lsn    | 0/70021F8
write_lsn   | 0/70021F8
flush_lsn   | 0/70021F8
replay_lsn  | 0/7002148
write_lag   | 00:00:00.000221
flush_lag   | 00:00:00.000687
replay_lag  | 00:00:00.000687

 delayed_row_visible 
---------------------
                   0
(1 row)

 delayed_row_visible 
---------------------
                   1
(1 row)

-[ RECORD 1 ]--------------
replay_lsn | 0/70021F8
replay_lag | 00:00:05.00795

[exit=0]
```

INSERT 1초 뒤 primary에서 보면, `sent_lsn`, `write_lsn`, `flush_lsn`은 primary 위치 `0/70021F8`까지 왔는데 `replay_lsn`만 `0/7002148`(실습 4의 위치)에 머물러 있습니다. WAL은 standby 디스크에 도착했지만 재생만 기다리는 중이라, standby에서는 새 행이 아직 보이지 않습니다(0).

lag 값은 standby의 보고를 **받은 순간**에, 그 위치를 primary가 flush한 시각과 비교해 계산합니다([`walsender.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L2488-L2490)). 이때의 `replay_lag`(0.000687초)가 `flush_lag`와 같은 것은, flush 보고를 받은 순간에 "아직 재생하지 않은 새 WAL을 지금 재생했다면"이라는 가정으로 계산한 값이기 때문입니다([`LagTrackerRead()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c#L4235)). 그 뒤 새 보고가 없어 값이 그대로 멈춰 있었습니다. 재생이 끝나자 startup이 곧바로 보고를 보내게 했고, `replay_lag`가 5.00795초로 바뀌었습니다. 늦춘 5초가 그대로 재생 지연으로 측정되었습니다. 참고로 `replay_lsn`은 primary가 마지막으로 받은 보고 기준이고, standby의 실제 재생 위치는 standby에서 `pg_last_wal_replay_lsn()`으로 봅니다.

### 실습 6. 동기 복제: 커밋이 standby를 기다린다

`synchronous_standby_names = 'standby1'`로 동기 복제를 켭니다. standby의 이름은 standby의 `cluster_name`에서 왔습니다(`primary_conninfo`에 `application_name`이 없으면 walreceiver가 `cluster_name`을 대신 씁니다).

```bash
psql -X -p 5432 -q -c "ALTER SYSTEM SET synchronous_standby_names = 'standby1'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 1
psql -X -p 5432 -c "SELECT application_name, sync_state FROM pg_stat_replication"
psql -X -p 5432 -c "\timing on" -c "INSERT INTO acct VALUES (200004, 1, 'sync ok')"
pg_ctl -D /home/postgres/standby stop -m fast
```

```text
 application_name | sync_state 
------------------+------------
 standby1         | sync
(1 row)

Timing is on.
INSERT 0 1
Time: 1.655 ms
waiting for server to shut down.... done
server stopped
[exit=0]
```

standby가 살아 있을 때 INSERT는 1.655ms에 끝났습니다. 이제 standby를 멈춘 상태에서 세션 A가 INSERT를 합니다.

```sql
-- 세션 A
INSERT INTO acct VALUES (200005, 1, 'sync wait');
```

3초가 지나도 응답이 없습니다. 다른 세션에서 보면, 세션 A는 `SyncRep` 대기 이벤트에서 기다리고 있습니다. 이 backend를 취소합니다.

```bash
psql -X -p 5432 -c "SELECT pid, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
psql -X -p 5432 -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
```

```text
 pid | state  | wait_event_type | wait_event |                       query                       
-----+--------+-----------------+------------+---------------------------------------------------
 171 | active | IPC             | SyncRep    | INSERT INTO acct VALUES (200005, 1, 'sync wait');
(1 row)

 pg_cancel_backend 
-------------------
 t
(1 row)

[exit=0]
```

```text
WARNING:  canceling wait for synchronous replication due to user request
DETAIL:  The transaction has already committed locally, but might not have been replicated to the standby.
INSERT 0 1
```

```bash
psql -X -p 5432 -c "SELECT * FROM acct WHERE id = 200005"
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 1
psql -X -p 5433 -c "SELECT * FROM acct WHERE id = 200005"
psql -X -p 5432 -q -c "ALTER SYSTEM RESET synchronous_standby_names" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
   id   | balance |    pad    
--------+---------+-----------
 200005 |       1 | sync wait
(1 row)

waiting for server to start.... done
server started
   id   | balance |    pad    
--------+---------+-----------
 200005 |       1 | sync wait
(1 row)

[exit=0]
```

- 세션 A는 취소된 뒤 `canceling wait for synchronous replication` 경고와 함께 `INSERT 0 1`을 받았습니다. DETAIL이 말하듯 **로컬에서는 이미 커밋되었고**, standby에는 복제되지 않았을 수 있다는 뜻입니다.
- 실제로 primary에서 200005번 행이 보입니다.
- standby를 다시 켜자 walreceiver가 밀린 WAL을 받아, standby에서도 그 행이 보입니다.

동기 복제는 "standby에 없으면 커밋하지 않는다"가 아니라 "standby에 닿기 전에는 커밋 완료를 알리지 않는다"입니다. 대기를 취소하거나 그 사이 primary가 죽으면, 클라이언트는 결과를 모르지만 로컬 커밋은 남아 있을 수 있습니다.

### 실습 7. standby 쿼리와 WAL 재생의 충돌

standby의 `max_standby_streaming_delay`를 3초로 줄이고, standby에서 20초 걸리는 쿼리를 돌리는 동안 primary에서 행을 지우고 VACUUM합니다.

```bash
psql -X -p 5433 -c "SHOW max_standby_streaming_delay" -c "SHOW hot_standby_feedback"
psql -X -p 5433 -q -c "ALTER SYSTEM SET max_standby_streaming_delay = '3s'" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
 max_standby_streaming_delay 
-----------------------------
 30s
(1 row)

 hot_standby_feedback 
----------------------
 off
(1 row)

[exit=0]
```

```sql
-- 세션 B
SELECT count(*), pg_sleep(20) FROM acct;
```

```bash
psql -X -p 5432 -q -c "DELETE FROM acct WHERE id > 200000"
psql -X -p 5432 -q -c "VACUUM acct"
```

```text
[exit=0]
```

```text
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

```bash
grep -E "conflict with recovery|recovery conflict" /home/postgres/standby.log | tail -3 | cut -c1-200
psql -X -p 5433 -c "SELECT datname, confl_snapshot FROM pg_stat_database_conflicts WHERE datname = 'postgres'"
psql -X -p 5433 -q -c "ALTER SYSTEM RESET max_standby_streaming_delay" -c "SELECT pg_reload_conf()" > /dev/null
```

```text
2026-09-24 04:29:59.251 UTC [276] client backend ERROR:  canceling statement due to conflict with recovery
 datname  | confl_snapshot 
----------+----------------
 postgres |              1
(1 row)

[exit=0]
```

standby의 쿼리가 `canceling statement due to conflict with recovery`로 취소되었습니다. DETAIL은 "쿼리가 봐야 할 수도 있는 행 버전을 지워야 한다"는 뜻입니다. primary의 VACUUM이 지운 행 버전(실습 4~6에서 넣었다가 DELETE한 행)의 정리 기록을 재생하려다, 그 버전을 볼 수도 있는 쿼리의 스냅숏과 부딪혔습니다. startup은 `max_standby_streaming_delay`(3초)까지 기다린 뒤 쿼리를 취소하고 재생을 계속했고, standby의 `pg_stat_database_conflicts.confl_snapshot`이 1이 되었습니다. 기본값(30초)이었다면 이 20초짜리 쿼리는 취소되지 않았을 것입니다. 대신 쿼리가 끝날 때까지 재생이 멈춰 standby가 그만큼 뒤처졌을 것입니다.

### 실습 8. replication slot은 standby가 멈춰도 WAL을 붙잡는다

primary의 `max_wal_size`를 64MB로 줄이고, standby를 멈춘 채 전체 행 UPDATE를 세 번 한 뒤 체크포인트합니다.

```bash
psql -X -p 5432 -q -c "ALTER SYSTEM SET max_wal_size = '64MB'" -c "SELECT pg_reload_conf()" > /dev/null
pg_ctl -D /home/postgres/standby stop -m fast
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, pg_size_pretty(safe_wal_size) AS safe_wal_size FROM pg_replication_slots"
for i in 1 2 3; do psql -X -p 5432 -q -c "UPDATE acct SET balance = balance + 1"; done
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots"
du -sh $PGDATA/pg_wal
```

```text
waiting for server to shut down.... done
server stopped
 slot_name | active | restart_lsn | wal_status | safe_wal_size 
-----------+--------+-------------+------------+---------------
 standby1  | f      | 0/A0543F0   | reserved   | 
(1 row)

 slot_name | active | restart_lsn | wal_status | retained 
-----------+--------+-------------+------------+----------
 standby1  | f      | 0/A0543F0   | extended   | 479 MB
(1 row)

497M	/var/lib/postgresql/data/pg_wal
[exit=0]
```

- standby를 멈춘 직후 slot은 `active = f`이고 `wal_status`는 `reserved`입니다. `safe_wal_size`가 비어 있는 것은 `max_slot_wal_keep_size`가 무제한(-1)이라 "지워지기까지 남은 양"이라는 것이 없기 때문입니다.
- UPDATE 세 번과 `CHECKPOINT` 뒤에도 `restart_lsn`은 standby가 멈춘 위치 `0/A0543F0`에 그대로이고, 그 뒤로 479MB의 WAL을 붙잡고 있습니다. `max_wal_size`(64MB)를 한참 넘었으므로 `wal_status`가 `extended`가 되었고, `pg_wal` 디렉터리는 497MB입니다. 체크포인트를 했는데도 WAL을 지우지 못한 것입니다.

### 실습 9. max_slot_wal_keep_size: 너무 많이 붙잡으면 slot을 포기한다

```bash
psql -X -p 5432 -q -c "ALTER SYSTEM SET max_slot_wal_keep_size = '128MB'" -c "SELECT pg_reload_conf()" > /dev/null
psql -X -p 5432 -q -c "UPDATE acct SET balance = balance + 1"
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, restart_lsn, wal_status, invalidation_reason FROM pg_replication_slots"
grep -E "invalidating obsolete replication slot|exceeds the limit" /home/postgres/primary.log | cut -c1-200
du -sh $PGDATA/pg_wal
pg_ctl -D /home/postgres/standby -l /home/postgres/standby.log start
sleep 2
grep -E "could not start WAL streaming" /home/postgres/standby.log | tail -1 | cut -c1-200
```

```text
 slot_name | active | restart_lsn | wal_status | invalidation_reason 
-----------+--------+-------------+------------+---------------------
 standby1  | f      |             | lost       | wal_removed
(1 row)

2026-09-24 04:30:04.892 UTC [42] checkpointer LOG:  invalidating obsolete replication slot "standby1"
2026-09-24 04:30:04.892 UTC [42] checkpointer DETAIL:  The slot's restart_lsn 0/A0543F0 exceeds the limit by 419085328 bytes.
65M	/var/lib/postgresql/data/pg_wal
waiting for server to start.... done
server started
2026-09-24 04:30:05.567 UTC [398] walreceiver FATAL:  could not start WAL streaming: ERROR:  can no longer access replication slot "standby1"
[exit=0]
```

- `max_slot_wal_keep_size`를 128MB로 정하고 체크포인트하자, checkpointer가 `invalidating obsolete replication slot "standby1"`을 남기고 slot을 무효화했습니다. DETAIL은 `restart_lsn`이 상한을 419085328바이트(약 400MB) 넘었다는 뜻입니다.
- slot은 `lost`, 원인은 `wal_removed`가 되었고 `restart_lsn`은 비었습니다. `pg_wal`은 65MB로 줄었습니다.
- standby를 다시 켜도 walreceiver가 `can no longer access replication slot`으로 실패합니다. WAL 아카이브([8편](/posts/postgresql/08-checkpoint-and-recovery/))가 없다면 이 standby는 새 베이스 백업으로 다시 만들어야 합니다. primary의 디스크를 지키는 대신 standby를 포기한 것입니다.

### 실습 10. idle_replication_slot_timeout (PG18)

아무도 쓰지 않는 slot `forgotten`을 만들고, 1초 이상 쉰 slot을 무효화하도록 설정합니다.

```bash
psql -X -p 5432 -c "SELECT * FROM pg_create_physical_replication_slot('forgotten', true)"
psql -X -p 5432 -q -c "ALTER SYSTEM SET idle_replication_slot_timeout = '1s'" -c "SELECT pg_reload_conf()" > /dev/null
sleep 2
psql -X -p 5432 -q -c "CHECKPOINT"
psql -X -p 5432 -c "SELECT slot_name, active, inactive_since IS NOT NULL AS has_inactive_since, wal_status, invalidation_reason FROM pg_replication_slots ORDER BY slot_name"
grep -E "invalidating obsolete replication slot \"forgotten\"" -A1 /home/postgres/primary.log | cut -c1-200
```

```text
 slot_name |    lsn     
-----------+------------
 forgotten | 0/3355E610
(1 row)

 slot_name | active | has_inactive_since | wal_status | invalidation_reason 
-----------+--------+--------------------+------------+---------------------
 forgotten | f      | t                  | lost       | idle_timeout
 standby1  | f      | t                  | lost       | wal_removed
(2 rows)

2026-09-24 04:30:09.773 UTC [42] checkpointer LOG:  invalidating obsolete replication slot "forgotten"
2026-09-24 04:30:09.773 UTC [42] checkpointer DETAIL:  The slot's idle time of 2s exceeds the configured "idle_replication_slot_timeout" duration of 1s.
[exit=0]
```

- 1초 넘게 쉰 `forgotten` slot을 체크포인트가 무효화했습니다. 원인은 `idle_timeout`이고, 로그에 쉰 시간(2s)과 설정값(1s)이 나옵니다.
- 이 검사는 **체크포인트 때** 합니다([`xlog.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/access/transam/xlog.c#L7356-L7358)). 두 번째 인자 `true`로 slot을 만들 때 WAL을 바로 예약했기 때문에 대상이 되었습니다. 그래서 실제로 무효화되는 시점은 설정값보다 체크포인트 간격만큼 늦을 수 있습니다. 실습에서는 `CHECKPOINT`로 바로 확인했습니다.
- slot은 한 번 무효화되면 되살릴 수 없습니다. 운영에서는 며칠처럼 넉넉한 값을 씁니다.

## 운영에서는 이렇게 나타납니다

### 방치된 slot이 디스크를 가득 채운다

가장 흔한 복제 사고입니다. standby를 없애거나 논리 복제 구독을 지우면서 slot을 지우지 않으면, 실습 8처럼 `pg_wal`이 끝없이 커집니다. `pg_replication_slots`에서 `active = false`이면서 `restart_lsn`이 오래된 slot을 주기적으로 확인하고, 쓰지 않는 slot은 `pg_drop_replication_slot()`으로 지워야 합니다. 안전장치로 `max_slot_wal_keep_size`를 디스크 여유에 맞게 정해 두면, 최악의 경우 standby 하나를 다시 만드는 것으로 끝나고 primary는 멈추지 않습니다. PG18에서는 `idle_replication_slot_timeout`도 쓸 수 있습니다.

### standby 쿼리가 자주 취소된다

`canceling statement due to conflict with recovery`가 자주 나오면 선택지는 세 가지입니다.

- `max_standby_streaming_delay`를 늘립니다. 대신 쿼리가 도는 동안 재생이 멈춰 standby가 그만큼 뒤처집니다.
- `hot_standby_feedback = on`으로 둡니다. 대신 standby의 긴 쿼리가 primary의 VACUUM을 막습니다.
- 분석용 긴 쿼리는 재생 지연을 감수하는 별도 standby로 보냅니다.

어떤 종류의 충돌인지는 standby의 `pg_stat_database_conflicts`에서 나눠 볼 수 있습니다.

### 복제 지연은 나눠서 본다

`pg_stat_replication`의 네 위치로 지연이 어디서 생기는지 먼저 나눕니다. `replay_lsn`만 뒤처진다면 standby의 재생이 느린 것이고, 원인은 standby의 I/O 부족이나 실습 7 같은 쿼리 충돌 대기인 경우가 많습니다. 재생은 startup 프로세스 하나가 순서대로 하므로([8편](/posts/postgresql/08-checkpoint-and-recovery/)), primary에서 여러 세션이 병렬로 만든 WAL을 standby가 따라잡지 못할 수도 있습니다.

## 정리

- **스트리밍 복제**는 standby가 primary의 WAL을 계속 받아 재생하는 "끝나지 않는 복구"입니다. primary의 **walsender**가 보내고, standby의 **walreceiver**가 받아 쓰고, **startup**이 재생합니다.
- standby는 write, flush, apply 위치를 primary에 보고하고, `pg_stat_replication`의 네 위치와 lag 컬럼으로 지연이 전송, 기록, 재생 중 어디서 생기는지 볼 수 있습니다.
- **동기 복제**에서 커밋은 로컬 flush 뒤 standby의 보고를 기다립니다. 기다리다 취소해도 로컬 커밋은 되돌아가지 않습니다.
- standby의 읽기 쿼리는 재생과 충돌하면 `max_standby_streaming_delay` 뒤에 취소됩니다.
- **replication slot**은 standby가 받지 못한 WAL을 지우지 않게 하지만, 방치하면 디스크를 채웁니다. `max_slot_wal_keep_size`와 PG18의 `idle_replication_slot_timeout`이 안전장치입니다.

다음 글에서는 시리즈의 마지막으로, SQL 한 줄이 결과가 되기까지의 **쿼리 처리 과정과 통계 정보**를 살펴봅니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/replication/walsender.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walsender.c): WAL 전송, standby 보고 처리
- [src/backend/replication/walreceiver.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/walreceiver.c): WAL 수신, 위치 보고
- [src/backend/replication/syncrep.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/syncrep.c): 동기 복제 대기
- [src/backend/replication/slot.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/replication/slot.c): replication slot, 무효화
- [src/backend/storage/ipc/standby.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/standby.c): hot standby 충돌 처리

PostgreSQL 18 공식 문서

- [Streaming Replication](https://www.postgresql.org/docs/18/warm-standby.html#STREAMING-REPLICATION), [Replication Slots](https://www.postgresql.org/docs/18/warm-standby.html#STREAMING-REPLICATION-SLOTS)
- [Synchronous Replication](https://www.postgresql.org/docs/18/warm-standby.html#SYNCHRONOUS-REPLICATION)
- [Hot Standby: Handling Query Conflicts](https://www.postgresql.org/docs/18/hot-standby.html#HOT-STANDBY-CONFLICT)
- [pg_stat_replication](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW), [pg_replication_slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html)
- [max_slot_wal_keep_size](https://www.postgresql.org/docs/18/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE), [idle_replication_slot_timeout](https://www.postgresql.org/docs/18/runtime-config-replication.html#GUC-IDLE-REPLICATION-SLOT-TIMEOUT)

실습 파일

- [실습 이미지 Dockerfile](/labs/pg-lab-image/Dockerfile), [labkit.sh](/labs/common/labkit.sh), [lab.sh](/labs/pg-09-streaming-replication/lab.sh), [final-run.log](/labs/pg-09-streaming-replication/final-run.log)
