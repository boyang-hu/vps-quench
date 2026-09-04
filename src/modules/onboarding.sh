# ══════════════════════════════════════════════════════════
#  首次开荒向导
# ══════════════════════════════════════════════════════════

FIRST_RUN_NETWORK_SECURITY_FILE="${FIRST_RUN_NETWORK_SECURITY_FILE:-/etc/sysctl.d/98-vps-quench-network-security.conf}"

first_run_route_ok() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -4 route get 1.1.1.1 >/dev/null 2>&1 \
        || ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
}

first_run_dns_ok() {
    if command -v getent >/dev/null 2>&1; then
        getent ahosts github.com >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup github.com >/dev/null 2>&1
    else
        ping -c 1 -W 3 github.com >/dev/null 2>&1
    fi
}

first_run_access_ready() {
    [ "$(user_ready_admin_count)" -gt 0 ] \
        && [ "$(get_config PasswordAuthentication)" = no ] \
        && [ "$(get_config KbdInteractiveAuthentication)" = no ] \
        && [ "$(get_config PubkeyAuthentication)" = yes ] \
        && [ "$(get_config PermitRootLogin)" = no ] \
        && ! ssh_read_port_state
}

first_run_firewall_ready() {
    local TYPE PORT
    TYPE=$(fw_detect)
    case "$TYPE" in
        ufw|firewalld) [ "$(fw_running "$TYPE")" = active ] || return 1 ;;
        *) return 1 ;;
    esac
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        firewall_port_ready "$PORT" || return 1
    done < <(ssh_effective_ports)
}

first_run_fail2ban_ready() {
    [ "$(f2b_status)" = running ] \
        && f2b_managed_ports_match "$(ssh_effective_ports_csv)" \
        && f2b_runtime_healthy
}

first_run_ssh_baseline_ready() {
    [ "$(get_config PubkeyAuthentication)" = yes ] \
        && [ "$(get_config PermitEmptyPasswords)" = no ] \
        && [ "$(get_config MaxAuthTries)" = 4 ] \
        && [ "$(get_config LoginGraceTime)" = 30 ] \
        && [ "$(get_config X11Forwarding)" = no ]
}

first_run_network_security_pairs() {
    cat <<'EOF'
net.ipv4.tcp_syncookies|1
net.ipv4.conf.all.accept_redirects|0
net.ipv4.conf.default.accept_redirects|0
net.ipv4.conf.all.send_redirects|0
net.ipv4.conf.default.send_redirects|0
net.ipv4.conf.all.accept_source_route|0
net.ipv4.conf.default.accept_source_route|0
net.ipv4.icmp_echo_ignore_broadcasts|1
net.ipv4.icmp_ignore_bogus_error_responses|1
net.ipv6.conf.all.accept_redirects|0
net.ipv6.conf.default.accept_redirects|0
EOF
}

first_run_sysctl_file_value() {
    local KEY="$1" FILE="${2:-$FIRST_RUN_NETWORK_SECURITY_FILE}"
    awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            value=$0
        }
        END {if (value != "") print value}
    ' "$FILE" 2>/dev/null
}

first_run_network_security_ready() {
    local KEY EXPECTED CURRENT PERSISTED SUPPORTED=0
    command -v sysctl >/dev/null 2>&1 || return 1
    [ -f "$FIRST_RUN_NETWORK_SECURITY_FILE" ] || return 1
    while IFS='|' read -r KEY EXPECTED; do
        [ -n "$KEY" ] || continue
        CURRENT=$(sysctl -n "$KEY" 2>/dev/null) || continue
        SUPPORTED=$((SUPPORTED + 1))
        PERSISTED=$(first_run_sysctl_file_value "$KEY")
        [ "$CURRENT" = "$EXPECTED" ] && [ "$PERSISTED" = "$EXPECTED" ] || return 1
    done < <(first_run_network_security_pairs)
    [ "$SUPPORTED" -gt 0 ]
}

first_run_status_label() {
    "$@" >/dev/null 2>&1 && printf '已完成\n' || printf '需配置\n'
}

