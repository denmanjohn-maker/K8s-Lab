# 01 — Architecture

## Components

| Component | Host | Software | Role |
|---|---|---|---|
| `k3s-lab` | 3 Fusion VMs (`k3s-server`, `k3s-agent-1/2`) | Ubuntu 24.04 ARM64, K3s v1.34, Traefik, local-path, metrics-server | Target cluster. Mirrors work VKS: same K8s minor, PSA `restricted` on app namespaces |
| Harbor | Fusion VM `harbor.lab.internal` | Ubuntu 24.04 ARM64, Docker CE + Compose v2, Harbor **v2.16.0-rc1** (arm64), Trivy | Private registry, Docker Hub proxy cache, vulnerability scanning, robot accounts |
| Runner | Fusion VM `runner.lab.internal` | Ubuntu 24.04 ARM64, Docker CE, kubectl/kustomize/helm/k9s, `actions-runner` 2.338.x | Executes GitHub Actions jobs from both repos; pushes to Harbor, deploys to k3s |
| Mac | M5 MacBook Pro | kubectl, k9s, helm, openssl, ssh | Control plane for the lab: runs the `*.sh` scripts, holds the lab CA |

## Networking

All VMs share Fusion's **vmnet8 NAT** network so they can talk to each other and to the Mac, and reach
the internet (GitHub, Docker Hub, GHCR for Trivy DB) via NAT.

- Name resolution is deliberately simple: `/etc/hosts` on the Mac and on every VM (`scripts/hosts-entries.sh`).
  No DNS server to keep alive. The domain is `lab.internal` — ICANN reserved `.internal` for private use
  in 2024, and unlike `.local` it does not collide with macOS mDNS/Bonjour.
- Give the Harbor and runner VMs **fixed addresses**. Either a DHCP reservation in Fusion's
  `/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf` (keyed on MAC address) or a Netplan static IP
  inside the VM. docs/03 §2 shows both.
- Ports that matter:

| From | To | Port | Why |
|---|---|---|---|
| Mac, runner, k3s nodes | Harbor | 443 | registry API + UI (80 redirects to 443) |
| runner | k3s-server | 6443 | `kubectl` via the deployer kubeconfig |
| Mac | all VMs | 22 | SSH for the scripts |
| runner | github.com, *.actions.githubusercontent.com | 443 | runner long-poll (outbound only — no inbound from GitHub) |
| Harbor | registry-1.docker.io, ghcr.io | 443 | proxy cache upstream, Trivy DB updates |

## Trust model

```
secrets/certs/ca.key  (Mac only, never leaves)
      └── ca.crt  ──► trusted by: Mac keychain (optional), each k3s node (/usr/local/share/ca-certificates +
                     /etc/rancher/k3s/registries.yaml tls.ca_file), runner VM (system store + /etc/docker/certs.d)
      └── harbor.crt / harbor.key ──► Harbor VM only (nginx TLS); SANs: harbor.lab.internal, <HARBOR_IP>
```

Why a private CA rather than Harbor's self-signed cert or plain HTTP: it exercises exactly the containerd
`registries.yaml` + system CA trust steps you need on VKS nodes against the corporate CA, and `docker push`
from the runner behaves like production. The CA is valid 10 years; the server cert 2 years (`harbor/20-gen-certs.sh --renew`).

## Identity and credential flow

| Credential | Created by | Lives on | Scope |
|---|---|---|---|
| Harbor `admin` | `30-install-harbor.sh` (random, saved to `secrets/harbor-admin.pw`) | Mac | break-glass + `40-init-harbor.sh` only |
| `robot$gha-push` | `40-init-harbor.sh` → `secrets/harbor-robot-gha-push.token` | GitHub repo secrets `HARBOR_ROBOT_USER/TOKEN` | push+pull on `containerhelper`, `devopshelpers`, `lab`; pull on `dockerhub` |
| `robot$k3s-pull` | `40-init-harbor.sh` → `secrets/harbor-robot-k3s-pull.token` | k3s `registries.yaml` on every node **and** `harbor-pull` imagePullSecret | pull-only on all projects |
| `gha-deployer` SA token | `k3s/40-make-kubeconfig.sh` → `secrets/kubeconfig-gha-deployer.yaml` | runner VM `/etc/github-runner/kubeconfig` (0600, owner = runner user) | namespaced Role in `containerhelper` + `devopshelpers`: deployments, services, configmaps, secrets, ingresses, jobs, pods (read) |
| GitHub runner registration token | GitHub UI | consumed once by `config.sh` | expires in 1 h; the runner keeps its own credential afterwards |

Two deliberate choices:

1. **The kubeconfig is a file on the runner, not a GitHub secret.** The runner is on-prem and already
   trusted; keeping cluster credentials off GitHub matches the usual on-prem posture and means a leaked
   repo secret can't reach the cluster. Workflows set `KUBECONFIG=/etc/github-runner/kubeconfig`.
2. **Registry credentials go the other way** — they *are* GitHub secrets, because the push happens in
   the job and the robot account is already least-privilege and revocable from Harbor.

## How a deploy flows

1. Push to `main` in `ContainerHelperAdditions` (or manual `workflow_dispatch`).
2. Job `build` runs on `runs-on: [self-hosted, k3s-lab]`: `docker buildx build --platform linux/arm64`
   (add `linux/amd64` when you want to publish to GHCR too) → `docker push harbor.lab.internal/containerhelper/<image>:<sha>`.
3. Harbor scans on push (Trivy). Job `scan-gate` polls `GET /api/v2.0/projects/.../artifacts/<sha>?with_scan_overview=true`
   and fails on Critical (configurable) — your EPSS/KEV policy can be layered here later.
4. Job `deploy` runs `kustomize edit set image` on the repo's `deploy/overlays/lab` and `kubectl apply -k`,
   then `kubectl rollout status`.
5. k3s nodes pull from Harbor using `registries.yaml` auth (`robot$k3s-pull`); the `harbor-pull` imagePullSecret
   is also present for manifests that reference it explicitly (as you would on VKS).

## What this lab deliberately is *not*

- Not HA (one Harbor VM, one K3s server). Backups are covered in docs/07; losing the Harbor VM means
  `docker compose` restore from `/data` tarball, not a rebuild from scratch.
- Not using Actions Runner Controller. You chose a classic VM runner; ARC notes are in docs/05 §6 if you
  want to compare later.
- Not Harbor-in-cluster via Helm. Keeping the registry outside the cluster is what lets you destroy and
  recreate `k3s-lab` freely.
