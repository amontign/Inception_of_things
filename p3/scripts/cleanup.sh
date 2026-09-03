#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

usage() {
  printf 'Usage: %s [--force]\n' "$0"
}

main() {
  local force=0
  local answer=""

  while (($# > 0)); do
    case "$1" in
      --force | -f)
        force=1
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  require_command k3d
  if ! cluster_exists; then
    success "K3d cluster '${CLUSTER_NAME}' does not exist; nothing was deleted."
    return
  fi

  if ((force == 0)); then
    [[ -t 0 ]] || die "Refusing a non-interactive deletion without --force."
    printf "Delete only the K3d cluster '%s'? [y/N] " "${CLUSTER_NAME}"
    read -r answer
    case "${answer}" in
      y | Y | yes | YES) ;;
      *)
        printf 'Cancelled.\n'
        return
        ;;
    esac
  fi

  log "Deleting only K3d cluster '${CLUSTER_NAME}'"
  k3d cluster delete "${CLUSTER_NAME}"
  success "Cluster '${CLUSTER_NAME}' was deleted. Docker, images, tools, and other clusters were preserved."
}

main "$@"
