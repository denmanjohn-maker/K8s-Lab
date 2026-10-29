#!/usr/bin/env bash
# Phase 0 of docs/09-plan-docker-desktop.md: prove Docker Desktop can host the lab before cutting over.
# Run on the Mac from the repo root. Fusion can keep running; nothing here touches the VMs.
#
#   ./scripts/phase0-spikes.sh preflight   tools, Docker Desktop shape/resources, free ports, file sharing, CA, /etc/hosts
#   ./scripts/phase0-spikes.sh s1          Harbor compose stack on Docker Desktop
#   ./scripts/phase0-spikes.sh s2          engine push by hostname + the Trivy scan S1 asks for
#   ./scripts/phase0-spikes.sh s3          k3d nodes pull through Harbor; PSA-restricted sample runs
#   ./scripts/phase0-spikes.sh s4          one runner container (needs secrets/runner-token-containerhelper)
#   ./scripts/phase0-spikes.sh all         preflight + s1 + s2 + s3 = the decision gate (s4 stays separate)
#   ./scripts/phase0-spikes.sh cleanup     remove the S3 sample deployment and the S2 test image (keeps Harbor + cluster)
#
# Flags:  --yes        answer yes to the sudo prompts (keychain trust, /etc/hosts, Docker Desktop restart)
#         --no-record  don't write results into the §2 table of docs/09
# Every run is logged to secrets/phase0-<timestamp>.log. Each spike is safe to re-run: the scripts it calls
# are idempotent, and a spike only (re)creates what is missing.
set -uo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

# ---- args ----------------------------------------------------------------------
CMD=""; YES=0; RECORD=1
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --no-record) RECORD=0 ;;
    -*) lab_die "unknown flag $a" ;;
    *) CMD="$a" ;;
  esac
done
[[ -n "$CMD" ]] || { sed -n '2,17p' "$0"; exit 1; }

LOG="$LAB_SECRETS/phase0-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

CA="$LAB_CERTS/ca.crt"
K="kubectl --context ${K3D_CONTEXT}"
API="https://${HARBOR_HOST}/api/v2.0"
PLAN="$LAB_ROOT/docs/09-plan-docker-desktop.md"
TODAY="$(date +%Y-%m-%d)"
TEST_REPO="lab/alpine"; TEST_TAG="test"
SAMPLE_NS="containerhelper"
PROXY_ALPINE="${HARBOR_HOST}/${HARBOR_PROXY_PROJECT}/library/alpine:3.20"
# results per spike (plain vars: macOS ships bash 3.2, no associative arrays)
# shellcheck disable=SC2034  # set indirectly via printf -v in record()
RES_S1="" RES_S2="" RES_S3="" RES_S4=""
SAMPLE_APPLY=""

