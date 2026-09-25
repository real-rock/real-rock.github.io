# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users
- 주니어~미들 DBA: 운영을 시작했고 PostgreSQL/MongoDB 내부 동작을 제대로 이해하고 싶은 사람.
- 백엔드 개발자: DB를 쓰지만 내부 구조는 잘 모르는 사람.
- 시니어 DBA/동료: 이미 아는 내용을 정리된 형태로 다시 찾아보는 사람.
- 작성자 본인: 공부하며 정리하는 학습 기록이기도 하다.

## Product Purpose
MongoDB·PostgreSQL DBA인 Jin이 데이터베이스에 관한 다양한 이야기를 기록하는 개인 블로그다. 지금 중심 콘텐츠는 PostgreSQL과 MongoDB 인터널 연재로, 내부 동작과 그 구조가 실제 운영에서 어떤 현상으로 나타나는지를 설명한다. 연재는 독자가 처음부터 순서대로 읽으며 개념을 쌓아 올릴 수 있으면 성공이다.

## Positioning
DB 연재는 운영 현장 관점. 내부 구조 설명을 실제 장애·성능 현상(bloat, wraparound, 복제 지연, plan cache 등)과 연결한다. 모든 글이 "운영에서는 이렇게 나타납니다" 섹션을 가진다.

## Operating Context
- 한국어 글, 기술 용어는 영어 원문 유지.
- 세 연재: PostgreSQL 인터널(10편, PostgreSQL 18 기준, REL_18_STABLE 소스), MongoDB 인터널(8편, MongoDB 8.0 기준), PostgreSQL 운영(12편, 장애/증상별, PostgreSQL 18 PGDG RPM + Rocky Linux 9 컨테이너 실측). 인터널 연재는 뒤의 개념이 앞의 개념 위에 쌓이는 순서.
- 운영 연재 글 템플릿: 개요 → 먼저 확인할 것 → 원인별 진단 → 조치 → 재발 방지 → 정리 → 참고 자료. 실습 파일은 labs/pg-ops/(비공개)에 두고 본문 출력은 그 캡처에서만 가져온다.
- 글 템플릿: 개요 → 동작 원리 → 직접 확인해 보기 → 운영에서는 이렇게 나타납니다 → 정리 → 참고 자료.
- 본문에는 긴 코드/쿼리 출력(psql, explain, 로그), Mermaid 다이어그램, 표, 긴 설명 글이 모두 들어간다.

## Capabilities and Constraints
- Hugo(0.166 extended) + PaperMod 테마, GitHub Pages 배포(GitHub Actions). 테마는 submodule이며 수정하지 않고 프로젝트 layouts/assets로 덮어쓴다.
- 시리즈 공개 목차는 content/series/<시리즈>/_index.md의 `chapters`로 관리하고, 미공개 글은 "준비 중"으로 표시한다.
- 라이트/다크 테마 전환, 검색(Fuse.js), 태그, RSS 지원.

## Brand Commitments
- 블로그 이름: "Jin's 블로그". 작성자 표기: Jin.

## Evidence on Hand
- 연재 계획과 글 골격 18편(모두 draft). 실제 본문, 다이어그램, 벤치마크는 아직 없다. 존재하지 않는 수치나 사례를 만들어 넣지 않는다.

## Product Principles
- 읽기가 우선이다. 긴 글과 긴 코드 출력을 오래 읽어도 피로하지 않아야 한다.
- 순서가 곧 구조다. 독자가 지금 연재의 어디에 있는지 항상 알 수 있어야 한다.
- 운영 현장과의 연결이 차별점이다. 그 연결을 드러내는 요소가 가장 눈에 띄어야 한다.
- 기록물로서 정직하게. 미완성·준비 중 상태를 숨기지 않는다.
