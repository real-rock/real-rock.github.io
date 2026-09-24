---
title: "PostgreSQL 인터널 2: 메모리 구조"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "메모리", "shared_buffers"]
weight: 2
summary: "shared buffers, work_mem, WAL buffers는 어디에 어떻게 쓰이는가"
description: "shared buffers, work_mem, WAL buffers"
---


## 개요

- 이 글에서 다룰 질문: shared buffers, work_mem, WAL buffers는 어디에 어떻게 쓰이는가

## 동작 원리

- 공유 메모리: shared buffers, WAL buffers, 락 테이블 등
- 로컬 메모리: work_mem, maintenance_work_mem, temp_buffers
- 버퍼 교체 알고리즘: clock sweep과 usage count
- 운영체제 페이지 캐시와의 이중 캐싱

## 직접 확인해 보기

- pg_buffercache로 버퍼에 올라간 테이블 확인
- EXPLAIN (ANALYZE, BUFFERS)로 hit과 read 비교
- work_mem 부족 시 임시 파일 생성 확인

## 운영에서는 이렇게 나타납니다

- shared_buffers를 무작정 키우면 안 되는 이유
- work_mem이 쿼리 노드 단위로 잡혀 메모리가 폭증하는 경우
- 정렬이 디스크로 넘어갈 때의 성능 저하

## 정리

## 참고 자료

