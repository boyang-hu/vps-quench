#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"

setup_shared() {
    export QUENCH_TEST_F2B_ROOT="$TMP/$1"
    mkdir -p "$QUENCH_TEST_F2B_ROOT/jail.d"
    QUENCH_F2B_JAIL_LOCAL="$QUENCH_TEST_F2B_ROOT/jail.local"
    QUENCH_F2B_STATE_DIR="$QUENCH_TEST_F2B_ROOT/state"
    QUENCH_TXN_DIR="$QUENCH_TEST_F2B_ROOT/transactions"
    QUENCH_TXN_LOCK_FILE="$QUENCH_TEST_F2B_ROOT/config.lock"
    QUENCH_TXN_LOCK_HELD=0; QUENCH_TXN_LOCK_MODE=""; QUENCH_TXN_WRITE_DEPTH=0
    QUENCH_TXN_FILE=""; SAFETY_SCRIPT=""; SAFETY_PID=""; SAFETY_UNIT=""
    export QUENCH_TEST_F2B_SERVICE=stopped
    cat > "$QUENCH_TEST_F2B_ROOT/jail.conf" <<'EOF'
[DEFAULT]
bantime = 600
findtime = 300
maxretry = 5
banaction = iptables-multiport
[sshd]
enabled = false
port = 22
EOF
    fail2ban-client() {
        case "$1" in
            -d) python3 "$ROOT/tests/lib/fail2ban-fixture.py" dump ;;
            -t) python3 "$ROOT/tests/lib/fail2ban-fixture.py" validate ;;
            get) shift 2; python3 "$ROOT/tests/lib/fail2ban-fixture.py" get "$@" ;;
            ping|status) [ -f "$QUENCH_TEST_F2B_ROOT/runtime" ] ;;
            version) echo 1.1.0 ;;
            *) return 1 ;;
        esac
    }
    f2b_status() { echo "$QUENCH_TEST_F2B_SERVICE"; }
    f2b_backend_detect() { echo auto; }
    fw_detect() { echo ufw; }
    restart_fail2ban() {
        echo restart >> "$QUENCH_TEST_F2B_ROOT/restarts"
        python3 "$ROOT/tests/lib/fail2ban-fixture.py" restart
    }
    start_fail2ban() { restart_fail2ban; }
    stop_fail2ban() { rm -f "$QUENCH_TEST_F2B_ROOT/runtime"; }
    audit_action() { :; }
    ssh_effective_ports_csv() { echo 2222; }
}

legacy_shared() {
    cat > "$(f2b_legacy_file)" <<'EOF'
# Managed by Quench. Keep unrelated jails in jail.local or separate jail.d files.
[DEFAULT]
allowipv6 = auto
[sshd]
enabled = true
port = 2222
backend = auto
mode = aggressive
bantime = 1h
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.maxtime = 1w
EOF
    cat > "$QUENCH_F2B_JAIL_LOCAL" <<'EOF'
# panel and user configuration
[DEFAULT]
bantime = 600
ignoreip = 127.0.0.1/8 ::1
[sshd]
enabled = true
port = 22
banaction = ufw
logpath = /var/log/auth.log
ignoreip = 192.0.2.10
[nginx-custom]
enabled = true
filter = nginx-custom
port = 80,443
bantime = 86400
EOF
}

t_fresh() {
    setup_shared fresh
    f2b_configure_shared 2222 auto start || fail 'fresh configuration failed'
    assert_eq "$(f2b_get_section_param sshd port)" 2222
    assert_eq "$(f2b_get_section_param sshd bantime)" 3600
    assert_eq "$(f2b_get_section_param sshd bantime.increment "$(f2b_advanced_file)")" true
    ! grep -q '^bantime\.' "$QUENCH_F2B_JAIL_LOCAL" || fail 'advanced key leaks into panel file'
    f2b_shared_effective_check yes || fail 'runtime differs'
    :
}
run_test 'Fresh install shares basic settings and verifies the running jail' t_fresh

t_distribution_action() {
    setup_shared distribution_action
    printf '[DEFAULT]\nbanaction = nftables-multiport\n' > "$QUENCH_TEST_F2B_ROOT/jail.d/defaults.conf"
    fw_running() { echo inactive; }
    f2b_configure_shared 2222 auto preserve || fail 'distribution action migration failed'
    assert_eq "$(f2b_get_section_param sshd banaction)" nftables-multiport
    :
}
run_test 'Preserve distribution action instead of selecting an inactive installed UFW' t_distribution_action

