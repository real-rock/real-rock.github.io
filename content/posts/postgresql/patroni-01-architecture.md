---
title: "Patroni HA 1: Patroni의 구조와 동작 원리"
date: 2026-09-26T08:00:00+09:00
draft: false
series: ["Patroni HA"]
categories: ["PostgreSQL"]
subcategory: "HA"
tags: ["PostgreSQL", "Patroni", "HA", "etcd", "failover"]
weight: 1
thumb: "Patroni"
summary: "primary가 죽었을 때 누가, 무엇을 근거로 새 primary를 정하는가"
description: "DCS와 leader key, HA loop, failover 판단"
---

## 개요

[인터널 9편](/posts/postgresql/09-streaming-replication/)에서 스트리밍 복제로 standby를 만들었습니다. standby는 primary의 WAL을 계속 받아 재생하므로 primary가 죽으면 `pg_ctl promote` 한 번으로 새 primary가 될 수 있습니다. 문제는 **그 한 번을 누가, 언제 하느냐**입니다. 사람이 새벽에 알람을 받고 판단하는 동안 서비스는 멈춰 있고, 서두르다 보면 더 나쁜 일이 생깁니다.

자동으로 하려면 생각보다 많은 것을 풀어야 합니다.

- primary가 정말 죽었는지, 아니면 나와의 네트워크만 끊겼는지 어떻게 아는가
- 두 서버가 동시에 primary가 되어 각자 쓰기를 받는 **split-brain**은 어떻게 막는가
- standby가 여러 대이면 누구를 올려야 데이터를 가장 적게 잃는가
- 남은 standby와 되살아난 옛 primary를 새 primary에 어떻게 다시 붙이는가
- 애플리케이션은 새 primary를 어떻게 찾아가는가

**Patroni**는 이 문제를 각 PostgreSQL 노드에 붙는 데몬과, 여러 서버가 합의해서 값을 저장하는 분산 저장소(**DCS**, Distributed Configuration Store)로 풉니다. 이 글에서는 Patroni가 무엇으로 이루어져 있고 어떤 규칙으로 primary를 정하고 바꾸는지를 실제 클러스터에서 확인합니다. 클러스터를 처음부터 구성하는 방법은 [2편](/posts/postgresql/patroni-02-setup/)에서 다룹니다.

이 글에서 답할 질문은 다음과 같습니다.

- Patroni 클러스터는 어떤 구성 요소로 이루어지는가
- DCS에는 무엇이 저장되고, "leader"라는 자격은 어떻게 표현되는가
- Patroni는 얼마나 자주 무엇을 확인하는가
- primary가 죽으면 replica들은 무엇을 근거로 새 primary를 고르는가
- DCS와 연락이 끊긴 primary는 어떻게 행동하는가

