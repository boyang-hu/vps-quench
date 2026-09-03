# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════

f2b_config_file() {
    printf '%s\n' "${F2B_JAIL_LOCAL:-/etc/fail2ban/jail.d/zz-vps-quench.local}"
}

f2b_validate_config() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null 2>&1
    else
        fail2ban-server -t >/dev/null 2>&1
    fi
}

f2b_ports_valid() {
    local INPUT="$1" ITEM
    local -a ITEMS=()
    [ -n "$INPUT" ] || return 1
    IFS=',' read -r -a ITEMS <<< "$INPUT"
    for ITEM in "${ITEMS[@]}"; do
        [[ "$ITEM" =~ ^[0-9]+$ ]] && [ "$ITEM" -ge 1 ] && [ "$ITEM" -le 65535 ] || return 1
    done
}

f2b_get_section_param() {
    local SECTION="$1" KEY="$2" FILE="${3:-$(f2b_config_file)}"
    awk -v section="$SECTION" -v key="$KEY" '
        /^\[[^]]+\][[:space:]]*$/ {
            current=$0
            gsub(/^[[:space:]]*\[/, "", current)
            gsub(/\][[:space:]]*$/, "", current)
            in_section=(current == section)
            next
        }
        in_section {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" key "[[:space:]]*=") {
                sub("^" key "[[:space:]]*=[[:space:]]*", "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                value=line
            }
        }
        END {if (value != "") print value}
    ' "$FILE" 2>/dev/null
}

f2b_render_managed_config() {
    local DEST="$1" BACKEND="$2" PORTS="$3" ALLOW_IPV6_LINE="$4"
    {
        echo "# Managed by Quench. Keep unrelated jails in jail.local or separate jail.d files."
        if [ -n "$ALLOW_IPV6_LINE" ]; then
            echo "[DEFAULT]"
            echo "$ALLOW_IPV6_LINE"
            echo ""
        fi
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ${PORTS}"
        echo "mode     = aggressive"
        echo "backend  = ${BACKEND}"
        echo "bantime  = 1h"
        echo "findtime = 10m"
        echo "maxretry = 5"
        echo "bantime.increment = true"
        echo "bantime.maxtime = 1w"
        if [ "$BACKEND" = systemd ]; then
            echo "journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd"
        else
            echo "logpath  = %(sshd_log)s"
        fi
    } > "$DEST"
}

f2b_backend_detect() {
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
        echo systemd
    else
        echo auto
    fi
}

f2b_allow_ipv6_line() {
    local MAJOR
    MAJOR=$(fail2ban-client version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ "${MAJOR:-0}" -ge 1 ] && echo 'allowipv6 = auto'
}

f2b_ensure_managed_config() {
    local PORTS="$1" TARGET STAGED BACKEND ALLOW_IPV6_LINE=""
    TARGET=$(f2b_config_file)
    [ -f "$TARGET" ] && return 0
    mkdir -p "$(dirname "$TARGET")" || return 1
    STAGED=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    BACKEND=$(f2b_backend_detect)
    ALLOW_IPV6_LINE=$(f2b_allow_ipv6_line || true)
    f2b_render_managed_config "$STAGED" "$BACKEND" "$PORTS" "$ALLOW_IPV6_LINE" \
        || { rm -f "$STAGED"; return 1; }
    info "正在创建 Quench 托管的 sshd drop-in"
    chmod 0644 "$STAGED"
    mv "$STAGED" "$TARGET" || { rm -f "$STAGED"; return 1; }
    if ! f2b_validate_config; then
        rm -f "$TARGET"
        error "Fail2ban 配置创建失败，已撤销新 drop-in"
        return 1
    fi
}

f2b_managed_ports_match() {
    local EXPECTED="$1" ACTUAL
    ACTUAL=$(f2b_get_section_param sshd port "$(f2b_config_file)" | tr -d '[:space:]')
    [ "$ACTUAL" = "$(printf '%s' "$EXPECTED" | tr -d '[:space:]')" ]
}

f2b_runtime_healthy() {
    f2b_ping && fail2ban-client status sshd >/dev/null 2>&1
}

