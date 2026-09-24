# 2편부터 쓰는 실습 이미지. 1편 이미지(pg-internals:rel18, ../pg-01-process/Dockerfile)에
# 도구 몇 가지와 xid_wraparound 테스트 모듈(6편에서 사용)을 더한다.
FROM pg-internals:rel18

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      bsdextrautils xxd strace \
    && rm -rf /var/lib/apt/lists/* \
    && make -C /usr/src/postgres/src/test/modules/xid_wraparound install

USER postgres
WORKDIR /home/postgres
