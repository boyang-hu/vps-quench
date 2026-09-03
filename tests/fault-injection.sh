#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/vps-quench.sh"

confirm_change_preview "test" "reject" <<< "n" >/dev/null 2>&1 && { echo "Preview accepted rejection" >&2; exit 1; }
confirm_change_preview "test" "accept" <<< "y" >/dev/null 2>&1 || { echo "Preview rejected confirmation" >&2; exit 1; }

# A pending network transaction must roll back before another starts. Newly created
# DNS drop-ins must also disappear during immediate rollback.
(
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
)

(
    ROLLBACK_MARK="$TMP/dns-immediate-rollback"
    safety_rollback_now() { : > "$ROLLBACK_MARK"; }
    dns_fail_and_rollback 'injected DNS failure' NetworkManager >/dev/null 2>&1 || true
    [ -f "$ROLLBACK_MARK" ] || { echo "DNS failure did not request immediate rollback" >&2; exit 1; }
)

(
    sleep 600 &
    STALE_PID=$!
    trap 'kill "$STALE_PID" 2>/dev/null || true; wait "$STALE_PID" 2>/dev/null || true' EXIT
    SAFETY_PID="$STALE_PID"
    SAFETY_SCRIPT="$TMP/already-finished-rollback.sh"
    ! safety_confirm >/dev/null 2>&1 || { echo "A finished safety timer was treated as active" >&2; exit 1; }
    kill -0 "$STALE_PID" 2>/dev/null || { echo "Safety confirmation killed an unrelated reused PID" >&2; exit 1; }
)

docker() { [ "$1" = "inspect" ] && printf '<no value>\n'; }
[ -z "$(docker_inspect_label fake-id com.docker.compose.project)" ] || {
    echo "Missing Compose label was treated as a real value" >&2
    exit 1
}

docker_compose_url_valid 'https://example.com/path/app.yml?token=1' \
    || { echo "Valid HTTPS Compose URL was rejected" >&2; exit 1; }
! docker_compose_url_valid 'http://example.com/app.yml' \
    || { echo "Insecure Compose URL was accepted" >&2; exit 1; }
! docker_compose_url_valid 'https://user:secret@example.com/app.yml' \
    || { echo "Credential-bearing Compose URL was accepted" >&2; exit 1; }

# A broken sshd validation must restore the previous configuration.
SSHD_CONFIG="$TMP/sshd_config"
LAST_SSHD_BACKUP="$TMP/sshd_config.bak"
printf 'Port 2222\n' > "$SSHD_CONFIG"
printf 'Port 22\n' > "$LAST_SSHD_BACKUP"
sshd() { return 1; }
restart_ssh() { return 0; }
apply_and_restart >/dev/null 2>&1 && { echo "Expected SSH validation failure" >&2; exit 1; }
grep -qx 'Port 22' "$SSHD_CONFIG" || { echo "SSH rollback did not restore backup" >&2; exit 1; }

# A tar failure must not leave a partial backup archive.
QUENCH_DATA_DIR="$TMP/data"
QUENCH_BACKUP_DIR="$QUENCH_DATA_DIR/backups"
export QUENCH_AUDIT_LOG="$TMP/audit.log"
# shellcheck disable=SC2329 # test stub overrides the sourced function for config_backup_create
config_backup_paths() { printf 'tmp/does-not-exist-quench-test\n'; }
config_backup_create injected_failure true >/dev/null 2>&1 && { echo "Expected backup failure" >&2; exit 1; }
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
[ "$COUNT" -eq 2 ] || { echo "Backup retention kept $COUNT archives instead of 2" >&2; exit 1; }

# Export/import helpers must validate paths and write archives to a caller-specified destination.
EXPORT_PATH="$TMP/exported-config.tar.gz"
config_export_archive "$EXPORT_PATH" test >/dev/null || { echo "Export helper failed" >&2; exit 1; }
[ -f "$EXPORT_PATH" ] || { echo "Export helper did not create archive" >&2; exit 1; }
config_import_archive() { [ "$1" = "$EXPORT_PATH" ]; }
config_import_archive "$EXPORT_PATH" >/dev/null || { echo "Import helper failed" >&2; exit 1; }

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
config_archive_validate "$TMP/valid-config.tar.gz" >/dev/null \
    || { echo "Config import rejected an allowlisted path" >&2; exit 1; }
