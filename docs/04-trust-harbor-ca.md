# 04 — Trusting the lab CA (k3s, Docker, Mac)

One private CA (`secrets/certs/ca.crt`) signs Harbor's certificate. Four consumers must trust it, each in its
own way — the same four you deal with at work against the corporate CA.

| Consumer | Where the CA goes | Why that place |
|---|---|---|
| **k3s nodes (containerd)** | `/etc/rancher/k3s/registries.yaml` → `configs.<host>.tls.ca_file` | containerd does **not** read the OS trust store; k3s generates `hosts.toml` from this file |
| k3s nodes (OS: curl, apt) | `/usr/local/share/ca-certificates/*.crt` + `update-ca-certificates` | lets you `curl https://harbor…` on a node when debugging |
| **Docker daemon** (runner VM, Harbor VM, Mac) | `/etc/docker/certs.d/harbor.lab.internal/ca.crt` | dockerd has its own per-registry trust dir; OS store alone works on Linux after a restart, but this is explicit |
| **Mac** (Safari, curl, kubectl to Harbor API) | System keychain, trustRoot | UI without warnings; `harbor/40-init-harbor.sh` uses `--cacert` so this is optional |

## 1. k3s nodes — `k3s/10-trust-harbor-ca.sh`

Renders `k3s/registries.yaml.template` and installs it on all three nodes, restarting `k3s`/`k3s-agent` only when
the file changed. The rendered file looks like:

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
    tls:  { ca_file: /etc/rancher/k3s/kubernetes-lab-ca.crt }
```

Consequences worth knowing:

- Pods can reference `harbor.lab.internal/containerhelper/app:sha` with **no imagePullSecret** — the node
  authenticates. The `harbor-pull` secret (`k3s/50-pull-secrets.sh`) exists for manifest portability to VKS.
- With the `docker.io` mirror, `image: nginx:1.27` is pulled from Harbor's cache (public project, no auth), cached
  on first pull, and shows up under Projects → dockerhub. If Harbor is down, containerd falls back to Docker Hub
  directly after the mirror fails (slower pulls, not broken pulls). Disable with `--no-dockerhub-mirror`.
- Verify on a node: `sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/harbor.lab.internal/hosts.toml`
  and `sudo k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20`.

## 2. Runner VM — done by `runner/10-prep-runner-vm.sh`

```bash
sudo install -m 644 ca.crt /usr/local/share/ca-certificates/kubernetes-lab-ca.crt && sudo update-ca-certificates
sudo mkdir -p /etc/docker/certs.d/harbor.lab.internal && sudo cp ca.crt /etc/docker/certs.d/harbor.lab.internal/ca.crt
sudo systemctl restart docker
docker login harbor.lab.internal   # with robot$gha-push — workflows do this via docker/login-action
```

`buildx` with the default `docker` driver inherits the daemon's trust. If you switch to the `docker-container`
driver (needed for multi-platform manifests in one build), create the builder with a config that carries the CA:

```toml
# ~/.config/buildkit/buildkitd.toml
[registry."harbor.lab.internal"]
  ca = ["/etc/docker/certs.d/harbor.lab.internal/ca.crt"]
```
```bash
docker buildx create --name lab --driver docker-container --config ~/.config/buildkit/buildkitd.toml --use
```

## 3. Mac

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/certs/ca.crt
```

## 4. Docker Desktop on the Mac (only if you push from the Mac)

Docker Desktop's Linux VM reads the macOS keychain for registry TLS since 4.x, so the step above is usually enough
after *Restart* from the Docker menu. If `docker pull harbor.lab.internal/...` still shows `x509: certificate signed
by unknown authority`, add the cert via Settings → Docker Engine isn't the fix; instead
`mkdir -p ~/.docker/certs.d/harbor.lab.internal && cp secrets/certs/ca.crt ~/.docker/certs.d/harbor.lab.internal/ca.crt`
and restart Docker Desktop.

## 5. Rotation

- **Server cert expired/changed IP** → `harbor/20-gen-certs.sh --renew`, `harbor/00-push-to-vm.sh`, re-run
  `harbor/30-install-harbor.sh` on the VM. Nothing else changes (CA is the same).
- **CA replaced** (new `ca.key`) → all four consumers again: `k3s/10-trust-harbor-ca.sh`, `runner/10-prep-runner-vm.sh`,
  Mac keychain (`security delete-certificate -c "Kubernetes Lab CA"` first), and Docker Desktop.
- **Robot secret rotated** → `harbor/40-init-harbor.sh --rotate-robots`, then `k3s/10-trust-harbor-ca.sh`,
  `k3s/50-pull-secrets.sh`, and the two GitHub repo secrets.
