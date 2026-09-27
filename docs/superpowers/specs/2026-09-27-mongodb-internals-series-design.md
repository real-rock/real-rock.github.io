# MongoDB 인터널 연재 설계

- 작성일: 2026-09-27
- 상태: 승인됨 (2026-09-27)

## 목적

기존 draft 뼈대 8편(`content/posts/mongodb/`)을 PostgreSQL 인터널 연재와 같은 방식으로 채운다. 내부 동작을 소스로 설명하고, 모든 출력은 Rocky Linux 9 도커 컨테이너에서 직접 실행한 결과만 쓴다. 독자는 PRODUCT.md의 독자와 같다.

## 확정된 결정

| 항목 | 결정 |
|---|---|
| 기준 버전 | MongoDB 8.0.32 (8.0 LTS). 시리즈 페이지의 "MongoDB 8.0 기준"을 그대로 둔다 |
| 설치 | MongoDB 공식 RPM(`repo.mongodb.org`, RHEL 9 aarch64) `mongodb-org-8.0.32` + `mongodb-mongosh` 2.12.0 |
| 소스 링크 | mongo `r8.0.32` 태그 커밋 `8f1f561d203201f9f19e832374813f46cfe0dc29`에 고정. WiredTiger도 mongo 저장소의 `src/third_party/wiredtiger` 경로로 링크한다 |
| 소스 읽기 | `~/workspace/source/mongo`는 `r8.3.11`에 체크아웃되어 있으므로 작업 트리를 읽지 말고 `git show r8.0.32:<경로>`, `git grep <패턴> r8.0.32`로 읽는다. 체크아웃은 바꾸지 않는다 |
| 진행 | 8편을 한 번에 작성하고 사용자가 일괄 검토한다. 모두 `draft: true`로 두고 공개는 검토 뒤에 결정한다 |

## 목차

기존 뼈대와 시리즈 `_index.md`의 `chapters`를 그대로 쓴다. 제목을 바꾸면 `_index.md`도 같이 고친다.

| 편 | 제목 | 핵심 실측 |
|---|---|---|
| 1 | WiredTiger 스토리지 엔진 구조와 캐시 | dbPath 파일 구성(`collection-*.wt`, `index-*.wt`, `_mdb_catalog.wt`, `WiredTiger.turtle`, `sizeStorer.wt`), `wt`로 본 B-tree와 메타데이터, 압축 방식별 파일 크기, 작은 `cacheSizeGB`에서 eviction 지표 |
| 2 | 체크포인트와 저널 | 60초 체크포인트 관측, `journal/WiredTigerLog.*`, `j:true`와 `j:false`의 차이, `kill -9` 뒤 재기동 복구 로그 |
| 3 | WiredTiger의 MVCC와 스냅샷 | 두 세션의 스냅샷 격리, WriteConflict, 오래 열린 스냅샷이 history store(`WiredTigerHS.wt`)를 키우는 모습, 60초 트랜잭션 제한 |
| 4 | 인덱스 구조와 쿼리 플래너의 계획 선택 방식 | explain `executionStats`, 후보 계획 경쟁(trial), `$planCacheStats`, replan, ESR과 커버링 쿼리 |
| 5 | oplog와 레플리카셋 복제 | 3노드 레플리카셋, oplog 엔트리(연산자 update가 멱등한 형태로 바뀌는 것), 복제 지연을 만들고 관측, oplog window |
| 6 | Primary 선출 과정 | `rs.stepDown()`, primary 강제 종료, term과 `electionCandidateMetrics`, priority, 네트워크 분할(`docker network disconnect`) |
| 7 | 샤딩 구조 | config server RS + 샤드 2개 + mongos, chunk와 balancer 이동, targeted 쿼리와 scatter-gather explain |
| 8 | Read/Write Concern이 실제로 보장하는 것 | `w:1` 쓰기가 롤백되는 재현(rollback 파일), `w:"majority"`, readConcern `local`과 `majority`의 차이, causal consistency |

