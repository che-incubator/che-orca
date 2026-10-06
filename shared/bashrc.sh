# shellcheck shell=bash
SA_CA=/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
[ -f "$SA_CA" ] && export NODE_EXTRA_CA_CERTS="$SA_CA"

__git_ps1_minimal() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  [ -n "$branch" ] || return
  local dirty=""
  git diff --quiet --ignore-submodules 2>/dev/null || dirty="*"
  git diff --cached --quiet --ignore-submodules 2>/dev/null || dirty="${dirty}+"
  printf " (%s%s)" "$branch" "$dirty"
}

PS1='\[\e[1;34m\]\w\[\e[0;33m\]$(__git_ps1_minimal)\[\e[0m\] \$ '
