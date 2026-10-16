# Yggdrasil Clearnet Proxy
Lightweight Docker Compose stack that runs an Yggdrasil node bundled with a NAT64 translator ([Jool](https://nicmx.github.io/Jool/) in the kernel when the host has it, [TAYGA](https://github.com/apalrd/tayga) otherwise) in a shared network namespace. It acts as an outbound internet (clearnet) exit node for [YggMesh](https://github.com/ed-asriyan/YggMesh) nodes built with `CLEARNET_EXITS`: their Wi-Fi clients get the Internet over IPv4 with no setup, any protocol (TCP, UDP, QUIC, ping).

The NAT64 image (`ghcr.io/ed-asriyan/yggdrasil-clearnet-proxy:latest`, [Dockerfile](Dockerfile), [nat64.sh](nat64.sh)) is rebuilt for `amd64` and `arm64` on every push to `master`; only `latest` is kept. The stack pulls it on every `up`.

## 🚀 Quick Start
### 1. Generate an Yggdrasil Private Key
You need a static private key so your node's IPv6 address remains constant across reboots. Generate one instantly with this one-liner:

```bash
docker run --rm --entrypoint yggdrasil ghcr.io/yggdrasil-network/yggdrasil-go:latest -genconf | grep PrivateKey
```

(Save the output string, you will need it in the next step).

### 2. Run the Mirror
You don't need to clone this repository. Run the setup directly using the raw Compose file:
```bash
YGG_PRIV_KEY="<YOUR_GENERATED_PRIVATE_KEY>" \
YGG_PEERS="tcp://1.2.3.4:12345 tls://5.6.7.8:9012" \
EXIT_USERS="200:1111:2222:3333:4444:5555:6666:7777 201:aaaa:bbbb:cccc:dddd:eeee:ffff:1" \
docker compose -f <(curl -fsSL https://raw.githubusercontent.com/ed-asriyan/yggdrasil-clearnet-proxy/master/docker-compose.yml) up -d
```

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `YGG_PRIV_KEY` | Yes | Your Yggdrasil private key. |
| `YGG_PEERS` | Yes | A space-separated list of Yggdrasil peers. *Find active public peers at [Yggdrasil Public Peers](https://publicpeers.neilalexander.dev).* |
| `EXIT_USERS` | No | A space-separated list of Yggdrasil addresses (`200::/8`) allowed to use this exit. Every YggMesh node has its own address, so list every node. **Empty: everyone in the Yggdrasil network is allowed.** |

To change `EXIT_USERS` later, run the same command again with the new list: the NAT64 container is recreated, open connections of all users break for a few seconds.

### 3. Get your Yggdrasil IPv6 Address
Retrieve the IPv6 address assigned to your container's tun0 interface:
```bash
docker compose -p yggdrasil-clearnet-proxy logs yggdrasil | grep "Your IPv6 address is"
```

The NAT64 container prints the same address, its NAT64 prefix and the allowed users:
```bash
docker compose -p yggdrasil-clearnet-proxy logs nat64
```

### 4. Register in Alfis DNS (optional)
1. Open your [Alfis GUI](https://alfis.name).
2. Mine a new key if you haven't done it before
3. Register your target .ygg domain.
4. Create an AAAA record pointing to the IPv6 address obtained in Step 3.

YggMesh nodes accept the domain in `CLEARNET_EXITS` instead of the address. With a domain the exit can be moved (a new server, a new key) by changing the AAAA record, without touching the nodes.

> [!WARNING]
> Never run two Yggdrasil nodes with the same `YGG_PRIV_KEY`. They get the same address, and the traffic of the YggMesh nodes goes to whichever of them the network finds, possibly one without NAT64.

## Connecting a YggMesh network (NAT64)
Build the [YggMesh](https://github.com/ed-asriyan/YggMesh) firmware with `CLEARNET_EXITS` set to the Yggdrasil address from step 3 or the domain from step 4 (several exits can be listed: each node uses the fastest working one). If `EXIT_USERS` is set, add the Yggdrasil address of every node to it.

How it works: a YggMesh node translates its clients' IPv4 packets into IPv6 packets addressed to `<this exit's Yggdrasil /64 subnet>::<IPv4 address>`. Yggdrasil routes the subnet to this exit, where the NAT64 (Jool or TAYGA) translates the packets back into IPv4 and they leave from the server's IP. Nothing but the Yggdrasil address has to be shared.

Safety: translated traffic can reach public IPv4 addresses only, private ranges (the Docker host, its networks, `10.0.0.0/8`, `192.168.0.0/16`, ...) are blocked.

Restarts: if the `yggdrasil` container restarts, the NAT64 container notices within 10 seconds that its network namespace is gone and restarts too, so it joins the new one.

## In-kernel NAT64 (optional, faster)
By default the NAT64 is TAYGA, in userspace: every packet goes from the kernel to TAYGA and back. If the host has the [Jool](https://nicmx.github.io/Jool/) kernel module loaded, the NAT64 container uses it instead and the packets stay in the kernel. Nothing else changes: the address, the prefix, `EXIT_USERS` and the YggMesh nodes stay the same, old and new nodes work with both.

On a Debian or Ubuntu host:
```bash
sudo apt install jool-dkms
sudo modprobe jool
echo jool | sudo tee /etc/modules-load.d/jool.conf   # load it on boot too
```
Then recreate the stack (the command from step 2). The log of the NAT64 container shows which one is used:
```bash
docker compose -p yggdrasil-clearnet-proxy logs nat64 | grep "NAT64 backend"
```

Notes:
- The module and the `jool` tool in the image (Debian trixie, Jool 4.1.13) must be the same version. On a mismatch the container says so in its log and uses TAYGA.
- Jool sends translated traffic from the container's own IPv4 address, from the ports above its ephemeral range (`net.ipv4.ip_local_port_range` in [docker-compose.yml](docker-compose.yml)): 25535 concurrent connections per protocol.
- Hosts without loadable modules (e.g. Home Assistant OS) keep TAYGA.

## Publishing the image (forks)
The [workflow](.github/workflows/image.yml) publishes `ghcr.io/<owner>/yggdrasil-clearnet-proxy:latest` with the repository's `GITHUB_TOKEN` and deletes every other version of the package. After the first run:
1. Open the package (your profile → **Packages** → `yggdrasil-clearnet-proxy`) → **Package settings** and set **Change visibility** to **Public**, so servers can pull it without logging in.
2. If the cleanup step fails with a permission error, give this repository the **Admin** role under **Manage Actions access** in the same settings.

In a fork, also replace the image name in [docker-compose.yml](docker-compose.yml).
