#!/usr/bin/env bash
# Fixtures only: never call the host's package manager or change its services.
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quench-onboarding-updates.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_updates() {
    TEST_LOG="$TMP/$1.log"; : > "$TEST_LOG"
    SSH_CONNECTION=''; SSH_TTY=''; TMUX=''; STY=''
    QUENCH_TXN_LOCK_HELD=0; QUENCH_TXN_WRITE_DEPTH=0
    system_package_manager() { echo apt; }
    system_update_debian_code() { echo bookworm; }
    system_update_terminal_ready() { return 0; }
    safety_timer_pending() { return 1; }
    print_header() { :; }
    ui_hint() { :; }
    menu_item() { :; }
    menu_pair() { :; }
    menu_group() { :; }
    menu_div() { :; }
    ui_pause() { :; }
    system_update_action() { printf 'action:%s\n' "$1" >> "$TEST_LOG"; }
    system_update_tmux_launch() { printf 'tmux:%s\n' "$1" >> "$TEST_LOG"; }
    system_update_debian_major() { fail 'onboarding started a major release upgrade'; }
}

t_choice() {
    setup_updates "choice_$2"
    assert_ok first_run_package_updates_setup <<< "$1"
    assert_eq "$(cat "$TEST_LOG")" "$2"
}
run_test 'Default refreshes and upgrades through the existing current-system transaction' t_choice '' action:current
run_test 'Current-system selection dispatches exactly once' t_choice 1 action:current
run_test 'Full dependency update does not then run a redundant normal upgrade' t_choice 2 action:full
run_test 'Explicit skip performs no package action' t_choice 0 ''
run_test 'Typo or major-upgrade key retries without executing an action' t_choice $'yy\nv\n2' action:full

t_eof() {
    setup_updates eof
    assert_ok first_run_package_updates_setup < /dev/null
    assert_eq "$(cat "$TEST_LOG")" ''
}
run_test 'Closed input does not start an upgrade or loop' t_eof

t_system() {
    setup_updates "system_$1"
    local TEST_PM="$1"
    system_package_manager() { echo "$TEST_PM"; }
    case "$TEST_PM" in
        unsupported-apt)
            system_package_manager() { echo apt; }
            system_update_debian_code() { return 1; }
            ;;
    esac
    assert_ok first_run_package_updates_setup <<< 1
    case "$TEST_PM" in
        dnf|yum|apk) assert_eq "$(cat "$TEST_LOG")" action:current ;;
        *) assert_eq "$(cat "$TEST_LOG")" '' ;;
    esac
}
for PM in dnf yum apk opkg unsupported-apt; do
    run_test "Package-manager support: $PM" t_system "$PM"
done

t_nonapt_choice() {
    setup_updates nonapt
    system_package_manager() { echo apk; }
    assert_ok first_run_package_updates_setup <<< $'2\n0'
    assert_eq "$(cat "$TEST_LOG")" ''
}
run_test 'Non-APT menu cannot select the hidden full-upgrade entry' t_nonapt_choice

t_failure() {
    setup_updates "failure_$1"
    case "$1" in
        pending) safety_timer_pending() { return 0; } ;;
        terminal) system_update_terminal_ready() { return 1; } ;;
        update) system_update_action() { return 7; } ;;
        launch)
            SSH_TTY=/dev/pts/1
            system_update_tmux_launch() { return 7; }
            ;;
    esac
    local RC=0
    first_run_package_updates_setup <<< 1 || RC=$?
    case "$1" in update|launch) assert_eq "$RC" 7 ;; *) assert_eq "$RC" 1 ;; esac
    assert_eq "$(cat "$TEST_LOG")" ''
}
for CASE in pending terminal update launch; do
    run_test "Update entry fails without later mutations: $CASE" t_failure "$CASE"
done

t_session() {
    setup_updates "session_$1"
    SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22'
    case "$1" in
        tmux) TMUX=inside ;;
        screen) STY=inside ;;
        tty-only) SSH_CONNECTION=''; SSH_TTY=/dev/pts/1 ;;
    esac
    local RC=0
    first_run_package_updates_setup <<< 1 || RC=$?
    case "$1" in
        tmux|screen) assert_eq "$RC" 0; assert_eq "$(cat "$TEST_LOG")" action:current ;;
        *) assert_eq "$RC" 3; assert_eq "$(cat "$TEST_LOG")" tmux:current ;;
    esac
}
for CASE in ssh tty-only tmux screen; do
    run_test "Update handoff distinguishes client return from completion: $CASE" t_session "$CASE"
done

setup_flow() {
    setup_updates "$1"
    first_run_preflight() { echo preflight >> "$TEST_LOG"; }
    config_backup_create() { echo backup >> "$TEST_LOG"; echo "$TMP/backup.tar.gz"; }
    first_run_access_ready() { echo access >> "$TEST_LOG"; return 0; }
    first_run_firewall_ready() { return 0; }
    first_run_fail2ban_ready() { return 0; }
    first_run_firewall_mode_ready() { return 0; }
    first_run_ssh_baseline_ready() { return 0; }
    system_auto_updates_supported() { return 1; }
    first_run_network_security_ready() { return 0; }
    first_run_performance_setup() { echo performance >> "$TEST_LOG"; }
    first_run_final_audit() { echo audit >> "$TEST_LOG"; }
}

t_flow() {
    setup_flow "flow_$1"
    local RC=0 OUTPUT EXPECTED=$'preflight\nbackup'
    case "$1" in
        failure) system_update_action() { echo failed >> "$TEST_LOG"; return 7; } ;;
        handoff|cancel-handoff)
            SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22'
            [ "$1" != cancel-handoff ] || system_update_tmux_launch() { :; }
            ;;
    esac
    OUTPUT=$(first_run_recommended_flow <<< $'y\n1') || RC=$?
    case "$1" in
        success)
            assert_eq "$RC" 0
            EXPECTED+=$'\naction:current\naccess\nperformance\naudit'
            ;;
        failure) assert_eq "$RC" 7; EXPECTED+=$'\nfailed' ;;
        handoff) assert_eq "$RC" 0; EXPECTED+=$'\ntmux:current' ;;
        cancel-handoff) assert_eq "$RC" 0 ;;
    esac
    assert_eq "$(cat "$TEST_LOG")" "$EXPECTED"
    if [ "$1" != success ]; then
        ! grep -q '推荐流程已执行完成' <<< "$OUTPUT" || fail 'unfinished update reported onboarding completion'
    fi
}
for CASE in success failure handoff cancel-handoff; do
    run_test "Recommended flow updates after backup, blocks following steps when unfinished: $CASE" t_flow "$CASE"
done

t_menu() {
    setup_updates menu
    first_run_print_status() { :; }
    assert_ok first_run_wizard <<< $'u\n2\n0'
    assert_eq "$(cat "$TEST_LOG")" action:full
}
run_test 'Standalone onboarding u reaches the same update path' t_menu

test_summary 'Onboarding updates'
