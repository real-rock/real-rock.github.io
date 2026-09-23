---
title: "PostgreSQL 인터널 7: WAL"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "WAL", "LSN"]
weight: 7
summary: "모든 변경은 왜 먼저 로그에 쓰이는가"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: 모든 변경은 왜 먼저 로그에 쓰이는가

## 동작 원리

- Write-Ahead Logging의 원칙
- WAL 세그먼트 파일과 LSN
- WAL 레코드 구조
- full page writes가 필요한 이유
- synchronous_commit 설정별 동작 차이

## 직접 확인해 보기

- pg_current_wal_lsn으로 LSN 확인
- pg_waldump로 WAL 레코드 읽기

## 운영에서는 이렇게 나타납니다

- 체크포인트 직후 WAL 발생량이 급증하는 이유
- WAL 디렉터리가 가득 차는 원인
- WAL 아카이빙이 밀릴 때 생기는 일

## 정리

## 참고 자료

