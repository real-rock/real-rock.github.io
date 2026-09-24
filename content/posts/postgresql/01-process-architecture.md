---
title: "PostgreSQL 인터널 1: 프로세스 구조"
date: 2026-09-24
draft: false
series: ["PostgreSQL 인터널"]
tags: ["PostgreSQL", "프로세스", "아키텍처", "postmaster"]
weight: 1
summary: "postmaster와 backend, 백그라운드 프로세스가 각각 무슨 일을 하는지"
description: "postmaster, backend, 백그라운드 프로세스들의 역할"
---

## 개요

`pg_ctl start`로 PostgreSQL을 띄우면 프로그램 하나가 도는 것처럼 보입니다. 실제로는 **프로세스 여러 개가 역할을 나눠 맡은 작은 조직**이 뜹니다. 접속을 받는 프로세스, 쿼리를 처리하는 프로세스, 메모리에 쌓인 변경을 디스크로 내보내는 프로세스, 죽은 데이터를 청소하는 프로세스가 모두 따로 있습니다.

이 글은 다음 질문에 답합니다.

- 서버를 띄우면 어떤 프로세스들이 생기고, 각각 무슨 일을 하는가
- 클라이언트가 접속하면 내부에서 어떤 순서로 무슨 일이 일어나는가
- backend 하나가 죽었는데 왜 모든 접속이 끊기는가

DB 내부를 처음 보는 개발자도 따라올 수 있도록, 용어가 처음 나올 때마다 뜻을 풀어 쓰겠습니다.

> **기준 버전**: 이 연재는 PostgreSQL 18을 기준으로 합니다. 정확히는 `REL_18_STABLE` 브랜치의 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16)(18.6 개발 버전)입니다. 본문의 소스 링크는 모두 이 커밋에 고정했고, 실습 결과는 이 소스를 Docker 안에서 그대로 빌드해 실행한 출력입니다.

먼저 결론부터 정리하면 이렇습니다.

| 프로세스 | 한 줄 설명 |
|---|---|
| postmaster | 문지기. 접속을 받아 fork하고, 자식 프로세스를 감시합니다. 쿼리는 처리하지 않습니다. |
| client backend | 접속 하나를 전담하는 프로세스. 클라이언트 하나당 하나씩 생깁니다. |
| 백그라운드 프로세스 | 디스크 쓰기, 읽기(PG18), 청소, WAL 보관 같은 뒷일을 나눠 맡습니다. |

## 동작 원리

### 한눈에 보기

아래 그림은 PostgreSQL 18이 기본 설정으로 떠 있을 때의 프로세스와 그 사이의 관계입니다. 그림 위쪽의 버튼으로 "연결 처리", "디스크 쓰기 담당" 같은 관점별로 강조해서 볼 수 있고, `SRC` 표시가 있는 상자는 해당 소스 위치로 연결됩니다.

{{< diagram src="/diagrams/pg-process-architecture.html" title="PostgreSQL 18 프로세스 구조" height="620" caption="PostgreSQL 18 프로세스 구조. 실선은 데이터나 요청이 흐르는 방향, 점선은 비동기 요청입니다." >}}

그림을 읽는 요령은 세 가지입니다.

1. **왼쪽의 postmaster는 입구만 지킵니다.** 접속을 받으면 자신을 복제(fork)해 backend를 만들고, 그다음부터 클라이언트는 backend와 직접 이야기합니다.
2. **가운데의 공유 메모리가 모든 프로세스의 작업대입니다.** 테이블 데이터를 캐시하는 shared buffers, 변경 기록(WAL)을 잠시 모아 두는 WAL buffers, 누가 어떤 락을 잡았는지 같은 정보가 여기 있습니다.
3. **오른쪽의 백그라운드 프로세스들이 디스크를 상대합니다.** backend는 되도록 메모리에서 일을 끝내고, 느린 디스크 쓰기는 뒤에서 따로 처리합니다.

> **용어 정리**
> - **프로세스**: 운영체제가 따로 메모리 공간을 주고 실행하는 프로그램 단위입니다. `ps` 명령에 한 줄씩 보이는 것이 프로세스입니다.
> - **fork**: 실행 중인 프로세스가 자신을 그대로 복제해 자식 프로세스를 만드는 유닉스 시스템 콜입니다. 부모가 열어 둔 파일, 메모리 매핑 같은 것을 자식이 물려받습니다.
> - **WAL(Write-Ahead Log)**: 데이터 파일을 고치기 전에 "무엇을 바꿀지"를 먼저 적어 두는 로그입니다. 장애가 나면 이 로그를 다시 재생해서 복구합니다. [7편](/posts/postgresql/07-wal/)에서 자세히 다룹니다.

### postmaster: 문을 지키고 자식을 감시하는 프로세스

postmaster는 서버를 띄웠을 때 가장 먼저 실행되는 프로세스입니다. `ps`에서는 `/usr/local/pgsql/bin/postgres -D ...`처럼 실행 파일 이름 그대로 보이고, PID는 `$PGDATA/postmaster.pid` 파일의 첫 줄에 기록됩니다.

[`postmaster.c` 맨 위의 주석](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L1-L60)이 이 프로세스의 성격을 잘 설명합니다. 요약하면 다음과 같습니다.

- 접속 요청이 오면 backend를 fork합니다.
- 기동, 종료처럼 시스템 전체에 걸친 일을 관리합니다. 다만 그 일을 **직접 하지 않고, 알맞은 때에 자식 프로세스를 띄워 시킵니다.**
- 공유 메모리를 만들기는 하지만 **평소에는 건드리지 않습니다.** 락 관리에도 참여하지 않습니다.
- backend가 죽으면 공유 메모리를 초기화해서 시스템을 되살립니다.

세 번째 항목이 postmaster 설계의 핵심입니다. 공유 메모리는 여러 프로세스가 함께 쓰는 곳이라, 어떤 backend가 락을 잡은 채로 죽으면 망가진 상태로 남을 수 있습니다. postmaster가 그 메모리를 만지지 않으면 **자식이 어떻게 죽든 postmaster만은 멀쩡하게 남아서 뒷수습을 할 수 있습니다.** 실제로 postmaster는 공유 메모리의 프로세스 목록(PGPROC 배열)에 들어 있지 않고, 그래서 `pg_stat_activity`에도 나오지 않습니다. 실습 2에서 확인합니다.

postmaster의 본체는 [`ServerLoop()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L1652)라는 무한 루프입니다. 핵심만 남기면 이렇습니다.

```c
/* src/backend/postmaster/postmaster.c, ServerLoop() (일부 생략) */
for (;;)
{
    /* 소켓에 새 접속이 오거나, 시그널 핸들러가 latch를 세울 때까지 잠든다 */
    nevents = WaitEventSetWait(pm_wait_set, DetermineSleepTime(), events, ...);

    for (int i = 0; i < nevents; i++)
    {
        if (pending_pm_shutdown_request) process_pm_shutdown_request(); /* 종료 요청 */
        if (pending_pm_reload_request)   process_pm_reload_request();   /* 설정 reload */
        if (pending_pm_child_exit)       process_pm_child_exit();       /* 자식 종료 */
        if (pending_pm_pmsignal)         process_pm_pmsignal();         /* 자식의 요청 */

        if (events[i].events & WL_SOCKET_ACCEPT)
        {
            if (AcceptConnection(events[i].fd, &s) == STATUS_OK)
                BackendStartup(&s);                 /* 접속이 오면 fork */
            closesocket(s.sock);                    /* postmaster 쪽 소켓은 바로 닫는다 */
        }
    }

    LaunchMissingBackgroundProcesses();             /* 빠진 백그라운드 프로세스를 다시 띄운다 */
    ...
}
```

루프는 "기다린다 → 온 일을 처리한다 → 빠진 프로세스가 있으면 띄운다"를 반복합니다. 할 일이 없으면 잠들어 있으니 CPU를 거의 쓰지 않습니다.

postmaster에게 일을 시키는 방법은 유닉스 시그널입니다. 시그널 핸들러는 [`PostmasterMain()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L550-L558)에서 등록합니다.

| 시그널 | 보내는 쪽 | postmaster가 하는 일 |
|---|---|---|
| `SIGHUP` | `pg_ctl reload`, `pg_reload_conf()` | 설정 파일을 다시 읽고 자식들에게도 전달 |
| `SIGTERM` | `pg_ctl stop -m smart` | 새 접속을 막고, 기존 세션이 모두 끝나면 종료 |
| `SIGINT` | `pg_ctl stop -m fast` (기본값) | 진행 중인 트랜잭션을 취소시키고 종료 |
| `SIGQUIT` | `pg_ctl stop -m immediate` | 모든 자식을 즉시 끝내고 종료. 다음 기동 때 복구 과정을 거침 |
| `SIGCHLD` | 운영체제 | 자식 프로세스가 끝났다는 알림. 종료 코드를 보고 정상인지 판단 |
| `SIGUSR1` | 자식 프로세스 | "autovacuum worker를 띄워 달라" 같은 자식의 요청 |

### backend: 접속 하나에 프로세스 하나

