#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/deploy.sh
source "$REPO_ROOT/shared/deploy.sh"
load_config
teardown_editor "Orca" "orca-workspace" "orca-editor" "orca-direct"
