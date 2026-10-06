# shellcheck shell=bash

load_config() {
  if [ ! -f "$REPO_ROOT/config.env" ]; then
    echo "config.env not found. Copy from config.env.example and fill in your values:"
    echo "  cp config.env.example config.env"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config.env"
  NAMESPACE="${NAMESPACE:?Set NAMESPACE to your Dev Spaces user namespace in config.env}"
}

build_and_push_image() {
  local image="$1" editor_dir="$2"
  echo "Building image for linux/amd64..."
  podman build --platform linux/amd64 -f "$editor_dir/Containerfile" -t "$image" "$REPO_ROOT"
  echo "Pushing image..."
  podman push "$image"
}

render_devfile() (
  export ORCA_IMAGE GOOGLE_CLOUD_PROJECT CLOUD_ML_REGION \
    ORCA_PAIRING_ADDRESS REDHAT_AI_NAMESPACE
  python3 "$REPO_ROOT/shared/render-devfile.py" "$@"
)

create_editor_template() {
  local devfile="$1" editor="$2" manifest
  manifest=$(render_devfile "$devfile" --template "$editor") || return 1
  echo "Creating editor template..."
  printf '%s\n' "$manifest" | oc apply -n "$NAMESPACE" -f -
}

create_workspace() {
  local workspace="$1" editor="$2"
  echo "Creating workspace..."
  cat <<EOF | oc apply -n "$NAMESPACE" -f -
apiVersion: workspace.devfile.io/v1alpha2
kind: DevWorkspace
metadata:
  name: ${workspace}
  labels:
    che.eclipse.org/devworkspace: "true"
spec:
  started: true
  routingClass: che
  contributions:
    - name: editor
      kubernetes:
        name: ${editor}
  template:
    projects: []
EOF
}

wait_for_workspace() {
  local workspace="$1" timeout="${2:-180s}"
  local timeout_seconds="${timeout%s}" deadline remaining deployment pods
  local selector="controller.devfile.io/devworkspace_name=$workspace"
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -eq 0 ]; then
    echo "Workspace timeout must be a positive number of seconds: $timeout" >&2
    return 1
  fi
  deadline=$((SECONDS + 10#$timeout_seconds))
  POD=""
  echo "Waiting for workspace deployment..."
  deployment=$(oc wait --for=create deployment -n "$NAMESPACE" -l "$selector" \
    --timeout="$timeout" --request-timeout="$timeout" -o name) || return 1

  remaining=$((deadline - SECONDS))
  if [ "$remaining" -le 0 ]; then
    echo "Workspace $workspace was not ready within $timeout." >&2
    return 1
  fi
  echo "Waiting for workspace rollout..."
  oc rollout status "$deployment" -n "$NAMESPACE" \
    --timeout="${remaining}s" --request-timeout="${remaining}s" || return 1

  remaining=$((deadline - SECONDS))
  if [ "$remaining" -le 0 ]; then
    echo "Workspace $workspace was not ready within $timeout." >&2
    return 1
  fi
  # Resolve the pod after the rollout, when replacements have finished.
  # Rows are name, Ready condition, and deletion time, sorted oldest first.
  pods=$(oc get pods -n "$NAMESPACE" -l "$selector" --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp --request-timeout="${remaining}s" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}') || return 1
  POD=$(printf '%s\n' "$pods" | awk -F '\t' '$1 !~ /cleanup/ && $2 == "True" && $3 == "" {pod=$1} END {print pod}')
  if [ -z "$POD" ]; then
    echo "No active ready pod found for workspace $workspace after rollout." >&2
    return 1
  fi
  echo "Pod ready: $POD"
}

create_direct_route() {
  local route="$1" port="$2" selector_key="$3" selector_value="$4"
  echo "Creating direct route..."
  cat <<EOF | oc apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Service
metadata:
  name: ${route}
spec:
  selector:
    ${selector_key}: ${selector_value}
  ports:
    - port: ${port}
      targetPort: ${port}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${route}
spec:
  to:
    kind: Service
    name: ${route}
  port:
    targetPort: ${port}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
}

teardown_editor() {
  local label="$1" workspace="$2" editor="$3" route="$4"
  echo "=== Tearing down $label from namespace: $NAMESPACE ==="
  oc delete devworkspace "$workspace" -n "$NAMESPACE" --ignore-not-found
  oc delete devworkspacetemplate "$editor" -n "$NAMESPACE" --ignore-not-found
  oc delete service "$route" -n "$NAMESPACE" --ignore-not-found
  oc delete route "$route" -n "$NAMESPACE" --ignore-not-found
  echo "Done."
}
