# 05 — On-prem GitHub Actions runner VM

Split of responsibilities: the lab prepares the VM (tools, Docker, CA trust, service user, kubeconfig); **you
install and register `actions-runner`** (§4). Workflows target the runner with `runs-on: [self-hosted, k3s-lab]`.

## 1. Create the VM (Fusion)

| Setting | Value |
|---|---|
| Image | Ubuntu Server 24.04.x arm64 |
| Name | `runner` |
| vCPU / RAM / Disk | 2 / 4 GB / 40 GB (docker build cache lives here; grow the disk if builds are big) |
| Network | Share with my Mac (NAT) — same vmnet8 |
| Installer | user `john`, OpenSSH server, hostname `runner`, fixed IP = `RUNNER_IP` (DHCP reservation, docs/03 §2) |

```bash
./scripts/hosts-entries.sh --push      # adds the runner to every machine's /etc/hosts
ssh john@runner.lab.internal
```

## 2. Prep the VM (Mac → VM)

```bash
# Mac
cd "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab"
ssh john@runner.lab.internal 'mkdir -p ~/lab/certs'
rsync -az lab-env.sh runner john@runner.lab.internal:~/lab/
rsync -az secrets/certs/ca.crt john@runner.lab.internal:~/lab/certs/
ssh john@runner.lab.internal 'chmod +x ~/lab/runner/*.sh'

# VM
~/lab/runner/10-prep-runner-vm.sh                 # add --with-dotnet if you build .NET outside containers
```

Installs: Docker CE + buildx (+ amd64 binfmt for cross-builds), kubectl v1.34.x, kustomize, helm, k9s,
yq, jq, trivy, shellcheck, git; trusts the lab CA in the OS store **and** `/etc/docker/certs.d/harbor.lab.internal/`;
creates the service user **`runner`** (docker group); creates `/etc/github-runner/` for the kubeconfig; ufw allows
SSH only (the runner is outbound-only — GitHub never connects in).

## 3. Install the deploy kubeconfig (Mac → VM)

```bash
./k3s/40-make-kubeconfig.sh      # if not done yet → secrets/kubeconfig-gha-deployer.yaml
scp secrets/kubeconfig-gha-deployer.yaml john@runner.lab.internal:/tmp/kubeconfig
ssh john@runner.lab.internal 'sudo install -m 640 -o root -g runner /tmp/kubeconfig /etc/github-runner/kubeconfig && rm /tmp/kubeconfig'
ssh john@runner.lab.internal 'sudo -u runner KUBECONFIG=/etc/github-runner/kubeconfig kubectl auth whoami && \
  sudo -u runner KUBECONFIG=/etc/github-runner/kubeconfig kubectl -n containerhelper auth can-i create deployments'
```

Expect `system:serviceaccount:containerhelper:gha-deployer` and `yes`. The file is readable only by root and the
`runner` group — job steps run as `runner`, so `KUBECONFIG=/etc/github-runner/kubeconfig` just works.

## 4. Install the runner (you)

Facts that shape the install:

- **Scope.** If `denmanjohn-maker` is a personal account, runners are **per repository** — install the runner twice
  (two directories, two services), once per repo. If it is (or you make it) an **organization**, install **one**
  runner at org level (Org → Settings → Actions → Runners) and both repos can use it. The org route is closer to
  work and halves the maintenance; a free org costs nothing.
- **Private repos only.** GitHub warns against self-hosted runners on public repos: a fork PR can run arbitrary
  code on your VM. Keep both repos private, or at minimum never trigger on `pull_request` from forks.
- **Non-root.** Run as the `runner` user created in §2. `svc.sh install runner` sets that up as a systemd unit.
- **Version.** 2.338.2 was current on 2026-10-27 — take whatever the GitHub "New self-hosted runner" page shows;
  the runner self-updates afterwards.

GitHub → repo (or org) → **Settings → Actions → Runners → New self-hosted runner → Linux → ARM64**. It shows
commands equivalent to these (the token is valid for 1 h):

```bash
# on the VM, as the service user
sudo -iu runner
RVER=2.338.2
mkdir -p ~/actions-runner-containerhelper && cd ~/actions-runner-containerhelper
curl -fL -o runner.tgz "https://github.com/actions/runner/releases/download/v${RVER}/actions-runner-linux-arm64-${RVER}.tar.gz"
tar -xzf runner.tgz && rm runner.tgz
# any missing libs (libicu etc.):  sudo ./bin/installdependencies.sh     (run from your sudo user, not 'runner')

./config.sh --unattended \
  --url    https://github.com/denmanjohn-maker/ContainerHelperAdditions \   # or https://github.com/<org> for org scope
  --token  <registration token from the page> \
  --name   runner-containerhelper \
  --labels k3s-lab,harbor,arm64 \
  --work   _work

# environment every job inherits (the runner reads .env and .path in its root on start)
cat > .env <<'EOF'
KUBECONFIG=/etc/github-runner/kubeconfig
DOCKER_BUILDKIT=1
HARBOR_HOST=harbor.lab.internal
EOF
exit                                   # back to your sudo user

cd /home/runner/actions-runner-containerhelper
sudo ./svc.sh install runner && sudo ./svc.sh start && sudo ./svc.sh status
```

Repeat with `~/actions-runner-devopshelpers` / `--url …/DevOpsHelperTools` / `--name runner-devopshelpers` for the
second repo (personal-account case). The runner appears under the repo's **Runners** tab as *Idle* with labels
`self-hosted · Linux · ARM64 · k3s-lab · harbor · arm64`.

Day-2:

| Task | Command |
|---|---|
| status / logs | `sudo ./svc.sh status` · `journalctl -u 'actions.runner.*' -f` · `_diag/Runner_*.log` |
| stop / start | `sudo ./svc.sh stop` / `start` |
| remove | `sudo ./svc.sh uninstall` then `sudo -u runner ./config.sh remove --token <removal token>` |
| job workspaces | `/home/runner/actions-runner-*/_work/<repo>/<repo>` — safe to delete when stopped |
| docker disk | `docker system df` · `docker builder prune -af --filter until=168h` (add to cron weekly) |

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
to GitHub (`gha-runner-scale-set-controller` + `gha-runner-scale-set` charts, in a `arc-systems` namespace). It
needs a GitHub App or PAT, and container builds need either Docker-in-Docker (`containerMode: dind`, which PSA
`restricted` forbids — you'd carve out a namespace at `privileged`) or a Kaniko/BuildKit rootless job pattern.
That PSA friction and the fact that work runs classic VM runners is why this lab uses a VM. Everything in this
lab except §4 is unchanged if you add ARC alongside later — same Harbor robots, same deployer SA.
