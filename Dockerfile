FROM debian:trixie-slim

LABEL org.opencontainers.image.source="https://github.com/ed-asriyan/yggdrasil-clearnet-proxy"
LABEL org.opencontainers.image.description="NAT64 exit (Jool or TAYGA) for YggMesh nodes, runs next to an Yggdrasil node"

RUN apt-get update \
    && apt-get install -y --no-install-recommends tayga jool-tools nftables iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY nat64.sh /usr/local/bin/nat64.sh

ENTRYPOINT ["/bin/sh", "/usr/local/bin/nat64.sh"]
