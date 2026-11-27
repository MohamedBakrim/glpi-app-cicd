#!/usr/bin/env bash
# Fail fast, before we spend 10 minutes building images on a typo or a broken daemon.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

log "toolchain"
need docker
need git
need curl
docker version --format '    client={{.Client.Version}}  server={{.Server.Version}}'
docker compose version | sed 's/^/    /'

log "artifact"
echo "    php image : ${PHP_IMAGE}:${TAG}"
echo "    web image : ${WEB_IMAGE}:${TAG}"
echo "    glpi      : ${GLPI_VERSION} (commit ${GIT_COMMIT})"

log "verify upstream tag exists"
curl -fsI "https://github.com/glpi-project/glpi/archive/refs/tags/${GLPI_VERSION}.tar.gz" \
    >/dev/null || fail "GLPI_VERSION=${GLPI_VERSION} has no tag on github.com/glpi-project/glpi"

if [ -s ci/glpi.sha256 ] && grep -qE "^${GLPI_VERSION}[[:space:]]+[0-9a-f]{64}" ci/glpi.sha256; then
    ok "archive checksum pinned in ci/glpi.sha256"
else
    echo "    WARNING: ${GLPI_VERSION} is not pinned. Run: ./ci/pin-version.sh ${GLPI_VERSION}"
fi

log "dockerfile lint (advisory)"
docker build --check . 2>&1 | sed 's/^/    /' || true

log "warm the build cache"
docker pull "${PHP_IMAGE}:${GLPI_VERSION}" >/dev/null 2>&1 || echo "    no cached php image yet"
docker pull "${WEB_IMAGE}:${GLPI_VERSION}" >/dev/null 2>&1 || echo "    no cached web image yet"

mkdir -p .ci-out
ok "ready"
