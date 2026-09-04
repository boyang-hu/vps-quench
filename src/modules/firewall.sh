# ══════════════════════════════════════════════════════════
#  防火墙模块
# ══════════════════════════════════════════════════════════

fw_running() {
    local TYPE="$1"
    case "$TYPE" in
        ufw) LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active' && echo active || echo inactive ;;
        firewalld) svc_is_active firewalld && echo active || echo inactive ;;
        conflict) echo conflict ;;
        *) echo none ;;
    esac
}

# 优先返回正在运行的后端；两者同时存在则显式报告冲突。
fw_detect() {
    local HAS_UFW=false HAS_FWD=false ACTIVE_UFW=false ACTIVE_FWD=false
    command -v ufw >/dev/null 2>&1 && HAS_UFW=true
    command -v firewall-cmd >/dev/null 2>&1 && HAS_FWD=true
    [ "$HAS_UFW" = true ] && [ "$(fw_running ufw)" = active ] && ACTIVE_UFW=true
    [ "$HAS_FWD" = true ] && [ "$(fw_running firewalld)" = active ] && ACTIVE_FWD=true
    if { [ "$ACTIVE_UFW" = true ] && [ "$ACTIVE_FWD" = true ]; } \
        || { [ "$HAS_UFW" = true ] && [ "$HAS_FWD" = true ] && [ "$ACTIVE_UFW" = false ] && [ "$ACTIVE_FWD" = false ]; }; then
        echo conflict
    elif [ "$ACTIVE_UFW" = true ]; then
        echo ufw
    elif [ "$ACTIVE_FWD" = true ]; then
        echo firewalld
    elif [ "$HAS_UFW" = true ]; then
        echo ufw
    elif [ "$HAS_FWD" = true ]; then
        echo firewalld
    else
        echo none
    fi
}

