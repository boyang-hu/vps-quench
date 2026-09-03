# ══════════════════════════════════════════════════════════
#  DNS 管理与诊断模块
# ══════════════════════════════════════════════════════════

dns_resolv_file() { printf '%s\n' "${DNS_RESOLV_FILE:-/etc/resolv.conf}"; }
dns_resolved_dropin() { printf '%s\n' "${DNS_RESOLVED_DROPIN:-/etc/systemd/resolved.conf.d/99-quench.conf}"; }
dns_resolvconf_head() { printf '%s\n' "${DNS_RESOLVCONF_HEAD:-/etc/resolvconf/resolv.conf.d/head}"; }

dns_nm_default_iface() {
    default_iface 2>/dev/null || true
}

dns_nm_connection_uuid() {
    local IFACE="${1:-}" UUID
    [ -n "$IFACE" ] || return 1
    UUID=$(nmcli -g GENERAL.CON-UUID device show "$IFACE" 2>/dev/null | awk 'NF && $0 != "--" {print; exit}')
    if [ -z "$UUID" ]; then
        UUID=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v iface="$IFACE" '$2 == iface {print $1; exit}')
    fi
    [ -n "$UUID" ] || return 1
    printf '%s\n' "$UUID"
}

dns_backend_detect() {
    local RESOLV IFACE
    RESOLV=$(dns_resolv_file)
    IFACE=$(dns_nm_default_iface)
    if command -v nmcli >/dev/null 2>&1 && svc_is_active NetworkManager \
        && [ -n "$IFACE" ] && dns_nm_connection_uuid "$IFACE" >/dev/null 2>&1; then
        echo NetworkManager
    elif command -v resolvectl >/dev/null 2>&1 \
        && { svc_is_active systemd-resolved \
            || { [ -L "$RESOLV" ] && readlink "$RESOLV" 2>/dev/null | grep -q 'systemd/resolve'; }; }; then
        echo systemd-resolved
    elif command -v resolvconf >/dev/null 2>&1; then
        echo resolvconf
    elif [ -L "$RESOLV" ]; then
        echo managed-symlink
    else
        echo static
    fi
}

dns_backend_label() {
    case "$1" in
        NetworkManager) echo 'NetworkManager（默认连接）' ;;
        systemd-resolved) echo systemd-resolved ;;
        resolvconf) echo resolvconf ;;
        managed-symlink) echo '未知托管后端（符号链接）' ;;
        *) echo '静态 /etc/resolv.conf' ;;
    esac
}

dns_effective_servers() {
    local BACKEND="$1" IFACE="${2:-}" RESOLV
    RESOLV=$(dns_resolv_file)
    case "$BACKEND" in
        NetworkManager)
            nmcli -g IP4.DNS,IP6.DNS device show "$IFACE" 2>/dev/null | awk 'NF && !seen[$0]++'
            ;;
        systemd-resolved)
            resolvectl dns 2>/dev/null \
                | awk '{sub(/^.*: /, ""); for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-Fa-f:.]+$/ && !seen[$i]++) print $i}'
            ;;
        *)
            awk '$1 == "nameserver" && NF >= 2 && !seen[$2]++ {print $2}' "$RESOLV" 2>/dev/null
            ;;
    esac
}

dns_show_current() {
    local BACKEND IFACE UUID SERVER COUNT=0
    BACKEND=$(dns_backend_detect)
    IFACE=$(dns_nm_default_iface)
    echo -e "  ${BOLD}DNS 后端：${NC}$(dns_backend_label "$BACKEND")"
    if [ "$BACKEND" = NetworkManager ]; then
        UUID=$(dns_nm_connection_uuid "$IFACE" 2>/dev/null || true)
        echo -e "  ${BOLD}默认连接：${NC}${IFACE:-未知}${UUID:+  ${DIM}$UUID${NC}}"
    elif [ -n "$IFACE" ]; then
        echo -e "  ${BOLD}默认网卡：${NC}$IFACE"
    fi
    echo -e "  ${BOLD}当前有效上游：${NC}"
    while IFS= read -r SERVER; do
        [ -n "$SERVER" ] || continue
        COUNT=$((COUNT + 1))
        if [[ "$SERVER" == *:* ]]; then
            echo -e "    ${YELLOW}$SERVER${NC}  ${DIM}(IPv6)${NC}"
        else
            echo -e "    ${CYAN}$SERVER${NC}  ${DIM}(IPv4)${NC}"
        fi
    done < <(dns_effective_servers "$BACKEND" "$IFACE")
    [ "$COUNT" -gt 0 ] || echo -e "    ${YELLOW}未能读取有效上游 DNS${NC}"
    [ "$BACKEND" != managed-symlink ] \
        || warn "无法识别 /etc/resolv.conf 的管理程序；为避免配置被覆盖，Quench 不会直接写入该链接"
}

