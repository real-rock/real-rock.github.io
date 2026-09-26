---
title: "Patroni HA"
description: "Patroni로 PostgreSQL 고가용성(HA)을 구성합니다. 동작 원리, 3노드 클러스터 구성, 운영할 때 주의할 점을 실측으로 확인합니다."
version: "Patroni 4.1, PostgreSQL 18"   # 시리즈 페이지에 "... 기준"으로 표시
order: 4                   # 홈과 시리즈 목록에서의 순서
# 공개 목차. n번째 항목은 같은 시리즈에서 weight가 n인 글과 연결됩니다.
chapters:
  - title: "Patroni의 구조와 동작 원리"
    description: "DCS와 leader key, HA loop, failover 판단"
  - title: "3노드 클러스터 구성하기"
    description: "etcd, patroni.yml, HAProxy, switchover와 failover"
  - title: "운영할 때 주의할 점"
    description: "설정 변경, DCS 장애, 데이터 유실, split-brain, slot"
---

[PostgreSQL 인터널 9편](/posts/postgresql/09-streaming-replication/)의 스트리밍 복제를 알고 있다고 가정합니다. 모든 실습은 Rocky Linux 9 컨테이너 7대(etcd 3대, PostgreSQL과 Patroni 3대, HAProxy 1대)에서 실행한 결과입니다.
