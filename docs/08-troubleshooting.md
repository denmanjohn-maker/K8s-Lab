# 08 — Troubleshooting

Work top-down: name resolution → TLS → auth → the component itself. `./scripts/verify.sh` runs the first three
layers for every path (Mac→Harbor, node→Harbor, runner→Harbor, runner→API server) and prints the first failure.

## 1. Harbor

| Symptom | Cause → fix |
|---|---|
| `install.sh` fails: `exec format error` / images won't start | amd64-only Harbor on the arm64 VM. `HARBOR_VERSION` must be `v2.16.0-rc1` or later and `HARBOR_ARCH=arm64` (docs/03). Check: `docker image inspect goharbor/harbor-core:<ver> --format '{{.Architecture}}'` |
| `prepare` complains about `_version` or unknown keys | `harbor.yml` from an older template. `30-install-harbor.sh` re-renders from the tarball's own template — re-run it |
| UI loads but `docker login` → `401 Unauthorized` | robot secret wrong or robot disabled/expired. Robots created by `40-init` never expire (`duration:-1`); re-issue with `--rotate-robots` |
| `docker push` → `unauthorized: project not found` / `denied` | image path must be `harbor.lab.internal/<project>/<repo>`. Project missing → `40-init-harbor.sh`; robot lacks push on that project → check robot permissions in UI |
| `x509: certificate signed by unknown authority` | consumer doesn't trust the lab CA — docs/04 table. On the Harbor VM itself: `/etc/docker/certs.d/harbor.lab.internal/ca.crt` present? |
| `x509: certificate is valid for harbor.lab.internal, not 192.168.x.y` | you pulled by IP; SAN includes the IP in `HARBOR_IP` only. Use the hostname, or `20-gen-certs.sh --renew` after fixing `HARBOR_IP` |
| Scan stuck in *Pending* / `scan-gate` times out | Trivy can't reach `ghcr.io` for its DB: `sudo docker compose logs trivy-adapter`. First scan after install downloads ~60 MB; wait. Air-gapped → `skip_update`/`offline_scan` |
| `proxy cache` pull → `manifest unknown` | official images need `library/`: `dockerhub/library/alpine`, not `dockerhub/alpine`. Private Hub repos need Hub creds on the registry endpoint |
| Containers restart-looping after reboot | `/data` permission or disk full: `df -h /data`, `sudo docker compose logs core database`. GC + retention (docs/07 §2) |
| Changed `harbor.yml`, nothing happened | config only applies via `prepare` + `compose down/up` — re-run `30-install-harbor.sh` |

Diagnostics: `cd /opt/harbor && sudo docker compose ps` · `sudo docker compose logs -f core registry jobservice` ·
`curl -sk https://localhost/api/v2.0/health | jq` (`-k` only on the VM itself).

## 2. k3s pulling from Harbor

| Symptom | Cause → fix |
|---|---|
| `ImagePullBackOff` — `failed to resolve reference … x509` | CA not in `registries.yaml` on **that** node, or k3s not restarted. `k3s/10-trust-harbor-ca.sh` again; then on the node `sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/harbor.lab.internal/hosts.toml` |
| `… 401 Unauthorized` on pull | `registries.yaml` creds stale (robot rotated). `k3s/10-…` + `k3s/50-pull-secrets.sh` |
| `… dial tcp: lookup harbor.lab.internal` | node can't resolve the name: `/etc/hosts` missing → `scripts/hosts-entries.sh --push`. CoreDNS is irrelevant here; **containerd uses the node's resolver** |
| docker.io images suddenly slow/failing | `docker.io` mirror points at Harbor and Harbor is down. containerd falls back to Hub after timeouts; start Harbor or re-run `10-trust-harbor-ca.sh --no-dockerhub-mirror` |
| Pod rejected: `violates PodSecurity "restricted:latest"` | the manifest lacks `runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]` — docs/02 §4. Use `lab-sandbox` for experiments that genuinely need more |
| `kubectl debug --target` ephemeral container rejected | same PSA rule applies to ephemeral containers; pass `--profile=restricted` (kubectl ≥1.30) or use `lab-sandbox` |
| Node `NotReady` after `10-trust-harbor-ca.sh` | malformed `registries.yaml` → k3s won't start: `sudo journalctl -u k3s -n 50`; `sudo yq /etc/rancher/k3s/registries.yaml`. Fix the template, re-run |

Test from a node without Kubernetes in the way:
`sudo k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20` and `sudo k3s crictl pull harbor.lab.internal/containerhelper/toolbox:latest`.

## 3. Runner

| Symptom | Cause → fix |
|---|---|
| Job queued forever, runner *Idle* | label mismatch: workflow `runs-on: [self-hosted, k3s-lab]` vs runner labels (`./config.sh` `--labels`). Repo-scoped runner on repo A can't serve repo B |
| Runner *Offline* | `sudo ./svc.sh status`; VM suspended/asleep; outbound 443 blocked (ufw default allows outgoing). `_diag/Runner_*.log` |
| `permission denied … docker.sock` | `runner` user not in `docker` group, or service started before `usermod`: `sudo usermod -aG docker runner && sudo ./svc.sh stop && sudo ./svc.sh start` |
| `kubectl`: `error loading config file … permission denied` | `/etc/github-runner/kubeconfig` must be `root:runner 0640` and the service must run as `runner` |
| `kubectl`: `Unauthorized` | SA token Secret recreated (cluster rebuilt) → `k3s/40-make-kubeconfig.sh`, re-copy |
| `kubectl`: `forbidden: cannot create resource "X"` | add the resource/verb to **both** Role copies in `k3s/30-deployer-rbac.yaml`, re-apply |
| `kubectl`: `x509` to API server | cluster rebuilt → new cluster CA → `40-make-kubeconfig.sh` again |
| buildx `failed to solve: … x509` pushing to Harbor | using the `docker-container` driver without the buildkitd CA config — docs/04 §2; or simply use `driver: docker` |
| Disk full on runner | `docker system df`; `docker builder prune -af`; `_work/` of old repos |
| `config.sh`: `Http response code: NotFound` | registration token expired (1 h) or wrong `--url` scope (repo URL for repo-level, org URL for org-level) |

## 4. Networking / Fusion

| Symptom | Cause → fix |
|---|---|
| VM IP changed after reboot | no reservation — docs/03 §2; then `hosts-entries.sh --push`, `20-gen-certs.sh --renew` if `HARBOR_IP` changed |
| Mac can't reach VMs but VMs reach internet | VM on the wrong vmnet (bridged vs NAT). All lab VMs must be on *Share with my Mac*. `ifconfig vmnet8` on the Mac shows the host-side address |
| `ssh: Connection refused` right after boot | cloud-init still running; wait, or check `systemctl status ssh` on the console |
| Slow pulls / builds | 24 GB host with 20 GB of VMs: memory pressure → swap. Suspend the runner when not building; drop k3s agents to 3 GB |
| `.local` names resolve to the wrong thing | you used `.local` — macOS mDNS owns that. The lab uses `lab.internal` for this reason |

## 5. Collecting a bundle for yourself

```bash
./scripts/verify.sh                                 # Mac-side summary
ssh john@harbor.lab.internal 'cd /opt/harbor && sudo docker compose ps && sudo docker compose logs --tail=100 core registry' > /tmp/harbor.txt
ssh ubuntu@k3s-server 'sudo journalctl -u k3s -n 200 --no-pager; sudo cat /etc/rancher/k3s/registries.yaml | sed "s/password:.*/password: ***/"' > /tmp/k3s.txt
kubectl get events -A --sort-by=.lastTimestamp | tail -40
```
