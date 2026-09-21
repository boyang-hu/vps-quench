#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

t_plan() {
    local A B C DEFAULT TARGET
    read -r A DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 400 150 8192 proxy)"
    read -r B DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 600 150 8192 proxy)"
    read -r C DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 400 300 8192 proxy)"
    [ "$A" -lt "$B" ] && [ "$A" -lt "$C" ] || fail 'bandwidth and RTT must drive the proposal'
    assert_eq "$A" 17104896
    read -r A DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 10000 150 512 bulk)"
    assert_eq "$A" 16777216
    assert_eq "$DEFAULT" 8388608
    read -r A DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 100000 2000 65536 bulk)"
    assert_eq "$A" 268435456
    read -r A DEFAULT TARGET <<< "$(bbr_measure_buffer_plan 1 1 512 proxy)"
    assert_eq "$A" 4194304
    assert_eq "$DEFAULT" 1048576
    assert_fail bbr_measure_buffer_plan nope 150 512 proxy
    assert_fail bbr_measure_buffer_plan 600 0 512 proxy
    assert_fail bbr_measure_buffer_plan 600 150 0 proxy
    assert_fail bbr_measure_buffer_plan 600 150 512 unknown
    :
}
run_test 'Measured buffer math follows bandwidth and RTT; RAM only caps it' t_plan

t_generator() {
    SYSCTL_FILE="$TMP/generator.conf"; BBR_BASELINE_FILE="$TMP/baseline"
    sysctl() { echo 0; }
    local CONFIG
    CONFIG=$(bbr_measure_generate_config 600 150 4096 proxy)
    assert_contains "$CONFIG" 'tcp_rmem = 4096 1048576'
    ! grep -Eq 'tcp_congestion_control|default_qdisc|tcp_mem|adv_win_scale|min_free|ip_forward|notsent' <<< "$CONFIG" \
        || fail 'measured generator touched independent/high-risk knobs'
    printf 'net.ipv4.tcp_notsent_lowat = 131072\n' > "$SYSCTL_FILE"
    printf 'net.ipv4.tcp_notsent_lowat = 4294967295\n' > "$BBR_BASELINE_FILE"
    CONFIG=$(bbr_measure_generate_config 600 150 4096 proxy)
    assert_contains "$CONFIG" 'net.ipv4.tcp_notsent_lowat = 4294967295'
    : > "$BBR_BASELINE_FILE"
    CONFIG=$(bbr_measure_generate_config 600 150 4096 proxy 2>/dev/null)
    ! grep -q '没有原始' <<< "$CONFIG" || fail 'warning polluted sysctl config'
    ! grep -q 'notsent' <<< "$CONFIG" || fail 'invented unknown baseline'
    :
}
run_test 'Measured config preserves independent functions and restores only known notsent baseline' t_generator

