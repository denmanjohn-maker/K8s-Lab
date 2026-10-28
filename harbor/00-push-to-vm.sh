#!/usr/bin/env bash
# Run on the Mac once the Harbor VM is up and you can `ssh $VM_SSH_USER@$HARBOR_IP`.
# Generates the Harbor admin/DB passwords (once) and copies everything the VM-side
# scripts need to ~/lab on the VM:  lab-env.sh, harbor/, secrets/certs/, secrets/*.pw
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"
lab_need rsync "brew install rsync"
lab_need openssl "brew install openssl"

[[ -s "$LAB_CERTS/harbor.crt" ]] || lab_die "no server cert — run ./harbor/20-gen-certs.sh first"

umask 077
for f in harbor-admin.pw harbor-db.pw; do
  if [[ ! -s "$LAB_SECRETS/$f" ]]; then
    # alnum only: harbor.yml is YAML and the DB password is passed to postgres — keep it boring
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32 > "$LAB_SECRETS/$f"
    lab_log "generated $f"
  fi
done

TARGET="${VM_SSH_USER}@${HARBOR_IP}"
lab_log "syncing to ${TARGET}:~/lab"
ssh -o StrictHostKeyChecking=accept-new "$TARGET" 'mkdir -p ~/lab/secrets/certs && chmod 700 ~/lab/secrets'
rsync -az --delete "$LAB_ROOT/lab-env.sh" "$LAB_ROOT/harbor" "$TARGET:~/lab/"
rsync -az "$LAB_CERTS/ca.crt" "$LAB_CERTS/harbor.crt" "$LAB_CERTS/harbor.key" "$TARGET:~/lab/secrets/certs/"
rsync -az "$LAB_SECRETS/harbor-admin.pw" "$LAB_SECRETS/harbor-db.pw" "$TARGET:~/lab/secrets/"
ssh "$TARGET" 'chmod +x ~/lab/harbor/*.sh'

cat <<EOF

Now on the VM:
  ssh $TARGET
  ~/lab/harbor/10-bootstrap-vm.sh        # docker + compose + CA trust (log out/in afterwards for the docker group)
  ~/lab/harbor/30-install-harbor.sh      # download ${HARBOR_VERSION} (${HARBOR_ARCH}) and install with Trivy
Then back on the Mac:
  ./harbor/40-init-harbor.sh             # projects, proxy cache, robot accounts
EOF
