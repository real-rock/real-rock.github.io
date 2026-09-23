---
title: "MongoDB 인터널 2: 체크포인트와 저널"
date: 2026-09-23
draft: true
series: ["MongoDB 인터널"]
tags: ["MongoDB", "체크포인트", "저널"]
weight: 2
summary: "MongoDB는 장애 후 어떻게 데이터를 복구하는가"
---

> 이 글은 MongoDB 8.0 기준으로 작성했습니다.

## 개요

- 이 글에서 다룰 질문: MongoDB는 장애 후 어떻게 데이터를 복구하는가

## 동작 원리

- WiredTiger 체크포인트 주기와 동작
- 저널(write-ahead log)의 역할
- write concern의 j 옵션과 저널
- 장애 복구 과정: 체크포인트와 저널 재생

## 직접 확인해 보기

- serverStatus에서 체크포인트 관련 지표 확인
- 저널 파일 위치와 크기 확인

## 운영에서는 이렇게 나타납니다

- 체크포인트 시점의 I/O 급증
- PostgreSQL의 WAL과 체크포인트와 비교하기

## 정리

## 참고 자료

