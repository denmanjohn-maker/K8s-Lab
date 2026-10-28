#!/usr/bin/env bash
# End-to-end smoke test from the Mac. Prints PASS/FAIL per check and keeps going; exit 1 if any failed.
#   ./scripts/verify.sh            # everything
#   ./scripts/verify.sh --quick    # skip the pod-launch test
set -uo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1
FAILS=0
chk() { # chk "label" cmd...
  local label="$1"; shift
  if out="$("$@" 2>&1)"; then printf '  \033[32mPASS\033[0m %s\n' "$label"
  else printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$label" "$(echo "$out" | tail -2 | tr '\n' ' ')"; FAILS=$((FAILS+1)); fi
}
ssh_q() { ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$@"; }
CA="$LAB_CERTS/ca.crt"

lab_log "1. names & reachability"
chk "resolve ${HARBOR_HOST}"   bash -c "getent hosts ${HARBOR_HOST} >/dev/null || dscacheutil -q host -a name ${HARBOR_HOST} | grep -q ip_address"
chk "ssh k3s-server"           ssh_q "${K3S_SSH_USER}@${K3S_SERVER_IP}" true
for ip in "${K3S_AGENT_IPS[@]}"; do chk "ssh k3s-agent ${ip}" ssh_q "${K3S_SSH_USER}@${ip}" true; done
chk "ssh harbor VM"            ssh_q "${VM_SSH_USER}@${HARBOR_IP}" true
chk "ssh runner VM"            ssh_q "${VM_SSH_USER}@${RUNNER_IP}" true

lab_log "2. Harbor"
chk "TLS chain valid against lab CA" bash -c "echo | openssl s_client -connect ${HARBOR_HOST}:443 -servername ${HARBOR_HOST} -CAfile '$CA' 2>/dev/null | grep -q 'Verify return code: 0'"
chk "API healthy"              bash -c "curl -fsS --cacert '$CA' https://${HARBOR_HOST}/api/v2.0/health | jq -e '.status==\"healthy\"' >/dev/null"
chk "cert expiry > 30 days"    bash -c "echo | openssl s_client -connect ${HARBOR_HOST}:443 2>/dev/null | openssl x509 -checkend 2592000 -noout"
for p in "${HARBOR_PROJECTS[@]}" "$HARBOR_PROXY_PROJECT"; do
  chk "project ${p} exists"    bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' --cacert '$CA' -u admin:\$(cat '$LAB_SECRETS/harbor-admin.pw') -I 'https://${HARBOR_HOST}/api/v2.0/projects?project_name=${p}') == 200 ]]"
done
if [[ -s "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.token" ]]; then
  chk "robot gha-push can auth"  bash -c "curl -fsS --cacert '$CA' -u \"\$(cat '$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.user'):\$(cat '$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.token')\" 'https://${HARBOR_HOST}/api/v2.0/projects/${HARBOR_PROJECTS[0]}/repositories' >/dev/null"
fi
chk "proxy cache serves alpine manifest" bash -c "curl -fsS --cacert '$CA' -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' 'https://${HARBOR_HOST}/v2/${HARBOR_PROXY_PROJECT}/library/alpine/manifests/3.20' >/dev/null"

lab_log "3. k3s"
chk "kubectl reaches cluster"  kubectl get --raw /readyz
chk "all nodes Ready"          bash -c "! kubectl get nodes --no-headers | awk '{print \$2}' | grep -qv '^Ready$'"
chk "k3s minor is ${K3S_CHANNEL}" bash -c "kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | grep -q '^${K3S_CHANNEL}\.'"
chk "registries.yaml on server" ssh_q "${K3S_SSH_USER}@${K3S_SERVER_IP}" "sudo test -f /var/lib/rancher/k3s/agent/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml"
for ip in "${K3S_AGENT_IPS[@]}"; do chk "registries.yaml on ${ip}" ssh_q "${K3S_SSH_USER}@${ip}" "sudo test -f /var/lib/rancher/k3s/agent/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml"; done
chk "node can pull via Harbor (crictl)" ssh_q "${K3S_SSH_USER}@${K3S_SERVER_IP}" "sudo k3s crictl pull ${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20 >/dev/null"
for ns in "${K8S_NAMESPACES[@]}"; do
  chk "namespace ${ns} PSA restricted" bash -c "kubectl get ns ${ns} -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -q restricted"
  chk "pull secret in ${ns}"          kubectl -n "$ns" get secret "$K8S_PULL_SECRET"
done
chk "deployer SA exists"       kubectl -n containerhelper get sa "$K8S_DEPLOYER_SA"
if [[ -s "$LAB_SECRETS/kubeconfig-gha-deployer.yaml" ]]; then
  chk "deployer kubeconfig: can create deployments" bash -c "KUBECONFIG='$LAB_SECRETS/kubeconfig-gha-deployer.yaml' kubectl -n containerhelper auth can-i create deployments | grep -q yes"
  chk "deployer kubeconfig: cannot delete nodes"    bash -c "KUBECONFIG='$LAB_SECRETS/kubeconfig-gha-deployer.yaml' kubectl auth can-i delete nodes | grep -q no"
fi
if [[ $QUICK -eq 0 ]]; then
  chk "restricted pod runs from Harbor image" kubectl -n containerhelper run "verify-$$" --rm -i --restart=Never --timeout=120s \
    --image="${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"v","image":"'"${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}"'/library/alpine:3.20","command":["true"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
fi

lab_log "4. runner VM"
chk "docker works for 'runner' user"   ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "sudo -u runner docker version --format '{{.Server.Version}}'"
chk "docker trusts Harbor CA"          ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "test -f /etc/docker/certs.d/${HARBOR_HOST}/ca.crt"
chk "kubeconfig installed (root:runner 0640)" ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "stat -c '%U:%G %a' /etc/github-runner/kubeconfig | grep -q 'root:runner 640'"
chk "runner can reach API server"      ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "sudo -u runner KUBECONFIG=/etc/github-runner/kubeconfig kubectl get --raw /readyz"
chk "runner can reach Harbor"          ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "curl -fsS https://${HARBOR_HOST}/api/v2.0/health >/dev/null"
chk "actions-runner service active"    ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "systemctl list-units --type=service --state=active 'actions.runner.*' | grep -q actions.runner"
chk "tools present"                    ssh_q "${VM_SSH_USER}@${RUNNER_IP}" "command -v kubectl kustomize helm k9s yq jq trivy shellcheck >/dev/null"

echo
if (( FAILS == 0 )); then lab_log "all checks passed"; else lab_warn "${FAILS} check(s) failed — see docs/08-troubleshooting.md"; exit 1; fi
