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
    assert_eq "$A" 17097152
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
    ! grep -Eq 'tcp_congestion_control|default_qdisc|ip_forward|notsent' <<< "$CONFIG" \
        || fail 'measured generator touched independent/high-risk knobs'
    assert_contains "$CONFIG" 'net.ipv4.tcp_mem = 65536 131072 262144'
    assert_contains "$CONFIG" 'net.core.netdev_budget = 600'
    assert_contains "$CONFIG" 'vm.min_free_kbytes = 32768'
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
    bbr_measure_apply_core() { echo core >> "$LOG"; }
    bbr_measure_cwnd() { echo "cwnd $1" >> "$LOG"; }
    bbr_measure_path_check() { echo "path $1" >> "$LOG"; }
    bbr_measure_swap_advice() { :; }
    bbr_measure_verdict() { :; }
    bbr_default_routes() { echo '6|default dev eth6'; }
    bbr_sweep_run() {
        printf 'calibrate 12 %s\n' "$QUENCH_PERF_DEV" >> "$LOG"
        printf 'STATUS=INCONCLUSIVE\nUNSHAPED_MBPS=600\n' > "$BBR_CALIBRATION_RESULT_FILE"
    }
    bbr_apply_sysctl() { printf '%s\n' "$1" > "$CASE_DIR/applied"; echo "apply $2" >> "$LOG"; }
    bbr_calibration_run() { printf 'calibrate %s %s\n' "$5" "$6" >> "$LOG"; }
    sleep() { :; }
    tc() { echo "qdisc fq 7ffd: root"; }
    sysctl() { case "$2" in *congestion_control) echo cubic ;; *default_qdisc) echo fq ;; *) echo "4096 1048576 16777216" ;; esac; }
    bbr_tc_rate_display() { echo "585Mbit"; }
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
        assert_file_contains "$LOG" 'calibrate 12 eth6'
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
for CASE in baseline probe restore route guard backup signal; do
    run_test "Stop without applying guessed config on $CASE" t_failure "$CASE"
done

t_post_failure() {
    setup_session "post_$1"
    case "$1" in
        apply) bbr_apply_sysctl() { echo attempt >> "$LOG"; return 1; } ;;
        shape) bbr_sweep_run() { return 1; } ;;
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
    bbr_measure_tcp_open() { :; }
    # command -v only; the network is mocked above.
    ping() { :; }
    assert_ok bbr_measure_pick_peer 6
    assert_eq "$QUENCH_PERF_PEER" near
    assert_eq "$QUENCH_PERF_PORT" 5202
    :
}
run_test 'Public selection orders by RTT, validates protocol, retries only candidate ports' t_peer

t_peer_full_pool() {
    QUENCH_PERF_PEER=''; QUENCH_PERF_PORT=''
    bbr_measure_peer_pool() { printf 'p1\np2\np3\np4\np5\n'; }
    bbr_measure_resolve() { echo "$1"; }
    bbr_measure_rtt() { echo "${1#p}"; }
    bbr_measure_tcp_open() { [ "$1:$2" = p5:5209 ]; }
    bbr_measure_peer_ready() { [ "$1:$2:$3" = p5:5209:4 ]; }
    assert_ok bbr_measure_pick_peer 4
    assert_eq "$QUENCH_PERF_PEER" p5
    assert_eq "$QUENCH_PERF_PORT" 5209
    assert_eq "$QUENCH_PERF_PROBE_PIDS" ''
}
run_test 'Fifth candidate and service port 5209 are eligible' t_peer_full_pool

t_peer_fallback() {
    local RTT_VALUE="$1"
    QUENCH_PERF_PEER=''; QUENCH_PERF_PORT=''
    bbr_measure_peer_pool() { echo distant; }
    bbr_measure_resolve() { echo 192.0.2.1; }
    bbr_measure_rtt() { [ "$RTT_VALUE" != unknown ] || return 1; echo "$RTT_VALUE"; }
    bbr_measure_tcp_open() { :; }
    bbr_measure_peer_ready() { :; }
    assert_ok bbr_measure_pick_peer 4
    assert_eq "$QUENCH_PERF_PEER" 192.0.2.1
}
for RTT in 150 unknown; do
    run_test "Remote/unknown RTT $RTT falls back without stopping the wizard" t_peer_fallback "$RTT"
done

