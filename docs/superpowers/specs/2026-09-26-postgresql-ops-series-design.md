# PostgreSQL 운영 연재 설계

- 작성일: 2026-09-26
- 상태: 승인됨 (2026-09-26)

## 목적

PostgreSQL 인터널 연재(10편)가 "왜 이렇게 동작하는가"를 다뤘다면, 운영 연재는 **"이 증상이 보이면 무엇을 어떤 순서로 확인하고 어떻게 조치하는가"**를 다룬다. 장애 현장에서 해당 편 하나만 펼쳐도 쓸 수 있어야 하고, 처음부터 순서대로 읽으면 진단 능력이 쌓여야 한다.

독자는 PRODUCT.md의 독자와 같다(주니어~미들 DBA, 백엔드 개발자, 시니어 DBA). 원리 설명은 인터널 편 링크로 넘기고, 이 연재는 증상 → 판단 → 조치의 흐름에 지면을 쓴다.

## 확정된 결정

| 항목 | 결정 |
|---|---|
| 연재 축 | 장애/증상별. 1편은 공통 진단 도구상자, 2~12편은 증상 하나씩 |
| 운영 환경 | 자체 구축 Linux. PostgreSQL 18, PGDG 공식 RPM 설치 |
| 도구 범위 | PostgreSQL 코어와 contrib 확장만. PgBouncer, Patroni, pgBackRest, pg_repack 등은 다루지 않는다 |
| 근거 | 모든 출력, 에러 문구, 수치는 Rocky Linux 9 도커 컨테이너에서 직접 재현해 측정한 것만 쓴다 |
| 태그 | 재현한 에러 메시지의 핵심 구절을 태그에 넣는다 |

## 목차

번호는 1부터 시작한다. 레이아웃이 `chapters`의 n번째 항목을 `weight: n`인 글과 연결하기 때문이다.

| 편 | 제목(가제) | 다루는 내용 | 주로 연결되는 인터널 편 |
|---|---|---|---|
| 1 | 진단 도구상자 | 미리 켜 둘 로그 설정(`log_lock_waits`, `log_autovacuum_min_duration`, `log_checkpoints`, `log_temp_files`, `log_min_duration_statement`), `pg_stat_activity`와 wait event, `pg_stat_statements`, `pg_stat_io`, OS에서 먼저 볼 것 | 1, 2 |
| 2 | 세션들이 멈춰 있다 | 락 대기, `pg_blocking_pids()`, DDL이 만드는 락 큐, deadlock, `lock_timeout` | 4 |
| 3 | 쿼리가 갑자기 느려졌다 | plan 변경, 통계 부정확, generic plan 전환, `auto_explain`, `pg_stat_statements`로 회귀 찾기 | 10 |
| 4 | 긴 트랜잭션과 idle in transaction | xmin horizon 정체, 원인 찾기(세션, prepared transaction, replication slot, standby feedback), `idle_in_transaction_session_timeout`, `transaction_timeout` | 4, 5 |
| 5 | 테이블과 인덱스가 계속 커진다 | bloat 측정(`pgstattuple`), autovacuum 튜닝, `REINDEX CONCURRENTLY`, `VACUUM FULL`의 비용 | 3, 5 |
| 6 | 디스크가 찬다 | `pg_wal` 증가(slot, archive 실패, `max_wal_size`), temp file, 서버 로그, 디스크가 가득 찼을 때 PostgreSQL의 동작 | 7, 9 |
| 7 | wraparound 경고가 떴다 | 경고 단계와 쓰기 거부, 원인 찾기, 강제 VACUUM 대응 | 6 |
| 8 | standby가 뒤처진다 | write/flush/replay lag 구분, hot standby 충돌, 쿼리 취소 | 9 |
| 9 | 접속이 안 된다 | too many clients, 예약 슬롯, `pg_hba.conf`와 인증 실패, 접속 폭주 | 1 |
| 10 | 주기적으로 I/O가 튄다 | 잦은 체크포인트, `pg_stat_checkpointer`, bgwriter, `checkpoint_completion_target` | 7, 8 |
| 11 | 메모리가 모자란다 | `work_mem`과 `hash_mem_multiplier`, OOM으로 backend가 죽을 때의 크래시 재시작 | 1, 2 |
| 12 | 데이터 손상이 의심된다 | checksum 오류, `amcheck`, `pg_checksums`, 손상 범위 파악과 대응 | 3, 8 |

