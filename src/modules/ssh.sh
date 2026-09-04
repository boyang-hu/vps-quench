# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：show_keys 未收到目标 authorized_keys 路径"; return 1; }
    print_header "查看已有公钥"
    list_keys "$AUTH_FILE"
}

add_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：add_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴完成后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 结束输入："
    echo ""
    menu_div
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    menu_div
    echo ""

    PUBKEY_INPUT=${PUBKEY_INPUT%$'\r'}
    if [ -z "$PUBKEY_INPUT" ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if [ "$(printf '%s\n' "$PUBKEY_INPUT" | wc -l | tr -d ' ')" -ne 1 ] \
        || ! printf '%s\n' "$PUBKEY_INPUT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+([[:space:]].*)?$'; then
        error "公钥格式不正确；每次只能添加一把 Ed25519/RSA/ECDSA/FIDO 公钥。"
        return
    fi

    mkdir -p "$(dirname "$AUTH_FILE")"
    chmod 700 "$(dirname "$AUTH_FILE")"

    # 检查是否已存在相同公钥（取类型+主体比较，忽略备注差异）
    local KEY_BODY
    KEY_BODY=$(echo "$PUBKEY_INPUT" | awk '{print $1, $2}')
    if grep -qF "$KEY_BODY" "$AUTH_FILE" 2>/dev/null; then
        warn "该公钥已存在，跳过添加（避免重复）"
        return
    fi

    echo "$PUBKEY_INPUT" >> "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"

    local TOTAL
    TOTAL=$(ssh_key_count "$AUTH_FILE")
    info "公钥已添加！当前共 $TOTAL 个公钥 ✓"
}

delete_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：delete_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "删除 SSH 公钥"

    if ! list_keys "$AUTH_FILE"; then
        return
    fi

    menu_div
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_FILE"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"; return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 取公钥主体（类型+base64）作为匹配依据，避免尾部空格/备注差异导致删除失败
    local KEY_BODY
    KEY_BODY=$(echo "$TARGET_LINE" | awk '{print $1, $2}')
    grep -vF "$KEY_BODY" "$AUTH_FILE" > "${AUTH_FILE}.tmp" || true
    mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    info "公钥已删除 ✓"
}

generate_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：generate_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    menu_item "1" "Ed25519  ${DIM}推荐，更安全更短${NC}"
    menu_item "2" "RSA 4096"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择密钥类型 [0-2]: ')" KEY_TYPE_CHOICE

    case "$KEY_TYPE_CHOICE" in
        0) return ;;
        1) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        2) KEY_TYPE="rsa";     KEY_BITS="-b 4096" ;;
        *) warn "无效选项，已取消。"; return ;;
    esac

    echo ""
    read -rp "  输入密钥备注（如 mypc@home，直接回车跳过）: " KEY_COMMENT
    KEY_COMMENT="${KEY_COMMENT:-ssh-key-$(date +%Y%m%d)}"

    local TMP_DIR KEY_FILE OLD_UMASK
    # 私钥只允许落在 mktemp -d 创建的 0700 目录里。
    # 可预测的 /tmp/quench_tmp_$$ 兜底会让本机攻击者预建目录并读走私钥，故不再保留。
    OLD_UMASK=$(umask)
    umask 077
    if ! TMP_DIR=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-keygen.XXXXXX"); then
        umask "$OLD_UMASK"
        error "无法创建安全的临时目录，已中止密钥生成。"
        return 1
    fi
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    # shellcheck disable=SC2086 # KEY_BITS intentionally expands to "-b 4096" for RSA only.
    if ! ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "$KEY_FILE" -N "" -q 2>/dev/null; then
        error "密钥生成失败。"; rm -rf "$TMP_DIR"; umask "$OLD_UMASK"; return 1
    fi

    local PUBKEY PRIVKEY FINGER
    PUBKEY=$(cat "${KEY_FILE}.pub")
    PRIVKEY=$(cat "$KEY_FILE")
    FINGER=$(ssh-keygen -lf "${KEY_FILE}.pub" 2>/dev/null | awk '{print $2}')

    print_header "密钥生成完成 — 请复制保存"

    echo -e "  ${DIM}类型：${NC}${BOLD}$KEY_TYPE${NC}   ${DIM}备注：${NC}${YELLOW}$KEY_COMMENT${NC}"
    echo -e "  ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
    echo ""
    echo -e "  ${BOLD}${RED}┌─── 私钥（仅显示一次，请立即复制！）───┐${NC}"
    echo ""
    echo "$PRIVKEY"
    echo ""
    echo -e "  ${BOLD}${RED}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}┌─── 公钥（可添加到服务器）─────────────┐${NC}"
    echo ""
    echo "$PUBKEY"
    echo ""
    echo -e "  ${BOLD}${GREEN}└────────────────────────────────────────┘${NC}"
    echo ""
    menu_div
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    menu_div
    echo ""

    read -rp "  是否将公钥添加到本服务器？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        mkdir -p "$(dirname "$AUTH_FILE")"; chmod 700 "$(dirname "$AUTH_FILE")"
        local KEY_BODY
        KEY_BODY=$(echo "$PUBKEY" | awk '{print $1, $2}')
        if grep -qF "$KEY_BODY" "$AUTH_FILE" 2>/dev/null; then
            warn "该公钥已存在于服务器，跳过添加"
        else
            echo "$PUBKEY" >> "$AUTH_FILE"; chmod 600 "$AUTH_FILE"
            local TOTAL
            TOTAL=$(ssh_key_count "$AUTH_FILE")
            echo ""
            info "公钥已添加到服务器！当前共 $TOTAL 个公钥 ✓"
        fi
    else
        warn "已跳过，公钥未添加到服务器。"
    fi

    rm -rf "$TMP_DIR"
    umask "$OLD_UMASK"
}

