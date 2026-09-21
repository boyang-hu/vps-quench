#!/usr/bin/env bash
# Real Linux qdisc test; all links are created in a fresh network namespace.
# sysctl persistence/services are fixtures: never change host-wide default_qdisc.
set -euo pipefail
exec < /dev/null
if [ "$(uname -s)" != Linux ]; then
    echo 'This integration test requires Linux, root, iproute2 and unshare.' >&2
    exit 1
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CURRENT_NS=$(readlink /proc/self/ns/net)
if [ -z "${QUENCH_TEST_PARENT_NETNS:-}" ]; then
    exec unshare --net env QUENCH_TEST_PARENT_NETNS="$CURRENT_NS" bash "$0"
fi
[ "$CURRENT_NS" != "$QUENCH_TEST_PARENT_NETNS" ] || { echo 'Refusing host network namespace' >&2; exit 1; }
QUENCH_TEST_INTEGRATION_ROOT=$(mktemp -d)
trap 'rm -rf "$QUENCH_TEST_INTEGRATION_ROOT"' EXIT
export QUENCH_TEST_MODE=1
QUENCH_TXN_DIR="$QUENCH_TEST_INTEGRATION_ROOT/transactions"
QUENCH_TXN_LOCK_FILE="$QUENCH_TEST_INTEGRATION_ROOT/lock"
source "$ROOT/vps-quench.sh"
TC_STATE_FILE="$QUENCH_TEST_INTEGRATION_ROOT/tc.state"
TC_BACKUP_DIR="$QUENCH_TEST_INTEGRATION_ROOT/tc-backups"
TC_HELPER="$QUENCH_TEST_INTEGRATION_ROOT/tc-helper"
SERVICE_TC="$QUENCH_TEST_INTEGRATION_ROOT/tc.service"
SERVICE_TC_INIT="$QUENCH_TEST_INTEGRATION_ROOT/tc.init"
SYSCTL_FILE="$QUENCH_TEST_INTEGRATION_ROOT/quench-bbr.conf"
BBR_BASELINE_FILE="$QUENCH_TEST_INTEGRATION_ROOT/baseline.conf"
TC_BIN=$(command -v tc)
mkdir "$QUENCH_TEST_INTEGRATION_ROOT/sysctl"
printf 'cubic\n' > "$QUENCH_TEST_INTEGRATION_ROOT/sysctl/net.ipv4.tcp_congestion_control"
printf 'fq_codel\n' > "$QUENCH_TEST_INTEGRATION_ROOT/sysctl/net.core.default_qdisc"
# Bash functions inherit caller locals. Do not use generic TMP/ROOT here:
# bbr_runtime_snapshot has its own local TMP holding a file, not this directory.
sysctl() {
    case "$1" in
        -n) cat "$QUENCH_TEST_INTEGRATION_ROOT/sysctl/$2" 2>/dev/null ;;
        -w) printf '%s\n' "${2#*=}" > "$QUENCH_TEST_INTEGRATION_ROOT/sysctl/${2%%=*}" ;;
        *) return 1 ;;
    esac
}
ensure_sysctl() { :; }
bbr_core_preflight() { :; }
default_iface() { echo quench0; }
bbr_default_ipv6_iface() { echo quench0; }
bbr_managed_keys() { printf '%s\n' net.core.default_qdisc net.ipv4.tcp_congestion_control; }
systemd_available() { return 0; }
systemctl() { :; }
bbr_tc_write_persistence() {
    printf 'DEV=%s\nRATE=%s\nBURST_KB=%s\nFORCE=%s\n' "$1" "$2" "$3" "$4" > "$TC_STATE_FILE"
}
ip link add quench0 type veth peer name quench1
ip link set quench0 up
ip link set quench1 up
bbr_enable_core <<< y
bbr_fq_runtime_ready "$(tc qdisc show dev quench0)"
bbr_apply_tc 400
bbr_tc_rate_matches quench0 "$TC_BIN" 400
# Emulate an external manual rate adjustment: basic mode must not undo it.
tc class change dev quench0 parent 1: classid 1:10 htb rate 300mbit ceil 300mbit
bbr_enable_core <<< y
bbr_tc_rate_matches quench0 "$TC_BIN" 300
bbr_remove_tc
bbr_fq_runtime_ready "$(tc qdisc show dev quench0)"
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]
[ ! -e "$TC_STATE_FILE" ]
# Temporary measurement followed by restoration must not turn our unlimited
# queue into an unrecognised externally-owned queue (auto-assigned tc handles).
BBR_CAL_DEV=quench0; BBR_CAL_TC_BIN="$TC_BIN"
bbr_measure_queue_guard quench0 "$TC_BIN"
bbr_calibration_capture_qdisc quench0 "$TC_BIN"
bbr_calibration_apply_shaper quench0 200 "$TC_BIN"
bbr_calibration_restore_qdisc
bbr_measure_queue_guard quench0 "$TC_BIN"
bbr_fq_runtime_ready "$(tc qdisc show dev quench0)"
# An external TBF must remain bit-for-bit unchanged after enabling the core.
tc qdisc replace dev quench0 root handle 20: tbf rate 200mbit burst 256kb latency 50ms
BEFORE=$(tc qdisc show dev quench0)
bbr_enable_core <<< y
[ "$(tc qdisc show dev quench0)" = "$BEFORE" ]
echo 'Isolated Linux FQ / HTB separation integration passed.'