t_discovery_parallel() {
    local TEST_DISCOVERY_DIR="$TMP/concurrent"
    mkdir -p "$TEST_DISCOVERY_DIR"
    bbr_measure_peer_pool() { seq 1 19; }
    bbr_measure_resolve() {
        : > "$TEST_DISCOVERY_DIR/$1.started"
        if [ "$1" = 1 ]; then
            local N
            for N in {1..50}; do [ ! -f "$TEST_DISCOVERY_DIR/18.started" ] || break; sleep 0.02; done
            [ -f "$TEST_DISCOVERY_DIR/18.started" ] || return 1
            [ ! -f "$TEST_DISCOVERY_DIR/19.started" ] || return 1
        fi
        echo "192.0.2.$1"
    }
    bbr_measure_rtt() { echo 10; }
    bbr_measure_tcp_open() { :; }
    bbr_measure_peer_ready() { :; }
    assert_ok bbr_measure_pick_peer 4
    assert_eq "$QUENCH_PERF_PEER" 192.0.2.1
    [ -f "$TEST_DISCOVERY_DIR/19.started" ] || fail 'discovery skipped later batch'
    assert_eq "$QUENCH_PERF_PROBE_PIDS" ''
}
run_test 'Discovery runs eighteen workers concurrently, waits before the next batch' t_discovery_parallel

t_discovery_cancel() {
    local TEST_DISCOVERY_DIR="$TMP/discovery-cancel" PID N RC=0
    mkdir -p "$TEST_DISCOVERY_DIR"
    bash -s -- "$ROOT" "$TEST_DISCOVERY_DIR" > "$TEST_DISCOVERY_DIR/output" 2>&1 <<'CHILD' &
export QUENCH_TEST_MODE=1
source "$1/vps-quench.sh"
TEST_DISCOVERY_DIR=$2
QUENCH_TMP_REGISTRY=''
quench_tmp_registry_init
printf '%s\n' "$QUENCH_TMP_REGISTRY" > "$TEST_DISCOVERY_DIR/registry"
QUENCH_PERF_REPORT=''; QUENCH_PERF_RESTORE=0
bbr_calibration_lock_release() { :; }
txn_write_end() { :; }
bbr_measure_peer_pool() { seq 1 19; }
bbr_measure_resolve() {
    : > "$TEST_DISCOVERY_DIR/$1.started"
    sleep 1
    : > "$TEST_DISCOVERY_DIR/$1.done"
    echo "192.0.2.$1"
}
bbr_measure_rtt() { echo 10; }
bbr_measure_peer_ready() { echo unexpected-handshake; return 1; }
trap bbr_measure_cleanup EXIT
trap 'exit 130' INT TERM HUP
bbr_measure_pick_peer 4
CHILD
    PID=$!
    for N in {1..100}; do
        [ ! -f "$TEST_DISCOVERY_DIR/18.started" ] || break
        sleep 0.02
    done
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" || RC=$?
    assert_eq "$RC" 130
    for N in {1..18}; do
        [ -f "$TEST_DISCOVERY_DIR/$N.done" ] || fail 'cleanup returned before worker finished'
    done
    [ ! -f "$TEST_DISCOVERY_DIR/19.started" ] || fail 'started next batch after cancellation'
    [ ! -e "$(cat "$TEST_DISCOVERY_DIR/registry")" ] || fail 'temporary registry leaked'
    ! grep -q unexpected-handshake "$TEST_DISCOVERY_DIR/output" || fail 'iperf ran after cancellation'
}
run_test 'Cancellation drains bounded discovery workers and cleans temporary resources' t_discovery_cancel

t_default_family() {
    ip() { [ "$1" != -6 ] || echo 'default via fe80::1 dev eth0'; }
    assert_eq "$(bbr_measure_default_family)" 6
    ip() { echo 'default dev eth0'; }
    assert_eq "$(bbr_measure_default_family)" 4
}
run_test 'IPv6-only default route suggests IPv6; dual-stack keeps IPv4 default' t_default_family

t_ping_compat() {
    timeout() { shift; "$@"; }
    ping() {
        case "$1" in -4|-6) echo 'ping: invalid option'; return 1 ;; esac
        echo 'round-trip min/avg/max = 10.0/11.5/13.0 ms'
    }
    ping6() { echo 'round-trip min/avg/max = 20.0/21.5/23.0 ms'; }
    assert_eq "$(bbr_measure_rtt 192.0.2.1 4)" 11.50
    assert_eq "$(bbr_measure_rtt 2001:db8::1 6)" 21.50
}
run_test 'BusyBox ping option fallback preserves address family' t_ping_compat

