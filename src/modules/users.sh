# ══════════════════════════════════════════════════════════
#  用户生命周期与权限管理
# ══════════════════════════════════════════════════════════

USER_PASSWD_FILE="${USER_PASSWD_FILE:-/etc/passwd}"
USER_GROUP_FILE="${USER_GROUP_FILE:-/etc/group}"
USER_SUDOERS_DIR="${USER_SUDOERS_DIR:-/etc/sudoers.d}"
USER_ADMIN_SUDOERS_FILE="${USER_ADMIN_SUDOERS_FILE:-$USER_SUDOERS_DIR/90-quench-admins}"
USER_NOPASSWD_MARKER="# Managed by Quench: passwordless sudo"

user_passwd_entries() {
    if [ "$USER_PASSWD_FILE" != /etc/passwd ] && [ -r "$USER_PASSWD_FILE" ]; then
        cat "$USER_PASSWD_FILE"
    elif command -v getent >/dev/null 2>&1; then
        getent passwd
    else
        cat /etc/passwd
    fi
}

user_group_entries() {
    if [ "$USER_GROUP_FILE" != /etc/group ] && [ -r "$USER_GROUP_FILE" ]; then
        cat "$USER_GROUP_FILE"
    elif command -v getent >/dev/null 2>&1; then
        getent group
    else
        cat /etc/group
    fi
}

user_uid_min() {
    local VALUE
    VALUE=$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/login.defs 2>/dev/null || true)
    case "$VALUE" in ''|*[!0-9]*) echo 1000 ;; *) echo "$VALUE" ;; esac
}

user_valid_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

user_exists() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {found=1} END {exit !found}'
}

user_home() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $6; exit}'
}

user_uid() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $3; exit}'
}

user_shell() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $7; exit}'
}

user_list_names() {
    local UID_MIN
    UID_MIN=$(user_uid_min)
    user_passwd_entries | awk -F: -v min="$UID_MIN" '
        $1 == "root" {print $1; next}
        $3 >= min && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}
    '
}

user_count() {
    local COUNT
    COUNT=$(user_list_names | awk 'NF {count++} END {print count+0}')
    printf '%s\n' "$COUNT"
}

user_group_exists() {
    local GROUP="$1"
    user_group_entries | awk -F: -v group="$GROUP" '$1 == group {found=1} END {exit !found}'
}

user_groups() {
    local USERNAME="$1" USER_GROUP_LIST=""
    if command -v id >/dev/null 2>&1 && id "$USERNAME" >/dev/null 2>&1; then
        id -nG "$USERNAME" 2>/dev/null || true
        return
    fi
    USER_GROUP_LIST=$(user_group_entries | awk -F: -v user="$USERNAME" '
        $4 != "" {
            count=split($4, members, ",")
            for (i=1; i<=count; i++) if (members[i] == user) {printf "%s%s", sep, $1; sep=" "; break}
        }
        END {if (sep != "") print ""}
    ')
    printf '%s\n' "$USER_GROUP_LIST"
}

user_is_admin() {
    local USERNAME="$1" USER_GROUP_LIST
    [ "$USERNAME" = root ] && return 0
    USER_GROUP_LIST=" $(user_groups "$USERNAME") "
    [[ "$USER_GROUP_LIST" == *" sudo "* || "$USER_GROUP_LIST" == *" wheel "* ]]
}

user_admin_count() {
    local USERNAME COUNT=0
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        [ "$USERNAME" = root ] && continue
        user_is_admin "$USERNAME" && COUNT=$((COUNT + 1))
    done < <(user_list_names)
    printf '%s\n' "$COUNT"
}

user_authorized_keys() {
    local USERNAME="$1" HOME_DIR
    HOME_DIR=$(user_home "$USERNAME")
    [ -n "$HOME_DIR" ] || HOME_DIR="/home/$USERNAME"
    [ "$USERNAME" = root ] && [ -z "$(user_home root)" ] && HOME_DIR=/root
    printf '%s/.ssh/authorized_keys\n' "$HOME_DIR"
}

user_key_count() {
    local USERNAME="$1" KEY_FILE COUNT
    KEY_FILE=$(user_authorized_keys "$USERNAME")
    COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$KEY_FILE" 2>/dev/null || true)
    case "$COUNT" in ''|*[!0-9]*) echo 0 ;; *) echo "$COUNT" ;; esac
}

