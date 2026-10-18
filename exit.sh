#!/bin/sh
# Clearnet exit for YggMesh nodes: Yggdrasil-ng with Crypto-Key Routing.
#
# A YggMesh node sends the IPv4 packets of its Wi-Fi clients over Yggdrasil to
# the public key of this exit, from the node's own IPv4 address: 100.64.0.0/10
# plus the last 22 bits of the node's public key. This exit derives the same
# address from every key in EXIT_USERS and accepts a node's packets only from
# that address (CKR checks the sender's key), then masquerades them to the
# Internet. Nothing but the public keys has to be exchanged.
#
# Environment:
#   YGG_PRIV_KEY  private key of this exit (128 hex digits)
#   YGG_PEERS     space-separated Yggdrasil peer URIs
#   YGG_LISTEN    space-separated listen URIs, e.g. tls://0.0.0.0:443 (optional)
#   EXIT_USERS    space-separated public keys (64 hex digits) of the YggMesh
#                 nodes allowed to use this exit
#
# The users are fixed while Yggdrasil runs: to change them, recreate the
# container (docker compose up -d).
set -e

CONF="/etc/yggdrasil.toml"
DEV="ygg0"
POOL="100.64.0.0/10"

fail() {
  echo "Error: $*" >&2
  exit 1
}

# Returns 0 if $1 is $2 hex digits
is_hex() {
  case "$1" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  [ "${#1}" -eq "$2" ]
}

# Prints the clearnet IPv4 address of public key $1, the same as YggMesh
# nodes derive (key_ipv4 in /usr/share/yggmesh/ygg.sh of the firmware)
key_ipv4() {
  n=$(printf '%d' "0x$(echo "$1" | cut -c59-64)")
  n=$((n & 0x3fffff))
  echo "100.$((64 + (n >> 16))).$(((n >> 8) & 255)).$((n & 255))"
}

# Prints the words $@ as a TOML array of strings
toml_list() {
  out=""
  for v in "$@"; do
    case "$v" in
      *\"*|*\\*) fail "'$v' must not contain quotes or backslashes" ;;
    esac
    out="${out:+$out, }\"$v\""
  done
  echo "[$out]"
}

is_hex "$YGG_PRIV_KEY" 128 || fail "YGG_PRIV_KEY must be 128 hex digits"
[ -n "$EXIT_USERS" ] || fail "EXIT_USERS is empty: list the public keys of the YggMesh nodes allowed to use this exit"

# The users and their addresses, "address key" per line. Two keys may get the
# same address: the exit cannot tell those nodes apart, so it refuses to start.
USERS=""
for u in $EXIT_USERS; do
  is_hex "$u" 64 || fail "EXIT_USERS: '$u' is not a public key (64 hex digits)"
  u=$(echo "$u" | tr 'A-F' 'a-f')
  a=$(key_ipv4 "$u")
  other=$(printf '%s\n' "$USERS" | awk -v a="$a" '$1 == a { print $2 }')
  if [ -n "$other" ]; then
    [ "$other" = "$u" ] && continue
    fail "the nodes $other and $u get the same address $a; only one of them can use this exit (or the other one changes its key)"
  fi
  USERS="${USERS:+$USERS
}$a $u"
done

# shellcheck disable=SC2086
{
  echo "private_key = \"$YGG_PRIV_KEY\""
  echo "peers = $(toml_list $YGG_PEERS)"
  echo "listen = $(toml_list $YGG_LISTEN)"
  echo "admin_listen = \"tcp://127.0.0.1:9001\""
  echo "if_name = \"$DEV\""
  echo "multicast_interfaces = []"
  echo
  echo "[tunnel_routing]"
  echo "enable = true"
  echo
  echo "[tunnel_routing.remote_subnets]"
  printf '%s\n' "$USERS" | while read -r a u; do
    echo "\"$u\" = [\"$a/32\"]"
  done
} > "$CONF"
chmod 600 "$CONF"

nft -f - <<EOF
table inet yggexit
delete table inet yggexit
table inet yggexit {
  set private4 {
    type ipv4_addr; flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/3 }
  }
  chain input {
    type filter hook input priority filter; policy accept;
    # The nodes use the exit as a router only, not the container itself
    iifname "$DEV" meta nfproto ipv4 drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    # The nodes must not reach the Docker host, its networks or each other
    iifname "$DEV" ip daddr @private4 drop
    # Only IPv4 leaves through the exit
    iifname "$DEV" meta nfproto ipv6 drop
    tcp flags syn tcp option maxseg size set rt mtu
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $POOL oifname != "$DEV" masquerade
  }
}
EOF

echo "Users of this exit (address, public key):"
printf '%s\n' "$USERS" | sed 's/^/  /'

exec yggdrasil -c "$CONF"
