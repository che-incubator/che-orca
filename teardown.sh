#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/deploy.sh
source "$REPO_ROOT/shared/deploy.sh"
# shellcheck source=shared/agent-workspaces.sh
source "$REPO_ROOT/shared/agent-workspaces.sh"
load_config
teardown_agent_environment "orca-workspace"
teardown_editor "Orca" "orca-workspace" "orca-editor"
