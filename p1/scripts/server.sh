#!/bin/sh

set -eu

export DEBIAN_FRONTEND=noninteractive

echo "Synchronizing the system clock before generating certificates..."
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
  "      address ${K3S_SERVER_IP}" \
  '      netmask 255.255.255.0' \
  >/etc/network/interfaces.d/eth1

ip link set eth1 up
if ! ip -4 address show dev eth1 | grep -Fq "inet ${K3S_SERVER_IP}/24 "; then
  ip -4 address flush dev eth1 scope global
  ip address add "${K3S_SERVER_IP}/24" dev eth1
fi

echo "Installing K3s server..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl

rm -f /vagrant/.k3s-node-token

k3s_server_exec="server \
  --node-name=amontigns \
  --node-ip=${K3S_SERVER_IP} \
  --advertise-address=${K3S_SERVER_IP} \
  --tls-san=${K3S_SERVER_IP} \
  --flannel-iface=eth1 \
  --write-kubeconfig-mode=0644"

if [ -n "${K3S_TOKEN:-}" ]; then
  curl -sfL https://get.k3s.io |
    K3S_TOKEN="${K3S_TOKEN}" \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
      INSTALL_K3S_EXEC="${k3s_server_exec}" \
      INSTALL_K3S_SKIP_START=true \
      sh -
else
  curl -sfL https://get.k3s.io |
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
      INSTALL_K3S_EXEC="${k3s_server_exec}" \
      INSTALL_K3S_SKIP_START=true \
      sh -
fi

echo "Waiting for the K3s server and its node to become ready..."
systemctl enable k3s
systemctl start --no-block k3s

attempt=0
until systemctl is-active --quiet k3s; do
  attempt=$((attempt + 1))
  if systemctl is-failed --quiet k3s || [ "${attempt}" -ge 150 ]; then
    echo "K3s server failed to become active within 5 minutes." >&2
    systemctl status k3s --no-pager -l || true
    journalctl -u k3s --no-pager -n 100 || true
    exit 1
  fi
  sleep 2
done

attempt=0
until kubectl get node amontigns >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 150 ]; then
    echo "The K3s server node was not registered within 5 minutes." >&2
    kubectl get nodes -o wide || true
    journalctl -u k3s --no-pager -n 100 || true
    exit 1
  fi
  sleep 2
done
kubectl wait \
  --for=condition=Ready \
  node/amontigns \
  --timeout=300s

echo "Configuring kubectl for the vagrant user..."
install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.kube
install \
  -m 0600 \
  -o vagrant \
  -g vagrant \
  /etc/rancher/k3s/k3s.yaml \
  /home/vagrant/.kube/config

echo "Exporting the cluster-specific join token for the worker..."
install \
  -m 0600 \
  /var/lib/rancher/k3s/server/node-token \
  /vagrant/.k3s-node-token

echo "K3s server is ready."
sudo -u vagrant kubectl get nodes -o wide
