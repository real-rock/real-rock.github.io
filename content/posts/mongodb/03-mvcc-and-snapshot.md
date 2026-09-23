---
title: "MongoDB 인터널 3: WiredTiger의 MVCC와 스냅샷"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "MVCC", "스냅샷", "트랜잭션"]
weight: 3
summary: "동시에 읽고 쓸 때 MongoDB 내부에서 일어나는 일"
description: "update chain, 타임스탬프, 스냅샷 격리"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: 동시에 읽고 쓸 때 MongoDB 내부에서 일어나는 일

## 동작 원리

- WiredTiger의 update chain
- 스냅샷 격리와 타임스탬프
- history store: 오래된 버전은 어디로 가는가
- 멀티 도큐먼트 트랜잭션의 제약

## 직접 확인해 보기

- 긴 트랜잭션 동안 캐시 사용량 변화 관찰

## 운영에서는 이렇게 나타납니다

- 긴 트랜잭션이나 커서가 캐시 압박을 일으키는 이유
- transactionLifetimeLimitSeconds의 의미
- PostgreSQL MVCC와의 차이

## 정리

## 참고 자료

