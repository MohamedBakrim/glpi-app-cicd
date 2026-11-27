#!/usr/bin/env bash
# Vulnerability gate. Trivy runs as a container so the Jenkins controller needs no
# extra tooling — only the docker socket it already has.
#
# NOTE: do not bind-mount the workspace into the trivy container. Jenkins usually
# talks to the *host* daemon, so a path inside the Jenkins container does not exist
# on the host. Output is streamed and captured on the Jenkins side instead.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

mkdir -p .ci-out
RC=0

scan() {
    local image="$1" out="$2" rc
    log "scanning ${image} (${TRIVY_SEVERITY})"

    set +e
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        aquasec/trivy:latest image \
        --scanners vuln \
        --severity "${TRIVY_SEVERITY}" \
        --ignore-unfixed \
        --no-progress \
        --timeout 15m \
        --format table \
        --exit-code 1 \
        "${image}" 2>&1 | tee ".ci-out/${out}" | tail -n 40 | sed 's/^/    /'
    rc=${PIPESTATUS[0]}
    set -e

    if [ "${rc}" -ne 0 ]; then
        echo "  vulnerabilities found in ${image}"
        RC=1
    else
        ok "${image}"
    fi
}

scan "${PHP_IMAGE}:${TAG}" trivy-php.txt
scan "${WEB_IMAGE}:${TAG}" trivy-web.txt

if [ "$RC" -ne 0 ]; then
    fail "image scan failed — fix the base image or add a reviewed exception here"
fi
