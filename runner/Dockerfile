# syntax=docker/dockerfile:1
# Lab GitHub Actions runner image: GitHub's official runner image + the tools the workflows use
# + the lab CA. Built by runner/docker-compose.yml, which passes the build args from lab-env.sh
# and the CA as the extra build context "certs" (secrets/certs). To build by hand:
#   docker build -t lab/actions-runner:2.338.2 --build-context certs=secrets/certs runner/
#
# Base image facts (actions/runner images/Dockerfile): Ubuntu 24.04, user "runner" (uid 1001,
# groups sudo + docker), Docker CLI + buildx preinstalled, runner unpacked in /home/runner,
# no entrypoint. Jobs talk to Docker Desktop's engine through the mounted socket.
ARG RUNNER_VERSION=2.338.2
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}
ARG TARGETARCH
ARG K3S_CHANNEL=v1.34
ARG K9S_VERSION=v0.51.0

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq shellcheck openssh-client rsync unzip \
 && rm -rf /var/lib/apt/lists/*

# Lab CA in the OS trust store: curl (scan-gate), kubectl and trivy inside jobs verify Harbor with it.
# `docker push` from a job uses the engine's trust, i.e. Docker Desktop's keychain bundle (docs/04).
COPY --from=certs ca.crt /usr/local/share/ca-certificates/kubernetes-lab-ca.crt
RUN update-ca-certificates

# kubectl pinned to the K3s/VKS minor; the rest tracks latest like the old runner VM did.
RUN set -eux; arch="${TARGETARCH}"; \
    KVER="$(curl -fsSL "https://dl.k8s.io/release/stable-${K3S_CHANNEL#v}.txt")"; \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${arch}/kubectl"; \
    chmod 755 /usr/local/bin/kubectl; \
    cd /tmp && curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash \
      && install -m 755 /tmp/kustomize /usr/local/bin/kustomize && rm -f /tmp/kustomize; \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR=/usr/local/bin USE_SUDO=false bash; \
    curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${arch}.tar.gz" | tar -xz -C /usr/local/bin k9s; \
    curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"; \
    chmod 755 /usr/local/bin/yq; \
    curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin; \
    kubectl version --client; kustomize version; helm version --short; k9s version --short; yq --version; trivy --version

COPY entrypoint.sh /usr/local/bin/lab-runner-entrypoint
RUN chmod 755 /usr/local/bin/lab-runner-entrypoint

# Jobs expect these; the compose file sets them too (KUBECONFIG is a read-only mount).
ENV DOCKER_BUILDKIT=1 \
    KUBECONFIG=/etc/github-runner/kubeconfig

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/lab-runner-entrypoint"]
