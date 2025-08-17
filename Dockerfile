# Dockerfile
FROM alpine:3.22.1

ARG TARGETARCH

RUN apk add --no-cache bash git openssh-client kustomize postgresql-client curl ca-certificates \
  && curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH} \
  && chmod +x /usr/local/bin/yq
