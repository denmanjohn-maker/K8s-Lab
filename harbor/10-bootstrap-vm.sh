#!/usr/bin/env bash
# Run ON the Harbor VM (fresh Ubuntu 24.04 ARM64) as your sudo-capable user.
# Installs Docker CE + Compose v2 from Docker's apt repo, trusts the lab CA,
# sets the hostname, and does light hardening. Idempotent.
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

[[ "$(uname -m)" == "aarch64" ]] || lab_warn "expected aarch64 — HARBOR_ARCH in lab-env.sh is '${HARBOR_ARCH}'"
[[ -s "$LAB_CERTS/ca.crt" ]] || lab_die "ca.crt missing — run harbor/00-push-to-vm.sh from the Mac first"

lab_log "hostname -> ${HARBOR_HOST}"
sudo hostnamectl set-hostname "${HARBOR_HOST}"
grep -q "${HARBOR_HOST}" /etc/hosts || echo "127.0.1.1 ${HARBOR_HOST} harbor" | sudo tee -a /etc/hosts >/dev/null

lab_log "base packages"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  ca-certificates curl gnupg lsb-release openssl jq rsync chrony ufw apt-transport-https

lab_log "trusting lab CA system-wide"
sudo install -m 644 "$LAB_CERTS/ca.crt" /usr/local/share/ca-certificates/kubernetes-lab-ca.crt
sudo update-ca-certificates >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  lab_log "installing Docker CE + compose plugin (Harbor needs Docker >= 20.10 and Compose v2)"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  lab_log "docker already installed: $(docker --version)"
fi

# Sane daemon defaults: json-file log rotation so /var/lib/docker doesn't fill the 60 GB disk.
sudo mkdir -p /etc/docker
if [[ ! -s /etc/docker/daemon.json ]]; then
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true
}
EOF
  sudo systemctl restart docker
fi
sudo systemctl enable --now docker >/dev/null
sudo usermod -aG docker "$USER"

lab_log "firewall: allow ssh, http, https only"
sudo ufw --force reset >/dev/null
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow 22/tcp  >/dev/null
sudo ufw allow 80/tcp  >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null

lab_log "Harbor data volume -> /data (same disk; attach a second vmdk here later if you want)"
sudo mkdir -p /data && sudo chmod 755 /data

cat <<EOF

bootstrap complete.
  docker:  $(docker --version)
  compose: $(docker compose version 2>/dev/null || echo 'log out/in then re-check')
Log out and back in (docker group), then run ~/lab/harbor/30-install-harbor.sh
EOF
