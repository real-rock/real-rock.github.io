# MongoDB 인터널 연재 실습 이미지: Rocky Linux 9 + MongoDB 공식 RPM 8.0.32 + mongosh
# 1~3편에서 .wt 파일을 직접 열어 보려고, 같은 태그(r8.0.32)에 들어 있는 WiredTiger 소스로 wt 유틸리티를 빌드한다.
# 빌드 컨텍스트에 make-wt-src.sh로 만든 wiredtiger-src.tar.gz가 있어야 한다. README.md 참고.
FROM rockylinux:9

COPY mongodb-org-8.0.repo /etc/yum.repos.d/
RUN dnf -y upgrade \
    && dnf -y install dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf -y install mongodb-org-8.0.32 mongodb-org-server-8.0.32 mongodb-org-mongos-8.0.32 \
         mongodb-org-tools-8.0.32 mongodb-mongosh \
         procps-ng iproute lsof strace less findutils diffutils which file vim-common python3 python3-devel jq \
         gcc gcc-c++ make cmake snappy-devel libzstd-devel zlib-devel \
    && dnf clean all

# wt 유틸리티: mongod가 쓰는 snappy/zstd/zlib 압축 extension도 같이 빌드한다
ADD wiredtiger-src.tar.gz /usr/src/
RUN cmake -S /usr/src/wiredtiger -B /usr/src/wiredtiger/build \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DENABLE_SNAPPY=1 -DENABLE_ZSTD=1 -DENABLE_ZLIB=1 -DENABLE_PYTHON=0 \
      -DHAVE_UNITTEST=0 -DENABLE_STATIC=0 -DWT_STANDALONE_BUILD=0 \
    && cmake --build /usr/src/wiredtiger/build -j"$(nproc)" --target wt \
         wiredtiger_snappy wiredtiger_zstd wiredtiger_zlib \
    && install -m 755 /usr/src/wiredtiger/build/wt /usr/local/bin/wt.bin \
    && mkdir -p /usr/local/lib/wt \
    && find /usr/src/wiredtiger/build -name 'libwiredtiger*.so*' -exec cp -a {} /usr/local/lib/wt/ \; \
    && rm -rf /usr/src/wiredtiger/build

# wt: 압축 extension을 늘 싣고 실행하는 래퍼 (mongod 기본 압축이 snappy라서 없으면 파일을 못 읽는다)
RUN printf '%s\n' '#!/bin/bash' \
      'EXT="extensions=[/usr/local/lib/wt/libwiredtiger_snappy.so,/usr/local/lib/wt/libwiredtiger_zstd.so,/usr/local/lib/wt/libwiredtiger_zlib.so]"' \
      'exec env LD_LIBRARY_PATH=/usr/local/lib/wt /usr/local/bin/wt.bin -C "$EXT" "$@"' > /usr/local/bin/wt \
    && chmod 755 /usr/local/bin/wt \
    && mkdir -p /data/db && chown -R mongod:mongod /data

ENV LANG=C.UTF-8
USER mongod
WORKDIR /data
