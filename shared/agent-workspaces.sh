# shellcheck shell=bash

# Stands in for a proposed CheCluster spec.devAgentEnvironments section:
#   ORCA_AGENT_NAMESPACE_TEMPLATE  namespace.template, e.g. <username>-agent-devspaces
#   ORCA_AGENT_RUNTIME_CLASS       runtimeClassName, e.g. kata
# The provisioner output (agent editor template, RBAC, and the automounted ConfigMap that
# points Orca at the agent namespace) is what che-operator would reconcile instead.

AGENT_ENVIRONMENT=orca-agent-environment
AGENT_EDITOR=orca-agent-editor
AGENT_PROVISIONER=orca-workspace-provisioner

agent_environments_enabled() {
  [ -n "${ORCA_AGENT_NAMESPACE_TEMPLATE:-}" ]
}

# Sets ORCA_AGENT_NAMESPACE from the template, the way Che resolves user namespaces.
resolve_agent_namespace() {
  agent_environments_enabled || return 0
  local username
  username=$(oc whoami) || return 1
  username=$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
  ORCA_AGENT_NAMESPACE="${ORCA_AGENT_NAMESPACE_TEMPLATE//<username>/$username}"
  if [[ ! "$ORCA_AGENT_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
      [ "${#ORCA_AGENT_NAMESPACE}" -gt 63 ] || [ "$ORCA_AGENT_NAMESPACE" = "$NAMESPACE" ]; then
    echo "ORCA_AGENT_NAMESPACE_TEMPLATE resolved to '$ORCA_AGENT_NAMESPACE', which is not a valid namespace separate from NAMESPACE." >&2
    return 1
  fi
}

check_agent_environment() {
  agent_environments_enabled || return 0
  resolve_agent_namespace || return 1
  # Just-in-time namespace creation belongs to che-operator; here it must already exist.
  if ! oc get project "$ORCA_AGENT_NAMESPACE" >/dev/null; then
    echo "Create the agent namespace first, for example: oc new-project $ORCA_AGENT_NAMESPACE" >&2
    return 1
  fi
  if [ -n "${ORCA_AGENT_RUNTIME_CLASS:-}" ]; then
    oc get runtimeclass "$ORCA_AGENT_RUNTIME_CLASS" >/dev/null || return 1
  fi
}

apply_agent_environment() {
  agent_environments_enabled || return 0
  echo "Configuring agent environments in namespace: $ORCA_AGENT_NAMESPACE"
  # Child workspaces use the same editor; the controller sets their pairing address.
  render_devfile "$REPO_ROOT/devfile.yaml" --template "$AGENT_EDITOR" |
    oc apply -n "$ORCA_AGENT_NAMESPACE" -f - || return 1
  # Every workspace in the user namespace may provision agents; none of them may read
  # Secrets, change RBAC, or create namespaces through this Role.
  cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${AGENT_PROVISIONER}
  namespace: ${ORCA_AGENT_NAMESPACE}
rules:
  - apiGroups: [workspace.devfile.io]
    resources: [devworkspaces]
    verbs: [create, get, patch, delete]
  - apiGroups: [workspace.devfile.io]
    resources: [devworkspacetemplates]
    resourceNames: [${AGENT_EDITOR}]
    verbs: [get]
  - apiGroups: ['']
    resources: [services]
    verbs: [create, get, delete]
  - apiGroups: ['']
    resources: [pods]
    verbs: [get, list]
  - apiGroups: ['']
    resources: [pods/exec]
    verbs: [get, create]
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [create, get, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${AGENT_PROVISIONER}
  namespace: ${ORCA_AGENT_NAMESPACE}
subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: system:serviceaccounts:${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${AGENT_PROVISIONER}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AGENT_ENVIRONMENT}
  namespace: ${NAMESPACE}
  labels:
    controller.devfile.io/mount-to-devworkspace: "true"
    controller.devfile.io/watch-configmap: "true"
  annotations:
    controller.devfile.io/mount-as: env
data:
  ORCA_AGENT_NAMESPACE: "${ORCA_AGENT_NAMESPACE}"
  ORCA_AGENT_RUNTIME_CLASS: "${ORCA_AGENT_RUNTIME_CLASS:-}"
EOF
}

teardown_agent_environment() {
  local controller="$1"
  oc delete configmap "$AGENT_ENVIRONMENT" -n "$NAMESPACE" --ignore-not-found || return 1
  agent_environments_enabled || return 0
  resolve_agent_namespace || return 1
  [ -n "$(oc get project "$ORCA_AGENT_NAMESPACE" --ignore-not-found -o name)" ] || return 0
  oc delete devworkspaces,services,routes -n "$ORCA_AGENT_NAMESPACE" \
    -l "orca.eclipse.org/controller-namespace=$NAMESPACE,orca.eclipse.org/controller=$controller" \
    --ignore-not-found || return 1
  oc delete rolebinding,role "$AGENT_PROVISIONER" -n "$ORCA_AGENT_NAMESPACE" --ignore-not-found || return 1
  oc delete devworkspacetemplate "$AGENT_EDITOR" -n "$ORCA_AGENT_NAMESPACE" --ignore-not-found
  # The namespace follows customer retention policy; never remove it here.
}
