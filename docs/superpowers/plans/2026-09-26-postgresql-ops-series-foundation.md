# PostgreSQL 운영 연재 기반 + 1편 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PostgreSQL 운영 연재의 시리즈 페이지, 실측 환경, 실측 검증 도구를 만들고, 그 위에서 1편(진단 도구상자)을 실측 기반으로 쓴다.

**Architecture:** Hugo 콘텐츠(`content/series`, `content/posts/postgresql-ops`)와 공개되지 않는 실습 디렉터리(`labs/pg-ops`)로 나눈다. 실습은 Rocky Linux 9 + PGDG RPM 이미지에서 `reproduce.sh`가 장애를 재현하고 `out/`에 캡처를 남긴다. `verify-post.py`는 글의 코드 블록 줄이 모두 캡처에 있는지 기계적으로 확인한다.

**Tech Stack:** Hugo 0.166 extended + PaperMod, Docker 29, `rockylinux:9`, PGDG `postgresql18-server`/`postgresql18-contrib`, bash, python3(표준 라이브러리만).

**Spec:** `docs/superpowers/specs/2026-09-26-postgresql-ops-series-design.md`

2~12편은 이 계획의 Task 4~6과 같은 방식으로 편마다 따로 진행한다(편별 계획은 그때 쓴다).

## Global Constraints

- PostgreSQL 18, PGDG RPM, Rocky Linux 9 컨테이너. 코어와 contrib만.
- 본문의 출력, 에러 문구, 수치는 모두 `labs/pg-ops/scenarios/NN-<slug>/out/`의 캡처에서 가져온다. 줄 생략(`...`)만 허용하고 값을 바꾸지 않는다.
- 본문에 Docker 명령, 실습 설정 섹션, 실습 번호를 넣지 않는다. 명령과 출력은 함께 보여 준다. 셸은 ` ```console `(`$ `), SQL은 ` ```psql `(`postgres=# `, 세션 구분은 `A=# `).
- 태그: `PostgreSQL` + 주제 1~2개 + 캡처에 실제로 나온 에러/로그 핵심 구절 0~3개(원문 대소문자 그대로).
- 글은 `draft: true`로 커밋한다. 공개는 사용자 확인 뒤.
- 커밋 작성자는 git 설정의 사용자(`jiheo`). Claude 공동 작성자 줄을 넣지 않는다(사용자 CLAUDE.md).
- 한국어 문체는 인터널 연재와 같은 "~합니다"체.
- `nexus.onkakao.net` 등 Kakao 도메인 이미지를 쓰지 않는다. 베이스는 로컬의 `rockylinux:9`.

---

### Task 1: 시리즈 페이지와 archetype

**Files:**
- Create: `content/series/postgresql-운영/_index.md`
- Create: `archetypes/postgresql-ops.md`
- Modify: `PRODUCT.md` (Operating Context)
- Modify: spec(`order` 값, labs 위치 확정, compose 시점)

- [ ] **Step 1: 실패 확인** — `D=$(mktemp -d); hugo --quiet -D -d "$D"; test -f "$D/series/postgresql-운영/index.html"` → 파일 없음.
- [ ] **Step 2: 시리즈 `_index.md` 작성** — `title: "PostgreSQL 운영"`, `version: "PostgreSQL 18"`, `order: 3`(MongoDB 인터널이 2), 스펙 목차 12편을 `chapters`에.
- [ ] **Step 3: archetype 작성** — 스펙의 글 틀 헤딩과 front matter(`series`, `categories`, `subcategory: "운영"`, `draft: true`).
- [ ] **Step 4: PRODUCT.md와 스펙 갱신**
- [ ] **Step 5: 확인** — 같은 빌드에서 시리즈 페이지가 생기고 `ch-state">준비 중`이 12번 나온다. `hugo --quiet`(draft 제외) 빌드도 오류가 없어야 한다.
- [ ] **Step 6: 커밋** — `Add the PostgreSQL operations series page`

### Task 2: 실측 이미지와 하네스

**Files:**
- Create: `labs/pg-ops/Dockerfile`
- Create: `labs/pg-ops/lib/labkit.sh`
- Create: `labs/pg-ops/smoke.sh`
- Create: `labs/pg-ops/README.md`

**Interfaces (labkit.sh, reproduce.sh가 source):**
- 환경 변수: `CT`(기본 `pgops`), `IMAGE`(기본 `pg-ops:rocky9-pg18`), `OUT`(필수, 캡처 파일)
- `step "제목"`, `note "메모"`: 캡처에 구분선/메모
- `host "명령"`: 호스트에서 실행, `$ 명령` + 출력 + `[exit=N]`
- `pg <<'EOF' … EOF`: 컨테이너 안 postgres 사용자로 셸 스크립트. 각 줄을 `$ `로 기록한 뒤 출력
- `pgroot <<'EOF' … EOF`: root로 실행, `# (root) `로 기록
- `q "SQL" [psql 옵션]`: `postgres=# SQL`(여러 줄이면 이어지는 줄은 `postgres-# `)을 기록하고 `psql -X -c`로 실행
- `sess_start A`, `sess A "SQL" [대기초]`, `sess_wait A [대기초]`, `sess_end A`: 동시에 여러 세션. 보낸 SQL은 `A=# SQL`로 기록
- `fresh_cluster [docker run 옵션…]`: 컨테이너를 새로 띄우고 `initdb`, `pg_ctl start`
- `env_info`: Rocky 릴리스, 패키지 버전, `postgres --version`, `uname -r`