# 把 Fail2ban 时间格式转为秒（支持 3600、1h、1d、-1 等）。
f2b_to_seconds() {
    local VAL="$1" NUM UNIT
    if echo "$VAL" | grep -qE '^-?[0-9]+$'; then
        echo "$VAL"
        return
    fi
    NUM=$(echo "$VAL" | grep -oE '[0-9]+' | head -1)
    UNIT=$(echo "$VAL" | grep -oE '[smhdw]' | tail -1)
    case "$UNIT" in
        s) echo "$NUM" ;;
        m) echo $((NUM * 60)) ;;
        h) echo $((NUM * 3600)) ;;
        d) echo $((NUM * 86400)) ;;
        w) echo $((NUM * 604800)) ;;
        *) echo "${NUM:-0}" ;;
    esac
}

f2b_seconds_to_human() {
    local SEC="$1"
    [ "$SEC" = -1 ] && { echo "永久"; return; }
    [ "$SEC" -ge 86400 ] && { echo "$((SEC / 86400))天"; return; }
    [ "$SEC" -ge 3600 ] && { echo "$((SEC / 3600))小时"; return; }
    [ "$SEC" -ge 60 ] && { echo "$((SEC / 60))分钟"; return; }
    echo "${SEC}秒"
}

f2b_ping() {
    local SOCK
    for SOCK in /run/fail2ban/fail2ban.sock /var/run/fail2ban/fail2ban.sock /tmp/fail2ban.sock; do
        [ -S "$SOCK" ] && fail2ban-client -s "$SOCK" ping >/dev/null 2>&1 && return 0
    done
    fail2ban-client ping >/dev/null 2>&1
}

f2b_status() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo not_installed
    elif f2b_ping || svc_is_active fail2ban 2>/dev/null; then
        echo running
    else
        echo stopped
    fi
}

f2b_install() {
    print_header "安装 Fail2ban"
    info "正在安装 fail2ban..."
    if ! pkg_install fail2ban; then
        error "安装失败，请检查网络或手动安装 fail2ban"
        return 1
    fi

    local BACKEND=auto
    if python3 -c "import systemd.journal" >/dev/null 2>&1; then
        BACKEND=systemd
        info "检测到 python3-systemd，使用 systemd backend ✓"
    elif pkg_install python3-systemd >/dev/null 2>&1 \
        && python3 -c "import systemd.journal" >/dev/null 2>&1; then
        BACKEND=systemd
        info "python3-systemd 安装成功，使用 systemd backend ✓"
    else
        warn "python3-systemd 不可用，使用 auto backend"
        if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
            info "安装 rsyslog 以生成 SSH 认证日志..."
            pkg_install rsyslog >/dev/null 2>&1 || true
            svc_enable rsyslog >/dev/null 2>&1 || true
            svc_start rsyslog >/dev/null 2>&1 || true
        fi
    fi

    local F2B_MAJOR ALLOW_IPV6_LINE="" PORTS TARGET STAGED BACKUP EXISTED=no WAS_RUNNING i
    F2B_MAJOR=$(fail2ban-client version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ "${F2B_MAJOR:-0}" -ge 1 ] && ALLOW_IPV6_LINE="allowipv6 = auto"
    PORTS=$(ssh_effective_ports_csv)
    f2b_ports_valid "$PORTS" || { error "无法确定有效的 SSH 端口"; return 1; }

    TARGET=$(f2b_config_file)
    mkdir -p "$(dirname "$TARGET")" || return 1
    STAGED=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    BACKUP=$(mktemp) || { rm -f "$STAGED"; return 1; }
    if [ -f "$TARGET" ]; then
        cp "$TARGET" "$BACKUP" || { rm -f "$STAGED" "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    WAS_RUNNING=$(f2b_status)
    f2b_render_managed_config "$STAGED" "$BACKEND" "$PORTS" "$ALLOW_IPV6_LINE" \
        || { rm -f "$STAGED" "$BACKUP"; return 1; }
    chmod 0644 "$STAGED"
    mv "$STAGED" "$TARGET" || { rm -f "$STAGED" "$BACKUP"; return 1; }
    info "已生成 $(basename "$TARGET")（端口=${PORTS}, backend=${BACKEND}, mode=aggressive）✓"

    info "验证 Fail2ban 配置..."
    if ! f2b_validate_config; then
        [ "$EXISTED" = yes ] && cp "$BACKUP" "$TARGET" || rm -f "$TARGET"
        rm -f "$BACKUP"
        error "Fail2ban 配置验证失败，已恢复原配置"
        fail2ban-client -t 2>&1 | sed 's/^/  /' || true
        return 1
    fi

    svc_enable fail2ban >/dev/null 2>&1 || true
    if [ "$WAS_RUNNING" = running ]; then
        restart_fail2ban >/dev/null 2>&1 || true
    else
        rm -f /run/fail2ban/fail2ban.sock /var/run/fail2ban/fail2ban.sock 2>/dev/null || true
        start_fail2ban >/dev/null 2>&1 || true
    fi
    i=0
    while [ "$i" -lt 10 ]; do
        f2b_ping && break
        sleep 1
        i=$((i + 1))
    done
    if ! f2b_ping || ! fail2ban-client status sshd >/dev/null 2>&1; then
        [ "$EXISTED" = yes ] && cp "$BACKUP" "$TARGET" || rm -f "$TARGET"
        rm -f "$BACKUP"
        if [ "$WAS_RUNNING" = running ]; then
            restart_fail2ban >/dev/null 2>&1 || true
        else
            stop_fail2ban >/dev/null 2>&1 || true
        fi
        error "Fail2ban 未能使用新配置启动，已恢复原配置"
        command -v journalctl >/dev/null 2>&1 && journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || true
        return 1
    fi
    rm -f "$BACKUP"
    info "Fail2ban 安装并启动成功 ✓"
}

f2b_write_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE="${F2B_JAIL_LOCAL:-$(f2b_config_file)}" TMP
    mkdir -p "$(dirname "$JAIL_FILE")" || return 1
    TMP=$(mktemp "${JAIL_FILE}.tmp.XXXXXX") || return 1
    [ -f "$JAIL_FILE" ] || : > "$JAIL_FILE"
    awk -v section="$SECTION" -v key="$KEY" -v value="$VAL" '
        function section_line(name) { return "[" name "]" }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_target && !written) print key " = " value
            current=$0
            gsub(/[[:space:]]+$/, "", current)
            in_target=(current == section_line(section))
            if (in_target) found_section=1
            written=0
            print
            next
        }
        in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!written) print key " = " value
            written=1
            next
        }
        {print}
        END {
            if (in_target && !written) print key " = " value
            if (!found_section) {
                if (NR > 0) print ""
                print section_line(section)
                print key " = " value
            }
        }
    ' "$JAIL_FILE" > "$TMP" || { rm -f "$TMP"; return 1; }
    mv "$TMP" "$JAIL_FILE" || { rm -f "$TMP"; return 1; }
}

