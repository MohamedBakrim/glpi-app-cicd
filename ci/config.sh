# shellcheck shell=bash
# Shared defaults. Jenkins environment variables always win; these only make the
# scripts runnable locally (bash ci/smoke.sh on your laptop).
#
# Image names deliberately match the Helm chart
# (MohamedBakrim/glpi-chart-cicd → values.yaml: image.repository / nginx.image.repository),
# so a pipeline run only has to change the tag, never the repository.
: "${REGISTRY:=docker.io}"
: "${IMAGE_NAMESPACE:=mdbak}"

: "${PHP_IMAGE:=${REGISTRY}/${IMAGE_NAMESPACE}/glpi-php-fpm}"
: "${WEB_IMAGE:=${REGISTRY}/${IMAGE_NAMESPACE}/glpi-nginx}"

: "${GLPI_VERSION:=12.0.2}"
: "${TAG:=${GLPI_VERSION}-local}"
: "${GIT_COMMIT:=local}"
: "${SMOKE_PROJECT:=glpi-ci-local}"
: "${TRIVY_SEVERITY:=HIGH,CRITICAL}"

# GitOps repository contract — must match the chart's values structure.
# Chart keys: image.{repository,tag} and nginx.image.{repository,tag}
: "${GITOPS_REPO_URL:=}"
: "${GITOPS_VALUES_FILE:=values-prod.yaml}"
: "${YQ_PHP_REPO:=.image.repository}"
: "${YQ_PHP_TAG:=.image.tag}"
: "${YQ_WEB_REPO:=.nginx.image.repository}"
: "${YQ_WEB_TAG:=.nginx.image.tag}"

: "${ARGOCD_SERVER:=}"
: "${ARGOCD_APP:=glpi}"
: "${PUBLIC_URL:=}"

export REGISTRY IMAGE_NAMESPACE PHP_IMAGE WEB_IMAGE GLPI_VERSION TAG GIT_COMMIT
export SMOKE_PROJECT TRIVY_SEVERITY GITOPS_REPO_URL GITOPS_VALUES_FILE
export YQ_PHP_REPO YQ_PHP_TAG YQ_WEB_REPO YQ_WEB_TAG ARGOCD_SERVER ARGOCD_APP PUBLIC_URL

# --- helpers -----------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ok: %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  FAIL: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
