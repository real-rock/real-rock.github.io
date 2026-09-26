---
title: "Patroni HA 2: 3노드 클러스터 구성하기"
date: 2026-09-26T08:00:00+09:00
draft: false
series: ["Patroni HA"]
categories: ["PostgreSQL"]
subcategory: "HA"
tags: ["PostgreSQL", "Patroni", "HA", "etcd", "HAProxy", "Rocky Linux"]
weight: 2
thumb: "구성"
summary: "Rocky Linux 9에 etcd 3대, Patroni 3대, HAProxy를 올리고 switchover와 failover를 해 본다"
description: "etcd, patroni.yml, HAProxy, switchover와 failover"
---

## 개요

[1편](/posts/postgresql/patroni-01-architecture/)에서 Patroni가 etcd의 leader key 하나로 primary를 정하고, 그 key가 사라지면 replica들이 경쟁한다는 것을 봤습니다. 이번 글에서는 그 클러스터를 Rocky Linux 9에서 처음부터 만듭니다. 순서는 다음과 같습니다.

1. PGDG 저장소에서 PostgreSQL 18, Patroni, etcd, HAProxy 설치
2. etcd 3대로 DCS 구성
3. `patroni.yml` 작성, 첫 노드 부트스트랩, replica 2대 추가
4. HAProxy로 쓰기와 읽기 연결 나누기
5. switchover(계획된 교대)와 failover(장애 교대) 확인

구성 중에 실제로 걸린 함정 두 가지(replica의 `pg_hba.conf` 누락, HAProxy 검사 주기 때문에 생긴 read-only 오류)도 그대로 보여 드립니다.

> **기준 버전**: Rocky Linux 9.8, PostgreSQL 18.6, Patroni 4.1.5, etcd 3.7.2, HAProxy 3.4.5. 모두 PGDG 저장소의 aarch64 RPM입니다. 서버 대신 `rockylinux:9` 이미지로 만든 컨테이너 7대를 쓰고, 컨테이너 안에서 systemd로 서비스를 띄웠습니다. 명령은 실제 서버에서도 같습니다.

실습 구성은 다음과 같습니다.

| 호스트 | 주소 | 역할 |
|---|---|---|
| etcd1, etcd2, etcd3 | 172.30.0.11-13 | etcd (DCS) |
| pg1, pg2, pg3 | 172.30.0.21-23 | PostgreSQL 18 + Patroni |
| haproxy | 172.30.0.31 | HAProxy (쓰기 5000, 읽기 5001) |

