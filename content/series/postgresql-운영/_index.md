---
title: "PostgreSQL 운영"
description: "장애 증상이 보일 때 무엇을 어떤 순서로 확인하고 어떻게 조치하는지, 직접 재현한 결과로 살펴봅니다."
version: "PostgreSQL 18"   # 시리즈 페이지에 "PostgreSQL 18 기준"으로 표시
order: 3                   # 홈과 시리즈 목록에서의 순서
# 공개 목차. n번째 항목은 같은 시리즈에서 weight가 n인 글과 연결됩니다.
# 글이 공개되기 전에는 '준비 중'으로 표시됩니다.
chapters:
  - title: "진단 도구상자"
    description: "미리 켜 둘 로그 설정, pg_stat_activity와 wait event, pg_stat_statements, pg_stat_io"
  - title: "세션들이 멈춰 있다"
    description: "락 대기, DDL이 만드는 락 큐, deadlock, lock_timeout"
  - title: "쿼리가 갑자기 느려졌다"
    description: "plan 변경, 통계, generic plan, auto_explain"
  - title: "긴 트랜잭션과 idle in transaction"
    description: "xmin horizon이 멈추는 원인과 찾는 법"
  - title: "테이블과 인덱스가 계속 커진다"
    description: "bloat 측정, autovacuum 튜닝, REINDEX CONCURRENTLY"
  - title: "디스크가 찬다"
    description: "pg_wal 증가, temp file, 디스크가 가득 찼을 때의 동작"
  - title: "wraparound 경고가 떴다"
    description: "경고 단계와 쓰기 거부, 강제 VACUUM 대응"
  - title: "standby가 뒤처진다"
    description: "write/flush/replay lag, hot standby 충돌"
  - title: "접속이 안 된다"
    description: "too many clients, 예약 슬롯, 인증 실패"
  - title: "주기적으로 I/O가 튄다"
    description: "잦은 체크포인트, pg_stat_checkpointer, bgwriter"
  - title: "메모리가 모자란다"
    description: "work_mem, OOM으로 backend가 죽을 때의 크래시 재시작"
  - title: "데이터 손상이 의심된다"
    description: "checksum 오류, amcheck, 손상 범위 파악"
---

증상별로 한 편씩 구성했습니다. 1편 진단 도구상자에서 공통 도구를 먼저 다루고, 나머지 편은 장애가 났을 때 해당 편만 펼쳐 봐도 되도록 썼습니다. 원리는 [PostgreSQL 인터널](/series/postgresql-인터널/) 연재의 해당 편으로 연결합니다.
