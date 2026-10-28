#!/usr/bin/env bash
# =============================================================================
# lab-env.sh — single source of truth for the Kubernetes Lab
#
# Source this from every script and from your shell:
#     source "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Kubernetes Lab/lab-env.sh"
#
# Edit the values in the "EDIT ME" block to match your Fusion network. Everything
# else is derived. Secrets are NOT stored here — they live in ./secrets/ (git-ignored).
# =============================================================================

# ---- EDIT ME ----------------------------------------------------------------
# Fusion NAT (vmnet8) addresses. Give the Harbor + runner VMs DHCP reservations
# (or static IPs) so these never change — see docs/03-harbor-vm.md §2.
export LAB_DOMAIN="lab.internal"            # .internal is reserved for private use; avoid .local (mDNS clash on macOS)

export HARBOR_HOST="harbor.${LAB_DOMAIN}"
export HARBOR_IP="192.168.64.50"            # <- Harbor VM

export RUNNER_HOST="runner.${LAB_DOMAIN}"
export RUNNER_IP="192.168.64.60"            # <- GitHub Actions runner VM

# Existing k3s-lab nodes (Ubuntu 24.04 ARM64, K3s v1.34). Names/IPs must match
# ~/Virtual Machines.localized/k3s-lab — check with:  ./lab.sh status
export K3S_SERVER_IP="192.168.64.10"
export K3S_AGENT_IPS=("192.168.64.11" "192.168.64.12")
export K3S_SSH_USER="ubuntu"                # user lab.sh created on the nodes

export VM_SSH_USER="john"                   # user you create on the Harbor and runner VMs

# GitHub
export GH_OWNER="denmanjohn-maker"
export GH_REPOS=("ContainerHelperAdditions" "DevOpsHelperTools")
export RUNNER_LABEL="k3s-lab"               # custom label your workflows target with runs-on
# -----------------------------------------------------------------------------

# ---- Versions (checked 2026-10-27) -------------------------------------------
# Harbor 2.16.0 is the first release with OFFICIAL multi-arch (amd64+arm64) images
# and an arm64 offline installer. 2.15.x and older are amd64-only and will not run
# natively on the Apple-Silicon Fusion VMs. Bump to "v2.16.0" when GA ships.
export HARBOR_VERSION="v2.16.0-rc1"
export HARBOR_ARCH="arm64"
export K9S_VERSION="v0.51.0"
export RUNNER_VERSION="2.338.2"             # actions/runner — you install this yourself (docs/05)
export K3S_CHANNEL="v1.34"                  # pinned to match work VKS
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
export K8S_DEPLOYER_SA="gha-deployer"       # ServiceAccount the runner's kubeconfig uses
export K8S_PULL_SECRET="harbor-pull"        # imagePullSecret name in each namespace
# -----------------------------------------------------------------------------

# ---- Paths -----------------------------------------------------------------
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LAB_ROOT
export LAB_SECRETS="${LAB_ROOT}/secrets"   # git-ignored; CA key, robot tokens, kubeconfig
export LAB_CERTS="${LAB_SECRETS}/certs"
mkdir -p "${LAB_SECRETS}" "${LAB_CERTS}"
chmod 700 "${LAB_SECRETS}"

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
