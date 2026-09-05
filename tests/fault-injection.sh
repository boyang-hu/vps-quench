#!/usr/bin/env bash
set -euo pipefail
# 断言各自用 <<< / < file 提供输入；脚本级 stdin 必须处于 EOF。
# 否则 fw_install 等会走到交互 read 上无限期阻塞且不输出任何信息
# （CI 的 stdin 是 /dev/null，所以这个坑一直没暴露）。
exec < /dev/null

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
# 事务记录现在是遗留事务检查的依据，写不进去事务就会失败。
# 真实运行时是 /var/lib/quench/transactions；测试里指到可写的临时目录。
QUENCH_TXN_DIR="$TMP/transactions"
# 事务锁默认落在 /run/lock，测试环境未必可写；缺少 flock 时会退回 mkdir 锁，
# 建不出锁目录就会（正确地）拒绝变更，所以这里必须指到可写路径。
QUENCH_TXN_LOCK_FILE="$TMP/quench-config.lock"
# shellcheck source=/dev/null
source "$ROOT/vps-quench.sh"
# shellcheck source=lib/harness.sh
source "$ROOT/tests/lib/harness.sh"

t_fitop_001() {
    confirm_change_preview "test" "reject" <<< "n" >/dev/null 2>&1 && { echo "Preview accepted rejection" >&2; exit 1; }
    confirm_change_preview "test" "accept" <<< "y" >/dev/null 2>&1 || { echo "Preview rejected confirmation" >&2; exit 1; }
    :
}
run_test "Preview accepted rejection …+1 项" t_fitop_001

# Passwordless sudo must roll back when the effective non-interactive check fails.
t_fi_001() {
    USER_PASSWD_FILE="$TMP/nopasswd-passwd"
    USER_GROUP_FILE="$TMP/nopasswd-group"
    USER_SUDOERS_DIR="$TMP/nopasswd-sudoers"
    USER_ADMIN_SUDOERS_FILE="$USER_SUDOERS_DIR/90-quench-admins"
    QUENCH_AUDIT_LOG="$TMP/nopasswd-audit.log"
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/bash' \
        'admin:x:1000:1000:Admin:/home/admin:/bin/bash' > "$USER_PASSWD_FILE"
    printf '%s\n' 'root:x:0:' 'sudo:x:27:admin' 'admin:x:1000:' > "$USER_GROUP_FILE"
    info() { :; }
    warn() { :; }
    error() { :; }
    sudo() { :; }
    visudo() { return 0; }
    user_nopasswd_runtime_valid() { return 1; }
    ! user_nopasswd_enable admin >/dev/null 2>&1 \
        || { echo "Passwordless sudo accepted a failed runtime verification" >&2; exit 1; }
    [ ! -e "$(user_nopasswd_file admin)" ] \
        || { echo "Failed passwordless sudo verification left an active rule" >&2; exit 1; }
    :
}
run_test "Passwordless sudo must roll back when the effective non-interactive check fails" t_fi_001

# A colliding sudoers file not owned by Quench must never be overwritten or deleted.
t_fi_002() {
    USER_PASSWD_FILE="$TMP/nopasswd-collision-passwd"
    USER_GROUP_FILE="$TMP/nopasswd-collision-group"
    USER_SUDOERS_DIR="$TMP/nopasswd-collision-sudoers"
    USER_ADMIN_SUDOERS_FILE="$USER_SUDOERS_DIR/90-quench-admins"
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/bash' \
        'admin:x:1000:1000:Admin:/home/admin:/bin/bash' > "$USER_PASSWD_FILE"
    printf '%s\n' 'root:x:0:' 'sudo:x:27:admin' 'admin:x:1000:' > "$USER_GROUP_FILE"
    mkdir -p "$USER_SUDOERS_DIR"
    COLLISION_FILE=$(user_nopasswd_file admin)
    printf 'admin ALL=(root) NOPASSWD: /usr/bin/systemctl\n' > "$COLLISION_FILE"
    chmod 440 "$COLLISION_FILE"
    info() { :; }
    warn() { :; }
    error() { :; }
    sudo() { :; }
    visudo() { return 0; }
    user_nopasswd_runtime_valid() { return 0; }
    ! user_nopasswd_enable admin >/dev/null 2>&1 \
        || { echo "Passwordless sudo overwrote a foreign sudoers file" >&2; exit 1; }
    ! user_nopasswd_disable admin >/dev/null 2>&1 \
        || { echo "Passwordless sudo deleted a foreign sudoers file" >&2; exit 1; }
    grep -qx 'admin ALL=(root) NOPASSWD: /usr/bin/systemctl' "$COLLISION_FILE" \
        || { echo "Foreign sudoers file contents changed" >&2; exit 1; }
    :
}
run_test "A colliding sudoers file not owned by Quench must never be overwritten or deleted" t_fi_002

# A pending network transaction must roll back before another starts. Newly created
# DNS drop-ins must also disappear during immediate rollback.
t_fi_003() {
    SAFETY_ROOT="$TMP/safety-root"
    SAFETY_DATA="$TMP/safety-data"
    SAFETY_SNAPSHOT="$TMP/safety-snapshot.tar.gz"
    SAFETY_NEW_HOST_PATH="/etc/systemd/resolved.conf.d/99-quench-fi-$$.conf"
    SAFETY_NEW_PATH="$SAFETY_ROOT$SAFETY_NEW_HOST_PATH"
    mkdir -p "$SAFETY_ROOT/etc" "$SAFETY_DATA" "$(dirname "$SAFETY_NEW_PATH")"
    printf 'nameserver 192.0.2.53\n' > "$SAFETY_ROOT/etc/resolv.conf"
    tar -czf "$SAFETY_SNAPSHOT" -C "$SAFETY_ROOT" etc/resolv.conf
    QUENCH_DATA_DIR="$SAFETY_DATA"
    QUENCH_BACKUP_DIR="$SAFETY_DATA/backups"
    QUENCH_AUDIT_LOG="$TMP/safety-audit.log"
    CONFIG_RESTORE_ROOT="$SAFETY_ROOT"
    SAFETY_DELAY_SECONDS=600
    SAFETY_PID="" SAFETY_SCRIPT=""
    config_backup_create() { printf '%s\n' "$SAFETY_SNAPSHOT"; }
    svc_is_active() { return 1; }

    safety_arm dns "$SAFETY_NEW_HOST_PATH" >/dev/null \
        || { echo "Could not arm DNS safety transaction" >&2; exit 1; }
    printf 'nameserver 1.1.1.1\n' > "$SAFETY_ROOT/etc/resolv.conf"
    printf '[Resolve]\nDNS=1.1.1.1\n' > "$SAFETY_NEW_PATH"

    safety_arm second_dns "$SAFETY_NEW_HOST_PATH" >/dev/null \
        || { echo "Could not replace a pending safety transaction" >&2; exit 1; }
    grep -qx 'nameserver 192.0.2.53' "$SAFETY_ROOT/etc/resolv.conf" \
        || { echo "A second safety transaction did not restore the first snapshot" >&2; exit 1; }
    [ ! -e "$SAFETY_NEW_PATH" ] \
        || { echo "Safety rollback left a newly-created DNS drop-in behind" >&2; exit 1; }
    cancel_safety_timer
    :
}
run_test "A pending network transaction must roll back before another starts" t_fi_003

t_fi_004() {
    ROLLBACK_MARK="$TMP/dns-immediate-rollback"
    safety_rollback_now() { : > "$ROLLBACK_MARK"; }
    dns_fail_and_rollback 'injected DNS failure' NetworkManager >/dev/null 2>&1 || true
    [ -f "$ROLLBACK_MARK" ] || { echo "DNS failure did not request immediate rollback" >&2; exit 1; }
    :
}
run_test "A failed DNS apply requests an immediate rollback" t_fi_004

t_fi_005() {
    sleep 600 &
    STALE_PID=$!
    trap 'kill "$STALE_PID" 2>/dev/null || true; wait "$STALE_PID" 2>/dev/null || true' EXIT
    SAFETY_PID="$STALE_PID"
    SAFETY_SCRIPT="$TMP/already-finished-rollback.sh"
    ! safety_confirm >/dev/null 2>&1 || { echo "A finished safety timer was treated as active" >&2; exit 1; }
    kill -0 "$STALE_PID" 2>/dev/null || { echo "Safety confirmation killed an unrelated reused PID" >&2; exit 1; }
    :
}
run_test "A finished safety timer is no longer reported as pending" t_fi_005

docker() { [ "$1" = "inspect" ] && printf '<no value>\n'; }
[ -z "$(docker_inspect_label fake-id com.docker.compose.project)" ] || {
    echo "Missing Compose label was treated as a real value" >&2
    exit 1
}

t_fitop_002() {
    docker_compose_url_valid 'https://example.com/path/app.yml?token=1' \
        || { echo "Valid HTTPS Compose URL was rejected" >&2; exit 1; }
    ! docker_compose_url_valid 'http://example.com/app.yml' \
        || { echo "Insecure Compose URL was accepted" >&2; exit 1; }
    ! docker_compose_url_valid 'https://user:secret@example.com/app.yml' \
        || { echo "Credential-bearing Compose URL was accepted" >&2; exit 1; }
    :
}
run_test "Valid HTTPS Compose URL was rejected …+2 项" t_fitop_002

# Atomic replacement must preserve the target mode, and must leave the target
# untouched when staging fails instead of truncating it like a plain cp would.
t_fi_006() {
    ATOMIC_DIR="$TMP/atomic"
    mkdir -p "$ATOMIC_DIR"
    printf 'new\n' > "$ATOMIC_DIR/source"
    printf 'old\n' > "$ATOMIC_DIR/target"
    chmod 644 "$ATOMIC_DIR/target"
    atomic_replace_file "$ATOMIC_DIR/source" "$ATOMIC_DIR/target" \
        || { echo "Atomic replace failed on a writable target" >&2; exit 1; }
    grep -qx new "$ATOMIC_DIR/target" \
        || { echo "Atomic replace did not write the new content" >&2; exit 1; }
    ATOMIC_MODE=$(stat -c '%a' "$ATOMIC_DIR/target" 2>/dev/null || stat -f '%Lp' "$ATOMIC_DIR/target")
    [ "$ATOMIC_MODE" = 644 ] \
        || { echo "Atomic replace leaked the staging mode onto the target: $ATOMIC_MODE" >&2; exit 1; }

    ATOMIC_RO="$ATOMIC_DIR/ro"
    mkdir -p "$ATOMIC_RO"
    printf 'keep\n' > "$ATOMIC_RO/target"
    chmod 500 "$ATOMIC_RO"
    ATOMIC_RC=0
    atomic_replace_file "$ATOMIC_DIR/source" "$ATOMIC_RO/target" >/dev/null 2>&1 || ATOMIC_RC=$?
    chmod 700 "$ATOMIC_RO"
    [ "$ATOMIC_RC" -ne 0 ] \
        || { echo "Atomic replace reported success on an unwritable directory" >&2; exit 1; }
    grep -qx keep "$ATOMIC_RO/target" \
        || { echo "A failed atomic replace damaged the target file" >&2; exit 1; }
    if find "$ATOMIC_DIR" -name '.quench-stage.*' 2>/dev/null | grep -q .; then
        echo "Atomic replace left a staging file behind" >&2
        exit 1
    fi
    :
}
run_test "Atomic replacement must preserve the target mode, and must leave the target untouched when…" t_fi_006

