#!/usr/bin/env bash
# Push the immutable tags and record the manifest digest of each image.
#
# The digest is the real identity: the Helm chart pins "<version>@sha256:...", so a
# re-pushed tag can never silently change what the cluster runs. build.sh also
# pushes the floating <GLPI_VERSION> tag, but only as a build-cache seed.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

: "${REGISTRY_USER:?REGISTRY_USER is empty — bind the 'registry-creds' credential}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is empty — bind the 'registry-creds' credential}"

mkdir -p .ci-out
SHORT=$(printf '%s' "${GIT_COMMIT}" | cut -c1-7)

log "docker login ${REGISTRY}"
printf '%s' "${REGISTRY_PASSWORD}" \
    | docker login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin >/dev/null
ok "authenticated as ${REGISTRY_USER}"

# Everything human-readable goes to stderr; only the digest goes to stdout, so the
# function can be used in a command substitution.
publish() {
    local image="$1" tag digest
    for tag in "${TAG}" "sha-${SHORT}" "${GLPI_VERSION}"; do
        printf '\n\033[1;34m==> push %s:%s\033[0m\n' "${image}" "${tag}" >&2
        docker push "${image}:${tag}" >&2
    done
    digest=$(docker image inspect \
        --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
        "${image}:${TAG}" 2>/dev/null | cut -d@ -f2)
    [ -n "${digest}" ] || fail "could not read manifest digest for ${image}:${TAG}"
    printf '\033[1;32m  ok: %s -> %s\033[0m\n' "${image}" "${digest}" >&2
    printf '%s' "${digest}"
}

PHP_DIGEST=$(publish "${PHP_IMAGE}")
WEB_DIGEST=$(publish "${WEB_IMAGE}")

{
    printf 'PHP_DIGEST=%s\n' "${PHP_DIGEST}"
    printf 'WEB_DIGEST=%s\n' "${WEB_DIGEST}"
} > .ci-out/digests.env

log "digests"
sed 's/^/    /' .ci-out/digests.env

docker logout "${REGISTRY}" >/dev/null 2>&1 || true
ok "published ${TAG}"
