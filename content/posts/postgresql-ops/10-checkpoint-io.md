---
title: "PostgreSQL 운영 10: 주기적으로 I/O가 튄다"
date: 2026-09-26T19:45:00+09:00
draft: false
series: ["PostgreSQL 운영"]
categories: ["PostgreSQL"]
subcategory: "운영"
tags: ["PostgreSQL", "체크포인트", "WAL", "checkpoints are occurring too frequently"]
weight: 10
summary: "몇 분마다 응답 시간이 튀고 디스크 쓰기가 몰린다면, 체크포인트를 어떻게 확인하고 무엇을 조정하는가"
description: "잦은 체크포인트, pg_stat_checkpointer, bgwriter"
---

## 개요

평소에는 괜찮다가 몇 분마다 응답 시간이 튀고, 그때마다 디스크 쓰기가 몰립니다. 이런 주기적인 패턴의 가장 흔한 원인은 **체크포인트**입니다. 체크포인트는 shared buffers의 dirty 페이지를 디스크에 내보내고, 그 뒤 처음 고치는 페이지마다 페이지 전체를 WAL에 기록하게 만듭니다(full page write)([인터널 7편](/posts/postgresql/07-wal/), [8편](/posts/postgresql/08-checkpoint-and-recovery/)). 체크포인트가 너무 잦거나 한꺼번에 몰리면 I/O와 WAL이 함께 튑니다.

이 글에서 답할 질문은 다음과 같습니다.

- 체크포인트가 너무 잦은지 어디서 보는가
- `max_wal_size`가 작으면 실제로 무엇이 얼마나 나빠지는가
- 체크포인트가 시작될 때 처리량이 떨어지는 이유는 무엇인가
- 누가 dirty 페이지를 디스크에 쓰고 있는지 어떻게 보는가

> **기준 환경**: PostgreSQL 18.6(PGDG RPM `postgresql18-server-18.6-1PGDG.rhel9.8`), Rocky Linux 9.8. 본문의 출력은 모두 이 환경에서 직접 재현한 결과입니다.

실습 데이터는 `pgbench` scale 50(약 750 MB)이고, 기본 shared buffers(128 MB)보다 훨씬 큽니다. 체크포인트 관련 기본값은 이렇습니다.

```psql
postgres=# SELECT name, setting, unit FROM pg_settings
postgres-# WHERE name IN ('max_wal_size', 'min_wal_size', 'checkpoint_timeout', 'checkpoint_completion_target',
postgres-#                'checkpoint_warning', 'full_page_writes', 'log_checkpoints')
postgres-# ORDER BY name;
             name             | setting | unit
------------------------------+---------+------
 checkpoint_completion_target | 0.9     |
 checkpoint_timeout           | 300     | s
 checkpoint_warning           | 30      | s
 full_page_writes             | on      |
 log_checkpoints              | on      |
 max_wal_size                 | 1024    | MB
 min_wal_size                 | 80      | MB
(7 rows)
```

체크포인트는 두 가지 이유로 시작됩니다. `checkpoint_timeout`(5분)이 지나거나(**time**), 마지막 체크포인트 이후 쌓인 WAL이 `max_wal_size`(1 GB)에 가까워지거나(**wal**) 둘 중 먼저 오는 쪽입니다.

## 먼저 확인할 것

### 서버 로그: 체크포인트가 왜, 얼마나 자주 시작되는가

`log_checkpoints`는 PostgreSQL 15부터 기본으로 켜져 있어서 체크포인트마다 두 줄이 남습니다.

```console

$ tail -n 2000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'checkpoint (starting|complete)' | tail -n 2
2026-09-26 10:42:33.963 UTC [31] LOG:  checkpoint starting: wal
```

`checkpoint starting:` 뒤의 이유가 핵심입니다. `time`이면 정상이고, **`wal`이 자주 보이면 `max_wal_size`가 부하에 비해 작은 것**입니다. 체크포인트 간격이 `checkpoint_warning`(30초)보다 짧으면 경고도 남습니다.

