# Kubernetes Lab — K3s + Harbor + on-prem GitHub Actions runner

A local, work-like CI/CD lab on the M5 MacBook Pro (VMware Fusion, ARM64) for building
and deploying **ContainerHelperAdditions** and **DevOpsHelperTools**:

```
  GitHub (denmanjohn-maker)                 VMware Fusion — vmnet8 NAT (192.168.64.0/24)
  ┌──────────────────────────┐              ┌──────────────────────────────────────────────────────┐
  │ ContainerHelperAdditions │  workflow    │  runner.lab.internal   (Ubuntu 24.04 arm64, 2c/4g)   │
  │ DevOpsHelperTools        │ ───────────► │  actions-runner (self-hosted, label: k3s-lab)        │
  └──────────────────────────┘   jobs       │  docker buildx · kubectl · kustomize · helm · k9s    │
                                            └───────┬──────────────────────────────┬───────────────┘
                                         push image │                              │ kubectl apply (SA kubeconfig)
                                                    ▼                              ▼
                                   ┌───────────────────────────┐   ┌──────────────────────────────────┐
                                   │ harbor.lab.internal       │   │ k3s-lab  (K3s v1.34, 1 server +  │
                                   │ Harbor 2.16 (compose)     │◄──│ 2 agents, Ubuntu 24.04 arm64)    │
                                   │ projects: containerhelper │pull│ ns: containerhelper, devopshelpers│
                                   │  devopshelpers, lab,      │   │ PSA restricted · registries.yaml │
                                   │  dockerhub (proxy cache)  │   │ trusts Harbor CA                 │
                                   │ Trivy scan-on-push        │   └──────────────────────────────────┘
                                   └───────────────────────────┘
```

Design decisions (made 2026-10-27):

| Decision | Choice | Why |
|---|---|---|
| Cluster | **Reuse existing `k3s-lab`** (3× Ubuntu 24.04 ARM64, K3s v1.34) | Already matches work VKS version; nothing to rebuild |
| Harbor | **Separate VM, docker compose** (`harbor.lab.internal`) | Mirrors how on-prem shops run it; registry survives cluster rebuilds |
| Harbor version | **v2.16.0-rc1, arm64 offline installer** | First Harbor with official arm64 images — 2.15.x and older are amd64-only and won't run on Apple-Silicon VMs. Swap to `v2.16.0` GA when it ships |
| Runner | **Self-hosted `actions-runner` on its own VM** (`runner.lab.internal`), **installed by John** | Classic VM runner, like a work jump box; docs cover prep + install |
| TLS | **Private lab CA** (`secrets/certs/ca.crt`) trusted by Mac, k3s nodes, runner | Realistic — forces the same CA-trust plumbing you do at work |
| Names | `*.lab.internal` via `/etc/hosts` | `.internal` is reserved for private use; `.local` collides with mDNS on macOS |
| k9s | installed on the Mac and runner | your TUI of choice; `k9s --context k3s-lab` |

## Folder layout

```
Kubernetes Lab/
├── README.md                 ← you are here
├── lab-env.sh                ← EDIT ME: IPs, names, versions; sourced by every script
├── docs/
│   ├── 01-architecture.md    ← components, networking, trust, credential flow
│   ├── 02-cluster-k3s.md     ← reuse k3s-lab, kubeconfig, k9s, namespaces, PSA
│   ├── 03-harbor-vm.md       ← build the Harbor VM + install Harbor (runbook)
│   ├── 04-trust-harbor-ca.md ← make k3s / docker / Mac trust the lab CA
│   ├── 05-github-runner.md   ← prep the runner VM; YOUR runner install steps
│   ├── 06-deploy-workflows.md← build→Harbor→k3s pipelines for both repos
│   ├── 07-operations.md      ← start/stop order, backup, upgrades, GC
│   ├── 08-troubleshooting.md ← symptoms → fixes
│   └── 09-plan-docker-desktop.md ← PROPOSAL: replace VMware Fusion with Docker Desktop (Harbor compose, k3d, runner container)
├── harbor/
│   ├── 00-push-to-vm.sh      ← Mac: generate admin/db passwords once, rsync harbor/ + certs to the VM
│   ├── 10-bootstrap-vm.sh    ← ON the Harbor VM: docker + compose, CA trust, ufw, /data
│   ├── 20-gen-certs.sh       ← Mac: lab CA (10y) + Harbor server cert (2y, SANs)
│   ├── 30-install-harbor.sh  ← ON the Harbor VM: download arm64 installer, render harbor.yml, install --with-trivy
│   └── 40-init-harbor.sh     ← Mac: projects (auto-scan), Docker Hub proxy cache, robot accounts
├── k3s/
│   ├── 10-trust-harbor-ca.sh ← Mac: CA + registries.yaml (Harbor auth, docker.io→proxy cache) on all 3 nodes
│   ├── 20-namespaces.yaml    ← containerhelper / devopshelpers (PSA restricted) + lab-sandbox (baseline)
│   ├── 30-deployer-rbac.yaml ← SA gha-deployer + namespaced Role/RoleBinding, read-only nodes/namespaces
│   ├── 40-make-kubeconfig.sh ← Mac: mint the runner's long-lived SA kubeconfig
│   ├── 50-pull-secrets.sh    ← Mac: harbor-pull imagePullSecret in each namespace
│   └── registries.yaml.template
├── runner/
│   └── 10-prep-runner-vm.sh  ← ON the runner VM: docker+buildx, kubectl/kustomize/helm/k9s/yq/trivy/shellcheck, CA trust, 'runner' user
├── workflows/
│   ├── containerhelperadditions.yml ← copy to that repo: lint → build → push Harbor → scan gate → deploy
│   ├── devopshelpertools.yml        ← same pipeline, devopshelpers defaults
│   └── sample-deploy/               ← PSA-restricted-clean Kustomize base + overlays/lab starter
├── scripts/
│   ├── hosts-entries.sh      ← print / --apply / --push the /etc/hosts block to Mac + VMs
│   └── verify.sh             ← end-to-end smoke test (names, TLS, Harbor, k3s, runner)
└── secrets/                  ← git-ignored: CA key, passwords, robot tokens, kubeconfig (created on first run)
```

