#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_scan() {
    CASE_DIR="$TMP/$1"; mkdir -p "$CASE_DIR"
    BBR_CALIBRATION_RESULT_FILE="$CASE_DIR/result"
    QUENCH_PERF_PEER=192.0.2.1; QUENCH_PERF_PORT=5201; QUENCH_PERF_FAMILY=6
    QUENCH_PERF_DEV=wan6; BBR_CAL_DEV=wan6; BBR_CAL_TC_BIN=tc
    QUENCH_PERF_REPORT="$CASE_DIR"
    QUENCH_PERF_AGREED_GB=10; QUENCH_PERF_RESTORE=0
    QUENCH_TMP_REGISTRY=''
    CURRENT_RATE=0; RESTORES=0; CALLS=0; SEEN8=0
    sleep() { :; }
    bbr_measure_queue_guard() { :; }
    bbr_measure_route_check() { :; }
    bbr_calibration_capture_qdisc() { :; }
    bbr_calibration_set_fq() { CURRENT_RATE=0; }
    bbr_calibration_apply_shaper() { assert_eq "$1" wan6; CURRENT_RATE=$2; }
    bbr_calibration_restore_qdisc() { RESTORES=$((RESTORES+1)); }
    bbr_measure_yes() { return 0; }
    bbr_tc_apply_selected_rate() { fail 'scan must not apply persistent shaping'; }
    bbr_calibration_measure() {
        assert_eq "$4" 12
        CALLS=$((CALLS+1))
        BBR_CAL_SENDER=600; BBR_CAL_RECEIVER=550; BBR_CAL_RETRANS=100; BBR_CAL_LOSS=2
        if [ "$CURRENT_RATE" -gt 0 ]; then
            BBR_CAL_RECEIVER=$CURRENT_RATE
            [ "$CURRENT_RATE" -gt 600 ] || BBR_CAL_LOSS=0.001
        fi
    }
}
status_is() { assert_eq "$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" STATUS)" "$1"; }

t_knee() {
    setup_scan knee
    assert_ok bbr_sweep_run 600
    status_is KNEE
    local K R
    K=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" KNEE_MBPS)
    R=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" RECOMMEND_MBPS)
    [ "$K" -ge 594 ] && [ "$K" -le 600 ] || fail 'fine sweep missed known 600M policer'
    assert_eq "$R" "$((K-15))"
    assert_eq "$RESTORES" 1
    assert_eq "$QUENCH_PERF_RESTORE" 0
    assert_file_contains "$CASE_DIR/samples.tsv" recheck
    assert_file_contains "$CASE_DIR/samples.tsv" unshaped
}
run_test 'Coarse scan, repeated spikes, fine scan, nominal margin and queue restoration' t_knee

t_clean() {
    setup_scan "$1"
    bbr_calibration_measure() {
        CALLS=$((CALLS+1)); BBR_CAL_SENDER=600; BBR_CAL_RETRANS=0; BBR_CAL_LOSS=0
        BBR_CAL_RECEIVER=600
        [ "$MODE" != slow ] || BBR_CAL_RECEIVER=100
    }
    local MODE="$1"
    assert_ok bbr_sweep_run 600
    if [ "$MODE" = slow ]; then status_is INCONCLUSIVE; assert_eq "$CALLS" 3
    else status_is NO_KNEE; assert_eq "$CALLS" 1; fi
    assert_eq "$RESTORES" 1
}
run_test 'Clean capacity means no knee without unnecessary scan' t_clean clean
run_test 'Three slow clean samples cannot invalidate prior shaping' t_clean slow

t_aggregate() {
    setup_scan "aggregate-$1"
    local MODE="$1"
    bbr_calibration_measure() {
        CALLS=$((CALLS+1)); BBR_CAL_SENDER=3000; BBR_CAL_RECEIVER=3000
        BBR_CAL_RETRANS=100; BBR_CAL_LOSS=2
        if [ "$5" = 8 ]; then
            SEEN8=1; BBR_CAL_LOSS=0; BBR_CAL_RECEIVER=9000
            case "$MODE" in slow) BBR_CAL_RECEIVER=1000 ;; cap) BBR_CAL_RECEIVER=12000 ;; esac
        fi
    }
    assert_ok bbr_sweep_run 5000
    assert_eq "$SEEN8" 1
    case "$MODE" in slow) status_is INCONCLUSIVE ;; cap) status_is ABOVE_CAP ;; *) status_is NO_KNEE ;; esac
}
for MODE in clean slow cap; do run_test "Eight-stream high-bandwidth confirmation: $MODE" t_aggregate "$MODE"; done