실습은 편의상 etcd, Patroni REST API, PostgreSQL 연결을 모두 평문으로 둡니다. 운영에서는 etcd의 client/peer 통신과 Patroni REST API에 TLS를 켜고, PostgreSQL 연결에도 SSL을 쓰는 것이 기본입니다. 인증은 [3편](/posts/postgresql/patroni-03-operations/#rest-api에는-인증을-건다)에서 다룹니다.

## 패키지 설치

PGDG 저장소를 등록하고, Rocky Linux 기본 AppStream의 `postgresql` 모듈을 끈 뒤 설치합니다. Patroni는 `pgdg-common` 저장소에 있고, etcd와 HAProxy는 기본으로 꺼져 있는 `pgdg-rhel9-extras` 저장소에 있습니다. 모든 노드에 같은 패키지를 넣었습니다(etcd 노드에는 etcd만, pg 노드에는 PostgreSQL과 Patroni만 있으면 됩니다).

```console
$ dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm
$ dnf -y install epel-release
$ dnf -qy module disable postgresql
$ dnf -y --enablerepo=pgdg-rhel9-extras install postgresql18-server postgresql18-contrib patroni patroni-etcd etcd haproxy
$ rpm -q postgresql18-server patroni patroni-etcd etcd haproxy
postgresql18-server-18.6-1PGDG.rhel9.8.aarch64
patroni-4.1.5-1PGDG.rhel9.8.noarch
patroni-etcd-4.1.5-1PGDG.rhel9.8.noarch
etcd-3.7.2-1PGDG.rhel9.8.aarch64
haproxy-3.4.5-1PGDG.rhel9.8.aarch64
```

- `patroni-etcd`는 Patroni가 etcd와 통신하는 데 필요한 의존성을 모은 패키지입니다. Consul이나 ZooKeeper를 쓰면 `patroni-consul`, `patroni-zookeeper`를 넣습니다.
- EPEL을 켜 두어야 Patroni의 Python 의존성이 풀립니다. Patroni RPM은 Python 3.12로 동작합니다(`/usr/bin/patroni`의 첫 줄이 `#!/usr/bin/python3.12`).
- `pgdg-common`에는 이전 버전인 `patroni-3.0.4` 패키지도 함께 있습니다. 버전을 고정하려면 `patroni-4.1.5`처럼 버전까지 적습니다.

#### RPM이 넣어 주는 systemd unit

```console
$ grep -vE "^#|^$" /usr/lib/systemd/system/patroni.service
[Unit]
Description=Runners to orchestrate a high-availability PostgreSQL
After=syslog.target network.target
[Service]
Type=notify
User=postgres
Group=postgres
EnvironmentFile=-/etc/patroni_env.conf
Environment=MALLOC_ARENA_MAX=1
Environment=PG_MALLOC_ARENA_MAX=
ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml
ExecReload=/usr/bin/kill -s HUP $MAINPID
KillMode=process
Restart=on-failure
TimeoutSec=30
Restart=no
[Install]
WantedBy=multi-user.target
```

- 설정 파일은 `/etc/patroni/patroni.yml`이고, `/etc/patroni_env.conf`가 있으면 환경 변수로 읽습니다. 비밀번호는 이 파일에 넣을 것입니다.
- `KillMode=process`: 서비스를 멈출 때 Patroni 프로세스에만 신호를 보냅니다. Patroni가 PostgreSQL을 순서대로 내리게 하려는 것입니다.
- `Restart=`가 두 번 나오고 뒤의 `Restart=no`가 이깁니다. Patroni가 죽어도 systemd가 되살리지 않습니다. 원본 주석에는 "장애 때 사람이 먼저 살펴보게 하려는 것"이라고 적혀 있습니다. Patroni가 죽은 채 PostgreSQL만 남는 상황의 위험은 [3편](/posts/postgresql/patroni-03-operations/#patroni가-죽으면-postgresql은-계속-primary다)에서 봅니다.
- 이 파일을 직접 고치지 말고 `/etc/systemd/system/patroni.service.d/` 아래 drop-in 파일로 덮어쓰라고 파일 머리 주석이 안내합니다.

## etcd 클러스터 만들기

etcd는 Raft로 합의하므로 **홀수 대**로 구성합니다. 3대면 1대, 5대면 2대까지 죽어도 쿼럼이 유지됩니다. etcd RPM의 unit은 `/etc/etcd/etcd.conf`를 환경 변수로 읽으니, 이 파일을 노드마다 이름과 주소만 바꿔 씁니다. etcd1의 설정입니다.

```console
$ cat /etc/etcd/etcd.conf
ETCD_NAME=etcd1
ETCD_DATA_DIR=/var/lib/etcd/default.etcd
ETCD_LISTEN_PEER_URLS=http://172.30.0.11:2380
ETCD_LISTEN_CLIENT_URLS=http://172.30.0.11:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://172.30.0.11:2380
ETCD_ADVERTISE_CLIENT_URLS=http://172.30.0.11:2379
ETCD_INITIAL_CLUSTER=etcd1=http://172.30.0.11:2380,etcd2=http://172.30.0.12:2380,etcd3=http://172.30.0.13:2380
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=pg-ha-etcd
```

세 노드에서 거의 동시에 띄웁니다. 첫 노드는 나머지가 올라와 쿼럼이 생길 때까지 기다립니다.

```console
$ systemctl start etcd       # etcd1, etcd2, etcd3에서
$ etcdctl --endpoints=172.30.0.11:2379,172.30.0.12:2379,172.30.0.13:2379 endpoint health -w table
┌──────────────────┬────────┬────────────┬───────┐
│     ENDPOINT     │ HEALTH │    TOOK    │ ERROR │
├──────────────────┼────────┼────────────┼───────┤
│ 172.30.0.12:2379 │   true │ 1.951041ms │       │
│ 172.30.0.13:2379 │   true │ 1.945791ms │       │
│ 172.30.0.11:2379 │   true │ 1.656417ms │       │
└──────────────────┴────────┴────────────┴───────┘
$ etcdctl member list -w table
┌──────────────────┬─────────┬───────┬─────────────────────────┬─────────────────────────┬────────────┐
│        ID        │ STATUS  │ NAME  │       PEER ADDRS        │      CLIENT ADDRS       │ IS LEARNER │
├──────────────────┼─────────┼───────┼─────────────────────────┼─────────────────────────┼────────────┤
│  72e66ce07e4d6a2 │ started │ etcd3 │ http://172.30.0.13:2380 │ http://172.30.0.13:2379 │      false │
│ efd75d861ad66f39 │ started │ etcd1 │ http://172.30.0.11:2380 │ http://172.30.0.11:2379 │      false │
│ f0e8a8f83b808c1e │ started │ etcd2 │ http://172.30.0.12:2380 │ http://172.30.0.12:2379 │      false │
└──────────────────┴─────────┴───────┴─────────────────────────┴─────────────────────────┴────────────┘
```

세 멤버가 모두 `started`이고 건강합니다. `endpoint status`로 보면 etcd2가 Raft leader였습니다. etcd는 디스크 fsync 지연과 네트워크 지연에 민감해서, 운영에서는 PostgreSQL과 디스크를 나눠 쓰거나 아예 별도 서버에 두는 경우가 많습니다. 이 실습도 etcd를 PostgreSQL 노드와 분리했습니다.

## patroni.yml 작성

pg1의 `/etc/patroni/patroni.yml`입니다. pg2, pg3는 `name`과 두 `connect_address`만 다릅니다.

```yaml
scope: pg-ha
namespace: /service/
name: pg1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 172.30.0.21:8008

etcd3:
  hosts:
    - 172.30.0.11:2379
    - 172.30.0.12:2379
    - 172.30.0.13:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 128MB
        password_encryption: scram-sha-256
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 172.30.0.21:5432
  data_dir: /var/lib/pgsql/18/data
  bin_dir: /usr/pgsql-18/bin
  pgpass: /var/lib/pgsql/.pgpass_patroni
  pg_hba:
    - local   all          all                        peer
    - host    all          all         127.0.0.1/32   scram-sha-256
    - host    replication  replicator  172.30.0.0/24  scram-sha-256
    - host    all          all         172.30.0.0/24  scram-sha-256
  parameters:
    unix_socket_directories: /run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

| 구역 | 뜻 |
|---|---|
| `scope`, `namespace`, `name` | 클러스터 이름(DCS의 `/service/pg-ha/`), 이 노드의 멤버 이름 |
| `restapi` | REST API가 들을 주소와, 다른 멤버와 HAProxy가 찾아올 주소 |
| `etcd3` | etcd v3 API로 접속할 etcd 노드들 |
| `bootstrap.dcs` | **클러스터를 처음 만들 때 한 번만** DCS의 `config` 키에 들어가는 설정. 그 뒤에 이 파일을 고쳐도 반영되지 않고, `patronictl edit-config`로 바꿔야 합니다 |
| `bootstrap.initdb` | 첫 노드가 실행할 initdb 옵션 |
| `postgresql` | 이 노드에만 적용되는 로컬 설정. 데이터 디렉터리, 바이너리 경로, `pg_hba.conf` 내용 |
| `tags` | failover 후보 제외(`nofailover`), 읽기 분산 제외(`noloadbalance`), 동기 standby 제외(`nosync`) 등 노드별 표시 |

- `use_pg_rewind: true`: failover 뒤 옛 primary를 다시 붙일 때 `pg_rewind`로 갈라진 부분만 되돌립니다. `pg_rewind`에는 `wal_log_hints = on`이나 data checksums가 필요해서 둘 다 켰습니다(PG18의 initdb는 checksums를 기본으로 켭니다).
- `use_slots: true`: replica마다 primary에 physical replication slot을 만들어 줍니다. slot 이름은 멤버 이름과 같습니다.
- `pgpass`: Patroni가 복제나 `pg_rewind`로 다른 노드에 접속할 때 쓰는 비밀번호 파일을 여기에 만듭니다.

#### 비밀번호는 환경 변수 파일로

`postgresql.authentication` 아래에 superuser, 복제, rewind 사용자의 이름과 비밀번호를 적을 수 있지만, 설정 파일에 비밀번호를 두지 않으려고 unit이 읽는 `/etc/patroni_env.conf`에 환경 변수로 넣었습니다. Patroni는 `PATRONI_` 접두사의 환경 변수로 대부분의 설정을 덮어쓸 수 있습니다.

```console
$ cat /etc/patroni_env.conf       # 비밀번호는 가렸습니다
PATRONI_SUPERUSER_USERNAME=postgres
PATRONI_SUPERUSER_PASSWORD=********
PATRONI_REPLICATION_USERNAME=replicator
PATRONI_REPLICATION_PASSWORD=********
PATRONI_REWIND_USERNAME=rewind_user
PATRONI_REWIND_PASSWORD=********
$ chown postgres:postgres /etc/patroni/patroni.yml /etc/patroni_env.conf
$ chmod 600 /etc/patroni/patroni.yml /etc/patroni_env.conf
```

`patroni --validate-config`로 설정을 미리 검사할 수 있습니다. 이때 환경 변수를 읽지 않으면 인증 설정이 없다고 나옵니다.

```console
$ patroni --validate-config /etc/patroni/patroni.yml; echo rc=$?
postgresql.authentication  is not defined.
rc=1
$ (set -a; . /etc/patroni_env.conf; set +a; patroni --validate-config /etc/patroni/patroni.yml); echo rc=$?
rc=0
```

## 첫 노드 부트스트랩

pg1에서 Patroni를 띄웁니다. 데이터 디렉터리는 비어 있고, DCS에도 아직 아무것도 없습니다.

```console
$ systemctl start patroni
$ journalctl -u patroni -o cat
Starting Runners to orchestrate a high-availability PostgreSQL...
2026-09-25 22:22:13,994 INFO: Using default value thread_stack_size = 524288
2026-09-25 22:22:13,997 INFO: Patroni global thread_pool_size = 5
2026-09-25 22:22:14,052 INFO: Selected new etcd server http://172.30.0.13:2379
2026-09-25 22:22:14,056 INFO: No PostgreSQL configuration items changed, nothing to reload.
2026-09-25 22:22:14,056 INFO: REST API thread_pool_size = 5
Started Runners to orchestrate a high-availability PostgreSQL.
2026-09-25 22:22:14,100 INFO: Lock owner: None; I am pg1
2026-09-25 22:22:14,189 INFO: trying to bootstrap a new cluster
The files belonging to this database system will be owned by user "postgres".
...
Data page checksums are enabled.
...
Success. You can now start the database server using:
    /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/18/data -l logfile start
2026-09-25 22:22:15,046 INFO: postmaster pid=131
localhost:5432 - accepting connections
2026-09-25 22:22:15,144 INFO: running post_bootstrap
2026-09-25 22:22:15,379 INFO: initialized a new cluster
2026-09-25 22:22:15,524 INFO: no action. I am (pg1), the leader with the lock
```

(initdb 출력 일부를 `...`로 줄였고, PostgreSQL이 뜨는 동안의 메시지 몇 줄을 뺐습니다.)

- `Lock owner: None`: leader key도, `initialize` 키도 없으니 pg1이 새 클러스터를 만들기로 합니다(`trying to bootstrap a new cluster`). 이 결정도 DCS의 `initialize` 키를 먼저 차지하는 방식이라, 여러 노드를 동시에 띄워도 initdb는 한 노드에서만 일어납니다.
- initdb, PostgreSQL 시작, `post_bootstrap`(복제용 사용자 등 생성) 뒤 `initialized a new cluster`, 그리고 leader key를 잡았습니다. 여기까지 1.5초입니다.

Patroni가 만든 사용자를 봅니다.

```psql
pg1=# SELECT rolname, rolsuper, rolreplication FROM pg_roles WHERE rolname IN ('postgres', 'replicator', 'rewind_user');
   rolname   | rolsuper | rolreplication 
-------------+----------+----------------
 postgres    | t        | t
 replicator  | f        | t
 rewind_user | f        | f
(3 rows)
```

`rewind_user`는 superuser가 아닌 대신 `pg_rewind`에 필요한 함수(`pg_ls_dir`, `pg_stat_file`, `pg_read_binary_file`)의 실행 권한을 받았습니다. 이때 DCS에 생긴 키는 [1편](/posts/postgresql/patroni-01-architecture/#dcs에-무엇이-저장되는가)에서 봤습니다.

## replica 추가

pg2에서 Patroni를 띄웁니다. 설정은 pg1과 같고 이름과 주소만 다릅니다.

```console
$ systemctl start patroni
$ journalctl -u patroni -o cat | grep -vE "^  |^Traceback|^    " | grep -E "INFO|ERROR|FATAL"
2026-09-25 22:23:05,427 INFO: Lock owner: pg1; I am pg2
2026-09-25 22:23:05,470 INFO: trying to bootstrap from leader 'pg1'
2026-09-25 22:23:07,304 INFO: replica has been created using basebackup
2026-09-25 22:23:07,305 INFO: bootstrapped from leader 'pg1'
2026-09-25 22:23:07,420 INFO: postmaster pid=102
2026-09-25 22:23:08,442 INFO: Lock owner: pg1; I am pg2
2026-09-25 22:23:08,442 INFO: establishing a new patroni heartbeat connection to postgres
2026-09-25 22:23:08,458 ERROR: Can not fetch local timeline and lsn from replication connection
connection to server at "localhost" (127.0.0.1), port 5432 failed: FATAL:  no pg_hba.conf entry for replication connection from host "127.0.0.1", user "replicator", no encryption
2026-09-25 22:23:08,547 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
```

(시작 직후의 설정 로그 몇 줄과, 오류와 함께 찍히는 Python traceback은 뺐습니다.)

- leader가 이미 있으니 `pg_basebackup`으로 pg1을 복제해 합류했습니다(`bootstrapped from leader 'pg1'`).
- 그런데 곧바로 `ERROR: Can not fetch local timeline and lsn from replication connection`이 10초마다 반복됩니다. Patroni는 replica의 timeline과 WAL 위치를 알아내려고 **자기 노드의 PostgreSQL에 localhost로 복제 연결**을 합니다. `pg_hba`에 복제 연결은 `172.30.0.0/24`에서만 허용했으니 `127.0.0.1`에서 온 연결이 거절된 것입니다.
- 복제 자체는 문제없이 돌지만, 이 정보는 failover 때 WAL 위치 비교와 timeline 확인에 쓰입니다. 그대로 두면 안 됩니다.

모든 노드의 `patroni.yml`에 한 줄을 넣고 reload합니다. `postgresql.pg_hba`는 로컬 설정이므로 파일을 고치고 `systemctl reload patroni`(SIGHUP)만 하면 Patroni가 `pg_hba.conf`를 다시 쓰고 PostgreSQL을 reload합니다.

```console
$ grep -A6 "pg_hba:" /etc/patroni/patroni.yml
  pg_hba:
    - local   all          all                        peer
    - host    all          all         127.0.0.1/32   scram-sha-256
    - host    replication  replicator  127.0.0.1/32   scram-sha-256
    - host    replication  replicator  172.30.0.0/24  scram-sha-256
    - host    all          all         172.30.0.0/24  scram-sha-256
  parameters:
$ systemctl reload patroni
$ journalctl -u patroni -o cat --since "-15s"
2026-09-25 22:23:45,988 INFO: Reloading PostgreSQL configuration.
server signaled
Reloaded Runners to orchestrate a high-availability PostgreSQL.
2026-09-25 22:23:47,046 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
2026-09-25 22:23:56,031 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
```

오류가 사라졌습니다. pg3도 같은 방법으로 붙이면 클러스터가 완성됩니다.

```console
$ patronictl -c /etc/patroni/patroni.yml list
+ Cluster: pg-ha (7689601790135361659) ------+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |   State   | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
| pg1    | 172.30.0.21 | Leader  | running   |  1 |             |     |            |     |
| pg2    | 172.30.0.22 | Replica | streaming |  1 |   0/504DB10 |   0 |  0/504DB10 |   0 |
| pg3    | 172.30.0.23 | Replica | streaming |  1 |   0/504DB10 |   0 |  0/504DB10 |   0 |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
```

`patronictl list`의 `TL`은 timeline, `Lag`는 leader보다 뒤처진 양(MB)입니다. primary 쪽에서 보면 [인터널 9편](/posts/postgresql/09-streaming-replication/)에서 본 그대로입니다.

```psql
pg1=# SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;
 slot_name | slot_type | active | restart_lsn 
-----------+-----------+--------+-------------
 pg2       | physical  | t      | 0/504DB10
 pg3       | physical  | t      | 0/504DB10
(2 rows)

pg1=# SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;
 application_name | client_addr |   state   | sync_state 
------------------+-------------+-----------+------------
 pg3              | 172.30.0.23 | streaming | async
 pg2              | 172.30.0.22 | streaming | async
(2 rows)
```

#### Patroni가 써 준 replica 설정

```console
$ head -3 /var/lib/pgsql/18/data/postgresql.conf       # pg2
# Do not edit this file manually!
# It will be overwritten by Patroni!
include 'postgresql.base.conf'
$ grep -E "^(primary_conninfo|primary_slot_name|recovery_target_timeline)" /var/lib/pgsql/18/data/postgresql.conf
primary_conninfo = 'dbname=postgres user=replicator passfile=/var/lib/pgsql/.pgpass_patroni host=172.30.0.21 port=5432 sslmode=prefer application_name=pg2 gssencmode=prefer channel_binding=prefer sslnegotiation=postgres'
primary_slot_name = 'pg2'
recovery_target_timeline = 'latest'
$ ls /var/lib/pgsql/18/data/standby.signal
/var/lib/pgsql/18/data/standby.signal
```

- `postgresql.conf`는 Patroni가 매번 새로 씁니다. initdb가 만든 원래 파일은 `postgresql.base.conf`로 이름이 바뀌어 `include`됩니다. 이 파일을 직접 고치면 안 되는 이유입니다.
- `primary_conninfo`의 `host`는 지금 leader(pg1)의 주소이고, `primary_slot_name`은 자기 이름입니다. leader가 바뀌면 Patroni가 이 값을 새 leader로 고쳐 씁니다. [인터널 9편](/posts/postgresql/09-streaming-replication/#pg_basebackup--r로-standby-만들기)에서 `pg_basebackup -R`이 해 주던 일을 Patroni가 계속 해 주는 셈입니다.

## HAProxy로 연결 보내기

애플리케이션이 primary를 찾아가게 하는 방법은 여럿이지만, 가장 흔한 것은 HAProxy가 **Patroni REST API로 health check**를 하는 방식입니다. REST API의 endpoint들은 노드의 역할에 따라 다른 HTTP 상태 코드를 돌려줍니다. primary pg1과 replica pg2에 각각 물어본 결과입니다.

| endpoint | pg1 (primary) | pg2 (replica) | 쓰임 |
|---|---|---|---|
| `GET /primary` | 200 | 503 | 쓰기 연결을 보낼 곳 |
| `GET /read-write` | 200 | 503 | `/primary`와 같음 |
| `GET /replica` | 503 | 200 | 읽기 연결을 보낼 곳 |
| `GET /health` | 200 | 200 | PostgreSQL이 떠 있는가 |
| `GET /liveness` | 200 | 200 | Patroni가 살아 있는가 (Kubernetes liveness probe용) |
| `GET /readiness` | 200 | 200 | 요청을 받을 준비가 되었는가 |

`/replica?lag=1MB`처럼 허용할 지연을 붙이면, 너무 뒤처진 replica를 읽기에서 뺄 수 있습니다. HAProxy 설정입니다(`/etc/haproxy/haproxy.cfg`).

```text
global
    log         127.0.0.1 local2
    maxconn     1000
    user        haproxy
    group       haproxy

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    retries                 3
    timeout connect         4s
    timeout client          30m
    timeout server          30m
    timeout check           5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 172.30.0.21:5432 maxconn 100 check port 8008
    server pg2 172.30.0.22:5432 maxconn 100 check port 8008
    server pg3 172.30.0.23:5432 maxconn 100 check port 8008

listen replicas
    bind *:5001
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 172.30.0.21:5432 maxconn 100 check port 8008
    server pg2 172.30.0.22:5432 maxconn 100 check port 8008
    server pg3 172.30.0.23:5432 maxconn 100 check port 8008
```

- 연결은 PostgreSQL 포트(5432)로 보내고, 검사는 `check port 8008`로 REST API에 합니다. 세 서버를 모두 등록해 두고, 검사에 통과한 서버로만 보냅니다.
- `inter 3s fall 3 rise 2`: 3초마다 검사하고, 3번 연속 실패하면 내리고, 2번 연속 성공하면 올립니다. Patroni 저장소의 예제 설정과 같은 값인데, 뒤에서 이 값 때문에 문제가 생깁니다.
- `on-marked-down shutdown-sessions`: 서버가 내려가면 그 서버로 붙어 있던 연결을 끊습니다. 강등된 옛 primary에 연결이 남아 있지 않게 하려는 것입니다.

```console
$ haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl start haproxy
$ curl -s "http://localhost:7000/;csv" | cut -d, -f1,2,18,37 | grep -E "primary|replicas" | grep -v FRONTEND
primary,pg1,UP,L7OK
primary,pg2,DOWN,L7STS
primary,pg3,DOWN,L7STS
primary,BACKEND,UP,
replicas,pg1,DOWN,L7STS
replicas,pg2,UP,L7OK
replicas,pg3,UP,L7OK
replicas,BACKEND,UP,
```

5000번은 pg1만, 5001번은 pg2와 pg3만 `UP`입니다. 애플리케이션용 사용자 `app`과 데이터베이스 `appdb`를 만들고 HAProxy로 접속해 봅니다.

```console
$ for p in 5000 5001 5001 5001; do psql -h localhost -p $p -U app -d appdb -Atc "select $p, inet_server_addr(), pg_is_in_recovery()"; done
5000|172.30.0.21|f
5001|172.30.0.22|t
5001|172.30.0.23|t
5001|172.30.0.22|t
```

5000번은 primary pg1로, 5001번은 replica 둘로 번갈아 갑니다.

## switchover: 계획된 교대

switchover는 점검이나 재시작을 위해 primary를 **계획적으로** 다른 노드로 넘기는 것입니다. 교대하는 동안 클라이언트가 무엇을 보는지 확인하려고, HAProxy 서버에서 0.5초마다 5000번 포트로 한 행씩 넣는 스크립트를 돌립니다.

```console
$ psql -h 127.0.0.1 -p 5000 -U app -d appdb -c "CREATE TABLE heartbeat (id bigserial PRIMARY KEY, at timestamptz DEFAULT clock_timestamp(), server inet DEFAULT inet_server_addr())"
$ cat /root/writer.sh
#!/bin/bash
# 0.5초마다 5000번 포트(primary)로 한 행씩 쓴다
while true; do
  r=$(psql "host=127.0.0.1 port=5000 user=app dbname=appdb connect_timeout=2" -Atc \
        "INSERT INTO heartbeat DEFAULT VALUES RETURNING server" 2>&1 | tr '\n' ' ' | cut -c1-140)
  echo "$(date +%T.%N | cut -c1-12) $r"
  sleep 0.5
done
$ /root/writer.sh > /root/writer.log 2>&1 &
```

(이 절의 첫 실험만은 스크립트가 `-h localhost`로 접속하고 오류의 첫 줄만 남겼습니다. 그래서 로그에 IPv6 주소 `::1`로 먼저 시도했다가 실패한 줄이 보입니다. HAProxy는 IPv4에서만 듣고 있습니다.)

pg1에서 pg2로 넘깁니다.

```console
$ patronictl -c /etc/patroni/patroni.yml switchover pg-ha --leader pg1 --candidate pg2 --force
Current cluster topology
+ Cluster: pg-ha (7689601790135361659) ------+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |   State   | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
| pg1    | 172.30.0.21 | Leader  | running   |  1 |             |     |            |     |
| pg2    | 172.30.0.22 | Replica | streaming |  1 |   0/549A288 |   0 |  0/549A288 |   0 |
| pg3    | 172.30.0.23 | Replica | streaming |  1 |   0/549A288 |   0 |  0/549A288 |   0 |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
2026-09-25 22:25:47.47296 Successfully switched over to "pg2"
+ Cluster: pg-ha (7689601790135361659) ----+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |  State  | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+---------+----+-------------+-----+------------+-----+
| pg1    | 172.30.0.21 | Replica | stopped |    |     unknown |     |    unknown |     |
| pg2    | 172.30.0.22 | Leader  | running |  2 |             |     |            |     |
| pg3    | 172.30.0.23 | Replica | running |  1 |   0/54A0BA0 |   0 |  0/54A0BA0 |   0 |
+--------+-------------+---------+---------+----+-------------+-----+------------+-----+
```

명령을 낸 것이 22:25:45.2, 완료 표시가 22:25:47.5입니다. 양쪽 Patroni 로그로 순서를 봅니다.

```console
$ journalctl -u patroni -o cat --since 22:25:44 --until 22:25:52 | grep -v "Got response"      # pg1
2026-09-25 22:25:45,375 INFO: received switchover request with leader=pg1 candidate=pg2 scheduled_at=None
2026-09-25 22:25:45,598 INFO: switchover: demoting myself
2026-09-25 22:25:45,598 INFO: Demoting self (graceful)
2026-09-25 22:25:46,911 INFO: Leader key released
2026-09-25 22:25:46,912 INFO: Lock owner: None; I am pg1
2026-09-25 22:25:46,912 INFO: not healthy enough for leader race
2026-09-25 22:25:46,969 INFO: Lock owner: pg2; I am pg1
2026-09-25 22:25:48,913 INFO: Local timeline=1 lsn=0/54A0B28
2026-09-25 22:25:48,923 INFO: primary_timeline=2
2026-09-25 22:25:49,054 INFO: postmaster pid=427
2026-09-25 22:25:50,173 INFO: no action. I am (pg1), a secondary, and following a leader (pg2)
$ journalctl -u patroni -o cat --since 22:25:44 --until 22:25:56      # pg2
2026-09-25 22:25:46,882 INFO: no action. I am (pg2), a secondary, and following a leader (pg1)
2026-09-25 22:25:46,969 INFO: Cleaning up failover key after acquiring leader lock...
2026-09-25 22:25:47,065 INFO: promoted self to leader by acquiring session lock
2026-09-25 22:25:47,066 INFO: Lock owner: pg2; I am pg2
2026-09-25 22:25:47,158 INFO: updated leader lock during promote
2026-09-25 22:25:48,255 INFO: no action. I am (pg2), the leader with the lock
```

(`Got response` 줄 말고도 `switchover: demote in progress`가 반복되는 줄, 연결을 다시 맺는 줄 등을 뺐습니다.)

- pg1은 REST API로 요청을 받고, pg2의 상태를 확인한 뒤 PostgreSQL을 **정상 종료**했습니다(`Demoting self (graceful)`). 정상 종료이므로 남은 WAL을 모두 replica에 보낸 다음 내려갑니다. 그리고 leader key를 스스로 지웠습니다(`Leader key released`). 1편의 failover처럼 lease 만료를 기다리지 않습니다.
- pg2는 key가 사라진 것을 watch로 바로 알아채고 key를 잡아 promote했습니다(timeline 2). pg1은 standby로 다시 시작해 pg2를 따릅니다. timeline이 바뀌었지만 pg1이 가진 WAL은 전부 pg2에도 있으므로 `pg_rewind`는 필요 없습니다.

#### HAProxy 검사 주기가 read-only 오류를 만든다

같은 시각 클라이언트가 본 것입니다.

```console
$ awk '$1>="22:25:44" && $1<="22:25:56"' /root/writer.log
22:25:44.399 172.30.0.21
22:25:44.923 172.30.0.21
22:25:45.433 172.30.0.21
22:25:48.958 psql: error: connection to server at "localhost" (::1), port 5000 failed: Connection refused
22:25:49.483 ERROR:  cannot execute INSERT in a read-only transaction
22:25:50.007 ERROR:  cannot execute INSERT in a read-only transaction
22:25:50.532 ERROR:  cannot execute INSERT in a read-only transaction
22:25:51.058 ERROR:  cannot execute INSERT in a read-only transaction
22:25:51.587 ERROR:  cannot execute INSERT in a read-only transaction
22:25:52.113 ERROR:  cannot execute INSERT in a read-only transaction
22:25:52.645 ERROR:  cannot execute INSERT in a read-only transaction
22:25:53.160 172.30.0.22
22:25:53.692 ERROR:  cannot execute INSERT in a read-only transaction
22:25:54.224 172.30.0.22
22:25:54.751 172.30.0.22
```

- 22:25:45.4 이후 3.5초 동안은 pg1이 내려가는 중이라 연결이 되지 않았습니다.
- 문제는 그다음입니다. 22:25:49.5부터 약 4초 동안 **`read-only transaction` 오류**가 났습니다. pg1은 이미 standby로 다시 떴는데, HAProxy가 아직 pg1을 primary 쪽 `UP`으로 보고 5000번 연결을 pg1으로 보낸 것입니다. `inter 3s fall 3`이면 내리기까지 최대 9초가 걸립니다.
- 22:25:53.7의 오류 한 줄은 pg2가 이미 `UP`이 되었는데 pg1이 아직 내려가지 않아, 두 서버에 번갈아 보낸 결과입니다. 잠깐이지만 쓰기 포트에 서버가 둘 걸려 있었습니다.

검사를 촘촘하게 바꾸고(`inter 1s fall 2 rise 1`), 반대로 pg2에서 pg1으로 다시 넘겨 봅니다.

```console
$ sed -i 's/inter 3s fall 3 rise 2/inter 1s fall 2 rise 1/' /etc/haproxy/haproxy.cfg && systemctl reload haproxy
$ patronictl -c /etc/patroni/patroni.yml switchover pg-ha --leader pg2 --candidate pg1 --force >/dev/null    # 22:26:29.9
$ awk '$1>="22:26:28" && $1<="22:26:35"' /root/writer.log
22:26:28.459 172.30.0.22
22:26:28.995 172.30.0.22
22:26:29.523 172.30.0.22
22:26:30.032 172.30.0.22
22:26:33.059 psql: error: connection to server at "localhost" (::1), port 5000 failed: Connection refused
22:26:33.569 172.30.0.21
22:26:34.085 172.30.0.21
22:26:34.619 172.30.0.21
```

이번에는 read-only 오류 없이 약 3.5초 쓰기가 끊겼다가 바로 새 primary로 이어졌습니다. 검사를 1초마다 하면 노드 3대 × 포트 2개로 초당 6번 REST API를 부르게 되지만, Patroni REST API에는 가벼운 요청입니다.

HAProxy 대신 또는 함께 쓸 수 있는 장치도 있습니다. libpq 연결 문자열에 호스트를 여러 개 적고 `target_session_attrs=read-write`를 주면, 클라이언트가 스스로 쓰기 가능한 서버를 찾아 붙습니다. 이 방법은 연결을 맺을 때만 확인하므로, 이미 맺은 연결이 강등된 서버에 남는 문제는 풀링 계층이나 애플리케이션의 재접속으로 풀어야 합니다.

## failover: 장애 교대

이번에는 primary pg1 컨테이너를 강제로 죽입니다. 과정은 [1편](/posts/postgresql/patroni-01-architecture/#primary-노드를-통째로-죽인다)에서 자세히 봤으니 클라이언트 쪽 결과만 봅니다.

```console
$ docker kill pg1       # 22:27:11.440
$ awk '$1>="22:27:10" && $1<="22:27:40"' /root/writer.log | awk '{k=$2" "$3" "$4; if (k!=p) print; p=k}'
22:27:10.173 172.30.0.21 INSERT 0 1 
22:27:13.731 psql: error: connection to server at "127.0.0.1", port 5000 failed: timeout expired 
22:27:35.826 172.30.0.22 INSERT 0 1 
$ patronictl -c /etc/patroni/patroni.yml list       # pg2에서
+ Cluster: pg-ha (7689601790135361659) ------+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |   State   | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
| pg2    | 172.30.0.22 | Leader  | running   |  4 |             |     |            |     |
| pg3    | 172.30.0.23 | Replica | streaming |  4 |   0/54C34C8 |   0 |  0/54C34C8 |   0 |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
```

(두 번째 `awk`는 같은 종류의 줄이 이어지면 첫 줄만 남깁니다.) 쓰기는 22:27:11 무렵부터 22:27:35.8까지 약 24초 끊겼습니다. switchover의 3.5초와 달리 lease 만료를 기다렸기 때문입니다. 죽은 pg1은 멤버 key도 같은 lease에 붙어 있어 목록에서 아예 사라졌습니다.

#### 죽었던 옛 primary를 다시 붙인다

pg1 서버를 다시 켜고 Patroni를 띄웁니다. 운영자가 한 일은 이것뿐입니다.

```console
$ systemctl start patroni        # pg1
$ journalctl -u patroni -o cat -b | grep -E "INFO|WARN" | grep -vE "thread_|etcd server|nothing to reload"
2026-09-25 22:28:12,974 WARNING: Postgresql is not running.
2026-09-25 22:28:12,974 INFO: Lock owner: pg2; I am pg1
2026-09-25 22:28:12,975 INFO: pg_controldata:
2026-09-25 22:28:13,020 INFO: doing crash recovery in a single user mode
...
2026-09-25 22:28:13,118 INFO: Local timeline=3 lsn=0/6000028
2026-09-25 22:28:13,125 INFO: primary_timeline=4
2026-09-25 22:28:13,125 INFO: primary: history=1	0/54A0BA0	no recovery target specified
2026-09-25 22:28:13,170 INFO: running pg_rewind from pg2
2026-09-25 22:28:13,183 INFO: running pg_rewind from dbname=postgres user=rewind_user host=172.30.0.22 port=5432 target_session_attrs=read-write
2026-09-25 22:28:13,559 INFO: pg_rewind exit code=0
2026-09-25 22:28:13,559 INFO:  stdout=
2026-09-25 22:28:13,559 INFO:  stderr=pg_rewind: servers diverged at WAL location 0/54B9380 on timeline 3
2026-09-25 22:28:13,601 INFO: starting as a secondary
2026-09-25 22:28:13,720 INFO: postmaster pid=96
2026-09-25 22:28:14,843 INFO: no action. I am (pg1), a secondary, and following a leader (pg2)
$ patronictl -c /etc/patroni/patroni.yml list
+ Cluster: pg-ha (7689601790135361659) ------+----+-------------+-----+------------+-----+
| Member |     Host    |   Role  |   State   | TL | Receive LSN | Lag | Replay LSN | Lag |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
| pg1    | 172.30.0.21 | Replica | streaming |  4 |   0/54C9D20 |   0 |  0/54C9D20 |   0 |
| pg2    | 172.30.0.22 | Leader  | running   |  4 |             |     |            |     |
| pg3    | 172.30.0.23 | Replica | streaming |  4 |   0/54C9D20 |   0 |  0/54C9D20 |   0 |
+--------+-------------+---------+-----------+----+-------------+-----+------------+-----+
```

(`...`는 같은 상태 줄이 반복되는 부분을 줄였습니다.)

1. pg1은 비정상 종료된 상태였으므로, 먼저 **single user mode로 crash recovery**를 해서 데이터 디렉터리를 일관된 상태로 만듭니다([인터널 8편](/posts/postgresql/08-checkpoint-and-recovery/)).
2. 자신은 timeline 3, leader pg2는 timeline 4입니다. pg1이 죽기 직전에 쓴 WAL 중 pg2가 받지 못한 부분이 있으면 두 서버의 역사가 갈라진 상태입니다.
3. `pg_rewind`가 두 서버가 갈라진 위치(`0/54B9380`)를 찾아 pg1을 그 지점으로 되돌리고, standby로 시작해 pg2를 따릅니다.

`use_pg_rewind`가 없었다면 이 노드는 스스로 합류하지 못하고, 데이터 디렉터리를 지우고 새로 복제(`patronictl reinit`)해야 했을 것입니다.

"되돌린다"는 말은 pg1에만 있던 WAL을 버린다는 뜻입니다. 그 WAL에 클라이언트가 커밋 응답을 받은 트랜잭션이 들어 있었다면 그 데이터는 사라집니다. 이번에는 확인해 보니 잃은 것이 없었습니다.

```console
$ psql -h 127.0.0.1 -p 5000 -U app -d appdb -c "select server, count(*), max(at)::time(3) as last_at from heartbeat group by server order by 3"
   server    | count |   last_at    
-------------+-------+--------------
 172.30.0.21 |    88 | 22:27:11.221
 172.30.0.22 |   196 | 22:28:41.355
(2 rows)
$ grep 172.30.0.21 /root/writer.log | tail -1
22:27:11.224 172.30.0.21 INSERT 0 1 
```

pg1에 성공한 마지막 쓰기(22:27:11.224)가 새 primary에도 있습니다(22:27:11.221에 커밋된 행). 0.5초에 한 행이라는 가벼운 부하였고, pg2가 WAL을 거의 실시간으로 받고 있었기 때문입니다. 부하가 크거나 복제가 지연된 순간에 primary가 죽으면 결과가 다릅니다. [3편](/posts/postgresql/patroni-03-operations/#비동기-복제는-커밋-응답을-받은-데이터도-잃을-수-있다)에서 수만 건을 잃는 경우를 재현합니다.

## 운영에서는 이렇게 나타납니다

- **replica의 `pg_hba`에 localhost 복제 연결이 없으면** Patroni 로그에 `Can not fetch local timeline and lsn from replication connection`이 계속 찍힙니다. 복제는 되니 놓치기 쉽지만, failover 판단에 쓰는 정보이므로 `host replication <복제 사용자> 127.0.0.1/32`를 꼭 넣습니다.
- **HAProxy 검사 주기는 switchover의 품질을 정한다.** 느슨하면 강등된 옛 primary로 쓰기가 가서 read-only 오류가 나고, 잠깐 두 서버에 쓰기 연결이 나뉩니다. `inter`를 1-2초로 줄이고 `on-marked-down shutdown-sessions`를 둡니다.
- **switchover는 수 초, failover는 TTL.** 실습에서 switchover의 쓰기 중단은 약 3.5초, 노드 장애 failover는 약 24초였습니다. 점검은 항상 switchover로 합니다.
- **`bootstrap.dcs`는 처음 한 번만 쓰인다.** 클러스터가 만들어진 뒤 `patroni.yml`의 `bootstrap` 구역을 고쳐도 아무 일도 일어나지 않습니다. 클러스터 전체 설정은 `patronictl edit-config`로 바꿉니다([3편](/posts/postgresql/patroni-03-operations/#설정은-dcs에서-바꾼다)).

## 정리

- Rocky Linux 9에서는 PGDG 저장소 하나로 PostgreSQL 18, Patroni 4.1, etcd, HAProxy를 모두 설치할 수 있습니다. etcd와 HAProxy는 `pgdg-rhel9-extras` 저장소에 있습니다.
- etcd는 홀수 대로 쿼럼을 만들고, Patroni는 노드마다 `patroni.yml` 하나로 설정합니다. 비밀번호는 unit이 읽는 `/etc/patroni_env.conf`에 환경 변수로 둘 수 있습니다.
- 첫 노드가 initdb로 클러스터를 만들고 leader key를 잡으면, 나머지 노드는 `pg_basebackup`으로 복제해 합류합니다. Patroni가 replica의 `primary_conninfo`와 slot을 관리합니다.
- HAProxy는 REST API(`/primary`, `/replica`)로 health check를 해서 쓰기와 읽기 연결을 나눕니다.
- switchover는 옛 primary가 정상 종료하고 key를 넘기므로 수 초에 끝나고, failover는 lease 만료를 기다립니다. 죽었던 옛 primary는 `pg_rewind`로 갈라진 부분을 되돌리고 스스로 합류합니다.

다음 글에서는 이 클러스터를 운영할 때 실제로 사고가 나는 지점들을 봅니다. 설정을 어디서 바꿔야 하는지, etcd가 멈추면 무슨 일이 생기는지, failover에서 데이터를 얼마나 잃을 수 있는지, Patroni가 죽으면 무엇이 위험한지를 재현합니다.

## 참고 자료

- [PostgreSQL Yum Repository (PGDG)](https://yum.postgresql.org/)
- [Patroni: YAML Configuration Settings](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [Patroni: Environment Configuration Settings](https://patroni.readthedocs.io/en/latest/ENVIRONMENT.html)
- [Patroni: REST API](https://patroni.readthedocs.io/en/latest/rest_api.html)
- [Patroni: patronictl](https://patroni.readthedocs.io/en/latest/patronictl.html)
- [Patroni 저장소의 HAProxy 예제 설정 (haproxy.cfg)](https://github.com/patroni/patroni/blob/v4.1.5/haproxy.cfg)
- [etcd: Clustering Guide](https://etcd.io/docs/v3.6/op-guide/clustering/)
- [PostgreSQL 18: pg_rewind](https://www.postgresql.org/docs/18/app-pgrewind.html)
- [PostgreSQL 18: libpq target_session_attrs](https://www.postgresql.org/docs/18/libpq-connect.html#LIBPQ-CONNECT-TARGET-SESSION-ATTRS)