클라이언트가 접속할 때마다 postmaster는 backend 프로세스를 하나씩 만듭니다. 접속이 100개면 backend도 100개입니다. 한 번 만들어진 backend는 **그 접속이 끝날 때까지 그 클라이언트만 상대합니다.** 요즘 많이 쓰는 "스레드 풀" 방식의 서버와 가장 다른 점입니다.

접속 하나가 처리되는 순서를 그림으로 보면 다음과 같습니다.

{{< diagram src="/diagrams/pg-connection-lifecycle.html" title="접속 하나가 처리되는 순서" height="560" caption="접속 하나가 처리되는 순서. postmaster는 fork까지만 하고, 인증부터는 backend가 맡습니다." >}}

순서대로 짚어 보겠습니다.

**1. accept와 fork.** 접속이 오면 postmaster는 [`BackendStartup()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L3531)에서 자식 슬롯을 하나 잡고 곧바로 fork합니다. fork는 [`postmaster_child_launch()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/launch_backend.c#L229)가 수행합니다. 눈여겨볼 점은 **인증보다 fork가 먼저**라는 것입니다. 소스 주석은 그 이유를 이렇게 설명합니다. 인증 코드를 단순한 단일 스레드 방식으로 짤 수 있고, 무엇보다 SSL이나 PAM처럼 느리게 막힐 수 있는 라이브러리가 postmaster를 붙잡아 다른 클라이언트까지 못 들어오게 하는 일을 막을 수 있습니다.

**2. 인증과 초기화.** 자식 프로세스는 [`BackendMain()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/backend_startup.c#L76)에서 시작합니다. 클라이언트가 보낸 첫 메시지(StartupMessage)에서 사용자와 DB 이름을 읽고, `pg_hba.conf` 규칙에 따라 인증합니다. 그다음 [`InitProcess()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/lmgr/proc.c#L390)로 공유 메모리에 자기 자리(PGPROC)를 얻습니다. 이 자리를 얻어야 락을 잡고 공유 메모리를 쓸 수 있습니다.

`max_connections` 제한이 실제로 걸리는 곳도 여기입니다. postmaster가 fork 전에 확인하는 자식 슬롯은 [`2 × (max_connections + max_wal_senders)`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/pmchild.c#L100)개로 넉넉하게 잡혀 있습니다. 인증 도중에 실패하거나 먼저 나가는 세션이 있기 때문입니다. 정확한 제한은 PGPROC 자리가 모자랄 때 [`sorry, too many clients already`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/lmgr/proc.c#L457)로 걸립니다. 그래서 **거절될 접속도 일단 fork는 됩니다.** 실습 6에서 확인합니다.

**3. 쿼리 처리.** 준비가 끝나면 backend는 [`PostgresMain()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L4188)의 [메인 루프](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L4520)에 들어갑니다. 클라이언트에 "준비됐다(ReadyForQuery)"를 보내고, 다음 명령을 기다리고, 받은 쿼리를 파싱, 계획, 실행하고, 결과를 돌려주는 일을 반복합니다. 쿼리 처리 과정은 [10편](/posts/postgresql/10-query-processing/)에서 다룹니다.

**4. 종료.** 클라이언트가 Terminate 메시지를 보내거나 연결이 끊기면 backend 프로세스가 끝납니다. 운영체제는 부모인 postmaster에게 `SIGCHLD`를 보내고, postmaster는 [`CleanupBackend()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L2565)에서 슬롯을 돌려받습니다.

**walsender도 시작은 backend입니다.** 복제용 접속(standby나 `pg_receivewal`)도 처음에는 평범한 backend로 fork됩니다. StartupMessage에 복제 요청이 들어 있으면 그 자리에서 [프로세스 타입이 `B_WAL_SENDER`로 바뀌고](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/backend_startup.c#L869-L872), 이후로는 쿼리 대신 WAL을 보내는 일을 합니다. 실습 8에서 로그로 확인합니다.

### 백그라운드 프로세스: 뒷일을 나눠 맡는 프로세스들

PostgreSQL 18이 만들 수 있는 프로세스 종류는 [`BackendType`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/miscadmin.h#L337-L375) 열거형에 모두 정의되어 있고, 각 타입의 시작 함수는 [`child_process_kinds[]`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/launch_backend.c#L179-L208) 표에 있습니다. 이 가운데 클라이언트 접속과 상관없이 뒤에서 도는 프로세스들을 정리하면 다음과 같습니다.

| 프로세스 (`ps` 표시) | 하는 일 | 언제 뜨나 |
|---|---|---|
| checkpointer | 주기적으로 메모리의 변경된 페이지(dirty page)를 모두 디스크에 쓰고 fsync합니다. 이 시점이 장애 복구의 출발점이 됩니다. | 항상 |
| background writer | dirty page를 조금씩 미리 써 두어, backend가 빈 버퍼를 찾을 때 직접 디스크에 쓰는 일을 줄입니다. | 항상 |
| walwriter | WAL buffers에 쌓인 WAL을 주기적으로 디스크에 씁니다. | 정상 운영 중(`PM_RUN`) |
| io worker | **PG18 신규.** backend 대신 실제 파일 읽기를 수행합니다. 아래에서 따로 설명합니다. | 항상, 기본 3개 |
| autovacuum launcher | 어느 DB를 청소할지 정하고 postmaster에 worker를 요청합니다. | `autovacuum = on`일 때 |
| autovacuum worker | 실제로 VACUUM과 ANALYZE를 수행합니다. | 필요할 때만 잠깐 |
| archiver | 다 쓴 WAL 파일을 `archive_command`로 다른 곳에 복사합니다. | `archive_mode = on`일 때 |
| startup | 기동할 때 WAL을 재생(redo)해 DB를 일관된 상태로 맞춥니다. standby에서는 계속 돕니다. | 기동과 복구 때 |
| logger | 모든 프로세스의 stderr 출력을 모아 로그 파일에 씁니다. | `logging_collector = on`일 때 |
| walsender | standby에 WAL을 보냅니다. 복제 접속마다 하나씩 생깁니다. | 복제 접속이 있을 때 |
| walreceiver | standby 쪽에서 primary의 WAL을 받습니다. | standby에서 |
| walsummarizer | 증분 백업용 WAL 요약을 만듭니다. | `summarize_wal = on`일 때 |
| slotsync worker | 논리 복제 슬롯을 standby로 동기화합니다. | standby에서 `sync_replication_slots = on`일 때 |
| logical replication launcher | 논리 복제 구독(subscription)의 worker를 관리합니다. background worker의 한 종류입니다. | 항상 |

이 조건들은 소스에 그대로 나와 있습니다. postmaster는 `ServerLoop`를 돌 때마다 [`LaunchMissingBackgroundProcesses()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L3280)를 불러 "지금 상태에서 있어야 하는데 없는 프로세스"를 띄웁니다. 예를 들어 checkpointer와 background writer는 기동 중에도 떠 있어야 하고, walwriter는 정상 운영(`PM_RUN`)일 때만 필요합니다. 복구 중에는 새 WAL을 쓸 일이 없기 때문입니다.

기동 순서도 소스에서 읽을 수 있습니다. [`PostmasterMain()`의 끝부분](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L1380-L1398)은 io worker, checkpointer, background writer, startup 순서로 프로세스를 띄웁니다. startup이 WAL 재생을 마치고 끝나면 그제야 walwriter, autovacuum launcher 등이 뜹니다. 실습 1에서 PID 번호로 이 순서를 확인합니다.

백그라운드 프로세스는 두 부류로 나뉩니다.

- **backend처럼 동작하는 프로세스**: autovacuum worker, walsender, background worker 등. 특정 DB에 붙어 트랜잭션을 실행할 수 있습니다.
- **보조 프로세스(auxiliary process)**: checkpointer, background writer, walwriter, io worker, startup, archiver 등. 공유 메모리에 자리(PGPROC)는 있지만 특정 DB에 붙지 않고, 트랜잭션을 실행하거나 일반 락을 잡을 수 없습니다([`miscadmin.h`의 주석](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/miscadmin.h#L352-L360)).

logger는 예외입니다. 공유 메모리에 붙지 않고 PGPROC도 없어서, postmaster처럼 `pg_stat_activity`에 보이지 않습니다(실습 10). 공유 메모리가 망가져도 로그만은 끝까지 남겨야 하기 때문입니다.

### PG18의 새 프로세스: io worker

PostgreSQL 18에는 비동기 I/O(AIO)가 들어왔고, 그 기본 구현이 `io_method = worker`입니다([`aio.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/storage/aio.h#L42)). 18 이전에는 backend가 테이블을 읽을 때 `read()` 시스템 콜을 직접 불렀습니다. 18에서는 다음처럼 바뀌었습니다([`method_worker.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/aio/method_worker.c#L1-L20)).

1. backend가 "이 블록들을 읽어 달라"는 요청을 공유 메모리의 제출 큐(submission queue)에 넣습니다.
2. io worker가 큐에서 요청을 꺼내 실제 읽기 시스템 콜을 수행하고, 완료 처리까지 합니다.
3. backend는 필요한 시점에만 결과를 기다립니다. 그 사이에 다른 일을 하거나 다음 읽기를 미리 요청할 수 있습니다.

요청이 몰리면 깨어난 worker가 다른 worker를 둘씩 더 깨웁니다(fan-out). worker 수는 `io_workers`(기본 3, 1-32)로 정하며, 서버를 재시작하지 않고 reload만으로 바꿀 수 있습니다. postmaster의 [`maybe_adjust_io_workers()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L4365)가 설정값에 맞춰 worker를 늘리거나 줄입니다(실습 4). 리눅스에서는 `io_method = io_uring`을 고를 수도 있는데, 그때는 io worker 대신 커널의 io_uring을 씁니다.

### 프로세스끼리 소통하는 방법

프로세스는 원래 서로의 메모리를 볼 수 없습니다. PostgreSQL 프로세스들이 협업하는 방법은 세 가지입니다.

**공유 메모리.** postmaster는 기동할 때 [`CreateSharedMemoryAndSemaphores()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L1003)로 큰 공유 메모리 영역을 만듭니다. 자식은 fork할 때 이 매핑을 그대로 물려받으므로, **모든 프로세스가 같은 가상 주소에서 같은 메모리를 봅니다**(실습 9). shared buffers, WAL buffers, 락 테이블, PGPROC 배열, PG18의 I/O 큐가 모두 여기에 있습니다. 크기는 `shared_memory_size`로 확인할 수 있습니다. 공유 메모리의 구성은 [2편](/posts/postgresql/02-memory-architecture/)에서 자세히 다룹니다.

**시그널과 latch.** "일이 생겼으니 깨어나라"는 알림은 시그널로 보냅니다. 받는 쪽은 latch라는 장치로 잠들어 있다가 깨어납니다. 앞에서 본 `ServerLoop`의 `WaitEventSetWait()`가 latch를 기다리는 부분입니다. 자식이 postmaster에게 부탁할 때도 같은 방식을 씁니다. 예를 들어 autovacuum launcher는 worker가 필요하면 [`SendPostmasterSignal(PMSIGNAL_START_AUTOVAC_WORKER)`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/autovacuum.c#L1271)로 요청만 보내고, fork는 postmaster가 [`StartAutovacuumWorker()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L4026)에서 합니다. 그래서 autovacuum worker의 부모 프로세스는 launcher가 아니라 postmaster입니다(실습 5).

**postmaster 생존 확인.** 자식들은 postmaster가 살아 있는지 계속 확인합니다. 리눅스에서는 [`prctl(PR_SET_PDEATHSIG)`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/ipc/pmsignal.c#L407-L420)로 "부모가 죽으면 나에게 시그널을 보내 달라"고 커널에 등록해 둡니다. postmaster가 사라지면 자식들도 스스로 종료합니다(실습 11). 감독이 없는 상태로 공유 메모리를 계속 만지면 위험하기 때문입니다.

### backend 하나가 죽으면 왜 모두 재시작하나

PostgreSQL을 운영하다 보면 "쿼리 하나가 죽었는데 모든 접속이 끊겼다"는 일을 겪게 됩니다. 이유는 postmaster의 판단 기준에 있습니다.

자식이 끝나면 postmaster는 [`CleanupBackend()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L2565)에서 종료 코드를 봅니다. **종료 코드가 0(정상)이나 1(FATAL 에러로 스스로 종료)이 아니면 크래시로 봅니다.** `kill -9`, 세그멘테이션 폴트, 리눅스 OOM killer에 의한 종료가 모두 여기에 해당합니다. 그 프로세스가 공유 메모리를 쓰던 중에 죽었는지 postmaster로서는 알 방법이 없습니다. 공유 메모리가 망가졌을 수 있다고 가정하고 모두 정리하는 것이 안전하다고 판단합니다.

{{< diagram src="/diagrams/pg-crash-restart.html" title="backend 하나가 죽었을 때 postmaster의 상태 변화" height="560" caption="크래시 후 postmaster의 상태(PMState) 변화. 위쪽 초록 화살표가 재시작 경로입니다." >}}

그림의 상태 이름은 소스의 [`PMState`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L336-L352) 값 그대로입니다. 순서는 다음과 같습니다.

1. **PM_RUN → PM_WAIT_BACKENDS**: [`HandleChildCrash()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L2785)가 "terminating any other active server processes"를 로그에 남기고, 살아 있는 모든 자식에게 `SIGQUIT`을 보냅니다. SIGQUIT을 받은 backend는 [`quickdie()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c#L2930)에서 클라이언트에게 경고를 보내고 곧바로 끝납니다.
2. **응답 없는 자식은 SIGKILL**: [5초](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L369) 안에 끝나지 않는 자식에게는 `SIGKILL`을 보냅니다.
3. **PM_NO_CHILDREN → PM_STARTUP**: 자식이 모두 사라지면 ["all server processes terminated; reinitializing"](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L3197-L3222)을 남기고 공유 메모리를 새로 만든 뒤 startup 프로세스를 띄웁니다. startup은 마지막 체크포인트부터 WAL을 재생합니다. 커밋된 데이터는 WAL에 남아 있으므로 잃지 않습니다.
4. **재시작하지 않는 경우**: `restart_after_crash = off`이거나 startup 프로세스 자체가 실패하면, postmaster도 재시작하지 않고 종료합니다. startup이 실패했다면 다시 해도 또 실패할 가능성이 크기 때문입니다.

반대로 `pg_terminate_backend()`로 끝낸 backend는 종료 코드 1로 스스로 끝나므로 이 과정을 거치지 않습니다. 실습 7에서 두 경우를 나란히 비교합니다.

## 직접 확인해 보기

### 실습 환경

글의 기준 버전과 정확히 같은 바이너리로 실습하려고, `REL_18_STABLE` 소스를 Docker 안에서 직접 빌드했습니다. 사용한 파일은 모두 공개해 두었습니다.

- [Dockerfile](/labs/pg-01-process/Dockerfile): Debian bookworm에서 소스를 빌드하는 이미지
- [lab.sh](/labs/pg-01-process/lab.sh): 아래 실습 전체를 새 컨테이너에서 처음부터 끝까지 실행하는 스크립트
- [final-run.log](/labs/pg-01-process/final-run.log): 이 글에 실린 출력의 원본 로그

먼저 postgres 소스 저장소에서 기준 커밋을 확인하고, 추적 중인 파일만 tar로 묶습니다. 소스가 없다면 `git clone --branch REL_18_STABLE https://github.com/postgres/postgres.git`으로 받은 뒤 같은 커밋을 체크아웃하면 됩니다.

```bash
git rev-parse --abbrev-ref HEAD
git log -1 --format='%H %s'
git archive --format=tar.gz -o postgres-src.tar.gz HEAD
```

```text
REL_18_STABLE
39a0db101105eab3f4044d11c609c58b9459ea16 Fix incorrect block accounting in TID Range Scans
```

`postgres-src.tar.gz`와 Dockerfile을 같은 디렉터리에 두고 이미지를 빌드합니다. 아래 출력은 빌드 로그에서 단계별 요약 줄만 추린 것입니다.

```bash
docker build -t pg-internals:rel18 . > build.log 2>&1; echo "exit=$?" >> build.log
```

```text
#4 [1/7] FROM docker.io/library/debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
#6 [2/7] RUN apt-get update && apt-get install -y --no-install-recommends       build-essential bison flex pkg-config       libreadline-dev zlib1g-dev libicu-dev       procps psmisc iproute2 less ca-certificates     && rm -rf /var/lib/apt/lists/*
#6 DONE 68.2s
#7 [3/7] ADD postgres-src.tar.gz /usr/src/postgres/
#7 DONE 1.7s
#9 [5/7] RUN ./configure --prefix=/usr/local/pgsql     && make -j"$(nproc)" world-bin     && make install-world-bin
#9 DONE 23.3s
#12 naming to docker.io/library/pg-internals:rel18 done
#12 DONE 9.2s
exit=0
```

컨테이너는 `--init`을 붙여 띄웁니다. 이유는 [뒤에서](#컨테이너에서는-pid-1이-좀비를-치워야-한다) 실제로 겪은 문제와 함께 설명합니다.

```bash
docker run -d --init --name pglab --hostname pglab pg-internals:rel18 sleep infinity
```

```text
c799db96799db48cf177ebe53dc240cc0320725a740350f138c7db6f4e682e71
[exit=0]
```

이후 명령은 `docker exec -it pglab bash`로 컨테이너에 들어가 postgres 사용자로 입력하면 같은 결과를 볼 수 있습니다. 이 글의 기록은 [lab.sh](/labs/pg-01-process/lab.sh)가 `docker exec -i pglab bash -s`로 같은 명령을 넘겨 실행한 것입니다.

실습 기록을 읽는 법은 이렇습니다.

- `bash` 블록은 실행한 명령입니다. `docker exec -d ...`로 시작하는 명령만 호스트에서 실행했고, 나머지는 모두 컨테이너 안에서 실행했습니다. `docker exec -d`는 psql 세션을 백그라운드에 열어 두는 데 썼습니다.
- `text` 블록은 그 명령의 stdout과 stderr를 합친 출력을 그대로 옮긴 것입니다. 마지막 줄의 `[exit=N]`은 실습 스크립트가 덧붙인 종료 코드입니다.
- PID와 시각은 실행할 때마다 달라집니다.

### 실습 0. 버전과 클러스터 초기화

```bash
postgres --version
initdb -D $PGDATA > /home/postgres/initdb.log 2>&1 && echo "initdb ok"
```

```text
postgres (PostgreSQL) 18.6
initdb ok
[exit=0]
```

### 실습 1. 서버를 띄우면 생기는 프로세스

서버를 시작하고, 아무도 접속하지 않은 상태에서 postmaster와 그 자식들을 봅니다. `ps -p $PM --ppid $PM`은 postmaster 자신과 postmaster를 부모로 둔 프로세스만 보여 줍니다.

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
```

```text
waiting for server to start.... done
server started
[exit=0]
```

```bash
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
```

```text
    PID    PPID CMD
     37       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
     38      37  \_ postgres: io worker 0
     39      37  \_ postgres: io worker 1
     40      37  \_ postgres: io worker 2
     41      37  \_ postgres: checkpointer 
     42      37  \_ postgres: background writer 
     44      37  \_ postgres: walwriter 
     45      37  \_ postgres: autovacuum launcher 
     46      37  \_ postgres: logical replication launcher 
[exit=0]
```

```bash
head -1 $PGDATA/postmaster.pid
cat /home/postgres/server.log
```

```text
37
2026-09-24 01:41:45.623 UTC [37] LOG:  starting PostgreSQL 18.6 on aarch64-unknown-linux-gnu, compiled by gcc (Debian 12.2.0-14+deb12u1) 12.2.0, 64-bit
2026-09-24 01:41:45.623 UTC [37] LOG:  listening on IPv6 address "::1", port 5432
2026-09-24 01:41:45.623 UTC [37] LOG:  listening on IPv4 address "127.0.0.1", port 5432
2026-09-24 01:41:45.624 UTC [37] LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
2026-09-24 01:41:45.625 UTC [43] LOG:  database system was shut down at 2026-09-24 01:41:45 UTC
2026-09-24 01:41:45.626 UTC [37] LOG:  database system is ready to accept connections
[exit=0]
```

확인할 점은 세 가지입니다.

- **모든 프로세스의 부모(PPID)가 37번 postmaster입니다.** 백그라운드 프로세스든 뭐든 fork는 postmaster만 합니다.
- **PID 번호가 기동 순서입니다.** io worker(38-40) → checkpointer(41) → background writer(42) 순서로, `PostmasterMain()`의 코드 순서와 같습니다.
- **43번이 비어 있습니다.** 로그를 보면 `database system was shut down at ...`을 남긴 프로세스가 43번입니다. 이것이 startup 프로세스입니다. 이번에는 정상 종료 후의 기동이라 WAL 재생할 것이 없어 바로 끝났고, 그 뒤에 walwriter(44), autovacuum launcher(45)가 떴습니다. startup이 끝나야 PM_RUN이 되고, 그때 walwriter를 띄우는 소스 조건과 정확히 맞습니다.

### 실습 2. pg_stat_activity로 역할 확인

```bash
psql -X -c "SELECT pid, backend_type FROM pg_stat_activity ORDER BY pid"
```

```text
 pid |         backend_type         
-----+------------------------------
  38 | io worker
  39 | io worker
  40 | io worker
  41 | checkpointer
  42 | background writer
  44 | walwriter
  45 | autovacuum launcher
  46 | logical replication launcher
  70 | client backend
(9 rows)

[exit=0]
```

`backend_type` 열의 문자열은 [`GetBackendTypeDesc()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/miscinit.c)가 정한 이름입니다. 70번은 이 쿼리를 실행한 psql의 backend입니다. **postmaster(37)는 목록에 없습니다.** PGPROC 배열에 들어가지 않는다는 설계가 그대로 드러나는 부분입니다.

### 실습 3. 접속할 때마다 backend가 하나씩 생긴다

접속 과정을 로그로 보려고 PG18의 `log_connections` 세부 옵션을 켭니다. PG18부터 `log_connections`는 on/off 대신 `receipt`, `authentication`, `authorization`, `setup_durations`처럼 단계별로 고를 수 있습니다. `log_line_prefix`의 `%b`는 로그 줄에 backend 타입을 찍어 줍니다.

```bash
psql -X -q <<'SQL'
ALTER SYSTEM SET log_line_prefix = '%m [%p] %b ';
ALTER SYSTEM SET log_connections = 'receipt,authentication,authorization,setup_durations';
ALTER SYSTEM SET log_disconnections = on;
SELECT pg_reload_conf();
SQL
```

```text
 pg_reload_conf 
----------------
 t
(1 row)

[exit=0]
```

세션 세 개를 열어 둡니다. 하나는 TCP로 접속해 가만히 있고, 하나는 Unix 소켓으로 접속해 가만히 있고, 하나는 긴 쿼리를 실행합니다.

```bash
docker exec -d pglab bash -c 'sleep 3600 | psql -X -q -h 127.0.0.1'
docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'
docker exec -d pglab bash -c 'psql -X -c "SELECT pg_sleep(3600)"'
```

```text
[exit=0]
[exit=0]
[exit=0]
```

```bash
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
```

```text
    PID    PPID CMD
     37       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
     38      37  \_ postgres: io worker 0
     39      37  \_ postgres: io worker 1
     40      37  \_ postgres: io worker 2
     41      37  \_ postgres: checkpointer 
     42      37  \_ postgres: background writer 
     44      37  \_ postgres: walwriter 
     45      37  \_ postgres: autovacuum launcher 
     46      37  \_ postgres: logical replication launcher 
     87      37  \_ postgres: postgres postgres 127.0.0.1(53408) idle
     96      37  \_ postgres: postgres postgres [local] idle
    103      37  \_ postgres: postgres postgres [local] SELECT
[exit=0]
```

접속 세 개에 backend 세 개(87, 96, 103)가 생겼고, 부모는 모두 postmaster입니다. backend는 `ps`의 프로세스 이름을 `사용자 DB 접속지 상태` 형식으로 바꿔 둡니다. `idle`은 명령을 기다리는 중, `SELECT`는 쿼리를 실행하는 중이라는 뜻이라, `ps`만으로도 각 세션이 무엇을 하는지 대략 알 수 있습니다.

```bash
psql -X -c "SELECT pid, backend_type, client_addr, state, query FROM pg_stat_activity WHERE backend_type = 'client backend' ORDER BY pid"
```

```text
 pid |  backend_type  | client_addr | state  |                                                            query                                                             
-----+----------------+-------------+--------+------------------------------------------------------------------------------------------------------------------------------
  87 | client backend | 127.0.0.1   | idle   | 
  96 | client backend |             | idle   | 
 103 | client backend |             | active | SELECT pg_sleep(3600)
 119 | client backend |             | active | SELECT pid, backend_type, client_addr, state, query FROM pg_stat_activity WHERE backend_type = 'client backend' ORDER BY pid
(4 rows)

[exit=0]
```

```bash
grep -E 'connection (received|authenticated|authorized|ready)' /home/postgres/server.log | head -8
```

```text
2026-09-24 01:41:46.064 UTC [87] not initialized LOG:  connection received: host=127.0.0.1 port=53408
2026-09-24 01:41:46.064 UTC [87] client backend LOG:  connection authenticated: user="postgres" method=trust (/var/lib/postgresql/data/pg_hba.conf:119)
2026-09-24 01:41:46.064 UTC [87] client backend LOG:  connection authorized: user=postgres database=postgres application_name=psql
2026-09-24 01:41:46.065 UTC [87] client backend LOG:  connection ready: setup total=1.032 ms, fork=0.146 ms, authentication=0.083 ms
2026-09-24 01:41:46.113 UTC [96] not initialized LOG:  connection received: host=[local]
2026-09-24 01:41:46.113 UTC [96] client backend LOG:  connection authenticated: user="postgres" method=trust (/var/lib/postgresql/data/pg_hba.conf:117)
2026-09-24 01:41:46.113 UTC [96] client backend LOG:  connection authorized: user=postgres database=postgres application_name=psql
2026-09-24 01:41:46.113 UTC [96] client backend LOG:  connection ready: setup total=1.047 ms, fork=0.140 ms, authentication=0.083 ms
[exit=0]
```

로그가 sequence 그림의 순서를 그대로 보여 줍니다.

- `connection received`를 남긴 것은 postmaster가 아니라 **이미 fork된 87번 프로세스**입니다. 그런데 backend 타입이 `not initialized`로 찍혀 있습니다. fork 직후에는 아직 자기가 일반 backend인지 walsender인지 모르는 상태이기 때문입니다. StartupMessage를 읽은 뒤에야 `client backend`로 정해집니다.
- `setup total=1.032 ms` 가운데 `fork=0.146 ms`입니다. 로컬에서 `trust` 인증을 쓴 조건이라 짧지만, 이 1ms 남짓은 매 접속마다 드는 비용입니다.

### 실습 4. io worker 수를 재시작 없이 바꾸기

```bash
psql -X -c "SHOW io_method" -c "SHOW io_workers"
```

```text
 io_method 
-----------
 worker
(1 row)

 io_workers 
------------
 3
(1 row)

[exit=0]
```

```bash
psql -X -q -c "ALTER SYSTEM SET io_workers = 5" -c "SELECT pg_reload_conf()"
sleep 1
ps -u postgres -o pid,ppid,cmd | grep 'io worker' | grep -v grep
```

```text
 pg_reload_conf 
----------------
 t
(1 row)

     38      37 postgres: io worker 0
     39      37 postgres: io worker 1
     40      37 postgres: io worker 2
    145      37 postgres: io worker 3
    146      37 postgres: io worker 4
[exit=0]
```

```bash
psql -X -q -c "ALTER SYSTEM RESET io_workers" -c "SELECT pg_reload_conf()"
sleep 1
ps -u postgres -o pid,ppid,cmd | grep 'io worker' | grep -v grep
```

```text
 pg_reload_conf 
----------------
 t
(1 row)

     38      37 postgres: io worker 0
     39      37 postgres: io worker 1
     40      37 postgres: io worker 2
[exit=0]
```

reload만으로 io worker가 5개로 늘었다가(145, 146 추가) 다시 3개로 줄었습니다. reload 요청(SIGHUP)을 받은 postmaster가 `maybe_adjust_io_workers()`로 개수를 맞춘 결과입니다.

### 실습 5. autovacuum worker는 누가 fork하나

autovacuum이 자주 돌도록 `autovacuum_naptime`을 1초로 줄이고, 테이블 전체를 UPDATE해서 청소할 거리(dead tuple)를 만듭니다. 그다음 worker가 나타날 때까지 `ps`를 0.25초 간격으로 확인합니다.

```bash
psql -X -q <<'SQL'
ALTER SYSTEM SET autovacuum_naptime = '1s';
ALTER SYSTEM SET log_autovacuum_min_duration = 0;
SELECT pg_reload_conf();
CREATE TABLE av_test AS SELECT g AS id, 0 AS v FROM generate_series(1, 200000) g;
UPDATE av_test SET v = 1;
SQL
for i in $(seq 1 40); do
  ps -u postgres -o pid,ppid,cmd | grep 'autovacuum worker' | grep -v grep && break
  sleep 0.25
done
sleep 3
grep -E 'autovacuum worker LOG:  automatic (vacuum|analyze) of table "postgres.public.av_test"' /home/postgres/server.log | cut -c1-120
```

```text
 pg_reload_conf 
----------------
 t
(1 row)

    213      37 postgres: autovacuum worker postgres
2026-09-24 01:41:51.298 UTC [179] autovacuum worker LOG:  automatic vacuum of table "postgres.public.av_test": index sca
2026-09-24 01:41:51.352 UTC [179] autovacuum worker LOG:  automatic analyze of table "postgres.public.av_test"
2026-09-24 01:41:52.291 UTC [197] autovacuum worker LOG:  automatic vacuum of table "postgres.public.av_test": index sca
2026-09-24 01:41:53.289 UTC [213] autovacuum worker LOG:  automatic vacuum of table "postgres.public.av_test": index sca
2026-09-24 01:41:54.297 UTC [217] autovacuum worker LOG:  automatic vacuum of table "postgres.public.av_test": index sca
2026-09-24 01:41:55.285 UTC [219] autovacuum worker LOG:  automatic vacuum of table "postgres.public.av_test": index sca
[exit=0]
```

`ps`로 잡은 213번 worker의 **부모는 launcher(45)가 아니라 postmaster(37)입니다.** 로그를 보면 179, 197, 213, 217, 219처럼 worker가 약 1초마다 새 PID로 생겼다 사라집니다. worker는 할 일을 마치면 종료하고, 다음 주기에 launcher가 다시 요청하면 postmaster가 새로 fork합니다. (실습용 설정은 이 단계 끝에서 `ALTER SYSTEM RESET`으로 되돌렸습니다.)

### 실습 6. max_connections를 넘으면: 먼저 fork하고 나중에 거절한다

`max_connections`를 5로 줄이고 재시작한 뒤, 세션 5개로 자리를 다 채우고 6번째로 접속해 봅니다.

```bash
psql -X -q -c "ALTER SYSTEM SET max_connections = 5" -c "ALTER SYSTEM SET superuser_reserved_connections = 0"
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
```

```text
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
[exit=0]
```

```bash
for i in 1 2 3 4 5; do docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'; done
psql -X -c "SELECT 1"
```

```text
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: FATAL:  sorry, too many clients already
[exit=2]
```

```bash
grep -B1 'too many clients' /home/postgres/server.log
```

```text
2026-09-24 01:41:58.942 UTC [309] not initialized LOG:  connection received: host=[local]
2026-09-24 01:41:58.942 UTC [309] client backend FATAL:  sorry, too many clients already
[exit=0]
```

거절 메시지를 남긴 것은 postmaster가 아니라 **309번 프로세스**입니다. 자리가 없는 접속도 먼저 fork되고, 자식이 PGPROC 자리를 얻으려다 실패해서 스스로 FATAL로 끝난 것입니다. (실습이 끝난 뒤 설정은 RESET하고 재시작했습니다.)

### 실습 7. 정상 종료와 비정상 종료의 차이

세션 셋을 엽니다. 둘은 idle, 하나(`neighbor`)는 긴 쿼리를 실행하면서 출력을 파일로 남깁니다.

```bash
docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'
docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'
docker exec -d pglab bash -c 'psql -X -c "SELECT pg_sleep(3600)" > /home/postgres/neighbor.out 2>&1'
```

```bash
psql -X -q -c "CREATE TABLE t AS SELECT generate_series(1, 1000) AS id"
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
```

```text
    PID    PPID CMD
    332       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    333     332  \_ postgres: io worker 0
    334     332  \_ postgres: io worker 1
    335     332  \_ postgres: io worker 2
    336     332  \_ postgres: checkpointer 
    337     332  \_ postgres: background writer 
    339     332  \_ postgres: walwriter 
    340     332  \_ postgres: autovacuum launcher 
    341     332  \_ postgres: logical replication launcher 
    350     332  \_ postgres: postgres postgres [local] idle
    359     332  \_ postgres: postgres postgres [local] idle
    367     332  \_ postgres: postgres postgres [local] SELECT
[exit=0]
```

**먼저 정상 종료.** idle 세션 하나(350)를 `pg_terminate_backend()`로 끝냅니다.

```bash
VICTIM=$(pgrep -f 'postgres: postgres postgres \[local\] idle' | head -1)
echo "pg_terminate_backend($VICTIM)"
psql -X -c "SELECT pg_terminate_backend($VICTIM)"
sleep 1
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
grep "\[$VICTIM\]" /home/postgres/server.log | tail -2
```

```text
pg_terminate_backend(350)
 pg_terminate_backend 
----------------------
 t
(1 row)

    PID    PPID CMD
    332       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    333     332  \_ postgres: io worker 0
    334     332  \_ postgres: io worker 1
    335     332  \_ postgres: io worker 2
    336     332  \_ postgres: checkpointer 
    337     332  \_ postgres: background writer 
    339     332  \_ postgres: walwriter 
    340     332  \_ postgres: autovacuum launcher 
    341     332  \_ postgres: logical replication launcher 
    359     332  \_ postgres: postgres postgres [local] idle
    367     332  \_ postgres: postgres postgres [local] SELECT
[exit=0]
2026-09-24 01:42:01.680 UTC [350] client backend FATAL:  terminating connection due to administrator command
2026-09-24 01:42:01.680 UTC [350] client backend LOG:  disconnection: session time: 0:00:02.272 user=postgres database=postgres host=[local]
[exit=0]
```

350번만 사라졌고 나머지 PID는 그대로입니다. backend가 FATAL로 스스로 끝나면서 종료 코드 1을 냈기 때문에, postmaster는 정상 종료로 처리했습니다.

**이번에는 비정상 종료.** 남은 idle 세션(359)에 `kill -9`를 보냅니다.

```bash
VICTIM=$(pgrep -f 'postgres: postgres postgres \[local\] idle' | head -1)
echo "kill -9 $VICTIM"
kill -9 $VICTIM
sleep 2
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
```

```text
kill -9 359
    PID    PPID CMD
    332       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    404     332  \_ postgres: io worker 0
    405     332  \_ postgres: io worker 1
    406     332  \_ postgres: io worker 2
    408     332  \_ postgres: checkpointer 
    409     332  \_ postgres: background writer 
    410     332  \_ postgres: walwriter 
    411     332  \_ postgres: autovacuum launcher 
    412     332  \_ postgres: logical replication launcher 
[exit=0]
```

postmaster(332)를 뺀 **모든 프로세스의 PID가 바뀌었습니다.** 백그라운드 프로세스까지 전부 새로 fork된 것이고, 아무 잘못이 없던 367번 세션도 사라졌습니다. 로그에 전 과정이 남아 있습니다.

```bash
sed -n '/terminated by signal 9/,$p' /home/postgres/server.log
```

```text
2026-09-24 01:42:02.788 UTC [332] postmaster LOG:  client backend (PID 359) was terminated by signal 9: Killed
2026-09-24 01:42:02.788 UTC [332] postmaster LOG:  terminating any other active server processes
2026-09-24 01:42:02.789 UTC [332] postmaster LOG:  all server processes terminated; reinitializing
2026-09-24 01:42:02.798 UTC [407] startup LOG:  database system was interrupted; last known up at 2026-09-24 01:41:59 UTC
2026-09-24 01:42:02.828 UTC [407] startup LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-24 01:42:02.829 UTC [407] startup LOG:  redo starts at 0/3F9F888
2026-09-24 01:42:02.832 UTC [407] startup LOG:  invalid record length at 0/3FC6978: expected at least 24, got 0
2026-09-24 01:42:02.832 UTC [407] startup LOG:  redo done at 0/3FC67E0 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
2026-09-24 01:42:02.834 UTC [408] checkpointer LOG:  checkpoint starting: end-of-recovery immediate wait
2026-09-24 01:42:02.838 UTC [408] checkpointer LOG:  checkpoint complete: wrote 22 buffers (0.1%), wrote 3 SLRU buffers; 0 WAL file(s) added, 0 removed, 0 recycled; write=0.001 s, sync=0.003 s, total=0.005 s; sync files=20, longest=0.001 s, average=0.001 s; distance=156 kB, estimate=156 kB; lsn=0/3FC6978, redo lsn=0/3FC6978
2026-09-24 01:42:02.838 UTC [332] postmaster LOG:  database system is ready to accept connections
[exit=0]
```

lifecycle 그림의 상태 변화가 로그 한 줄 한 줄에 대응합니다.

| 로그 | 상태 |
|---|---|
| `was terminated by signal 9` | 종료 코드가 0, 1이 아니므로 크래시로 판단 |
| `terminating any other active server processes` | PM_WAIT_BACKENDS. 모든 자식에게 SIGQUIT |
| `all server processes terminated; reinitializing` | PM_NO_CHILDREN. 공유 메모리 재생성 |
| `[407] startup ... automatic recovery in progress`, `redo starts` | PM_STARTUP. 새 startup 프로세스(407)가 WAL 재생 |
| `invalid record length ...` | WAL의 끝에 도달했다는 뜻으로, 복구 중에 흔히 보이는 정상 메시지 |
| `database system is ready to accept connections` | PM_RUN 복귀 |

크래시부터 복귀까지 약 50ms가 걸렸습니다. 재생할 WAL이 156kB뿐이라 빨랐던 것이고, 쓰기가 많은 운영 서버라면 마지막 체크포인트 이후 쌓인 WAL 양만큼 오래 걸립니다([8편](/posts/postgresql/08-checkpoint-and-recovery/)에서 다룹니다).

아무 잘못이 없던 옆 세션(367번)의 클라이언트는 다음 메시지를 받았습니다.

```bash
cat /home/postgres/neighbor.out
```

```text
WARNING:  terminating connection because of crash of another server process
DETAIL:  The postmaster has commanded this server process to roll back the current transaction and exit, because another server process exited abnormally and possibly corrupted shared memory.
HINT:  In a moment you should be able to reconnect to the database and repeat your command.
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
[exit=0]
```

"다른 서버 프로세스가 비정상 종료해서 공유 메모리가 망가졌을 수 있으니, 이 프로세스도 트랜잭션을 롤백하고 끝내라고 postmaster가 명령했다"는 뜻입니다. 앞에서 본 설계 이유가 메시지에 그대로 적혀 있습니다. 커밋까지 끝난 데이터는 WAL 재생으로 복구되었습니다.

```bash
psql -X -c "SELECT count(*) FROM t"
```

```text
 count 
-------
  1000
(1 row)

[exit=0]
```

### 실습 8. 일반 backend가 walsender로 바뀌는 경우

`pg_receivewal`로 복제 접속을 만들어 봅니다.

```bash
docker exec -d pglab bash -c 'mkdir -p /home/postgres/wal && pg_receivewal -D /home/postgres/wal'
```

```bash
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
ps -o pid,ppid,cmd -C pg_receivewal
```

```text
    PID    PPID CMD
    332       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    404     332  \_ postgres: io worker 0
    405     332  \_ postgres: io worker 1
    406     332  \_ postgres: io worker 2
    408     332  \_ postgres: checkpointer 
    409     332  \_ postgres: background writer 
    410     332  \_ postgres: walwriter 
    411     332  \_ postgres: autovacuum launcher 
    412     332  \_ postgres: logical replication launcher 
    450     332  \_ postgres: walsender postgres [local] streaming 0/3FD1BB8
    PID    PPID CMD
    443       0 pg_receivewal -D /home/postgres/wal
[exit=0]
```

```bash
WS=$(pgrep -f 'postgres: walsender')
grep "\[$WS\]" /home/postgres/server.log
psql -X -c "SELECT pid, backend_type, application_name, state FROM pg_stat_activity WHERE backend_type = 'walsender'"
```

```text
2026-09-24 01:42:05.115 UTC [450] not initialized LOG:  connection received: host=[local]
2026-09-24 01:42:05.115 UTC [450] walsender LOG:  connection authenticated: user="postgres" method=trust (/var/lib/postgresql/data/pg_hba.conf:124)
2026-09-24 01:42:05.115 UTC [450] walsender LOG:  replication connection authorized: user=postgres application_name=pg_receivewal
2026-09-24 01:42:05.115 UTC [450] walsender LOG:  connection ready: setup total=0.710 ms, fork=0.107 ms, authentication=0.112 ms
 pid | backend_type | application_name | state  
-----+--------------+------------------+--------
 450 | walsender    | pg_receivewal    | active
(1 row)

[exit=0]
```

450번은 일반 접속과 똑같이 `not initialized` 상태로 fork되었다가, StartupMessage에서 복제 요청을 확인한 순간부터 `walsender`로 찍힙니다. 인증에 쓰인 규칙도 일반 접속(117, 119행)과 달리 `pg_hba.conf`의 124행, 즉 `replication` 항목입니다.

### 실습 9. 공유 메모리는 모든 프로세스에 같은 주소로 붙어 있다

```bash
psql -X -c "SHOW shared_buffers" -c "SHOW shared_memory_size" -c "SHOW shared_memory_type"
```

```text
 shared_buffers 
----------------
 128MB
(1 row)

 shared_memory_size 
--------------------
 150MB
(1 row)

 shared_memory_type 
--------------------
 mmap
(1 row)

[exit=0]
```

shared buffers는 128MB지만, 락 테이블과 PGPROC 등을 합친 공유 메모리 전체는 150MB입니다. 21MB짜리 테이블을 만든 뒤, 한 세션은 이 테이블을 한 번 읽고 idle로 두고, 다른 세션은 아무것도 하지 않고 idle로 둡니다.

```bash
psql -X -q -c "CREATE TABLE big AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 150000) g"
psql -X -c "SELECT pg_size_pretty(pg_relation_size('big'))"
```

```text
 pg_size_pretty 
----------------
 21 MB
(1 row)

[exit=0]
```

```bash
docker exec -d pglab bash -c '(echo "SELECT count(*) FROM big;"; sleep 3600) | psql -X -q > /dev/null'
docker exec -d pglab bash -c 'sleep 3600 | psql -X -q'
```

postmaster와 두 backend의 공유 매핑(`rw-s`)을 비교합니다.

```bash
PM=$(head -1 $PGDATA/postmaster.pid)
for p in $PM $(pgrep -f 'postgres: postgres postgres \[local\] idle'); do
  echo "== PID $p  $(ps -o cmd= -p $p)"
  grep ' rw-s ' /proc/$p/maps | awk '{print "   ", $1, $6, $7}'
done
```

```text
== PID 332  /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    ffff7cb27000-ffff860d9000 /dev/zero (deleted)
    ffff88938000-ffff88940000 /dev/shm/PostgreSQL.2214466610 
    ffff889a9000-ffff889aa000 /SYSV000fb191 (deleted)
== PID 502  postgres: postgres postgres [local] idle
    ffff7c994000-ffff7c9c5000 /dev/shm/PostgreSQL.3907697562 
    ffff7ca06000-ffff7cb06000 /dev/shm/PostgreSQL.2641106026 
    ffff7cb27000-ffff860d9000 /dev/zero (deleted)
    ffff88938000-ffff88940000 /dev/shm/PostgreSQL.2214466610 
    ffff889a9000-ffff889aa000 /SYSV000fb191 (deleted)
== PID 512  postgres: postgres postgres [local] idle
    ffff7ca06000-ffff7cb06000 /dev/shm/PostgreSQL.2641106026 
    ffff7cb27000-ffff860d9000 /dev/zero (deleted)
    ffff88938000-ffff88940000 /dev/shm/PostgreSQL.2214466610 
    ffff889a9000-ffff889aa000 /SYSV000fb191 (deleted)
[exit=0]
```

- `ffff7cb27000-ffff860d9000 /dev/zero (deleted)`가 본체 공유 메모리입니다. 주소 범위를 계산하면 156,966,912바이트, 약 150MB로 `shared_memory_size`와 같습니다. **세 프로세스 모두 정확히 같은 주소에 붙어 있습니다.** postmaster가 만든 매핑을 fork로 물려받았기 때문입니다. `/dev/zero (deleted)`는 `shared_memory_type = mmap`일 때 익명 공유 매핑이 `/proc`에 표시되는 방식입니다.
- `/SYSV000fb191`는 몇 바이트짜리 System V 공유 메모리입니다. 데이터를 담는 곳이 아니라, 같은 데이터 디렉터리에 postmaster가 두 개 뜨는 일을 막는 잠금 장치로 씁니다([`sysv_shmem.c`의 주석](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/port/sysv_shmem.c#L43-L46)).
- `/dev/shm/PostgreSQL.*`는 필요할 때 따로 만들어 붙이는 동적 공유 메모리(DSM)입니다. 프로세스마다 붙어 있는 조각이 다른 것도 그래서입니다.

이번에는 메모리 사용량을 봅니다. `VmRSS`는 `ps`나 `top`이 보여 주는 RSS 값이고, 리눅스는 이를 개인 메모리(`RssAnon`), 파일 매핑(`RssFile`), 공유 메모리(`RssShmem`)로 나눠 보여 줍니다.

```bash
PM=$(head -1 $PGDATA/postmaster.pid)
for p in $PM $(pgrep -f 'postgres: postgres postgres \[local\] idle'); do
  echo "== PID $p  $(ps -o cmd= -p $p)"
  grep -E '^(VmRSS|RssAnon|RssShmem)' /proc/$p/status
done
```

```text
== PID 332  /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
VmRSS:	   22792 kB
RssAnon:	     956 kB
RssShmem:	   13372 kB
== PID 502  postgres: postgres postgres [local] idle
VmRSS:	   34768 kB
RssAnon:	    2028 kB
RssShmem:	   24640 kB
== PID 512  postgres: postgres postgres [local] idle
VmRSS:	   11684 kB
RssAnon:	    1776 kB
RssShmem:	    3472 kB
[exit=0]
```

테이블을 읽은 502번은 RSS가 34MB로, 아무것도 안 한 512번(11MB)의 세 배입니다. 하지만 늘어난 부분은 거의 `RssShmem`(24MB)이고, 자기만 쓰는 `RssAnon`은 2MB 정도로 비슷합니다. 21MB 테이블을 shared buffers로 읽어 들이면서 **공유 메모리 페이지를 만진 만큼 그 프로세스의 RSS에 잡힌 것**입니다. 같은 페이지를 다른 backend가 만지면 그쪽 RSS에도 똑같이 잡힙니다. 운영에서 이 점이 왜 중요한지는 아래에서 다룹니다.

### 실습 10. 설정에 따라 생기는 프로세스: logger, archiver

`logging_collector`와 `archive_mode`를 켜고 재시작합니다. 두 설정 모두 재시작이 필요합니다.

```bash
mkdir -p /home/postgres/archive
psql -X -q <<'SQL'
ALTER SYSTEM SET logging_collector = on;
ALTER SYSTEM SET archive_mode = on;
ALTER SYSTEM SET archive_command = 'cp %p /home/postgres/archive/%f';
SQL
pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
sleep 1
PM=$(head -1 $PGDATA/postmaster.pid); ps -o pid,ppid,cmd --forest -p $PM --ppid $PM
```

```text
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
    PID    PPID CMD
    560       1 /usr/local/pgsql/bin/postgres -D /var/lib/postgresql/data
    561     560  \_ postgres: logger 
    562     560  \_ postgres: io worker 0
    563     560  \_ postgres: io worker 1
    564     560  \_ postgres: io worker 2
    565     560  \_ postgres: checkpointer 
    566     560  \_ postgres: background writer 
    568     560  \_ postgres: walwriter 
    569     560  \_ postgres: autovacuum launcher 
    570     560  \_ postgres: archiver 
    571     560  \_ postgres: logical replication launcher 
[exit=0]
```

```bash
psql -X -c "SELECT pid, backend_type FROM pg_stat_activity ORDER BY pid"
```

```text
 pid |         backend_type         
-----+------------------------------
 562 | io worker
 563 | io worker
 564 | io worker
 565 | checkpointer
 566 | background writer
 568 | walwriter
 569 | autovacuum launcher
 570 | archiver
 571 | logical replication launcher
 582 | client backend
(10 rows)

[exit=0]
```

logger(561)는 가장 먼저(다른 어떤 자식보다 먼저) 떴습니다. 이후 프로세스들의 로그를 받아 적어야 하기 때문입니다. archiver(570)는 `pg_stat_activity`에 보이지만 **logger는 보이지 않습니다.** 공유 메모리에 붙지 않는 프로세스라서 그렇습니다.

### 실습 11. postmaster가 죽으면

마지막으로 postmaster 자체에 `kill -9`를 보냅니다. **운영 서버에서는 절대 하면 안 되는 일입니다.**

```bash
PM=$(head -1 $PGDATA/postmaster.pid)
echo "kill -9 $PM (postmaster)"
kill -9 $PM
sleep 2
ps -u postgres -o pid,ppid,stat,cmd | grep -v -e 'ps -u' -e 'sleep infinity'
```

```text
kill -9 560 (postmaster)
    PID    PPID STAT CMD
    583       0 Ss   bash -s
[exit=0]
```

`bash -s`는 이 명령을 실행한 셸입니다. PostgreSQL 프로세스는 하나도 남지 않았습니다. 부모가 죽은 것을 알아챈 자식들이 스스로 종료했습니다.

```bash
psql -X -c "SELECT 1"
```

```text
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: Connection refused
	Is the server running locally and accepting connections on that socket?
[exit=2]
```

```bash
pg_ctl -D $PGDATA -l /home/postgres/server.log start
sleep 1
tail -n 8 $PGDATA/log/$(ls -t $PGDATA/log | head -1)
```

```text
pg_ctl: another server might be running; trying to start server anyway
waiting for server to start.... done
server started
2026-09-24 01:42:13.447 UTC [609] postmaster LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
2026-09-24 01:42:13.449 UTC [616] startup LOG:  database system was interrupted; last known up at 2026-09-24 01:42:10 UTC
2026-09-24 01:42:13.473 UTC [616] startup LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-24 01:42:13.475 UTC [616] startup LOG:  unexpected pageaddr 0/26EC000 in WAL segment 000000010000000000000005, LSN 0/56EC000, offset 7258112
2026-09-24 01:42:13.475 UTC [616] startup LOG:  redo is not required
2026-09-24 01:42:13.476 UTC [614] checkpointer LOG:  checkpoint starting: end-of-recovery immediate wait
2026-09-24 01:42:13.478 UTC [614] checkpointer LOG:  checkpoint complete: wrote 0 buffers (0.0%), wrote 3 SLRU buffers; 0 WAL file(s) added, 0 removed, 0 recycled; write=0.001 s, sync=0.001 s, total=0.003 s; sync files=2, longest=0.001 s, average=0.001 s; distance=0 kB, estimate=0 kB; lsn=0/56EC048, redo lsn=0/56EC048
2026-09-24 01:42:13.478 UTC [609] postmaster LOG:  database system is ready to accept connections
[exit=0]
```

`postmaster.pid`가 남아 있어서 `pg_ctl`이 "다른 서버가 떠 있을 수도 있다"고 경고했지만, 파일에 적힌 PID의 프로세스가 없으니 그대로 기동했습니다. 정상 종료가 아니었으므로 이번에도 startup이 복구 과정을 거쳤습니다. 마지막 체크포인트 이후 변경이 없어서 `redo is not required`로 끝났습니다.

## 운영에서는 이렇게 나타납니다

### 커넥션이 많을수록 비싸지는 이유

접속 하나가 프로세스 하나이므로, 커넥션 수는 곧 프로세스 수입니다. 실습에서 확인한 비용은 다음과 같습니다.

- **접속할 때마다 드는 비용**: 실습 3에서 접속 준비에 약 1ms(fork 약 0.15ms)가 걸렸습니다. 로컬 소켓에 `trust` 인증을 쓴 가장 가벼운 조건입니다. 네트워크 왕복, TLS, 비밀번호 인증이 붙으면 더 걸립니다. 요청마다 새로 접속하는 애플리케이션이라면 이 비용을 요청마다 냅니다.
- **프로세스마다 드는 메모리**: idle backend 하나의 개인 메모리(`RssAnon`)는 약 1.8MB였습니다. 쿼리를 실행하면 카탈로그 캐시와 정렬, 해시에 쓰는 작업 메모리(`work_mem`)가 여기에 더해집니다. 작업 메모리는 [2편](/posts/postgresql/02-memory-architecture/)에서 다룹니다.
- **공유 자원 경쟁**: 모든 backend가 같은 공유 메모리의 락과 PGPROC 배열을 씁니다. 프로세스가 많아지면 그만큼 경쟁과 문맥 전환(context switch)이 늘어납니다.

그래서 수천 개의 애플리케이션 커넥션을 그대로 PostgreSQL에 붙이지 않고, **PgBouncer 같은 커넥션 풀러**를 앞에 둡니다. 풀러는 애플리케이션의 접속은 많이 받고, PostgreSQL에는 적은 수의 접속만 유지하면서 backend를 돌려 씁니다. fork와 인증 비용은 한 번만 내고, 프로세스 수도 일정하게 유지됩니다.

### RSS를 합산하면 메모리 사용량이 부풀려진다

실습 9에서 본 것처럼, backend의 RSS에는 그 프로세스가 만진 **공유 메모리 페이지가 포함됩니다.** 같은 shared buffers 페이지를 backend 100개가 읽었다면, 그 페이지는 100개 프로세스의 RSS에 모두 잡힙니다. 모니터링 도구로 `postgres` 프로세스들의 RSS를 합산하면 실제 사용량보다 훨씬 큰 값이 나오는 이유입니다. 프로세스별 개인 메모리를 보려면 `/proc/<pid>/status`의 `RssAnon`이나 `smem`의 USS/PSS 같은 지표를 보는 것이 정확합니다.

### "too many clients"는 이미 fork된 뒤에 나온다

실습 6처럼 `max_connections`에 걸린 접속도 일단 fork되었다가 거절됩니다. 애플리케이션이 접속 실패를 짧은 간격으로 재시도하도록 되어 있으면, 거절될 접속을 만드느라 fork가 계속 일어납니다. 한도에 걸리는 상황이라면 재시도 간격을 늘리고 풀러를 두는 것이 근본적인 해결책입니다.

관리자용 여유분도 알아 두면 좋습니다. `superuser_reserved_connections`(기본 3)만큼의 자리는 superuser만 쓸 수 있어서, 일반 접속이 한도를 다 채워도 DBA는 들어와서 조치할 수 있습니다. PG16부터는 `pg_use_reserved_connections` 역할에게 줄 여유분을 `reserved_connections`로 따로 둘 수 있습니다.

### backend에 kill -9를 쓰면 안 되는 이유

실습 7의 결과가 곧 이유입니다. 문제가 된 세션 하나를 끝내려고 `kill -9`를 쓰면, **그 순간 서버의 모든 세션이 끊기고 복구 과정을 거칩니다.** 세션을 끝낼 때는 다음을 씁니다.

```sql
SELECT pg_cancel_backend(pid);     -- 실행 중인 쿼리만 취소 (세션은 유지)
SELECT pg_terminate_backend(pid);  -- 세션 종료 (다른 세션에는 영향 없음)
```

운영자가 직접 `kill -9`를 쓰지 않아도 같은 일이 일어날 수 있습니다. 대표적인 것이 **리눅스 OOM killer**입니다. 메모리가 모자라 커널이 backend 하나를 죽이면 똑같이 전체 재시작이 일어나고, 커널이 postmaster를 골라 죽이면 서버가 아예 내려갑니다. 그래서 PostgreSQL 문서는 전용 DB 서버에서 `vm.overcommit_memory = 2`로 메모리 overcommit을 막아 OOM killer가 개입할 상황 자체를 줄이라고 권합니다([Linux Memory Overcommit](https://www.postgresql.org/docs/18/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT)).

로그에서 다음 줄이 보이면 크래시 재시작이 일어난 것입니다. 바로 앞 줄에 어떤 프로세스가 어떤 시그널로 죽었는지 나오므로, 그 PID를 기준으로 원인을 추적합니다.

```text
2026-09-24 01:42:02.788 UTC [332] postmaster LOG:  terminating any other active server processes
2026-09-24 01:42:02.789 UTC [332] postmaster LOG:  all server processes terminated; reinitializing
```

### 컨테이너에서는 PID 1이 좀비를 치워야 한다

이 글의 실습은 `docker run --init`으로 컨테이너를 띄웠습니다. 처음에는 `--init` 없이 `sleep infinity`를 PID 1로 두고 실습했는데, 실습 11에서 postmaster를 죽인 뒤 재기동이 실패했습니다. 그때의 기록입니다.

```text
2026-09-24 01:39:36.364 UTC [642] postmaster FATAL:  lock file "postmaster.pid" already exists
2026-09-24 01:39:36.364 UTC [642] postmaster HINT:  Is another postmaster (PID 615) running in data directory "/var/lib/postgresql/data"?
```

```text
    PID    PPID STAT CMD
      1       0 Ss   sleep infinity
    615       1 Zs   [postgres] <defunct>
    616       1 Zs   [postgres] <defunct>
    617       1 Zs   [postgres] <defunct>
```

(`ps` 출력에서 PostgreSQL과 관계없는 좀비 줄은 생략했습니다.)

postmaster가 죽자 자식들의 부모는 PID 1로 바뀌었습니다. 그런데 `sleep`은 끝난 자식 프로세스를 회수(`wait`)하지 않으므로, 죽은 postmaster(615)가 좀비(`Z`)로 남았습니다. 좀비도 PID는 차지하고 있어서, 새 postmaster는 `postmaster.pid`에 적힌 615번이 아직 살아 있다고 판단하고 기동을 거부했습니다. PostgreSQL을 컨테이너에서 직접 띄울 때 PID 1을 `sleep`이나 셸 스크립트로 두었다면 `--init`(tini)이나 좀비를 회수하는 init을 쓰는 것이 안전합니다. 공식 `postgres` 이미지처럼 postmaster 자체를 PID 1로 두는 경우에는, postmaster가 자식을 회수하므로 이 문제가 없습니다.

## 정리

- PostgreSQL은 **프로세스 기반**입니다. postmaster가 모든 프로세스의 부모이고, fork는 postmaster만 합니다.
- postmaster는 **접속을 받아 fork하고 자식을 감시할 뿐**, 쿼리를 처리하거나 공유 메모리를 만지지 않습니다. 그래서 자식이 어떻게 죽든 뒷수습을 할 수 있습니다.
- backend는 **접속 하나에 하나**입니다. fork가 먼저이고, 인증과 `max_connections` 확인은 fork된 자식이 합니다.
- 백그라운드 프로세스들이 디스크 쓰기(checkpointer, background writer, walwriter), 읽기(PG18의 io worker), 청소(autovacuum), 보관(archiver)을 나눠 맡습니다. 어떤 프로세스가 뜰지는 postmaster 상태와 설정으로 정해집니다.
- 모든 프로세스는 **같은 공유 메모리를 같은 주소로** 봅니다. 그래서 프로세스 하나가 비정상 종료하면 postmaster는 공유 메모리를 믿을 수 없다고 보고, **모두 내린 뒤 WAL로 복구해서 다시 띄웁니다.**
- 운영에서는 커넥션 풀러로 프로세스 수를 관리하고, 세션은 `pg_terminate_backend()`로 끝내고, OOM killer가 backend를 죽이지 않도록 메모리 설정을 관리합니다.

다음 글에서는 이 프로세스들이 함께 쓰는 **공유 메모리 안쪽**, 즉 shared buffers, WAL buffers, 그리고 backend마다 따로 쓰는 `work_mem`을 살펴봅니다.

## 참고 자료

소스 코드 (모두 `REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/postmaster/postmaster.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c): postmaster 본체, `ServerLoop`, `BackendStartup`, 크래시 처리, `PMState`
- [src/backend/postmaster/launch_backend.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/launch_backend.c): 프로세스 종류별 시작 함수 표와 fork
- [src/backend/postmaster/pmchild.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/pmchild.c): 자식 프로세스 슬롯 관리
- [src/backend/tcop/backend_startup.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/backend_startup.c): backend 시작, StartupMessage 처리, `log_connections`
- [src/backend/tcop/postgres.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/tcop/postgres.c): `PostgresMain` 메인 루프, `quickdie`
- [src/backend/storage/aio/method_worker.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/storage/aio/method_worker.c): PG18 io worker
- [src/include/miscadmin.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/miscadmin.h): `BackendType` 정의

PostgreSQL 18 공식 문서

- [How Connections Are Established](https://www.postgresql.org/docs/18/connect-estab.html)
- [Glossary: Postmaster](https://www.postgresql.org/docs/18/glossary.html#GLOSSARY-POSTMASTER), [Auxiliary process](https://www.postgresql.org/docs/18/glossary.html#GLOSSARY-AUXILIARY-PROC)
- [io_method, io_workers](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-IO-METHOD)
- [log_connections](https://www.postgresql.org/docs/18/runtime-config-logging.html#GUC-LOG-CONNECTIONS)
- [restart_after_crash](https://www.postgresql.org/docs/18/runtime-config-error-handling.html#GUC-RESTART-AFTER-CRASH)
- [pg_stat_activity](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW)
- [Linux Memory Overcommit](https://www.postgresql.org/docs/18/kernel-resources.html#LINUX-MEMORY-OVERCOMMIT)

실습 파일

- [Dockerfile](/labs/pg-01-process/Dockerfile), [lab.sh](/labs/pg-01-process/lab.sh), [final-run.log](/labs/pg-01-process/final-run.log)
