---
title: "PostgreSQL extension은 어떻게 동작하는가"
date: 2026-09-25
draft: false
categories: ["PostgreSQL"]
subcategory: "인터널"
tags: ["PostgreSQL", "extension", "CREATE EXTENSION", "shared_preload_libraries", "dlopen"]
summary: "control 파일, SQL 스크립트, 공유 라이브러리가 CREATE EXTENSION과 dlopen을 거쳐 서버 프로세스 안에서 돌기까지"
description: "공유 라이브러리와 fork 같은 OS 배경지식부터 CREATE EXTENSION, 라이브러리 로드, hook, shared_preload_libraries, 업그레이드까지"
---

## 개요

`CREATE EXTENSION pg_stat_statements` 한 줄이면 새 뷰와 함수가 생기고, `shared_preload_libraries`에 이름을 넣고 재시작하면 모든 쿼리의 통계가 쌓이기 시작합니다. 너무 간단해서 안에서 무슨 일이 일어나는지 생각해 볼 일이 별로 없습니다. 그러다 운영 중에 이런 일을 겪습니다.

- `CREATE EXTENSION`은 성공했는데 조회하면 `must be loaded via "shared_preload_libraries"` 오류가 난다.
- 패키지를 올렸는데 `ALTER EXTENSION ... UPDATE`가 `could not find function` 오류로 실패한다.
- extension 함수 하나를 불렀을 뿐인데 모든 접속이 끊기고 서버가 복구 모드로 들어간다.

이런 일은 모두 extension이 **파일 몇 개와 카탈로그 행 몇 개, 그리고 서버 프로세스 안으로 들어온 C 코드**로 이루어져 있기 때문에 생깁니다. 이 글은 다음 질문에 답합니다.

- extension은 무엇으로 이루어지고, `CREATE EXTENSION`은 정확히 무엇을 하는가
- C로 짠 함수는 언제, 어떻게 서버 프로세스 안으로 들어오는가
- 왜 어떤 extension은 `shared_preload_libraries`에 넣고 재시작해야 하는가
- 라이브러리 파일을 바꾸면 이미 떠 있는 프로세스에는 무슨 일이 일어나는가

C extension의 동작은 공유 라이브러리, 심볼, `dlopen`, `fork` 같은 운영체제 개념 위에 서 있습니다. 이 개념들을 먼저 짧게 정리하고 시작합니다. 설명에는 직접 만든 작은 extension `demo_ext`를 씁니다.

