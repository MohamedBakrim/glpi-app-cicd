# Jenkins controller with just enough client tooling to run this pipeline.
# Nothing here builds PHP: the images do that themselves.
FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg jq git openssh-client make \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && curl -fsSL -o /usr/local/bin/yq \
        https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && curl -fsSL -o /usr/local/bin/argocd \
        https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 \
    && chmod +x /usr/local/bin/yq /usr/local/bin/argocd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER jenkins

# Sanity check after build:
#   docker exec -u jenkins jenkins docker version
#   docker exec -u jenkins jenkins docker compose version
