FROM alpine:3.22.1 AS app-image

ARG TARGETARCH

ENV YQ_VERSION="v4.47.1" KUBECTL_VERSION="v1.33.4"

RUN apk add --no-cache bash git openssh-client postgresql-client curl ca-certificates \
  && curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH} \
  && chmod +x /usr/local/bin/yq \
  && curl -Lo /usr/local/bin/kubectl https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl \
  && chmod +x /usr/local/bin/kubectl

RUN echo "HashKnownHosts no" >> /etc/ssh/ssh_config && \
    echo "IdentityFile /etc/ssh/id_rsa" >> /etc/ssh/ssh_config && \
    echo "IdentityFile /etc/ssh/id_ed25519" >> /etc/ssh/ssh_config

COPY docker-entrypoint.sh ./

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["bash"]
