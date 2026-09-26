# PostgreSQL 인터널 연재 실습

[PostgreSQL 인터널](../../content/series/) 연재 01~10편의 출력은 모두 여기서 실행한 로그에서 가져옵니다. 이 디렉터리는 Hugo 빌드 대상이 아니므로 사이트에 공개되지 않습니다.

- `Dockerfile`: Rocky Linux 9에서 PostgreSQL `REL_18_STABLE` 커밋 `39a0db1`(18.6) 소스를 빌드한 이미지
- `lib/labkit.sh`: 공용 하네스 (`pg`, `sess` 등). 01편만 자체 함수를 쓴다
- `lib/verify-post.py`: 글의 console/psql/text 블록 출력 줄이 모두 실측 로그에 있는지 확인
- `pg-NN-*/lab.sh`: 편마다 새 컨테이너에서 실습을 처음부터 끝까지 실행하고 `final-run.log`를 남김
- `run-all.sh`: 10편을 순서대로 실행 (시간을 재는 실습이 있어 동시에 돌리지 않는다)

소스 tarball은 저장소에 넣지 않습니다. 기준 커밋을 `git archive`로 묶어 Dockerfile 옆에 두고 빌드합니다.

```console
$ git -C <postgres 저장소> archive --format=tar.gz -o postgres-src.tar.gz 39a0db101105eab3f4044d11c609c58b9459ea16
$ docker build -t pg-internals:rocky9-rel18 .
$ labs/pg-internals/run-all.sh
$ python3 labs/pg-internals/lib/verify-post.py content/posts/postgresql/01-process-architecture.md labs/pg-internals/pg-01-process/final-run.log
```

로그는 항상 한 번의 전체 실행 결과여야 합니다. 스크립트를 고치면 그 편을 처음부터 다시 실행하고 로그를 통째로 바꿉니다.

## 단독 글: extension 동작 원리

[PostgreSQL extension은 어떻게 동작하는가](../../content/posts/postgresql/extension-internals.md)의 출력은 `extension-internals/`에서 가져옵니다. 이 실습은 두 가지를 더 준비해야 합니다.

- strace가 든 이미지: `Dockerfile`에 strace를 추가했으므로 이미지를 다시 빌드했다면 그대로 쓰면 됩니다(`IMAGE=pg-internals:rocky9-rel18`). 2026-09-26 실측은 네트워크 없이 하려고, 기존 이미지에 strace 바이너리만 더한 `extension-internals/Dockerfile.strace`로 만든 `pg-internals:rocky9-rel18-strace`를 썼습니다.
- PostgreSQL 17.11 소스: 17용으로 빌드한 모듈이 18에서 거부되는 모습을 보려고 컨테이너 안에서 17을 빌드합니다. 이 tarball도 저장소에 넣지 않습니다.

```console
$ git -C <postgres 저장소> archive --format=tar.gz -o labs/pg-internals/extension-internals/postgres17-src.tar.gz REL_17_11
$ docker build -t pg-internals:rocky9-rel18-strace -f labs/pg-internals/extension-internals/Dockerfile.strace labs/pg-internals/extension-internals
$ bash labs/pg-internals/extension-internals/lab.sh
$ python3 labs/pg-internals/lib/verify-post.py content/posts/postgresql/extension-internals.md labs/pg-internals/extension-internals/final-run.log
```

`src/`에는 글에서 쓰는 데모 extension(`demo_ext`, `pathdemo`)과 일부러 잘못 만든 모듈(`nomagic`, `abi17`), `dltest.c`가 있습니다. 컨테이너 이름은 다른 실습과 겹치지 않게 `pglab-ext`를 씁니다.
