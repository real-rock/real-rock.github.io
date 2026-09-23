---
title: "MongoDB 인터널 4: 인덱스 구조와 쿼리 플래너의 계획 선택 방식"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "인덱스", "쿼리 플래너", "explain"]
weight: 4
summary: "MongoDB는 여러 실행 계획 중 하나를 어떻게 고르는가"
description: "인덱스 구조, 후보 계획 경쟁, plan cache"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: MongoDB는 여러 실행 계획 중 하나를 어떻게 고르는가

## 동작 원리

- 인덱스 구조와 복합 인덱스의 키 순서
- ESR 규칙(Equality, Sort, Range)
- 쿼리 플래너의 후보 계획 경쟁 방식
- plan cache와 재계획

## 직접 확인해 보기

- explain('executionStats') 결과 읽기
- totalKeysExamined와 totalDocsExamined 비교

## 운영에서는 이렇게 나타납니다

- plan cache 때문에 갑자기 느려지는 쿼리
- 인메모리 정렬 한도에 걸리는 경우
- 사용하지 않는 인덱스 찾기

## 정리

## 참고 자료