# 返回 0 只代表“已恢复且服务验证通过”。原来 restart 的结果被 || true 吞掉，
# 于是恢复其实没成功也报成功，调用方据此取消了安全网。
ssh_restore_last_backup() {
    [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ] || return 1
    atomic_replace_file "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" || return 1
    sshd -t 2>/dev/null || return 1
    restart_ssh >/dev/null 2>&1 || return 1
}

ssh_apply_policy() {
    local LABEL="$1" PASSWORD="$2" KEYBOARD="$3" PUBKEY="$4" ROOT_LOGIN="$5" CANDIDATE APPLY_RC
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    set_config_file "$CANDIDATE" PasswordAuthentication "$PASSWORD"
    set_config_file "$CANDIDATE" KbdInteractiveAuthentication "$KEYBOARD"
    set_config_file "$CANDIDATE" PubkeyAuthentication "$PUBKEY"
    set_config_file "$CANDIDATE" PermitRootLogin "$ROOT_LOGIN"
    set_config_file "$CANDIDATE" PermitEmptyPasswords no
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "$LABEL"; then
        rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return 1
    fi
    backup_config || { rm -f "$CANDIDATE"; return 1; }
    safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"; cancel_safety_timer; error "SSH 配置写入失败"; return 1
    fi
    rm -f "$CANDIDATE"
    apply_and_restart
    APPLY_RC=$?
    if [ "$APPLY_RC" -ne 0 ]; then
        if [ "$APPLY_RC" -eq 2 ]; then
            safety_release_after_failure unverified
        else
            safety_release_after_failure restored
        fi
        return 1
    fi
    local EFFECTIVE_ROOT
    EFFECTIVE_ROOT=$(get_config PermitRootLogin)
    [ "$ROOT_LOGIN" != prohibit-password ] || [ "$EFFECTIVE_ROOT" != without-password ] || EFFECTIVE_ROOT=prohibit-password
    if [ "$(get_config PasswordAuthentication)" != "$PASSWORD" ] \
        || [ "$(get_config KbdInteractiveAuthentication)" != "$KEYBOARD" ] \
        || [ "$(get_config PubkeyAuthentication)" != "$PUBKEY" ] \
        || [ "$EFFECTIVE_ROOT" != "$ROOT_LOGIN" ]; then
        error "sshd 最终生效值与目标策略不一致，正在恢复"
        if ssh_restore_last_backup; then
            safety_release_after_failure restored
        else
            safety_release_after_failure unverified
        fi
        return 1
    fi
    audit_action "$LABEL" SUCCESS
    info "$LABEL 已生效 ✓"
    safety_confirm
}

