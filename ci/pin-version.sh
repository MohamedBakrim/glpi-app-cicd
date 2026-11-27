#!/usr/bin/env bash
# Pin the checksum of an upstream release archive. Run this once per GLPI upgrade,
# review the diff, commit it. After that ci/build.sh verifies every build.
#
#   ./ci/pin-version.sh 12.0.2
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ci/pin-version.sh <glpi-tag>}"
FILE="ci/glpi.sha256"

[ -f "${FILE}" ] || printf '# glpi  sha256(github archive)\n' > "${FILE}"

echo "downloading glpi ${VERSION} ..."
SHA=$(curl -fsSL "https://github.com/glpi-project/glpi/archive/refs/tags/${VERSION}.tar.gz" \
      | sha256sum | cut -d' ' -f1)

[ -n "${SHA}" ] || { echo "download failed" >&2; exit 1; }

if grep -qE "^${VERSION}[[:space:]]" "${FILE}"; then
    sed -i -E "s|^${VERSION}[[:space:]].*|${VERSION}  ${SHA}|" "${FILE}"
else
    printf '%s  %s\n' "${VERSION}" "${SHA}" >> "${FILE}"
fi

echo
echo "pinned:"
grep -E "^${VERSION}[[:space:]]" "${FILE}"
echo
echo "review and commit: git add ${FILE} && git commit -m 'chore: pin glpi ${VERSION}'"
