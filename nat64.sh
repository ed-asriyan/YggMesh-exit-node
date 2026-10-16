#!/bin/sh
# NAT64 exit for YggMesh nodes (CLEARNET_EXITS build input of YggMesh).
#
# Runs in the network namespace of the yggdrasil service. The NAT64 prefix is
# this node's Yggdrasil /64 subnet followed by 32 zero bits:
# <subnet>::a.b.c.d is translated to the IPv4 address a.b.c.d. Yggdrasil
# routes the subnet here, nothing else needs to be configured.
#
# The translator is one of two backends, the packets on the wire are the same:
#   - jool: Jool NAT64 in the kernel of the host, so translated packets never
#     visit userspace. Used when the host has the jool kernel module loaded
#     and it matches the jool tool of this image.
#   - tayga: TAYGA in userspace with a tun device, otherwise.
#
# Environment:
#   EXIT_USERS  space-separated Yggdrasil addresses (200::/8) allowed to use
#               this exit; empty: everyone is allowed
#
# The container exits (and Docker restarts it) when the translator dies or
# when the Yggdrasil address disappears from the namespace: after a restart of
# the yggdrasil container this one would otherwise stay in its old, empty
# network namespace.
set -e

POOL="100.64.0.0/16"
TAYGA_ADDR="100.64.0.1"
CONF="/etc/tayga-exit.conf"
JOOL_INSTANCE="yggexit"
MTU=1520   # IPv4 1500 + 20 bytes of IPv6 header growth

# Destinations translated traffic must not reach: the Docker host, its
# networks and other non-public ranges
PRIVATE4="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/3"

# Prints the Yggdrasil address (200::/8) of this network namespace, or nothing
ygg_addr() {
  ip -6 -o addr show scope global | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -E '^2[0-9a-f][0-9a-f]:' | head -n 1 || true
}

# Prints the IPv4 CIDRs $@ as nft ranges of 32-bit integers, comma-separated:
# 10.0.0.0/8 -> 0x0a000000-0x0affffff
cidrs_hex() {
  echo "$@" | tr ' ' '\n' | awk -F'[./]' '
    {
      n = (($1 * 256 + $2) * 256 + $3) * 256 + $4
      size = 2 ^ (32 - $5)
      n = n - n % size
      m = n + size - 1
      # In 16-bit halves: mawk prints %x of 32-bit values wrong
      printf "%s0x%04x%04x-0x%04x%04x", (NR > 1 ? ", " : ""), int(n / 65536), n % 65536, int(m / 65536), m % 65536
    }'
}

# Starts Jool NAT64 for $PREFIX: translated IPv4 leaves from this namespace's
# address, from the ports above the ephemeral range of its own sockets.
# Returns 1 (and leaves nothing behind) when Jool cannot be used.
jool_start() {
  local v4 lo hi first p
  [ -d /sys/module/jool ] || { echo "The jool kernel module is not loaded on the host"; return 1; }
  jool instance remove "$JOOL_INSTANCE" >/dev/null 2>&1 || true
  if ! jool instance add "$JOOL_INSTANCE" --netfilter --pool6 "$PREFIX"; then
    echo "Cannot create a Jool instance (does the module version match jool $(jool --version 2>/dev/null | head -n 1)?)"
    return 1
  fi
  v4=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range
  first=$((hi + 1))
  if [ -z "$v4" ] || [ "$first" -gt 65000 ]; then
    echo "No IPv4 address or no free ports for Jool (address '$v4', ephemeral ports $lo-$hi)"
    jool instance remove "$JOOL_INSTANCE" >/dev/null 2>&1 || true
    return 1
  fi
  for p in tcp udp icmp; do
    jool -i "$JOOL_INSTANCE" pool4 add "$v4" "${first}-65535" "--$p" >/dev/null
  done
  # Like TAYGA on its 1520 tun: IPv4 without DF is not fragmented below that
  jool -i "$JOOL_INSTANCE" global update lowest-ipv6-mtu "$MTU" >/dev/null
  echo "Jool NAT64: translated traffic leaves from $v4, ports ${first}-65535 ($((65536 - first)) per protocol)"
}

jool_running() {
  jool -i "$JOOL_INSTANCE" global display >/dev/null 2>&1
}

