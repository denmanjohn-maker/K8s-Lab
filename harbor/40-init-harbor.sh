#!/usr/bin/env bash
# Run on the Mac after Harbor is healthy. Idempotent.
#   - projects:   $HARBOR_PROJECTS (private, auto-scan on push)
#   - proxy cache: project $HARBOR_PROXY_PROJECT -> Docker Hub (public, so k3s can pull without auth)
#   - robots:     robot$gha-push (push/pull on your projects), robot$k3s-pull (pull everywhere)
#   - secrets saved to secrets/harbor-robot-<name>.{user,token}
# Flags:  --rotate-robots   delete + recreate robots (secrets can't be re-read once created)
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need curl ""; lab_need jq "brew install jq"

ROTATE=0; [[ "${1:-}" == "--rotate-robots" ]] && ROTATE=1
ADMIN_PW="$(lab_secret harbor-admin.pw 'run harbor/30-install-harbor.sh first')"
API="https://${HARBOR_HOST}/api/v2.0"

h() { # h METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -sS --cacert "$LAB_CERTS/ca.crt" -u "admin:${ADMIN_PW}" -X "$m" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' "${API}${p}" -d "$d"
  else
    curl -sS --cacert "$LAB_CERTS/ca.crt" -u "admin:${ADMIN_PW}" -X "$m" -w '\n%{http_code}' "${API}${p}"
  fi
}
body() { sed '$d'; }          # strip trailing status line
code() { tail -n1; }

lab_log "checking ${API}/health"
h GET /health | body | jq -e '.status=="healthy"' >/dev/null || lab_die "Harbor not healthy at ${HARBOR_HOST}"

# ---- projects -----------------------------------------------------------------
project_exists() { [[ "$(h HEAD "/projects?project_name=$1" | code)" == "200" ]]; }

for p in "${HARBOR_PROJECTS[@]}"; do
  if project_exists "$p"; then lab_log "project $p exists"; continue; fi
  lab_log "creating project $p (private, auto-scan on push)"
  h POST /projects "$(jq -nc --arg n "$p" '{project_name:$n, metadata:{public:"false", auto_scan:"true",
      reuse_sys_cve_allowlist:"true", prevent_vul:"false", severity:"critical"}}')" | code | grep -q '^201' \
    || lab_die "failed creating project $p"
done

# ---- Docker Hub proxy cache ---------------------------------------------------------
# Pull as: ${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20  (note the 'library/' for official images)
REG_ID="$(h GET "/registries?q=name%3D${HARBOR_PROXY_PROJECT}" | body | jq -r '.[0].id // empty')"
if [[ -z "$REG_ID" ]]; then
  lab_log "creating registry endpoint '${HARBOR_PROXY_PROJECT}' -> https://hub.docker.com"
  h POST /registries "$(jq -nc --arg n "$HARBOR_PROXY_PROJECT" '{name:$n, type:"docker-hub", url:"https://hub.docker.com", insecure:false}')" \
    | code | grep -q '^201' || lab_die "failed creating registry endpoint"
  REG_ID="$(h GET "/registries?q=name%3D${HARBOR_PROXY_PROJECT}" | body | jq -r '.[0].id')"
fi
if project_exists "$HARBOR_PROXY_PROJECT"; then
  lab_log "proxy project ${HARBOR_PROXY_PROJECT} exists"
else
  lab_log "creating proxy-cache project ${HARBOR_PROXY_PROJECT} (registry_id=${REG_ID}, public)"
  h POST /projects "$(jq -nc --arg n "$HARBOR_PROXY_PROJECT" --argjson r "$REG_ID" \
      '{project_name:$n, registry_id:$r, metadata:{public:"true", auto_scan:"false"}}')" | code | grep -q '^201' \
    || lab_die "failed creating proxy project"
fi

# ---- robot accounts --------------------------------------------------------------
# System-level robots so one credential spans several projects. Names come back as robot$<name>.
robot_id() { h GET "/robots?q=name%3D$1" | body | jq -r '.[0].id // empty'; }

perm() { # perm PROJECT ACTIONS...  -> one permission object
  local ns="$1"; shift
  local acc; acc="$(printf '%s\n' "$@" | jq -R 'split(":") | {resource:.[0], action:.[1]}' | jq -sc .)"
  jq -nc --arg ns "$ns" --argjson a "$acc" '{kind:"project", namespace:$ns, access:$a}'
}

create_robot() { # create_robot NAME DESCRIPTION PERMISSIONS_JSON_ARRAY
  local name="$1" desc="$2" perms="$3" id
  id="$(robot_id "$name")"
  if [[ -n "$id" && $ROTATE -eq 1 ]]; then lab_log "deleting robot $name (id $id) for rotation"; h DELETE "/robots/$id" >/dev/null; id=""; fi
  if [[ -n "$id" ]]; then
    lab_log "robot $name exists (id $id) — keeping; use --rotate-robots to re-issue the secret"; return
  fi
  lab_log "creating robot $name"
  local resp; resp="$(h POST /robots "$(jq -nc --arg n "$name" --arg d "$desc" --argjson p "$perms" \
      '{name:$n, description:$d, duration:-1, disable:false, level:"system", permissions:$p}')")"
  [[ "$(echo "$resp" | code)" == "201" ]] || lab_die "robot create failed: $(echo "$resp" | body)"
  umask 077
  echo "$resp" | body | jq -r '.name'   > "$LAB_SECRETS/harbor-robot-${name}.user"
  echo "$resp" | body | jq -r '.secret' > "$LAB_SECRETS/harbor-robot-${name}.token"
  lab_log "  saved secrets/harbor-robot-${name}.{user,token}"
}

# Valid resource:action pairs come from src/common/rbac/const.go (ScopeProject) in the Harbor repo.
PUSH_ACTIONS=(repository:pull repository:push repository:list artifact:read artifact:list artifact-addition:read tag:create tag:list scan:create scan:read)
PULL_ACTIONS=(repository:pull repository:list artifact:read artifact:list tag:list)

push_perms="$( { for p in "${HARBOR_PROJECTS[@]}"; do perm "$p" "${PUSH_ACTIONS[@]}"; done
                 perm "$HARBOR_PROXY_PROJECT" "${PULL_ACTIONS[@]}"; } | jq -sc .)"
pull_perms="$( { for p in "${HARBOR_PROJECTS[@]}" "$HARBOR_PROXY_PROJECT"; do perm "$p" "${PULL_ACTIONS[@]}"; done; } | jq -sc .)"

create_robot "$HARBOR_ROBOT_PUSH" "GitHub Actions runner: build & push, read scan results" "$push_perms"
create_robot "$HARBOR_ROBOT_PULL" "k3s nodes + imagePullSecrets: pull only" "$pull_perms"

# ---- summary ------------------------------------------------------------------
cat <<EOF

Harbor initialised at https://${HARBOR_HOST}/
  projects:    ${HARBOR_PROJECTS[*]}  (+ ${HARBOR_PROXY_PROJECT} = Docker Hub proxy cache, public)
  robots:      $(cat "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.user" 2>/dev/null)  $(cat "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PULL}.user" 2>/dev/null)
  test pull:   docker pull ${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20
  test login:  docker login ${HARBOR_HOST} -u "\$(cat secrets/harbor-robot-${HARBOR_ROBOT_PUSH}.user)" -p "\$(cat secrets/harbor-robot-${HARBOR_ROBOT_PUSH}.token)"
Next:  ./k3s/10-render-registries.sh  then  ./lab.sh create-cluster
EOF
