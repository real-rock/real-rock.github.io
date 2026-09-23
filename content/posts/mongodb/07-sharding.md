---
title: "MongoDB 인터널 7: 샤딩 구조"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "샤딩", "mongos", "balancer"]
weight: 7
summary: "MongoDB는 데이터를 여러 샤드에 어떻게 나누는가"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: MongoDB는 데이터를 여러 샤드에 어떻게 나누는가

## 동작 원리

- mongos, config server, shard의 역할
- shard key와 chunk(range)
- 범위 샤딩과 해시 샤딩
- balancer와 chunk 이동
- 쿼리 라우팅: 타깃 쿼리와 브로드캐스트 쿼리

## 직접 확인해 보기

- sh.status()로 chunk 분포 확인
- explain으로 쿼리가 몇 개 샤드에 가는지 확인

## 운영에서는 이렇게 나타납니다

- 잘못된 shard key가 만드는 hot shard
- jumbo chunk
- balancer 작업이 서비스에 주는 영향

## 정리

## 참고 자료