user_has_ssh_key() {
    [ "$(user_key_count "$1")" -gt 0 ]
}

user_ready_admin() {
    local USERNAME="$1"
    [ "$USERNAME" != root ] && user_exists "$USERNAME" && user_is_admin "$USERNAME" && user_has_ssh_key "$USERNAME"
}

user_ready_admin_count() {
    local USERNAME COUNT=0
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        user_ready_admin "$USERNAME" && COUNT=$((COUNT + 1))
    done < <(user_list_names)
    printf '%s\n' "$COUNT"
}

user_current_actor() {
    local CANDIDATE
    for CANDIDATE in "${SUDO_USER:-}" "${LOGNAME:-}" "${USER:-}"; do
        [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != root ] && user_exists "$CANDIDATE" && { echo "$CANDIDATE"; return; }
    done
    CANDIDATE=$(who -m 2>/dev/null | awk 'NR == 1 {print $1}')
    [ -n "$CANDIDATE" ] && user_exists "$CANDIDATE" && { echo "$CANDIDATE"; return; }
    echo root
}

user_password_state() {
    local USERNAME="$1" STATE
    STATE=$(passwd -S "$USERNAME" 2>/dev/null | awk 'NR == 1 {print $2}' || true)
    case "$STATE" in
        L|LK) echo "已锁定" ;;
        P|PS) echo "已设置" ;;
        NP) echo "无密码" ;;
        *) echo "未知" ;;
    esac
}

user_primary_group() {
    local USERNAME="$1" GROUP
    GROUP=$(id -gn "$USERNAME" 2>/dev/null || true)
    [ -n "$GROUP" ] && { echo "$GROUP"; return; }
    echo "$USERNAME"
}

user_fix_ssh_permissions() {
    local USERNAME="$1" HOME_DIR KEY_FILE GROUP
    HOME_DIR=$(user_home "$USERNAME")
    KEY_FILE=$(user_authorized_keys "$USERNAME")
    GROUP=$(user_primary_group "$USERNAME")
    [ -d "$HOME_DIR/.ssh" ] || return 0
    chmod 700 "$HOME_DIR/.ssh" 2>/dev/null || return 1
    chown "$USERNAME:$GROUP" "$HOME_DIR/.ssh" 2>/dev/null || return 1
    if [ -f "$KEY_FILE" ]; then
        chmod 600 "$KEY_FILE" 2>/dev/null || return 1
        chown "$USERNAME:$GROUP" "$KEY_FILE" 2>/dev/null || return 1
    fi
}

user_admin_group() {
    if user_group_exists sudo; then echo sudo
    elif user_group_exists wheel; then echo wheel
    elif command -v apt-get >/dev/null 2>&1; then echo sudo
    else echo wheel
    fi
}

user_ensure_admin_backend() {
    local GROUP SUDOERS_FILE TMP
    GROUP=$(user_admin_group)
    if ! user_group_exists "$GROUP"; then
        if command -v groupadd >/dev/null 2>&1; then groupadd "$GROUP"
        elif command -v addgroup >/dev/null 2>&1; then addgroup "$GROUP"
        else error "无法创建管理员组 $GROUP"; return 1
        fi
    fi
    command -v sudo >/dev/null 2>&1 || pkg_install sudo || { error "sudo 安装失败"; return 1; }
    mkdir -p "$USER_SUDOERS_DIR" || return 1
    SUDOERS_FILE="$USER_ADMIN_SUDOERS_FILE"
    # 暂存文件建在 sudoers.d 内，mv 才是同文件系统的原子 rename；
    # 名字带点号，sudo 会忽略它，不会在替换前被当成一条生效规则读入。
    TMP=$(mktemp "$USER_SUDOERS_DIR/.90-quench-admins.XXXXXX") || return 1
    printf '%%%s ALL=(ALL:ALL) ALL\n' "$GROUP" > "$TMP"
    chmod 440 "$TMP"
    if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$TMP" >/dev/null 2>&1; then
        rm -f "$TMP"
        error "sudoers 语法校验失败"
        return 1
    fi
    if ! mv "$TMP" "$SUDOERS_FILE"; then
        rm -f "$TMP"
        error "sudoers 写入失败"
        return 1
    fi
    chmod 440 "$SUDOERS_FILE"
    printf '%s\n' "$GROUP"
}

