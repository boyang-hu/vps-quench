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
QUENCH_TXN_DIR="$TMP/transactions"
# 事务锁默认落在 /run/lock，测试环境未必可写；缺少 flock 时会退回 mkdir 锁，
# 建不出锁目录就会（正确地）拒绝变更，所以这里必须指到可写路径。
QUENCH_TXN_LOCK_FILE="$TMP/quench-config.lock"
# shellcheck source=/dev/null
source "$ROOT/vps-quench.sh"
# shellcheck source=lib/harness.sh
source "$ROOT/tests/lib/harness.sh"

t_top_001() {
    for fn in systemd_available show_cli_help main_menu first_run_wizard first_run_route_ok first_run_dns_ok \
        first_run_access_ready first_run_ssh_baseline_render first_run_ssh_baseline_ready \
        first_run_network_security_pairs first_run_network_security_ready \
        system_package_manager system_auto_updates_supported system_auto_updates_enabled system_enable_auto_security_updates \
        user_management_menu ssh_key_count \
        user_list_names user_count user_is_admin user_admin_count user_ready_admin user_ready_admin_count user_authorized_keys \
        user_nopasswd_file user_file_mode user_nopasswd_file_valid user_nopasswd_enabled user_nopasswd_path_exists user_nopasswd_runtime_valid user_nopasswd_status user_nopasswd_enable user_nopasswd_disable user_sudo_permissions_show \
        ssh_port_valid ssh_port_number_valid ssh_set_ports_file ssh_write_port_state ssh_read_port_state ssh_security_status \
        fail2ban_menu f2b_config_file f2b_ports_valid f2b_get_section_param f2b_ensure_managed_config f2b_managed_ports_match f2b_runtime_healthy bbr_menu firewall_menu fw_port_spec_normalize fw_ip_family ufw_port_rule_present firewall_port_ready \
        dns_menu dns_backend_detect dns_effective_servers dns_detect_network dns_list_validate dns_probe_server dns_apply_resolved dns_apply_nm dns_apply_resolvconf dns_apply_static dns_effective_matches dns_fail_and_rollback timesync_menu \
        mirror_menu mirror_arch mirror_rpm_basearch mirror_ubuntu_archive_kind mirror_apt_candidate mirror_apt_probe_candidate mirror_apt_format mirror_apt_current_uris mirror_apt_tree_has_entries mirror_apt_snapshot_create mirror_apt_stage_create mirror_apt_install_tree mirror_apt_validate mirror_apply_apt mirror_restore_apt mirror_rpm_candidate mirror_rpm_repo_render mirror_apply_rpm mirror_restore_rpm \
        ts_current_timezone ts_timezone_syntax_valid ts_timezone_valid ts_timesyncd_available ts_timesyncd_active \
        ts_chrony_service ts_chrony_active ts_external_ntp_service ts_backend_detect ts_ntp_synchronized ts_backend_label \
        ts_time_health_inline ts_diagnostics ts_ntp_disable_chrony ts_ntp_disable_timesyncd ts_resolve_ntp_conflict \
        ts_wait_synchronized ts_ntp_request_backend ts_ntp_repair ts_request_sync ts_set_timezone ts_set_custom_timezone \
        ts_https_date_epoch ts_epoch_utc ts_https_fetch_epoch ts_https_consensus ts_pause_backend ts_resume_backend ts_sync_https \
        ip_config_menu ip_show_status ip_gai_markers_valid ip_gai_strip_managed ip_gai_has_external_precedence ip_gai_render_v4 ip_gai_validate_v4 ip_gai_policy_label ip_prefer_v4 ip_prefer_v6 ip_v6_state_summary ip_v6_external_disable_sources ip_v6_config_managed ip_v6_snapshot_create ip_v6_rollback_script_create ip_v6_write_runtime ip_v6_runtime_matches ip_apply_v6_state ip_source_switch_menu ip_source_switch_family ip_source_probe ip_source_policy_is_simple ip_source_default_iface ip_source_current ip_source_addresses ip_source_default_route ip_route_token ip_source_route_replace ip_source_route_restore ip_source_safety_arm ip_address_valid ip_source_verify caddy_menu caddy_site_records caddy_site_count caddy_managed_site_count caddy_site_address_parse caddy_backend_valid caddy_webroot_valid caddy_redirect_target_valid caddy_release_checksum_verify caddy_render_proxy_site caddy_render_static_site caddy_render_redirect_site caddy_render_php_site caddy_apply_managed_site caddy_delete_site nft_menu \
        nft_refresh_domain_targets nft_refresh_timer_status nft_refresh_timer_enable nft_refresh_timer_disable \
        system_toolbox_menu \
        resource_health_check system_update_manager system_hostname_apply config_backup_create config_path_allowed safety_timer_pending safety_rollback_now self_update docker_menu change_port \
        restore_backup_or_remove atomic_replace_file \
        safety_launch_timer safety_stop_timer_process cancel_safety_timer safety_confirm \
        txn_lock_acquire txn_lock_release txn_record_begin txn_record_end txn_record_field \
        txn_record_state txn_record_state_label txn_pending_records txn_review_menu rollback_center_menu; do
        declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing function: \$fn" t_top_001

t_top_002() {
    config_path_allowed /etc/resolv.conf || { echo "Allowlisted DNS path was rejected" >&2; exit 1; }
    ! config_path_allowed /etc/../passwd || { echo "Safety cleanup accepted path traversal" >&2; exit 1; }
    dns_list_validate '1.1.1.1 8.8.8.8' 4 || { echo "Valid IPv4 DNS list was rejected" >&2; exit 1; }
    ! dns_list_validate '1.1.1.999' 4 || { echo "Invalid IPv4 DNS was accepted" >&2; exit 1; }
    dns_list_validate '2606:4700:4700::1111 2001:4860:4860::8888' 6 \
        || { echo "Valid IPv6 DNS list was rejected" >&2; exit 1; }
    ! dns_list_validate '2001:db8::zz' 6 || { echo "Invalid IPv6 DNS was accepted" >&2; exit 1; }
    ! grep -Fq '183.60.83.19' "$ROOT/src/modules/dns.sh" \
        || { echo "DNSPod preset contains an undocumented address" >&2; exit 1; }
    [[ "$(mirror_ubuntu_archive_kind amd64)" = ubuntu ]] || { echo "Ubuntu amd64 archive classification failed" >&2; exit 1; }
    [[ "$(mirror_ubuntu_archive_kind arm64)" = ubuntu-ports ]] || { echo "Ubuntu arm64 archive classification failed" >&2; exit 1; }
    ! mirror_ubuntu_archive_kind mips64 >/dev/null 2>&1 || { echo "Ubuntu accepted an unsupported archive architecture" >&2; exit 1; }
    [[ "$(mirror_apt_candidate ubuntu ustc amd64)" = 'https://mirrors.ustc.edu.cn/ubuntu|https://mirrors.ustc.edu.cn/ubuntu|中科大 USTC' ]] \
        || { echo "Ubuntu amd64 mirror mapping failed" >&2; exit 1; }
    [[ "$(mirror_apt_candidate ubuntu ustc arm64)" = 'https://mirrors.ustc.edu.cn/ubuntu-ports|https://mirrors.ustc.edu.cn/ubuntu-ports|中科大 USTC' ]] \
        || { echo "Ubuntu arm64 mirror mapping failed" >&2; exit 1; }
    :
}
run_test "Allowlisted DNS path was rejected …+11 项" t_top_002

t_sm_001() {
    MIRROR_APT_DIR="$TMP/mirror-apt"
    MIRROR_STATE_DIR="$TMP/mirror-state"
    mkdir -p "$MIRROR_APT_DIR/sources.list.d"
    cat > "$MIRROR_APT_DIR/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable
deb https://ppa.launchpadcontent.net/example/project/ubuntu noble main
EOF
    cat > "$MIRROR_APT_DIR/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    cat > "$MIRROR_APT_DIR/sources.list.d/ppa.sources" <<'EOF'
Types: deb
URIs: https://ppa.launchpadcontent.net/example/project/ubuntu
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/example-ppa.gpg
EOF
    mirror_apt_stage_create https://mirrors.ustc.edu.cn/ubuntu https://security.ubuntu.com/ubuntu ubuntu noble 24.04
    grep -qF 'deb https://mirrors.ustc.edu.cn/ubuntu noble main' "$MIRROR_APT_STAGE/sources.list" \
        || { echo "APT list main archive rewrite failed" >&2; exit 1; }
    grep -qF 'deb https://security.ubuntu.com/ubuntu noble-security main' "$MIRROR_APT_STAGE/sources.list" \
        || { echo "APT list official security preservation failed" >&2; exit 1; }
    grep -qF 'https://download.docker.com/linux/ubuntu noble stable' "$MIRROR_APT_STAGE/sources.list" \
        || { echo "APT rewrite changed a third-party repository" >&2; exit 1; }
    grep -qF 'https://ppa.launchpadcontent.net/example/project/ubuntu noble main' "$MIRROR_APT_STAGE/sources.list" \
        || { echo "APT list rewrite changed a PPA" >&2; exit 1; }
    grep -qF 'URIs: https://ppa.launchpadcontent.net/example/project/ubuntu' "$MIRROR_APT_STAGE/sources.list.d/ppa.sources" \
        || { echo "APT Deb822 rewrite changed a PPA" >&2; exit 1; }
    [ "$(grep -c '^URIs:' "$MIRROR_APT_STAGE/sources.list.d/ubuntu.sources")" -eq 2 ] \
        || { echo "Deb822 mixed security stanza was not split" >&2; exit 1; }
    grep -qF 'URIs: https://security.ubuntu.com/ubuntu' "$MIRROR_APT_STAGE/sources.list.d/ubuntu.sources" \
        || { echo "Deb822 official security repository is missing" >&2; exit 1; }
    mirror_apt_snapshot_create || { echo "APT source snapshot failed" >&2; exit 1; }
    ORIGINAL_BACKUP="$MIRROR_APT_BACKUP"
    mirror_apt_install_tree "$MIRROR_APT_STAGE" || { echo "APT staged tree install failed" >&2; exit 1; }
    grep -qF 'https://mirrors.ustc.edu.cn/ubuntu' "$MIRROR_APT_DIR/sources.list" \
        || { echo "APT staged configuration was not installed" >&2; exit 1; }
    mirror_apt_install_tree "$ORIGINAL_BACKUP" || { echo "APT source snapshot restore failed" >&2; exit 1; }
    grep -qF 'http://archive.ubuntu.com/ubuntu' "$MIRROR_APT_DIR/sources.list" \
        || { echo "APT source restore did not recover the original archive" >&2; exit 1; }
    grep -qF 'https://download.docker.com/linux/ubuntu noble stable' "$MIRROR_APT_DIR/sources.list" \
        || { echo "APT source restore lost a third-party repository" >&2; exit 1; }
    :
}
run_test "APT list main archive rewrite failed" t_sm_001

t_sm_002() {
    MIRROR_APT_DIR="$TMP/mirror-unknown-apt"
    MIRROR_STATE_DIR="$TMP/mirror-unknown-state"
    mkdir -p "$MIRROR_APT_DIR/sources.list.d"
    printf 'deb https://ppa.launchpadcontent.net/example/project/ubuntu noble main\n' > "$MIRROR_APT_DIR/sources.list"
    if mirror_apt_stage_create https://mirrors.ustc.edu.cn/ubuntu https://security.ubuntu.com/ubuntu ubuntu noble 24.04; then
        echo "APT rewrote a configuration with no recognized system repository" >&2
        exit 1
    else
        RC=$?
        [ "$RC" -eq 3 ] || { echo "APT unknown-source refusal returned $RC instead of 3" >&2; exit 1; }
    fi
    :
}
run_test "APT rewrote a configuration with no recognized system repository" t_sm_002

RPM9=$(mirror_rpm_repo_render rocky 9 https://mirror.example/rocky Test file:///key)
t_top_003() {
    [[ "$RPM9" = *'/9/CRB/$basearch/os/'* && "$RPM9" = *'gpgcheck=1'* ]] \
        || { echo "Rocky 9 repository rendering failed" >&2; exit 1; }
    :
}
run_test "Rocky 9 repository rendering failed" t_top_003
RPM8=$(mirror_rpm_repo_render almalinux 8 https://mirror.example/alma Test file:///key)
t_top_004() {
    [[ "$RPM8" = *'/8/PowerTools/$basearch/os/'* ]] || { echo "AlmaLinux 8 PowerTools rendering failed" >&2; exit 1; }
    :
}
run_test "AlmaLinux 8 PowerTools rendering failed" t_top_004
CENTOS9=$(mirror_rpm_repo_render centos 9 https://mirror.example/centos-stream Test file:///key)
t_top_005() {
    [[ "$CENTOS9" = *'/9-stream/BaseOS/$basearch/os/'* && "$CENTOS9" = *'/SIGs/9-stream/extras/$basearch/extras-common/'* ]] \
        || { echo "CentOS Stream repository rendering failed" >&2; exit 1; }
    ! mirror_rpm_candidate rocky tuna >/dev/null 2>&1 \
        || { echo "Rocky Linux exposed a known-missing TUNA repository" >&2; exit 1; }
    ! mirror_rpm_candidate almalinux tuna >/dev/null 2>&1 \
        || { echo "AlmaLinux exposed a known-missing TUNA repository" >&2; exit 1; }
    :
}
run_test "CentOS Stream repository rendering failed …+2 项" t_top_005
t_sm_003() {
    MIRROR_OS_RELEASE_FILE="$TMP/centos-stream-8-os-release"
    QUENCH_MIRROR_RPM_ARCH=x86_64
    printf 'ID=centos\nVERSION_ID="8"\n' > "$MIRROR_OS_RELEASE_FILE"
    ! mirror_apply_rpm aliyun >/dev/null 2>&1 \
        || { echo "CentOS Stream 8 was allowed to use an incomplete EOL repository" >&2; exit 1; }
    :
}
run_test "CentOS Stream 8 was allowed to use an incomplete EOL repository" t_sm_003

t_sm_004() {
    DNS_RESOLV_FILE="$TMP/backend-resolv.conf"
    : > "$DNS_RESOLV_FILE"
    dns_nm_default_iface() { echo eth0; }
    dns_nm_connection_uuid() { [ "$1" = eth0 ] && echo uuid-default; }
    nmcli() { return 0; }
    svc_is_active() { [ "$1" = NetworkManager ]; }
    [ "$(dns_backend_detect)" = NetworkManager ] \
        || { echo "DNS backend detection did not prefer the active default NetworkManager profile" >&2; exit 1; }
    :
}
run_test "DNS backend detection did not prefer the active default NetworkManager profile" t_sm_004

t_sm_005() {
    DNS_RESOLV_FILE="$TMP/resolv-static.conf"
    printf 'search internal.example\nnameserver 192.0.2.53\noptions timeout:2\n' > "$DNS_RESOLV_FILE"
    dns_apply_static '1.1.1.1 1.0.0.1' || { echo "Static DNS apply failed" >&2; exit 1; }
    grep -qx 'search internal.example' "$DNS_RESOLV_FILE" || { echo "Static DNS lost search domains" >&2; exit 1; }
    grep -qx 'options timeout:2' "$DNS_RESOLV_FILE" || { echo "Static DNS lost resolver options" >&2; exit 1; }
    [ "$(grep -c '^nameserver ' "$DNS_RESOLV_FILE")" -eq 2 ] || { echo "Static DNS server replacement failed" >&2; exit 1; }
    ! grep -q '192.0.2.53' "$DNS_RESOLV_FILE" || { echo "Static DNS retained a stale server" >&2; exit 1; }
    :
}
run_test "Static DNS apply failed" t_sm_005

t_sm_006() {
    DNS_RESOLVED_DROPIN="$TMP/resolved/99-quench.conf"
    svc_restart() { [ "$1" = systemd-resolved ]; }
    resolvectl() { return 0; }
    dns_apply_resolved '1.1.1.1 2606:4700:4700::1111' \
        || { echo "systemd-resolved DNS apply failed" >&2; exit 1; }
    grep -qx 'DNS=1.1.1.1 2606:4700:4700::1111' "$DNS_RESOLVED_DROPIN" \
        || { echo "systemd-resolved DNS list is missing" >&2; exit 1; }
    grep -qx 'FallbackDNS=' "$DNS_RESOLVED_DROPIN" || { echo "systemd-resolved fallback was not disabled" >&2; exit 1; }
    grep -qx 'Domains=~.' "$DNS_RESOLVED_DROPIN" || { echo "systemd-resolved catch-all route is missing" >&2; exit 1; }
    :
}
run_test "systemd-resolved DNS apply failed" t_sm_006

t_sm_007() {
    DNS_RESOLVCONF_HEAD="$TMP/resolvconf/head"
    mkdir -p "$(dirname "$DNS_RESOLVCONF_HEAD")"
    printf 'search internal.example\nnameserver 192.0.2.53\n' > "$DNS_RESOLVCONF_HEAD"
    resolvconf() { [ "$1" = -u ]; }
    dns_apply_resolvconf '8.8.8.8 8.8.4.4' || { echo "resolvconf DNS apply failed" >&2; exit 1; }
    grep -qx 'search internal.example' "$DNS_RESOLVCONF_HEAD" || { echo "resolvconf lost non-DNS directives" >&2; exit 1; }
    [ "$(grep -c '^nameserver ' "$DNS_RESOLVCONF_HEAD")" -eq 2 ] || { echo "resolvconf DNS replacement failed" >&2; exit 1; }
    :
}
run_test "resolvconf DNS apply failed" t_sm_007

t_sm_008() {
    NM_LOG="$TMP/nmcli-dns.log"
    dns_nm_default_iface() { echo eth0; }
    dns_nm_connection_uuid() { [ "$1" = eth0 ] && echo uuid-default; }
    nmcli() {
        local ARG
        for ARG in "$@"; do printf '<%s>' "$ARG" >> "$NM_LOG"; done
        printf '\n' >> "$NM_LOG"
    }
    dns_apply_nm '1.1.1.1 1.0.0.1' '' || { echo "NetworkManager DNS apply failed" >&2; exit 1; }
    grep -Fq '<connection><modify><uuid-default>' "$NM_LOG" || { echo "NetworkManager did not target the default UUID" >&2; exit 1; }
    grep -Fq '<ipv6.dns><>' "$NM_LOG" || { echo "NetworkManager did not clear stale IPv6 DNS" >&2; exit 1; }
    grep -Fq '<device><reapply><eth0>' "$NM_LOG" || { echo "NetworkManager did not reapply only the default interface" >&2; exit 1; }
    [ "$(grep -Fc '<connection><modify><uuid-default>' "$NM_LOG")" -eq 3 ] \
        || { echo "NetworkManager unexpectedly modified another connection" >&2; exit 1; }
    :
}
run_test "NetworkManager DNS apply failed" t_sm_008

t_sm_009() {
    ip() {
        case "$*" in
            '-4 addr show scope global') echo 'inet 192.0.2.10/24 scope global eth0' ;;
            '-4 route get 1.1.1.1') return 0 ;;
            '-6 addr show scope global') echo 'inet6 2001:db8::10/64 scope global' ;;
            '-6 route get 2606:4700:4700::1111') return 1 ;;
            *) return 1 ;;
        esac
    }
    sysctl() { echo 0; }
    [ "$(dns_detect_network)" = 'true:false' ] \
        || { echo "DNS network detection accepted IPv6 without a working route" >&2; exit 1; }
    :
}
run_test "DNS network detection accepted IPv6 without a working route" t_sm_009