## Quick start (order matters)

| # | Where | Command / action | Doc |
|---|---|---|---|
| 0 | Mac | Edit `lab-env.sh` (IPs); `source lab-env.sh`; `scripts/hosts-entries.sh --apply` | 01 |
| 1 | Mac | `./lab.sh up` in `~/Virtual Machines.localized/k3s-lab`; confirm `kubectl get nodes` | 02 |
| 2 | Mac | `harbor/20-gen-certs.sh` → creates `secrets/certs/{ca.crt,ca.key,harbor.crt,harbor.key}` | 03 |
| 3 | Fusion | Create **harbor** VM (Ubuntu 24.04 arm64, 2 vCPU / 4 GB / 60 GB), DHCP reservation | 03 |
| 4 | Mac → Harbor VM | `harbor/00-push-to-vm.sh`; then on the VM `~/lab/harbor/10-bootstrap-vm.sh` and `~/lab/harbor/30-install-harbor.sh` | 03 |
| 5 | Mac | `harbor/40-init-harbor.sh` → projects, proxy cache, robots, scan-on-push | 03 |
| 6 | Mac | `k3s/10-trust-harbor-ca.sh` → nodes trust CA, `registries.yaml`, k3s restarted | 04 |
| 7 | Mac | `kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml`; `k3s/50-pull-secrets.sh`; `k3s/40-make-kubeconfig.sh` | 02/04 |
| 8 | Fusion | Create **runner** VM (Ubuntu 24.04 arm64, 2 vCPU / 4 GB / 40 GB) | 05 |
| 9 | Runner VM | `runner/10-prep-runner-vm.sh`; copy `secrets/kubeconfig-gha-deployer.yaml` to `/etc/github-runner/kubeconfig` | 05 |
| 10 | Runner VM | **You:** install `actions-runner` for each repo, label `k3s-lab`, run as a service | 05 |
| 11 | GitHub | Add repo secrets `HARBOR_ROBOT_USER` / `HARBOR_ROBOT_TOKEN`; copy workflows | 06 |
| 12 | Mac | `scripts/verify.sh` — pulls through proxy cache, pushes a test image, deploys a pod | 07 |

Sizing on the 24 GB MacBook Pro: k3s-lab (3 × 4 GB) + Harbor (4 GB) + runner (4 GB) = **20 GB of VM RAM**.
That is tight. Run Harbor + runner with the k3s agents at 3 GB each, or stop the runner VM when not
building — see docs/07 §1.

## Conventions used throughout

- Every script is `bash`, `set -euo pipefail`, idempotent, and sources `lab-env.sh`.
- Scripts named `NN-*.sh` run in numeric order within their folder.
- "Mac" = your terminal on the MacBook Pro. "Harbor VM"/"Runner VM" = SSH into that VM.
- Secrets never go in docs or git. `secrets/` has a `.gitignore` with `*`.
- Image naming: `harbor.lab.internal/<project>/<image>:<git-sha>` plus a moving `:latest` only on `main`.
# K8s-Lab