# A broken sshd validation must restore the previous configuration.
SSHD_CONFIG="$TMP/sshd_config"
LAST_SSHD_BACKUP="$TMP/sshd_config.bak"
printf 'Port 2222\n' > "$SSHD_CONFIG"
printf 'Port 22\n' > "$LAST_SSHD_BACKUP"
sshd() { return 1; }
restart_ssh() { return 0; }
t_fitop_003() {
    apply_and_restart >/dev/null 2>&1 && { echo "Expected SSH validation failure" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG" || { echo "SSH rollback did not restore backup" >&2; exit 1; }
    :
}
run_test "Expected SSH validation failure …+1 项" t_fitop_003

# A tar failure must not leave a partial backup archive.
QUENCH_DATA_DIR="$TMP/data"
QUENCH_BACKUP_DIR="$QUENCH_DATA_DIR/backups"
export QUENCH_AUDIT_LOG="$TMP/audit.log"
# shellcheck disable=SC2329 # test stub overrides the sourced function for config_backup_create
config_backup_paths() { printf 'tmp/does-not-exist-quench-test\n'; }
t_fitop_004() {
    config_backup_create injected_failure true >/dev/null 2>&1 && { echo "Expected backup failure" >&2; exit 1; }
    :
}
run_test "Expected backup failure" t_fitop_004
if find "$QUENCH_BACKUP_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q .; then
    echo "Partial backup archive was left behind" >&2
    exit 1
fi

# Retention must remove old archives after the configured limit.
mkdir -p "$TMP/source"
printf 'config\n' > "$TMP/source/value"
config_backup_paths() { printf '%s/source/value\n' "${TMP#/}"; }
export QUENCH_BACKUP_KEEP=2
config_backup_create one true >/dev/null
config_backup_create two true >/dev/null
config_backup_create three true >/dev/null
COUNT=$(find "$QUENCH_BACKUP_DIR" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
t_fitop_005() {
    [ "$COUNT" -eq 2 ] || { echo "Backup retention kept $COUNT archives instead of 2" >&2; exit 1; }
    :
}
run_test "Backup retention kept \$COUNT archives instead of 2" t_fitop_005

# Export/import helpers must validate paths and write archives to a caller-specified destination.
EXPORT_PATH="$TMP/exported-config.tar.gz"
t_fitop_006() {
    config_export_archive "$EXPORT_PATH" test >/dev/null || { echo "Export helper failed" >&2; exit 1; }
    [ -f "$EXPORT_PATH" ] || { echo "Export helper did not create archive" >&2; exit 1; }
    :
}
run_test "Export helper failed …+1 项" t_fitop_006
config_import_archive() { [ "$1" = "$EXPORT_PATH" ]; }
t_fitop_007() {
    config_import_archive "$EXPORT_PATH" >/dev/null || { echo "Import helper failed" >&2; exit 1; }
    :
}
run_test "Import helper failed" t_fitop_007

# Imported archives may contain only the explicit Quench configuration allowlist.
mkdir -p "$TMP/archive-source/etc"
printf 'not allowed\n' > "$TMP/archive-source/etc/passwd"
tar -czf "$TMP/malicious-config.tar.gz" -C "$TMP/archive-source" etc/passwd
config_archive_validate "$TMP/malicious-config.tar.gz" >/dev/null 2>&1 && {
    echo "Config import accepted a path outside the allowlist" >&2
    exit 1
}
mkdir -p "$TMP/archive-source/etc/caddy"
printf 'valid\n' > "$TMP/archive-source/etc/caddy/Caddyfile"
tar -czf "$TMP/valid-config.tar.gz" -C "$TMP/archive-source" etc/caddy/Caddyfile
t_fitop_008() {
    config_archive_validate "$TMP/valid-config.tar.gz" >/dev/null \
        || { echo "Config import rejected an allowlisted path" >&2; exit 1; }
    :
}
run_test "Config import rejected an allowlisted path" t_fitop_008
t_fi_007() {
    export CONFIG_RESTORE_ROOT="$TMP/restored-root"
    config_archive_extract "$TMP/valid-config.tar.gz" >/dev/null
    grep -qx valid "$CONFIG_RESTORE_ROOT/etc/caddy/Caddyfile" \
        || { echo "Allowlisted config archive was not restored" >&2; exit 1; }
    :
}
run_test "Config archive restore accepts allowlisted paths and rejects the rest" t_fi_007

# A partially applied first-run network baseline must restore its file and runtime sysctl values.
t_fi_008() {
    FIRST_RUN_NETWORK_SECURITY_FILE="$TMP/first-run-network-security.conf"
    FIRST_RUN_SYSCTL_STATE="$TMP/first-run-sysctl.state"
    printf '# existing network policy\nnet.ipv4.tcp_syncookies = 0\n' > "$FIRST_RUN_NETWORK_SECURITY_FILE"
    while IFS='|' read -r KEY VALUE; do
        [ "$VALUE" = 1 ] && CURRENT=0 || CURRENT=1
        printf '%s|%s\n' "$KEY" "$CURRENT"
    done < <(first_run_network_security_pairs) > "$FIRST_RUN_SYSCTL_STATE"
    cp "$FIRST_RUN_NETWORK_SECURITY_FILE" "$TMP/first-run-network-security.expected"
    cp "$FIRST_RUN_SYSCTL_STATE" "$TMP/first-run-sysctl.expected"

    first_run_test_sysctl_set() {
        local KEY="$1" VALUE="$2" TEMP
        TEMP=$(mktemp) || return 1
        awk -F'|' -v key="$KEY" -v value="$VALUE" '
            $1 == key {print key "|" value; found=1; next}
            {print}
            END {if (!found) print key "|" value}
        ' "$FIRST_RUN_SYSCTL_STATE" > "$TEMP"
        mv "$TEMP" "$FIRST_RUN_SYSCTL_STATE"
    }
    sysctl() {
        local ASSIGN KEY VALUE
        case "${1:-}" in
            -n) awk -F'|' -v key="$2" '$1 == key {print $2; found=1} END {exit !found}' "$FIRST_RUN_SYSCTL_STATE" ;;
            -w)
                ASSIGN="$2"; KEY=${ASSIGN%%=*}; VALUE=${ASSIGN#*=}
                first_run_test_sysctl_set "$KEY" "$VALUE"
                ;;
            -p)
                KEY=$(first_run_network_security_pairs | head -1 | cut -d'|' -f1)
                VALUE=$(first_run_network_security_pairs | head -1 | cut -d'|' -f2)
                first_run_test_sysctl_set "$KEY" "$VALUE"
                return 1
                ;;
            *) return 1 ;;
        esac
    }
    ensure_sysctl() { return 0; }
    has_sysctl_write() { return 0; }
    confirm_change_preview() { return 0; }
    safety_arm() { SAFETY_PID=fake; return 0; }
    cancel_safety_timer() { SAFETY_PID=""; }
    audit_action() { :; }

    ! first_run_network_security_apply >/dev/null 2>&1 \
        || { echo "Partially failed first-run sysctl apply returned success" >&2; exit 1; }
    cmp -s "$FIRST_RUN_NETWORK_SECURITY_FILE" "$TMP/first-run-network-security.expected" \
        || { echo "First-run sysctl failure did not restore the config file" >&2; exit 1; }
    cmp -s "$FIRST_RUN_SYSCTL_STATE" "$TMP/first-run-sysctl.expected" \
        || { echo "First-run sysctl failure did not restore runtime values" >&2; exit 1; }
    :
}
run_test "A partially applied first-run network baseline must restore its file and runtime sysctl values" t_fi_008

# Firewall installation must never enable UFW when the rate-limited SSH rule failed.
t_fi_009() {
    UFW_LOG="$TMP/ufw.log"
    print_header() { :; }
    info() { :; }
    error() { :; }
    pkg_install() { return 0; }
    safety_arm() { return 0; }
    safety_confirm() { :; }
    get_config() { echo 2222; }
    ufw() {
        printf '%s\n' "$*" >> "$UFW_LOG"
        [ "$1 $2" != "limit 2222/tcp" ]
    }
    fw_install ufw >/dev/null 2>&1 && { echo "UFW install succeeded after SSH allow failure" >&2; exit 1; }
    ! grep -q -- '--force enable' "$UFW_LOG" || { echo "UFW was enabled without its SSH rule" >&2; sed 's/^/  /' "$UFW_LOG" >&2; exit 1; }
    :
}
run_test "Firewall installation must never enable UFW when the rate-limited SSH rule failed" t_fi_009

# UFW's own netfilter rules must not be mistaken for a separate raw-iptables backend.
t_fi_010() {
    IPTABLES_CALLED=false
    UFW_LIMIT=false
    info() { :; }
    warn() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    ufw() {
        if [ "$1" = status ]; then
            printf 'Status: active\n'
            [ "$UFW_LIMIT" = true ] && printf '2222/tcp LIMIT IN Anywhere\n'
            return 0
        fi
        [ "$1" = limit ] && UFW_LIMIT=true
        return 0
    }
    iptables() { IPTABLES_CALLED=true; return 1; }
    firewall_allow_port 2222 <<< '' >/dev/null \
        || { echo "UFW SSH port allowance failed" >&2; exit 1; }
    [ "$IPTABLES_CALLED" = false ] \
        || { echo "UFW rules were misclassified as raw iptables" >&2; exit 1; }
    :
}
run_test "UFW's own netfilter rules must not be mistaken for a separate raw-iptables backend" t_fi_010

# A successful UFW command without an effective rule must still abort SSH migration.
t_fi_011() {
    info() { :; }
    warn() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    ufw() {
        [ "$1" = status ] && printf 'Status: active\n'
        return 0
    }
    ! firewall_allow_port 2222 <<< '' >/dev/null 2>&1 \
        || { echo "UFW allowance was accepted without an effective LIMIT rule" >&2; exit 1; }
    :
}
run_test "A successful UFW command without an effective rule must still abort SSH migration" t_fi_011

# A pre-existing broad ALLOW must not silently bypass the newly added SSH LIMIT rule.
t_fi_012() {
    info() { :; }
    warn() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    ufw() {
        if [ "$1" = status ]; then
            printf 'Status: active\n2222/tcp ALLOW IN Anywhere\n2222/tcp LIMIT IN Anywhere\n'
        fi
        return 0
    }
    ! firewall_allow_port 2222 <<< '' >/dev/null 2>&1 \
        || { echo "UFW broad ALLOW was allowed to bypass SSH rate limiting" >&2; exit 1; }
    :
}
run_test "A pre-existing broad ALLOW must not silently bypass the newly added SSH LIMIT rule" t_fi_012

# A broad UFW deny/reject must not be mistaken for a usable SSH allowance.
t_fi_013() {
    ufw() { printf 'Status: active\n2222/tcp LIMIT IN Anywhere\n2222/tcp DENY IN Anywhere\n'; }
    svc_is_active() { return 1; }
    ! firewall_port_ready 2222 \
        || { echo "UFW broad DENY was ignored during SSH readiness validation" >&2; exit 1; }
    :
}
run_test "A broad UFW deny/reject must not be mistaken for a usable SSH allowance" t_fi_013

# firewalld SSH rules must target the zone bound to the active interface, not blindly use default.
t_fi_014() {
    FWD_LOG="$TMP/firewalld-ssh-zone.log"
    info() { :; }
    warn() { :; }
    error() { :; }
    svc_is_active() { [ "$1" = firewalld ]; }
    fw_firewalld_zone() { echo external; }
    firewall-cmd() { printf '%s\n' "$*" >> "$FWD_LOG"; return 0; }
    firewall_allow_port 2222 <<< '' >/dev/null \
        || { echo "firewalld SSH allowance failed" >&2; exit 1; }
    grep -Fq -- '--permanent --zone=external --add-port=2222/tcp' "$FWD_LOG" \
        || { echo "firewalld SSH rule used the wrong zone" >&2; exit 1; }
    grep -Fq -- '--zone=external --query-port=2222/tcp' "$FWD_LOG" \
        || { echo "firewalld SSH rule was not verified in its active zone" >&2; exit 1; }
    :
}
run_test "firewalld SSH rules must target the zone bound to the active interface, not blindly use default" t_fi_014

# UFW installation must set explicit defaults, limit SSH, and keep web ports closed by default.
t_fi_015() {
    UFW_LOG="$TMP/ufw-minimal.log"
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    pkg_install() { return 0; }
    safety_arm() { return 0; }
    safety_confirm() { :; }
    cancel_safety_timer() { :; }
    svc_is_active() { return 1; }
    get_config() { echo 2222; }
    ufw() {
        printf '%s\n' "$*" >> "$UFW_LOG"
        case "$*" in
            status) printf 'Status: active\n2222/tcp LIMIT IN Anywhere\n' ;;
        esac
        return 0
    }
    fw_install ufw </dev/null >/dev/null 2>&1 || { echo "Minimal UFW installation failed" >&2; exit 1; }
    grep -qx 'default deny incoming' "$UFW_LOG" || { echo "UFW incoming default was not denied" >&2; exit 1; }
    grep -qx 'default allow outgoing' "$UFW_LOG" || { echo "UFW outgoing default was not allowed" >&2; exit 1; }
    grep -qx 'logging low' "$UFW_LOG" || { echo "UFW low logging was not enabled" >&2; exit 1; }
    grep -qx 'limit 2222/tcp' "$UFW_LOG" || { echo "UFW SSH rule was not rate-limited" >&2; exit 1; }
    ! grep -Eq 'allow (80|443)/tcp' "$UFW_LOG" || { echo "UFW opened web ports without confirmation" >&2; exit 1; }
    :
}
run_test "UFW installation must set explicit defaults, limit SSH, and keep web ports closed by default" t_fi_015

# A first firewalld start must write the permanent SSH rule while the daemon is still offline.
t_fi_016() {
    FWD_LOG="$TMP/firewalld-order.log"
    FWD_ACTIVE=false
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    pkg_install() { return 0; }
    safety_arm() { return 0; }
    safety_confirm() { :; }
    cancel_safety_timer() { :; }
    get_config() { echo 2222; }
    svc_enable() { :; }
    svc_start() { printf 'START\n' >> "$FWD_LOG"; FWD_ACTIVE=true; }
    svc_is_active() { [ "$1" = firewalld ] && [ "$FWD_ACTIVE" = true ]; }
    firewall-offline-cmd() { printf 'OFFLINE %s\n' "$*" >> "$FWD_LOG"; }
    firewall-cmd() {
        case "$1" in
            --get-default-zone) echo public ;;
            --zone=public) return 0 ;;
        esac
    }
    fw_install firewalld </dev/null >/dev/null 2>&1 || { echo "Safe firewalld installation failed" >&2; exit 1; }
    OFFLINE_LINE=$(grep -n 'OFFLINE .*--add-port=2222/tcp' "$FWD_LOG" | cut -d: -f1)
    START_LINE=$(grep -n '^START$' "$FWD_LOG" | cut -d: -f1)
    [ -n "$OFFLINE_LINE" ] && [ -n "$START_LINE" ] && [ "$OFFLINE_LINE" -lt "$START_LINE" ] \
        || { echo "firewalld started before its SSH rule was written" >&2; exit 1; }
    :
}
run_test "A first firewalld start must write the permanent SSH rule while the daemon is still offline" t_fi_016

# Port/IP input helpers must reject malformed or out-of-range values and support IPv6 CIDR.
t_fitop_009() {
    [ "$(fw_port_spec_normalize 3000:3010/tcp ufw)" = 3000:3010/tcp ] \
        || { echo "UFW port range normalization failed" >&2; exit 1; }
    [ "$(fw_port_spec_normalize 3000:3010/tcp firewalld)" = 3000-3010/tcp ] \
        || { echo "firewalld port range normalization failed" >&2; exit 1; }
    ! fw_port_spec_normalize 70000/tcp ufw >/dev/null 2>&1 \
        || { echo "Out-of-range firewall port was accepted" >&2; exit 1; }
    [ "$(fw_ip_family 2001:db8::/64)" = ipv6 ] || { echo "IPv6 CIDR validation failed" >&2; exit 1; }
    ! fw_ip_family 999.2.3.4 >/dev/null 2>&1 || { echo "Invalid IPv4 address was accepted" >&2; exit 1; }
    :
}
run_test "UFW port range normalization failed …+4 项" t_fitop_009

# UFW verification must handle both compact, directional, and IPv6 status layouts.
t_fi_017() {
    ufw() {
        cat <<'EOF'
Status: active
22/tcp LIMIT Anywhere
22/tcp (v6) LIMIT IN Anywhere (v6)
2223/tcp ALLOW IN 203.0.113.10
EOF
    }
    ufw_port_rule_present 22 LIMIT broad \
        || { echo "UFW compact broad LIMIT rule was not recognized" >&2; exit 1; }
    ufw_port_rule_present 2223 ALLOW \
        || { echo "UFW source-scoped ALLOW rule was not recognized" >&2; exit 1; }
    ! ufw_port_rule_present 2223 ALLOW broad \
        || { echo "UFW source-scoped rule was mistaken for a broad rule" >&2; exit 1; }
    :
}
run_test "UFW verification must handle both compact, directional, and IPv6 status layouts" t_fi_017

