#!/usr/bin/env bash
# Builds the two deployable artifacts. This is the only place images are produced,
# so CI, a laptop and a future migration to kaniko all run the same logic.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

SHA=""
if [ -f ci/glpi.sha256 ]; then
    SHA=$(awk -v v="$GLPI_VERSION" '!/^#/ && $1 == v { print $2; exit }' ci/glpi.sha256 || true)
fi

SHORT=$(printf '%s' "${GIT_COMMIT}" | cut -c1-7)
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

COMMON=(
    --build-arg "GLPI_VERSION=${GLPI_VERSION}"
    --label "org.opencontainers.image.revision=${GIT_COMMIT}"
    --label "org.opencontainers.image.version=${GLPI_VERSION}-b${BUILD_NUMBER:-0}"
    --label "org.opencontainers.image.created=${CREATED}"
)

if [ -n "${SHA}" ]; then
    COMMON+=(--build-arg "GLPI_SHA256=${SHA}")
    log "building with pinned checksum ${SHA}"
else
    log "building WITHOUT checksum verification"
fi

log "php-fpm image"
docker build "${COMMON[@]}" \
    --target php-fpm \
    --cache-from "${PHP_IMAGE}:${GLPI_VERSION}" \
    --tag "${PHP_IMAGE}:${TAG}" \
    --tag "${PHP_IMAGE}:sha-${SHORT}" \
    --tag "${PHP_IMAGE}:${GLPI_VERSION}" \
    .
ok "${PHP_IMAGE}:${TAG}"

log "nginx image"
docker build "${COMMON[@]}" \
    --target nginx \
    --cache-from "${WEB_IMAGE}:${GLPI_VERSION}" \
    --tag "${WEB_IMAGE}:${TAG}" \
    --tag "${WEB_IMAGE}:sha-${SHORT}" \
    --tag "${WEB_IMAGE}:${GLPI_VERSION}" \
    .
ok "${WEB_IMAGE}:${TAG}"

log "sizes"
docker image ls --format '    {{.Repository}}:{{.Tag}}  {{.Size}}' \
    "${PHP_IMAGE}:${TAG}" "${WEB_IMAGE}:${TAG}"
