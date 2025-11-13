ARG BUILD_FROM=ghcr.io/netbox-community/netbox:v4.4.6-3.4.2
FROM ${BUILD_FROM}

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gosu \
    jq \
    postgresql \
    postgresql-client \
    redis-server \
    redis-tools \
    tini \
    && rm -rf /var/lib/apt/lists/*

RUN if ! id -u netbox >/dev/null 2>&1; then \
    addgroup --system netbox && adduser --system --ingroup netbox netbox; \
    fi \
    && mkdir -p /data/postgres /data/redis /data/netbox/{media,reports,scripts} /run/postgresql \
    && chown -R postgres:postgres /data/postgres /run/postgresql \
    && chown -R redis:redis /data/redis \
    && chown -R netbox:netbox /data/netbox

COPY run.sh /usr/local/bin/addon-run.sh
RUN chmod +x /usr/local/bin/addon-run.sh

ENV PGDATA=/data/postgres \
    REDIS_DATA_DIR=/data/redis \
    NETBOX_DATA_DIR=/data/netbox \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/addon-run.sh"]
CMD ["/opt/netbox/docker-entrypoint.sh", "gunicorn"]