ssh_apply_recommended_policy() {
    local ADMIN="$1"
    user_ready_admin "$ADMIN" || { error "$ADMIN 不是已配置公钥的非 root 管理员"; return 1; }
    ssh_apply_policy "SSH 仅密钥并禁止 root 登录" no no yes no
}

set_login_mode() {
    print_header "SSH 登录策略"
    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT MODE ADMIN TOKEN
    CURRENT_PWD=$(get_config PasswordAuthentication)
    CURRENT_PUBKEY=$(get_config PubkeyAuthentication)
    CURRENT_ROOT=$(get_config PermitRootLogin)
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo -e "  可接管管理员           : ${BOLD}$(user_ready_admin_count)${NC}"
    echo ""
    menu_div
    menu_item "1" "仅密钥 + 禁止 root SSH  ${DIM}推荐${NC}"
    menu_item "2" "密码 + 密钥，root 仅允许密钥"
    menu_item "3" "仅密钥，允许 root 使用密钥"
    menu_item "4" "密码 + 密钥并允许 root  ${RED}高风险${NC}" "$YELLOW"
    menu_item "0" "返回上级" "$RED"
    menu_div
    read -rp "$(ui_prompt '选择策略 [0-4]: ')" MODE
    case "$MODE" in
        1)
            ADMIN=$(user_select_ready_admin) || return
            warn "请先在另一个终端用 $ADMIN 的密钥登录，并成功执行 sudo -v。"
            read -rp "  测试完成后输入管理员用户名 $ADMIN: " TOKEN
            [ "$TOKEN" = "$ADMIN" ] || { warn "未确认，配置未修改"; return; }
            ssh_apply_recommended_policy "$ADMIN"
            ;;
        2) ssh_apply_policy "SSH 密码和密钥登录（root 仅密钥）" yes yes yes prohibit-password ;;
        3)
            ADMIN=$(user_select_ready_admin) || return
            ssh_apply_policy "SSH 仅密钥登录（允许 root 密钥）" no no yes prohibit-password
            ;;
        4)
            warn "该策略会允许 root 使用密码直接登录，暴力破解风险显著增加。"
            read -rp "  输入 ALLOW-ROOT 继续: " TOKEN
            [ "$TOKEN" = ALLOW-ROOT ] || { warn "已取消"; return; }
            ssh_apply_policy "SSH 密码和密钥登录（允许 root）" yes yes yes yes
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

SSH_PORT_STATE_FILE="${SSH_PORT_STATE_FILE:-$QUENCH_DATA_DIR/ssh-port-migration.state}"

ssh_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

ssh_port_number_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

ssh_port_listening() {
    local PORT="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk -v port=":$PORT" '$4 ~ port "$" {found=1} END {exit !found}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v port=":$PORT" '$4 ~ port "$" {found=1} END {exit !found}'
    else
        return 1
    fi
}

ssh_set_ports_file() {
    local FILE="$1" FIRST BODY SETTINGS PORT
    shift
    FIRST="$1"; shift
    BODY=$(quench_mktemp) || return 1
    SETTINGS=$(quench_mktemp) || { rm -f "$BODY"; return 1; }
    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        managed && $0 !~ /^[[:space:]]*Port[[:space:]]+/ {print}
    ' "$FILE" > "$SETTINGS" || { rm -f "$BODY" "$SETTINGS"; return 1; }
    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        managed {next}
        /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/ {
            print "# Disabled by Quench SSH port migration: " $0
            next
        }
        {print}
    ' "$FILE" > "$BODY" || { rm -f "$BODY" "$SETTINGS"; return 1; }
    {
        echo "$SSHD_MANAGED_BEGIN"
        echo "Port $FIRST"
        for PORT in "$@"; do echo "Port $PORT"; done
        cat "$SETTINGS"
        echo "$SSHD_MANAGED_END"
        echo ""
        cat "$BODY"
    } > "$FILE"
    rm -f "$BODY" "$SETTINGS"
    return 0
}

ssh_apply_ports() {
    local LABEL="$1" CANDIDATE
    shift
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    ssh_set_ports_file "$CANDIDATE" "$@" || { rm -f "$CANDIDATE"; return 1; }
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "$LABEL"; then
        rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return 1
    fi
    backup_config || { rm -f "$CANDIDATE"; return 1; }
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"; error "SSH 配置写入失败"; return 1
    fi
    rm -f "$CANDIDATE"
    apply_and_restart || return 1
    audit_action "$LABEL" SUCCESS
}

