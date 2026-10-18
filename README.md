# Yggdrasil Clearnet Exit Node
Lightweight Docker Compose stack that runs an outbound internet (clearnet) exit for [YggMesh](https://github.com/ed-asriyan/YggMesh) nodes.

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
| `YGG_PRIV_KEY` | Yes | Your Yggdrasil private key from step 1. |
| `YGG_PEERS` | Yes | A space-separated list of Yggdrasil peers. *Find active public peers at [Yggdrasil Public Peers](https://publicpeers.neilalexander.dev).* |
| `EXIT_USERS` | Yes | A space-separated list of public keys from step 2. |
| `YGG_LISTEN` | No | A space-separated list of listen URIs (e.g. `tls://0.0.0.0:443`) to accept peers directly. Publish the ports in the Compose file if you use it. |

### 4. Collect the public key of the exit node
```bash
docker compose -p yggmesh-exit-node logs
```

### 5. Provide the public key to YggMesh nodes users
Provide the public key to the users of the YggMesh nodes that will connect to this exit. They should add to **Exits** in **Clearnet (the Internet)** section.

## Publishing the image (forks)
The [workflow](.github/workflows/image.yml) publishes `ghcr.io/<owner>/yggmesh-exit-node:latest` with the repository's `GITHUB_TOKEN` and deletes every other version of the package. After the first run:
1. Open the package (your profile → **Packages** → `yggmesh-exit-node`) → **Package settings** and set **Change visibility** to **Public**, so servers can pull it without logging in.
2. If the cleanup step fails with a permission error, give this repository the **Admin** role under **Manage Actions access** in the same settings.

In a fork, also replace the image name in [docker-compose.yml](docker-compose.yml).
