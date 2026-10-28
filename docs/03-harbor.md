# 03 — Harbor on Docker Desktop (docker compose)

Goal: `https://harbor.lab.internal` serving Harbor **v2.16.0-rc1 (arm64)** with Trivy, a Docker Hub proxy
cache, and two robot accounts — as a compose stack on the Mac's Docker engine. Estimated time: 20–30 min,
most of it the 700 MB installer download.

> **Why 2.16.0-rc1?** Harbor only started publishing official multi-arch images and an arm64 offline
> installer with 2.16.0 ("Full Multi-Architecture Enablement", PR #22311). Every stable release up to
> 2.15.x is amd64-only and would run under emulation on Apple silicon. When `v2.16.0` GA appears
> on https://github.com/goharbor/harbor/releases, change `HARBOR_VERSION` in `lab-env.sh` and re-run
> `30-install-harbor.sh` — upgrade path is in docs/07 §4. (2.16 also swaps Redis for Valkey; no action needed.)

## 1. Certificates and trust (Mac)

```bash
cd "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab"
source lab-env.sh
./harbor/20-gen-certs.sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/certs/ca.crt
# Docker Desktop builds its engine's CA bundle from the keychain at start-up:
#   Docker menu → Restart   (or Quit and reopen)
./scripts/hosts-entry.sh --apply        # 127.0.0.1 harbor.lab.internal
```

Produces `secrets/certs/ca.{key,crt}` (10 y) and `harbor.{key,crt}` (2 y, SANs: hostname, `harbor`, `nginx`,
`localhost`, `127.0.0.1`). `ca.key` never leaves the Mac. The keychain step is **not optional** here: it is how
`docker push` from the Mac and from CI jobs trusts Harbor (docs/04 §3).

## 2. Where it lives

`HARBOR_HOME` (default `~/Lab/harbor`, set in `lab-env.sh`):

| Path | What | Notes |
|---|---|---|
| `harbor/` | unpacked offline installer: `harbor.yml`, `docker-compose.yml`, `docker-compose.override.yml`, `common/` | compose project name `harbor` → network `harbor_harbor` |
| `data/` | registry blobs, Postgres, Valkey, Trivy DB, secret key | `harbor.yml` `data_volume`; **this is Harbor** — back it up (docs/07 §3) |
| `log/` | Harbor's log files | `harbor.yml` `log.local.location` (Harbor's default `/var/log/harbor` is not shared with Docker Desktop) |
| `certs/` | `harbor.crt`, `harbor.key`, `ca.crt` | copied from `secrets/certs` |
| `downloads/` | installer tarballs | safe to delete |

Two rules the install script enforces: the folder must be **outside iCloud Drive** (registry blobs must not sync;
the repo itself lives in iCloud, the data does not), and inside Docker Desktop's file-sharing list (`/Users` is
shared by default — Settings → Resources → File sharing).

## 3. Install Harbor (Mac)

```bash
./harbor/30-install-harbor.sh
```

What it does, so you can do it by hand on a work box:

1. Generates `secrets/harbor-admin.pw` and `secrets/harbor-db.pw` once.
2. Downloads `harbor-offline-installer-v2.16.0-rc1-arm64.tgz` from GitHub releases, checks the md5.
3. Unpacks to `~/Lab/harbor/harbor`.
4. Copies `harbor.crt/key` and the CA to `~/Lab/harbor/certs/`.
5. Copies `harbor.yml.tmpl → harbor.yml` and patches: `hostname`, `https.certificate/private_key`,
   `harbor_admin_password`, `database.password`, `data_volume`, `log.local.location`, `trivy.ignore_unfixed: false`.
6. Renders `docker-compose.override.yml` next to Harbor's compose file: the `proxy` service (container `nginx`)
   gets the network aliases `harbor.lab.internal` and `harbor`, so k3d nodes and runners on `harbor_harbor` reach it by
   the real hostname. Compose merges override files automatically; Harbor's `prepare` never touches it.
7. `./install.sh --with-trivy` — loads the arm64 images from the tarball and brings up compose.
8. Polls `/api/v2.0/health` until `healthy`.

Re-running the script on an installed Harbor = **reconfigure**: it re-renders `harbor.yml` and runs
`prepare` + `docker compose stop/up`. That's the sanctioned way to change settings in compose-based Harbor.

