#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
command -v cmp >/dev/null 2>&1 || { echo 'BBR separation tests require cmp (diffutils).' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
QUENCH_TXN_DIR="$TMP/transactions"
QUENCH_TXN_LOCK_FILE="$TMP/lock"
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_bbr() {
    CASE_DIR="$TMP/$1"
    mkdir -p "$CASE_DIR/bin" "$CASE_DIR/tc" "$CASE_DIR/sysctl"
    export QUENCH_TEST_TC_ROOT="$CASE_DIR/tc"
    cp "$ROOT/tests/lib/bbr-tc-fixture.sh" "$CASE_DIR/bin/tc"
    chmod +x "$CASE_DIR/bin/tc"
    export PATH="$CASE_DIR/bin:$PATH"
    SYSCTL_FILE="$CASE_DIR/quench-bbr.conf"
    BBR_BASELINE_FILE="$CASE_DIR/baseline.conf"
    TC_STATE_FILE="$CASE_DIR/tc.state"
    TC_BACKUP_DIR="$CASE_DIR/tc-backups"
    TC_HELPER="$CASE_DIR/tc-helper"
    SERVICE_TC="$CASE_DIR/tc.service"
    SERVICE_TC_INIT="$CASE_DIR/tc.init"
    printf 'qdisc fq_codel 0: root refcnt 2\n' > "$QUENCH_TEST_TC_ROOT/qdisc"
    : > "$QUENCH_TEST_TC_ROOT/class"
    : > "$QUENCH_TEST_TC_ROOT/filter"
    : > "$QUENCH_TEST_TC_ROOT/writes"
    : > "$CASE_DIR/sysctl-writes"
    printf 'cubic\n' > "$CASE_DIR/sysctl/net.ipv4.tcp_congestion_control"
    printf 'fq_codel\n' > "$CASE_DIR/sysctl/net.core.default_qdisc"
    printf '212992\n' > "$CASE_DIR/sysctl/net.core.rmem_max"
    printf '1\n' > "$CASE_DIR/sysctl/net.ipv4.ip_forward"
    sysctl() {
        case "$1" in
            -n) [ ! -f "$CASE_DIR/stale" ] || { echo stale; return; }; cat "$CASE_DIR/sysctl/$2" 2>/dev/null ;;
            -w)
                printf '%s\n' "$2" >> "$CASE_DIR/sysctl-writes"
                if [ -f "$CASE_DIR/fail-fq" ] && [ "$2" = net.core.default_qdisc=fq ]; then return 1; fi
                printf '%s\n' "${2#*=}" > "$CASE_DIR/sysctl/${2%%=*}"
                ;;
            *) return 1 ;;
        esac
    }
    ensure_sysctl() { :; }
    bbr_core_preflight() { :; }
    bbr_preflight() { :; }
    bbr_managed_keys() { printf '%s\n' net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.ipv4.ip_forward; }
    default_iface() { echo eth0; }
    bbr_default_ipv6_iface() { echo eth0; }
    bbr_tc_snapshot_foreign() { printf '%s\n' "$QUENCH_TEST_TC_ROOT/qdisc"; }
    bbr_tc_reconcile_saved() { fail 'implicit tc reconciliation'; }
    systemd_available() { return 0; }
    systemctl() { [ ! -f "$CASE_DIR/service-fail" ]; }
    bbr_tc_write_persistence() {
        printf 'DEV=%s\nRATE=%s\nBURST_KB=%s\nFORCE=%s\n' "$1" "$2" "$3" "$4" > "$TC_STATE_FILE"
    }
}

core() { bbr_enable_core <<< y; }
assert_only_core() {
    ! grep -Ev '^net\.(core\.default_qdisc|ipv4\.tcp_congestion_control)=' "$CASE_DIR/sysctl-writes" | grep -q . \
        || fail 'basic mode changed non-core sysctls'
}

