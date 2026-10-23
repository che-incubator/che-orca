#!/bin/bash
# Run after building the editor image, without touching a cluster or host files.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:?Usage: tests/injector.sh EDITOR_IMAGE}"

podman run -i --rm --tmpfs /orca:mode=0777 \
  --volume "$REPO_ROOT/entrypoint-init-container.sh:/entrypoint-init-container.sh:ro" \
  --entrypoint /bin/bash "$IMAGE" -s <<'SH'
set -e
/entrypoint-init-container.sh >/dev/null
printf 'stale runtime' > /orca/runtime/orcad.js
/entrypoint-init-container.sh >/dev/null
test ! -d /orca/runtime/runtime
test ! -d /orca/web/web
/entrypoint-init-container.sh >/dev/null
node - <<'JS'
const assert = require('node:assert/strict')
const fs = require('node:fs')
for (const file of ['runtime/orcad.js', 'web/web-index.html', 'bin/opencode']) {
  assert.ok(fs.readFileSync(`/opt/orca/${file}`).equals(fs.readFileSync(`/orca/${file}`)), file)
}
assert.equal(fs.readlinkSync('/orca/bin/orca-ide'), 'orca')
console.log('Repeated injection refreshes stale files without nesting.')
JS
SH
