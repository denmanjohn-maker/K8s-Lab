# 09 — Migration: VMware Fusion → Docker Desktop

Status (2026-10-28): **Phase 1 (repository) is done** — every script, config and runbook in this repo now
describes the Docker Desktop lab. **Phases 0 and 2–5 run on the Mac** and are tracked in the checklist in §4.
Keep this file as the record: tick the boxes and note spike results as you go.

## 0. Summary

Fusion gave the lab five Ubuntu VMs. Docker Desktop gives the lab one Linux VM with a Docker engine in it, and
every lab role has a standard Docker shape:

```
  Mac — Docker Desktop (one Linux VM, arm64)                     docker network: harbor_harbor
  ┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  Harbor 2.16 (arm64)        docker compose stack from the official offline installer                 │
  │     nginx :443 → published on the Mac as 127.0.0.1:443 = harbor.lab.internal (/etc/hosts)            │
  │     network alias harbor.lab.internal so nodes and the runners reach nginx directly                  │
  │                                                                                                      │
  │  k3s-lab                    k3d cluster: 1 server + 2 agents, image rancher/k3s:v1.34.x-k3s1         │
  │     nodes on harbor_harbor; registries.yaml + lab CA mounted at create; Traefik on :8080/:8443       │
  │     API server published on the Mac as 127.0.0.1:6443; in-network name k3d-k3s-lab-server-0:6443    │
  │                                                                                                      │
  │  runner-containerhelper /   containers from runner/Dockerfile (ghcr.io/actions/actions-runner base)  │
  │  runner-devopshelpers       + kubectl/kustomize/helm/yq/trivy; Docker socket mounted; kubeconfig ro  │
  └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
         GitHub ──► runner (outbound long-poll) ──► docker build/push ──► Harbor ──► k3s pulls ──► kubectl apply
```

| Decision | Fusion lab | Docker Desktop lab |
|---|---|---|
| Hypervisor | VMware Fusion, five VMs, vmnet8 NAT | Docker Desktop, one VM, one Docker network |
| Harbor host | Ubuntu VM, Docker CE, `/opt/harbor`, `/data` | compose stack on the Mac's engine; `~/Lab/harbor/{harbor,data,log}` (outside iCloud) |
| Cluster | K3s on three VMs, external `lab.sh` | **k3d** (K3s nodes as containers), still v1.34, `k3s/k3d-config.yaml.template` |
| Runners | Ubuntu VM, `actions-runner` systemd service | two containers from `runner/Dockerfile`, Docker socket mounted, `/home/runner` volume |
| Names | `/etc/hosts` pushed to every VM, DHCP reservations | one `/etc/hosts` line on the Mac; Docker DNS alias on nginx inside the VM |
| CA trust | OS store on every VM + `/etc/docker/certs.d` | macOS keychain (engine + Mac), `ca_file` in `registries.yaml` (nodes), image-baked CA (runners) |
| Start after reboot | Fusion auto-start | Docker Desktop at login; `restart: always` / `unless-stopped` |
| RAM | 20 GB of VM memory | Docker Desktop VM at 12 GB |

Given up, stated once: the five "hosts" became containers in one VM. Node-level exercises (SSH into a node,
`systemctl restart k3s-agent`, `ufw`, Netplan, cloud-init) are now `docker exec` into a k3d node or gone.
The pipeline, registry, scanning, PSA and RBAC exercises are unchanged. Docker Desktop is free for personal
use and needs a paid subscription on company machines above 250 employees or $10M revenue.

## 1. Facts the design rests on (checked 2026-10-28)

