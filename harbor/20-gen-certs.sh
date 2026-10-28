#!/usr/bin/env bash
# Run on the Mac. Creates the lab CA (once) and the Harbor server certificate.
#   ./harbor/20-gen-certs.sh          # create CA if missing, create server cert if missing
#   ./harbor/20-gen-certs.sh --renew  # keep CA, re-issue the server cert (e.g. IP/hostname changed)
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
  lab_log "issuing server cert for ${HARBOR_HOST} / ${HARBOR_IP} (2y)"
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
IP.1=${HARBOR_IP}
EOF
  openssl x509 -req -sha512 -days 730 -extfile harbor.ext -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in harbor.csr -out harbor.crt
  rm -f harbor.csr harbor.ext
  chmod 644 harbor.crt
fi

# Docker (the daemon on the runner/Harbor VM) wants the server cert in .cert form too.
openssl x509 -inform PEM -in harbor.crt -out harbor.cert

lab_log "done:"
openssl x509 -in harbor.crt -noout -subject -ext subjectAltName -enddate | sed 's/^/  /'
cat <<EOF

Next:
  1. Trust the CA on this Mac (optional, lets Safari/curl hit the Harbor UI cleanly):
       sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$LAB_CERTS/ca.crt"
  2. ./harbor/00-push-to-vm.sh   (after the Harbor VM exists — docs/03)
EOF