t_pending_edit_guards() {
    setup_shared pending_edits
    mkdir -p "$QUENCH_F2B_STATE_DIR"
    echo unfinished > "$QUENCH_F2B_STATE_DIR/pending"
    pkg_install() { fail 'installation crossed pending guard'; }
    open_editor() { fail 'editor crossed pending guard'; }
    ! f2b_install_locked || fail 'install ignored pending migration'
    ! f2b_config_params_locked || fail 'parameters ignored pending migration'
    ! f2b_edit_config_locked || fail 'editor ignored pending migration'
    :
}
run_test 'All configuration entry points refuse an unfinished migration' t_pending_edit_guards

t_edit_backup_survives_cleanup() {
    setup_shared edit_backup
    f2b_configure_shared 2222 auto start || fail 'setup failed'
    export QUENCH_TEST_F2B_SERVICE=running
    quench_tmp_registry_init
    restart_fail2ban() { return 1; }
    atomic_restore_file() { return 1; }
    ! f2b_config_params <<< $'1\n7200' || fail 'accepted restart/restore failure'
    quench_tmp_cleanup
    local BACKUP
    BACKUP=$(find "$QUENCH_TEST_F2B_ROOT" -name '.quench-fail2ban-backup.*' | head -1)
    [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || fail 'failed restoration backup was deleted on exit'
    assert_eq "$(f2b_get_section_param sshd bantime "$BACKUP")" 3600
    :
}
run_test 'Failed parameter restore keeps its backup across temporary-file cleanup' t_edit_backup_survives_cleanup

t_migrate() {
    setup_shared migrate; legacy_shared
    cp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/before"
    cp "$(f2b_legacy_file)" "$QUENCH_TEST_F2B_ROOT/legacy-before"
    f2b_panel_migrate <<< y || fail 'migration failed'
    assert_eq "$(f2b_get_section_param sshd port)" 2222
    assert_eq "$(f2b_get_section_param sshd bantime)" 3600
    assert_eq "$(f2b_get_section_param sshd findtime)" 600
    assert_eq "$(f2b_get_section_param sshd maxretry)" 3
    assert_eq "$(f2b_get_section_param sshd ignoreip)" 192.0.2.10
    assert_eq "$(f2b_get_section_param DEFAULT bantime)" 600
    diff <(sed -n '/^\[nginx-custom\]/,$p' "$QUENCH_TEST_F2B_ROOT/before") \
        <(sed -n '/^\[nginx-custom\]/,/^\[sshd\]/{ /^\[sshd\]/d; /^$/d; p; }' "$QUENCH_F2B_JAIL_LOCAL") || fail 'other jail modified'
    [ ! -f "$(f2b_legacy_file)" ] || fail 'legacy override remains'
    [ ! -f "$QUENCH_TEST_F2B_ROOT/restarts" ] || fail 'migration started a stopped service'
    local BACKUP
    BACKUP=$(find "$QUENCH_F2B_STATE_DIR" -name legacy -type f | head -1)
    cmp "$BACKUP" "$QUENCH_TEST_F2B_ROOT/legacy-before" || fail 'legacy backup missing'
    :
}
run_test 'Migration keeps legacy policy, panel whitelist, other jails and backups' t_migrate

t_panel_edit() {
    setup_shared panel_edit; legacy_shared
    f2b_configure_shared 2222 auto start || fail 'setup failed'
    export QUENCH_TEST_F2B_SERVICE=running
    # Match 1Panel v2.2.5 UpdateConf: updates lines starting with the requested key.
    python3 - "$QUENCH_F2B_JAIL_LOCAL" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines, ssh = [], False
for line in p.read_text().splitlines():
    if line.startswith('['): ssh = line == '[sshd]'
    if ssh and line.startswith('bantime'): line = 'bantime = 7200'
    lines.append(line)
p.write_text('\n'.join(lines) + '\n')
PY
    restart_fail2ban || fail 'restart failed'
    assert_eq "$(fail2ban-client get sshd bantime)" 7200
    f2b_configure_shared 2222 auto preserve || fail 'repeat sync failed'
    assert_eq "$(f2b_get_section_param sshd bantime)" 7200
    assert_eq "$(f2b_get_section_param sshd bantime.increment "$(f2b_advanced_file)")" true
    cp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/once"
    f2b_configure_shared 2222 auto preserve || fail 'repeat sync failed'
    cmp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/once" || fail 'merge not idempotent'
    :
}
run_test 'Panel edits take effect, advanced bans survive, repeated sync preserves edits' t_panel_edit

t_ports() {
    setup_shared ports
    f2b_configure_shared 22 auto start || fail 'setup failed'
    export QUENCH_TEST_F2B_SERVICE=running
    ssh_sync_fail2ban_ports 22,2222 || fail 'dual port failed'
    assert_eq "$(fail2ban-client get sshd action iptables-multiport port)" 22,2222
    ssh_sync_fail2ban_ports 2222 || fail 'finalize failed'
    assert_eq "$(fail2ban-client get sshd action iptables-multiport port)" 2222
    ssh_sync_fail2ban_ports 22 || fail 'rollback failed'
    assert_eq "$(fail2ban-client get sshd action iptables-multiport port)" 22
    :
}
run_test 'SSH migration, finalize and rollback update running action ports' t_ports

t_failure() {
    setup_shared "failure-$1"; legacy_shared
    local WHY="$1"
    cp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/base-before"
    cp "$(f2b_legacy_file)" "$QUENCH_TEST_F2B_ROOT/legacy-before"
    export QUENCH_TEST_F2B_SERVICE=running
    case "$WHY" in
        validate) f2b_validate_config() { return 1; } ;;
        write)
            eval "$(declare -f atomic_replace_file | sed '1s/atomic_replace_file/test_atomic_replace/')"
            atomic_replace_file() { [ "$2" != "$(f2b_advanced_file)" ] && test_atomic_replace "$@"; }
            ;;
        restart)
            restart_fail2ban() {
                if [ ! -f "$QUENCH_TEST_F2B_ROOT/failed-once" ]; then
                    : > "$QUENCH_TEST_F2B_ROOT/failed-once"; return 1
                fi
                python3 "$ROOT/tests/lib/fail2ban-fixture.py" restart
            }
            ;;
        runtime) f2b_shared_effective_check() { [ "$1" = no ]; } ;;
    esac
    f2b_configure_shared 2222 auto preserve && fail "accepted $WHY failure"
    cmp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/base-before" || fail 'base not restored'
    cmp "$(f2b_legacy_file)" "$QUENCH_TEST_F2B_ROOT/legacy-before" || fail 'legacy not restored'
    [ ! -f "$(f2b_advanced_file)" ] || fail 'new advanced file survived failure'
    [ ! -f "$QUENCH_F2B_STATE_DIR/pending" ] || fail 'successful restore left pending marker'
    :
}
for CASE in validate write restart runtime; do
    run_test "Failed $CASE restores original shared file and legacy drop-in" t_failure "$CASE"
