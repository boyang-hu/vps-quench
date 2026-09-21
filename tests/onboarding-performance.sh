#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_onboarding() {
    TEST_LOG="$TMP/$1.log"; : > "$TEST_LOG"
    safety_timer_pending() { return 1; }
    print_header() { :; }
    ui_hint() { :; }
    menu_item() { :; }
    menu_pair() { :; }
    menu_group() { :; }
    menu_div() { :; }
    ui_pause() { :; }
    bbr_measure_menu() { printf 'measure:%s\n' "$1" >> "$TEST_LOG"; }
    bbr_enable_core() { echo core >> "$TEST_LOG"; }
}

t_selection() {
    setup_onboarding "selection_$1"
    assert_ok first_run_performance_setup <<< "$1"
    assert_eq "$(cat "$TEST_LOG")" "$2"
    :
}
run_test 'Measured choice dispatches the full tuning wizard' t_selection 1 measure:tune
run_test 'Basic choice dispatches only BBR/FQ' t_selection 2 core
run_test 'Explicit skip performs no tuning' t_selection 3 ''
run_test 'Enter defaults to skip, never starts a bandwidth test' t_selection '' ''

t_eof() {
    setup_onboarding eof
    assert_ok first_run_performance_setup < /dev/null
    assert_eq "$(cat "$TEST_LOG")" ''
    :
}
run_test 'Closed input does not hang or trigger measurements' t_eof

t_invalid() {
    setup_onboarding invalid
    assert_ok first_run_performance_setup <<< $'typo\n2'
    assert_eq "$(cat "$TEST_LOG")" core
    :
}
run_test 'Invalid choice retries without performing an action' t_invalid

t_pending() {
    setup_onboarding pending
    safety_timer_pending() { return 0; }
    assert_fail first_run_performance_setup <<< 1
    assert_eq "$(cat "$TEST_LOG")" ''
    :
}
run_test 'Unconfirmed rollback blocks performance entry' t_pending

setup_recommended() {
    setup_onboarding "$1"
    first_run_preflight() { echo preflight >> "$TEST_LOG"; }
    config_backup_create() { echo backup >> "$TEST_LOG"; echo "$TMP/config-backup.tar.gz"; }
    first_run_access_ready() { return 0; }
    first_run_firewall_ready() { return 0; }
    first_run_fail2ban_ready() { return 0; }
    first_run_ssh_baseline_ready() { return 0; }
    system_auto_updates_supported() { return 0; }
    system_auto_updates_enabled() { return 0; }
    first_run_network_security_ready() { return 1; }
    first_run_network_security_apply() { echo network >> "$TEST_LOG"; }
    first_run_offer_step() { "$3"; }
    first_run_final_audit() { echo audit >> "$TEST_LOG"; }
    # Already-enabled BBR must not suppress the new choice.
    sysctl() { echo bbr; }
}

t_recommended() {
    setup_recommended "recommended_$1"
    assert_ok first_run_recommended_flow <<< "$(printf 'y\n%s\n' "$1")"
    local EXPECTED=$'preflight\nbackup\nnetwork'
    [ -z "$2" ] || EXPECTED="${EXPECTED}"$'\n'"$2"
    EXPECTED="${EXPECTED}"$'\n''audit'
    assert_eq "$(cat "$TEST_LOG")" "$EXPECTED"
    :
}
run_test 'Recommended flow offers measurement after security and before audit even when BBR is enabled' t_recommended 1 measure:tune
run_test 'Recommended flow supports basic-only setup' t_recommended 2 core
run_test 'Recommended flow continues directly to audit on skip' t_recommended 3 ''

t_failure() {
    setup_recommended "failure_$1"
    bbr_measure_menu() { echo measure-failed >> "$TEST_LOG"; return 7; }
    bbr_enable_core() { echo core-failed >> "$TEST_LOG"; return 7; }
    local ACTUAL_RC=0 OUTPUT
    OUTPUT=$(first_run_recommended_flow <<< "$(printf 'y\n%s\n' "$1")") || ACTUAL_RC=$?
    assert_eq "$ACTUAL_RC" 7
    assert_eq "$(tail -n 1 "$TEST_LOG")" audit
    assert_contains "$OUTPUT" '性能步骤未完成'
    ! grep -q '推荐流程已执行完成' <<< "$OUTPUT" || fail 'failed performance was reported as success'
    :
}
run_test 'Measured failure still audits and returns a failure status' t_failure 1
run_test 'Basic BBR failure still audits and returns a failure status' t_failure 2

t_direct_menu() {
    setup_onboarding direct
    first_run_print_status() { :; }
    assert_ok first_run_wizard <<< $'8\n1\n0'
    assert_eq "$(cat "$TEST_LOG")" measure:tune
    :
}
run_test 'Standalone onboarding item 8 uses the same three-way entry' t_direct_menu

t_confirmation() {
    setup_onboarding confirmation
    # Exercise the real measured wizard input layer; do not permit any network session.
    source "$ROOT/src/modules/bbr-measure.sh"
    bbr_measure_session() { fail 'measurement began without the final consent'; }
    assert_ok first_run_performance_setup <<< $'1\n4\n192.0.2.1\n5201\n\n150\n1\nn\nn\nn'
    assert_eq "$(cat "$TEST_LOG")" ''
    :
}
run_test 'Choosing measured onboarding still requires explicit network-test consent' t_confirmation

test_summary 'Onboarding performance choices'
