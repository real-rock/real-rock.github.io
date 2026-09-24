---
title: "PostgreSQL 인터널 1: 프로세스 구조"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "프로세스", "아키텍처"]
weight: 1
summary: "postmaster와 backend, 백그라운드 프로세스가 각각 무슨 일을 하는지"
description: "postmaster, backend, 백그라운드 프로세스들의 역할"
---


## 개요

- 이 글에서 다룰 질문: postmaster와 backend, 백그라운드 프로세스가 각각 무슨 일을 하는지

## 동작 원리

- postmaster의 역할과 fork 기반 연결 처리
- backend 프로세스: 연결 하나당 프로세스 하나
- 백그라운드 프로세스: checkpointer, background writer, walwriter, autovacuum launcher/worker, archiver, WAL sender/receiver
- 공유 메모리와 프로세스 간 통신

## 직접 확인해 보기

- ps로 프로세스 목록 확인
- pg_stat_activity의 backend_type으로 역할 확인

## 운영에서는 이렇게 나타납니다

- 커넥션이 많을 때 메모리와 컨텍스트 스위칭 비용이 커지는 이유
- 커넥션 풀러(PgBouncer 등)가 필요한 이유
- backend 하나가 비정상 종료되면 전체가 재시작되는 이유

## 정리

## 참고 자료

