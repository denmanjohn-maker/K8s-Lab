# 04 — Trusting the lab CA (k3d nodes, Docker Desktop, runners, Mac)

One private CA (`secrets/certs/ca.crt`) signs Harbor's certificate. Four consumers must trust it, each in its
own way — the same four kinds you deal with at work against the corporate CA.

| Consumer | Where the CA goes | Why that place |
|---|---|---|
| **k3d nodes (containerd)** | `/etc/rancher/k3s/registries.yaml` → `configs.<host>.tls.ca_file` = `/etc/ssl/certs/kubernetes-lab-ca.crt` (both files bind-mounted by k3d) | containerd does **not** read the OS trust store; k3s generates `hosts.toml` from this file |
| **Docker Desktop's engine** (every `docker push/pull`, from the Mac and from CI jobs) | macOS **System keychain**, trustRoot; Docker Desktop rebuilds its engine's CA bundle from the keychain at start-up | the engine runs in Docker Desktop's VM and has no `/etc/docker/certs.d` you maintain; the keychain is the supported path |
| **Runner image** (curl to the Harbor API in `scan-gate`, trivy, kubectl) | `/usr/local/share/ca-certificates/` + `update-ca-certificates`, baked in by `runner/Dockerfile` | jobs call the API directly over the docker network |
| **Mac** (Safari, curl, `40-init-harbor.sh`) | the same keychain entry | UI without warnings; scripts also pass `--cacert` |

## 1. k3d nodes — `k3s/10-render-registries.sh`

Renders `k3s/registries.yaml.template` to `secrets/registries.yaml`; `k3s/k3d-config.yaml.template` bind-mounts
it and `ca.crt` into every node at create time. The rendered file looks like:

```yaml
mirrors:
  "harbor.lab.internal":
    endpoint: ["https://harbor.lab.internal"]
  "docker.io":                       # every docker.io pull goes through the Harbor proxy cache
    endpoint: ["https://harbor.lab.internal"]
    rewrite:
      "^(.*)$": "dockerhub/$1"       # docker.io/library/alpine -> harbor.lab.internal/dockerhub/library/alpine
configs:
  "harbor.lab.internal":
    auth: { username: "robot$k3s-pull", password: "…" }
    tls:  { ca_file: /etc/ssl/certs/kubernetes-lab-ca.crt }
```

Consequences worth knowing:

- Pods can reference `harbor.lab.internal/containerhelper/app:sha` with **no imagePullSecret** — the node
  authenticates. The `harbor-pull` secret (`k3s/50-pull-secrets.sh`) exists for manifest portability to VKS.
- With the `docker.io` mirror, `image: nginx:1.27` is pulled from Harbor's cache (public project, no auth), cached
  on first pull, and shows up under Projects → dockerhub. If Harbor is down, containerd falls back to Docker Hub
  directly after the mirror fails (slower pulls, not broken pulls). Disable with `--no-dockerhub-mirror`.
- Inside the nodes `harbor.lab.internal` resolves through Docker's DNS to the `nginx` container (alias), not through
  `/etc/hosts`; the certificate's SAN covers that name, so the same CA check applies.
- Re-rendering after a robot rotation updates the mounted file in place; the script then restarts the cluster
  (`k3d cluster stop/start`) so K3s regenerates `hosts.toml`.
- Verify on a node: `docker exec k3d-k3s-lab-agent-0 cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/harbor.lab.internal/hosts.toml`
  and `docker exec k3d-k3s-lab-server-0 k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20`.

## 2. Runner image — `runner/Dockerfile`

```dockerfile
COPY --from=certs ca.crt /usr/local/share/ca-certificates/kubernetes-lab-ca.crt
RUN update-ca-certificates
```

`certs` is the extra build context `runner/docker-compose.yml` points at `secrets/certs`. The `docker` CLI in the
runner talks to Docker Desktop's engine over the mounted socket, so **pushes use the engine's trust (§3), not the
image's**. `buildx` with the default `docker` driver (what the workflows use) inherits that. If you switch to the
`docker-container` driver (multi-platform manifests in one build), the builder runs as its own container and needs
the CA explicitly:

```toml
# buildkitd.toml (mount it into the runner or bake it into the image)
[registry."harbor.lab.internal"]
  ca = ["/usr/local/share/ca-certificates/kubernetes-lab-ca.crt"]
```
```bash
docker buildx create --name lab --driver docker-container --config buildkitd.toml --use
```

## 3. Mac keychain = Docker Desktop

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/certs/ca.crt
docker desktop restart              # or Docker menu → Restart (install.sh does this for you)
docker pull harbor.lab.internal/dockerhub/library/alpine:3.20     # proves it
```

Docker Desktop's Linux VM reads the macOS keychain for registry TLS; it only re-reads it on restart, so the
restart is part of the step. If `docker pull` still reports `x509: certificate signed by unknown authority`, the
per-user fallback is `mkdir -p ~/.docker/certs.d/harbor.lab.internal && cp secrets/certs/ca.crt
~/.docker/certs.d/harbor.lab.internal/ca.crt` followed by another restart.

## 4. Rotation

- **Server cert expired/renewed** → `harbor/20-gen-certs.sh --renew`, re-run `harbor/30-install-harbor.sh`. Nothing
  else changes (CA is the same).
- **CA replaced** (new `ca.key`) → all four consumers again: `k3s/10-render-registries.sh` (the mount already points at
  the new file; the restart reloads it), `docker compose -f runner/docker-compose.yml build` + `up -d`, keychain
  (`sudo security delete-certificate -c "Kubernetes Lab CA" /Library/Keychains/System.keychain` first), Docker Desktop
  restart.
- **Robot secret rotated** → `harbor/40-init-harbor.sh --rotate-robots`, then `k3s/10-render-registries.sh`,
  `k3s/50-pull-secrets.sh`, and the two GitHub repo secrets.
