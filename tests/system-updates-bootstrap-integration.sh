#!/usr/bin/env bash
# Installs Python only in a fresh Debian CI container; the selected full upgrade
# is simulated. Do not install Python before this test: that hid the regression.
set -euo pipefail
[ "${QUENCH_TEST_BOOTSTRAP_CONTAINER:-}" = 1 ] && [ -f /.dockerenv ] \
    || { echo 'Run only in an explicit disposable Debian Docker container.' >&2; exit 1; }
! command -v python3 >/dev/null 2>&1 || { echo 'Test requires a pristine image without Python.' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUENCH_TEST_BOOTSTRAP_ROOT=$(mktemp -d /tmp/quench-bootstrap-test.XXXXXX)
trap 'rm -rf "$QUENCH_TEST_BOOTSTRAP_ROOT"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
QUENCH_UPDATE_STATE_DIR="$QUENCH_TEST_BOOTSTRAP_ROOT/updates"
QUENCH_TXN_DIR="$QUENCH_TEST_BOOTSTRAP_ROOT/transactions"
QUENCH_TXN_LOCK_FILE="$QUENCH_TEST_BOOTSTRAP_ROOT/txn.lock"
SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22'; SSH_TTY=''; TMUX=''; STY=''
system_update_tmux_launch() { echo 'Onboarding must stay in the current terminal' >&2; return 99; }
system_update_terminal_ready() { return 0; }
confirm_change_preview() { return 0; }
audit_action() { printf '%s %s\n' "$2" "$1" >> "$QUENCH_TEST_BOOTSTRAP_ROOT/audit"; }
system_update_apt_locked() {
    [ "$1" = full ] || return 1
    system_update_python_ready || return 1
    system_update_apt_preflight || return 1
    # The real update entry gets its own original-source indices, not the
    # private bootstrap indices. Simulate the chosen upgrade but never run it.
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_apt_origins_guard "$(system_update_debian_code)" || return 1
    LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_TEST_BOOTSTRAP_ROOT/full-plan" || return 1
    touch "$QUENCH_TEST_BOOTSTRAP_ROOT/continued-full"
}
cp -a /etc/apt "$QUENCH_TEST_BOOTSTRAP_ROOT/apt-before"
first_run_package_updates_setup <<< $'2\ny'
test -f "$QUENCH_TEST_BOOTSTRAP_ROOT/continued-full"
system_update_python_ready
diff -r "$QUENCH_TEST_BOOTSTRAP_ROOT/apt-before" /etc/apt
grep -q 'operation=full' "$QUENCH_UPDATE_STATE_DIR"/run-*/result.txt
grep -q 'exit_code=0' "$QUENCH_UPDATE_STATE_DIR"/run-*/result.txt
grep -q SUCCESS "$QUENCH_TEST_BOOTSTRAP_ROOT/audit"
echo "Fresh Debian $(system_update_debian_code): Python bootstrap and onboarding continuation passed."