(
    export CONFIG_RESTORE_ROOT="$TMP/restored-root"
    config_archive_extract "$TMP/valid-config.tar.gz" >/dev/null
    grep -qx valid "$CONFIG_RESTORE_ROOT/etc/caddy/Caddyfile" \
        || { echo "Allowlisted config archive was not restored" >&2; exit 1; }
)

# A partially applied first-run network baseline must restore its file and runtime sysctl values.
(
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
)

# Firewall installation must never enable UFW when the rate-limited SSH rule failed.
(
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
)

# UFW's own netfilter rules must not be mistaken for a separate raw-iptables backend.
(
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
)

# A successful UFW command without an effective rule must still abort SSH migration.
(
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
)

# A pre-existing broad ALLOW must not silently bypass the newly added SSH LIMIT rule.
(
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
)

# A broad UFW deny/reject must not be mistaken for a usable SSH allowance.
(
    ufw() { printf 'Status: active\n2222/tcp LIMIT IN Anywhere\n2222/tcp DENY IN Anywhere\n'; }
    svc_is_active() { return 1; }
    ! firewall_port_ready 2222 \
        || { echo "UFW broad DENY was ignored during SSH readiness validation" >&2; exit 1; }
)

# firewalld SSH rules must target the zone bound to the active interface, not blindly use default.
(
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
)

# UFW installation must set explicit defaults, limit SSH, and keep web ports closed by default.
(
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
)

# A first firewalld start must write the permanent SSH rule while the daemon is still offline.
(
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
)

# Port/IP input helpers must reject malformed or out-of-range values and support IPv6 CIDR.
[ "$(fw_port_spec_normalize 3000:3010/tcp ufw)" = 3000:3010/tcp ] \
    || { echo "UFW port range normalization failed" >&2; exit 1; }
[ "$(fw_port_spec_normalize 3000:3010/tcp firewalld)" = 3000-3010/tcp ] \
    || { echo "firewalld port range normalization failed" >&2; exit 1; }
! fw_port_spec_normalize 70000/tcp ufw >/dev/null 2>&1 \
    || { echo "Out-of-range firewall port was accepted" >&2; exit 1; }
[ "$(fw_ip_family 2001:db8::/64)" = ipv6 ] || { echo "IPv6 CIDR validation failed" >&2; exit 1; }
! fw_ip_family 999.2.3.4 >/dev/null 2>&1 || { echo "Invalid IPv4 address was accepted" >&2; exit 1; }

# UFW verification must handle both compact, directional, and IPv6 status layouts.
(
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
)

# Trusted-source SSH rules must cover both ports during a staged SSH migration.
(
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
)
(
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
)

# Atomic replacement must leave the destination untouched when staging fails.
(
    SOURCE="$TMP/update-source"
    DEST="$TMP/update-dest"
    printf 'new\n' > "$SOURCE"
    printf 'old\n' > "$DEST"
    install() { return 1; }
    ! self_atomic_replace "$SOURCE" "$DEST" || { echo "Atomic update ignored install failure" >&2; exit 1; }
    grep -qx old "$DEST" || { echo "Atomic update damaged the current script" >&2; exit 1; }
)

# Caddy startup failure must propagate instead of reporting success.
(
    CADDYFILE="$TMP/Caddyfile"
    : > "$CADDYFILE"
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    svc_start() { return 1; }
    caddy() { [ "$1" = validate ]; }
    ! caddy_reload_config >/dev/null 2>&1 || { echo "Caddy reload hid a startup failure" >&2; exit 1; }
)

# Caddy layout adoption must restore the exact root config if active reload fails.
(
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
)

# A failed managed-site apply must remove the staged site and reload the old config.
(
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
)

# Failed site deletion must restore both contents and permissions.
(
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
)

# Quench Fail2ban changes are scoped to sshd and must not rewrite global defaults.
(
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
)

