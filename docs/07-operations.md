# 07 — Operations

## 1. Start / stop order

Harbor first, cluster second, runner last — the cluster pulls from Harbor and the runner pushes to it.

| Action | Steps |
|---|---|
| **Start** | Fusion: power on `harbor` → wait for `curl -fsS https://harbor.lab.internal/api/v2.0/health` → `./lab.sh start` (k3s) → power on `runner` |
| **Stop** | power off `runner` → `./lab.sh stop` → `ssh john@harbor.lab.internal 'cd /opt/harbor && sudo docker compose down'` → power off `harbor` |
| **Low-memory mode** | keep `harbor` + k3s up, **suspend** `runner` (resumes in seconds; the GitHub runner reconnects on its own, queued jobs wait) |
| **Cluster rebuild** | `./lab.sh destroy && ./lab.sh up`, then docs/02 §3 (five commands). Harbor keeps every image |

Harbor's containers are `restart: always`, so after a VM reboot it is back in ~60 s without `compose up`.
The actions-runner is a systemd service — same.

Quick health check from the Mac: `./scripts/verify.sh`.

## 2. Day-2 on Harbor

| Task | How |
|---|---|
| Garbage collection (reclaims deleted blobs) | UI → Administration → Clean Up → Garbage Collection → schedule **weekly**, "delete untagged artifacts" on |
| Tag retention (keep last N per repo) | Project → Policy → Tag Retention: `retain the most recently pushed 10 artifacts` + `retain always :latest` |
| Trivy DB freshness | automatic on scan; UI → Interrogation Services → Scanners shows last update. Air-gapped note in docs/03 §7 |
| Proxy-cache growth | project `dockerhub` → Configuration → *Proxy cache*: set a 7-day cache TTL for untagged blobs |
| Disk | `ssh harbor 'df -h /data; sudo du -sh /data/*'` — registry blobs dominate; 60 GB fits months of lab churn with weekly GC |
| Logs | `/var/log/harbor/*.log` (rotated 50×200 MB per `harbor.yml`) |
| Admin password reset | `harbor.yml` only sets it on first install; afterwards change it in the UI (then update `secrets/harbor-admin.pw`) |

## 3. Backup / restore (Harbor)

Everything is `/data` + `/opt/harbor/harbor.yml`. Postgres must be stopped (or dumped) for a consistent copy:

```bash
# backup — on the Harbor VM
cd /opt/harbor && sudo docker compose down
sudo tar -C / -czf "/home/john/harbor-backup-$(date +%F).tgz" data opt/harbor/harbor.yml
sudo docker compose up -d
scp john@harbor.lab.internal:harbor-backup-*.tgz ~/Backups/kubernetes-lab/     # from the Mac

# restore — on a rebuilt VM after 10-bootstrap-vm.sh
sudo tar -C / -xzf harbor-backup-YYYY-MM-DD.tgz
~/lab/harbor/30-install-harbor.sh      # same HARBOR_VERSION; it finds /data and harbor.yml and just brings it up
```

Alternative without downtime: `sudo docker compose exec postgresql pg_dumpall -U postgres > db.sql` plus an rsync of
`/data/registry`; restore is more fiddly, so the stop-and-tar approach is the lab default. Snapshotting the VM in Fusion
(*powered off*) is the easiest of all and is fine here.

## 4. Upgrading Harbor (e.g. 2.16.0-rc1 → 2.16.0 GA)

1. Backup (§3). Note current version: `curl -s https://harbor.lab.internal/api/v2.0/systeminfo | jq .harbor_version`.
2. On the Mac: set `HARBOR_VERSION="v2.16.0"` in `lab-env.sh`; `./harbor/00-push-to-vm.sh`.
3. On the VM: `cd /opt/harbor && sudo docker compose down`; `sudo mv /opt/harbor /opt/harbor-$(date +%F)`; then
   `~/lab/harbor/30-install-harbor.sh` — it downloads the new tarball, re-renders `harbor.yml` from the *new*
   template, and runs `install.sh` against the existing `/data`. Harbor migrates the DB schema on first start.
4. Within the same minor (2.16.x) that is the whole procedure. Across minors, Harbor documents a `migrate` step
   with the `goharbor/prepare:<ver>` image; check the release notes before moving to 2.17.

## 5. Upgrading K3s

`lab.sh` pins the channel; the k3s install script with `INSTALL_K3S_CHANNEL=v1.34` updates patch versions in place
(`curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=v1.34 sh -` on the server, then each agent). Keep the minor equal to
work VKS. Re-run `k3s/10-trust-harbor-ca.sh` afterwards — it's idempotent and confirms `registries.yaml` survived.

## 6. Secrets inventory (`secrets/`, git-ignored)

| File | Used by | Rotate with |
|---|---|---|
| `certs/ca.key` `ca.crt` | everything | docs/04 §5 (CA replacement — rare) |
| `certs/harbor.{key,crt,cert}` | Harbor nginx | `harbor/20-gen-certs.sh --renew` + `00-push` + `30-install` |
| `harbor-admin.pw` `harbor-db.pw` | Harbor | UI for admin; DB password only via reinstall |
| `harbor-robot-gha-push.{user,token}` | GitHub secrets | `harbor/40-init-harbor.sh --rotate-robots` + `gh secret set` |
| `harbor-robot-k3s-pull.{user,token}` | `registries.yaml`, `harbor-pull` secrets | `--rotate-robots` + `k3s/10-…` + `k3s/50-…` |
| `kubeconfig-gha-deployer.yaml` | runner VM | `kubectl -n containerhelper delete secret gha-deployer-token && kubectl apply -f k3s/30-deployer-rbac.yaml && ./k3s/40-make-kubeconfig.sh`, re-copy |

Back the folder up somewhere encrypted (it is inside iCloud already; that is fine for a lab, not for work).

## 7. Weekly maintenance cron (runner VM)

```bash
# /etc/cron.weekly/lab-runner-prune  (chmod +x)
#!/bin/sh
docker builder prune -af --filter until=168h >/dev/null
docker image prune -af --filter until=336h >/dev/null
find /home/runner/actions-runner-*/_diag -name '*.log' -mtime +14 -delete
```