setup_session() {
    CASE_DIR="$TMP/$1"; mkdir -p "$CASE_DIR/bin"
    QUENCH_PERF_REPORT_DIR="$CASE_DIR/reports"
    SYSCTL_FILE="$CASE_DIR/sysctl.conf"
    BBR_BASELINE_FILE="$CASE_DIR/baseline.conf"
    TC_STATE_FILE="$CASE_DIR/tc.state"
    BBR_CALIBRATION_RESULT_FILE="$CASE_DIR/calibration.state"
    LOG="$CASE_DIR/events"; : > "$LOG"
    MEASURE_N=0
    txn_write_begin() { echo lock >> "$LOG"; }
    txn_write_end() { echo unlock >> "$LOG"; }
    bbr_calibration_lock_acquire() { :; }
    bbr_calibration_lock_release() { :; }
    bbr_measure_dependencies() { :; }
    bbr_measure_resolve() { echo 192.0.2.10; }
    bbr_measure_peer_ready() { :; }
    bbr_measure_iface() { echo eth6; }
    bbr_measure_queue_guard() { :; }
    bbr_calibration_capture_qdisc() { echo capture >> "$LOG"; }
    bbr_calibration_set_fq() { echo fq >> "$LOG"; }
    bbr_calibration_restore_qdisc() { echo restore >> "$LOG"; }
    bbr_calibration_stop_child() { :; }
    bbr_runtime_snapshot() { echo 'net.core.rmem_max = 212992' > "$1"; }
    bbr_physical_memory_mb() { echo 4096; }
    bbr_tcp_fastopen_value() { echo 3; }
    bbr_backup_sysctl() { echo backup >> "$LOG"; }
    bbr_enable_core_locked() { echo core >> "$LOG"; }
    bbr_apply_sysctl() { printf '%s\n' "$1" > "$CASE_DIR/applied"; echo "apply $2" >> "$LOG"; }
    bbr_calibration_run() { printf 'calibrate %s %s\n' "$5" "$6" >> "$LOG"; }
    sleep() { :; }
    tc() { :; }
    bbr_calibration_measure() {
        MEASURE_N=$((MEASURE_N + 1))
        BBR_CAL_SENDER=620; BBR_CAL_RETRANS=2; BBR_CAL_LOSS=0.0001
        BBR_CAL_RECEIVER=600
        case "$MEASURE_N" in 3) BBR_CAL_RECEIVER=580 ;; 4) BBR_CAL_RECEIVER=620 ;; esac
        printf 'measure %s %s\n' "$5" "$6" >> "$LOG"
    }
    bbr_measure_yes() { return 0; }
}

t_session() {
    setup_session "$1"
    local CORE=n SHAPE=n
    if [ "$1" = combined ]; then CORE=y; SHAPE=y; fi
    assert_ok bbr_measure_session tune peer.test 5201 6 '' 150 proxy "$CORE" "$SHAPE"
    assert_file_contains "$CASE_DIR/applied" '带宽基准=600Mbps'
    assert_file_contains "$LOG" 'apply measured'
    assert_file_contains "$LOG" 'measure 4 after'
    assert_file_contains "$LOG" restore
    if [ "$1" = combined ]; then
        assert_file_contains "$LOG" core
        assert_file_contains "$LOG" 'calibrate 8 eth6'
    else
        ! grep -Eq '^core|^calibrate' "$LOG" || fail 'parameter-only workflow changed core/shaping'
    fi
    local REPORTS=("$QUENCH_PERF_REPORT_DIR"/run-*)
    assert_file_contains "${REPORTS[0]}/samples.tsv" probe
    assert_file_contains "${REPORTS[0]}/outcome.txt" 'exit_code=0'
    :
}
run_test 'Measured workflow derives config from samples, preserves core/tc when skipped, then verifies' t_session params
run_test 'Combined workflow explicitly enables core and calibrates the actual IPv6 egress' t_session combined

t_nominal() {
    setup_session nominal
    assert_ok bbr_measure_session tune peer.test 5201 4 400 200 bulk n n
    assert_file_contains "$CASE_DIR/applied" '带宽基准=400Mbps 目标RTT=200ms'
    :
}
run_test 'Known package bandwidth is explicitly distinguished from observed throughput' t_nominal

t_verify() {
    setup_session verify
    bbr_measure_queue_guard() { fail 'verification should allow external QoS'; }
    assert_ok bbr_measure_session verify peer.test 5201 6 '' 150 proxy n n
    ! grep -Eq '^fq|^restore|^capture|^core|^apply|^calibrate|^backup' "$LOG" || fail 'verification mutated configuration'
    [ ! -e "$CASE_DIR/applied" ] || fail 'verification wrote sysctl'
    :
}
run_test 'Standalone verification never changes queues or parameters' t_verify

