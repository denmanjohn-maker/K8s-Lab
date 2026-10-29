#!/usr/bin/env bash
# install.sh — the whole lab on a fresh Mac in one run: tools, CA, Harbor, k3d cluster, GitHub runners, verify.
# Idempotent: every stage checks what already exists, so re-run it after fixing anything.
#   ./install.sh                   all stages in order
#   ./install.sh --from cluster    start at a stage   (stages: tools certs hosts harbor cluster github runners verify)
#   ./install.sh --only github     run one stage
#   ./install.sh --skip-github     don't use `gh`: paste the runner registration tokens when asked
#   ./install.sh --yes             never prompt; with missing tokens it stops before the runners stage
# Needs: macOS with Homebrew. sudo is used twice: trusting the lab CA (keychain) and the /etc/hosts line.
set -euo pipefail
# shellcheck source=lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab-env.sh"

STAGES=(tools certs hosts harbor cluster github runners verify)
FROM=""; ONLY=""; SKIP_GITHUB=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --skip-github) SKIP_GITHUB=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) lab_die "unknown option: $1 (try --help)" ;;
  esac
done
for s in "$FROM" "$ONLY"; do
  [[ -z "$s" ]] || printf '%s\n' "${STAGES[@]}" | grep -qx "$s" || lab_die "unknown stage '$s' — one of: ${STAGES[*]}"
done
[[ "$(uname -s)" == "Darwin" ]] || lab_die "this installer is for macOS with Docker Desktop"
cd "$LAB_ROOT"

