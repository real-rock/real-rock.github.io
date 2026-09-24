---
title: "PostgreSQL 인터널 3: 데이터 저장 구조"
date: 2026-09-23
draft: true
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "스토리지", "페이지", "TOAST"]
weight: 3
summary: "테이블은 디스크에 어떤 모양으로 저장되는가"
description: "페이지 레이아웃, 튜플 구조, TOAST"
---


## 개요

- 이 글에서 다룰 질문: 테이블은 디스크에 어떤 모양으로 저장되는가

## 동작 원리

- 데이터 디렉터리와 relfilenode
- 8KB 페이지 구조: 페이지 헤더, line pointer, 튜플
- 힙 튜플 헤더: xmin, xmax, ctid, infomask
- TOAST: 큰 값을 따로 저장하는 방식
- FSM과 VM 파일

## 직접 확인해 보기

- pg_relation_filepath로 실제 파일 위치 확인
- pageinspect로 페이지 헤더와 튜플 읽기

## 운영에서는 이렇게 나타납니다

- 컬럼 순서와 정렬(alignment)에 따른 저장 공간 차이
- TOAST 컬럼 조회가 느려지는 경우

## 정리

## 참고 자료