t_failure() {
    setup_session "failure_$1"
    case "$1" in
        baseline) bbr_calibration_measure() { return 1; } ;;
        probe) bbr_calibration_set_fq() { echo fq >> "$LOG"; return 1; } ;;
        restore) bbr_calibration_restore_qdisc() { echo restore >> "$LOG"; return 1; } ;;
        route) bbr_measure_route_check() { return 1; } ;;
        guard) bbr_measure_queue_guard() { return 1; } ;;
        backup) bbr_backup_sysctl() { return 1; } ;;
        signal) bbr_calibration_set_fq() { echo fq >> "$LOG"; exit 130; } ;;
        cancelled) bbr_measure_yes() { return 1; } ;;
    esac
    if [ "$1" = cancelled ]; then
        assert_ok bbr_measure_session tune peer.test 5201 4 '' 150 proxy y y
    else
        assert_fail bbr_measure_session tune peer.test 5201 4 '' 150 proxy y y
    fi
    [ ! -e "$CASE_DIR/applied" ] || fail 'failed measurement still applied a preset'
    ! grep -Eq '^core|^calibrate' "$LOG" || fail 'failure enabled core/shaping'
    case "$1" in probe|restore|signal) assert_file_contains "$LOG" restore ;; esac
    assert_file_contains "$LOG" unlock
    :
}
for CASE in baseline probe restore route guard backup signal cancelled; do
    run_test "Stop without applying guessed config on $CASE" t_failure "$CASE"
done

t_post_failure() {
    setup_session "post_$1"
    case "$1" in
        apply) bbr_apply_sysctl() { echo attempt >> "$LOG"; return 1; } ;;
        shape) bbr_calibration_run() { return 1; } ;;
        verify) bbr_measure_pair() { [ "$1" != after ]; } ;;
    esac
    assert_fail bbr_measure_session tune peer.test 5201 4 '' 150 proxy y y
    assert_file_contains "$LOG" unlock
    local REPORTS=("$QUENCH_PERF_REPORT_DIR"/run-*)
    assert_file_contains "${REPORTS[0]}/outcome.txt" 'exit_code=1'
    :
}
for CASE in apply shape verify; do
    run_test "Do not report successful tuning after $CASE failure" t_post_failure "$CASE"
done

t_peer() {
    QUENCH_PERF_PEER=''; QUENCH_PERF_PORT=''
    bbr_measure_peer_pool() { printf 'far\nnear\nmiddle\n'; }
    bbr_measure_resolve() { echo "$1"; }
    bbr_measure_rtt() { case "$1" in far) echo 150 ;; near) echo 10 ;; middle) echo 30 ;; esac; }
    bbr_measure_peer_ready() { [ "$1:$2:$3" = near:5202:6 ]; }
    # command -v only; the network is mocked above.
    ping() { :; }
    assert_ok bbr_measure_pick_peer 6
    assert_eq "$QUENCH_PERF_PEER" near
    assert_eq "$QUENCH_PERF_PORT" 5202
    :
}
run_test 'Public selection orders by RTT, validates protocol, retries only candidate ports' t_peer

t_resolve() {
    timeout() { shift; "$@"; }
    getent() { printf '192.0.2.2 STREAM\n::ffff:192.0.2.3 STREAM\n2001:db8::2 STREAM\n'; }
    assert_eq "$(bbr_measure_resolve example.test 4)" 192.0.2.2
    assert_eq "$(bbr_measure_resolve example.test 6)" 2001:db8::2
    assert_fail bbr_measure_resolve --bad 4
    :
}
run_test 'Resolve to an explicit family, never IPv4-mapped IPv6' t_resolve

t_incomplete_sample() {
    local FILE="$TMP/sender-only.txt"
    printf '[  5] 0.00-8.00 sec 900 MBytes 944 Mbits/sec 12000 sender\n' > "$FILE"
    assert_fail bbr_calibration_parse_iperf "$FILE" 1
    printf '[  5] 0.00-8.00 sec 600 MBytes 620 Mbits/sec receiver\n' >> "$FILE"
    assert_eq "$(bbr_calibration_parse_iperf "$FILE" 1)" '944 12000 620'
    :
}
run_test 'Never substitute sender throughput for a missing receiver summary' t_incomplete_sample