f2b_set_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE="${F2B_JAIL_LOCAL:-$(f2b_config_file)}" BACKUP EXISTED=no
    BACKUP=$(mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    if ! f2b_write_section_param "$SECTION" "$KEY" "$VAL" || ! f2b_validate_config; then
        [ "$EXISTED" = yes ] && cp "$BACKUP" "$JAIL_FILE" || rm -f "$JAIL_FILE"
        rm -f "$BACKUP"
        error "Fail2ban 配置验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
}

# 参数只作用于 Quench 管理的 sshd jail，不改变用户的其他 jail。
f2b_set_param() {
    local KEY="$1" VAL="$2"
    f2b_set_section_param sshd "$KEY" "$VAL" || return 1
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

f2b_set_param_jail() {
    local KEY="$1" VAL="$2" JAIL_FILE BACKUP EXISTED=no
    JAIL_FILE=$(f2b_config_file)
    BACKUP=$(mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    if ! f2b_write_section_param sshd enabled true \
        || ! f2b_write_section_param sshd "$KEY" "$VAL" \
        || ! f2b_validate_config; then
        [ "$EXISTED" = yes ] && cp "$BACKUP" "$JAIL_FILE" || rm -f "$JAIL_FILE"
        rm -f "$BACKUP"
        error "Fail2ban 配置验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

f2b_config_params() {
    print_header "Fail2ban SSH 防护参数"
    local JAIL_FILE CUR_BAN CUR_FIND CUR_MAX CUR_PORT BAN_SEC FIND_SEC CH VAL PRESET
    local APPLY_BAN="" APPLY_FIND="" APPLY_MAX="" APPLY_PORT="" BACKUP WAS_RUNNING
    JAIL_FILE=$(f2b_config_file)
    CUR_BAN=$(f2b_get_section_param sshd bantime "$JAIL_FILE"); CUR_BAN="${CUR_BAN:-1h}"
    CUR_FIND=$(f2b_get_section_param sshd findtime "$JAIL_FILE"); CUR_FIND="${CUR_FIND:-10m}"
    CUR_MAX=$(f2b_get_section_param sshd maxretry "$JAIL_FILE"); CUR_MAX="${CUR_MAX:-5}"
    CUR_PORT=$(f2b_get_section_param sshd port "$JAIL_FILE"); CUR_PORT="${CUR_PORT:-$(ssh_effective_ports_csv)}"
    BAN_SEC=$(f2b_to_seconds "$CUR_BAN")
    FIND_SEC=$(f2b_to_seconds "$CUR_FIND")
    echo -e "  封禁时长  : ${BOLD}${CUR_BAN}${NC}  （$(f2b_seconds_to_human "$BAN_SEC")）"
    echo -e "  时间窗口  : ${BOLD}${CUR_FIND}${NC}  （$(f2b_seconds_to_human "$FIND_SEC")）"
    echo -e "  最大重试  : ${BOLD}${CUR_MAX}${NC} 次"
    echo -e "  SSH 端口  : ${BOLD}${CUR_PORT}${NC}"
    echo ""
    menu_div
    menu_pair "1" "封禁时长" "2" "时间窗口"
    menu_pair "3" "最大重试次数" "4" "SSH 端口"
    menu_item "5" "快速预设"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    read -rp "$(ui_prompt '选择参数 [0-5]: ')" CH
    case "$CH" in
        1)
            read -rp "  新 bantime（秒，-1=永久）: " VAL
            echo "$VAL" | grep -qE '^-?[0-9]+$' || { error "无效数值"; return; }
            APPLY_BAN="$VAL"
            ;;
        2)
            read -rp "  新 findtime（秒）: " VAL
            echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
            APPLY_FIND="$VAL"
            ;;
        3)
            read -rp "  新 maxretry（次）: " VAL
            echo "$VAL" | grep -qE '^[1-9][0-9]*$' || { error "无效数值"; return; }
            APPLY_MAX="$VAL"
            ;;
        4)
            VAL=$(ssh_effective_ports_csv)
            echo -e "  当前 sshd 端口：${BOLD}${VAL}${NC}"
            read -rp "  输入逗号分隔的数字端口（回车使用当前值）: " CUR_PORT
            CUR_PORT="${CUR_PORT:-$VAL}"
            f2b_ports_valid "$CUR_PORT" || { error "端口必须为 1-65535 的数字，多个用逗号分隔"; return; }
            APPLY_PORT="$CUR_PORT"
            ;;
        5)
            menu_item "1" "严格 · 1天 / 10分钟 / 3次"
            menu_item "2" "标准 · 1小时 / 10分钟 / 5次"
            menu_item "3" "宽松 · 30分钟 / 5分钟 / 10次"
            menu_item "4" "永久 · 永久 / 10分钟 / 3次" "$YELLOW"
            read -rp "$(ui_prompt '选择预设 [1-4]: ')" PRESET
            case "$PRESET" in
                1) VAL="86400 600 3" ;;
                2) VAL="3600 600 5" ;;
                3) VAL="1800 300 10" ;;
                4) VAL="-1 600 3" ;;
                *) warn "无效选项"; return ;;
            esac
            read -r APPLY_BAN APPLY_FIND APPLY_MAX <<< "$VAL"
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    [ -f "$JAIL_FILE" ] || { error "Quench Fail2ban 配置不存在，请先安装/修复"; return 1; }
    BACKUP=$(mktemp) || return 1
    cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    WAS_RUNNING=$(f2b_status)
    if { [ -z "$APPLY_BAN" ] || f2b_set_param bantime "$APPLY_BAN"; } \
        && { [ -z "$APPLY_FIND" ] || f2b_set_param findtime "$APPLY_FIND"; } \
        && { [ -z "$APPLY_MAX" ] || f2b_set_param maxretry "$APPLY_MAX"; } \
        && { [ -z "$APPLY_PORT" ] || f2b_set_param_jail port "$APPLY_PORT"; }; then
        :
    else
        cp "$BACKUP" "$JAIL_FILE"
        rm -f "$BACKUP"
        error "参数写入失败，已恢复修改前配置"
        return 1
    fi

    if [ "$WAS_RUNNING" != running ]; then
        rm -f "$BACKUP"
        info "配置已保存；Fail2ban 当前未运行，因此未自动启动"
    elif restart_fail2ban && f2b_ping; then
        rm -f "$BACKUP"
        info "Fail2ban 已重启 ✓"
    else
        cp "$BACKUP" "$JAIL_FILE"
        restart_fail2ban >/dev/null 2>&1 || true
        rm -f "$BACKUP"
        error "Fail2ban 无法使用新参数运行，已恢复修改前配置"
        return 1
    fi
}

