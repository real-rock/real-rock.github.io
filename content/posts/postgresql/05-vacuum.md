---
title: "PostgreSQL 인터널 5: VACUUM과 Autovacuum"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "VACUUM", "Autovacuum", "bloat"]
weight: 5
summary: "dead tuple은 언제, 어떻게 정리되는가"
description: "dead tuple, FSM, Visibility Map"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: dead tuple은 언제, 어떻게 정리되는가

## 동작 원리

- VACUUM의 단계: 힙 스캔, 인덱스 정리, 힙 정리
- Visibility Map과 index-only scan의 관계
- VACUUM과 VACUUM FULL의 차이
- Autovacuum 실행 조건: threshold와 scale factor
- cost 기반 지연(throttling)

## 직접 확인해 보기

- pg_stat_user_tables의 n_dead_tup과 마지막 vacuum 시각 확인
- pg_stat_progress_vacuum으로 진행 상황 보기

## 운영에서는 이렇게 나타납니다

- 큰 테이블에서 기본 scale factor가 맞지 않는 이유
- 테이블 bloat 진단과 해결 방법
- Autovacuum이 끝나지 않는 경우

## 정리

## 참고 자료