done

t_restore_failure() {
    setup_shared restore_failure; legacy_shared
    f2b_validate_config() { return 1; }
    atomic_restore_file() { return 1; }
    f2b_configure_shared 2222 auto preserve && fail 'failed recovery returned success'
    [ -s "$QUENCH_F2B_STATE_DIR/pending" ] || fail 'no durable failure marker'
    local WORK
    WORK=$(cat "$QUENCH_F2B_STATE_DIR/pending")
    [ -f "$WORK/base" ] && [ -f "$WORK/legacy" ] || fail 'recovery material lost'
    f2b_configure_shared 2223 auto preserve && fail 'unresolved migration allowed another write'
    :
}
run_test 'Failed recovery retains durable backups and blocks another migration' t_restore_failure

t_conflict() {
    setup_shared "conflict-$1"; legacy_shared
    case "$1" in
        dropin) printf '[sshd]\nport = 2222\n' > "$QUENCH_TEST_F2B_ROOT/jail.d/99-external.local" ;;
        foreign) printf '[sshd]\nport = 22\n' > "$(f2b_legacy_file)" ;;
        extra) printf '\n[nginx]\nenabled = true\n' >> "$(f2b_legacy_file)" ;;
        advanced) printf '[sshd]\nport = 22\n' > "$(f2b_advanced_file)" ;;
    esac
    cp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/before"
    f2b_configure_shared 2222 auto preserve && fail 'accepted ambiguous ownership/override'
    cmp "$QUENCH_F2B_JAIL_LOCAL" "$QUENCH_TEST_F2B_ROOT/before" || fail 'changed config on refusal'
    [ -f "$(f2b_legacy_file)" ] || fail 'removed legacy on refusal'
    :
}
for CASE in dropin foreign extra advanced; do
    run_test "Refuse $CASE conflict without overwriting user configuration" t_conflict "$CASE"
done

t_effective_mismatch() {
    setup_shared effective
    f2b_configure_shared 2222 auto start || fail 'setup failed'
    printf '[sshd]\nport = 22\n' > "$QUENCH_TEST_F2B_ROOT/jail.d/99-later.local"
    f2b_shared_effective_check no && fail 'accepted merged port mismatch'
    rm "$QUENCH_TEST_F2B_ROOT/jail.d/99-later.local"
    f2b_write_section_param sshd port 2223
    f2b_shared_effective_check yes && fail 'accepted stale runtime port'
    :
}
run_test 'Checks reject merged configuration overrides and stale runtime actions' t_effective_mismatch

t_guard() {
    setup_shared guard
    safety_timer_pending() { return 0; }
    f2b_configure_shared 2222 auto preserve && fail 'wrote while rollback pending'
    [ ! -e "$QUENCH_F2B_JAIL_LOCAL" ] || fail 'configuration changed despite lock guard'
    :
}
run_test 'Shared migration respects pending rollback protection' t_guard

test_summary 'Fail2ban shared configuration'
