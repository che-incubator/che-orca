# shellcheck shell=bash

setup_runtime() {
  local bashrc="$1" source_line service_ca
  umask 077

  # OpenShift containers run with an arbitrary UID in GID 0.
  if ! whoami &>/dev/null && [ -w /etc/passwd ]; then
    printf 'default:x:%s:0:default user:%s:/sbin/nologin\n' "$(id -u)" "$HOME" >> /etc/passwd || return 1
  fi

  printf -v source_line 'source %q' "$bashrc"
  if [ -f "$bashrc" ] && ! grep -Fqx "$source_line" "$HOME/.bashrc" 2>/dev/null; then
    printf '%s\n' "$source_line" >> "$HOME/.bashrc" || return 1
  fi

  service_ca=/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
  if [ -f "$service_ca" ]; then
    export NODE_EXTRA_CA_CERTS="$service_ca"
  fi
  return 0
}