t_sm_010() {
    resolvectl() {
        printf 'Global: 1.1.1.1 2606:4700:4700::1111\nLink 2 (eth0): 192.0.2.53\n'
    }
    EFFECTIVE=$(dns_effective_servers systemd-resolved eth0)
    printf '%s\n' "$EFFECTIVE" | grep -Fxq '1.1.1.1' || { echo "Resolved global DNS was hidden" >&2; exit 1; }
    printf '%s\n' "$EFFECTIVE" | grep -Fxq '2606:4700:4700::1111' || { echo "Resolved IPv6 DNS parsing failed" >&2; exit 1; }
    :
}
run_test "Resolved global DNS was hidden" t_sm_010

t_top_006() {
    grep -q 'menu_group "初始化与诊断"' "$ROOT/src/modules/main.sh" \
        || { echo "Initialization and diagnostics main menu group is missing" >&2; exit 1; }
    grep -q 'menu_pair "w" "首次开荒向导" "h" "安全与诊断"' "$ROOT/src/modules/main.sh" \
        || { echo "First-run and diagnostics menu pairing is missing" >&2; exit 1; }
    grep -q -- '--first-run' "$ROOT/src/modules/main.sh" \
        || { echo "First-run CLI entry is missing" >&2; exit 1; }
    ! grep -RqE 'ts_https_(schedule|scheduled|cron|runner|interval)|--https-time-sync-run' "$ROOT/src" \
        || { echo "HTTPS emergency time sync must remain manual-only" >&2; exit 1; }
    ! grep -RqE '(^|[^[:alnum:]_])ntpdate([^[:alnum:]_]|$)' "$ROOT/src" \
        || { echo "Time synchronization must not use ntpdate" >&2; exit 1; }
    :
}
run_test "Initialization and diagnostics main menu group is missing …+4 项" t_top_006

t_sm_011() {
    ip() {
        [ "$*" = '-4 route get 1.1.1.1' ]
    }
    getent() {
        [ "$*" = 'ahosts github.com' ]
    }
    first_run_route_ok || { echo "First-run IPv4 route preflight failed" >&2; exit 1; }
    first_run_dns_ok || { echo "First-run DNS preflight failed" >&2; exit 1; }
    :
}
run_test "First-run IPv4 route preflight failed" t_sm_011

FIRST_RUN_SSH_SAMPLE="$TMP/first-run-sshd_config"
cat > "$FIRST_RUN_SSH_SAMPLE" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
MaxAuthTries 6
LoginGraceTime 2m
X11Forwarding yes
EOF
first_run_ssh_baseline_render "$FIRST_RUN_SSH_SAMPLE"
t_top_007() {
    for EXPECTED in \
        'PubkeyAuthentication yes' \
        'PermitEmptyPasswords no' \
        'MaxAuthTries 4' \
        'LoginGraceTime 30' \
        'X11Forwarding no'; do
        grep -qx "$EXPECTED" "$FIRST_RUN_SSH_SAMPLE" \
            || { echo "First-run SSH baseline missing: $EXPECTED" >&2; exit 1; }
    done
    :
}
run_test "First-run SSH baseline missing: \$EXPECTED" t_top_007
FIRST_RUN_FIRST_DIRECTIVE=$(grep -m1 -E '^(Include|PubkeyAuthentication|MaxAuthTries|LoginGraceTime|X11Forwarding)' "$FIRST_RUN_SSH_SAMPLE")
t_top_008() {
    [[ "$FIRST_RUN_FIRST_DIRECTIVE" = 'PubkeyAuthentication yes' ]] \
        || { echo "First-run SSH baseline must precede Include" >&2; exit 1; }
    :
}
run_test "First-run SSH baseline must precede Include" t_top_008

t_sm_012() {
    FIRST_RUN_NETWORK_SECURITY_FILE="$TMP/first-run-network-security.conf"
    while IFS='|' read -r KEY VALUE; do
        printf '%s = %s\n' "$KEY" "$VALUE"
    done < <(first_run_network_security_pairs) > "$FIRST_RUN_NETWORK_SECURITY_FILE"
    sysctl() {
        if [ "${1:-}" = -n ]; then
            first_run_network_security_pairs | awk -F'|' -v key="$2" '$1 == key {print $2; found=1} END {exit !found}'
        else
            return 1
        fi
    }
    first_run_network_security_ready \
        || { echo "Valid first-run network security baseline was rejected" >&2; exit 1; }
    awk '{sub("net.ipv4.tcp_syncookies = 1", "net.ipv4.tcp_syncookies = 0"); print}' \
        "$FIRST_RUN_NETWORK_SECURITY_FILE" > "$FIRST_RUN_NETWORK_SECURITY_FILE.tmp"
    mv "$FIRST_RUN_NETWORK_SECURITY_FILE.tmp" "$FIRST_RUN_NETWORK_SECURITY_FILE"
    ! first_run_network_security_ready \
        || { echo "Drifted first-run network security baseline was accepted" >&2; exit 1; }
    :
}
run_test "Valid first-run network security baseline was rejected" t_sm_012

t_sm_013() {
    QUENCH_APT_AUTO_UPGRADES_FILE="$TMP/20auto-upgrades"
    QUENCH_APT_UNATTENDED_FILE="$TMP/52quench-unattended-upgrades"
    system_package_manager() { echo apt; }
    systemd_available() { return 1; }
    unattended-upgrade() { :; }
    printf '%s\n' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' > "$QUENCH_APT_AUTO_UPGRADES_FILE"
    printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "false";' > "$QUENCH_APT_UNATTENDED_FILE"
    system_auto_updates_enabled \
        || { echo "Valid automatic security update config was rejected" >&2; exit 1; }
    printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' > "$QUENCH_APT_UNATTENDED_FILE"
    ! system_auto_updates_enabled \
        || { echo "Automatic reboot was accepted by first-run safety status" >&2; exit 1; }
    :
}
run_test "Valid automatic security update config was rejected" t_sm_013

t_top_009() {
    [[ "$(ip_source_probe 4)" = "1.1.1.1" ]] || { echo "IPv4 source-switch probe is wrong" >&2; exit 1; }
    [[ "$(ip_source_probe 6)" = "2606:4700:4700::1111" ]] || { echo "IPv6 source-switch probe is wrong" >&2; exit 1; }
    ip_address_valid 4 198.51.100.10 || { echo "Valid IPv4 address was rejected" >&2; exit 1; }
    ! ip_address_valid 4 198.51.100.999 || { echo "Invalid IPv4 address was accepted" >&2; exit 1; }
    ip_address_valid 6 2001:db8::10 || { echo "Valid IPv6 address was rejected" >&2; exit 1; }
    ! ip_address_valid 6 2001:db8::zz || { echo "Invalid IPv6 address was accepted" >&2; exit 1; }
    :
}
run_test "IPv4 source-switch probe is wrong …+5 项" t_top_009

t_sm_014() {
    GAI_BASE="$TMP/gai.conf"
    GAI_RENDERED="$TMP/gai.rendered"
    GAI_STRIPPED="$TMP/gai.stripped"
    printf '# Keep this user comment\nlabel ::1/128 0\n' > "$GAI_BASE"
    ip_gai_render_v4 "$GAI_BASE" "$GAI_RENDERED" \
        || { echo "glibc IPv4-preference rendering failed" >&2; exit 1; }
    ip_gai_validate_v4 "$GAI_RENDERED" \
        || { echo "Rendered glibc precedence table was rejected" >&2; exit 1; }
    [ "$(grep -Ec '^[[:space:]]*precedence[[:space:]]+' "$GAI_RENDERED")" -eq 5 ] \
        || { echo "glibc IPv4 preference did not render the complete table" >&2; exit 1; }
    grep -Eq '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100$' "$GAI_RENDERED" \
        || { echo "glibc IPv4-mapped precedence is wrong" >&2; exit 1; }
    ip_gai_strip_managed "$GAI_RENDERED" "$GAI_STRIPPED" \
        || { echo "Quench gai.conf block removal failed" >&2; exit 1; }
    grep -Fxq '# Keep this user comment' "$GAI_STRIPPED" \
        || { echo "gai.conf cleanup lost user content" >&2; exit 1; }
    ! grep -Fq "$IP_GAI_BEGIN" "$GAI_STRIPPED" \
        || { echo "gai.conf cleanup retained the managed block" >&2; exit 1; }

    printf 'precedence ::ffff:0:0/96 75\n' >> "$GAI_BASE"
    if ip_gai_render_v4 "$GAI_BASE" "$GAI_RENDERED"; then
        echo "glibc policy rendering overwrote an external precedence table" >&2
        exit 1
    else
        [ "$?" -eq 2 ] || { echo "External gai.conf policy refusal returned the wrong status" >&2; exit 1; }
    fi
    printf '%s\n%s\n' "$IP_GAI_END" "$IP_GAI_BEGIN" > "$GAI_BASE"
    ! ip_gai_markers_valid "$GAI_BASE" \
        || { echo "Out-of-order gai.conf markers were accepted" >&2; exit 1; }
    :
}
run_test "glibc IPv4-preference rendering failed" t_sm_014

t_sm_015() {
    POLICY_CUSTOM=0
    ip() {
        [ "$*" = '-4 rule show' ] || return 1
        printf '%s\n' \
            '0:      from all lookup local' \
            '32766:  from all lookup main' \
            '32767:  from all lookup default'
        [ "$POLICY_CUSTOM" -eq 0 ] || printf '1000: from 198.51.100.0/24 lookup 100\n'
    }
    ip_source_policy_is_simple 4 \
        || { echo "Standard policy-routing rules were rejected" >&2; exit 1; }
    POLICY_CUSTOM=1
    ! ip_source_policy_is_simple 4 \
        || { echo "Custom policy-routing rules were accepted" >&2; exit 1; }
    :
}
run_test "Standard policy-routing rules were rejected" t_sm_015

t_sm_016() {
    IP_V6_PROC_ROOT="$TMP/ip-v6-proc"
    IP_STATE_DIR="$TMP/ip-state"
    IP_V6_SYSCTL_FILE="$TMP/sysctl.d/99-quench-ipv6.conf"
    IP_SYSCTL_CONF="$TMP/sysctl.conf"
    IP_SYSCTL_DIR="$TMP/sysctl.d"
    for IFACE in all default lo eth0; do mkdir -p "$IP_V6_PROC_ROOT/$IFACE"; done
    printf '0\n' > "$IP_V6_PROC_ROOT/all/disable_ipv6"
    printf '1\n' > "$IP_V6_PROC_ROOT/default/disable_ipv6"
    printf '0\n' > "$IP_V6_PROC_ROOT/lo/disable_ipv6"
    printf '1\n' > "$IP_V6_PROC_ROOT/eth0/disable_ipv6"
    [ "$(ip_v6_state_summary)" = '混合状态（启用 1 / 禁用 1）' ] \
        || { echo "Per-interface IPv6 state summary is wrong" >&2; exit 1; }
    ip_v6_snapshot_create || { echo "IPv6 exact-state snapshot failed" >&2; exit 1; }
    SNAPSHOT="$IP_V6_SNAPSHOT"
    printf '1\n' > "$IP_V6_PROC_ROOT/all/disable_ipv6"
    printf '0\n' > "$IP_V6_PROC_ROOT/default/disable_ipv6"
    printf '1\n' > "$IP_V6_PROC_ROOT/lo/disable_ipv6"
    printf '0\n' > "$IP_V6_PROC_ROOT/eth0/disable_ipv6"
    mkdir -p "$(dirname "$IP_V6_SYSCTL_FILE")"
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$IP_V6_SYSCTL_FILE"
    # The rollback that actually runs in production is the standalone script, not a
    # helper in this process. Exercise that one so the two cannot drift apart.
    ROLLBACK_SCRIPT="$TMP/rollback-ipv6.sh"
    ip_v6_rollback_script_create "$SNAPSHOT" "$ROLLBACK_SCRIPT" 180 \
        || { echo "IPv6 rollback script generation failed" >&2; exit 1; }
    bash -n "$ROLLBACK_SCRIPT" \
        || { echo "Generated IPv6 rollback script has invalid syntax" >&2; exit 1; }
    bash "$ROLLBACK_SCRIPT" --now \
        || { echo "IPv6 exact-state restore failed" >&2; exit 1; }
    [ ! -e "$ROLLBACK_SCRIPT" ] \
        || { echo "A successful IPv6 rollback did not remove its own script" >&2; exit 1; }
    [ ! -e "$IP_V6_SYSCTL_FILE" ] \
        || { echo "IPv6 restore retained a newly-created managed config" >&2; exit 1; }
    [ "$(cat "$IP_V6_PROC_ROOT/all/disable_ipv6")" = 0 ] \
        && [ "$(cat "$IP_V6_PROC_ROOT/default/disable_ipv6")" = 1 ] \
        && [ "$(cat "$IP_V6_PROC_ROOT/lo/disable_ipv6")" = 0 ] \
        && [ "$(cat "$IP_V6_PROC_ROOT/eth0/disable_ipv6")" = 1 ] \
        || { echo "IPv6 restore did not recover every saved runtime value" >&2; exit 1; }
    ip_v6_write_runtime 1 && ip_v6_runtime_matches 1 \
        || { echo "IPv6 all-interface runtime write verification failed" >&2; exit 1; }
    [ "$(ip_v6_state_summary)" = '所有接口已禁用' ] \
        || { echo "Disabled IPv6 state summary is wrong" >&2; exit 1; }
    printf 'net.ipv6.conf.eth0.disable_ipv6 = 1\n' > "$IP_SYSCTL_CONF"
    ip_v6_external_disable_sources | grep -Fq "$IP_SYSCTL_CONF:1:" \
        || { echo "External persistent IPv6 disable was not detected" >&2; exit 1; }
    printf '# Not managed by Quench\n' > "$IP_V6_SYSCTL_FILE"
    ! ip_v6_config_managed \
        || { echo "An unrelated IPv6 sysctl file was treated as Quench-managed" >&2; exit 1; }
    ! ip_apply_v6_state 1 \
        || { echo "IPv6 apply overwrote an unrelated sysctl file" >&2; exit 1; }
    :
}
run_test "Per-interface IPv6 state summary is wrong" t_sm_016

t_sm_017() {
    IP_ROUTE_LOG="$TMP/ip-source-route.log"
    ip() { printf '%s\n' "$*" > "$IP_ROUTE_LOG"; }
    ip_source_route_replace 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' 198.51.100.11
    grep -qx -- '-4 route replace default via 192.0.2.1 dev eth0 proto dhcp metric 100 src 198.51.100.11' "$IP_ROUTE_LOG" \
        || { echo "IPv4 source-switch route replacement is wrong" >&2; exit 1; }
    ip_source_route_replace 6 'default via fe80::1 dev eth0 proto ra src 2001:4860::10 metric 1024 expires 1200sec pref high' 2001:4860::11
    grep -qx -- '-6 route replace default via fe80::1 dev eth0 proto ra metric 1024 expires 1200sec pref high src 2001:4860::11' "$IP_ROUTE_LOG" \
        || { echo "IPv6 source-switch route replacement did not preserve route attributes" >&2; exit 1; }
    ip_source_route_restore 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100'
    grep -qx -- '-4 route replace default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' "$IP_ROUTE_LOG" \
        || { echo "Source-switch route restoration is wrong" >&2; exit 1; }
    ip_source_route_restore 6 'default via fe80::1 dev eth0 proto ra src 2001:4860::10 metric 1024 expires 1200sec pref high'
    grep -qx -- '-6 route replace default via fe80::1 dev eth0 proto ra src 2001:4860::10 metric 1024 expires 1200sec pref high' "$IP_ROUTE_LOG" \
        || { echo "IPv6 source-switch rollback did not preserve the exact route" >&2; exit 1; }
    :
}
run_test "IPv4 source-switch route replacement is wrong" t_sm_017

