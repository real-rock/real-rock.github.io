---
title: "PostgreSQL 인터널 10: 쿼리 처리 과정"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "쿼리", "플래너", "통계"]
weight: 10
summary: "SQL 한 줄이 결과가 되기까지"
description: "파서, 플래너, 실행기와 통계 정보"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: SQL 한 줄이 결과가 되기까지

## 동작 원리

- 파서, 분석기, 리라이터, 플래너, 실행기
- 비용 모델: seq_page_cost, random_page_cost
- 통계 정보: pg_statistic과 히스토그램, MCV
- 조인 방식: Nested Loop, Hash Join, Merge Join
- 실행기의 노드 구조

## 직접 확인해 보기

- EXPLAIN과 EXPLAIN ANALYZE 비교
- pg_stats로 컬럼 통계 확인

## 운영에서는 이렇게 나타납니다

- 통계가 오래되어 실행 계획이 바뀌는 경우
- 인덱스가 있는데 사용되지 않는 이유
- 추정 행 수와 실제 행 수가 크게 다를 때

## 정리

## 참고 자료

