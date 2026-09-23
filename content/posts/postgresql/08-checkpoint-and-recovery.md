---
title: "PostgreSQL 인터널 8: 체크포인트와 장애 복구 과정"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "체크포인트", "복구"]
weight: 8
summary: "장애가 나도 데이터가 사라지지 않는 이유"
description: "체크포인트가 하는 일과 장애 후 복구가 진행되는 순서"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: 장애가 나도 데이터가 사라지지 않는 이유

## 동작 원리

- 체크포인트가 하는 일
- checkpoint_timeout과 max_wal_size
- 체크포인트 분산(checkpoint_completion_target)
- 장애 복구 과정: 마지막 체크포인트부터 WAL 재생
- PITR의 원리

## 직접 확인해 보기

- pg_controldata로 마지막 체크포인트 위치 확인
- 로그로 체크포인트 발생 원인(time/wal) 확인

## 운영에서는 이렇게 나타납니다

- 체크포인트가 너무 잦을 때의 성능 영향
- 복구 시간이 길어지는 경우

## 정리

## 참고 자료