f2b_edit_config() {
    print_header "编辑 Quench Fail2ban 配置"
    local JAIL_FILE BACKUP RESTART
    JAIL_FILE=$(f2b_config_file)
    mkdir -p "$(dirname "$JAIL_FILE")"
    [ -f "$JAIL_FILE" ] || { warn "请先执行 Fail2ban 安装/修复"; return 1; }
    BACKUP=$(mktemp) || return 1
    cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    warn "即将编辑 ${JAIL_FILE}；保存后会先验证，失败自动恢复"
    ui_continue
    open_editor "$JAIL_FILE"
    if ! f2b_validate_config; then
        cp "$BACKUP" "$JAIL_FILE"
        rm -f "$BACKUP"
        error "配置验证失败，已恢复编辑前版本"
        return 1
    fi
    read -rp "  验证通过，是否重启 Fail2ban？(Y/n): " RESTART
    RESTART="${RESTART:-y}"
    if echo "$RESTART" | grep -qiE '^y(es)?$'; then
        if ! restart_fail2ban || ! f2b_ping; then
            cp "$BACKUP" "$JAIL_FILE"
            restart_fail2ban >/dev/null 2>&1 || true
            rm -f "$BACKUP"
            error "新配置无法启动服务，已恢复原配置"
            return 1
        fi
        info "Fail2ban 已重启 ✓"
    fi
    rm -f "$BACKUP"
}