```console
$ tail -n 2000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -A 1 -E 'checkpoints are occurring too frequently' | tail -n 2
2026-09-26 10:42:34.389 UTC [31] LOG:  checkpoints are occurring too frequently (1 second apart)
2026-09-26 10:42:34.389 UTC [31] HINT:  Consider increasing the configuration parameter "max_wal_size".
```

### pg_stat_checkpointer

누적 통계는 `pg_stat_checkpointer`(PostgreSQL 17부터, 그 전에는 `pg_stat_bgwriter`에 있던 값)에 있습니다. `num_timed`는 시간으로, `num_requested`는 WAL 양이나 요청으로 시작된 체크포인트 수입니다. `num_requested`가 `num_timed`보다 훨씬 많다면 `max_wal_size`를 먼저 의심합니다.

## 원인별 진단

### max_wal_size가 작다: 체크포인트가 끝없이 돈다

`max_wal_size`를 64 MB로 줄이고, 통계를 초기화한 뒤 60초 동안 부하를 줍니다.

```psql
postgres=# ALTER SYSTEM SET max_wal_size = '64MB';
ALTER SYSTEM

postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)


postgres=# CHECKPOINT;
CHECKPOINT

postgres=# SELECT pg_stat_reset_shared('checkpointer'), pg_stat_reset_shared('wal'),
postgres-#        pg_stat_reset_shared('io'), pg_stat_reset_shared('bgwriter'), pg_stat_reset();
 pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset
----------------------+----------------------+----------------------+----------------------+---------------
                      |                      |                      |                      |
(1 row)
```

```console
$ pgbench -n -c 8 -j 2 -T 60 -P 5 postgres 2>&1 | grep -E '^progress|^tps|latency average'
progress: 5.0 s, 8836.5 tps, lat 0.897 ms stddev 3.228, 0 failed
progress: 10.0 s, 9037.0 tps, lat 0.882 ms stddev 2.919, 0 failed
progress: 15.0 s, 9966.2 tps, lat 0.798 ms stddev 2.421, 0 failed
progress: 20.0 s, 9954.2 tps, lat 0.797 ms stddev 3.076, 0 failed
progress: 25.0 s, 9962.0 tps, lat 0.799 ms stddev 3.031, 0 failed
progress: 30.0 s, 10037.0 tps, lat 0.792 ms stddev 2.533, 0 failed
progress: 35.0 s, 10163.8 tps, lat 0.779 ms stddev 2.211, 0 failed
progress: 40.0 s, 10394.2 tps, lat 0.768 ms stddev 2.291, 0 failed
progress: 45.0 s, 10217.5 tps, lat 0.778 ms stddev 2.583, 0 failed
progress: 50.0 s, 9803.4 tps, lat 0.811 ms stddev 3.227, 0 failed
progress: 55.0 s, 10074.1 tps, lat 0.789 ms stddev 2.575, 0 failed
progress: 60.0 s, 9511.6 tps, lat 0.835 ms stddev 2.630, 0 failed
latency average = 0.809 ms
tps = 9829.277229 (without initial connection time)
```

```psql
postgres=# SELECT c.num_timed, c.num_requested, c.num_done, c.buffers_written,
postgres-#        round(c.write_time) AS write_ms, round(c.sync_time) AS sync_ms,
postgres-#        w.wal_fpi, pg_size_pretty(w.wal_bytes) AS wal,
postgres-#        d.xact_commit, pg_size_pretty(w.wal_bytes / d.xact_commit) AS wal_per_xact
postgres-# FROM pg_stat_checkpointer c, pg_stat_wal w, pg_stat_database d
postgres-# WHERE d.datname = 'postgres';
 num_timed | num_requested | num_done | buffers_written | write_ms | sync_ms | wal_fpi |   wal   | xact_commit |        wal_per_xact
-----------+---------------+----------+-----------------+----------+---------+---------+---------+-------------+-----------------------------
         0 |           170 |      169 |          651127 |    41982 |   14690 |  679639 | 5432 MB |      589820 | 9656.1948424943203011 bytes
(1 row)
```