# ---- helpers ---------------------------------------------------------------------
FAILS=0
chk() { # chk "label" cmd...   — PASS/FAIL, keeps going
  local label="$1"; shift; local out
  if out="$("$@" 2>&1)"; then printf '  \033[32mPASS\033[0m %s\n' "$label"
  else printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$label" "$(echo "$out" | tail -3 | tr '\n' ' ')"; FAILS=$((FAILS+1)); fi
}
warn_chk() { # like chk, but a miss is a warning, not a failure
  local label="$1"; shift; local out
  if out="$("$@" 2>&1)"; then printf '  \033[32mPASS\033[0m %s\n' "$label"
  else printf '  \033[33mWARN\033[0m %s\n       %s\n' "$label" "$(echo "$out" | tail -2 | tr '\n' ' ')"; fi
}
step() { # step "label" cmd...  — setup step, output streamed; failure aborts the spike
  local label="$1"; shift
  lab_log "→ $label"
  if "$@"; then return 0; fi
  printf '  \033[31mFAIL\033[0m setup step failed: %s\n' "$label"; FAILS=$((FAILS+1)); return 1
}
confirm() { # confirm "question" — yes with --yes; no when there is no terminal
  [[ $YES -eq 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local r; read -r -p "$1 [y/N] " r; [[ "$r" =~ ^[Yy] ]]
}
hdr() { echo; printf '\033[1;36m==== %s ====\033[0m\n' "$*"; }

harbor_healthy() { curl -fsS --max-time 5 --cacert "$CA" "$API/health" 2>/dev/null | jq -e '.status=="healthy"' >/dev/null; }
cluster_exists()  { k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; }
admin_pw()        { cat "$LAB_SECRETS/harbor-admin.pw"; }
hapi() { curl -fsS --cacert "$CA" -u "admin:$(admin_pw)" "$@"; }   # hapi [curl args] URL

ca_fingerprint() { openssl x509 -in "$CA" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':'; }
ca_in_keychain() { security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "SHA-1 hash: $(ca_fingerprint)"; }
hosts_ok()       { grep -Eq "^127\.0\.0\.1[[:space:]].*\b${HARBOR_HOST}\b" /etc/hosts; }
no_psa_violation() { ! grep -qi 'violate PodSecurity' <<<"$SAMPLE_APPLY"; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

wait_docker() {
  lab_log "waiting for the Docker engine"
  for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && { lab_log "engine is back"; return 0; }; sleep 2; done
  return 1
}
restart_docker_desktop() {
  lab_log "restarting Docker Desktop (it re-reads the keychain only on restart)"
  if docker desktop version >/dev/null 2>&1; then
    docker desktop restart || return 1
  else
    osascript -e 'quit app "Docker"' || return 1
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 || break; sleep 2; done
    open -a Docker || return 1
  fi
  sleep 5; wait_docker
}

# Write a result into the Result column of the docs/09 §2 table (row "| S<n> |").
record() { # record S1 "✅ 2026-10-28 …"
  printf -v "RES_$1" '%s' "$2"
  [[ $RECORD -eq 1 && -w "$PLAN" ]] || return 0
  ROW="$1" TEXT="$2" python3 - "$PLAN" <<'PY'
import os, sys
p, row, text = sys.argv[1], os.environ["ROW"], os.environ["TEXT"]
lines = open(p, encoding="utf-8").read().split("\n")
for i, l in enumerate(lines):
    if l.startswith(f"| {row} |"):
        cells = l.split("|")
        if len(cells) >= 7:
            cells[4] = f" {text} "
            lines[i] = "|".join(cells)
        break
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
}
verdict() { # verdict S1 fails [note]
  local id="$1" n="$2" note="${3:-}"
  if (( n == 0 )); then record "$id" "✅ ${TODAY}${note:+ — $note}"; lab_log "$id PASSED"
  else record "$id" "❌ ${TODAY} — ${n} check(s) failed, log secrets/$(basename "$LOG")"; lab_warn "$id FAILED (${n}) — see the 'If it fails' column for $id in docs/09 §2"; fi
}

# ---- preflight ---------------------------------------------------------------------
cmd_preflight() {
  hdr "Preflight"; FAILS=0
  local t
  for t in docker k3d kubectl jq curl openssl python3; do chk "command $t" command -v "$t"; done
  chk "docker compose plugin"   docker compose version
  chk "Docker engine reachable" docker info
  docker info >/dev/null 2>&1 || { lab_warn "start Docker Desktop and re-run"; return 1; }

  warn_chk "docker context is desktop-linux (not colima/orbstack)" bash -c '[[ "$(docker context show)" == desktop-linux ]]'
  chk "engine is arm64"         bash -c '[[ "$(docker info --format "{{.Architecture}}")" =~ ^(aarch64|arm64)$ ]]'
  warn_chk "Docker Desktop memory ≥ ~12 GB (Settings → Resources)" bash -c '(( $(docker info --format "{{.MemTotal}}") >= 11*1024*1024*1024 ))'
  warn_chk "Docker Desktop CPUs ≥ 6"  bash -c '(( $(docker info --format "{{.NCPU}}") >= 6 ))'
  warn_chk "k3d is ${K3D_VERSION%.*}.x" bash -c "k3d version | grep -q 'k3d version v${K3D_VERSION%.*}\.'"

  # Harbor's dir must be shared with the Docker VM (Settings → Resources → File sharing; /Users is default).
  mkdir -p "$HARBOR_HOME"
  chk "file sharing covers $HARBOR_HOME" bash -c "docker run --rm -v '$HARBOR_HOME:/probe' alpine:3.20 sh -c 'touch /probe/.share-probe && rm /probe/.share-probe'"

  # Ports: Harbor 80/443, k3d API 6443, Traefik 8080/8443. Only a problem if something other than our stack holds them.
  local port owner
  for port in "$HARBOR_HTTP_PORT" "$HARBOR_HTTPS_PORT" "$K8S_API_HOST_PORT" "$TRAEFIK_HTTP_PORT" "$TRAEFIK_HTTPS_PORT"; do
    owner="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1}' | sort -u | tr '\n' ' ')"
    if [[ -z "$owner" || "$owner" =~ ^(com\.docke|com\.docker|docker|vpnkit) ]]; then printf '  \033[32mPASS\033[0m port %s free or Docker-owned\n' "$port"
    else printf '  \033[31mFAIL\033[0m port %s held by: %s (sudo lsof -iTCP:%s -sTCP:LISTEN)\n' "$port" "$owner" "$port"; FAILS=$((FAILS+1)); fi
  done

  # CA: reuse the Fusion lab's CA if it exists in another checkout, so keychain trust carries over.
  if [[ -s "$CA" ]]; then
    printf '  \033[32mPASS\033[0m lab CA present (%s)\n' "$(openssl x509 -in "$CA" -noout -subject | sed 's/.*CN *= *//')"
    warn_chk "lab CA trusted in System keychain (S1 offers to add it)" ca_in_keychain
  else
    printf '  \033[33mWARN\033[0m no secrets/certs/ca.crt yet — S1 creates a NEW CA.\n'
    printf '       To keep the Fusion lab CA (already trusted), copy that checkout'"'"'s secrets/ here first.\n'
  fi

  # /etc/hosts: the Fusion-era block points the name at the Harbor VM; S1 rewrites it to 127.0.0.1.
  if hosts_ok; then printf '  \033[32mPASS\033[0m /etc/hosts: %s → 127.0.0.1\n' "$HARBOR_HOST"
  elif grep -Eq "^[0-9.]+[[:space:]].*\b${HARBOR_HOST}\b" /etc/hosts; then
    printf '  \033[33mWARN\033[0m /etc/hosts points %s at the Fusion VM; S1 will repoint the Mac to 127.0.0.1\n' "$HARBOR_HOST"
    printf '       (the VMs keep their own /etc/hosts; rollback: docs/09 §4 "Rollback")\n'
  else printf '  \033[33mWARN\033[0m /etc/hosts has no %s line yet — S1 adds it\n' "$HARBOR_HOST"; fi

  (( FAILS == 0 )) && lab_log "preflight OK" || lab_warn "preflight: ${FAILS} blocking issue(s)"
  return $(( FAILS > 0 ))
}

# ---- S1: Harbor compose on Docker Desktop -------------------------------------------------
cmd_s1() {
  hdr "S1 — Harbor compose stack on Docker Desktop"; FAILS=0
  lab_docker_ok
  step "lab CA + Harbor server cert" "$LAB_ROOT/harbor/20-gen-certs.sh" || { verdict S1 "$FAILS"; return 1; }

  if ca_in_keychain; then lab_log "lab CA already trusted in the System keychain"
  elif confirm "Add the lab CA to the System keychain (sudo) and restart Docker Desktop?"; then
    step "trust lab CA (System keychain)" sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA" \
      && step "restart Docker Desktop" restart_docker_desktop || { verdict S1 "$FAILS"; return 1; }
  else lab_warn "CA not trusted — Harbor will install, but S2 (docker push) will fail with x509 until it is"; fi

  if hosts_ok; then lab_log "/etc/hosts already maps $HARBOR_HOST → 127.0.0.1"
  elif confirm "Rewrite the kubernetes-lab block in /etc/hosts to 127.0.0.1 $HARBOR_HOST (sudo)?"; then
    step "/etc/hosts entry" "$LAB_ROOT/scripts/hosts-entry.sh" --apply || { verdict S1 "$FAILS"; return 1; }
  else lab_warn "no hosts entry — the health check below will fail"; fi

  [[ -d "$HARBOR_HOME/data/registry" ]] && lab_log "note: $HARBOR_HOME/data already has registry data — reusing it (not a fresh install)"
  step "install Harbor ${HARBOR_VERSION} (${HARBOR_ARCH})" "$LAB_ROOT/harbor/30-install-harbor.sh" || { verdict S1 "$FAILS"; return 1; }

  lab_log "checks"
  # give containers still in 'starting' a moment
  for _ in $(seq 1 24); do
    docker compose --project-directory "$HARBOR_INSTALL_DIR" ps --format '{{.Health}}' | grep -q starting || break; sleep 5
  done
  chk "API healthy via ${HARBOR_HOST} (curl --cacert ca.crt)" harbor_healthy
  chk "TLS chain on 127.0.0.1:${HARBOR_HTTPS_PORT} verifies against lab CA" \
      bash -c "echo | openssl s_client -connect 127.0.0.1:${HARBOR_HTTPS_PORT} -servername ${HARBOR_HOST} -CAfile '$CA' 2>/dev/null | grep -q 'Verify return code: 0'"
  local c
  for c in nginx harbor-log harbor-core registry harbor-db trivy-adapter; do chk "container $c running" container_running "$c"; done
  chk "no Harbor container exited/unhealthy" bash -c "! docker compose --project-directory '$HARBOR_INSTALL_DIR' ps -a --format '{{.Name}} {{.State}} {{.Health}}' | grep -Ev ' running ?(healthy)?\$'"
  chk "log pipeline writes $HARBOR_HOME/log/core.log (else: json-file fallback)" test -s "$HARBOR_HOME/log/core.log"
  chk "nginx carries alias ${HARBOR_HOST} on ${HARBOR_NETWORK}" bash -c "docker inspect nginx --format '{{json .NetworkSettings.Networks}}' | grep -q '${HARBOR_HOST}'"
  chk "alias resolves + TLS from a container on ${HARBOR_NETWORK}" \
      docker run --rm --network "$HARBOR_NETWORK" -v "$CA:/ca.crt:ro" alpine:3.20 sh -c "apk add -q --no-cache curl >/dev/null && curl -fsS --cacert /ca.crt https://${HARBOR_HOST}/api/v2.0/health"
  verdict S1 "$FAILS" "scan checked in S2"
  return $(( FAILS > 0 ))
}

# ---- S2: engine push by hostname (+ scan) --------------------------------------------------
cmd_s2() {
  hdr "S2 — engine push by hostname"; FAILS=0
  lab_docker_ok
  harbor_healthy || lab_die "Harbor not healthy at $HARBOR_HOST — run s1 first"
  step "projects, proxy cache, robots (40-init-harbor.sh)" "$LAB_ROOT/harbor/40-init-harbor.sh" || { verdict S2 "$FAILS"; return 1; }

  local user tok
  user="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PUSH}.user" 'run harbor/40-init-harbor.sh')"
  tok="$(lab_secret "harbor-robot-${HARBOR_ROBOT_PUSH}.token" 'run harbor/40-init-harbor.sh')"

  lab_log "checks"
  chk "engine pulls ${PROXY_ALPINE} (CA trusted + proxy cache)" docker pull -q "$PROXY_ALPINE"
  chk "docker login as ${user}"  bash -c "printf '%s' '$tok' | docker login '$HARBOR_HOST' -u '$user' --password-stdin"
  chk "tag ${TEST_REPO}:${TEST_TAG}" docker tag "$PROXY_ALPINE" "${HARBOR_HOST}/${TEST_REPO}:${TEST_TAG}"
  chk "docker push ${HARBOR_HOST}/${TEST_REPO}:${TEST_TAG} over TLS" docker push -q "${HARBOR_HOST}/${TEST_REPO}:${TEST_TAG}"
  docker logout "$HARBOR_HOST" >/dev/null 2>&1

  # Auto-scan on push is on for the lab project; kick it if it hasn't started, then wait (first run downloads the Trivy DB).
  local proj="${TEST_REPO%%/*}" repo="${TEST_REPO#*/}" art status=""
  art="$API/projects/${proj}/repositories/${repo}/artifacts/${TEST_TAG}"
  lab_log "waiting for the Trivy scan of ${TEST_REPO}:${TEST_TAG} (up to 10 min on first run)"
  for i in $(seq 1 120); do
    status="$(hapi "${art}?with_scan_overview=true" 2>/dev/null | jq -r '[.scan_overview // {} | .[] | .scan_status][0] // "Not Scanned"')"
    [[ "$status" == "Success" || "$status" == "Error" ]] && break
    if [[ $i -eq 6 && "$status" == "Not Scanned" ]]; then hapi -X POST "${art}/scan" >/dev/null 2>&1 || true; fi
    sleep 5
  done
  chk "Trivy scan completed (status: ${status:-unknown})" test "$status" == "Success"
  if [[ "$status" == "Success" ]]; then
    hapi "${art}?with_scan_overview=true" | jq -r '[.scan_overview[]][0].summary.summary // {} | to_entries | map("\(.key)=\(.value)") | "  vulnerabilities: " + (join(" ") | if .=="" then "none" else . end)'
  fi
  verdict S2 "$FAILS" "push + scan"
  return $(( FAILS > 0 ))
}

# ---- S3: k3d nodes pull through Harbor ----------------------------------------------------
cmd_s3() {
  hdr "S3 — k3d nodes pull through Harbor"; FAILS=0
  lab_docker_ok; lab_need k3d "brew install k3d"; lab_need kubectl "brew install kubectl"
  harbor_healthy || lab_die "Harbor not healthy — run s1 first"
  [[ -s "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PULL}.token" ]] || lab_die "robot ${HARBOR_ROBOT_PULL} missing — run s2 (or harbor/40-init-harbor.sh) first"

  step "render secrets/registries.yaml" "$LAB_ROOT/k3s/10-render-registries.sh" || { verdict S3 "$FAILS"; return 1; }
  if cluster_exists; then lab_log "cluster $K3D_CLUSTER exists — reusing it"
  else step "create k3d cluster" "$LAB_ROOT/lab.sh" create-cluster || { verdict S3 "$FAILS"; return 1; }; fi
  step "namespaces (PSA labels)" $K apply -f "$LAB_ROOT/k3s/20-namespaces.yaml" || { verdict S3 "$FAILS"; return 1; }
  step "harbor-pull secrets" "$LAB_ROOT/k3s/50-pull-secrets.sh" || { verdict S3 "$FAILS"; return 1; }

  lab_log "checks"
  local want=$((K3D_SERVERS + K3D_AGENTS)) n
  chk "all nodes Ready"         $K wait --for=condition=Ready nodes --all --timeout=180s
  chk "$want nodes"             bash -c "[[ \$($K get nodes --no-headers | wc -l | tr -d ' ') -eq $want ]]"
  chk "kubelet is ${K3S_CHANNEL}.x" bash -c "$K get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | grep -q '^${K3S_CHANNEL}\.'"
  for n in $(k3d_nodes); do
    chk "hosts.toml for ${HARBOR_HOST} on $n" docker exec "$n" test -f "/var/lib/rancher/k3s/agent/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml"
  done
  chk "crictl pull ${PROXY_ALPINE} on ${K3D_SERVER_NODE}" docker exec "$K3D_SERVER_NODE" k3s crictl pull "$PROXY_ALPINE"
  chk "crictl pull on k3d-${K3D_CLUSTER}-agent-0"         docker exec "k3d-${K3D_CLUSTER}-agent-0" k3s crictl pull "$PROXY_ALPINE"
  chk "docker.io/library/busybox goes via the Harbor mirror" docker exec "k3d-${K3D_CLUSTER}-agent-1" k3s crictl pull docker.io/library/busybox:1.36
  chk "…and lands in Harbor's ${HARBOR_PROXY_PROJECT} cache" hapi -o /dev/null "$API/projects/${HARBOR_PROXY_PROJECT}/repositories/library%252Fbusybox"

  # The sample's image doesn't exist until CI builds it; swap in the proxy-cached alpine, same PSA-restricted spec.
  SAMPLE_APPLY="$($K kustomize "$LAB_ROOT/workflows/sample-deploy/overlays/lab" \
    | sed "s#image: ${HARBOR_HOST}/containerhelper/toolbox:latest#image: ${PROXY_ALPINE}#" \
    | $K apply -f - 2>&1)"; echo "$SAMPLE_APPLY" | sed 's/^/  /'
  chk "sample applies without PodSecurity violations" no_psa_violation
  chk "sample-deploy toolbox Running in ${SAMPLE_NS} (PSA restricted)" $K -n "$SAMPLE_NS" rollout status deploy/toolbox --timeout=180s
  chk "Traefik answers on localhost:${TRAEFIK_HTTP_PORT}" bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${TRAEFIK_HTTP_PORT}/) != 000 ]]"
  verdict S3 "$FAILS" "3 nodes, pulls + restricted pod"
  return $(( FAILS > 0 ))
}