fw_port_spec_normalize() {
    local INPUT="$1" TYPE="$2" BASE PROTO START END SEP OUT_SEP
    [[ "$INPUT" =~ ^[0-9]+([:-][0-9]+)?(/(tcp|udp))?$ ]] || return 1
    if [[ "$INPUT" == */* ]]; then
        PROTO="${INPUT##*/}"; BASE="${INPUT%/*}"
    else
        PROTO=tcp; BASE="$INPUT"
    fi
    if [[ "$BASE" == *:* ]]; then SEP=:; elif [[ "$BASE" == *-* ]]; then SEP=-; else SEP=""; fi
    if [ -n "$SEP" ]; then
        START="${BASE%%"$SEP"*}"; END="${BASE##*"$SEP"}"
    else
        START="$BASE"; END="$BASE"
    fi
    [ "$START" -ge 1 ] && [ "$START" -le 65535 ] \
        && [ "$END" -ge "$START" ] && [ "$END" -le 65535 ] || return 1
    [ "$TYPE" = ufw ] && OUT_SEP=: || OUT_SEP=-
    if [ "$START" = "$END" ]; then
        printf '%s/%s\n' "$START" "$PROTO"
    else
        printf '%s%s%s/%s\n' "$START" "$OUT_SEP" "$END" "$PROTO"
    fi
}

fw_ipv4_valid() {
    local VALUE="${1%%/*}" PREFIX="" OCTET
    local -a OCTETS=()
    [[ "$1" == */* ]] && PREFIX="${1##*/}"
    [[ "$VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a OCTETS <<< "$VALUE"
    for OCTET in "${OCTETS[@]}"; do
        [[ "$OCTET" =~ ^[0-9]+$ ]] && [ "$OCTET" -le 255 ] || return 1
    done
    [ -z "$PREFIX" ] || { [[ "$PREFIX" =~ ^[0-9]+$ ]] && [ "$PREFIX" -le 32 ]; }
}

fw_ip_family() {
    local VALUE="$1" PREFIX
    if [[ "$VALUE" == *:* ]]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$VALUE" >/dev/null 2>&1 || return 1
        else
            [[ "$VALUE" =~ ^[0-9A-Fa-f:]+(/[0-9]+)?$ ]] || return 1
            if [[ "$VALUE" == */* ]]; then
                PREFIX="${VALUE##*/}"
                [ "$PREFIX" -le 128 ] || return 1
            fi
        fi
        echo ipv6
    elif fw_ipv4_valid "$VALUE"; then
        echo ipv4
    else
        return 1
    fi
}

fw_firewalld_zone() {
    local ZONE="" IFACE=""
    if command -v firewall-cmd >/dev/null 2>&1 && svc_is_active firewalld; then
        IFACE=$(default_iface 2>/dev/null || true)
        [ -n "$IFACE" ] && ZONE=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>/dev/null || true)
    fi
    if [ -z "$ZONE" ] && command -v firewall-cmd >/dev/null 2>&1; then
        ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    fi
    [ -z "$ZONE" ] && [ -f /etc/firewalld/firewalld.conf ] \
        && ZONE=$(awk -F= '$1 == "DefaultZone" {print $2; exit}' /etc/firewalld/firewalld.conf)
    printf '%s\n' "${ZONE:-public}"
}

fw_warn_environment() {
    if svc_is_active docker 2>/dev/null || { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
        warn "检测到 Docker：容器发布端口可能绕过 UFW，请同时检查绑定地址与 DOCKER-USER 规则"
    fi
    warn "本机防火墙不会修改云厂商安全组，请确保 SSH 端口已在云端放行"
}

fw_ufw_allow_ssh() {
    local PORT PORTS COUNT=0
    PORTS=$(ssh_effective_ports)
    [ -n "$PORTS" ] || { error "无法确定 SSH 端口，拒绝启用 UFW"; return 1; }
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        ufw limit "${PORT}/tcp" >/dev/null 2>&1 \
            || { error "ufw 无法限速放行 SSH ${PORT}/tcp"; return 1; }
        COUNT=$((COUNT + 1))
    done <<< "$PORTS"
    [ "$COUNT" -gt 0 ]
}

fw_firewalld_allow_ssh() {
    local MODE="$1" ZONE="$2" PORT PORTS COUNT=0
    PORTS=$(ssh_effective_ports)
    [ -n "$PORTS" ] || { error "无法确定 SSH 端口，拒绝启用 firewalld"; return 1; }
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        if [ "$MODE" = offline ]; then
            firewall-offline-cmd --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 \
                || { error "firewalld 无法预先放行 SSH ${PORT}/tcp"; return 1; }
        else
            firewall-cmd --permanent --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 \
                || { error "firewalld 无法放行 SSH ${PORT}/tcp"; return 1; }
        fi
        COUNT=$((COUNT + 1))
    done <<< "$PORTS"
    [ "$COUNT" -gt 0 ] || return 1
    [ "$MODE" = offline ] || firewall-cmd --reload >/dev/null 2>&1
}

fw_allow_web_ports() {
    local TYPE="$1" MODE="${2:-online}" ZONE="${3:-public}" PORT
    for PORT in 80 443; do
        case "$TYPE:$MODE" in
            ufw:*) ufw allow "${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
            firewalld:offline) firewall-offline-cmd --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
            firewalld:online) firewall-cmd --permanent --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
        esac
    done
    if [ "$TYPE:$MODE" = firewalld:online ]; then
        firewall-cmd --reload >/dev/null 2>&1 || return 1
    fi
}