```console
$ tail -n 2000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -c 'checkpoint starting: wal'
171
[exit=0]
```

60초 동안 체크포인트가 **170번**, 거의 1초에 3번 돌았습니다. 모두 `num_requested`, 로그로는 `wal`입니다. 같은 부하를 `max_wal_size` 4 GB에서 다시 줍니다.

```psql
postgres=# ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM

postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)


postgres=# CHECKPOINT;
CHECKPOINT

postgres=# SELECT pg_stat_reset_shared('checkpointer'), pg_stat_reset_shared('wal'),
postgres-#        pg_stat_reset_shared('io'), pg_stat_reset_shared('bgwriter'), pg_stat_reset();
 pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset_shared | pg_stat_reset
----------------------+----------------------+----------------------+----------------------+---------------
                      |                      |                      |                      |
(1 row)
```

```console
$ pgbench -n -c 8 -j 2 -T 60 -P 5 postgres 2>&1 | grep -E '^progress|^tps|latency average'
progress: 5.0 s, 13490.2 tps, lat 0.587 ms stddev 0.648, 0 failed
progress: 10.0 s, 14140.8 tps, lat 0.561 ms stddev 0.339, 0 failed
progress: 15.0 s, 13064.4 tps, lat 0.607 ms stddev 0.765, 0 failed
progress: 20.0 s, 14205.0 tps, lat 0.558 ms stddev 0.248, 0 failed
progress: 25.0 s, 14422.8 tps, lat 0.550 ms stddev 0.220, 0 failed
progress: 30.0 s, 14013.1 tps, lat 0.566 ms stddev 0.260, 0 failed
progress: 35.0 s, 14125.7 tps, lat 0.561 ms stddev 0.255, 0 failed
progress: 40.0 s, 14227.3 tps, lat 0.557 ms stddev 0.197, 0 failed
progress: 45.0 s, 13654.7 tps, lat 0.581 ms stddev 1.751, 0 failed
progress: 50.0 s, 13773.3 tps, lat 0.576 ms stddev 0.204, 0 failed
progress: 55.0 s, 14229.0 tps, lat 0.557 ms stddev 0.204, 0 failed
progress: 60.0 s, 14313.4 tps, lat 0.554 ms stddev 0.192, 0 failed
latency average = 0.567 ms
tps = 13972.776666 (without initial connection time)
```

```psql
postgres=# SELECT c.num_timed, c.num_requested, c.num_done, c.buffers_written,
postgres-#        round(c.write_time) AS write_ms, round(c.sync_time) AS sync_ms,
postgres-#        w.wal_fpi, pg_size_pretty(w.wal_bytes) AS wal,
postgres-#        d.xact_commit, pg_size_pretty(w.wal_bytes / d.xact_commit) AS wal_per_xact
postgres-# FROM pg_stat_checkpointer c, pg_stat_wal w, pg_stat_database d
postgres-# WHERE d.datname = 'postgres';
 num_timed | num_requested | num_done | buffers_written | write_ms | sync_ms | wal_fpi |   wal   | xact_commit |        wal_per_xact
-----------+---------------+----------+-----------------+----------+---------+---------+---------+-------------+-----------------------------
         0 |             0 |        0 |               0 |        0 |       0 |   93556 | 1043 MB |      838330 | 1304.3643278899717295 bytes
(1 row)
```

두 결과를 나란히 놓으면 이렇습니다.

| | max_wal_size 64 MB | max_wal_size 4 GB |
|---|---|---|
| 체크포인트 | 170번 | 0번 |
| full page image(`wal_fpi`) | 679,639 | 93,556 |
| WAL 양 | 5432 MB | 1043 MB |
| 트랜잭션당 WAL | 약 9.7 kB | 약 1.3 kB |
| 처리량 | 9,829 tps | 13,972 tps |
| 평균 지연 | 0.809 ms | 0.567 ms |

