#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

anonymous_repository_preflight() {
  local repository_url
  local target_revision
  local source_path
  local repository_slug
  local remote_deployment_url

  repository_url="$(application_source_value repoURL)"
  target_revision="$(application_source_value targetRevision)"
  source_path="$(application_source_value path)"

  [[ -n "${repository_url}" ]] || die "The Argo CD Application has no repoURL."
  [[ -n "${target_revision}" ]] || die "The Argo CD Application has no targetRevision."
  [[ -n "${source_path}" ]] || die "The Argo CD Application has no source path."
  [[ "${repository_url}" == https://github.com/* ]] ||
    die "The GitOps source must be an HTTPS GitHub URL; got '${repository_url}'."

  log "Checking anonymous access to ${repository_url}"
  if ! GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false \
    git -c credential.helper= -c core.askPass=/bin/false \
      ls-remote --exit-code "${repository_url}" "refs/heads/${target_revision}" \
      >/dev/null 2>&1; then
    die "Argo CD cannot anonymously read branch '${target_revision}' from ${repository_url}. Make the repository public before running setup.sh. No cluster changes were made."
  fi

  repository_slug="${repository_url#https://github.com/}"
  repository_slug="${repository_slug%.git}"
  remote_deployment_url="https://raw.githubusercontent.com/${repository_slug}/${target_revision}/${source_path}/deployment.yaml"
  if ! curl --fail --silent --show-error --location \
    --max-time 20 --output /dev/null "${remote_deployment_url}"; then
    die "The public branch does not contain ${source_path}/deployment.yaml yet. Commit and push p3 before running setup.sh. No cluster changes were made."
  fi

  success "The GitOps repository and application path are anonymously readable."
}

wait_for_argocd_pods() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local pod_count=0

  while ((SECONDS < deadline)); do
    pod_count="$(
      kube -n "${ARGOCD_NAMESPACE}" get pods --no-headers 2>/dev/null |
        wc -l |
        tr -d '[:space:]'
    )"
    if [[ "${pod_count}" =~ ^[1-9][0-9]*$ ]]; then
      break
    fi
    sleep 2
  done

  [[ "${pod_count}" =~ ^[1-9][0-9]*$ ]] ||
    die "Argo CD did not create any pods within ${WAIT_TIMEOUT_SECONDS} seconds."

  kube -n "${ARGOCD_NAMESPACE}" wait \
    --for=condition=Ready pod --all \
    --timeout="${WAIT_TIMEOUT_SECONDS}s"
}

main() {
  local expected_version
  local argocd_install_url

  ((EUID != 0)) ||
    die "Run setup.sh as your normal user, not with sudo, so K3d writes to your kubeconfig."
  require_positive_integer WAIT_TIMEOUT_SECONDS "${WAIT_TIMEOUT_SECONDS}"

  for command_name in docker git curl k3d kubectl argocd; do
    require_command "${command_name}"
  done
  require_file "${K3D_CONFIG_FILE}"
  require_file "${NAMESPACES_MANIFEST}"
  require_file "${ARGOCD_APPLICATION_MANIFEST}"
  require_file "${APP_DEPLOYMENT_MANIFEST}"

  docker info >/dev/null 2>&1 ||
    die "Docker is not accessible as the current user. Run 'newgrp docker' or log out and back in, then retry."

  expected_version="$(manifest_image_version)"
  [[ "${expected_version}" =~ ^v[12]$ ]] ||
    die "The application Deployment must use ${APP_IMAGE_REPOSITORY}:v1 or :v2."

  anonymous_repository_preflight

  if cluster_exists; then
    log "Reusing the existing K3d cluster '${CLUSTER_NAME}'"
    if ! kube get nodes >/dev/null 2>&1; then
      k3d cluster start "${CLUSTER_NAME}" \
        --wait \
        --timeout "${WAIT_TIMEOUT_SECONDS}s"
    fi
  else
    port_in_use "${KUBE_API_PORT}" &&
      die "TCP port ${KUBE_API_PORT} is already in use. Free it before creating the cluster."
    port_in_use "${APP_HOST_PORT}" &&
      die "TCP port ${APP_HOST_PORT} is already in use. Free it before creating the cluster."

    log "Creating K3d cluster '${CLUSTER_NAME}' with ${K3S_IMAGE}"
    k3d cluster create "${CLUSTER_NAME}" \
      --config "${K3D_CONFIG_FILE}" \
      --image "${K3S_IMAGE}"
  fi

  k3d kubeconfig merge "${CLUSTER_NAME}" \
    --kubeconfig-merge-default \
    --kubeconfig-switch-context \
    >/dev/null
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
  kube wait --for=condition=Ready node --all \
    --timeout="${WAIT_TIMEOUT_SECONDS}s"

  log "Creating the '${ARGOCD_NAMESPACE}' and '${APP_NAMESPACE}' namespaces"
  kube apply -f "${NAMESPACES_MANIFEST}"

  argocd_install_url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  log "Installing Argo CD ${ARGOCD_VERSION}"
  kube -n "${ARGOCD_NAMESPACE}" apply \
    --server-side \
    --force-conflicts \
    -f "${argocd_install_url}"
  kube wait --for=condition=Established \
    customresourcedefinition/applications.argoproj.io \
    --timeout="${WAIT_TIMEOUT_SECONDS}s"
  wait_for_argocd_pods

  log "Creating the Argo CD Application '${APP_NAME}'"
  kube apply -f "${ARGOCD_APPLICATION_MANIFEST}"

  "${SCRIPT_DIR}/check.sh" "${expected_version}"

  log "Part 3 is ready"
  printf 'Application: http://localhost:%s/\n' "${APP_HOST_PORT}"
  printf 'Argo CD UI:  %s/argocd-ui.sh 8080\n' "${SCRIPT_DIR}"
}

main "$@"
