#!/usr/bin/env bash
# Run ON the runner VM (fresh Ubuntu 24.04 ARM64) as your sudo user. Prepares everything the
# GitHub Actions runner needs; it does NOT install actions-runner itself — you do that (docs/05 §4).
#   ~/lab/runner/10-prep-runner-vm.sh                # tools + docker + CA trust + 'runner' service user
#   ~/lab/runner/10-prep-runner-vm.sh --with-dotnet  # also .NET 10 SDK (for building outside containers)
# Copy files here first from the Mac:
#   rsync -az lab-env.sh runner secrets/certs/ca.crt john@runner.lab.internal:~/lab/   (see docs/05 §2)
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

WITH_DOTNET=0; [[ "${1:-}" == "--with-dotnet" ]] && WITH_DOTNET=1
ARCH="$(dpkg --print-architecture)"            # arm64
CA_SRC="$LAB_ROOT/certs/ca.crt"; [[ -s "$CA_SRC" ]] || CA_SRC="$LAB_CERTS/ca.crt"
[[ -s "$CA_SRC" ]] || lab_die "ca.crt not found — rsync secrets/certs/ca.crt to ~/lab/certs/ first"

lab_log "hostname -> ${RUNNER_HOST}"
sudo hostnamectl set-hostname "${RUNNER_HOST}"
grep -q "${RUNNER_HOST}" /etc/hosts || echo "127.0.1.1 ${RUNNER_HOST} runner" | sudo tee -a /etc/hosts >/dev/null

lab_log "base packages (git, jq, build tools, shellcheck for your bash repos)"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  ca-certificates curl gnupg lsb-release git jq unzip zip tar rsync chrony ufw \
  shellcheck make build-essential python3 python3-pip libicu74
# libicu is the one runtime dependency actions-runner (.NET-based) needs on Ubuntu 24.04;
# its own bin/installdependencies.sh covers anything else when you install it (docs/05 §4).

lab_log "trust lab CA (system store + docker certs.d)"
sudo install -m 644 "$CA_SRC" /usr/local/share/ca-certificates/kubernetes-lab-ca.crt
sudo update-ca-certificates >/dev/null
sudo mkdir -p "/etc/docker/certs.d/${HARBOR_HOST}"
sudo install -m 644 "$CA_SRC" "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt"

# ---- service user ------------------------------------------------------------
# actions-runner must NOT run as root. 'runner' owns /opt/actions-runner-* and is in the docker group.
if ! id runner >/dev/null 2>&1; then
  lab_log "creating service user 'runner'"
  sudo useradd --system --create-home --home-dir /home/runner --shell /bin/bash runner
fi
sudo install -d -m 750 -o root -g runner /etc/github-runner      # kubeconfig lands here (docs/05 §3)

# ---- docker --------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  lab_log "installing Docker CE + buildx + compose"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo mkdir -p /etc/docker
[[ -s /etc/docker/daemon.json ]] || sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
EOF
sudo systemctl enable --now docker >/dev/null
sudo systemctl restart docker
sudo usermod -aG docker "$USER"
sudo usermod -aG docker runner

# binfmt so buildx can also produce linux/amd64 images (QEMU user-mode; slow but works for publishing to GHCR)
sudo docker run --privileged --rm tonistiigi/binfmt --install amd64 >/dev/null 2>&1 || lab_warn "binfmt amd64 install skipped (no internet?)"

# ---- kubernetes tooling ------------------------------------------------------------
install_bin() { sudo install -m 755 "$1" "/usr/local/bin/$2"; lab_log "  $2 -> $("/usr/local/bin/$2" "${3:-version}" 2>/dev/null | head -1)"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

KVER="$(curl -fsSL "https://dl.k8s.io/release/stable-${K3S_CHANNEL#v}.txt")"     # latest v1.34.x
lab_log "kubectl ${KVER}"
curl -fsSL -o "$TMP/kubectl" "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
curl -fsSL -o "$TMP/kubectl.sha256" "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl.sha256"
(cd "$TMP" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - >/dev/null)
install_bin "$TMP/kubectl" kubectl "version --client"

lab_log "kustomize (latest)"
(cd "$TMP" && curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash >/dev/null)
install_bin "$TMP/kustomize" kustomize version

lab_log "helm (latest 3.x)"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR=/usr/local/bin sudo -E bash >/dev/null
helm version --short

lab_log "k9s ${K9S_VERSION}"
curl -fsSL -o "$TMP/k9s.tgz" "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz"
tar -xzf "$TMP/k9s.tgz" -C "$TMP" k9s
install_bin "$TMP/k9s" k9s version

lab_log "yq"
curl -fsSL -o "$TMP/yq" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
install_bin "$TMP/yq" yq --version

lab_log "trivy CLI (scan locally in jobs before pushing, if you want)"
curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin >/dev/null
trivy --version | head -1

if [[ $WITH_DOTNET -eq 1 ]]; then
  lab_log ".NET 10 SDK -> /usr/share/dotnet"
  curl -fsSL -o "$TMP/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
  sudo bash "$TMP/dotnet-install.sh" --channel 10.0 --install-dir /usr/share/dotnet
  sudo ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
  echo 'export DOTNET_ROOT=/usr/share/dotnet' | sudo tee /etc/profile.d/dotnet.sh >/dev/null
  dotnet --version
fi

# ---- firewall: ssh only; the runner is outbound-only to GitHub -----------------------------------
sudo ufw --force reset >/dev/null; sudo ufw default deny incoming >/dev/null; sudo ufw default allow outgoing >/dev/null
sudo ufw allow 22/tcp >/dev/null; sudo ufw --force enable >/dev/null

# ---- kubeconfig placeholder for the runner --------------------------------------------------
sudo tee /etc/profile.d/kubernetes-lab.sh >/dev/null <<'EOF'
# set for every login shell; workflows set it explicitly as well
[ -r /etc/github-runner/kubeconfig ] && export KUBECONFIG=/etc/github-runner/kubeconfig
EOF

cat <<EOF

runner VM prepared.
  tools: docker $(docker --version | awk '{print $3}') · kubectl ${KVER} · kustomize · helm · k9s ${K9S_VERSION} · yq · trivy · shellcheck$( [[ $WITH_DOTNET -eq 1 ]] && echo ' · dotnet 10')
  service user: runner (docker group)        kubeconfig dir: /etc/github-runner (copy from Mac — docs/05 §3)
Next: install actions-runner yourself as user 'runner' — docs/05 §4.  Log out/in first for the docker group.
EOF
