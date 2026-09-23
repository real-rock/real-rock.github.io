---
title: "MongoDB 인터널 8: Read/Write Concern이 실제로 보장하는 것"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "write concern", "read concern", "일관성"]
weight: 8
summary: "MongoDB는 무엇을 언제까지 보장하는가"
description: "write concern, read concern, 읽기 일관성의 범위"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: MongoDB는 무엇을 언제까지 보장하는가

## 동작 원리

- write concern: w, j, wtimeout
- read concern: local, available, majority, linearizable, snapshot
- read preference와 secondary 읽기
- majority commit point

## 직접 확인해 보기

- w:1과 w:majority의 지연 차이 측정
- 장애 상황에서 w:1 쓰기가 rollback되는 과정 재현

## 운영에서는 이렇게 나타납니다

- 기본값을 그대로 쓸 때 생길 수 있는 데이터 유실
- secondary 읽기에서 오래된 데이터가 보이는 경우
- PostgreSQL 동기 복제 설정과 비교하기

## 정리

## 참고 자료

