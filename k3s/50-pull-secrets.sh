#!/usr/bin/env bash
# Run on the Mac. Creates/refreshes the `harbor-pull` imagePullSecret (robot$k3s-pull) in every
# solution namespace and attaches it to the `default` ServiceAccount there.
# Note: nodes already authenticate via registries.yaml, so this secret is belt-and-braces — it
# keeps manifests portable to VKS, where there is no registries.yaml you control.
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need kubectl "brew install kubectl"

USER_="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.user"  'run harbor/40-init-harbor.sh')"
TOKEN="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PULL}.token" 'run harbor/40-init-harbor.sh')"

for ns in "${K8S_NAMESPACES[@]}" lab-sandbox; do
  kubectl get ns "$ns" >/dev/null 2>&1 || { lab_warn "namespace $ns missing — kubectl apply -f k3s/20-namespaces.yaml"; continue; }
  lab_log "$ns/$K8S_PULL_SECRET"
  kubectl -n "$ns" create secret docker-registry "$K8S_PULL_SECRET" \
    --docker-server="$HARBOR_HOST" --docker-username="$USER_" --docker-password="$TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" patch serviceaccount default -p "{\"imagePullSecrets\":[{\"name\":\"$K8S_PULL_SECRET\"}]}" >/dev/null
done
lab_log "done — reference it in manifests as spec.imagePullSecrets[].name=$K8S_PULL_SECRET"
