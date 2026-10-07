#!/usr/bin/env bash
# shellcheck disable=SC2329 # Fixtures are called indirectly by sourced modules / the test harness.
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_firewall() {
    CASE_DIR=$(mktemp -d "$TMP/case.XXXXXX")
    QUENCH_SSH_FIREWALL_MODE_FILE="$CASE_DIR/quench/ssh-firewall-mode"
    QUENCH_UFW_DEFAULTS_FILE="$CASE_DIR/defaults"
    printf 'IPV6=yes\n' > "$QUENCH_UFW_DEFAULTS_FILE"
    QUENCH_TEST_UFW_RULES="$CASE_DIR/rules"; LOG="$CASE_DIR/log"
    printf '%s\n' '22345|4|LIMIT|Anywhere|' '22345|6|LIMIT|Anywhere|' \
        '443|4|ALLOW|Anywhere|website' '22345|4|ALLOW|203.0.113.10|trusted' > "$QUENCH_TEST_UFW_RULES"
    : > "$LOG"
    FIXTURE_UFW_ACTIVE=true; FAILURE=none; PENDING=false
    print_header() { :; }
    fw_warn_environment() { :; }
    svc_is_active() { return 1; }
    fw_detect() { echo ufw; }
    ssh_effective_ports() { printf '22345\n'; }
    ssh_effective_ports_csv() { echo 22345; }
    pkg_install() { :; }
    # Model UFW's ordinary action update (same match replaces in place). Reject
    # delete/insert/prepend: migration must not introduce an SSH allowance gap.
    ufw() {
        printf '%s\n' "$*" >> "$LOG"
        case "$1" in
            status)
                if [ "$FAILURE" = status ] && grep -q '^allow ' "$LOG"; then return 1; fi
                if [ "$FIXTURE_UFW_ACTIVE" = false ]; then echo 'Status: inactive'; return 0; fi
                awk -F'|' 'BEGIN {print "Status: active"} {printf "%s/tcp%s %s IN %s%s", $1, ($2==6 ? " (v6)" : ""), $3, $4, ($2==6 ? " (v6)" : ""); if ($5!="") printf " # %s", $5; print ""}' "$QUENCH_TEST_UFW_RULES"
                ;;
            allow|limit)
                [ "$FAILURE" != command ] || return 1
                [ "$FAILURE" != skip ] || return 0
                [ "$FAILURE:$2" != second:22346/tcp ] || return 1
                local ACTION PORT FAMILY
                ACTION=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]'); PORT="${2%/tcp}"
                for FAMILY in 4 6; do
                    [ "$FAMILY:$FAILURE" != 6:ipv6 ] || continue
                    if [ "$FAMILY" = 6 ] && ! fw_ufw_ipv6_enabled; then continue; fi
                    awk -F'|' -v OFS='|' -v port="$PORT" -v family="$FAMILY" -v action="$ACTION" '
                        $1==port && $2==family && $4=="Anywhere" {$3=action; $5=""; found=1}
                        {print}
                        END {if (!found) print port,family,action,"Anywhere",""}
                    ' "$QUENCH_TEST_UFW_RULES" > "$QUENCH_TEST_UFW_RULES.tmp"
                    mv "$QUENCH_TEST_UFW_RULES.tmp" "$QUENCH_TEST_UFW_RULES"
                done
                ;;
            default|logging) : ;;
            --force) [ "$2" = enable ] || return 1; FIXTURE_UFW_ACTIVE=true ;;
            *) return 1 ;;
        esac
    }
    safety_arm() {
        printf 'arm\n' >> "$LOG"
        cp "$QUENCH_TEST_UFW_RULES" "$CASE_DIR/snapshot"
        if [ -f "$QUENCH_SSH_FIREWALL_MODE_FILE" ]; then
            cp "$QUENCH_SSH_FIREWALL_MODE_FILE" "$CASE_DIR/mode-snapshot"
        fi
        PENDING=true
    }
    safety_rollback_after_failure() {
        printf 'rollback\n' >> "$LOG"
        cp "$CASE_DIR/snapshot" "$QUENCH_TEST_UFW_RULES"
        if [ -f "$CASE_DIR/mode-snapshot" ]; then
            cp "$CASE_DIR/mode-snapshot" "$QUENCH_SSH_FIREWALL_MODE_FILE"
        else
            rm -f "$QUENCH_SSH_FIREWALL_MODE_FILE"
        fi
        PENDING=false
    }
    safety_confirm() { printf 'confirm\n' >> "$LOG"; PENDING=false; }
    safety_timer_pending() { [ "$PENDING" = true ]; }
}