t_core_only() {
    setup_bbr core_only
    assert_ok core
    assert_only_core
    assert_eq "$(wc -l < "$CASE_DIR/sysctl-writes" | tr -d ' ')" 2
    assert_eq "$(sysctl -n net.core.rmem_max)" 212992
    assert_eq "$(sysctl -n net.ipv4.ip_forward)" 1
    assert_eq "$(wc -l < "$SYSCTL_FILE" | tr -d ' ')" 2
    assert_ok bbr_fq_runtime_ready "$(cat "$QUENCH_TEST_TC_ROOT/qdisc")"
    [ ! -e "$TC_STATE_FILE" ] && [ ! -e "$SERVICE_TC" ] || fail 'basic mode installed shaping persistence'
    ! grep -Eq 'htb|maxrate|class ' "$QUENCH_TEST_TC_ROOT/writes" || fail 'basic mode shapes bandwidth'
    :
}
run_test 'Basic BBR/FQ changes exactly two sysctls and installs no limiter' t_core_only

t_integration_sysctl_scope() {
    setup_bbr integration_sysctl_scope
    QUENCH_TEST_INTEGRATION_ROOT="$CASE_DIR"
    # Reuse the real integration fixture without creating links or namespaces.
    # This also exercises it on macOS and in every distribution smoke job.
    eval "$(sed -n '/^sysctl() {/,/^}/p' "$ROOT/tests/bbr-separation-integration.sh")"
    local TMP="$CASE_DIR/not-the-fixture-directory"
    assert_ok bbr_runtime_snapshot "$CASE_DIR/runtime.conf"
    assert_file_contains "$CASE_DIR/runtime.conf" 'net.core.default_qdisc = fq_codel'
    assert_file_contains "$CASE_DIR/runtime.conf" 'net.ipv4.tcp_congestion_control = cubic'
    assert_ok bbr_apply_sysctl $'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr' core
    assert_eq "$(sysctl -n net.core.default_qdisc)" fq
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" bbr
    assert_file_contains "$BBR_BASELINE_FILE" 'net.ipv4.tcp_congestion_control = cubic'
    [ ! -e "$TMP" ] || fail 'integration fixture wrote through a caller-local TMP'
    :
}
run_test 'Integration sysctl fixture survives caller-local TMP during snapshot and apply' t_integration_sysctl_scope

t_preserve_tuning() {
    setup_bbr preserve_tuning
    printf '%s\n' '# keep this configuration' 'net.core.rmem_max = 123456' 'net.ipv4.ip_forward = 1' \
        'net.ipv4.tcp_congestion_control = cubic' > "$SYSCTL_FILE"
    assert_ok core
    assert_only_core
    assert_file_contains "$SYSCTL_FILE" 'net.core.rmem_max = 123456'
    assert_file_contains "$SYSCTL_FILE" 'net.ipv4.ip_forward = 1'
    cp "$SYSCTL_FILE" "$CASE_DIR/once"
    : > "$QUENCH_TEST_TC_ROOT/writes"
    assert_ok core
    assert_ok cmp "$SYSCTL_FILE" "$CASE_DIR/once"
    [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'repeat core call reset runtime queue'
    :
}
run_test 'Basic mode preserves old tuning and forwarding without reapplying it' t_preserve_tuning

t_tuning_only() {
    setup_bbr tuning_only
    printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' > "$SYSCTL_FILE"
    # Runtime may intentionally differ from saved config; parameter tuning must not change it.
    echo saved-rate > "$TC_STATE_FILE"
    assert_ok bbr_apply_sysctl 'net.core.rmem_max = 67108864' tuning
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" cubic
    assert_eq "$(sysctl -n net.core.default_qdisc)" fq_codel
    assert_eq "$(cat "$CASE_DIR/sysctl-writes")" net.core.rmem_max=67108864
    assert_file_contains "$SYSCTL_FILE" 'net.ipv4.tcp_congestion_control = bbr'
    assert_file_contains "$SYSCTL_FILE" 'net.core.default_qdisc = fq'
    [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'tuning touched qdisc'
    :
}
run_test 'Parameter tuning preserves both live and saved congestion/queue settings' t_tuning_only

t_generator() {
    setup_bbr generator
    bbr_physical_memory_mb() { echo 1024; }
    local CONFIG
    CONFIG=$(bbr_generate_config 16777216 16777216 131072 balanced 0)
    ! grep -Eq 'tcp_congestion_control|default_qdisc' <<< "$CONFIG" || fail 'tuning generator still enables BBR/FQ'
    bbr_check_kernel() { fail 'parameter tuning queried BBR'; }
    has_sysctl_write() { return 0; }
    # Test actual generic preflight, not the fixture stub.
    eval "$(sed -n '/^bbr_preflight() {/,/^}/p' "$ROOT/src/modules/bbr.sh")"
    assert_ok bbr_preflight
    :
}
run_test 'Tuning presets do not require or select BBR' t_generator

t_preserve_queue() {
    setup_bbr "queue_$1"
    case "$1" in
        owned)
            printf 'DEV=eth0\nRATE=600\nBURST_KB=293\nFORCE=0\n' > "$TC_STATE_FILE"
            printf '%s\n' 'qdisc htb 1: root' 'qdisc fq 100: parent 1:10 maxrate 400Mbit' > "$QUENCH_TEST_TC_ROOT/qdisc"
            echo 'class htb 1:10 root rate 400Mbit ceil 400Mbit' > "$QUENCH_TEST_TC_ROOT/class" ;;
        external) echo 'qdisc htb 10: root default 1' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
        cake) echo 'qdisc cake 8001: root bandwidth 400Mbit' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
        fq_rate) echo 'qdisc fq 8011: root maxrate 400Mbit' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
        custom_default) echo 'qdisc fq_codel 1234: root' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
        custom_mq) printf '%s\n' 'qdisc mq 0: root' 'qdisc fq 8001: parent :1 maxrate 400Mbit' 'qdisc fq_codel 0: parent :2' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
        filter) echo 'filter protocol ip pref 1 u32' > "$QUENCH_TEST_TC_ROOT/filter" ;;
        nopacing) echo 'qdisc fq 1234: root nopacing' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
    esac
    cp "$QUENCH_TEST_TC_ROOT/qdisc" "$CASE_DIR/before"
    assert_ok core
    assert_ok cmp "$QUENCH_TEST_TC_ROOT/qdisc" "$CASE_DIR/before"
    [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'core modified an existing queue/rate'
    :
}
for CASE in owned external cake fq_rate custom_default custom_mq filter nopacing; do
    run_test "Preserve existing queue: $CASE" t_preserve_queue "$CASE"