# 只有同时具备全局地址和可用路由，才启用对应协议族的 DNS。
dns_detect_network() {
    local HAS_V4=false HAS_V6=false V6_DISABLED
    if ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' \
        && ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        HAS_V4=true
    fi
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
    if [ "$V6_DISABLED" != 1 ] \
        && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' \
        && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_V6=true
    fi
    echo "${HAS_V4}:${HAS_V6}"
}

dns_ipv4_valid() {
    local VALUE="$1" OCTET
    local -a OCTETS=()
    [[ "$VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a OCTETS <<< "$VALUE"
    [ "${#OCTETS[@]}" -eq 4 ] || return 1
    for OCTET in "${OCTETS[@]}"; do
        [[ "$OCTET" =~ ^[0-9]+$ ]] && [ "$OCTET" -le 255 ] || return 1
    done
}

dns_ipv6_valid() {
    local VALUE="$1"
    [[ "$VALUE" == *:* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$VALUE" >/dev/null 2>&1
    else
        [[ "$VALUE" =~ ^[0-9A-Fa-f:]+$ ]] \
            && ip -6 route get "$VALUE" >/dev/null 2>&1
    fi
}

dns_list_validate() {
    local LIST="$1" FAMILY="$2" SERVER
    [ -n "$LIST" ] || return 0
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $LIST; do
        case "$FAMILY" in
            4) dns_ipv4_valid "$SERVER" || return 1 ;;
            6) dns_ipv6_valid "$SERVER" || return 1 ;;
            *) return 1 ;;
        esac
    done
}

# 返回 0=直连查询成功，1=失败，2=系统缺少直连查询工具。
dns_probe_server() {
    local SERVER="$1"
    if command -v dig >/dev/null 2>&1; then
        dig @"$SERVER" example.com A +time=2 +tries=1 +short 2>/dev/null | grep -qE '^[0-9]+\.' \
            && dig @"$SERVER" example.com A +tcp +time=2 +tries=1 +short 2>/dev/null | grep -qE '^[0-9]+\.'
    elif command -v nslookup >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 nslookup example.com "$SERVER" >/dev/null 2>&1
        else
            nslookup example.com "$SERVER" >/dev/null 2>&1
        fi
    else
        return 2
    fi
}

dns_filter_reachable() {
    local LIST="$1" FAMILY="$2" SERVER RC
    DNS_FILTERED=""
    [ -n "$LIST" ] || return 0
    if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
        warn "未安装 dig/nslookup，跳过逐台 DNS 直连预检"
        DNS_FILTERED="$LIST"
        return 0
    fi
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $LIST; do
        RC=0
        dns_probe_server "$SERVER" || RC=$?
        if [ "$RC" -eq 0 ]; then
            DNS_FILTERED="${DNS_FILTERED:+$DNS_FILTERED }$SERVER"
            info "IPv${FAMILY} DNS 直连正常：$SERVER"
        else
            warn "IPv${FAMILY} DNS 无法完成直连查询，已从本次配置排除：$SERVER"
        fi
    done
}

dns_atomic_write() {
    local TARGET="$1" CONTENT="$2" DIR TMP
    DIR=$(dirname "$TARGET")
    mkdir -p "$DIR" || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    printf '%s\n' "$CONTENT" > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 644 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$TARGET" || { rm -f "$TMP"; return 1; }
}

dns_apply_resolved() {
    local ALL_DNS="$1" DROPIN CONTENT
    DROPIN=$(dns_resolved_dropin)
    CONTENT="[Resolve]
DNS=$ALL_DNS
FallbackDNS=
Domains=~."
    dns_atomic_write "$DROPIN" "$CONTENT" || return 1
    svc_restart systemd-resolved || return 1
    resolvectl flush-caches >/dev/null 2>&1 || true
}

dns_apply_nm() {
    local V4_LIST="$1" V6_LIST="$2" IFACE UUID
    IFACE=$(dns_nm_default_iface)
    UUID=$(dns_nm_connection_uuid "$IFACE") || return 1
    if [ -n "$V4_LIST" ]; then
        nmcli connection modify "$UUID" ipv4.ignore-auto-dns yes ipv4.dns "$V4_LIST" \
            ipv4.dns-priority 10 +ipv4.dns-search '~.' >/dev/null 2>&1 || return 1
    else
        nmcli connection modify "$UUID" ipv4.ignore-auto-dns yes ipv4.dns '' ipv4.dns-priority 10 >/dev/null 2>&1 || return 1
        nmcli connection modify "$UUID" -ipv4.dns-search '~.' >/dev/null 2>&1 || true
    fi
    if [ -n "$V6_LIST" ]; then
        nmcli connection modify "$UUID" ipv6.ignore-auto-dns yes ipv6.dns "$V6_LIST" \
            ipv6.dns-priority 10 +ipv6.dns-search '~.' >/dev/null 2>&1 || return 1
    else
        nmcli connection modify "$UUID" ipv6.ignore-auto-dns yes ipv6.dns '' ipv6.dns-priority 10 >/dev/null 2>&1 || return 1
        nmcli connection modify "$UUID" -ipv6.dns-search '~.' >/dev/null 2>&1 || true
    fi
    nmcli device reapply "$IFACE" >/dev/null 2>&1 || return 1
}

dns_apply_resolvconf() {
    local ALL_DNS="$1" HEAD DIR TMP SERVER
    HEAD=$(dns_resolvconf_head)
    DIR=$(dirname "$HEAD")
    mkdir -p "$DIR" || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    awk '$1 != "nameserver"' "$HEAD" 2>/dev/null > "$TMP" || true
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $ALL_DNS; do printf 'nameserver %s\n' "$SERVER" >> "$TMP"; done
    chmod 644 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$HEAD" || { rm -f "$TMP"; return 1; }
    resolvconf -u >/dev/null 2>&1
}

dns_apply_static() {
    local ALL_DNS="$1" RESOLV DIR TMP SERVER IMMUTABLE=false
    RESOLV=$(dns_resolv_file)
    [ ! -L "$RESOLV" ] || return 1
    DIR=$(dirname "$RESOLV")
    mkdir -p "$DIR" || return 1
    if command -v lsattr >/dev/null 2>&1 \
        && lsattr -d "$RESOLV" 2>/dev/null | awk '{print $1}' | grep -q i; then
        IMMUTABLE=true
    fi
    [ "$IMMUTABLE" = false ] || chattr -i "$RESOLV" 2>/dev/null || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    [ ! -e "$RESOLV" ] || cp -a "$RESOLV" "$TMP" 2>/dev/null || true
    awk '$1 != "nameserver"' "$RESOLV" 2>/dev/null > "$TMP" || true
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $ALL_DNS; do printf 'nameserver %s\n' "$SERVER" >> "$TMP"; done
    chmod 644 "$TMP" 2>/dev/null || true
    if ! mv -f "$TMP" "$RESOLV"; then
        rm -f "$TMP"
        [ "$IMMUTABLE" = false ] || chattr +i "$RESOLV" 2>/dev/null || true
        return 1
    fi
    [ "$IMMUTABLE" = false ] || chattr +i "$RESOLV" 2>/dev/null || return 1
}

dns_flush_caches() {
    resolvectl flush-caches >/dev/null 2>&1 || true
    if command -v nscd >/dev/null 2>&1; then nscd -i hosts >/dev/null 2>&1 || true; fi
}

dns_system_resolves() {
    local DOMAIN
    for DOMAIN in github.com example.com; do
        if command -v getent >/dev/null 2>&1; then
            getent ahosts "$DOMAIN" >/dev/null 2>&1 || return 1
        elif command -v host >/dev/null 2>&1; then
            host "$DOMAIN" >/dev/null 2>&1 || return 1
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup "$DOMAIN" >/dev/null 2>&1 || return 1
        else
            return 2
        fi
    done
}

dns_effective_matches() {
    local BACKEND="$1" IFACE="$2" EXPECTED="$3" EFFECTIVE SERVER
    EFFECTIVE=$(dns_effective_servers "$BACKEND" "$IFACE")
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $EXPECTED; do
        printf '%s\n' "$EFFECTIVE" | grep -Fxq "$SERVER" && return 0
    done
    return 1
}

dns_fail_and_rollback() {
    local MESSAGE="$1" BACKEND="$2"
    error "$MESSAGE"
    audit_action "DNS 更新失败，后端 $BACKEND" FAILED
    if safety_rollback_now; then
        warn "已立即恢复本次 DNS 修改前的配置"
    fi
    return 1
}

dns_write() {
    local V4_LIST="$1" V6_LIST="$2" HAS_V6="$3"
    local BACKEND IFACE ALL_DNS CURRENT_DNS NET_INFO HAS_V4_ROUTE HAS_V6_ROUTE EFFECTIVE_PATHS=() RESOLVE_RC=0
    dns_list_validate "$V4_LIST" 4 || { error "IPv4 DNS 地址格式不正确"; return 1; }
    dns_list_validate "$V6_LIST" 6 || { error "IPv6 DNS 地址格式不正确"; return 1; }
    NET_INFO=$(dns_detect_network)
    HAS_V4_ROUTE=${NET_INFO%%:*}
    HAS_V6_ROUTE=${NET_INFO##*:}
    if [ "$HAS_V4_ROUTE" != true ] && [ -n "$V4_LIST" ]; then
        warn "当前没有可用 IPv4 路由，本次不写入 IPv4 DNS"
        V4_LIST=""
    fi
    if { [ "$HAS_V6" != true ] || [ "$HAS_V6_ROUTE" != true ]; } && [ -n "$V6_LIST" ]; then
        warn "当前没有可用 IPv6 路由，本次不写入 IPv6 DNS"
        V6_LIST=""
    fi

    dns_filter_reachable "$V4_LIST" 4
    V4_LIST="$DNS_FILTERED"
    dns_filter_reachable "$V6_LIST" 6
    V6_LIST="$DNS_FILTERED"
    ALL_DNS="$V4_LIST${V4_LIST:+${V6_LIST:+ }}$V6_LIST"
    [ -n "$ALL_DNS" ] || { error "候选 DNS 均无法直连，未修改系统配置"; return 1; }

    BACKEND=$(dns_backend_detect)
    IFACE=$(dns_nm_default_iface)
    [ "$BACKEND" != managed-symlink ] || {
        error "无法识别 /etc/resolv.conf 的托管后端，拒绝直接覆盖符号链接"
        return 1
    }
    CURRENT_DNS=$(dns_effective_servers "$BACKEND" "$IFACE" | awk '{printf "%s%s", sep, $0; sep=" "}')
    confirm_change_preview "DNS 管理" \
        "后端：$(dns_backend_label "$BACKEND")" \
        "作用范围：${IFACE:-全局}" \
        "当前上游：${CURRENT_DNS:-未读取到}" \
        "目标上游：$ALL_DNS" || { warn "已取消"; return 0; }

    case "$BACKEND" in
        systemd-resolved) EFFECTIVE_PATHS+=("$(dns_resolved_dropin)") ;;
        resolvconf) EFFECTIVE_PATHS+=("$(dns_resolvconf_head)") ;;
        static) EFFECTIVE_PATHS+=("$(dns_resolv_file)") ;;
    esac
    safety_arm dns "${EFFECTIVE_PATHS[@]}" || return 1

    case "$BACKEND" in
        systemd-resolved) dns_apply_resolved "$ALL_DNS" \
            || { dns_fail_and_rollback "systemd-resolved 配置应用失败" "$BACKEND"; return 1; } ;;
        NetworkManager) dns_apply_nm "$V4_LIST" "$V6_LIST" \
            || { dns_fail_and_rollback "NetworkManager 默认连接的 DNS 应用失败" "$BACKEND"; return 1; } ;;
        resolvconf) dns_apply_resolvconf "$ALL_DNS" \
            || { dns_fail_and_rollback "resolvconf 配置应用失败" "$BACKEND"; return 1; } ;;
        static) dns_apply_static "$ALL_DNS" \
            || { dns_fail_and_rollback "静态 resolv.conf 写入失败" "$BACKEND"; return 1; } ;;
        *) dns_fail_and_rollback "不支持的 DNS 后端：$BACKEND" "$BACKEND"; return 1 ;;
    esac

    dns_flush_caches
    dns_effective_matches "$BACKEND" "$IFACE" "$ALL_DNS" \
        || { dns_fail_and_rollback "后端未报告本次设置的 DNS，上游可能没有真正生效" "$BACKEND"; return 1; }
    dns_system_resolves || RESOLVE_RC=$?
    if [ "$RESOLVE_RC" -eq 1 ]; then
        dns_fail_and_rollback "系统域名解析测试失败" "$BACKEND"
        return 1
    elif [ "$RESOLVE_RC" -eq 2 ]; then
        warn "系统缺少 getent/host/nslookup，仅完成了后端生效检查"
    fi

    info "DNS 已通过 $BACKEND 持久化，且有效上游检查通过 ✓"
    audit_action "更新 DNS，后端 ${BACKEND}，上游 $ALL_DNS" SUCCESS
    echo ""
    dns_show_current
    safety_confirm
}

