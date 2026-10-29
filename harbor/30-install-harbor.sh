#!/usr/bin/env bash
# Run on the Mac (Docker Desktop running). Downloads the Harbor offline installer for
# $HARBOR_VERSION/$HARBOR_ARCH into $HARBOR_HOME, renders harbor.yml from the tarball's own template
# (so it tracks the version), installs certs, adds the compose override (network alias), and runs
# install.sh --with-trivy. Re-running on an installed Harbor does a safe reconfigure (prepare +
# compose up), which is also how you apply harbor.yml changes. Idempotent.
#
# Layout under $HARBOR_HOME (default ~/Lab/harbor — NOT in iCloud Drive):
#   harbor/      unpacked installer: harbor.yml, docker-compose.yml, common/      (= HARBOR_INSTALL_DIR)
#   data/        registry blobs, Postgres, Valkey, Trivy DB, secret key           (= harbor.yml data_volume)
#   log/         Harbor's log files                                               (= harbor.yml log.local.location)
#   certs/       harbor.crt / harbor.key / ca.crt
#   downloads/   installer tarballs
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need docker "install Docker Desktop"; lab_need curl ""; lab_need jq "brew install jq"; lab_need openssl "brew install openssl"
lab_docker_ok
docker compose version >/dev/null 2>&1 || lab_die "docker compose plugin missing (ships with Docker Desktop)"

case "$HARBOR_HOME" in
  *"Mobile Documents"*|*CloudDocs*) lab_die "HARBOR_HOME=$HARBOR_HOME is inside iCloud Drive — registry data must not sync. Set HARBOR_HOME in lab-env.sh" ;;
esac
INSTALL_DIR="$HARBOR_INSTALL_DIR"
DATA_DIR="$HARBOR_HOME/data"
LOG_DIR="$HARBOR_HOME/log"
CERT_DIR="$HARBOR_HOME/certs"
DL_DIR="$HARBOR_HOME/downloads"
mkdir -p "$HARBOR_HOME" "$DATA_DIR" "$LOG_DIR" "$CERT_DIR" "$DL_DIR"
[[ -s "$LAB_CERTS/harbor.crt" && -s "$LAB_CERTS/harbor.key" ]] || lab_die "certs missing — ./harbor/20-gen-certs.sh"

# ---- 0. passwords (generated once, kept in secrets/) ----------------------------------
umask 077
for s in harbor-admin.pw harbor-db.pw; do
  if [[ ! -s "$LAB_SECRETS/$s" ]]; then
    openssl rand -base64 24 | tr -d '/+=' | cut -c1-24 > "$LAB_SECRETS/$s"
    lab_log "generated secrets/$s"
  fi
done
ADMIN_PW="$(lab_secret harbor-admin.pw '')"
DB_PW="$(lab_secret harbor-db.pw '')"
umask 022

# ---- 1. download ---------------------------------------------------------------
# 2.16.0-rc1 ships per-arch tarballs (…-arm64.tgz). Fall back to the un-suffixed name
# in case GA goes back to a single multi-arch tarball.
BASE="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}"
TGZ=""
for cand in "harbor-offline-installer-${HARBOR_VERSION}-${HARBOR_ARCH}.tgz" "harbor-offline-installer-${HARBOR_VERSION}.tgz"; do
  if [[ -s "$DL_DIR/$cand" ]]; then TGZ="$cand"; break; fi
  lab_log "trying ${BASE}/${cand}"
  if curl -fL --retry 3 -o "$DL_DIR/$cand.part" "${BASE}/${cand}"; then
    mv "$DL_DIR/$cand.part" "$DL_DIR/$cand"; TGZ="$cand"; break
  fi
  rm -f "$DL_DIR/$cand.part"
done
[[ -n "$TGZ" ]] || lab_die "could not download a Harbor installer for ${HARBOR_VERSION}/${HARBOR_ARCH}"

# md5sum file lists every asset; verify ours if we can fetch it (openssl: works on macOS and Linux).
if curl -fsSL -o "$DL_DIR/md5sum" "${BASE}/md5sum" 2>/dev/null && grep -q "$TGZ" "$DL_DIR/md5sum"; then
  expected="$(grep "$TGZ" "$DL_DIR/md5sum" | awk '{print $1}')"
  actual="$(openssl dgst -md5 -r "$DL_DIR/$TGZ" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || lab_die "md5 mismatch on $TGZ"
  lab_log "checksum OK"
fi

# ---- 2. unpack ---------------------------------------------------------------
if [[ ! -x "$INSTALL_DIR/install.sh" ]]; then
  lab_log "unpacking to $INSTALL_DIR"
  tar -xzf "$DL_DIR/$TGZ" -C "$HARBOR_HOME"          # tarball root is 'harbor/'
fi

# ---- 3. certs ----------------------------------------------------------------
lab_log "installing TLS cert/key to $CERT_DIR"
install -m 644 "$LAB_CERTS/harbor.crt" "$CERT_DIR/harbor.crt"
install -m 600 "$LAB_CERTS/harbor.key" "$CERT_DIR/harbor.key"
install -m 644 "$LAB_CERTS/ca.crt"     "$CERT_DIR/ca.crt"