fw_install() {
    local TYPE="$1" WEB_CONFIRM=n MODE=offline ZONE PORT
    print_header "安装并配置防火墙"
    fw_warn_environment
    echo -e "  ${BOLD}必须放行：${NC}SSH $(ssh_effective_ports_csv)/tcp"
    read -rp "  这台机器是否对外提供 HTTP/HTTPS？(y/N): " WEB_CONFIRM || WEB_CONFIRM=n
    echo "$WEB_CONFIRM" | grep -qiE '^y(es)?$' && WEB_CONFIRM=y || WEB_CONFIRM=n

    pkg_install "$TYPE" || { error "安装 $TYPE 失败"; return 1; }
    safety_arm "${TYPE}_install" || return 1
    case "$TYPE" in
        ufw)
            # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
            ufw default deny incoming >/dev/null 2>&1 \
                && ufw default allow outgoing >/dev/null 2>&1 \
                && ufw logging low >/dev/null 2>&1 \
                && fw_ufw_allow_ssh \
                || { safety_rollback_after_failure; error "UFW 基础策略写入失败，未启用"; return 1; }
            if [ "$WEB_CONFIRM" = y ] && ! fw_allow_web_ports ufw; then
                safety_rollback_after_failure
                error "HTTP/HTTPS 放行失败，未启用 UFW"
                return 1
            fi
            ufw --force enable >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ] \
                || { safety_rollback_after_failure; error "UFW 启用失败"; return 1; }
            while IFS= read -r PORT; do
                LC_ALL=C ufw status 2>/dev/null | grep -Eq "${PORT}/tcp.*LIMIT" \
                    || { error "UFW 启用后未找到 SSH ${PORT}/tcp 限速规则"; return 1; }
            done < <(ssh_effective_ports)
            ;;
        firewalld)
            ZONE=$(fw_firewalld_zone)
            if [ "$(fw_running firewalld)" = active ]; then
                MODE=online
            elif ! command -v firewall-offline-cmd >/dev/null 2>&1; then
                cancel_safety_timer
                error "缺少 firewall-offline-cmd，拒绝在 SSH 规则写入前启动 firewalld"
                return 1
            fi
            fw_firewalld_allow_ssh "$MODE" "$ZONE" \
                || { safety_rollback_after_failure; return 1; }
            if [ "$WEB_CONFIRM" = y ] && ! fw_allow_web_ports firewalld "$MODE" "$ZONE"; then
                safety_rollback_after_failure
                error "HTTP/HTTPS 放行失败，未启用 firewalld"
                return 1
            fi
            svc_enable firewalld || warn "firewalld 开机自启设置失败：重启后防火墙不会自动生效"
            if [ "$MODE" != online ] && ! svc_start firewalld; then
                safety_rollback_after_failure
                error "firewalld 启动失败"
                return 1
            fi
            [ "$(fw_running firewalld)" = active ] \
                || { safety_rollback_after_failure; error "firewalld 未进入运行状态"; return 1; }
            while IFS= read -r PORT; do
                firewall-cmd --zone="$ZONE" --query-port="${PORT}/tcp" >/dev/null 2>&1 \
                    || { error "firewalld 启动后未放行 SSH ${PORT}/tcp"; return 1; }
            done < <(ssh_effective_ports)
            ;;
        *) cancel_safety_timer; return 1 ;;
    esac
    info "$TYPE 已使用最小开放策略启用 ✓"
    [ "$WEB_CONFIRM" = y ] && info "HTTP 80/tcp 与 HTTPS 443/tcp 已放行"
    safety_confirm
}

ufw_show_rules() {
    print_header "防火墙规则 — UFW"
    ufw status verbose 2>/dev/null
    echo ""
    ufw status numbered 2>/dev/null
}

ufw_add_port() {
    local INPUT SPEC DIR
    print_header "添加端口规则 — UFW"
    read -rp "  端口（如 80、53/udp、3000:3010/tcp）: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" ufw) || { error "端口或协议格式无效"; return 1; }
    read -rp "  方向 [in/out，默认 in]: " DIR
    DIR="${DIR:-in}"
    [[ "$DIR" =~ ^(in|out)$ ]] || { error "方向只能是 in 或 out"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    ufw allow "$DIR" "$SPEC" >/dev/null 2>&1 && info "已放行 $DIR $SPEC ✓" || error "添加失败"
}

ufw_delete_numbered_rule() {
    local TITLE="$1" NUM
    while true; do
        print_header "$TITLE — UFW"
        ufw status numbered 2>/dev/null
        read -rp "  输入规则编号（回车返回）: " NUM
        [ -n "$NUM" ] || return
        [[ "$NUM" =~ ^[0-9]+$ ]] || { error "无效编号"; continue; }
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        echo y | ufw delete "$NUM" >/dev/null 2>&1 && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
}

ufw_del_port() { ufw_delete_numbered_rule "删除端口规则"; }
ufw_del_ip() { ufw_delete_numbered_rule "删除 IP 规则"; }