done

t_mq() {
    setup_bbr mq
    printf '%s\n' 'qdisc mq 0: root' 'qdisc fq_codel 0: parent :1' 'qdisc fq_codel 0: parent :2' > "$QUENCH_TEST_TC_ROOT/qdisc"
    assert_ok core
    assert_file_contains "$QUENCH_TEST_TC_ROOT/qdisc" 'qdisc mq '
    assert_ok bbr_fq_runtime_ready "$(cat "$QUENCH_TEST_TC_ROOT/qdisc")"
    ! grep -q 'root handle 7ffd: fq' "$QUENCH_TEST_TC_ROOT/writes" || fail 'flattened multiqueue interface'
    :
}
run_test 'Default mq retains multiple queues and verifies FQ leaves' t_mq

t_failure() {
    setup_bbr "failure_$1"
    case "$1" in
        sysctl) : > "$CASE_DIR/fail-fq" ;;
        tc) : > "$QUENCH_TEST_TC_ROOT/fail" ;;
        readback) : > "$QUENCH_TEST_TC_ROOT/no-effect" ;;
    esac
    assert_fail core
    if [ "$1" = sysctl ]; then
        assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" cubic
        assert_eq "$(sysctl -n net.core.default_qdisc)" fq_codel
        [ ! -e "$SYSCTL_FILE" ] || fail 'failed sysctl persisted'
        [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'changed queue after sysctl failed'
    fi
    :
}
for CASE in sysctl tc readback; do
    run_test "Report basic configuration failure: $CASE" t_failure "$CASE"
done

t_shape_remove() {
    setup_bbr shape_remove
    assert_ok core
    : > "$CASE_DIR/sysctl-writes"
    cp "$SYSCTL_FILE" "$CASE_DIR/before"
    assert_ok bbr_apply_tc 400
    assert_ok bbr_tc_rate_matches eth0 "$(command -v tc)" 400
    assert_ok cmp "$SYSCTL_FILE" "$CASE_DIR/before"
    assert_ok bbr_remove_tc
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" bbr
    assert_ok bbr_fq_runtime_ready "$(cat "$QUENCH_TEST_TC_ROOT/qdisc")"
    ! grep -Eq 'htb|maxrate' "$QUENCH_TEST_TC_ROOT/qdisc" || fail 'limiter survives cancel'
    [ ! -s "$CASE_DIR/sysctl-writes" ] || fail 'tc changed sysctl'
    [ ! -e "$TC_STATE_FILE" ] || fail 'cancel left saved limiter'
    :
}
run_test 'Enable core, independently shape, cancel shaping: BBR and unlimited FQ survive' t_shape_remove

