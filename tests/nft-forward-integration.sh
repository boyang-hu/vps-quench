#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ "$(uname -s)" = Linux ] || { echo "NFT integration test requires Linux."; exit 0; }
[ "$(id -u)" = 0 ] || { echo "NFT integration test requires root." >&2; exit 1; }

for cmd in nft ip python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing integration dependency: $cmd" >&2; exit 1; }
done

SUFFIX="${$}"
CLIENT_NS="qclient${SUFFIX}"
RELAY_NS="qrelay${SUFFIX}"
LANDING_NS="qland${SUFFIX}"
CLIENT_IF="qc${SUFFIX: -5}"
RELAY_CLIENT_IF="qrc${SUFFIX: -4}"
LANDING_IF="ql${SUFFIX: -5}"
RELAY_LANDING_IF="qrl${SUFFIX: -4}"
TEST_DIR=$(mktemp -d /tmp/quench-nft-netns.XXXXXX)
TCP_SERVER=""
UDP_SERVER=""

cleanup() {
    set +e
    [ -z "$TCP_SERVER" ] || kill "$TCP_SERVER" >/dev/null 2>&1
    [ -z "$UDP_SERVER" ] || kill "$UDP_SERVER" >/dev/null 2>&1
    ip netns delete "$CLIENT_NS" >/dev/null 2>&1
    ip netns delete "$RELAY_NS" >/dev/null 2>&1
    ip netns delete "$LANDING_NS" >/dev/null 2>&1
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

ip netns add "$CLIENT_NS"
ip netns add "$RELAY_NS"
ip netns add "$LANDING_NS"
ip link add "$RELAY_CLIENT_IF" type veth peer name "$CLIENT_IF"
ip link add "$RELAY_LANDING_IF" type veth peer name "$LANDING_IF"
ip link set "$CLIENT_IF" netns "$CLIENT_NS"
ip link set "$RELAY_CLIENT_IF" netns "$RELAY_NS"
ip link set "$LANDING_IF" netns "$LANDING_NS"
ip link set "$RELAY_LANDING_IF" netns "$RELAY_NS"

ip netns exec "$CLIENT_NS" ip addr add 10.203.1.2/24 dev "$CLIENT_IF"
ip netns exec "$CLIENT_NS" ip link set lo up
ip netns exec "$CLIENT_NS" ip link set "$CLIENT_IF" up
ip netns exec "$CLIENT_NS" ip route add default via 10.203.1.1
ip netns exec "$RELAY_NS" ip addr add 10.203.1.1/24 dev "$RELAY_CLIENT_IF"
ip netns exec "$RELAY_NS" ip addr add 10.203.2.1/24 dev "$RELAY_LANDING_IF"
ip netns exec "$RELAY_NS" ip link set lo up
ip netns exec "$RELAY_NS" ip link set "$RELAY_CLIENT_IF" up
ip netns exec "$RELAY_NS" ip link set "$RELAY_LANDING_IF" up
ip netns exec "$LANDING_NS" ip addr add 10.203.2.2/24 dev "$LANDING_IF"
ip netns exec "$LANDING_NS" ip link set lo up
ip netns exec "$LANDING_NS" ip link set "$LANDING_IF" up
ip netns exec "$LANDING_NS" ip route add default via 10.203.2.1
ip netns exec "$RELAY_NS" sysctl -w net.ipv4.ip_forward=1 >/dev/null

mkdir -p "$TEST_DIR/state" "$TEST_DIR/runtime"
printf '%s\n' \
    '1|ipv4|tcp|10.203.1.1|18080|18081|ip|10.203.2.2|10.203.2.2|8080|8081|range_offset|masquerade|whitelist|yes|tcp-offset-masquerade' \
    '2|ipv4|udp|10.203.1.1|18082|18082|ip|10.203.2.2|10.203.2.2|8082|8082|single|preserve|off|yes|udp-preserve' \
    > "$TEST_DIR/state/rules.db"
printf '%s\n' '1|ipv4|10.203.1.0/24' > "$TEST_DIR/state/access.db"
: > "$TEST_DIR/state/firewall.db"

export NFT_STATE_DIR="$TEST_DIR/state"
export NFT_RUNTIME_DIR="$TEST_DIR/runtime"
export NFT_RULES_FILE="$TEST_DIR/state/rules.db"
export NFT_ACCESS_FILE="$TEST_DIR/state/access.db"
export NFT_FIREWALL_STATE="$TEST_DIR/state/firewall.db"
export NFT_MANAGED_FILE="$TEST_DIR/quench.nft"
export NFT_LOCK_FILE="$TEST_DIR/quench.lock"
# shellcheck source=../src/modules/nft.sh
source "$ROOT/src/modules/nft.sh"

nft_validate_database
nft_generate_config > "$NFT_MANAGED_FILE"
ip netns exec "$RELAY_NS" nft add table ip quench_integration_user
ip netns exec "$RELAY_NS" nft -c -f "$NFT_MANAGED_FILE"
ip netns exec "$RELAY_NS" nft -f "$NFT_MANAGED_FILE"

ip netns exec "$LANDING_NS" python3 - <<'PY' &
import socket
sockets = []
for port in (8080, 8081):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("10.203.2.2", port))
    s.listen(1)
    sockets.append((port, s))
for port, s in sockets:
    c, peer = s.accept()
    c.sendall(f"{port}|{peer[0]}".encode())
    c.close()
    s.close()
PY
TCP_SERVER=$!

ip netns exec "$LANDING_NS" python3 - <<'PY' &
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("10.203.2.2", 8082))
data, peer = s.recvfrom(1024)
s.sendto(peer[0].encode(), peer)
s.close()
PY
UDP_SERVER=$!
sleep 0.3

TCP_SOURCE=$(ip netns exec "$CLIENT_NS" python3 - <<'PY'
import socket
for port in (18080, 18081):
    s = socket.create_connection(("10.203.1.1", port), timeout=3)
    print(s.recv(128).decode())
    s.close()
PY
)
[ "$TCP_SOURCE" = $'8080|10.203.2.1\n8081|10.203.2.1' ] \
    || { echo "Masquerade source mismatch: $TCP_SOURCE" >&2; exit 1; }

UDP_SOURCE=$(ip netns exec "$CLIENT_NS" python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"probe", ("10.203.1.1", 18082))
print(s.recv(128).decode())
s.close()
PY
)
[ "$UDP_SOURCE" = 10.203.1.2 ] \
    || { echo "Preserved UDP source mismatch: $UDP_SOURCE" >&2; exit 1; }

wait "$TCP_SERVER"
wait "$UDP_SERVER"
ip netns exec "$RELAY_NS" nft list table ip quench_integration_user >/dev/null
ip netns exec "$RELAY_NS" nft list table ip quench_nft4 | grep -q 'quench-forward-1-tcp'
ip netns exec "$RELAY_NS" nft list table ip quench_nft4 | grep -q 'quench-forward-2-udp'

echo "NFT TCP/UDP network-namespace integration test passed."
