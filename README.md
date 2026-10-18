# Yggdrasil Clearnet Proxy
Lightweight Docker Compose stack that runs a [Yggdrasil-ng](https://github.com/Revertron/Yggdrasil-ng) node as an outbound internet (clearnet) exit for [YggMesh](https://github.com/ed-asriyan/YggMesh) nodes: their Wi-Fi clients get the Internet over IPv4 with no setup, any protocol (TCP, UDP, QUIC, ping).

The image (`ghcr.io/ed-asriyan/yggmesh-exit-node:latest`, [Dockerfile](Dockerfile), [exit.sh](exit.sh)) is rebuilt for `amd64` and `arm64` on every push to `master`; only `latest` is kept. The stack pulls it on every `up`.

## 🚀 Quick Start
### 1. Generate an Yggdrasil Private Key
You need a static private key: YggMesh nodes know the exit by its public key. Generate one instantly with this one-liner:

```bash
docker run --rm --entrypoint yggdrasil ghcr.io/ed-asriyan/yggmesh-exit-node:latest --genconf | grep private_key
```

(Save the 128 hex digits, you will need them in the next step.) The public key of the exit is the last 64 of them.

### 2. Collect the public keys of the nodes
Every YggMesh node shows its **public key** on its YggMesh page in LuCI (below the private key). Ask the owner of every node that should use this exit for it. The owners never send their private keys.

### 3. Run the exit
You don't need to clone this repository. Run the setup directly using the raw Compose file:
```bash
YGG_PRIV_KEY="<YOUR_GENERATED_PRIVATE_KEY>" \
YGG_PEERS="tcp://1.2.3.4:12345 tls://5.6.7.8:9012" \
EXIT_USERS="<PUBLIC_KEY_OF_NODE_1> <PUBLIC_KEY_OF_NODE_2>" \
docker compose -f <(curl -fsSL https://raw.githubusercontent.com/ed-asriyan/yggmesh-exit-node/master/docker-compose.yml) up -d
```

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `YGG_PRIV_KEY` | Yes | Your Yggdrasil private key. |
| `YGG_PEERS` | Yes | A space-separated list of Yggdrasil peers. *Find active public peers at [Yggdrasil Public Peers](https://publicpeers.neilalexander.dev).* |
| `EXIT_USERS` | Yes | A space-separated list of public keys (64 hex digits) of the YggMesh nodes allowed to use this exit. |
| `YGG_LISTEN` | No | A space-separated list of listen URIs (e.g. `tls://0.0.0.0:443`) to accept peers directly. Publish the ports in the Compose file if you use it. |

To change `EXIT_USERS` later, run the same command again with the new list: the container is recreated, open connections of all users break for a few seconds.

The container prints every user with its address:
```bash
docker compose -p yggmesh-exit-node logs exit
```

> [!WARNING]
> Never run two Yggdrasil nodes with the same `YGG_PRIV_KEY`. They are the same node to the network, and the traffic of the YggMesh nodes goes to whichever of them the network finds.

## Connecting a YggMesh network
Put the **public key** of this exit (the last 64 hex digits of `YGG_PRIV_KEY`) into the exits of the YggMesh nodes: the `clearnet_exits` build input, or Clearnet → Exits on the YggMesh page of a node. Several exits can be listed: each node uses the fastest working one.

How it works: Yggdrasil-ng's [Crypto-Key Routing](https://github.com/Revertron/Yggdrasil-ng/blob/master/docs/CKR.md) (CKR). A YggMesh node masquerades its clients' IPv4 to its own address, `100.64.0.0/10` plus the last 22 bits of its public key, and sends it over Yggdrasil to the public key of the exit. This exit derives the same address from every key in `EXIT_USERS` and accepts a node's packets only from that address, after Yggdrasil has checked they come from the node's key. They leave masqueraded to the server's IP. Nothing but the public keys has to be exchanged.

Two nodes may get the same address (about 0.1% for 100 users of one exit). The exit then refuses to start and names both keys: only one of them can use it, unless the other one changes its key.

Safety: the users reach public IPv4 addresses only: private ranges (the Docker host, its networks, `10.0.0.0/8`, `192.168.0.0/16`, the other users in `100.64.0.0/10`, ...) are blocked, and IPv6 is not forwarded.

## Publishing the image (forks)
The [workflow](.github/workflows/image.yml) publishes `ghcr.io/<owner>/yggmesh-exit-node:latest` with the repository's `GITHUB_TOKEN` and deletes every other version of the package. After the first run:
1. Open the package (your profile → **Packages** → `yggmesh-exit-node`) → **Package settings** and set **Change visibility** to **Public**, so servers can pull it without logging in.
2. If the cleanup step fails with a permission error, give this repository the **Admin** role under **Manage Actions access** in the same settings.

In a fork, also replace the image name in [docker-compose.yml](docker-compose.yml).