편 제목과 순서는 글을 쓰면서 바꿀 수 있다. 바꾸면 이 표와 시리즈 `_index.md`를 같이 고친다.

## 사이트 구성

- 시리즈: `content/series/postgresql-운영/_index.md`
  - `title: "PostgreSQL 운영"`, `version: "PostgreSQL 18"`, `order: 3` (MongoDB 인터널이 2)
  - `chapters`에 위 12편을 넣는다. 쓰기 전인 편은 기존 동작대로 "준비 중"으로 보인다.
- 글: `content/posts/postgresql-ops/NN-<slug>.md`
  - `series: ["PostgreSQL 운영"]`, `categories: ["PostgreSQL"]`, `subcategory: "운영"`, `weight: NN`
  - 제목 형식: `PostgreSQL 운영 N: <제목>` (인터널 연재와 같은 형식)
  - 쓰는 동안에는 `draft: true`로 둔다. `draft: false`는 사용자가 확인한 뒤에 바꾼다.
- archetype: `archetypes/postgresql-ops.md`에 아래 글 틀을 넣는다.
- PRODUCT.md의 Operating Context에 운영 연재를 추가한다.
- 레이아웃은 고치지 않는다. 시리즈, 카테고리, subcategory가 기존 partial로 동작하는지 첫 편에서 확인하고, 안 되면 그때 따로 논의한다.

## 글 틀

인터널 연재 정리(커밋 `932c6b5`)에서 정한 방식을 따른다. 실습을 별도 섹션으로 모으지 않고 설명 옆에 놓고, 명령과 출력은 함께 보여 준다. 실습 설정 섹션, Docker 명령, 실습 번호는 본문에 넣지 않는다.

1. **개요**: 어떤 증상인지, 어떤 에러나 현상으로 처음 알게 되는지. 이 글에서 답할 질문 목록.
2. **기준 환경 한 줄**: 인터널 연재의 "기준 버전" 인용 블록과 같은 형식. 예: `> **기준 환경**: PostgreSQL 18.x(PGDG RPM), Rocky Linux 9. 본문의 출력은 모두 이 환경에서 장애를 직접 재현한 결과입니다.` 버전은 실측할 때의 정확한 패키지 버전으로 채운다.
3. **먼저 확인할 것**: 증상이 보이면 가장 먼저 돌릴 쿼리나 명령, 그 결과로 원인 후보를 좁히는 방법.
4. **원인별 진단**: 원인 후보마다 소절 하나. 재현한 출력으로 "이렇게 보이면 이 원인"을 보여 준다.
5. **조치**: 지금 당장 할 일과 근본 해결을 나눈다. 되돌릴 수 없는 조치(세션 종료, `VACUUM FULL`, 파일 삭제 등)에는 위험과 전제 조건을 적는다.
6. **재발 방지**: 모니터링 쿼리, 알람 기준, 미리 바꿔 둘 설정.
7. **정리**
8. **참고 자료**: PostgreSQL 18 공식 문서와 소스(`REL_18_STABLE` 커밋 고정 링크). 관련 인터널 편.

코드 블록은 기존 render hook을 쓴다. 셸은 ` ```console `(`$ ` 프롬프트), SQL은 ` ```psql `(`postgres=# ` 프롬프트)로 쓴다.

## 실측 환경

### 구성

- 베이스 이미지: Rocky Linux 9
- PostgreSQL: PGDG 저장소의 `postgresql18-server`, `postgresql18-contrib`. 기본 `postgresql` 모듈은 비활성화한다.
- 경로: `/usr/pgsql-18/bin`, `/var/lib/pgsql/18/data` (PGDG 기본값)
- 진단용 OS 도구: `procps-ng`, `sysstat`, `iproute`, `lsof`
- 컨테이너에는 systemd가 없으므로 `pg_ctl`로 서버를 띄운다. 본문에서 systemd 동작을 이야기할 때는 문서를 근거로 쓴다.
- 기본 구성은 primary 1대. 8편(복제 지연)처럼 필요한 편에서만 standby를 추가한다.

### 장애를 일으키는 방법