t_default() {
    setup_firewall
    assert_eq "$(fw_ssh_mode_get)" limit
    assert_fail fw_ssh_mode_choose < /dev/null
    assert_ok fw_ssh_mode_choose <<< 2
    assert_eq "$QUENCH_SSH_FIREWALL_CHOICE" panel
    assert_ok fw_ssh_mode_save panel
    assert_ok fw_ssh_mode_choose <<< ''
    assert_eq "$QUENCH_SSH_FIREWALL_CHOICE" panel
    printf 'invalid\npanel\n' > "$QUENCH_SSH_FIREWALL_MODE_FILE"
    assert_fail fw_ssh_mode_get
    assert_fail firewall_allow_port 22346 <<< ''
    assert_fail grep -q '^allow ' "$LOG"
}
run_test 'Mode defaults, persisted choice, EOF and invalid configuration fail closed' t_default

t_migrate() {
    setup_firewall
    assert_ok fw_ssh_mode_setup <<< 2
    assert_eq "$(fw_ssh_mode_get)" panel
    assert_ok fw_ufw_ssh_rule_ready 22345 panel
    assert_file_contains "$QUENCH_TEST_UFW_RULES" '443|4|ALLOW|Anywhere|website'
    assert_file_contains "$QUENCH_TEST_UFW_RULES" '22345|4|ALLOW|203.0.113.10|trusted'
    assert_file_contains "$LOG" 'arm'
    assert_file_contains "$LOG" 'confirm'
    assert_fail grep -Eq 'delete|insert|prepend' "$LOG"
    # A panel UUID must survive subsequent Quench repairs and Web quick-allow.
    awk 'sub(/22345\|4\|ALLOW\|Anywhere\|$/, "22345|4|ALLOW|Anywhere|1panel-rule:uuid4") { } {print}' "$QUENCH_TEST_UFW_RULES" > "$QUENCH_TEST_UFW_RULES.tmp"
    mv "$QUENCH_TEST_UFW_RULES.tmp" "$QUENCH_TEST_UFW_RULES"
    : > "$LOG"
    assert_ok fw_ufw_allow_ssh
    assert_ok ufw_quick_allow <<< y
    assert_file_contains "$QUENCH_TEST_UFW_RULES" '22345|4|ALLOW|Anywhere|1panel-rule:uuid4'
    assert_fail grep -q 'allow 22345/tcp' "$LOG"
    assert_fail grep -q '^limit ' "$LOG"
    assert_ok firewall_allow_port 22346 <<< ''
    assert_ok fw_ufw_ssh_rule_ready 22346 panel
    assert_file_contains "$LOG" 'allow 22346/tcp'
}
run_test 'Panel migration preserves unrelated rules and UUIDs; later port changes stay ALLOW' t_migrate

t_failure() {
    setup_firewall
    FAILURE="$1"
    if [ "$FAILURE" = second ]; then
        ssh_effective_ports() { printf '22345\n22346\n'; }
    fi
    if [ "$FAILURE" = save ]; then
        fw_ssh_mode_save() { return 1; }
    fi
    cp "$QUENCH_TEST_UFW_RULES" "$CASE_DIR/expected"
    assert_fail fw_ssh_mode_apply panel
    assert_ok cmp "$QUENCH_TEST_UFW_RULES" "$CASE_DIR/expected"
    assert_fail test -e "$QUENCH_SSH_FIREWALL_MODE_FILE"
    assert_file_contains "$LOG" rollback
    assert_fail grep -qx confirm "$LOG"
}
for FAILURE_CASE in command skip ipv6 second save status; do
    run_test "Failed migration rolls back rules and mode: $FAILURE_CASE" t_failure "$FAILURE_CASE"
done

t_dual_ports() {
    setup_firewall
    ssh_effective_ports() { printf '22345\n22346\n'; }
    assert_ok fw_ssh_mode_apply panel
    assert_ok fw_ufw_ssh_rule_ready 22345 panel
    assert_ok fw_ufw_ssh_rule_ready 22346 panel
    assert_ok fw_ssh_mode_apply limit
    assert_eq "$(fw_ssh_mode_get)" limit
    assert_ok fw_ufw_ssh_rule_ready 22345 limit
    assert_ok fw_ufw_ssh_rule_ready 22346 limit
}
run_test 'Both ports in an ongoing SSH migration follow mode changes in both directions' t_dual_ports

