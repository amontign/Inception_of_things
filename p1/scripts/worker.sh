#!/bin/sh

set -eu

export DEBIAN_FRONTEND=noninteractive
k3s_url="https://${K3S_SERVER_IP}:6443"
k3s_token_file="/vagrant/.k3s-node-token"

echo "Synchronizing the system clock before joining the cluster..."
timedatectl set-timezone UTC
timedatectl set-ntp true
systemctl restart systemd-timesyncd

attempt=0
until [ "$(timedatectl show --property=NTPSynchronized --value)" = "yes" ]; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 60 ]; then
    echo "The system clock did not synchronize within 1 minute." >&2
    timedatectl status || true
    exit 1
  fi
  sleep 1
done
hwclock --systohc --utc

echo "Configuring the private network on eth1..."
sed -i '/#VAGRANT-BEGIN/,/#VAGRANT-END/d' /etc/network/interfaces
printf '%s\n' \
  'auto eth1' \
  'iface eth1 inet static' \
  "      address ${K3S_WORKER_IP}" \
  '      netmask 255.255.255.0' \
  >/etc/network/interfaces.d/eth1

ip link set eth1 up
if ! ip -4 address show dev eth1 | grep -Fq "inet ${K3S_WORKER_IP}/24 "; then
  ip -4 address flush dev eth1 scope global
  ip address add "${K3S_WORKER_IP}/24" dev eth1
fi

echo "Installing K3s agent..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl

echo "Waiting for the K3s API and its cluster-specific join token..."
attempt=0
until curl -skf --connect-timeout 2 "${k3s_url}/cacerts" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 150 ]; then
    echo "The K3s API at ${k3s_url} was not reachable within 5 minutes." >&2
    exit 1
  fi
  sleep 2
done

attempt=0
until [ -s "${k3s_token_file}" ]; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 150 ]; then
    echo "The K3s join token was not available within 5 minutes." >&2
    exit 1
  fi
  sleep 2
done

k3s_join_token="$(cat "${k3s_token_file}")"
k3s_join_token_hash="$(
  printf '%s' "${k3s_join_token}" |
    sha256sum |
    awk '{print $1}'
)"
token_hash_file="/var/lib/rancher/k3s/agent/vagrant-token.sha256"

if [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
  if [ -s "${token_hash_file}" ] &&
    ! grep -Fxq "${k3s_join_token_hash}" "${token_hash_file}"; then
    echo "The cluster token changed; removing stale K3s agent state..."
    /usr/local/bin/k3s-agent-uninstall.sh
  elif [ ! -s "${token_hash_file}" ] &&
    ! systemctl is-active --quiet k3s-agent; then
    echo "Removing incomplete K3s agent state from a previous attempt..."
    /usr/local/bin/k3s-agent-uninstall.sh
  fi
fi

curl -sfL https://get.k3s.io |
  K3S_URL="${k3s_url}" \
    K3S_TOKEN="${k3s_join_token}" \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    INSTALL_K3S_EXEC="agent \
      --node-name=amontignsw \
      --node-ip=${K3S_WORKER_IP} \
      --flannel-iface=eth1" \
    INSTALL_K3S_SKIP_START=true \
    sh -

echo "Waiting for the K3s agent to become active..."
systemctl enable k3s-agent
systemctl start --no-block k3s-agent

attempt=0
until systemctl is-active --quiet k3s-agent; do
  attempt=$((attempt + 1))
  if systemctl is-failed --quiet k3s-agent || [ "${attempt}" -ge 150 ]; then
    echo "K3s agent failed to become active within 5 minutes." >&2
    systemctl status k3s-agent --no-pager -l || true
    journalctl -u k3s-agent --no-pager -n 100 || true
    exit 1
  fi
  sleep 2
done

install -d -m 0700 /var/lib/rancher/k3s/agent
printf '%s\n' "${k3s_join_token_hash}" >"${token_hash_file}"
chmod 0600 "${token_hash_file}"

echo "Waiting for the worker node to become ready..."
attempt=0
until k3s kubectl \
  --kubeconfig /var/lib/rancher/k3s/agent/kubelet.kubeconfig \
  get node amontignsw \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null |
  grep -qx 'True'; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 150 ]; then
    echo "The worker node did not become Ready within 5 minutes." >&2
    systemctl status k3s-agent --no-pager -l || true
    journalctl -u k3s-agent --no-pager -n 100 || true
    exit 1
  fi
  sleep 2
done

echo "K3s agent is running and node amontignsw is Ready."
