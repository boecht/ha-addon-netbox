# syntax=docker/dockerfile:1.9

# Builder inherits from the official NetBox container; Home Assistant injects BUILD_FROM.
ARG BUILD_FROM=ghcr.io/netbox-community/netbox:v4.4.6-3.4.2@sha256:150fb9808d633712a75ad57ba364fa38caab3a88d123c470967fd3b9b2f32d9c

FROM scratch AS get-pip
ADD --checksum=sha256:dffc3658baada4ef383f31c3c672d4e5e306a6e376cee8bee5dbdf1385525104 \
    https://bootstrap.pypa.io/get-pip.py /get-pip.py

FROM ${BUILD_FROM}

# Provenance build args (must be declared after FROM)
ARG IMAGE_COMMIT=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_TAG=unknown

LABEL org.opencontainers.image.title="NetBox Home Assistant Add-on" \
    org.opencontainers.image.source="https://github.com/boecht/ha-addon-netbox" \
    org.opencontainers.image.licenses="Apache-2.0"

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Base OS packages: Gosu for privilege dropping, PostgreSQL/Redis for embedded services,
# jq for option parsing, and tini for tidy signal handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    fping \
    gosu \
    jq \
    postgresql \
    postgresql-client \
    redis-server \
    redis-tools \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Ensure runtime directories exist with predictable permissions even before first launch.
RUN if ! id -u netbox >/dev/null 2>&1; then \
    addgroup --system netbox && adduser --system --ingroup netbox netbox; \
    fi \
    && mkdir -p /data/postgres /data/redis /data/netbox/{media,reports,scripts} /run/postgresql \
    && chown -R postgres:postgres /data/postgres /run/postgresql \
    && chown -R redis:redis /data/redis \
    && chown -R netbox:netbox /data/netbox

# Install extra NetBox plugins that the add-on exposes as defaults. Versions are pinned
# for reproducibility across architectures.
RUN --mount=type=bind,from=get-pip,source=/get-pip.py,target=/tmp/getpip.py \
    /opt/netbox/venv/bin/python /tmp/getpip.py \
    && /opt/netbox/venv/bin/pip install --no-cache-dir \
    netbox-napalm-plugin==0.3.3 \
    netbox-ping==0.54 \
    netbox-topology-views==4.4.0

# Persist provenance and base image so runtime logs can always show what was built
RUN mkdir -p /etc/netbox \
 && echo "${BUILD_FROM}" > /etc/netbox/base_image \
 && commit_val=${IMAGE_COMMIT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} \
 && source_val=${IMAGE_SOURCE:-local-build} \
 && tag_val=${IMAGE_TAG:-dev} \
 && echo "$commit_val" > /etc/netbox/image_commit \
 && echo "$source_val" > /etc/netbox/image_source \
 && echo "$tag_val" > /etc/netbox/image_tag

# Home Assistant entrypoint takes over from upstream to orchestrate services.
COPY run.sh /usr/local/bin/addon-run.sh
RUN chmod +x /usr/local/bin/addon-run.sh

ENV PGDATA=/data/postgres \
    REDIS_DATA_DIR=/data/redis \
    NETBOX_DATA_DIR=/data/netbox \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    IMAGE_COMMIT_FILE=/etc/netbox/image_commit \
    IMAGE_SOURCE_FILE=/etc/netbox/image_source \
    IMAGE_TAG_FILE=/etc/netbox/image_tag \
    BASE_IMAGE_FILE=/etc/netbox/base_image

# tini ensures signals propagate to all subprocesses launched by addon-run.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/addon-run.sh"]
CMD ["/opt/netbox/docker-entrypoint.sh", "/opt/netbox/launch-netbox.sh"]
