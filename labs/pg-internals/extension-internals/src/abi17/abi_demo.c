#include "postgres.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(abi_demo_one);
Datum
abi_demo_one(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(1);
}
