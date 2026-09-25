---
title: "MongoDB 인터널 5: oplog와 레플리카셋 복제"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
categories: ["MongoDB"]
subcategory: "인터널"
tags: ["MongoDB", "oplog", "복제", "레플리카셋"]
weight: 5
summary: "secondary는 primary의 변경을 어떻게 따라가는가"
description: "oplog 구조, secondary 복제 흐름, 복제 지연"
---


## 개요

- 이 글에서 다룰 질문: secondary는 primary의 변경을 어떻게 따라가는가

## 동작 원리

- oplog 컬렉션의 구조와 멱등성
- secondary의 oplog fetch와 적용 과정
- oplog 크기와 복제 가능 시간 창
- 초기 동기화(initial sync)

## 직접 확인해 보기

- rs.printReplicationInfo()와 rs.printSecondaryReplicationInfo()
- local.oplog.rs 조회

## 운영에서는 이렇게 나타납니다

- oplog 시간 창이 짧아 재동기화가 필요한 경우
- 복제 지연의 원인
- PostgreSQL 스트리밍 복제와의 차이

## 정리

## 참고 자료