first_run_status_state() {
    "$@" >/dev/null 2>&1 && printf 'active\n' || printf 'warning\n'
}

first_run_print_status() {
    local DNS_LABEL DNS_STATE ACCESS_LABEL ACCESS_STATE FW_LABEL FW_STATE
    local F2B_LABEL F2B_STATE SSH_LABEL SSH_STATE UPDATE_LABEL UPDATE_STATE
    local NET_LABEL NET_STATE BBR_LABEL BBR_STATE TIME_LABEL TIME_STATE TIME_BACKEND
    if first_run_route_ok && first_run_dns_ok; then DNS_LABEL="正常"; DNS_STATE=active
    else DNS_LABEL="需检查"; DNS_STATE=warning; fi
    ACCESS_LABEL=$(first_run_status_label first_run_access_ready)
    ACCESS_STATE=$(first_run_status_state first_run_access_ready)
    FW_LABEL=$(first_run_status_label first_run_firewall_ready)
    FW_STATE=$(first_run_status_state first_run_firewall_ready)
    F2B_LABEL=$(first_run_status_label first_run_fail2ban_ready)
    F2B_STATE=$(first_run_status_state first_run_fail2ban_ready)
    SSH_LABEL=$(first_run_status_label first_run_ssh_baseline_ready)
    SSH_STATE=$(first_run_status_state first_run_ssh_baseline_ready)
    if system_auto_updates_supported; then
        UPDATE_LABEL=$(first_run_status_label system_auto_updates_enabled)
        UPDATE_STATE=$(first_run_status_state system_auto_updates_enabled)
    else
        UPDATE_LABEL="不支持"; UPDATE_STATE=unknown
    fi
    NET_LABEL=$(first_run_status_label first_run_network_security_ready)
    NET_STATE=$(first_run_status_state first_run_network_security_ready)
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_LABEL="已启用"; BBR_STATE=active
    else
        BBR_LABEL="可选"; BBR_STATE=unknown
    fi
    TIME_BACKEND=$(ts_backend_detect)
    if ts_ntp_synchronized "$TIME_BACKEND"; then
        TIME_LABEL="已同步"; TIME_STATE=active
    elif [ "$TIME_BACKEND" = conflict ]; then
        TIME_LABEL="后端冲突"; TIME_STATE=warning
    else
        TIME_LABEL="需检查"; TIME_STATE=warning
    fi

    status_pair "网络 / DNS" "$DNS_LABEL" "$DNS_STATE" "用户 / SSH" "$ACCESS_LABEL" "$ACCESS_STATE"
    status_pair "防火墙" "$FW_LABEL" "$FW_STATE" "Fail2ban" "$F2B_LABEL" "$F2B_STATE"
    status_pair "SSH 基线" "$SSH_LABEL" "$SSH_STATE" "自动更新" "$UPDATE_LABEL" "$UPDATE_STATE"
    status_pair "网络安全" "$NET_LABEL" "$NET_STATE" "时间同步" "$TIME_LABEL" "$TIME_STATE"
    status_pair "BBR" "$BBR_LABEL" "$BBR_STATE"
}