user_nopasswd_file() {
    local USERNAME="$1"
    user_valid_name "$USERNAME" || return 1
    printf '%s/91-quench-nopasswd-%s\n' "$USER_SUDOERS_DIR" "$USERNAME"
}

user_file_mode() {
    local FILE="$1" MODE
    MODE=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%Lp' "$FILE" 2>/dev/null || true)
    printf '%s\n' "$MODE"
}

user_nopasswd_file_valid() {
    local USERNAME="$1" FILE="${2:-}" EXPECTED COUNT
    [ -n "$FILE" ] || FILE=$(user_nopasswd_file "$USERNAME") || return 1
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || return 1
    EXPECTED="$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL"
    [ "$(sed -n '1p' "$FILE" 2>/dev/null)" = "$USER_NOPASSWD_MARKER" ] \
        && [ "$(sed -n '2p' "$FILE" 2>/dev/null)" = "$EXPECTED" ] || return 1
    COUNT=$(wc -l < "$FILE" 2>/dev/null | tr -d '[:space:]')
    [ "$COUNT" = 2 ] && [ "$(user_file_mode "$FILE")" = 440 ]
}

user_nopasswd_enabled() {
    local FILE
    FILE=$(user_nopasswd_file "$1") || return 1
    user_nopasswd_file_valid "$1" "$FILE"
}

user_nopasswd_path_exists() {
    local FILE
    FILE=$(user_nopasswd_file "$1") || return 1
    [ -e "$FILE" ] || [ -L "$FILE" ]
}

user_nopasswd_runtime_valid() {
    local USERNAME="$1"
    command -v sudo >/dev/null 2>&1 || return 1
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USERNAME" -- sudo -n true >/dev/null 2>&1
    else
        sudo -n -u "$USERNAME" -- sudo -n true >/dev/null 2>&1
    fi
}

user_nopasswd_status() {
    local USERNAME="$1"
    if user_nopasswd_enabled "$USERNAME"; then
        echo "已开启（Quench）"
    elif user_nopasswd_runtime_valid "$USERNAME"; then
        echo "已开启（其他规则）"
    else
        echo "未开启"
    fi
}