t_sm_018() {
    USER_PASSWD_FILE="$TMP/passwd"
    USER_GROUP_FILE="$TMP/group"
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/bash' \
        'daemon:x:2:2:daemon:/sbin:/usr/sbin/nologin' \
        'admin:x:1000:1000:Admin:/home/admin:/bin/bash' \
        'alice:x:1001:1001:Alice:/home/alice:/bin/sh' > "$USER_PASSWD_FILE"
    printf '%s\n' \
        'root:x:0:' \
        'sudo:x:27:admin' \
        'admin:x:1000:' \
        'alice:x:1001:' > "$USER_GROUP_FILE"
    mkdir -p "$TMP/home/admin/.ssh" "$TMP/home/alice"
    sed -i.bak "s#/home/admin#$TMP/home/admin#; s#/home/alice#$TMP/home/alice#" "$USER_PASSWD_FILE"
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestAdmin admin-key' > "$TMP/home/admin/.ssh/authorized_keys"
    [[ "$(user_list_names)" = $'root\nadmin\nalice' ]] || { echo "Managed user listing is wrong" >&2; exit 1; }
    [[ "$(user_count)" = 3 ]] || { echo "Managed user count is wrong" >&2; exit 1; }
    user_is_admin admin || { echo "sudo group member was not recognized as admin" >&2; exit 1; }
    ! user_is_admin alice || { echo "regular user was recognized as admin" >&2; exit 1; }
    [[ "$(user_admin_count)" = 1 ]] || { echo "Admin count is wrong" >&2; exit 1; }
    [[ "$(user_key_count admin)" = 1 ]] || { echo "Per-user SSH key count is wrong" >&2; exit 1; }
    user_ready_admin admin || { echo "Keyed admin was not considered ready" >&2; exit 1; }
    [[ "$(user_ready_admin_count)" = 1 ]] || { echo "Ready admin count is wrong" >&2; exit 1; }
    USER_SUDOERS_DIR="$TMP/sudoers.d"
    USER_ADMIN_SUDOERS_FILE="$USER_SUDOERS_DIR/90-quench-admins"
    QUENCH_AUDIT_LOG="$TMP/user-audit.log"
    sudo() { :; }
    visudo() { [ "$1" = -cf ] && [ -f "$2" ]; }
    user_nopasswd_runtime_valid() { user_nopasswd_enabled "$1"; }
    user_nopasswd_enable admin >/dev/null \
        || { echo "Passwordless sudo could not be enabled for an admin" >&2; exit 1; }
    NOPASSWD_FILE=$(user_nopasswd_file admin)
    user_nopasswd_file_valid admin "$NOPASSWD_FILE" \
        || { echo "Passwordless sudo file failed ownership or mode validation" >&2; exit 1; }
    [ "$(user_file_mode "$NOPASSWD_FILE")" = 440 ] \
        || { echo "Passwordless sudo file mode is not 0440" >&2; exit 1; }
    [ "$(user_nopasswd_status admin)" = '已开启（Quench）' ] \
        || { echo "Passwordless sudo status is wrong" >&2; exit 1; }
    ! user_nopasswd_enable alice >/dev/null 2>&1 \
        || { echo "Passwordless sudo was granted to a non-admin" >&2; exit 1; }
    ! user_revoke_admin admin >/dev/null 2>&1 \
        || { echo "Admin role was removed while passwordless sudo remained" >&2; exit 1; }
    user_nopasswd_disable admin >/dev/null \
        || { echo "Passwordless sudo could not be disabled" >&2; exit 1; }
    [ ! -e "$NOPASSWD_FILE" ] \
        || { echo "Passwordless sudo file remains after disable" >&2; exit 1; }
    ! user_revoke_admin admin >/dev/null 2>&1 || { echo "Last non-root admin could be revoked" >&2; exit 1; }
    :
}
run_test "Managed user listing is wrong" t_sm_018

t_sm_019() {
    SSH_PORT_STATE_FILE="$TMP/ssh-port-migration.state"
    ssh_write_port_state 22 2222
    OLD_PORT="" NEW_PORT=""
    ssh_read_port_state || { echo "Valid SSH port migration state was rejected" >&2; exit 1; }
    [[ "$OLD_PORT" = 22 && "$NEW_PORT" = 2222 ]] || { echo "SSH port migration state parsed incorrectly" >&2; exit 1; }
    ssh_port_valid 2222 || { echo "Valid high SSH port was rejected" >&2; exit 1; }
    ! ssh_port_valid 22 || { echo "Reserved new SSH port was accepted" >&2; exit 1; }
    ssh_port_number_valid 22 || { echo "Existing SSH port 22 was rejected" >&2; exit 1; }
    SSHD_CONFIG_FIXTURE="$TMP/sshd_config"
    cat > "$SSHD_CONFIG_FIXTURE" <<'EOF'
# BEGIN QUENCH SSH SETTINGS
Port 2200
PasswordAuthentication no
# END QUENCH SSH SETTINGS
Port 22
PermitRootLogin prohibit-password
EOF
    ssh_set_ports_file "$SSHD_CONFIG_FIXTURE" 22 2222
    [[ "$(grep -c '^Port ' "$SSHD_CONFIG_FIXTURE")" = 2 ]] || { echo "SSH dual-port config did not contain exactly two managed ports" >&2; exit 1; }
    grep -qx 'Port 22' "$SSHD_CONFIG_FIXTURE" || { echo "Old SSH port missing from migration config" >&2; exit 1; }
    grep -qx 'Port 2222' "$SSHD_CONFIG_FIXTURE" || { echo "New SSH port missing from migration config" >&2; exit 1; }
    grep -qx 'PasswordAuthentication no' "$SSHD_CONFIG_FIXTURE" || { echo "SSH policy was lost while changing ports" >&2; exit 1; }
    grep -q '^# Disabled by Quench SSH port migration: Port 22$' "$SSHD_CONFIG_FIXTURE" \
        || { echo "External SSH Port directive was not neutralized" >&2; exit 1; }
    :
}
run_test "Valid SSH port migration state was rejected" t_sm_019
t_sm_020() {
    ip() {
        case "$*" in
            '-4 route get 1.1.1.1') echo '1.1.1.1 via 192.0.2.1 dev eth0 src 198.51.100.11 uid 0' ;;
            '-4 -o addr show dev eth0 scope global')
                printf '%s\n' \
                    '2: eth0 inet 198.51.100.10/24 brd 198.51.100.255 scope global eth0' \
                    '2: eth0 inet 198.51.100.11/24 brd 198.51.100.255 scope global secondary eth0' \
                    '2: eth0 inet 198.51.100.12/24 brd 198.51.100.255 scope global temporary eth0'
                ;;
        esac
    }
    [[ "$(ip_source_default_iface 4)" = eth0 ]] || { echo "Source-switch default interface parsing failed" >&2; exit 1; }
    [[ "$(ip_source_current 4)" = 198.51.100.11 ]] || { echo "Source-switch current address parsing failed" >&2; exit 1; }
    [[ "$(ip_source_addresses 4 eth0)" = $'198.51.100.10\n198.51.100.11' ]] \
        || { echo "Source-switch candidate filtering failed" >&2; exit 1; }
    :
}
run_test "Source-switch default interface parsing failed" t_sm_020

t_sm_021() {
    AUTH_KEYS="$TMP/authorized_keys"
    : > "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 0 ]] || { echo "Empty authorized_keys did not return a single zero" >&2; exit 1; }
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest1 test-one' 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTest2 test-two' > "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 2 ]] || { echo "SSH key counter did not count valid keys" >&2; exit 1; }
    rm -f "$AUTH_KEYS"
    [[ "$(ssh_key_count)" = 0 ]] || { echo "Missing authorized_keys did not return zero" >&2; exit 1; }
    :
}
run_test "Empty authorized_keys did not return a single zero" t_sm_021

# These helpers used to take their target from a dynamically scoped AUTH_KEYS, so a
# caller that shadowed it in the wrong order would write a user's key into root's
# authorized_keys. The target is an explicit argument now; the global is only a default.
t_sm_022() {
    mkdir -p "$TMP/keyarg"
    AUTH_KEYS="$TMP/keyarg/global"
    : > "$AUTH_KEYS"
    KEY_TARGET="$TMP/keyarg/explicit"
    : > "$KEY_TARGET"

    # error/warn 打到 stdout，失败信息必须把 stdout 一并收进来，否则只剩一句空白
    KEY_OUT=$(printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExplicitTarget explicit@test' \
        | add_key "$KEY_TARGET" 2>&1) \
        || { echo "add_key failed (flock=$(command -v flock || echo none) lock_mode=${QUENCH_TXN_LOCK_MODE:-} lock_file=$QUENCH_TXN_LOCK_FILE): $KEY_OUT" >&2; ls -la "$QUENCH_TXN_LOCK_FILE"* >&2 2>/dev/null; exit 1; }
    grep -qF ExplicitTarget "$KEY_TARGET" \
        || { echo "add_key ignored its explicit target file" >&2; exit 1; }
    [ ! -s "$AUTH_KEYS" ] \
        || { echo "add_key wrote into the global AUTH_KEYS instead of its argument" >&2; exit 1; }

    [ "$(ssh_key_count "$KEY_TARGET")" = 1 ] \
        || { echo "ssh_key_count ignored its explicit target file" >&2; exit 1; }
    [ "$(ssh_key_count)" = 0 ] \
        || { echo "ssh_key_count no longer defaults to the global AUTH_KEYS" >&2; exit 1; }

    list_keys "$KEY_TARGET" >/dev/null \
        || { echo "list_keys ignored its explicit target file" >&2; exit 1; }
    list_keys >/dev/null 2>&1 \
        && { echo "list_keys default did not fall back to the empty global file" >&2; exit 1; }

    printf '1\ny\n' | delete_key "$KEY_TARGET" >/dev/null 2>&1
    [ "$(ssh_key_count "$KEY_TARGET")" = 0 ] \
        || { echo "delete_key ignored its explicit target file" >&2; exit 1; }

    # The mutating helpers take no default: forgetting the argument must fail loudly
    # rather than quietly falling back to root's authorized_keys.
    for KEY_FN in show_keys add_key delete_key generate_key; do
        "$KEY_FN" >/dev/null 2>&1 \
            && { echo "$KEY_FN accepted a missing target file" >&2; exit 1; }
    done

    # 没有任何一处写到全局默认文件上
    if [ -s "$AUTH_KEYS" ]; then
        echo "A key helper leaked into the global AUTH_KEYS" >&2
        exit 1
    fi
    :
}
run_test "These helpers used to take their target from a dynamically scoped AUTH_KEYS, so a caller that…" t_sm_022

t_top_010() {
    [[ "$(ts_https_date_epoch 'Sat, 25 Jul 2026 12:00:00 GMT')" = 1784980800 ]] || { echo "HTTPS Date header parsing failed" >&2; exit 1; }
    ! ts_https_date_epoch 'invalid date' >/dev/null 2>&1 || { echo "Invalid HTTPS Date header was accepted" >&2; exit 1; }
    [[ "$(ts_epoch_utc 1784980800)" = '2026-07-25 12:00:00' ]] || { echo "HTTPS epoch formatting failed" >&2; exit 1; }
    [[ "$(ts_https_consensus 1784980800 1784980802 1784980900)" = '1784980801 2 2' ]] || { echo "HTTPS time consensus did not reject an outlier" >&2; exit 1; }
    ! ts_https_consensus 1784980800 1784980820 >/dev/null 2>&1 || { echo "HTTPS time consensus accepted disagreeing sources" >&2; exit 1; }
    ts_timezone_syntax_valid UTC || { echo "UTC timezone syntax was rejected" >&2; exit 1; }
    ts_timezone_syntax_valid Asia/Shanghai || { echo "IANA timezone syntax was rejected" >&2; exit 1; }
    ts_timezone_syntax_valid GMT || { echo "Single-component IANA timezone syntax was rejected" >&2; exit 1; }
    ! ts_timezone_syntax_valid '../etc/passwd' >/dev/null 2>&1 || { echo "Timezone traversal was accepted" >&2; exit 1; }
    ! ts_timezone_syntax_valid '/etc/localtime' >/dev/null 2>&1 || { echo "Absolute timezone path was accepted" >&2; exit 1; }
    ! ts_timezone_syntax_valid 'Asia/Shanghai;id' >/dev/null 2>&1 || { echo "Timezone shell metacharacters were accepted" >&2; exit 1; }
    :
}
run_test "HTTPS Date header parsing failed …+10 项" t_top_010
t_sm_023() {
    ts_timesyncd_active() { return 0; }
    ts_chrony_active() { return 1; }
    ts_external_ntp_service() { return 1; }
    [[ "$(ts_backend_detect)" = timesyncd ]] || { echo "timesyncd backend detection failed" >&2; exit 1; }
    ts_chrony_active() { return 0; }
    [[ "$(ts_backend_detect)" = conflict ]] || { echo "NTP backend conflict was not detected" >&2; exit 1; }
    ts_timesyncd_active() { return 0; }
    ts_chrony_active() { return 1; }
    ts_external_ntp_service() { echo ntpd; }
    [[ "$(ts_backend_detect)" = conflict ]] || { echo "External and managed NTP conflict was not detected" >&2; exit 1; }
    :
}
run_test "timesyncd backend detection failed" t_sm_023
t_sm_024() {
    chronyc() {
        printf 'Stratum         : 3\nLeap status     : Normal\n'
    }
    ts_ntp_synchronized chrony || { echo "Healthy chrony tracking was not accepted" >&2; exit 1; }
    :
}
run_test "Healthy chrony tracking was not accepted" t_sm_024
t_sm_025() {
    # shellcheck disable=SC2329 # test stub used indirectly by ts_https_fetch_epoch
    curl() { printf 'HTTP/2 200\r\nDate: Sat, 25 Jul 2026 12:00:00 GMT\r\n\r\n'; }
    [[ "$(ts_https_fetch_epoch https://example.com/)" = 1784980800 ]] || { echo "HTTPS response Date extraction failed" >&2; exit 1; }
    :
}
run_test "HTTPS response Date extraction failed" t_sm_025

CADDYFILE="$TMP/Caddyfile"
CADDY_CONFIG_DIR="$TMP/caddy-parser"
CADDY_SITES_DIR="$CADDY_CONFIG_DIR/sites.d"
CADDY_LOG_DIR="$CADDY_CONFIG_DIR/log"
CADDY_DATA_DIR="$CADDY_CONFIG_DIR/data"
CADDY_STATE_DIR="$CADDY_CONFIG_DIR/state"
CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
cat > "$CADDYFILE" <<'EOF'
{
    email admin@example.com
}

(common_headers) {
    header X-Test enabled
}

cdr.289599.top {
	reverse_proxy 127.0.0.1:8081 {
		header_up Host {host}
		transport http {
			tls
		}
	}
}

dockge.289599.top {
    reverse_proxy 127.0.0.1:5001
}

fwx.289599.top {
    handle {
        reverse_proxy 127.0.0.1:18080
    }
}

example.com, www.example.com {
    redir https://www.example.com{uri}
}
EOF
CADDY_RECORDS=$(caddy_site_records)
EXPECTED_CADDY_SITES=$(printf '%s\n' 'cdr.289599.top' 'dockge.289599.top' 'fwx.289599.top' 'example.com, www.example.com')
ACTUAL_CADDY_SITES=$(printf '%s\n' "$CADDY_RECORDS" | awk -F '\t' '$1 == "site" { print $2 }')
t_top_011() {
    [[ "$ACTUAL_CADDY_SITES" = "$EXPECTED_CADDY_SITES" ]] || { echo "Caddy nested blocks were parsed as sites" >&2; exit 1; }
    [[ "$(caddy_site_count)" = 4 ]] || { echo "Caddy site count included nested or option blocks" >&2; exit 1; }
    [[ "$CADDY_RECORDS" == *$'directive\treverse_proxy\t127.0.0.1:8081'* ]] || { echo "Caddy nested reverse proxy target was not listed" >&2; exit 1; }
    :
}
run_test "Caddy nested blocks were parsed as sites …+2 项" t_top_011
[[ "$CADDY_RECORDS" != *$'site\treverse_proxy'* && "$CADDY_RECORDS" != *$'site\theader_up'* && "$CADDY_RECORDS" != *$'site\ttransport'* ]] || {
    echo "Caddy nested directive was exposed as a site" >&2
    exit 1
}
CADDY_LIST_OUTPUT=$(caddy_list_sites)
[[ "$CADDY_LIST_OUTPUT" == *'[1] cdr.289599.top'* && "$CADDY_LIST_OUTPUT" == *'[2] dockge.289599.top'* && "$CADDY_LIST_OUTPUT" == *'[4] example.com, www.example.com'* ]] || {
    echo "Caddy site list numbering is incomplete" >&2
    exit 1
}
[[ "$CADDY_LIST_OUTPUT" == *'reverse_proxy → 127.0.0.1:8081'* && "$CADDY_LIST_OUTPUT" != *'[2] reverse_proxy'* ]] || {
    echo "Caddy site list did not render a nested proxy correctly" >&2
    exit 1
}

caddy_site_address_parse 'https://EXAMPLE.com:443'
t_top_012() {
    [[ "$CADDY_SITE_ADDRESS" = example.com && "$CADDY_SITE_SCHEME" = https && "$CADDY_SITE_PORT" = 443 ]] \
        || { echo "Caddy HTTPS address canonicalization failed" >&2; exit 1; }
    :
}
run_test "Caddy HTTPS address canonicalization failed" t_top_012
caddy_site_address_parse 'example.com:8443'
t_top_013() {
    [[ "$CADDY_SITE_ADDRESS" = 'https://example.com:8443' && "$CADDY_SITE_PORT" = 8443 ]] \
        || { echo "Caddy custom HTTPS address canonicalization failed" >&2; exit 1; }
    :
}
run_test "Caddy custom HTTPS address canonicalization failed" t_top_013
caddy_site_address_parse '198.51.100.10:8080'
t_top_014() {
    [[ "$CADDY_SITE_ADDRESS" = 'http://198.51.100.10:8080' && "$CADDY_SITE_SCHEME" = http ]] \
        || { echo "Caddy IPv4 address was mistaken for a domain" >&2; exit 1; }
    ! caddy_site_address_parse '999.51.100.10:8080' \
        || { echo "Caddy accepted an invalid IPv4 address as a domain" >&2; exit 1; }
    ! caddy_site_address_parse 'https://example.com:80' \
        || { echo "Caddy accepted a conflicting HTTPS port" >&2; exit 1; }
    caddy_backend_valid '127.0.0.1:8080' || { echo "Caddy rejected a safe proxy backend" >&2; exit 1; }
    ! caddy_backend_valid '127.0.0.1:8080 { malicious' \
        || { echo "Caddy accepted an injectable proxy backend" >&2; exit 1; }
    caddy_webroot_valid '/var/www/example.com/public' || { echo "Caddy rejected a safe web root" >&2; exit 1; }
    ! caddy_webroot_valid '/var/www/../etc' || { echo "Caddy accepted web-root traversal" >&2; exit 1; }
    caddy_redirect_target_valid 'https://www.example.com' || { echo "Caddy rejected a safe redirect" >&2; exit 1; }
    ! caddy_redirect_target_valid 'https://www.example.com/path' \
        || { echo "Caddy accepted an ambiguous redirect path" >&2; exit 1; }
    :
}
run_test "Caddy IPv4 address was mistaken for a domain …+8 项" t_top_014

printf 'verified Caddy archive\n' > "$TMP/caddy-test.tar.gz"
CADDY_TEST_HASH=$(caddy_sha512 "$TMP/caddy-test.tar.gz")
printf '%s  %s\n' "$CADDY_TEST_HASH" caddy-test.tar.gz > "$TMP/caddy-checksums.txt"
t_top_015() {
    caddy_release_checksum_verify "$TMP/caddy-test.tar.gz" "$TMP/caddy-checksums.txt" caddy-test.tar.gz \
        || { echo "Caddy rejected a valid SHA-512 release checksum" >&2; exit 1; }
    :
}
run_test "Caddy rejected a valid SHA-512 release checksum" t_top_015
printf 'tampered\n' >> "$TMP/caddy-test.tar.gz"
t_top_016() {
    ! caddy_release_checksum_verify "$TMP/caddy-test.tar.gz" "$TMP/caddy-checksums.txt" caddy-test.tar.gz \
        || { echo "Caddy accepted a mismatched release checksum" >&2; exit 1; }
    :
}
run_test "Caddy accepted a mismatched release checksum" t_top_016
printf '%s  %s\n%s  %s\n' "$CADDY_TEST_HASH" caddy-test.tar.gz "$CADDY_TEST_HASH" caddy-test.tar.gz \
    > "$TMP/caddy-duplicate-checksums.txt"
t_top_017() {
    ! caddy_release_checksum_verify "$TMP/caddy-test.tar.gz" "$TMP/caddy-duplicate-checksums.txt" caddy-test.tar.gz \
        || { echo "Caddy accepted duplicate release checksum entries" >&2; exit 1; }
    :
}
run_test "Caddy accepted duplicate release checksum entries" t_top_017

CADDY_RENDER=$(caddy_render_proxy_site 'proxy.example.com' '127.0.0.1:8080' 'proxy.example.com')
t_top_018() {
    [[ "$CADDY_RENDER" == *'# Managed by Quench: Caddy site'* \
        && "$CADDY_RENDER" == *'reverse_proxy 127.0.0.1:8080'* \
        && "$CADDY_RENDER" == *'format json'* \
        && "$CADDY_RENDER" == *'roll_keep_for 720h'* ]] \
        || { echo "Caddy managed proxy rendering is incomplete" >&2; exit 1; }
    :
}
run_test "Caddy managed proxy rendering is incomplete" t_top_018
t_sm_026() {
    UFW_CASE=source
    ufw() {
        printf 'Status: active\n'
        case "$UFW_CASE" in
            source) printf '80/tcp ALLOW IN 203.0.113.10\n' ;;
            broad) printf '80/tcp ALLOW IN Anywhere\n' ;;
            denied) printf '80/tcp ALLOW IN Anywhere\n80/tcp DENY IN Anywhere\n' ;;
            udp) printf '443/udp ALLOW IN Anywhere\n' ;;
        esac
    }
    ! caddy_firewall_rule_ready ufw 80/tcp \
        || { echo "Caddy accepted a source-limited UFW rule as a public Web rule" >&2; exit 1; }
    UFW_CASE=broad
    caddy_firewall_rule_ready ufw 80/tcp \
        || { echo "Caddy rejected a broad UFW Web allow rule" >&2; exit 1; }
    UFW_CASE=denied
    ! caddy_firewall_rule_ready ufw 80/tcp \
        || { echo "Caddy ignored a broad UFW deny rule" >&2; exit 1; }
    UFW_CASE=udp
    caddy_firewall_rule_ready ufw 443/udp \
        || { echo "Caddy rejected a broad UFW HTTP/3 rule" >&2; exit 1; }
    :
}
run_test "Caddy accepted a source-limited UFW rule as a public Web rule" t_sm_026
t_sm_027() {
    CADDY_RULE_CAPTURE="$TMP/caddy-ingress-rules"
    caddy_domain_addresses() { printf '203.0.113.20\n'; }
    caddy_listener_conflicts() { return 0; }
    caddy_firewall_prepare_rules() { printf '%s\n' "$*" > "$CADDY_RULE_CAPTURE"; }
    caddy_site_address_parse example.com
    caddy_prepare_ingress >/dev/null
    grep -Fqx '80/tcp 443/tcp 443/udp' "$CADDY_RULE_CAPTURE" \
        || { echo "Caddy HTTPS ingress omitted its HTTP/3 UDP rule" >&2; exit 1; }
    :
}
run_test "Caddy HTTPS ingress omitted its HTTP/3 UDP rule" t_sm_027