ufw_block_ip() {
    local IP FAMILY
    print_header "拉黑 IP — UFW"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    ufw deny from "$IP" to any >/dev/null 2>&1 \
        && info "已拉黑 ${IP}（${FAMILY}）✓" || error "操作失败"
}

fw_prompt_allow_scope() {
    local TYPE="$1" CH INPUT SPEC
    FW_ALLOW_SCOPE=""
    menu_item "1" "仅 SSH（推荐）"
    menu_item "2" "指定端口/协议"
    menu_item "3" "所有服务" "$YELLOW"
    read -rp "$(ui_prompt '选择放行范围 [1-3]: ')" CH
    case "$CH" in
        1)
            FW_ALLOW_SCOPE=ssh
            ;;
        2)
            read -rp "  端口（如 443/tcp、53/udp）: " INPUT
            SPEC=$(fw_port_spec_normalize "$INPUT" "$TYPE") || return 1
            FW_ALLOW_SCOPE="$SPEC"
            ;;
        3) FW_ALLOW_SCOPE=all ;;
        *) return 1 ;;
    esac
}

ufw_allow_ip() {
    local IP FAMILY SCOPE BASE PROTO PORT FAILED=false
    print_header "放行来源 IP — UFW"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    fw_prompt_allow_scope ufw || { error "放行范围无效"; return 1; }
    SCOPE="$FW_ALLOW_SCOPE"
    if [ "$SCOPE" = all ]; then
        warn "这将允许 $IP 访问所有服务"
        ufw allow from "$IP" to any >/dev/null 2>&1 || FAILED=true
    elif [ "$SCOPE" = ssh ]; then
        while IFS= read -r PORT; do
            [ -n "$PORT" ] || continue
            ufw allow from "$IP" to any port "$PORT" proto tcp >/dev/null 2>&1 || FAILED=true
        done < <(ssh_effective_ports)
    else
        BASE="${SCOPE%/*}"; PROTO="${SCOPE##*/}"
        ufw allow from "$IP" to any port "$BASE" proto "$PROTO" >/dev/null 2>&1 || FAILED=true
    fi
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    [ "$FAILED" = false ] && info "已放行 ${IP}（${FAMILY}，范围 ${SCOPE}）✓" || error "操作失败"
}

ufw_quick_allow() {
    local CONFIRM
    print_header "快速放行 Web 服务 — UFW"
    echo -e "  将保证 SSH $(ssh_effective_ports_csv)/tcp，并放行 80/tcp、443/tcp"
    read -rp "  确认？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    fw_ufw_allow_ssh && fw_allow_web_ports ufw \
        && info "SSH / HTTP / HTTPS 已放行 ✓" || error "放行失败"
}

fwd_show_rules() {
    local ZONE
    ZONE=$(fw_firewalld_zone)
    print_header "防火墙规则 — firewalld"
    firewall-cmd --zone="$ZONE" --list-all 2>/dev/null
}

fwd_add_port() {
    local INPUT SPEC ZONE
    print_header "添加端口规则 — firewalld"
    read -rp "  端口（如 80/tcp、53/udp、3000-3010/tcp）: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" firewalld) || { error "端口或协议格式无效"; return 1; }
    ZONE=$(fw_firewalld_zone)
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    firewall-cmd --permanent --zone="$ZONE" --add-port="$SPEC" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已放行 $SPEC ✓" || error "添加失败"
}

fwd_del_port() {
    local INPUT SPEC ZONE
    print_header "删除端口规则 — firewalld"
    ZONE=$(fw_firewalld_zone)
    firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null
    read -rp "  输入要删除的端口/协议: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" firewalld) || { error "格式无效"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    firewall-cmd --permanent --zone="$ZONE" --remove-port="$SPEC" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "端口 $SPEC 已删除 ✓" || error "删除失败"
}

fwd_block_ip() {
    local IP FAMILY ZONE RULE
    print_header "拉黑 IP — firewalld"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    ZONE=$(fw_firewalld_zone)
    RULE="rule family='${FAMILY}' source address='${IP}' reject"
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已拉黑 $IP ✓" || error "操作失败"
}

