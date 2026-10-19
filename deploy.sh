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

# Step 2: DevWorkspaceTemplate
create_editor_template "$REPO_ROOT/devfile.yaml" "orca-editor"

# Step 3: DevWorkspace
create_workspace "orca-workspace" "orca-editor"

# Step 4: Wait for the workspace pod
wait_for_workspace "orca-workspace" 180s

# Step 5: Wait for orcad's readiness line. The page pairs on load once it appears.
echo "Waiting for Orca to start..."
READY=""
for _ in $(seq 1 60); do
  if oc exec "$POD" -c orca-runtime -n "$NAMESPACE" -- \
    grep -q '"type":"orca_server_ready"' /projects/.che-orca/ready.jsonl 2>/dev/null; then
    READY=1
    break
  fi
  sleep 3
done
if [ -z "$READY" ]; then
  echo "Orca did not start. Check the startup logs:"
  echo "  oc exec $POD -c orca-runtime -n $NAMESPACE -- cat /orca/entrypoint-logs.txt"
  exit 1
fi

URL=$(oc get devworkspace orca-workspace -n "$NAMESPACE" -o jsonpath='{.status.mainUrl}')
echo ""
echo "=== Orca is ready ==="
echo ""
echo "URL:      ${URL}"
echo "Shell:    oc exec -it $POD -c orca-runtime -n $NAMESPACE -- bash"
