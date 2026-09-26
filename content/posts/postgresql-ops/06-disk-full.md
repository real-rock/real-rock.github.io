---
title: "PostgreSQL 운영 6: 디스크가 찬다"
date: 2026-09-26T19:24:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "디스크", "WAL", "No space left on device", "archive command failed", "temp_file_limit"]
weight: 6
summary: "데이터는 그대로인데 디스크가 찬다면 무엇이 차지하고 있고, 가득 차면 어떻게 되며, 어떻게 되살리는가"
description: "pg_wal 증가, temp file, 디스크가 가득 찼을 때의 동작"
---

## 개요

디스크 사용률 알람이 울립니다. 데이터가 갑자기 늘어난 것도 아닌데 여유 공간이 빠르게 줄어듭니다. PostgreSQL 서버의 디스크를 채우는 것은 테이블만이 아닙니다. **WAL**(`pg_wal`), **임시 파일**, 서버 로그, 그리고 [5편](/posts/postgresql-ops/05-table-bloat/)의 bloat가 있습니다. 이 가운데 가장 위험한 것은 WAL입니다. 지워져야 할 WAL이 지워지지 않으면 디스크가 가득 차고, WAL을 쓰지 못하면 서버가 멈춥니다.

이 글에서 답할 질문은 다음과 같습니다.

- 디스크를 무엇이 차지하고 있는지 어떻게 나눠 보는가
- WAL이 지워지지 않는 원인(아카이브 실패, 쓰지 않는 replication slot)은 어떻게 보이는가
- 디스크가 가득 차면 PostgreSQL은 어떻게 되고, 어떻게 되살리는가
- 임시 파일이 디스크를 채우는 것은 어떻게 막는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습에서는 데이터 디렉터리를 600MB로 크기를 제한한 파일 시스템(`/pgfs`)에 두고, **서버 로그와 WAL 아카이브는 그 밖**(`/var/lib/pgsql/log`, `/var/lib/pgsql/archive`)에 둡니다. 로그를 데이터와 같은 디스크에 두면 디스크가 찼을 때 원인을 알려 줄 로그마저 쓰지 못하기 때문입니다. 운영에서도 로그는 데이터와 다른 디스크에 두는 편이 안전합니다.

```console
$ df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M   39M  562M   7% /pgfs
```

## 먼저 확인할 것

디스크 사용량을 DB 파일과 WAL로 나눠 봅니다. `pg_ls_waldir()`는 `pg_wal`의 파일 목록과 크기를 돌려줍니다.

```sql
SELECT pg_size_pretty(pg_database_size('postgres')) AS db,
       (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS pg_wal,
       (SELECT count(*) FROM pg_ls_waldir()) AS wal_files;
```

`pg_wal`이 비정상적으로 크다면 다음 두 가지를 먼저 확인합니다.

1. **아카이브가 실패하고 있는가**: `pg_stat_archiver`의 `failed_count`, `last_failed_wal`
2. **WAL을 붙잡는 replication slot이 있는가**: `pg_replication_slots`의 `active`, `restart_lsn`, `wal_status`

평소 WAL은 체크포인트 때마다 필요 없어진 파일이 재활용되거나 지워지므로 대략 `max_wal_size`(기본 1GB) 근처에서 머뭅니다([인터널 7편](/posts/postgresql/07-wal/), [8편](/posts/postgresql/08-checkpoint-and-recovery/)). 이보다 한참 크다면 누군가 붙잡고 있는 것입니다.

## 원인별 진단

### 아카이브 실패: 보내지 못한 WAL은 지울 수 없다

`archive_mode = on`이면 WAL 파일은 `archive_command`로 다른 곳에 복사된 뒤에야 지우거나 재활용할 수 있습니다. 아카이브 대상(백업 서버, 마운트한 NFS 등)이 망가진 상황을 항상 실패하는 명령(`false`)으로 흉내 냅니다.

