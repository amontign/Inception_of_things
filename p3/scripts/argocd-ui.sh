#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  local local_port="${1:-8080}"
  local encoded_password=""
  local initial_password=""

  (($# <= 1)) || die "Usage: $0 [local-port]"
  [[ "${local_port}" =~ ^[0-9]+$ ]] || die "The local port must be numeric."
  ((local_port >= 1024 && local_port <= 65535)) ||
    die "The local port must be between 1024 and 65535."
  require_command kubectl
  require_command base64

  cluster_exists || die "K3d cluster '${CLUSTER_NAME}' does not exist. Run setup.sh first."
  kube -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server \
    --timeout="${WAIT_TIMEOUT_SECONDS}s"
  port_in_use "${local_port}" && die "TCP port ${local_port} is already in use."

  encoded_password="$(
    kube -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null || true
  )"
  if [[ -n "${encoded_password}" ]]; then
    initial_password="$(printf '%s' "${encoded_password}" | base64 -d)"
    printf 'Username: admin\n'
    printf 'Initial password: %s\n' "${initial_password}"
  else
    warn "The initial admin secret is absent, so the password was probably changed or deleted."
  fi

  printf 'Argo CD URL: https://127.0.0.1:%s\n' "${local_port}"
  printf 'The development certificate is self-signed. Press Ctrl-C to stop forwarding.\n'

  exec kubectl --context "${KUBE_CONTEXT}" \
    -n "${ARGOCD_NAMESPACE}" \
    port-forward service/argocd-server \
    "${local_port}:443" \
    --address=127.0.0.1
}

main "$@"
