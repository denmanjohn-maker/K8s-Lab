# 08 — Troubleshooting

Work top-down: Docker Desktop → name resolution → TLS → auth → the component itself. `./scripts/verify.sh` runs
the first layers for every path (Mac→Harbor, node→Harbor, runner→Harbor, runner→API server) and prints the first
failure.

## 1. Harbor

| Symptom | Cause → fix |
|---|---|
| `install.sh`: `Mounts denied` / `path … is not shared from the host` | `HARBOR_HOME` outside Docker Desktop's file sharing. Default `~/Lab/harbor` is under `/Users` (shared); otherwise add it under Settings → Resources → File sharing. `/var/log` is never shared — the script already moves logs under `HARBOR_HOME` |
| `registry` won't start: `create mountpoint for /etc/registry/root.crt … is outside of rootfs` | Docker Desktop's nested-bind-mount bug (docker/for-mac#7853): the mountpoint file must exist on the host before the first `up`. `30-install-harbor.sh` touches `harbor/common/config/registry/root.crt` after every `prepare`; if you ran Harbor's own `install.sh` or `prepare` by hand, touch it and `docker compose up -d` again |
| `install.sh` fails: `exec format error` / images won't start | amd64-only Harbor. `HARBOR_VERSION` must be `v2.16.0-rc1` or later and `HARBOR_ARCH=arm64` (docs/03). Check: `docker image inspect goharbor/harbor-core:<ver> --format '{{.Architecture}}'` |
| `bind: address already in use` on 443/80 | something else on the Mac owns the port (`sudo lsof -iTCP:443 -sTCP:LISTEN`) — Traefik is on 8080/8443 for that reason; a previous Harbor still running: `docker compose --project-directory ~/Lab/harbor/harbor ps` |
| a container exits with `failed to initialize logging driver: dial tcp 127.0.0.1:1514` | the `log` container isn't up yet or the syslog-on-localhost pattern failed on this Docker Desktop version. `docker compose … up -d` again; if it persists, uncomment the `json-file` fallback in `harbor/docker-compose.override.yml.template` and re-run `30-install-harbor.sh` |
| `prepare` complains about `_version` or unknown keys | `harbor.yml` from an older template. `30-install-harbor.sh` re-renders from the tarball's own template — re-run it |
| `docker compose down` → `network harbor_harbor has active endpoints` | the k3d nodes / runners are attached. Use `stop`, or `./lab.sh stop` first |
| UI loads but `docker login` → `401 Unauthorized` | robot secret wrong or robot disabled/expired. Robots created by `40-init` never expire (`duration:-1`); re-issue with `--rotate-robots` |
| `docker push` → `unauthorized: project not found` / `denied` | image path must be `harbor.lab.internal/<project>/<repo>`. Project missing → `40-init-harbor.sh`; robot lacks push on that project → check robot permissions in UI |
| `x509: certificate signed by unknown authority` from **docker** on the Mac or in a job | Docker Desktop's engine doesn't have the CA: keychain step + **restart Docker Desktop** (docs/04 §3) |
| `x509: certificate is valid for harbor.lab.internal, not …` | you used a name not in the SANs (`20-gen-certs.sh` lists them). Use the hostname |
| Scan stuck in *Pending* / `scan-gate` times out | Trivy can't reach `ghcr.io` for its DB: `docker compose … logs trivy-adapter`. First scan after install downloads ~60 MB; wait. Air-gapped → `skip_update`/`offline_scan` |
| `proxy cache` pull → `manifest unknown` | official images need `library/`: `dockerhub/library/alpine`, not `dockerhub/alpine`. Private Hub repos need Hub creds on the registry endpoint |
| Containers restart-looping after a reboot | `data/` permission or disk full: `df -h ~/Lab`, `docker compose … logs core database`. GC + retention (docs/07 §2) |
| Changed `harbor.yml`, nothing happened | config only applies via `prepare` + `compose stop/up` — re-run `30-install-harbor.sh` |
| Slow pushes/pulls | bind-mount performance: Settings → General → file sharing implementation **VirtioFS**; exclude `~/Lab/harbor/data` from Spotlight and antivirus |

Diagnostics: `docker compose --project-directory ~/Lab/harbor/harbor ps` · `… logs -f core registry jobservice` ·
`curl -s --cacert secrets/certs/ca.crt https://harbor.lab.internal/api/v2.0/health | jq`.

## 2. k3d nodes pulling from Harbor

| Symptom | Cause → fix |
|---|---|
| `ImagePullBackOff` — `failed to resolve reference … x509` | `ca_file` path in `secrets/registries.yaml` doesn't match the mount, or K3s hasn't regenerated `hosts.toml`: `./k3s/10-render-registries.sh` (restarts the cluster); then `docker exec k3d-k3s-lab-agent-0 cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/harbor.lab.internal/hosts.toml` |
| `… 401 Unauthorized` on pull | `registries.yaml` creds stale (robot rotated). `k3s/10-render-registries.sh` + `k3s/50-pull-secrets.sh` |
| `… dial tcp: lookup harbor.lab.internal` | the alias is missing on nginx (`docker inspect nginx --format '{{json .NetworkSettings.Networks}}'`) — re-run `30-install-harbor.sh`; or the nodes are not on `harbor_harbor` (`docker inspect k3d-k3s-lab-server-0 --format '{{json .NetworkSettings.Networks}}'`) — re-create the cluster. CoreDNS is irrelevant here; **containerd uses the node's resolver**, which is Docker's embedded DNS |
| `… connect: connection refused` to Harbor from a node | Harbor stopped (`./lab.sh status`). Start order: Harbor before the cluster |
| docker.io images suddenly slow/failing | `docker.io` mirror points at Harbor and Harbor is down. containerd falls back to Hub after timeouts; start Harbor or re-render with `--no-dockerhub-mirror` |
| Pod rejected: `violates PodSecurity "restricted:latest"` | the manifest lacks `runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]` — docs/02 §4. Use `lab-sandbox` for experiments that genuinely need more |
| `kubectl debug --target` ephemeral container rejected | same PSA rule applies to ephemeral containers; pass `--profile=restricted` (kubectl ≥1.30) or use `lab-sandbox` |
| Node `NotReady` after `10-render-registries.sh` | malformed `registries.yaml` → k3s won't start: `docker logs k3d-k3s-lab-server-0 --tail 50`; `yq secrets/registries.yaml`. Fix the template, re-run |
| `k3d cluster create` → `network harbor_harbor not found` | Harbor not installed/started yet (docs/03 §3) |
| `kubectl`: `connection refused` to `127.0.0.1:6443` after a Mac reboot | nodes still starting; `k3d cluster list` / `./lab.sh up`. If the serverlb is unhealthy: `k3d cluster stop k3s-lab && k3d cluster start k3s-lab` |

Test from a node without Kubernetes in the way:
`docker exec k3d-k3s-lab-server-0 k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20` and
`… k3s crictl pull harbor.lab.internal/containerhelper/toolbox:latest`.

## 3. Runners

| Symptom | Cause → fix |
|---|---|
| Job queued forever, runner *Idle* | label mismatch: workflow `runs-on: [self-hosted, k3s-lab]` vs `RUNNER_LABELS` in `lab-env.sh`. Repo-scoped runner on repo A can't serve repo B |
| Runner *Offline* | container stopped (`docker compose -f runner/docker-compose.yml ps`); Docker Desktop paused/Resource Saver; outbound 443 blocked. `docker logs runner-containerhelper` |
| container exits with `no registration token` | first start without `secrets/runner-token-<repo>` content (docs/05 §4). Tokens expire after 1 h — fetch a fresh one |
| `config.sh`: `Http response code: NotFound` / `Invalid configuration` | token expired or wrong `RUNNER_URL` scope (repo URL for repo-level, org URL for org-level) |
| runner registered but GitHub shows it removed | `.runner` exists in the volume while GitHub forgot the runner. `docker compose -f runner/docker-compose.yml down -v`, new token, `up -d` |
| `permission denied … docker.sock` | `group_add: ["0"]` missing, or your Docker Desktop version mounts the socket with another gid: `docker exec runner-containerhelper stat -c '%U:%G %a' /var/run/docker.sock` and put that gid in `group_add` |
| `kubectl`: `error loading config file … permission denied` | Docker Desktop normally maps bind-mounted files so any container user can read them; if your file-sharing setting preserves mode bits, the `0600` kubeconfig is unreadable for uid 1001: `chmod 644 secrets/kubeconfig-gha-deployer.yaml` (the token inside is namespaced and revocable) and restart the runners |
| `kubectl`: `Unauthorized` | SA token Secret recreated (cluster rebuilt) → `k3s/40-make-kubeconfig.sh`, restart runners |
| `kubectl`: `forbidden: cannot create resource "X"` | add the resource/verb to **both** Role copies in `k3s/30-deployer-rbac.yaml`, re-apply |
| `kubectl`: `x509` to API server | cluster rebuilt → new cluster CA → `40-make-kubeconfig.sh` again |
| `kubectl`: `dial tcp: lookup k3d-k3s-lab-server-0` | runner not on `harbor_harbor` (compose network) or cluster deleted. `docker inspect runner-containerhelper --format '{{json .NetworkSettings.Networks}}'` |
| buildx `failed to solve: … x509` pushing to Harbor | `docker-container` driver without the buildkitd CA config — docs/04 §2; or simply use `driver: docker` (the workflows do) |
| Disk full | `docker system df`; `./lab.sh prune`; `_work/` of old repos inside the volume |

## 4. Networking / Docker Desktop

| Symptom | Cause → fix |
|---|---|
| `docker: Cannot connect to the Docker daemon` | Docker Desktop not running / still starting. Everything waits on it |
| `curl https://harbor.lab.internal` from the Mac → `Could not resolve host` | `/etc/hosts` line missing: `./scripts/hosts-entry.sh --apply` |
| Mac resolves the name but `docker push` can't: `dial tcp … connect: connection refused` | the engine resolved `harbor.lab.internal` through the Mac's hosts file to `127.0.0.1`, and Harbor's 443 isn't published (Harbor stopped) or the publish failed (port conflict, §1) |
| containers can't reach the internet after a VPN change | Docker Desktop's VM lost its route: Docker menu → Restart |
| everything slow / swapping | Docker Desktop VM memory too low for Harbor + 3 nodes + a build: Settings → Resources → 12 GB; stop the runners while not building (docs/07 §1) |
| `.local` names resolve to the wrong thing | you used `.local` — macOS mDNS owns that. The lab uses `lab.internal` for this reason |
| after a Docker Desktop upgrade: `harbor_harbor` missing, nodes fail to start | networks are recreated by compose: `docker compose --project-directory ~/Lab/harbor/harbor up -d` first, then `k3d cluster start k3s-lab`; `./lab.sh up` does this in order |

## 5. Collecting a bundle for yourself

```bash
./scripts/verify.sh                                                     # Mac-side summary
docker compose --project-directory ~/Lab/harbor/harbor ps > /tmp/harbor.txt
docker compose --project-directory ~/Lab/harbor/harbor logs --tail=100 core registry >> /tmp/harbor.txt
docker logs k3d-k3s-lab-server-0 --tail 200 > /tmp/k3s.txt 2>&1
docker exec k3d-k3s-lab-server-0 cat /etc/rancher/k3s/registries.yaml | sed 's/password:.*/password: ***/' >> /tmp/k3s.txt
kubectl --context k3d-k3s-lab get events -A --sort-by=.lastTimestamp | tail -40
docker logs runner-containerhelper --tail 100 > /tmp/runner.txt 2>&1
```
