#!/usr/bin/env bash
# Print (default) or apply (--apply) the one /etc/hosts line the Mac needs: Harbor's hostname -> 127.0.0.1,
# where Docker Desktop publishes Harbor's port 443. Inside Docker the same name is a network alias
# (harbor/docker-compose.override.yml.template), so nothing else needs a hosts entry.
set -euo pipefail
# shellcheck source=../lab-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab-env.sh"

BEGIN="# >>> kubernetes-lab >>>"
END="# <<< kubernetes-lab <<<"

block() {
  echo "$BEGIN"
  printf '%-18s %s\n' "127.0.0.1" "$HARBOR_HOST harbor"
  echo "$END"
}

# Replace an existing block (including the old Fusion-era VM lines) or append a new one.
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

case "${1:-}" in
  --apply) apply_local ;;
  *) block ;;
esac
