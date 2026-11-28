# syntax=docker/dockerfile:1.7

# =============================================================================
#  GLPI 12 — runtime images
#
#  Targets (publish both, with the same tag):
#    php-fpm  -> glpi-php : PHP-FPM application container
#    nginx    -> glpi-web : static assets + reverse proxy
#
#  Example:
#    docker build --target php-fpm --build-arg GLPI_VERSION=12.0.2 -t REG/glpi-php:12.0.2 .
#    docker build --target nginx   --build-arg GLPI_VERSION=12.0.2 -t REG/glpi-web:12.0.2 .
# =============================================================================

ARG PHP_VERSION=8.3
ARG NODE_VERSION=24
ARG GLPI_VERSION=12.0.2
# Pass this from CI to verify the downloaded archive. Empty = skip (not recommended).
ARG GLPI_SHA256=

# -----------------------------------------------------------------------------
# 0. Node source stage
#
# `COPY --from=` does NOT expand build args in an image reference, so the node
# binaries have to come from a named stage. Keep this before php-base.
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS node-src

# -----------------------------------------------------------------------------
# 1. Shared PHP base — single source of truth for PHP + extensions
#
# Both the builder and the runtime inherit this stage, so the extension set used
# to build dependencies can never drift from the one available at runtime.
# -----------------------------------------------------------------------------
FROM php:${PHP_VERSION}-fpm-bookworm AS php-base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# NOTE: the *-dev packages and the compiler toolchain ($PHPIZE_DEPS, shipped by
# the official php image) intentionally remain in this layer for now.
# Do NOT slim this with `apt-get purge --auto-remove <lib>-dev`: autoremove also
# drops the runtime .so files (libicu, libzip, ...) that the compiled extensions
# link against, and php-fpm then dies on start with "undefined symbol".
# The safe optimisation is a separate build stage that copies only the .so files
# into a lean runtime — do that after the CI pipeline is green.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        bash patch gettext perl git unzip curl ca-certificates \
        libbz2-dev libfreetype6-dev libjpeg62-turbo-dev libpng-dev \
        libicu-dev libldap2-dev libzip-dev libxml2-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure ldap \
        --with-libdir="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath bz2 exif gd intl ldap mysqli opcache soap zip \
    && pecl install apcu redis \
    && docker-php-ext-enable apcu redis \
    && rm -rf /var/lib/apt/lists/* /tmp/pear /tmp/*.tgz

# Chart contract: run as UID/GID 82.
RUN groupadd --gid 82 glpi \
    && useradd --uid 82 --gid 82 \
       --create-home --home-dir /home/glpi \
       --shell /usr/sbin/nologin glpi

# Pool settings go into a late-loading file so they win over the distro defaults.
# `user`/`group` only apply when the container is started as root (defence in
# depth); the image itself runs as 82 and FPM then logs a harmless NOTICE.
RUN printf '%s\n' \
        '[global]' \
        'pid = /tmp/php-fpm.pid' \
        '' \
        '[www]' \
        'user = glpi' \
        'group = glpi' \
        'clear_env = no' \
        'catch_workers_output = yes' \
        'pm = dynamic' \
        'pm.max_children = 20' \
        'pm.start_servers = 4' \
        'pm.min_spare_servers = 2' \
        'pm.max_spare_servers = 8' \
        > /usr/local/etc/php-fpm.d/zz-glpi.conf

# Production PHP settings. `max_input_vars` matters: GLPI admin forms exceed the
# default of 1000 fields and silently lose the tail of the form.
RUN printf '%s\n' \
        'memory_limit=512M' \
        'upload_max_filesize=100M' \
        'post_max_size=100M' \
        'max_execution_time=300' \
        'max_input_time=300' \
        'max_input_vars=5000' \
        'date.timezone=UTC' \
        'display_errors=Off' \
        'log_errors=On' \
        'expose_php=Off' \
        'zend.assertions=-1' \
        'session.save_path=/tmp' \
        'realpath_cache_size=4096k' \
        'realpath_cache_ttl=600' \
        'opcache.enable=1' \
        'opcache.enable_cli=0' \
        'opcache.memory_consumption=256' \
        'opcache.max_accelerated_files=20000' \
        'opcache.validate_timestamps=0' \
        > /usr/local/etc/php/conf.d/zz-glpi.ini


# -----------------------------------------------------------------------------
# 2. GLPI builder — upstream release source + upstream build script
# -----------------------------------------------------------------------------
FROM php-base AS builder

ARG NODE_VERSION=24
ARG GLPI_VERSION
ARG GLPI_SHA256

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

COPY --from=node-src /usr/local/bin/node /usr/local/bin/node
COPY --from=node-src /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