jool_stop() {
  jool instance remove "$JOOL_INSTANCE" >/dev/null 2>&1 || true
}

tayga_start() {
  printf 'tun-device nat64\nipv4-addr %s\nprefix %s\ndynamic-pool %s\n' \
    "$TAYGA_ADDR" "$PREFIX" "$POOL" > "$CONF"
  ip link show nat64 >/dev/null 2>&1 || tayga -c "$CONF" --mktun
  ip link set nat64 mtu "$MTU" up
  ip -6 route replace "$PREFIX" dev nat64
  ip -4 route replace "$POOL" dev nat64
  tayga -c "$CONF" -d &
  TAYGA_PID=$!
}

# The firewall, by backend. Jool translates in PREROUTING and its translated
# packets skip FORWARD, so with Jool the checks run in PREROUTING before it,
# on the IPv6 packet: the source against EXIT_USERS and the IPv4 destination
# (the last 32 bits of the IPv6 one) against PRIVATE4. With TAYGA they run in
# FORWARD on both sides of the tun, and translated IPv4 is masqueraded.
firewall() {
  echo 'table inet yggexit'
  echo 'delete table inet yggexit'
  echo 'table inet yggexit {'
  if [ -n "$USERS" ]; then
    echo "  set users { type ipv6_addr; elements = { $USERS } }"
  fi
  if [ "$BACKEND" = jool ]; then
    echo '  chain prerouting {'
    echo '    type filter hook prerouting priority raw; policy accept;'
    if [ -n "$USERS" ]; then
      echo "    ip6 daddr $PREFIX ip6 saddr != @users drop"
    fi
    echo "    ip6 daddr $PREFIX @nh,288,32 { $(cidrs_hex $PRIVATE4) } drop"
    echo '  }'
  else
    echo "  set private4 { type ipv4_addr; flags interval; elements = { $(echo $PRIVATE4 | sed 's/ /, /g') } }"
    echo '  chain forward {'
    echo '    type filter hook forward priority filter; policy accept;'
    echo '    iifname "nat64" ip daddr @private4 drop'
    if [ -n "$USERS" ]; then
      echo '    oifname "nat64" ip6 saddr != @users drop'
    fi
    echo '  }'
    echo '  chain postrouting {'
    echo '    type nat hook postrouting priority srcnat; policy accept;'
    echo "    ip saddr $POOL oifname != \"nat64\" masquerade"
    echo '  }'
  fi
  echo '}'
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

# The rest of the subnet is unused: do not bounce it back into Yggdrasil.
# With Jool the prefix is caught before routing, so this covers it as well.
ip -6 route replace unreachable "${SUBNET}/64"

# Leftovers of the other backend from a previous run of this container
jool_stop
ip link del nat64 2>/dev/null || true

if jool_start; then
  BACKEND=jool
else
  echo "Using TAYGA (userspace) instead; see README.md for the in-kernel NAT64"
  BACKEND=tayga
fi

# The firewall goes up before TAYGA starts translating
firewall | nft -f -
[ "$BACKEND" = tayga ] && tayga_start

echo "Yggdrasil address: $ADDR"
echo "NAT64 prefix: $PREFIX"
echo "NAT64 backend: $BACKEND"
if [ -n "$USERS" ]; then
  echo "Allowed users: $EXIT_USERS"
else
  echo "WARNING: EXIT_USERS is empty, this exit is open to the whole Yggdrasil network"
fi

if [ "$BACKEND" = jool ]; then
  trap 'jool_stop; exit 0' INT TERM
else
  trap 'kill "$TAYGA_PID" 2>/dev/null; exit 0' INT TERM
fi

while :; do
  sleep 10 &
  wait $!
  if [ "$BACKEND" = jool ]; then
    if ! jool_running; then
      echo "The Jool instance is gone, restarting"
      exit 1
    fi
  elif ! kill -0 "$TAYGA_PID" 2>/dev/null; then
    echo "TAYGA exited, restarting"
    exit 1
  fi
  if [ "$(ygg_addr)" != "$ADDR" ]; then
    echo "The Yggdrasil address is gone from this network namespace (yggdrasil restarted?), restarting"
    [ "$BACKEND" = jool ] && jool_stop
    [ "$BACKEND" = tayga ] && kill "$TAYGA_PID" 2>/dev/null
    exit 1
  fi
done
