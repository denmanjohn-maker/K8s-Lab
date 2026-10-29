# 01 — Architecture

## Components

Everything is a container in Docker Desktop's Linux VM on the Mac. "Host" below is the compose project or
k3d cluster that owns it.

| Component | Host | Software | Role |
|---|---|---|---|
| `k3s-lab` | k3d cluster: `k3d-k3s-lab-server-0`, `k3d-k3s-lab-agent-0/1` (+ `k3d-k3s-lab-serverlb`) | `rancher/k3s:v1.34.x` with Traefik, CoreDNS, local-path, metrics-server | Target cluster. Mirrors work VKS: same K8s minor, PSA `restricted` on app namespaces |
| Harbor | compose project `harbor` in `~/Lab/harbor/harbor` (10 containers, `nginx` is the front door) | Harbor **v2.16.0-rc1** (arm64), Trivy, Postgres, Valkey | Private registry, Docker Hub proxy cache, vulnerability scanning, robot accounts |
| Runners | compose project `lab-runners`: `runner-containerhelper`, `runner-devopshelpers` | `ghcr.io/actions/actions-runner` 2.338.x + kubectl/kustomize/helm/k9s/yq/trivy/shellcheck | Execute GitHub Actions jobs; build with the Mac's Docker engine, push to Harbor, deploy to k3s |
| Mac | M5 MacBook Pro | Docker Desktop, k3d, kubectl, k9s, helm, openssl | Control plane for the lab: runs the `*.sh` scripts and `lab.sh`, holds the lab CA |

## Networking

