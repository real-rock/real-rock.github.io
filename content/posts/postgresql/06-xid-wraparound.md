---
title: "PostgreSQL 인터널 6: 트랜잭션 ID wraparound"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "XID", "wraparound", "freeze"]
weight: 6
summary: "32비트 트랜잭션 ID가 한 바퀴 돌면 무슨 일이 생기는가"
description: "왜 생기고 어떻게 막는가"
---


## 개요

- 이 글에서 다룰 질문: 32비트 트랜잭션 ID가 한 바퀴 돌면 무슨 일이 생기는가

## 동작 원리

- 32비트 XID와 원형 비교
- freeze: 오래된 튜플을 모든 트랜잭션에게 보이게 만들기
- relfrozenxid와 datfrozenxid
- anti-wraparound autovacuum
- MultiXact ID도 같은 문제를 가진다

## 직접 확인해 보기

- age(datfrozenxid)로 데이터베이스별 XID 나이 확인
- 테이블별 age(relfrozenxid) 상위 목록 조회

## 운영에서는 이렇게 나타납니다

- 쓰기가 막히기 전 나타나는 경고 메시지
- freeze를 막는 원인: 긴 트랜잭션, 방치된 replication slot, prepared transaction
- 미리 대비하는 모니터링 기준

## 정리

## 참고 자료

