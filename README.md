# Kubernetes Lab — K3s + Harbor + on-prem GitHub Actions runners, on Docker Desktop

A local, work-like CI/CD lab on the M5 MacBook Pro for building and deploying **ContainerHelperAdditions**
and **DevOpsHelperTools**. Everything runs inside Docker Desktop's single Linux VM: Harbor as a compose
stack, the cluster as k3d (K3s nodes as containers), the runners as containers.

```
  GitHub (denmanjohn-maker)                Docker Desktop (arm64 VM) — docker network harbor_harbor
  ┌──────────────────────────┐             ┌──────────────────────────────────────────────────────────┐
  │ ContainerHelperAdditions │  workflow   │  runner-containerhelper / runner-devopshelpers            │
  │ DevOpsHelperTools        │ ──────────► │  (ghcr.io/actions/actions-runner + kubectl/kustomize/helm │
  └──────────────────────────┘   jobs      │   /trivy, label: k3s-lab, Docker socket mounted)          │
                                           └───────┬──────────────────────────────┬───────────────────┘
                                        push image │                              │ kubectl apply (SA kubeconfig)
                                                   ▼                              ▼
                                  ┌───────────────────────────┐   ┌──────────────────────────────────────┐
                                  │ harbor.lab.internal       │   │ k3s-lab  (k3d: 1 server + 2 agents,  │
                                  │ Harbor 2.16 (compose)     │◄──│ rancher/k3s v1.34)                   │
                                  │ projects: containerhelper │pull│ ns: containerhelper, devopshelpers   │
                                  │  devopshelpers, lab,      │   │ PSA restricted · registries.yaml     │
                                  │  dockerhub (proxy cache)  │   │ trusts Harbor CA · Traefik :8080/8443│
                                  │ Trivy scan-on-push        │   └──────────────────────────────────────┘
                                  │ :443 on the Mac           │
                                  └───────────────────────────┘
```

Design decisions (2026-10-27, hypervisor changed 2026-10-28 — see docs/09):

