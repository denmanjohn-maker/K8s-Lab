#!/usr/bin/env bash
# Run on the Mac. Renders secrets/registries.yaml for the k3d nodes: Harbor auth (robot$k3s-pull),
# the lab CA, and docker.io mirrored through the Harbor proxy cache. k3d bind-mounts the file at
# /etc/rancher/k3s/registries.yaml on every node when the cluster is created (lab.sh create-cluster).
# Re-run after rotating the robot: the mounted file is updated in place and the cluster is restarted
# so K3s regenerates containerd's hosts.toml. Idempotent.
#   ./k3s/10-render-registries.sh                      # default: docker.io pulls go via Harbor proxy cache
#   ./k3s/10-render-registries.sh --no-dockerhub-mirror
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

MIRROR_HUB=1; [[ "${1:-}" == "--no-dockerhub-mirror" ]] && MIRROR_HUB=0
[[ -s "$LAB_CERTS/ca.crt" ]] || lab_die "ca.crt missing — harbor/20-gen-certs.sh"
ROBOT_USER="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.user"  'run harbor/40-init-harbor.sh')"
ROBOT_TOKEN="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.token" 'run harbor/40-init-harbor.sh')"
export ROBOT_USER ROBOT_TOKEN

# containerd resolves "alpine" to docker.io/library/alpine; the rewrite prefixes the proxy project.
if [[ $MIRROR_HUB -eq 1 ]]; then
  DOCKERHUB_MIRROR_BLOCK="$(cat <<EOF
  "docker.io":
    endpoint:
      - "https://${HARBOR_HOST}"
    rewrite:
      "^(.*)\$": "${HARBOR_PROXY_PROJECT}/\$1"
EOF
)"
else
  DOCKERHUB_MIRROR_BLOCK=""
fi
export DOCKERHUB_MIRROR_BLOCK

OUT="$LAB_SECRETS/registries.yaml"
umask 077
# ">" truncates in place: the nodes bind-mount this inode, so they see the new content.
lab_render "$LAB_ROOT/k3s/registries.yaml.template" > "$OUT"
lab_log "wrote $OUT (docker.io mirror: $([[ $MIRROR_HUB -eq 1 ]] && echo on || echo off))"

if command -v k3d >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
   && k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; then
  lab_log "cluster $K3D_CLUSTER exists — restarting it so K3s re-reads registries.yaml"
  k3d cluster stop "$K3D_CLUSTER" && k3d cluster start "$K3D_CLUSTER"
  for n in $(k3d_nodes); do
    if lab_node_exec "$n" test -f "/var/lib/rancher/k3s/agent/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" 2>/dev/null; then
      lab_log "  $n: hosts.toml present"
    else
      lab_warn "  $n: hosts.toml not (yet) generated — give it a minute, then docs/08 §2"
    fi
  done
else
  lab_log "no running cluster — the file is picked up by ./lab.sh create-cluster"
fi
