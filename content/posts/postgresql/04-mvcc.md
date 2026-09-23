---
title: "PostgreSQL 인터널 4: MVCC"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "MVCC", "트랜잭션", "격리 수준"]
weight: 4
summary: "PostgreSQL은 어떻게 읽기와 쓰기를 서로 막지 않는가"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: PostgreSQL은 어떻게 읽기와 쓰기를 서로 막지 않는가

## 동작 원리

- UPDATE는 새 튜플을 쓰고 옛 튜플을 남긴다
- xmin/xmax와 트랜잭션 상태(CLOG)
- 스냅샷의 구성: xmin, xmax, xip 목록
- 튜플 가시성 판단 규칙
- 격리 수준별 스냅샷을 잡는 시점 차이

## 직접 확인해 보기

- 두 세션에서 UPDATE 후 pageinspect로 옛 튜플과 새 튜플 비교
- txid_current_snapshot으로 스냅샷 확인

## 운영에서는 이렇게 나타납니다

- 긴 트랜잭션 하나가 dead tuple 정리를 막는 이유
- idle in transaction이 위험한 이유
- HOT 업데이트와 인덱스 비대화

## 정리

## 참고 자료