- [ ] **Step 1: 실패 확인** — `labs/pg-ops/smoke.sh`를 먼저 쓰고 실행 → 이미지가 없어 FAIL.
- [ ] **Step 2: Dockerfile** — `rockylinux:9` + PGDG repo RPM + `dnf -qy module disable postgresql` + `postgresql18-server postgresql18-contrib procps-ng sysstat iproute lsof less glibc-langpack-en`, `/run/postgresql` 생성(컨테이너에는 tmpfiles.d가 돌지 않음), `PATH=/usr/pgsql-18/bin`, `PGDATA=/var/lib/pgsql/18/data`, `LANG=en_US.UTF-8`, `USER postgres`.
- [ ] **Step 3: labkit.sh** — 위 인터페이스 구현(인터널 연재 labkit을 바탕으로 `q`, `env_info`, 세션 프롬프트 형식을 추가).
- [ ] **Step 4: 빌드와 smoke 통과** — `docker build -t pg-ops:rocky9-pg18 labs/pg-ops && labs/pg-ops/smoke.sh` → 모든 줄 `ok`, exit 0. 확인 항목: Rocky 9, server_version_num 18xxxx, `data_checksums = on`, contrib 확장 5종 생성, `LOAD 'auto_explain'`, `pgbench` 18.
- [ ] **Step 5: 커밋** — `Add a Rocky Linux 9 lab image for the operations series`

### Task 3: 실측 검증 도구

**Files:**
- Create: `labs/pg-ops/lib/verify-post.py`
- Create: `labs/pg-ops/lib/tests/test-verify-post.sh` + 픽스처

규칙: 글의 ` ```console `, ` ```psql `, ` ```text ` 블록 안 줄(빈 줄과 `...` 제외)은 줄 끝 공백을 무시하고 캡처 파일 어딘가에 같은 줄로 있어야 한다. 캡처 쪽의 `psql:<stdin>:N: ` 접두어(하네스가 psql을 표준입력으로 돌려서 생기는 것)는 지우고 비교한다.

- [ ] **Step 1: 테스트 작성** — 통과 픽스처(캡처에 있는 줄 + `...` 생략), 실패 픽스처(캡처에 없는 수치 한 줄) 두 경우.
- [ ] **Step 2: 실패 확인** — 스크립트 없음으로 FAIL.
- [ ] **Step 3: 구현**
- [ ] **Step 4: 테스트 통과**
- [ ] **Step 5: 커밋** — `Add a checker that ties post outputs to lab captures`

### Task 4: 1편 재현 스크립트와 캡처

**Files:**
- Create: `labs/pg-ops/scenarios/01-diagnostic-toolkit/reproduce.sh`
- Create: `labs/pg-ops/scenarios/01-diagnostic-toolkit/out/capture.txt` (실행 결과)

재현 단계:
1. 환경: `fresh_cluster`, `env_info`
2. 설치 직후 로그 관련 설정값(`pg_settings`): `logging_collector`, `log_directory`, `log_filename`, `log_line_prefix`, `log_lock_waits`, `log_autovacuum_min_duration`, `log_checkpoints`, `log_temp_files`, `log_min_duration_statement`, `track_io_timing`, `shared_preload_libraries`
3. 진단용 설정 켜기(`ALTER SYSTEM`) → `pending_restart` 확인 → 재시작
4. 락 대기: 세션 A가 행을 잡은 채 idle in transaction, 세션 B가 같은 행 UPDATE → `pg_stat_activity`(state, wait_event_type, wait_event, `pg_blocking_pids`), `ps`의 프로세스 제목, 서버 로그의 `log_lock_waits` 메시지
5. `pgbench` 부하 후 `pg_stat_statements` 상위 쿼리
6. `work_mem`을 줄인 정렬 → `EXPLAIN (ANALYZE, BUFFERS)`, `log_temp_files`, `log_min_duration_statement`, `auto_explain` 로그
7. `pg_stat_io`
8. autovacuum과 checkpoint 로그
9. OS: 부하 중 `iostat`, `df`, `free`

- [ ] **Step 1: 스크립트 작성 후 실행** — `labs/pg-ops/scenarios/01-diagnostic-toolkit/reproduce.sh`
- [ ] **Step 2: 캡처 확인** — 캡처에 다음이 모두 있어야 한다: `still waiting for`, `pending_restart`, `Sort Method: external merge`, `temporary file:`, `duration:`, `automatic vacuum of table`, `checkpoint complete`. 없으면 스크립트를 고쳐 다시 실행(캡처는 항상 한 번의 전체 실행 결과여야 한다).
- [ ] **Step 3: 커밋** — `Capture the diagnostic toolkit lab for operations part 1`

### Task 5: 1편 본문

**Files:**
- Create: `content/posts/postgresql-ops/01-diagnostic-toolkit.md` (`hugo new content --kind postgresql-ops`)

- [ ] **Step 1: 본문 작성** — 스펙의 글 틀. 기준 환경 줄의 버전은 캡처의 `rpm -q` 결과. 원리는 인터널 1·2·4·5·7·8·10편 링크.
- [ ] **Step 2: 검증** — `python3 labs/pg-ops/lib/verify-post.py <글> <캡처>` exit 0, 본문에 `docker`/`Docker` 없음, 태그의 에러 구절이 캡처에 있음, `hugo --quiet -D` 오류 없음.
- [ ] **Step 3: 커밋** — `Draft PostgreSQL operations part 1: the diagnostic toolkit`

### Task 6: 렌더링 확인

- [ ] `hugo` 미리보기(`.claude/launch.json`의 `hugo`)로 1편, 시리즈 페이지, PostgreSQL 카테고리 사이드바의 "운영" 하위 분류, console/psql 블록 하이라이팅을 확인하고 스크린샷을 남긴다.
- [ ] 사용자에게 검토를 요청한다. `draft: false`는 승인 뒤.
