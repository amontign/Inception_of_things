# Part 3: K3d and Argo CD

This directory implements the mandatory Part 3 environment without Vagrant. It
creates a local K3s cluster through K3d, installs Argo CD in `argocd`, and lets
Argo CD continuously deploy `wil42/playground` into `dev` from this GitHub
repository.

## K3s and K3d

- **K3s** is a lightweight Kubernetes distribution. It runs the Kubernetes
  control plane and worker services directly on Linux nodes.
- **K3d** is a development wrapper that runs K3s server and agent nodes inside
  Docker containers. It makes local clusters fast to create, delete, and
  reproduce while still exposing a normal Kubernetes API to `kubectl`.

Part 1 and Part 2 run K3s in Vagrant machines. Part 3 runs K3s in Docker through
K3d inside a Linux VM, so there is intentionally no `Vagrantfile` here.

## What gets installed

The installer supports 64-bit Ubuntu and Debian VMs on AMD64 or ARM64. Its
default versions are deliberately pinned for a reproducible defense:

| Component | Default |
| --- | --- |
| Docker Engine | 29.7.2 on a fresh installation |
| K3d | v5.9.0 |
| K3s | v1.36.4+k3s1 |
| kubectl | v1.36.4 |
| Argo CD | v3.5.2 |
| ARM64 AMD64-emulation helper | `tonistiigi/binfmt:qemu-v10.2.3-68` |

Wil's `v1` and `v2` images are Linux/AMD64-only. On an ARM64 VM, the installer
registers an AMD64 emulator and validates it before cluster setup. That one step
uses a privileged, short-lived container because `binfmt_misc` is a host-kernel
facility. It is skipped on AMD64.

Version defaults can be overridden deliberately, for example:

```sh
K3D_VERSION=v5.9.0 KUBECTL_VERSION=v1.36.4 ./p3/scripts/install.sh
```

## Required GitHub state

Argo CD must clone its source anonymously. Before running `setup.sh`:

1. Commit and push the complete `p3` directory to `main`.
2. Make `https://github.com/amontign/Inception_of_things` public.
3. Before the final defense, rename the repository so its name contains the
   login `amontign`, as required by the subject.
4. After a rename, update `repoURL` in
   `confs/argocd/application.yaml` and push that change.

The setup script deliberately disables local Git credentials during its
preflight. If the repository or `p3/confs/app/deployment.yaml` is not publicly
readable, it stops before creating or changing the cluster. No GitHub token,
Argo CD password, or kubeconfig is stored in this repository.

## Fresh VM setup

Run the installer as your normal user. It invokes `sudo` only for apt, system
services, `/usr/local/bin`, and ARM64 emulator registration:

```sh
cd /path/to/IoT
./p3/scripts/install.sh
```

If the installer says it added you to the `docker` group, refresh group
membership before continuing:

```sh
newgrp docker
```

You can alternatively log out of the VM and back in. Confirm that `docker info`
works without `sudo`, then create the complete environment:

```sh
./p3/scripts/setup.sh
```

`setup.sh` is idempotent. It creates or reuses the `iot` cluster, switches to
the `k3d-iot` kubectl context, applies the two namespaces, installs Argo CD,
creates its Application, and waits for the initial GitOps deployment.

Verify the initial version at any time:

```sh
./p3/scripts/check.sh v1
curl http://localhost:8888/
```

Expected response:

```json
{"status":"ok", "message": "v1"}
```

Useful inspection commands for the defense are:

```sh
kubectl get nodes -o wide
kubectl get namespaces
kubectl get pods -n argocd
kubectl get all,ingress -n dev
kubectl get application -n argocd
```

## Argo CD web interface

Start a foreground port-forward on local port 8080:

```sh
./p3/scripts/argocd-ui.sh
```

The script prints the initial `admin` password when that Kubernetes Secret still
exists. Open `https://127.0.0.1:8080`; the development certificate is
self-signed. Use another unprivileged local port if 8080 is occupied:

```sh
./p3/scripts/argocd-ui.sh 8081
```

Press Ctrl-C to end the port-forward.

## Required v1 to v2 GitOps demonstration

Change only the desired image in Git; do not run `kubectl apply` on the workload
and do not press the manual Sync button:

```sh
sed -i 's|wil42/playground:v1|wil42/playground:v2|' \
  p3/confs/app/deployment.yaml
git add p3/confs/app/deployment.yaml
git commit -m "p3: deploy playground v2"
git push origin main
./p3/scripts/check.sh v2
```

Argo CD's automated sync then reconciles `dev`. The check allows enough time
for the normal repository polling interval and succeeds only when Argo CD is
`Synced` and `Healthy`, the live Deployment uses `v2`, its pod is ready, and the
endpoint returns:

```json
{"status":"ok", "message": "v2"}
```

To demonstrate the reverse direction later, replace `v2` with `v1`, commit,
push, and run `./p3/scripts/check.sh v1`.

## Cleanup

Interactive cleanup deletes only the K3d cluster named `iot`:

```sh
./p3/scripts/cleanup.sh
```

For repeatable automation:

```sh
./p3/scripts/cleanup.sh --force
```

Docker, downloaded tools, cached images, and unrelated K3d clusters are not
removed.

## Troubleshooting

### The repository check fails

Confirm that the repository is public, `main` has been pushed, and this URL can
be opened in a private browser window:

```text
https://raw.githubusercontent.com/amontign/Inception_of_things/main/p3/confs/app/deployment.yaml
```

If the repository was renamed, update the Argo CD Application's `repoURL`.

### Docker reports permission denied

Run `newgrp docker` or log out and back in. `setup.sh` must run as the normal
user, not with `sudo`, because K3d maintains that user's kubeconfig.

Membership in the `docker` group is effectively root-level access. Use this
only in the disposable project VM.

### Port 6550 or 8888 is already occupied

Stop the conflicting process or delete an obsolete `iot` cluster with
`cleanup.sh`. Port 6550 exposes the Kubernetes API only on VM localhost; port
8888 maps VM localhost to Traefik and then to the playground Service.

### Argo CD stays OutOfSync or Unknown

Inspect the Application conditions and the repository-server logs:

```sh
kubectl describe application wil-playground -n argocd
kubectl logs -n argocd deployment/argocd-repo-server --tail=100
```

The usual causes are a private or renamed repository, an unpushed manifest,
network/DNS failure, or an invalid Git path.

### The ARM64 pod reports an executable-format error

Rerun `install.sh` so it re-registers AMD64 emulation, then recreate the pod:

```sh
./p3/scripts/install.sh
kubectl delete pod -n dev -l app.kubernetes.io/name=wil-playground
```

Argo CD and the Deployment will recreate the pod from Git.