## 실측 환경 (`labs/mongo-internals/`, Hugo 빌드 대상 아님)

- `Dockerfile`: `rockylinux:9` + MongoDB RPM 8.0.32 + mongosh + 진단 도구(procps-ng, iproute, lsof, strace, jq). `wt` 유틸리티를 r8.0.32의 WiredTiger 소스로 빌드해 넣는다(snappy, zstd, zlib extension 포함, `wt` 래퍼가 늘 싣는다). 이미지 이름 `mongo-internals:rocky9-8.0.32`.
- `make-wt-src.sh`: `wt` 빌드용 소스 tarball을 네트워크 없이 만든다. mongo 저장소 안의 WiredTiger 사본은 CMake 파일이 빠져 있어서, 빠진 파일만 WiredTiger 저장소 `mongodb-8.0` 브랜치에서 채운다. 소스 코드는 r8.0.32 그대로다.
- `lib/labkit.sh`: 공용 하네스. 셸 명령은 `$ 명령` + 출력 + `[exit=N]`, mongosh 명령은 `프롬프트> 명령` + mongosh가 보여 주는 결과로 기록한다. 동시 세션(`sess_*`), 레플리카셋(`fresh_replset`, `wait_primary`), 컨테이너 정리(`lab_clean`) 포함.
- `lib/replfmt.py`: mongosh 프롬프트를 마커로 바꿔 실행한 출력을 명령과 결과로 다시 짝짓는다.
- `lib/verify-post.py`: 글의 `console`/`mongosh`/`text` 블록 출력 줄이 모두 로그에 있는지 확인한다.
- `mongo-NN-<slug>/lab.sh` → `final-run.log`. 편마다 `LAB=mNN` 접두어를 써서 컨테이너와 네트워크가 겹치지 않는다. 로그는 항상 한 번의 전체 실행 결과여야 한다.

## 글 틀

PostgreSQL 인터널 연재와 같다: 개요(답할 질문 목록) → 기준 버전 인용 블록 → 동작 원리와 실측을 번갈아 → 운영에서는 이렇게 나타납니다 → 정리 → 참고 자료. 실습을 별도 섹션으로 모으지 않고 설명 옆에 둔다. Docker 명령과 실습 번호는 본문에 넣지 않는다.

- 기준 버전 블록: `> **기준 버전**: MongoDB 8.0.32. 소스 링크는 모두 r8.0.32 태그(커밋 8f1f561)에 고정했고, 실습 출력은 공식 RPM을 Rocky Linux 9.8 컨테이너에 설치해 실행한 결과입니다.`
- 코드 블록: 셸은 ` ```console `, mongosh는 새로 추가한 ` ```mongosh `(프롬프트 `test> `, `rs0 [direct: primary] test> ` 등, 여러 줄 명령의 이어지는 줄은 `... `).
- 다이어그램: 편마다 1~2개, archify로 `diagrams-src/mongo-*.json` → `static/diagrams/mongo-*.html`, `{{< diagram >}}` shortcode.
- 태그: 주제 키워드 + 실측 출력에 실제로 나온 에러 문구의 핵심 구절(있을 때만).

## 사이트 변경

- `layouts/_markup/render-codeblock-mongosh.html` 추가, 복사 버튼 스크립트(`extend_footer.html`)가 mongosh 블록도 명령만 복사하도록.
- PRODUCT.md의 연재 설명에 기준 버전(8.0.32, Rocky Linux 9 실측)을 적는다.

## 검증

- 편마다 `verify-post.py`가 0줄을 보고해야 한다.
- `hugo --buildDrafts`로 렌더링 확인.
- 수치나 동작을 문서·기억으로 쓰지 않는다. 실측이 안 되는 내용(예: systemd, 실제 디스크 장애)은 소스나 공식 문서를 근거로 쓰고 그렇다고 밝힌다.