t_sm_028() {
    CADDY_CONFIG_DIR="$TMP/caddy-delete"
    CADDYFILE="$CADDY_CONFIG_DIR/Caddyfile"
    CADDY_SITES_DIR="$CADDY_CONFIG_DIR/sites.d"
    CADDY_LOG_DIR="$CADDY_CONFIG_DIR/log"
    CADDY_DATA_DIR="$CADDY_CONFIG_DIR/data"
    CADDY_STATE_DIR="$CADDY_CONFIG_DIR/state"
    CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
    mkdir -p "$CADDY_SITES_DIR" "$CADDY_STATE_DIR"
    printf 'import %s/*.caddy\n' "$CADDY_SITES_DIR" > "$CADDYFILE"
    caddy_render_proxy_site 'managed.example.com' '127.0.0.1:8080' 'managed.example.com' \
        > "$CADDY_SITES_DIR/managed.example.com.caddy"
    printf 'external.example.com {\n    respond "external"\n}\n' > "$CADDY_SITES_DIR/external.caddy"
    confirm_change_preview() { return 0; }
    caddy_validate() { return 0; }
    svc_is_active() { return 1; }
    caddy_backup_before_change() { :; }
    audit_action() { :; }
    caddy_delete_site >/dev/null <<'EOF'
1
EOF
    [ ! -e "$CADDY_SITES_DIR/managed.example.com.caddy" ] \
        || { echo "Caddy managed site was not deleted" >&2; exit 1; }
    grep -qF 'external.example.com {' "$CADDY_SITES_DIR/external.caddy" \
        || { echo "Caddy deletion touched an external site file" >&2; exit 1; }
    :
}
run_test "Caddy managed site was not deleted" t_sm_028

BANNER_WIDE=$(COLUMNS=80 NO_COLOR=1 quench_art_banner)
t_top_019() {
    [[ "$BANNER_WIDE" = *'██████╗ ██╗   ██╗███████╗'* && "$BANNER_WIDE" = *'╚══▀▀═╝'* ]] || { echo "Wide QUENCH banner is missing" >&2; exit 1; }
    :
}
run_test "Wide QUENCH banner is missing" t_top_019
BANNER_COMPACT=$(COLUMNS=60 NO_COLOR=1 quench_art_banner)
t_top_020() {
    [[ "$BANNER_COMPACT" = *'██████╗ ██╗   ██╗███████╗'* && "$BANNER_COMPACT" = *'╚══▀▀═╝'* ]] || { echo "Compact QUENCH banner is missing" >&2; exit 1; }
    [[ "$(COLUMNS=40 NO_COLOR=1 quench_art_banner)" = *'QUENCH'* ]] || { echo "Narrow QUENCH banner fallback is missing" >&2; exit 1; }
    [[ "$(app_header_line)" = *'VPS INIT/MANAGEMENT TOOLS  ·  V0.1.0  ·  Boyang'* ]] || { echo "QUENCH header line is wrong" >&2; exit 1; }
    [ "$(vis_len '用户管理')" = 8 ] || { echo "CJK width is wrong" >&2; exit 1; }
    [ "$(vis_len 'abc')" = 3 ] || { echo "ASCII width is wrong" >&2; exit 1; }
    [ "$(vis_len '')" = 0 ] || { echo "Empty string width is wrong" >&2; exit 1; }
    [ "$(vis_len '1  Fail2ban 管理')" = 16 ] || { echo "Mixed CJK/ASCII width is wrong" >&2; exit 1; }
    [ "$(vis_len '中英mix混排')" = 11 ] || { echo "Interleaved CJK/ASCII width is wrong" >&2; exit 1; }
    [ "$(vis_len '带全角标点：，（）')" = 18 ] || { echo "Fullwidth punctuation width is wrong" >&2; exit 1; }
    [ "$(vis_len '●  用户  3')" = 10 ] || { echo "Ambiguous-width symbol counted as wide" >&2; exit 1; }
    ! grep -q 'python3' <(sed -n '/^vis_len() {/,/^}/p' "$ROOT/src/lib/core.sh") \
        || { echo "vis_len still shells out to python3" >&2; exit 1; }
    grep -q 'sshd_effective_reload' <(sed -n '/^main_menu() {/,/^}/p' "$ROOT/src/modules/main.sh") \
        || { echo "main_menu no longer primes the sshd cache in the parent shell" >&2; exit 1; }
    [ "$(QUENCH_TEST_MODE=0 "$ROOT/vps-quench.sh" --version)" = "Quench $APP_VERSION" ] \
        || { echo "--version did not report the app version" >&2; exit 1; }
    :
}
run_test "Compact QUENCH banner is missing …+12 项" t_top_020
QUENCH_TEST_MODE=0 "$ROOT/vps-quench.sh" --help >/dev/null 2>&1 \
    || { echo "--help stopped working" >&2; exit 1; }
t_top_021() {
    grep -qE '^    \*\)' <(sed -n '/^# CLI 处理/,/^esac/p' "$ROOT/src/modules/main.sh") \
        || { echo "CLI dispatcher lost its unknown-argument catch-all" >&2; exit 1; }
    :
}
run_test "CLI dispatcher lost its unknown-argument catch-all" t_top_021

# An unbraced $VAR directly followed by a multi-byte character loses its first byte on
# libcs whose UTF-8 locale reports high bytes as alnum (reproducible on macOS), so the
# variable silently expands to nothing. Every such site must use ${VAR}.
QUOTE_TAB=$(printf '\t')
if LC_ALL=C grep -rlE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~${QUOTE_TAB}]" "$ROOT/src" | grep -q .; then
    echo "Unbraced \$VAR is followed by a multi-byte character; use \${VAR}:" >&2
    LC_ALL=C grep -rnE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~${QUOTE_TAB}]" "$ROOT/src" >&2
    exit 1
fi
t_top_022() {
    [[ "$QUENCH_MANIFEST_URL" = 'https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.manifest.json' ]] || { echo "Update-check manifest URL points outside vps-quench" >&2; exit 1; }
    [[ "$GITHUB_REF_URL" = 'https://api.github.com/repos/boyang-hu/vps-quench/git/ref/heads/main' ]] || { echo "Self-update GitHub API URL points outside vps-quench" >&2; exit 1; }
    :
}
run_test "Update-check manifest URL points outside vps-quench …+1 项" t_top_022

t_top_023() {
    for fn in bbr_preflight bbr_runtime_snapshot bbr_ensure_baseline bbr_restore_runtime_snapshot bbr_restore_initial_baseline bbr_baseline_value bbr_config_has_key bbr_config_value \
        bbr_apply_sysctl bbr_generate_config bbr_physical_memory_mb bbr_effective_memory_mb bbr_buffer_cap_bytes bbr_conntrack_max_for_memory bbr_bdp_mb bbr_buffer_target_bytes bbr_recommend_profile \
        bbr_kernel_at_least bbr_initial_or_current_value bbr_capacity_floor bbr_port_range_union bbr_tcp_fastopen_value \
        bbr_nft_forwarding_family_active bbr_scene_key_owned_by_nft \
        bbr_tc_qdisc_safe_to_replace bbr_tc_current_rate bbr_tc_owned_rate bbr_tc_rate_token_mbps bbr_tc_rate_mbps_from_output bbr_tc_rate_matches bbr_tc_burst_kb bbr_tc_saved_values bbr_tc_saved_rate_display bbr_tc_rate_display \
        bbr_tc_topology_matches bbr_tc_persistence_current bbr_tc_reconcile_saved \
        bbr_tc_snapshot_foreign bbr_tc_force_confirm bbr_tc_remove_confirm bbr_tc_apply_runtime bbr_parse_bandwidth_mbps bbr_shaping_rate_mbps bbr_calibration_host_valid bbr_calibration_margin bbr_calibration_estimate_gb bbr_calibration_loss_pct bbr_calibration_is_spike bbr_calibration_parse_iperf bbr_calibration_mq_leaves bbr_calibration_mq_addressable_major bbr_calibration_run bbr_menu_calibration bbr_default_routes bbr_route_token \
        bbr_route_strip_cwnd bbr_apply_initcwnd_route bbr_restore_initcwnd_route bbr_remove_initcwnd quench_tcp_profile; do
        declare -F "$fn" >/dev/null || { echo "Missing BBR function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing BBR function: \$fn" t_top_023

BBR_BASELINE_FILE="$TMP/bbr-baseline.conf"
cat > "$BBR_BASELINE_FILE" <<'EOF'
netXipv4Xip_forward = 9
net.ipv4.ip_forward = 1
net.core.somaxconn = 4096
EOF
t_top_024() {
    [[ "$(bbr_baseline_value net.ipv4.ip_forward)" = "1" ]] || { echo "BBR baseline key matching was not exact" >&2; exit 1; }
    [[ "$(bbr_config_dynamic_scene_keys 'net.ipv6.conf.eth9.accept_ra = 2')" = net.ipv6.conf.eth9.accept_ra ]] || { echo "BBR old IPv6 interface cleanup key was not detected" >&2; exit 1; }
    :
}
run_test "BBR baseline key matching was not exact …+1 项" t_top_024
t_sm_029() {
    NFT_RULES_FILE="$TMP/nft-forwarding-rules.db"
    cat > "$NFT_RULES_FILE" <<'EOF'
1|ipv4|tcp||443|443|ip|192.0.2.10|192.0.2.10|443|443|single|masquerade|off|yes|test-v4
2|ipv6|udp||443|443|ip|2001:db8::10|2001:db8::10|443|443|single|preserve|off|no|test-v6-disabled
EOF
    bbr_nft_forwarding_family_active ipv4 || { echo "BBR did not detect active IPv4 forwarding ownership" >&2; exit 1; }
    ! bbr_nft_forwarding_family_active ipv6 || { echo "BBR claimed disabled IPv6 forwarding ownership" >&2; exit 1; }
    bbr_scene_key_owned_by_nft net.ipv4.ip_forward || { echo "BBR could restore NFT-owned IPv4 forwarding" >&2; exit 1; }
    ! bbr_scene_key_owned_by_nft net.ipv6.conf.eth0.accept_ra || { echo "BBR claimed inactive IPv6 RA ownership" >&2; exit 1; }
    sed -i.bak 's/|no|test-v6-disabled$/|yes|test-v6-enabled/' "$NFT_RULES_FILE"
    bbr_scene_key_owned_by_nft net.ipv6.conf.eth0.accept_ra || { echo "BBR could restore NFT-owned IPv6 RA" >&2; exit 1; }
    ! bbr_scene_key_owned_by_nft net.core.somaxconn || { echo "BBR assigned unrelated sysctl ownership to NFT" >&2; exit 1; }
    :
}
run_test "BBR did not detect active IPv4 forwarding ownership" t_sm_029
BBR_RESTORE_LOG="$TMP/bbr-restore.log"
# shellcheck disable=SC2329 # test stub used indirectly by bbr_restore_baseline_key
sysctl() {
    [ "${1:-}" = -w ] && printf '%s\n' "$2" >> "$BBR_RESTORE_LOG"
}
bbr_restore_baseline_key net.core.somaxconn
t_top_025() {
    grep -qx 'net.core.somaxconn=4096' "$BBR_RESTORE_LOG" || { echo "BBR baseline restore used the wrong value" >&2; exit 1; }
    :
}
run_test "BBR baseline restore used the wrong value" t_top_025
unset -f sysctl

t_sm_030() {
    BBR_BASELINE_FILE="$TMP/bbr-growing-baseline.conf"
    printf 'net.ipv4.ip_forward = 0\n' > "$BBR_BASELINE_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    bbr_managed_keys() { printf '%s\n' net.ipv4.ip_forward net.ipv6.conf.eth0.accept_ra; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_ensure_baseline
    sysctl() {
        [ "${1:-}" = -n ] && [ "${2:-}" = net.ipv6.conf.eth0.accept_ra ] && echo 1
    }
    bbr_ensure_baseline
    [[ "$(bbr_baseline_value net.ipv4.ip_forward)" = 0 ]] || { echo "BBR baseline overwrote an existing value" >&2; exit 1; }
    [[ "$(bbr_baseline_value net.ipv6.conf.eth0.accept_ra)" = 1 ]] || { echo "BBR baseline did not capture a newly managed interface" >&2; exit 1; }
    :
}
run_test "BBR baseline overwrote an existing value" t_sm_030
t_sm_031() {
    SYSCTL_FILE="$TMP/bbr-initial-restore.conf"
    BBR_BASELINE_FILE="$TMP/bbr-initial-restore-baseline.conf"
    TC_STATE_FILE="$TMP/no-restore-tc.state"
    TC_HELPER="$TMP/no-restore-tc-helper"
    SERVICE_TC="$TMP/no-restore-tc-service"
    SERVICE_TC_INIT="$TMP/no-restore-tc-init"
    CWND_STATE_FILE="$TMP/no-restore-cwnd.state"
    CWND_HELPER="$TMP/no-restore-cwnd-helper"
    SERVICE_CWND="$TMP/no-restore-cwnd-service"
    SERVICE_CWND_INIT="$TMP/no-restore-cwnd-init"
    printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$SYSCTL_FILE"
    printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$BBR_BASELINE_FILE"
    BACKUP_MARKER="$TMP/bbr-initial-restore-backup"
    RESTORE_MARKER="$TMP/bbr-initial-restore-runtime"
    bbr_backup_sysctl() { : > "$BACKUP_MARKER"; }
    bbr_restore_runtime_snapshot() { printf '%s|%s\n' "$1" "${2:-}" > "$RESTORE_MARKER"; }
    bbr_restore_initial_baseline >/dev/null <<'EOF'
y
EOF
    [ -f "$BACKUP_MARKER" ] || { echo "BBR initial restore skipped its safety backup" >&2; exit 1; }
    grep -qx "$BBR_BASELINE_FILE|respect_nft" "$RESTORE_MARKER" || { echo "BBR initial restore did not preserve NFT-owned forwarding" >&2; exit 1; }
    [ ! -e "$SYSCTL_FILE" ] && [ ! -e "$BBR_BASELINE_FILE" ] \
        || { echo "BBR initial restore left managed persistence behind" >&2; exit 1; }
    :
}
run_test "BBR initial restore skipped its safety backup" t_sm_031
t_sm_032() {
    NFT_RULES_FILE="$TMP/bbr-restore-nft-rules.db"
    printf '%s\n' '1|ipv4|tcp||443|443|ip|192.0.2.10|192.0.2.10|443|443|single|masquerade|off|yes|active' > "$NFT_RULES_FILE"
    SNAPSHOT="$TMP/bbr-respect-nft.snapshot"
    printf '%s\n' 'net.ipv4.ip_forward = 0' 'net.core.somaxconn = 1024' > "$SNAPSHOT"
    RESTORE_LOG="$TMP/bbr-respect-nft.log"
    sysctl() { [ "${1:-}" = -w ] && printf '%s\n' "$2" >> "$RESTORE_LOG"; }
    bbr_restore_runtime_snapshot "$SNAPSHOT" respect_nft >/dev/null
    ! grep -q '^net.ipv4.ip_forward=' "$RESTORE_LOG" \
        || { echo "BBR baseline restore disabled active NFT forwarding" >&2; exit 1; }
    grep -qx 'net.core.somaxconn=1024' "$RESTORE_LOG" \
        || { echo "BBR NFT-aware restore skipped an unrelated parameter" >&2; exit 1; }
    :
}
run_test "BBR baseline restore disabled active NFT forwarding" t_sm_032
t_sm_033() {
    TC_STATE_FILE="$TMP/active-tc.state"
    TC_BIN="$TMP/active-tc"
    printf 'DEV=eth0\nRATE=1100\nBURST_KB=1100\nFORCE=0\n' > "$TC_STATE_FILE"
    cat > "$TC_BIN" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    printf '%s\n' \
        'qdisc htb 1: root refcnt 3 r2q 10 default 0x10 direct_packets_stat 0 direct_qlen 1000' \
        'qdisc fq 100: parent 1:10 limit 10000p flow_limit 100p buckets 1024 maxrate 1100Mbit low_rate_threshold 550Kbit'
elif [ "$1 $2" = "class show" ]; then
    echo 'class htb 1:10 root prio 0 rate 1100Mbit ceil 1100Mbit burst 1126400b cburst 1126400b'
fi
EOF
    chmod +x "$TC_BIN"
    [[ "$(bbr_tc_rate_display eth0 "$TC_BIN")" = "1100Mbit" ]] \
        || { echo "BBR active owned qdisc was shown as saved or inactive" >&2; exit 1; }
    :
}
run_test "BBR active owned qdisc was shown as saved or inactive" t_sm_033

t_sm_034() {
    SYSCTL_FILE="$TMP/bbr-sysctl.conf"
    BBR_BASELINE_FILE="$TMP/bbr-transaction-baseline.conf"
    printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FILE"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    ensure_sysctl() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_ensure_baseline() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    bbr_runtime_snapshot() {
        printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$1"
    }
    bbr_kernel_at_least() { return 1; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_sysctl
    sysctl() {
        case "${1:-} ${2:-}" in
            '-w net.core.default_qdisc=fq') return 1 ;;
            '-n net.ipv4.tcp_congestion_control') echo bbr ;;
            '-n net.core.default_qdisc') echo fq ;;
            *) return 0 ;;
        esac
    }
    CONFIG=$(printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr')
    if bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1; then
        echo "BBR fq sysctl failure returned success" >&2
        exit 1
    fi
    grep -qx 'net.ipv4.tcp_congestion_control = cubic' "$SYSCTL_FILE" || {
        echo "BBR failed apply replaced the previous persistent config" >&2
        exit 1
    }
    :
}
run_test "BBR fq sysctl failure returned success" t_sm_034

