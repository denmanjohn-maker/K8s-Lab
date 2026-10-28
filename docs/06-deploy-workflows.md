# 06 — Build → Harbor → k3s workflows

Two drop-in workflows, one per repo, identical except for their defaults:

| File | Copy to | Defaults |
|---|---|---|
| `workflows/containerhelperadditions.yml` | `ContainerHelperAdditions/.github/workflows/lab-build-deploy.yml` | project `containerhelper`, image `toolbox`, ns `containerhelper` |
| `workflows/devopshelpertools.yml` | `DevOpsHelperTools/.github/workflows/lab-build-deploy.yml` | project `devopshelpers`, image `kdt`, ns `devopshelpers` |

Both expect a Kustomize overlay at `deploy/overlays/lab/` — `workflows/sample-deploy/` is a PSA-`restricted`-clean
starter you can copy into either repo (`base/` + `overlays/lab/`). Every path is a repo *variable* with a default,
so you change the layout in **Settings → Variables**, not in the YAML.

## 1. Repo setup (per repo, once)

| Where | Item | Value |
|---|---|---|
| Settings → Secrets → Actions | `HARBOR_ROBOT_USER` | `cat secrets/harbor-robot-gha-push.user` → `robot$gha-push` |
| | `HARBOR_ROBOT_TOKEN` | `cat secrets/harbor-robot-gha-push.token` |
| Settings → Variables → Actions (optional) | `HARBOR_HOST` `HARBOR_PROJECT` `IMAGE_NAME` `DOCKERFILE` `KUSTOMIZE_DIR` `K8S_NAMESPACE` | only if the defaults don't fit |
| Settings → Environments | `k3s-lab` | the `deploy` job targets it; add "required reviewers" if you want a manual gate |
| Settings → Actions → Runners | runner container with label **`k3s-lab`** | docs/05 §4 |

With `gh` from the Mac:

```bash
source lab-env.sh
for r in "${GH_REPOS[@]}"; do
  gh secret set HARBOR_ROBOT_USER  -R "$GH_OWNER/$r" < secrets/harbor-robot-gha-push.user
  gh secret set HARBOR_ROBOT_TOKEN -R "$GH_OWNER/$r" < secrets/harbor-robot-gha-push.token
done
```

## 2. What the pipeline does

```
push to main ─► lint ─► build ─► scan-gate ─► deploy
pull_request ─► lint only
workflow_dispatch ─► all (deploy optional via input)
```

| Job | Runs | Notes |
|---|---|---|
| `lint` | shellcheck (`-S warning -x`) on every tracked shell script; `sh -n` under **Alpine 3.20 and Ubuntu 24.04** pulled through the Harbor proxy cache | Matches your Alpine + Noble compatibility requirement for the app-* scripts. Skips if there are no scripts |
| `build` | `docker/build-push-action` → `harbor.lab.internal/<project>/<image>:sha-<12>` (+ `:latest` on main), `linux/arm64`, registry build cache at `:buildcache` | Skips with a notice if `DOCKERFILE` doesn't exist. `provenance: false` keeps a plain manifest so Trivy scans it directly. Add `linux/amd64` to `PLATFORMS` when you want the same image for x86 clusters (Docker Desktop emulates it; slow) |
| `scan-gate` | polls Harbor `GET /projects/{p}/repositories/{r}/artifacts/{digest}?with_scan_overview=true` up to 6 min; writes the severity table to the job summary; fails if `Critical > MAX_CRITICAL` (default 0) | Harbor auto-scans on push (project setting from `40-init-harbor.sh`). This is where an EPSS/KEV filter would go — Harbor exposes the full Trivy report at `/additions/vulnerabilities` for the `robot$gha-push` account |
| `deploy` | `kustomize edit set image <image>=<harbor image>@<digest>` in the overlay, `kustomize build \| kubectl apply --server-side`, `rollout status` | Deploys **by digest**, never by tag. `KUBECONFIG=/etc/github-runner/kubeconfig` — the SA from docs/02 §3, mounted into the runner container. Skips with a notice if the overlay doesn't exist |

## 3. Adapting to each repo

**ContainerHelperAdditions** — if the repo is the `app-*` script collection, the natural image is the *toolbox*
(`FROM harbor.lab.internal/dockerhub/library/alpine:3.20` + the scripts) used with `kubectl debug --target`. Deploying
it as a Deployment is only for a smoke test (the sample does `sleep infinity`); the useful artifact is the image
in Harbor, which you then use from the runner or your Mac:

```bash
kubectl -n containerhelper debug -it <pod> --image=harbor.lab.internal/containerhelper/toolbox:latest --target=app -- app-banner
```

**DevOpsHelperTools** — if it's mostly `kdt` tooling + Kustomize, you may want `lint` plus a `kustomize build`
dry-run job rather than an image build. Delete the `build/scan-gate/deploy` jobs or leave them (they skip without a
Dockerfile) and add:

```yaml
  kustomize-dry-run:
    needs: lint
    runs-on: [self-hosted, k3s-lab]
    steps:
      - uses: actions/checkout@v4
      - run: |
          for k in $(git ls-files | grep -E 'kustomization\.ya?ml$' | xargs -n1 dirname | sort -u); do
            echo "== $k"; kustomize build "$k" | kubectl apply --dry-run=server -f - ; done
```

Server-side dry-run against the real cluster catches PSA violations and schema errors before anything is applied —
one of the main reasons to have this lab.

## 4. Base images through the proxy cache

In Dockerfiles, prefer `FROM harbor.lab.internal/dockerhub/library/alpine:3.20` over `FROM alpine:3.20` when building
*in the lab*: no Hub rate limits, and the base image gets scanned and stays visible in Harbor. For images that must
build identically at work, keep `FROM alpine:3.20` and accept that the build pulls from Docker Hub directly: a
`registry-mirrors` entry in Docker Desktop's engine settings does **not** work for proxy-cache projects — Harbor needs the
project prefix — so the `FROM` rewrite is the honest option.

## 5. Promoting to GHCR later

The toolbox already lives on GHCR for work use. Add a second `docker/login-action` to `ghcr.io` with
`${{ secrets.GITHUB_TOKEN }}` and a second tag line `ghcr.io/${{ github.repository_owner }}/toolbox:…`; `build-push-action`
pushes to both registries in one build. Gate it on `scan-gate` passing so GHCR only ever gets images Harbor cleared.
