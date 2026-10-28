#!/usr/bin/env bash
# Run on the Mac (needs the k3d admin context). Builds a standalone kubeconfig for the gha-deployer
# ServiceAccount and writes it to secrets/kubeconfig-gha-deployer.yaml. The runner containers mount
# that file read-only at /etc/github-runner/kubeconfig (runner/docker-compose.yml) — restart them
# after re-running this:  docker compose -f runner/docker-compose.yml restart
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need kubectl "brew install kubectl"
K="kubectl --context ${K3D_CONTEXT}"

NS="containerhelper"; SECRET="gha-deployer-token"; OUT="$LAB_SECRETS/kubeconfig-gha-deployer.yaml"
$K -n "$NS" get sa "$K8S_DEPLOYER_SA" >/dev/null || lab_die "apply k3s/30-deployer-rbac.yaml first"

lab_log "waiting for token controller to populate $NS/$SECRET"
for _ in $(seq 1 20); do
  TOKEN="$($K -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$TOKEN" ]] && break; sleep 2
done
[[ -n "${TOKEN:-}" ]] || lab_die "no token in secret $NS/$SECRET"

# Cluster CA from the k3d context; API endpoint pinned to the server node's container name so the
# runners (on the same docker network) never depend on the 127.0.0.1 port k3d publishes for the Mac.
CA_DATA="$($K config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$CA_DATA" ]] || lab_die "could not read cluster CA from context ${K3D_CONTEXT}"
SERVER="${K8S_API_INTERNAL}"

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${K3D_CLUSTER}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${K8S_DEPLOYER_SA}
  user:
    token: ${TOKEN}
contexts:
- name: ${K3D_CLUSTER}
  context:
    cluster: ${K3D_CLUSTER}
    user: ${K8S_DEPLOYER_SA}
    namespace: ${NS}
current-context: ${K3D_CLUSTER}
EOF

# The server name only resolves inside docker, so verify from a throwaway container on that network.
lab_log "verifying with the new kubeconfig (from inside the docker network)"
if docker network inspect "$HARBOR_NETWORK" >/dev/null 2>&1; then
  docker run --rm --network "$HARBOR_NETWORK" -v "$OUT:/kc:ro" -e KUBECONFIG=/kc \
    "${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/bitnami/kubectl:${K3S_CHANNEL#v}" auth whoami 2>/dev/null \
    || lab_warn "in-network check skipped (image not cached yet) — the runner smoke test covers it (docs/05 §5)"
fi
for ns in "${K8S_NAMESPACES[@]}"; do
  printf '  %-16s create deployments: %s   delete nodes: %s\n' "$ns" \
    "$($K -n "$ns" auth can-i create deployments --as "system:serviceaccount:${ns}:${K8S_DEPLOYER_SA}")" \
    "$($K auth can-i delete nodes --as "system:serviceaccount:${ns}:${K8S_DEPLOYER_SA}")"
done

cat <<EOF

wrote $OUT  (0600)  server=${SERVER}
Mounted into the runners by runner/docker-compose.yml. If they are already running:
  docker compose -f runner/docker-compose.yml restart
EOF
