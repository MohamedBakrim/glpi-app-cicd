#!/usr/bin/env bash
# Create the glpi-app multibranch job and scan its branches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

J="${JENKINS_URL:-http://192.168.1.50:8080}"
J="${J%/}"
U="${JENKINS_ADMIN_USER:-admin}"
P="${JENKINS_ADMIN_PASSWORD:-}"
JOB=glpi-app

if [ -z "$P" ]; then
    echo "Set JENKINS_ADMIN_PASSWORD to your Jenkins password or API token" >&2
    exit 2
fi

COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT
AUTH=(-u "$U:$P" -b "$COOKIE_JAR" -c "$COOKIE_JAR")

curl -fsS "${AUTH[@]}" "$J/api/json" >/dev/null || {
    echo "Jenkins is not answering at $J (or the credentials are wrong)" >&2
    exit 1
}

CRUMB_JSON=$(curl -fsS "${AUTH[@]}" "$J/crumbIssuer/api/json" 2>/dev/null || true)
CRUMB=$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<<"$CRUMB_JSON")
CRUMB_FIELD=$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<<"$CRUMB_JSON")
HDR=()
if [ -n "$CRUMB" ]; then
    HDR=(-H "${CRUMB_FIELD:-Jenkins-Crumb}: ${CRUMB}")
fi

if curl -fsS "${AUTH[@]}" "$J/job/${JOB}/api/json" >/dev/null 2>&1; then
    echo "==> job ${JOB} already exists"
else
    echo "==> creating multibranch job ${JOB}"
    curl -fsS "${AUTH[@]}" "${HDR[@]}" \
        -H 'Content-Type: application/xml' \
        --data-binary "@$SCRIPT_DIR/multibranch.xml" \
        "$J/createItem?name=${JOB}" >/dev/null
fi

echo "==> triggering branch indexing"
curl -fsS "${AUTH[@]}" "${HDR[@]}" -X POST "$J/job/${JOB}/build?delay=0sec" >/dev/null

echo "==> job: $J/job/${JOB}/"
