# 02 — Cluster: reusing `k3s-lab`

The cluster already exists: `~/Virtual Machines.localized/k3s-lab` — 1 server + 2 agents, Ubuntu 24.04 ARM64,
K3s pinned to **v1.34** (same minor as work VKS), default add-ons (Traefik, CoreDNS, local-path, metrics-server).
This doc covers what the lab adds to it; `lab.sh` remains the way you start/stop/destroy it.

## 1. Bring it up and point this lab at it

```bash
cd ~/Virtual\ Machines.localized/k3s-lab
./lab.sh up && ./lab.sh status          # note the node IPs → K3S_SERVER_IP / K3S_AGENT_IPS in lab-env.sh
kubectl config use-context k3s-lab      # or whatever context lab.sh created; `kubectl config get-contexts`
kubectl get nodes -o wide
```

If `lab.sh` hands out DHCP addresses rather than fixed ones, give the three VMs reservations the same way as
the Harbor VM (docs/03 §2) — `registries.yaml`, the runner's kubeconfig and `/etc/hosts` all assume stable IPs.

## 2. k9s

```bash
brew install derailed/k9s/k9s           # v0.51.x
k9s --context k3s-lab
```

Useful in this lab: `:ns` → pick `containerhelper`; `:deploy`; `l` logs; `s` shell; `:events`; `:pulse` overview.
Set `k9s` to open in the solution namespaces by default: `~/Library/Application Support/k9s/config.yaml` →
`k9s.clusters.k3s-lab.namespace.favorites: [containerhelper, devopshelpers, lab-sandbox]`.
The runner VM gets k9s too (`runner/10-prep-runner-vm.sh`), handy when you SSH in to debug a failed job.

## 3. What the lab adds to the cluster

| Step | File | Effect |
|---|---|---|
| CA + registry auth on nodes | `k3s/10-trust-harbor-ca.sh` | `/etc/rancher/k3s/registries.yaml` on all nodes: Harbor creds (`robot$k3s-pull`), lab CA, and `docker.io` **mirrored through the Harbor proxy cache**; restarts `k3s` / `k3s-agent` |
| Namespaces | `k3s/20-namespaces.yaml` | `containerhelper`, `devopshelpers` with **PSA `restricted` enforced**; `lab-sandbox` at `baseline` for toolbox experiments |
| Deployer identity | `k3s/30-deployer-rbac.yaml` | SA `gha-deployer` + namespaced `deployer` Role in both namespaces; read-only nodes/namespaces cluster-wide |
| Runner kubeconfig | `k3s/40-make-kubeconfig.sh` | `secrets/kubeconfig-gha-deployer.yaml` with a long-lived SA token, API server = `https://<K3S_SERVER_IP>:6443` |
| Pull secret | `k3s/50-pull-secrets.sh` | `harbor-pull` docker-registry Secret in each namespace, attached to the `default` SA |

```bash
./k3s/10-trust-harbor-ca.sh
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

| VM | vCPU | RAM | Notes |
|---|---|---|---|
| k3s-server | 2 | 4 GB | control plane + Traefik; schedulable |
| k3s-agent-1/2 | 2 | 4 GB each | app workloads |
| harbor | 2 | 4 GB | |
| runner | 2 | 4 GB | docker buildx + .NET SDK builds want this |
| **total** | 10 | **20 GB** of 24 GB |

Options when it's too much: drop agents to 3 GB each (edit the `.vmx` `memsize` while powered off), or suspend
the runner VM between builds. The Harbor VM has to stay up while the cluster is pulling.

## 6. Destroy / recreate the cluster without losing anything

Because Harbor and the runner live outside the cluster, `./lab.sh destroy && ./lab.sh up` followed by
section 3 above gets you back to a working pipeline in ~10 minutes. The `secrets/` folder has everything;
only `k3s/40-make-kubeconfig.sh` needs re-running (new cluster CA + token) and the result re-copied to the runner.