```psql
postgres=# ALTER SYSTEM SET archive_mode = on;
ALTER SYSTEM

# 아카이브 대상이 망가진 상황을 흉내 낸다: 명령이 항상 실패한다

postgres=# ALTER SYSTEM SET archive_command = 'false';
ALTER SYSTEM
```

WAL을 만드는 작업을 하고 체크포인트를 돌립니다.

```console
$ pgbench -i -s 10 -q postgres 2>&1 | tail -n 1
done in 0.42 s (drop tables 0.00 s, create tables 0.00 s, client-side generate 0.29 s, vacuum 0.03 s, primary keys 0.09 s).
```

```psql
postgres=# CHECKPOINT;
CHECKPOINT

postgres=# SELECT pg_size_pretty(pg_database_size('postgres')) AS db,
postgres-#        (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS pg_wal,
postgres-#        (SELECT count(*) FROM pg_ls_waldir()) AS wal_files;
   db   | pg_wal | wal_files
--------+--------+-----------
 157 MB | 144 MB |         9
(1 row)


postgres=# SELECT archived_count, failed_count, last_failed_wal, last_failed_time
postgres-# FROM pg_stat_archiver;
 archived_count | failed_count |     last_failed_wal      |       last_failed_time
----------------+--------------+--------------------------+-------------------------------
              0 |            1 | 000000010000000000000001 | 2026-09-26 10:23:01.860649+00
(1 row)
```

`failed_count`가 올라가고 `archived_count`는 0입니다. 보내지 못한 WAL 파일은 `pg_wal/archive_status` 아래 `.ready` 표시가 붙은 채 남습니다.

```console
$ ls $PGDATA/pg_wal/archive_status | head -n 3
$ ls $PGDATA/pg_wal/archive_status | grep -c '\.ready$'
000000010000000000000001.ready
000000010000000000000002.ready
000000010000000000000003.ready
8
```

서버 로그에는 실패할 때마다 이렇게 남습니다.

```console
$ tail -n 600 "$(ls -t /var/lib/pgsql/log/*.log | head -1)" | grep -A 1 -E 'archive command failed' | tail -n 2
2026-09-26 10:23:01.860 UTC [106] LOG:  archive command failed with exit code 1
2026-09-26 10:23:01.860 UTC [106] DETAIL:  The failed archive command was: false
```

아카이브는 실패해도 쓰기는 계속되므로, 대상이 몇 시간 동안 망가져 있으면 그동안의 WAL이 모두 `pg_wal`에 쌓입니다. 아카이브 대상을 고치면 밀린 파일을 차례로 보냅니다.

```psql
postgres=# ALTER SYSTEM SET archive_command = 'test ! -f /var/lib/pgsql/archive/%f && cp %p /var/lib/pgsql/archive/%f';
ALTER SYSTEM

postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)


postgres=# SELECT archived_count, failed_count, last_archived_wal FROM pg_stat_archiver;
 archived_count | failed_count |    last_archived_wal
----------------+--------------+--------------------------
              8 |            1 | 000000010000000000000008
(1 row)
```

밀려 있던 8개가 모두 아카이브되었습니다. 이제 다음 체크포인트부터 이 파일들을 재활용할 수 있습니다. 이 실습에서는 체크포인트 로그에 `8 recycled`로 남았습니다.

```text
2026-09-26 10:23:07.849 UTC [101] LOG:  checkpoint complete: wrote 0 buffers (0.0%), wrote 0 SLRU buffers; 0 WAL file(s) added, 0 removed, 8 recycled; write=0.001 s, sync=0.001 s, total=0.001 s; sync files=0, longest=0.000 s, average=0.000 s; distance=0 kB, estimate=113474 kB; lsn=0/927BE18, redo lsn=0/927BDC0
```

재활용된 파일은 앞으로 쓸 WAL 파일로 이름만 바뀌어 남으므로 `pg_wal`의 크기가 바로 줄지는 않지만, 더 늘지 않습니다.