first_run_preflight() {
    print_header "首次开荒 · 环境、DNS 与时间预检"
    local OS_INFO KERNEL VIRT IFACE ROUTE_STATE=warning DNS_STATE=warning TIME_STATE=warning
    local TIME_BACKEND ANSWER
    OS_INFO=$(detect_os 2>/dev/null || echo unknown)
    KERNEL=$(uname -r 2>/dev/null || echo unknown)
    VIRT=$(systemd-detect-virt 2>/dev/null || true)
    VIRT=${VIRT:-unknown}
    IFACE=$(default_iface 2>/dev/null || true)
    first_run_route_ok && ROUTE_STATE=active
    first_run_dns_ok && DNS_STATE=active
    TIME_BACKEND=$(ts_backend_detect)
    ts_ntp_synchronized "$TIME_BACKEND" && TIME_STATE=active
    status_pair "系统" "$OS_INFO · $KERNEL" active "虚拟化" "$VIRT" unknown
    status_pair "默认网卡" "${IFACE:-未检测到}" "$ROUTE_STATE" "DNS 解析" "$([ "$DNS_STATE" = active ] && echo 正常 || echo 失败)" "$DNS_STATE"
    status_pair "时间同步" "$([ "$TIME_STATE" = active ] && echo 正常 || echo 需检查)" "$TIME_STATE" "NTP 后端" "$(ts_backend_label "$TIME_BACKEND")" "$TIME_STATE"
    echo ""
    if [ "$ROUTE_STATE" != active ]; then
        error "没有可用的 IPv4/IPv6 默认路由，请先修复网络"
        audit_action "首次开荒环境预检：默认路由失败" FAILED
        return 1
    fi
    if [ "$DNS_STATE" = active ]; then
        info "当前 DNS 解析正常，按安全默认保持现有配置不变"
        if [ "$TIME_STATE" != active ]; then
            warn "系统时间尚未确认同步；建议完成向导后进入时间模块诊断或修复"
        fi
        audit_action "首次开荒环境与 DNS 预检" SUCCESS
        return 0
    fi
    warn "当前 DNS 无法解析 github.com；继续安装软件前建议先修复"
    read -rp "  是否进入 DNS 管理进行修复？(Y/n，默认Y): " ANSWER
    ANSWER=${ANSWER:-y}
    if echo "$ANSWER" | grep -qiE '^y(es)?$'; then
        dns_menu
        if first_run_dns_ok; then
            info "DNS 解析已恢复"
            [ "$TIME_STATE" = active ] || warn "系统时间尚未确认同步；建议进入时间模块诊断或修复"
            return 0
        fi
    fi
    audit_action "首次开荒环境预检：DNS 失败" FAILED
    return 1
}

first_run_ssh_baseline_render() {
    local FILE="$1"
    set_config_file "$FILE" PubkeyAuthentication yes
    set_config_file "$FILE" PermitEmptyPasswords no
    set_config_file "$FILE" MaxAuthTries 4
    set_config_file "$FILE" LoginGraceTime 30
    set_config_file "$FILE" X11Forwarding no
}

first_run_ssh_baseline_apply() {
    print_header "首次开荒 · SSH 基础加固"
    first_run_ssh_baseline_ready && { info "SSH 基础加固已经生效，无需重复修改"; return 0; }
    command -v sshd >/dev/null 2>&1 || { error "未找到 sshd，无法应用 SSH 基线"; return 1; }
    [ -f "$SSHD_CONFIG" ] || { error "SSH 主配置不存在：$SSHD_CONFIG"; return 1; }
    local CANDIDATE
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    first_run_ssh_baseline_render "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 基础加固"; then
        rm -f "$CANDIDATE"
        warn "已取消，SSH 配置未修改"
        return 0
    fi
    backup_config || { rm -f "$CANDIDATE"; return 1; }
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"
        error "SSH 配置写入失败"
        return 1
    fi
    rm -f "$CANDIDATE"
    if ! apply_and_restart || ! first_run_ssh_baseline_ready; then
        error "SSH 基础参数未完全生效，正在恢复"
        ssh_restore_last_backup
        return 1
    fi
    audit_action "应用首次开荒 SSH 基础加固" SUCCESS
    info "SSH 基础加固已生效：认证尝试 4 次、登录等待 30 秒、关闭 X11 转发"
}

# 返回 0 只代表“确认恢复成功”。原来文件恢复和每一条 sysctl 回写都 || true，
# 结果无论恢复成没成都报成功，调用方据此取消了安全网。
first_run_network_security_restore() {
    local EXISTED="$1" BACKUP="$2" RUNTIME="$3" KEY VALUE RC=0
    if [ "$EXISTED" = yes ]; then
        atomic_replace_file "$BACKUP" "$FIRST_RUN_NETWORK_SECURITY_FILE" || RC=1
    else
        rm -f "$FIRST_RUN_NETWORK_SECURITY_FILE" || RC=1
    fi
    while IFS='|' read -r KEY VALUE; do
        [ -n "$KEY" ] || continue
        sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || RC=1
    done < "$RUNTIME"
    return "$RC"
}

