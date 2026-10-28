# 09 — Plan: replace VMware Fusion with Apple's Containerization framework

Status: **proposal** (written 2026-10-28, against `apple/container` 1.6.1). Nothing in this document has been
executed yet; Phase 0 exists to prove the risky parts before anything in the lab is torn down.

## 0. Summary

Fusion gives the lab five Ubuntu VMs: `k3s-server`, `k3s-agent-1/2`, `harbor`, `runner`. Apple's
[`container`](https://github.com/apple/container) tool runs Linux guests as lightweight VMs on
Virtualization.framework, and since 1.0 it has a **container machine** mode: a persistent guest booted from an
OCI image that runs the image's own `/sbin/init` (systemd), keeps its disk across stop/start, has every Linux
capability, supports nested virtualisation, and mounts your macOS home directory inside. That is close enough to a
VM that the lab's existing runbooks and scripts carry over with small edits.

Target shape:

```
  Mac (macOS 26, apple/container ≥ 1.6.1)                 default vmnet network, DNS domain lab.internal
  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  container machine  harbor        Ubuntu 24.04 + systemd + Docker CE + compose → Harbor 2.16 (arm64) │
  │  container machine  k3s-server    Ubuntu 24.04 + systemd + K3s v1.34 server                          │
  │  container machine  k3s-agent-1   Ubuntu 24.04 + systemd + K3s v1.34 agent                           │
  │  container machine  k3s-agent-2   Ubuntu 24.04 + systemd + K3s v1.34 agent                           │
  │  container machine  runner        Ubuntu 24.04 + systemd + Docker CE + tools + actions-runner        │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘
       names resolve everywhere as <machine>.lab.internal — no /etc/hosts pushing, no DHCP reservations
```

What changes for the design decisions in README:

| Decision | Fusion lab | After migration |
|---|---|---|
| Hypervisor | VMware Fusion (licensed, GUI, vmnet8 NAT, `.vmx` sizing) | `container machine` on Virtualization.framework (free, CLI, built into macOS 26) |
| Guest provisioning | Ubuntu Server ISO install by hand | Ubuntu 24.04 **OCI image** built once from a Dockerfile in this repo (`machines/`) |
| Addressing | fixed IPs via DHCP reservations in `dhcpd.conf` + `/etc/hosts` everywhere | **DNS names** from the `container` DNS service (`harbor.lab.internal`); IPs are dynamic and never written into config |
| Cluster | `k3s-lab` managed by an external `lab.sh` in `~/Virtual Machines.localized` | K3s v1.34 on three machines, managed by a `lab.sh` **in this repo** (same `up/stop/destroy` verbs) |
| Harbor / runner | unchanged — same scripts, same Harbor version, same robot accounts, same CA | unchanged — same scripts, same Harbor version, same robot accounts, same CA |
| Snapshots / suspend | Fusion snapshots, suspend-to-disk | none for machines — stop/start only; backups stay the `tar` of `/data` (docs/07 §3) |

Everything below the hypervisor (Harbor config, robots, CA, `registries.yaml`, RBAC, kubeconfig, workflows) is
untouched. Expect to keep roughly 80 % of the scripts and change how they *reach* the guests, not what they do.

## 1. Facts this plan rests on (checked 2026-10-28)

| Fact | Consequence for the lab |
|---|---|
| `apple/container` requires **macOS 26** and Apple silicon; older macOS is unsupported. Latest release **1.6.1** (2026-10-23). The `cluster` subcommand is marked experimental | Upgrade the MacBook to macOS 26 first; pin the tool version in `lab-env.sh` the way Harbor is pinned |
| **`container machine`**: persistent guest from an OCI image, image's own init as PID 1 (systemd works), all capabilities, `/proc` `/sys` unmasked, host home mounted at the same path (`rw` default, `ro` or `none` optional), host user auto-created with passwordless sudo, SSH agent forwarded, settings changed with `container machine set cpus= memory= …`, **memory defaults to half the host** | This is the VM replacement. Every machine must be created with an explicit `--memory`. Use `--home-mount ro` on anything that runs CI jobs |
| Machine images must ship `/sbin/init`; the upstream example is Ubuntu 24.04 + `systemd` + `sudo` + `openssh-server` with `multi-user.target` and some units masked | One Dockerfile in this repo produces the base image for all five machines |
| Nested virtualisation (`--virtualization`) needs M3+ **and a kernel with `CONFIG_KVM=y`**; the default kernel lacks it | Not needed for this lab (Docker and k3s are not nested VMs). Ignore unless you later want KVM inside the runner |
| The stock guest kernel is a **monolithic Kata kernel (6.18.x) with no loadable modules**: no VXLAN, no `br_netfilter`, no eBPF. `kindest/node` + kindnet and kube-proxy run on it; Flannel VXLAN and Cilium do not. `--kernel <path>` (per container and per machine) and `container system kernel set` accept a custom kernel; the kiac project publishes one with VXLAN/br_netfilter/eBPF | K3s must run with **`--flannel-backend=host-gw`** (all nodes share one L2 vmnet) or `--flannel-backend=none` + kindnet. Docker inside a machine runs without `br_netfilter` (bridge NAT still works; Docker only logs a warning). Both are Phase 0 spikes |
| Networking: `container system start` creates the `default` vmnet network (docs show `192.168.64.0/24`). Every guest gets an IP reachable from the Mac and from other guests on the same network. **No static IP flag** (apple/container issue #282 is still a request). Custom networks (`container network create --subnet`) need macOS 26 and **do not resolve bare hostnames** between guests | Stay on the `default` network. Stop treating IPs as configuration: derive them at runtime (`container inspect`) and use DNS names everywhere |
| DNS: set `[dns] domain = "lab.internal"` in `~/.config/container/config.toml`, restart the service, then `sudo container system dns create lab.internal` → each guest is `<name>.lab.internal` on the Mac (via `/etc/resolver/`) **and** inside every guest on the default network. Extra names via `--network default,alias=…` (regular containers) | Machine names become the hostnames the lab already uses: `harbor`, `runner`, `k3s-server`, `k3s-agent-1`, `k3s-agent-2`. `scripts/hosts-entries.sh` is retired |
| Storage: guest disks are sparse images that grow and never shrink; named volumes (`container volume create`, ext4) have better I/O than bind mounts; **`container machine create` has no `--volume`/`--mount` flags** (only the home mount) | Harbor `/data` lives on the machine's own disk; reclaim with GC + `container clean`. Backups go **through the home mount** (`~/Backups/...` is visible inside the machine) |
| No restart policy and no documented auto-start of containers after reboot; `container system start` registers launchd agents for the API server only | `lab.sh up` becomes the start order (Harbor → cluster → runner), optionally run by a LaunchAgent at login |
| `container cluster create` (experimental): kubeadm on `kindest/node` (default `v1.35.5`, `--node-image` to pin, `--workers N`, `--cni <manifest>`), kubeconfig merged into `~/.kube/config`, **stopped control plane cannot be restarted — delete and recreate**, no node customisation hooks | Not the primary choice (wrong distro, wrong version, not persistent) but a usable fallback for the cluster if K3s won't run in a machine. See §4 option B |
| Community: **kiac** (`saiyam1814/kiac`) runs k3s or kubeadm with one lightweight VM per node, `--distro k3s`, pinned versions 1.32–1.37, `--kernel full` for VXLAN, `kiac resume cluster` after reboot. Requires apple/container 1.0+, recommends 1.4.1 | Option C for the cluster. Proves K3s boots on this runtime; also the source of the "full" kernel if host-gw is not enough |
| `container build` runs BuildKit in a builder VM (2 CPU / 2 GiB default, `container builder start --cpus --memory`); `container registry login` for pushes; Rosetta for amd64 builds | Only matters on the Mac. CI builds keep using Docker **inside the runner machine** exactly as today |
| Default per-container sizing is 4 CPU / 1 GiB; overcommit is allowed and swaps when RAM is exhausted | Same 24 GB budget discipline as docs/02 §5, but no Fusion GUI/overhead and no need to edit `.vmx` files |

## 2. Risks and the spikes that retire them (Phase 0)

Do these on the Mac **while the Fusion lab keeps running**. Each is 30–60 min. Record results in this doc.

| # | Spike | Pass criterion | If it fails |
|---|---|---|---|
| A | **Docker CE + Compose inside a machine.** Build the Ubuntu+systemd image, `container machine create --memory 4g --name spike-docker`, run `harbor/10-bootstrap-vm.sh` logic by hand (Docker apt repo, `systemctl enable --now docker`), then `docker run --rm alpine`, `docker compose up` of a two-service stack with a published port, pull of a multi-layer image (overlay2) | `docker info` shows `overlay2`, compose services talk over the bridge, port reachable from the Mac at `spike-docker.lab.internal:<port>` | Try `--kernel` with the kiac full kernel. If still no: Harbor runs in the cluster via Helm (loses "registry survives cluster rebuild") — last resort |
| B | **K3s server + agent in machines**, stock kernel, `INSTALL_K3S_CHANNEL=v1.34`, `--flannel-backend=host-gw`, `--disable traefik` off (keep Traefik as today). Join one agent. Deploy a 2-replica pod across nodes, `curl` pod-to-pod across nodes, `kubectl logs`, `kubectl exec` | Both nodes `Ready`, cross-node pod traffic works, Traefik and metrics-server pods healthy, survives `container machine stop/run` of both machines | Retry with the kiac kernel (`--kernel`) and default VXLAN. If still no: Option B (`container cluster`, kindest v1.34) or Option C (kiac `--distro k3s`) |
| C | **Node trusts Harbor** from a machine: `registries.yaml` with the lab CA, `k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20` against the *Fusion* Harbor (temporarily `/etc/hosts`-map it inside the machine) | Pull succeeds | Nothing structural — debug containerd `hosts.toml` as in docs/08 §2 |
| D | **DNS names.** Configure `[dns] domain = "lab.internal"` + `dns create`; confirm `harbor.lab.internal` (machine named `harbor`) resolves from the Mac, from another machine, and from a pod via CoreDNS | All three resolve | Fall back to a small `lab.sh dns` step that writes `/etc/hosts` in each guest from `container inspect` output (keeps `hosts-entries.sh` alive in a new form) |
| E | **Stop/start persistence and boot order.** Stop all machines, `container system stop`, reboot the Mac, `lab.sh up` | Harbor healthy without reinstall, nodes `Ready`, runner reconnects to GitHub | Document the manual sequence; file an issue upstream if a machine loses state |
| F | **`container` CLI trusts the lab CA** on the Mac (`container registry login harbor.lab.internal`, `container image pull`) after `security add-trusted-cert` | Pull works without `--scheme http` | Keep Docker Desktop for Mac-side pushes (docs/04 §4) or skip Mac-side pushes entirely; CI pushes from the runner are unaffected |
| G | **Subnet collision while both hypervisors are installed.** Compare Fusion `dhcpd.conf` subnet with `container network list` | No overlap | Set `[network] subnet` in `config.toml` to a free `/24` before `container system start`; the lab's `192.168.64.x` placeholders are irrelevant after migration anyway |

Decision gate after Phase 0: **A, B, D, E must pass** (or have an accepted fallback) before Phase 2.

## 3. Repository changes (Phase 1)

Done on a branch while Fusion still serves the lab; nothing here touches running guests.

### 3.1 New files

| File | Purpose |
|---|---|
| `machines/Dockerfile` | Ubuntu 24.04 arm64 + `systemd sudo openssh-server ca-certificates curl` …, `multi-user.target`, masked units per upstream example, lab CA baked in from a build arg (optional), `sshd` enabled. Built with `container build -t lab/ubuntu-machine:24.04 machines/` |
| `machines/README.md` | How the image is built, what is masked and why, how to rebuild after a base-image CVE |
| `lab.sh` | Replaces the external `~/Virtual Machines.localized/k3s-lab/lab.sh` **and** the manual Fusion power-on steps. Verbs: `up` (system start → harbor → wait health → k3s-server → agents → runner), `stop` (reverse), `status` (`container machine ls` + health), `create <machine>` (idempotent `container machine create` with sizes from `lab-env.sh`), `destroy-cluster` (rm the three k3s machines only), `ip <machine>`, `shell <machine>` |
| `k3s/00-install-k3s.sh` | What the old external `lab.sh` did: install K3s `v1.34` on `k3s-server` (`--flannel-backend=host-gw`, `--write-kubeconfig-mode 644`, `--tls-san k3s-server.lab.internal`), join agents with the node token, write the `k3s-lab` context into `~/.kube/config` with `server: https://k3s-server.lab.internal:6443` |
| `scripts/launchd/com.kubernetes-lab.up.plist` (optional) | LaunchAgent that runs `lab.sh up` at login, so the lab comes back after a reboot the way Fusion auto-start did |

### 3.2 Edited files

| File | Change |
|---|---|
| `lab-env.sh` | Remove `HARBOR_IP`, `RUNNER_IP`, `K3S_SERVER_IP`, `K3S_AGENT_IPS` as *inputs*. Add `LAB_MACHINE_IMAGE`, per-machine `cpus`/`memory` (`MACHINE_SIZES[harbor]="2:4g"` …), `CONTAINER_VERSION="1.6.1"`, and helpers: `lab_ip <machine>` (via `container inspect`), `lab_exec <machine> [--root] <cmd>` (wraps `container machine run -n`), `lab_copy` (home mount or `container cp`). Keep `K3S_SSH_USER`/`VM_SSH_USER` only if SSH is retained for convenience (see §3.3) |
| `scripts/hosts-entries.sh` | **Retire.** Replace with `lab.sh dns` that verifies the `container` DNS domain exists (spike D fallback keeps an `/etc/hosts` writer here) |
| `harbor/20-gen-certs.sh` | SANs become `harbor.lab.internal`, `harbor` only; drop the IP SAN (IP is dynamic). Existing certs stay valid — the hostname SAN is what every client uses |
| `harbor/00-push-to-vm.sh` | Either delete (the repo is already visible inside the machine via the home mount) or reduce to copying `secrets/certs/*` into the machine with `lab_copy`. Recommend: keep a thin version so the machine never depends on iCloud Drive being mounted |
| `harbor/10-bootstrap-vm.sh` | Drop `ufw` (no inbound exposure beyond the vmnet; and the stock kernel may lack the netfilter bits ufw wants), keep Docker install, CA trust, `/data`. `hostnamectl` works under systemd; keep |
| `harbor/30-install-harbor.sh`, `harbor/40-init-harbor.sh` | Unchanged except `HARBOR_IP` references → `$(lab_ip harbor)` (only used for the SAN/hosts block today) |
| `k3s/10-trust-harbor-ca.sh` | Loop over machine names instead of IPs; `ssh` → `lab_exec`; same `registries.yaml` template, same restart of `k3s`/`k3s-agent` |
| `k3s/40-make-kubeconfig.sh` | `server: https://k3s-server.lab.internal:6443` instead of the IP (the TLS SAN is added in `00-install-k3s.sh`) |
| `k3s/registries.yaml.template` | Unchanged |
| `runner/10-prep-runner-vm.sh` | Drop `ufw`; `binfmt` amd64 install becomes best-effort (already is); everything else unchanged. Runner machine is created with `--home-mount ro` so a CI job cannot write to the Mac's home directory |
| `scripts/verify.sh` | `ssh_q` → `lab_exec`; add checks: `container system status`, DNS resolution of all five names from the Mac, `container machine ls` shows all five running |
| `README.md`, `docs/01`–`08` | Replace Fusion/vmnet/`.vmx`/DHCP-reservation text (see §6 doc map). Architecture diagram header, resource table, start/stop order, troubleshooting §4 |

### 3.3 SSH or `container machine run`?

Every script today shells out with `ssh user@ip`. Two viable paths:

- **Keep SSH.** The machine image enables `sshd`; the auto-created user is your macOS user; put your public key in
  `authorized_keys` at image-build time. Scripts change only the target (`john@harbor.lab.internal`) and `k9s`,
  `scp`, `rsync` all keep working. Cost: host-key churn whenever a machine is recreated (IP and key change).
- **Use `container machine run -n <machine> -- <cmd>`** through a `lab_exec` helper. No keys, no host-key prompts,
  works even before networking is up. Cost: `rsync`/`scp` idiom is replaced by the home mount or `container cp`.

Recommendation: `lab_exec` for scripts (deterministic, no key management), SSH kept for interactive use.

## 4. Cluster options (pick in Phase 0)

| Option | What | Keeps | Loses | When |
|---|---|---|---|---|
| **A — K3s v1.34 on three machines** (recommended) | Same distro and minor as work VKS, same `registries.yaml` plumbing, same PSA, SSH-able nodes, `k3s crictl` debugging | Everything in docs/02, 04, 08 §2 | Flannel VXLAN (use host-gw); Fusion snapshots | Spike B passes on the stock or kiac kernel |
| B — `container cluster create --node-image kindest/node:v1.34.x --workers 2` | Apple-maintained, one command, kubeconfig auto-merged | Fast rebuilds, `load-image` for local images | kubeadm not K3s; cluster is gone whenever the control plane stops; CA trust must be re-applied with `container exec` into the node (`/etc/containerd/certs.d/`) after every create; experimental API | Spike B fails and you accept a kind-style disposable cluster |
| C — kiac `--distro k3s --k8s-version 1.34` | K3s per-VM nodes, `resume` after reboot, built-in LoadBalancer and local-path storage | K3s, persistence | Third-party tool and kernel in the critical path; kindnet instead of Flannel; version compatibility churn (1.2.0 was incompatible) | You want K3s but B-spike shows the stock kernel is the blocker and you'd rather not maintain a custom machine image for nodes |

With A, the `lab.sh destroy-cluster && lab.sh up` rebuild in docs/02 §6 still holds, and Harbor/runner stay
untouched because they are separate machines.

## 5. Cutover sequence

Order is chosen so Fusion can be powered back on at any point before Phase 5 and nothing is lost.

| Phase | Steps | Done when |
|---|---|---|
| **0 Prepare** (no lab impact) | macOS 26; install `container` 1.6.1 pkg; `container system start`; `config.toml` `[dns] domain`, `[container]` defaults, `[network] subnet` if spike G says so; `sudo container system dns create lab.internal`; build `lab/ubuntu-machine`; run spikes A–G; **make a Harbor backup** per docs/07 §3 and a copy of `secrets/` | Decision gate passed, backup tarball on the Mac |
| **1 Repo** | §3 changes on a branch; `shellcheck` everything; dry-run `lab.sh create` against throwaway machine names | PR merged |
| **2 Harbor** | Fusion Harbor VM: `docker compose down` (frozen, not deleted). `lab.sh create harbor` (`--memory 4g`, `--home-mount ro`); `10-bootstrap`; restore `/data` + `harbor.yml` from the backup; `30-install-harbor.sh` (same `HARBOR_VERSION`, finds existing `/data`); **no `40-init` needed** — projects, robots, proxy cache come back with the DB; `docs/03 §6` smoke test from the Mac using `container registry login` (or Docker Desktop if spike F failed) | `curl https://harbor.lab.internal/api/v2.0/health` healthy, existing images listed, `docker pull` via proxy cache works |
| **3 Cluster** | `lab.sh create k3s-server k3s-agent-1 k3s-agent-2` (3 g / 2.5 g / 2.5 g); `k3s/00-install-k3s.sh`; `k3s/10-trust-harbor-ca.sh` (now pointing at the **new** Harbor); `kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml`; `k3s/50-pull-secrets.sh`; `k3s/40-make-kubeconfig.sh` | `kubectl get nodes` 3× Ready, `crictl pull` via Harbor works, sample-deploy overlay rolls out under PSA restricted |
| **4 Runner** | `lab.sh create runner` (4 g, `--home-mount ro`); `runner/10-prep-runner-vm.sh`; install kubeconfig (docs/05 §3); **remove the old runners in GitHub** (Settings → Actions → Runners) and register new ones per docs/05 §4 with the same labels; `.env` unchanged | `runner-smoke` workflow green; `scripts/verify.sh` all PASS |
| **5 Decommission Fusion** | Power off all Fusion VMs; move `~/Virtual Machines.localized/{k3s-lab,harbor,runner}` to an external disk or delete after 2 weeks of clean operation; remove the `host harbor {}` / `host runner {}` blocks from `/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf` (moot once Fusion is gone); uninstall Fusion (Trash the app, then `/Library/Preferences/VMware Fusion`, `/Library/Application Support/VMware`, `~/Library/Application Support/VMware Fusion`, `~/Library/Preferences/com.vmware.fusion*`, `~/Library/Caches/com.vmware.fusion`); delete the Fusion `/etc/hosts` block the old `hosts-entries.sh --apply` wrote (`# >>> kubernetes-lab >>>`) | `container` is the only hypervisor; `/etc/hosts` has no lab entries; docs updated |

Rollback at any phase before 5: `lab.sh stop`, power on the Fusion VMs, re-apply the `/etc/hosts` block with the
old script (keep a copy in `git log` until Phase 5). Harbor data cannot diverge because the Fusion Harbor is
frozen at the backup point; if you rolled back after pushing new images to the new Harbor, take a fresh backup
from the machine first (same tar procedure, written to `~/Backups` through the home mount).

## 6. Documentation map

| Doc | Edits |
|---|---|
| `README.md` | Header diagram (Fusion → `container machine`), decision table row for hypervisor, quick-start rows 1/3/8 (`lab.sh create …` instead of "Fusion: create VM"), sizing paragraph, folder layout (`machines/`, `lab.sh`, `k3s/00-install-k3s.sh`), link to this doc |
| `docs/01-architecture.md` | Components table "Host" column; Networking section rewritten around the default vmnet network + DNS domain; remove DHCP-reservation paragraph; ports table unchanged |
| `docs/02-cluster-k3s.md` | §1 becomes `lab.sh up` + `k3s/00-install-k3s.sh`; §5 budget table for machines; §6 rebuild uses `lab.sh destroy-cluster` |
| `docs/03-harbor-vm.md` | §2 "Create the VM (Fusion)" → "Create the machine" (one command, no ISO, no IP fixing); §3 push step simplified; §7 add `container clean` / disk growth note |
| `docs/04-trust-harbor-ca.md` | §4 Docker Desktop → `container` CLI trust (spike F result) |
| `docs/05-github-runner.md` | §1 create machine; mention `--home-mount ro` and why; §4 unchanged |
| `docs/07-operations.md` | §1 start/stop order → `lab.sh up/stop`; "suspend runner" → `container machine stop runner`; §3 backups written via home mount; add "reclaiming disk" (`container system df`, `container clean`, `container image prune`) |
| `docs/08-troubleshooting.md` | §4 "Networking / Fusion" → "Networking / container": name not resolving (`container system dns list`, `/etc/resolver/lab.internal`), machine IP changed (nothing to do — names), `container system start` fails after upgrade (`container system stop` first), stock-kernel symptoms (`modprobe: not found`, VXLAN), memory pressure (`container stats`) |
| `docs/09` (this) | Fill in spike results; convert to a record of what was done |

## 7. Resource budget after migration

| Machine | vCPU | RAM | Notes |
|---|---|---|---|
| harbor | 2 | 4 g | Harbor minimum; Trivy scanning is the memory hog |
| k3s-server | 2 | 3 g | control plane + Traefik, schedulable |
| k3s-agent-1 / 2 | 2 | 2.5 g each | app workloads |
| runner | 2 | 4 g | docker buildx + .NET SDK builds |
| **total** | 10 | **16 g** of 24 | 4 g less than Fusion with the same roles; no Fusion GUI, no per-VM video/EFI overhead |

Builder VM (`container build` on the Mac) is extra and only alive while building; stop it with
`container builder stop` when done. Per-machine `cpus=`/`memory=` are changed with `container machine set` and
take effect after a stop/start — no more editing `.vmx` files.

## 8. What you gain and what you give up

Gain: no Fusion licence or updates; guests boot in seconds; machines are reproducible from a Dockerfile instead
of an ISO install; names instead of IPs (no more `hosts-entries.sh --push` after a reboot); the home mount makes
`secrets/`, scripts and backups visible inside every guest; nested virtualisation is available on the M5 if a future
exercise needs KVM; the same `container` tool builds and pushes images from the Mac.

Give up: Fusion snapshots and suspend (use stop/start and the `tar` backups); fixed IPs (nothing in the lab needs
them once DNS is on); the Fusion GUI console (use `container machine logs --boot <name>` and `lab.sh shell`);
loadable kernel modules (host-gw Flannel instead of VXLAN; no Cilium without a custom kernel); the experimental
label on parts of the tool, and a release cadence of roughly one minor per month, so pin the version and upgrade on
purpose.

## 9. Open questions to settle during Phase 0

1. Does a `container machine` register under the `[dns]` domain the same way a regular container does? (Community
   write-ups use `ubuntu.machine` style names for machines, which suggests yes.)
2. Does `container start <machine>` boot a stopped machine, or only `container machine run -n <machine>`? `lab.sh up`
   needs a non-interactive boot verb.
3. Does Docker's `binfmt` amd64 registration work on the stock kernel (`binfmt_misc`)? Only affects optional
   cross-builds for GHCR.
4. How large can a machine's root disk grow, and is there a flag for it? Harbor `/data` was sized at 60 GB on
   Fusion. If the sparse image has no hard cap, rely on weekly GC + `container clean`.
5. Does the `container` CLI honour the System keychain for private CAs (spike F), or does it need the CA in a
   config path?