| Fact | Where it landed |
|---|---|
| Docker Desktop trusts CAs from the **macOS keychain** and rebuilds the engine's bundle on restart | docs/03 §1, docs/04 §3, `20-gen-certs.sh` "Next" |
| Default file sharing covers `/Users`, not `/var/log`; `/var` resolves through `/private/var` | `HARBOR_HOME` default `~/Lab/harbor`; `log.local.location` and `data_volume` patched there by `30-install-harbor.sh` |
| Harbor's compose file: network `harbor` → `harbor_harbor`, service `proxy` = container `nginx` on `80:8080`/`443:8443`, `log` service reached at `127.0.0.1:1514`, all `restart: always` | `HARBOR_NETWORK`, `harbor/docker-compose.override.yml.template` (aliases + `json-file` fallback) |
| Harbor 2.16.0-rc1 arm64 offline installer; `install.sh` needs only `docker` + `docker compose` | `30-install-harbor.sh` runs on the Mac (no `sudo`, `openssl` md5, python patcher validated against the real `harbor.yml.tmpl`) |
| **k3d 5.9.0**, config `k3d.io/v1alpha5`: `image`, `network`, `volumes` with `nodeFilters`, `kubeAPI.hostIP/hostPort`, `ports`, `options.k3s.extraArgs`, `options.runtime.serversMemory/agentsMemory`; nodes restart with Docker | `k3s/k3d-config.yaml.template` (validated against k3d's JSON schema) |
| K3s v1.34 images: `rancher/k3s:v1.34.12-k3s1` is current | `K3S_IMAGE` in `lab-env.sh` |
| `ghcr.io/actions/actions-runner:2.338.2`: Ubuntu 24.04, user `runner` uid 1001, Docker CLI + buildx, no compose, no entrypoint | `runner/Dockerfile`, `runner/entrypoint.sh` |
| Docker socket inside containers on Docker Desktop is `root:root`; `group_add: ["0"]` is the usual fix | `runner/docker-compose.yml` |
| Harbor owns 80/443 on the Mac | Traefik on 8080/8443 (`TRAEFIK_*_PORT`), API on 127.0.0.1:6443 |
| Docker Desktop's VM resolver honours the Mac's `/etc/hosts` and published ports are bound inside the VM (why `docker push localhost:5000/…` works there) | `127.0.0.1 harbor.lab.internal` serves the Mac CLI and the engine; cert SAN includes `127.0.0.1` |

## 2. Phase 0 spikes — prove these on the Mac before cutting over

Fusion keeps running while you do them. Each is 30–60 min. Record the result here.

`scripts/phase0-spikes.sh` runs them: `preflight` (tools, Docker Desktop resources, free ports, file sharing,
CA, `/etc/hosts`), then `s1` … `s4`, or `all` for preflight + S1–S3 (the gate). Each spike calls the repo's own
scripts, prints PASS/FAIL per criterion, writes its verdict into the Result column below, and logs to
`secrets/phase0-<timestamp>.log`. It asks before the two `sudo` steps (keychain trust, `/etc/hosts`) and the
Docker Desktop restart; `--yes` skips the prompts, `--no-record` leaves this file alone. Notes:

- S1's "a scan completes" is checked in S2, which pushes the first image (the `lab` project and robots come from
  `40-init-harbor.sh`, which S2 runs).
- S3 deploys `workflows/sample-deploy` with its image swapped for the proxy-cached `alpine:3.20` (the real
  `toolbox` image only exists after CI); it also proves the `docker.io` mirror by pulling `busybox` through Harbor.
- S4 needs a runner token in `secrets/runner-token-containerhelper`; it records ◐ until you run `runner-smoke`
  on GitHub (it offers to dispatch it with `gh` when that is installed).
- If `secrets/certs/` is empty here but the Fusion lab's CA exists in another checkout, copy that `secrets/`
  in first: the CA is already trusted in the keychain, and S1 then skips the trust + restart.
- `cleanup` removes the S3 sample and the S2 test image; Harbor and the cluster stay for Phase 2/3.

| # | Spike | Pass criterion | Result | If it fails |
|---|---|---|---|---|
| S1 | **Harbor compose on Docker Desktop.** `harbor/20-gen-certs.sh`, keychain + restart, `scripts/hosts-entry.sh --apply`, `harbor/30-install-harbor.sh` (fresh `HARBOR_HOME`) | `curl --cacert secrets/certs/ca.crt https://harbor.lab.internal/api/v2.0/health` healthy; `docker compose … ps` shows `nginx`, `log`, `core` up; a scan completes | ☐ | logging: uncomment the `json-file` fallback in the override template; file sharing: add `~/Lab`; port 443 busy: `sudo lsof -iTCP:443` |
| S2 | **Engine push by hostname.** docs/03 §5 smoke test | `docker push harbor.lab.internal/lab/alpine:test` succeeds over TLS from the Mac | ☐ | use the Mac's LAN IP in `/etc/hosts` (changes with network), or add a `host.docker.internal` SAN and name |
| S3 | **k3d node pulls through Harbor.** `harbor/40-init-harbor.sh` (on the spike Harbor), `k3s/10-render-registries.sh`, `./lab.sh create-cluster`, `docker exec k3d-k3s-lab-server-0 k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20` | pull succeeds; 3 nodes Ready; a PSA-restricted pod from `workflows/sample-deploy` runs | ☐ | alias on nginx (`docker inspect nginx`), `ca_file` path in the node, `hosts.toml` (docs/08 §2) |
| S4 | **Runner container.** docs/05 §4 with one repo, run the `runner-smoke` workflow | green: `docker version`, `kubectl get nodes` via `k3d-k3s-lab-server-0:6443`, `curl` to Harbor | ☐ | socket gid (docs/08 §3); API SAN already set by the k3d template |