# ---- helpers -----------------------------------------------------------------
docker_wait() { local i; for i in $(seq 1 90); do docker info >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
docker_restart() {
  lab_log "restarting Docker Desktop so its engine rebuilds the CA bundle from the keychain"
  osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
  local i; for i in $(seq 1 30); do docker info >/dev/null 2>&1 || break; sleep 2; done
  open -a Docker
  docker_wait || lab_die "Docker Desktop did not come back — open it by hand, then re-run"
}
harbor_healthy() { curl -fsS --cacert "$LAB_CERTS/ca.crt" "https://${HARBOR_HOST}/api/v2.0/health" 2>/dev/null | grep -q '"healthy"'; }
cluster_exists() { k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$K3D_CLUSTER"; }
runner_registered() { docker exec "runner-$1" test -f /home/runner/.runner >/dev/null 2>&1; }
token_fresh() { [[ -s "$1" ]] && [[ -n "$(find "$1" -mmin -50 2>/dev/null)" ]]; }
gh_ok() { (( SKIP_GITHUB == 0 )) && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }
banner() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

# ---- 1. tools ----------------------------------------------------------------
stage_tools() {
  command -v brew >/dev/null 2>&1 || lab_die "Homebrew is missing — install it from https://brew.sh and re-run"
  local pkgs=() f
  for f in k3d kubectl jq gh; do command -v "$f" >/dev/null 2>&1 || pkgs+=("$f"); done
  command -v k9s >/dev/null 2>&1 || pkgs+=(derailed/k9s/k9s)
  if (( ${#pkgs[@]} )); then lab_log "brew install ${pkgs[*]}"; brew install "${pkgs[@]}"; fi
  if [[ ! -d /Applications/Docker.app ]]; then
    lab_log "installing Docker Desktop (brew cask)"; brew install --cask docker
  fi
  if ! docker info >/dev/null 2>&1; then
    lab_log "starting Docker Desktop (first start asks for your password and shows a licence dialog)"
    open -a Docker; docker_wait || lab_die "Docker engine not reachable — finish Docker Desktop's first-run dialogs, then re-run"
  fi
  docker compose version >/dev/null 2>&1 || lab_die "docker compose plugin missing (ships with Docker Desktop)"
  local mem; mem="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  if (( mem < 11 * 1024 * 1024 * 1024 )); then
    lab_warn "Docker Desktop VM has $(( mem / 1024 / 1024 / 1024 )) GB — set 12 GB / 6 CPU under Settings → Resources (docs/02 §5)"
  fi
  lab_log "tools OK: $(docker version --format 'engine {{.Server.Version}}'), k3d $(k3d version 2>/dev/null | head -1 | awk '{print $3}'), kubectl $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)"
}

# ---- 2. certs ----------------------------------------------------------------
stage_certs() {
  ./harbor/20-gen-certs.sh
  local kc=/Library/Keychains/System.keychain want have
  want="$(openssl x509 -in "$LAB_CERTS/ca.crt" -noout -fingerprint -sha256)"
  have="$(security find-certificate -c "Kubernetes Lab CA" -p "$kc" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
  if [[ "$want" == "$have" ]]; then lab_log "lab CA already trusted in the System keychain"; return; fi
  if [[ -n "$have" ]]; then
    lab_log "replacing an older 'Kubernetes Lab CA' in the keychain"
    sudo security delete-certificate -c "Kubernetes Lab CA" "$kc"
  fi
  lab_log "trusting the lab CA (sudo)"
  sudo security add-trusted-cert -d -r trustRoot -k "$kc" "$LAB_CERTS/ca.crt"
  docker_restart
}

# ---- 3. hosts ----------------------------------------------------------------
stage_hosts() {
  if grep -qE "^127\.0\.0\.1[[:space:]].*(^|[[:space:]])${HARBOR_HOST}([[:space:]]|$)" /etc/hosts; then
    lab_log "/etc/hosts already maps ${HARBOR_HOST} to 127.0.0.1"
  else
    lab_log "adding ${HARBOR_HOST} to /etc/hosts (sudo)"; ./scripts/hosts-entry.sh --apply
  fi
}

# ---- 4. harbor ---------------------------------------------------------------
stage_harbor() {
  if harbor_healthy; then
    lab_log "Harbor already healthy at https://${HARBOR_HOST} — skipping install (re-run harbor/30-install-harbor.sh to reconfigure)"
  else
    ./harbor/30-install-harbor.sh
    harbor_healthy || lab_die "Harbor is not healthy after install — docs/08 §1"
  fi
  ./harbor/40-init-harbor.sh            # idempotent: projects, proxy cache, robots
}

# ---- 5. cluster --------------------------------------------------------------
stage_cluster() {
  [[ -s "$LAB_SECRETS/registries.yaml" ]] || ./k3s/10-render-registries.sh
  local fresh=0
  if cluster_exists; then
    lab_log "cluster ${K3D_CLUSTER} exists"; k3d cluster start "$K3D_CLUSTER" >/dev/null 2>&1 || true
  else
    ./lab.sh create-cluster; fresh=1
  fi
  kubectl --context "$K3D_CONTEXT" apply -f k3s/20-namespaces.yaml -f k3s/30-deployer-rbac.yaml
  ./k3s/50-pull-secrets.sh
  if (( fresh )) || [[ ! -s "$LAB_SECRETS/kubeconfig-gha-deployer.yaml" ]]; then ./k3s/40-make-kubeconfig.sh; fi
}

# ---- 6. github ---------------------------------------------------------------
stage_github() {
  local entry repo slug f missing=0
  umask 077
  if gh_ok; then
    lab_log "gh is authenticated as $(gh api user --jq .login 2>/dev/null || echo '?') — setting repo secrets and runner tokens"
    for f in user token; do
      [[ -s "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.${f}" ]] || lab_die "secrets/harbor-robot-${HARBOR_ROBOT_PUSH}.${f} missing — ./install.sh --only harbor"
    done
  else
    lab_warn "gh not available/authenticated (or --skip-github): Harbor robot secrets and runner tokens are manual (docs/05 §4, docs/06 §1)"
  fi
  for entry in "${RUNNER_REPOS[@]}"; do
    repo="${entry%%:*}"; slug="${entry##*:}"; f="$LAB_SECRETS/runner-token-${slug}"
    if gh_ok; then
      gh secret set HARBOR_ROBOT_USER  -R "${GH_OWNER}/${repo}" < "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.user"
      gh secret set HARBOR_ROBOT_TOKEN -R "${GH_OWNER}/${repo}" < "$LAB_SECRETS/harbor-robot-${HARBOR_ROBOT_PUSH}.token"
      lab_log "  ${repo}: HARBOR_ROBOT_USER/TOKEN set"
    fi
    if runner_registered "$slug"; then lab_log "  ${repo}: runner-${slug} already registered"; : > "$f"; continue; fi
    if token_fresh "$f"; then lab_log "  ${repo}: registration token on file (fresh)"; continue; fi
    if gh_ok; then
      gh api -X POST "repos/${GH_OWNER}/${repo}/actions/runners/registration-token" --jq .token > "$f"
      lab_log "  ${repo}: registration token fetched → secrets/runner-token-${slug}"
    elif (( YES )); then
      missing=1; : > "$f"
      lab_warn "  ${repo}: no token. GitHub → https://github.com/${GH_OWNER}/${repo}/settings/actions/runners/new → paste it into secrets/runner-token-${slug}"
    else
      echo "  ${repo}: open https://github.com/${GH_OWNER}/${repo}/settings/actions/runners/new (Linux / ARM64) and copy the --token value"
      local t; read -rs -p "  registration token for ${repo}: " t; echo
      [[ -n "$t" ]] || lab_die "empty token"
      printf '%s\n' "$t" > "$f"
    fi
  done
  (( missing == 0 )) || lab_die "fill in the token files above, then: ./install.sh --from runners"
}

# ---- 7. runners --------------------------------------------------------------
stage_runners() {
  [[ -s "$LAB_SECRETS/kubeconfig-gha-deployer.yaml" ]] || lab_die "secrets/kubeconfig-gha-deployer.yaml missing — ./install.sh --only cluster"
  local entry slug; for entry in "${RUNNER_REPOS[@]}"; do slug="${entry##*:}"; [[ -e "$LAB_SECRETS/runner-token-${slug}" ]] || : > "$LAB_SECRETS/runner-token-${slug}"; done
  docker compose -f "$RUNNER_COMPOSE" up -d --build
  for entry in "${RUNNER_REPOS[@]}"; do
    slug="${entry##*:}"
    lab_log "waiting for runner-${slug} to connect to GitHub"
    local i ok=0
    for i in $(seq 1 60); do
      if docker logs "runner-${slug}" 2>&1 | grep -q "Listening for Jobs"; then ok=1; break; fi
      docker inspect -f '{{.State.Running}}' "runner-${slug}" 2>/dev/null | grep -q true || break
      sleep 5
    done
    if (( ok )); then lab_log "  runner-${slug}: Listening for Jobs"
    else lab_warn "  runner-${slug}: not listening yet — docker logs runner-${slug} (expired token? docs/08 §3)"; fi
  done
}

# ---- 8. verify ---------------------------------------------------------------
stage_verify() { ./scripts/verify.sh --quick; }

# ---- run ---------------------------------------------------------------------
sudo -v 2>/dev/null || true          # cache sudo credentials once (keychain + /etc/hosts)
run=0
for s in "${STAGES[@]}"; do
  if [[ -n "$ONLY" ]]; then [[ "$s" == "$ONLY" ]] || continue
  else [[ -z "$FROM" || $run -eq 1 || "$s" == "$FROM" ]] && run=1 || continue; fi
  banner "$s"
  "stage_$s"
done

banner "done"
cat <<EOF
  Harbor:    https://${HARBOR_HOST}/   admin / \$(cat secrets/harbor-admin.pw)
  Cluster:   kubectl --context ${K3D_CONTEXT} get nodes     Traefik: http://localhost:${TRAEFIK_HTTP_PORT}
  Runners:   $(for e in "${RUNNER_REPOS[@]}"; do printf 'runner-%s ' "${e##*:}"; done)(label: ${RUNNER_LABEL})
  Day-2:     ./lab.sh status | up | stop | reset        Smoke test: ./scripts/verify.sh
  Still manual: copy workflows/*.yml into each repo as .github/workflows/lab-build-deploy.yml (docs/06 §1)
EOF
if ! gh_ok; then echo "  Tip: 'gh auth login' lets ./install.sh --only github set the repo secrets and fetch runner tokens for you."; fi
