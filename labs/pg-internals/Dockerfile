# PostgreSQL 인터널 연재 실습 이미지: Rocky Linux 9에서 REL_18_STABLE 커밋 39a0db1 소스를 그대로 빌드한다.
# 빌드 컨텍스트에 그 커밋의 소스 tarball(postgres-src.tar.gz)이 있어야 한다. README.md 참고.
FROM rockylinux:9

RUN dnf -y upgrade \
    && dnf -y install gcc make bison flex perl pkgconf readline-devel zlib-devel libicu-devel \
      procps-ng file vim-common less findutils diffutils which strace \
    && dnf clean all

ADD postgres-src.tar.gz /usr/src/postgres/
WORKDIR /usr/src/postgres
# world-bin: 서버와 contrib(pageinspect, pg_buffercache, pg_walinspect 등)
# xid_wraparound: 6편에서 xid를 빠르게 소모하는 데 쓰는 테스트 모듈
RUN ./configure --prefix=/usr/local/pgsql \
    && make -j"$(nproc)" world-bin \
    && make install-world-bin \
    && make -C src/test/modules/xid_wraparound install

RUN useradd -m -s /bin/bash postgres \
    && mkdir -p /var/lib/postgresql/data \
    && chown -R postgres:postgres /var/lib/postgresql
ENV PATH=/usr/local/pgsql/bin:$PATH \
    PGDATA=/var/lib/postgresql/data \
    LANG=C.UTF-8
USER postgres
WORKDIR /home/postgres
