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

Design decisions:

| Decision | Choice | Why |
|---|---|---|
| Platform | **Docker Desktop** (one Linux VM) | Every lab role has a standard Docker shape; ~12 GB for the whole lab; free for personal use (paid above 250 employees / $10M revenue) |
| Cluster | **k3d**, `rancher/k3s:v1.34.x` pinned in `lab-env.sh` | Same K8s minor as work VKS; `registries.yaml`/CA plumbing identical to real nodes; rebuilds in ~2 min |
| Harbor | **Compose stack from the official offline installer**, data under `~/Lab/harbor` | Mirrors how on-prem shops run it; registry survives cluster rebuilds; stays out of iCloud |
| Harbor version | **v2.16.0-rc1, arm64 offline installer** | First Harbor with official arm64 images. Swap to `v2.16.0` GA when it ships |
| Runners | **Containers built on `ghcr.io/actions/actions-runner`**, one per repo, Docker socket mounted | Classic long-lived runners with the `k3s-lab` label, like work; `/home/runner` on a volume so registration survives restarts |
| TLS | **Private lab CA** (`secrets/certs/ca.crt`) trusted by the Mac keychain (= Docker Desktop's engine), the nodes (`ca_file`) and the runner image | Realistic — forces the same CA-trust plumbing you do at work |
| Names | `harbor.lab.internal` → `127.0.0.1` on the Mac; a Docker DNS alias on Harbor's nginx inside the VM | One hosts line on the Mac; `.internal` is reserved for private use, `.local` collides with mDNS |
| k9s | installed on the Mac and in the runner image | your TUI of choice; `k9s --context k3d-k3s-lab` |

## Folder layout

```
Kubernetes Lab/
├── README.md                 ← you are here
├── lab-env.sh                ← EDIT ME: names, sizes, versions; sourced by every script
├── install.sh                ← ONE COMMAND: tools → CA → hosts → Harbor → cluster → GitHub → runners → verify
├── lab.sh                    ← day-2: up / stop / status / create-cluster / destroy-cluster / shell / prune / reset
├── docs/
│   ├── 01-architecture.md    ← components, networking, trust, credential flow
│   ├── 02-cluster-k3s.md     ← k3d cluster, kubeconfig, k9s, namespaces, PSA
│   ├── 03-harbor.md          ← install Harbor on Docker Desktop (runbook)
│   ├── 04-trust-harbor-ca.md ← make k3d nodes / Docker Desktop / runners / Mac trust the lab CA
│   ├── 05-github-runner.md   ← build + register the runner containers
│   ├── 06-deploy-workflows.md← build→Harbor→k3s pipelines for both repos
│   ├── 07-operations.md      ← start/stop, backup, upgrades, GC, disk
│   └── 08-troubleshooting.md ← symptoms → fixes
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

## Quick start

Prerequisites: a Mac with Homebrew, and (optional, recommended) `gh auth login` so the installer can set the repo
secrets and fetch runner tokens itself.

```bash
cd "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab"
vi lab-env.sh          # names, HARBOR_HOME, sizes, versions — defaults are fine for the M5
./install.sh           # ~30 min, mostly downloads; sudo asked for the keychain and /etc/hosts
```

`install.sh` is idempotent: re-run it after fixing anything, or `./install.sh --from <stage>` / `--only <stage>`.
What it does, stage by stage:

| # | Stage | What happens | Doc |
|---|---|---|---|
| 1 | `tools` | `brew install k3d kubectl jq gh k9s`, Docker Desktop (cask) if missing, waits for the engine, warns if the VM has < 11 GB | 02 §5 |
| 2 | `certs` | `harbor/20-gen-certs.sh` → lab CA + Harbor cert; trusts the CA in the System keychain; restarts Docker Desktop so its engine trusts it | 03 §1, 04 |
| 3 | `hosts` | `scripts/hosts-entry.sh --apply` → `127.0.0.1 harbor.lab.internal` | 01 |
| 4 | `harbor` | `harbor/30-install-harbor.sh` (Harbor under `~/Lab/harbor`) and `harbor/40-init-harbor.sh` (projects, proxy cache, robots) | 03 |
| 5 | `cluster` | `k3s/10-render-registries.sh`; `./lab.sh create-cluster`; namespaces + RBAC; `k3s/50-pull-secrets.sh`; `k3s/40-make-kubeconfig.sh` | 02, 04 |
| 6 | `github` | with `gh`: repo secrets `HARBOR_ROBOT_USER/TOKEN` + a registration token per repo; without: you paste the tokens | 05 §4, 06 §1 |
| 7 | `runners` | `docker compose -f runner/docker-compose.yml up -d --build`; waits for "Listening for Jobs" | 05 |
| 8 | `verify` | `scripts/verify.sh --quick` | 07 |

The one thing that stays manual: copy `workflows/*.yml` into each repo (docs/06 §1). Day-2 is `./lab.sh`
(`status`, `up`, `stop`, `reset` to wipe everything and start over).

Sizing on the 24 GB MacBook Pro: give the Docker Desktop VM **12 GB** (Harbor ~2.5 GB, three K3s nodes ~3 GB,
runners idle ~0.3 GB, a .NET build 2–3 GB while it runs). 10 GB works if you run one build at a time — docs/02 §5.

## Conventions used throughout

- Every script is `bash`, `set -euo pipefail`, idempotent, runs **on the Mac**, and sources `lab-env.sh`.
- Scripts named `NN-*.sh` run in numeric order within their folder.
- "Node" = a k3d node container; you get onto one with `./lab.sh shell` or `docker exec k3d-k3s-lab-server-0 …`.
- Secrets never go in docs or git. `secrets/` has a `.gitignore` with `*`.
- Image naming: `harbor.lab.internal/<project>/<image>:<git-sha>` plus a moving `:latest` only on `main`.
