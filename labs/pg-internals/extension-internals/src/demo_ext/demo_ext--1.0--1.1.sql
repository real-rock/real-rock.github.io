\echo Use "ALTER EXTENSION demo_ext UPDATE TO '1.1'" to load this file. \quit

CREATE FUNCTION demo_sub(integer, integer) RETURNS integer
AS 'MODULE_PATHNAME', 'demo_sub'
LANGUAGE C STRICT IMMUTABLE;
