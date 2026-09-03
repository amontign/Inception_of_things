#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

temporary_directory=""
docker_group_changed=0

cleanup_temporary_directory() {
  if [[ -n "${temporary_directory}" && -d "${temporary_directory}" ]]; then
    rm -rf -- "${temporary_directory}"
  fi
}

trap cleanup_temporary_directory EXIT

as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    sudo "$@"
  fi
}

package_is_installed() {
  local package="$1"

  dpkg-query -W -f='${db:Status-Abbrev}\n' "${package}" 2>/dev/null |
    grep -q '^ii '
}

docker_is_usable_as_root() {
  command -v docker >/dev/null 2>&1 && as_root docker info >/dev/null 2>&1
}

download_file() {
  local url="$1"
  local output="$2"

  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --output "${output}" \
    "${url}"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] ||
    die "Checksum verification failed for $(basename -- "${file}")."
}

install_docker() {
  local docker_repository_url
  local docker_codename
  local docker_package_version=""
  local package
  local -a conflicting_packages=()
  local -a docker_packages

  if docker_is_usable_as_root; then
    local installed_version
    installed_version="$(as_root docker version --format '{{.Server.Version}}')"
    version_at_least "${installed_version}" "${MIN_DOCKER_VERSION}" ||
      die "Docker ${installed_version} is older than the supported minimum ${MIN_DOCKER_VERSION}. Upgrade it manually before continuing."
    success "Keeping the existing compatible Docker Engine ${installed_version}."
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
    if docker_is_usable_as_root; then
      success "Started the existing Docker Engine."
      return
    fi
  fi

  for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
    if package_is_installed "${package}"; then
      conflicting_packages+=("${package}")
    fi
  done

  if ((${#conflicting_packages[@]} > 0)); then
    die "Docker Engine is not usable and conflicting packages are installed: ${conflicting_packages[*]}. Review and remove them manually so this script cannot destroy an existing container setup."
  fi

  docker_repository_url="https://download.docker.com/linux/${ID}"
  docker_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "${docker_codename}" ]] ||
    die "Could not determine the ${ID} release codename from /etc/os-release."

  log "Configuring Docker's official apt repository"
  download_file "${docker_repository_url}/gpg" "${temporary_directory}/docker.asc"
  as_root install -d -m 0755 /etc/apt/keyrings
  as_root install -m 0644 "${temporary_directory}/docker.asc" /etc/apt/keyrings/docker.asc

  {
    printf 'Types: deb\n'
    printf 'URIs: %s\n' "${docker_repository_url}"
    printf 'Suites: %s\n' "${docker_codename}"
    printf 'Components: stable\n'
    printf 'Architectures: %s\n' "$(dpkg --print-architecture)"
    printf 'Signed-By: /etc/apt/keyrings/docker.asc\n'
  } >"${temporary_directory}/docker.sources"
  as_root install -m 0644 \
    "${temporary_directory}/docker.sources" \
    /etc/apt/sources.list.d/docker.sources

  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq

  if [[ "${DOCKER_VERSION}" != "latest" ]]; then
    docker_package_version="$(
      apt-cache madison docker-ce |
        awk -F '|' -v wanted="5:${DOCKER_VERSION}-" '
          {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            if (index($2, wanted) == 1) {
              print $2
              exit
            }
          }
        '
    )"
    [[ -n "${docker_package_version}" ]] ||
      die "Docker ${DOCKER_VERSION} is not available for ${ID} ${docker_codename}. Set DOCKER_VERSION=latest or choose a version listed by 'apt-cache madison docker-ce'."
  fi

  docker_packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
  )
  if [[ -n "${docker_package_version}" ]]; then
    docker_packages[0]="docker-ce=${docker_package_version}"
    docker_packages[1]="docker-ce-cli=${docker_package_version}"
  fi

  log "Installing Docker Engine ${DOCKER_VERSION}"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "${docker_packages[@]}"
  as_root systemctl enable --now docker
  docker_is_usable_as_root || die "Docker Engine was installed but its daemon is not usable."
  success "Docker Engine is installed and running."
}

configure_docker_group() {
  local target_user="$1"

  [[ "${target_user}" != "root" ]] || return
  id -u "${target_user}" >/dev/null 2>&1 ||
    die "Cannot configure Docker access for unknown user '${target_user}'."

  if ! getent group docker >/dev/null 2>&1; then
    as_root groupadd docker
  fi

  if ! id -nG "${target_user}" | tr ' ' '\n' | grep -qx docker; then
    as_root usermod -aG docker "${target_user}"
    docker_group_changed=1
  fi
}