dns_custom_prompt() {
    local HAS_V6="$1" V4_LIST V6_LIST=""
    echo -e "  ${DIM}多个地址用空格或英文逗号分隔；可以只填一个协议族。${NC}"
    read -rp "  IPv4 DNS（可留空）: " V4_LIST
    V4_LIST=$(printf '%s' "$V4_LIST" | tr ',' ' ' | awk '{$1=$1; print}')
    if [ "$HAS_V6" = true ]; then
        read -rp "  IPv6 DNS（可留空）: " V6_LIST
        V6_LIST=$(printf '%s' "$V6_LIST" | tr ',' ' ' | awk '{$1=$1; print}')
    fi
    [ -n "$V4_LIST$V6_LIST" ] || { warn "没有输入 DNS 地址"; return 1; }
    dns_write "$V4_LIST" "$V6_LIST" "$HAS_V6"
}

dns_menu() {
    while true; do
        print_header "DNS 管理与诊断"
        dns_show_current
        echo ""

        local NET_INFO HAS_V4 HAS_V6 V4_LABEL V6_LABEL CH
        NET_INFO=$(dns_detect_network)
        HAS_V4=${NET_INFO%%:*}
        HAS_V6=${NET_INFO##*:}
        [ "$HAS_V4" = true ] && V4_LABEL="${GREEN}IPv4 路由可用${NC}" || V4_LABEL="${YELLOW}IPv4 不可用${NC}"
        [ "$HAS_V6" = true ] && V6_LABEL="${GREEN}IPv6 路由可用${NC}" || V6_LABEL="${DIM}IPv6 不可用${NC}"
        echo -e "  网络：$V4_LABEL  $V6_LABEL"
        echo -e "  ${DIM}应用前会逐台直连测试；失败的候选不会写入配置。${NC}"
        echo ""

        menu_div
        echo -e "  ${BOLD}国际公共 DNS：${NC}"
        menu_item "1" "Cloudflare  ${DIM}1.1.1.1 / 1.0.0.1${NC}"
        menu_item "2" "Google  ${DIM}8.8.8.8 / 8.8.4.4${NC}"
        menu_item "3" "跨运营商冗余  ${DIM}Cloudflare + Google${NC}"
        menu_div
        echo -e "  ${BOLD}中国大陆公共 DNS：${NC}"
        menu_item "4" "阿里云  ${DIM}223.5.5.5 / 223.6.6.6${NC}"
        menu_item "5" "腾讯 DNSPod  ${DIM}119.29.29.29${NC}"
        menu_item "6" "114 DNS  ${DIM}114.114.114.114 / 114.114.115.115${NC}"
        menu_div
        menu_item "7" "自定义 DNS 地址"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择 DNS [0-7]: ')" CH

        case "$CH" in
            1) dns_write "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001" "$HAS_V6" ;;
            2) dns_write "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844" "$HAS_V6" ;;
            3) dns_write "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888" "$HAS_V6" ;;
            4) dns_write "223.5.5.5 223.6.6.6" "2400:3200::1 2400:3200:baba::1" "$HAS_V6" ;;
            5) dns_write "119.29.29.29" "" "$HAS_V6" ;;
            6) dns_write "114.114.114.114 114.114.115.115" "" "$HAS_V6" ;;
            7) dns_custom_prompt "$HAS_V6" ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "$CH" != 0 ] && ui_pause
    done
}