# Trusted-source SSH rules must cover both ports during a staged SSH migration.
t_fi_018() {
    UFW_LOG="$TMP/ufw-source.log"
    print_header() { :; }
    info() { :; }
    error() { :; }
    ssh_effective_ports() { printf '%s\n' 22 2222; }
    ufw() { printf '%s\n' "$*" >> "$UFW_LOG"; }
    ufw_allow_ip <<< $'203.0.113.10\n1' >/dev/null \
        || { echo "UFW trusted SSH source rule failed" >&2; exit 1; }
    grep -Fqx 'allow from 203.0.113.10 to any port 22 proto tcp' "$UFW_LOG" \
        || { echo "UFW trusted source missed old SSH port" >&2; exit 1; }
    grep -Fqx 'allow from 203.0.113.10 to any port 2222 proto tcp' "$UFW_LOG" \
        || { echo "UFW trusted source missed new SSH port" >&2; exit 1; }
    :
}
run_test "Trusted-source SSH rules must cover both ports during a staged SSH migration" t_fi_018
t_fi_019() {
    FWD_LOG="$TMP/firewalld-source.log"
    print_header() { :; }
    info() { :; }
    error() { :; }
    ssh_effective_ports() { printf '%s\n' 22 2222; }
    fw_firewalld_zone() { echo public; }
    firewall-cmd() { printf '%s\n' "$*" >> "$FWD_LOG"; }
    fwd_allow_ip <<< $'2001:db8::10\n1' >/dev/null \
        || { echo "firewalld trusted SSH source rule failed" >&2; exit 1; }
    grep -Fq "port port='22' protocol='tcp' accept" "$FWD_LOG" \
        || { echo "firewalld trusted source missed old SSH port" >&2; exit 1; }
    grep -Fq "port port='2222' protocol='tcp' accept" "$FWD_LOG" \
        || { echo "firewalld trusted source missed new SSH port" >&2; exit 1; }
    :
}
run_test "firewalld keeps a trusted SSH source rule after a partial failure" t_fi_019

# Atomic replacement must leave the destination untouched when staging fails.
t_fi_020() {
    SOURCE="$TMP/update-source"
    DEST="$TMP/update-dest"
    printf 'new\n' > "$SOURCE"
    printf 'old\n' > "$DEST"
    install() { return 1; }
    ! self_atomic_replace "$SOURCE" "$DEST" || { echo "Atomic update ignored install failure" >&2; exit 1; }
    grep -qx old "$DEST" || { echo "Atomic update damaged the current script" >&2; exit 1; }
    :
}
run_test "Atomic replacement must leave the destination untouched when staging fails" t_fi_020

# Caddy startup failure must propagate instead of reporting success.
t_fi_021() {
    CADDYFILE="$TMP/Caddyfile"
    : > "$CADDYFILE"
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    svc_start() { return 1; }
    caddy() { [ "$1" = validate ]; }
    ! caddy_reload_config >/dev/null 2>&1 || { echo "Caddy reload hid a startup failure" >&2; exit 1; }
    :
}
run_test "Caddy startup failure must propagate instead of reporting success" t_fi_021

# Caddy layout adoption must restore the exact root config if active reload fails.
t_fi_022() {
    CADDY_CONFIG_DIR="$TMP/caddy-layout-failure"
    CADDYFILE="$CADDY_CONFIG_DIR/Caddyfile"
    CADDY_SITES_DIR="$CADDY_CONFIG_DIR/sites.d"
    CADDY_LOG_DIR="$CADDY_CONFIG_DIR/log"
    CADDY_DATA_DIR="$CADDY_CONFIG_DIR/data"
    CADDY_STATE_DIR="$CADDY_CONFIG_DIR/state"
    CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
    mkdir -p "$CADDY_CONFIG_DIR"
    printf 'original.example.com {\n    respond "original"\n}\n' > "$CADDYFILE"
    cp "$CADDYFILE" "$TMP/Caddyfile.original"
    confirm_file_diff() { return 0; }
    caddy_validate() { return 0; }
    svc_is_active() { return 0; }
    RELOAD_CALLS=0
    caddy_reload_active() {
        RELOAD_CALLS=$((RELOAD_CALLS + 1))
        [ "$RELOAD_CALLS" -gt 1 ]
    }
    caddy_backup_before_change() { :; }
    audit_action() { :; }
    ! caddy_ensure_layout >/dev/null 2>&1 \
        || { echo "Caddy layout adoption hid a reload failure" >&2; exit 1; }
    cmp -s "$TMP/Caddyfile.original" "$CADDYFILE" \
        || { echo "Caddy layout failure did not restore the root config" >&2; exit 1; }
    ! grep -qF '# BEGIN QUENCH CADDY SITE IMPORT' "$CADDYFILE" \
        || { echo "Caddy failed layout import remained after rollback" >&2; exit 1; }
    :
}
run_test "Caddy layout adoption must restore the exact root config if active reload fails" t_fi_022

# A failed managed-site apply must remove the staged site and reload the old config.
t_fi_023() {
    CADDY_CONFIG_DIR="$TMP/caddy-apply-failure"
    CADDYFILE="$CADDY_CONFIG_DIR/Caddyfile"
    CADDY_SITES_DIR="$CADDY_CONFIG_DIR/sites.d"
    CADDY_LOG_DIR="$CADDY_CONFIG_DIR/log"
    CADDY_DATA_DIR="$CADDY_CONFIG_DIR/data"
    CADDY_STATE_DIR="$CADDY_CONFIG_DIR/state"
    CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
    mkdir -p "$CADDY_SITES_DIR" "$CADDY_STATE_DIR"
    printf 'import %s/*.caddy\n' "$CADDY_SITES_DIR" > "$CADDYFILE"
    caddy_ensure_layout() { return 0; }
    caddy_validate() { return 0; }
    svc_is_active() { return 0; }
    caddy_reload_or_start() { return 1; }
    ROLLBACK_RELOADS=0
    caddy_reload_active() { ROLLBACK_RELOADS=$((ROLLBACK_RELOADS + 1)); return 0; }
    caddy_backup_before_change() { :; }
    audit_action() { :; }
    CONTENT=$(caddy_render_proxy_site 'failed.example.com' '127.0.0.1:8080' 'failed.example.com')
    ! caddy_apply_managed_site proxy failed.example.com 127.0.0.1:8080 "$CONTENT" >/dev/null 2>&1 \
        || { echo "Caddy managed-site apply hid a reload failure" >&2; exit 1; }
    [ ! -e "$CADDY_SITES_DIR/failed.example.com.caddy" ] \
        || { echo "Caddy failed site file remained after rollback" >&2; exit 1; }
    [ "$ROLLBACK_RELOADS" -eq 1 ] \
        || { echo "Caddy did not reload the previous active config" >&2; exit 1; }
    :
}
run_test "A failed managed-site apply must remove the staged site and reload the old config" t_fi_023

# Failed site deletion must restore both contents and permissions.
t_fi_024() {
    CADDY_CONFIG_DIR="$TMP/caddy-delete-failure"
    CADDYFILE="$CADDY_CONFIG_DIR/Caddyfile"
    CADDY_SITES_DIR="$CADDY_CONFIG_DIR/sites.d"
    CADDY_LOG_DIR="$CADDY_CONFIG_DIR/log"
    CADDY_DATA_DIR="$CADDY_CONFIG_DIR/data"
    CADDY_STATE_DIR="$CADDY_CONFIG_DIR/state"
    CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
    mkdir -p "$CADDY_SITES_DIR" "$CADDY_STATE_DIR"
    printf 'import %s/*.caddy\n' "$CADDY_SITES_DIR" > "$CADDYFILE"
    SITE_FILE="$CADDY_SITES_DIR/restore.example.com.caddy"
    caddy_render_static_site restore.example.com /var/www/restore.example.com restore.example.com > "$SITE_FILE"
    chmod 640 "$SITE_FILE"
    cp "$SITE_FILE" "$TMP/Caddy-site.original"
    MODE_BEFORE=$(stat -c '%a' "$SITE_FILE" 2>/dev/null || stat -f '%Lp' "$SITE_FILE")
    confirm_change_preview() { return 0; }
    caddy_validate() { return 0; }
    svc_is_active() { return 0; }
    RELOAD_CALLS=0
    caddy_reload_active() {
        RELOAD_CALLS=$((RELOAD_CALLS + 1))
        [ "$RELOAD_CALLS" -gt 1 ]
    }
    caddy_backup_before_change() { :; }
    audit_action() { :; }
    ! caddy_delete_site >/dev/null 2>&1 <<'EOF'
1
EOF
    cmp -s "$TMP/Caddy-site.original" "$SITE_FILE" \
        || { echo "Caddy deletion rollback changed site contents" >&2; exit 1; }
    MODE_AFTER=$(stat -c '%a' "$SITE_FILE" 2>/dev/null || stat -f '%Lp' "$SITE_FILE")
    [ "$MODE_AFTER" = "$MODE_BEFORE" ] \
        || { echo "Caddy deletion rollback changed site permissions" >&2; exit 1; }
    :
}
run_test "Failed site deletion must restore both contents and permissions" t_fi_024