# The managed Fail2ban drop-in must use real numeric ports and escalating bans.
(
    F2B_RENDER="$TMP/zz-vps-quench.local"
    f2b_render_managed_config "$F2B_RENDER" systemd 22,2222 'allowipv6 = auto'
    grep -Eq '^port[[:space:]]*=[[:space:]]*22,2222$' "$F2B_RENDER" \
        || { echo "Fail2ban managed config missed SSH migration ports" >&2; exit 1; }
    grep -Eq '^mode[[:space:]]*=[[:space:]]*aggressive$' "$F2B_RENDER" \
        || { echo "Fail2ban aggressive mode is missing" >&2; exit 1; }
    grep -Eq '^bantime\.increment[[:space:]]*=[[:space:]]*true$' "$F2B_RENDER" \
        || { echo "Fail2ban escalating bans are missing" >&2; exit 1; }
)

# Invalid Fail2ban edits must restore the previous managed drop-in.
(
    export F2B_JAIL_LOCAL="$TMP/fail2ban-rollback.local"
    printf '[sshd]\nenabled = true\nport = 22\n' > "$F2B_JAIL_LOCAL"
    fail2ban-client() { return 1; }
    ! f2b_set_param_jail port 2222 >/dev/null 2>&1 \
        || { echo "Invalid Fail2ban change was accepted" >&2; exit 1; }
    grep -Eq '^port[[:space:]]*=[[:space:]]*22$' "$F2B_JAIL_LOCAL" \
        || { echo "Fail2ban validation failure did not restore the original file" >&2; exit 1; }
)

# Updating SSH while Fail2ban is intentionally stopped must update its file without starting it.
(
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
)

# A running sshd jail health failure must restore the previous Fail2ban port configuration.
(
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
)

# Firewall cleanup must not report success while a broad UFW SSH rule remains effective.
(
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    ufw() {
        [ "$1" = status ] && printf 'Status: active\n2222/tcp LIMIT IN Anywhere\n'
        return 0
    }
    ! ssh_firewall_close_port 2222 >/dev/null 2>&1 \
        || { echo "UFW cleanup accepted a rule that remained effective" >&2; exit 1; }
)

# A runtime restart failure after parameter edits must restore the whole previous file.
(
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
)


# Swap deletion must stop before touching fstab/files when swapoff fails.
(
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
)

# An existing foreign file at the managed default path must be rejected before swapoff.
(
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
)

# A Docker restart failure must restore the exact previous daemon.json.
(
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
)

# NTP repair must report a timedatectl failure.
(
    print_header() { :; }
    info() { :; }
    error() { :; }
    ts_backend_detect() { echo timesyncd; }
    timedatectl() { return 1; }
    ! ts_ntp_repair >/dev/null 2>&1 || { echo "NTP repair hid timedatectl failure" >&2; exit 1; }
)

# Timezone changes must validate the write instead of reporting false success.
(
    error() { :; }
    ts_timezone_valid() { return 0; }
    systemd_available() { return 0; }
    timedatectl() { return 1; }
    ! ts_set_timezone UTC >/dev/null 2>&1 || { echo "Timezone update hid timedatectl failure" >&2; exit 1; }
)

# An external NTP daemon must be reported, not silently replaced by Quench.
(
    print_header() { :; }
    warn() { :; }
    ts_backend_detect() { echo external:ntpd; }
    ts_ntp_synchronized() { return 1; }
    ! ts_ntp_repair >/dev/null 2>&1 || { echo "Unsynchronized external NTP was reported as repaired" >&2; exit 1; }
)

# Resolving an external/managed conflict keeps the external daemon and stops only managed backends.
(
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
)

# Multi-IP source switching must arm an exact route rollback and restore on verification failure.
(
    QUENCH_DATA_DIR="$TMP/ip-source-safety"
    mkdir -p "$QUENCH_DATA_DIR"
    audit_action() { :; }
    warn() { :; }
    nohup() { return 0; }
    ip_source_safety_arm 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' >/dev/null
    grep -Fq 'ip -4 route replace default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' "$SAFETY_SCRIPT" \
        || { echo "Multi-IP safety timer did not preserve the original route" >&2; exit 1; }
    cancel_safety_timer
)
(
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
)

# If direct route restoration fails, the independent rollback script must remain the fallback.
(
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
)