user_nopasswd_enable() {
    local USERNAME="$1" TARGET TMP
    [ "$USERNAME" != root ] || { error "root 不需要免密 sudo"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    user_valid_name "$USERNAME" && user_exists "$USERNAME" \
        || { error "用户名无效或用户不存在"; return 1; }
    user_is_admin "$USERNAME" \
        || { error "请先授予 $USERNAME sudo/wheel 管理员权限"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    command -v sudo >/dev/null 2>&1 && command -v visudo >/dev/null 2>&1 \
        || { error "系统缺少 sudo 或 visudo"; return 1; }
    TARGET=$(user_nopasswd_file "$USERNAME") || return 1
    mkdir -p "$USER_SUDOERS_DIR" || return 1
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        user_nopasswd_file_valid "$USERNAME" "$TARGET" \
            || { error "$TARGET 已存在且不属于 Quench，拒绝覆盖"; return 1; }
        if user_nopasswd_runtime_valid "$USERNAME"; then
            info "$USERNAME 的 Quench 免密 sudo 已经生效"
            return 0
        fi
        error "Quench 免密 sudo 文件存在但未实际生效，请查看最终 sudo 权限"
        return 1
    fi
    TMP=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    {
        printf '%s\n' "$USER_NOPASSWD_MARKER"
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USERNAME"
    } > "$TMP"
    chmod 440 "$TMP"
    if ! user_nopasswd_file_valid "$USERNAME" "$TMP" \
        || ! visudo -cf "$TMP" >/dev/null 2>&1 \
        || ! mv "$TMP" "$TARGET"; then
        rm -f "$TMP"
        error "免密 sudo 配置校验或写入失败"
        return 1
    fi
    if ! chmod 440 "$TARGET" \
        || ! user_nopasswd_file_valid "$USERNAME" "$TARGET" \
        || ! user_nopasswd_runtime_valid "$USERNAME"; then
        rm -f "$TARGET"
        error "免密 sudo 运行验证失败，已恢复原配置"
        return 1
    fi
    audit_action "为用户 $USERNAME 开启免密 sudo" SUCCESS
    info "$USERNAME 已获得免密 sudo 权限 ✓"
    warn "该权限等同完整 root 控制；安装任务结束后可从本菜单关闭"
}

user_nopasswd_disable() {
    local USERNAME="$1" TARGET
    TARGET=$(user_nopasswd_file "$USERNAME") \
        || { error "用户名不适用于 Quench sudoers 文件"; return 1; }
    if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
        info "$USERNAME 没有 Quench 管理的免密 sudo 配置"
        user_nopasswd_runtime_valid "$USERNAME" \
            && warn "其他 sudoers 规则仍然允许该用户免密提权" || true
        return 0
    fi
    user_nopasswd_file_valid "$USERNAME" "$TARGET" \
        || { error "$TARGET 不属于 Quench，拒绝删除"; return 1; }
    rm -f "$TARGET" || { error "无法删除免密 sudo 配置"; return 1; }
    [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] \
        || { error "免密 sudo 配置仍然存在"; return 1; }
    audit_action "为用户 $USERNAME 关闭免密 sudo" SUCCESS
    info "$USERNAME 的 Quench 免密 sudo 权限已关闭 ✓"
    user_nopasswd_runtime_valid "$USERNAME" \
        && warn "其他 sudoers 规则仍然允许该用户免密提权，请运行权限查看确认来源" || true
}

user_sudo_permissions_show() {
    local USERNAME="$1"
    print_header "$USERNAME · sudo 权限"
    echo -e "  管理员组：${BOLD}$(user_is_admin "$USERNAME" && echo 是 || echo 否)${NC}"
    echo -e "  免密 sudo：${BOLD}$(user_nopasswd_status "$USERNAME")${NC}"
    echo ""
    if command -v sudo >/dev/null 2>&1; then
        sudo -l -U "$USERNAME" 2>&1 | sed 's/^/  /' \
            || warn "无法读取 sudo 的最终权限列表"
    else
        warn "sudo 尚未安装"
    fi
}

user_grant_admin() {
    local USERNAME="$1" GROUP
    GROUP=$(user_ensure_admin_backend) || return 1
    if command -v usermod >/dev/null 2>&1; then
        usermod -aG "$GROUP" "$USERNAME" || return 1
    elif command -v adduser >/dev/null 2>&1; then
        adduser "$USERNAME" "$GROUP" || return 1
    else
        error "系统缺少 usermod/adduser"
        return 1
    fi
    user_is_admin "$USERNAME" || { error "管理员权限验证失败"; return 1; }
    audit_action "授予用户 $USERNAME 管理员权限" SUCCESS
    info "$USERNAME 已加入 $GROUP 管理员组 ✓"
}

user_remove_from_group() {
    local USERNAME="$1" GROUP="$2"
    user_group_exists "$GROUP" || return 0
    case " $(user_groups "$USERNAME") " in *" $GROUP "*) ;; *) return 0 ;; esac
    if command -v gpasswd >/dev/null 2>&1; then gpasswd -d "$USERNAME" "$GROUP" >/dev/null 2>&1
    elif command -v delgroup >/dev/null 2>&1; then delgroup "$USERNAME" "$GROUP" >/dev/null 2>&1
    elif command -v deluser >/dev/null 2>&1; then deluser "$USERNAME" "$GROUP" >/dev/null 2>&1
    else return 1
    fi
}