t_guard() {
    TC_STATE_FILE="$TMP/no-tc-state"
    bbr_tc_is_owned() { return 1; }
    tc() { if [ "$1" = qdisc ]; then printf '%s\n' "$QDISC"; fi; }
    local QDISC='qdisc cake 20: root bandwidth 400Mbit'
    assert_fail bbr_measure_queue_guard eth0 tc
    QDISC='qdisc fq 0: root maxrate 400Mbit'
    assert_fail bbr_measure_queue_guard eth0 tc
    QDISC='qdisc fq 7ffd: root refcnt 2 limit 10000p'
    assert_ok bbr_measure_queue_guard eth0 tc
    QDISC='qdisc fq_codel 0: root refcnt 2'
    assert_ok bbr_measure_queue_guard eth0 tc
    :
}
run_test 'Reject external shaping but allow default and Quench unlimited FQ' t_guard

t_lock() {
    setup_session locked
    txn_write_begin() { return 1; }
    bbr_measure_dependencies() { fail 'dependencies ran without transaction lock'; }
    assert_fail bbr_measure_session tune peer.test 5201 4 '' 150 proxy y y
    :
}
run_test 'Pending transaction stops measurement before any network or configuration work' t_lock

t_registry() {
    setup_session registry
    quench_tmp_registry_init
    local PARENT_REGISTRY="$QUENCH_TMP_REGISTRY" SENTINEL
    SENTINEL=$(quench_mktemp "${TMPDIR:-/tmp}/quench-parent-test.XXXXXX")
    assert_ok bbr_measure_session verify peer.test 5201 4 '' 150 proxy n n
    [ -f "$PARENT_REGISTRY" ] && [ -f "$SENTINEL" ] || fail 'subworkflow cleaned parent temporaries'
    rm -f "$SENTINEL" "$PARENT_REGISTRY"
    QUENCH_TMP_REGISTRY=""
    :
}
run_test 'Subworkflow cleanup does not delete parent menu temporary resources' t_registry

t_low_samples() {
    setup_session low_samples
    bbr_calibration_measure() {
        MEASURE_N=$((MEASURE_N+1))
        [ "$MEASURE_N" -le 3 ] || return 1
        BBR_CAL_SENDER=600; BBR_CAL_RECEIVER=600; BBR_CAL_RETRANS=0; BBR_CAL_LOSS=0
    }
    assert_fail bbr_measure_session tune peer.test 5201 4 '' 150 proxy y y
    [ ! -e "$CASE_DIR/applied" ] || fail 'one successful bandwidth sample was enough to apply'
    assert_file_contains "$LOG" restore
    :
}
run_test 'Require at least two successful unlimited bandwidth samples' t_low_samples

t_route() {
    ip() {
        if [ "$1" = -6 ]; then echo '2001:db8::1 dev wan6 src 2001:db8::2 metric 100'
        else echo '192.0.2.1 via 192.0.2.254 dev wan4 src 192.0.2.2'; fi
    }
    assert_eq "$(bbr_measure_iface 2001:db8::1 6)" wan6
    assert_eq "$(bbr_measure_iface 192.0.2.1 4)" wan4
    :
}
run_test 'Resolve the peer-specific egress rather than the default IPv4 interface' t_route

