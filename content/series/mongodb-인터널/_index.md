---
title: "MongoDB 인터널"
description: "MongoDB와 WiredTiger가 내부에서 어떻게 동작하는지, 스토리지 엔진부터 샤딩과 일관성 보장까지 살펴봅니다."
key: "mongo"       # 색상 테마 키 (assets/css/extended/custom.css의 .s-mongo)
mark: "MDB"        # 카드에 표시되는 짧은 표식
version: "MongoDB 8.0"
order: 2
# 공개 목차. n번째 항목은 같은 시리즈에서 weight가 n인 글과 연결됩니다.
# 글이 공개되기 전에는 '준비 중'으로 표시됩니다.
chapters:
  - title: "WiredTiger 스토리지 엔진 구조와 캐시"
    description: "WiredTiger의 파일 구조, B-tree, 캐시와 eviction"
  - title: "체크포인트와 저널"
    description: "체크포인트 주기, 저널 기록과 장애 복구"
  - title: "WiredTiger의 MVCC와 스냅샷"
    description: "update chain, 타임스탬프, 스냅샷 격리"
  - title: "인덱스 구조와 쿼리 플래너의 계획 선택 방식"
    description: "인덱스 구조, 후보 계획 경쟁, plan cache"
  - title: "oplog와 레플리카셋 복제"
    description: "oplog 구조, secondary 복제 흐름, 복제 지연"
  - title: "Primary 선출 과정"
    description: "Raft 기반 선출, 투표 조건, priority와 failover"
  - title: "샤딩 구조"
    description: "mongos, config server, chunk와 balancer"
  - title: "Read/Write Concern이 실제로 보장하는 것"
    description: "write concern, read concern, 읽기 일관성의 범위"
---

스토리지 엔진에서 시작해 복제, 샤딩, 일관성 보장 순서로 올라갑니다. 앞 글에서 다룬 WiredTiger의 동작이 뒤 글의 전제가 됩니다.