# Quench Fail2ban changes are scoped to sshd and must not rewrite global defaults.
t_fi_025() {
    export F2B_JAIL_LOCAL="$TMP/jail.local"
    cat > "$F2B_JAIL_LOCAL" <<'EOF'
[DEFAULT]
bantime = 3600
[sshd]
bantime = 120
enabled = true
EOF
    fail2ban-client() { return 0; }
    f2b_set_param bantime 7200 >/dev/null
    [ "$(awk '/^\[DEFAULT\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 3600 ] \
        || { echo "Fail2ban SSH update changed DEFAULT" >&2; exit 1; }
    [ "$(awk '/^\[sshd\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 7200 ] \
        || { echo "Fail2ban SSH update missed sshd section" >&2; exit 1; }
    :
}
run_test "Quench Fail2ban changes are scoped to sshd and must not rewrite global defaults" t_fi_025

# The managed Fail2ban drop-in must use real numeric ports and escalating bans.
t_fi_026() {
    F2B_RENDER="$TMP/zz-vps-quench.local"
    f2b_render_managed_config "$F2B_RENDER" systemd 22,2222 'allowipv6 = auto'
    grep -Eq '^port[[:space:]]*=[[:space:]]*22,2222$' "$F2B_RENDER" \
        || { echo "Fail2ban managed config missed SSH migration ports" >&2; exit 1; }
    grep -Eq '^mode[[:space:]]*=[[:space:]]*aggressive$' "$F2B_RENDER" \
        || { echo "Fail2ban aggressive mode is missing" >&2; exit 1; }
    grep -Eq '^bantime\.increment[[:space:]]*=[[:space:]]*true$' "$F2B_RENDER" \
        || { echo "Fail2ban escalating bans are missing" >&2; exit 1; }
    :
}
run_test "The managed Fail2ban drop-in must use real numeric ports and escalating bans" t_fi_026

# Invalid Fail2ban edits must restore the previous managed drop-in.
t_fi_027() {
    export F2B_JAIL_LOCAL="$TMP/fail2ban-rollback.local"
    printf '[sshd]\nenabled = true\nport = 22\n' > "$F2B_JAIL_LOCAL"
    fail2ban-client() { return 1; }
    ! f2b_set_param_jail port 2222 >/dev/null 2>&1 \
        || { echo "Invalid Fail2ban change was accepted" >&2; exit 1; }
    grep -Eq '^port[[:space:]]*=[[:space:]]*22$' "$F2B_JAIL_LOCAL" \
        || { echo "Fail2ban validation failure did not restore the original file" >&2; exit 1; }
    :
}
run_test "Invalid Fail2ban edits must restore the previous managed drop-in" t_fi_027

# Updating SSH while Fail2ban is intentionally stopped must update its file without starting it.
t_fi_028() {
    export F2B_JAIL_LOCAL="$TMP/fail2ban-stopped.local"
    printf '[sshd]\nenabled = true\nport = 22\n' > "$F2B_JAIL_LOCAL"
    RESTARTED=false
    info() { :; }
    warn() { :; }
    error() { :; }
    f2b_status() { echo stopped; }
    restart_fail2ban() { RESTARTED=true; }
    fail2ban-client() { :; }
    ssh_sync_fail2ban_ports 22,2222 \
        || { echo "Stopped Fail2ban blocked SSH port synchronization" >&2; exit 1; }
    [ "$RESTARTED" = false ] \
        || { echo "SSH port synchronization started an intentionally stopped Fail2ban" >&2; exit 1; }
    grep -Eq '^port[[:space:]]*=[[:space:]]*22,2222$' "$F2B_JAIL_LOCAL" \
        || { echo "Stopped Fail2ban configuration did not receive both SSH ports" >&2; exit 1; }
    :
}
run_test "Updating SSH while Fail2ban is intentionally stopped must update its file without starting it" t_fi_028

# A running sshd jail health failure must restore the previous Fail2ban port configuration.
t_fi_029() {
    export F2B_JAIL_LOCAL="$TMP/fail2ban-jail-health.local"
    printf '[sshd]\nenabled = true\nport = 22\n' > "$F2B_JAIL_LOCAL"
    RESTART_COUNT=0
    info() { :; }
    warn() { :; }
    error() { :; }
    f2b_status() { echo running; }
    fail2ban-client() { :; }
    restart_fail2ban() { RESTART_COUNT=$((RESTART_COUNT + 1)); }
    f2b_runtime_healthy() { [ "$RESTART_COUNT" -ge 2 ]; }
    ! ssh_sync_fail2ban_ports 22,2222 >/dev/null 2>&1 \
        || { echo "Unhealthy Fail2ban sshd jail was accepted" >&2; exit 1; }
    grep -Eq '^port[[:space:]]*=[[:space:]]*22$' "$F2B_JAIL_LOCAL" \
        || { echo "Fail2ban sshd jail health failure did not restore old ports" >&2; exit 1; }
    [ "$RESTART_COUNT" -eq 2 ] \
        || { echo "Fail2ban old configuration was not restarted after rollback" >&2; exit 1; }
    :
}
run_test "A running sshd jail health failure must restore the previous Fail2ban port configuration" t_fi_029

# Firewall cleanup must not report success while a broad UFW SSH rule remains effective.
t_fi_030() {
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    ufw() {
        [ "$1" = status ] && printf 'Status: active\n2222/tcp LIMIT IN Anywhere\n'
        return 0
    }
    ! ssh_firewall_close_port 2222 >/dev/null 2>&1 \
        || { echo "UFW cleanup accepted a rule that remained effective" >&2; exit 1; }
    :
}
run_test "Firewall cleanup must not report success while a broad UFW SSH rule remains effective" t_fi_030

# A runtime restart failure after parameter edits must restore the whole previous file.
t_fi_031() {
    export F2B_JAIL_LOCAL="$TMP/fail2ban-runtime-rollback.local"
    printf '[sshd]\nenabled = true\nport = 22\nbantime = 3600\n' > "$F2B_JAIL_LOCAL"
    print_header() { :; }
    menu_div() { :; }
    menu_pair() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    info() { :; }
    error() { :; }
    f2b_validate_config() { return 0; }
    f2b_status() { echo running; }
    restart_fail2ban() { return 1; }
    f2b_ping() { return 1; }
    ! f2b_config_params <<< $'1\n7200' >/dev/null 2>&1 \
        || { echo "Fail2ban parameter restart failure returned success" >&2; exit 1; }
    grep -Eq '^bantime[[:space:]]*=[[:space:]]*3600$' "$F2B_JAIL_LOCAL" \
        || { echo "Fail2ban restart failure did not restore all parameters" >&2; exit 1; }
    :
}
run_test "A runtime restart failure after parameter edits must restore the whole previous file" t_fi_031


# Swap deletion must stop before touching fstab/files when swapoff fails.
t_fi_032() {
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    QUENCH_SWAP_FILE="$TMP/quench-test.swap"
    QUENCH_SWAP_STATE_DIR="$TMP/quench-swap-state"
    QUENCH_SWAP_STATE_FILE="$QUENCH_SWAP_STATE_DIR/managed-file"
    QUENCH_SWAP_FSTAB="$TMP/quench-fstab"
    mkdir -p "$QUENCH_SWAP_STATE_DIR"
    printf 'swap data\n' > "$QUENCH_SWAP_FILE"
    printf '%s\n' "$QUENCH_SWAP_FILE" > "$QUENCH_SWAP_STATE_FILE"
    printf '# BEGIN QUENCH SWAP\n%s none swap sw 0 0\n# END QUENCH SWAP\n' "$QUENCH_SWAP_FILE" > "$QUENCH_SWAP_FSTAB"
    cp "$QUENCH_SWAP_FSTAB" "$QUENCH_SWAP_FSTAB.expected"
    confirm_change_preview() { return 0; }
    swapon() { [ "$*" != '--show --noheadings' ] || echo "$QUENCH_SWAP_FILE"; }
    swapoff() { return 1; }
    ! swap_delete <<< 'DELETE-SWAP' >/dev/null 2>&1 || { echo "Swap delete ignored swapoff failure" >&2; exit 1; }
    [ -f "$QUENCH_SWAP_FILE" ] || { echo "Swap delete removed file after swapoff failure" >&2; exit 1; }
    cmp -s "$QUENCH_SWAP_FSTAB.expected" "$QUENCH_SWAP_FSTAB" \
        || { echo "Swap delete changed fstab after swapoff failure" >&2; exit 1; }
    :
}
run_test "Swap deletion must stop before touching fstab/files when swapoff fails" t_fi_032

# An existing foreign file at the managed default path must be rejected before swapoff.
t_fi_033() {
    QUENCH_SWAP_FILE="$TMP/foreign-swapfile"
    QUENCH_SWAP_STATE_DIR="$TMP/foreign-swap-state"
    QUENCH_SWAP_STATE_FILE="$QUENCH_SWAP_STATE_DIR/managed-file"
    printf 'foreign data\n' > "$QUENCH_SWAP_FILE"
    cp "$QUENCH_SWAP_FILE" "$QUENCH_SWAP_FILE.expected"
    swap_stage_file() { printf 'new data\n' > "${1}.stage.test"; printf '%s\n' "${1}.stage.test"; }
    swapoff() { : > "$TMP/foreign-swapoff-called"; return 0; }
    ! swap_create_apply 64 >/dev/null 2>&1 \
        || { echo "Swap replacement accepted a foreign target" >&2; exit 1; }
    [ ! -e "$TMP/foreign-swapoff-called" ] \
        || { echo "Swap replacement called swapoff before ownership validation" >&2; exit 1; }
    cmp -s "$QUENCH_SWAP_FILE.expected" "$QUENCH_SWAP_FILE" \
        || { echo "Swap replacement changed a foreign target" >&2; exit 1; }
    :
}
run_test "An existing foreign file at the managed default path must be rejected before swapoff" t_fi_033

# A Docker restart failure must restore the exact previous daemon.json.
t_fi_034() {
    QUENCH_DOCKER_CONFIG="$TMP/docker-daemon.json"
    QUENCH_DOCKER_STATE_DIR="$TMP/docker-state"
    printf '{"data-root":"/srv/original"}\n' > "$QUENCH_DOCKER_CONFIG"
    cp "$QUENCH_DOCKER_CONFIG" "$QUENCH_DOCKER_CONFIG.expected"
    docker_require_ready() { return 0; }
    docker_config_validate() { return 0; }
    confirm_change_preview() { return 0; }
    docker() { [ "${1:-}" != ps ] || return 0; }
    svc_restart() { return 1; }
    ! docker_apply_production_baseline >/dev/null 2>&1 \
        || { echo "Docker baseline ignored a restart failure" >&2; exit 1; }
    cmp -s "$QUENCH_DOCKER_CONFIG.expected" "$QUENCH_DOCKER_CONFIG" \
        || { echo "Docker baseline restart failure did not restore daemon.json" >&2; exit 1; }
    :
}
run_test "A Docker restart failure must restore the exact previous daemon.json" t_fi_034

# NTP repair must report a timedatectl failure.
t_fi_035() {
    print_header() { :; }
    info() { :; }
    error() { :; }
    ts_backend_detect() { echo timesyncd; }
    timedatectl() { return 1; }
    ! ts_ntp_repair >/dev/null 2>&1 || { echo "NTP repair hid timedatectl failure" >&2; exit 1; }
    :
}
run_test "NTP repair must report a timedatectl failure" t_fi_035

# Timezone changes must validate the write instead of reporting false success.
t_fi_036() {
    error() { :; }
    ts_timezone_valid() { return 0; }
    systemd_available() { return 0; }
    timedatectl() { return 1; }
    ! ts_set_timezone UTC >/dev/null 2>&1 || { echo "Timezone update hid timedatectl failure" >&2; exit 1; }
    :
}
run_test "Timezone changes must validate the write instead of reporting false success" t_fi_036

# An external NTP daemon must be reported, not silently replaced by Quench.
t_fi_037() {
    print_header() { :; }
    warn() { :; }
    ts_backend_detect() { echo external:ntpd; }
    ts_ntp_synchronized() { return 1; }
    ! ts_ntp_repair >/dev/null 2>&1 || { echo "Unsynchronized external NTP was reported as repaired" >&2; exit 1; }
    :
}
run_test "An external NTP daemon must be reported, not silently replaced by Quench" t_fi_037

# Resolving an external/managed conflict keeps the external daemon and stops only managed backends.
t_fi_038() {
    print_header() { :; }
    warn() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    audit_action() { :; }
    ts_external_ntp_service() { echo ntpd; }
    ts_ntp_disable_timesyncd() { : > "$TMP/timesyncd-disabled"; }
    ts_ntp_disable_chrony() { : > "$TMP/chrony-disabled"; }
    ts_resolve_ntp_conflict <<< '1' >/dev/null \
        || { echo "External NTP conflict resolution failed" >&2; exit 1; }
    [ -f "$TMP/timesyncd-disabled" ] && [ -f "$TMP/chrony-disabled" ] \
        || { echo "Managed NTP backends were not disabled around an external daemon" >&2; exit 1; }
    :
}
run_test "Resolving an external/managed conflict keeps the external daemon and stops only managed backends" t_fi_038

# Multi-IP source switching must arm an exact route rollback and restore on verification failure.
t_fi_039() {
    QUENCH_DATA_DIR="$TMP/ip-source-safety"
    mkdir -p "$QUENCH_DATA_DIR"
    audit_action() { :; }
    warn() { :; }
    nohup() { return 0; }
    ip_source_safety_arm 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' >/dev/null
    grep -Fq 'ip -4 route replace default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' "$SAFETY_SCRIPT" \
        || { echo "Multi-IP safety timer did not preserve the original route" >&2; exit 1; }
    cancel_safety_timer
    :
}
run_test "Multi-IP source switching must arm an exact route rollback and restore on verification failure" t_fi_039
t_fi_040() {
    APPLIED=0
    RESTORED=0
    print_header() { :; }
    menu_div() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    error() { :; }
    warn() { :; }
    confirm_change_preview() { return 0; }
    ip_source_policy_is_simple() { return 0; }
    ip_source_default_iface() { echo eth0; }
    ip_source_default_route() { echo 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100'; }
    ip_source_addresses() { printf '%s\n' 198.51.100.10 198.51.100.11; }
    ip_source_current() { echo 198.51.100.10; }
    ip_source_safety_arm() { return 0; }
    ip_source_route_replace() { APPLIED=1; }
    ip_source_verify() { return 1; }
    ip_source_route_restore() { RESTORED=1; }
    cancel_safety_timer() { :; }
    ! ip_source_switch_family 4 <<< 2 >/dev/null 2>&1 \
        || { echo "Multi-IP switch accepted a failed HTTPS verification" >&2; exit 1; }
    [ "$APPLIED" -eq 1 ] || { echo "Multi-IP switch did not apply the selected route" >&2; exit 1; }
    [ "$RESTORED" -eq 1 ] || { echo "Multi-IP switch did not restore the route after verification failure" >&2; exit 1; }
    :
}
run_test "Multi-IP switch accepted a failed HTTPS verification" t_fi_040

# If direct route restoration fails, the independent rollback script must remain the fallback.
t_fi_041() {
    APPLIED=0
    FALLBACK=0
    CANCELLED=0
    print_header() { :; }
    menu_div() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    error() { :; }
    warn() { :; }
    confirm_change_preview() { return 0; }
    ip_source_policy_is_simple() { return 0; }
    ip_source_default_iface() { echo eth0; }
    ip_source_default_route() { echo 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100'; }
    ip_source_addresses() { printf '%s\n' 198.51.100.10 198.51.100.11; }
    ip_source_current() { echo 198.51.100.10; }
    ip_source_safety_arm() { return 0; }
    ip_source_route_replace() { APPLIED=1; }
    ip_source_verify() { return 1; }
    ip_source_route_restore() { return 1; }
    cancel_safety_timer() { CANCELLED=1; }
    safety_rollback_now() { FALLBACK=1; }
    ! ip_source_switch_family 4 <<< 2 >/dev/null 2>&1 \
        || { echo "Multi-IP switch accepted failed verification and failed direct restore" >&2; exit 1; }
    [ "$APPLIED" -eq 1 ] || { echo "Multi-IP fallback test did not apply the selected route" >&2; exit 1; }
    [ "$FALLBACK" -eq 1 ] || { echo "Multi-IP switch did not execute its independent rollback fallback" >&2; exit 1; }
    [ "$CANCELLED" -eq 0 ] || { echo "Multi-IP switch canceled rollback after direct restore failed" >&2; exit 1; }
    :
}
run_test "If direct route restoration fails, the independent rollback script must remain the fallback" t_fi_041

# An IPv6 apply failure must immediately invoke the exact-state rollback.
t_fi_042() {
    ROLLED_BACK=0
    IP_V6_SYSCTL_FILE="$TMP/nonexistent-quench-ipv6.conf"
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    confirm_change_preview() { return 0; }
    ip_v6_state_summary() { echo '混合状态（启用 1 / 禁用 1）'; }
    ip_v6_safety_arm() { return 0; }
    ip_apply_v6_state() { return 1; }
    safety_rollback_now() { ROLLED_BACK=1; }
    ! ip_disable_v6 >/dev/null 2>&1 \
        || { echo "IPv6 disable accepted a failed runtime apply" >&2; exit 1; }
    [ "$ROLLED_BACK" -eq 1 ] || { echo "IPv6 apply failure did not invoke exact-state rollback" >&2; exit 1; }
    :
}
run_test "An IPv6 apply failure must immediately invoke the exact-state rollback" t_fi_042

# HTTPS synchronization must not set the clock without enough trusted responses.
t_fi_043() {
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by ts_sync_https
    ts_https_fetch_epoch() { return 1; }
    ! ts_sync_https fallback >/dev/null 2>&1 || { echo "HTTPS time sync accepted zero valid sources" >&2; exit 1; }
    :
}
run_test "HTTPS synchronization must not set the clock without enough trusted responses" t_fi_043

# HTTPS emergency time must report failure if the original NTP backend cannot be resumed.
t_fi_044() {
    CLOCK=2000000000
    SET_MARKER="$TMP/https-clock-set"
    PAUSE_MARKER="$TMP/https-ntp-paused"
    RESUME_MARKER="$TMP/https-ntp-resume-attempted"
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    menu_div() { :; }
    audit_action() { :; }
    ts_https_fetch_epoch() { echo 2000000100; }
    ts_epoch_utc() { echo '2033-05-18 03:35:00'; }
    ts_backend_detect() { echo timesyncd; }
    ts_pause_backend() { : > "$PAUSE_MARKER"; echo timesyncd; }
    ts_resume_backend() { : > "$RESUME_MARKER"; return 1; }
    date() {
        if [ "${1:-}" = -u ] && [ "${2:-}" = -s ]; then
            CLOCK=2000000100
            : > "$SET_MARKER"
            return 0
        fi
        case "$*" in
            *+%s*) echo "$CLOCK" ;;
            *) command date "$@" ;;
        esac
    }
    ! ts_sync_https <<< 'y' >/dev/null 2>&1 \
        || { echo "HTTPS time sync hid NTP resume failure" >&2; exit 1; }
    [ -f "$SET_MARKER" ] && [ -f "$PAUSE_MARKER" ] && [ -f "$RESUME_MARKER" ] \
        || { echo "HTTPS time sync did not exercise pause, set, and resume" >&2; exit 1; }
    :
}
run_test "HTTPS emergency time must report failure if the original NTP backend cannot be resumed" t_fi_044

# A failed APT source copy must leave neither a partial snapshot nor a modified source tree.
t_fi_045() {
    MIRROR_APT_DIR="$TMP/mirror-copy-failure/apt"
    MIRROR_STATE_DIR="$TMP/mirror-copy-failure/state"
    mkdir -p "$MIRROR_APT_DIR/sources.list.d" "$MIRROR_STATE_DIR"
    printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$MIRROR_APT_DIR/sources.list"
    cp() { return 1; }
    ! mirror_apt_snapshot_create >/dev/null 2>&1 \
        || { echo "APT snapshot succeeded after an injected copy failure" >&2; exit 1; }
    grep -qxF 'deb http://archive.ubuntu.com/ubuntu noble main' "$MIRROR_APT_DIR/sources.list" \
        || { echo "APT snapshot failure modified the live source" >&2; exit 1; }
    ! find "$MIRROR_STATE_DIR" -maxdepth 1 -type d -name 'apt-backup.*' | grep -q . \
        || { echo "APT snapshot failure left a partial backup" >&2; exit 1; }
    :
}
run_test "A failed APT source copy must leave neither a partial snapshot nor a modified source tree" t_fi_045

# Strict APT validation failure must restore every source file, including third-party entries.
t_fi_046() {
    MIRROR_APT_DIR="$TMP/mirror-apt-rollback/apt"
    MIRROR_STATE_DIR="$TMP/mirror-apt-rollback/state"
    MIRROR_OS_RELEASE_FILE="$TMP/mirror-apt-rollback/os-release"
    MIRROR_SECURITY_POLICY=official
    QUENCH_MIRROR_ARCH=amd64
    EXPECTED="$TMP/mirror-apt-rollback/expected"
    mkdir -p "$MIRROR_APT_DIR/sources.list.d" "$MIRROR_STATE_DIR"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' > "$MIRROR_OS_RELEASE_FILE"
    cat > "$MIRROR_APT_DIR/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe
deb https://ppa.launchpadcontent.net/example/project/ubuntu noble main
EOF
    cp -a "$MIRROR_APT_DIR" "$EXPECTED"
    mirror_url_probe() { return 0; }
    confirm_change_preview() { return 0; }
    audit_action() { :; }
    apt-get() { return 100; }
    ! mirror_apply_apt ustc >/dev/null 2>&1 \
        || { echo "APT switch succeeded after an injected validation failure" >&2; exit 1; }
    diff -ru "$EXPECTED" "$MIRROR_APT_DIR" >/dev/null \
        || { echo "APT validation failure did not restore the exact source tree" >&2; exit 1; }
    :
}
run_test "Strict APT validation failure must restore every source file, including third-party entries" t_fi_046

# An unreadable DNF enabled-state must abort snapshot creation before any write.
t_fi_047() {
    MIRROR_STATE_DIR="$TMP/mirror-rpm-state-failure/state"
    MIRROR_RPM_REPO_DIR="$TMP/mirror-rpm-state-failure/yum.repos.d"
    mkdir -p "$MIRROR_STATE_DIR" "$MIRROR_RPM_REPO_DIR"
    printf '[baseos]\nenabled=1\n' > "$MIRROR_RPM_REPO_DIR/rocky.repo"
    dnf() { return 1; }
    ! mirror_rpm_snapshot_create >/dev/null 2>&1 \
        || { echo "RPM snapshot accepted an unreadable enabled-repository state" >&2; exit 1; }
    ! find "$MIRROR_STATE_DIR" -maxdepth 1 -type d -name 'rpm-backup.*' | grep -q . \
        || { echo "RPM state-capture failure left a partial backup" >&2; exit 1; }
    :
}
run_test "An unreadable DNF enabled-state must abort snapshot creation before any write" t_fi_047

# An isolated DNF validation failure must restore the exact repository directory.
t_fi_048() {
    MIRROR_STATE_DIR="$TMP/mirror-rpm-rollback/state"
    MIRROR_RPM_REPO_DIR="$TMP/mirror-rpm-rollback/yum.repos.d"
    MIRROR_RPM_GPG_DIR="$TMP/mirror-rpm-rollback/rpm-gpg"
    MIRROR_OS_RELEASE_FILE="$TMP/mirror-rpm-rollback/os-release"
    QUENCH_MIRROR_RPM_ARCH=x86_64
    EXPECTED="$TMP/mirror-rpm-rollback/expected"
    mkdir -p "$MIRROR_STATE_DIR" "$MIRROR_RPM_REPO_DIR" "$MIRROR_RPM_GPG_DIR"
    printf 'ID=rocky\nVERSION_ID="9.6"\n' > "$MIRROR_OS_RELEASE_FILE"
    printf 'test key\n' > "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-Rocky-9"
    printf '[baseos]\nname=Original BaseOS\nenabled=1\n' > "$MIRROR_RPM_REPO_DIR/rocky.repo"
    cp -a "$MIRROR_RPM_REPO_DIR" "$EXPECTED"
    mirror_url_probe() { return 0; }
    confirm_change_preview() { return 0; }
    audit_action() { :; }
    dnf() {
        if [ "${1:-}" = config-manager ] && [ "${2:-}" = --help ]; then return 0; fi
        if [ "${1:-}" = repolist ]; then
            printf 'repo id                  repo name\nbaseos                   Rocky Linux BaseOS\nappstream                Rocky Linux AppStream\n'
            return 0
        fi
        [[ "$*" == *"--disablerepo="* ]] && return 1
        return 0
    }
    ! mirror_apply_rpm aliyun >/dev/null 2>&1 \
        || { echo "RPM switch succeeded after an injected isolated validation failure" >&2; exit 1; }
    diff -ru "$EXPECTED" "$MIRROR_RPM_REPO_DIR" >/dev/null \
        || { echo "RPM validation failure did not restore the exact repository tree" >&2; exit 1; }
    :
}
run_test "An isolated DNF validation failure must restore the exact repository directory" t_fi_048

# Offline bundle creation must package a local script and offline install must place it at the target path.
LOCAL_SCRIPT="$TMP/local-script"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
APP_VERSION="V9.9.9"
echo offline
EOF
chmod 700 "$LOCAL_SCRIPT"
if ! self_offline_bundle_create >/dev/null; then
    echo "Offline bundle creation failed" >&2
    exit 1
fi
OFFLINE_BUNDLE=$(find "$QUENCH_DATA_DIR/offline" -type f -name '*.tar.gz' | head -1)
t_fitop_010() {
    [ -f "$OFFLINE_BUNDLE" ] || { echo "Offline bundle was not created" >&2; exit 1; }
    :
}
run_test "Offline bundle was not created" t_fitop_010
LOCAL_SCRIPT="$TMP/installed-script.sh"
LOCAL_BIN_DIR="$TMP/bin"
t_fitop_011() {
    self_offline_bundle_install "$OFFLINE_BUNDLE" >/dev/null || { echo "Offline install failed" >&2; exit 1; }
    [ -f "$LOCAL_SCRIPT" ] || { echo "Offline install did not place script" >&2; exit 1; }
    [ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Offline install did not create an isolated shortcut" >&2; exit 1; }
    :
}
run_test "Offline install failed …+2 项" t_fitop_011

# Process-substitution descriptors are streams, not complete reusable script files.
if self_resolve_script_source /dev/fd/0 >/dev/null 2>&1; then
    echo "Installer accepted a process-substitution descriptor as a complete script" >&2
    exit 1
fi
BROKEN_LINK_TARGET="$TMP/removed-script.sh"
rm -f "$LOCAL_BIN_DIR/v"
ln -s "$BROKEN_LINK_TARGET" "$LOCAL_BIN_DIR/v"
self_install_shortcut v >/dev/null
t_fitop_012() {
    [ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Installer did not repair a dangling shortcut" >&2; exit 1; }
    :
}
run_test "Installer did not repair a dangling shortcut" t_fitop_012
FOREIGN_SCRIPT="$TMP/foreign-command"
printf '#!/bin/sh\nexit 0\n' > "$FOREIGN_SCRIPT"
chmod +x "$FOREIGN_SCRIPT"
rm -f "$LOCAL_BIN_DIR/V"
ln -s "$FOREIGN_SCRIPT" "$LOCAL_BIN_DIR/V"
self_install_shortcut V >/dev/null
t_fitop_013() {
    [ "$(readlink "$LOCAL_BIN_DIR/V")" = "$FOREIGN_SCRIPT" ] || { echo "Installer overwrote a foreign shortcut" >&2; exit 1; }
    :
}
run_test "Installer overwrote a foreign shortcut" t_fitop_013

# The real updater must reject a mismatched checksum without replacing the local script.
LOCAL_SCRIPT="$TMP/local-script"
self_remote_main_sha() { printf '%040d\n' 1; }
printf 'original\n' > "$LOCAL_SCRIPT"
curl() {
    local URL="" OUT="" PREV=""
    for arg in "$@"; do
        [ "$PREV" = "-o" ] && OUT="$arg"
        case "$arg" in https://*) URL="$arg" ;; esac
        PREV="$arg"
    done
    if [[ "$URL" == *.sha256 ]]; then
        printf '%064d  vps-quench.sh\n' 0 > "$OUT"
    else
        cp "$ROOT/vps-quench.sh" "$OUT"
    fi
}
if self_update >/dev/null 2>&1; then
    echo "Updater reported success after checksum mismatch" >&2
    exit 1
fi
t_fitop_014() {
    grep -qx 'original' "$LOCAL_SCRIPT" || { echo "Updater replaced script after checksum mismatch" >&2; exit 1; }
    :
}
run_test "Updater replaced script after checksum mismatch" t_fitop_014

# Post-update tc reconciliation must execute the newly installed script, not a function from the old process.
TC_STATE_FILE="$TMP/update-tc.state"
LOCAL_SCRIPT="$TMP/newly-installed-vps-quench"
UPDATE_TC_MARKER="$TMP/update-tc.marker"
export UPDATE_TC_MARKER
printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$TC_STATE_FILE"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--bbr-reconcile-tc" ] || exit 1
[ "${QUENCH_TEST_MODE:-}" = 0 ] || exit 1
[ "${BBR_TUNE_TEST_MODE:-}" = 0 ] || exit 1
: > "$UPDATE_TC_MARKER"
EOF
chmod +x "$LOCAL_SCRIPT"
t_fitop_015() {
    self_reconcile_tc_after_update >/dev/null \
        || { echo "Updater could not invoke the new tc reconciliation endpoint" >&2; exit 1; }
    [ -f "$UPDATE_TC_MARKER" ] \
        || { echo "Updater reconciled tc through the old process" >&2; exit 1; }
    :
}
run_test "Updater could not invoke the new tc reconciliation endpoint …+1 项" t_fitop_015

# NFT firewall reconciliation must add the replacement before deleting the old
# route, and an add/remove failure must retain the ownership state for rollback.
t_fi_049() {
    NFT_TEST="$TMP/nft-firewall-transaction"
    mkdir -p "$NFT_TEST"
    NFT_FIREWALL_STATE="$NFT_TEST/firewall.db"
    ACTIVE_RULES="$NFT_TEST/active.db"
    OLD='ufw|ipv4|tcp|eth0|eth1|198.51.100.10|443|QUENCH_NFT_1_tcp'
    NEW='ufw|ipv4|tcp|eth0|eth1|198.51.100.20|8443|QUENCH_NFT_1_tcp'
    printf '%s\n' "$OLD" > "$NFT_FIREWALL_STATE"
    printf '%s\n' "$OLD" > "$ACTIVE_RULES"
    nft_firewall_backend() { echo ufw; }
    nft_firewall_specs() { printf '%s\n' "$NEW"; }
    nft_firewall_line_present() { grep -qxF "$1" "$ACTIVE_RULES"; }
    nft_firewall_add_line() {
        [ "${FAIL_ADD:-no}" != yes ] || return 1
        [ "${ADD_WITHOUT_EFFECT:-no}" != yes ] || return 0
        printf '%s\n' "$1" >> "$ACTIVE_RULES"
    }
    nft_firewall_remove_line() {
        [ "${FAIL_REMOVE:-no}" != yes ] || return 1
        grep -vxF "$1" "$ACTIVE_RULES" > "$ACTIVE_RULES.new" || true
        mv "$ACTIVE_RULES.new" "$ACTIVE_RULES"
    }

    FAIL_ADD=yes
    ! nft_firewall_reconcile >/dev/null 2>&1 \
        || { echo "NFT firewall transaction ignored an add failure" >&2; exit 1; }
    grep -qxF "$OLD" "$NFT_FIREWALL_STATE" \
        || { echo "NFT firewall add failure lost old ownership state" >&2; exit 1; }
    grep -qxF "$OLD" "$ACTIVE_RULES" \
        || { echo "NFT firewall add failure removed the working route" >&2; exit 1; }

    FAIL_ADD=no
    ADD_WITHOUT_EFFECT=yes
    ! nft_firewall_reconcile >/dev/null 2>&1 \
        || { echo "NFT firewall accepted an ineffective successful command" >&2; exit 1; }
    grep -qxF "$OLD" "$NFT_FIREWALL_STATE" \
        || { echo "NFT ineffective add lost old ownership state" >&2; exit 1; }

    ADD_WITHOUT_EFFECT=no
    FAIL_ADD=no
    nft_firewall_reconcile >/dev/null
    grep -qxF "$NEW" "$NFT_FIREWALL_STATE" \
        || { echo "NFT firewall replacement did not update ownership state" >&2; exit 1; }
    ! grep -qxF "$OLD" "$ACTIVE_RULES" \
        || { echo "NFT firewall replacement retained the stale route" >&2; exit 1; }

    : > "$NFT_TEST/empty-rules.db"
    nft_firewall_specs() { return 0; }
    FAIL_REMOVE=yes
    ! nft_firewall_reconcile >/dev/null 2>&1 \
        || { echo "NFT firewall transaction ignored a remove failure" >&2; exit 1; }
    grep -qxF "$NEW" "$NFT_FIREWALL_STATE" \
        || { echo "NFT firewall remove failure lost retry ownership state" >&2; exit 1; }
    :
}
run_test "NFT firewall reconciliation must add the replacement before deleting the old route, and an…" t_fi_049

# If a multi-rule firewall update fails after an earlier addition and that
# addition cannot be rolled back, it must remain owned so a later retry can remove it.
t_fi_050() {
    NFT_TEST="$TMP/nft-firewall-partial-add"
    mkdir -p "$NFT_TEST"
    NFT_FIREWALL_STATE="$NFT_TEST/firewall.db"
    ACTIVE_RULES="$NFT_TEST/active.db"
    OLD='ufw|ipv4|tcp|eth0|eth1|198.51.100.10|443|QUENCH_NFT_1_tcp'
    NEW1='ufw|ipv4|tcp|eth0|eth1|198.51.100.20|8443|QUENCH_NFT_1_tcp'
    NEW2='ufw|ipv4|udp|eth0|eth1|198.51.100.20|8443|QUENCH_NFT_1_udp'
    printf '%s\n' "$OLD" > "$NFT_FIREWALL_STATE"
    printf '%s\n' "$OLD" > "$ACTIVE_RULES"
    nft_firewall_backend() { echo ufw; }
    nft_firewall_specs() { printf '%s\n' "$NEW1" "$NEW2"; }
    nft_firewall_line_present() { grep -qxF "$1" "$ACTIVE_RULES"; }
    nft_firewall_add_line() {
        [ "$1" != "$NEW2" ] || return 1
        printf '%s\n' "$1" >> "$ACTIVE_RULES"
    }
    nft_firewall_remove_line() { return 1; }

    ! nft_firewall_reconcile >/dev/null 2>&1 \
        || { echo "NFT partial firewall add failure returned success" >&2; exit 1; }
    grep -qxF "$OLD" "$NFT_FIREWALL_STATE" \
        || { echo "NFT partial add lost old firewall ownership" >&2; exit 1; }
    grep -qxF "$NEW1" "$NFT_FIREWALL_STATE" \
        || { echo "NFT orphaned a partially added firewall rule" >&2; exit 1; }
    :
}
run_test "If a multi-rule firewall update fails after an earlier addition and that addition cannot be…" t_fi_050

# The rollback timer must outlive the login session: under systemd it has to run as a
# system-level transient unit, because nohup does not survive a logind session sweep.
t_fi_051() {
    TIMER_DIR="$TMP/safety-timer"
    mkdir -p "$TIMER_DIR"
    TIMER_SCRIPT="$TIMER_DIR/rollback.sh"
    RUN_LOG="$TIMER_DIR/systemd-run.log"
    RUN_CALLS=0
    printf '#!/bin/bash\nsleep 5\n' > "$TIMER_SCRIPT"
    chmod 700 "$TIMER_SCRIPT"

    # shellcheck disable=SC2329 # test stub overrides the sourced function
    systemd_available() { return 0; }
    # shellcheck disable=SC2329 # test stub stands in for the systemd-run binary
    systemd-run() { RUN_CALLS=$((RUN_CALLS + 1)); printf '%s\n' "$*" >> "$RUN_LOG"; return 0; }

    safety_launch_timer "$TIMER_SCRIPT" >/dev/null 2>&1 \
        || { echo "Timer launch failed while systemd was available" >&2; exit 1; }
    [ -n "$SAFETY_UNIT" ] \
        || { echo "Timer did not register a transient unit under systemd" >&2; exit 1; }
    [ -z "$SAFETY_PID" ] \
        || { echo "Timer kept a session-bound background PID under systemd" >&2; exit 1; }
    grep -q -- "--unit=$SAFETY_UNIT" "$RUN_LOG" \
        || { echo "systemd-run was not asked for the registered unit" >&2; exit 1; }

    # Older systemd rejects --collect; the launcher must retry without it, not fall back.
    RUN_CALLS=0
    : > "$RUN_LOG"
    # shellcheck disable=SC2329 # test stub stands in for the systemd-run binary
    systemd-run() {
        RUN_CALLS=$((RUN_CALLS + 1))
        printf '%s\n' "$*" >> "$RUN_LOG"
        case "$*" in *--collect*) return 1 ;; esac
        return 0
    }
    safety_launch_timer "$TIMER_SCRIPT" >/dev/null 2>&1 \
        || { echo "Timer launch failed when --collect was unsupported" >&2; exit 1; }
    [ "$RUN_CALLS" = 2 ] \
        || { echo "Launcher did not retry systemd-run without --collect: $RUN_CALLS" >&2; exit 1; }
    [ -n "$SAFETY_UNIT" ] \
        || { echo "Launcher gave up on systemd instead of retrying" >&2; exit 1; }

    # A unit-backed timer must be cancelled through systemctl rather than kill.
    SYSTEMCTL_LOG="$TIMER_DIR/systemctl.log"
    UNIT_ACTIVE=1
    # 必须有状态：cancel 现在会轮询 is-active 确认真的停住了。
    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() {
        printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
        case "${1:-}" in
            stop) UNIT_ACTIVE=0; return 0 ;;
            is-active) [ "$UNIT_ACTIVE" = 1 ] && return 0 || return 1 ;;
            show)
                # 停止确认会用 ActiveState 复核 is-active 的非零结果
                [ "$UNIT_ACTIVE" = 1 ] && printf 'ActiveState=active\n' \
                    || printf 'ActiveState=inactive\n'
                return 0
                ;;
        esac
        return 0
    }
    SAFETY_UNIT=quench-rollback-test
    SAFETY_PID=""
    SAFETY_SCRIPT="$TIMER_SCRIPT"
    cancel_safety_timer
    grep -qx 'stop quench-rollback-test' "$SYSTEMCTL_LOG" \
        || { echo "Unit-backed timer was not stopped through systemctl" >&2; exit 1; }
    [ ! -e "$TIMER_SCRIPT" ] \
        || { echo "Cancelled timer left its rollback script behind" >&2; exit 1; }
    [ -z "$SAFETY_UNIT" ] \
        || { echo "Cancelled timer kept a stale unit handle" >&2; exit 1; }

    # Without systemd there is no logind sweep to defend against, so nohup stays.
    printf '#!/bin/bash\nsleep 5\n' > "$TIMER_SCRIPT"
    chmod 700 "$TIMER_SCRIPT"
    # shellcheck disable=SC2329 # test stub overrides the sourced function
    systemd_available() { return 1; }
    safety_launch_timer "$TIMER_SCRIPT" >/dev/null 2>&1 \
        || { echo "Timer launch failed without systemd" >&2; exit 1; }
    [ -n "$SAFETY_PID" ] \
        || { echo "Non-systemd launch did not record a background PID" >&2; exit 1; }
    [ -z "$SAFETY_UNIT" ] \
        || { echo "Non-systemd launch invented a transient unit" >&2; exit 1; }
    kill "$SAFETY_PID" 2>/dev/null || true
    wait "$SAFETY_PID" 2>/dev/null || true
    :
}
run_test "The rollback timer must outlive the login session: under systemd it has to run as a…" t_fi_051