### 쓰지 않는 replication slot: WAL을 끝없이 붙잡는다

replication slot은 "이 standby가 아직 받지 않은 WAL을 지우지 말라"는 약속입니다([인터널 9편](/posts/postgresql/09-streaming-replication/)). standby를 없애고 slot을 지우지 않았거나, standby가 오래 끊겨 있으면 slot은 그 시점 이후의 WAL을 모두 붙잡습니다. 아무도 쓰지 않는 slot을 하나 만들어 봅니다.

```psql
postgres=# SELECT pg_create_physical_replication_slot('standby1', true);
 pg_create_physical_replication_slot
-------------------------------------
 (standby1,0/927BDC0)
(1 row)


postgres=# SELECT slot_name, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots;
 slot_name | active | restart_lsn | wal_status | safe_wal_size
-----------+--------+-------------+------------+---------------
 standby1  | f      | 0/927BDC0   | reserved   |
(1 row)


postgres=# SHOW max_slot_wal_keep_size;
 max_slot_wal_keep_size
------------------------
 -1
(1 row)
```

`active = f`이고, `max_slot_wal_keep_size`는 기본값 `-1`(제한 없음)입니다. 부하를 20초 줍니다.

```console
$ pgbench -n -c 4 -T 20 postgres 2>&1 | grep -E 'processed|tps'
number of transactions actually processed: 251116
tps = 12556.039820 (without initial connection time)
```

```psql
postgres=# CHECKPOINT;
CHECKPOINT

postgres=# SELECT pg_size_pretty(pg_database_size('postgres')) AS db,
postgres-#        (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS pg_wal,
postgres-#        (SELECT count(*) FROM pg_ls_waldir()) AS wal_files;
   db   | pg_wal | wal_files
--------+--------+-----------
 172 MB | 256 MB |        16
(1 row)


postgres=# SELECT slot_name, active, restart_lsn,
postgres-#        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained,
postgres-#        wal_status
postgres-# FROM pg_replication_slots;
 slot_name | active | restart_lsn | retained | wal_status
-----------+--------+-------------+----------+------------
 standby1  | f      | 0/927BDC0   | 249 MB   | reserved
(1 row)
```

`retained` 249 MB가 slot이 붙잡고 있는 WAL의 양입니다. `pg_wal`은 256 MB로, 부하를 준 만큼 그대로 쌓였습니다. 체크포인트를 돌려도 이 WAL은 지워지지 않습니다. **`active = f`인데 `restart_lsn`이 오래전에 멈춘 slot**이 디스크를 채우는 대표적인 원인입니다.

```console
$ df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M  444M  157M  74% /pgfs
```

## 디스크가 가득 차면

같은 상태로 부하를 계속 주면 어떻게 되는지 봅니다. 그 전에 **비상용 여유 공간**으로 50 MB짜리 파일을 하나 만들어 둡니다. 이 파일의 쓰임새는 아래에서 봅니다.

```console
$ dd if=/dev/zero of=/pgfs/ballast bs=1M count=50 status=none && ls -lh /pgfs/ballast
-rw-r--r-- 1 postgres postgres 50M Sep 26 10:23 /pgfs/ballast
```

```console
$ timeout 300 pgbench -n -c 4 -T 280 postgres 2>&1 | tail -n 6
number of transactions actually processed: 19799
number of failed transactions: 0 (0.000%)
latency average = 0.323 ms
initial connection time = 3.756 ms
tps = 12382.834023 (without initial connection time)
pgbench: error: Run was aborted; the above results are incomplete.
[exit=0]

$ df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M  591M  9.8M  99% /pgfs
```

pgbench는 1.6초 만에 중단되었고 디스크는 99%입니다. 서버 로그를 봅니다.

