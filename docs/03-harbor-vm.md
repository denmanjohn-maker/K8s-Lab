# 03 — Harbor VM (docker compose)

Goal: `https://harbor.lab.internal` serving Harbor **v2.16.0-rc1 (arm64)** with Trivy, a Docker Hub proxy
cache, and two robot accounts. Estimated time: 30–40 min, most of it the 700 MB installer download.

> **Why 2.16.0-rc1?** Harbor only started publishing official multi-arch images and an arm64 offline
> installer with 2.16.0 ("Full Multi-Architecture Enablement", PR #22311). Every stable release up to
> 2.15.x is amd64-only and will not run natively on Apple-Silicon Fusion VMs. When `v2.16.0` GA appears
> on https://github.com/goharbor/harbor/releases, change `HARBOR_VERSION` in `lab-env.sh` and re-run
> `30-install-harbor.sh` — upgrade path is in docs/07 §4. (2.16 also swaps Redis for Valkey; no action needed.)

## 1. Certificates (Mac)

```bash
cd "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab"
source lab-env.sh
./harbor/20-gen-certs.sh
# optional – trust the lab CA on the Mac so the Harbor UI and `curl` are clean:
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/certs/ca.crt
```

Produces `secrets/certs/ca.{key,crt}` (10 y) and `harbor.{key,crt,cert}` (2 y, SANs: hostname, `harbor`, IP).
`ca.key` never leaves the Mac.

## 2. Create the VM (Fusion)

| Setting | Value |
|---|---|
| Image | Ubuntu Server 24.04.x **arm64** ISO (same one `k3s-lab` used; in `~/Virtual Machines.localized/VMWIsoImages`) |
| Name | `harbor` |
| vCPU / RAM | 2 / **4 GB** (Harbor's documented minimum; 8 GB recommended if you enable lots of Trivy scanning) |
| Disk | 60 GB (Harbor minimum is 40 GB; `/data` holds the registry blobs) |
| Network | **Share with my Mac (NAT)** — same vmnet8 as k3s-lab |
| Installer choices | user `john` (= `VM_SSH_USER`), **Install OpenSSH server**, no snaps, hostname `harbor` |

**Fix the IP.** Pick one of:

*a) DHCP reservation (preferred — nothing to configure in the VM)*. Get the VM's MAC from
`Settings → Network Adapter → Advanced`, then on the Mac:

```bash
sudo vi "/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf"
# append, outside the existing subnet {} block:
host harbor {
    hardware ethernet 00:50:56:xx:xx:xx;
    fixed-address 192.168.64.50;      # = HARBOR_IP
}
sudo /Applications/VMware\ Fusion.app/Contents/Library/vmnet-cli --stop
sudo /Applications/VMware\ Fusion.app/Contents/Library/vmnet-cli --start
```
In the VM: `sudo dhclient -r && sudo dhclient` (or reboot). Check Fusion's subnet first — `grep subnet
"/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf"` — and make `lab-env.sh` match it; `192.168.64.x`
is a placeholder.

*b) Static IP in the VM* (Netplan):

```yaml
# /etc/netplan/50-cloud-init.yaml  (then: sudo netplan apply)
network:
  version: 2
  ethernets:
    ens160:               # check with `ip link`
      dhcp4: false
      addresses: [192.168.64.50/24]
      routes: [{ to: default, via: 192.168.64.2 }]   # Fusion NAT gateway is usually .2
      nameservers: { addresses: [192.168.64.2] }
```

Then from the Mac: `./scripts/hosts-entries.sh --push` and confirm `ssh john@harbor.lab.internal`.

## 3. Push files and bootstrap (Mac → VM)

```bash
./harbor/00-push-to-vm.sh          # generates admin/db passwords once; rsyncs lab-env.sh, harbor/, certs → ~/lab
ssh john@harbor.lab.internal
~/lab/harbor/10-bootstrap-vm.sh    # Docker CE + compose v2, CA trust, ufw (22/80/443), /data
exit && ssh john@harbor.lab.internal   # re-login so the docker group applies
```

## 4. Install Harbor (VM)

```bash
~/lab/harbor/30-install-harbor.sh
```

What it does, so you can do it by hand on a work box:

1. Downloads `harbor-offline-installer-v2.16.0-rc1-arm64.tgz` from GitHub releases, checks `md5sum`.
2. Unpacks to `/opt/harbor`.
3. Installs `harbor.crt/key` to `/etc/harbor/certs/`, and the CA to `/etc/docker/certs.d/harbor.lab.internal/ca.crt`.
4. Copies `harbor.yml.tmpl → harbor.yml` and patches: `hostname`, `https.certificate/private_key`,
   `harbor_admin_password`, `database.password`, `data_volume: /data`, `trivy.ignore_unfixed: false`.
5. `sudo ./install.sh --with-trivy` — loads the images from the tarball and brings up compose.
6. Polls `/api/v2.0/health` until `healthy`.

Re-running the script on an installed Harbor = **reconfigure**: it re-renders `harbor.yml` and runs
`prepare` + `docker compose down/up`. That's the sanctioned way to change settings in compose-based Harbor.

Managing it afterwards (`cd /opt/harbor` first, always `sudo`):

| Task | Command |
|---|---|
| status | `sudo docker compose ps` |
| logs | `sudo docker compose logs -f core jobservice registry` or `/var/log/harbor/*.log` |
| stop / start | `sudo docker compose down` / `sudo docker compose up -d` |
| restart after reboot | automatic (containers are `restart: always`); allow ~60 s |
| admin password | `cat ~/lab/secrets/harbor-admin.pw` on the VM, or `secrets/harbor-admin.pw` on the Mac |

## 5. Initialise Harbor (Mac)

```bash
./harbor/40-init-harbor.sh
```

Creates, idempotently:

| Object | Detail |
|---|---|
| Projects `containerhelper`, `devopshelpers`, `lab` | private; **auto-scan on push**; `prevent_vul` off (turn on per project in the UI to block pulls of Critical images — useful later for your EPSS/KEV policy work) |
| Registry endpoint `dockerhub` + project `dockerhub` | **proxy cache** of Docker Hub, public. Pull `harbor.lab.internal/dockerhub/library/alpine:3.20` (note `library/` for official images). Saves you from Hub rate limits and lets k3s pull base images with no auth |
| `robot$gha-push` | system-level robot: pull/push/list on your 3 projects, read scan results; pull on `dockerhub`. Goes into GitHub repo secrets |
| `robot$k3s-pull` | pull-only on everything. Goes into `registries.yaml` on the nodes and into the `harbor-pull` imagePullSecret |

Secrets land in `secrets/harbor-robot-<name>.{user,token}`. Robot secrets **cannot be re-read** from Harbor;
`--rotate-robots` deletes and recreates them (then re-run `k3s/10-trust-harbor-ca.sh`, `k3s/50-pull-secrets.sh`
and update the GitHub secrets).

## 6. Smoke test (Mac)

```bash
docker pull harbor.lab.internal/dockerhub/library/alpine:3.20            # proxy cache (Docker Desktop must trust ca.crt — see docs/04 §4)
docker login harbor.lab.internal -u "$(cat secrets/harbor-robot-gha-push.user)" -p "$(cat secrets/harbor-robot-gha-push.token)"
docker tag alpine:3.20 harbor.lab.internal/lab/alpine:test && docker push harbor.lab.internal/lab/alpine:test
open https://harbor.lab.internal/harbor/projects   # Projects → lab → alpine → scan results appear within ~1 min
```

## 7. Things worth knowing about compose-based Harbor

- **Config is `harbor.yml`, applied by `prepare`.** Editing files under `/opt/harbor/common/config/` directly is
  overwritten on the next `prepare`.
- **`/data` is everything**: registry blobs (`/data/registry`), Postgres (`/data/database`), Valkey, Trivy DB,
  secret key (`/data/secret`). Back up `/data` + `harbor.yml` and you can rebuild the VM. docs/07 §3.
- Harbor's own nginx binds 80/443 on the VM, so nothing else can share those ports there.
- Trivy needs outbound access to `ghcr.io` for DB updates; in an air-gapped work environment you'd set
  `trivy.skip_update: true` and `offline_scan: true` and load the DB by hand.
- Garbage collection is **not** automatic. Schedule it: Administration → Clean Up → Garbage Collection → weekly.
- The UI's Interrogation Services page shows Trivy health; "Scan All" is useful after a DB update.