user_revoke_admin() {
    local USERNAME="$1" ACTOR
    if user_nopasswd_path_exists "$USERNAME"; then
        if user_nopasswd_enabled "$USERNAME"; then
            error "请先关闭 $USERNAME 的免密 sudo，再移除管理员权限"
        else
            error "检测到未通过所有权或权限校验的免密 sudo 文件，请先人工检查"
        fi
        return 1
    fi
    if user_nopasswd_runtime_valid "$USERNAME"; then
        error "$USERNAME 仍通过其他 sudoers 规则拥有免密 sudo，请先清理该授权"
        return 1
    fi
    ACTOR=$(user_current_actor)
    [ "$USERNAME" != "$ACTOR" ] || { error "不能移除当前登录用户 $USERNAME 的管理员权限"; return 1; }
    [ "$(user_admin_count)" -gt 1 ] || { error "不能移除最后一个非 root 管理员"; return 1; }
    if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
        error "不能移除最后一个可通过 SSH 公钥接管的管理员"
        return 1
    fi
    user_remove_from_group "$USERNAME" sudo || return 1
    user_remove_from_group "$USERNAME" wheel || return 1
    user_is_admin "$USERNAME" && { error "管理员权限仍然存在，请人工检查用户组"; return 1; }
    audit_action "移除用户 $USERNAME 管理员权限" SUCCESS
    info "$USERNAME 的管理员权限已移除 ✓"
}

user_select() {
    local ALLOW_ROOT="${1:-yes}" PROMPT="${2:-选择用户}" USERNAME INDEX=1 INPUT
    local -a USERS=()
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        [ "$ALLOW_ROOT" = yes ] || [ "$USERNAME" != root ] || continue
        USERS+=("$USERNAME")
        printf '  %s[%d]%s %-18s UID %-6s %s\n' "$GREEN" "$INDEX" "$NC" "$USERNAME" "$(user_uid "$USERNAME")" "$(user_is_admin "$USERNAME" && echo 管理员 || echo 普通用户)" >&2
        INDEX=$((INDEX + 1))
    done < <(user_list_names)
    [ "${#USERS[@]}" -gt 0 ] || { warn "没有可选择的用户"; return 1; }
    read -rp "  ${PROMPT}（回车取消）: " INPUT
    [ -n "$INPUT" ] || return 1
    [[ "$INPUT" =~ ^[0-9]+$ ]] || { error "无效编号"; return 1; }
    [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#USERS[@]}" ] || { error "编号不存在"; return 1; }
    printf '%s\n' "${USERS[$((INPUT - 1))]}"
}

user_show_list() {
    print_header "用户与权限"
    local USERNAME ROLE STATE KEYS HOME_DIR LOGIN_SHELL
    printf '  %-18s %-7s %-9s %-8s %s\n' "用户" "UID" "权限" "密码" "公钥"
    menu_div
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        user_is_admin "$USERNAME" && ROLE=管理员 || ROLE=普通用户
        STATE=$(user_password_state "$USERNAME")
        KEYS=$(user_key_count "$USERNAME")
        printf '  %-18s %-7s %-9s %-8s %s\n' "$USERNAME" "$(user_uid "$USERNAME")" "$ROLE" "$STATE" "$KEYS"
        HOME_DIR=$(user_home "$USERNAME"); LOGIN_SHELL=$(user_shell "$USERNAME")
        echo -e "  ${DIM}  ${HOME_DIR:-未知} · ${LOGIN_SHELL:-未知}${NC}"
    done < <(user_list_names)
    menu_div
    ui_hint "当前登录身份：$(user_current_actor)"
}

user_default_shell() {
    local CANDIDATE_SHELL
    for CANDIDATE_SHELL in /bin/bash /bin/ash /bin/sh; do
        [ -x "$CANDIDATE_SHELL" ] && { echo "$CANDIDATE_SHELL"; return; }
    done
    echo /bin/sh
}

user_create_account() {
    local USERNAME="$1" LOGIN_SHELL
    LOGIN_SHELL=$(user_default_shell)
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$LOGIN_SHELL" "$USERNAME"
    elif command -v adduser >/dev/null 2>&1; then
        if adduser --help 2>&1 | grep -q -- '--disabled-password'; then
            adduser --disabled-password --gecos "" --shell "$LOGIN_SHELL" "$USERNAME"
        else
            adduser -D -s "$LOGIN_SHELL" "$USERNAME"
        fi
    else
        error "系统缺少 useradd/adduser"
        return 1
    fi
}

user_set_password() {
    local USERNAME="$1"
    info "正在调用系统 passwd，为 $USERNAME 设置密码"
    passwd "$USERNAME" || { error "密码设置失败"; return 1; }
    audit_action "修改用户 $USERNAME 密码" SUCCESS
}

user_key_menu_for() {
    local USERNAME="$1" CHOICE AUTH_FILE
    while true; do
        AUTH_FILE=$(user_authorized_keys "$USERNAME")
        print_header "$USERNAME · SSH 公钥"
        echo -e "  路径：${DIM}${AUTH_FILE}${NC}"
        echo -e "  公钥：${BOLD}$(user_key_count "$USERNAME")${NC}"
        echo ""
        menu_pair "1" "查看公钥" "2" "添加公钥"
        menu_pair "3" "删除公钥" "4" "生成密钥对"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CHOICE
        case "$CHOICE" in
            1) show_keys "$AUTH_FILE"; ui_pause ;;
            2) add_key "$AUTH_FILE"; user_fix_ssh_permissions "$USERNAME"; audit_action "为用户 $USERNAME 添加 SSH 公钥" SUCCESS; ui_pause ;;
            3)
                if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ] \
                    && [ "$(get_config PasswordAuthentication)" = no ]; then
                    error "不能删除最后一个可接管管理员的最后一组公钥"
                else
                    delete_key "$AUTH_FILE"
                    user_fix_ssh_permissions "$USERNAME"
                    audit_action "删除用户 $USERNAME 的 SSH 公钥" SUCCESS
                fi
                ui_pause
                ;;
            4) generate_key "$AUTH_FILE"; user_fix_ssh_permissions "$USERNAME"; audit_action "为用户 $USERNAME 生成 SSH 密钥" SUCCESS; ui_pause ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