f2b_uninstall() {
    print_header "卸载 Fail2ban"
    local CONFIRM PURGE TARGET
    TARGET=$(f2b_config_file)
    warn "卸载会停止动态封禁；默认保留所有配置，方便恢复"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    stop_fail2ban >/dev/null 2>&1 || true
    svc_disable fail2ban >/dev/null 2>&1 || true
    pkg_remove fail2ban || { error "卸载失败"; return 1; }
    info "Fail2ban 已卸载，配置已保留 ✓"
    if [ -f "$TARGET" ]; then
        read -rp "  如需删除 Quench 配置，输入 PURGE（其他 Fail2ban 配置不会删除）: " PURGE
        if [ "$PURGE" = PURGE ]; then
            rm -f "$TARGET"
            info "已删除 Quench 托管的 Fail2ban drop-in"
        fi
    fi
}

f2b_jail_name() {
    local JAIL
    JAIL=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 -E '^sshd?$' || true)
    printf '%s\n' "${JAIL:-sshd}"
}

f2b_banned_ips() {
    local JAIL="$1"
    fail2ban-client status "$JAIL" 2>/dev/null \
        | sed -n 's/.*Banned IP list:[[:space:]]*//p'
}

f2b_banned_list() {
    local JAIL="${1:-sshd}" RAW IP i=1
    print_header "封禁 IP 列表 — $JAIL"
    RAW=$(f2b_banned_ips "$JAIL")
    [ -n "$RAW" ] || { echo -e "  ${GREEN}当前没有封禁的 IP${NC}"; return; }
    for IP in $RAW; do
        echo -e "  ${RED}[$i]${NC} $IP"
        i=$((i + 1))
    done
    echo -e "\n  ${DIM}共 $((i - 1)) 个封禁 IP${NC}"
}

f2b_unban() {
    local JAIL="${1:-sshd}" RAW UNBAN_IP
    while true; do
        print_header "手动解封 IP — $JAIL"
        RAW=$(f2b_banned_ips "$JAIL")
        [ -n "$RAW" ] || { echo -e "  ${GREEN}当前没有封禁的 IP${NC}"; return; }
        for UNBAN_IP in $RAW; do
            printf '  %s\n' "$UNBAN_IP"
        done
        read -rp "  输入要解封的 IP（回车返回）: " UNBAN_IP
        [ -n "$UNBAN_IP" ] || return
        fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" >/dev/null 2>&1 \
            && info "IP $UNBAN_IP 已解封 ✓" || error "解封失败"
        sleep 1
    done
}

f2b_logs() {
    print_header "Fail2ban 实时日志"
    echo -e "  ${DIM}显示最近 30 条，按 Ctrl+C 退出实时模式${NC}"
    if [ -f /var/log/fail2ban.log ]; then
        tail -n 30 /var/log/fail2ban.log
        read -r -p "  按 Enter 开始实时跟踪..." _
        tail -f /var/log/fail2ban.log
    elif command -v journalctl >/dev/null 2>&1; then
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null
        read -r -p "  按 Enter 开始实时跟踪..." _
        journalctl -u fail2ban -f
    else
        warn "未找到 Fail2ban 日志"
    fi
}