체크포인트가 잦으면 **같은 일을 하는 데 WAL을 7배 넘게 씁니다.** 체크포인트가 끝날 때마다 페이지를 다시 처음 고치는 것이 되어 full page image를 새로 쓰기 때문입니다. WAL이 늘면 WAL을 디스크에 쓰는 시간, 아카이브와 복제로 보내는 양, standby가 재생할 양이 모두 늘어납니다. 처리량은 42% 떨어졌습니다.

### 체크포인트가 시작될 때 처리량이 떨어진다

잦지 않더라도 체크포인트는 주기적인 흔들림을 만듭니다. `checkpoint_timeout`을 30초로 줄여 시간 기준 체크포인트가 부하 도중에 돌게 합니다.

```psql
postgres=# CHECKPOINT;
CHECKPOINT

postgres=# ALTER SYSTEM SET checkpoint_timeout = '30s';
ALTER SYSTEM

postgres=# SELECT pg_reload_conf();
 pg_reload_conf
----------------
 t
(1 row)
```

```console
$ pgbench -n -c 8 -j 2 -T 70 -P 5 postgres 2>&1 | grep -E '^progress|^tps'
progress: 5.0 s, 14097.2 tps, lat 0.562 ms stddev 0.754, 0 failed
progress: 10.0 s, 14490.4 tps, lat 0.547 ms stddev 0.087, 0 failed
progress: 15.0 s, 13674.7 tps, lat 0.580 ms stddev 0.785, 0 failed
progress: 20.0 s, 13957.3 tps, lat 0.568 ms stddev 0.133, 0 failed
progress: 25.0 s, 14181.0 tps, lat 0.559 ms stddev 0.085, 0 failed
progress: 30.0 s, 13995.2 tps, lat 0.567 ms stddev 0.131, 0 failed
progress: 35.0 s, 11633.8 tps, lat 0.673 ms stddev 2.018, 0 failed
progress: 40.0 s, 12508.8 tps, lat 0.643 ms stddev 1.638, 0 failed
progress: 45.0 s, 10561.2 tps, lat 0.752 ms stddev 2.344, 0 failed
progress: 50.0 s, 6617.0 tps, lat 1.204 ms stddev 8.370, 0 failed
progress: 55.0 s, 5207.0 tps, lat 1.531 ms stddev 2.233, 0 failed
progress: 60.0 s, 13100.9 tps, lat 0.605 ms stddev 0.907, 0 failed
progress: 65.0 s, 11957.9 tps, lat 0.664 ms stddev 4.772, 0 failed
progress: 70.0 s, 7108.1 tps, lat 1.120 ms stddev 1.828, 0 failed
tps = 11650.093680 (without initial connection time)
```

```console
$ tail -n 2000 "$(ls -t $PGDATA/log/*.log | head -1)" | grep -E 'checkpoint (starting|complete)' | tail -n 4
2026-09-26 10:43:35.566 UTC [31] LOG:  checkpoint complete: wrote 8992 buffers (54.9%), wrote 58 SLRU buffers; 0 WAL file(s) added, 0 removed, 66 recycled; write=0.023 s, sync=0.262 s, total=0.414 s; sync files=25, longest=0.196 s, average=0.011 s; distance=1084112 kB, estimate=1084112 kB; lsn=1/BF2BAE30, redo lsn=1/BF2BADD8
2026-09-26 10:44:05.175 UTC [31] LOG:  checkpoint starting: time
2026-09-26 10:44:32.495 UTC [31] LOG:  checkpoint complete: wrote 213 buffers (1.3%), wrote 46 SLRU buffers; 0 WAL file(s) added, 0 removed, 52 recycled; write=26.840 s, sync=0.300 s, total=27.321 s; sync files=18, longest=0.251 s, average=0.017 s; distance=865433 kB, estimate=1062244 kB; lsn=2/2B003938, redo lsn=1/F3FE11D8
2026-09-26 10:44:35.506 UTC [31] LOG:  checkpoint starting: time
```

