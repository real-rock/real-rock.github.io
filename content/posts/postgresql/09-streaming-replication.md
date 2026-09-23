---
title: "PostgreSQL 인터널 9: 스트리밍 복제와 Replication Slot"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "복제", "replication slot", "standby"]
weight: 9
summary: "standby는 primary의 변경을 어떻게 따라가는가"
description: "WAL 전송, standby 재생, replication slot"
---

> 이 글은 PostgreSQL 17 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: standby는 primary의 변경을 어떻게 따라가는가

## 동작 원리

- WAL sender와 WAL receiver
- 물리 복제의 흐름: 전송, 기록, 재생
- 동기 복제와 비동기 복제
- replication slot이 WAL을 붙잡는 방식
- WAL 아카이브와 restore_command를 이용한 복구

## 직접 확인해 보기

- pg_stat_replication의 lag 컬럼 읽기
- pg_replication_slots로 slot 상태 확인

## 운영에서는 이렇게 나타납니다

- 방치된 slot이 디스크를 가득 채우는 경우
- standby 쿼리와 WAL 재생이 충돌하는 경우
- 복제 지연의 원인 구분: 전송, 기록, 재생

## 정리

## 참고 자료

