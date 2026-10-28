#!/usr/bin/env bash
# Run ON the Harbor VM after 10-bootstrap-vm.sh.
# Downloads the Harbor offline installer for $HARBOR_VERSION/$HARBOR_ARCH, renders harbor.yml
# from the tarball's own template (so it tracks the version), installs certs, and runs
# install.sh --with-trivy. Re-running on an installed Harbor does a safe reconfigure
# (prepare + compose up), which is also how you apply harbor.yml changes.
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

INSTALL_DIR=/opt/harbor
CERT_DIR=/etc/harbor/certs
DL_DIR="$HOME/lab/downloads"
mkdir -p "$DL_DIR"

command -v docker >/dev/null || lab_die "docker missing — run 10-bootstrap-vm.sh"
docker compose version >/dev/null 2>&1 || lab_die "docker compose plugin missing (or log out/in for the docker group)"
ADMIN_PW="$(lab_secret harbor-admin.pw 'run harbor/00-push-to-vm.sh from the Mac')"
DB_PW="$(lab_secret harbor-db.pw 'run harbor/00-push-to-vm.sh from the Mac')"

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

# md5sum file lists every asset; verify ours if we can fetch it.
if curl -fsSL -o "$DL_DIR/md5sum" "${BASE}/md5sum" 2>/dev/null; then
  if grep -q "$TGZ" "$DL_DIR/md5sum"; then
    (cd "$DL_DIR" && grep "$TGZ" md5sum | md5sum -c -) || lab_die "md5 mismatch on $TGZ"
    lab_log "checksum OK"
  fi
fi

# ---- 2. unpack ---------------------------------------------------------------
if [[ ! -x "$INSTALL_DIR/install.sh" ]]; then
  lab_log "unpacking to $INSTALL_DIR"
  sudo mkdir -p "$INSTALL_DIR"
  sudo tar -xzf "$DL_DIR/$TGZ" -C "$(dirname "$INSTALL_DIR")"   # tarball root is 'harbor/'
  sudo chown -R root:root "$INSTALL_DIR"
fi

# ---- 3. certs ----------------------------------------------------------------
lab_log "installing TLS cert/key to $CERT_DIR"
sudo mkdir -p "$CERT_DIR"
sudo install -m 644 "$LAB_CERTS/harbor.crt" "$CERT_DIR/harbor.crt"
sudo install -m 600 "$LAB_CERTS/harbor.key" "$CERT_DIR/harbor.key"
sudo install -m 644 "$LAB_CERTS/ca.crt"     "$CERT_DIR/ca.crt"
# Let the local docker CLI trust Harbor too (handy for `docker login` tests on this box).
sudo mkdir -p "/etc/docker/certs.d/${HARBOR_HOST}"
sudo install -m 644 "$LAB_CERTS/ca.crt" "/etc/docker/certs.d/${HARBOR_HOST}/ca.crt"

# ---- 4. harbor.yml -------------------------------------------------------------
# Start from the shipped template every time so new keys appear; then patch the handful we own.
lab_log "rendering harbor.yml from harbor.yml.tmpl"
sudo cp "$INSTALL_DIR/harbor.yml.tmpl" "$INSTALL_DIR/harbor.yml"
sudo sed -i \
  -e "s|^hostname: .*|hostname: ${HARBOR_HOST}|" \
  -e "s|^  certificate: .*|  certificate: ${CERT_DIR}/harbor.crt|" \
  -e "s|^  private_key: .*|  private_key: ${CERT_DIR}/harbor.key|" \
  -e "s|^harbor_admin_password: .*|harbor_admin_password: ${ADMIN_PW}|" \
  -e "0,/^  password: .*/s|^  password: .*|  password: ${DB_PW}|" \
  -e "s|^data_volume: .*|data_volume: /data|" \
  "$INSTALL_DIR/harbor.yml"
# Trivy: scan unfixed too (you want to see them), keep DB fresh from GHCR.
sudo sed -i -e "s|^  ignore_unfixed: .*|  ignore_unfixed: false|" "$INSTALL_DIR/harbor.yml"
sudo chmod 600 "$INSTALL_DIR/harbor.yml"

# Sanity: the values we care about landed.
grep -E '^(hostname|data_volume):|^  (certificate|private_key):' "$INSTALL_DIR/harbor.yml" | sed 's/^/  /'

# ---- 5. install / reconfigure --------------------------------------------------------
cd "$INSTALL_DIR"
if [[ -s docker-compose.yml ]] && sudo docker compose ps --status running 2>/dev/null | grep -q harbor-core; then
  lab_log "Harbor already running — applying config (prepare + compose up)"
  sudo ./prepare --with-trivy
  sudo docker compose down
  sudo docker compose up -d
else
  lab_log "running install.sh --with-trivy (loads images from the tarball, ~2-4 min)"
  sudo ./install.sh --with-trivy
fi

# ---- 6. wait + report ---------------------------------------------------------------
lab_log "waiting for https://${HARBOR_HOST}/api/v2.0/health"
for _ in $(seq 1 60); do
  if curl -fsS --cacert "$CERT_DIR/ca.crt" --resolve "${HARBOR_HOST}:443:127.0.0.1" \
       "https://${HARBOR_HOST}/api/v2.0/health" | jq -e '.status=="healthy"' >/dev/null 2>&1; then
    lab_log "Harbor is healthy"; break
  fi
  sleep 5
done
sudo docker compose ps --format 'table {{.Name}}\t{{.Status}}'

cat <<EOF

Harbor ${HARBOR_VERSION} installed.
  UI:        https://${HARBOR_HOST}/   (admin / \$(cat ~/lab/secrets/harbor-admin.pw))
  manage:    cd ${INSTALL_DIR} && sudo docker compose [ps|logs -f|down|up -d]
  reconfig:  edit this script's sed block or ${INSTALL_DIR}/harbor.yml, then re-run this script
Next, on the Mac:  ./harbor/40-init-harbor.sh
EOF