fwd_allow_ip() {
    local IP FAMILY SCOPE BASE PROTO ZONE RULE PORT FAILED=false
    print_header "放行来源 IP — firewalld"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    fw_prompt_allow_scope firewalld || { error "放行范围无效"; return 1; }
    SCOPE="$FW_ALLOW_SCOPE"
    ZONE=$(fw_firewalld_zone)
    if [ "$SCOPE" = all ]; then
        warn "这将允许 $IP 访问所有服务"
        RULE="rule family='${FAMILY}' source address='${IP}' accept"
        firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
    elif [ "$SCOPE" = ssh ]; then
        while IFS= read -r PORT; do
            [ -n "$PORT" ] || continue
            RULE="rule family='${FAMILY}' source address='${IP}' port port='${PORT}' protocol='tcp' accept"
            firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
        done < <(ssh_effective_ports)
    else
        BASE="${SCOPE%/*}"; PROTO="${SCOPE##*/}"
        RULE="rule family='${FAMILY}' source address='${IP}' port port='${BASE}' protocol='${PROTO}' accept"
        firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
    fi
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    [ "$FAILED" = false ] && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已放行 ${IP}（范围 ${SCOPE}）✓" || error "操作失败"
}

fwd_del_ip() {
    local ZONE NUM i=1
    local RULES=() RULE
    ZONE=$(fw_firewalld_zone)
    while IFS= read -r RULE; do [ -n "$RULE" ] && RULES+=("$RULE"); done < <(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null)
    [ "${#RULES[@]}" -gt 0 ] || { warn "暂无 Rich Rule"; return; }
    print_header "删除 IP 规则 — firewalld"
    for RULE in "${RULES[@]}"; do echo -e "  ${YELLOW}[$i]${NC} $RULE"; i=$((i + 1)); done
    read -rp "  输入要删除的规则编号: " NUM
    [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "${#RULES[@]}" ] \
        || { error "无效编号"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="${RULES[$((NUM - 1))]}" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
}

fwd_quick_allow() {
    local CONFIRM ZONE
    print_header "快速放行 Web 服务 — firewalld"
    echo -e "  将保证 SSH $(ssh_effective_ports_csv)/tcp，并放行 80/tcp、443/tcp"
    read -rp "  确认？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    ZONE=$(fw_firewalld_zone)
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    fw_firewalld_allow_ssh online "$ZONE" && fw_allow_web_ports firewalld online "$ZONE" \
        && info "SSH / HTTP / HTTPS 已放行 ✓" || error "放行失败"
}

fw_uninstall() {
    local TYPE="$1" CONFIRM PURGE CONFIG_DIR
    print_header "卸载 $TYPE"
    warn "卸载会停止该防火墙，主机将交由云安全组或其他防火墙保护"
    warn "默认保留配置；不会 flush iptables/nftables，也不会删除其他管理器的规则"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    case "$TYPE" in
        ufw) ufw --force disable >/dev/null 2>&1 || true; CONFIG_DIR=/etc/ufw ;;
        firewalld) svc_stop firewalld >/dev/null 2>&1 || true; svc_disable firewalld >/dev/null 2>&1 || true; CONFIG_DIR=/etc/firewalld ;;
        *) return 1 ;;
    esac
    pkg_remove "$TYPE" || { error "卸载 $TYPE 失败"; return 1; }
    info "$TYPE 已卸载，配置目录已保留 ✓"
    if [ -d "$CONFIG_DIR" ]; then
        read -rp "  输入 PURGE 才会删除整个 ${CONFIG_DIR}（含非 Quench 规则）: " PURGE
        if [ "$PURGE" = PURGE ]; then
            rm -rf "$CONFIG_DIR"
            info "已删除 ${CONFIG_DIR}；该操作需从配置备份恢复"
        fi
    fi
}

