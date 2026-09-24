---
title: "PostgreSQL 인터널"
description: "PostgreSQL이 내부에서 어떻게 동작하는지, 프로세스 구조부터 복제와 쿼리 처리까지 순서대로 살펴봅니다."
version: "PostgreSQL 17"   # 시리즈 페이지에 "PostgreSQL 17 기준"으로 표시
order: 1                   # 홈과 시리즈 목록에서의 순서
# 공개 목차. n번째 항목은 같은 시리즈에서 weight가 n인 글과 연결됩니다.
# 글이 공개되기 전에는 '준비 중'으로 표시됩니다.
chapters:
  - title: "프로세스 구조"
    description: "postmaster, backend, 백그라운드 프로세스들의 역할"
  - title: "메모리 구조"
    description: "shared buffers, work_mem, WAL buffers"
  - title: "데이터 저장 구조"
    description: "페이지 레이아웃, 튜플 구조, TOAST"
  - title: "MVCC"
    description: "xmin/xmax, 스냅샷, 튜플 가시성 판단"
  - title: "VACUUM과 Autovacuum"
    description: "dead tuple, FSM, Visibility Map"
  - title: "트랜잭션 ID wraparound"
    description: "왜 생기고 어떻게 막는가"
  - title: "WAL"
    description: "LSN, full page writes, WAL 레코드 구조"
  - title: "체크포인트와 장애 복구 과정"
    description: "체크포인트가 하는 일과 장애 후 복구가 진행되는 순서"
  - title: "스트리밍 복제와 Replication Slot"
    description: "WAL 전송, standby 재생, replication slot"
  - title: "쿼리 처리 과정"
    description: "파서, 플래너, 실행기와 통계 정보"
---

뒤의 개념이 앞의 개념 위에 쌓이도록 순서를 잡았습니다. 처음 읽는다면 1편부터 차례대로 읽는 것을 권합니다.