t_early_report() {
    setup_session early_report
    bbr_measure_pick_peer() { bbr_measure_log '[dns_failed] host=unresolvable.test'; return 1; }
    assert_fail bbr_measure_session tune '' 5201 4 '' 150 proxy n n
    local REPORTS=("$QUENCH_PERF_REPORT_DIR"/run-*)
    assert_file_contains "${REPORTS[0]}/connections.log" dns_failed
    assert_file_contains "${REPORTS[0]}/outcome.txt" 'exit_code=1'
    ! grep -q '^measure' "$LOG" || fail 'measured after selection failure'
}
run_test 'Failed peer selection still leaves diagnostics and exit status' t_early_report

t_retry() {
    local MODE="$1" COUNT=0
    local LOG="$TMP/retry-$MODE"; : > "$LOG"
    QUENCH_PERF_PEER=192.0.2.1; QUENCH_PERF_PORT=5201; QUENCH_PERF_FAMILY=6
    QUENCH_PERF_PORTS=''
    [ "$MODE" != public ] || QUENCH_PERF_PORTS=$'5201\n5202\n5209'
    bbr_measure_tcp_open() { [ "$2" = 5209 ]; }
    sleep() { :; }
    bbr_calibration_measure_once() {
        COUNT=$((COUNT + 1))
        printf '%s %s %s\n' "$1" "$2" "$3" >> "$LOG"
        QUENCH_PERF_RETRYABLE=1
        [ "$MODE" != parse ] || QUENCH_PERF_RETRYABLE=0
        if [ "$COUNT" = 2 ] && [ "$MODE" != exhausted ]; then
            BBR_CAL_RECEIVER=600; return 0
        fi
        BBR_CAL_RECEIVER=''; return 1
    }
    case "$MODE" in
        public|custom)
            assert_ok bbr_calibration_measure 192.0.2.1 5201 6 8 1 sample
            assert_eq "$COUNT" 2
            if [ "$MODE" = public ]; then assert_eq "$QUENCH_PERF_PORT" 5209
            else assert_eq "$QUENCH_PERF_PORT" 5201; fi ;;
        exhausted)
            assert_fail bbr_calibration_measure 192.0.2.1 5201 6 8 1 sample
            assert_eq "$COUNT" 3
            assert_eq "$BBR_CAL_RECEIVER" '' ;;
        parse)
            assert_fail bbr_calibration_measure 192.0.2.1 5201 6 8 1 sample
            assert_eq "$COUNT" 1 ;;
    esac
    ! grep -vE '^192.0.2.1 520[129] 6$' "$LOG" || fail 'changed peer or protocol family'
}
for MODE in public custom exhausted parse; do
    run_test "Retry $MODE keeps peer/family, limits attempts, rejects invalid samples" t_retry "$MODE"
done

t_iperf_log() {
    QUENCH_PERF_REPORT="$TMP/iperf-log"; mkdir -p "$QUENCH_PERF_REPORT"
    timeout() { shift; "$@"; }
    iperf3() { echo 'iperf3: error - the server is busy running a test. try again later'; return 1; }
    assert_fail bbr_measure_peer_ready 192.0.2.1 5201 4
    assert_eq "$BBR_CAL_IPERF_PID" ''
    assert_eq "$BBR_CAL_TEMP_FILE" ''
    assert_file_contains "$QUENCH_PERF_REPORT/connections.log" '[handshake] peer=192.0.2.1 port=5201 exit=1'
    assert_fail bbr_calibration_measure_once 192.0.2.1 5201 4 8 1 test
    assert_eq "$QUENCH_PERF_RETRYABLE" 1
    assert_eq "$BBR_CAL_RECEIVER" ''
    assert_file_contains "$QUENCH_PERF_REPORT/connections.log" '[test/1]'
    iperf3() { echo '[  5] 0.00-8.00 sec 600 MBytes 620 Mbits/sec sender'; }
    assert_fail bbr_calibration_measure_once 192.0.2.1 5201 4 8 1 malformed
    assert_eq "$QUENCH_PERF_RETRYABLE" 0
}
run_test 'Handshake and measurement retain actual iperf error and clear stale results' t_iperf_log

t_swap_advice() {
    local MODE="$1" CALLED=0
    bbr_physical_memory_mb() { if [ "$MODE" = large ]; then echo 2048; else echo 512; fi; }
    bbr_measure_swap_active() {
        case "$MODE" in present) return 0 ;; unknown) return 2 ;; *) return 1 ;; esac
    }
    df() { printf 'Filesystem 1M-blocks Used Available\n/dev/test 10000 1 9999\n'; }
    swap_managed_path() { echo /swapfile.quench; }
    swap_create_apply() { assert_eq "$1" 2048; CALLED=$((CALLED + 1)); }
    swap_set_swappiness_apply() { assert_eq "$1" 10; }
    local INPUT=0
    [ "$MODE" != accept ] || INPUT=2
    assert_ok bbr_measure_swap_advice <<< "$INPUT"
    if [ "$MODE" = accept ]; then assert_eq "$CALLED" 1; else assert_eq "$CALLED" 0; fi
}
for MODE in accept decline present unknown large; do
    run_test "Low RAM swap advice: $MODE" t_swap_advice "$MODE"
