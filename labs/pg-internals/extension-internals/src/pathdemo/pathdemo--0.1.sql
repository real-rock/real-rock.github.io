CREATE FUNCTION pathdemo_hello() RETURNS text
AS 'MODULE_PATHNAME', 'pathdemo_hello'
LANGUAGE C STRICT;