# Config changes must be mutually exclusive across sessions, and a failed arm must
# never leave the lock behind — a leaked lock would wedge every later change.
t_fi_052() {
    QUENCH_TXN_LOCK_FILE="$TMP/txn/quench-config.lock"
    mkdir -p "$TMP/txn"
    FLOCK_RC=0
    FLOCK_CALLS=0
    # shellcheck disable=SC2329 # test stub stands in for the flock binary
    flock() {
        case "${1:-}" in -u) return 0 ;; esac
        FLOCK_CALLS=$((FLOCK_CALLS + 1))
        return "$FLOCK_RC"
    }

    QUENCH_TXN_LOCK_HELD=0
    txn_lock_acquire || { echo "Lock acquire failed while the lock was free" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_HELD" = 1 ] || { echo "Acquired lock was not marked held" >&2; exit 1; }
    [ "$FLOCK_CALLS" = 1 ] || { echo "Acquire did not call flock exactly once" >&2; exit 1; }

    txn_lock_acquire || { echo "Re-entrant acquire failed in the same process" >&2; exit 1; }
    [ "$FLOCK_CALLS" = 1 ] || { echo "Re-entrant acquire tried to take the lock again" >&2; exit 1; }

    txn_lock_release
    [ "$QUENCH_TXN_LOCK_HELD" = 0 ] || { echo "Lock stayed held after release" >&2; exit 1; }

    FLOCK_RC=1
    ! txn_lock_acquire >/dev/null 2>&1 \
        || { echo "Acquire reported success while another session held the lock" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_HELD" = 0 ] || { echo "Busy lock left a stale held flag" >&2; exit 1; }

    # Arming must give the lock back when the rollback timer cannot be started.
    FLOCK_RC=0
    QUENCH_TXN_LOCK_HELD=0
    QUENCH_DATA_DIR="$TMP/txn/data"
    QUENCH_TXN_DIR="$TMP/txn/records"
    mkdir -p "$QUENCH_DATA_DIR"
    # shellcheck disable=SC2329 # test stub avoids touching real system state
    config_backup_create() { printf '%s\n' "$TMP/txn/snapshot.tar.gz"; }
    # shellcheck disable=SC2329 # test stub forces the launch failure path
    safety_launch_timer() { return 1; }
    : > "$TMP/txn/snapshot.tar.gz"
    safety_arm lock_release_probe >/dev/null 2>&1 \
        && { echo "safety_arm succeeded despite a failed timer launch" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_HELD" = 0 ] \
        || { echo "A failed safety_arm leaked the config transaction lock" >&2; exit 1; }
    :
}
run_test "Config changes must be mutually exclusive across sessions, and a failed arm must never leave…" t_fi_052

# A crashed session leaves no in-process trace, so the transaction record on disk is
# the only way the rollback centre can surface it afterwards.
t_fi_053() {
    QUENCH_TXN_DIR="$TMP/txn-records"
    QUENCH_TXN_FILE=""
    SAFETY_UNIT=quench-rollback-probe
    SAFETY_PID=4242
    TXN_SCRIPT="$TMP/txn-rollback.sh"
    printf '#!/bin/bash\n' > "$TXN_SCRIPT"

    txn_record_begin ssh_login "$TXN_SCRIPT"
    [ -n "$QUENCH_TXN_FILE" ] && [ -f "$QUENCH_TXN_FILE" ] \
        || { echo "Transaction record was not written" >&2; exit 1; }
    [ "$(txn_record_field "$QUENCH_TXN_FILE" LABEL)" = ssh_login ] \
        || { echo "Transaction record lost its label" >&2; exit 1; }
    [ "$(txn_record_field "$QUENCH_TXN_FILE" UNIT)" = quench-rollback-probe ] \
        || { echo "Transaction record lost the timer unit handle" >&2; exit 1; }
    [ "$(txn_record_field "$QUENCH_TXN_FILE" QUENCH_PID)" = "$$" ] \
        || { echo "Transaction record lost the owning pid" >&2; exit 1; }
    TXN_MODE=$(stat -c '%a' "$QUENCH_TXN_FILE" 2>/dev/null || stat -f '%Lp' "$QUENCH_TXN_FILE")
    [ "$TXN_MODE" = 600 ] \
        || { echo "Transaction record is world-readable: $TXN_MODE" >&2; exit 1; }

    [ "$(txn_record_state "$QUENCH_TXN_FILE")" = mine ] \
        || { echo "this process's own record was not reported as mine" >&2; exit 1; }
    TXN_RECORD="$QUENCH_TXN_FILE"

    # 属主进程已消失、回滚脚本还在 => armed。这正是最危险的一种遗留：
    # 放行新事务的话，那笔回滚到期会把新配置覆盖回它自己的旧快照。
    ( : ) & DEAD_PID=$!
    wait "$DEAD_PID" 2>/dev/null || true
    sed "s/^QUENCH_PID=.*/QUENCH_PID=$DEAD_PID/" "$TXN_RECORD" > "$TXN_RECORD.new"
    mv "$TXN_RECORD.new" "$TXN_RECORD"
    [ "$(txn_record_state "$TXN_RECORD")" = armed ] \
        || { echo "an orphaned record with a live rollback script was not reported as armed" >&2; exit 1; }
    txn_reconcile_stale >/dev/null 2>&1 \
        && { echo "reconcile started a new transaction while an armed rollback was pending" >&2; exit 1; }
    [ -f "$TXN_RECORD" ] \
        || { echo "reconcile deleted an armed record instead of blocking on it" >&2; exit 1; }

    # 回滚脚本已消失 => stale，只剩残骸，可以清掉并放行
    rm -f "$TXN_SCRIPT"
    [ "$(txn_record_state "$TXN_RECORD")" = stale ] \
        || { echo "A record whose rollback script is gone was not reported as stale" >&2; exit 1; }
    txn_reconcile_stale >/dev/null 2>&1 \
        || { echo "reconcile refused to proceed past a stale record" >&2; exit 1; }
    [ ! -e "$TXN_RECORD" ] \
        || { echo "reconcile left a stale record behind" >&2; exit 1; }

    QUENCH_TXN_FILE="$TXN_RECORD"
    txn_record_end
    [ -z "$QUENCH_TXN_FILE" ] || { echo "Completed transaction kept a stale record handle" >&2; exit 1; }
    :
}
run_test "A crashed session leaves no in-process trace, so the transaction record on disk is the only way…" t_fi_053

# sshd -T reparses the whole config and the dashboard asks for three keys per redraw.
# The cache must collapse those into one call, and must drop on any config rewrite.
t_fi_054() {
    # The stub logs to a file: real callers use $(...), so a counter variable
    # bumped inside a subshell would never be visible here.
    SSHD_LOG="$TMP/sshd-calls.log"
    : > "$SSHD_LOG"
    # shellcheck disable=SC2329 # test stub stands in for the sshd binary
    sshd() {
        echo call >> "$SSHD_LOG"
        printf 'port 22\npasswordauthentication no\npubkeyauthentication yes\n'
    }
    sshd_calls() { wc -l < "$SSHD_LOG" | tr -d '[:space:]'; }

    sshd_effective_reload
    [ "$(sshd_calls)" = 1 ] || { echo "Reload did not run sshd -T exactly once" >&2; exit 1; }
    [ "$(sshd_effective_value Port)" = 22 ] || { echo "Cached sshd lookup lost Port" >&2; exit 1; }
    [ "$(sshd_effective_value PasswordAuthentication)" = no ] \
        || { echo "Cached sshd lookup lost PasswordAuthentication" >&2; exit 1; }
    [ "$(sshd_effective_value PubkeyAuthentication)" = yes ] \
        || { echo "Cached sshd lookup lost PubkeyAuthentication" >&2; exit 1; }
    [ "$(sshd_calls)" = 1 ] \
        || { echo "Subshell lookups re-ran sshd -T $(sshd_calls) times; cache is not inherited" >&2; exit 1; }

    sshd_effective_reset
    [ "$(sshd_effective_value Port)" = 22 ] || { echo "Lookup broke after a reset" >&2; exit 1; }
    [ "$(sshd_calls)" = 2 ] \
        || { echo "Reset did not force a fresh sshd -T: $(sshd_calls)" >&2; exit 1; }

    # An unknown key must still fail rather than return a neighbouring value.
    ! sshd_effective_value NoSuchDirective >/dev/null 2>&1 \
        || { echo "Unknown directive returned a value" >&2; exit 1; }
    :
}
run_test "sshd -T reparses the whole config and the dashboard asks for three keys per redraw" t_fi_054

# Both subsystem locks use fixed descriptors: exec {VAR}> is a bash 4.1 feature and
# fails outright on the bash 3.2 the interpreter guard still admits. A failed acquire
# must also give the descriptor back instead of leaking it for the rest of the session.
t_fi_055() {
    LOCK_DIR="$TMP/fixed-fd-locks"
    mkdir -p "$LOCK_DIR"
    NFT_LOCK_FILE="$LOCK_DIR/nft.lock"
    BBR_CALIBRATION_LOCK_FILE="$LOCK_DIR/bbr.lock"
    FLOCK_RC=0
    # shellcheck disable=SC2329 # test stub stands in for the flock binary
    flock() { case "${1:-}" in -u) return 0 ;; esac; return "$FLOCK_RC"; }
    # shellcheck disable=SC2329 # test stub avoids touching real nft state
    nft_ensure_state_dir() { mkdir -p "$LOCK_DIR/nft-state"; }

    NFT_LOCK_HELD=0
    nft_lock_acquire || { echo "nft lock acquire failed on a free lock" >&2; exit 1; }
    [ "$NFT_LOCK_HELD" = 1 ] || { echo "nft lock was not marked held" >&2; exit 1; }
    { : >&8; } 2>/dev/null || { echo "nft lock did not open its descriptor" >&2; exit 1; }
    nft_lock_release
    [ "$NFT_LOCK_HELD" = 0 ] || { echo "nft lock stayed held after release" >&2; exit 1; }
    { : >&8; } 2>/dev/null && { echo "nft lock leaked its descriptor after release" >&2; exit 1; }

    FLOCK_RC=1
    ! nft_lock_acquire >/dev/null 2>&1 \
        || { echo "nft lock reported success while another task held it" >&2; exit 1; }
    { : >&8; } 2>/dev/null && { echo "a failed nft acquire leaked its descriptor" >&2; exit 1; }

    FLOCK_RC=0
    BBR_CAL_LOCK_HELD=0
    BBR_CAL_LOCK_MODE=""
    bbr_calibration_lock_acquire || { echo "bbr lock acquire failed on a free lock" >&2; exit 1; }
    [ "$BBR_CAL_LOCK_HELD" = 1 ] || { echo "bbr lock was not marked held" >&2; exit 1; }
    [ "$BBR_CAL_LOCK_MODE" = flock ] || { echo "bbr lock did not take the flock path" >&2; exit 1; }
    { : >&7; } 2>/dev/null || { echo "bbr lock did not open its descriptor" >&2; exit 1; }
    bbr_calibration_lock_release
    [ "$BBR_CAL_LOCK_HELD" = 0 ] || { echo "bbr lock stayed held after release" >&2; exit 1; }
    { : >&7; } 2>/dev/null && { echo "bbr lock leaked its descriptor after release" >&2; exit 1; }

    FLOCK_RC=1
    ! bbr_calibration_lock_acquire >/dev/null 2>&1 \
        || { echo "bbr lock reported success while another task held it" >&2; exit 1; }
    if { : >&7; } 2>/dev/null; then
        echo "a failed bbr acquire leaked its descriptor" >&2
        exit 1
    fi
    :
}
run_test "Both subsystem locks use fixed descriptors: exec {VAR}> is a bash 4.1 feature and fails…" t_fi_055

# Ctrl+C used to leave every mktemp file behind, including full copies of
# sshd_config. Registered temporaries must be swept on exit, and the sweep must
# refuse to touch anything outside a temp directory.
t_tmpreg_001() {
    quench_tmp_registry_init || fail "temp registry could not be initialised"
    REG_FILE=$(quench_mktemp) || fail "quench_mktemp failed"
    REG_DIR=$(quench_mktemp_d) || fail "quench_mktemp_d failed"
    [ -f "$REG_FILE" ] || fail "quench_mktemp did not create a file"
    [ -d "$REG_DIR" ] || fail "quench_mktemp_d did not create a directory"
    quench_tmp_cleanup
    [ ! -e "$REG_FILE" ] || fail "cleanup left a registered file behind"
    [ ! -e "$REG_DIR" ] || fail "cleanup left a registered directory behind"
    :
}
run_test "Registered temporaries are swept on exit" t_tmpreg_001

t_tmpreg_002() {
    # $TMP itself lives under TMPDIR, so an "outside" path has to come from
    # somewhere else entirely; the repository working directory always qualifies.
    GUARD_DIR="$ROOT/.quench-tmpguard-$$"
    mkdir -p "$GUARD_DIR" || fail "could not create the guard fixture"
    printf 'keep\n' > "$GUARD_DIR/must-survive"
    quench_tmp_registry_init || fail "temp registry could not be initialised"
    quench_tmp_register "$GUARD_DIR/must-survive"
    quench_tmp_register "/tmp/../etc/quench-traversal-probe"
    INSIDE=$(quench_mktemp) || fail "quench_mktemp failed"
    quench_tmp_cleanup
    SURVIVED=0
    [ -f "$GUARD_DIR/must-survive" ] && SURVIVED=1
    rm -rf "$GUARD_DIR"
    [ "$SURVIVED" = 1 ] || fail "cleanup deleted a path outside every temp directory"
    [ ! -e "$INSIDE" ] || fail "cleanup skipped a genuine temp file"
    :
}
run_test "Exit sweep never deletes outside a temp directory" t_tmpreg_002

t_tmpreg_003() {
    # Callers all write X=$(quench_mktemp ...), which runs in a subshell. A registry
    # kept in a variable would lose those entries; it has to live in a file.
    quench_tmp_registry_init || fail "temp registry could not be initialised"
    SUBSHELL_FILE=$( quench_mktemp ) || fail "quench_mktemp failed"
    grep -qxF "$SUBSHELL_FILE" "$QUENCH_TMP_REGISTRY" \
        || fail "a temp file created in a subshell was not registered for the parent"
    quench_tmp_cleanup
    [ ! -e "$SUBSHELL_FILE" ] || fail "cleanup missed the subshell-created file"
    :
}
run_test "Temporaries created inside a subshell are still registered" t_tmpreg_003

t_tmpreg_004() {
    # bbr and caddy take over INT for a while. Releasing it with `trap - INT` would
    # reset to the default action and silently drop the exit sweep.
    quench_install_signal_traps || fail "signal traps could not be installed"
    case "$(trap -p EXIT)" in
        *quench_tmp_cleanup*) ;;
        *) fail "EXIT handler was not installed" ;;
    esac
    trap 'echo module-handler' INT
    quench_restore_signal_traps
    case "$(trap -p INT)" in
        *quench_signal_cleanup*) ;;
        *) fail "restoring after a module handler did not bring back the global one" ;;
    esac
    quench_tmp_cleanup
    :
}
run_test "A module releasing INT restores the global handler, not the default" t_tmpreg_004