done

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

t_probe_rounding() {
    setup_session probe_rounding
    QUENCH_PERF_DEV=eth6; BBR_CAL_TC_BIN=tc
    QUENCH_PERF_PEER=192.0.2.10; QUENCH_PERF_PORT=5201; QUENCH_PERF_FAMILY=6
    QUENCH_PERF_REPORT=''
    bbr_calibration_measure() {
        MEASURE_N=$((MEASURE_N+1))
        assert_eq "$4" 10; assert_eq "$5" 4
        BBR_CAL_SENDER=621; BBR_CAL_RECEIVER=623; BBR_CAL_RETRANS=0; BBR_CAL_LOSS=0
    }
    assert_ok bbr_measure_probe
    assert_eq "$MEASURE_N" 1
    assert_eq "$QUENCH_PERF_BW" 600
    assert_eq "$QUENCH_PERF_RESTORE" 0
}
run_test 'Auto bandwidth uses one valid ten-second four-stream sample and rounds like tcpfit' t_probe_rounding

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


t_scan_result() {
    setup_session "scan-result-$1"
    bbr_tc_apply_selected_rate() { echo "shape $1 $2" >> "$LOG"; }
    bbr_tc_remove_selected() { echo "remove $1" >> "$LOG"; }
    local RESULT="$1"
    bbr_sweep_run() {
        printf 'STATUS=%s\nUNSHAPED_MBPS=600\nKNEE_MBPS=598\nRECOMMEND_MBPS=583\n' "$RESULT" > "$BBR_CALIBRATION_RESULT_FILE"
    }
    assert_ok bbr_measure_session tune peer.test 5201 6 600 150 proxy y auto
    case "$RESULT" in
        KNEE) assert_file_contains "$LOG" 'shape eth6 583' ;;
        NO_KNEE) assert_file_contains "$LOG" 'remove eth6' ;;
        *)
            ! grep -Eq '^shape|^remove' "$LOG" || fail 'uncertain result changed shaping'
            if [ "$RESULT" = CANCELLED ]; then
                ! grep -q '^measure' "$LOG" || fail 'cancelled scan still spent verification traffic'
            fi ;;
    esac
}
for STATUS in KNEE NO_KNEE INCONCLUSIVE OUT_OF_RANGE ABOVE_CAP CANCELLED; do
    run_test "Wizard applies only the permitted action for $STATUS" t_scan_result "$STATUS"
done

t_old_shape() {
    setup_session old_shape
    printf 'DEV=eth6\nRATE=950\n' > "$TC_STATE_FILE"
    bbr_sweep_run() { printf 'STATUS=NO_KNEE\nUNSHAPED_MBPS=100\n' > "$BBR_CALIBRATION_RESULT_FILE"; }
    bbr_tc_remove_selected() { fail 'slow result removed existing limiter'; }
    assert_ok bbr_measure_session tune peer.test 5201 6 100 150 proxy y auto
    assert_eq "$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" STATUS)" INCONCLUSIVE
}
run_test 'Slow automatic bandwidth cannot invalidate an existing higher limiter' t_old_shape

t_scan_only() {
    setup_session scan_only
    bbr_measure_cwnd() { fail 'scan-only changed initial windows'; }
    assert_ok bbr_measure_session calibrate peer.test 5201 6 600 150 proxy n auto
    ! grep -Eq '^backup|^core|^apply|^cwnd' "$LOG" || fail 'independent scan applied base tuning'
    assert_file_contains "$LOG" 'calibrate 12 eth6'
}
run_test 'Standalone calibration shares the scanner and leaves TCP parameters alone' t_scan_only

t_no_iperf() {
    setup_session no_iperf
    QUENCH_PERF_HAVE_IPERF=0
    ip() { echo 'default dev eth6'; }
    bbr_measure_connect() { fail 'fallback tried to measure'; }
    assert_ok bbr_measure_session tune '' 5201 6 400 150 proxy y auto
    assert_file_contains "$LOG" 'apply measured'
    ! grep -Eq '^measure|^calibrate' "$LOG" || fail 'basic-only fallback attempted tests'
}
run_test 'Without iperf the explicit bandwidth drives base tuning without measurements' t_no_iperf


