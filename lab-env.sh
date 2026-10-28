#!/usr/bin/env bash
# =============================================================================
# lab-env.sh — single source of truth for the Kubernetes Lab (Docker Desktop edition)
#
# Source this from every script and from your shell:
#     source "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab/lab-env.sh"
#
# Everything runs on the Mac inside Docker Desktop: Harbor is a compose stack, the
# cluster is k3d (K3s nodes as containers on Harbor's docker network), and the GitHub
# runners are containers. Edit the "EDIT ME" block; everything else is derived.
# Secrets are NOT stored here — they live in ./secrets/ (git-ignored).
# =============================================================================

# ---- EDIT ME ----------------------------------------------------------------
export LAB_DOMAIN="lab.internal"            # .internal is reserved for private use; avoid .local (mDNS clash on macOS)

# Resolves to 127.0.0.1 on the Mac (scripts/hosts-entry.sh) and to Harbor's nginx container
# inside Docker (network alias from harbor/docker-compose.override.yml.template).
export HARBOR_HOST="harbor.${LAB_DOMAIN}"

# Harbor install dir, registry data and logs. MUST be outside iCloud Drive (registry blobs must
# not sync) and inside Docker Desktop's file-sharing list (/Users is shared by default).
export HARBOR_HOME="${HARBOR_HOME:-$HOME/Lab/harbor}"
export HARBOR_HTTPS_PORT="443"              # Harbor owns 80/443 on the Mac …
export HARBOR_HTTP_PORT="80"

# k3d cluster: K3s nodes as containers, attached to Harbor's docker network.
export K3D_CLUSTER="k3s-lab"
export K3D_SERVERS=1
export K3D_AGENTS=2
export K3D_SERVER_MEMORY="1.5g"             # soft caps per node container (docs/02 §5)
export K3D_AGENT_MEMORY="1g"
export K8S_API_HOST_PORT="6443"             # API server published on 127.0.0.1 for kubectl on the Mac
export TRAEFIK_HTTP_PORT="8080"             # … so Traefik (the k3d load balancer) is published here instead
export TRAEFIK_HTTPS_PORT="8443"

# GitHub
export GH_OWNER="denmanjohn-maker"
export GH_REPOS=("ContainerHelperAdditions" "DevOpsHelperTools")
export RUNNER_LABEL="k3s-lab"               # custom label your workflows target with runs-on
export RUNNER_LABELS="${RUNNER_LABEL},harbor,arm64"
# -----------------------------------------------------------------------------

# ---- Versions (checked 2026-10-28) -------------------------------------------
# Harbor 2.16.0 is the first release with OFFICIAL multi-arch (amd64+arm64) images and an
# arm64 offline installer. Bump to "v2.16.0" when GA ships (docs/07 §4).
export HARBOR_VERSION="v2.16.0-rc1"
export HARBOR_ARCH="arm64"
export K3S_CHANNEL="v1.34"                  # pinned to match work VKS
export K3S_IMAGE="rancher/k3s:v1.34.12-k3s1" # k3d node image — always pin; k3d's own default is newer than VKS
export K3D_VERSION="5.9.0"                  # brew install k3d
export RUNNER_VERSION="2.338.2"             # ghcr.io/actions/actions-runner tag, base of runner/Dockerfile
export K9S_VERSION="v0.51.0"
# -----------------------------------------------------------------------------

# ---- Harbor layout -----------------------------------------------------------
# One project per repo + a Docker Hub proxy cache so the cluster never hits Hub
# rate limits. Robot accounts are least-privilege: GHA pushes, k3s pulls.
export HARBOR_PROJECTS=("containerhelper" "devopshelpers" "lab")
export HARBOR_PROXY_PROJECT="dockerhub"     # proxy-cache project -> pull as harbor.lab.internal/dockerhub/library/alpine
export HARBOR_ROBOT_PUSH="gha-push"         # becomes robot$gha-push
export HARBOR_ROBOT_PULL="k3s-pull"         # becomes robot$k3s-pull
# -----------------------------------------------------------------------------

# ---- Kubernetes layout --------------------------------------------------------
# Namespaces mirror work: PSA "restricted" enforced, one namespace per solution.
export K8S_NAMESPACES=("containerhelper" "devopshelpers")
export K8S_DEPLOYER_SA="gha-deployer"       # ServiceAccount the runners' kubeconfig uses
export K8S_PULL_SECRET="harbor-pull"        # imagePullSecret name in each namespace
# -----------------------------------------------------------------------------

# ---- Paths -----------------------------------------------------------------
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LAB_ROOT
export LAB_SECRETS="${LAB_ROOT}/secrets"   # git-ignored; CA key, robot tokens, kubeconfig, rendered configs
export LAB_CERTS="${LAB_SECRETS}/certs"
mkdir -p "${LAB_SECRETS}" "${LAB_CERTS}"
chmod 700 "${LAB_SECRETS}"

# ---- Derived -----------------------------------------------------------------
export HARBOR_INSTALL_DIR="${HARBOR_HOME}/harbor"        # the unpacked offline installer (harbor.yml, docker-compose.yml)
export HARBOR_NETWORK="harbor_harbor"                     # compose project "harbor" + network "harbor" from Harbor's compose file
export K3D_CONTEXT="k3d-${K3D_CLUSTER}"                  # kubectl context k3d writes
export K3D_SERVER_NODE="k3d-${K3D_CLUSTER}-server-0"
export K8S_API_INTERNAL="https://${K3D_SERVER_NODE}:6443" # API endpoint for containers on the docker network (runners)
export RUNNER_COMPOSE="${LAB_ROOT}/runner/docker-compose.yml"

# ---- Helpers -----------------------------------------------------------------
lab_log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
lab_warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*" >&2; }
lab_die()  { printf '\033[1;31m[lab]\033[0m %s\n' "$*" >&2; exit 1; }
lab_need() { command -v "$1" >/dev/null 2>&1 || lab_die "missing command: $1 ($2)"; }

# Read a secret file, or fail with a hint on how to create it.
lab_secret() {
  local f="${LAB_SECRETS}/$1"
  [[ -s "$f" ]] || lab_die "secret '$1' not found at $f — $2"
  cat "$f"
}

# Docker Desktop must be running for almost everything.
lab_docker_ok() { docker info >/dev/null 2>&1 || lab_die "Docker is not reachable — start Docker Desktop"; }

# Node container names of the k3d cluster, servers first.
k3d_nodes() {
  local i
  for ((i = 0; i < K3D_SERVERS; i++)); do echo "k3d-${K3D_CLUSTER}-server-${i}"; done
  for ((i = 0; i < K3D_AGENTS; i++));  do echo "k3d-${K3D_CLUSTER}-agent-${i}"; done
}

# The replacement for `ssh user@node cmd`:  lab_node_exec k3d-k3s-lab-agent-0 cat /etc/rancher/k3s/registries.yaml
lab_node_exec() { local n="$1"; shift; docker exec "$n" "$@"; }

# Render a template to stdout: ${VAR} from the environment; unknown names (e.g. containerd's "$1") are left alone.
lab_render() {
  python3 - "$1" <<'PY'
import os, sys, string
sys.stdout.write(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
PY
}