t_sm_035() {
    SYSCTL_FILE="$TMP/bbr-readback-sysctl.conf"
    BBR_BASELINE_FILE="$TMP/bbr-readback-baseline.conf"
    printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FILE"
    ROLLBACK_LOG="$TMP/bbr-readback-rollback.log"
    ensure_sysctl() { :; }
    bbr_ensure_baseline() { :; }
    bbr_runtime_snapshot() {
        printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$1"
    }
    sysctl() {
        case "${1:-} ${2:-}" in
            '-n net.ipv4.tcp_congestion_control') echo bbr ;;
            '-n net.core.default_qdisc') echo fq_codel ;;
            '-w net.core.default_qdisc=fq_codel'|'-w net.ipv4.tcp_congestion_control=cubic') printf '%s\n' "$2" >> "$ROLLBACK_LOG" ;;
            *) return 0 ;;
        esac
    }
    bbr_kernel_at_least() { return 0; }
    CONFIG=$(printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr')
    bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1 \
        || { echo "Modern BBR rejected a non-fatal fq readback mismatch" >&2; exit 1; }
    [ ! -s "$ROLLBACK_LOG" ] || { echo "Modern BBR rolled back after a non-fatal fq mismatch" >&2; exit 1; }
    grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$SYSCTL_FILE" \
        || { echo "Modern BBR did not persist congestion control after fq warning" >&2; exit 1; }
    :
}
run_test "Modern BBR rejected a non-fatal fq readback mismatch" t_sm_035

t_sm_036() {
    PREFLIGHT_CALLED=0
    BACKUP_CALLED=0
    # shellcheck disable=SC2329 # test stub used indirectly by quench_tcp_profile
    bbr_preflight() { PREFLIGHT_CALLED=1; return 1; }
    # shellcheck disable=SC2329 # must stay uncalled when preflight fails
    bbr_backup_sysctl() { BACKUP_CALLED=1; }
    if quench_tcp_profile balanced >/dev/null 2>&1; then
        echo "BBR smart profile ignored a failed preflight" >&2
        exit 1
    fi
    [ "$PREFLIGHT_CALLED" -eq 1 ] || { echo "BBR smart profile skipped preflight" >&2; exit 1; }
    [ "$BACKUP_CALLED" -eq 0 ] || { echo "BBR smart profile changed state after failed preflight" >&2; exit 1; }
    :
}
run_test "BBR smart profile ignored a failed preflight" t_sm_036