One Docker bridge network, `harbor_harbor` (created by Harbor's compose file), carries everything:

- Harbor's `nginx` container is on it with the **DNS aliases `harbor.lab.internal` and `harbor`**
  (`harbor/docker-compose.override.yml.template`). k3d nodes and runner containers join the same network
  (`network:` in `k3s/k3d-config.yaml.template`, `networks:` in `runner/docker-compose.yml`), so inside Docker
  the registry hostname resolves to nginx directly on 443. Containers on the network also resolve each other
  by name — the runners reach the API server as `k3d-k3s-lab-server-0:6443`.
- On the Mac, `harbor.lab.internal` is one `/etc/hosts` line → `127.0.0.1` (`scripts/hosts-entry.sh`), where
  Docker Desktop publishes Harbor's 443. Docker Desktop's engine resolves names through the Mac's resolver and
  binds published ports inside the VM too, so `docker push harbor.lab.internal/…` from the Mac and from a job
  takes the same path. The domain is `lab.internal` — ICANN reserved `.internal` for private use in 2024, and unlike
  `.local` it does not collide with macOS mDNS/Bonjour.
- Node-level work (`registries.yaml`, `crictl`, containerd config, logs) is `docker exec` into the node container
  (`./lab.sh shell`).

Ports published on the Mac:

| Port | Owner | Why |
|---|---|---|
| 443 (and 80 → redirect) | Harbor `nginx` | registry API + UI: `https://harbor.lab.internal` |
| 6443 (127.0.0.1 only) | k3d `serverlb` | `kubectl` from the Mac (context `k3d-k3s-lab`) |
| 8080 / 8443 | k3d `serverlb` → Traefik | Ingress for lab apps (`http://localhost:8080`); Harbor already owns 80/443 |
| 127.0.0.1:1514 | Harbor `log` | syslog target for the other Harbor containers (Harbor's own design) |

Outbound (from the VM, via the Mac): runners → `github.com`, `*.actions.githubusercontent.com` (long-poll, nothing
inbound); Harbor → `registry-1.docker.io` (proxy cache), `ghcr.io` (Trivy DB).

## Trust model

```
secrets/certs/ca.key  (Mac only, never leaves)
      └── ca.crt  ──► trusted by: Mac System keychain  = Docker Desktop's engine (docker push/pull from the Mac and from jobs)
                                  k3d nodes            via registries.yaml tls.ca_file (k3d bind-mounts ca.crt into every node)
                                  runner image         OS trust store (curl to the Harbor API, trivy, kubectl → Harbor)
      └── harbor.crt / harbor.key ──► Harbor nginx only; SANs: harbor.lab.internal, harbor, nginx, localhost, 127.0.0.1
```

Why a private CA rather than Harbor's self-signed cert or plain HTTP: it exercises exactly the containerd
`registries.yaml` + trust-store steps you need on VKS nodes against the corporate CA, and `docker push` from a job
behaves like production. The CA is valid 10 years; the server cert 2 years (`harbor/20-gen-certs.sh --renew`).

## Identity and credential flow

| Credential | Created by | Lives on | Scope |
|---|---|---|---|
| Harbor `admin` | `30-install-harbor.sh` (random, saved to `secrets/harbor-admin.pw`) | Mac | break-glass + `40-init-harbor.sh` only |
| `robot$gha-push` | `40-init-harbor.sh` → `secrets/harbor-robot-gha-push.token` | GitHub repo secrets `HARBOR_ROBOT_USER/TOKEN` | push+pull on `containerhelper`, `devopshelpers`, `lab`; pull on `dockerhub` |
| `robot$k3s-pull` | `40-init-harbor.sh` → `secrets/harbor-robot-k3s-pull.token` | `secrets/registries.yaml` (mounted into every node) **and** the `harbor-pull` imagePullSecret | pull-only on all projects |
| `gha-deployer` SA token | `k3s/40-make-kubeconfig.sh` → `secrets/kubeconfig-gha-deployer.yaml` | mounted read-only into the runner containers at `/etc/github-runner/kubeconfig` | namespaced Role in `containerhelper` + `devopshelpers`: deployments, services, configmaps, secrets, ingresses, jobs, pods (read) |
| GitHub runner registration token | GitHub UI → `secrets/runner-token-<repo>` | consumed once by `config.sh` on the container's first start | expires in 1 h; the runner keeps its own credential in its home volume afterwards |

Two deliberate choices:

1. **The kubeconfig is a file mounted into the runner, not a GitHub secret.** The runner is on-prem and already
   trusted; keeping cluster credentials off GitHub matches the usual on-prem posture and means a leaked
   repo secret can't reach the cluster. Workflows set `KUBECONFIG=/etc/github-runner/kubeconfig`.
2. **Registry credentials go the other way** — they *are* GitHub secrets, because the push happens in
   the job and the robot account is already least-privilege and revocable from Harbor.

One consequence of the Docker shape: the runner containers hold the Docker socket, which is root on the Docker
VM. Keep both repos private (docs/05 §4).

## How a deploy flows

1. Push to `main` in `ContainerHelperAdditions` (or manual `workflow_dispatch`).
2. Job `build` runs on `runs-on: [self-hosted, k3s-lab]`: `docker buildx build --platform linux/arm64`
   (add `linux/amd64` when you want to publish to GHCR too — Docker Desktop emulates it) → `docker push
   harbor.lab.internal/containerhelper/<image>:<sha>`. The build runs on the Mac's engine through the mounted socket.
3. Harbor scans on push (Trivy). Job `scan-gate` polls `GET /api/v2.0/projects/.../artifacts/<sha>?with_scan_overview=true`
   and fails on Critical (configurable) — your EPSS/KEV policy can be layered here later.
4. Job `deploy` runs `kustomize edit set image` on the repo's `deploy/overlays/lab` and `kubectl apply -k`,
   then `kubectl rollout status`, against `https://k3d-k3s-lab-server-0:6443`.
5. k3s nodes pull from Harbor using `registries.yaml` auth (`robot$k3s-pull`); the `harbor-pull` imagePullSecret
   is also present for manifests that reference it explicitly (as you would on VKS).

## What this lab deliberately is *not*

- Not HA (one Harbor, one K3s server). Backups are covered in docs/07; losing Harbor means a `tar` restore of
  `~/Lab/harbor/data`, not a rebuild from scratch.
- Not using Actions Runner Controller. You chose classic long-lived runners; ARC notes are in docs/05 §6.
- Not Harbor-in-cluster via Helm. Keeping the registry outside the cluster is what lets you destroy and
  recreate `k3s-lab` freely.