ufw_menu() {
    while true; do
        local STATUS ST_COLOR CH OK=true
        STATUS=$(fw_running ufw); [ "$STATUS" = active ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"
        print_header "防火墙管理 — UFW"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        [ "$STATUS" = active ] && menu_item "1" "关闭防火墙" "$YELLOW" || menu_item "1" "开启防火墙"
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行来源 IP" "7" "删除 IP 规则"
        menu_item "8" "快速放行 SSH + Web"
        menu_pair "u" "安装 / 修复" "9" "安全卸载 UFW" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-9 / u]: ')" CH
        case "$CH" in 1|3|4|5|6|7|8) safety_arm ufw || continue ;; esac
        case "$CH" in
            1)
                if [ "$STATUS" = active ]; then
                    ufw --force disable >/dev/null 2>&1 || OK=false
                else
                    ufw --force enable >/dev/null 2>&1 || OK=false
                fi
                ;;
            2) ufw_show_rules; OK=false ;;
            3) ufw_add_port || OK=false ;;
            4) ufw_del_port || OK=false ;;
            5) ufw_block_ip || OK=false ;;
            6) ufw_allow_ip || OK=false ;;
            7) ufw_del_ip || OK=false ;;
            8) ufw_quick_allow || OK=false ;;
            u|U) fw_install ufw; OK=false ;;
            9) fw_uninstall ufw; return ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; OK=false ;;
        esac
        case "$CH" in 1|3|4|5|6|7|8) if [ "$OK" = true ]; then safety_confirm; else safety_rollback_after_failure; fi ;; esac
        [ "$CH" != 0 ] && ui_pause
    done
}

fwd_menu() {
    while true; do
        local STATUS ST_COLOR CH OK=true
        STATUS=$(fw_running firewalld); [ "$STATUS" = active ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"
        print_header "防火墙管理 — firewalld"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        [ "$STATUS" = active ] && menu_item "1" "关闭防火墙" "$YELLOW" || menu_item "1" "开启防火墙"
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行来源 IP" "7" "删除 IP 规则"
        menu_item "8" "快速放行 SSH + Web"
        menu_pair "u" "安装 / 修复" "9" "安全卸载 firewalld" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-9 / u]: ')" CH
        case "$CH" in 1|3|4|5|6|7|8) safety_arm firewalld || continue ;; esac
        case "$CH" in
            1)
                if [ "$STATUS" = active ]; then
                    svc_stop firewalld || OK=false
                else
                    svc_start firewalld || OK=false
                fi
                ;;
            2) fwd_show_rules; OK=false ;;
            3) fwd_add_port || OK=false ;;
            4) fwd_del_port || OK=false ;;
            5) fwd_block_ip || OK=false ;;
            6) fwd_allow_ip || OK=false ;;
            7) fwd_del_ip || OK=false ;;
            8) fwd_quick_allow || OK=false ;;
            u|U) fw_install firewalld; OK=false ;;
            9) fw_uninstall firewalld; return ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; OK=false ;;
        esac
        case "$CH" in 1|3|4|5|6|7|8) if [ "$OK" = true ]; then safety_confirm; else safety_rollback_after_failure; fi ;; esac
        [ "$CH" != 0 ] && ui_pause
    done
}

firewall_menu() {
    while true; do
        local FW_TYPE CH
        FW_TYPE=$(fw_detect)
        case "$FW_TYPE" in
            none)
                print_header "防火墙管理"
                warn "未检测到已安装的防火墙"
                menu_item "1" "UFW  Ubuntu / Debian 推荐"
                menu_item "2" "firewalld  Rocky / Fedora 推荐"
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                read -rp "$(ui_prompt '选择防火墙 [0-2]: ')" CH
                case "$CH" in
                    1) fw_install ufw; ui_continue ;;
                    2) fw_install firewalld; ui_continue ;;
                    0) return ;;
                    00) safe_clear; exit 0 ;;
                    *) warn "无效选项" ;;
                esac
                ;;
            conflict)
                print_header "防火墙冲突"
                warn "同时检测到 UFW 与 firewalld，拒绝自动选择以避免管理错误后端"
                echo -e "  UFW: $(fw_running ufw)    firewalld: $(fw_running firewalld)"
                menu_pair "1" "管理 UFW" "2" "管理 firewalld"
                menu_item "0" "返回主菜单"
                read -rp "$(ui_prompt '选择要管理的后端 [0-2]: ')" CH
                case "$CH" in 1) ufw_menu ;; 2) fwd_menu ;; *) return ;; esac
                ;;
            ufw) ufw_menu; return ;;
            firewalld) fwd_menu; return ;;
        esac
    done
}
