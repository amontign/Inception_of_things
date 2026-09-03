#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

diagnostics() {
  set +e
  printf '\n--- Part 3 diagnostics ---\n' >&2
  kube get nodes -o wide >&2
  kube get namespaces >&2
  kube -n "${ARGOCD_NAMESPACE}" get pods >&2
  kube -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o wide >&2
  kube -n "${ARGOCD_NAMESPACE}" describe application "${APP_NAME}" >&2
  kube -n "${APP_NAMESPACE}" get all,ingress >&2
  kube -n "${APP_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp >&2
  printf '%s\n' '--- End diagnostics ---' >&2
  set -e
}

fail_check() {
  warn "$*"
  diagnostics
  exit 1
}

wait_for_application() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local sync_status=""
  local health_status=""
  local last_status=""
  local current_status

  while ((SECONDS < deadline)); do
    sync_status="$(
      kube -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || true
    )"
    health_status="$(
      kube -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || true
    )"
    current_status="${sync_status:-Pending}/${health_status:-Pending}"
    if [[ "${current_status}" != "${last_status}" ]]; then
      printf 'Argo CD status: %s\n' "${current_status}"
      last_status="${current_status}"
    fi
    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      return
    fi
    sleep 5
  done

  fail_check "Argo CD did not become Synced/Healthy within ${WAIT_TIMEOUT_SECONDS} seconds."
}

wait_for_image() {
  local expected_image="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local live_image=""

  while ((SECONDS < deadline)); do
    live_image="$(
      kube -n "${APP_NAMESPACE}" get deployment "${APP_NAME}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
    )"
    [[ "${live_image}" == "${expected_image}" ]] && return
    sleep 3
  done

  fail_check "The live Deployment image is '${live_image:-missing}', expected '${expected_image}'."
}

wait_for_response() {
  local expected_response="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local response=""

  while ((SECONDS < deadline)); do
    response="$(
      curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${APP_HOST_PORT}/" 2>/dev/null || true
    )"
    [[ "${response}" == "${expected_response}" ]] && return
    sleep 3
  done

  fail_check "The application response was '${response:-unreachable}', expected '${expected_response}'."
}

main() {
  local expected_version="${1:-v1}"
  local expected_image
  local expected_response
  local pod_count

  (($# <= 1)) || die "Usage: $0 [v1|v2]"
  [[ "${expected_version}" =~ ^v[12]$ ]] || die "Usage: $0 [v1|v2]"
  require_positive_integer WAIT_TIMEOUT_SECONDS "${WAIT_TIMEOUT_SECONDS}"
  require_command k3d
  require_command kubectl
  require_command curl

  cluster_exists || die "K3d cluster '${CLUSTER_NAME}' does not exist. Run setup.sh first."
  kubectl config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1 ||
    die "kubectl context '${KUBE_CONTEXT}' does not exist."

  expected_image="${APP_IMAGE_REPOSITORY}:${expected_version}"
  expected_response="{\"status\":\"ok\", \"message\": \"${expected_version}\"}"

  log "Checking Kubernetes and Argo CD"
  kube get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 ||
    fail_check "Namespace '${ARGOCD_NAMESPACE}' is missing."
  kube get namespace "${APP_NAMESPACE}" >/dev/null 2>&1 ||
    fail_check "Namespace '${APP_NAMESPACE}' is missing."
  kube wait --for=condition=Ready node --all \
    --timeout="${WAIT_TIMEOUT_SECONDS}s" ||
    fail_check "The K3d node is not Ready."

  pod_count="$(
    kube -n "${ARGOCD_NAMESPACE}" get pods --no-headers 2>/dev/null |
      wc -l |
      tr -d '[:space:]'
  )"
  [[ "${pod_count}" =~ ^[1-9][0-9]*$ ]] ||
    fail_check "No Argo CD pods were found."
  kube -n "${ARGOCD_NAMESPACE}" wait \
    --for=condition=Ready pod --all \
    --timeout="${WAIT_TIMEOUT_SECONDS}s" ||
    fail_check "One or more Argo CD pods are not Ready."

  wait_for_application
  wait_for_image "${expected_image}"
  kube -n "${APP_NAMESPACE}" rollout status \
    "deployment/${APP_NAME}" \
    --timeout="${WAIT_TIMEOUT_SECONDS}s" ||
    fail_check "The ${APP_NAME} Deployment did not roll out."
  kube -n "${APP_NAMESPACE}" wait \
    --for=condition=Ready pod \
    -l "app.kubernetes.io/name=${APP_NAME}" \
    --timeout="${WAIT_TIMEOUT_SECONDS}s" ||
    fail_check "The ${APP_NAME} pod is not Ready."
  kube -n "${APP_NAMESPACE}" get ingress "${APP_NAME}" >/dev/null 2>&1 ||
    fail_check "The ${APP_NAME} Ingress is missing."

  log "Checking ${expected_image} through localhost:${APP_HOST_PORT}"
  wait_for_response "${expected_response}"

  success "Argo CD is Synced/Healthy and ${expected_image} returns ${expected_response}"
  printf '\n'
  kube get namespaces "${ARGOCD_NAMESPACE}" "${APP_NAMESPACE}"
  kube -n "${APP_NAMESPACE}" get pods -o wide
  kube -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o wide
}

main "$@"
