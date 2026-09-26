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