t_shape_only() {
    setup_bbr shape_only
    assert_ok bbr_apply_tc 600
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" cubic
    assert_eq "$(sysctl -n net.core.default_qdisc)" fq_codel
    assert_ok bbr_remove_tc
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" cubic
    [ ! -e "$SYSCTL_FILE" ] && [ ! -s "$CASE_DIR/sysctl-writes" ] || fail 'standalone tc implicitly enabled BBR'
    :
}
run_test 'Standalone shaping works without enabling BBR or changing sysctls' t_shape_only

t_remove_failure() {
    setup_bbr "remove_$1"
    assert_ok core
    assert_ok bbr_apply_tc 400
    case "$1" in
        delete) : > "$QUENCH_TEST_TC_ROOT/fail" ;;
        no_effect) : > "$QUENCH_TEST_TC_ROOT/no-effect" ;;
        service) : > "$SERVICE_TC"; : > "$CASE_DIR/service-fail" ;;
    esac
    assert_fail bbr_remove_tc
    [ -s "$TC_STATE_FILE" ] || fail 'cancel failure deleted saved recovery state'
    assert_eq "$(sysctl -n net.ipv4.tcp_congestion_control)" bbr
    :
}
run_test 'Queue deletion failure preserves limiter recovery state' t_remove_failure delete
run_test 'A successful delete with an unchanged HTB must not discard recovery state' t_remove_failure no_effect
run_test 'Service disable failure preserves limiter recovery state' t_remove_failure service

t_lock_rejection() {
    setup_bbr blocked
    txn_write_begin() { return 1; }
    assert_fail core
    assert_fail bbr_apply_tc 400
    assert_fail bbr_remove_tc
    [ ! -s "$CASE_DIR/sysctl-writes" ] && [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'writes crossed lock guard'
    :
}
run_test 'Core and shaping entry points respect the configuration transaction guard' t_lock_rejection

t_measured_merge() {
    setup_bbr measured_merge
    printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' \
        'net.ipv4.ip_forward = 1' 'net.core.rmem_max = 212992' > "$SYSCTL_FILE"
    assert_ok bbr_apply_sysctl 'net.core.rmem_max = 16777216' measured
    assert_eq "$(sysctl -n net.core.rmem_max)" 16777216
    assert_eq "$(cat "$CASE_DIR/sysctl-writes")" net.core.rmem_max=16777216
    assert_file_contains "$SYSCTL_FILE" 'net.ipv4.ip_forward = 1'
    assert_file_contains "$SYSCTL_FILE" 'net.ipv4.tcp_congestion_control = bbr'
    assert_eq "$(grep -c '^net.core.rmem_max' "$SYSCTL_FILE")" 1
    [ ! -s "$QUENCH_TEST_TC_ROOT/writes" ] || fail 'measured sysctl touched queues'
    :
}
run_test 'Measured apply changes only proposed keys and retains unrelated saved policies' t_measured_merge

t_measured_failure() {
    setup_bbr "measured_failure_$1"
    printf 'net.core.rmem_max = 212992\n' > "$SYSCTL_FILE"
    cp "$SYSCTL_FILE" "$CASE_DIR/before.conf"
    local MODE="$1"
    sysctl() {
        case "$1" in
            -n) cat "$CASE_DIR/sysctl/$2" 2>/dev/null ;;
            -w)
                printf '%s\n' "$2" >> "$CASE_DIR/sysctl-writes"
                if [ "$2" = net.core.rmem_max=16777216 ]; then
                    [ "$MODE" != reject ] || return 1
                    return 0 # Pretend success but do not change the kernel value.
                fi
                printf '%s\n' "${2#*=}" > "$CASE_DIR/sysctl/${2%%=*}"
                ;;
        esac
    }
    assert_fail bbr_apply_sysctl 'net.core.rmem_max = 16777216' measured
    assert_ok cmp "$SYSCTL_FILE" "$CASE_DIR/before.conf"
    assert_eq "$(sysctl -n net.core.rmem_max)" 212992
    :
}
run_test 'Rejected measured parameter rolls back and retains old configuration' t_measured_failure reject
run_test 'Measured parameter readback mismatch is a transaction failure' t_measured_failure stale

test_summary 'BBR/FQ and tc separation'