# An IPv6 apply failure must immediately invoke the exact-state rollback.
(
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
)

# HTTPS synchronization must not set the clock without enough trusted responses.
(
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by ts_sync_https
    ts_https_fetch_epoch() { return 1; }
    ! ts_sync_https fallback >/dev/null 2>&1 || { echo "HTTPS time sync accepted zero valid sources" >&2; exit 1; }
)

# HTTPS emergency time must report failure if the original NTP backend cannot be resumed.
(
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
)

# A failed APT source copy must leave neither a partial snapshot nor a modified source tree.
(
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
)

# Strict APT validation failure must restore every source file, including third-party entries.
(
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
)

# An unreadable DNF enabled-state must abort snapshot creation before any write.
(
    MIRROR_STATE_DIR="$TMP/mirror-rpm-state-failure/state"
    MIRROR_RPM_REPO_DIR="$TMP/mirror-rpm-state-failure/yum.repos.d"
    mkdir -p "$MIRROR_STATE_DIR" "$MIRROR_RPM_REPO_DIR"
    printf '[baseos]\nenabled=1\n' > "$MIRROR_RPM_REPO_DIR/rocky.repo"
    dnf() { return 1; }
    ! mirror_rpm_snapshot_create >/dev/null 2>&1 \
        || { echo "RPM snapshot accepted an unreadable enabled-repository state" >&2; exit 1; }
    ! find "$MIRROR_STATE_DIR" -maxdepth 1 -type d -name 'rpm-backup.*' | grep -q . \
        || { echo "RPM state-capture failure left a partial backup" >&2; exit 1; }
)

# An isolated DNF validation failure must restore the exact repository directory.
(
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
)

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
[ -f "$OFFLINE_BUNDLE" ] || { echo "Offline bundle was not created" >&2; exit 1; }
LOCAL_SCRIPT="$TMP/installed-script.sh"
LOCAL_BIN_DIR="$TMP/bin"
self_offline_bundle_install "$OFFLINE_BUNDLE" >/dev/null || { echo "Offline install failed" >&2; exit 1; }
[ -f "$LOCAL_SCRIPT" ] || { echo "Offline install did not place script" >&2; exit 1; }
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Offline install did not create an isolated shortcut" >&2; exit 1; }

# Process-substitution descriptors are streams, not complete reusable script files.
if self_resolve_script_source /dev/fd/0 >/dev/null 2>&1; then
    echo "Installer accepted a process-substitution descriptor as a complete script" >&2
    exit 1
fi
BROKEN_LINK_TARGET="$TMP/removed-script.sh"
rm -f "$LOCAL_BIN_DIR/v"
ln -s "$BROKEN_LINK_TARGET" "$LOCAL_BIN_DIR/v"
self_install_shortcut v >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Installer did not repair a dangling shortcut" >&2; exit 1; }
FOREIGN_SCRIPT="$TMP/foreign-command"
printf '#!/bin/sh\nexit 0\n' > "$FOREIGN_SCRIPT"
chmod +x "$FOREIGN_SCRIPT"
rm -f "$LOCAL_BIN_DIR/V"
ln -s "$FOREIGN_SCRIPT" "$LOCAL_BIN_DIR/V"
self_install_shortcut V >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/V")" = "$FOREIGN_SCRIPT" ] || { echo "Installer overwrote a foreign shortcut" >&2; exit 1; }

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
grep -qx 'original' "$LOCAL_SCRIPT" || { echo "Updater replaced script after checksum mismatch" >&2; exit 1; }

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
self_reconcile_tc_after_update >/dev/null \
    || { echo "Updater could not invoke the new tc reconciliation endpoint" >&2; exit 1; }
[ -f "$UPDATE_TC_MARKER" ] \
    || { echo "Updater reconciled tc through the old process" >&2; exit 1; }

# NFT firewall reconciliation must add the replacement before deleting the old
# route, and an add/remove failure must retain the ownership state for rollback.
(
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
)

# If a multi-rule firewall update fails after an earlier addition and that
# addition cannot be rolled back, it must remain owned so a later retry can remove it.
(
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
)

echo "Fault injection tests passed."