install_k3d() {
  local architecture="$1"
  local asset="k3d-linux-${architecture}"
  local checksums_file="${temporary_directory}/k3d-checksums.txt"
  local binary_file="${temporary_directory}/${asset}"
  local expected

  [[ "${K3D_VERSION}" == v* ]] || die "K3D_VERSION must start with 'v'."
  log "Installing K3d ${K3D_VERSION}"
  download_file \
    "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/${asset}" \
    "${binary_file}"
  download_file \
    "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/checksums.txt" \
    "${checksums_file}"
  expected="$(awk -v name="_dist/${asset}" '$2 == name {print $1; exit}' "${checksums_file}")"
  [[ -n "${expected}" ]] || die "No checksum was published for ${asset}."
  verify_sha256 "${binary_file}" "${expected}"
  as_root install -o root -g root -m 0755 "${binary_file}" /usr/local/bin/k3d
}

install_kubectl() {
  local architecture="$1"
  local binary_file="${temporary_directory}/kubectl"
  local checksum_file="${temporary_directory}/kubectl.sha256"
  local base_url

  [[ "${KUBECTL_VERSION}" == v* ]] || die "KUBECTL_VERSION must start with 'v'."
  base_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${architecture}"
  log "Installing kubectl ${KUBECTL_VERSION}"
  download_file "${base_url}/kubectl" "${binary_file}"
  download_file "${base_url}/kubectl.sha256" "${checksum_file}"
  verify_sha256 "${binary_file}" "$(tr -d '[:space:]' <"${checksum_file}")"
  as_root install -o root -g root -m 0755 "${binary_file}" /usr/local/bin/kubectl
}

install_argocd_cli() {
  local architecture="$1"
  local asset="argocd-linux-${architecture}"
  local checksums_file="${temporary_directory}/argocd-checksums.txt"
  local binary_file="${temporary_directory}/${asset}"
  local expected

  [[ "${ARGOCD_VERSION}" == v* ]] || die "ARGOCD_VERSION must start with 'v'."
  log "Installing Argo CD CLI ${ARGOCD_VERSION}"
  download_file \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/${asset}" \
    "${binary_file}"
  download_file \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/cli_checksums.txt" \
    "${checksums_file}"
  expected="$(awk -v name="${asset}" '$2 == name {print $1; exit}' "${checksums_file}")"
  [[ -n "${expected}" ]] || die "No checksum was published for ${asset}."
  verify_sha256 "${binary_file}" "${expected}"
  as_root install -o root -g root -m 0555 "${binary_file}" /usr/local/bin/argocd
}

configure_amd64_emulation() {
  local architecture="$1"
  local emulated_architecture

  [[ "${architecture}" == "arm64" ]] || return

  log "Registering AMD64 emulation for Wil's AMD64-only application image"
  as_root docker run --privileged --rm "${BINFMT_IMAGE}" --install amd64
  emulated_architecture="$(
    as_root docker run --rm --platform linux/amd64 alpine:3.23 uname -m
  )"
  [[ "${emulated_architecture}" == "x86_64" ]] ||
    die "AMD64 emulation validation returned '${emulated_architecture}' instead of 'x86_64'."
  success "AMD64 containers run correctly on this ARM64 VM."
}

main() {
  local architecture
  local target_user

  [[ "$(uname -s)" == "Linux" ]] ||
    die "Part 3 must be installed inside a Linux VM, not on $(uname -s)."
  require_command apt-get
  require_command dpkg
  require_command systemctl

  if ((EUID != 0)); then
    require_command sudo
    sudo -v
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu | debian) ;;
    *)
      die "Unsupported Linux distribution '${ID:-unknown}'. Use Ubuntu or Debian."
      ;;
  esac

  architecture="$(linux_architecture)"
  case "$(dpkg --print-architecture)" in
    amd64 | arm64) ;;
    *) die "The apt architecture must be amd64 or arm64." ;;
  esac

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    target_user="${SUDO_USER}"
  else
    target_user="$(id -un)"
  fi

  temporary_directory="$(mktemp -d /tmp/iot-p3-install.XXXXXX)"

  log "Installing base packages"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl git gnupg jq coreutils

  install_docker
  configure_docker_group "${target_user}"
  install_k3d "${architecture}"
  install_kubectl "${architecture}"
  install_argocd_cli "${architecture}"
  configure_amd64_emulation "${architecture}"

  log "Installed versions"
  as_root docker version --format 'Docker Engine {{.Server.Version}}'
  k3d version | sed -n '1,2p'
  kubectl version --client=true
  argocd version --client --short

  if ((docker_group_changed == 1)); then
    warn "User '${target_user}' was added to the docker group. Run 'newgrp docker' or log out and back in before running setup.sh."
  else
    success "The required Part 3 tools are installed."
  fi
}

main "$@"
