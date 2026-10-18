FROM debian:trixie-slim

LABEL org.opencontainers.image.source="https://github.com/ed-asriyan/yggdrasil-clearnet-proxy"
LABEL org.opencontainers.image.description="Clearnet exit for YggMesh nodes: Yggdrasil-ng with Crypto-Key Routing"

# Yggdrasil-ng (https://github.com/Revertron/Yggdrasil-ng), the static binary
# of its release. To update it, change the version and both checksums (the
# same release as YGGDRASIL_NG_VERSION in YggMesh's scripts/common.sh).
ARG YGGDRASIL_NG_VERSION=0.3.1
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends nftables ca-certificates curl \
    && case "$TARGETARCH" in \
        amd64) sum=d44847469b85ad3ede77041b0f73d1be428ba20d88c8b88d4999d594d788316b ;; \
        arm64) sum=f62cd8fae45f19c735ce0a50789625239973327250716ee0dbb0f3ed95e25924 ;; \
        *) echo "No Yggdrasil-ng binary for $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/yggdrasil \
        "https://github.com/Revertron/Yggdrasil-ng/releases/download/v${YGGDRASIL_NG_VERSION}/yggdrasil-${TARGETARCH}" \
    && echo "$sum  /usr/local/bin/yggdrasil" | sha256sum -c - \
    && chmod 755 /usr/local/bin/yggdrasil \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY exit.sh /usr/local/bin/exit.sh

ENTRYPOINT ["/bin/sh", "/usr/local/bin/exit.sh"]
