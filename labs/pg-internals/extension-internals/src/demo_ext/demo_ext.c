#include "postgres.h"

#include <unistd.h>

#include "executor/executor.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"

#ifdef DEMO_V11
#define DEMO_VERSION "1.1"
#else
#define DEMO_VERSION "1.0"
#endif

#ifndef DEMO_BUILD_TAG
#define DEMO_BUILD_TAG ""
#endif

PG_MODULE_MAGIC_EXT(.name = "demo_ext", .version = DEMO_VERSION);

/* 공유 메모리에 둘 상태: 모든 backend가 함께 보는 카운터 */
typedef struct DemoSharedState
{
	pg_atomic_uint64 queries;
} DemoSharedState;

static DemoSharedState *demo_state = NULL;

/* 프로세스마다 따로 있는 카운터 */
static uint64 local_queries = 0;

static bool demo_trace = false;

static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

static void demo_ExecutorEnd(QueryDesc *queryDesc);
static void demo_shmem_request(void);
static void demo_shmem_startup(void);

void
_PG_init(void)
{
	elog(LOG, "demo_ext %s: _PG_init in pid %d (shared_preload_libraries: %s)",
		 DEMO_VERSION, (int) getpid(),
		 process_shared_preload_libraries_in_progress ? "yes" : "no");

	DefineCustomBoolVariable("demo_ext.trace",
							 "Report the number of rows each query processed.",
							 NULL,
							 &demo_trace,
							 false,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);
	MarkGUCPrefixReserved("demo_ext");

	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = demo_ExecutorEnd;

	/* 공유 메모리는 postmaster가 만들 때만 요청할 수 있다 */
	if (process_shared_preload_libraries_in_progress)
	{
		prev_shmem_request_hook = shmem_request_hook;
		shmem_request_hook = demo_shmem_request;
		prev_shmem_startup_hook = shmem_startup_hook;
		shmem_startup_hook = demo_shmem_startup;
	}
}

static void
demo_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	RequestAddinShmemSpace(MAXALIGN(sizeof(DemoSharedState)));
}

static void
demo_shmem_startup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	demo_state = ShmemInitStruct("demo_ext", sizeof(DemoSharedState), &found);
	if (!found)
		pg_atomic_init_u64(&demo_state->queries, 0);
}

static void
demo_ExecutorEnd(QueryDesc *queryDesc)
{
	local_queries++;
	if (demo_state)
		pg_atomic_fetch_add_u64(&demo_state->queries, 1);

	if (demo_trace)
		ereport(NOTICE,
				(errmsg("demo_ext: %llu rows processed",
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
	int32		a = PG_GETARG_INT32(0);
	int32		b = PG_GETARG_INT32(1);

	PG_RETURN_INT32(a + b);
}

#ifdef DEMO_V11
PG_FUNCTION_INFO_V1(demo_sub);
Datum
demo_sub(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(PG_GETARG_INT32(0) - PG_GETARG_INT32(1));
}
#endif

PG_FUNCTION_INFO_V1(demo_build);
Datum
demo_build(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text("demo_ext.so " DEMO_VERSION DEMO_BUILD_TAG));
}

PG_FUNCTION_INFO_V1(demo_local_count);
Datum
demo_local_count(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) local_queries);
}

PG_FUNCTION_INFO_V1(demo_shared_count);
Datum
demo_shared_count(PG_FUNCTION_ARGS)
{
	if (demo_state == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("demo_ext must be loaded via \"shared_preload_libraries\"")));
	PG_RETURN_INT64((int64) pg_atomic_read_u64(&demo_state->queries));
}

PG_FUNCTION_INFO_V1(demo_crash);
Datum
demo_crash(PG_FUNCTION_ARGS)
{
	volatile int *p = NULL;

	*p = 1;						/* 일부러 NULL 포인터에 쓴다 */
	PG_RETURN_VOID();
}