t_sm_037() {
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_generate_config
    bbr_default_ipv6_iface() { echo eth0; }
    bbr_physical_memory_mb() { echo 512; }
    BBR_BASELINE_FILE="$TMP/bbr-config-baseline.conf"
    printf '%s\n' \
        'net.ipv4.tcp_fastopen = 8' \
        'net.core.somaxconn = 16384' \
        'net.ipv4.udp_rmem_min = 32768' \
        'net.ipv4.ip_local_port_range = 20000 60000' > "$BBR_BASELINE_FILE"
    CONFIG=$(bbr_generate_config 12582912 12582912 131072 relay 0)
    grep -qx 'net.ipv4.tcp_rmem = 4096 131072 12582912' <<< "$CONFIG" || { echo "BBR receive defaults are unsafe" >&2; exit 1; }
    grep -qx 'net.ipv4.tcp_wmem = 4096 16384 12582912' <<< "$CONFIG" || { echo "BBR send defaults are unsafe" >&2; exit 1; }
    grep -qx 'net.core.somaxconn = 16384' <<< "$CONFIG" || { echo "BBR lowered a pre-existing proxy concurrency capacity" >&2; exit 1; }
    grep -qx 'net.ipv4.ip_local_port_range = 10000 65535' <<< "$CONFIG" || { echo "BBR did not preserve the union of the original port range" >&2; exit 1; }
    grep -qx 'net.ipv4.tcp_fastopen = 11' <<< "$CONFIG" || { echo "BBR erased existing TCP Fast Open feature bits" >&2; exit 1; }
    grep -qx 'net.ipv4.udp_rmem_min = 32768' <<< "$CONFIG" || { echo "BBR lowered the existing UDP receive guarantee" >&2; exit 1; }
    ! grep -qE '^(vm\.(swappiness|min_free_kbytes)|net\.ipv4\.(udp_wmem_min|tcp_mem|tcp_adv_win_scale|tcp_tw_reuse|tcp_fin_timeout|tcp_keepalive_time|tcp_ecn|tcp_slow_start_after_idle|tcp_fastopen_blackhole_timeout_sec))[[:space:]]*=' <<< "$CONFIG" \
        || { echo "BBR generated unsupported or risky TCP settings" >&2; exit 1; }
    ! grep -qE '^net\.ipv4\.ip_forward[[:space:]]*=' <<< "$CONFIG" || { echo "BBR enabled forwarding without consent" >&2; exit 1; }
    ! grep -qE '^net\.netfilter\.nf_conntrack_max[[:space:]]*=' <<< "$CONFIG" || { echo "BBR tuned conntrack while forwarding was disabled" >&2; exit 1; }

    CONFIG=$(bbr_generate_config 12582912 12582912 131072 relay 1)
    grep -qx 'net.ipv6.conf.default.accept_ra = 2' <<< "$CONFIG" || { echo "BBR forwarding profile missing default IPv6 accept_ra=2" >&2; exit 1; }
    grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' <<< "$CONFIG" || { echo "BBR forwarding profile missing interface IPv6 accept_ra=2" >&2; exit 1; }
    grep -qx 'net.ipv4.ip_forward = 1' <<< "$CONFIG" || { echo "BBR forwarding profile missing IPv4 forwarding" >&2; exit 1; }
    CONNTRACK_VALUE=$(awk -F= '$1 ~ /net.netfilter.nf_conntrack_max/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "$CONFIG")
    [[ "$CONNTRACK_VALUE" =~ ^[0-9]+$ && "$CONNTRACK_VALUE" -ge 131072 ]] \
        || { echo "BBR conntrack limit ignored the 512MB floor or existing capacity" >&2; exit 1; }
    :
}
run_test "BBR receive defaults are unsafe" t_sm_037

t_top_026() {
    [[ "$(bbr_effective_memory_mb 16384 512)" = 512 ]] || { echo "BBR memory selection was not clamped to physical RAM" >&2; exit 1; }
    [[ "$(bbr_buffer_cap_bytes 512)" = 33554432 ]] || { echo "BBR mixed buffer cap is not 1/16 of RAM" >&2; exit 1; }
    [[ "$(bbr_buffer_cap_bytes 512 proxy)" = 16777216 ]] || { echo "BBR proxy buffer cap is not 1/32 of RAM" >&2; exit 1; }
    [[ "$(bbr_buffer_cap_bytes 16384 bulk)" = 268435456 ]] || { echo "BBR buffer cap ignored the 256MiB absolute ceiling" >&2; exit 1; }
    ! bbr_managed_keys | grep -qx 'vm.min_free_kbytes' || { echo "BBR must leave min_free_kbytes to the kernel" >&2; exit 1; }
    ! bbr_managed_keys | grep -qx 'vm.swappiness' || { echo "BBR must leave Swap policy to the Swap module" >&2; exit 1; }
    ! bbr_managed_keys | grep -qx 'net.ipv4.udp_wmem_min' || { echo "BBR must not manage ineffective udp_wmem_min" >&2; exit 1; }
    [[ "$(bbr_conntrack_max_for_memory 512)" = 131072 ]] || { echo "BBR 512MB conntrack tier is wrong" >&2; exit 1; }
    [[ "$(bbr_conntrack_max_for_memory 1024)" = 262144 ]] || { echo "BBR 1GB conntrack tier is wrong" >&2; exit 1; }
    [[ "$(bbr_conntrack_max_for_memory 2048)" = 524288 ]] || { echo "BBR 2GB conntrack tier is wrong" >&2; exit 1; }
    [[ "$(bbr_conntrack_max_for_memory 4096)" = 1048576 ]] || { echo "BBR 4GB conntrack tier is wrong" >&2; exit 1; }
    :
}
run_test "BBR memory selection was not clamped to physical RAM …+10 项" t_top_026

t_sm_038() {
    bbr_physical_memory_mb() { echo 512; }
    bbr_confirm_apply() { printf '%s %s %s\n' "$1" "$2" "$3"; }
    AUTO_RESULT=$(bbr_auto_calc 16384 250 10240 16GB+ 200ms以上 10Gbps)
    AUTO_PARAMS=$(tail -n 1 <<< "$AUTO_RESULT")
    [[ "$AUTO_PARAMS" = '33554432 33554432 262144' ]] \
        || { echo "BBR 512MB auto calculation trusted a 16GB selection: $AUTO_PARAMS" >&2; exit 1; }
    for PROFILE in balanced latency throughput relay landing line_landing; do
        PROFILE_PARAMS=$(quench_tcp_profile "$PROFILE" | tail -n 1)
        PROFILE_RMEM=${PROFILE_PARAMS%% *}
        PROFILE_CAP=$(bbr_buffer_cap_bytes 512 "$PROFILE")
        [ "$PROFILE_RMEM" -le "$PROFILE_CAP" ] \
            || { echo "BBR profile $PROFILE exceeded the physical-memory buffer cap" >&2; exit 1; }
    done
    :
}
run_test "BBR 512MB auto calculation trusted a 16GB selection: \$AUTO_PARAMS" t_sm_038

t_top_027() {
    bbr_tc_qdisc_safe_to_replace fq || { echo "BBR rejected a safe default qdisc" >&2; exit 1; }
    ! bbr_tc_qdisc_safe_to_replace cake || { echo "BBR would overwrite a foreign CAKE qdisc" >&2; exit 1; }
    :
}
run_test "BBR rejected a safe default qdisc …+1 项" t_top_027
t_sm_039() {
    TC_STATE_FILE="$TMP/mq-no-state"
    SERVICE_TC="$TMP/mq-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by tc service handling
    SERVICE_TC_INIT="$TMP/mq-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_restore_owned
    TC_HELPER="$TMP/mq-tc-helper"
    TC_TEST_LOG="$TMP/mq-tc.log"
    export TC_TEST_LOG
    FAKE_TC="$TMP/fake-mq-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    printf '%s\n' \
        'qdisc mq 0: root' \
        'qdisc fq 0: parent :1 limit 10000p flow_limit 100p'
    exit 0
fi
if [ "$1 $2" = "class show" ]; then exit 0; fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$FAKE_TC"
    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "未设置" ] \
        || { echo "BBR reported a rate for the default mq/fq topology" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 2200 2200 "$FAKE_TC" >/dev/null \
        || { echo "BBR could not replace an undeletable mq root qdisc" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "BBR did not use qdisc replace for an mq root" >&2; exit 1; }
    ! grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR tried to delete an undeletable mq root" >&2; exit 1; }
    :
}
run_test "BBR reported a rate for the default mq/fq topology" t_sm_039
t_sm_040() {
    TC_STATE_FILE="$TMP/saved-tc.state"
    TC_HELPER="$TMP/saved-tc-helper"
    SERVICE_TC="$TMP/saved-tc.service"
    SERVICE_TC_INIT="$TMP/saved-tc.init"
    TC_MARKER="$TMP/saved-tc-active"
    export TC_MARKER
    printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$TC_STATE_FILE"
    TC_BIN_DIR="$TMP/saved-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cat > "$TC_BIN_DIR/tc" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    if [ -f "$TC_MARKER" ]; then
        printf '%s\n' \
            'qdisc htb 1: root refcnt 3 default 0x10' \
            'qdisc fq 100: parent 1:10 limit 10000p maxrate 2200Mbit'
    else
        echo 'qdisc mq 0: root'
    fi
elif [ "$1 $2" = "class show" ] && [ -f "$TC_MARKER" ]; then
    echo 'class htb 1:10 root rate 2200Mbit ceil 2200Mbit'
fi
EOF
    chmod +x "$TC_BIN_DIR/tc"
    cat > "$TC_HELPER" <<'EOF'
#!/bin/sh
# QUENCH_TC_HELPER_VERSION=3
[ "${1:-}" = apply ] || exit 1
: > "$TC_MARKER"
EOF
    chmod +x "$TC_HELPER"
    PATH="$TC_BIN_DIR:$PATH"
    default_iface() { echo eth0; }
    [ "$(bbr_tc_rate_display eth0 "$TC_BIN_DIR/tc")" = "2200Mbit（已保存，未生效）" ] \
        || { echo "BBR did not expose an inactive saved tc rate" >&2; exit 1; }
    unset QUENCH_TEST_MODE BBR_TUNE_TEST_MODE
    bbr_tc_reconcile_saved >/dev/null \
        || { echo "BBR could not restore an inactive saved tc rate" >&2; exit 1; }
    [ -f "$TC_MARKER" ] || { echo "BBR tc reconciliation did not invoke the saved helper" >&2; exit 1; }
    [ "$(bbr_tc_rate_display eth0 "$TC_BIN_DIR/tc")" = "2200Mbit" ] \
        || { echo "BBR tc rate remained inactive after reconciliation" >&2; exit 1; }
    :
}
run_test "BBR did not expose an inactive saved tc rate" t_sm_040
t_sm_041() {
    TC_STATE_FILE="$TMP/stale-helper.state"
    TC_HELPER="$TMP/stale-helper"
    SERVICE_TC="$TMP/stale-helper.service"
    SERVICE_TC_INIT="$TMP/stale-helper.init"
    TC_MARKER="$TMP/stale-helper-active"
    PERSIST_MARKER="$TMP/stale-helper-refreshed"
    export TC_MARKER
    printf 'DEV=eth0\nRATE=780\nBURST_KB=780\nFORCE=0\n' > "$TC_STATE_FILE"
    cat > "$TC_HELPER" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$TC_HELPER"
    TC_BIN_DIR="$TMP/stale-helper-bin"
    mkdir -p "$TC_BIN_DIR"
    cat > "$TC_BIN_DIR/tc" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    if [ -f "$TC_MARKER" ]; then
        printf '%s\n' 'qdisc htb 1: root default 0x10' 'qdisc fq 100: parent 1:10 maxrate 780Mbit'
    else
        echo 'qdisc mq 0: root'
    fi
elif [ "$1 $2" = "class show" ]; then
    [ ! -f "$TC_MARKER" ] || echo 'class htb 1:10 root rate 780Mbit ceil 780Mbit'
elif [ "$1 $2 $3" = "qdisc replace dev" ]; then
    : > "$TC_MARKER"
fi
exit 0
EOF
    chmod +x "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    default_iface() { echo eth0; }
    bbr_tc_write_persistence() {
        printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$PERSIST_MARKER"
    }
    unset QUENCH_TEST_MODE BBR_TUNE_TEST_MODE
    bbr_tc_reconcile_saved >/dev/null \
        || { echo "BBR could not recover from a stale tc helper" >&2; exit 1; }
    [ -f "$TC_MARKER" ] || { echo "BBR reused a stale tc helper" >&2; exit 1; }
    grep -qx 'eth0 780 780 0' "$PERSIST_MARKER" \
        || { echo "BBR did not refresh stale tc persistence" >&2; exit 1; }
    :
}
run_test "BBR could not recover from a stale tc helper" t_sm_041
t_sm_042() {
    TC_STATE_FILE="$TMP/saved-other-interface.state"
    TC_HELPER="$TMP/saved-other-interface-helper"
    TC_MARKER="$TMP/saved-other-interface-called"
    export TC_MARKER
    printf 'DEV=eth9\nRATE=500\nBURST_KB=500\nFORCE=0\n' > "$TC_STATE_FILE"
    cat > "$TC_HELPER" <<'EOF'
#!/bin/sh
: > "$TC_MARKER"
EOF
    chmod +x "$TC_HELPER"
    default_iface() { echo eth0; }
    [ "$(bbr_tc_saved_rate_display eth0)" = "500Mbit（保存于 eth9，当前未生效）" ] \
        || { echo "BBR did not identify a saved rate from another interface" >&2; exit 1; }
    unset QUENCH_TEST_MODE BBR_TUNE_TEST_MODE
    ! bbr_tc_reconcile_saved >/dev/null \
        || { echo "BBR silently migrated tc state to another interface" >&2; exit 1; }
    [ ! -e "$TC_MARKER" ] || { echo "BBR invoked tc helper for the wrong interface" >&2; exit 1; }
    :
}
run_test "BBR did not identify a saved rate from another interface" t_sm_042
t_sm_043() {
    # shellcheck disable=SC2034 # consumed by bbr_tc_is_owned
    TC_STATE_FILE="$TMP/no-tc-state"
    TC_BACKUP_DIR="$TMP/tc-backups"
    SERVICE_TC="$TMP/foreign-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_remove_tc
    SERVICE_TC_INIT="$TMP/foreign-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_remove_tc
    TC_HELPER="$TMP/foreign-tc-helper"
    TC_TEST_LOG="$TMP/tc-test.log"
    export TC_TEST_LOG
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v by bbr_remove_tc
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    rc-service() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    FAKE_TC="$TMP/fake-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    echo 'qdisc tbf 8001: root refcnt 2 rate 1024Mbit burst 1Mb lat 50ms'
    exit 0
fi
if [ "$1 $2" = "class show" ]; then
    echo 'class tbf 8001:1 root'
    exit 0
fi
if [ "$1 $2" = "filter show" ]; then
    echo 'filter parent 8001: protocol ip pref 1 u32 chain 0'
    exit 0
fi
if [ "$1 $2 $3" = "-j qdisc show" ]; then
    echo '[{"kind":"tbf","root":true}]'
    exit 0
fi
if [ "$1 $2 $3" = "-j class show" ]; then
    echo '[{"kind":"tbf","classid":"8001:1"}]'
    exit 0
fi
if [ "$1 $2 $3" = "-j filter show" ]; then
    echo '[{"kind":"u32","parent":"8001:"}]'
    exit 0
fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
EOF
    chmod +x "$FAKE_TC"
    TC_BIN_DIR="$TMP/foreign-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "1024Mbit（外部 tbf）" ] \
        || { echo "BBR did not label a foreign tbf rate" >&2; exit 1; }
    APPLY_RC=0
    bbr_tc_apply_runtime eth0 100 100 "$FAKE_TC" >/dev/null 2>&1 || APPLY_RC=$?
    if [ "$APPLY_RC" -ne 2 ]; then
        echo "BBR accepted a foreign root qdisc" >&2
        exit 1
    fi
    [ ! -s "$TC_TEST_LOG" ] || { echo "BBR modified a foreign root qdisc" >&2; exit 1; }

    REMOVE_RC=0
    bbr_remove_tc >/dev/null 2>&1 || REMOVE_RC=$?
    [ "$REMOVE_RC" -eq 2 ] || { echo "BBR cancel did not identify the foreign tbf" >&2; exit 1; }
    [ ! -s "$TC_TEST_LOG" ] || { echo "BBR cancel deleted a foreign tbf without confirmation" >&2; exit 1; }
    if bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
DELETE eth1
EOF
    then
        echo "BBR accepted an incorrect foreign qdisc deletion confirmation" >&2
        exit 1
    fi
    bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null <<'EOF'
DELETE eth0
EOF
    bbr_remove_tc 1 >/dev/null \
        || { echo "BBR refused to delete a confirmed foreign tbf" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR did not delete the confirmed foreign tbf" >&2; exit 1; }
    REMOVE_SNAPSHOT=$(find "$TC_BACKUP_DIR" -type f -name 'eth0_*.txt' -print -quit)
    [ -n "$REMOVE_SNAPSHOT" ] && grep -qF 'qdisc tbf 8001: root' "$REMOVE_SNAPSHOT" \
        || { echo "BBR did not snapshot the foreign tbf before deletion" >&2; exit 1; }
    : > "$TC_TEST_LOG"
    rm -rf "$TC_BACKUP_DIR"

    if bbr_tc_force_confirm eth0 100 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
FORCE eth1
EOF
    then
        echo "BBR accepted an incorrect force confirmation" >&2
        exit 1
    fi
    bbr_tc_force_confirm eth0 100 "$FAKE_TC" >/dev/null <<'EOF'
FORCE eth0
EOF

    bbr_tc_apply_runtime eth0 100 100 "$FAKE_TC" 1 >/dev/null \
        || { echo "BBR refused an explicitly authorized foreign qdisc takeover" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not delete the foreign root qdisc" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its root qdisc" >&2; exit 1; }
    grep -qx 'class add dev eth0 parent 1: classid 1:10 htb rate 100mbit ceil 100mbit burst 100kb cburst 100kb' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its shaping class" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 parent 1:10 handle 100: fq maxrate 100mbit' "$TC_TEST_LOG" \
        || { echo "BBR force takeover did not install its fq leaf" >&2; exit 1; }
    SNAPSHOT=$(find "$TC_BACKUP_DIR" -type f -name 'eth0_*.txt' -print -quit)
    [ -n "$SNAPSHOT" ] || { echo "BBR force takeover did not save a tc snapshot" >&2; exit 1; }
    grep -qF 'qdisc tbf 8001: root' "$SNAPSHOT" \
        && grep -qF 'class tbf 8001:1 root' "$SNAPSHOT" \
        && grep -qF 'filter parent 8001:' "$SNAPSHOT" \
        && grep -qF '"kind":"tbf"' "$SNAPSHOT" \
        || { echo "BBR tc snapshot omitted qdisc/class/filter diagnostics" >&2; exit 1; }
    :
}
run_test "BBR did not label a foreign tbf rate" t_sm_043
t_top_028() {
    [[ "$(bbr_route_token 'default dev eth0 proto static metric 100' dev)" = eth0 ]] || { echo "BBR direct default route device parsing failed" >&2; exit 1; }
    [[ -z "$(bbr_route_token 'default dev eth0 proto static metric 100' via)" ]] || { echo "BBR direct default route invented a gateway" >&2; exit 1; }
    [[ "$(bbr_route_strip_cwnd 'default via 192.0.2.1 dev eth0 metric 100 initcwnd 50 initrwnd 50')" = 'default via 192.0.2.1 dev eth0 metric 100' ]] || { echo "BBR initcwnd route cleanup failed" >&2; exit 1; }
    :
}
run_test "BBR direct default route device parsing failed …+2 项" t_top_028
t_sm_044() {
    ROUTE_CALL="$TMP/bbr-route-call"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_apply_initcwnd_route
    ip() { printf '%s\n' "$*" > "$ROUTE_CALL"; }
    bbr_apply_initcwnd_route 4 'default dev eth0 proto static metric 100' 50
    grep -qx -- '-4 route replace default dev eth0 proto static metric 100 initcwnd 50' "$ROUTE_CALL" || {
        echo "BBR direct route initcwnd application was malformed" >&2
        exit 1
    }
    bbr_apply_initcwnd_route 6 'default dev eth0 metric 100' 50 25
    grep -qx -- '-6 route replace default dev eth0 metric 100 initcwnd 50 initrwnd 25' "$ROUTE_CALL" || {
        echo "BBR optional initrwnd application was malformed" >&2
        exit 1
    }
    bbr_restore_initcwnd_route 6 'default dev eth0 metric 100 initcwnd 50 initrwnd 25'
    grep -qx -- '-6 route replace default dev eth0 metric 100' "$ROUTE_CALL" || {
        echo "BBR initcwnd restore did not remove route attributes" >&2
        exit 1
    }
    :
}
run_test "BBR direct route initcwnd application was malformed" t_sm_044
t_top_029() {
    [[ "$(bbr_parse_bandwidth_mbps 400)" = 400 ]] || { echo "tc parser rejected bare Mbps" >&2; exit 1; }
    [[ "$(bbr_parse_bandwidth_mbps '600M')" = 600 ]] || { echo "tc parser rejected M suffix" >&2; exit 1; }
    [[ "$(bbr_parse_bandwidth_mbps '1.5G')" = 1500 ]] || { echo "tc parser does not use decimal Gbit units" >&2; exit 1; }
    [[ "$(bbr_parse_bandwidth_mbps '2.5 Gbps')" = 2500 ]] || { echo "tc parser rejected spaced Gbps input" >&2; exit 1; }
    ! bbr_parse_bandwidth_mbps '50MB/s' >/dev/null 2>&1 || { echo "tc parser accepted bytes-per-second input" >&2; exit 1; }
    ! bbr_parse_bandwidth_mbps '100.1G' >/dev/null 2>&1 || { echo "tc parser accepted an unsafe bandwidth bound" >&2; exit 1; }
    [[ "$(bbr_shaping_rate_mbps 400 97)" = 388 ]] || { echo "tc smart ratio calculation is wrong" >&2; exit 1; }
    [[ "$(bbr_bdp_mb 100 50)" != "0.00" ]] || { echo "BBR BDP estimate was truncated to zero" >&2; exit 1; }
    [[ "$(bbr_buffer_target_bytes 100 50)" = "3407872" ]] || { echo "BBR exact 2x-BDP plus headroom calculation failed" >&2; exit 1; }
    [[ "$(bbr_tc_burst_kb 100)" = 49 ]] || { echo "tc 4ms burst calculation is wrong at 100M" >&2; exit 1; }
    [[ "$(bbr_tc_burst_kb 400)" = 196 ]] || { echo "tc 4ms burst calculation is wrong at 400M" >&2; exit 1; }
    [[ "$(bbr_tc_rate_token_mbps 1Gbit)" = 1000.000000 ]] || { echo "tc Gbit rate normalization failed" >&2; exit 1; }
    [[ "$(bbr_tc_rate_token_mbps 500Kbit)" = 0.500000 ]] || { echo "tc Kbit rate normalization failed" >&2; exit 1; }
    [[ "$(bbr_calibration_margin 600)" = 15 ]] || { echo "calibration percentage margin is wrong" >&2; exit 1; }
    [[ "$(bbr_calibration_estimate_gb 1000 8)" = 50.0 ]] || { echo "calibration traffic estimate changed unexpectedly" >&2; exit 1; }
    bbr_calibration_host_valid iperf.example.com || { echo "calibration rejected a hostname" >&2; exit 1; }
    bbr_calibration_host_valid 2001:db8::10 || { echo "calibration rejected an IPv6 literal" >&2; exit 1; }
    ! bbr_calibration_host_valid '-c' || { echo "calibration accepted an option-like peer" >&2; exit 1; }
    ! bbr_calibration_host_valid 'host;reboot' || { echo "calibration accepted shell metacharacters" >&2; exit 1; }
    :
}
run_test "tc parser rejected bare Mbps …+18 项" t_top_029
IPERF_SAMPLE="$TMP/iperf-sample.txt"
printf '%s\n' \
    '[  5]   0.00-8.00   sec   900 MBytes   944 Mbits/sec  12             sender' \
    '[  5]   0.00-8.00   sec   892 MBytes   935 Mbits/sec                  receiver' \
    > "$IPERF_SAMPLE"
t_top_030() {
    [[ "$(bbr_calibration_parse_iperf "$IPERF_SAMPLE" 1)" = '944 12 935' ]] \
        || { echo "calibration could not parse single-stream iperf3 output" >&2; exit 1; }
    :
}
run_test "calibration could not parse single-stream iperf3 output" t_top_030
printf '%s\n' \
    '[SUM]   0.00-8.00   sec  1.80 GBytes  1930 Mbits/sec  42             sender' \
    '[SUM]   0.00-8.00   sec  1.78 GBytes  1910 Mbits/sec                 receiver' \
    > "$IPERF_SAMPLE"
t_top_031() {
    [[ "$(bbr_calibration_parse_iperf "$IPERF_SAMPLE" 4)" = '1930 42 1910' ]] \
        || { echo "calibration could not parse multi-stream iperf3 output" >&2; exit 1; }
    :
}
run_test "calibration could not parse multi-stream iperf3 output" t_top_031
RATE_TC="$TMP/rate-readback-tc"
cat > "$RATE_TC" <<'EOF'
#!/bin/sh
[ "$1 $2" = 'class show' ] && echo 'class htb 1:10 root rate 1Gbit ceil 1Gbit'
EOF
chmod +x "$RATE_TC"
t_top_032() {
    bbr_tc_rate_matches eth0 "$RATE_TC" 1000 || { echo "tc readback rejected equivalent Gbit output" >&2; exit 1; }
    ! bbr_tc_rate_matches eth0 "$RATE_TC" 900 || { echo "tc readback accepted a mismatched rate" >&2; exit 1; }
    :
}
run_test "tc readback rejected equivalent Gbit output …+1 项" t_top_032
t_sm_045() {
    GUARD_TC="$TMP/calibration-qdisc-guard-tc"
    cat > "$GUARD_TC" <<'EOF'
#!/bin/sh
echo 'qdisc cake 8001: root refcnt 2 bandwidth 1Gbit besteffort'
EOF
    chmod +x "$GUARD_TC"
    bbr_tc_is_owned() { return 1; }
    ! bbr_calibration_capture_qdisc eth0 "$GUARD_TC" >/dev/null 2>&1 \
        || { echo "calibration qdisc guard accepted external CAKE" >&2; exit 1; }
    :
}
run_test "calibration qdisc guard accepted external CAKE" t_sm_045
t_sm_046() {
    GUARD_TC="$TMP/calibration-mq-guard-tc"
    cat > "$GUARD_TC" <<'EOF'
#!/bin/sh
printf '%s\n' \
    'qdisc mq 0: root' \
    'qdisc cake 8001: parent :1 bandwidth 1Gbit besteffort'
EOF
    chmod +x "$GUARD_TC"
    bbr_tc_is_owned() { return 1; }
    ! bbr_calibration_capture_qdisc eth0 "$GUARD_TC" >/dev/null 2>&1 \
        || { echo "calibration qdisc guard accepted an external mq leaf" >&2; exit 1; }
    :
}
run_test "calibration qdisc guard accepted an external mq leaf" t_sm_046
t_sm_047() {
    MQ_TC="$TMP/calibration-mq-addressable-tc"
    MQ_STATE="$TMP/calibration-mq-addressable.state"
    MQ_LOG="$TMP/calibration-mq-addressable.log"
    export MQ_STATE MQ_LOG
    cat > "$MQ_TC" <<'EOF'
#!/bin/sh
if [ "$*" = 'qdisc show dev eth0' ]; then
    if [ -f "$MQ_STATE" ]; then
        printf '%s\n' 'qdisc mq 1: root' 'qdisc fq_codel 0: parent 1:1'
    else
        printf '%s\n' 'qdisc mq 0: root' 'qdisc fq_codel 0: parent :1'
    fi
elif [ "$*" = 'qdisc replace dev eth0 root handle 1: mq' ]; then
    : > "$MQ_STATE"
    printf '%s\n' "$*" >> "$MQ_LOG"
elif [ "$*" = 'qdisc replace dev eth0 parent 1:1 fq' ]; then
    printf '%s\n' "$*" >> "$MQ_LOG"
else
    exit 1
fi
EOF
    chmod +x "$MQ_TC"
    bbr_tc_is_owned() { return 1; }
    bbr_calibration_capture_qdisc eth0 "$MQ_TC" \
        || { echo "calibration could not capture kernel mq leaves" >&2; exit 1; }
    [ "$BBR_CAL_QDISC_LEAVES" = '1|fq_codel' ] \
        || { echo "calibration did not normalize mq parent indexes" >&2; exit 1; }
    bbr_calibration_set_fq eth0 "$MQ_TC" \
        || { echo "calibration could not make mq leaves addressable" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: mq' "$MQ_LOG" \
        && grep -qx 'qdisc replace dev eth0 parent 1:1 fq' "$MQ_LOG" \
        || { echo "calibration addressed mq leaves through handle zero" >&2; exit 1; }
    :
}
run_test "calibration could not capture kernel mq leaves" t_sm_047
t_sm_048() {
    CAL_BIN="$TMP/calibration-no-knee-bin"
    mkdir -p "$CAL_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$CAL_BIN/tc"
    chmod +x "$CAL_BIN/tc"
    PATH="$CAL_BIN:$PATH"
    TC_STATE_FILE="$TMP/calibration-no-knee-tc.state"
    FINISHED=0 RESULT_STATUS="" APPLIED=0
    default_iface() { echo eth0; }
    bbr_calibration_lock_acquire() { :; }
    bbr_calibration_capture_qdisc() { BBR_CAL_QDISC_MODE=default; BBR_CAL_QDISC_TYPE=fq; }
    bbr_calibration_traffic_mark() { :; }
    bbr_calibration_set_fq() { :; }
    bbr_calibration_measure() {
        BBR_CAL_SENDER=505; BBR_CAL_RECEIVER=500; BBR_CAL_RETRANS=1; BBR_CAL_LOSS=0.0010
    }
    bbr_calibration_write_result() { RESULT_STATUS=$1; }
    bbr_calibration_finish() { trap - INT TERM HUP; FINISHED=1; }
    bbr_tc_apply_selected_rate() { APPLIED=1; }
    bbr_calibration_run test.example 5201 4 500 8 >/dev/null \
        || { echo "clean calibration path returned failure" >&2; exit 1; }
    [ "$RESULT_STATUS" = NO_KNEE ] && [ "$FINISHED" -eq 1 ] && [ "$APPLIED" -eq 0 ] \
        || { echo "clean calibration invented a policer or skipped cleanup" >&2; exit 1; }
    :
}
run_test "clean calibration path returned failure" t_sm_048
t_sm_049() {
    CAL_BIN="$TMP/calibration-knee-bin"
    mkdir -p "$CAL_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$CAL_BIN/tc"
    chmod +x "$CAL_BIN/tc"
    PATH="$CAL_BIN:$PATH"
    TC_STATE_FILE="$TMP/calibration-knee-tc.state"
    CURRENT_RATE=0 FINISHED=0 RESULT_STATUS="" RESULT_KNEE="" RESULT_RECOMMEND="" APPLIED=0
    default_iface() { echo eth0; }
    sleep() { :; }
    bbr_calibration_lock_acquire() { :; }
    bbr_calibration_capture_qdisc() { BBR_CAL_QDISC_MODE=default; BBR_CAL_QDISC_TYPE=fq; }
    bbr_calibration_traffic_mark() { :; }
    bbr_calibration_set_fq() { :; }
    bbr_calibration_apply_shaper() { CURRENT_RATE=$2; }
    bbr_calibration_measure() {
        if [ "$CURRENT_RATE" -eq 0 ]; then
            BBR_CAL_SENDER=500; BBR_CAL_RECEIVER=480; BBR_CAL_RETRANS=9000; BBR_CAL_LOSS=2.0000
        elif [ "$CURRENT_RATE" -le 500 ]; then
            BBR_CAL_SENDER=$CURRENT_RATE; BBR_CAL_RECEIVER=$CURRENT_RATE; BBR_CAL_RETRANS=1; BBR_CAL_LOSS=0.0010
        else
            BBR_CAL_SENDER=$CURRENT_RATE; BBR_CAL_RECEIVER=480; BBR_CAL_RETRANS=9000; BBR_CAL_LOSS=2.0000
        fi
    }
    bbr_calibration_write_result() {
        RESULT_STATUS=$1; RESULT_KNEE=${7:-}; RESULT_RECOMMEND=${8:-}
    }
    bbr_calibration_finish() { trap - INT TERM HUP; FINISHED=1; }
    bbr_tc_apply_selected_rate() { APPLIED=1; }
    bbr_calibration_run test.example 5201 4 500 8 >/dev/null <<'EOF'
n
EOF
    [ "$RESULT_STATUS" = KNEE ] && [ "$RESULT_KNEE" = 499 ] && [ "$RESULT_RECOMMEND" = 487 ] \
        && [ "$FINISHED" -eq 1 ] && [ "$APPLIED" -eq 0 ] \
        || { echo "calibration knee/refinement decision is wrong" >&2; exit 1; }
    :
}
run_test "calibration knee/refinement decision is wrong" t_sm_049
t_top_033() {
    [[ "$(bbr_recommend_profile 4095)" = balanced ]] || { echo "BBR sub-4GB recommendation changed unexpectedly" >&2; exit 1; }
    [[ "$(bbr_recommend_profile 4096)" = throughput ]] || { echo "BBR 4GB recommendation does not match documentation" >&2; exit 1; }
    :
}
run_test "BBR sub-4GB recommendation changed unexpectedly …+1 项" t_top_033

BBR_TC_HELPER_TEST="$TMP/tc-helper.sh"
BBR_CWND_HELPER_TEST="$TMP/cwnd-helper.sh"
awk 'p && /^TC_HELPER_EOF$/{exit} /<< '\''TC_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_TC_HELPER_TEST"
awk 'p && /^CWND_HELPER_EOF$/{exit} /<< '\''CWND_HELPER_EOF'\''/{p=1; next} p{print}' "$ROOT/src/modules/bbr.sh" > "$BBR_CWND_HELPER_TEST"
t_top_034() {
    sh -n "$BBR_TC_HELPER_TEST" || { echo "Generated tc helper has syntax errors" >&2; exit 1; }
    sh -n "$BBR_CWND_HELPER_TEST" || { echo "Generated initcwnd helper has syntax errors" >&2; exit 1; }
    grep -qxF '# QUENCH_TC_HELPER_VERSION=3' "$BBR_TC_HELPER_TEST" \
        || { echo "Generated tc helper is missing its compatibility version" >&2; exit 1; }
    :
}
run_test "Generated tc helper has syntax errors …+2 项" t_top_034

t_sm_050() {
    HELPER_STATE="$TMP/cwnd-helper.state"
    HELPER_RUN="$TMP/cwnd-helper-run.sh"
    HELPER_BIN="$TMP/cwnd-helper-bin"
    HELPER_LOG="$TMP/cwnd-helper.log"
    export HELPER_LOG
    sed "s|^STATE=.*|STATE=$HELPER_STATE|" "$BBR_CWND_HELPER_TEST" > "$HELPER_RUN"
    chmod +x "$HELPER_RUN"
    printf 'FAMILIES=4,6\nVALUE=50\nINITRWND=0\n' > "$HELPER_STATE"
    mkdir -p "$HELPER_BIN"
    cat > "$HELPER_BIN/ip" <<'EOF'
#!/bin/sh
if [ "$2 $3" = "route show" ]; then
    echo "default dev eth0 metric 100 initcwnd 20 initrwnd 20"
else
    printf '%s\n' "$*" >> "$HELPER_LOG"
fi
EOF
    chmod +x "$HELPER_BIN/ip"
    PATH="$HELPER_BIN:$PATH" "$HELPER_RUN" apply \
        || { echo "Generated initcwnd helper could not apply dual stack" >&2; exit 1; }
    grep -qx -- '-4 route replace default dev eth0 metric 100 initcwnd 50' "$HELPER_LOG" \
        && grep -qx -- '-6 route replace default dev eth0 metric 100 initcwnd 50' "$HELPER_LOG" \
        || { echo "Generated initcwnd helper did not apply both families" >&2; exit 1; }
    : > "$HELPER_LOG"
    PATH="$HELPER_BIN:$PATH" "$HELPER_RUN" remove \
        || { echo "Generated initcwnd helper could not restore kernel defaults" >&2; exit 1; }
    grep -qx -- '-4 route replace default dev eth0 metric 100' "$HELPER_LOG" \
        && grep -qx -- '-6 route replace default dev eth0 metric 100' "$HELPER_LOG" \
        || { echo "Generated initcwnd helper remove is not functional" >&2; exit 1; }
    :
}
run_test "Generated initcwnd helper could not apply dual stack" t_sm_050

t_sm_051() {
    HELPER_STATE="$TMP/tc-helper-mq.state"
    HELPER_RUN="$TMP/tc-helper-mq.sh"
    HELPER_BIN="$TMP/tc-helper-bin"
    HELPER_LOG="$TMP/tc-helper-mq.log"
    export HELPER_LOG
    sed "s|^STATE=.*|STATE=$HELPER_STATE|" "$BBR_TC_HELPER_TEST" > "$HELPER_RUN"
    chmod +x "$HELPER_RUN"
    printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$HELPER_STATE"
    mkdir -p "$HELPER_BIN"
    cat > "$HELPER_BIN/tc" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then echo 'qdisc mq 0: root'; exit 0; fi
if [ "$1 $2" = "class show" ]; then echo 'class htb 1:10 root rate 2200Mbit ceil 2200Mbit'; exit 0; fi
printf '%s\n' "$*" >> "$HELPER_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$HELPER_BIN/tc"
    PATH="$HELPER_BIN:$PATH" "$HELPER_RUN" apply \
        || { echo "Generated tc helper could not replace mq after reboot" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$HELPER_LOG" \
        || { echo "Generated tc helper did not replace mq after reboot" >&2; exit 1; }
    ! grep -qx 'qdisc del dev eth0 root' "$HELPER_LOG" \
        || { echo "Generated tc helper tried to delete mq after reboot" >&2; exit 1; }
    :
}
run_test "Generated tc helper could not replace mq after reboot" t_sm_051

t_sm_052() {
    TC_STATE_FILE="$TMP/tc-persistence.state"
    TC_HELPER="$TMP/tc-persistence-helper"
    SERVICE_TC="$TMP/tc-persistence.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_write_persistence
    SERVICE_TC_INIT="$TMP/tc-persistence.init"
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_tc_write_persistence
    systemd_available() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_tc_write_persistence
    systemctl() { return 0; }
    bbr_tc_write_persistence eth0 500 500 1 \
        || { echo "BBR failed to persist an authorized tc takeover" >&2; exit 1; }
    grep -qx 'FORCE=1' "$TC_STATE_FILE" \
        || { echo "BBR tc persistence omitted force authorization" >&2; exit 1; }
    grep -qF '*) [ "$FORCE" -eq 1 ] || exit 1 ;;' "$TC_HELPER" \
        || { echo "Generated tc helper does not gate foreign qdisc takeover" >&2; exit 1; }
    :
}
run_test "BBR failed to persist an authorized tc takeover" t_sm_052

t_top_035() {
    for fn in docker_install docker_install_apt docker_install_rpm docker_apply_production_baseline docker_diagnose docker_status docker_select_container docker_upgrade_container docker_container_action docker_inspect_label docker_download_file docker_compose_url_valid docker_compose_risk_report docker_compose_fetch_and_deploy; do
        declare -F "$fn" >/dev/null || { echo "Missing Docker function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing Docker function: \$fn" t_top_035
t_top_036() {
    docker_compose_url_valid 'https://example.com/compose.yaml?ref=main' \
        || { echo "Docker rejected a valid HTTPS Compose URL" >&2; exit 1; }
    ! docker_compose_url_valid 'http://example.com/compose.yaml' \
        || { echo "Docker accepted an HTTP Compose URL" >&2; exit 1; }
    ! docker_compose_url_valid 'https://user:token@example.com/compose.yaml' \
        || { echo "Docker accepted credentials embedded in a Compose URL" >&2; exit 1; }
    :
}
run_test "Docker rejected a valid HTTPS Compose URL …+2 项" t_top_036
printf '{"data-root":"/srv/docker","log-opts":{"labels":"app"}}\n' > "$TMP/daemon-existing.json"
docker_config_render "$TMP/daemon-existing.json" "$TMP/daemon-rendered.json"
python3 - "$TMP/daemon-rendered.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["data-root"] == "/srv/docker"
assert data["log-driver"] == "local"
assert data["log-opts"] == {"labels": "app", "max-size": "20m", "max-file": "5"}
assert data["live-restore"] is True
PY
cat > "$TMP/compose-risk.json" <<'EOF'
{"services":{"app":{"privileged":true,"network_mode":"host","volumes":[{"type":"bind","source":"/srv/app","target":"/data"}],"ports":[{"published":"8080","target":80,"protocol":"tcp"}]}}}
EOF
DOCKER_RISKS=$(docker_compose_risk_report "$TMP/compose-risk.json")
t_top_037() {
    [[ "$DOCKER_RISKS" = *$'HIGH\tapp\tprivileged'* && "$DOCKER_RISKS" = *$'HIGH\tapp\tnetwork_mode=host'* \
        && "$DOCKER_RISKS" = *$'HIGH\tapp\tmount=/srv/app:/data'* \
        && "$DOCKER_RISKS" = *$'PORT\tapp\t0.0.0.0/:::8080->80/tcp'* ]] \
        || { echo "Docker Compose risk report is incomplete" >&2; exit 1; }
    ! grep -Fq 'get.docker.com' "$ROOT/src/modules/docker.sh" \
        || { echo "Docker installer must use the official package repository" >&2; exit 1; }
    :
}
run_test "Docker Compose risk report is incomplete …+1 项" t_top_037

t_top_038() {
    for fn in self_install self_script_valid self_resolve_script_source self_reconcile_tc_after_update self_fetch_script self_shortcut_owned self_install_shortcut self_remove_shortcut self_offline_bundle_create self_offline_bundle_install self_update self_remote_main_sha config_health_check diagnostic_bundle_create; do
        declare -F "$fn" >/dev/null || { echo "Missing new function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing new function: \$fn" t_top_038
t_top_039() {
    grep -q -- '--bbr-reconcile-tc)' "$ROOT/src/modules/main.sh" \
        || { echo "Missing internal tc reconciliation CLI dispatch" >&2; exit 1; }
    :
}
run_test "Missing internal tc reconciliation CLI dispatch" t_top_039

t_top_040() {
    for fn in software_menu common_software_menu software_group_packages software_refresh_index software_install_transaction; do
        declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing function: \$fn" t_top_040
t_top_041() {
    for fn in config_export_archive config_import_archive config_transfer_menu rollback_center_menu; do
        declare -F "$fn" >/dev/null || { echo "Missing toolbox function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing toolbox function: \$fn" t_top_041

t_top_042() {
    for fn in stun_ports_normalize stun_host_valid stun_udp_explanation stun_nat_explanation stun_mapping_explanation stun_filtering_explanation stun_confidence_explanation stun_recommendation stun_probe_engine stun_render_results stun_probe_execute stun_nat_quick stun_nat_custom stun_nat_menu; do
        declare -F "$fn" >/dev/null || { echo "Missing STUN function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing STUN function: \$fn" t_top_042
t_top_043() {
    [[ "$(stun_ports_normalize '3478, 19302;3478 443')" = "3478,19302,443" ]] || { echo "STUN port normalization failed" >&2; exit 1; }
    ! stun_ports_normalize '0,3478' >/dev/null 2>&1 || { echo "STUN accepted port zero" >&2; exit 1; }
    ! stun_ports_normalize '3478,65536' >/dev/null 2>&1 || { echo "STUN accepted an out-of-range port" >&2; exit 1; }
    ! stun_ports_normalize '1,2,3,4,5,6,7,8,9,10,11,12,13' >/dev/null 2>&1 || { echo "STUN accepted more than 12 ports" >&2; exit 1; }
    stun_host_valid stun.nextcloud.com || { echo "STUN rejected a valid hostname" >&2; exit 1; }
    ! stun_host_valid 'bad host;id' || { echo "STUN accepted an unsafe hostname" >&2; exit 1; }
    ! stun_host_valid 'bad..example.com' || { echo "STUN accepted an empty hostname label" >&2; exit 1; }
    [[ "$(stun_probe_engine selftest - -)" = $'SELFTEST\tok' ]] || { echo "STUN protocol self-test failed" >&2; exit 1; }
    ! grep -Fq 'stun.sipgate.net' "$ROOT/src/modules/stun.sh" || { echo "STUN must not use the unavailable Sipgate endpoint" >&2; exit 1; }
    grep -Fq '("stun.nextcloud.com", 443)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/443" >&2; exit 1; }
    grep -Fq '("stun.nextcloud.com", 3478)' "$ROOT/src/modules/stun.sh" || { echo "STUN quick endpoints missing Nextcloud UDP/3478" >&2; exit 1; }
    [[ "$(stun_udp_explanation 5 5)" = *"全部节点响应"* ]] || { echo "STUN complete UDP explanation failed" >&2; exit 1; }
    [[ "$(stun_udp_explanation 3 5)" = *"3/5 节点响应"* ]] || { echo "STUN partial UDP explanation failed" >&2; exit 1; }
    [[ "$(stun_udp_explanation 0 5)" = *"无节点响应"* ]] || { echo "STUN unavailable UDP explanation failed" >&2; exit 1; }
    :
}
run_test "STUN port normalization failed …+13 项" t_top_043
t_top_044() {
    for NAT_RESULT in open_internet public_udp_firewall full_cone restricted_cone port_restricted symmetric nat_unknown udp_unavailable unknown; do
        [ -n "$(stun_nat_explanation "$NAT_RESULT")" ] || { echo "STUN NAT explanation missing for $NAT_RESULT" >&2; exit 1; }
        [ -n "$(stun_recommendation "$NAT_RESULT")" ] || { echo "STUN recommendation missing for $NAT_RESULT" >&2; exit 1; }
    done
    :
}
run_test "STUN NAT explanation missing for \$NAT_RESULT …+1 项" t_top_044
t_top_045() {
    for MAPPING_RESULT in eim adm apdm endpoint_dependent unknown; do
        [ -n "$(stun_mapping_explanation "$MAPPING_RESULT")" ] || { echo "STUN mapping explanation missing for $MAPPING_RESULT" >&2; exit 1; }
    done
    :
}
run_test "STUN mapping explanation missing for \$MAPPING_RESULT" t_top_045
t_top_046() {
    for FILTERING_RESULT in eif adf apdf unknown; do
        [ -n "$(stun_filtering_explanation "$FILTERING_RESULT")" ] || { echo "STUN filtering explanation missing for $FILTERING_RESULT" >&2; exit 1; }
    done
    :
}
run_test "STUN filtering explanation missing for \$FILTERING_RESULT" t_top_046
t_top_047() {
    for CONFIDENCE_RESULT in high medium low; do
        [ -n "$(stun_confidence_explanation "$CONFIDENCE_RESULT")" ] || { echo "STUN confidence explanation missing for $CONFIDENCE_RESULT" >&2; exit 1; }
    done
    :
}
run_test "STUN confidence explanation missing for \$CONFIDENCE_RESULT" t_top_047
STUN_RENDERED=$(stun_render_results $'SUMMARY\t10.0.0.2\t12345\t198.51.100.2:54321\tapdm\tapdf\tsymmetric\thigh\t5\t5')
t_top_048() {
    [[ "$STUN_RENDERED" = *"结果解释"* && "$STUN_RENDERED" = *"UDP 打洞和 P2P 直连较困难"* ]] || { echo "STUN rendered result explanations are missing" >&2; exit 1; }
    [[ "$(software_group_packages apt base)" = *curl* ]] || { echo "APT base package mapping is incomplete" >&2; exit 1; }
    [[ "$(software_group_packages apk network)" = *mtr* ]] || { echo "APK network package mapping is incomplete" >&2; exit 1; }
    ! grep -RE 'pacman[[:space:]]+-Sy([[:space:]]|$)' "$ROOT/src" >/dev/null \
        || { echo "Source still performs an unsafe Arch partial upgrade" >&2; exit 1; }
    :
}
run_test "STUN rendered result explanations are missing …+3 项" t_top_048
t_top_049() {
    for fn in swap_managed_path swap_fstab_render swap_fstab_apply swap_create_apply swap_delete swap_set_swappiness_apply; do
        declare -F "$fn" >/dev/null || { echo "Missing Swap transaction function: $fn" >&2; exit 1; }
    done
    :
}
run_test "Missing Swap transaction function: \$fn" t_top_049
printf 'UUID=root / ext4 defaults 0 1\n# BEGIN QUENCH SWAP\n/old none swap sw 0 0\n# END QUENCH SWAP\n' > "$TMP/fstab-source"
SWAP_FSTAB_RENDERED=$(swap_fstab_render add /swapfile.quench "$TMP/fstab-source")
t_top_050() {
    [[ "$SWAP_FSTAB_RENDERED" = *'UUID=root / ext4 defaults 0 1'* \
        && "$SWAP_FSTAB_RENDERED" = *'/swapfile.quench none swap sw 0 0'* \
        && "$SWAP_FSTAB_RENDERED" != *'/old none swap'* ]] \
        || { echo "Swap fstab renderer did not replace only its managed block" >&2; exit 1; }
    :
}
run_test "Swap fstab renderer did not replace only its managed block" t_top_050
CLI_HELP=$(show_cli_help)
t_top_051() {
    [[ "$CLI_HELP" = *"--user-menu"* ]] || { echo "CLI help missing user management entry" >&2; exit 1; }
    [[ "$CLI_HELP" = *"--docker-menu"* ]] || { echo "CLI help missing Docker entry" >&2; exit 1; }
    [[ "$CLI_HELP" = *"--hostname-menu"* ]] || { echo "CLI help missing hostname entry" >&2; exit 1; }
    [[ "$CLI_HELP" = *"--stun-test"* ]] || { echo "CLI help missing STUN entry" >&2; exit 1; }
    [[ "$CLI_HELP" = *"--nft-refresh-targets"* ]] || { echo "CLI help missing NFT domain target refresh entry" >&2; exit 1; }
    grep -q "已测试成功，现在完成切换" "$ROOT/src/modules/ssh.sh" || { echo "SSH new port confirmation prompt missing" >&2; exit 1; }
    grep -q "继续同时保留.*OLD_PORT.*NEW_PORT" "$ROOT/src/modules/ssh.sh" || { echo "SSH persistent dual-port safety message missing" >&2; exit 1; }
    grep -q "关闭旧端口.*防火墙放行" "$ROOT/src/modules/ssh.sh" || { echo "SSH old firewall rule prompt missing" >&2; exit 1; }
    system_hostname_valid GreenCloud.HK6666 || { echo "Hostname validation rejected valid dotted name" >&2; exit 1; }
    ! system_hostname_valid "-bad-name" || { echo "Hostname validation accepted bad leading hyphen" >&2; exit 1; }
    :
}
run_test "CLI help missing user management entry …+9 项" t_top_051
SSHD_SAMPLE="$TMP/sshd_config"
cat > "$SSHD_SAMPLE" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes

Match User deploy
    PasswordAuthentication yes
EOF
set_config_file "$SSHD_SAMPLE" "PasswordAuthentication" "no"
FIRST_DIRECTIVE=$(grep -m1 -E '^(Include|PasswordAuthentication|Match)' "$SSHD_SAMPLE")
t_top_052() {
    [[ "$FIRST_DIRECTIVE" = "PasswordAuthentication no" ]] || { echo "Managed SSH settings must precede Include and Match blocks" >&2; exit 1; }
    :
}
run_test "Managed SSH settings must precede Include and Match blocks" t_top_052
t_sm_053() {
    NFT_TEST="$TMP/nft-render"
    mkdir -p "$NFT_TEST"
    NFT_RULES_FILE="$NFT_TEST/rules.db"
    NFT_ACCESS_FILE="$NFT_TEST/access.db"
    printf '%s\n' \
        '1|ipv4|tcp||443|443|ip|198.51.100.10|198.51.100.10|8443|8443|single|masquerade|whitelist|yes|web' \
        '2|ipv4|udp|203.0.113.2|10000|10002|ip|198.51.100.20|198.51.100.20|20000|20002|range_offset|preserve|off|yes|udp' \
        '3|ipv6|tcp||80|80|ip|2001:db8::10|2001:db8::10|8080|8080|single|masquerade|blacklist|yes|v6' \
        > "$NFT_RULES_FILE"
    printf '%s\n' '1|ipv4|192.0.2.0/24' '3|ipv6|2001:db8:1::/48' > "$NFT_ACCESS_FILE"
    nft_validate_database
    ! nft_validate_record 9 ipv4 tcp '' 1000 1002 ip 198.51.100.30 198.51.100.30 \
        2000 2001 range_offset masquerade off yes broken-offset \
        || { echo "NFT accepted mismatched offset ranges" >&2; exit 1; }
    NFT_CONFIG=$(nft_generate_config)
    [[ "$NFT_CONFIG" != *"flush ruleset"* ]] || { echo "NFT config must not flush the host ruleset" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip quench_nft4"* ]] || { echo "NFT IPv4 table is not Quench-scoped" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *"table ip6 quench_nft6"* ]] || { echo "NFT IPv6 table is not Quench-scoped" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *'tcp dport 443 ct mark set ct mark | 0x40000000'* ]] \
        || { echo "NFT scoped masquerade mark missing" >&2; exit 1; }
    [[ "$NFT_CONFIG" != *'ct status dnat masquerade'* ]] \
        || { echo "NFT still masquerades unrelated DNAT connections" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *'tcp dport 443 ip saddr != @acl_1'* ]] \
        || { echo "NFT per-rule whitelist missing" >&2; exit 1; }
    [[ "$NFT_CONFIG" = *'ip daddr 203.0.113.2 udp dport 10000-10002 counter dnat'* ]] \
        || { echo "NFT UDP preserve rule is wrong" >&2; exit 1; }
    [[ "$NFT_CONFIG" != *'ip daddr 203.0.113.2 udp dport 10000-10002 ct mark'* ]] \
        || { echo "NFT preserve rule unexpectedly enables SNAT" >&2; exit 1; }
    [ "$(nft_rule_conflict_id '' ipv4 both '' 443 443)" = 1 ] \
        || { echo "NFT overlapping listener detection failed" >&2; exit 1; }
    nft_refresh_interval_valid 10s && nft_refresh_interval_valid 24h \
        && ! nft_refresh_interval_valid 9s && ! nft_refresh_interval_valid '5 minutes' \
        || { echo "NFT refresh interval validation failed" >&2; exit 1; }
    default_iface() { echo eth0; }
    nft_ipv6_default_iface() { echo eth6; }
    ip() {
        if [[ " $* " == *' addr show '* ]]; then
            echo '2: eth0 inet 203.0.113.2/24 scope global eth0'
        else
            echo '198.51.100.20 via 203.0.113.1 dev eth1 src 203.0.113.2'
        fi
    }
    NFT_EDIT_ID=""
    ! nft_rule_preflight ipv4 udp 203.0.113.99 5353 5353 198.51.100.20 5353 >/dev/null 2>&1 \
        || { echo "NFT accepted a listener IP absent from this host" >&2; exit 1; }
    UFW_SPECS=$(nft_firewall_specs ufw '')
    [[ "$UFW_SPECS" = *'ufw|ipv4|udp|eth0|eth1|198.51.100.20|20000:20002|QUENCH_NFT_2_udp'* ]] \
        || { echo "NFT UFW routed rule is not interface/range scoped" >&2; exit 1; }
    FIREWALLD_SPECS=$(nft_firewall_specs firewalld public)
    [[ "$FIREWALLD_SPECS" = *'forward-port port="10000-10002" protocol="udp" to-port="20000-20002" to-addr="198.51.100.20"'* ]] \
        || { echo "NFT firewalld rich forward rule is wrong" >&2; exit 1; }

(
    NFT_TEST="$TMP/nft-transaction"
    mkdir -p "$NFT_TEST/state" "$NFT_TEST/runtime"
    NFT_MANAGED_FILE="$NFT_TEST/quench.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RUNTIME_DIR="$NFT_TEST/runtime"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.db"
    : > "$NFT_RULES_FILE"; : > "$NFT_ACCESS_FILE"
    nft() {
        [ "${1:-}" = list ] && return 1
        return 0
    }
    nft_write_managed_file >/dev/null
    [ -s "$NFT_MANAGED_FILE" ] || { echo "NFT managed rules file missing" >&2; exit 1; }
    [[ "$(cat "$NFT_MANAGED_FILE")" != *'table ip '* ]] \
        || { echo "Empty NFT database rendered an unexpected table" >&2; exit 1; }
)
(
    NFT_TEST="$TMP/nft-rollback"
    mkdir -p "$NFT_TEST/state" "$NFT_TEST/runtime"
    NFT_MANAGED_FILE="$NFT_TEST/quench.nft"
    NFT_STATE_DIR="$NFT_TEST/state"
    NFT_RUNTIME_DIR="$NFT_TEST/runtime"
    NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
    NFT_ACCESS_FILE="$NFT_STATE_DIR/access.db"
    printf '%s\n' '1|ipv4|tcp||443|443|ip|198.51.100.10|198.51.100.10|443|443|single|masquerade|off|yes|web' > "$NFT_RULES_FILE"
    : > "$NFT_ACCESS_FILE"
    printf '# old managed rules\n' > "$NFT_MANAGED_FILE"
    cp "$NFT_MANAGED_FILE" "$NFT_TEST/managed.expected"
    nft() {
        [ "${1:-}" = list ] && return 1
        [ "${1:-}" = -c ] && return 0
        return 1
    }
    ! nft_write_managed_file >/dev/null 2>&1 || { echo "NFT apply failure returned success" >&2; exit 1; }
    [ "$(cat "$NFT_MANAGED_FILE")" = "$(cat "$NFT_TEST/managed.expected")" ] \
        || { echo "NFT apply failure did not restore managed config" >&2; exit 1; }
)
(
    NFT_TEST="$TMP/nft-sysctl"
    mkdir -p "$NFT_TEST/state" "$NFT_TEST/runtime"
    NFT_RULES_FILE="$NFT_TEST/state/rules.db"
    NFT_ACCESS_FILE="$NFT_TEST/state/access.db"
    NFT_SYSCTL_FILE="$NFT_TEST/98-quench-nft-forward.conf"
    NFT_SYSCTL_BASELINE="$NFT_TEST/runtime/sysctl-baseline"
    NFT_BBR_SYSCTL_FILE="$NFT_TEST/99-quench-bbr.conf"
    printf '%s\n' '1|ipv6|tcp||443|443|ip|2001:db8::10|2001:db8::10|443|443|single|masquerade|off|yes|v6' > "$NFT_RULES_FILE"
    : > "$NFT_ACCESS_FILE"
    nft_ipv6_default_iface() { echo eth6; }
    nft_sysctl_get() {
        case "$1" in
            net.ipv4.ip_forward|net.ipv6.conf.all.forwarding) echo 0 ;;
            *) echo 1 ;;
        esac
    }
    nft_sysctl_set() { printf '%s=%s\n' "$1" "$2" >> "$NFT_TEST/restored.log"; }
    sysctl() { return 0; }
    nft_sysctl_reconcile
    grep -qx 'net.ipv6.conf.all.forwarding = 1' "$NFT_SYSCTL_FILE" \
        || { echo "NFT IPv6 forwarding sysctl missing" >&2; exit 1; }
    grep -qx 'net.ipv6.conf.eth6.accept_ra = 2' "$NFT_SYSCTL_FILE" \
        || { echo "NFT IPv6 RA compatibility setting missing" >&2; exit 1; }
    cat > "$NFT_BBR_SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.eth6.accept_ra = 2
EOF
    : > "$NFT_RULES_FILE"
    nft_sysctl_reconcile
    [ ! -e "$NFT_SYSCTL_FILE" ] || { echo "NFT sysctl file remained after last rule" >&2; exit 1; }
    [ ! -e "$NFT_SYSCTL_BASELINE" ] || { echo "NFT left a stale baseline after the last rule" >&2; exit 1; }
    grep -qx 'net.ipv4.ip_forward=1' "$NFT_TEST/restored.log" \
        || { echo "NFT restore ignored BBR-owned IPv4 forwarding" >&2; exit 1; }
    grep -qx 'net.ipv6.conf.all.forwarding=1' "$NFT_TEST/restored.log" \
        || { echo "NFT restore ignored BBR-owned IPv6 forwarding" >&2; exit 1; }
    grep -qx 'net.ipv6.conf.eth6.accept_ra=2' "$NFT_TEST/restored.log" \
        || { echo "NFT restore ignored BBR-owned IPv6 RA" >&2; exit 1; }
)
    :
}
run_test "NFT accepted mismatched offset ranges" t_sm_053
OS=$(detect_os)
t_top_053() {
    [ -n "$OS" ] || { echo "OS detection returned empty" >&2; exit 1; }
    :
}
run_test "OS detection returned empty" t_top_053

COLUMNS=44; ui_refresh_dimensions
t_top_054() {
    [ "$UI_COMPACT" -eq 1 ] || { echo "Narrow terminal did not enable compact layout" >&2; exit 1; }
    :
}
run_test "Narrow terminal did not enable compact layout" t_top_054
COLUMNS=72; ui_refresh_dimensions
t_top_055() {
    [ "$UI_COMPACT" -eq 0 ] || { echo "Wide terminal did not enable two-column layout" >&2; exit 1; }
    :
}
run_test "Wide terminal did not enable two-column layout" t_top_055

# The diagnostic bundle used to declare `local TMPDIR` and then build its work
# directory from ${TMPDIR:-/tmp}. The local shadow made that expansion always /tmp,
# and every helper called from the function saw the work directory as TMPDIR.
t_diag_001() {
    DIAG_ROOT=$(mktemp -d)
    export TMPDIR="$DIAG_ROOT/mytmp"
    mkdir -p "$TMPDIR"
    QUENCH_DATA_DIR="$DIAG_ROOT/data"
    QUENCH_VERSION_DIR="$DIAG_ROOT/data/versions"
    QUENCH_BACKUP_DIR="$DIAG_ROOT/data/backups"
    quench_tmp_registry_init || fail "temp registry could not be initialised"
    diagnostic_bundle_create >/dev/null 2>&1 || fail "diagnostic bundle creation failed"
    find "$DIAG_ROOT/data/diagnostics" -name 'diagnostic_*.tar.gz' 2>/dev/null | grep -q . \
        || fail "no diagnostic archive was produced"
    grep -q "^$TMPDIR/quench-diagnostic" "$QUENCH_TMP_REGISTRY" \
        || fail "the diagnostic work directory ignored the caller's TMPDIR"
    quench_tmp_cleanup
    rm -rf "$DIAG_ROOT"
    :
}
run_test "The diagnostic bundle honours the caller's TMPDIR" t_diag_001

# Rebuilding unchanged sources must not rewrite the manifest, or every build dirties
# the working tree with a generated_at that is the only thing to have moved.
t_build_001() {
    BUILD_COPY=$(mktemp -d "${TMPDIR:-/tmp}/quench-buildcheck.XXXXXX")
    [ -n "$BUILD_COPY" ] && [ -d "$BUILD_COPY" ] \
        || fail "could not create a staging directory"
    cp -a "$ROOT/src" "$ROOT/build.sh" "$ROOT/vps-quench.sh" \
          "$ROOT/vps-quench.sh.sha256" "$ROOT/vps-quench.manifest.json" "$BUILD_COPY/" \
        || fail "could not stage a build copy"
    # 构建输出必须带进失败信息，否则 CI 上只看到 "first build failed"。
    BUILD_LOG="$BUILD_COPY/build.log"
    if ! ( cd "$BUILD_COPY" && bash ./build.sh ) > "$BUILD_LOG" 2>&1; then
        BUILD_OUT=$(cat "$BUILD_LOG" 2>/dev/null)
        rm -rf "$BUILD_COPY"
        fail "first build failed: $BUILD_OUT"
    fi
    MANIFEST_FIRST=$(cat "$BUILD_COPY/vps-quench.manifest.json")
    sleep 1
    if ! ( cd "$BUILD_COPY" && bash ./build.sh ) > "$BUILD_LOG" 2>&1; then
        BUILD_OUT=$(cat "$BUILD_LOG" 2>/dev/null)
        rm -rf "$BUILD_COPY"
        fail "second build failed: $BUILD_OUT"
    fi
    # 用字符串比较而不是 cmp：精简的 Rocky 镜像里没有 diffutils。
    MANIFEST_SECOND=$(cat "$BUILD_COPY/vps-quench.manifest.json")
    rm -rf "$BUILD_COPY"
    [ "$MANIFEST_FIRST" = "$MANIFEST_SECOND" ] \
        || fail "rebuilding unchanged sources rewrote the manifest"
    :
}
run_test "Rebuilding unchanged sources leaves the manifest untouched" t_build_001

test_summary "Smoke ($OS)"
