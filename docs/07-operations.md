# 07 — Operations

## 1. Start / stop order

Harbor first, cluster second, runners last — the cluster pulls from Harbor and the runners push to it.
`lab.sh` encodes the order.

| Action | Steps |
|---|---|
| **Start** | Docker Desktop starts at login and restarts every container by itself (Harbor `restart: always`, nodes and runners `unless-stopped`). After a manual stop: `./lab.sh up` (Harbor → wait for health → `k3d cluster start` → runners) |
| **Stop** | `./lab.sh stop` (runners → `k3d cluster stop` → Harbor `compose stop`). Stopped containers stay stopped until the next Docker Desktop restart or `up` |
| **Low-memory mode** | `docker compose -f runner/docker-compose.yml stop` (queued jobs wait; runners show *Offline*), or `k3d cluster stop k3s-lab` when only Harbor work is needed. Harbor has to stay up while the cluster is pulling |
| **Cluster rebuild** | `./lab.sh destroy-cluster && ./lab.sh create-cluster`, then docs/02 §3 (three commands) and a runner restart. Harbor keeps every image |
| **Everything off** | `./lab.sh stop`, then quit Docker Desktop (Resource Saver also idles the VM on its own) |
| **Everything gone** | `./lab.sh reset` — runners (and their GitHub registrations), cluster, Harbor + data, hosts line, keychain CA. `secrets/` stays unless `--purge-secrets`. `./install.sh` rebuilds it all |

Quick health check from the Mac: `./lab.sh status` or `./scripts/verify.sh`.

## 2. Day-2 on Harbor

| Task | How |
|---|---|
| Garbage collection (reclaims deleted blobs) | UI → Administration → Clean Up → Garbage Collection → schedule **weekly**, "delete untagged artifacts" on |
| Tag retention (keep last N per repo) | Project → Policy → Tag Retention: `retain the most recently pushed 10 artifacts` + `retain always :latest` |
| Trivy DB freshness | automatic on scan; UI → Interrogation Services → Scanners shows last update. Air-gapped note in docs/03 §6 |
| Proxy-cache growth | project `dockerhub` → Configuration → *Proxy cache*: set a 7-day cache TTL for untagged blobs |
| Disk | `du -sh ~/Lab/harbor/data/*` — registry blobs dominate; weekly GC keeps months of lab churn in a few GB |
| Logs | `~/Lab/harbor/log/*.log` (rotated 50×200 MB per `harbor.yml`) |
| Admin password reset | `harbor.yml` only sets it on first install; afterwards change it in the UI (then update `secrets/harbor-admin.pw`) |

## 3. Backup / restore (Harbor)

Everything is `~/Lab/harbor/data` + `~/Lab/harbor/harbor/harbor.yml`. Postgres must be stopped (or dumped) for a
consistent copy:

```bash
# backup — on the Mac
source lab-env.sh
docker compose --project-directory "$HARBOR_INSTALL_DIR" stop
mkdir -p ~/Backups/kubernetes-lab
tar -C "$HARBOR_HOME" -czf ~/Backups/kubernetes-lab/harbor-backup-$(date +%F).tgz data harbor/harbor.yml
docker compose --project-directory "$HARBOR_INSTALL_DIR" up -d

# restore — on a fresh Mac / fresh HARBOR_HOME
./harbor/30-install-harbor.sh                       # lays down harbor/, certs, harbor.yml; first install
docker compose --project-directory "$HARBOR_INSTALL_DIR" stop
rm -rf "$HARBOR_HOME/data" && tar -C "$HARBOR_HOME" -xzf ~/Backups/kubernetes-lab/harbor-backup-YYYY-MM-DD.tgz data
./harbor/30-install-harbor.sh                       # same HARBOR_VERSION; re-renders harbor.yml for this Mac's paths and brings it up
```

Do not restore `harbor.yml` itself across machines — `data_volume` and `log.local.location` are absolute paths and
`30-install-harbor.sh` renders the right ones.

Alternative without downtime: `docker compose … exec postgresql pg_dumpall -U postgres > db.sql` plus a copy of
`data/registry`; restore is more fiddly, so the stop-and-tar approach is the lab default. Time Machine also sees
`~/Lab/harbor/data` — exclude it if you'd rather keep backups explicit.

## 4. Upgrading Harbor (e.g. 2.16.0-rc1 → 2.16.0 GA)

1. Backup (§3). Note current version: `curl -s --cacert secrets/certs/ca.crt https://harbor.lab.internal/api/v2.0/systeminfo | jq .harbor_version`.
2. Set `HARBOR_VERSION="v2.16.0"` in `lab-env.sh`.
3. `docker compose --project-directory "$HARBOR_INSTALL_DIR" stop`; `mv "$HARBOR_INSTALL_DIR" "$HARBOR_INSTALL_DIR-$(date +%F)"`; then
   `./harbor/30-install-harbor.sh` — it downloads the new tarball, re-renders `harbor.yml` from the *new*
   template, and runs `install.sh` against the existing `data/`. Harbor migrates the DB schema on first start.
4. Within the same minor (2.16.x) that is the whole procedure. Across minors, Harbor documents a `migrate` step
   with the `goharbor/prepare:<ver>` image; check the release notes before moving to 2.17.

## 5. Upgrading K3s

Change `K3S_IMAGE` in `lab-env.sh` (stay on the `v1.34` minor to match work VKS) and re-create the cluster:
`./lab.sh destroy-cluster && ./lab.sh create-cluster`, then docs/02 §3. k3d has no in-place node upgrade, and the
cluster is disposable by design. `K3S_CHANNEL` drives the kubectl version in the runner image — rebuild it when you
move minors.

## 6. Secrets inventory (`secrets/`, git-ignored)

| File | Used by | Rotate with |
|---|---|---|
| `certs/ca.key` `ca.crt` | everything | docs/04 §4 (CA replacement — rare) |
| `certs/harbor.{key,crt}` | Harbor nginx | `harbor/20-gen-certs.sh --renew` + `30-install` |
| `harbor-admin.pw` `harbor-db.pw` | Harbor | UI for admin; DB password only via reinstall |
| `harbor-robot-gha-push.{user,token}` | GitHub secrets | `harbor/40-init-harbor.sh --rotate-robots` + `gh secret set` |
| `harbor-robot-k3s-pull.{user,token}` | `registries.yaml`, `harbor-pull` secrets | `--rotate-robots` + `k3s/10-…` + `k3s/50-…` |
| `registries.yaml` (rendered) | mounted into every k3d node | `k3s/10-render-registries.sh` |
| `k3d-config.yaml` (rendered) | `k3d cluster create` | `./lab.sh create-cluster` |
| `kubeconfig-gha-deployer.yaml` | mounted into the runners | `kubectl -n containerhelper delete secret gha-deployer-token && kubectl apply -f k3s/30-deployer-rbac.yaml && ./k3s/40-make-kubeconfig.sh`, then restart the runners |
| `runner-token-<repo>` | first start of each runner | new token from GitHub; only needed again after `down -v` |

Back the folder up somewhere encrypted (it is inside iCloud already; that is fine for a lab, not for work).

## 7. Reclaiming disk

Docker Desktop's VM disk grows with images, build cache and the k3d nodes' containerd stores, and only shrinks when
you prune:

```bash
docker system df
./lab.sh prune                       # builder cache > 7 days, images > 14 days
docker exec k3d-k3s-lab-agent-0 k3s crictl rmi --prune    # unused images inside a node (Kubernetes GC also does this)
```

Harbor's blobs are on the Mac filesystem (`~/Lab/harbor/data`), governed by Harbor GC (§2), not by Docker prune.