> **기준 버전**: Patroni 4.1.5, PostgreSQL 18.6, etcd 3.7.2, HAProxy 3.4.5. 모두 PGDG 저장소의 Rocky Linux 9 RPM입니다. 실습은 `rockylinux:9` 이미지(Rocky Linux 9.8로 업데이트)로 만든 컨테이너 7대(etcd 3대, PostgreSQL과 Patroni 3대, HAProxy 1대)에서 systemd로 서비스를 띄워 실행했습니다. Patroni 소스 링크는 [`v4.1.5` 태그](https://github.com/patroni/patroni/tree/v4.1.5) 기준입니다.

## Patroni 클러스터의 구성 요소

{{< diagram src="/diagrams/patroni-architecture.html" title="Patroni 클러스터: 누가 누구와 이야기하는가" height="720" caption="각 노드의 Patroni가 자기 PostgreSQL을 관리하고, etcd의 leader key로 누가 primary인지 정합니다. 애플리케이션은 HAProxy를 거쳐 들어오고, HAProxy는 Patroni REST API로 primary를 찾습니다." >}}

실습 클러스터의 이름(`scope`)은 `pg-ha`이고 노드는 `pg1`, `pg2`, `pg3`입니다.

- **Patroni 데몬**: PostgreSQL 노드마다 하나씩 돕니다. PostgreSQL을 직접 시작하고, 멈추고, promote하고, standby로 되돌립니다. 운영자가 `pg_ctl`을 직접 쓰는 대신 Patroni에게 맡기는 구조입니다.
- **DCS**: 클러스터 상태의 유일한 기준입니다. 누가 leader인지, 멤버가 누구인지, 클러스터 전체에 적용할 설정이 무엇인지가 여기에 있습니다. etcd, Consul, ZooKeeper, Kubernetes API를 쓸 수 있습니다. 이 연재는 etcd(v3 API)를 씁니다. etcd 자체도 3대로 쿼럼을 이루므로 한 대가 죽어도 동작합니다.
- **REST API**: 각 Patroni가 8008번 포트로 엽니다. Patroni끼리 서로의 WAL 위치를 물어볼 때, HAProxy가 primary를 찾을 때, `patronictl`이 명령을 보낼 때 씁니다.
- **patronictl**: 운영자용 명령행 도구입니다. 클러스터 상태 보기, switchover, 재시작, 설정 변경을 합니다.
- **HAProxy**: Patroni는 애플리케이션의 연결을 옮겨 주지 않습니다. 새 primary가 생겨도 애플리케이션이 그쪽으로 가게 하는 일은 별도 계층의 몫입니다. 여기서는 HAProxy가 REST API의 응답을 보고 연결을 보냅니다.

복제 자체는 PostgreSQL의 스트리밍 복제 그대로입니다. Patroni는 WAL을 나르지 않고, **누가 primary인지 정하고 나머지가 그 primary를 따르도록 설정을 써 줄 뿐**입니다.

#### Patroni가 PostgreSQL을 자식 프로세스로 띄운다

systemd가 띄우는 것은 Patroni 하나이고 PostgreSQL은 Patroni의 자식 프로세스로 뜹니다. pg1에서 서비스 상태를 봅니다.

```console
$ systemctl status patroni --no-pager
● patroni.service - Runners to orchestrate a high-availability PostgreSQL
     Loaded: loaded (/usr/lib/systemd/system/patroni.service; disabled; preset: disabled)
     Active: active (running) since Fri 2026-09-25 22:22:14 UTC; 12s ago
   Main PID: 100 (patroni)
      Tasks: 28 (limit: 205294)
     Memory: 96.4M (peak: 108.7M)
        CPU: 593ms
     CGroup: /docker/81cd58c6b4fd2aa5b4a7ce063c1b562f74ecf2f391458e69e06715db6787b997/system.slice/patroni.service
             ├─100 /usr/bin/python3.12 /usr/bin/patroni /etc/patroni/patroni.yml
             ├─131 /usr/pgsql-18/bin/postgres -D /var/lib/pgsql/18/data --config-file=/var/lib/pgsql/18/data/postgresql.conf --listen_addresses=0.0.0.0 --port=5432 --cluster_name=pg-ha --wal_level=replica --hot_standby=on --max_connections=100 --max_wal_senders=10 --max_prepared_transactions=0 --max_locks_per_transaction=64 --track_commit_timestamp=off --max_replication_slots=10 --max_worker_processes=8 --wal_log_hints=on
             ├─132 "postgres: pg-ha: logger "
             ├─134 "postgres: pg-ha: io worker 0"
             ├─135 "postgres: pg-ha: io worker 1"
             ├─136 "postgres: pg-ha: io worker 2"
             ├─137 "postgres: pg-ha: checkpointer "
             ├─138 "postgres: pg-ha: background writer "
             ├─142 "postgres: pg-ha: walwriter "
             ├─143 "postgres: pg-ha: autovacuum launcher "
             ├─144 "postgres: pg-ha: logical replication launcher "
             └─146 "postgres: pg-ha: postgres postgres 127.0.0.1(50430) idle"
```

- `patroni.service`의 cgroup 안에 Patroni(PID 100)와 postmaster(PID 131), 그리고 [인터널 1편](/posts/postgresql/01-process-architecture/)에서 본 백그라운드 프로세스들이 함께 있습니다.
- postmaster의 명령행에 `--max_connections=100`, `--wal_level=replica` 같은 파라미터가 직접 붙어 있습니다. Patroni는 복제에 꼭 맞아야 하는 몇몇 파라미터를 명령행으로 넘깁니다. 명령행 값은 `postgresql.conf`나 `ALTER SYSTEM`보다 우선하므로 이 값들은 DCS 설정으로만 바꿀 수 있습니다([3편](/posts/postgresql/patroni-03-operations/)에서 확인합니다).
- 마지막 줄의 `127.0.0.1(50430) idle`은 Patroni가 PostgreSQL 상태를 확인하려고 붙어 있는 연결입니다.

## DCS에 무엇이 저장되는가

Patroni는 etcd의 `/service/<scope>/` 아래에 키를 만듭니다(`namespace` 기본값이 `/service/`). pg1 하나만 부트스트랩한 직후의 키입니다.

```console
$ etcdctl get --prefix /service/pg-ha --keys-only | grep .
/service/pg-ha/config
/service/pg-ha/initialize
/service/pg-ha/leader
/service/pg-ha/members/pg1
/service/pg-ha/status
$ etcdctl get /service/pg-ha/initialize --print-value-only
7689601790135361659
$ etcdctl get /service/pg-ha/leader --print-value-only
pg1
$ etcdctl get /service/pg-ha/members/pg1 --print-value-only | jq .
{
  "conn_url": "postgres://172.30.0.21:5432/postgres",
  "api_url": "http://172.30.0.21:8008/patroni",
  "state": "running",
  "role": "primary",
  "version": "4.1.5",
  "xlog_location": 24506360,
  "timeline": 1
}
$ etcdctl get /service/pg-ha/status --print-value-only
{"optime":24506416,"slots":{"pg1":24506416},"retain_slots":["pg1"]}
```

| 키 | 내용 |
|---|---|
| `initialize` | 클러스터를 처음 만든 노드가 적은 system identifier(`pg_controldata`의 값). 이 키가 있으면 다른 노드는 initdb 대신 기존 클러스터를 복제해 합류합니다 |
| `config` | 클러스터 전체에 적용하는 동적 설정(`ttl`, `loop_wait`, PostgreSQL 파라미터 등). `patronictl edit-config`로 바꿉니다 |
| `leader` | 지금 primary인 멤버의 이름. **이 키를 가진 노드만 primary로 동작할 수 있습니다** |
| `members/<이름>` | 각 멤버가 스스로 보고하는 접속 주소, REST API 주소, 역할, WAL 위치, timeline |
| `status` | leader가 기록하는 마지막 WAL 위치(`optime`)와 replication slot 위치 |

클러스터를 운영하다 보면 키가 더 생깁니다. 실습을 모두 마친 뒤의 목록입니다.

```console
$ etcdctl get --prefix /service/pg-ha --keys-only | grep .
/service/pg-ha/config
/service/pg-ha/failover
/service/pg-ha/failsafe
/service/pg-ha/history
/service/pg-ha/initialize
/service/pg-ha/leader
/service/pg-ha/members/pg1
/service/pg-ha/members/pg2
/service/pg-ha/members/pg3
/service/pg-ha/status
/service/pg-ha/sync
```

`history`는 timeline이 바뀔 때마다(leader가 바뀔 때마다) 쌓이는 기록이고, `failover`는 switchover 요청을 전달하는 데, `sync`와 `failsafe`는 [3편](/posts/postgresql/patroni-03-operations/)에서 볼 동기 복제와 failsafe 모드에 씁니다.

## leader key: TTL이 붙은 잠금

leader key는 **스스로 사라지는 잠금**입니다. etcd v3에서는 키에 lease를 붙이고, lease를 갱신하지 않으면 TTL이 지난 뒤 키가 지워집니다. leader인 Patroni는 주기적으로 lease를 갱신해 키를 지킵니다. 갱신이 멈추면 키가 사라져 다른 노드가 차지할 수 있게 됩니다.

#### lease는 10초마다 30초로 되돌아간다

```console
$ etcdctl get /service/pg-ha/leader -w json | jq -c ".kvs[0] | {lease}"
{"lease":6242728894488118532}
$ printf "%x\n" 6242728894488118532
56a2a0daa9080504
$ etcdctl lease timetolive 56a2a0daa9080504 --keys
lease 56a2a0daa9080504 granted with TTL(30s), remaining(28s), attached keys([/service/pg-ha/members/pg1 /service/pg-ha/leader])
$ for i in $(seq 1 8); do echo "$(date +%T) $(etcdctl lease timetolive 56a2a0daa9080504 | grep -o "remaining([0-9]*s)")"; sleep 2; done
22:22:44 remaining(20s)
22:22:46 remaining(28s)
22:22:48 remaining(26s)
22:22:50 remaining(24s)
22:22:52 remaining(22s)
22:22:54 remaining(20s)
22:22:56 remaining(28s)
22:22:58 remaining(26s)
```

같은 시각 pg1의 Patroni 로그입니다.

```console
$ journalctl -u patroni -o cat --since "-30s" | tail -3
2026-09-25 22:22:35,530 INFO: no action. I am (pg1), the leader with the lock
2026-09-25 22:22:45,431 INFO: no action. I am (pg1), the leader with the lock
2026-09-25 22:22:55,433 INFO: no action. I am (pg1), the leader with the lock
```

- lease의 TTL은 30초(`ttl`)이고 남은 시간이 20초까지 줄었다가 28초로 돌아갑니다. Patroni가 10초(`loop_wait`)마다 한 번씩 갱신하기 때문이고, 로그의 `the leader with the lock`이 찍히는 시각(:45, :55)과 같습니다.
- leader key와 pg1의 `members/pg1` 키가 **같은 lease**에 붙어 있습니다. pg1이 갱신을 멈추면 leader 자격과 멤버 정보가 함께 사라집니다.

Patroni는 세 값이 `loop_wait + 2 × retry_timeout <= ttl` 규칙을 지키도록 요구하고, 어기면 `retry_timeout`을 줄여 맞춥니다([`config.py`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/config.py#L298)). 기본값 `ttl 30`, `loop_wait 10`, `retry_timeout 10`이 이 규칙을 딱 맞춘 값입니다. 이유는 [뒤에서](#dcs와-끊긴-primary는-스스로-내려간다) 봅니다. leader가 DCS에 닿지 못하면 lease가 만료되기 전에 스스로 물러날 시간이 있어야 하기 때문입니다.

## HA loop: 10초마다 하는 판단

모든 Patroni는 `loop_wait`마다 같은 순서로 한 바퀴를 돕니다([`Ha._run_cycle()`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py#L2167)). DCS에서 클러스터 상태를 읽고, 자기 PostgreSQL이 어떤 상태인지 확인한 뒤, 둘을 맞추는 행동을 하나 고릅니다. 로그의 `no action. I am (...)` 한 줄이 이 한 바퀴의 결론입니다.

| 상황 | 하는 일 | 로그 |
|---|---|---|
| leader key가 내 것 | lease 갱신, `status`에 WAL 위치 기록 | `the leader with the lock` |
| leader key가 남의 것 | 그 leader를 따르도록 `primary_conninfo`를 맞춤 | `a secondary, and following a leader (pg1)` |
| leader key가 없음 | leader 경쟁(leader race) | `Lock owner: None` |
| key는 내 것인데 PostgreSQL이 죽음 | 제자리에서 다시 시작 | `starting primary after failure` |
| DCS에 닿지 못함 | primary였다면 강등 | `demoting self because DCS is not accessible` |

loop 사이에도 etcd의 watch로 leader key가 바뀌는 것을 알아채면 바로 다음 바퀴를 돕니다. 그래서 switchover처럼 key를 일부러 내려놓는 경우에는 10초를 다 기다리지 않습니다([2편](/posts/postgresql/patroni-02-setup/)에서 switchover는 1.2초 만에 끝납니다).

#### PostgreSQL만 죽으면 failover가 아니라 재시작한다

primary pg2의 postmaster를 `kill -9`로 죽여 봅니다. Patroni 프로세스는 살아 있습니다.

```console
$ kill -9 $(head -1 /var/lib/pgsql/18/data/postmaster.pid)
$ journalctl -u patroni -o cat --since "-16s" | grep -E "INFO|WARN" | grep -v "heartbeat connection"
2026-09-25 22:28:51,093 INFO: establishing a new patroni restapi connection to postgres
2026-09-25 22:28:56,690 WARNING: Postgresql is not running.
2026-09-25 22:28:56,691 INFO: Lock owner: pg2; I am pg2
2026-09-25 22:28:56,737 INFO: pg_controldata:
2026-09-25 22:28:56,788 INFO: starting primary after failure
2026-09-25 22:28:56,929 INFO: postmaster pid=702
2026-09-25 22:28:57,158 INFO: establishing a new patroni heartbeat connection to postgres
2026-09-25 22:28:57,169 INFO: establishing a new patroni restapi connection to postgres
2026-09-25 22:28:58,082 INFO: no action. I am (pg2), the leader with the lock
$ patronictl -c /etc/patroni/patroni.yml list
+ Cluster: pg-ha (7689601790135361659) ----+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |  State  | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+---------+----+-------------+-----+------------+-----+
| pg1    | 172.30.0.21 | Replica | running |  4 |   0/54CBDE0 |   0 |  0/54CBDE0 |   0 |
| pg2    | 172.30.0.22 | Leader  | running |  4 |             |     |            |     |
| pg3    | 172.30.0.23 | Replica | running |  4 |   0/54CBDE0 |   0 |  0/54CBDE0 |   0 |
+--------+-------------+---------+---------+----+-------------+-----+------------+-----+
```

- 22:28:50.2에 죽였고 다음 loop인 22:28:56.7에 `Postgresql is not running`을 확인한 뒤 `starting primary after failure`로 같은 노드에서 다시 띄웠습니다.
- leader key는 pg2가 계속 쥐고 있었으므로(`Lock owner: pg2`) failover는 일어나지 않았고, timeline도 4 그대로입니다. 0.5초마다 쓰던 클라이언트는 약 8초 동안 쓰지 못했고, 22:28:57.9부터 같은 pg2에 다시 썼습니다.
- 재시작이 계속 실패하면 언제 포기하고 failover할지는 `primary_start_timeout`(기본 300초)이 정합니다.

Patroni가 먼저 재시작을 시도하는 것은 합리적입니다. failover는 timeline을 바꾸고 비동기 복제라면 데이터를 잃을 수도 있는 큰 사건이지만, 제자리 재시작은 crash recovery만 하면 되기 때문입니다.

## leader가 사라지면: leader race

leader key가 사라지면 replica들이 경쟁합니다. 각자 몇 가지를 확인한 뒤에야 key를 잡으려고 시도합니다([`Ha.is_healthiest_node()`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py#L1494), [`Ha._is_healthiest_node()`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py#L1290)).

{{< diagram src="/diagrams/patroni-leader-race.html" title="leader key가 사라졌을 때 replica가 하는 판단" height="520" caption="자기 점검(nofailover 태그, pause, 복제 지연)을 통과한 replica만 다른 멤버와 WAL 위치를 비교하고, 가장 앞선 노드가 leader key를 만듭니다. key는 없을 때만 만들 수 있으므로 한 노드만 성공합니다." >}}

1. **후보인가**: `nofailover: true` 태그가 붙은 노드와, 클러스터가 pause 상태일 때는 후보가 아닙니다.
2. **너무 뒤처지지 않았는가**: 내가 받은 WAL 위치가 DCS `status`에 적힌 leader의 마지막 위치보다 `maximum_lag_on_failover`(실습은 1MB)보다 더 뒤처졌으면 빠집니다([`Ha.is_lagging()`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py#L1280)).
3. **나보다 앞선 멤버가 있는가**: 다른 멤버의 REST API(`GET /patroni`)에 물어 WAL 위치를 비교합니다. 나보다 앞선 멤버가 있으면 양보합니다. 위치가 같으면 `failover_priority` 태그가 높은 쪽이 이깁니다.
4. **leader key 만들기**: etcd에 "키가 없을 때만 생성"을 요청합니다. 두 노드가 동시에 시도해도 etcd는 하나만 성공시키므로 leader는 하나만 나옵니다.
5. 이긴 노드는 PostgreSQL을 promote하고(timeline이 1 올라갑니다), 진 노드는 새 leader를 따릅니다.

#### primary 노드를 통째로 죽인다

primary pg1 컨테이너를 `docker kill`로 죽입니다. 전원이 나간 것과 같아서 pg1의 Patroni도 함께 죽고 아무도 lease를 갱신하지 않습니다. 다른 노드에서 2초마다 leader key를 봅니다.

```console
$ docker kill pg1        # 22:27:11.440
$ for i in $(seq 1 20); do echo "$(date +%T) leader=$(etcdctl get /service/pg-ha/leader --print-value-only)"; sleep 2; done
22:27:11 leader=pg1
22:27:13 leader=pg1
22:27:15 leader=pg1
22:27:17 leader=pg1
22:27:20 leader=pg1
22:27:22 leader=pg1
22:27:24 leader=pg1
22:27:26 leader=pg1
22:27:28 leader=pg1
22:27:30 leader=pg1
22:27:32 leader=pg1
22:27:35 leader=
22:27:37 leader=pg2
22:27:39 leader=pg2
```

pg1이 죽은 뒤에도 약 22초 동안 leader key는 `pg1`으로 남아 있었습니다. 마지막 갱신에서 30초가 지나 lease가 만료되고 나서야 key가 사라졌습니다. 그 순간 pg2와 pg3의 로그입니다(`Got response` 줄의 JSON은 줄였습니다).

```console
$ journalctl -u patroni -o cat --since 22:27:05 --until 22:27:42 | grep -E "INFO|WARN"     # pg2
2026-09-25 22:27:13,501 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
2026-09-25 22:27:23,454 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
2026-09-25 22:27:33,355 INFO: Got response from pg3 http://172.30.0.23:8008/patroni: {"state": "running", ... "role": "replica", ...
2026-09-25 22:27:35,348 WARNING: Request failed to pg1: GET http://172.30.0.21:8008/patroni (HTTPConnectionPool(host='172.30.0.21', port=8008): Max retries exceeded ...
2026-09-25 22:27:35,486 INFO: promoted self to leader by acquiring session lock
2026-09-25 22:27:35,486 INFO: Lock owner: pg2; I am pg2
2026-09-25 22:27:35,571 INFO: updated leader lock during promote
2026-09-25 22:27:36,684 INFO: no action. I am (pg2), the leader with the lock
$ journalctl -u patroni -o cat --since 22:27:05 --until 22:27:42 | grep -E "INFO|WARN"     # pg3
2026-09-25 22:27:33,355 INFO: Got response from pg2 http://172.30.0.22:8008/patroni: {"state": "running", ... "role": "replica", ...
2026-09-25 22:27:35,358 WARNING: Request failed to pg1: GET http://172.30.0.21:8008/patroni (HTTPConnectionPool(host='172.30.0.21', port=8008): Max retries exceeded ...
2026-09-25 22:27:35,446 INFO: Could not take out TTL lock
2026-09-25 22:27:35,455 INFO: following new leader after trying and failing to obtain lock
2026-09-25 22:27:35,455 INFO: Lock owner: pg2; I am pg3
2026-09-25 22:27:35,507 INFO: no action. I am (pg3), a secondary, and following a leader (pg2)
```

- pg2와 pg3는 서로의 REST API에 WAL 위치를 물었고(`Got response from ...`), 옛 leader pg1에게도 물었지만 응답이 없었습니다. 둘의 위치가 같아 둘 다 key를 만들려고 했습니다.
- pg2가 먼저 성공했고(`promoted self to leader by acquiring session lock`), pg3는 `Could not take out TTL lock`으로 실패한 뒤 pg2를 따르기 시작했습니다. etcd의 원자적 생성 덕분에 leader는 하나만 나왔습니다.
- 22:27:11.4에 죽이고 22:27:35.5에 promote했으니 **failover에 24초**가 걸렸습니다. 0.5초마다 HAProxy로 쓰던 클라이언트는 22:27:11.2의 성공 뒤 22:27:35.8까지 쓰지 못했습니다. 이 시간의 대부분은 lease 만료를 기다린 시간입니다.

Patroni가 "죽었다"를 판단하는 근거는 lease 만료입니다. 노드가 갑자기 죽으면 최악의 경우 `ttl`만큼 기다린 뒤에야 failover가 시작됩니다. `ttl`을 줄이면 빨라지지만 그만큼 짧은 네트워크 지연이나 etcd의 일시적인 느려짐도 "leader가 죽었다"로 해석될 수 있습니다.

## DCS와 끊긴 primary는 스스로 내려간다

leader key 방식에는 빈틈이 하나 있어 보입니다. primary가 살아 있는데 etcd와의 연결만 끊기면 어떻게 될까요? lease는 만료되고 다른 노드가 promote합니다. 그런데 옛 primary가 계속 쓰기를 받으면 split-brain입니다.

Patroni의 답은 **leader가 DCS에 닿지 못하면 스스로 primary를 그만둔다**입니다. primary pg2에서 etcd 포트(2379)로 나가는 연결만 막아 확인합니다. HAProxy와 다른 노드에서 pg2로의 연결은 그대로입니다.

```console
$ iptables -A OUTPUT -p tcp --dport 2379 -j REJECT --reject-with tcp-reset     # pg2, 22:32:32.484
$ for i in $(seq 1 12); do echo "$(date +%T) pg2_in_recovery=$(psql -h /run/postgresql -Atc 'select pg_is_in_recovery()') leader=$(etcdctl get /service/pg-ha/leader --print-value-only)"; sleep 3; done
22:32:32 pg2_in_recovery=f leader=pg2
22:32:35 pg2_in_recovery=f leader=pg2
22:32:38 pg2_in_recovery=f leader=pg2
22:32:42 pg2_in_recovery=f leader=pg2
22:32:45 pg2_in_recovery=f leader=pg2
22:32:48 pg2_in_recovery=t leader=pg2
22:32:51 pg2_in_recovery=t leader=pg2
22:32:54 pg2_in_recovery=t leader=pg2
22:32:58 pg2_in_recovery=t leader=pg2
22:33:01 pg2_in_recovery=t leader=pg1
22:33:04 pg2_in_recovery=t leader=pg1
22:33:07 pg2_in_recovery=t leader=pg1
```

(`psql`은 pg2에서, `etcdctl`은 etcd 노드에서 실행했습니다.) 22:32:48부터 pg2는 `pg_is_in_recovery() = t`, 즉 standby가 되었습니다. 그런데 etcd의 leader key는 22:33:01까지 여전히 `pg2`입니다. pg2가 먼저 내려가고 한참 뒤에 pg1이 올라왔습니다. pg2의 로그에서 반복되는 etcd 재시도 줄을 빼고 보면 이렇습니다.

```console
$ journalctl -u patroni -o cat --since 22:32:10 --until 22:33:10 | grep -vE "Request to server|Reconnection allowed|Retrying on|Failed to get list|KVCache"
2026-09-25 22:32:18,082 INFO: no action. I am (pg2), the leader with the lock
2026-09-25 22:32:28,080 INFO: no action. I am (pg2), the leader with the lock
2026-09-25 22:32:37,946 INFO: Lock owner: pg2; I am pg2
2026-09-25 22:32:38,620 ERROR: watchprefix failed: ProtocolError("Connection broken: ConnectionResetError(104, 'Connection reset by peer')", ConnectionResetError(104, 'Connection reset by peer'))
2026-09-25 22:32:46,056 ERROR: Error communicating with DCS
2026-09-25 22:32:46,057 INFO: demoting self because DCS is not accessible and I was a leader
2026-09-25 22:32:46,057 INFO: Demoting self (offline)
2026-09-25 22:32:47,084 INFO: closed patroni connections to postgres
2026-09-25 22:32:47,229 INFO: postmaster pid=1599
2026-09-25 22:32:47,414 INFO: establishing a new patroni heartbeat connection to postgres
2026-09-25 22:32:47,424 INFO: establishing a new patroni restapi connection to postgres
2026-09-25 22:32:48,246 INFO: demoted self because DCS is not accessible and I was a leader
2026-09-25 22:32:58,249 ERROR: Error communicating with DCS
2026-09-25 22:32:58,250 INFO: DCS is not accessible
```

같은 시각 pg1입니다.

```console
$ journalctl -u patroni -o cat --since 22:32:55 --until 22:33:05 | grep -E "INFO|WARN" | cut -c1-110
2026-09-25 22:32:58,339 INFO: Got response from pg3 http://172.30.0.23:8008/patroni: {"state": "running", "pos
2026-09-25 22:32:58,340 INFO: Got response from pg2 http://172.30.0.22:8008/patroni: {"state": "running", "pos
2026-09-25 22:32:58,468 INFO: promoted self to leader by acquiring session lock
2026-09-25 22:32:59,654 INFO: no action. I am (pg1), the leader with the lock
```

{{< diagram src="/diagrams/patroni-dcs-isolation.html" title="etcd와 끊긴 primary: 강등이 승격보다 먼저 일어난다" height="620" caption="pg2는 retry_timeout 안에 lease를 갱신하지 못하자 22:32:46에 스스로 read-only로 내려갑니다. leader key는 마지막 갱신(22:32:28) 뒤 30초가 지난 22:32:58에야 만료되고, 그때 pg1이 key를 잡습니다." >}}

- pg2가 마지막으로 lease를 갱신한 것은 22:32:28입니다. 다음 loop(22:32:37.9)부터 etcd에 닿지 못했고, `retry_timeout`(10초) 동안 재시도하다가 22:32:46에 `demoting self because DCS is not accessible and I was a leader`로 스스로 내려갔습니다([`Ha._handle_dcs_error()`](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py#L2352)).
- leader key는 22:32:28 + 30초 = **22:32:58**에 만료되었고, pg1이 바로 그 시각(22:32:58.468)에 key를 잡았습니다.
- 그 사이 12초 동안은 primary가 하나도 없었습니다. 두 primary가 겹치는 순간은 없었습니다.

HAProxy로 쓰던 클라이언트가 본 것도 같습니다.

```console
$ awk '$1>="22:32:44" && $1<="22:33:00"' /root/writer.log
22:32:44.401 172.30.0.22 INSERT 0 1 
22:32:44.926 172.30.0.22 INSERT 0 1 
22:32:45.437 172.30.0.22 INSERT 0 1 
22:32:45.962 172.30.0.22 INSERT 0 1 
22:32:47.492 ERROR:  cannot execute INSERT in a read-only transaction 
22:32:48.018 ERROR:  cannot execute INSERT in a read-only transaction 
22:32:48.533 ERROR:  cannot execute INSERT in a read-only transaction 
22:32:49.048 psql: error: connection to server at "127.0.0.1", port 5000 failed: server closed the connection 
...
22:32:59.887 172.30.0.21 INSERT 0 1 
```

(`writer.log`는 0.5초마다 HAProxy 5000번 포트로 한 행씩 넣고 결과를 적는 스크립트의 출력입니다. [2편](/posts/postgresql/patroni-02-setup/#switchover-계획된-교대)에서 만듭니다. `...`는 같은 줄이 반복되는 부분을 줄였습니다.) pg2(172.30.0.22)는 22:32:45.9까지 쓰기를 받았고, 강등된 뒤에는 read-only 오류를 냈습니다. pg1(172.30.0.21)의 첫 쓰기는 22:32:59.9입니다. 쓰기를 받은 서버는 어느 순간에도 하나였습니다.

이제 `loop_wait + 2 × retry_timeout <= ttl` 규칙의 뜻이 보입니다. leader가 마지막으로 갱신한 직후 DCS가 끊겨도, 다음 loop까지 `loop_wait`, 재시도에 `retry_timeout`을 쓰고 강등할 여유가 lease 만료 전에 남아야 합니다. 이 순서가 지켜지는 한 **옛 primary의 강등이 새 primary의 승격보다 먼저** 일어납니다.

이 보장에는 **옛 primary의 Patroni가 살아서 판단할 수 있어야 한다**는 전제가 있습니다. Patroni 프로세스가 죽거나 멈추면 PostgreSQL은 primary로 남은 채 아무도 강등시키지 않습니다. 이 틈을 막는 것이 watchdog이고, [3편](/posts/postgresql/patroni-03-operations/#patroni가-죽으면-postgresql은-계속-primary다)에서 실제로 두 primary가 생기는 것을 확인합니다.

## 운영에서는 이렇게 나타납니다

- **failover 시간은 대부분 TTL이다.** 노드가 통째로 죽으면 lease가 만료될 때까지 기다립니다. 실습에서는 24초였고, 기본값에서 최악은 30초 남짓입니다. 이 시간을 줄이려고 `ttl`을 낮추면 DCS나 네트워크가 잠깐 느려질 때도 멀쩡한 primary가 강등됩니다. 실제 장애 대응 시간 목표와 오탐 비용을 같이 놓고 정해야 합니다.
- **PostgreSQL 프로세스 장애는 대개 failover가 아니다.** postmaster가 죽으면 Patroni는 같은 노드에서 다시 띄웁니다. 로그에 `starting primary after failure`가 있으면 failover가 일어나지 않은 것이고, timeline도 그대로입니다.
- **DCS는 PostgreSQL만큼 중요하다.** leader가 DCS에 닿지 못하면 PostgreSQL이 멀쩡해도 강등됩니다. etcd 쿼럼이 깨지면 모든 노드가 DCS에 닿지 못하므로 클러스터 전체가 read-only가 됩니다([3편](/posts/postgresql/patroni-03-operations/#dcs가-멈추면-클러스터-전체가-read-only가-된다)).
- **Patroni는 연결을 옮겨 주지 않는다.** 새 primary가 생겨도 애플리케이션이 옛 주소로 붙고 있으면 소용이 없습니다. HAProxy, pgBouncer, DNS, libpq의 `target_session_attrs=read-write` 같은 별도 수단이 필요합니다([2편](/posts/postgresql/patroni-02-setup/#haproxy로-연결-보내기)).

## 정리

- Patroni는 노드마다 도는 **Patroni 데몬**과 **DCS**(etcd 등)로 이루어집니다. Patroni가 PostgreSQL을 자식 프로세스로 띄우고, 누가 primary인지는 DCS의 **leader key** 하나로 정합니다. 복제는 PostgreSQL 스트리밍 복제 그대로입니다.
- leader key는 TTL(`ttl`, 기본 30초)이 붙은 잠금이고, leader는 `loop_wait`(기본 10초)마다 lease를 갱신합니다. 갱신이 멈추면 key가 사라지고 replica들이 경쟁합니다.
- 경쟁에서는 nofailover 태그, 복제 지연(`maximum_lag_on_failover`), 다른 멤버와의 WAL 위치 비교를 거쳐 가장 앞선 노드가 key를 만듭니다. etcd의 원자적 생성 덕분에 leader는 하나만 나옵니다.
- PostgreSQL만 죽으면 제자리에서 재시작하고, 노드가 죽으면 lease 만료 뒤 failover합니다(실습 24초).
- DCS에 닿지 못한 primary는 `retry_timeout` 안에 스스로 강등합니다. `loop_wait + 2 × retry_timeout <= ttl` 덕분에 강등이 새 primary의 승격보다 먼저 일어납니다. 단, 이것은 Patroni 프로세스가 살아 있을 때의 이야기입니다.

다음 글에서는 이 클러스터를 Rocky Linux 9에서 처음부터 구성하고, HAProxy를 붙여 switchover와 failover를 직접 해 봅니다.

## 참고 자료

Patroni 소스 코드 (`v4.1.5` 태그 기준)

- [patroni/ha.py](https://github.com/patroni/patroni/blob/v4.1.5/patroni/ha.py): HA loop(`_run_cycle`), leader 경쟁(`is_healthiest_node`, `is_lagging`), DCS 장애 처리(`_handle_dcs_error`)
- [patroni/config.py](https://github.com/patroni/patroni/blob/v4.1.5/patroni/config.py#L298): `loop_wait + 2*retry_timeout <= ttl` 검사
- [patroni/dcs/etcd3.py](https://github.com/patroni/patroni/blob/v4.1.5/patroni/dcs/etcd3.py): etcd v3 lease와 leader key 처리

Patroni 공식 문서

- [Introduction](https://patroni.readthedocs.io/en/latest/README.html)
- [Dynamic Configuration Settings](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html): `ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover`
- [YAML Configuration Settings](https://patroni.readthedocs.io/en/latest/yaml_configuration.html): `tags`(`nofailover`, `failover_priority`)
- [REST API](https://patroni.readthedocs.io/en/latest/rest_api.html)

etcd

- [etcd: Lease API](https://etcd.io/docs/v3.6/learning/api/#lease-api)