t_reusable_queue() {
    CASE_DIR="$TMP/reusable_queue"; mkdir -p "$CASE_DIR"
    export QUENCH_TEST_TC_ROOT="$CASE_DIR"
    printf '%s\n' 'qdisc fq_codel 0: root refcnt 2' > "$CASE_DIR/qdisc"
    : > "$CASE_DIR/class"; : > "$CASE_DIR/filter"; : > "$CASE_DIR/writes"
    local FIXTURE_TC_SCRIPT="$ROOT/tests/lib/bbr-tc-fixture.sh"
    # Existing fixture is deliberately non-executable in a checkout; invoke via wrapper.
    tc() { bash "$FIXTURE_TC_SCRIPT" "$@"; }
    bbr_tc_is_owned() { return 1; }
    BBR_CAL_DEV=eth0; BBR_CAL_TC_BIN=tc; TC_STATE_FILE="$CASE_DIR/no-state"
    assert_ok bbr_calibration_capture_qdisc eth0 tc
    printf 'qdisc htb 1: root\n' > "$CASE_DIR/qdisc"
    assert_ok bbr_calibration_restore_qdisc
    assert_ok bbr_measure_queue_guard eth0 tc
    ! grep -q 'qdisc replace' "$CASE_DIR/writes" || fail 'unnecessarily recreated an already-restored default queue'
    printf 'qdisc fq 7ffd: root\n' > "$CASE_DIR/qdisc"
    assert_ok bbr_calibration_capture_qdisc eth0 tc
    printf 'qdisc htb 1: root\n' > "$CASE_DIR/qdisc"
    assert_ok bbr_calibration_restore_qdisc
    assert_ok bbr_measure_queue_guard eth0 tc
    # An acknowledged delete with no effect must never count as a successful restore.
    printf 'qdisc htb 1: root\n' > "$CASE_DIR/qdisc"
    : > "$CASE_DIR/no-effect"
    assert_fail bbr_calibration_restore_qdisc
    :
}
run_test 'Restored default queues remain eligible for subsequent tuning; verify actual restore' t_reusable_queue

t_aggregate() {
    setup_session "aggregate_$1"
    cp "$ROOT/tests/lib/bbr-tc-fixture.sh" "$CASE_DIR/bin/tc"
    chmod +x "$CASE_DIR/bin/tc"
    PATH="$CASE_DIR/bin:$PATH"
    unset -f tc bbr_calibration_run
    # Use the real scanning decision function, not the session fixture stub.
    source "$ROOT/src/modules/bbr.sh"
    TC_STATE_FILE="$CASE_DIR/tc.state"
    local TEST_STATUS="" APPLIED=0 SEEN8=0 RESTORE_RC="$1"
    default_iface() { echo eth4; }
    bbr_calibration_lock_acquire() { :; }
    bbr_calibration_write_result() { TEST_STATUS=$1; }
    bbr_calibration_capture_qdisc() { :; }
    bbr_calibration_traffic_mark() { :; }
    bbr_calibration_set_fq() { :; }
    bbr_calibration_finish() { trap - INT TERM HUP; return "$RESTORE_RC"; }
    bbr_tc_apply_selected_rate() { APPLIED=1; }
    bbr_calibration_measure() {
        BBR_CAL_SENDER=3000; BBR_CAL_RECEIVER=3000; BBR_CAL_RETRANS=9000; BBR_CAL_LOSS=2
        if [ "$5" = 8 ]; then
            SEEN8=1; BBR_CAL_SENDER=9000; BBR_CAL_RECEIVER=9000; BBR_CAL_LOSS=0.001
        fi
    }
    if [ "$RESTORE_RC" = 0 ]; then assert_ok bbr_calibration_run peer.test 5201 6 5000 8 wan6
    else assert_fail bbr_calibration_run peer.test 5201 6 5000 8 wan6; fi
    assert_eq "$SEEN8" 1
    assert_eq "$BBR_CAL_DEV" wan6
    assert_eq "$TEST_STATUS" NO_KNEE
    assert_eq "$APPLIED" 0
    :
}
run_test 'High-bandwidth scan uses eight-stream confirmation and the selected egress' t_aggregate 0
run_test 'Calibration restore failure prevents subsequent persistent actions' t_aggregate 1

test_summary 'Measured performance workflow'