# ---- S4: runner container --------------------------------------------------------------
cmd_s4() {
  hdr "S4 — runner container (runner-containerhelper)"; FAILS=0
  lab_docker_ok
  cluster_exists || lab_die "no cluster — run s3 first"
  local r="runner-containerhelper" tokf="$LAB_SECRETS/runner-token-containerhelper"
  local registered=0
  local vol="lab-runners_runner-containerhelper-home"
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    docker run --rm -v "$vol:/h:ro" alpine:3.20 test -f /h/.runner >/dev/null 2>&1 && registered=1
  fi
  if [[ ! -s "$tokf" && $registered -eq 0 ]]; then
    lab_warn "need a registration token (valid 1 h): GitHub → ${GH_OWNER}/${GH_REPOS[0]} → Settings → Actions → Runners"
    lab_warn "→ New self-hosted runner → Linux → ARM64, copy the --token value, then:"
    echo "    umask 077; echo '<token>' > secrets/runner-token-containerhelper; ./scripts/phase0-spikes.sh s4"
    return 1
  fi
  # compose wants both secret files to exist; the second runner is not started here (stale/empty is fine).
  [[ -e "$LAB_SECRETS/runner-token-devopshelpers" ]] || (umask 077; : > "$LAB_SECRETS/runner-token-devopshelpers")

  step "deployer RBAC" $K apply -f "$LAB_ROOT/k3s/30-deployer-rbac.yaml" || { verdict S4 "$FAILS"; return 1; }
  step "runner kubeconfig" "$LAB_ROOT/k3s/40-make-kubeconfig.sh" || { verdict S4 "$FAILS"; return 1; }
  step "build + start $r" docker compose -f "$RUNNER_COMPOSE" up -d --build "$r" || { verdict S4 "$FAILS"; return 1; }

  lab_log "waiting for 'Listening for Jobs'"
  for _ in $(seq 1 60); do docker logs "$r" 2>&1 | grep -q 'Listening for Jobs' && break; sleep 3; done

  lab_log "checks"
  chk "$r running"                       container_running "$r"
  chk "$r registered and listening"       bash -c "docker logs $r 2>&1 | grep -q 'Listening for Jobs'"
  chk "$r: docker socket usable"          docker exec "$r" docker version --format '{{.Server.Version}}'
  chk "$r: API via ${K3D_SERVER_NODE}:6443" docker exec "$r" kubectl get --raw /readyz
  chk "$r: deployer can create deployments" bash -c "docker exec $r kubectl -n containerhelper auth can-i create deployments | grep -q yes"
  chk "$r: Harbor over TLS (baked CA)"    docker exec "$r" curl -fsS "https://${HARBOR_HOST}/api/v2.0/health"
  chk "$r: tools present"                 docker exec "$r" sh -c 'command -v kubectl kustomize helm k9s yq jq trivy >/dev/null'

  if (( FAILS == 0 )); then
    record S4 "◐ ${TODAY} — container checks pass; run runner-smoke on GitHub"
    lab_log "last step is on GitHub: run the runner-smoke workflow (docs/05 §5) in ${GH_OWNER}/${GH_REPOS[0]}"
    if command -v gh >/dev/null 2>&1 && gh workflow view runner-smoke -R "${GH_OWNER}/${GH_REPOS[0]}" >/dev/null 2>&1; then
      confirm "Dispatch runner-smoke now with gh?" && gh workflow run runner-smoke -R "${GH_OWNER}/${GH_REPOS[0]}" \
        && lab_log "dispatched — watch: gh run watch -R ${GH_OWNER}/${GH_REPOS[0]}"
    fi
    lab_log "when it is green, change S4's Result in docs/09 §2 to ✅"
  else verdict S4 "$FAILS"; fi
  return $(( FAILS > 0 ))
}