t_fault() {
    setup_scan "fault-$1"
    case "$1" in
        baseline) bbr_calibration_measure() { return 1; } ;;
        apply) bbr_calibration_apply_shaper() { return 1; } ;;
        restore) bbr_calibration_restore_qdisc() { return 1; } ;;
        route) bbr_measure_route_check() { return 1; } ;;
        write) bbr_calibration_write_result() { return 1; } ;;
    esac
    assert_fail bbr_sweep_run 600
    if [ "$1" = baseline ]; then
        assert_eq "$RESTORES" 1; assert_eq "$QUENCH_PERF_RESTORE" 0
    else
        [ "$QUENCH_PERF_RESTORE" = 1 ] || fail 'failed scan did not request cleanup restoration'
    fi
}
for MODE in baseline apply restore route write; do run_test "Scan failure retains restoration duty: $MODE" t_fault "$MODE"; done

t_gap() {
    setup_scan gap
    bbr_calibration_measure() {
        BBR_CAL_SENDER=600; BBR_CAL_RECEIVER=550; BBR_CAL_RETRANS=10; BBR_CAL_LOSS=2
        if [ "$CURRENT_RATE" -gt 0 ]; then
            [ "$CURRENT_RATE" != 541 ] || return 1
            BBR_CAL_RECEIVER=$CURRENT_RATE
            [ "$CURRENT_RATE" -gt 600 ] || BBR_CAL_LOSS=0.001
        fi
    }
    assert_ok bbr_sweep_run 600
    status_is INCONCLUSIVE
}
run_test 'Missing scan point cannot produce a persistent recommendation' t_gap

t_cancel() {
    setup_scan cancel
    bbr_measure_yes() { return 1; }
    assert_ok bbr_sweep_run 100
    status_is CANCELLED
    assert_eq "$CURRENT_RATE" 0
    assert_eq "$RESTORES" 1
}
run_test 'Actual capacity far above declared bandwidth asks before spending scan traffic' t_cancel

t_floor_noise() {
    setup_scan noise
    bbr_calibration_measure() {
        BBR_CAL_SENDER=250; BBR_CAL_RECEIVER=200; BBR_CAL_RETRANS=100; BBR_CAL_LOSS=0.3
        if [ "$CURRENT_RATE" -gt 0 ]; then
            BBR_CAL_RECEIVER=$CURRENT_RATE
            [ "$CURRENT_RATE" -lt 220 ] || BBR_CAL_LOSS=1.35
        fi
    }
    assert_ok bbr_sweep_run 250
    status_is KNEE
    assert_file_contains "$CASE_DIR/samples.tsv" scan-142
}
run_test 'Low-rate control recognizes stable path loss but still detects a 1.35 percent spike' t_floor_noise

t_threshold() {
    QUENCH_SWEEP_BASE=0.3
    assert_fail bbr_sweep_spike 0.9
    assert_ok bbr_sweep_spike 1.01
    QUENCH_SWEEP_BASE=0.01
    assert_fail bbr_sweep_spike 0.1
    assert_ok bbr_sweep_spike 0.101
}
run_test 'Spike threshold is max(0.1, five times baseline), capped at one percent' t_threshold

t_retry() {
    local COUNT=0 GAPS=0
    QUENCH_PERF_PORT=5201; QUENCH_PERF_PORTS=$'5201\n5202\n5203'
    bbr_calibration_measure_once() {
        COUNT=$((COUNT+1)); QUENCH_PERF_RETRYABLE=1
        [ "$COUNT" = 8 ]
    }
    sleep() { assert_eq "$1" 8; GAPS=$((GAPS+1)); }
    assert_ok bbr_measure_sample_retry 192.0.2.1 5201 6 10 4 probe
    assert_eq "$COUNT" 8; assert_eq "$GAPS" 2; assert_eq "$QUENCH_PERF_PORT" 5202
}
run_test 'Public measurement rotates advertised ports across three rounds with eight-second gaps' t_retry

t_budget() {
    local INPUT EXPECTED
    while read -r INPUT EXPECTED; do
        assert_eq "$(bbr_calibration_margin "$INPUT")" "$EXPECTED"
    done <<'CASES'
30 1
31 2
60 2
61 5
100 5
101 10
300 10
301 15
600 15
601 25
1000 25
1001 40
CASES
}
run_test 'Bandwidth margin boundaries match the reference table' t_budget