```console
2026-09-26 10:23:30.180 UTC [316] postgres@postgres/pgbench PANIC:  could not write to file "pg_wal/xlogtemp.316": No space left on device
2026-09-26 10:23:30.182 UTC [96] LOG:  client backend (PID 316) was terminated by signal 6: Aborted
2026-09-26 10:23:30.182 UTC [96] LOG:  terminating any other active server processes
2026-09-26 10:23:30.182 UTC [106] FATAL:  archive command was terminated by signal 3: Quit
2026-09-26 10:23:30.187 UTC [96] LOG:  all server processes terminated; reinitializing
2026-09-26 10:23:30.204 UTC [328] LOG:  database system was interrupted; last known up at 2026-09-26 10:23:28 UTC
2026-09-26 10:23:30.206 UTC [328] LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-26 10:23:30.206 UTC [328] LOG:  redo starts at 0/18B93B20
2026-09-26 10:23:30.292 UTC [328] LOG:  redo done at 0/1EFFF3D0 system usage: CPU: user: 0.05 s, system: 0.03 s, elapsed: 0.08 s
2026-09-26 10:23:30.294 UTC [328] FATAL:  could not write to file "pg_wal/xlogtemp.328": No space left on device
2026-09-26 10:23:30.298 UTC [96] LOG:  terminating any other active server processes
2026-09-26 10:23:30.308 UTC [96] LOG:  database system is shut down
```

차례로 읽으면 이렇습니다.

1. backend가 새 WAL 파일(`xlogtemp.316`)을 만들다 공간이 없어 **PANIC**으로 죽었습니다. WAL을 쓰지 못하면 커밋을 보장할 수 없으므로, PostgreSQL은 에러로 넘기지 않고 서버 전체를 멈춥니다.
2. postmaster가 다른 프로세스를 모두 끝내고 재시작해 장애 복구를 시작합니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).
3. WAL 재생(`redo`)은 끝났지만, 복구를 마무리하려고 WAL을 쓰다가 **다시 공간이 없어** 실패합니다.
4. 서버가 내려간 채로 멈춥니다.

```console
$ pg_ctl -D $PGDATA status
pg_ctl: no server running
[exit=3]
```

**디스크를 비우지 않으면 서버는 다시 뜨지 않습니다.** 그리고 서버가 멈춰 있으니 slot을 지우는 SQL도 실행할 수 없습니다. 여기서 흔히 저지르는 실수가 `pg_wal` 안의 파일을 손으로 지우는 것입니다. 어느 파일이 복구에 필요한지는 PostgreSQL만 알고 있고, 필요한 WAL을 지우면 데이터베이스를 잃습니다. `pg_wal`은 절대 직접 지우지 않습니다.

## 조치

### 서버가 멈췄을 때: 공간을 만들고, 띄우고, 원인을 없앤다

미리 만들어 둔 비상용 파일이 여기서 쓰입니다. 지우면 곧바로 50 MB가 생깁니다.

```console
$ rm /pgfs/ballast
$ df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M  541M   60M  91% /pgfs
[exit=0]

$ pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
waiting for server to start.... done
server started
[exit=0]
```

```console
$ tail -n 600 "$(ls -t /var/lib/pgsql/log/*.log | head -1)" | grep -E 'redo|ready to accept' | tail -n 4
2026-09-26 10:23:30.531 UTC [380] LOG:  redo starts at 0/18B93B20
2026-09-26 10:23:30.617 UTC [380] LOG:  redo done at 0/1EFFF3D0 system usage: CPU: user: 0.04 s, system: 0.04 s, elapsed: 0.08 s
2026-09-26 10:23:30.643 UTC [378] LOG:  checkpoint complete: wrote 11979 buffers (73.1%), wrote 4 SLRU buffers; 0 WAL file(s) added, 0 removed, 0 recycled; write=0.022 s, sync=0.001 s, total=0.022 s; sync files=11, longest=0.001 s, average=0.000 s; distance=102833 kB, estimate=102833 kB; lsn=0/1F000058, redo lsn=0/1F000058
2026-09-26 10:23:30.644 UTC [373] LOG:  database system is ready to accept connections
```

