#!/usr/bin/env bash
# Always-runs step: never leave containers, workspaces or credentials behind.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

docker compose -p "${SMOKE_PROJECT}" -f ci/docker-compose.test.yml \
    down -v --remove-orphans >/dev/null 2>&1 || true

# contains the GitOps clone, including its tokenized remote URL
rm -rf .ci-out/gitops

echo "cleanup done"