# Cancelling used to swallow a failed systemctl stop and delete the rollback script
# anyway, so the interface reported "cancelled" while the unit stayed armed and fired
# minutes later.
t_cancel_001() {
    CANCEL_DIR="$TMP/cancel-guard"
    mkdir -p "$CANCEL_DIR"
    SAFETY_SCRIPT="$CANCEL_DIR/rollback.sh"
    printf '#!/bin/bash\n' > "$SAFETY_SCRIPT"
    SAFETY_UNIT=quench-rollback-stuck
    SAFETY_PID=""
    QUENCH_TXN_REGISTRY=""
    # A unit that refuses to stop: stop reports success, is-active stays true.
    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() {
        case "${1:-}" in
            is-active) return 0 ;;
            show) printf 'ActiveState=active\n'; return 0 ;;
        esac
        return 0
    }

    cancel_safety_timer >/dev/null 2>&1 \
        && { echo "cancel reported success while the timer was still active" >&2; exit 1; }
    [ -f "$SAFETY_SCRIPT" ] \
        || { echo "a failed cancel deleted the rollback script anyway" >&2; exit 1; }
    [ -n "$SAFETY_UNIT" ] \
        || { echo "a failed cancel dropped the unit handle, losing the only way to stop it" >&2; exit 1; }
    :
}
run_test "A cancel that cannot stop the timer reports failure and keeps the rollback" t_cancel_001

