#!/usr/bin/env bash
# lab.sh — start, stop and inspect the whole lab on Docker Desktop. Run on the Mac.
#   ./lab.sh up               Harbor -> cluster -> runners (the order the dependencies need)
#   ./lab.sh stop             runners -> cluster -> Harbor
#   ./lab.sh status           what is running, Harbor health, nodes
#   ./lab.sh create-cluster   k3d cluster from k3s/k3d-config.yaml.template (needs Harbor up + secrets/registries.yaml)
#   ./lab.sh destroy-cluster  delete the k3d cluster — Harbor keeps every image, re-create in ~2 min
#   ./lab.sh shell [node]     shell into a k3d node (default: server-0); the replacement for ssh
#   ./lab.sh prune            reclaim Docker disk: build cache, old images
# Docker Desktop restarts everything by itself at login (Harbor: restart always, nodes/runners:
# unless-stopped); `up` is for after `stop`, and it enforces the order.
set -euo pipefail
# shellcheck source=lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab-env.sh"

harbor_installed() { [[ -s "$HARBOR_INSTALL_DIR/docker-compose.yml" ]]; }
harbor_compose()   { docker compose --project-directory "$HARBOR_INSTALL_DIR" "$@"; }
runner_compose()   { docker compose -f "$RUNNER_COMPOSE" "$@"; }
cluster_exists()   { k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; }
runners_ready()    { [[ -s "$LAB_SECRETS/kubeconfig-gha-deployer.yaml" ]] && ls "$LAB_SECRETS"/runner-token-* >/dev/null 2>&1; }

wait_harbor() {
  lab_log "waiting for https://${HARBOR_HOST}/api/v2.0/health"
  for _ in $(seq 1 60); do
    if curl -fsS --cacert "$LAB_CERTS/ca.crt" "https://${HARBOR_HOST}/api/v2.0/health" 2>/dev/null | grep -q '"healthy"'; then
      lab_log "Harbor is healthy"; return 0
    fi
    sleep 5
  done
  lab_die "Harbor did not become healthy — docker compose --project-directory '$HARBOR_INSTALL_DIR' ps / logs"
}

cmd_up() {
  lab_docker_ok; lab_need k3d "brew install k3d"
  if harbor_installed; then harbor_compose up -d; wait_harbor
  else lab_warn "Harbor not installed yet — ./harbor/30-install-harbor.sh (docs/03)"; fi
  if cluster_exists; then k3d cluster start "$K3D_CLUSTER"
  else lab_warn "no k3d cluster yet — ./lab.sh create-cluster (docs/02)"; fi
  if runners_ready; then runner_compose up -d
  else lab_warn "runners skipped: need secrets/kubeconfig-gha-deployer.yaml and secrets/runner-token-* (docs/05)"; fi
  cmd_status
}

cmd_stop() {
  lab_docker_ok
  [[ -n "$(runner_compose ps -q 2>/dev/null)" ]] && runner_compose stop
  if command -v k3d >/dev/null && cluster_exists; then k3d cluster stop "$K3D_CLUSTER"; fi
  # `stop`, not `down`: the k3d nodes live on Harbor's network, and `down` would try to remove it.
  harbor_installed && harbor_compose stop
  lab_log "lab stopped (Docker Desktop will bring it back on its next restart; use ./lab.sh up before then)"
}

cmd_status() {
  lab_docker_ok
  lab_log "Harbor ($HARBOR_INSTALL_DIR)"
  if harbor_installed; then
    harbor_compose ps --format 'table {{.Name}}\t{{.Status}}' | sed 's/^/  /'
    curl -fsS --cacert "$LAB_CERTS/ca.crt" "https://${HARBOR_HOST}/api/v2.0/health" 2>/dev/null | sed 's/^/  health: /' || echo "  health: unreachable"
  else echo "  not installed"; fi
  lab_log "cluster $K3D_CLUSTER"
  if command -v k3d >/dev/null && cluster_exists; then
    k3d cluster list | sed 's/^/  /'
    kubectl --context "$K3D_CONTEXT" get nodes -o wide 2>/dev/null | sed 's/^/  /' || echo "  (stopped or API not reachable)"
  else echo "  none"; fi
  lab_log "runners"
  runner_compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /' || echo "  none"
}

cmd_create_cluster() {
  lab_docker_ok; lab_need k3d "brew install k3d"; lab_need kubectl "brew install kubectl"
  docker network inspect "$HARBOR_NETWORK" >/dev/null 2>&1 || lab_die "docker network $HARBOR_NETWORK missing — install and start Harbor first (docs/03)"
  [[ -s "$LAB_CERTS/ca.crt" ]] || lab_die "ca.crt missing — ./harbor/20-gen-certs.sh"
  [[ -s "$LAB_SECRETS/registries.yaml" ]] || "$LAB_ROOT/k3s/10-render-registries.sh"
  cluster_exists && lab_die "cluster $K3D_CLUSTER already exists — ./lab.sh destroy-cluster first"
  umask 077
  lab_render "$LAB_ROOT/k3s/k3d-config.yaml.template" > "$LAB_SECRETS/k3d-config.yaml"
  lab_log "creating k3d cluster $K3D_CLUSTER (${K3D_SERVERS} server, ${K3D_AGENTS} agents, $K3S_IMAGE)"
  k3d cluster create --config "$LAB_SECRETS/k3d-config.yaml"
  kubectl config use-context "$K3D_CONTEXT" >/dev/null
  kubectl get nodes -o wide
  cat <<EOF

Cluster up. Next (docs/02 §3):
  kubectl apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml
  ./k3s/50-pull-secrets.sh
  ./k3s/40-make-kubeconfig.sh
  Traefik: http://localhost:${TRAEFIK_HTTP_PORT}  https://localhost:${TRAEFIK_HTTPS_PORT}
EOF
}

cmd_destroy_cluster() {
  lab_need k3d "brew install k3d"
  cluster_exists || { lab_warn "no cluster $K3D_CLUSTER"; return 0; }
  k3d cluster delete "$K3D_CLUSTER"
  lab_log "cluster deleted; Harbor and the runners are untouched (re-run ./k3s/40-make-kubeconfig.sh after re-creating)"
}

cmd_shell() {
  lab_docker_ok
  docker exec -it "${1:-$K3D_SERVER_NODE}" sh
}

cmd_prune() {
  lab_docker_ok
  docker builder prune -af --filter until=168h
  docker image prune -f --filter until=336h
  docker system df
}

case "${1:-}" in
  up)              cmd_up ;;
  stop)            cmd_stop ;;
  status)          cmd_status ;;
  create-cluster)  cmd_create_cluster ;;
  destroy-cluster) cmd_destroy_cluster ;;
  shell)           cmd_shell "${2:-}" ;;
  prune)           cmd_prune ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