| Decision | Choice | Why |
|---|---|---|
| Hypervisor | **Docker Desktop** (one VM), not VMware Fusion | Every lab role has a standard Docker shape; 12 GB instead of 20 GB of VMs; nothing to license beyond personal use |
| Cluster | **k3d**, `rancher/k3s:v1.34.x` pinned in `lab-env.sh` | Same K8s minor as work VKS; `registries.yaml`/CA plumbing identical to real nodes; rebuilds in ~2 min |
| Harbor | **Compose stack from the official offline installer**, data under `~/Lab/harbor` | Mirrors how on-prem shops run it; registry survives cluster rebuilds; stays out of iCloud |
| Harbor version | **v2.16.0-rc1, arm64 offline installer** | First Harbor with official arm64 images. Swap to `v2.16.0` GA when it ships |
| Runners | **Containers built on `ghcr.io/actions/actions-runner`**, one per repo, Docker socket mounted | Same labels and job environment as the old VM runner; `/home/runner` on a volume so registration survives restarts |
| TLS | **Private lab CA** (`secrets/certs/ca.crt`) trusted by the Mac keychain (= Docker Desktop's engine), the nodes (`ca_file`) and the runner image | Realistic — forces the same CA-trust plumbing you do at work |
| Names | `harbor.lab.internal` → `127.0.0.1` on the Mac; a Docker DNS alias on Harbor's nginx inside the VM | One hosts line instead of five; `.internal` is reserved for private use, `.local` collides with mDNS |
| k9s | installed on the Mac and in the runner image | your TUI of choice; `k9s --context k3d-k3s-lab` |

## Folder layout

```
Kubernetes Lab/
├── README.md                 ← you are here
├── lab-env.sh                ← EDIT ME: names, sizes, versions; sourced by every script
├── lab.sh                    ← up / stop / status / create-cluster / destroy-cluster / shell / prune
├── docs/
│   ├── 01-architecture.md    ← components, networking, trust, credential flow
│   ├── 02-cluster-k3s.md     ← k3d cluster, kubeconfig, k9s, namespaces, PSA
│   ├── 03-harbor.md          ← install Harbor on Docker Desktop (runbook)
│   ├── 04-trust-harbor-ca.md ← make k3d nodes / Docker Desktop / runners / Mac trust the lab CA
│   ├── 05-github-runner.md   ← build + register the runner containers
│   ├── 06-deploy-workflows.md← build→Harbor→k3s pipelines for both repos
│   ├── 07-operations.md      ← start/stop, backup, upgrades, GC, disk
│   ├── 08-troubleshooting.md ← symptoms → fixes
│   └── 09-plan-docker-desktop.md ← the Fusion → Docker Desktop migration: cutover + Fusion removal
├── harbor/
│   ├── 20-gen-certs.sh       ← Mac: lab CA (10y) + Harbor server cert (2y, SANs)
│   ├── 30-install-harbor.sh  ← Mac: download arm64 installer, render harbor.yml, install --with-trivy
│   ├── 40-init-harbor.sh     ← Mac: projects (auto-scan), Docker Hub proxy cache, robot accounts
│   └── docker-compose.override.yml.template ← DNS alias harbor.lab.internal on Harbor's nginx
├── k3s/
│   ├── k3d-config.yaml.template ← the cluster: nodes, image, Harbor network, CA + registries mounts, ports
│   ├── 10-render-registries.sh  ← Mac: render secrets/registries.yaml (Harbor auth, CA, docker.io→proxy cache)
│   ├── 20-namespaces.yaml    ← containerhelper / devopshelpers (PSA restricted) + lab-sandbox (baseline)
│   ├── 30-deployer-rbac.yaml ← SA gha-deployer + namespaced Role/RoleBinding, read-only nodes/namespaces
│   ├── 40-make-kubeconfig.sh ← Mac: mint the runners' long-lived SA kubeconfig
│   ├── 50-pull-secrets.sh    ← Mac: harbor-pull imagePullSecret in each namespace
│   └── registries.yaml.template
├── runner/
│   ├── Dockerfile            ← official runner image + kubectl/kustomize/helm/k9s/yq/trivy/shellcheck + lab CA
│   ├── entrypoint.sh         ← config.sh once (token from secrets/), then run.sh
│   └── docker-compose.yml    ← runner-containerhelper, runner-devopshelpers (socket, kubeconfig, home volume)
├── workflows/
│   ├── containerhelperadditions.yml ← copy to that repo: lint → build → push Harbor → scan gate → deploy
│   ├── devopshelpertools.yml        ← same pipeline, devopshelpers defaults
│   └── sample-deploy/               ← PSA-restricted-clean Kustomize base + overlays/lab starter
├── scripts/
│   ├── hosts-entry.sh        ← print / --apply the single /etc/hosts line on the Mac
│   └── verify.sh             ← end-to-end smoke test (names, TLS, Harbor, k3d, runners)
└── secrets/                  ← git-ignored: CA key, passwords, robot tokens, kubeconfig, rendered configs
```

## Quick start (order matters)

| # | Where | Command / action | Doc |
|---|---|---|---|
| 0 | Mac | Install Docker Desktop (Resources: 12 GB / 6 CPU), `brew install k3d kubectl derailed/k9s/k9s`; edit `lab-env.sh`; `source lab-env.sh` | 01 |
| 1 | Mac | `harbor/20-gen-certs.sh` → `secrets/certs/{ca.crt,ca.key,harbor.crt,harbor.key}`; trust `ca.crt` in the System keychain; **restart Docker Desktop** | 03/04 |
| 2 | Mac | `scripts/hosts-entry.sh --apply` (`127.0.0.1 harbor.lab.internal`) | 01 |
| 3 | Mac | `harbor/30-install-harbor.sh` → Harbor under `~/Lab/harbor`, healthy at `https://harbor.lab.internal` | 03 |
| 4 | Mac | `harbor/40-init-harbor.sh` → projects, proxy cache, robots, scan-on-push | 03 |
| 5 | Mac | `k3s/10-render-registries.sh`; `./lab.sh create-cluster` → 3 nodes Ready, context `k3d-k3s-lab` | 02/04 |
| 6 | Mac | `kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml`; `k3s/50-pull-secrets.sh`; `k3s/40-make-kubeconfig.sh` | 02 |
| 7 | GitHub | New self-hosted runner (per repo) → registration token → `secrets/runner-token-<repo>` | 05 |
| 8 | Mac | `docker compose -f runner/docker-compose.yml up -d --build` → runners *Idle* with label `k3s-lab` | 05 |
| 9 | GitHub | Add repo secrets `HARBOR_ROBOT_USER` / `HARBOR_ROBOT_TOKEN`; copy workflows | 06 |
| 10 | Mac | `scripts/verify.sh` — pulls through proxy cache, node pull, restricted pod, runner checks | 07 |

Sizing on the 24 GB MacBook Pro: give the Docker Desktop VM **12 GB** (Harbor ~2.5 GB, three K3s nodes ~3 GB,
runners idle ~0.3 GB, a .NET build 2–3 GB while it runs). 10 GB works if you run one build at a time — docs/02 §5.

## Conventions used throughout

- Every script is `bash`, `set -euo pipefail`, idempotent, runs **on the Mac**, and sources `lab-env.sh`.
- Scripts named `NN-*.sh` run in numeric order within their folder.
- "Node" = a k3d node container (`docker exec k3d-k3s-lab-server-0 …`, or `./lab.sh shell`), the stand-in for SSH.
- Secrets never go in docs or git. `secrets/` has a `.gitignore` with `*`.
- Image naming: `harbor.lab.internal/<project>/<image>:<git-sha>` plus a moving `:latest` only on `main`.