first_run_network_security_apply() {
    print_header "首次开荒 · 内核网络安全基线"
    first_run_network_security_ready && { info "内核网络安全基线已经生效"; return 0; }
    ensure_sysctl || return 1
    has_sysctl_write || { error "当前容器或宿主机不允许写入 sysctl"; return 1; }
    local CANDIDATE RUNTIME BACKUP EXISTED=no KEY EXPECTED CURRENT COUNT=0
    CANDIDATE=$(quench_mktemp) || return 1
    RUNTIME=$(quench_mktemp) || { rm -f "$CANDIDATE"; return 1; }
    BACKUP=$(quench_mktemp) || { rm -f "$CANDIDATE" "$RUNTIME"; return 1; }
    {
        echo "# Managed by Quench first-run network security baseline."
        echo "# Performance tuning remains in /etc/sysctl.d/99-quench-bbr.conf."
        while IFS='|' read -r KEY EXPECTED; do
            [ -n "$KEY" ] || continue
            if CURRENT=$(sysctl -n "$KEY" 2>/dev/null); then
                printf '%s|%s\n' "$KEY" "$CURRENT" >> "$RUNTIME"
                printf '%s = %s\n' "$KEY" "$EXPECTED"
                COUNT=$((COUNT + 1))
            fi
        done < <(first_run_network_security_pairs)
    } > "$CANDIDATE"
    if [ "$COUNT" -eq 0 ]; then
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        error "当前内核没有可应用的网络安全参数"
        return 1
    fi
    if ! confirm_change_preview "内核网络安全基线" \
        "关闭 ICMP redirect、source route 与 IPv6 redirect 接受" \
        "启用 SYN cookies，并忽略广播 ICMP 与异常 ICMP 错误" \
        "只写入当前内核实际支持的 ${COUNT} 个参数" \
        "不修改 BBR、缓冲区、转发和 swappiness"; then
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        warn "已取消，内核网络参数未修改"
        return 0
    fi
    if [ -f "$FIRST_RUN_NETWORK_SECURITY_FILE" ]; then
        cp "$FIRST_RUN_NETWORK_SECURITY_FILE" "$BACKUP" || { rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    safety_arm first_run_network_security || { rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"; return 1; }
    if ! { mkdir -p "$(dirname "$FIRST_RUN_NETWORK_SECURITY_FILE")" \
        && cp "$CANDIDATE" "$FIRST_RUN_NETWORK_SECURITY_FILE" \
        && chmod 0644 "$FIRST_RUN_NETWORK_SECURITY_FILE"; } \
        || ! sysctl -p "$FIRST_RUN_NETWORK_SECURITY_FILE" >/dev/null 2>&1 \
        || ! first_run_network_security_ready; then
        error "网络安全基线应用失败，正在恢复原参数"
        if first_run_network_security_restore "$EXISTED" "$BACKUP" "$RUNTIME"; then
            safety_release_after_failure restored
        else
            safety_release_after_failure unverified
        fi
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        audit_action "应用首次开荒内核网络安全基线" FAILED
        return 1
    fi
    rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
    audit_action "应用首次开荒内核网络安全基线" SUCCESS
    info "内核网络安全基线已应用，BBR 性能配置未被改动"
    safety_confirm
}

first_run_access_setup() {
    print_header "首次开荒 · 用户与 SSH 安全接管"
    first_run_access_ready && { info "非 root 公钥管理员和推荐 SSH 登录策略已经就绪"; return 0; }
    if ssh_read_port_state; then
        warn "检测到未完成的 SSH 端口迁移：$OLD_PORT → $NEW_PORT"
        change_port
        ssh_read_port_state && { warn "请先完成或回滚 SSH 端口迁移"; return 1; }
    fi
    if [ "$(user_ready_admin_count)" -eq 0 ]; then
        user_recommended_wizard
        first_run_access_ready
        return $?
    fi

    local ADMIN CONFIRM
    info "检测到可通过公钥接管的非 root 管理员，可直接完成 SSH 安全策略"
    ADMIN=$(user_select_ready_admin) || { warn "未选择管理员"; return 1; }
    warn "请先在另一个终端用 $ADMIN 的密钥登录，并成功执行 sudo -v"
    read -rp "  测试成功后输入管理员用户名 $ADMIN: " CONFIRM
    [ "$CONFIRM" = "$ADMIN" ] || { warn "未确认，SSH 策略未修改"; return 1; }
    read -rp "  是否先迁移 SSH 端口？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' && change_port
    ssh_apply_recommended_policy "$ADMIN" || return 1
    first_run_access_ready
}

first_run_recommended_firewall() {
    if command -v apt-get >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; then
        printf 'ufw\n'
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        printf 'firewalld\n'
    else
        printf 'unknown\n'
    fi
}

first_run_firewall_fail2ban_setup() {
    print_header "首次开荒 · 防火墙与 Fail2ban"
    local TYPE RECOMMENDED
    TYPE=$(fw_detect)
    case "$TYPE" in
        conflict)
            error "检测到 UFW 与 firewalld 冲突，请先选择并整理防火墙后端"
            firewall_menu
            ;;
        ufw|firewalld)
            if [ "$(fw_running "$TYPE")" != active ] || ! first_run_firewall_ready; then
                fw_install "$TYPE" || return 1
            else
                info "$TYPE 已运行，SSH 端口规则验证通过"
            fi
            ;;
        none)
            RECOMMENDED=$(first_run_recommended_firewall)
            if [ "$RECOMMENDED" = unknown ]; then
                warn "无法自动推荐防火墙后端，请手动选择"
                firewall_menu
            else
                info "根据当前发行版推荐安装 $RECOMMENDED"
                fw_install "$RECOMMENDED" || return 1
            fi
            ;;
    esac
    first_run_firewall_ready || { error "防火墙尚未达到最小开放并保护 SSH 的状态"; return 1; }
    if safety_timer_pending; then
        warn "防火墙防断联回滚仍在计时；确认连接后再继续配置 Fail2ban"
        return 1
    fi
    if first_run_fail2ban_ready; then
        info "Fail2ban sshd jail 已运行，端口与当前 SSH 一致"
    else
        f2b_install || return 1
    fi
    first_run_fail2ban_ready || { error "Fail2ban 尚未通过运行状态与端口检查"; return 1; }
    audit_action "完成首次开荒防火墙与 Fail2ban" SUCCESS
}