> **기준 버전**: PostgreSQL 18, `REL_18_STABLE` 커밋 [`39a0db1`](https://github.com/postgres/postgres/commit/39a0db101105eab3f4044d11c609c58b9459ea16)(18.6 개발 버전). [PostgreSQL 인터널 연재](/series/postgresql-인터널/)와 같은 커밋이고, 소스 링크는 모두 이 커밋에 고정했습니다. 실습은 Rocky Linux 9.8(aarch64) 컨테이너에서 이 소스를 gcc 11.5로 빌드해 실행한 결과입니다.

먼저 결론부터 정리하면 이렇습니다.

| 구성 요소 | 위치 | 하는 일 |
|---|---|---|
| control 파일 (`이름.control`) | `share/extension/` | 기본 버전, 라이브러리 경로, 권한 같은 메타데이터 |
| SQL 스크립트 (`이름--버전.sql`, `이름--이전--다음.sql`) | `share/extension/` | 설치하거나 업데이트할 때 실행할 SQL |
| 공유 라이브러리 (`이름.so`) | `$libdir` (`lib/`) | C 함수와 hook. 서버 프로세스 안으로 들어와 실행됨 |
| `pg_extension` 행 | 카탈로그 | 이 DB에 어떤 extension이 몇 버전으로 설치되어 있는지 |
| `pg_depend` 행 (`deptype = 'e'`) | 카탈로그 | 어떤 객체가 그 extension의 소속인지 |

`CREATE EXTENSION`은 앞의 두 파일을 읽어 카탈로그를 채우는 명령이고, `.so`는 그 과정이나 첫 함수 호출 때 `dlopen`으로 프로세스에 올라옵니다. 이 둘이 서로 다른 시점에 따로 움직인다는 것이 이 글 전체의 요점입니다.

## 먼저 알아야 할 OS 배경지식

### 공유 라이브러리와 심볼

C 소스를 컴파일하면 기계어와 함께 **심볼 표**가 나옵니다. 심볼은 함수나 전역 변수의 이름입니다. 파일 안에 정의가 있는 심볼(defined)이 있고, 이름만 쓰고 정의는 다른 곳에서 찾아야 하는 심볼(undefined)이 있습니다.

**공유 라이브러리**(Linux에서는 `.so`, shared object)는 실행 파일처럼 ELF 형식이지만 혼자 실행되지 않고 다른 프로세스에 끼워 넣어 쓰는 파일입니다. 어느 주소에 올라가도 동작하도록 위치 독립 코드(`-fPIC`)로 컴파일하고 `-shared`로 링크합니다. 이 파일을 실행 중에 프로세스로 불러오는 함수가 `dlopen()`, 불러온 라이브러리에서 이름으로 심볼 주소를 찾는 함수가 `dlsym()`입니다. `dlopen()`이 라이브러리를 올릴 때 **동적 링커**가 라이브러리의 undefined 심볼을 이미 프로세스에 있는 심볼과 연결합니다.

`demo_ext`를 PGXS(extension 빌드용 Makefile 틀, [뒤에서](#extension을-이루는-파일들) 설명)로 빌드할 때 나온 명령에서 이 옵션들을 볼 수 있습니다(경고 옵션은 줄였습니다).

```console
$ make
gcc -Wall -Wmissing-prototypes -Wpointer-arith -Wdeclaration-after-statement -Werror=vla -Wendif-labels -Wmissing-format-attribute -Wimplicit-fallthrough=3 -Wcast-function-type -Wshadow=compatible-local -Wformat-security -fno-strict-aliasing -fwrapv -fexcess-precision=standard -Wno-format-truncation -Wno-stringop-truncation -O2 -fPIC -fvisibility=hidden -I. -I./ -I/usr/local/pgsql/include/server -I/usr/local/pgsql/include/internal -D_GNU_SOURCE      -c -o demo_ext.o demo_ext.c
gcc -Wall -Wmissing-prototypes -Wpointer-arith -Wdeclaration-after-statement -Werror=vla -Wendif-labels -Wmissing-format-attribute -Wimplicit-fallthrough=3 -Wcast-function-type -Wshadow=compatible-local -Wformat-security -fno-strict-aliasing -fwrapv -fexcess-precision=standard -Wno-format-truncation -Wno-stringop-truncation -O2 -fPIC -fvisibility=hidden demo_ext.o -L/usr/local/pgsql/lib   -Wl,--as-needed -Wl,-rpath,'/usr/local/pgsql/lib',--enable-new-dtags -fvisibility=hidden -shared -o demo_ext.so
```

`-fvisibility=hidden`은 기본적으로 모든 심볼을 라이브러리 밖에서 안 보이게 숨기는 옵션입니다. 밖에서 찾아야 하는 심볼만 PostgreSQL 매크로(`PG_FUNCTION_INFO_V1`, `PG_MODULE_MAGIC`)가 `PGDLLEXPORT`로 내보냅니다([`fmgr.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/fmgr.h#L415)).

#### demo_ext.so의 심볼 표

`nm -D`는 동적 심볼 표를 보여 줍니다. `T`는 이 파일 안에 정의된 함수, `U`는 다른 곳에서 찾아야 하는 심볼입니다.

```console
$ file demo_ext.so
demo_ext.so: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked, BuildID[sha1]=020d9238e238d042536254e28e669018b6045b7c, not stripped
$ nm -D --defined-only demo_ext.so
0000000000000ed0 T Pg_magic_func
0000000000000ee0 T _PG_init
0000000000001030 T demo_add
0000000000001054 T demo_build
0000000000001100 T demo_crash
0000000000001070 T demo_local_count
0000000000001090 T demo_shared_count
0000000000001020 T pg_finfo_demo_add
0000000000001044 T pg_finfo_demo_build
00000000000010f0 T pg_finfo_demo_crash
0000000000001060 T pg_finfo_demo_local_count
0000000000001080 T pg_finfo_demo_shared_count
$ nm -D --undefined-only demo_ext.so
                 U DefineCustomBoolVariable
                 U ExecutorEnd_hook
                 U MarkGUCPrefixReserved
                 U RequestAddinShmemSpace
                 U ShmemInitStruct
                 w _ITM_deregisterTMCloneTable
                 w _ITM_registerTMCloneTable
                 w __cxa_finalize@GLIBC_2.17
                 U __getauxval@GLIBC_2.17
                 w __gmon_start__
                 U cstring_to_text
                 U errcode
                 U errfinish
                 U errmsg
                 U errmsg_internal
                 U errstart
                 U errstart_cold
                 U getpid@GLIBC_2.17
                 U process_shared_preload_libraries_in_progress
                 U shmem_request_hook
                 U shmem_startup_hook
                 U standard_ExecutorEnd
$ ldd demo_ext.so
	linux-vdso.so.1 (0x0000ffffbe987000)
	libc.so.6 => /lib64/libc.so.6 (0x0000ffffbe771000)
	/lib/ld-linux-aarch64.so.1 (0x0000ffffbe940000)
```

- 정의된 심볼에는 SQL에서 부를 함수(`demo_add` 등)와 짝을 이루는 `pg_finfo_demo_add`, 그리고 `Pg_magic_func`, `_PG_init`이 있습니다. 이 세 종류가 PostgreSQL이 `dlsym()`으로 찾는 이름입니다. C 소스의 `static` 변수(`local_queries` 등)는 숨겨져서 보이지 않습니다.
- undefined 심볼의 대부분은 **PostgreSQL 서버 자신의 함수와 전역 변수**입니다. `errstart`, `errmsg`는 `ereport()`가, `cstring_to_text`는 문자열 반환이, `ExecutorEnd_hook`은 [hook](#_pg_init과-hook)이 쓰는 심볼입니다. `GLIBC` 표시가 붙은 몇 개만 C 라이브러리에서 옵니다.
- 그런데 `ldd`로 의존 라이브러리를 보면 `libc`뿐이고 PostgreSQL은 없습니다. 이 심볼들은 어디서 찾는 걸까요.

### 서버 실행 파일이 심볼을 내보낸다

답은 **`postgres` 실행 파일 자신**입니다. 보통 실행 파일은 자기 함수 이름을 동적 심볼 표에 올리지 않지만 PostgreSQL은 서버를 링크할 때 `-Wl,--export-dynamic`을 붙여 모든 전역 심볼을 동적 심볼 표에 올립니다([`configure.ac`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/configure.ac#L2453)). 그래서 `postgres` 프로세스 안으로 올라온 `.so`는 서버 내부 함수를 제 것처럼 부를 수 있습니다.

#### postgres 실행 파일의 동적 심볼

```console
$ grep -E "^(LDFLAGS_EX_BE|CFLAGS_SL|CFLAGS_SL_MODULE|DLSUFFIX) " $(pg_config --pgxs | sed "s#makefiles/pgxs.mk#Makefile.global#")
CFLAGS_SL = -fPIC
CFLAGS_SL_MODULE =  -fvisibility=hidden
LDFLAGS_EX_BE =  -Wl,--export-dynamic
DLSUFFIX = .so
$ nm -D --defined-only /usr/local/pgsql/bin/postgres | wc -l
11192
$ nm -D --defined-only /usr/local/pgsql/bin/postgres | grep -wE "cstring_to_text|errstart|ExecutorEnd_hook|ShmemInitStruct|standard_ExecutorEnd|shmem_request_hook|process_shared_preload_libraries_in_progress"
0000000000d0bd78 B ExecutorEnd_hook
0000000000809b30 T ShmemInitStruct
00000000009461d4 T cstring_to_text
000000000096f660 T errstart
0000000000d26760 B process_shared_preload_libraries_in_progress
0000000000d26790 B shmem_request_hook
0000000000670870 T standard_ExecutorEnd
```

`postgres` 실행 파일은 동적 심볼 11192개를 내보냅니다. `demo_ext.so`가 찾던 이름이 모두 여기 있습니다. `T`는 함수이고, `B`는 초기값 없는 전역 변수(`.bss` 영역)입니다. `ExecutorEnd_hook`이 **함수가 아니라 변수**라는 점을 기억해 두세요. [hook](#_pg_init과-hook)은 이 변수에 함수 주소를 써넣는 방식으로 동작합니다.

그렇다면 `demo_ext.so`를 PostgreSQL이 아닌 프로그램에 올리면 어떻게 될까요. `dlopen()`만 부르는 작은 C 프로그램을 만들어 봤습니다. 플래그는 PostgreSQL이 쓰는 것과 같은 `RTLD_NOW | RTLD_GLOBAL`입니다.

#### PostgreSQL 밖에서 dlopen하면

```console
$ cat dltest.c
#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	void	   *h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);

	if (h == NULL)
	{
		printf("dlopen failed: %s\n", dlerror());
		return 1;
	}
	printf("dlopen ok\n");
	return 0;
}
$ gcc -o dltest dltest.c
$ ./dltest ./demo_ext/demo_ext.so
dlopen failed: ./demo_ext/demo_ext.so: undefined symbol: ExecutorEnd_hook
$ ./dltest /usr/local/pgsql/lib/pg_stat_statements.so
dlopen failed: /usr/local/pgsql/lib/pg_stat_statements.so: undefined symbol: post_parse_analyze_hook
```

`RTLD_NOW`는 "올리는 순간 undefined 심볼을 모두 연결하라"는 뜻입니다. 이 프로그램에는 `ExecutorEnd_hook`이 없으니 올리는 단계에서 실패합니다. PostgreSQL의 extension 라이브러리는 **`postgres` 프로세스 안에서만 살 수 있는 코드**이고, 서버 내부의 함수와 전역 변수를 직접 만질 수 있습니다. 서버 코드와 같은 권한, 같은 주소 공간에서 돈다는 뜻이고, [C 함수의 버그가 서버 전체에 영향을 주는 이유](#운영에서는-c-extension의-버그는-서버-전체를-재시작시킨다)도 여기 있습니다.

### dlopen은 파일을 메모리에 매핑한다

`dlopen()`은 파일을 `read()`로 통째로 읽어 들이지 않습니다. **`mmap()`으로 파일을 프로세스 주소 공간에 매핑**합니다. 매핑된 영역은 `/proc/<pid>/maps`에 한 줄씩 나타나며 공유 라이브러리 하나는 보통 권한이 다른 네 영역으로 보입니다.

| 권한 | 내용 |
|---|---|
| `r-xp` | 기계어 코드 (읽기, 실행) |
| `---p` | 정렬을 맞추려고 비워 둔 틈 |
| `r--p` | 동적 링커가 주소를 채운 뒤 읽기 전용으로 바꾼 영역(RELRO) |
| `rw-p` | 전역 변수와 `static` 변수 |

끝의 `p`는 private, 즉 **copy-on-write 매핑**입니다. 여러 프로세스가 같은 `.so`를 매핑하면 처음에는 같은 물리 페이지를 공유하지만 한 프로세스가 `rw-p` 영역에 쓰는 순간 그 페이지만 해당 프로세스 전용으로 복사됩니다. 그래서 `.so` 안의 `static` 변수는 **프로세스마다 따로** 있습니다. 실제 매핑 모습은 [CREATE EXTENSION 절](#backend-주소-공간에-생긴-매핑)에서 봅니다.

### fork와 프로세스별 메모리

[1편](/posts/postgresql/01-process-architecture/)에서 봤듯이 PostgreSQL은 접속마다 postmaster가 `fork()`로 backend를 만듭니다. `fork()`는 부모의 주소 공간을 그대로 복제하므로(copy-on-write) **부모가 이미 매핑해 둔 라이브러리와 거기 담긴 전역 변수 값**이 자식에게 그대로 넘어갑니다. 반대로 `fork()` 뒤에 자식이 따로 `dlopen()`한 라이브러리는 그 자식에게만 있습니다.

프로세스끼리 값을 함께 보려면 **공유 메모리**([2편](/posts/postgresql/02-memory-architecture/))가 필요합니다. PostgreSQL의 공유 메모리는 postmaster가 시작할 때 크기를 정해 한 번 만들고, 이후 모든 자식이 물려받습니다. 크기를 나중에 늘릴 수 없으니 공유 메모리를 쓰려는 extension은 postmaster가 공유 메모리를 만들기 전에 올라와 있어야 하고, 그러려면 [`shared_preload_libraries`](#shared_preload_libraries-postmaster가-먼저-올리는-경우)가 필요합니다.

> **용어 정리**
> - **심볼(symbol)**: 함수나 전역 변수의 이름과 주소. 공유 라이브러리를 올릴 때 이름으로 서로 연결됩니다.
> - **`dlopen()` / `dlsym()`**: 실행 중에 공유 라이브러리를 프로세스에 올리는 함수 / 올린 라이브러리에서 이름으로 심볼 주소를 찾는 함수.
> - **`mmap()`**: 파일이나 메모리를 프로세스 주소 공간에 매핑하는 시스템 콜. `dlopen()`이 라이브러리를 올릴 때 씁니다.
> - **copy-on-write**: 여러 프로세스가 같은 페이지를 공유하다가, 누군가 쓰는 순간 그 페이지만 복사해 주는 방식. `fork()`와 private 매핑이 이렇게 동작합니다.
> - **`$libdir`**: PostgreSQL이 공유 라이브러리를 두는 디렉터리(`pg_config --pkglibdir`). 이 빌드에서는 `/usr/local/pgsql/lib`입니다.

## extension을 이루는 파일들

extension 하나는 **control 파일**, **SQL 스크립트**, (C로 짠 경우) **공유 라이브러리**로 이루어집니다. SQL과 PL/pgSQL만으로 된 extension은 `.so` 없이 앞의 둘만 있습니다. 파일 위치는 `pg_config`로 확인합니다.

```console
$ pg_config --version --pkglibdir --sharedir --includedir-server --pgxs
PostgreSQL 18.6
/usr/local/pgsql/lib
/usr/local/pgsql/share
/usr/local/pgsql/include/server
/usr/local/pgsql/lib/pgxs/src/makefiles/pgxs.mk
```

`demo_ext`의 파일은 다음과 같습니다. 처음에는 버전 1.0만 있습니다.

```console
$ cat demo_ext.control
# demo_ext extension
comment = 'demo extension for extension internals'
default_version = '1.0'
module_pathname = '$libdir/demo_ext'
relocatable = true
$ cat demo_ext--1.0.sql
\echo Use "CREATE EXTENSION demo_ext" to load this file. \quit

CREATE FUNCTION demo_add(integer, integer) RETURNS integer
AS 'MODULE_PATHNAME', 'demo_add'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION demo_build() RETURNS text
AS 'MODULE_PATHNAME', 'demo_build'
LANGUAGE C STRICT;

CREATE FUNCTION demo_local_count() RETURNS bigint
AS 'MODULE_PATHNAME', 'demo_local_count'
LANGUAGE C STRICT;

CREATE FUNCTION demo_shared_count() RETURNS bigint
AS 'MODULE_PATHNAME', 'demo_shared_count'
LANGUAGE C STRICT;

CREATE TABLE demo_note (id int PRIMARY KEY, note text);
SELECT pg_catalog.pg_extension_config_dump('demo_note', '');
$ cat Makefile
MODULES = demo_ext
EXTENSION = demo_ext
DATA = demo_ext--1.0.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

control 파일에서 자주 쓰는 항목은 다음과 같습니다([`parse_extension_control_file()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L641)).

| 항목 | 뜻 |
|---|---|
| `default_version` | 버전을 지정하지 않은 `CREATE EXTENSION`이 설치할 버전 |
| `module_pathname` | 스크립트의 `MODULE_PATHNAME` 글자를 이 값으로 바꿈 |
| `relocatable` | 설치 후 `ALTER EXTENSION ... SET SCHEMA`로 스키마를 옮길 수 있는지 |
| `schema` | 설치할 스키마를 고정할 때 |
| `requires` | 먼저 설치되어 있어야 하는 다른 extension |
| `superuser` | 설치에 superuser가 필요한지 (기본 `true`) |
| `trusted` | superuser가 아니어도 설치할 수 있는지 ([권한 절](#권한-superuser와-trusted)) |

스크립트 첫 줄의 `\echo ... \quit`은 누가 psql로 이 파일을 직접 실행하는 것을 막는 줄입니다. `CREATE EXTENSION`은 `\echo`로 시작하는 줄을 지우고 실행합니다([`extension.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1340-L1349)).

C 소스의 핵심은 다음과 같습니다(전체는 약 170줄입니다).

```c
PG_MODULE_MAGIC_EXT(.name = "demo_ext", .version = DEMO_VERSION);

static uint64 local_queries = 0;          /* 프로세스마다 따로 있는 카운터 */
static DemoSharedState *demo_state = NULL; /* 공유 메모리의 카운터를 가리킴 */
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;

void
_PG_init(void)
{
	elog(LOG, "demo_ext %s: _PG_init in pid %d (shared_preload_libraries: %s)",
		 DEMO_VERSION, (int) getpid(),
		 process_shared_preload_libraries_in_progress ? "yes" : "no");

	DefineCustomBoolVariable("demo_ext.trace", ..., &demo_trace, false, PGC_USERSET, ...);
	MarkGUCPrefixReserved("demo_ext");

	prev_ExecutorEnd = ExecutorEnd_hook;   /* 원래 값을 저장하고 */
	ExecutorEnd_hook = demo_ExecutorEnd;   /* 내 함수로 바꾼다 */

	/* 공유 메모리는 postmaster가 만들 때만 요청할 수 있다 */
	if (process_shared_preload_libraries_in_progress)
	{
		prev_shmem_request_hook = shmem_request_hook;
		shmem_request_hook = demo_shmem_request;   /* RequestAddinShmemSpace() */
		prev_shmem_startup_hook = shmem_startup_hook;
		shmem_startup_hook = demo_shmem_startup;   /* ShmemInitStruct("demo_ext") */
	}
}

static void
demo_ExecutorEnd(QueryDesc *queryDesc)
{
	local_queries++;
	if (demo_state)
		pg_atomic_fetch_add_u64(&demo_state->queries, 1);
	if (demo_trace)
		ereport(NOTICE, (errmsg("demo_ext: %llu rows processed",
								(unsigned long long) queryDesc->estate->es_processed)));

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

PG_FUNCTION_INFO_V1(demo_add);
Datum
demo_add(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(PG_GETARG_INT32(0) + PG_GETARG_INT32(1));
}
```

`demo_build()`는 이 `.so`가 몇 버전으로 빌드되었는지 문자열로 돌려주고, `demo_local_count()`와 `demo_shared_count()`는 두 카운터 값을 돌려줍니다. `demo_shared_count()`는 공유 메모리가 없으면 오류를 냅니다. `demo_crash()`는 일부러 NULL 포인터에 씁니다.

설치는 root로 `make install`을 실행합니다. PGXS는 control 파일과 스크립트를 `share/extension/`에, `.so`를 `$libdir`에 복사할 뿐입니다. 여기까지는 DB에 아무 변화가 없습니다.

```console
$ make install
/usr/bin/mkdir -p '/usr/local/pgsql/share/extension'
/usr/bin/mkdir -p '/usr/local/pgsql/share/extension'
/usr/bin/mkdir -p '/usr/local/pgsql/lib'
/usr/bin/install -c -m 644 .//demo_ext.control '/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 644 .//demo_ext--1.0.sql  '/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 755  demo_ext.so '/usr/local/pgsql/lib/'
```

## CREATE EXTENSION이 하는 일

{{< diagram src="/diagrams/pg-create-extension.html" title="CREATE EXTENSION이 하는 일" height="600" caption="control 파일과 스크립트를 읽어 카탈로그를 채우고, LANGUAGE C 함수를 만들 때 .so를 dlopen합니다. 모두 한 트랜잭션 안에서 일어납니다." >}}

`CREATE EXTENSION`을 받은 backend는 다음 순서로 일합니다([`CreateExtension()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L2094), [`CreateExtensionInternal()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1784)).

1. **control 파일 찾기와 읽기**: `extension_control_path`에 적힌 디렉터리에서 `이름.control`을 찾습니다. 기본값 `$system`은 `share/extension/`입니다([`get_extension_control_directories()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L473)). 없으면 `extension "..." is not available` 오류입니다. 버전별 보조 control 파일(`이름--버전.control`)이 있으면 그것도 읽습니다.
2. **설치 경로 정하기**: 설치할 버전(지정이 없으면 `default_version`)의 스크립트가 있으면 그것을 쓰고, 없으면 있는 설치 스크립트에서 업데이트 스크립트를 이어 붙여 목표 버전까지 가는 가장 짧은 경로를 찾습니다([`find_install_path()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1729)).
3. **`pg_extension`에 행 넣기**: 스크립트를 실행하기 전에 먼저 extension 자신을 등록합니다([`InsertExtensionTuple()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1986)). 스크립트가 만드는 객체가 가리킬 대상이 있어야 하기 때문입니다.
4. **스크립트 읽고 바꾸기**: 스크립트를 읽어 `\echo` 줄을 지우고, `@extschema@`를 설치 스키마로, `MODULE_PATHNAME`을 control 파일의 `module_pathname`으로 바꿉니다([`execute_extension_script()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1196), 치환은 [L1373-L1434](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1373-L1434)). 실행하는 동안만 `search_path`를 설치 스키마로, `client_min_messages`를 `warning`으로, `check_function_bodies`를 `off`로 바꿔 둡니다.
5. **스크립트 실행**: `creating_extension = true`, `CurrentExtensionObject = <extension OID>`로 표시해 두고([L1319](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1319)) 스크립트의 SQL 문을 하나씩 실행합니다([`execute_sql_string()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1046)). 객체를 만드는 코드는 이 표시를 보고 새 객체에서 extension으로 가는 `pg_depend` 행(`deptype = 'e'`)을 추가합니다([`recordDependencyOnCurrentExtension()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/catalog/pg_depend.c#L206)). "extension의 멤버"라는 말의 실체가 이 행입니다.
6. **C 함수 검증**: `LANGUAGE C` 함수를 만들면 C 언어의 검증 함수 [`fmgr_c_validator()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/catalog/pg_proc.c#L795)가 불립니다. 이 함수는 라이브러리를 실제로 올려서 심볼이 있는지 확인합니다. 4번에서 `check_function_bodies`를 꺼 뒀지만 C 함수 검증은 이 설정을 무시합니다([pg_proc.c L808](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/catalog/pg_proc.c#L808-L811)). 이 검증을 거치면서 `CREATE EXTENSION`을 실행한 backend에는 `.so`가 올라오고 `_PG_init()`이 실행됩니다.

이 모든 일이 한 트랜잭션 안에서 일어납니다. 스크립트 중간에 오류가 나면 `pg_extension` 행과 만들던 객체가 모두 롤백됩니다. 다만 6번에서 프로세스에 올라온 `.so`는 롤백되지 않습니다. 라이브러리를 내리는 기능은 없습니다([`dfmgr.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L183-L186)).

#### strace로 보는 CREATE EXTENSION

접속 A를 열고 그 backend에 `strace`를 붙인 상태에서 `CREATE EXTENSION`을 실행했습니다. 먼저 실행 전의 상태입니다. `/proc/self/maps`는 backend 자신의 매핑 목록이라 `pg_read_file()`로 읽으면 SQL에서 바로 볼 수 있습니다.

```psql
A=# SELECT pg_backend_pid();
 pg_backend_pid 
----------------
            165
(1 row)

A=# SELECT name, default_version, installed_version, comment FROM pg_available_extensions WHERE name IN ('demo_ext', 'pg_stat_statements', 'pgcrypto') ORDER BY name;
        name        | default_version | installed_version |                                comment                                 
--------------------+-----------------+-------------------+------------------------------------------------------------------------
 demo_ext           | 1.0             |                   | demo extension for extension internals
 pg_stat_statements | 1.12            |                   | track planning and execution statistics of all SQL statements executed
(2 rows)

A=# SELECT count(*) AS mapped FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext%';
 mapped 
--------
      0
(1 row)

A=# SELECT * FROM pg_get_loaded_modules();
 module_name | version | file_name 
-------------+---------+-----------
(0 rows)
```

`pg_available_extensions`는 control 파일만 읽어서 보여 주는 뷰입니다(이 빌드는 OpenSSL 없이 만들어 `pgcrypto`가 없습니다). `demo_ext`가 보이지만 `installed_version`은 비어 있고 backend에는 아직 `.so`가 매핑되어 있지 않습니다. `pg_get_loaded_modules()`는 PG18에서 새로 생긴 함수로, 이 프로세스에 올라온 라이브러리 목록을 보여 줍니다([`extension.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L2975)).

```console
$ strace -p 165 -f -tt -e trace=openat,read,mmap,mprotect,close -o /tmp/create_ext.strace
```

```psql
A=# CREATE EXTENSION demo_ext;
CREATE EXTENSION
```

strace 결과 67줄 중 앞부분과, 카탈로그 파일(`base/5/...`)을 여는 줄을 줄인 결과입니다.

```console
$ cat /tmp/create_ext.strace
165   11:01:47.364224 openat(AT_FDCWD, "/usr/local/pgsql/share/extension/demo_ext.control", O_RDONLY) = 59
165   11:01:47.364503 read(59, "# demo_ext extension\ncomment = '"..., 8192) = 152
165   11:01:47.364633 read(59, "", 4096) = 0
165   11:01:47.364733 read(59, "", 8192) = 0
165   11:01:47.364826 close(59)         = 0
165   11:01:47.365033 openat(AT_FDCWD, "/usr/local/pgsql/share/extension/demo_ext--1.0.control", O_RDONLY) = -1 ENOENT (No such file or directory)
165   11:01:47.365205 openat(AT_FDCWD, "base/5/2685", O_RDWR|O_CLOEXEC) = 59
165   11:01:47.365644 openat(AT_FDCWD, "base/5/3079_fsm", O_RDWR|O_CLOEXEC) = 60
165   11:01:47.366096 openat(AT_FDCWD, "base/5/3079_vm", O_RDWR|O_CLOEXEC) = 61
165   11:01:47.366485 openat(AT_FDCWD, "base/5/2608_fsm", O_RDWR|O_CLOEXEC) = 62
165   11:01:47.366951 openat(AT_FDCWD, "base/5/2608", O_RDWR|O_CLOEXEC) = 63
...
165   11:01:47.369823 openat(AT_FDCWD, "/usr/local/pgsql/share/extension/demo_ext--1.0.sql", O_RDONLY) = 71
165   11:01:47.370011 read(71, "\\echo Use \"CREATE EXTENSION demo"..., 4096) = 624
165   11:01:47.370102 close(71)         = 0
...
165   11:01:47.371182 openat(AT_FDCWD, "base/5/1255_fsm", O_RDWR|O_CLOEXEC) = 74
165   11:01:47.371705 openat(AT_FDCWD, "base/5/1255_vm", O_RDWR|O_CLOEXEC) = 75
165   11:01:47.372210 openat(AT_FDCWD, "base/5/2682", O_RDWR|O_CLOEXEC) = 76
165   11:01:47.372780 openat(AT_FDCWD, "/usr/local/pgsql/lib/demo_ext.so", O_RDONLY|O_CLOEXEC) = 77
165   11:01:47.372893 read(77, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\200\f\0\0\0\0\0\0"..., 832) = 832
165   11:01:47.373063 mmap(NULL, 131264, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_DENYWRITE, 77, 0) = 0xffffaa30c000
165   11:01:47.373166 mprotect(0xffffaa30e000, 118784, PROT_NONE) = 0
165   11:01:47.373269 mmap(0xffffaa32b000, 8192, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 77, 0xf000) = 0xffffaa32b000
165   11:01:47.373378 close(77)         = 0
165   11:01:47.373498 mprotect(0xffffaa32b000, 4096, PROT_READ) = 0
165   11:01:47.374790 openat(AT_FDCWD, "base/5/16389", O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC, 0600) = 77
...
165   11:01:47.384251 openat(AT_FDCWD, "pg_wal/000000010000000000000001", O_RDWR|O_CLOEXEC) = 91
```

`base/5/<번호>`는 `postgres` DB(OID 5)의 카탈로그 파일입니다. 번호를 카탈로그 이름으로 바꿔 보면 다음과 같습니다.

```psql
postgres=# SELECT pg_relation_filenode(c.oid) AS filenode, c.relname FROM pg_class c WHERE pg_relation_filenode(c.oid) IN (3079, 1255, 2608, 1259, 1247) ORDER BY 1;
 filenode |   relname    
----------+--------------
     1247 | pg_type
     1255 | pg_proc
     1259 | pg_class
     2608 | pg_depend
     3079 | pg_extension
(5 rows)
```

strace의 순서가 위 목록과 그대로 맞습니다.

1. `demo_ext.control`을 열어 읽습니다(152바이트). 보조 control 파일 `demo_ext--1.0.control`은 없어서 `ENOENT`입니다.
2. 스크립트보다 먼저 extension 행을 넣으므로 `pg_extension`(3079)과 `pg_depend`(2608)를 엽니다.
3. `demo_ext--1.0.sql`을 읽습니다(624바이트).
4. 첫 `CREATE FUNCTION`이 `pg_proc`(1255)에 행을 넣은 직후 `demo_ext.so`를 엽니다. ELF 헤더 832바이트를 읽고, 파일을 `mmap()`하고, 가운데 틈을 `PROT_NONE`으로, 데이터 영역을 `PROT_READ|PROT_WRITE`로 다시 매핑합니다. 마지막 `mprotect(..., PROT_READ)`는 동적 링커가 심볼 주소를 채운 영역을 읽기 전용으로 바꾸는 것(RELRO)입니다.
5. `.so`를 여는 것은 한 번뿐입니다. 나머지 `CREATE FUNCTION` 세 개는 이미 올라온 라이브러리를 그대로 씁니다.
6. `16389`, `16393` 같은 새 파일은 스크립트의 `CREATE TABLE demo_note`가 만든 테이블과 인덱스입니다. 마지막에 커밋하며 WAL에 씁니다.

#### 서버 로그의 _PG_init

```console
$ cat /home/postgres/server.log
...
2026-09-26 11:01:47.373 UTC [165] LOG:  demo_ext 1.0: _PG_init in pid 165 (shared_preload_libraries: no)
2026-09-26 11:01:47.373 UTC [165] CONTEXT:  SQL statement "CREATE FUNCTION demo_add(integer, integer) RETURNS integer
	AS '$libdir/demo_ext', 'demo_add'
	LANGUAGE C STRICT IMMUTABLE"
	extension script file "demo_ext--1.0.sql", near line 3
2026-09-26 11:01:47.373 UTC [165] STATEMENT:  CREATE EXTENSION demo_ext;
```

`_PG_init()`이 backend 165에서 실행되었고, `CONTEXT`가 그 시점을 정확히 알려 줍니다. 스크립트 3번째 줄의 첫 `CREATE FUNCTION`이고, 스크립트의 `'MODULE_PATHNAME'`이 이미 `'$libdir/demo_ext'`로 바뀌어 있습니다.

#### backend 주소 공간에 생긴 매핑

```psql
A=# SELECT l FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext%';
                                                     l                                                     
-----------------------------------------------------------------------------------------------------------
 ffffaa30c000-ffffaa30e000 r-xp 00000000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so
 ffffaa30e000-ffffaa32b000 ---p 00002000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so
 ffffaa32b000-ffffaa32c000 r--p 0000f000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so
 ffffaa32c000-ffffaa32d000 rw-p 00010000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so
(4 rows)

A=# SELECT * FROM pg_get_loaded_modules();
 module_name | version |  file_name  
-------------+---------+-------------
 demo_ext    | 1.0     | demo_ext.so
(1 row)
```

[앞에서 본](#dlopen은-파일을-메모리에-매핑한다) 네 영역이 strace의 `mmap()` 주소 그대로 보입니다. 다섯째 열 `1306724`는 파일의 **inode 번호**입니다. [라이브러리를 교체할 때](#라이브러리-파일을-바꾸면) 이 번호가 중요해집니다. `pg_get_loaded_modules()`의 `version`은 C 소스의 `PG_MODULE_MAGIC_EXT`에 적은 값입니다.

#### 카탈로그에 남은 것

```psql
A=# SELECT oid, extname, extversion, extrelocatable, extnamespace::regnamespace, extconfig::regclass[] FROM pg_extension;
  oid  | extname  | extversion | extrelocatable | extnamespace |  extconfig  
-------+----------+------------+----------------+--------------+-------------
 13554 | plpgsql  | 1.0        | f              | pg_catalog   | 
 16384 | demo_ext | 1.0        | t              | public       | {demo_note}
(2 rows)

A=# SELECT proname, (SELECT lanname FROM pg_language WHERE oid = prolang) AS lang, probin, prosrc FROM pg_proc WHERE proname IN ('demo_add', 'demo_build', 'demo_local_count', 'demo_shared_count') ORDER BY proname;
      proname      | lang |      probin      |      prosrc       
-------------------+------+------------------+-------------------
 demo_add          | c    | $libdir/demo_ext | demo_add
 demo_build        | c    | $libdir/demo_ext | demo_build
 demo_local_count  | c    | $libdir/demo_ext | demo_local_count
 demo_shared_count | c    | $libdir/demo_ext | demo_shared_count
(4 rows)

A=# SELECT classid::regclass, pg_describe_object(classid, objid, objsubid) AS member, deptype FROM pg_depend WHERE refclassid = 'pg_extension'::regclass AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'demo_ext') ORDER BY 1, 2;
 classid  |               member               | deptype 
----------+------------------------------------+---------
 pg_type  | type demo_note                     | e
 pg_type  | type demo_note[]                   | e
 pg_proc  | function demo_add(integer,integer) | e
 pg_proc  | function demo_build()              | e
 pg_proc  | function demo_local_count()        | e
 pg_proc  | function demo_shared_count()       | e
 pg_class | table demo_note                    | e
(7 rows)
```

- `pg_extension`: 이름, 버전, 설치 스키마와 함께 `extconfig`에 `demo_note`가 들어 있습니다. 스크립트의 `pg_extension_config_dump('demo_note', '')`가 이 테이블을 "사용자가 데이터를 넣는 설정 테이블"로 표시한 것입니다([pg_dump 절](#pg_dump와-drop-extension)).
- `pg_proc`: C 함수의 `probin`(라이브러리 파일)과 `prosrc`(심볼 이름)입니다. 함수를 부를 때 [이 두 값으로 `.so`와 심볼을 찾습니다](#c-함수가-호출되기까지).
- `pg_depend`: 스크립트가 만든 객체가 모두 `deptype = 'e'`로 extension을 가리킵니다. 테이블을 만들 때 자동으로 생긴 행 타입(`demo_note`, `demo_note[]`)도 들어 있습니다. 기본 키 인덱스는 테이블에 딸린 객체라 여기 없습니다.

## C 함수가 호출되기까지

SQL에서 `demo_add(1, 2)`를 부르면 함수 관리자(fmgr)가 `pg_proc` 행을 보고 실제 C 함수 주소를 찾습니다. 언어가 `c`이면 [`fmgr_info_C_lang()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/fmgr.c#L349)이 불리고 다음 순서로 동적 로더(dfmgr)를 거칩니다.

1. **이 backend에서 찾아 둔 적이 있는가**: 한 번 찾은 함수 주소는 backend의 해시 테이블에 캐시합니다. 두 번째 호출부터는 아래 과정을 건너뜁니다.
2. **파일 이름 풀기** ([`expand_dynamic_library_name()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L466)): `probin`에 `/`가 있으면 `$libdir`을 실제 경로로 바꾸고, 없으면 `dynamic_library_path`에 적힌 디렉터리에서 찾습니다. 파일이 없으면 끝에 `.so`를 붙여 다시 찾습니다. `'$libdir/demo_ext'`는 `/usr/local/pgsql/lib/demo_ext.so`가 됩니다.
3. **이미 올린 파일인가** ([`internal_load_library()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L189)): backend마다 올린 라이브러리 목록이 있습니다. 먼저 **경로 문자열**로 찾고, 없으면 `stat()`으로 inode를 얻어 같은 파일을 다른 경로로 올린 적이 있는지 봅니다. 찾으면 해당 핸들을 그대로 씁니다.
4. **`dlopen(RTLD_NOW | RTLD_GLOBAL)`** ([L244](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L244)): 처음 보는 파일이면 올립니다. undefined 심볼은 [`postgres` 실행 파일이 내보낸 심볼](#서버-실행-파일이-심볼을-내보낸다)과 이때 연결됩니다.
5. **magic block 검사** ([L257-L291](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L257-L291)): `dlsym("Pg_magic_func")`로 magic block을 꺼내 서버와 비교합니다. 없거나 다르면 `dlclose()`하고 오류를 냅니다.
6. **`_PG_init()` 호출** ([L297](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L297)): 라이브러리에 `_PG_init`이 있으면 부릅니다. 파일 하나당 프로세스마다 딱 한 번입니다.
7. **심볼 찾기**: `dlsym(prosrc)`로 함수 주소를, `dlsym("pg_finfo_" + prosrc)`로 호출 규약 정보를 찾습니다([`fetch_finfo_record()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/fmgr.c#L455)). `PG_FUNCTION_INFO_V1(demo_add)`가 만든 `pg_finfo_demo_add`는 "버전 1 호출 규약"이라는 뜻의 `{ 1 }`을 돌려줍니다.

### magic block: 서버와 라이브러리의 ABI 확인

C 라이브러리는 서버의 구조체 크기나 상수 값을 컴파일할 때 그대로 박아 넣습니다. 다른 major 버전의 헤더로 빌드한 라이브러리를 올리면 구조체 모양이 달라 메모리를 엉뚱하게 읽게 됩니다. 이를 막는 것이 **magic block**입니다. `PG_MODULE_MAGIC` 매크로는 빌드할 때의 값을 담은 구조체를 돌려주는 `Pg_magic_func()`를 만들고, 로더는 이 값을 서버 자신의 값과 `memcmp()`로 비교합니다([`fmgr.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/fmgr.h#L466-L484)).

| 필드 | 값 |
|---|---|
| `version` | major 버전 (`PG_VERSION_NUM / 100`, 여기서는 18) |
| `funcmaxargs` | 함수 인자 최대 개수 `FUNC_MAX_ARGS` |
| `indexmaxkeys` | 인덱스 키 최대 개수 `INDEX_MAX_KEYS` |
| `namedatalen` | 이름 길이 `NAMEDATALEN` |
| `float8byval` | `float8`을 값으로 넘기는지 |
| `abi_extra` | 파생 제품이 ABI를 구별하려고 쓰는 문자열 |

PG18에서는 `PG_MODULE_MAGIC_EXT(.name = ..., .version = ...)`로 모듈 이름과 버전도 넣을 수 있게 되었고([`fmgr.h`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/fmgr.h#L538)), 이 값이 `pg_get_loaded_modules()`에 나옵니다. 이름과 버전은 비교에 쓰이지 않는 설명용 값입니다.

#### 라이브러리를 올리다 실패하는 네 가지 경우

magic block을 빠뜨린 모듈(`nomagic.so`)과, 같은 소스를 PostgreSQL 17.11 헤더로 빌드한 모듈(`abi_demo.so`)을 만들어 PG18에서 올려 봤습니다. `probin`에는 이렇게 절대 경로를 써도 됩니다.

```console
$ nm -D --defined-only nomagic/nomagic.so
00000000000005a0 T nomagic_one
0000000000000590 T pg_finfo_nomagic_one
$ make -C abi17 PG_CONFIG=/usr/local/pgsql17/bin/pg_config
$ nm -D --defined-only abi17/abi_demo.so
00000000000005c0 T Pg_magic_func
00000000000005e0 T abi_demo_one
00000000000005d0 T pg_finfo_abi_demo_one
```

```psql
postgres=# CREATE FUNCTION nomagic_one() RETURNS int AS '/home/postgres/lab/nomagic/nomagic.so', 'nomagic_one' LANGUAGE C;
ERROR:  incompatible library "/home/postgres/lab/nomagic/nomagic.so": missing magic block
HINT:  Extension libraries are required to use the PG_MODULE_MAGIC macro.
postgres=# CREATE FUNCTION abi_demo_one() RETURNS int AS '/home/postgres/lab/abi17/abi_demo.so', 'abi_demo_one' LANGUAGE C;
ERROR:  incompatible library "/home/postgres/lab/abi17/abi_demo.so": version mismatch
DETAIL:  Server is version 18, library is version 17.
postgres=# CREATE FUNCTION demo_nosuch() RETURNS int AS '$libdir/demo_ext', 'demo_nosuch' LANGUAGE C;
ERROR:  could not find function "demo_nosuch" in file "/usr/local/pgsql/lib/demo_ext.so"
postgres=# CREATE FUNCTION demo_nolib() RETURNS int AS '$libdir/demo_extx', 'demo_add' LANGUAGE C;
ERROR:  could not access file "demo_extx": No such file or directory
```

| 오류 | 실패한 단계 |
|---|---|
| `missing magic block` | 5. `dlsym("Pg_magic_func")`이 없음 |
| `version mismatch` | 5. magic block의 major 버전이 다름. 17용 모듈은 `dlopen()` 자체는 성공했지만 여기서 걸렸습니다 |
| `could not find function` | 7. `dlsym(prosrc)`가 없음 |
| `could not access file` | 3. 파일 이름을 풀지 못해 원래 문자열 그대로 `stat()`했다가 실패 |

C 함수 검증기가 함수를 만들 때 라이브러리를 올려 보므로 오류는 모두 `CREATE FUNCTION` 단계에서 났습니다.

#### 다른 backend는 처음 부를 때 올린다

A가 `CREATE EXTENSION`을 했으니 A에는 `.so`가 올라와 있습니다. 새 접속 B는 어떨까요.

```psql
B=# SELECT pg_backend_pid();
 pg_backend_pid 
----------------
           9320
(1 row)

B=# SELECT count(*) AS mapped FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so%';
 mapped 
--------
      0
(1 row)

B=# SELECT * FROM pg_get_loaded_modules();
 module_name | version | file_name 
-------------+---------+-----------
(0 rows)

B=# SELECT demo_add(1, 2);
 demo_add 
----------
        3
(1 row)

B=# SELECT count(*) AS mapped FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so%';
 mapped 
--------
      4
(1 row)
```

```console
$ grep -A1 "_PG_init" /home/postgres/server.log
2026-09-26 11:01:47.373 UTC [165] LOG:  demo_ext 1.0: _PG_init in pid 165 (shared_preload_libraries: no)
2026-09-26 11:01:47.373 UTC [165] CONTEXT:  SQL statement "CREATE FUNCTION demo_add(integer, integer) RETURNS integer
--
2026-09-26 11:02:20.705 UTC [9305] LOG:  demo_ext 1.0: _PG_init in pid 9305 (shared_preload_libraries: no)
2026-09-26 11:02:20.705 UTC [9305] STATEMENT:  CREATE FUNCTION demo_nosuch() RETURNS int AS '$libdir/demo_ext', 'demo_nosuch' LANGUAGE C;
--
2026-09-26 11:02:25.807 UTC [9320] LOG:  demo_ext 1.0: _PG_init in pid 9320 (shared_preload_libraries: no)
2026-09-26 11:02:25.807 UTC [9320] STATEMENT:  SELECT demo_add(1, 2);
```

extension은 DB에 이미 설치되어 있지만 B에는 `demo_add()`를 처음 부를 때까지 `.so`가 없었습니다. 처음 부르는 순간 B가 직접 `dlopen()`했고, `_PG_init()`도 B에서 따로 한 번 실행되었습니다. 가운데의 9305는 [앞 절](#라이브러리를-올리다-실패하는-네-가지-경우)에서 오류 실험을 한 접속입니다. `demo_nosuch`를 찾으려고 `demo_ext.so`를 올렸기 때문에, 함수 생성은 실패했지만 `_PG_init()`은 실행되었습니다. **extension 설치는 DB 단위이고, 라이브러리 로드는 프로세스 단위**입니다.

`LOAD` 명령으로 함수를 부르지 않고 미리 올릴 수도 있습니다([`load_file()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L149)). 이때도 `_PG_init()`은 그 backend에서 실행됩니다([다음 절](#_pg_init과-hook)의 실습).

## _PG_init과 hook

`.so`가 올라오기만 해서는 SQL로 부를 수 있는 함수가 늘어날 뿐입니다. pg_stat_statements나 auto_explain처럼 모든 쿼리에 끼어드는 extension은 `_PG_init()`에서 **hook**을 겁니다.

hook은 서버 곳곳에 있는 **함수 포인터 전역 변수**입니다. 서버는 어떤 지점에 이르면 이 변수가 NULL이 아닌지 보고 값이 있으면 변수에 담긴 함수를 대신 부릅니다. 예를 들어 실행기의 마지막 단계는 이렇게 생겼습니다([`execMain.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/executor/execMain.c#L466-L472)).

```c
void
ExecutorEnd(QueryDesc *queryDesc)
{
	if (ExecutorEnd_hook)
		(*ExecutorEnd_hook) (queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}
```

[앞에서](#postgres-실행-파일의-동적-심볼) `nm`으로 본 `B ExecutorEnd_hook`이 바로 이 변수입니다. `demo_ext`의 `_PG_init()`은 원래 값을 `prev_ExecutorEnd`에 저장하고 자기 함수 주소를 써넣습니다. 자기 일을 마친 뒤에는 저장해 둔 이전 hook을, 없으면 원래 함수 `standard_ExecutorEnd()`를 부릅니다. 여러 extension이 같은 hook을 걸면 이렇게 사슬이 됩니다. `_PG_init()`이 나중에 실행된 extension이 사슬의 맨 앞에 섭니다. pg_stat_statements도 같은 방식입니다([`pg_stat_statements.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/contrib/pg_stat_statements/pg_stat_statements.c#L484-L485)). PG18 헤더에는 이런 hook 타입이 31개 정의되어 있습니다(`src/include`에서 `typedef ..._hook_type`을 센 값).

hook 변수도, `.so`의 `static` 변수도 결국 **프로세스의 전역 변수**라서 hook은 `_PG_init()`이 실행된 프로세스에만 걸립니다.

`_PG_init()`에서는 extension 전용 설정(custom GUC)도 등록합니다. `DefineCustomBoolVariable("demo_ext.trace", ...)`는 `demo_ext.trace`라는 설정을 만들고, `MarkGUCPrefixReserved("demo_ext")`는 `demo_ext.`로 시작하는 다른 이름을 쓰지 못하게 막습니다.

#### hook과 custom GUC의 동작

`demo_ext`를 이미 올린 B에서 설정을 켜 봅니다.

```psql
B=# SET demo_ext.trace = on;
SET
B=# SELECT count(*) FROM pg_class WHERE relkind = 'r';
NOTICE:  demo_ext: 1 rows processed
 count 
-------
    69
(1 row)

B=# SET demo_ext.tarce = on;
ERROR:  invalid configuration parameter name "demo_ext.tarce"
DETAIL:  "demo_ext" is a reserved prefix.
```

모든 쿼리가 끝날 때 `demo_ExecutorEnd()`가 불려 `NOTICE`가 나옵니다. 오타 난 이름은 예약된 접두어라 거부됩니다. 아직 `demo_ext`를 올리지 않은 새 접속 C에서는 다릅니다.

```psql
C=# SET demo_ext.tarce = on;
SET
C=# SHOW demo_ext.tarce;
 demo_ext.tarce 
----------------
 on
(1 row)

C=# LOAD 'demo_ext';
WARNING:  invalid configuration parameter name "demo_ext.tarce", removing it
DETAIL:  "demo_ext" is now a reserved prefix.
LOAD
C=# SELECT * FROM pg_get_loaded_modules();
 module_name | version |  file_name  
-------------+---------+-------------
 demo_ext    | 1.0     | demo_ext.so
(1 row)
```

라이브러리가 올라오기 전에는 서버가 `demo_ext.tarce`가 맞는 이름인지 알 방법이 없어서 점이 들어간 이름은 일단 **임시 설정(placeholder)** 으로 받아 둡니다. `LOAD`로 `_PG_init()`이 실행되고 나서야 오타를 알아채고 경고와 함께 지웁니다. `postgresql.conf`에 extension 설정을 적어 둘 때도 오타가 이렇게 조용히 무시될 수 있습니다.

#### 프로세스마다 따로 있는 static 변수

`local_queries`는 `.so` 안의 `static` 변수이고 쿼리가 끝날 때마다 1씩 늘어납니다. A와 B에서 값을 읽어 봤습니다.

```psql
B=# SELECT demo_local_count();
 demo_local_count 
------------------
                3
(1 row)

B=# SELECT demo_local_count();
 demo_local_count 
------------------
                4
(1 row)

B=# SELECT demo_shared_count();
ERROR:  demo_ext must be loaded via "shared_preload_libraries"

A=# SELECT demo_local_count();
 demo_local_count 
------------------
                6
(1 row)
```

같은 `.so`, 같은 변수인데 A는 6, B는 4입니다. [private 매핑](#dlopen은-파일을-메모리에-매핑한다)이라 변수 영역이 프로세스마다 따로 있습니다(값은 라이브러리를 올린 뒤 끝난 쿼리 수입니다. 지금 실행 중인 쿼리는 아직 세지 않았습니다). 모든 backend가 함께 보는 값을 두려면 공유 메모리가 필요한데, `demo_shared_count()`는 공유 메모리가 없다며 오류를 냅니다.

## shared_preload_libraries: postmaster가 먼저 올리는 경우

{{< diagram src="/diagrams/pg-extension-loading.html" title="공유 라이브러리가 프로세스에 올라오는 두 경로" height="640" caption="shared_preload_libraries에 넣으면 postmaster가 시작할 때 한 번 올리고 자식이 fork로 물려받습니다. 넣지 않으면 backend마다 처음 쓸 때 따로 올립니다." >}}

`shared_preload_libraries`에 적은 라이브러리는 postmaster가 시작할 때 올립니다. 순서가 중요합니다([`PostmasterMain()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L932)).

1. [`process_shared_preload_libraries()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/miscinit.c#L1903): 라이브러리를 올리고 `_PG_init()`을 부릅니다. 이 동안만 `process_shared_preload_libraries_in_progress`가 `true`입니다.
2. [`process_shmem_requests()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L961): `_PG_init()`이 걸어 둔 `shmem_request_hook`을 불러 필요한 공유 메모리 크기를 모읍니다(`RequestAddinShmemSpace()`).
3. [`CreateSharedMemoryAndSemaphores()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L1003): 모은 크기로 공유 메모리를 만들고, `shmem_startup_hook`에서 extension이 자기 영역을 초기화합니다(`ShmemInitStruct()`).
4. 그 뒤로 만드는 모든 자식 프로세스는 `fork()`로 라이브러리 매핑, hook 포인터, 공유 메모리를 물려받습니다.

공유 메모리는 2번과 3번을 거쳐 한 번 만들어지고 나중에 늘릴 수 없으니, 공유 메모리가 필요한 extension은 반드시 여기 들어가야 합니다. pg_stat_statements의 `_PG_init()`은 preload 중이 아니면 아무것도 하지 않고 바로 돌아가고([`pg_stat_statements.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/contrib/pg_stat_statements/pg_stat_statements.c#L380-L396)), 함수가 불리면 오류를 냅니다.

#### CREATE EXTENSION은 되는데 조회가 안 되는 이유

```psql
A=# CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION
A=# SELECT count(*) FROM pg_stat_statements;
ERROR:  pg_stat_statements must be loaded via "shared_preload_libraries"
```

`CREATE EXTENSION`은 파일을 읽어 카탈로그를 채우는 일이라 preload 여부와 상관없이 성공합니다. C 함수 검증 때 `.so`도 올라오지만 `_PG_init()`이 preload 중이 아닌 것을 보고 그냥 돌아갑니다. 공유 메모리가 없으니 뷰를 조회하면 오류가 납니다.

#### 운영에서는: shared_preload_libraries를 잘못 적으면 서버가 뜨지 않는다

두 라이브러리를 preload하려고 이렇게 적었다가 서버가 뜨지 않았습니다.

```psql
postgres=# ALTER SYSTEM SET shared_preload_libraries = 'demo_ext, pg_stat_statements';
ALTER SYSTEM
```

```console
$ pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
...
pg_ctl: could not start server
Examine the log output.
$ tail -2 /home/postgres/server.log
2026-09-26 11:03:02.250 UTC [10095] FATAL:  could not access file "demo_ext, pg_stat_statements": No such file or directory
2026-09-26 11:03:02.250 UTC [10095] LOG:  database system is shut down
$ cat $PGDATA/postgresql.auto.conf
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
shared_preload_libraries = '"demo_ext, pg_stat_statements"'
$ postgres -D $PGDATA -C shared_preload_libraries
"demo_ext, pg_stat_statements"
```

`shared_preload_libraries`는 목록형 설정입니다. `ALTER SYSTEM`에 작은따옴표 하나로 묶어 넘기면 쉼표까지 포함한 문자열 하나가 원소 하나가 되어 큰따옴표로 감싸져 저장됩니다. postmaster는 `demo_ext, pg_stat_statements`라는 이름의 파일을 찾다가 실패했습니다([`load_libraries()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/miscinit.c#L1851)). preload 실패는 곧 **서버 시작 실패**이고, 서버가 안 떠 있으니 `ALTER SYSTEM`으로 되돌릴 수도 없습니다. `postgresql.auto.conf`에서 그 줄을 직접 지우고 서버를 띄운 뒤 따옴표 없이 다시 설정했습니다.

```psql
postgres=# ALTER SYSTEM SET shared_preload_libraries = demo_ext, pg_stat_statements;
ALTER SYSTEM
```

```console
$ cat $PGDATA/postgresql.auto.conf
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
shared_preload_libraries = 'demo_ext, pg_stat_statements'
```

라이브러리 파일이 없는 서버(패키지를 설치하지 않은 새 서버나 standby)에 같은 설정 파일을 복사할 때도 똑같이 서버가 뜨지 않습니다. `postgres -C shared_preload_libraries`로 재시작 전에 값을 확인하는 습관이 도움이 됩니다.

#### postmaster의 _PG_init과 자식 프로세스

`shared_preload_libraries = 'demo_ext'`로 재시작한 뒤의 모습입니다.

```console
$ PM=$(head -1 $PGDATA/postmaster.pid); echo $PM
9751
$ grep "_PG_init" /home/postgres/server.log | tail -1
2026-09-26 11:02:45.013 UTC [9751] LOG:  demo_ext 1.0: _PG_init in pid 9751 (shared_preload_libraries: yes)
$ for p in $PM $(pgrep -P $PM); do printf "%6s %-45s %s\n" $p "$(tr "\0" " " < /proc/$p/cmdline | cut -c1-45)" "$(grep -c demo_ext.so /proc/$p/maps)"; done
  9751 /usr/local/pgsql/bin/postgres -D /var/lib/pos 4
  9752 postgres: io worker 0                         4
  9753 postgres: io worker 1                         4
  9754 postgres: io worker 2                         4
  9755 postgres: checkpointer                        4
  9756 postgres: background writer                   4
  9758 postgres: walwriter                           4
  9759 postgres: autovacuum launcher                 4
  9760 postgres: logical replication launcher        4
```

`_PG_init()`이 postmaster(9751)에서 `shared_preload_libraries: yes`로 한 번 실행되었습니다. 마지막 열은 각 프로세스의 `maps`에서 `demo_ext.so` 줄을 센 값입니다. postmaster가 올린 뒤에 fork한 백그라운드 프로세스들도 모두 네 영역을 갖고 있습니다. checkpointer나 walwriter는 `demo_ext`를 쓸 일이 없지만 fork로 물려받았습니다.

새 접속이 생길 때 postmaster를 strace로 봤습니다.

```console
$ strace -p 9751 -f -e trace=clone,clone3,fork,execve,openat -o /tmp/fork.strace
```

```psql
A=# SELECT pg_backend_pid();
 pg_backend_pid 
----------------
           9844
(1 row)
```

```console
$ grep -vE "base/|global/|pg_|\.conf" /tmp/fork.strace
9751  clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID|SIGCHLD, child_tidptr=0xffffab110ef0) = 9844
9844  openat(AT_FDCWD, "/dev/urandom", O_RDONLY) = 5
9844  openat(AT_FDCWD, "/dev/urandom", O_RDONLY) = 7
9844  openat(AT_FDCWD, "/dev/shm/PostgreSQL.3186032154", O_RDWR|O_NOFOLLOW|O_CLOEXEC) = 8
$ grep -c "demo_ext" /tmp/fork.strace
0
$ grep -c "_PG_init" /home/postgres/server.log
5
```

postmaster가 `clone()`(glibc의 `fork()`)으로 backend 9844를 만들었고, `execve()`는 없습니다. 라이브러리가 이미 부모의 주소 공간에 있었으니 새 backend는 `demo_ext.so`를 한 번도 열지 않았고, 서버 로그의 `_PG_init` 줄 수도 그대로입니다.

주소까지 같은지 pg_stat_statements로 확인해 봤습니다(`shared_preload_libraries = 'demo_ext, pg_stat_statements'` 상태).

```console
$ grep pg_stat_statements.so /proc/10122/maps
ffff8d30f000-ffff8d317000 r-xp 00000000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d317000-ffff8d32e000 ---p 00008000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d32e000-ffff8d32f000 r--p 0000f000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d32f000-ffff8d330000 rw-p 00010000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
$ grep pg_stat_statements.so /proc/10148/maps
ffff8d30f000-ffff8d317000 r-xp 00000000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d317000-ffff8d32e000 ---p 00008000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d32e000-ffff8d32f000 r--p 0000f000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
ffff8d32f000-ffff8d330000 rw-p 00010000 00:49 1274832                    /usr/local/pgsql/lib/pg_stat_statements.so
```

postmaster(10122)와 backend(10148)의 매핑이 주소와 inode까지 똑같습니다. `fork()`가 주소 공간을 그대로 복제했다는 뜻입니다.

#### 공유 메모리의 카운터

preload한 상태에서는 `demo_shared_count()`가 동작합니다. 두 접속에서 번갈아 읽어 봤습니다.

```psql
A=# SELECT * FROM pg_get_loaded_modules();
 module_name | version |  file_name  
-------------+---------+-------------
 demo_ext    | 1.0     | demo_ext.so
(1 row)

A=# SELECT demo_local_count(), demo_shared_count();
 demo_local_count | demo_shared_count 
------------------+-------------------
                2 |                 2
(1 row)

B=# SELECT demo_local_count(), demo_shared_count();
 demo_local_count | demo_shared_count 
------------------+-------------------
                0 |                 3
(1 row)

B=# SELECT demo_local_count(), demo_shared_count();
 demo_local_count | demo_shared_count 
------------------+-------------------
                1 |                 4
(1 row)

A=# SELECT demo_local_count(), demo_shared_count();
 demo_local_count | demo_shared_count 
------------------+-------------------
                3 |                 5
(1 row)

A=# SELECT name, size, allocated_size FROM pg_shmem_allocations WHERE name = 'demo_ext';
   name   | size | allocated_size 
----------+------+----------------
 demo_ext |    8 |            128
(1 row)
```

`demo_local_count()`는 A와 B가 따로 세고, `demo_shared_count()`는 두 접속의 쿼리를 합쳐서 셉니다. `pg_shmem_allocations`에 `ShmemInitStruct("demo_ext", ...)`로 잡은 8바이트(`pg_atomic_uint64` 하나)가 보입니다. `pg_get_loaded_modules()`에 A가 따로 올리지 않은 `demo_ext`가 처음부터 있는 것도 fork로 물려받은 라이브러리 목록 때문입니다.

pg_stat_statements도 preload하고 재시작하면 조회가 됩니다.

```psql
postgres=# SHOW shared_preload_libraries;
   shared_preload_libraries   
------------------------------
 demo_ext, pg_stat_statements
(1 row)

postgres=# SELECT count(*) > 0 AS has_rows FROM pg_stat_statements;
 has_rows 
----------
 t
(1 row)

postgres=# SELECT * FROM pg_get_loaded_modules();
    module_name     | version |       file_name       
--------------------+---------+-----------------------
 demo_ext           | 1.0     | demo_ext.so
 pg_stat_statements | 18.6    | pg_stat_statements.so
(2 rows)

postgres=# SELECT name, size FROM pg_shmem_allocations WHERE name LIKE 'pg_stat_statements%' OR name = 'demo_ext' ORDER BY name;
          name           | size 
-------------------------+------
 demo_ext                |    8
 pg_stat_statements      |   64
 pg_stat_statements hash | 2896
(3 rows)
```

pg_stat_statements의 라이브러리 버전은 18.6이고, SQL 쪽 extension 버전은 1.12입니다([앞의 `pg_available_extensions`](#strace로-보는-create-extension)). contrib 모듈은 `PG_MODULE_MAGIC_EXT(.version = PG_VERSION)`로 서버 버전을 라이브러리 버전으로 씁니다([`pg_stat_statements.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/contrib/pg_stat_statements/pg_stat_statements.c#L74-L77)). **라이브러리 버전과 extension 버전은 별개**라는 점은 [업데이트 절](#alter-extension-update와-라이브러리-교체)에서 다시 중요해집니다.

### 라이브러리를 올리는 방법 정리

| 방법 | 누가, 언제 | `_PG_init` 실행 | 공유 메모리 요청 | 반영 |
|---|---|---|---|---|
| `shared_preload_libraries` | postmaster, 서버 시작 때 | postmaster에서 한 번 | 가능 | 재시작 |
| `session_preload_libraries` | backend, 접속할 때 ([`postinit.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/postinit.c#L1228)) | 접속마다 | 불가 | 새 접속부터 |
| `local_preload_libraries` | backend, 접속할 때. `$libdir/plugins/`의 파일만 | 접속마다 | 불가 | 새 접속부터 |
| `LOAD` | 그 backend, 명령을 실행할 때 | 그 backend에서 | 불가 | 즉시 |
| 첫 함수 호출 (`CREATE FUNCTION` 검증 포함) | 그 backend, 처음 필요할 때 | 그 backend에서 | 불가 | 즉시 |

`session_preload_libraries`는 [auto_explain](https://www.postgresql.org/docs/18/auto-explain.html)처럼 공유 메모리는 필요 없지만 모든 세션에 hook을 걸고 싶을 때 씁니다. 재시작 없이 reload만으로 새 접속부터 적용됩니다.

```psql
postgres=# ALTER SYSTEM SET session_preload_libraries = demo_ext;
ALTER SYSTEM
postgres=# SELECT pg_reload_conf();
 pg_reload_conf 
----------------
 t
(1 row)
```

```console
$ grep -E 'parameter "session_preload_libraries" changed to "demo_ext"|_PG_init' /home/postgres/server.log | tail -2
2026-09-26 11:03:43.750 UTC [10509] LOG:  parameter "session_preload_libraries" changed to "demo_ext"
2026-09-26 11:03:44.757 UTC [11137] LOG:  demo_ext 1.1: _PG_init in pid 11137 (shared_preload_libraries: no)
```

새 접속(11137)이 쿼리를 보내기 전, 접속하는 단계에서 `_PG_init()`이 실행되었습니다. 앞의 로그와 달리 `STATEMENT` 줄이 없습니다.

## ALTER EXTENSION UPDATE와 라이브러리 교체

extension을 새 버전으로 올리는 일은 두 부분으로 나뉩니다.

- **파일 교체**: 패키지 관리자나 `make install`이 새 control 파일, 업데이트 스크립트, 새 `.so`를 디스크에 씁니다. DB와 프로세스는 이 사실을 모릅니다.
- **카탈로그 업데이트**: `ALTER EXTENSION ... UPDATE`가 업데이트 스크립트(`이름--이전--다음.sql`)를 실행해 객체를 고치고 `pg_extension.extversion`을 바꿉니다([`ExecAlterExtensionStmt()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L3408)). DB마다 따로 해야 합니다.

그리고 세 번째로, **이미 떠 있는 프로세스가 어떤 `.so`를 쓰고 있는가**가 따로 있습니다. `demo_ext`를 1.0에서 1.1로 올리며 이 셋이 어긋나는 모습을 봅니다. 1.1은 함수 `demo_sub()`를 추가합니다.

```console
$ cat demo_ext--1.0--1.1.sql
\echo Use "ALTER EXTENSION demo_ext UPDATE TO '1.1'" to load this file. \quit

CREATE FUNCTION demo_sub(integer, integer) RETURNS integer
AS 'MODULE_PATHNAME', 'demo_sub'
LANGUAGE C STRICT IMMUTABLE;
```

### 라이브러리 파일을 바꾸면

`shared_preload_libraries = 'demo_ext, pg_stat_statements'`로 서버가 떠 있고 접속 A가 열려 있는 상태입니다.

```psql
A=# SELECT pg_backend_pid(), demo_build();
 pg_backend_pid |   demo_build    
----------------+-----------------
          10148 | demo_ext.so 1.0
(1 row)
```

이 상태에서 1.1을 설치합니다. control 파일의 `default_version`을 `'1.1'`로 바꾸고, Makefile의 `DATA`에 업데이트 스크립트를 추가하고, `demo_sub()`가 들어가도록 `-DDEMO_V11`로 빌드했습니다.

```console
$ make install
/usr/bin/install -c -m 644 .//demo_ext.control '/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 644 .//demo_ext--1.0.sql .//demo_ext--1.0--1.1.sql  '/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 755  demo_ext.so '/usr/local/pgsql/lib/'
$ ls -li /usr/local/pgsql/lib/demo_ext.so
1306722 -rwxr-xr-x 1 root root 72640 Sep 26 11:03 /usr/local/pgsql/lib/demo_ext.so
$ nm -D --defined-only /usr/local/pgsql/lib/demo_ext.so | grep -w demo_sub
0000000000001094 T demo_sub
```

`install` 명령은 기존 파일을 지우고(unlink) 새 파일을 만들어서 inode가 1306724에서 1306722로 바뀌었습니다. 다시 A에서 봅니다.

```psql
A=# SELECT l FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so%';
                                                          l                                                          
---------------------------------------------------------------------------------------------------------------------
 ffff8d330000-ffff8d332000 r-xp 00000000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so (deleted)
 ffff8d332000-ffff8d34f000 ---p 00002000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so (deleted)
 ffff8d34f000-ffff8d350000 r--p 0000f000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so (deleted)
 ffff8d350000-ffff8d351000 rw-p 00010000 00:49 1306724                    /usr/local/pgsql/lib/demo_ext.so (deleted)
(4 rows)

A=# SELECT demo_build();
   demo_build    
-----------------
 demo_ext.so 1.0
(1 row)

A=# SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name = 'demo_ext';
   name   | default_version | installed_version 
----------+-----------------+-------------------
 demo_ext | 1.1             | 1.0
(1 row)

A=# SELECT * FROM pg_extension_update_paths('demo_ext');
 source | target |   path   
--------+--------+----------
 1.0    | 1.1    | 1.0--1.1
 1.1    | 1.0    | 
(2 rows)

A=# ALTER EXTENSION demo_ext UPDATE;
ERROR:  could not find function "demo_sub" in file "/usr/local/pgsql/lib/demo_ext.so"
CONTEXT:  SQL statement "CREATE FUNCTION demo_sub(integer, integer) RETURNS integer
AS '$libdir/demo_ext', 'demo_sub'
LANGUAGE C STRICT IMMUTABLE"
extension script file "demo_ext--1.0--1.1.sql", near line 3
```

- A의 매핑은 옛 inode 1306724를 가리키고 `(deleted)`가 붙었습니다. 디렉터리에서 이름은 사라졌지만 매핑이 남아 있는 동안 커널은 파일 내용을 지우지 않습니다. A는 계속 1.0 코드를 실행합니다.
- control 파일은 이미 새것이라 `pg_available_extensions`는 기본 버전 1.1, 설치 버전 1.0을 보여 주고, 1.0 → 1.1 업데이트 경로도 보입니다.
- 그런데 `ALTER EXTENSION UPDATE`가 실패했습니다. 업데이트 스크립트의 `CREATE FUNCTION demo_sub`를 검증하면서 로더가 `$libdir/demo_ext.so`를 찾았는데, 이 backend의 라이브러리 목록에 **같은 경로 문자열**이 이미 있어서 옛 1.0 핸들을 그대로 돌려줬습니다([L200-L204](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c#L200-L204)). 1.0 `.so`에는 `demo_sub`가 없습니다. 오류로 트랜잭션이 롤백되어 `extversion`은 1.0 그대로입니다.

새 접속 B를 열면 새 `.so`를 쓸까요.

```psql
B=# SELECT pg_backend_pid(), demo_build();
 pg_backend_pid |   demo_build    
----------------+-----------------
          10396 | demo_ext.so 1.0
(1 row)

B=# SELECT count(*) AS deleted_mappings FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so (deleted)%';
 deleted_mappings 
------------------
                4
(1 row)

B=# ALTER EXTENSION demo_ext UPDATE;
ERROR:  could not find function "demo_sub" in file "/usr/local/pgsql/lib/demo_ext.so"
CONTEXT:  SQL statement "CREATE FUNCTION demo_sub(integer, integer) RETURNS integer
AS '$libdir/demo_ext', 'demo_sub'
LANGUAGE C STRICT IMMUTABLE"
extension script file "demo_ext--1.0--1.1.sql", near line 3
```

새 접속도 1.0입니다. `demo_ext`가 preload되어 있어서 B는 postmaster가 서버 시작 때 올린 옛 `.so`를 fork로 물려받았습니다. 라이브러리 목록까지 물려받았으니 업데이트도 똑같이 실패합니다. **preload한 라이브러리는 서버를 재시작해야만 바뀝니다.**

```console
$ pg_ctl -D $PGDATA -l /home/postgres/server.log restart -m fast
waiting for server to shut down.... done
server stopped
waiting for server to start.... done
server started
$ grep _PG_init /home/postgres/server.log | tail -1
2026-09-26 11:03:20.450 UTC [10486] LOG:  demo_ext 1.1: _PG_init in pid 10486 (shared_preload_libraries: yes)
```

```psql
postgres=# SELECT demo_build();
   demo_build    
-----------------
 demo_ext.so 1.1
(1 row)

postgres=# SELECT * FROM pg_get_loaded_modules() WHERE module_name = 'demo_ext';
 module_name | version |  file_name  
-------------+---------+-------------
 demo_ext    | 1.1     | demo_ext.so
(1 row)

postgres=# ALTER EXTENSION demo_ext UPDATE;
ALTER EXTENSION
postgres=# SELECT extversion FROM pg_extension WHERE extname = 'demo_ext';
 extversion 
------------
 1.1
(1 row)

postgres=# SELECT demo_sub(10, 3);
 demo_sub 
----------
        7
(1 row)
```

재시작 뒤에야 업데이트가 됩니다.

preload하지 않은 라이브러리는 다릅니다. `shared_preload_libraries = pg_stat_statements`로 바꿔 재시작했습니다. 접속 A가 1.1 `.so`(`hotfix` 표시를 붙여 빌드)를 올린 상태에서 다시 빌드한 `hotfix2`를 `make install`했습니다.

```psql
A=# SELECT pg_backend_pid(), demo_build();
 pg_backend_pid |       demo_build       
----------------+------------------------
          10589 | demo_ext.so 1.1 hotfix
(1 row)
```

```console
$ make install
$ ls -li /usr/local/pgsql/lib/demo_ext.so
1306718 -rwxr-xr-x 1 root root 72640 Sep 26 11:03 /usr/local/pgsql/lib/demo_ext.so
```

```psql
A=# SELECT demo_build();
       demo_build       
------------------------
 demo_ext.so 1.1 hotfix
(1 row)

A=# SELECT count(*) AS deleted_mappings FROM regexp_split_to_table(pg_read_file('/proc/self/maps'), E'\n') AS l WHERE l LIKE '%demo_ext.so (deleted)%';
 deleted_mappings 
------------------
                4
(1 row)

# 세션 B 시작: psql -X application_name=sessB

B=# SELECT pg_backend_pid(), demo_build();
 pg_backend_pid |       demo_build        
----------------+-------------------------
          10732 | demo_ext.so 1.1 hotfix2
(1 row)
```

이미 올린 A는 옛 파일을, 새 접속 B는 새 파일을 씁니다. 같은 서버에서 **접속마다 다른 버전의 코드가 동시에 돌 수 있다**는 뜻입니다.

| 상황 | 기존 backend | 새 backend |
|---|---|---|
| preload한 라이브러리 | 옛 `.so` | 옛 `.so` (postmaster에게서 물려받음) |
| preload하지 않은 라이브러리 | 이미 올렸으면 옛 `.so` | 새 `.so` |
| 서버 재시작 뒤 | 새 `.so` | 새 `.so` |

#### 운영에서는: 라이브러리를 cp로 덮어쓰지 않는다

`install`이나 패키지 관리자(rpm)는 새 파일을 만들어 교체하므로 옛 매핑이 안전하게 남습니다. 같은 inode를 제자리에서 덮어쓰면 어떻게 되는지 보려고 A가 `hotfix2`를 올린 상태에서 다른 빌드를 `cp`로 덮어썼습니다.

```psql
A=# SELECT pg_backend_pid(), demo_build(), demo_add(1, 2);
 pg_backend_pid |       demo_build        | demo_add 
----------------+-------------------------+----------
          10823 | demo_ext.so 1.1 hotfix2 |        3
(1 row)
```

```console
$ ls -li /usr/local/pgsql/lib/demo_ext.so
1306718 -rwxr-xr-x 1 root root 72640 Sep 26 11:03 /usr/local/pgsql/lib/demo_ext.so
$ cp /tmp/demo_ext.hotfix3.so /usr/local/pgsql/lib/demo_ext.so
$ ls -li /usr/local/pgsql/lib/demo_ext.so
1306718 -rwxr-xr-x 1 root root 72640 Sep 26 11:03 /usr/local/pgsql/lib/demo_ext.so
```

```psql
A=# SELECT demo_build();
ERROR:  unrecognized function API version: 0
A=# SELECT demo_add(1, 2);
ERROR:  unrecognized function API version: 0
```

`cp`는 기존 파일을 비우고 그 자리에 새 내용을 씁니다. inode가 그대로라 A가 매핑한 페이지가 새 파일의 내용을 보게 되고, A가 캐시해 둔 주소에는 더 이상 원래 값이 없습니다. 이 실습에서는 `pg_finfo_` 레코드가 있던 자리를 읽어 `0`이 나왔고([`fmgr.c`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/fmgr.c#L407)), 방금까지 되던 `demo_add()`도 실패했습니다.

여기서 끝나지 않았습니다. 이어서 세션 A를 닫자 그 backend가 죽었습니다.

```console
$ cat /home/postgres/server.log
...
2026-09-26 11:03:32.559 UTC [10823] ERROR:  unrecognized function API version: 0
2026-09-26 11:03:32.559 UTC [10823] STATEMENT:  SELECT demo_build();
2026-09-26 11:03:33.562 UTC [10823] ERROR:  unrecognized function API version: 0
2026-09-26 11:03:33.562 UTC [10823] STATEMENT:  SELECT demo_add(1, 2);
2026-09-26 11:03:34.564 UTC [10509] LOG:  client backend (PID 10823) was terminated by signal 11: Segmentation fault
2026-09-26 11:03:34.564 UTC [10509] LOG:  terminating any other active server processes
2026-09-26 11:03:34.565 UTC [10509] LOG:  all server processes terminated; reinitializing
2026-09-26 11:03:34.585 UTC [10909] LOG:  database system was interrupted; last known up at 2026-09-26 11:03:20 UTC
2026-09-26 11:03:34.615 UTC [10909] LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-26 11:03:34.615 UTC [10909] LOG:  invalid record length at 0/1844298: expected at least 24, got 0
2026-09-26 11:03:34.615 UTC [10909] LOG:  redo is not required
2026-09-26 11:03:34.616 UTC [10910] LOG:  checkpoint starting: end-of-recovery immediate wait
2026-09-26 11:03:34.621 UTC [10910] LOG:  checkpoint complete: wrote 0 buffers (0.0%), wrote 3 SLRU buffers; 0 WAL file(s) added, 0 removed, 0 recycled; write=0.001 s, sync=0.001 s, total=0.006 s; sync files=2, longest=0.001 s, average=0.001 s; distance=0 kB, estimate=0 kB; lsn=0/1844298, redo lsn=0/1844298
2026-09-26 11:03:34.622 UTC [10509] LOG:  database system is ready to accept connections
```

backend 10823은 쿼리 없이 접속을 끝내던 중에 `SIGSEGV`로 죽어서 `Failed process was running` 줄이 없습니다. 어떤 코드가 망가진 페이지를 실행했는지는 로그로 알 수 없지만, 결과는 [C 함수의 버그](#운영에서는-c-extension의-버그는-서버-전체를-재시작시킨다)와 같습니다. postmaster가 모든 프로세스를 끝내고 crash recovery를 한 뒤 접속을 다시 받았습니다. 파일 하나를 덮어쓴 것이 서버 전체의 재시작으로 이어진 것입니다. 라이브러리 파일은 패키지 관리자나 `install`로 교체합니다.

#### 운영에서는: 패키지 업그레이드 뒤에 해야 할 일

위 실습을 운영 절차로 옮기면 이렇습니다.

1. 패키지를 올립니다. 이것만으로는 카탈로그도, 떠 있는 프로세스도 바뀌지 않습니다.
2. preload하는 라이브러리라면 서버를 재시작합니다. 아니라면 적어도 새 접속에서 작업합니다. 커넥션 풀의 오래된 접속은 옛 `.so`를 쥐고 있을 수 있습니다.
3. 새 버전에 SQL 변경이 있으면 DB마다 `ALTER EXTENSION ... UPDATE`를 실행합니다. 다음 쿼리로 남은 곳을 찾을 수 있습니다.

```psql
postgres=# SELECT name, default_version, installed_version FROM pg_available_extensions WHERE installed_version IS DISTINCT FROM default_version AND installed_version IS NOT NULL;
```

`pg_get_loaded_modules()`(PG18)는 지금 이 프로세스가 쥐고 있는 라이브러리 버전을, `pg_extension.extversion`은 이 DB의 SQL 쪽 버전을 보여 줍니다. 둘을 함께 보면 어긋난 곳을 알 수 있습니다.

#### 버전을 건너뛰는 설치

설치 스크립트가 1.0뿐이어도 `default_version = '1.1'`인 `CREATE EXTENSION`은 1.0을 설치한 뒤 업데이트 스크립트를 이어서 실행합니다. 새 DB `verdb`에서 `client_min_messages = debug1`로 보면 두 스크립트가 차례로 실행됩니다.

```psql
verdb=# SET client_min_messages = debug1;
SET
verdb=# CREATE EXTENSION demo_ext;
DEBUG:  executing extension script for "demo_ext" version '1.0'
DEBUG:  executing extension script for "demo_ext" update from version '1.0' to '1.1'
CREATE EXTENSION
verdb=# RESET client_min_messages;
RESET
verdb=# SELECT extversion FROM pg_extension WHERE extname = 'demo_ext';
 extversion 
------------
 1.1
(1 row)
```

덕분에 extension 배포판은 모든 버전의 설치 스크립트를 들고 다닐 필요 없이, 기준이 되는 설치 스크립트 하나와 업데이트 스크립트만 있으면 됩니다.

## C extension은 서버 프로세스 안에서 돈다

C 함수는 서버 코드와 같은 프로세스, 같은 주소 공간에서 실행되니 C 함수의 버그는 서버의 버그와 같습니다.

#### 운영에서는: C extension의 버그는 서버 전체를 재시작시킨다

접속 B가 트랜잭션 안에서 `demo_note`에 행을 넣고 커밋하지 않았습니다. 그 상태에서 다른 접속이 NULL 포인터에 쓰는 `demo_crash()`를 불렀습니다. 함수는 extension 스크립트 밖에서 같은 `.so`의 심볼로 따로 만들었습니다. 이렇게 `CREATE FUNCTION`만으로도 라이브러리의 어떤 심볼이든 SQL 함수로 만들 수 있습니다.

```psql
B=# BEGIN;
BEGIN
B=*# INSERT INTO demo_note VALUES (1, 'written before the crash, not committed');
INSERT 0 1
```

```psql
postgres=# CREATE FUNCTION demo_crash() RETURNS void AS '$libdir/demo_ext', 'demo_crash' LANGUAGE C;
CREATE FUNCTION
postgres=# SELECT pg_backend_pid();
 pg_backend_pid 
----------------
          11077
(1 row)

postgres=# SELECT demo_crash();
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
connection to server was lost
```

```psql
B=*# COMMIT;
WARNING:  terminating connection because of crash of another server process
DETAIL:  The postmaster has commanded this server process to roll back the current transaction and exit, because another server process exited abnormally and possibly corrupted shared memory.
HINT:  In a moment you should be able to reconnect to the database and repeat your command.
server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
```

```console
$ cat /home/postgres/server.log
...
2026-09-26 11:03:39.800 UTC [10509] LOG:  client backend (PID 11077) was terminated by signal 11: Segmentation fault
2026-09-26 11:03:39.800 UTC [10509] DETAIL:  Failed process was running: SELECT demo_crash();
2026-09-26 11:03:39.800 UTC [10509] LOG:  terminating any other active server processes
2026-09-26 11:03:39.801 UTC [10509] LOG:  all server processes terminated; reinitializing
2026-09-26 11:03:39.811 UTC [11082] LOG:  database system was interrupted; last known up at 2026-09-26 11:03:34 UTC
2026-09-26 11:03:39.981 UTC [11082] LOG:  database system was not properly shut down; automatic recovery in progress
2026-09-26 11:03:39.982 UTC [11082] LOG:  redo starts at 0/1844310
2026-09-26 11:03:39.988 UTC [11082] LOG:  invalid record length at 0/1C8F118: expected at least 24, got 0
2026-09-26 11:03:39.988 UTC [11082] LOG:  redo done at 0/1C8F0B0 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
2026-09-26 11:03:39.998 UTC [11083] LOG:  checkpoint starting: end-of-recovery immediate wait
2026-09-26 11:03:40.115 UTC [11083] LOG:  checkpoint complete: wrote 953 buffers (5.8%), wrote 3 SLRU buffers; 0 WAL file(s) added, 0 removed, 0 recycled; write=0.004 s, sync=0.108 s, total=0.119 s; sync files=318, longest=0.004 s, average=0.001 s; distance=4395 kB, estimate=4395 kB; lsn=0/1C8F118, redo lsn=0/1C8F118
2026-09-26 11:03:40.116 UTC [10509] LOG:  database system is ready to accept connections
```

```psql
postgres=# SELECT count(*) FROM demo_note;
 count 
-------
     0
(1 row)
```

backend 하나가 `SIGSEGV`로 죽자 postmaster는 그 프로세스가 공유 메모리를 망가뜨렸을 수 있다고 보고 **아무 잘못 없는 B를 포함한 모든 프로세스를 종료**했습니다([`HandleChildCrash()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/postmaster/postmaster.c#L2785)). 그다음 공유 메모리를 다시 만들고 WAL로 crash recovery를 한 뒤 접속을 다시 받았습니다([1편](/posts/postgresql/01-process-architecture/), [8편](/posts/postgresql/08-checkpoint-and-recovery/)). B가 커밋하지 않은 행은 사라졌습니다.

같은 일이 extension 코드 안의 NULL 참조, 해제된 메모리 사용, 스택 넘침으로 생깁니다. 로그에 `terminated by signal 11`이 보이고 `Failed process was running`의 쿼리가 extension 함수를 쓰고 있다면 그 extension을 먼저 의심합니다. 새 C extension은 운영 전에 부하를 걸어 충분히 시험하고, 코어 덤프를 남기도록 설정해 두면 원인을 찾기 쉽습니다.

## 권한: superuser와 trusted

C 함수를 만들면 서버 프로세스 안에서 임의의 코드를 실행할 수 있습니다. 그래서 `LANGUAGE C` 함수는 superuser만 만들 수 있고, control 파일의 `superuser`도 기본값이 `true`입니다. PG13부터는 control 파일에 `trusted = true`를 적은 extension을, superuser가 아니어도 DB에 `CREATE` 권한이 있으면 설치할 수 있습니다. 이때 스크립트는 **bootstrap superuser의 권한으로** 실행되고([`execute_extension_script()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L1216-L1255)), extension의 소유자만 설치한 사용자가 됩니다.

#### trusted extension과 일반 사용자

```console
$ cat /usr/local/pgsql/share/extension/hstore.control
# hstore extension
comment = 'data type for storing sets of (key, value) pairs'
default_version = '1.8'
module_pathname = '$libdir/hstore'
relocatable = true
trusted = true
```

```psql
postgres=# SELECT e.name, e.default_version, v.superuser, v.trusted FROM pg_available_extensions e JOIN pg_available_extension_versions v ON v.name = e.name AND v.version = e.default_version WHERE e.name IN ('demo_ext', 'hstore', 'pg_stat_statements') ORDER BY 1;
        name        | default_version | superuser | trusted 
--------------------+-----------------+-----------+---------
 demo_ext           | 1.1             | t         | f
 hstore             | 1.8             | t         | t
 pg_stat_statements | 1.12            | t         | f
(3 rows)

postgres=# CREATE ROLE app LOGIN;
CREATE ROLE
postgres=# CREATE DATABASE appdb;
CREATE DATABASE
postgres=# GRANT CREATE ON DATABASE appdb TO app;
GRANT
```

`appdb`의 `public` 스키마에도 `app`에게 `CREATE` 권한을 준 뒤, `app`으로 접속해 설치해 봤습니다.

```psql
appdb=> SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user;
 current_user | rolsuper 
--------------+----------
 app          | f
(1 row)

appdb=> CREATE EXTENSION demo_ext;
ERROR:  permission denied to create extension "demo_ext"
HINT:  Must be superuser to create this extension.
appdb=> CREATE EXTENSION hstore;
CREATE EXTENSION
appdb=> SELECT extname, extowner::regrole FROM pg_extension WHERE extname = 'hstore';
 extname | extowner 
---------+----------
 hstore  | app
(1 row)

appdb=> SELECT proname, proowner::regrole FROM pg_proc WHERE proname = 'hstore_in';
  proname  | proowner 
-----------+----------
 hstore_in | postgres
(1 row)

appdb=> SELECT 'a=>1, b=>2'::hstore -> 'b' AS b;
 b 
---
 2
(1 row)
```

`trusted`가 아닌 `demo_ext`는 거부되고 `hstore`는 설치됩니다. extension 소유자는 `app`이지만 C 함수 `hstore_in`의 소유자는 bootstrap superuser인 `postgres`입니다. 일반 사용자가 C 함수를 만든 것이 아니라, superuser가 검토해 `trusted`로 표시한 스크립트를 대신 실행해 준 것입니다. 이 빌드에 설치된 extension 44개 중 19개가 `trusted`였습니다.

## PG18: extension_control_path

PG17까지 control 파일은 반드시 PostgreSQL 설치 디렉터리의 `share/extension/`에 있어야 했습니다. PG18에는 `extension_control_path`가 생겨 다른 디렉터리에 둔 extension도 쓸 수 있습니다([`get_extension_control_directories()`](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c#L473)). 목록의 각 디렉터리 뒤에 `/extension`을 붙여 찾고, `$system`은 원래 위치를 뜻합니다. `.so`는 예전부터 있던 `dynamic_library_path`로 찾습니다. 컨테이너 이미지처럼 PostgreSQL 설치 디렉터리를 고칠 수 없는 환경을 위한 기능입니다.

#### 설치 디렉터리 밖에 둔 extension

`module_pathname = 'pathdemo'`(경로 없이 이름만)로 작은 extension을 만들어 `DESTDIR`로 `/opt/pathdemo` 아래에 설치했습니다.

```console
$ make install DESTDIR=/opt/pathdemo
/usr/bin/install -c -m 644 .//pathdemo.control '/opt/pathdemo/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 644 .//pathdemo--0.1.sql  '/opt/pathdemo/usr/local/pgsql/share/extension/'
/usr/bin/install -c -m 755  pathdemo.so '/opt/pathdemo/usr/local/pgsql/lib/'
```

```psql
postgres=# SELECT name, setting, context FROM pg_settings WHERE name IN ('extension_control_path', 'dynamic_library_path');
          name          | setting |  context  
------------------------+---------+-----------
 dynamic_library_path   | $libdir | superuser
 extension_control_path | $system | superuser
(2 rows)

postgres=# CREATE EXTENSION pathdemo;
ERROR:  extension "pathdemo" is not available
HINT:  The extension must first be installed on the system where PostgreSQL is running.
postgres=# SET extension_control_path = '$system:/opt/pathdemo/usr/local/pgsql/share';
SET
postgres=# SELECT name, default_version, comment FROM pg_available_extensions WHERE name = 'pathdemo';
   name   | default_version |                     comment                     
----------+-----------------+-------------------------------------------------
 pathdemo | 0.1             | extension installed outside the PostgreSQL tree
(1 row)

postgres=# CREATE EXTENSION pathdemo;
ERROR:  could not access file "pathdemo": No such file or directory
CONTEXT:  SQL statement "CREATE FUNCTION pathdemo_hello() RETURNS text
AS 'pathdemo', 'pathdemo_hello'
LANGUAGE C STRICT"
extension script file "pathdemo--0.1.sql", near line 1
postgres=# SET dynamic_library_path = '$libdir:/opt/pathdemo/usr/local/pgsql/lib';
SET
postgres=# CREATE EXTENSION pathdemo;
CREATE EXTENSION
postgres=# SELECT pathdemo_hello();
       pathdemo_hello       
----------------------------
 hello from outside $libdir
(1 row)

postgres=# SELECT probin FROM pg_proc WHERE proname = 'pathdemo_hello';
  probin  
----------
 pathdemo
(1 row)
```

control 파일은 `extension_control_path`로, `.so`는 `dynamic_library_path`로 따로 찾는다는 것이 오류 순서에서 드러납니다. control 경로만 추가했을 때는 스크립트까지는 실행되었고 C 함수 검증에서 `.so`를 찾지 못했습니다. `probin`에 경로 없이 `pathdemo`만 저장되었으므로 이 함수를 부르는 모든 세션이 `dynamic_library_path`를 알아야 합니다. 설정하지 않은 새 접속에서 보면 이렇습니다.

```psql
postgres=# SELECT pathdemo_hello();
ERROR:  could not access file "pathdemo": No such file or directory
postgres=# SELECT extname, extversion FROM pg_extension WHERE extname = 'pathdemo';
 extname  | extversion 
----------+------------
 pathdemo | 0.1
(1 row)

postgres=# SELECT name, installed_version FROM pg_available_extensions WHERE name = 'pathdemo';
 name | installed_version 
------+-------------------
(0 rows)
```

카탈로그에는 extension이 설치되어 있다고 나오는데, 이 세션은 control 파일도 `.so`도 찾지 못합니다. 실습에서는 세션에서 `SET`했지만 실제로 쓸 때는 두 설정을 `postgresql.conf`에 넣어야 합니다.

## pg_dump와 DROP EXTENSION

extension의 멤버 객체는 카탈로그에 있지만 정의의 원본은 디스크의 스크립트 파일입니다. `pg_dump`는 이 점을 이용합니다.

#### pg_dump가 남기는 것

```psql
postgres=# INSERT INTO demo_note VALUES (1, 'kept by pg_dump');
INSERT 0 1
postgres=# \dx+ demo_ext
  Objects in extension "demo_ext"
         Object description         
------------------------------------
 function demo_add(integer,integer)
 function demo_build()
 function demo_local_count()
 function demo_shared_count()
 function demo_sub(integer,integer)
 table demo_note
 type demo_note
 type demo_note[]
(8 rows)

postgres=# DROP FUNCTION demo_add(integer, integer);
ERROR:  cannot drop function demo_add(integer,integer) because extension demo_ext requires it
HINT:  You can drop extension demo_ext instead.
```

```console
$ pg_dump -d postgres | grep -vE "^--|^$|^SET |^SELECT pg_catalog.set_config|^\\\\(un)?restrict"
CREATE EXTENSION IF NOT EXISTS demo_ext WITH SCHEMA public;
COMMENT ON EXTENSION demo_ext IS 'demo extension for extension internals';
CREATE EXTENSION IF NOT EXISTS pathdemo WITH SCHEMA public;
COMMENT ON EXTENSION pathdemo IS 'extension installed outside the PostgreSQL tree';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';
COPY public.demo_note (id, note) FROM stdin;
1	kept by pg_dump
\.
```

- 멤버 객체는 `pg_depend`의 `'e'` 의존성 때문에 따로 지울 수 없습니다.
- `pg_dump`는 멤버 객체의 정의를 하나도 내보내지 않고 `CREATE EXTENSION` 한 줄만 남깁니다. 복원하는 서버가 **자기 디스크의 스크립트**로 객체를 다시 만듭니다.
- 이 줄에는 버전이 없습니다. 복원하는 서버의 `default_version`으로 설치됩니다.
- `pg_extension_config_dump()`로 표시한 `demo_note`는 테이블 정의는 빠지고 데이터만 `COPY`로 나옵니다.

#### 운영에서는: 복원할 서버에 extension 파일이 없으면

위 덤프에는 [앞 절](#설치-디렉터리-밖에-둔-extension)에서 설치 디렉터리 밖에 둔 `pathdemo`도 들어 있습니다. 이 덤프를 `extension_control_path` 설정 없이 새 DB에 복원했습니다.

```console
$ createdb restoredb
$ pg_dump -d postgres | grep -n "CREATE EXTENSION"
26:CREATE EXTENSION IF NOT EXISTS demo_ext WITH SCHEMA public;
40:CREATE EXTENSION IF NOT EXISTS pathdemo WITH SCHEMA public;
54:CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
$ pg_dump -d postgres | psql -X -q -d restoredb
 set_config 
------------
 
(1 row)

ERROR:  extension "pathdemo" is not available
HINT:  The extension must first be installed on the system where PostgreSQL is running.
ERROR:  extension "pathdemo" does not exist
```

extension 파일은 DB 안에 있지 않으므로 덤프에도 없습니다. 복원할 서버에는 **같은 extension 패키지를 먼저 설치**해야 합니다. 물리 복제도 마찬가지입니다. standby는 WAL로 카탈로그를 그대로 받지만 `$libdir`과 `share/extension/`의 파일은 WAL에 실리지 않으므로, standby에도 primary와 같은 패키지를 설치해 둬야 합니다. 그렇지 않으면 [앞에서 본](#설치-디렉터리-밖에-둔-extension) "카탈로그에는 있는데 파일은 없는" 상태가 되고, `shared_preload_libraries`에 있는 라이브러리라면 [서버가 뜨지 않습니다](#운영에서는-shared_preload_libraries를-잘못-적으면-서버가-뜨지-않는다).

#### 운영에서는: DROP EXTENSION은 데이터도 지운다

```psql
restoredb=# INSERT INTO demo_note VALUES (2, 'important');
INSERT 0 1
restoredb=# DROP EXTENSION demo_ext;
DROP EXTENSION
restoredb=# SELECT to_regclass('demo_note');
 to_regclass 
-------------
 
(1 row)
```

`DROP EXTENSION`은 `pg_depend`를 따라 멤버 객체를 모두 지웁니다. 사용자가 데이터를 넣던 설정 테이블도 멤버라서 경고 없이 데이터와 함께 사라졌습니다. extension을 지웠다 다시 설치해 문제를 해결하려 할 때는 먼저 `\dx+`로 멤버에 테이블이 있는지 확인합니다.

## 정리

- extension은 **control 파일, SQL 스크립트, 공유 라이브러리**라는 파일과, **`pg_extension`, `pg_depend`(`deptype = 'e'`)** 라는 카탈로그 행으로 이루어집니다. 파일은 서버에, 카탈로그는 DB에 있습니다.
- `CREATE EXTENSION`은 control 파일을 읽고, `pg_extension`에 행을 넣고, 스크립트의 자리표시자를 바꿔 한 트랜잭션으로 실행합니다. 스크립트가 만든 객체는 모두 `pg_depend`로 extension에 묶입니다.
- C 함수는 `pg_proc`의 `probin`(파일)과 `prosrc`(심볼)로 찾습니다. 로더는 `.so`를 `dlopen()`으로 매핑하고, magic block으로 ABI를 확인하고, `_PG_init()`을 부른 뒤 `dlsym()`으로 함수를 찾습니다. `.so`의 undefined 심볼은 `postgres` 실행 파일이 내보낸 심볼로 채워집니다.
- 라이브러리 로드는 **프로세스 단위**입니다. 보통은 backend마다 처음 쓸 때 올리고, `shared_preload_libraries`에 넣으면 postmaster가 한 번 올려 fork로 물려줍니다. 공유 메모리가 필요한 extension은 preload해야 합니다.
- hook은 서버의 함수 포인터 전역 변수이고, `_PG_init()`에서 이전 값을 저장하고 자기 함수로 바꿔 사슬을 만듭니다.
- 한 번 올린 라이브러리는 내릴 수 없습니다. 파일을 바꿔도 기존 프로세스는 옛 코드를 쓰고, preload한 라이브러리는 재시작해야 바뀝니다. 그 전에 `ALTER EXTENSION UPDATE`를 하면 옛 `.so`에서 새 심볼을 찾다가 실패할 수 있습니다.
- C 함수는 서버 프로세스 안에서 돌기 때문에 버그 하나가 모든 접속을 끊고 crash recovery를 일으킵니다.

## 참고 자료

소스 코드 (`REL_18_STABLE` 커밋 `39a0db1` 기준)

- [src/backend/commands/extension.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/commands/extension.c): `CREATE EXTENSION`, `ALTER EXTENSION`, control 파일, `pg_get_loaded_modules()`
- [src/backend/utils/fmgr/dfmgr.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/dfmgr.c): 동적 로더(`dlopen`, magic block, `_PG_init`)
- [src/backend/utils/fmgr/fmgr.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/fmgr/fmgr.c): C 함수 찾기와 호출 규약
- [src/include/fmgr.h](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/include/fmgr.h): `PG_MODULE_MAGIC`, `PG_MODULE_MAGIC_EXT`, `PG_FUNCTION_INFO_V1`
- [src/backend/catalog/pg_proc.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/catalog/pg_proc.c): `fmgr_c_validator()`
- [src/backend/catalog/pg_depend.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/catalog/pg_depend.c): `recordDependencyOnCurrentExtension()`
- [src/backend/utils/init/miscinit.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/src/backend/utils/init/miscinit.c): `*_preload_libraries`, `shmem_request_hook`
- [contrib/pg_stat_statements/pg_stat_statements.c](https://github.com/postgres/postgres/blob/39a0db101105eab3f4044d11c609c58b9459ea16/contrib/pg_stat_statements/pg_stat_statements.c): preload와 hook을 쓰는 실제 extension

PostgreSQL 18 공식 문서

- [Packaging Related Objects into an Extension](https://www.postgresql.org/docs/18/extend-extensions.html)
- [C-Language Functions](https://www.postgresql.org/docs/18/xfunc-c.html)
- [Extension Building Infrastructure (PGXS)](https://www.postgresql.org/docs/18/extend-pgxs.html)
- [CREATE EXTENSION](https://www.postgresql.org/docs/18/sql-createextension.html), [ALTER EXTENSION](https://www.postgresql.org/docs/18/sql-alterextension.html)
- [Shared Library Preloading](https://www.postgresql.org/docs/18/runtime-config-client.html#RUNTIME-CONFIG-CLIENT-PRELOAD)

운영체제

- `dlopen(3)`, `mmap(2)`, `fork(2)`, `proc_pid_maps(5)` 매뉴얼 페이지