# A failed backup used to still record the path and print "已备份", handing
# apply_and_restart a rollback point that does not exist.
t_restore_001() {
    BK_DIR="$TMP/backup-guard"
    mkdir -p "$BK_DIR/ro"
    SSHD_CONFIG="$BK_DIR/sshd_config"
    printf 'Port 22\n' > "$SSHD_CONFIG"
    LAST_SSHD_BACKUP="sentinel-must-be-cleared"
    chmod 500 "$BK_DIR/ro"
    SSHD_CONFIG="$BK_DIR/ro/sshd_config"
    printf 'Port 22\n' > "$BK_DIR/source"
    # 目标目录不可写 => cp 必然失败
    backup_config >/dev/null 2>&1 \
        && { chmod 700 "$BK_DIR/ro"; echo "backup_config reported success while cp failed" >&2; exit 1; }
    chmod 700 "$BK_DIR/ro"
    [ -z "$LAST_SSHD_BACKUP" ] \
        || { echo "a failed backup left a bogus rollback point behind: $LAST_SSHD_BACKUP" >&2; exit 1; }
    :
}
run_test "A failed SSH backup reports failure and records no rollback point" t_restore_001

# apply_and_restart must tell the caller whether the config was actually put back:
# cancelling the safety timer is only safe when it was.
t_restore_002() {
    AR_DIR="$TMP/apply-restart"
    mkdir -p "$AR_DIR"
    SSHD_CONFIG="$AR_DIR/sshd_config"
    LAST_SSHD_BACKUP="$AR_DIR/sshd_config.bak"
    printf 'Port 2222\n' > "$SSHD_CONFIG"
    printf 'Port 22\n' > "$LAST_SSHD_BACKUP"

    # sshd -t 按“配置文件当前内容”判定，而不是靠标志位：它在 restart_ssh
    # 之前求值，用标志位会永远拿到旧值。
    # shellcheck disable=SC2329 # test stub stands in for the sshd binary
    sshd() {
        [ "$SSHD_ACCEPTS_BACKUP" = 1 ] || return 1
        grep -qx 'Port 22' "$SSHD_CONFIG" 2>/dev/null
    }
    # shellcheck disable=SC2329 # test stub stands in for restart_ssh
    restart_ssh() { return 0; }

    # 新配置语法不过，但回滚后的验证通过 => 1（已恢复，可以取消计时器）
    SSHD_ACCEPTS_BACKUP=1
    # 必须写成 `|| RC=$?`：非零返回在 set -e 下会直接中止用例。
    RC=0
    apply_and_restart >/dev/null 2>&1 || RC=$?
    [ "$RC" = 1 ] \
        || { echo "a failure with a verified rollback should return 1, got $RC" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG" \
        || { echo "the verified rollback did not restore the backup" >&2; exit 1; }

    # 回滚后的验证也失败 => 2（恢复未确认，必须保留计时器）
    printf 'Port 2222\n' > "$SSHD_CONFIG"
    SSHD_ACCEPTS_BACKUP=0
    # 必须写成 `|| RC=$?`：非零返回在 set -e 下会直接中止用例。
    RC=0
    apply_and_restart >/dev/null 2>&1 || RC=$?
    [ "$RC" = 2 ] \
        || { echo "an unverified rollback should return 2, got $RC" >&2; exit 1; }
    :
}
run_test "apply_and_restart distinguishes a verified rollback from an unverified one" t_restore_002

# The unverified branch must leave the timer, the snapshot and the record alone.
t_restore_003() {
    REL_DIR="$TMP/release-guard"
    mkdir -p "$REL_DIR"
    SAFETY_SCRIPT="$REL_DIR/rollback.sh"
    printf '#!/bin/bash\n' > "$SAFETY_SCRIPT"
    SAFETY_UNIT=""
    SAFETY_PID=""
    QUENCH_TXN_REGISTRY=""
    safety_release_after_failure unverified >/dev/null 2>&1 \
        || { echo "the unverified branch reported failure" >&2; exit 1; }
    [ -f "$SAFETY_SCRIPT" ] \
        || { echo "an unverified restore cancelled the safety net anyway" >&2; exit 1; }
    [ -n "$SAFETY_SCRIPT" ] \
        || { echo "an unverified restore dropped the rollback handle" >&2; exit 1; }
    :
}
run_test "An unverified restore keeps the rollback timer armed" t_restore_003

# ssh_restore_last_backup swallowed the restart result with || true, so callers
# treated a service that never came back as a successful restore and cancelled
# the safety net on the strength of it.
t_restore_004() {
    RB_DIR="$TMP/restore-verify"
    mkdir -p "$RB_DIR"
    SSHD_CONFIG="$RB_DIR/sshd_config"
    LAST_SSHD_BACKUP="$RB_DIR/sshd_config.bak"
    printf 'Port 2222\n' > "$SSHD_CONFIG"
    printf 'Port 22\n' > "$LAST_SSHD_BACKUP"
    # shellcheck disable=SC2329 # test stub stands in for the sshd binary
    sshd() { return 0; }
    # shellcheck disable=SC2329 # test stub stands in for restart_ssh
    restart_ssh() { return 1; }
    ssh_restore_last_backup >/dev/null 2>&1 \
        && { echo "restore reported success while the service failed to restart" >&2; exit 1; }

    # 语法检查不过时同样必须失败，而不是写完就算数
    # shellcheck disable=SC2329 # test stub stands in for the sshd binary
    sshd() { return 1; }
    # shellcheck disable=SC2329 # test stub stands in for restart_ssh
    restart_ssh() { return 0; }
    ssh_restore_last_backup >/dev/null 2>&1 \
        && { echo "restore reported success while sshd -t rejected the config" >&2; exit 1; }

    # 都正常时必须成功
    # shellcheck disable=SC2329 # test stub stands in for the sshd binary
    sshd() { return 0; }
    ssh_restore_last_backup >/dev/null 2>&1 \
        || { echo "restore failed even though the config and service were fine" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG" \
        || { echo "restore did not put the backup back" >&2; exit 1; }
    :
}
run_test "Restoring the SSH backup only succeeds when the service verifies" t_restore_004

# The archive check only looked at member paths, and the post-extraction pass only
# inspected symlinks. A device node or FIFO on an allowlisted path went straight into
# /etc through cp -a.
t_archive_001() {
    ARC_DIR="$TMP/archive-special"
    mkdir -p "$ARC_DIR/src/etc" "$ARC_DIR/dest"
    printf 'quench-test\n' > "$ARC_DIR/src/etc/hostname"
    mkfifo "$ARC_DIR/src/etc/hosts" 2>/dev/null \
        || { echo "SKIP: mkfifo unavailable" >&2; exit 0; }
    ( cd "$ARC_DIR/src" && tar -czf "$ARC_DIR/special.tar.gz" etc/hostname etc/hosts ) \
        || { echo "could not build the fixture archive" >&2; exit 1; }

    CONFIG_RESTORE_ROOT="$ARC_DIR/dest"
    config_archive_extract "$ARC_DIR/special.tar.gz" >/dev/null 2>&1 \
        && { echo "extraction accepted an archive containing a FIFO" >&2; exit 1; }
    [ ! -e "$ARC_DIR/dest/etc/hostname" ] \
        || { echo "a rejected archive still copied files into the restore root" >&2; exit 1; }

    # 同一批文件去掉 FIFO 之后必须能正常恢复，证明拒绝的是类型而不是路径
    rm -f "$ARC_DIR/src/etc/hosts"
    ( cd "$ARC_DIR/src" && tar -czf "$ARC_DIR/plain.tar.gz" etc/hostname )
    config_archive_extract "$ARC_DIR/plain.tar.gz" >/dev/null 2>&1 \
        || { echo "extraction rejected an archive of plain files" >&2; exit 1; }
    [ -f "$ARC_DIR/dest/etc/hostname" ] \
        || { echo "a valid archive was not restored" >&2; exit 1; }
    :
}
run_test "Archive restore rejects device nodes, FIFOs and sockets" t_archive_001

# A service that is running now but will not come back after a reboot must not be
# reported as a successful install.
t_svc_001() {
    # shellcheck disable=SC2329 # test stub overrides the sourced function
    systemd_available() { return 0; }
    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() { case "${1:-}" in enable) return 1 ;; esac; return 0; }
    svc_enable somesvc >/dev/null 2>&1 \
        && { echo "svc_enable reported success while systemctl enable failed" >&2; exit 1; }

    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() { return 0; }
    svc_enable somesvc >/dev/null 2>&1 \
        || { echo "svc_enable reported failure while systemctl enable succeeded" >&2; exit 1; }
    :
}
run_test "svc_enable reports a failed boot-time enable" t_svc_001

# safety_rollback_now used to delete the record, release the lock and remove the
# script before running it, and removed the script even when the rollback failed —
# while safety_rollback_after_failure told the operator the record had been kept.
t_rbnow_001() {
    RB_DIR="$TMP/rollback-now"
    mkdir -p "$RB_DIR"
    QUENCH_TXN_DIR="$RB_DIR/txn"
    QUENCH_TXN_LOCK_FILE="$RB_DIR/lock"
    QUENCH_TXN_LOCK_HELD=0
    QUENCH_TXN_LOCK_MODE=""
    SAFETY_SCRIPT="$RB_DIR/rollback.sh"
    printf '#!/bin/bash\nexit 3\n' > "$SAFETY_SCRIPT"
    chmod 700 "$SAFETY_SCRIPT"
    SAFETY_UNIT=""; SAFETY_PID=""
    # shellcheck disable=SC2329 # test stub: the timer stops cleanly, the rollback does not
    safety_stop_timer_process() { return 0; }
    txn_lock_acquire || { echo "could not take the lock for the fixture" >&2; exit 1; }
    txn_record_begin rollback_probe "$SAFETY_SCRIPT" \
        || { echo "could not write the fixture transaction record" >&2; exit 1; }
    REC="$QUENCH_TXN_FILE"

    safety_rollback_now >/dev/null 2>&1 \
        && { echo "rollback reported success while the script exited non-zero" >&2; exit 1; }
    [ -f "$SAFETY_SCRIPT" ] \
        || { echo "a failed rollback deleted the rollback script" >&2; exit 1; }
    [ -f "$REC" ] \
        || { echo "a failed rollback deleted the transaction record" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_HELD" = 1 ] \
        || { echo "a failed rollback released the lock" >&2; exit 1; }
    [ -n "$SAFETY_SCRIPT" ] \
        || { echo "a failed rollback cleared the rollback handle" >&2; exit 1; }

    # 停不掉计时器时必须拒绝执行：否则手动这次和它自己的倒计时会各回滚一次
    RAN_MARKER="$RB_DIR/ran"
    printf '#!/bin/bash\ntouch %s\nexit 0\n' "$RAN_MARKER" > "$SAFETY_SCRIPT"
    chmod 700 "$SAFETY_SCRIPT"
    # shellcheck disable=SC2329 # test stub: the timer refuses to stop
    safety_stop_timer_process() { return 1; }
    safety_rollback_now >/dev/null 2>&1 \
        && { echo "rollback reported success while the timer could not be stopped" >&2; exit 1; }
    [ ! -e "$RAN_MARKER" ] \
        || { echo "the rollback ran even though its timer could not be stopped" >&2; exit 1; }
    [ -f "$SAFETY_SCRIPT" ] \
        || { echo "refusing to roll back still deleted the script" >&2; exit 1; }
    :
}
run_test "A failed immediate rollback keeps the script, the record and the lock" t_rbnow_001

# Stopping must not read "state unavailable" as "stopped".
t_stop_001() {
    SAFETY_UNIT=quench-rollback-unknown
    SAFETY_PID=""
    # 总线不可用：is-active 非零，ActiveState 也查不到
    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() { return 1; }
    safety_stop_timer_process >/dev/null 2>&1 \
        && { echo "an unreadable unit state was treated as stopped" >&2; exit 1; }

    # 明确 inactive 才算停住
    # shellcheck disable=SC2329 # test stub stands in for the systemctl binary
    systemctl() {
        case "${1:-}" in
            is-active) return 1 ;;
            show) printf 'ActiveState=inactive\n'; return 0 ;;
        esac
        return 0
    }
    safety_stop_timer_process >/dev/null 2>&1 \
        || { echo "a confirmed inactive unit was not accepted as stopped" >&2; exit 1; }
    :
}
run_test "Stopping tells a confirmed inactive unit from an unreadable one" t_stop_001