t_pending() {
    setup_firewall
    safety_confirm() { :; }
    OUTPUT=$(fw_ssh_mode_apply panel)
    assert_contains "$OUTPUT" '面板兼容'
    assert_fail grep -q '重新同步' <<< "$OUTPUT"
    safety_confirm() { safety_rollback_after_failure; return 2; }
    assert_fail fw_ssh_mode_apply limit
    assert_eq "$(fw_ssh_mode_get)" panel
    assert_ok fw_ufw_ssh_rule_ready 22345 panel
}
run_test 'Unconfirmed or expired rollback cannot announce a completed panel migration' t_pending

t_reject() {
    setup_firewall
    printf '22345|4|DENY|Anywhere|manual\n' >> "$QUENCH_TEST_UFW_RULES"
    assert_fail fw_ssh_mode_apply panel
    assert_fail grep -q '^allow ' "$LOG"
    assert_file_contains "$QUENCH_TEST_UFW_RULES" '22345|4|DENY|Anywhere|manual'
}
run_test 'Existing broad deny is preserved and prevents migration' t_reject

t_parse() {
    setup_firewall
    assert_ok fw_ufw_ssh_rule_ready 22345 limit
    printf '22345|4|ALLOW|Anywhere|bypass\n' >> "$QUENCH_TEST_UFW_RULES"
    assert_fail fw_ufw_ssh_rule_ready 22345 limit
    for ROW in '22345/tcp (v6) ALLOW IN Anywhere (v6)' '22345/tcp ALLOW OUT Anywhere' \
        '22345/tcp on eth0 ALLOW IN Anywhere' '22345/tcp ALLOW IN 203.0.113.10'; do
        ufw() { printf 'Status: active\n%s\n' "$ROW"; }
        assert_fail fw_ufw_ssh_rule_ready 22345 panel
    done
    printf 'IPV6="no"\n' > "$QUENCH_UFW_DEFAULTS_FILE"
    ufw() { printf 'Status: active\n22345/tcp ALLOW Anywhere\n'; }
    assert_ok fw_ufw_ssh_rule_ready 22345 panel
}
run_test 'Validation rejects family gaps, mixed actions, output and scoped rules; supports IPv4-only UFW' t_parse

t_install() {
    setup_firewall
    FIXTURE_UFW_ACTIVE=false
    : > "$QUENCH_TEST_UFW_RULES"
    assert_ok fw_install ufw <<< $'2\nn'
    assert_eq "$(fw_ssh_mode_get)" panel
    assert_ok fw_ufw_ssh_rule_ready 22345 panel
    assert_file_contains "$LOG" 'allow 22345/tcp'
    assert_fail grep -Eq '^limit |allow (80|443)/tcp' "$LOG"
    assert_ok config_path_allowed /etc/quench/ssh-firewall-mode
    local ALLOW_LINE ENABLE_LINE
    ALLOW_LINE=$(awk '/^allow 22345/{print NR}' "$LOG")
    ENABLE_LINE=$(awk '/^--force enable/{print NR}' "$LOG")
    assert_ok test "$ALLOW_LINE" -lt "$ENABLE_LINE"
}
run_test 'Fresh installation selects panel mode and allows SSH before enabling UFW' t_install

t_onboarding() {
    setup_firewall
    first_run_firewall_ready() { return 0; }
    first_run_fail2ban_ready() { return 0; }
    audit_action() { :; }
    assert_fail first_run_firewall_mode_ready
    assert_ok first_run_firewall_fail2ban_setup <<< 2
    assert_ok first_run_firewall_mode_ready
    assert_eq "$(fw_ssh_mode_get)" panel
}
run_test 'First-run setup offers mode choice even when UFW and Fail2ban are already ready' t_onboarding

t_recommended() {
    setup_firewall
    first_run_preflight() { :; }
    config_backup_create() { echo "$CASE_DIR/snapshot"; }
    first_run_access_ready() { return 0; }
    first_run_firewall_ready() { return 0; }
    first_run_fail2ban_ready() { return 0; }
    first_run_ssh_baseline_ready() { return 0; }
    system_auto_updates_supported() { return 1; }
    first_run_network_security_ready() { return 0; }
    first_run_performance_setup() { :; }
    first_run_final_audit() { :; }
    audit_action() { :; }
    first_run_offer_step() { "$3"; }
    assert_ok first_run_recommended_flow <<< $'y\n2'
    assert_eq "$(fw_ssh_mode_get)" panel
    # Once chosen and verified, the next recommended run skips this step.
    first_run_firewall_fail2ban_setup() { fail 'Repeated mode prompt'; }
    assert_ok first_run_recommended_flow <<< y
}
run_test 'Recommended flow asks for an unchosen UFW mode once and then skips the verified step' t_recommended

test_summary 'SSH firewall modes'