# ---- cleanup -----------------------------------------------------------------------------
cmd_cleanup() {
  hdr "Cleanup (Harbor and the cluster stay)"
  if cluster_exists; then
    $K -n "$SAMPLE_NS" delete deploy/toolbox svc/toolbox --ignore-not-found
  fi
  if harbor_healthy; then
    hapi -X DELETE -o /dev/null "$API/projects/${TEST_REPO%%/*}/repositories/${TEST_REPO#*/}" 2>/dev/null \
      && lab_log "deleted ${TEST_REPO} from Harbor" || lab_log "${TEST_REPO} not in Harbor"
  fi
  docker image rm "${HARBOR_HOST}/${TEST_REPO}:${TEST_TAG}" >/dev/null 2>&1 || true
  lab_log "done"
}

summary() {
  hdr "Phase 0 summary"
  local id v
  for id in S1 S2 S3; do v="RES_$id"; printf '  %s  %s\n' "$id" "${!v:-not run}"; done
  if [[ "$RES_S1" == ✅* && "$RES_S2" == ✅* && "$RES_S3" == ✅* ]]; then
    lab_log "decision gate PASSED (S1–S3). Next: ./scripts/phase0-spikes.sh s4 when you have a runner token, then Phase 2."
  else
    lab_warn "decision gate not met — fix the failing spike and re-run it (each one is re-runnable)"; return 1
  fi
}

lab_log "log: $LOG"
rc=0
case "$CMD" in
  preflight) cmd_preflight || rc=1 ;;
  s1) cmd_s1 || rc=1 ;;
  s2) cmd_s2 || rc=1 ;;
  s3) cmd_s3 || rc=1 ;;
  s4) cmd_s4 || rc=1 ;;
  all)
    cmd_preflight || lab_die "fix preflight first"
    cmd_s1 && cmd_s2 && cmd_s3
    summary || rc=1 ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
exit "$rc"
