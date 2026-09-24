# REL_18_STABLE 브랜치 소스(git archive HEAD)를 그대로 빌드한 실습용 이미지
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bison flex pkg-config \
      libreadline-dev zlib1g-dev libicu-dev \
      procps psmisc iproute2 less ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ADD postgres-src.tar.gz /usr/src/postgres/
WORKDIR /usr/src/postgres
RUN ./configure --prefix=/usr/local/pgsql \
    && make -j"$(nproc)" world-bin \
    && make install-world-bin

RUN useradd -m -s /bin/bash postgres \
    && mkdir -p /var/lib/postgresql/data \
    && chown -R postgres:postgres /var/lib/postgresql
ENV PATH=/usr/local/pgsql/bin:$PATH \
    PGDATA=/var/lib/postgresql/data \
    LANG=C.UTF-8
USER postgres
WORKDIR /home/postgres
