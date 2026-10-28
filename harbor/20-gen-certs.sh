#!/usr/bin/env bash
# Run on the Mac. Creates the lab CA (once) and the Harbor server certificate.
#   ./harbor/20-gen-certs.sh          # create CA if missing, create server cert if missing
#   ./harbor/20-gen-certs.sh --renew  # keep CA, re-issue the server cert (expiry, hostname change)
# SANs: the hostname (Mac + docker network alias), "harbor" and "nginx" (compose names), localhost/127.0.0.1
# (the Mac's /etc/hosts points the hostname at 127.0.0.1, and the published port lives there).
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need openssl "brew install openssl"

cd "$LAB_CERTS"
umask 077

if [[ ! -s ca.key ]]; then
  lab_log "creating lab CA (10y) -> $LAB_CERTS/ca.{key,crt}"
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -sha512 -days 3650 -key ca.key -out ca.crt \
    -subj "/C=US/ST=Texas/L=Houston/O=jdtechprojects lab/CN=Kubernetes Lab CA"
  chmod 644 ca.crt
else
  lab_log "CA already exists, reusing"
fi

if [[ -s harbor.crt && "${1:-}" != "--renew" ]]; then
  lab_log "harbor.crt exists; pass --renew to re-issue"
else
  lab_log "issuing server cert for ${HARBOR_HOST} (2y)"
  openssl genrsa -out harbor.key 4096
  openssl req -new -sha512 -key harbor.key -out harbor.csr \
    -subj "/C=US/ST=Texas/L=Houston/O=jdtechprojects lab/CN=${HARBOR_HOST}"
  cat > harbor.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=${HARBOR_HOST}
DNS.2=harbor
DNS.3=nginx
DNS.4=localhost
IP.1=127.0.0.1
EOF
  openssl x509 -req -sha512 -days 730 -extfile harbor.ext -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in harbor.csr -out harbor.crt
  rm -f harbor.csr harbor.ext
  chmod 644 harbor.crt
fi

lab_log "done:"
openssl x509 -in harbor.crt -noout -subject -ext subjectAltName -enddate | sed 's/^/  /'
cat <<EOF

Next:
  1. Trust the CA on this Mac. Docker Desktop's engine reads the keychain, so this is REQUIRED for
     docker push to Harbor (restart Docker Desktop afterwards — docs/04 §3):
       sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$LAB_CERTS/ca.crt"
  2. ./scripts/hosts-entry.sh --apply     (127.0.0.1 ${HARBOR_HOST})
  3. ./harbor/30-install-harbor.sh        (docs/03)
EOF
