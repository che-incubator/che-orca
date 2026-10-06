#!/bin/bash

# shellcheck source=shared/runtime.sh
source /orca/runtime.sh
setup_runtime /orca/bashrc.sh || exit 1

export PATH="/orca/npm-global/bin:/orca/google-cloud-sdk/bin:${PATH}"
export SHELL=/bin/bash

PERSIST="${PROJECTS_ROOT:-/projects}/.devspaces-orca"
mkdir -p "$PERSIST/gcloud" "$PERSIST/orca-home" \
         "$PERSIST/opencode-config" "$PERSIST/opencode-share" "$PERSIST/opencode-state" || exit 1
chmod 700 "$PERSIST" || exit 1
touch "$PERSIST/ready.jsonl" || exit 1
chmod 600 "$PERSIST/ready.jsonl" || exit 1

export ORCA_USER_DATA="$PERSIST/orca-home"
export ORCA_WEB_ROOT=/orca/web
export ORCA_VERSION=1.4.219
export CLOUDSDK_CONFIG="$PERSIST/gcloud"

mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state"
ln -sfn "$PERSIST/opencode-config" "$HOME/.config/opencode"
ln -sfn "$PERSIST/opencode-share" "$HOME/.local/share/opencode"
ln -sfn "$PERSIST/opencode-state" "$HOME/.local/state/opencode"
ln -sfn "$PERSIST/gcloud" "$HOME/.config/gcloud"

if [ -f /orca/discover-models.sh ]; then
  bash /orca/discover-models.sh "${PROJECTS_ROOT:-/projects}/opencode.json"
fi
# Load discovered providers even inside repositories and worktrees under /projects.
if [ -s "${PROJECTS_ROOT:-/projects}/opencode.json" ]; then
  export OPENCODE_CONFIG="${PROJECTS_ROOT:-/projects}/opencode.json"
fi

cd "${PROJECTS_ROOT:-/projects}" || exit 1

ARGS=(--bind 0.0.0.0 --port 6768 --json)
if [ -n "$ORCA_PAIRING_ADDRESS" ]; then
  ARGS+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
fi

# Capture the readiness JSON, including the browser pairing URL, for deploy.sh.
while true; do
  /orca/runtime/bun-runtime /orca/runtime/orcad.js "${ARGS[@]}" > "$PERSIST/ready.jsonl" &
  ORCA_PID=$!
  wait "$ORCA_PID"
  STATUS=$?
  if [ "$STATUS" -eq 78 ]; then
    echo "Orca configuration error. Check the data directory and pairing address."
    exit "$STATUS"
  fi
  echo "Orca exited ($STATUS), restarting in 2s..."
  sleep 2
done
