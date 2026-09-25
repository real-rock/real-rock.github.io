# PostgreSQL 운영 연재 실습 이미지: Rocky Linux 9 + PGDG 공식 RPM(PostgreSQL 18)
FROM rockylinux:9

RUN dnf -y upgrade \
    && dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" \
    && dnf -qy module disable postgresql \
    && dnf install -y postgresql18-server postgresql18-contrib \
         procps-ng sysstat iproute lsof less glibc-langpack-en \
    && dnf clean all

# 컨테이너에는 systemd-tmpfiles가 돌지 않아 소켓 디렉터리를 직접 만든다
RUN mkdir -p /run/postgresql && chown postgres:postgres /run/postgresql

ENV PATH=/usr/pgsql-18/bin:$PATH \
    PGDATA=/var/lib/pgsql/18/data \
    LANG=en_US.UTF-8
USER postgres
WORKDIR /var/lib/pgsql