# ---- 4. harbor.yml -------------------------------------------------------------
# Start from the shipped template every time so new keys appear; then patch the handful we own.
# (python rather than sed: BSD sed has no "first match only" address, and -i differs from GNU sed.)
lab_log "rendering harbor.yml from harbor.yml.tmpl"
cp "$INSTALL_DIR/harbor.yml.tmpl" "$INSTALL_DIR/harbor.yml"
HARBOR_YML="$INSTALL_DIR/harbor.yml" CERT_DIR="$CERT_DIR" DATA_DIR="$DATA_DIR" LOG_DIR="$LOG_DIR" \
ADMIN_PW="$ADMIN_PW" DB_PW="$DB_PW" HTTP_PORT="$HARBOR_HTTP_PORT" HTTPS_PORT="$HARBOR_HTTPS_PORT" \
python3 - <<'PY'
import os, re
p = os.environ["HARBOR_YML"]
lines = open(p).read().split("\n")
def set_first(pattern, value, start=0):
    rx = re.compile(pattern)
    for i in range(start, len(lines)):
        if rx.match(lines[i]):
            indent = re.match(r"\s*", lines[i]).group(0)
            lines[i] = f"{indent}{value}"
            return i
    raise SystemExit(f"harbor.yml: no line matches {pattern!r}")
set_first(r"^hostname:", f"hostname: {os.environ['HARBOR_HOST']}")
set_first(r"^  port: 80\b",  f"port: {os.environ['HTTP_PORT']}")
i = set_first(r"^https:", "https:")
set_first(r"^  port: 443\b",   f"port: {os.environ['HTTPS_PORT']}", i)
set_first(r"^  certificate:",  f"certificate: {os.environ['CERT_DIR']}/harbor.crt", i)
set_first(r"^  private_key:",  f"private_key: {os.environ['CERT_DIR']}/harbor.key", i)
set_first(r"^harbor_admin_password:", f"harbor_admin_password: {os.environ['ADMIN_PW']}")
i = set_first(r"^database:", "database:")
set_first(r"^  password:", f"password: {os.environ['DB_PW']}", i)
set_first(r"^data_volume:", f"data_volume: {os.environ['DATA_DIR']}")
i = set_first(r"^trivy:", "trivy:")
set_first(r"^  ignore_unfixed:", "ignore_unfixed: false", i)      # scan unfixed too (you want to see them)
i = set_first(r"^log:", "log:")
i = set_first(r"^  local:", "local:", i)
set_first(r"^    location:", f"location: {os.environ['LOG_DIR']}", i)   # /var/log is not shared with Docker Desktop
open(p, "w").write("\n".join(lines))
PY
chmod 600 "$INSTALL_DIR/harbor.yml"
grep -E '^(hostname|data_volume):|^  (certificate|private_key):|^    location:' "$INSTALL_DIR/harbor.yml" | sed 's/^/  /'

# ---- 5. compose override: DNS alias so k3d nodes and runners reach nginx as $HARBOR_HOST ----
lab_render "$LAB_ROOT/harbor/docker-compose.override.yml.template" > "$INSTALL_DIR/docker-compose.override.yml"

# ---- 6. install / reconfigure --------------------------------------------------------
# Same steps as Harbor's own install.sh (load images → prepare → compose up), done here so that:
#   - re-runs skip the 2-minute image load when the images are already present,
#   - the existing stack is stopped, not `down`ed (k3d nodes may be attached to the harbor network),
#   - the Docker Desktop bind-mount quirk below can be worked around between prepare and up.
cd "$INSTALL_DIR"
IMG_TAG="$(grep -o 'goharbor/prepare:[^ "]*' prepare | head -1 | cut -d: -f2)"
if [[ -z "$IMG_TAG" ]] || ! docker image inspect "goharbor/prepare:${IMG_TAG}" >/dev/null 2>&1; then
  lab_log "loading Harbor images from the tarball (~2 min)"
  docker load -i ./harbor*.tar.gz
fi
lab_log "rendering Harbor's compose file and configs (prepare --with-trivy)"
./prepare --with-trivy
# Docker Desktop (VirtioFS) fails the first time a file is bind-mounted into a directory that is itself a
# bind mount, unless the mountpoint already exists on the host (docker/for-mac#7853). Harbor's registry
# mounts data/secret/registry/root.crt at /etc/registry/root.crt under the ./common/config/registry/
# mount, and prepare regenerates that directory — so recreate the mountpoint after every prepare.
touch common/config/registry/root.crt
if [[ -n "$(docker compose ps -aq 2>/dev/null)" ]]; then
  lab_log "stopping the existing Harbor containers before applying the new config"
  docker compose stop
fi
lab_log "docker compose up -d"
docker compose up -d

# ---- 7. wait + report ---------------------------------------------------------------
lab_log "waiting for https://${HARBOR_HOST}:${HARBOR_HTTPS_PORT}/api/v2.0/health"
for _ in $(seq 1 60); do
  if curl -fsS --cacert "$CERT_DIR/ca.crt" --resolve "${HARBOR_HOST}:${HARBOR_HTTPS_PORT}:127.0.0.1" \
       "https://${HARBOR_HOST}:${HARBOR_HTTPS_PORT}/api/v2.0/health" | jq -e '.status=="healthy"' >/dev/null 2>&1; then
    lab_log "Harbor is healthy"; break
  fi
  sleep 5
done
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
docker network inspect "$HARBOR_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q nginx \
  || lab_warn "nginx is not on $HARBOR_NETWORK — check docker-compose.override.yml"

cat <<EOF

Harbor ${HARBOR_VERSION} installed.
  UI:        https://${HARBOR_HOST}/   (admin / \$(cat secrets/harbor-admin.pw))
  manage:    docker compose --project-directory "${INSTALL_DIR}" [ps|logs -f|stop|up -d]
  reconfig:  edit this script's patch block or ${INSTALL_DIR}/harbor.yml, then re-run this script
Next:  ./harbor/40-init-harbor.sh   (skip after a restore from backup — docs/07 §3)
EOF
