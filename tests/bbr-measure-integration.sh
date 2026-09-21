#!/usr/bin/env bash
# No public traffic and no host-network writes. Exercise the actual iperf3 client/parser.
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ "$(uname -s)" = Linux ] || { echo 'Requires Linux, unshare, iproute2 and iperf3' >&2; exit 1; }
CURRENT_NS=$(readlink /proc/self/ns/net)
if [ -z "${QUENCH_TEST_PARENT_NETNS:-}" ]; then
    exec unshare --net env QUENCH_TEST_PARENT_NETNS="$CURRENT_NS" bash "$0"
fi
[ "$CURRENT_NS" != "$QUENCH_TEST_PARENT_NETNS" ] || { echo 'Refusing host namespace' >&2; exit 1; }
TMP=$(mktemp -d)
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
QUENCH_PERF_REPORT_DIR="$TMP/reports"
QUENCH_TXN_DIR="$TMP/transactions"
QUENCH_TXN_LOCK_FILE="$TMP/txn.lock"
BBR_CALIBRATION_LOCK_FILE="$TMP/calibration.lock"
TC_STATE_FILE="$TMP/tc.state"
ip link set lo up
iperf3 -s -B 127.0.0.1 -p 5209 > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
READY=0
for TRY in 1 2 3 4 5; do
    if bbr_measure_peer_ready 127.0.0.1 5209 4; then READY=1; break; fi
    sleep 1
done
[ "$READY" = 1 ] || { cat "$TMP/server.log" >&2; exit 1; }
BEFORE=$(tc qdisc show dev lo)
for STREAMS in 1 4; do
    bbr_calibration_measure 127.0.0.1 5209 4 1 "$STREAMS" integration
    awk -v rate="$BBR_CAL_RECEIVER" 'BEGIN {exit !(rate>0)}'
done
bbr_measure_session verify 127.0.0.1 5209 4 '' 150 proxy n n
[ "$(tc qdisc show dev lo)" = "$BEFORE" ]
grep -q 'exit_code=0' "$TMP"/reports/run-*/outcome.txt
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
# A refused connection must fail rather than leave the preceding successful sample.
if bbr_calibration_measure 127.0.0.1 5209 4 1 1 refused; then
    echo 'Measurement accepted a stopped peer' >&2; exit 1
fi
[ -z "$BBR_CAL_RECEIVER" ]
echo 'Isolated real iperf3 measurement integration passed.'
