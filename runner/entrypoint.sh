#!/usr/bin/env bash
# Entrypoint of the lab runner container. Registers the runner with GitHub once (config.sh), then
# runs it in the foreground (run.sh). /home/runner is a named volume, so .runner/.credentials and
# _work survive restarts and the one-hour registration token is only needed the first time.
#   RUNNER_URL         https://github.com/<owner>/<repo>  (or https://github.com/<org> for org scope)
#   RUNNER_NAME        name shown in GitHub
#   RUNNER_LABELS      comma-separated extra labels (default k3s-lab,harbor,arm64)
#   RUNNER_TOKEN_FILE  file with the registration token (compose secret), or RUNNER_TOKEN
set -euo pipefail
cd /home/runner

if [[ ! -f .runner ]]; then
  : "${RUNNER_URL:?RUNNER_URL is required for first registration}"
  : "${RUNNER_NAME:?RUNNER_NAME is required for first registration}"
  token="${RUNNER_TOKEN:-}"
  if [[ -z "$token" && -n "${RUNNER_TOKEN_FILE:-}" && -s "$RUNNER_TOKEN_FILE" ]]; then
    token="$(tr -d '[:space:]' < "$RUNNER_TOKEN_FILE")"
  fi
  [[ -n "$token" ]] || { echo "no registration token: set RUNNER_TOKEN or RUNNER_TOKEN_FILE (docs/05 §4)" >&2; exit 2; }
  echo "[runner] registering ${RUNNER_NAME} at ${RUNNER_URL}"
  ./config.sh --unattended --replace \
    --url "$RUNNER_URL" --token "$token" --name "$RUNNER_NAME" \
    --labels "${RUNNER_LABELS:-k3s-lab,harbor,arm64}" --work _work
fi

# Sanity: the two things every job needs.
docker version --format 'docker engine {{.Server.Version}}' || echo "[runner] WARNING: docker socket not usable (docs/08 §3)" >&2
[[ -r "${KUBECONFIG:-/etc/github-runner/kubeconfig}" ]] || echo "[runner] WARNING: kubeconfig not mounted (docs/05 §3)" >&2

exec ./run.sh
