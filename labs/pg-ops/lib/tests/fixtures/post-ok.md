본문

```psql
postgres=# SHOW data_checksums
 data_checksums
----------------
 on
(1 row)
A=# UPDATE t SET v = 2 WHERE id = 1;
ERROR:  canceling statement due to lock timeout
```

```console
$ df -h /var/lib/pgsql
...
overlay          59G   12G   44G  22% /
```

```sql
-- sql 블록은 검사하지 않는다
SELECT 1;
```
