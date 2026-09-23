---
title: "MongoDB 인터널 6: Primary 선출 과정"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "선출", "레플리카셋", "고가용성"]
weight: 6
summary: "primary가 죽으면 누가, 어떻게 새 primary가 되는가"
description: "Raft 기반 선출, 투표 조건, priority와 failover"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: primary가 죽으면 누가, 어떻게 새 primary가 되는가

## 동작 원리

- heartbeat와 장애 감지
- Raft 기반 선출 프로토콜
- term과 투표 규칙
- priority와 votes 설정
- rollback: 복제되지 않은 쓰기의 운명

## 직접 확인해 보기

- rs.status()로 멤버 상태와 term 확인
- rs.stepDown()으로 선출 관찰

## 운영에서는 이렇게 나타납니다

- 선출 중 쓰기가 실패하는 시간
- retryable writes의 역할
- 짝수 멤버 구성과 arbiter 사용 시 주의점

## 정리

## 참고 자료

