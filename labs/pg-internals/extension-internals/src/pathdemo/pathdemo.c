#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC_EXT(.name = "pathdemo", .version = "0.1");

PG_FUNCTION_INFO_V1(pathdemo_hello);
Datum
pathdemo_hello(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text("hello from outside $libdir"));
}
