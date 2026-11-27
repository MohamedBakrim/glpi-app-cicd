#!/usr/bin/env bash
# Waits for ArgoCD to report the app healthy, then makes one real request through
# the ingress. A green ArgoCD app with a 500 from the edge is not a deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

if [ -z "${ARGOCD_TOKEN:-}" ]; then
    echo "ARGOCD_TOKEN not set — skipping rollout verification"
    exit 0
fi
: "${ARGOCD_SERVER:?ARGOCD_SERVER is empty}"

need argocd

log "argocd login ${ARGOCD_SERVER}"
argocd login "${ARGOCD_SERVER}" \
    --auth-token "${ARGOCD_TOKEN}" \
    --grpc-web --insecure >/dev/null
ok "authenticated"

log "wait for app ${ARGOCD_APP} (sync + health, 10 min)"
argocd app wait "${ARGOCD_APP}" \
    --health --timeout 600 \
    --grpc-web --insecure
ok "app healthy"

if [ -n "${PUBLIC_URL}" ]; then
    log "edge check ${PUBLIC_URL}"
    for i in $(seq 1 20); do
        code=$(curl -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/" || true)
        # 200 = login page, 302 = redirected to login. Anything 5xx is a failure.
        case "${code}" in
            200|302) ok "HTTP ${code}"; break ;;
        esac
        [ "$i" -eq 20 ] && fail "edge returned ${code} after deploy"
        sleep 3
    done
fi

log "rollout verified"