# Without flock the lock must fall back to an atomic mkdir, not wave the change through.
t_lock_001() {
    LK_DIR="$TMP/mkdir-lock"
    mkdir -p "$LK_DIR"
    QUENCH_TXN_LOCK_FILE="$LK_DIR/lock"
    QUENCH_TXN_LOCK_HELD=0
    QUENCH_TXN_LOCK_MODE=""
    txn_lock_mkdir_acquire || { echo "mkdir lock could not be taken" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_MODE" = mkdir ] \
        || { echo "mkdir lock did not record its mode" >&2; exit 1; }
    [ -d "$LK_DIR/lock.d" ] || { echo "mkdir lock left no lock directory" >&2; exit 1; }

    # 另一个活着的进程持有 -> 必须拒绝
    QUENCH_TXN_LOCK_HELD=0
    printf '%s\n' "$$" > "$LK_DIR/lock.d/pid"
    txn_lock_mkdir_acquire >/dev/null 2>&1 \
        && { echo "mkdir lock was handed out twice" >&2; exit 1; }

    # 持有者已消失 -> 陈旧锁应被清理并重新取得
    ( : ) & GONE=$!
    wait "$GONE" 2>/dev/null || true
    printf '%s\n' "$GONE" > "$LK_DIR/lock.d/pid"
    QUENCH_TXN_LOCK_HELD=0
    txn_lock_mkdir_acquire >/dev/null 2>&1 \
        || { echo "a stale mkdir lock was not reclaimed" >&2; exit 1; }
    txn_lock_release
    [ ! -d "$LK_DIR/lock.d" ] || { echo "release left the lock directory behind" >&2; exit 1; }
    :
}
run_test "Without flock the transaction lock falls back to an atomic mkdir" t_lock_001

# A transaction that cannot be recorded cannot be reconciled later, so it must fail.
t_rec_001() {
    REC_DIR="$TMP/record-fail"
    mkdir -p "$REC_DIR"
    chmod 500 "$REC_DIR"
    QUENCH_TXN_DIR="$REC_DIR/nested/transactions"
    QUENCH_TXN_FILE=""
    RC=0
    txn_record_begin probe /nonexistent >/dev/null 2>&1 || RC=$?
    chmod 700 "$REC_DIR"
    [ "$RC" -ne 0 ] \
        || { echo "an unwritable transaction directory was reported as recorded" >&2; exit 1; }

    # 目录建得出、但记录文件写不进去，是另一条分支。txn_record_begin 会
    # chmod 700 把目录权限改回来，所以要挡住 chmod 才能停在不可写状态。
    WR_DIR="$TMP/record-write-fail"
    mkdir -p "$WR_DIR"
    QUENCH_TXN_DIR="$WR_DIR"
    QUENCH_TXN_FILE=""
    chmod 500 "$WR_DIR"
    # shellcheck disable=SC2329 # test stub keeps the fixture directory read-only
    chmod() { return 0; }
    RC=0
    txn_record_begin probe /nonexistent >/dev/null 2>&1 || RC=$?
    unset -f chmod
    command chmod 700 "$WR_DIR"
    [ "$RC" -ne 0 ] \
        || { echo "an unwritable record file was reported as recorded" >&2; exit 1; }
    [ -z "$QUENCH_TXN_FILE" ] \
        || { echo "a failed record left a dangling record handle" >&2; exit 1; }
    :
}
run_test "A transaction that cannot be recorded is refused" t_rec_001

# And the caller must act on that: arming has to fail and take the timer down with it.
t_rec_002() {
    RC2_DIR="$TMP/record-arm"
    mkdir -p "$RC2_DIR/root/etc" "$RC2_DIR/data"
    QUENCH_DATA_DIR="$RC2_DIR/data"
    QUENCH_BACKUP_DIR="$RC2_DIR/data/backups"
    QUENCH_TXN_LOCK_FILE="$RC2_DIR/lock"
    QUENCH_TXN_LOCK_HELD=0
    CONFIG_RESTORE_ROOT="$RC2_DIR/root"
    printf 'x\n' > "$RC2_DIR/root/etc/hostname"
    tar -czf "$RC2_DIR/snap.tar.gz" -C "$RC2_DIR/root" etc/hostname
    # shellcheck disable=SC2329 # test stub avoids touching real system state
    config_backup_create() { printf '%s\n' "$RC2_DIR/snap.tar.gz"; }
    # shellcheck disable=SC2329 # test stub overrides the sourced function
    svc_is_active() { return 1; }
    # shellcheck disable=SC2329 # test stub records the script instead of launching it
    safety_launch_timer() { SAFETY_UNIT=""; SAFETY_PID=""; SAFETY_SCRIPT="$1"; return 0; }
    # shellcheck disable=SC2329 # test stub forces the record-failure path
    txn_record_begin() { return 1; }
    STOPPED=0
    # shellcheck disable=SC2329 # test stub observes the cleanup
    safety_stop_timer_process() { STOPPED=1; return 0; }

    safety_arm recprobe >/dev/null 2>&1 \
        && { echo "arming succeeded even though the transaction could not be recorded" >&2; exit 1; }
    [ "$STOPPED" = 1 ] \
        || { echo "a failed record left the rollback timer running" >&2; exit 1; }
    [ -z "$SAFETY_SCRIPT" ] \
        || { echo "a failed record left a rollback handle behind" >&2; exit 1; }
    [ "$QUENCH_TXN_LOCK_HELD" = 0 ] \
        || { echo "a failed record leaked the transaction lock" >&2; exit 1; }
    :
}
run_test "Arming fails and stands down when the transaction cannot be recorded" t_rec_002

# The generated rollback script must aggregate its steps instead of always exiting 0.
t_genrb_001() {
    GEN_DIR="$TMP/gen-rollback"
    mkdir -p "$GEN_DIR/root/etc" "$GEN_DIR/data"
    QUENCH_DATA_DIR="$GEN_DIR/data"
    QUENCH_BACKUP_DIR="$GEN_DIR/data/backups"
    QUENCH_TXN_DIR="$GEN_DIR/txn"
    QUENCH_TXN_LOCK_FILE="$GEN_DIR/lock"
    QUENCH_TXN_LOCK_HELD=0
    CONFIG_RESTORE_ROOT="$GEN_DIR/root"
    printf 'x\n' > "$GEN_DIR/root/etc/hostname"
    tar -czf "$GEN_DIR/snap.tar.gz" -C "$GEN_DIR/root" etc/hostname
    # shellcheck disable=SC2329 # test stub avoids touching real system state
    config_backup_create() { printf '%s\n' "$GEN_DIR/snap.tar.gz"; }
    # shellcheck disable=SC2329 # test stub overrides the sourced function
    svc_is_active() { return 1; }
    # shellcheck disable=SC2329 # test stub records the script instead of launching it
    safety_launch_timer() { SAFETY_UNIT=""; SAFETY_PID=""; SAFETY_SCRIPT="$1"; return 0; }
    safety_arm genprobe >/dev/null 2>&1 \
        || { echo "could not arm the fixture transaction" >&2; exit 1; }
    bash -n "$SAFETY_SCRIPT" \
        || { echo "the generated rollback script does not parse" >&2; exit 1; }
    grep -q '^RC=0$' "$SAFETY_SCRIPT" \
        || { echo "the generated script does not track a result code" >&2; exit 1; }
    grep -q 'exit "\$RC"' "$SAFETY_SCRIPT" \
        || { echo "the generated script does not exit with its result code" >&2; exit 1; }
    grep -q 'sysctl --system >/dev/null 2>&1 || RC=1' "$SAFETY_SCRIPT" \
        || { echo "the generated script still swallows a failed sysctl reload" >&2; exit 1; }
    :
}
run_test "The generated rollback script reports a failed step instead of exiting 0" t_genrb_001

# Restoring a snapshot must reproduce it exactly, not merge into what is there now.
t_exact_001() {
    EX_DIR="$TMP/exact-restore"
    mkdir -p "$EX_DIR/src/etc/fail2ban" "$EX_DIR/dest"
    printf 'original\n' > "$EX_DIR/src/etc/fail2ban/jail.local"
    ( cd "$EX_DIR/src" && tar -czf "$EX_DIR/snap.tar.gz" etc/fail2ban )
    mkdir -p "$EX_DIR/dest/etc/fail2ban"
    printf 'original\n' > "$EX_DIR/dest/etc/fail2ban/jail.local"
    printf 'added-after-the-snapshot\n' > "$EX_DIR/dest/etc/fail2ban/extra.local"

    CONFIG_RESTORE_ROOT="$EX_DIR/dest"
    config_archive_extract "$EX_DIR/snap.tar.gz" >/dev/null 2>&1 \
        || { echo "restoring a valid snapshot failed" >&2; exit 1; }
    [ -f "$EX_DIR/dest/etc/fail2ban/jail.local" ] \
        || { echo "the snapshot's own file was not restored" >&2; exit 1; }
    [ ! -e "$EX_DIR/dest/etc/fail2ban/extra.local" ] \
        || { echo "a file created after the snapshot survived the restore" >&2; exit 1; }
    :
}
run_test "Snapshot restore reproduces the directory exactly" t_exact_001

test_summary "Fault injection"