처음 30초는 초당 1만 4천 건 안팎이다가, 체크포인트가 시작된 뒤(30초 무렵)부터 처리량이 떨어져 50~55초 구간에는 5천 건대까지 내려갔습니다. 체크포인트가 끝나자 회복했고, 60초 무렵 다음 체크포인트가 시작되자 다시 떨어졌습니다. **몇 분마다 튀는 응답 시간이 체크포인트 주기와 맞는지** 로그의 `checkpoint starting` 시각과 비교해 보면 원인을 가를 수 있습니다.

두 가지가 함께 일어납니다. 체크포인트가 시작되면 그 뒤 처음 고치는 페이지마다 full page image를 WAL에 쓰므로 WAL이 갑자기 늘어나고(앞 절에서 본 차이), 체크포인터는 dirty 페이지를 쓰고 마지막에 fsync합니다. 로그의 `write=26.840 s`는 체크포인터가 쓰기를 `checkpoint_timeout` × `checkpoint_completion_target`(30초 × 0.9 = 27초)에 걸쳐 나눠 썼다는 뜻입니다. 쓰기를 이렇게 펴 두는 것이 `checkpoint_completion_target`의 역할이고, 기본값 0.9면 대개 충분합니다.

### 누가 페이지를 쓰는가

`pg_stat_io`로 relation 페이지를 누가 디스크에 썼는지 봅니다. 64 MB일 때입니다.

```psql
postgres=# SELECT backend_type, writes, fsyncs
postgres-# FROM pg_stat_io
postgres-# WHERE object = 'relation' AND context = 'normal' AND writes > 0
postgres-# ORDER BY writes DESC;
   backend_type    | writes | fsyncs
-------------------+--------+--------
 checkpointer      | 651127 |   1173
 background writer |   7871 |      0
(2 rows)
```

거의 모든 쓰기를 체크포인터가 했습니다. 4 GB일 때는 다릅니다.

```psql
postgres=# SELECT backend_type, writes, fsyncs
postgres-# FROM pg_stat_io
postgres-# WHERE object = 'relation' AND context = 'normal' AND writes > 0
postgres-# ORDER BY writes DESC;
   backend_type    | writes | fsyncs
-------------------+--------+--------
 client backend    | 737700 |      0
 background writer |  29730 |      0
 autovacuum worker |    173 |      0
(3 rows)
```

체크포인트가 한 번도 돌지 않았으므로, shared buffers가 부족할 때마다 **client backend가 직접** dirty 페이지를 내보냈습니다. 쿼리를 처리하던 backend가 쓰기까지 하니 그만큼 응답이 늦어집니다. 문서는 client backend의 쓰기가 많으면 shared buffers나 체크포인트 설정이 맞지 않을 수 있다고 설명합니다([pg_stat_io](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-IO-VIEW)). 이 실습은 데이터(750 MB)에 비해 shared buffers(128 MB)가 작아서 생긴 일로, [인터널 2편](/posts/postgresql/02-memory-architecture/)과 [1편](/posts/postgresql-ops/01-diagnostic-toolkit/)에서 본 것과 같은 모습입니다. background writer가 미리 써 주는 양(`bgwriter_lru_maxpages`, `bgwriter_lru_multiplier`)을 늘리거나 shared buffers를 키우는 것이 방법입니다.

## 조치

| 증상 | 확인 | 조치 |
|---|---|---|
| `checkpoint starting: wal`이 잦음, `too frequently` 경고 | 로그, `num_requested` ≫ `num_timed` | `max_wal_size`를 늘림 |
| 체크포인트 시작 무렵 처리량이 떨어짐 | 로그의 `checkpoint starting` 시각과 지연 그래프 비교 | `checkpoint_completion_target` 확인(0.9), `checkpoint_timeout`을 늘려 빈도를 줄임, 디스크 성능 확인 |
| client backend의 쓰기가 많음 | `pg_stat_io`의 `client backend` / `relation` / `normal` writes | shared buffers, background writer 설정 |

