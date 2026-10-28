#!/usr/bin/env bash
# Print (default) or apply (--apply) the /etc/hosts lines every lab machine needs.
# Run on the Mac. To push to the VMs:  ./scripts/hosts-entries.sh --push
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

BEGIN="# >>> kubernetes-lab >>>"
END="# <<< kubernetes-lab <<<"

block() {
  echo "$BEGIN"
  printf '%-18s %s\n' "$HARBOR_IP"  "$HARBOR_HOST harbor"
  printf '%-18s %s\n' "$RUNNER_IP"  "$RUNNER_HOST runner"
  printf '%-18s %s\n' "$K3S_SERVER_IP" "k3s-server.${LAB_DOMAIN} k3s-server"
  local i=1
  for ip in "${K3S_AGENT_IPS[@]}"; do
    printf '%-18s %s\n' "$ip" "k3s-agent-${i}.${LAB_DOMAIN} k3s-agent-${i}"
    i=$((i+1))
  done
  echo "$END"
}

# Replace an existing block or append a new one; works on macOS and Linux.
apply_local() {
  local tmp; tmp="$(mktemp)"
  if grep -q "$BEGIN" /etc/hosts; then
    awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' /etc/hosts > "$tmp"
  else
    cat /etc/hosts > "$tmp"
  fi
  block >> "$tmp"
  sudo cp "$tmp" /etc/hosts && rm -f "$tmp"
  lab_log "/etc/hosts updated on $(hostname)"
}

push_remote() {
  local target="$1" user="$2"
  lab_log "pushing hosts block to ${user}@${target}"
  block | ssh -o StrictHostKeyChecking=accept-new "${user}@${target}" '
    set -e; B="# >>> kubernetes-lab >>>"; E="# <<< kubernetes-lab <<<"
    tmp=$(mktemp); cat > "$tmp.block"
    if grep -q "$B" /etc/hosts; then
      awk -v b="$B" -v e="$E" "\$0==b{skip=1} !skip{print} \$0==e{skip=0}" /etc/hosts > "$tmp"
    else cat /etc/hosts > "$tmp"; fi
    cat "$tmp.block" >> "$tmp"; sudo cp "$tmp" /etc/hosts; rm -f "$tmp" "$tmp.block"'
}

case "${1:-}" in
  --apply) apply_local ;;
  --push)
    apply_local
    push_remote "$K3S_SERVER_IP" "$K3S_SSH_USER"
    for ip in "${K3S_AGENT_IPS[@]}"; do push_remote "$ip" "$K3S_SSH_USER"; done
    push_remote "$HARBOR_IP" "$VM_SSH_USER" || lab_warn "Harbor VM not reachable yet (fine before docs/03)"
    push_remote "$RUNNER_IP" "$VM_SSH_USER" || lab_warn "runner VM not reachable yet (fine before docs/05)"
    ;;
  *) block ;;
esac
