#!/usr/bin/env bash
# Runs the REAL artifacts: install schema, boot fpm+nginx, assert the app answers
# and that nothing wrote to the PHP error log. This is the gate that a broken
# Dockerfile or a bad GLPI release has to pass before anything is published.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/config.sh
source ci/config.sh

mkdir -p .ci-out

COMPOSE=(docker compose -p "${SMOKE_PROJECT}" -f ci/docker-compose.test.yml)

on_exit() {
    local rc=$?
    "${COMPOSE[@]}" logs --no-color > .ci-out/compose.log 2>&1 || true
    if [ "$rc" -ne 0 ]; then
        "${COMPOSE[@]}" ps > .ci-out/compose-ps.txt 2>&1 || true
        printf '\n--- last 80 log lines ---\n'
        tail -n 80 .ci-out/compose.log || true
    fi
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    exit "$rc"
}
trap on_exit EXIT

# Probe from inside the compose network: works whether Jenkins runs on the host,
# in a container, or on another machine talking to the same daemon.
in_php() { "${COMPOSE[@]}" exec -T php "$@"; }
http_code() { in_php curl -s -o /dev/null -w '%{http_code}' "$1" | tr -d '\r'; }

log "start database"
"${COMPOSE[@]}" up -d --wait db
ok "mariadb healthy"

log "install schema (cold install, not an upgrade)"
"${COMPOSE[@]}" run --rm install
ok "database:install succeeded"

log "start application"
# --no-deps on purpose: `install` already ran and must not be re-triggered (it would
# wipe the schema while the app boots).
# php first: nginx fails hard at startup if its upstream name does not resolve yet.
"${COMPOSE[@]}" up -d --no-deps php
"${COMPOSE[@]}" up -d --no-deps web

log "wait for the front controller"
for i in $(seq 1 30); do
    if in_php curl -fsS -o /dev/null http://web:8080/ 2>/dev/null; then
        ok "responds after ${i}s"
        break
    fi
    [ "$i" -eq 30 ] && fail "app did not answer within 60s (see .ci-out/compose.log)"
    sleep 2
done

log "checks"
# 1. login page is a real page, not a redirect to the installer or an error page
body_size=$(in_php curl -fsS http://web:8080/ | wc -c | tr -d ' \r')
[ "$body_size" -gt 2000 ] || fail "login page suspiciously small (${body_size} bytes)"
ok "login page rendered (${body_size} bytes)"

# 2. REST API answers with auth required, not 500
code=$(http_code http://web:8080/apirest.php)
[ "$code" = "401" ] || fail "apirest.php returned ${code}, expected 401"
ok "apirest.php -> 401"

# 3. database is fully migrated for this release
in_php php bin/console database:is_up_to_date --env=production >/dev/null \
    || fail "database is not up to date after install"
ok "database:is_up_to_date"

# 4. the container really runs as the chart's UID
uid=$(in_php id -u | tr -d '\r')
[ "$uid" = "82" ] || fail "container runs as uid ${uid}, chart expects 82"
ok "runs as uid 82"

# 5. static assets are served by nginx without touching PHP
in_php curl -fsS -o /dev/null http://web:8080/index.php || fail "index.php not served"
ok "index.php served"

# 6. nothing was logged as a PHP error while doing all of the above
if "${COMPOSE[@]}" exec -T php sh -c 'test -s /var/lib/glpi/_log/php-errors.log'; then
    "${COMPOSE[@]}" exec -T php sh -c 'cat /var/lib/glpi/_log/php-errors.log' \
        | tee .ci-out/php-errors.log
    fail "PHP errors were logged during the smoke test"
fi
ok "no PHP errors logged"

# 6. the chart's hook scripts are present (warning until they are added)
missing=$("${COMPOSE[@]}" exec -T php sh -c '
    for s in glpi-verify-dir.sh glpi-db-install.sh glpi-db-upgrade.sh \
             glpi-db-configure.sh glpi-cache-configure.sh; do
        test -x "/usr/local/bin/$s" || echo "$s"
    done' | tr -d '\r')
if [ -n "$missing" ]; then
    echo "    WARNING: missing chart hook script(s):"
    echo "$missing" | sed 's/^/      - /'
    echo "    The Helm post-install/post-upgrade Jobs will fail until these exist in the image."
else
    ok "chart hook scripts present"
fi

log "smoke test passed"
