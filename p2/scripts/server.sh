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

k3s_server_exec="server \
  --node-name=amontigns \
  --node-ip=${K3S_SERVER_IP} \
  --advertise-address=${K3S_SERVER_IP} \
  --tls-san=${K3S_SERVER_IP} \
  --flannel-iface=eth1 \
  --write-kubeconfig-mode=0644 \
  --disable=traefik"

curl -sfL https://get.k3s.io |
  INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    INSTALL_K3S_EXEC="${k3s_server_exec}" \
    INSTALL_K3S_SKIP_START=true \
    sh -

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

echo "Deploying the web applications..."

echo "[P1] - Initiating..."
kubectl create configmap app-one-html --from-file /vagrant_shared/app1/index.html
kubectl apply -f /vagrant_shared/app1/deployment.yaml
kubectl apply -f /vagrant_shared/app1/service.yaml
echo "[P1] - Done"

echo "[P2] - Initiating..."
kubectl create configmap app-two-html --from-file /vagrant_shared/app2/index.html
kubectl apply -f /vagrant_shared/app2/deployment.yaml
kubectl apply -f /vagrant_shared/app2/service.yaml
echo "[P2] - Done"

echo "[P3] - Initiating..."
kubectl create configmap app-three-html --from-file /vagrant_shared/app3/index.html
kubectl apply -f /vagrant_shared/app3/deployment.yaml
kubectl apply -f /vagrant_shared/app3/service.yaml
echo "[P3] - Done"

echo "[Ingress] - Initiating..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'

echo "Waiting for NGINX Ingress controller to be ready..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s
sleep 15

until kubectl apply -f /vagrant_shared/ingress/ingress.yaml; do
  echo "Retrying ingress application (waiting for webhook)..."
  sleep 3
done
echo "[Ingress] - Done"

echo "Waiting for the deployments to roll out..."
kubectl rollout status deployment/app-one --timeout=300s
kubectl rollout status deployment/app-two --timeout=300s
kubectl rollout status deployment/app-three --timeout=300s

echo "Waiting for the ingress to be reachable on port 80..."
attempt=0
until curl -s --max-time 3 -o /dev/null "http://${K3S_SERVER_IP}/" || [ "${attempt}" -ge 90 ]; do
  attempt=$((attempt + 1))
  sleep 2
done

echo "K3s server and applications are ready."
sudo -u vagrant kubectl get nodes -o wide
sudo -u vagrant kubectl get all
