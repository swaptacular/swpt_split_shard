FROM alpine:3.22.1 AS app-image

ARG TARGETARCH

ENV YQ_VERSION="v4.47.1"

RUN apk add --no-cache bash git openssh-client postgresql-client curl ca-certificates \
  && curl -Lo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH} \
  && chmod +x /usr/local/bin/yq

COPY docker-entrypoint.sh ./

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["bash"]