Decision gate: S1–S3 must pass; S4 may slip into Phase 4.

## 3. Phase 1 — repository changes (done)

| File | Change |
|---|---|
| `lab-env.sh` | IPs and SSH users removed; `HARBOR_HOME`, k3d sizing/ports, `K3S_IMAGE`, `K3D_VERSION`, `RUNNER_VERSION`; derived `HARBOR_NETWORK`, `K3D_CONTEXT`, `K8S_API_INTERNAL`; helpers `lab_docker_ok`, `k3d_nodes`, `lab_node_exec`, `lab_render` |
| `lab.sh` (new) | `up` / `stop` / `status` / `create-cluster` / `destroy-cluster` / `shell` / `prune` |
| `k3s/k3d-config.yaml.template` (new) | the cluster: image, Harbor network, API on 127.0.0.1:6443, Traefik 8080/8443, CA + registries mounts, `--tls-san`, memory caps |
| `k3s/10-render-registries.sh` (replaces `10-trust-harbor-ca.sh`) | renders `secrets/registries.yaml`; restarts the cluster if it is running |
| `k3s/registries.yaml.template` | `ca_file` → `/etc/ssl/certs/kubernetes-lab-ca.crt` (the k3d mount) |
| `k3s/40-make-kubeconfig.sh` | server = `https://k3d-k3s-lab-server-0:6443`, k3d context, in-network verification |
| `harbor/20-gen-certs.sh` | SANs: hostname, `harbor`, `nginx`, `localhost`, `127.0.0.1`; no IP from Fusion |
| `harbor/30-install-harbor.sh` | runs on the Mac: `HARBOR_HOME` layout, passwords generated here, python `harbor.yml` patcher, override file, `compose stop/up` reconfigure |
| `harbor/docker-compose.override.yml.template` (new) | aliases `harbor.lab.internal`, `harbor` on `proxy`; commented `json-file` logging fallback |
| `harbor/40-init-harbor.sh` | hints only |
| `runner/Dockerfile`, `runner/entrypoint.sh`, `runner/docker-compose.yml` (new) | the two runner containers |
| `scripts/hosts-entry.sh` (replaces `hosts-entries.sh`) | one line, Mac only |
| `scripts/verify.sh` | Docker Desktop, alias, k3d nodes via `docker exec`, runner containers |
| deleted | `harbor/00-push-to-vm.sh`, `harbor/10-bootstrap-vm.sh`, `runner/10-prep-runner-vm.sh`, `scripts/hosts-entries.sh`, `k3s/10-trust-harbor-ca.sh` |
| docs | README, 01–08 rewritten for the Docker shape (`03-harbor-vm.md` → `03-harbor.md`); workflows unchanged |

Validated in the session that produced it: `shellcheck -S warning -x` on every script; the k3d template rendered
and checked against k3d's `v1alpha5` JSON schema; `docker compose config` on `runner/docker-compose.yml`; the
compose override merged against a Harbor-shaped base file; the `harbor.yml` patcher run against the real
`v2.16.0-rc1` template. Not validated: anything that needs a Mac, Docker Desktop or GitHub — that is Phase 0.

## 4. Cutover checklist (Mac)