`max_wal_size`를 늘리는 대가도 알고 있어야 합니다.

- **디스크**: 평소 `pg_wal`이 그만큼 커질 수 있습니다. 4 GB로 둔 실습에서 60초 뒤 `pg_wal`은 1 GB를 넘었습니다.

```psql
postgres=# SELECT pg_size_pretty(sum(size)) AS pg_wal FROM pg_ls_waldir();
 pg_wal
---------
 1072 MB
(1 row)
```

- **장애 복구 시간**: 장애가 나면 마지막 체크포인트 이후의 WAL을 재생해야 하므로, 체크포인트 간격이 길수록 복구가 오래 걸립니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).

일반적인 방향은 **평소에는 `time`으로 체크포인트가 돌 만큼 `max_wal_size`를 넉넉히** 잡는 것입니다. 로그에서 `wal` 체크포인트가 드물게만 보이면 됩니다. `checkpoint_timeout`은 복구 시간 목표에 맞춰 정합니다.

## 재발 방지

- **체크포인트 이유 비율**: `pg_stat_checkpointer`의 `num_timed`와 `num_requested`를 수집합니다. 부하가 늘면서 `num_requested`가 늘기 시작하면 `max_wal_size`를 다시 봅니다.
- **체크포인트 소요 시간**: 로그의 `write=`, `sync=`, `total=`. `sync`가 길면 디스크가 fsync를 버거워하는 것입니다.
- **WAL 생성량**: `pg_stat_wal`의 `wal_bytes`, `wal_fpi` 추세. full page image 비율이 갑자기 늘면 체크포인트가 잦아진 것입니다.
- **누가 쓰는가**: `pg_stat_io`에서 client backend의 쓰기 비율.
- **지연 그래프와 체크포인트 시각을 겹쳐 봅니다.** 주기적인 튐이 체크포인트와 맞는지 한눈에 보입니다.

## 정리

- 체크포인트는 `time` 또는 `wal` 이유로 시작됩니다. 로그의 `checkpoint starting: wal`이 잦고 `checkpoints are occurring too frequently`가 보이면 `max_wal_size`가 작은 것입니다.
- 이 실습에서 `max_wal_size` 64 MB는 60초에 체크포인트 170번, 트랜잭션당 WAL 7배 이상, 처리량 42% 감소로 이어졌습니다. 체크포인트마다 full page image를 새로 쓰기 때문입니다.
- 체크포인트가 시작되면 full page image와 체크포인터의 쓰기로 처리량이 주기적으로 떨어질 수 있습니다. 지연 그래프를 체크포인트 시각과 겹쳐 봅니다.
- `pg_stat_io`로 누가 페이지를 쓰는지 봅니다. client backend의 쓰기가 많으면 shared buffers와 background writer를 봅니다.
- `max_wal_size`는 평소 `time` 체크포인트가 되도록 넉넉히 잡되, 디스크와 복구 시간을 함께 고려합니다.

## 참고 자료

- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html)
- [Write Ahead Log 설정](https://www.postgresql.org/docs/18/runtime-config-wal.html): `max_wal_size`, `checkpoint_timeout`, `checkpoint_completion_target`, `checkpoint_warning`
- [pg_stat_checkpointer](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-CHECKPOINTER-VIEW), [pg_stat_wal](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-WAL-VIEW), [pg_stat_io](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-IO-VIEW)
- [Resource Consumption](https://www.postgresql.org/docs/18/runtime-config-resource.html): background writer
- PostgreSQL 인터널 [2편 메모리 구조](/posts/postgresql/02-memory-architecture/), [7편 WAL](/posts/postgresql/07-wal/), [8편 체크포인트와 장애 복구](/posts/postgresql/08-checkpoint-and-recovery/)

