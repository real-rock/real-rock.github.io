---
title: "MongoDB 인터널 1: WiredTiger 스토리지 엔진 구조"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "WiredTiger", "캐시"]
weight: 1
summary: "MongoDB의 데이터는 실제로 어디에 어떻게 저장되는가"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: MongoDB의 데이터는 실제로 어디에 어떻게 저장되는가

## 동작 원리

- MongoDB와 WiredTiger의 관계
- 컬렉션과 인덱스가 각각 파일로 저장되는 구조
- WiredTiger의 B-tree 구조
- WiredTiger 캐시와 운영체제 페이지 캐시
- eviction: 캐시에서 페이지를 내보내는 방식

## 직접 확인해 보기

- db.collection.stats()로 스토리지 정보 확인
- serverStatus의 wiredTiger.cache 지표 읽기

## 운영에서는 이렇게 나타납니다

- 캐시가 가득 차서 애플리케이션 스레드가 eviction에 참여할 때
- cacheSizeGB 설정 기준

## 정리

## 참고 자료

