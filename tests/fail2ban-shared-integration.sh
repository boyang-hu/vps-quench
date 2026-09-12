#!/usr/bin/env bash
# Uses the real Fail2ban parser/server with a no-op action and isolated paths.
# Override QUENCH_TEST_F2B_SOURCE to test a checked-out Fail2ban source tree.
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quench-f2b-integration.XXXXXX")
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
cleanup() {
    local RC=$?
    fail2ban-client stop >/dev/null 2>&1 || true
    if [ "$RC" != 0 ] && [ -f "$TMP/fail2ban.log" ]; then
        tail -60 "$TMP/fail2ban.log" >&2
    fi
    rm -rf "$TMP"
    return "$RC"
}
trap cleanup EXIT
if [ -n "${QUENCH_TEST_F2B_SOURCE:-}" ]; then
    export PYTHONPATH="$QUENCH_TEST_F2B_SOURCE${PYTHONPATH:+:$PYTHONPATH}"
    CLIENT=(python3 "$QUENCH_TEST_F2B_SOURCE/bin/fail2ban-client")
    CONFIG_SOURCE="$QUENCH_TEST_F2B_SOURCE/config"
else
    CLIENT=("$(command -v fail2ban-client)")
    CONFIG_SOURCE=/etc/fail2ban
fi
mkdir -p "$TMP/config/jail.d"
for FILE in "$CONFIG_SOURCE"/*.conf; do cp "$FILE" "$TMP/config/"; done
cp -R "$CONFIG_SOURCE/filter.d" "$CONFIG_SOURCE/action.d" "$TMP/config/"
cat > "$TMP/config/fail2ban.local" <<EOF
[Definition]
logtarget = $TMP/fail2ban.log
socket = $TMP/socket
pidfile = $TMP/pid
dbfile = None
allowipv6 = auto
EOF
cat > "$TMP/config/action.d/quench-test.conf" <<'EOF'
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /bin/true
actionunban = /bin/true
[Init]
port = 22
EOF
: > "$TMP/auth.log"
cat > "$TMP/config/jail.local" <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
[sshd]
port = 22
bantime = 600
findtime = 300
maxretry = 5
ignoreip = 192.0.2.10
[nginx-http-auth]
enabled = false
EOF
cat > "$TMP/config/jail.d/zz-vps-quench.local" <<EOF
# Managed by Quench. Keep unrelated jails in jail.local or separate jail.d files.
[sshd]
enabled = true
port = 2222
backend = polling
banaction = quench-test
logpath = $TMP/auth.log
bantime = 1h
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.maxtime = 1w
EOF
QUENCH_F2B_JAIL_LOCAL="$TMP/config/jail.local"
QUENCH_F2B_STATE_DIR="$TMP/state"
QUENCH_TXN_DIR="$TMP/transactions"
QUENCH_TXN_LOCK_FILE="$TMP/config.lock"
QUENCH_AUDIT_LOG="$TMP/audit.log"
fail2ban-client() { "${CLIENT[@]}" -c "$TMP/config" -s "$TMP/socket" -p "$TMP/pid" "$@"; }
restart_fail2ban() { fail2ban-client reload --restart sshd; }
start_fail2ban() { fail2ban-client start; }
stop_fail2ban() { fail2ban-client stop; }
f2b_status() { if fail2ban-client ping >/dev/null 2>&1; then echo running; else echo stopped; fi; }
f2b_ping() { fail2ban-client ping >/dev/null 2>&1; }
fw_detect() { echo none; }
f2b_backend_detect() { echo polling; }

f2b_configure_shared 2222 polling start
[ "$(fail2ban-client get sshd action quench-test port)" = 2222 ]
[ "$(fail2ban-client get sshd bantime)" = 3600 ]
[ "$(f2b_get_section_param sshd ignoreip)" = 192.0.2.10 ]
[ ! -f "$(f2b_legacy_file)" ]
ssh_sync_fail2ban_ports 2222,2223
[ "$(fail2ban-client get sshd action quench-test port)" = 2222,2223 ]
ssh_sync_fail2ban_ports 2223
[ "$(fail2ban-client get sshd action quench-test port)" = 2223 ]
# A panel-style change to the shared file must affect the real jail on reload.
f2b_write_section_param sshd bantime 7200
restart_fail2ban
f2b_shared_effective_check yes
[ "$(fail2ban-client get sshd bantime)" = 7200 ]
f2b_configure_shared 2223 polling preserve
[ "$(fail2ban-client get sshd bantime)" = 7200 ]
fail2ban-client get sshd ignoreip | grep -q '192.0.2.10'
echo 'Real Fail2ban shared-configuration integration passed.'
