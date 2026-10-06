#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/deploy.sh
source "$REPO_ROOT/shared/deploy.sh"
load_config
ORCA_IMAGE="${ORCA_IMAGE:?Set ORCA_IMAGE in config.env}"
render_devfile "$REPO_ROOT/devfile.yaml" --check

echo "=== Deploying Orca to namespace: $NAMESPACE ==="

# Step 1: Build and push
build_and_push_image "$ORCA_IMAGE" "$REPO_ROOT"

# Step 2: Create the direct route before startup so pairing advertises its hostname.
create_direct_route "orca-direct" 6768 controller.devfile.io/devworkspace_name "orca-workspace"

ROUTE_HOST=$(oc get route orca-direct -n "$NAMESPACE" -o jsonpath='{.spec.host}')
ORCA_PAIRING_ADDRESS="wss://${ROUTE_HOST}/"

# Step 3: DevWorkspaceTemplate
create_editor_template "$REPO_ROOT/devfile.yaml" "orca-editor"

# Step 4: DevWorkspace
create_workspace "orca-workspace" "orca-editor"

# Step 5: Wait for the workspace pod
wait_for_workspace "orca-workspace" 180s

# Step 6: Read the browser pairing URL from Orca's readiness contract.
echo "Waiting for Orca to start..."
WEB_URL=""
for _ in $(seq 1 60); do
  WEB_URL=$(oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- node -e '
    const fs = require("fs");
    const lines = fs.readFileSync("/projects/.devspaces-orca/ready.jsonl", "utf8").split("\n");
    for (const line of lines) {
      let ready;
      try { ready = JSON.parse(line); } catch { continue; }
      if (ready.type === "orca_server_ready" && ready.schemaVersion === 1 &&
          ready.pairing?.available && ready.pairing.webClientUrl) {
        process.stdout.write(ready.pairing.webClientUrl);
        process.exit(0);
      }
    }
    process.exit(1);
  ' 2>/dev/null || true)
  [ -n "$WEB_URL" ] && break
  sleep 3
done
if [ -z "$WEB_URL" ]; then
  echo "Orca did not publish a browser pairing URL. Check the startup logs:"
  echo "  oc exec $POD -c orca-runtime -n $NAMESPACE -- cat /orca/entrypoint-logs.txt"
  exit 1
fi

echo ""
echo "=== Orca is ready ==="
echo ""
echo "URL:      ${WEB_URL}"
echo "Shell:    oc exec -it $POD -c orca-runtime -n $NAMESPACE -- bash"
echo ""
echo "Start OpenCode in an Orca terminal and use /models to select a Red Hat AI model."
echo "Configure other providers in ~/.config/opencode/config.json."
echo "For Vertex AI, shell in and run:"
echo "  export PATH=/orca/npm-global/bin:/orca/google-cloud-sdk/bin:\$PATH"
echo "  gcloud auth application-default login --no-launch-browser"