복구를 마치고 접속을 받기 시작했습니다. 이제 SQL로 원인을 없앱니다.

```psql
postgres=# SELECT slot_name, active, wal_status FROM pg_replication_slots;
 slot_name | active | wal_status
-----------+--------+------------
 standby1  | f      | reserved
(1 row)


postgres=# SELECT pg_drop_replication_slot('standby1');
 pg_drop_replication_slot
--------------------------

(1 row)


postgres=# CHECKPOINT;
CHECKPOINT

postgres=# SELECT pg_size_pretty(pg_database_size('postgres')) AS db,
postgres-#        (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS pg_wal,
postgres-#        (SELECT count(*) FROM pg_ls_waldir()) AS wal_files;
   db   | pg_wal | wal_files
--------+--------+-----------
 173 MB | 224 MB |        14
(1 row)
```

```console
$ df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M  413M  188M  69% /pgfs
```

slot을 지우고 체크포인트를 돌리자 사용량이 541 MB에서 413 MB로 줄었습니다. 비상용 파일은 다시 만들어 둡니다.

비상용 파일이 없다면 같은 디스크에서 지워도 되는 다른 파일(오래된 로그, 덤프 파일 등)을 찾거나, 볼륨을 늘려야 합니다. 클라우드 볼륨이나 LVM처럼 온라인으로 늘릴 수 있는 환경이라면 그것이 가장 빠릅니다.

### 원인별 근본 조치

| 원인 | 확인 | 조치 |
|---|---|---|
| 아카이브 실패 | `pg_stat_archiver.failed_count`, 로그의 `archive command failed` | 아카이브 대상 복구. 밀린 WAL은 자동으로 보냄 |
| 쓰지 않는 slot | `pg_replication_slots`의 `active = f`, `restart_lsn` | 필요 없는 slot은 `pg_drop_replication_slot()` |
| slot의 무한 보존 | `max_slot_wal_keep_size = -1` | 상한을 걸어 두면 초과한 slot은 `wal_status = lost`로 무효화되고 WAL은 지워짐 |