fail2ban_menu() {
    while true; do
        local F2B_ST F2B_COLOR BANNED_COUNT TOTAL_FAIL JAIL_NAME JAIL_FILE
        local CUR_BAN CUR_FIND CUR_MAX CUR_PORT BAN_SEC FIND_SEC CHOICE
        F2B_ST=$(f2b_status)
        if [ "$F2B_ST" = not_installed ]; then
            print_header "Fail2ban 管理"
            warn "Fail2ban 未安装"
            menu_item "1" "立即安装 Fail2ban"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            read -rp "$(ui_prompt '选择操作 [0-1]: ')" CHOICE
            case "$CHOICE" in
                1) f2b_install; ui_continue ;;
                0) return ;;
                00) safe_clear; exit 0 ;;
                *) warn "无效选项" ;;
            esac
            continue
        fi

        [ "$F2B_ST" = running ] && F2B_COLOR="$GREEN" || F2B_COLOR="$RED"
        JAIL_NAME=$(f2b_jail_name)
        if [ "$F2B_ST" = running ]; then
            BANNED_COUNT=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | sed -n 's/.*Currently banned:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            TOTAL_FAIL=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | sed -n 's/.*Total failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            BANNED_COUNT="${BANNED_COUNT:-0}"; TOTAL_FAIL="${TOTAL_FAIL:-0}"
        else
            BANNED_COUNT="-"; TOTAL_FAIL="-"
        fi
        JAIL_FILE=$(f2b_config_file)
        CUR_BAN=$(f2b_get_section_param sshd bantime "$JAIL_FILE"); CUR_BAN="${CUR_BAN:-1h}"
        CUR_FIND=$(f2b_get_section_param sshd findtime "$JAIL_FILE"); CUR_FIND="${CUR_FIND:-10m}"
        CUR_MAX=$(f2b_get_section_param sshd maxretry "$JAIL_FILE"); CUR_MAX="${CUR_MAX:-5}"
        CUR_PORT=$(f2b_get_section_param sshd port "$JAIL_FILE"); CUR_PORT="${CUR_PORT:-未托管}"
        BAN_SEC=$(f2b_to_seconds "$CUR_BAN"); FIND_SEC=$(f2b_to_seconds "$CUR_FIND")

        safe_clear
        echo ""
        box_top
        app_header_line
        echo -e "  ${BOLD}${CYAN}Fail2ban 管理${NC}"
        box_sep
        box_line "  服务: ${F2B_ST}  jail: ${JAIL_NAME}" "  服务: ${F2B_COLOR}${BOLD}${F2B_ST}${NC}  jail: ${BOLD}${JAIL_NAME}${NC}"
        box_line "  封禁IP: ${BANNED_COUNT}  总失败: ${TOTAL_FAIL}  端口: ${CUR_PORT}" "  封禁IP: ${RED}${BOLD}${BANNED_COUNT}${NC}  总失败: ${YELLOW}${BOLD}${TOTAL_FAIL}${NC}  端口: ${BOLD}${CUR_PORT}${NC}"
        box_line "  封禁: $(f2b_seconds_to_human "$BAN_SEC")  窗口: $(f2b_seconds_to_human "$FIND_SEC")  重试: ${CUR_MAX}次" "  封禁: ${BOLD}$(f2b_seconds_to_human "$BAN_SEC")${NC}  窗口: ${BOLD}$(f2b_seconds_to_human "$FIND_SEC")${NC}  重试: ${BOLD}${CUR_MAX}${NC}次"
        box_sep
        menu_pair "1" "查看封禁 IP" "2" "手动解封"
        menu_pair "3" "实时日志" "4" "SSH 防护参数"
        menu_pair "5" "编辑 Quench 配置" "6" "卸载 Fail2ban" "$GREEN" "$YELLOW"
        menu_item "u" "安装 / 修复 / 更新 Fail2ban" "$CYAN"
        [ "$F2B_ST" = running ] && menu_item "7" "停止服务" "$YELLOW" || menu_item "7" "启动服务"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        box_bot
        read -rp "$(ui_prompt '选择操作 [0-7 / u]: ')" CHOICE
        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            u|U) f2b_install ;;
            7)
                if [ "$F2B_ST" = running ]; then
                    stop_fail2ban && info "Fail2ban 已停止" || error "停止失败"
                else
                    f2b_validate_config && start_fail2ban && f2b_ping \
                        && info "Fail2ban 已启动 ✓" || error "启动失败，请检查配置和日志"
                fi
                ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        [ "$CHOICE" != 0 ] && ui_pause
    done
}
