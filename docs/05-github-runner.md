# 05 — On-prem GitHub Actions runners (containers)

Two long-lived runner containers, one per repo, built from GitHub's official runner image plus the tools the
workflows use. Workflows target them with `runs-on: [self-hosted, k3s-lab]`. The split of responsibilities is the
same as before: the lab builds the image and wires Docker, the CA and the kubeconfig; **you** supply the GitHub
registration token.

## 1. What is in the image — `runner/Dockerfile`

| Layer | Content |
|---|---|
| base | `ghcr.io/actions/actions-runner:2.338.x`: Ubuntu 24.04, user `runner` (uid 1001), Docker CLI + buildx, the runner unpacked in `/home/runner` |
| lab tools | kubectl (latest v1.34.x), kustomize, helm 3, k9s, yq, jq, trivy, shellcheck, git, rsync |
| trust | lab CA in the OS store (`COPY --from=certs`, docs/04 §2) |
| entrypoint | `runner/entrypoint.sh`: `config.sh` on first start (reads the token from `secrets/`), then `run.sh` |

Rebuild after changing the Dockerfile, the CA, or `RUNNER_VERSION` in `lab-env.sh`:

```bash
source lab-env.sh
docker compose -f runner/docker-compose.yml build --pull
```

(The runner self-updates its own binaries inside the home volume; the image rebuild is for the tools.)

## 2. How the containers are wired — `runner/docker-compose.yml`

| Item | Setting | Why |
|---|---|---|
| Docker | `/var/run/docker.sock` mounted; `group_add: ["0"]` | jobs build with Docker Desktop's engine (same engine as the Mac). The socket is `root:root 0660` inside containers on Docker Desktop, so the runner user is added to the root group. Holding the socket = root on the Docker VM, as the old VM runner was root on its own Docker |
| kubeconfig | `secrets/kubeconfig-gha-deployer.yaml` → `/etc/github-runner/kubeconfig`, read-only; `KUBECONFIG` set | the `gha-deployer` SA (docs/02 §3); the server address is `https://k3d-k3s-lab-server-0:6443`, resolvable because… |
| network | `harbor_harbor` (external) | …the runners sit on Harbor's docker network with the k3d nodes; `harbor.lab.internal` resolves to nginx |
| state | named volume per runner at `/home/runner` | `.runner`, `.credentials`, `_work` and the self-updated runner survive restarts and image rebuilds |
| registration | compose secret `runner-token-<repo>` from `secrets/runner-token-<repo>` | read only when `.runner` is absent; stale afterwards, but the file must exist for compose to start |
| restart | `unless-stopped` | Docker Desktop brings the runners back at login |

Memory: an idle runner is ~150 MB; a .NET build inside a job needs 2–3 GB of the Docker Desktop VM while it runs.

## 3. Install the deploy kubeconfig

```bash
./k3s/40-make-kubeconfig.sh      # → secrets/kubeconfig-gha-deployer.yaml (0600), server = k3d-k3s-lab-server-0
```

Nothing to copy: the compose file mounts it. After re-running (cluster rebuilt): `docker compose -f runner/docker-compose.yml restart`.

## 4. Register the runners (you)

Facts that shape the install:

- **Scope.** `denmanjohn-maker` is a personal account, so runners are **per repository** — one container per repo
  (that is what the compose file defines). If you later make an **organization**, one runner at org level serves
  both repos: keep one service, set `RUNNER_URL=https://github.com/<org>` and take the token from the org's
  Runners page. The org route is closer to work and halves the maintenance; a free org costs nothing.
- **Private repos only.** GitHub warns against self-hosted runners on public repos: a fork PR can run arbitrary
  code on your runner — and this runner holds the Docker socket. Keep both repos private, or at minimum never
  trigger on `pull_request` from forks.
- **Non-root.** Jobs run as `runner` (uid 1001). `group_add: ["0"]` only grants the socket.
- **Version.** `RUNNER_VERSION` in `lab-env.sh` pins the image tag; the runner self-updates afterwards.

GitHub → repo → **Settings → Actions → Runners → New self-hosted runner → Linux → ARM64**. Copy only the
`--token` value from the page (valid for 1 h):

```bash
source lab-env.sh
umask 077
echo 'AXXXXXXXXXXXXXXXXXXXXXXXXXXXX' > secrets/runner-token-containerhelper      # from ContainerHelperAdditions
echo 'AYYYYYYYYYYYYYYYYYYYYYYYYYYYY' > secrets/runner-token-devopshelpers        # from DevOpsHelperTools
docker compose -f runner/docker-compose.yml up -d --build
docker compose -f runner/docker-compose.yml logs -f        # "√ Runner successfully added" … "Listening for Jobs"
```

Each runner appears under its repo's **Runners** tab as *Idle* with labels
`self-hosted · Linux · ARM64 · k3s-lab · harbor · arm64`. The entrypoint registers with `--replace`, so re-using
a runner name after a rebuild is fine.

Day-2:

| Task | Command |
|---|---|
| status / logs | `docker compose -f runner/docker-compose.yml ps` · `docker logs -f runner-containerhelper` · `_diag/` inside the volume: `docker exec runner-containerhelper ls _diag` |
| stop / start | `docker compose -f runner/docker-compose.yml stop` / `up -d` (or `./lab.sh stop` / `up`) |
| shell | `docker exec -it runner-containerhelper bash` (as `runner`) |
| remove / re-register | remove the runner in GitHub, then `docker compose -f runner/docker-compose.yml down -v` (drops the home volumes), new token files, `up -d` |
| job workspaces | `/home/runner/_work/<repo>/<repo>` in the volume — safe to delete when stopped |
| docker disk | `docker system df` · `./lab.sh prune` (build cache older than 7 days, images older than 14) |

## 5. Verify end to end

Push a workflow with `runs-on: [self-hosted, k3s-lab]` (workflows/ has the real ones; this is the minimum):

```yaml
name: runner-smoke
on: workflow_dispatch
jobs:
  smoke:
    runs-on: [self-hosted, k3s-lab]
    steps:
      - run: |
          docker version --format '{{.Server.Version}}'
          kubectl get nodes
          kubectl -n containerhelper auth can-i create deployments
          curl -fsS https://${HARBOR_HOST}/api/v2.0/health
```

Or run `scripts/verify.sh` from the Mac, which checks the same things from outside.

## 6. If you later want to compare with Actions Runner Controller (ARC)

ARC runs ephemeral runner pods in the cluster via a Helm-installed controller and a *runner scale set* registered
to GitHub (`gha-runner-scale-set-controller` + `gha-runner-scale-set` charts, in an `arc-systems` namespace). It
needs a GitHub App or PAT, and container builds need either Docker-in-Docker (`containerMode: dind`, which PSA
`restricted` forbids — you'd carve out a namespace at `privileged`) or a Kaniko/BuildKit rootless job pattern.
That PSA friction and the fact that work runs classic long-lived runners is why this lab uses them. Everything in
this lab except §4 is unchanged if you add ARC alongside later — same Harbor robots, same deployer SA. The base
image is the same one ARC uses, so the Dockerfile here is a head start.