user_create() {
    local FORCE_ADMIN="${1:-no}" USERNAME TYPE SET_PASSWORD ADD_KEY
    print_header "创建用户"
    read -rp "  新用户名（回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消"; return 1; }
    user_valid_name "$USERNAME" || { error "用户名只能使用小写字母、数字、下划线和短横线，且不能以数字开头"; return 1; }
    [ "$USERNAME" != root ] || { error "不能创建 root"; return 1; }
    ! user_exists "$USERNAME" || { error "用户 $USERNAME 已存在"; return 1; }
    if [ "$FORCE_ADMIN" = yes ]; then TYPE=2
    else
        menu_item "1" "普通用户"
        menu_item "2" "sudo/wheel 管理员"
        read -rp "$(ui_prompt '用户类型 [1-2，默认 1]: ')" TYPE
        TYPE="${TYPE:-1}"
        [[ "$TYPE" =~ ^[12]$ ]] || { error "无效用户类型"; return 1; }
    fi
    user_create_account "$USERNAME" || { error "用户创建失败"; return 1; }
    if [ "$TYPE" = 2 ] && ! user_grant_admin "$USERNAME"; then
        warn "用户已创建，但管理员授权失败"
        return 1
    fi
    read -rp "  现在设置密码？(y/N): " SET_PASSWORD
    echo "$SET_PASSWORD" | grep -qiE '^y(es)?$' && user_set_password "$USERNAME"
    read -rp "  现在添加 SSH 公钥？(Y/n): " ADD_KEY
    ADD_KEY="${ADD_KEY:-y}"
    if echo "$ADD_KEY" | grep -qiE '^y(es)?$'; then
        local AUTH_FILE
        AUTH_FILE=$(user_authorized_keys "$USERNAME")
        add_key "$AUTH_FILE"
        user_fix_ssh_permissions "$USERNAME"
    fi
    audit_action "创建用户 $USERNAME" SUCCESS
    info "用户 $USERNAME 已创建 ✓"
    [ "$TYPE" = 2 ] && warn "请在另一个终端测试：ssh $USERNAME@服务器地址，然后执行 sudo -v"
    CREATED_USER="$USERNAME"
}