t_endpoint() {
    assert_ok bbr_measure_endpoint '[2001:db8::1]:5210'
    assert_eq "$QUENCH_PERF_INPUT_HOST" 2001:db8::1; assert_eq "$QUENCH_PERF_INPUT_PORT" 5210
    assert_ok bbr_measure_endpoint '2001:db8::1'
    assert_eq "$QUENCH_PERF_INPUT_PORT" 5201
    assert_ok bbr_measure_endpoint peer.test:5001
    assert_eq "$QUENCH_PERF_INPUT_HOST" peer.test
    assert_fail bbr_measure_endpoint peer.test:65536
    assert_fail bbr_measure_endpoint '-c'
}
run_test 'Custom endpoint supports IPv4, IPv6 and ports without accepting options' t_endpoint

t_cwnd() {
    local MODE="$1" REMOVED=0 APPLIED=0 PERSISTED=0
    CWND_STATE_FILE="$TMP/cwnd-$MODE"; : > "$CWND_STATE_FILE"
    QUENCH_PERF_FAMILY=6; QUENCH_PERF_DEV=wan6
    bbr_remove_initcwnd_locked() { assert_eq "$1" owned; REMOVED=1; }
    ip() { echo 'default dev wan6 initcwnd 32 initrwnd 32'; }
    bbr_apply_initcwnd_route() { assert_eq "$1" 6; assert_eq "$3" 32; assert_eq "$4" 32; APPLIED=1; }
    bbr_cwnd_write_persistence() { PERSISTED=1; }
    if [ "$MODE" = small ]; then
        assert_ok bbr_measure_cwnd 100
        assert_eq "$REMOVED" 1; assert_eq "$APPLIED" 0
    else
        assert_ok bbr_measure_cwnd 101
        assert_eq "$REMOVED" 0; assert_eq "$PERSISTED" 1
    fi
}
run_test 'At 100Mbps only owned initial-window overrides are cleared' t_cwnd small
run_test 'Above 100Mbps the actual route receives 32/32 and persistence' t_cwnd large

t_full_parameter_fixture() {
    # Reference: Kylin010/tcpfit 38fbf5af, 600Mbps / 150ms / 4096MiB / proxy.
    SYSCTL_FILE="$TMP/no-existing"
    bbr_measure_generate_config 600 150 4096 proxy | sed '/^#/d' | sort > "$TMP/actual-params"
    sort > "$TMP/expected-params" <<'PARAMS'
net.core.rmem_max = 24597152
net.core.wmem_max = 24597152
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 24597152
net.ipv4.tcp_wmem = 4096 1048576 24597152
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.optmem_max = 65536
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
vm.min_free_kbytes = 32768
fs.file-max = 1000000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
PARAMS
    assert_ok diff -u "$TMP/expected-params" "$TMP/actual-params"
    bbr_default_ipv6_iface() { :; }
    assert_ok bbr_managed_keys > "$TMP/managed-keys"
    local KEY
    while read -r KEY; do
        grep -qxF "$KEY" "$TMP/managed-keys" || fail "$KEY missing from backup inventory"
    done < <(awk '{print $1}' "$TMP/actual-params")
}
run_test 'Every generated base parameter matches the reference fixture and has backup coverage' t_full_parameter_fixture

t_burst() {
    assert_eq "$(bbr_tc_burst_bytes 15)" 32768
    assert_eq "$(bbr_tc_burst_bytes 100 49)" 50000
    assert_eq "$(bbr_tc_burst_bytes 400 196)" 200000
    assert_eq "$(bbr_tc_burst_bytes 100 100)" 102400
}
run_test 'HTB uses exact four-millisecond bytes while preserving custom snapshot bursts' t_burst

t_connect_retry() {
    local ATTEMPTS=0
    sleep() { :; }
    bbr_measure_resolve() { echo "$1"; }
    bbr_measure_peer_ready() { ATTEMPTS=$((ATTEMPTS+1)); [ "$1:$2" = 192.0.2.2:5209 ]; }
    assert_ok bbr_measure_connect 192.0.2.1 5201 4 <<< '192.0.2.2:5209'
    assert_eq "$ATTEMPTS" 3
    assert_eq "$QUENCH_PERF_PEER" 192.0.2.2
    assert_eq "$QUENCH_PERF_PORT" 5209
    assert_eq "$QUENCH_PERF_PORTS" ''
}
run_test 'An unavailable custom endpoint allows replacing it without restarting the wizard' t_connect_retry

test_summary 'Aligned TCP tuning'
