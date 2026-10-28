#!/usr/bin/env bash
# Run on the Mac (needs cluster-admin kubeconfig for k3s-lab). Builds a standalone kubeconfig
# for the gha-deployer ServiceAccount and writes it to secrets/kubeconfig-gha-deployer.yaml.
# Then copy it to the runner VM:  /etc/github-runner/kubeconfig  (docs/05 §3).
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need kubectl "brew install kubectl"

NS="containerhelper"; SECRET="gha-deployer-token"; OUT="$LAB_SECRETS/kubeconfig-gha-deployer.yaml"
kubectl -n "$NS" get sa "$K8S_DEPLOYER_SA" >/dev/null || lab_die "apply k3s/30-deployer-rbac.yaml first"

lab_log "waiting for token controller to populate $NS/$SECRET"
for _ in $(seq 1 20); do
  TOKEN="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$TOKEN" ]] && break; sleep 2
done
[[ -n "${TOKEN:-}" ]] || lab_die "no token in secret $NS/$SECRET"

# Cluster CA from the admin kubeconfig's current context; API endpoint pinned to the server VM so
# the runner never depends on 127.0.0.1 entries that k3s writes into /etc/rancher/k3s/k3s.yaml.
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$CA_DATA" ]] || lab_die "could not read cluster CA from current kubeconfig context"
SERVER="https://${K3S_SERVER_IP}:6443"

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: k3s-lab
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${K8S_DEPLOYER_SA}
  user:
    token: ${TOKEN}
contexts:
- name: k3s-lab
  context:
    cluster: k3s-lab
    user: ${K8S_DEPLOYER_SA}
    namespace: ${NS}
current-context: k3s-lab
EOF

lab_log "verifying with the new kubeconfig"
KUBECONFIG="$OUT" kubectl auth whoami 2>/dev/null || true
for ns in "${K8S_NAMESPACES[@]}"; do
  printf '  %-16s create deployments: %s   delete nodes: %s\n' "$ns" \
    "$(KUBECONFIG="$OUT" kubectl -n "$ns" auth can-i create deployments)" \
    "$(KUBECONFIG="$OUT" kubectl auth can-i delete nodes)"
done

cat <<EOF

wrote $OUT  (0600)
Copy to the runner VM once it exists:
  scp "$OUT" ${VM_SSH_USER}@${RUNNER_IP}:/tmp/kubeconfig
  ssh ${VM_SSH_USER}@${RUNNER_IP} 'sudo install -d -m 750 -o root -g runner /etc/github-runner && sudo install -m 640 -o root -g runner /tmp/kubeconfig /etc/github-runner/kubeconfig && rm /tmp/kubeconfig'
(runner/10-prep-runner-vm.sh creates the 'runner' group/user.)
EOF