first_run_auto_updates_apply() {
    print_header "首次开荒 · 自动安全更新"
    system_auto_updates_supported \
        || { warn "当前发行版不支持由 Quench 自动托管安全更新"; return 1; }
    system_auto_updates_enabled && { info "自动安全更新已经启用"; return 0; }
    confirm_change_preview "自动安全更新" \
        "启用发行版提供的定时安全更新" \
        "Debian / Ubuntu 明确禁止 unattended-upgrades 自动重启" \
        "更新安装后如需重启，将由系统提示并交给管理员安排" \
        || { warn "已取消"; return 0; }
    system_enable_auto_security_updates
}

first_run_final_audit() {
    security_audit
    echo ""
    menu_group "首次开荒基线"
    first_run_print_status
    audit_action "执行首次开荒最终体检" SUCCESS
}

first_run_offer_step() {
    local LABEL="$1" DEFAULT="$2" FUNCTION="$3" ANSWER
    read -rp "  ${LABEL}？($([ "$DEFAULT" = y ] && echo 'Y/n，默认Y' || echo 'y/N，默认N')): " ANSWER
    ANSWER=${ANSWER:-$DEFAULT}
    echo "$ANSWER" | grep -qiE '^y(es)?$' || { info "已跳过：$LABEL"; return 0; }
    "$FUNCTION"
}

