# PostgreSQL 운영 연재 실습

[PostgreSQL 운영](../../content/series/postgresql-운영/_index.md) 연재의 모든 출력은 여기서 재현한 캡처에서 가져옵니다. 이 디렉터리는 Hugo 빌드 대상이 아니므로 사이트에 공개되지 않습니다.

- `Dockerfile`: Rocky Linux 9 + PGDG 공식 RPM(PostgreSQL 18)
- `lib/labkit.sh`: 시나리오 공용 하네스 (`q`, `pg`, `sess` 등)
- `lib/verify-post.py`: 글의 console/psql/text 블록 줄이 모두 캡처에 있는지 확인
- `smoke.sh`: 이미지가 연재의 전제(Rocky 9, PostgreSQL 18, checksum, contrib)를 만족하는지 확인
- `scenarios/NN-<slug>/reproduce.sh`: 편마다 장애를 재현하고 `out/`에 캡처를 남김

```console
$ docker build -t pg-ops:rocky9-pg18 labs/pg-ops
$ labs/pg-ops/smoke.sh
$ labs/pg-ops/scenarios/01-diagnostic-toolkit/reproduce.sh
$ python3 labs/pg-ops/lib/verify-post.py content/posts/postgresql-ops/01-diagnostic-toolkit.md labs/pg-ops/scenarios/01-diagnostic-toolkit/out/capture.txt
```

캡처는 항상 한 번의 전체 실행 결과여야 합니다. 스크립트를 고치면 처음부터 다시 실행하고 캡처를 통째로 바꿉니다.