Managing it afterwards:

| Task | Command |
|---|---|
| status | `docker compose --project-directory ~/Lab/harbor/harbor ps` (or `./lab.sh status`) |
| logs | `docker compose --project-directory ~/Lab/harbor/harbor logs -f core jobservice registry` or `~/Lab/harbor/log/*.log` |
| stop / start | `… stop` / `… up -d` — use **`stop`, not `down`**: the k3d nodes are attached to `harbor_harbor` and `down` would try to remove it |
| restart after reboot | automatic: containers are `restart: always`, Docker Desktop starts at login; allow ~60 s |
| admin password | `cat secrets/harbor-admin.pw` |

## 4. Initialise Harbor (Mac)

```bash
./harbor/40-init-harbor.sh
```

Creates, idempotently:

| Object | Detail |
|---|---|
| Projects `containerhelper`, `devopshelpers`, `lab` | private; **auto-scan on push**; `prevent_vul` off (turn on per project in the UI to block pulls of Critical images — useful later for your EPSS/KEV policy work) |
| Registry endpoint `dockerhub` + project `dockerhub` | **proxy cache** of Docker Hub, public. Pull `harbor.lab.internal/dockerhub/library/alpine:3.20` (note `library/` for official images). Saves you from Hub rate limits and lets k3s pull base images with no auth |
| `robot$gha-push` | system-level robot: pull/push/list on your 3 projects, read scan results; pull on `dockerhub`. Goes into GitHub repo secrets |
| `robot$k3s-pull` | pull-only on everything. Goes into `secrets/registries.yaml` (mounted into the nodes) and into the `harbor-pull` imagePullSecret |

Secrets land in `secrets/harbor-robot-<name>.{user,token}`. Robot secrets **cannot be re-read** from Harbor;
`--rotate-robots` deletes and recreates them (then re-run `k3s/10-render-registries.sh`, `k3s/50-pull-secrets.sh`
and update the GitHub secrets).

Skip this step after a **restore from backup** (docs/07 §3): projects, robots and the proxy cache come back
with the database, and the robot tokens are still the ones in `secrets/`.

## 5. Smoke test (Mac)

```bash
docker pull harbor.lab.internal/dockerhub/library/alpine:3.20            # proxy cache; proves the engine trusts ca.crt
docker login harbor.lab.internal -u "$(cat secrets/harbor-robot-gha-push.user)" -p "$(cat secrets/harbor-robot-gha-push.token)"
docker tag harbor.lab.internal/dockerhub/library/alpine:3.20 harbor.lab.internal/lab/alpine:test
docker push harbor.lab.internal/lab/alpine:test
open https://harbor.lab.internal/harbor/projects   # Projects → lab → alpine → scan results appear within ~1 min
docker inspect nginx --format '{{json .NetworkSettings.Networks}}' | grep -o 'harbor.lab.internal'   # alias present
```

## 6. Things worth knowing about compose-based Harbor on Docker Desktop

- **Config is `harbor.yml`, applied by `prepare`.** Editing files under `harbor/common/config/` directly is
  overwritten on the next `prepare`. The override file is the one thing `prepare` leaves alone.
- **`data/` is everything**: registry blobs (`data/registry`), Postgres (`data/database`), Valkey, Trivy DB,
  secret key (`data/secret`). Back up `data/` + `harbor/harbor.yml` and you can rebuild. docs/07 §3.
- Harbor's own nginx takes 80/443 on the Mac, so nothing else can share those ports there — Traefik is on 8080/8443.
- Harbor's containers log to its `log` container over syslog at `127.0.0.1:1514` (a published port). That works on
  Docker Desktop because published ports are bound inside the VM as well; if a container ever shows
  `failed to initialize logging driver`, the override template has a commented `json-file` fallback (docs/08 §1).
- Trivy needs outbound access to `ghcr.io` for DB updates; in an air-gapped work environment you'd set
  `trivy.skip_update: true` and `offline_scan: true` and load the DB by hand.
- Garbage collection is **not** automatic. Schedule it: Administration → Clean Up → Garbage Collection → weekly.
- Bind mounts from the Mac filesystem are slower than Docker volumes. For a lab registry that is fine; if pushes
  feel slow, the first thing to check is Docker Desktop's file-sharing implementation (VirtioFS is the fast one).
