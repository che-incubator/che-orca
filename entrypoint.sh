#!/bin/bash

# shellcheck source=shared/runtime.sh
source /orca/runtime.sh
setup_runtime /orca/bashrc.sh || exit 1

export PATH="/orca/bin:${PATH}"
export SHELL=/bin/bash

PERSIST="${PROJECTS_ROOT:-/projects}/.che-orca"
mkdir -p "$PERSIST/orca-home" || exit 1
chmod 700 "$PERSIST" || exit 1
touch "$PERSIST/ready.jsonl" || exit 1
chmod 600 "$PERSIST/ready.jsonl" || exit 1

export ORCA_USER_DATA="$PERSIST/orca-home"
export ORCA_USER_DATA_PATH="$ORCA_USER_DATA"
export ORCA_WEB_ROOT=/orca/web
export ORCA_VERSION=1.4.219

cd "${PROJECTS_ROOT:-/projects}" || exit 1

ARGS=(--bind 0.0.0.0 --port 6768 --json)
if [ -n "$ORCA_PAIRING_ADDRESS" ]; then
  ARGS+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
fi

# Register the Git repositories Che cloned under /projects. orcad prints its
# readiness line only after the CLI socket and orca-runtime.json are in place.
# Orca returns the existing entry for a known path, so this is safe on every start.
register_projects() {
  local dir
  for dir in "${PROJECTS_ROOT:-/projects}"/*/; do
    [ -d "${dir}.git" ] || continue
    if orca repo add --path "${dir%/}" >/dev/null; then
      echo "Registered ${dir%/} in Orca"
    else
      echo "Could not register ${dir%/} in Orca"
    fi
  done
}

# Install Orca's skills and status hooks for the agents on PATH. They live in the
# home directory, which Che recreates with the container, so a marker in /tmp
# skips the work when only orcad restarts. mkdir claims it atomically, and a
# failure releases it so the next orcad start retries.
configure_agents() {
  local marker=/tmp/che-orca-agents-configured agents=() ok=true
  mkdir "$marker" 2>/dev/null || return
  command -v claude >/dev/null && agents+=(claude-code)
  command -v codex >/dev/null && agents+=(codex)
  command -v opencode >/dev/null && agents+=(opencode)
  if [ "${#agents[@]}" -eq 0 ]; then
    echo "No claude, codex, or opencode on PATH; skipping Orca skills"
    rmdir "$marker"
    return
  fi
  if orca skills install --all --agent "$(IFS=,; echo "${agents[*]}")" >/dev/null 2>&1; then
    echo "Installed Orca skills for ${agents[*]}"
  else
    echo "Could not install Orca skills for ${agents[*]}"
    ok=false
  fi
  # orcad writes hook files only when the setting changes, and it defaults to on.
  # OpenCode gets its plugin from Orca's terminals instead.
  if command -v claude >/dev/null || command -v codex >/dev/null; then
    if orca agent hooks off >/dev/null && orca agent hooks on >/dev/null; then
      echo "Installed Orca agent status hooks"
    else
      echo "Could not install Orca agent status hooks"
      ok=false
    fi
  fi
  "$ok" || rmdir "$marker"
}

setup_orca() {
  register_projects
  if [ -n "${DEVWORKSPACE_NAME:-}" ]; then
    orca host name --name "$DEVWORKSPACE_NAME" >/dev/null ||
      echo "Could not set the Orca host name"
  fi
  configure_agents
}

# Wait for the readiness line, then set up Orca in the background while this
# keeps draining output, so orcad never blocks on or writes to a closed pipe.
register_when_ready() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *'"type":"orca_server_ready"'*)
        setup_orca &
        break
        ;;
    esac
  done
  cat >/dev/null
}

# Capture the readiness JSON, including the browser pairing URL, for deploy.sh.
while true; do
  /orca/runtime/bun-runtime /orca/runtime/orcad.js "${ARGS[@]}" \
    > >(tee "$PERSIST/ready.jsonl" | register_when_ready) &
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