ssh_write_port_state() {
    local OLD_PORT="$1" NEW_PORT="$2"
    mkdir -p "$(dirname "$SSH_PORT_STATE_FILE")" || return 1
    printf 'OLD_PORT=%s\nNEW_PORT=%s\n' "$OLD_PORT" "$NEW_PORT" > "$SSH_PORT_STATE_FILE"
    chmod 600 "$SSH_PORT_STATE_FILE"
}

ssh_read_port_state() {
    [ -r "$SSH_PORT_STATE_FILE" ] || return 1
    OLD_PORT=$(awk -F= '$1 == "OLD_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$SSH_PORT_STATE_FILE")
    NEW_PORT=$(awk -F= '$1 == "NEW_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$SSH_PORT_STATE_FILE")
    ssh_port_number_valid "$OLD_PORT" && ssh_port_valid "$NEW_PORT"
}

ssh_sync_fail2ban_ports() {
    local PORTS="$1" JAIL_FILE WAS_RUNNING BACKUP EXISTED=no FAILED=false
    declare -F f2b_config_file >/dev/null 2>&1 || return 0
    # 保留配置但已卸载 Fail2ban 时，新装流程会按实时 SSH 端口重建配置；
    # 此处不能让一份休眠配置阻断 SSH 端口迁移。
    command -v fail2ban-client >/dev/null 2>&1 || return 0
    declare -F f2b_ensure_managed_config >/dev/null 2>&1 || return 1
    declare -F f2b_set_param_jail >/dev/null 2>&1 || return 1
    declare -F f2b_runtime_healthy >/dev/null 2>&1 || return 1
    f2b_ports_valid "$PORTS" || { warn "Fail2ban 端口列表无效"; return 1; }
    JAIL_FILE=$(f2b_config_file)
    BACKUP=$(quench_mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    WAS_RUNNING=$(f2b_status)
    if ! f2b_ensure_managed_config "$PORTS" \
        || ! f2b_set_param_jail port "$PORTS" \
        || ! f2b_managed_ports_match "$PORTS"; then
        FAILED=true
    elif [ "$WAS_RUNNING" = running ] \
        && { ! restart_fail2ban >/dev/null 2>&1 || ! f2b_runtime_healthy; }; then
        FAILED=true
    elif [ "$WAS_RUNNING" != running ] && ! f2b_validate_config; then
        FAILED=true
    fi
    if [ "$FAILED" = true ]; then
        restore_backup_or_remove "$BACKUP" "$JAIL_FILE" "$EXISTED" || return 1
        if [ "$WAS_RUNNING" = running ]; then
            restart_fail2ban >/dev/null 2>&1 && f2b_runtime_healthy \
                || warn "Fail2ban 原配置恢复后仍未正常运行，请立即检查服务"
        fi
        warn "Fail2ban 端口同步或 sshd jail 验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
    [ "$WAS_RUNNING" = running ] \
        && info "Fail2ban sshd jail 已验证：端口 ${PORTS} ✓" \
        || info "Fail2ban 配置已验证：端口 ${PORTS}（服务保持停止）"
}

ssh_firewall_close_port() {
    local PORT="$1" FAILED=false FIREWALLD_ZONE=""
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1 || true
        ufw --force delete limit "$PORT/tcp" >/dev/null 2>&1 || true
        if ufw_port_rule_present "$PORT" 'ALLOW|LIMIT' broad; then
            error "ufw 的 $PORT/tcp 宽泛放行规则仍然存在"
            FAILED=true
        else
            info "ufw 已清理 $PORT/tcp 的 Quench 宽泛放行规则"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && svc_is_active firewalld; then
        FIREWALLD_ZONE=$(fw_firewalld_zone)
        firewall-cmd --permanent --zone="$FIREWALLD_ZONE" --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
        if ! firewall-cmd --reload >/dev/null 2>&1 \
            || firewall-cmd --zone="$FIREWALLD_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then
            error "firewalld 的 $PORT/tcp 放行规则清理失败"
            FAILED=true
        else
            info "firewalld 已清理 $PORT/tcp 放行规则"
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null || break
        done
        [ -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        if iptables -C INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null; then
            error "Quench 标记的 iptables $PORT/tcp 规则仍然存在"
            FAILED=true
        fi
    fi
    [ "$FAILED" = false ]
}

ssh_port_finalize() {
    local TOKEN CLOSE_OLD OLD_PORT NEW_PORT
    ssh_read_port_state || { warn "没有待完成的 SSH 端口迁移"; return 1; }
    warn "必须已在另一个终端通过端口 $NEW_PORT 成功登录。"
    read -rp "  确认测试成功请输入 TESTED: " TOKEN
    [ "$TOKEN" = TESTED ] || { warn "未确认，继续同时保留 $OLD_PORT 和 $NEW_PORT"; return; }
    ssh_port_listening "$NEW_PORT" || { error "没有检测到端口 $NEW_PORT 正在监听"; return 1; }
    firewall_port_ready "$NEW_PORT" || { error "新端口 $NEW_PORT 的防火墙放行规则验证失败"; return 1; }
    ssh_apply_ports "SSH 端口完成迁移 $OLD_PORT → $NEW_PORT" "$NEW_PORT" || return 1
    ssh_port_listening "$NEW_PORT" || { error "切换后新端口 $NEW_PORT 未监听，正在恢复双端口"; ssh_restore_last_backup; return 1; }
    if ssh_port_listening "$OLD_PORT"; then
        error "旧端口 $OLD_PORT 仍被监听，可能有其他 sshd 配置声明 Port；暂不关闭防火墙"
        return 1
    fi
    if ! ssh_sync_fail2ban_ports "$NEW_PORT"; then
        error "Fail2ban 未能切换到新端口，正在恢复 SSH 双端口"
        ssh_restore_last_backup || true
        ssh_sync_fail2ban_ports "$OLD_PORT,$NEW_PORT" || true
        return 1
    fi
    read -rp "  关闭旧端口 $OLD_PORT 的防火墙放行？(Y/n): " CLOSE_OLD
    CLOSE_OLD="${CLOSE_OLD:-y}"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$' && ! ssh_firewall_close_port "$OLD_PORT"; then
        error "旧端口防火墙规则未完全清理，迁移状态已保留以便重试"
        return 1
    fi
    rm -f "$SSH_PORT_STATE_FILE"
    info "SSH 已仅监听新端口 $NEW_PORT ✓"
}

ssh_port_rollback() {
    local CLOSE_NEW OLD_PORT NEW_PORT
    ssh_read_port_state || { warn "没有待回滚的 SSH 端口迁移"; return 1; }
    if ! firewall_port_ready "$OLD_PORT"; then
        warn "旧 SSH 端口缺少有效防火墙规则，正在补齐"
        firewall_allow_port "$OLD_PORT" || return 1
    fi
    ssh_apply_ports "回滚 SSH 端口迁移到 $OLD_PORT" "$OLD_PORT" || return 1
    ssh_port_listening "$OLD_PORT" || { error "回滚后旧端口 $OLD_PORT 未恢复监听"; ssh_restore_last_backup; return 1; }
    if ! ssh_sync_fail2ban_ports "$OLD_PORT"; then
        error "Fail2ban 未能恢复旧端口保护，正在恢复 SSH 双端口"
        ssh_restore_last_backup || true
        return 1
    fi
    read -rp "  清理新端口 $NEW_PORT 的防火墙放行？(y/N): " CLOSE_NEW
    if echo "$CLOSE_NEW" | grep -qiE '^y(es)?$' && ! ssh_firewall_close_port "$NEW_PORT"; then
        error "新端口防火墙规则未完全清理，迁移状态已保留以便重试"
        return 1
    fi
    rm -f "$SSH_PORT_STATE_FILE"
    info "SSH 端口迁移已回滚 ✓"
}

change_port() {
    print_header "SSH 端口双端口迁移"
    local CURRENT_PORT INPUT_PORT CHOICE OLD_PORT NEW_PORT TEST_NOW
    if ssh_read_port_state; then
        warn "检测到未完成迁移：$OLD_PORT → $NEW_PORT"
        menu_item "1" "已测试新端口，完成切换"
        menu_item "2" "回滚到旧端口"
        menu_item "0" "暂不处理，继续保留双端口" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CHOICE
        case "$CHOICE" in 1) ssh_port_finalize ;; 2) ssh_port_rollback ;; esac
        return
    fi
    CURRENT_PORT=$(get_config Port); CURRENT_PORT="${CURRENT_PORT:-22}"
    echo -e "  当前端口：${BOLD}$CURRENT_PORT${NC}"
    read -rp "  新端口（1024-65535，回车取消）: " INPUT_PORT
    [ -n "$INPUT_PORT" ] || return
    ssh_port_valid "$INPUT_PORT" || { error "端口必须在 1024-65535 之间"; return 1; }
    [ "$INPUT_PORT" != "$CURRENT_PORT" ] || { warn "端口没有变化"; return; }
    ssh_port_listening "$INPUT_PORT" && { error "端口 $INPUT_PORT 已被其他服务监听"; return 1; }
    warn "请先在云厂商安全组放行 TCP ${INPUT_PORT}；旧端口 ${CURRENT_PORT} 暂时不会关闭。"
    read -rp "  已放行并继续？(y/N): " CHOICE
    echo "$CHOICE" | grep -qiE '^y(es)?$' || return
    firewall_allow_port "$INPUT_PORT" || return 1
    if ! ssh_apply_ports "SSH 双端口迁移 $CURRENT_PORT + $INPUT_PORT" "$CURRENT_PORT" "$INPUT_PORT"; then
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_port_listening "$CURRENT_PORT" || ! ssh_port_listening "$INPUT_PORT"; then
        error "双端口监听验证失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! firewall_port_ready "$INPUT_PORT"; then
        error "新端口防火墙规则生效验证失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_write_port_state "$CURRENT_PORT" "$INPUT_PORT"; then
        error "迁移状态保存失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_sync_fail2ban_ports "$CURRENT_PORT,$INPUT_PORT"; then
        error "Fail2ban 新旧端口同步失败，正在回滚 SSH 配置与防火墙"
        ssh_restore_last_backup || true
        ssh_sync_fail2ban_ports "$CURRENT_PORT" || true
        ssh_firewall_close_port "$INPUT_PORT"
        rm -f "$SSH_PORT_STATE_FILE"
        return 1
    fi
    info "SSH 现同时监听 $CURRENT_PORT 和 $INPUT_PORT ✓"
    echo -e "  请保持当前连接，并新开终端测试：${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    read -rp "  已测试成功，现在完成切换？(y/N): " TEST_NOW
    echo "$TEST_NOW" | grep -qiE '^y(es)?$' && ssh_port_finalize
}

ssh_security_status() {
    print_header "SSH 状态与安全检查"
    local VALUE WARNINGS=0
    for KEY in Port PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication PubkeyAuthentication MaxAuthTries LoginGraceTime; do
        VALUE=$(get_config "$KEY")
        printf '  %-34s %s\n' "$KEY" "${VALUE:-未确认}"
    done
    echo ""
    echo -e "  非 root 管理员：${BOLD}$(user_admin_count)${NC}"
    echo -e "  可安全接管管理员：${BOLD}$(user_ready_admin_count)${NC}"
    [ "$(user_ready_admin_count)" -gt 0 ] || { warn "没有同时具备管理员权限和 SSH 公钥的非 root 用户"; WARNINGS=$((WARNINGS + 1)); }
    [ "$(get_config PermitRootLogin)" = no ] || { warn "root SSH 尚未完全禁止"; WARNINGS=$((WARNINGS + 1)); }
    [ "$(get_config PasswordAuthentication)" = no ] || { warn "SSH 密码认证仍允许"; WARNINGS=$((WARNINGS + 1)); }
    if command -v ss >/dev/null 2>&1; then
        echo ""
        echo "  SSH 监听："
        ss -lntp 2>/dev/null | awk '/sshd/ {print "  " $0}' || true
    fi
    if ssh_read_port_state; then warn "存在未完成端口迁移：$OLD_PORT → $NEW_PORT"; WARNINGS=$((WARNINGS + 1)); fi
    echo ""
    [ "$WARNINGS" -eq 0 ] && info "SSH 访问链路检查通过" || warn "发现 $WARNINGS 项需要确认"
}
