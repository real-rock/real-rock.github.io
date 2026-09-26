#include "postgres.h"
#include "fmgr.h"

/* PG_MODULE_MAGIC; 를 일부러 빼먹었다 */

PG_FUNCTION_INFO_V1(nomagic_one);
Datum
nomagic_one(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(1);
}
