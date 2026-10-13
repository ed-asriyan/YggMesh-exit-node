#!/bin/sh
# NAT64 exit for YggMesh nodes (CLEARNET_EXITS build input of YggMesh).
#
# Runs in the network namespace of the yggdrasil service. The NAT64 prefix is
# this node's Yggdrasil /64 subnet followed by 32 zero bits:
# <subnet>::a.b.c.d is translated to the IPv4 address a.b.c.d. Yggdrasil
# routes the subnet here, nothing else needs to be configured.
#
# Environment:
#   EXIT_USERS  space-separated Yggdrasil addresses (200::/8) allowed to use
#               this exit; empty: everyone is allowed
#
# The container exits (and Docker restarts it) when TAYGA dies or when the
# Yggdrasil address disappears from the namespace: after a restart of the
# yggdrasil container this one would otherwise stay in its old, empty network
# namespace.
set -e

POOL="100.64.0.0/16"
TAYGA_ADDR="100.64.0.1"
CONF="/etc/tayga-exit.conf"

# Prints the Yggdrasil address (200::/8) of this network namespace, or nothing
ygg_addr() {
  ip -6 -o addr show scope global | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -E '^2[0-9a-f][0-9a-f]:' | head -n 1 || true
}

echo "Waiting for the Yggdrasil address..."
ADDR=""
while [ -z "$ADDR" ]; do
  ADDR=$(ygg_addr)
  [ -n "$ADDR" ] || sleep 1
done

# Yggdrasil subnet of the address: first byte 0x02 -> 0x03, first 64 bits
SUBNET=$(echo "$ADDR" | awk '
  function hex(s,    i, n) {
    n = 0
    for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
    return n
  }
  {
    n = split($0, halves, "::")
    nh = (halves[1] == "") ? 0 : split(halves[1], h, ":")
    nt = (n == 2 && halves[2] != "") ? split(halves[2], t, ":") : 0
    for (i = 1; i <= 8; i++) g[i] = 0
    for (i = 1; i <= nh; i++) g[i] = hex(h[i])
    for (i = 1; i <= nt; i++) g[8 - nt + i] = hex(t[i])
    printf "%x:%x:%x:%x::\n", g[1] + 256, g[2], g[3], g[4]
  }')
PREFIX="${SUBNET}/96"

USERS=""
for u in $EXIT_USERS; do
  USERS="${USERS:+$USERS, }$u"
done

printf 'tun-device nat64\nipv4-addr %s\nprefix %s\ndynamic-pool %s\n' \
  "$TAYGA_ADDR" "$PREFIX" "$POOL" > "$CONF"
ip link show nat64 >/dev/null 2>&1 || tayga -c "$CONF" --mktun
ip link set nat64 mtu 1520 up
ip -6 route replace "$PREFIX" dev nat64
# The rest of the subnet is unused: do not bounce it back into Yggdrasil
ip -6 route replace unreachable "${SUBNET}/64"
ip -4 route replace "$POOL" dev nat64

{
  echo 'table inet yggexit'
  echo 'delete table inet yggexit'
  echo 'table inet yggexit {'
  if [ -n "$USERS" ]; then
    echo "  set users { type ipv6_addr; elements = { $USERS } }"
  fi
  echo '  set private4 { type ipv4_addr; flags interval; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 } }'
  echo '  chain forward {'
  echo '    type filter hook forward priority filter; policy accept;'
  # Clients must not reach the Docker host or its networks through NAT64
  echo '    iifname "nat64" ip daddr @private4 drop'
  if [ -n "$USERS" ]; then
    echo '    oifname "nat64" ip6 saddr != @users drop'
  fi
  echo '  }'
  echo '  chain postrouting {'
  echo '    type nat hook postrouting priority srcnat; policy accept;'
  echo "    ip saddr $POOL oifname != \"nat64\" masquerade"
  echo '  }'
  echo '}'
} | nft -f -

echo "Yggdrasil address: $ADDR"
echo "NAT64 prefix: $PREFIX"
if [ -n "$USERS" ]; then
  echo "Allowed users: $EXIT_USERS"
else
  echo "WARNING: EXIT_USERS is empty, this exit is open to the whole Yggdrasil network"
fi

tayga -c "$CONF" -d &
TAYGA_PID=$!
trap 'kill "$TAYGA_PID" 2>/dev/null; exit 0' INT TERM

while kill -0 "$TAYGA_PID" 2>/dev/null; do
  sleep 10 &
  wait $!
  if [ "$(ygg_addr)" != "$ADDR" ]; then
    echo "The Yggdrasil address is gone from this network namespace (yggdrasil restarted?), restarting"
    kill "$TAYGA_PID" 2>/dev/null
    exit 1
  fi
done
echo "TAYGA exited, restarting"
exit 1
