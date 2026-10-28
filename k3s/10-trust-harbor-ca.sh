#!/usr/bin/env bash
# Run on the Mac. For every k3s node: install the lab CA in the OS trust store, write
# /etc/rancher/k3s/registries.yaml (Harbor auth + CA, and docker.io mirrored through the
# Harbor proxy cache), then restart k3s / k3s-agent. Idempotent; safe to re-run after rotating robots.
#   ./k3s/10-trust-harbor-ca.sh                      # default: docker.io pulls go via Harbor proxy cache
#   ./k3s/10-trust-harbor-ca.sh --no-dockerhub-mirror
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need kubectl "brew install kubectl"

MIRROR_HUB=1; [[ "${1:-}" == "--no-dockerhub-mirror" ]] && MIRROR_HUB=0
[[ -s "$LAB_CERTS/ca.crt" ]] || lab_die "ca.crt missing — harbor/20-gen-certs.sh"
ROBOT_USER="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.user"  'run harbor/40-init-harbor.sh')"
ROBOT_TOKEN="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.token" 'run harbor/40-init-harbor.sh')"

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

render() {
  local tpl="$LAB_ROOT/k3s/registries.yaml.template"
  HARBOR_HOST="$HARBOR_HOST" ROBOT_USER="$ROBOT_USER" ROBOT_TOKEN="$ROBOT_TOKEN" \
  DOCKERHUB_MIRROR_BLOCK="$DOCKERHUB_MIRROR_BLOCK" \
  python3 - "$tpl" <<'PY'
import os, sys, string
# safe_substitute: leaves the containerd rewrite's "$1" alone instead of treating it as a variable
print(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
PY
}
REG_YAML="$(render)"

apply_node() { # apply_node IP SERVICE
  local ip="$1" svc="$2"
  local t="${K3S_SSH_USER}@${ip}"
  lab_log "node ${ip} (${svc})"
  scp -q -o StrictHostKeyChecking=accept-new "$LAB_CERTS/ca.crt" "$t:/tmp/kubernetes-lab-ca.crt"
  printf '%s\n' "$REG_YAML" | ssh "$t" 'cat > /tmp/registries.yaml'
  ssh "$t" "set -e
    sudo install -m 644 /tmp/kubernetes-lab-ca.crt /usr/local/share/ca-certificates/kubernetes-lab-ca.crt
    sudo update-ca-certificates >/dev/null
    sudo mkdir -p /etc/rancher/k3s
    sudo install -m 644 /tmp/kubernetes-lab-ca.crt /etc/rancher/k3s/kubernetes-lab-ca.crt
    if ! sudo cmp -s /tmp/registries.yaml /etc/rancher/k3s/registries.yaml; then
      sudo install -m 600 /tmp/registries.yaml /etc/rancher/k3s/registries.yaml
      echo '  registries.yaml changed -> restarting ${svc}'
      sudo systemctl restart ${svc}
    else
      echo '  registries.yaml unchanged'
    fi
    rm -f /tmp/registries.yaml /tmp/kubernetes-lab-ca.crt"
}

apply_node "$K3S_SERVER_IP" k3s
for ip in "${K3S_AGENT_IPS[@]}"; do apply_node "$ip" k3s-agent; done

lab_log "waiting for nodes Ready"
for _ in $(seq 1 30); do
  if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qv '^Ready$'; then sleep 4; else break; fi
done
kubectl get nodes -o wide

# Prove containerd can pull through Harbor without any imagePullSecret (registries.yaml auth).
lab_log "test: run a pod from ${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine via the proxy cache"
kubectl run harbor-pull-test --rm -i --restart=Never --image="${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"harbor-pull-test","image":"'"${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}"'/library/alpine:3.20","command":["sh","-c","echo pulled-through-harbor-ok"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  --timeout=120s || lab_warn "test pod failed — see docs/08 §2"

cat <<EOF
Next:
  kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml
  ./k3s/50-pull-secrets.sh
  ./k3s/40-make-kubeconfig.sh
EOF