t_summary() {
    setup_session "summary_$1"
    local MODE="$1" RC=0 REPORT OUTPUT
    case "$MODE" in
        failure) bbr_measure_pair() { return 1; } ;;
        partial)
            bbr_measure_pair() {
                BBR_CAL_SENDER=700; BBR_CAL_RECEIVER=567; BBR_CAL_RETRANS=2; BBR_CAL_LOSS=0.1
                bbr_measure_record after 1 10
                return 1
            } ;;
        skipped) QUENCH_PERF_HAVE_IPERF=0; ip() { echo 'default dev eth6'; } ;;
        knee)
            bbr_sweep_run() { printf 'STATUS=KNEE\nRECOMMEND_MBPS=585\n' > "$BBR_CALIBRATION_RESULT_FILE"; }
            bbr_tc_apply_selected_rate() { :; } ;;
        verify) : ;;
        stale) printf 'STATUS=KNEE\nRECOMMEND_MBPS=999\n' > "$BBR_CALIBRATION_RESULT_FILE" ;;
    esac
    if [ "$MODE" = verify ]; then
        OUTPUT=$(bbr_measure_session verify peer.test 5201 6 '' 150 proxy n keep) || RC=$?
    elif [ "$MODE" = knee ]; then
        OUTPUT=$(bbr_measure_session tune peer.test 5201 6 600 150 proxy y auto) || RC=$?
    else
        OUTPUT=$(bbr_measure_session tune peer.test 5201 6 400 150 proxy y keep) || RC=$?
    fi
    local REPORTS=("$QUENCH_PERF_REPORT_DIR"/run-*)
    REPORT="${REPORTS[0]}/summary.txt"
    assert_file_contains "$REPORT" 'TCP 调优结果报告'
    assert_contains "$OUTPUT" "$(cat "$REPORT")"
    assert_file_contains "$REPORT" 'tcp_congestion_control = cubic'
    assert_file_contains "$REPORT" '当前整形：585Mbit'
    assert_file_contains "$REPORT" 'qdisc fq 7ffd: root'
    case "$MODE" in
        failure|partial)
            assert_ne "$RC" 0
            assert_file_contains "$REPORT" '流程结果：未完成'
            assert_file_contains "$REPORT" '四流：无有效验证样本'
            ! grep -q '流程结果：已完成' "$REPORT" || fail 'failed run called complete'
            if [ "$MODE" = partial ]; then assert_file_contains "$REPORT" '单流：567 Mbps'; fi
            ;;
        skipped)
            assert_eq "$RC" 0
            assert_file_contains "$REPORT" '单流：无有效验证样本'
            assert_file_contains "$REPORT" '四流：无有效验证样本'
            ;;
        *)
            assert_eq "$RC" 0
            assert_file_contains "$REPORT" '单流：600 Mbps'
            assert_file_contains "$REPORT" '四流：600 Mbps'
            ;;
    esac
    if [ "$MODE" = knee ]; then
        assert_file_contains "$REPORT" '建议整形：585 Mbps'
    else
        ! grep -q '建议整形' "$REPORT" || fail 'report reused a stale scan recommendation'
    fi
    if [ "$MODE" != verify ]; then
        assert_file_contains "$REPORT" '不是最终测速结果'
        assert_file_contains "$REPORT" '不是实测延迟'
    fi
    assert_file_contains "${REPORTS[0]}/outcome.txt" "exit_code=$RC"
}
for MODE in normal failure partial skipped knee verify stale; do
    run_test "Final tuning report: $MODE" t_summary "$MODE"
done

t_summary_restoration() {
    setup_session summary_restoration
    QUENCH_PERF_REPORT="$QUENCH_PERF_REPORT_DIR/run-fixture"
    mkdir -p "$QUENCH_PERF_REPORT"
    printf 'phase\tstreams\n' > "$QUENCH_PERF_REPORT/samples.tsv"
    QUENCH_PERF_DEV=eth6; BBR_CAL_TC_BIN=tc; QUENCH_PERF_RESTORE=1
    bbr_calibration_restore_qdisc() { echo restored >> "$LOG"; return 1; }
    bbr_measure_summary() { assert_eq "$1" 1; assert_file_contains "$LOG" restored; echo 'restoration failed'; }
    local RC=0
    (true; bbr_measure_cleanup) || RC=$?
    assert_eq "$RC" 1
    assert_file_contains "$QUENCH_PERF_REPORT/summary.txt" 'restoration failed'
    assert_file_contains "$QUENCH_PERF_REPORT/outcome.txt" exit_code=1
    assert_file_contains "$LOG" unlock
}
run_test 'Report reflects queue restoration failure and cleanup still releases the lock' t_summary_restoration

test_summary 'Measured performance workflow'
