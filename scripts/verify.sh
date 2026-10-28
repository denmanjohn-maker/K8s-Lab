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
CA="$LAB_CERTS/ca.crt"
K="kubectl --context ${K3D_CONTEXT}"
RUNNERS=(runner-containerhelper runner-devopshelpers)

lab_log "0. Docker Desktop"
chk "docker engine reachable"    docker info
chk "k3d installed"              k3d version
chk "network ${HARBOR_NETWORK} exists" docker network inspect "$HARBOR_NETWORK"

lab_log "1. names"
chk "${HARBOR_HOST} -> 127.0.0.1 on the Mac" bash -c "grep -Eq '^127\.0\.0\.1[[:space:]].*\b${HARBOR_HOST}\b' /etc/hosts"
chk "nginx carries alias ${HARBOR_HOST}"     bash -c "docker inspect nginx --format '{{json .NetworkSettings.Networks}}' | grep -q '${HARBOR_HOST}'"

lab_log "2. Harbor"
chk "TLS chain valid against lab CA" bash -c "echo | openssl s_client -connect 127.0.0.1:${HARBOR_HTTPS_PORT} -servername ${HARBOR_HOST} -CAfile '$CA' 2>/dev/null | grep -q 'Verify return code: 0'"
chk "API healthy"              bash -c "curl -fsS --cacert '$CA' https://${HARBOR_HOST}/api/v2.0/health | jq -e '.status==\"healthy\"' >/dev/null"
chk "cert expiry > 30 days"    bash -c "echo | openssl s_client -connect 127.0.0.1:${HARBOR_HTTPS_PORT} -servername ${HARBOR_HOST} 2>/dev/null | openssl x509 -checkend 2592000 -noout"
for p in "${HARBOR_PROJECTS[@]}" "$HARBOR_PROXY_PROJECT"; do
  chk "project ${p} exists"    bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' --cacert '$CA' -u admin:\$(cat '$LAB_SECRETS/harbor-admin.pw') -I 'https://${HARBOR_HOST}/api/v2.0/projects?project_name=${p}') == 200 ]]"
done
if [[ -s "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.token" ]]; then
  chk "robot gha-push can auth"  bash -c "curl -fsS --cacert '$CA' -u \"\$(cat '$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.user'):\$(cat '$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.token')\" 'https://${HARBOR_HOST}/api/v2.0/projects/${HARBOR_PROJECTS[0]}/repositories' >/dev/null"
fi
chk "proxy cache serves alpine manifest" bash -c "curl -fsS --cacert '$CA' -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' 'https://${HARBOR_HOST}/v2/${HARBOR_PROXY_PROJECT}/library/alpine/manifests/3.20' >/dev/null"
chk "engine trusts lab CA (docker pull via proxy cache)" docker pull -q "${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20"

lab_log "3. k3s (k3d)"
chk "cluster ${K3D_CLUSTER} listed"  bash -c "k3d cluster list --no-headers | awk '{print \$1}' | grep -qx '${K3D_CLUSTER}'"
chk "kubectl reaches cluster"  $K get --raw /readyz
chk "all nodes Ready"          bash -c "! $K get nodes --no-headers | awk '{print \$2}' | grep -qv '^Ready$'"
chk "k3s minor is ${K3S_CHANNEL}" bash -c "$K get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | grep -q '^${K3S_CHANNEL}\.'"
for n in $(k3d_nodes); do
  chk "hosts.toml on ${n}"     docker exec "$n" test -f "/var/lib/rancher/k3s/agent/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml"
done
chk "node can pull via Harbor (crictl)" docker exec "$K3D_SERVER_NODE" k3s crictl pull "${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20"
for ns in "${K8S_NAMESPACES[@]}"; do
  chk "namespace ${ns} PSA restricted" bash -c "$K get ns ${ns} -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -q restricted"
  chk "pull secret in ${ns}"          $K -n "$ns" get secret "$K8S_PULL_SECRET"
done
chk "deployer SA exists"       $K -n containerhelper get sa "$K8S_DEPLOYER_SA"
chk "deployer cannot delete nodes" bash -c "$K auth can-i delete nodes --as system:serviceaccount:containerhelper:${K8S_DEPLOYER_SA} | grep -q no"
if [[ $QUICK -eq 0 ]]; then
  chk "restricted pod runs from Harbor image" $K -n containerhelper run "verify-$$" --rm -i --restart=Never --timeout=120s \
    --image="${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"v","image":"'"${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}"'/library/alpine:3.20","command":["true"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
fi

lab_log "4. runners"
chk "kubeconfig for runners exists"    test -s "$LAB_SECRETS/kubeconfig-gha-deployer.yaml"
for r in "${RUNNERS[@]}"; do
  chk "${r} container running"         bash -c "docker inspect -f '{{.State.Running}}' ${r} | grep -q true"
  chk "${r}: docker socket usable"     docker exec "$r" docker version --format '{{.Server.Version}}'
  chk "${r}: can reach API server"     docker exec "$r" kubectl get --raw /readyz
  chk "${r}: deployer can create deployments" bash -c "docker exec ${r} kubectl -n containerhelper auth can-i create deployments | grep -q yes"
  chk "${r}: can reach Harbor"         docker exec "$r" curl -fsS "https://${HARBOR_HOST}/api/v2.0/health"
  chk "${r}: registered (.runner present)" docker exec "$r" test -f /home/runner/.runner
  chk "${r}: tools present"            docker exec "$r" sh -c 'command -v kubectl kustomize helm k9s yq jq trivy shellcheck >/dev/null'
done

echo
if (( FAILS == 0 )); then lab_log "all checks passed"; else lab_warn "${FAILS} check(s) failed — see docs/08-troubleshooting.md"; exit 1; fi