WORKDIR /usr/src/glpi

RUN set -eux; \
    curl -fsSL -o /tmp/glpi.tar.gz \
        "https://github.com/glpi-project/glpi/archive/refs/tags/${GLPI_VERSION}.tar.gz"; \
    if [ -n "${GLPI_SHA256}" ]; then \
        echo "${GLPI_SHA256}  /tmp/glpi.tar.gz" | sha256sum -c -; \
    else \
        echo "WARNING: GLPI_SHA256 is not set, archive integrity is not verified"; \
    fi; \
    tar -xzf /tmp/glpi.tar.gz --strip-components=1 -C /usr/src/glpi; \
    rm /tmp/glpi.tar.gz; \
    chown -R glpi:glpi /usr/src/glpi

# build_glpi.sh runs composer/npm as the current user and needs a writable HOME
# for their caches. It also refuses to run when a .git directory is present.
ENV HOME=/home/glpi
USER glpi

# Installs dependencies (with dev deps, needed by the build steps), compiles
# locales and SCSS, minifies assets, then prunes the dev files (tests/, tools/,
# node_modules/, composer.json, ...). Output: a clean production tree.
RUN ./tools/build_glpi.sh


# -----------------------------------------------------------------------------
# 3. PHP-FPM runtime
# -----------------------------------------------------------------------------
FROM php-base AS php-fpm

LABEL org.opencontainers.image.title="glpi-php-fpm" \
      org.opencontainers.image.description="GLPI 12 application runtime (PHP-FPM)" \
      org.opencontainers.image.source="https://github.com/glpi-project/glpi"

WORKDIR /var/www/html

COPY --from=builder --chown=82:82 /usr/src/glpi/ /var/www/html/

# GLPI resolves its writable locations from these variables. The Helm chart
# overrides them via ConfigMap, but the defaults must match its contract:
#   GLPI_CONFIG_DIR=/etc/glpi/config, GLPI_VAR_DIR=/var/lib/glpi
ENV GLPI_CONFIG_DIR=/etc/glpi/config \
    GLPI_VAR_DIR=/var/lib/glpi \
    GLPI_MARKETPLACE_DIR=/var/www/html/marketplace \
    GLPI_LOG_DIR=/var/lib/glpi/_log \
    HOME=/var/lib/glpi

# Pre-create the writable tree with the right ownership. Under Docker, a named
# volume mounted on an existing directory inherits this ownership; a bind mount
# or a PVC does NOT — the chart fixes that with fsGroup 82 and its verify-dir job.
RUN mkdir -p \
        /etc/glpi/config \
        /var/lib/glpi/_log \
        /var/lib/glpi/_cache \
        /var/lib/glpi/_tmp \
        /var/lib/glpi/_uploads \
        /var/lib/glpi/_rss \
        /var/www/html/marketplace \
    && chown -R 82:82 /etc/glpi /var/lib/glpi /var/www/html/marketplace \
    && chmod -R 750 /etc/glpi /var/lib/glpi

# REQUIRED by the chart's hook Jobs (post-install/post-upgrade chain):
#   glpi-verify-dir.sh  glpi-db-install.sh  glpi-db-upgrade.sh
#   glpi-db-configure.sh  glpi-cache-configure.sh
# Uncomment once those scripts are added to docker/ in this repository:
#
# COPY --chown=82:82 docker/glpi-*.sh /usr/local/bin/
# RUN chmod 755 /usr/local/bin/glpi-*.sh

USER 82:82

EXPOSE 9000
# SIGQUIT = graceful FPM shutdown/restart (SIGTERM is immediate).
STOPSIGNAL SIGQUIT

CMD ["php-fpm"]


# -----------------------------------------------------------------------------
# 4. Nginx runtime — static assets + proxy to PHP-FPM
# -----------------------------------------------------------------------------
FROM alpine:3.23 AS nginx

RUN apk upgrade --no-cache \
    && apk add --no-cache nginx

LABEL org.opencontainers.image.title="glpi-nginx" \
      org.opencontainers.image.description="GLPI 12 web frontend (nginx)" \
      org.opencontainers.image.source="https://github.com/glpi-project/glpi"

COPY --from=builder --chown=82:82 /usr/src/glpi/public/ /var/www/html/public/

# Base config (pid/temp paths in /tmp) + a default vhost. The chart replaces
# /etc/nginx/conf.d/default.conf with its own ConfigMap; because the base config
# includes conf.d, that override works instead of being silently ignored.
COPY nginx/nginx.conf    /etc/nginx/nginx.conf
COPY nginx/default.conf  /etc/nginx/conf.d/default.conf

USER 82:82

EXPOSE 8080
STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
