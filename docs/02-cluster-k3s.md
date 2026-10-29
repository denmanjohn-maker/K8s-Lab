# 02 — Cluster: `k3s-lab` on k3d

The cluster is k3d: 1 server + 2 agents, each a container running `rancher/k3s:v1.34.x` (pinned in `lab-env.sh`,
same minor as work VKS), default add-ons (Traefik, CoreDNS, local-path, metrics-server). It is declared in
`k3s/k3d-config.yaml.template`, created by `lab.sh create-cluster`, and disposable: Harbor lives outside it.

## 1. Create it and point this lab at it

Harbor must be installed and running first (docs/03) — the nodes join Harbor's docker network and mount the
registries file, so `create-cluster` refuses to run without `harbor_harbor` and `secrets/registries.yaml`.
`./install.sh` runs this section and §3 as its `cluster` stage; by hand:

```bash
cd "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab"
source lab-env.sh
./k3s/10-render-registries.sh            # secrets/registries.yaml: Harbor auth + CA, docker.io → proxy cache
./lab.sh create-cluster                  # ~90 s; writes context k3d-k3s-lab into ~/.kube/config and switches to it
kubectl get nodes -o wide
```

What the template sets, and why:

| Key | Value | Why |
|---|---|---|
| `image` | `$K3S_IMAGE` (`rancher/k3s:v1.34.12-k3s1`) | k3d's own default is newer than VKS; always pin |
| `network` | `harbor_harbor` | nodes resolve `harbor.lab.internal` to Harbor's nginx; runners resolve the server node |
| `kubeAPI` | `127.0.0.1:6443` | `kubectl` on the Mac; not exposed on the LAN |
| `ports` | `8080:80`, `8443:443` on the load balancer | Traefik; Harbor owns 80/443 on the Mac |
| `volumes` | `secrets/certs/ca.crt` → `/etc/ssl/certs/kubernetes-lab-ca.crt`, `secrets/registries.yaml` → `/etc/rancher/k3s/registries.yaml` on every node | the same files a real node would carry (docs/04 §1) |
| `--tls-san=k3d-k3s-lab-server-0` | server nodes | the runners' kubeconfig uses that name |
| `runtime.serversMemory/agentsMemory` | 1.5 g / 1 g | soft caps so one runaway pod cannot starve Harbor |

## 2. k9s

```bash
brew install derailed/k9s/k9s           # v0.51.x
k9s --context k3d-k3s-lab
```

Useful in this lab: `:ns` → pick `containerhelper`; `:deploy`; `l` logs; `s` shell; `:events`; `:pulse` overview.
Set `k9s` to open in the solution namespaces by default: `~/Library/Application Support/k9s/config.yaml` →
`k9s.clusters.k3d-k3s-lab.namespace.favorites: [containerhelper, devopshelpers, lab-sandbox]`.
The runner image has k9s too (`docker exec -it runner-containerhelper k9s`), handy when debugging a failed job.

## 3. What the lab adds to the cluster

| Step | File | Effect |
|---|---|---|
| CA + registry auth on nodes | `k3s/10-render-registries.sh` + the mounts in `k3d-config.yaml.template` | `/etc/rancher/k3s/registries.yaml` on all nodes: Harbor creds (`robot$k3s-pull`), lab CA, and `docker.io` **mirrored through the Harbor proxy cache**. Re-running after a robot rotation restarts the cluster so K3s regenerates `hosts.toml` |
| Namespaces | `k3s/20-namespaces.yaml` | `containerhelper`, `devopshelpers` with **PSA `restricted` enforced**; `lab-sandbox` at `baseline` for toolbox experiments |
| Deployer identity | `k3s/30-deployer-rbac.yaml` | SA `gha-deployer` + namespaced `deployer` Role in both namespaces; read-only nodes/namespaces cluster-wide |
| Runner kubeconfig | `k3s/40-make-kubeconfig.sh` | `secrets/kubeconfig-gha-deployer.yaml` with a long-lived SA token, API server = `https://k3d-k3s-lab-server-0:6443` (resolvable from the runner containers) |
| Pull secret | `k3s/50-pull-secrets.sh` | `harbor-pull` docker-registry Secret in each namespace, attached to the `default` SA |

```bash
kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml
./k3s/50-pull-secrets.sh
./k3s/40-make-kubeconfig.sh
```

## 4. PSA `restricted` — what your manifests must have

Work VKS enforces this cluster-wide; the lab enforces it on the two solution namespaces so CI fails here first.
Every Pod/Deployment template needs:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        # runAsUser: 10001        # only if the image doesn't declare a non-root USER
```

Images must run as non-root — for the .NET images that means `USER app` (the `app` user shipped in the
`mcr.microsoft.com/dotnet/aspnet:*` images) and listening on 8080, not 80. `kubectl debug --target` with the
toolbox image works under `restricted` as long as the ephemeral container also carries the securityContext
above (the `lab-sandbox` namespace is there for when it doesn't).

## 5. Resource budget

| Component | RAM (steady) | Notes |
|---|---|---|
| Harbor (10 containers, Trivy idle) | ~2.5 GB | a Trivy scan adds ~1 GB while it runs |
| `k3d-k3s-lab-server-0` | ≤ 1.5 GB | control plane + Traefik; schedulable |
| `k3d-k3s-lab-agent-0/1` | ≤ 1 GB each | app workloads |
| two runners idle | ~0.3 GB | a .NET build inside a job adds 2–3 GB while it runs |
| **Docker Desktop VM** | **12 GB** (6 CPU) | Settings → Resources. 10 GB works if you run one build at a time |

Change node caps in `lab-env.sh` (`K3D_SERVER_MEMORY`, `K3D_AGENT_MEMORY`) and re-create the cluster.

## 6. Working on a node

Everything on a node goes through `docker exec`:

```bash
./lab.sh shell                                           # sh on k3d-k3s-lab-server-0
./lab.sh shell k3d-k3s-lab-agent-1
docker exec k3d-k3s-lab-agent-0 cat /etc/rancher/k3s/registries.yaml
docker exec k3d-k3s-lab-server-0 k3s crictl pull harbor.lab.internal/dockerhub/library/alpine:3.20
docker logs k3d-k3s-lab-server-0 --tail 100              # journalctl -u k3s equivalent
k3d node stop k3d-k3s-lab-agent-1 && k3d node start k3d-k3s-lab-agent-1   # simulate a node outage
```

## 7. Destroy / recreate the cluster without losing anything

Because Harbor and the runners live outside the cluster, `./lab.sh destroy-cluster && ./lab.sh create-cluster`
followed by section 3 above gets you back to a working pipeline in ~3 minutes. The `secrets/` folder has
everything; only `k3s/40-make-kubeconfig.sh` needs re-running (new cluster CA + token), then
`docker compose -f runner/docker-compose.yml restart` so the runners pick up the new file.