| 장애 | 방법 |
|---|---|
| 디스크 가득 참 | 크기를 제한한 볼륨에 데이터 디렉터리나 `pg_wal`을 둔다 |
| 메모리 부족 | 컨테이너 메모리 제한(`--memory`) |
| 데이터 손상 | 서버를 멈추고 `dd`로 relation 파일의 페이지를 망가뜨린다. PG18은 `initdb` 기본값으로 data checksum이 켜져 있다 |
| 락, 긴 트랜잭션, 접속 폭주 | 여러 psql 세션이나 `pgbench`로 만든다 |

### 실측 결과를 다루는 원칙

- 본문의 출력, 에러 문구, 수치는 모두 이 환경에서 실행해 캡처한 원본에서 가져온다. 캡처하지 않은 출력을 지어내거나, 다른 실행 결과끼리 짜깁기하지 않는다.
- 캡처 원본에서 본문으로 옮길 때 줄이는 것(관련 없는 줄 생략)은 허용한다. 생략한 곳은 `...`로 표시한다. 값을 바꾸지 않는다.
- 실습 환경과 실제 서버가 달라서 결과 해석이 달라지는 경우에는 본문에 그 차이를 적는다. 예:
  - 메모리 부족은 호스트의 OOM killer가 아니라 cgroup OOM으로 일어난다.
  - 커널은 Docker Desktop VM의 커널이다.
  - I/O 수치는 실제 디스크와 다르다.
  실제 서버에서 어떻게 다른지는 공식 문서를 근거로만 쓴다.
- 재현하지 못한 현상은 "재현하지 못했다"고 쓰거나 문서 근거로만 설명하고, 실측처럼 보이게 쓰지 않는다.

### 실습 파일 위치

인터널 연재에서는 실습 파일을 `static/labs/`에 두어 사이트에 공개했다가 커밋 `932c6b5`에서 지웠다. 운영 연재는 다음과 같이 한다.

- 실습 파일은 저장소 루트의 `labs/pg-ops/`에 둔다. Hugo 빌드 대상이 아니므로 사이트에 공개되지 않고, 본문에서 링크하지 않는다.
  - `Dockerfile` (standby가 필요한 편에서 `compose.yaml` 추가)
  - `scenarios/NN-<slug>/reproduce.sh`: 장애를 재현하는 스크립트
  - `scenarios/NN-<slug>/out/`: 캡처한 원본 출력
- 사용자 결정(2026-09-26): 저장소에 둔다.

## 태그

- 구성: `PostgreSQL` + 주제 태그 1~2개 + 에러 메시지 핵심 구절 0~3개
- 에러 구절 규칙
  - 그 편에서 **실제로 재현한 출력에 나온 문구**만 쓴다. 문서에서만 본 문구는 태그로 달지 않는다.
  - 메시지 전체가 아니라 검색에 쓰일 짧은 구절을 원문 그대로(영어, 대소문자 포함) 쓴다. 테이블 이름이나 숫자처럼 매번 바뀌는 부분은 뺀다.
  - SQLSTATE 코드는 본문에만 적고 태그로는 달지 않는다.
- 후보 예시(실측으로 확정): 2편 `deadlock detected`, `lock timeout` / 6편 `No space left on device` / 7편 `database is not accepting commands` / 8편 `conflict with recovery` / 9편 `too many clients already` / 12편 `invalid page in block`

## 편별 작업 흐름

1. `reproduce.sh`를 쓰고 컨테이너에서 실행해 `out/`에 출력을 캡처한다.
2. 캡처한 출력을 바탕으로 본문과 태그를 쓴다. 원리 설명은 인터널 편 링크로 대신한다.
3. 로컬 `hugo server`로 렌더링(코드 블록, 시리즈 목차, 사이드바의 subcategory)을 확인한다.
4. 한 편씩 커밋한다. 커밋 작성자는 사용자(git 설정의 `jiheo`)로 한다.
5. 사용자 확인을 받은 뒤 `draft: false`로 바꾼다.

1편을 쓰기 전에 시리즈 `_index.md`, archetype, 실측 환경(`Dockerfile`, `compose.yaml`)을 먼저 만든다.

## 범위 밖

- 레이아웃 변경(0편 번호 체계 등)
- 코어 밖 도구의 설치와 운영
- 클라우드 관리형 서비스(RDS, Aurora, Cloud SQL)와 Kubernetes 환경
- 인터널 연재 본문 수정. 운영 편에서 인터널 편으로 링크하는 것은 범위 안이고, 인터널 편에서 운영 편으로 거는 역링크는 연재가 어느 정도 쌓인 뒤 따로 정한다.
