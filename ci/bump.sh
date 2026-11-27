#!/usr/bin/env bash
# The only "deploy" action Jenkins performs: change the pinned tags in the GitOps
# repo. ArgoCD notices the commit and does the actual rollout.
#
# Writes tags in the chart's existing style: "12.0.2@sha256:<manifest digest>",
# never a bare floating tag.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

: "${GITOPS_REPO_URL:?GITOPS_REPO_URL is empty}"
: "${GITOPS_TOKEN:?GITOPS_TOKEN is empty — bind the 'gitops-token' credential}"

need git
need yq

# Digests produced by publish.sh. Fall back to the build tag so a manual run of
# bump.sh does not silently write an empty string.
if [ -f .ci-out/digests.env ]; then
    # shellcheck disable=SC1091
    . .ci-out/digests.env
fi
: "${PHP_DIGEST:?PHP_DIGEST missing — run ci/publish.sh first}"
: "${WEB_DIGEST:?WEB_DIGEST missing — run ci/publish.sh first}"

PHP_TAG="${GLPI_VERSION}@${PHP_DIGEST}"
WEB_TAG="${GLPI_VERSION}@${WEB_DIGEST}"

WORK=".ci-out/gitops"
rm -rf "${WORK}"
mkdir -p .ci-out

# HTTPS + token keeps the setup self-contained. A read/write SSH deploy key bound
# with sshagent{} is the better production choice — swap it here when ready.
AUTH_URL=$(printf '%s' "${GITOPS_REPO_URL}" \
    | sed -E "s#^https://#https://x-access-token:${GITOPS_TOKEN}@#")

log "clone ${GITOPS_REPO_URL}"
git clone --quiet --depth 1 "${AUTH_URL}" "${WORK}"
cd "${WORK}"

[ -f "${GITOPS_VALUES_FILE}" ] || fail "values file not found in GitOps repo: ${GITOPS_VALUES_FILE}"

log "pin images"
PHP_REPO="${PHP_IMAGE}" PHP_TAG="${PHP_TAG}" WEB_REPO="${WEB_IMAGE}" WEB_TAG="${WEB_TAG}" \
yq -i "
    ${YQ_PHP_REPO} = strenv(PHP_REPO) |
    ${YQ_PHP_TAG}  = strenv(PHP_TAG) |
    ${YQ_WEB_REPO} = strenv(WEB_REPO) |
    ${YQ_WEB_TAG}  = strenv(WEB_TAG)
" "${GITOPS_VALUES_FILE}"

git config user.name  "jenkins-ci"
git config user.email "jenkins-ci@${CI_DOMAIN:-localhost}"
git add "${GITOPS_VALUES_FILE}"

if git diff --cached --quiet; then
    ok "values already pinned to ${PHP_TAG}, nothing to commit"
    exit 0
fi

git commit --quiet \
    -m "chore(glpi): deploy ${GLPI_VERSION}" \
    -m "php=${PHP_IMAGE}@${PHP_DIGEST}" \
    -m "web=${WEB_IMAGE}@${WEB_DIGEST}"

log "push"
git push --quiet origin HEAD
ok "GitOps repo updated — ArgoCD will reconcile"