user_admin_manage() {
    print_header "管理员权限"
    local USERNAME CHOICE TOKEN CONFIRM
    USERNAME=$(user_select no "选择要管理的用户") || return
    if user_is_admin "$USERNAME"; then
        echo -e "  ${BOLD}$USERNAME${NC} 当前是管理员。"
        echo -e "  免密 sudo：${BOLD}$(user_nopasswd_status "$USERNAME")${NC}"
        menu_pair "1" "开启免密 sudo" "2" "关闭免密 sudo" "$YELLOW" "$GREEN"
        menu_pair "3" "查看实际 sudo 权限" "4" "移除管理员权限" "$CYAN" "$YELLOW"
        menu_item "0" "取消" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CHOICE
        case "$CHOICE" in
            1)
                warn "免密 sudo 允许 $USERNAME 无需密码执行任意 root 命令"
                read -rp "  输入用户名 $USERNAME 确认开启: " TOKEN
                if [ "$TOKEN" = "$USERNAME" ]; then
                    user_nopasswd_enable "$USERNAME"
                else
                    warn "确认不匹配，已取消"
                fi
                ;;
            2)
                read -rp "  关闭 $USERNAME 的 Quench 免密 sudo？(Y/n): " CONFIRM
                CONFIRM="${CONFIRM:-y}"
                echo "$CONFIRM" | grep -qiE '^y(es)?$' && user_nopasswd_disable "$USERNAME"
                ;;
            3) user_sudo_permissions_show "$USERNAME" ;;
            4) user_revoke_admin "$USERNAME" ;;
        esac
    else
        echo -e "  ${BOLD}$USERNAME${NC} 当前是普通用户。"
        menu_item "1" "授予 sudo/wheel 管理员权限"
        menu_item "2" "查看实际 sudo 权限" "$CYAN"
        menu_item "0" "取消" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CHOICE
        case "$CHOICE" in
            1) user_grant_admin "$USERNAME" ;;
            2) user_sudo_permissions_show "$USERNAME" ;;
        esac
    fi
}

user_password_manage() {
    print_header "密码与账户锁定"
    local USERNAME CHOICE TOKEN ACTOR
    USERNAME=$(user_select yes "选择用户") || return
    ACTOR=$(user_current_actor)
    echo -e "  当前状态：${BOLD}$(user_password_state "$USERNAME")${NC}"
    menu_item "1" "设置/修改密码"
    menu_item "2" "锁定密码登录" "$YELLOW"
    menu_item "3" "解除密码锁定"
    menu_item "0" "取消" "$RED"
    read -rp "$(ui_prompt '选择操作 [0-3]: ')" CHOICE
    case "$CHOICE" in
        1) user_set_password "$USERNAME" ;;
        2)
            [ "$USERNAME" != "$ACTOR" ] || { error "不能锁定当前登录用户 $USERNAME"; return 1; }
            if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
                error "不能锁定最后一个可通过 SSH 公钥接管的管理员"
                return 1
            fi
            read -rp "  输入用户名 $USERNAME 确认锁定: " TOKEN
            [ "$TOKEN" = "$USERNAME" ] || { warn "确认不匹配，已取消"; return; }
            passwd -l "$USERNAME" && audit_action "锁定用户 $USERNAME" SUCCESS && info "$USERNAME 已锁定 ✓"
            ;;
        3) passwd -u "$USERNAME" && audit_action "解锁用户 $USERNAME" SUCCESS && info "$USERNAME 已解锁 ✓" ;;
    esac
}