**Phase 0 — prepare (no lab impact)**
- [ ] Docker Desktop installed; Settings → Resources: 12 GB / 6 CPU; file sharing includes `/Users` (default)
- [ ] `brew install k3d kubectl derailed/k9s/k9s jq`
- [ ] `source lab-env.sh`; review `HARBOR_HOME`, `K3S_IMAGE`, `RUNNER_VERSION`
- [ ] **Harbor backup from the Fusion VM** per the old procedure (`docker compose down` on the VM, `tar … data opt/harbor/harbor.yml`, `scp` to `~/Backups/kubernetes-lab/`)
- [ ] copy of `secrets/` somewhere safe
- [ ] spikes S1–S4 (§2): `./scripts/phase0-spikes.sh all`, then `s4` — they double as the first real install; keep the spike Harbor if S1 passes

**Phase 2 — Harbor**
- [ ] Fusion Harbor VM: `cd /opt/harbor && sudo docker compose down` (frozen, not deleted)
- [ ] `docker compose --project-directory ~/Lab/harbor/harbor stop`; `rm -rf ~/Lab/harbor/data`; `tar -C ~/Lab/harbor -xzf ~/Backups/kubernetes-lab/harbor-backup-<date>.tgz data` (restores projects, robots, proxy cache, images); `./harbor/30-install-harbor.sh` again (docs/07 §3)
- [ ] skip `40-init-harbor.sh`; confirm existing images and robots in the UI; `docker pull harbor.lab.internal/dockerhub/library/alpine:3.20`

**Phase 3 — cluster**
- [ ] `./k3s/10-render-registries.sh`; `./lab.sh create-cluster`
- [ ] `kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml`; `./k3s/50-pull-secrets.sh`; `./k3s/40-make-kubeconfig.sh`
- [ ] `kubectl apply -k workflows/sample-deploy/overlays/lab` → Running under PSA restricted; reachable via Traefik on `:8080`

**Phase 4 — runners**
- [ ] remove the old VM runners in GitHub (Settings → Actions → Runners, both repos)
- [ ] fresh tokens → `secrets/runner-token-containerhelper`, `secrets/runner-token-devopshelpers`
- [ ] `docker compose -f runner/docker-compose.yml up -d --build`; both *Idle* with labels `k3s-lab · harbor · arm64`
- [ ] `runner-smoke`, then a real `main` push through both workflows; `./scripts/verify.sh` all PASS

**Phase 5 — decommission Fusion**
- [ ] power off all Fusion VMs; archive `~/Virtual Machines.localized/{k3s-lab,harbor,runner}` to an external disk; delete after two clean weeks
- [ ] uninstall Fusion: Trash the app, then `/Library/Preferences/VMware Fusion`, `/Library/Application Support/VMware`, `~/Library/Application Support/VMware Fusion`, `~/Library/Preferences/com.vmware.fusion*`, `~/Library/Caches/com.vmware.fusion`
- [ ] `./scripts/hosts-entry.sh --apply` (rewrites the `# >>> kubernetes-lab >>>` block, dropping the VM IP lines)
- [ ] delete the old `~/Virtual Machines.localized/k3s-lab/lab.sh` folder; remove the Fusion `dhcpd.conf` host blocks if Fusion is kept for anything else

Rollback before Phase 5: `./lab.sh stop`, power on the Fusion VMs, restore the old `/etc/hosts` block from git
history (`git show 38abbcf:scripts/hosts-entries.sh`). The Fusion Harbor is frozen at the backup point, so Harbor
data cannot diverge; if images were pushed to the new Harbor after cutover, back up `~/Lab/harbor/data` first.

## 5. Alternatives considered

- **Apple `container` (Containerization framework), machines mode.** Investigated first (git history of this
  file, commit "Add migration plan"). It would have kept the five-VM shape, at the cost of a monolithic guest
  kernel (no VXLAN, no `br_netfilter`), no static IPs, no restart policy, an experimental cluster command, and seven
  spikes before cutover. Dropped in favour of the well-trodden Docker path on 2026-10-28.
- **Docker Desktop's built-in Kubernetes (kind).** Multi-node is supported in current releases, but it is kubeadm,
  not K3s, and the version is chosen by Docker Desktop. k3d keeps the v1.34 match with work VKS and the
  `registries.yaml` plumbing.
- **Harbor in-cluster via Helm.** Rejected for the same reason as before: the registry must survive cluster rebuilds.
- **OrbStack.** Would carry the VM-style scripts over almost unchanged, but adds a second commercial tool when Docker
  Desktop already covers the need.
