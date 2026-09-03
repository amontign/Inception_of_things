#!/usr/bin/env bash

# Shared, non-user-facing settings and helpers for the Part 3 scripts.
# Variables in this file are consumed by the scripts that source it.
# shellcheck disable=SC2034

P3_SCRIPTS_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 || exit 1
  pwd -P
)"
P3_DIR="$(cd -- "${P3_SCRIPTS_DIR}/.." >/dev/null 2>&1 && pwd -P)"
CONFS_DIR="${P3_DIR}/confs"

K3D_CONFIG_FILE="${CONFS_DIR}/k3d.yaml"
NAMESPACES_MANIFEST="${CONFS_DIR}/namespaces.yaml"
ARGOCD_APPLICATION_MANIFEST="${CONFS_DIR}/argocd/application.yaml"
APP_DEPLOYMENT_MANIFEST="${CONFS_DIR}/app/deployment.yaml"

DOCKER_VERSION="${DOCKER_VERSION:-29.7.2}"
MIN_DOCKER_VERSION="${MIN_DOCKER_VERSION:-24.0.0}"
K3D_VERSION="${K3D_VERSION:-v5.9.0}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.36.4-k3s1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.4}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.2}"
BINFMT_IMAGE="${BINFMT_IMAGE:-tonistiigi/binfmt:qemu-v10.2.3-68}"

CLUSTER_NAME="${CLUSTER_NAME:-iot}"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
ARGOCD_NAMESPACE="argocd"
APP_NAMESPACE="dev"
APP_NAME="wil-playground"
APP_IMAGE_REPOSITORY="wil42/playground"

KUBE_API_PORT=6550
APP_HOST_PORT=8888
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"

log() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32mOK:\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 ||
    die "Required command '${command_name}' is not installed."
}

require_file() {
  local path="$1"

  [[ -f "${path}" ]] || die "Required file is missing: ${path}"
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] ||
    die "${name} must be a positive integer; got '${value}'."
}

linux_architecture() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf 'amd64\n'
      ;;
    aarch64 | arm64)
      printf 'arm64\n'
      ;;
    *)
      die "Unsupported CPU architecture: $(uname -m). Only AMD64 and ARM64 are supported."
      ;;
  esac
}

version_at_least() {
  local installed="$1"
  local minimum="$2"
  local first

  first="$(printf '%s\n%s\n' "${installed}" "${minimum}" | sort -V | head -n 1)"
  [[ "${first}" == "${minimum}" ]]
}

cluster_exists() {
  command -v k3d >/dev/null 2>&1 || return 1

  k3d cluster list --no-headers 2>/dev/null |
    awk -v expected="${CLUSTER_NAME}" '
      $1 == expected { found = 1 }
      END { exit(found ? 0 : 1) }
    '
}

port_in_use() {
  local port="$1"

  (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

kube() {
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

application_source_value() {
  local key="$1"

  awk -v wanted="${key}:" '$1 == wanted { print $2; exit }' \
    "${ARGOCD_APPLICATION_MANIFEST}"
}

manifest_image_version() {
  sed -nE \
    "s|^[[:space:]]*image:[[:space:]]*${APP_IMAGE_REPOSITORY}:(v[12])[[:space:]]*$|\\1|p" \
    "${APP_DEPLOYMENT_MANIFEST}" |
    head -n 1
}