user_delete() {
    print_header "删除用户"
    local USERNAME USER_ID ACTOR TOKEN REMOVE_HOME
    USERNAME=$(user_select no "选择要删除的用户") || return
    USER_ID=$(user_uid "$USERNAME"); ACTOR=$(user_current_actor)
    [ "$USERNAME" != "$ACTOR" ] || { error "不能删除当前登录用户 $USERNAME"; return 1; }
    [ "$USER_ID" -ge "$(user_uid_min)" ] || { error "拒绝删除系统账户 $USERNAME"; return 1; }
    if user_is_admin "$USERNAME" && [ "$(user_admin_count)" -le 1 ]; then
        error "不能删除最后一个非 root 管理员"
        return 1
    fi
    if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
        error "不能删除最后一个可通过 SSH 公钥接管的管理员"
        return 1
    fi
    pgrep -u "$USERNAME" >/dev/null 2>&1 && warn "该用户仍有运行中的进程，删除可能失败"
    read -rp "  输入用户名 $USERNAME 确认删除: " TOKEN
    [ "$TOKEN" = "$USERNAME" ] || { warn "确认不匹配，已取消"; return; }
    read -rp "  同时删除家目录 $(user_home "$USERNAME")？(y/N): " REMOVE_HOME
    if command -v userdel >/dev/null 2>&1; then
        if echo "$REMOVE_HOME" | grep -qiE '^y(es)?$'; then userdel -r "$USERNAME"; else userdel "$USERNAME"; fi
    elif command -v deluser >/dev/null 2>&1; then
        if echo "$REMOVE_HOME" | grep -qiE '^y(es)?$'; then deluser --remove-home "$USERNAME"; else deluser "$USERNAME"; fi
    else
        error "系统缺少 userdel/deluser"
        return 1
    fi
    if user_nopasswd_path_exists "$USERNAME"; then
        if user_nopasswd_enabled "$USERNAME"; then
            user_nopasswd_disable "$USERNAME" || {
                error "用户已删除，但其免密 sudo 文件清理失败，请立即人工检查"
                return 1
            }
        else
            warn "用户已删除，但同名 sudoers 文件不属于 Quench，已保留并需要人工检查"
        fi
    fi
    audit_action "删除用户 $USERNAME" SUCCESS
    info "用户 $USERNAME 已删除 ✓"
}

user_ssh_keys_manage() {
    print_header "用户 SSH 公钥"
    local USERNAME
    USERNAME=$(user_select yes "选择用户") || return
    user_key_menu_for "$USERNAME"
}

user_select_ready_admin() {
    local USERNAME INDEX=1 INPUT
    local -a USERS=()
    while IFS= read -r USERNAME; do
        user_ready_admin "$USERNAME" || continue
        USERS+=("$USERNAME")
        printf '  %s[%d]%s %s · %s 个公钥\n' "$GREEN" "$INDEX" "$NC" "$USERNAME" "$(user_key_count "$USERNAME")" >&2
        INDEX=$((INDEX + 1))
    done < <(user_list_names)
    [ "${#USERS[@]}" -gt 0 ] || { error "没有同时满足非 root、管理员、有公钥这三个条件的用户"; return 1; }
    read -rp "  选择已测试登录的管理员（回车取消）: " INPUT
    [[ "$INPUT" =~ ^[0-9]+$ ]] && [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#USERS[@]}" ] || return 1
    printf '%s\n' "${USERS[$((INPUT - 1))]}"
}

user_recommended_wizard() {
    print_header "推荐安全配置向导"
    local ADMIN="" CONFIRM
    echo "  1. 创建 sudo/wheel 管理员"
    echo "  2. 为管理员安装 SSH 公钥"
    echo "  3. 在另一个终端验证登录和 sudo"
    echo "  4. 可选迁移 SSH 端口"
    echo "  5. 禁止 root SSH 和密码认证"
    echo ""
    read -rp "  开始向导？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    CREATED_USER=""
    user_create yes || return
    ADMIN="$CREATED_USER"
    user_ready_admin "$ADMIN" || { warn "$ADMIN 尚未配置可用公钥，向导停止以避免锁死"; return; }
    warn "请保持当前窗口，并在另一个终端以 $ADMIN 登录后执行 sudo -v"
    read -rp "  测试成功后输入管理员用户名 $ADMIN: " CONFIRM
    [ "$CONFIRM" = "$ADMIN" ] || { warn "未确认，未修改 SSH 策略"; return; }
    read -rp "  是否迁移 SSH 端口？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' && change_port
    ssh_apply_recommended_policy "$ADMIN"
}
