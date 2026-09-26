#!/bin/bash
# PostgreSQL 운영 8편(standby가 뒤처진다) 실습. primary와 standby 두 컨테이너를 같은 도커 네트워크에 띄운다.
cd "$(dirname "$0")"
export OUT=out/capture.txt CT=pgprimary PROMPT=primary
source ../../lib/labkit.sh
NET=pgops-net
SB=pgstandby

# standby에서 실행하는 도우미
sq()  { CT=$SB PROMPT=standby q "$@"; }
spg() { CT=$SB pg; }
PLOG='tail -n 400 "$(ls -t $PGDATA/log/*.log | head -1)"'
LAG="SELECT application_name AS app, state, sent_lsn, replay_lsn,
       write_lag, flush_lag, replay_lag,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
FROM pg_stat_replication;"
SLAG="SELECT pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS gap,
       now() - pg_last_xact_replay_timestamp() AS since_last_replay;"

step "0. 실습 환경"
docker rm -f "$SB" >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
host "docker network create $NET"
fresh_cluster --network $NET
env_info
note "실습용 접속 허용 (운영에서는 대상과 인증 방식을 좁힌다)"
pg <<'SH'
printf 'host all all samenet trust\nhost replication all samenet trust\n' >> $PGDATA/pg_hba.conf
SH
q "ALTER SYSTEM SET listen_addresses = '*';"
q "ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d/%a ';"
pg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w restart -m fast
SH
q "CREATE TABLE acc (id int PRIMARY KEY, v int);"
q "INSERT INTO acc SELECT g, 0 FROM generate_series(1, 100000) g;"
host "docker run -d --init --name $SB --hostname $SB --network $NET $IMAGE sleep infinity"
spg <<'SH'
pg_basebackup -h pgprimary -D $PGDATA -R -X stream -C -S standby1 -c fast
ls $PGDATA/standby.signal && grep primary_conninfo $PGDATA/postgresql.auto.conf
SH
spg <<'SH'
cat >> $PGDATA/postgresql.auto.conf <<'CONF'
log_line_prefix = '%m [%p] %q%u@%d/%a '
log_recovery_conflict_waits = on
max_standby_streaming_delay = '10s'
CONF
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH

step "1. 정상 상태"
q "$LAG"
sq "$SLAG"
sq "SELECT status, sender_host, written_lsn, flushed_lsn FROM pg_stat_wal_receiver;"
sq "SELECT name, setting FROM pg_settings WHERE name IN ('hot_standby_feedback', 'max_standby_streaming_delay', 'log_recovery_conflict_waits') ORDER BY name;"

step "2. standby의 긴 쿼리가 재생을 멈춘다"
CT=$SB sess_start R
CT=$SB sess R "SET application_name = 'report';"
CT=$SB sess R "\\timing on"
CT=$SB sess R "SELECT count(*), pg_sleep(40) FROM acc;" 1
q "UPDATE acc SET v = v + 1;"
q "VACUUM acc;"
sleep 4
q "$LAG"
sq "$SLAG"
spg <<SH
$PLOG | grep -E 'recovery still waiting|conflict' | tail -n 3
SH
CT=$SB sess_wait R 10
spg <<SH
$PLOG | grep -E 'recovery conflict|canceling statement|finished waiting' | tail -n 4
SH
sleep 2
q "$LAG"
sq "SELECT datname, confl_snapshot, confl_lock, confl_bufferpin, confl_deadlock FROM pg_stat_database_conflicts WHERE datname = 'postgres';"

step "3. hot_standby_feedback: 취소 대신 primary의 VACUUM을 막는다"
sq "ALTER SYSTEM SET hot_standby_feedback = on;"
sq "SELECT pg_reload_conf();"
sleep 2
CT=$SB sess R "SELECT count(*), pg_sleep(20) FROM acc;" 1
sleep 1
q "SELECT application_name AS app, backend_xmin FROM pg_stat_replication;"
q "SELECT slot_name, active, xmin, age(xmin) AS xmin_age FROM pg_replication_slots;"
q "UPDATE acc SET v = v + 1;"
q "VACUUM (VERBOSE) acc;"
sleep 2
q "$LAG"
CT=$SB sess_wait R 20
CT=$SB sess_end R

step "4. standby가 멈추면"
spg <<'SH'
pg_ctl -D $PGDATA -w stop -m fast
SH
q "$LAG"
pg <<'SH'
pgbench -i -s 10 -q postgres 2>&1 | tail -n 1
SH
q "SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;"
spg <<'SH'
pg_ctl -D $PGDATA -l /var/lib/pgsql/startup.log -w start
SH
sleep 1
q "$LAG"

docker rm -f "$SB" "$CT" >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
