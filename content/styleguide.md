---
title: "스타일 확인용 시트"
date: 2026-09-23
draft: true
build:
  list: never
summary: "본문 요소가 어떻게 보이는지 확인하는 페이지. draft라서 배포되지 않습니다."
description: "제목, 코드 출력, 표, 인용, 다이어그램"
---

> Every row version has xmin and xmax fields that determine its visibility to snapshots.
>
> 공식 문서의 설명을 옮겨 붙인 인용 예시입니다.

## 동작 원리

UPDATE는 기존 튜플을 제자리에서 고치지 않습니다. 새 버전의 튜플을 쓰고, 옛 튜플의 `xmax`에 자신의 트랜잭션 ID를 기록합니다. 그래서 **읽기와 쓰기가 서로를 막지 않습니다**. 대신 옛 튜플은 누군가 정리해 줄 때까지 페이지에 남습니다. [VACUUM](/posts/postgresql/05-vacuum/)이 그 일을 합니다.

### 튜플 헤더

- `t_xmin`: 이 튜플을 만든 트랜잭션
- `t_xmax`: 이 튜플을 지웠거나 잠근 트랜잭션
- `t_ctid`: 다음 버전을 가리키는 포인터

```sql
SELECT lp, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('accounts', 0))
WHERE lp <= 3; -- 첫 세 개의 line pointer만
```

```text
 lp | t_xmin | t_xmax | t_ctid
----+--------+--------+--------
  1 |    742 |    745 | (0,3)
  2 |    742 |      0 | (0,2)
  3 |    745 |      0 | (0,3)
(3 rows)
```

| 파라미터 | 기본값 | 의미 |
|---|---|---|
| `autovacuum_vacuum_scale_factor` | 0.2 | 테이블 크기 대비 dead tuple 비율 |
| `autovacuum_vacuum_threshold` | 50 | 최소 dead tuple 수 |
| `autovacuum_naptime` | 1min | launcher가 깨어나는 주기 |

```mermaid
flowchart LR
  A[UPDATE] --> B[새 튜플 쓰기] --> C[옛 튜플 xmax 기록] --> D[VACUUM이 정리]
```

## 운영에서는 이렇게 나타납니다

긴 트랜잭션 하나가 열려 있으면 그보다 뒤에 죽은 튜플을 VACUUM이 지우지 못합니다. `pg_stat_activity`에서 `xact_start`가 오래된 세션부터 확인합니다.

```bash
psql -c "SELECT pid, now() - xact_start AS age, state FROM pg_stat_activity ORDER BY age DESC LIMIT 5;"
```

## 정리

1. 새 버전을 쓰고 옛 버전은 남긴다.
2. 가시성은 스냅샷과 xmin/xmax로 판단한다.
3. 남은 옛 버전은 VACUUM이 정리한다.