`max_slot_wal_keep_size`를 걸면 slot이 붙잡을 수 있는 WAL에 상한이 생깁니다. 상한을 넘은 slot의 standby는 다시 구성해야 하지만, primary의 디스크가 차서 서비스 전체가 멈추는 것보다는 낫습니다([max_slot_wal_keep_size](https://www.postgresql.org/docs/18/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE)). `pg_replication_slots`의 `safe_wal_size`가 무효화까지 남은 여유를 알려 줍니다.

## 임시 파일: 쿼리만 실패한다

큰 정렬과 해시가 `work_mem`을 넘으면 임시 파일을 씁니다([1편](/posts/postgresql-ops/01-diagnostic-toolkit/)). 임시 파일로 디스크가 차면 어떻게 되는지 봅니다. 여유 공간을 30 MB만 남기고 큰 정렬을 돌립니다.

```console
$ avail=$(df --output=avail -m /pgfs | tail -n 1); dd if=/dev/zero of=/pgfs/filler bs=1M count=$((avail - 30)) status=none; df -h /pgfs
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           600M  571M   30M  96% /pgfs
```

```psql
postgres=# SET max_parallel_workers_per_gather = 0;
postgres-# SELECT count(*) FROM (SELECT * FROM pgbench_accounts ORDER BY filler, aid OFFSET 0) s;
SET
ERROR:  could not write to file "base/pgsql_tmp/pgsql_tmp459.0": No space left on device

postgres=# SELECT 1 AS still_alive;
 still_alive
-------------
           1
(1 row)
```

WAL과 달리 **쿼리 하나만 에러로 끝나고 서버는 멀쩡합니다.** 임시 파일은 그 쿼리만 쓰는 것이라 지우고 에러를 내면 그만이기 때문입니다. 하지만 그 순간 디스크가 가득 차 있으므로, 같은 때 WAL을 써야 하는 다른 세션이 있었다면 앞의 PANIC으로 이어질 수 있습니다.

`temp_file_limit`을 걸면 쿼리 하나가 쓸 수 있는 임시 파일 크기에 상한이 생깁니다.

```psql
postgres=# SET temp_file_limit = '20MB';
postgres-# SELECT count(*) FROM (SELECT * FROM pgbench_accounts ORDER BY filler, aid OFFSET 0) s;
ERROR:  temporary file size exceeds "temp_file_limit" (20480kB)
CONTEXT:  parallel worker
SET
```

20 MB를 넘자 병렬 worker에서 에러가 났습니다. 기본값은 제한 없음(-1)입니다. 애플리케이션 계정에 걸어 두면 잘못 짠 쿼리 하나가 디스크를 채우는 일을 막을 수 있습니다.

## 재발 방지

- **디스크 사용률 알람**을 두 단계로 겁니다. 경고(예: 80%)에서 원인을 찾고, 위험(예: 90%)에서 바로 조치합니다. 이 실습처럼 WAL은 몇 초 만에 수백 MB가 쌓일 수 있습니다.
- **`pg_wal` 크기와 WAL 파일 수**를 따로 감시합니다. `max_wal_size`보다 한참 크면 아카이브와 slot부터 봅니다.
- **`pg_stat_archiver.failed_count`** 증가를 알람으로 겁니다.
- **pg_replication_slots**에서 `active = f`인 slot과, `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)`이 큰 slot을 감시합니다. `max_slot_wal_keep_size`로 상한을 겁니다.
- **temp_file_limit**을 애플리케이션 계정에 겁니다. 임시 파일은 `log_temp_files`로 기록합니다.
- **비상용 여유 공간**을 데이터 디스크에 만들어 둡니다. 서버가 멈췄을 때 가장 빨리 공간을 만드는 방법입니다.
- **로그는 데이터와 다른 디스크에** 둡니다. PGDG 패키지의 기본 로그 위치는 데이터 디렉터리 안(`log/`)입니다([1편](/posts/postgresql-ops/01-diagnostic-toolkit/)).

## 정리

- 디스크는 DB 파일, WAL, 임시 파일, 로그가 나눠 씁니다. `pg_database_size()`와 `pg_ls_waldir()`로 나눠 봅니다.
- 아카이브가 실패하면 보내지 못한 WAL이 `.ready`로 쌓이고, 로그에 `archive command failed`가 남습니다. 대상을 고치면 밀린 WAL을 보냅니다.
- 쓰지 않는 replication slot은 WAL을 끝없이 붙잡습니다. `max_slot_wal_keep_size`로 상한을 겁니다.
- WAL을 쓸 공간이 없으면 `PANIC: could not write to file "pg_wal/xlogtemp...": No space left on device`로 서버가 멈추고, 복구도 WAL을 써야 하므로 공간을 만들기 전에는 다시 뜨지 않습니다. `pg_wal`을 직접 지우지 않습니다.
- 임시 파일로 디스크가 차면 그 쿼리만 실패합니다. `temp_file_limit`로 상한을 겁니다.

## 참고 자료

- [Write Ahead Log 설정](https://www.postgresql.org/docs/18/runtime-config-wal.html): `archive_mode`, `archive_command`, `max_wal_size`
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html)
- [Continuous Archiving](https://www.postgresql.org/docs/18/continuous-archiving.html)
- [pg_replication_slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html), [max_slot_wal_keep_size](https://www.postgresql.org/docs/18/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE)
- [pg_stat_archiver](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ARCHIVER-VIEW)
- [temp_file_limit](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-TEMP-FILE-LIMIT)
- PostgreSQL 인터널 [7편 WAL](/posts/postgresql/07-wal/), [8편 체크포인트와 장애 복구](/posts/postgresql/08-checkpoint-and-recovery/), [9편 스트리밍 복제](/posts/postgresql/09-streaming-replication/)

