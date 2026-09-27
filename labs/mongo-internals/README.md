# MongoDB 인터널 연재 실습

[MongoDB 인터널](../../content/series/mongodb-인터널/_index.md) 연재 1~8편의 출력은 모두 여기서 실행한 로그에서 가져옵니다. 이 디렉터리는 Hugo 빌드 대상이 아니므로 사이트에 공개되지 않습니다.

- `Dockerfile`: Rocky Linux 9 + MongoDB 공식 RPM 8.0.32 + mongosh, 그리고 같은 버전의 WiredTiger 소스로 빌드한 `wt` 유틸리티
- `make-wt-src.sh`: `wt` 빌드용 소스 tarball(`wiredtiger-src.tar.gz`)을 만든다
- `lib/labkit.sh`: 공용 하네스 (`ct`, `msh`, `sess`, `fresh_replset` 등)
- `lib/replfmt.py`: mongosh 출력을 "프롬프트> 명령" + 결과로 짝짓는다 (`msh`, `sess`가 쓴다)
- `lib/verify-post.py`: 글의 console/mongosh/text 블록 출력 줄이 모두 실측 로그에 있는지 확인
- `mongo-NN-*/lab.sh`: 편마다 새 컨테이너에서 실습을 처음부터 끝까지 실행하고 `final-run.log`를 남김
- `run-all.sh`: 8편을 순서대로 실행

## 이미지 만들기

`wt`를 빌드할 WiredTiger 소스는 mongo 저장소 `r8.0.32`의 `src/third_party/wiredtiger`입니다. 이 사본은 CMake 파일이 빠져 있어서, 빠진 파일만 WiredTiger 저장소의 `mongodb-8.0` 브랜치에서 가져와 채웁니다. tarball은 저장소에 넣지 않습니다.

```console
$ labs/mongo-internals/make-wt-src.sh <mongo 저장소> <wiredtiger 저장소>
$ docker build -t mongo-internals:rocky9-8.0.32 labs/mongo-internals
$ labs/mongo-internals/run-all.sh
$ python3 labs/mongo-internals/lib/verify-post.py content/posts/mongodb/01-wiredtiger-architecture.md labs/mongo-internals/mongo-01-wiredtiger/final-run.log
```

이미지 빌드에는 `repo.mongodb.org`(RPM)와 Rocky Linux 미러 접속이 필요합니다.

## 하네스 쓰는 법

```bash
cd "$(dirname "$0")"
LAB=m05                      # 컨테이너 m05-1, m05-2 ..., 네트워크 m05-net
source ../lib/labkit.sh

step "0. 실습 환경"
fresh_standalone --wiredTigerCacheSizeGB 0.25     # 컨테이너 하나 + mongod
msh <<'JS'                                         # mongosh 대화형 세션처럼 기록
db.t.insertOne({a: 1})
JS
ct <<'EOF'                                          # 컨테이너 안 셸 명령
ls /data/db
EOF
```

- mongod의 dbPath는 `/data/db`, 로그는 `/data/mongod.log`(JSON 한 줄에 하나, `jq`로 뽑는다)입니다.
- `msh`는 빈 줄과 `//` 주석 줄을 보내지 않습니다. 여러 줄 명령은 둘째 줄부터 들여쓰거나 닫는 괄호로 시작해야 한 명령으로 묶입니다.
- `RSPROMPT=1`이면 프롬프트에 레플리카셋 상태가 붙습니다(`rs0 [direct: primary] test>`). 프롬프트를 만들 때마다 `hello`를 한 번 보내므로, 명령 수를 세는 실습에서는 끕니다.
- 레플리카셋은 `fresh_replset rs0 3` 뒤에 `rs.initiate`를 직접 부르고, `wait_primary 3`으로 primary 컨테이너 이름을 `PRIMARY`에 받습니다.
- 동시 세션: `sess_start A <컨테이너>`, `sess A "명령" [기다릴 초]`, `sess_wait A [초]`, `sess_end A`.

로그는 항상 한 번의 전체 실행 결과여야 합니다. 스크립트를 고치면 그 편을 처음부터 다시 실행하고 로그를 통째로 바꿉니다.