first_run_recommended_flow() {
    print_header "首次开荒 · 推荐流程"
    echo "  环境与 DNS 预检 → 配置备份 → 用户与 SSH → 防火墙与 Fail2ban"
    echo "  → SSH 基线 → 自动安全更新 → 网络安全基线 → 可选 BBR → 最终体检"
    echo ""
    ui_hint "每一步都会单独确认；已完成项目按实时状态跳过，可随时退出后重新进入"
    local ANSWER BACKUP
    read -rp "  开始推荐流程？(y/N): " ANSWER
    echo "$ANSWER" | grep -qiE '^y(es)?$' || return 0

    first_run_preflight || { warn "预检未通过，推荐流程已停止"; return 1; }
    BACKUP=$(config_backup_create first_run_wizard true) \
        && info "配置快照已创建：$BACKUP" \
        || { error "配置备份失败，推荐流程已停止"; return 1; }

    first_run_access_ready \
        || first_run_offer_step "配置用户与 SSH 安全接管" y first_run_access_setup \
        || { warn "用户与 SSH 步骤未完成，可稍后继续"; return 1; }
    first_run_firewall_ready && first_run_fail2ban_ready \
        || first_run_offer_step "配置防火墙与 Fail2ban" y first_run_firewall_fail2ban_setup \
        || { warn "防火墙与 Fail2ban 步骤未完成，可稍后继续"; return 1; }
    first_run_ssh_baseline_ready \
        || first_run_offer_step "应用 SSH 基础加固" y first_run_ssh_baseline_apply \
        || { warn "SSH 基础加固未完成，可稍后继续"; return 1; }
    if system_auto_updates_supported; then
        system_auto_updates_enabled \
            || first_run_offer_step "启用自动安全更新" y first_run_auto_updates_apply \
            || { warn "自动安全更新未完成，可稍后继续"; return 1; }
    else
        info "当前发行版不支持由 Quench 自动托管安全更新，已跳过"
    fi
    first_run_network_security_ready \
        || first_run_offer_step "应用内核网络安全基线" y first_run_network_security_apply \
        || { warn "内核网络安全基线未完成，可稍后继续"; return 1; }
    if safety_timer_pending; then
        warn "防断联回滚仍在计时；确认网络正常后再继续 BBR"
        return 1
    fi
    if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
        first_run_offer_step "进入 BBR 智能向导（可选）" n bbr_smart_wizard || true
    fi
    first_run_final_audit
    info "首次开荒推荐流程已执行完成；请处理体检中仍显示的警告"
}

first_run_wizard() {
    local CHOICE BACKUP
    while true; do
        print_header "首次开荒向导"
        menu_group "实时状态"
        first_run_print_status
        echo ""
        menu_group "开荒步骤"
        menu_pair "1" "环境与 DNS 预检" "2" "创建配置备份"
        menu_pair "3" "用户与 SSH 安全接管" "4" "防火墙与 Fail2ban"
        menu_pair "5" "SSH 基础加固" "6" "自动安全更新"
        menu_pair "7" "内核网络安全基线" "8" "BBR 智能向导"
        menu_pair "9" "最终安全体检" "r" "按推荐顺序执行" "$CYAN" "$GREEN"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择步骤 [0-9 / r]: ')" CHOICE
        case "$CHOICE" in
            1) first_run_preflight; ui_pause ;;
            2)
                BACKUP=$(config_backup_create first_run_wizard true) \
                    && info "配置快照已创建：$BACKUP" \
                    || error "配置备份失败"
                ui_pause
                ;;
            3) first_run_access_setup; ui_pause ;;
            4) first_run_firewall_fail2ban_setup; ui_pause ;;
            5) first_run_ssh_baseline_apply; ui_pause ;;
            6) first_run_auto_updates_apply; ui_pause ;;
            7) first_run_network_security_apply; ui_pause ;;
            8) bbr_smart_wizard; ui_pause ;;
            9) first_run_final_audit; ui_pause ;;
            r|R) first_run_recommended_flow; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
