# ══════════════════════════════════════════════════════════
#  系统检查、备份与诊断工具箱
# ══════════════════════════════════════════════════════════

config_backup_allowed_roots() {
    local p
    for p in \
        etc/hostname etc/hosts \
        etc/ssh/sshd_config etc/ssh/sshd_config.d root/.ssh/authorized_keys \
        etc/fail2ban etc/ufw etc/firewalld etc/nftables.conf etc/nftables.d/quench-nft-forward.nft etc/quench/nft-forward \
        etc/sysctl.conf etc/sysctl.d/98-vps-quench-network-security.conf etc/sysctl.d/98-quench-nft-forward.conf etc/sysctl.d/99-quench-bbr.conf etc/sysctl.d/99-quench-ipv6.conf \
        etc/systemd/system/quench-nft-forward.service etc/systemd/system/quench-nft-target-refresh.service etc/systemd/system/quench-nft-target-refresh.timer \
        etc/init.d/quench-nft-forward usr/local/libexec/quench-nft-forward-apply var/lib/quench/nft-forward \
        etc/apt/apt.conf.d/20auto-upgrades etc/apt/apt.conf.d/52quench-unattended-upgrades etc/dnf/automatic.conf \
        etc/gai.conf etc/resolv.conf etc/systemd/resolved.conf etc/systemd/resolved.conf.d \
        etc/NetworkManager/conf.d etc/NetworkManager/system-connections etc/sysconfig/network-scripts etc/resolvconf/resolv.conf.d \
        etc/caddy \
        var/spool/cron/crontabs/root var/spool/cron/root etc/crontabs/root; do
        printf '%s\n' "$p"
    done
}

config_path_allowed() {
    local PATH_VALUE="$1" REL ROOT
    [ "${PATH_VALUE#/}" != "$PATH_VALUE" ] || return 1
    REL=${PATH_VALUE#/}
    case "/$REL/" in *'/../'*|*'/./'*) return 1 ;; esac
    while IFS= read -r ROOT; do
        case "$REL" in "$ROOT"|"$ROOT"/*) return 0 ;; esac
    done < <(config_backup_allowed_roots)
    return 1
}

config_backup_paths() {
    local p
    while IFS= read -r p; do
        [ -e "/$p" ] || [ -L "/$p" ] || continue
        printf '%s\n' "$p"
    done < <(config_backup_allowed_roots)
}

config_archive_validate() {
    local FILE="$1" MEMBER ROOT OK
    tar -tzf "$FILE" >/dev/null 2>&1 || { error "备份文件损坏"; return 1; }
    while IFS= read -r MEMBER; do
        MEMBER=${MEMBER#./}
        MEMBER=${MEMBER%/}
        [ -n "$MEMBER" ] || continue
        case "$MEMBER" in /*|../*|*/../*|*/..) error "归档包含不安全路径：$MEMBER"; return 1 ;; esac
        OK=false
        while IFS= read -r ROOT; do
            case "$MEMBER" in "$ROOT"|"$ROOT"/*) OK=true; break ;; esac
        done < <(config_backup_allowed_roots)
        [ "$OK" = true ] || { error "归档包含非 Quench 配置路径：$MEMBER"; return 1; }
    done < <(tar -tzf "$FILE")
}

config_archive_extract() {
    local FILE="$1" STAGE LINK REL TARGET ROOT SRC DEST RESTORE_ROOT
    RESTORE_ROOT="${CONFIG_RESTORE_ROOT:-/}"
    STAGE=$(quench_mktemp_d) || return 1
    if ! tar -xzf "$FILE" -C "$STAGE" --no-same-owner 2>/dev/null; then
        rm -rf "$STAGE"
        error "导入包解压失败"
        return 1
    fi
    while IFS= read -r LINK; do
        REL=${LINK#"$STAGE"/}
        TARGET=$(readlink "$LINK" 2>/dev/null || true)
        case "$TARGET" in
            /*)
                case "$REL:$TARGET" in
                    etc/resolv.conf:/run/systemd/resolve/*|etc/resolv.conf:/run/NetworkManager/*|etc/resolv.conf:/run/resolvconf/*) ;;
                    *) rm -rf "$STAGE"; error "归档包含不安全符号链接：$REL -> $TARGET"; return 1 ;;
                esac
                ;;
            ../*|*/../*|*/..) rm -rf "$STAGE"; error "归档包含越界符号链接：$REL -> $TARGET"; return 1 ;;
        esac
    done < <(find "$STAGE" -type l 2>/dev/null)
    while IFS= read -r ROOT; do
        SRC="$STAGE/$ROOT"
        DEST="${RESTORE_ROOT%/}/$ROOT"
        [ -e "$SRC" ] || [ -L "$SRC" ] || continue
        mkdir -p "$(dirname "$DEST")" || { rm -rf "$STAGE"; return 1; }
        cp -a "$SRC" "$(dirname "$DEST")/" || { rm -rf "$STAGE"; error "恢复路径失败：$ROOT"; return 1; }
    done < <(config_backup_allowed_roots)
    rm -rf "$STAGE"
}

config_backup_prune() {
    local FILES=() f REMOVE_COUNT i
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$QUENCH_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r
    )
    [ "${#FILES[@]}" -le "$QUENCH_BACKUP_KEEP" ] && return 0
    REMOVE_COUNT=$((${#FILES[@]} - QUENCH_BACKUP_KEEP))
    for ((i=${#FILES[@]}-1; i>=QUENCH_BACKUP_KEEP; i--)); do
        rm -f "${FILES[$i]}"
    done
    audit_action "自动清理 $REMOVE_COUNT 个旧配置备份" SUCCESS
}

safety_stop_timer_process() {
    if [ -n "${SAFETY_UNIT:-}" ]; then
        systemctl stop "$SAFETY_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SAFETY_UNIT" >/dev/null 2>&1 || true
    elif [ -n "${SAFETY_PID:-}" ]; then
        kill "$SAFETY_PID" 2>/dev/null || true
        wait "$SAFETY_PID" 2>/dev/null || true
    fi
}

safety_timer_pending() {
    { [ -n "${SAFETY_UNIT:-}" ] && systemctl is-active --quiet "$SAFETY_UNIT" 2>/dev/null; } \
        || { [ -n "${SAFETY_PID:-}" ] && kill -0 "$SAFETY_PID" 2>/dev/null; } \
        || { [ -n "${SAFETY_SCRIPT:-}" ] && [ -f "$SAFETY_SCRIPT" ]; }
}

cancel_safety_timer() {
    if [ -n "${SAFETY_SCRIPT:-}" ] && [ -f "$SAFETY_SCRIPT" ]; then
        safety_stop_timer_process
    fi
    rm -f "${SAFETY_SCRIPT:-}"
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_UNIT=""
    txn_record_end
    txn_lock_release
}

safety_rollback_now() {
    local SCRIPT="${SAFETY_SCRIPT:-}" RC=0
    [ -n "$SCRIPT" ] && [ -f "$SCRIPT" ] || {
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_UNIT=""
        return 0
    }
    safety_stop_timer_process
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_UNIT=""
    txn_record_end
    txn_lock_release
    bash "$SCRIPT" --now >/dev/null 2>&1 || RC=$?
    rm -f "$SCRIPT"
    [ "$RC" -eq 0 ] || {
        audit_action "立即执行防断联回滚失败" FAILED
        error "自动回滚执行失败，请立即检查当前 SSH 与网络配置"
        return "$RC"
    }
    audit_action "立即执行防断联回滚" SUCCESS
}

confirm_change_preview() {
    local TITLE="$1"
    shift
    echo ""
    menu_div
    echo -e "  ${BOLD}变更预览：$TITLE${NC}"
    while [ "$#" -gt 0 ]; do echo -e "  ${YELLOW}•${NC} $1"; shift; done
    menu_div
    read -rp "  确认应用以上变更？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

confirm_file_diff() {
    local OLD_FILE="$1" NEW_FILE="$2" TITLE="$3"
    echo ""
    menu_div
    echo -e "  ${BOLD}配置差异：$TITLE${NC}"
    if command -v diff >/dev/null 2>&1; then
        diff -u "$OLD_FILE" "$NEW_FILE" 2>/dev/null | sed -n '1,120p' || true
    else
        warn "系统没有 diff，无法显示逐行差异"
    fi
    menu_div
    read -rp "  确认应用以上配置？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$'
}

config_backup_create() {
    local LABEL="${1:-manual}" QUIET="${2:-false}" TS FILE LIST
    TS=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$QUENCH_BACKUP_DIR"
    chmod 700 "$QUENCH_DATA_DIR" "$QUENCH_BACKUP_DIR" 2>/dev/null || true
    FILE="$QUENCH_BACKUP_DIR/${TS}_${LABEL}.tar.gz"
    LIST=$(quench_mktemp)
    config_backup_paths > "$LIST"
    if [ ! -s "$LIST" ] || ! tar -czf "$FILE" -C / -T "$LIST" 2>/dev/null; then
        rm -f "$LIST" "$FILE"
        [ "$QUIET" = true ] || error "配置备份失败"
        return 1
    fi
    rm -f "$LIST"
    chmod 600 "$FILE"
    audit_action "创建配置备份 $(basename "$FILE")" SUCCESS
    config_backup_prune
    if [ "$QUIET" = true ]; then printf '%s\n' "$FILE"; else info "配置已备份：$FILE"; fi
}

config_backup_restore() {
    local FILE="$1"
    [ -f "$FILE" ] || { error "备份不存在"; return 1; }
    config_archive_validate "$FILE" || return 1
    warn "恢复将覆盖当前配置，并重启相关服务。"
    read -rp "  输入 RESTORE 确认恢复: " CONFIRM
    [ "$CONFIRM" = "RESTORE" ] || { warn "已取消"; return; }
    config_backup_create before_restore true >/dev/null || return 1
    safety_arm config_restore || return 1
    if ! config_archive_extract "$FILE"; then
        error "恢复失败，已保留恢复前快照"
        audit_action "恢复配置 $(basename "$FILE")" FAILED
        return 1
    fi
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
        error "恢复后的 SSH 配置语法错误，请从 before_restore 快照恢复"
        audit_action "恢复配置 $(basename "$FILE") SSH校验失败" FAILED
        return 1
    fi
    restart_ssh 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && systemctl restart systemd-resolved 2>/dev/null || true
    command -v nft >/dev/null 2>&1 && [ -f /etc/nftables.conf ] && nft -f /etc/nftables.conf 2>/dev/null || true
    [ -x /usr/local/libexec/quench-nft-forward-apply ] \
        && /usr/local/libexec/quench-nft-forward-apply >/dev/null 2>&1 || true
    audit_action "恢复配置 $(basename "$FILE")" SUCCESS
    info "配置恢复完成"
    safety_confirm
}

config_backup_menu() {
    while true; do
        print_header "配置备份与恢复"
        mkdir -p "$QUENCH_BACKUP_DIR"
        local FILES=() f i=1
        while IFS= read -r f; do FILES+=("$f"); done < <(find "$QUENCH_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r)
        for f in "${FILES[@]}"; do
            echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}$(du -h "$f" 2>/dev/null | awk '{print $1}')${NC}"
            i=$((i+1))
        done
        [ "${#FILES[@]}" -eq 0 ] && echo -e "  ${DIM}暂无备份${NC}"
        menu_div
        menu_pair "c" "创建备份" "r" "恢复备份" "$GREEN" "$YELLOW"
        menu_pair "d" "删除备份" "0" "返回上级" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作: ')" CH
        case "$CH" in
            c|C) config_backup_create manual ;;
            r|R|d|D)
                [ "${#FILES[@]}" -gt 0 ] || { warn "暂无备份"; sleep 1; continue; }
                read -rp "  输入备份编号: " N
                echo "$N" | grep -qE '^[0-9]+$' || { warn "编号无效"; continue; }
                [ "$N" -ge 1 ] && [ "$N" -le "${#FILES[@]}" ] || { warn "编号无效"; continue; }
                if echo "$CH" | grep -qi '^r$'; then
                    config_backup_restore "${FILES[$((N-1))]}"
                else
                    rm -f "${FILES[$((N-1))]}" && audit_action "删除配置备份 $(basename "${FILES[$((N-1))]}")" SUCCESS
                fi
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        ui_pause
    done
}

config_export_archive() {
    local TARGET="${1:-}" LABEL="${2:-export}" TMP_ARCHIVE
    local OLD_KEEP="$QUENCH_BACKUP_KEEP"
    QUENCH_BACKUP_KEEP=999999
    TMP_ARCHIVE=$(config_backup_create "export_${LABEL}" true)
    local RC=$?
    QUENCH_BACKUP_KEEP="$OLD_KEEP"
    [ "$RC" -eq 0 ] || return "$RC"
    if [ -z "$TARGET" ]; then
        printf '%s\n' "$TMP_ARCHIVE"
        return 0
    fi
    mkdir -p "$(dirname "$TARGET")" 2>/dev/null || { error "无法创建导出目录"; return 1; }
    if ! cp "$TMP_ARCHIVE" "$TARGET" 2>/dev/null; then
        error "导出失败"
        return 1
    fi
    chmod 600 "$TARGET" 2>/dev/null || true
    audit_action "导出配置到 $(basename "$TARGET")" SUCCESS
    info "配置已导出：$TARGET"
    printf '%s\n' "$TARGET"
}

config_import_archive() {
    local FILE="$1"
    [ -f "$FILE" ] || { error "导入包不存在"; return 1; }
    config_archive_validate "$FILE" || return 1
    config_backup_restore "$FILE"
}

config_transfer_menu() {
    while true; do
        print_header "配置导出 / 导入"
        ui_hint "适合迁移到新机器或把当前配置带走备份"
        echo ""; menu_div
        menu_item "1" "导出当前配置" "$GREEN"
        menu_item "2" "导入配置包" "$YELLOW"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1)
                local TARGET ARCHIVE_NAME
                read -rp "$(ui_prompt '导出文件路径（默认 /root/quench-config-export.tar.gz）: ')" TARGET
                TARGET=${TARGET:-/root/quench-config-export.tar.gz}
                ARCHIVE_NAME="$(date +%Y%m%d_%H%M%S)_export"
                config_export_archive "$TARGET" "$ARCHIVE_NAME" || true
                ui_pause
                ;;
            2)
                local FILE
                read -rp "$(ui_prompt '输入要导入的 tar.gz 路径: ')" FILE
                config_import_archive "$FILE" || true
                ui_pause
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

txn_pending_records() {
    find "$QUENCH_TXN_DIR" -maxdepth 1 -type f -name '*.txn' 2>/dev/null | sort
}

# 机器可读状态：running=原会话还活着 / armed=回滚脚本仍在 / stale=已失效
txn_record_state() {
    local FILE="$1" SCRIPT QPID
    SCRIPT=$(txn_record_field "$FILE" SCRIPT)
    QPID=$(txn_record_field "$FILE" QUENCH_PID)
    if [ -n "$QPID" ] && [ "$QPID" != "$$" ] && kill -0 "$QPID" 2>/dev/null; then
        echo running
    elif [ -n "$SCRIPT" ] && [ -f "$SCRIPT" ]; then
        echo armed
    else
        echo stale
    fi
}

txn_record_state_label() {
    case "$1" in
        running) echo "另一个 Quench 会话仍在运行" ;;
        armed)   echo "回滚脚本仍在，可能仍会触发" ;;
        *)       echo "已失效（回滚脚本已消失）" ;;
    esac
}

txn_review_menu() {
    local FILES=() FILE LABEL SCRIPT STARTED STATE INDEX CH SELECTED REMOVED
    while true; do
        print_header "未完成的配置变更"
        FILES=()
        while IFS= read -r FILE; do
            [ -n "$FILE" ] && FILES+=("$FILE")
        done < <(txn_pending_records)
        if [ "${#FILES[@]}" -eq 0 ]; then
            info "没有未完成的变更记录"
            ui_pause
            return 0
        fi
        ui_hint "这些记录来自没有正常收尾的会话（崩溃、断线或被强制结束）"
        ui_hint "Quench 不会自动删除回滚脚本：它们可能仍会按时正常触发"
        echo ""
        INDEX=1
        for FILE in "${FILES[@]}"; do
            LABEL=$(txn_record_field "$FILE" LABEL)
            STARTED=$(txn_record_field "$FILE" STARTED)
            STATE=$(txn_record_state_label "$(txn_record_state "$FILE")")
            echo -e "  ${GREEN}[$INDEX]${NC} ${BOLD}${LABEL:-未知}${NC}"
            echo -e "      ${DIM}开始：${NC}${STARTED:-未知}   ${DIM}状态：${NC}${STATE}"
            INDEX=$((INDEX + 1))
        done
        echo ""; menu_div
        menu_item "1" "立即执行某条记录的回滚" "$YELLOW"
        menu_item "2" "清理已失效的记录" "$CYAN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1)
                read -rp "  输入要回滚的编号（回车取消）: " SELECTED
                [ -n "$SELECTED" ] || continue
                case "$SELECTED" in *[!0-9]*) error "编号无效"; ui_pause; continue ;; esac
                [ "$SELECTED" -ge 1 ] && [ "$SELECTED" -le "${#FILES[@]}" ] \
                    || { error "编号不存在"; ui_pause; continue; }
                FILE="${FILES[$((SELECTED - 1))]}"
                SCRIPT=$(txn_record_field "$FILE" SCRIPT)
                if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
                    error "该记录的回滚脚本已不存在，无法执行"
                    ui_pause
                    continue
                fi
                confirm_change_preview "立即执行遗留回滚" \
                    "记录：$(txn_record_field "$FILE" LABEL)" \
                    "将恢复该事务开始前保存的配置快照" || continue
                if bash "$SCRIPT" --now >/dev/null 2>&1; then
                    rm -f "$FILE"
                    audit_action "手动执行遗留回滚 $(basename "$FILE")" SUCCESS
                    info "回滚已执行 ✓"
                else
                    audit_action "手动执行遗留回滚 $(basename "$FILE")" FAILED
                    error "回滚执行失败，请立即人工检查当前配置"
                fi
                ui_pause
                ;;
            2)
                REMOVED=0
                for FILE in "${FILES[@]}"; do
                    SCRIPT=$(txn_record_field "$FILE" SCRIPT)
                    if [ -n "$SCRIPT" ] && [ -f "$SCRIPT" ]; then
                        continue
                    fi
                    rm -f "$FILE" && REMOVED=$((REMOVED + 1))
                done
                info "已清理 ${REMOVED} 条失效记录"
                [ "$REMOVED" -eq 0 ] || audit_action "清理 ${REMOVED} 条失效变更记录" SUCCESS
                ui_pause
                ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

rollback_center_menu() {
    while true; do
        local BACKUP_COUNT VERSION_COUNT LATEST_BACKUP LATEST_VERSION TXN_COUNT
        BACKUP_COUNT=$(find "$QUENCH_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
        VERSION_COUNT=$(find "$QUENCH_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
        LATEST_BACKUP=$(find "$QUENCH_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r | head -1)
        LATEST_VERSION=$(find "$QUENCH_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r | head -1)
        print_header "统一回滚中心"
        [ -n "$LATEST_BACKUP" ] && LATEST_BACKUP="${LATEST_BACKUP##*/}" || LATEST_BACKUP="无"
        [ -n "$LATEST_VERSION" ] && LATEST_VERSION="${LATEST_VERSION##*/}" || LATEST_VERSION="无"
        echo -e "  备份包：${BOLD}${BACKUP_COUNT:-0}${NC}   最新配置：${BOLD}${LATEST_BACKUP}${NC}"
        echo -e "  版本包：${BOLD}${VERSION_COUNT:-0}${NC}   最新脚本：${BOLD}${LATEST_VERSION}${NC}"
        TXN_COUNT=$(txn_pending_records | wc -l | tr -d ' ')
        [ "${TXN_COUNT:-0}" -eq 0 ] \
            || echo -e "  ${YELLOW}未完成的变更记录：${BOLD}${TXN_COUNT}${NC}${YELLOW}（见选项 4）${NC}"
        echo ""; menu_div
        menu_item "1" "配置备份与恢复" "$GREEN"
        menu_item "2" "配置导出 / 导入" "$CYAN"
        menu_item "3" "脚本版本回滚" "$YELLOW"
        menu_item "4" "检查未完成的变更" "$CYAN"
        menu_item "0" "返回上级" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
        case "$CH" in
            1) config_backup_menu ;;
            2) config_transfer_menu ;;
            3) self_rollback ;;
            4) txn_review_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}


safety_arm() {
    local LABEL="$1" SNAP SCRIPT UFW_STATE="inactive" FIREWALLD_STATE="inactive"
    local DELAY="${SAFETY_DELAY_SECONDS:-180}" RESTORE_ROOT="${CONFIG_RESTORE_ROOT:-/}"
    local RESOLV_IMMUTABLE="inactive" CLEANUP_LINES="" PATH_VALUE TARGET TARGET_Q
    local SNAP_Q SCRIPT_Q ROOT_Q LABEL_Q RESOLV_Q
    shift
    [[ "$DELAY" =~ ^[0-9]+$ ]] && [ "$DELAY" -ge 1 ] || DELAY=180
    txn_lock_acquire || return 1
    if safety_timer_pending; then
        warn "检测到上一笔未确认的网络变更，先恢复上一笔配置"
        safety_rollback_now || return 1
    fi
    for PATH_VALUE in "$@"; do
        config_path_allowed "$PATH_VALUE" || {
            error "拒绝将非 Quench 配置路径加入回滚：$PATH_VALUE"
            return 1
        }
        [ -e "$PATH_VALUE" ] || [ -L "$PATH_VALUE" ] || {
            if [ "$RESTORE_ROOT" = / ]; then TARGET="$PATH_VALUE"; else TARGET="${RESTORE_ROOT%/}$PATH_VALUE"; fi
            printf -v TARGET_Q '%q' "$TARGET"
            CLEANUP_LINES+="rm -rf -- $TARGET_Q"$'\n'
        }
    done
    SNAP=$(config_backup_create "safety_${LABEL}" true) || return 1
    if [ "$RESTORE_ROOT" = / ] && command -v lsattr >/dev/null 2>&1 \
        && lsattr -d /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q i; then
        RESOLV_IMMUTABLE="active"
    fi
    command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active' && UFW_STATE="active"
    svc_is_active firewalld && FIREWALLD_STATE="active"
    SCRIPT="$QUENCH_DATA_DIR/rollback_$$_$(date +%s)_${RANDOM}.sh"
    mkdir -p "$QUENCH_DATA_DIR"
    if [ "$RESTORE_ROOT" = / ]; then TARGET=/etc/resolv.conf; else TARGET="${RESTORE_ROOT%/}/etc/resolv.conf"; fi
    printf -v SNAP_Q '%q' "$SNAP"
    printf -v SCRIPT_Q '%q' "$SCRIPT"
    printf -v ROOT_Q '%q' "$RESTORE_ROOT"
    printf -v LABEL_Q '%q' "$LABEL"
    printf -v RESOLV_Q '%q' "$TARGET"
    cat > "$SCRIPT" <<ROLLBACK_EOF
#!/bin/bash
ROLLBACK_SLEEP_PID=""
rollback_cancel_wait() {
    [ -z "\$ROLLBACK_SLEEP_PID" ] || kill "\$ROLLBACK_SLEEP_PID" 2>/dev/null || true
    exit 0
}
trap rollback_cancel_wait TERM INT
if [ "\${1:-}" != --now ]; then
    sleep $DELAY &
    ROLLBACK_SLEEP_PID=\$!
    wait "\$ROLLBACK_SLEEP_PID" || exit 0
fi
trap - TERM INT
chattr -i $RESOLV_Q >/dev/null 2>&1 || true
tar -xzf $SNAP_Q -C $ROOT_Q >/dev/null 2>&1 || exit 1
$CLEANUP_LINES
tar -tzf $SNAP_Q 2>/dev/null | grep -qx 'etc/sysctl.d/98-vps-quench-network-security.conf' || rm -f ${RESTORE_ROOT%/}/etc/sysctl.d/98-vps-quench-network-security.conf
tar -tzf $SNAP_Q 2>/dev/null | grep -qx 'etc/sysctl.d/99-quench-ipv6.conf' || rm -f ${RESTORE_ROOT%/}/etc/sysctl.d/99-quench-ipv6.conf
if [ '$RESOLV_IMMUTABLE' = active ]; then chattr +i $RESOLV_Q >/dev/null 2>&1 || true; fi
if [ $ROOT_Q != / ]; then rm -f $SCRIPT_Q; exit 0; fi
sysctl --system >/dev/null 2>&1 || true
sshd -t >/dev/null 2>&1 && (systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null)
systemctl restart systemd-resolved >/dev/null 2>&1 || true
systemctl restart NetworkManager >/dev/null 2>&1 || true
if command -v ufw >/dev/null 2>&1; then
    if [ '$UFW_STATE' = active ]; then ufw --force enable >/dev/null 2>&1; else ufw --force disable >/dev/null 2>&1; fi
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    if [ '$FIREWALLD_STATE' = active ]; then systemctl start firewalld >/dev/null 2>&1; else systemctl stop firewalld >/dev/null 2>&1; fi
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
nft -f /etc/nftables.conf >/dev/null 2>&1 || true
[ -x /usr/local/libexec/quench-nft-forward-apply ] && /usr/local/libexec/quench-nft-forward-apply >/dev/null 2>&1 || true
logger -t quench "未确认连接，已自动恢复 $LABEL_Q 配置"
rm -f $SCRIPT_Q
ROLLBACK_EOF
    chmod 700 "$SCRIPT"
    safety_launch_timer "$SCRIPT" \
        || { rm -f "$SCRIPT"; txn_lock_release; error "无法启动防断联回滚计时器"; return 1; }
    txn_record_begin "$LABEL" "$SCRIPT"
    audit_action "启动防断联保护 $LABEL" SUCCESS
    warn "防断联保护已启动：${DELAY} 秒内未确认将自动恢复。"
}

safety_confirm() {
    [ -n "${SAFETY_SCRIPT:-}" ] && [ -f "$SAFETY_SCRIPT" ] || {
        SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_UNIT=""
        txn_record_end
        txn_lock_release
        warn "自动回滚计时器已结束；请重新检查当前连接与配置状态"
        return 1
    }
    echo ""
    warn "请保持当前连接，并用新终端确认 SSH 和网络正常。"
    read -rp "  确认连接正常，取消自动回滚？(y/N): " OK
    if echo "$OK" | grep -qiE '^y(es)?$'; then
        cancel_safety_timer
        audit_action "确认连接正常，取消自动回滚" SUCCESS
        info "已取消自动回滚"
    else
        warn "自动回滚仍在计时，请勿关闭旧连接。"
    fi
}

security_audit() {
    print_header "系统安全体检"
    local WARNINGS=0 VALUE PORT
    echo -e "  ${BOLD}SSH${NC}"
    VALUE=$(get_config PasswordAuthentication)
    if [ "$VALUE" = no ]; then info "密码登录已关闭"; else warn "密码登录未关闭"; WARNINGS=$((WARNINGS+1)); fi
    VALUE=$(get_config PermitRootLogin)
    if [ "$VALUE" = no ] || [ "$VALUE" = prohibit-password ]; then info "root 密码登录已限制"; else warn "root 密码登录允许"; WARNINGS=$((WARNINGS+1)); fi
    VALUE=$(get_config PermitEmptyPasswords)
    if [ "$VALUE" = yes ]; then warn "允许空密码登录"; WARNINGS=$((WARNINGS+1)); else info "未允许空密码登录"; fi
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then info "sshd 配置语法正常"; else warn "无法通过 sshd 配置检查"; WARNINGS=$((WARNINGS+1)); fi
    echo ""; echo -e "  ${BOLD}网络与服务${NC}"
    PORT=$(get_config Port); PORT=${PORT:-22}
    echo -e "  SSH 端口：${BOLD}$PORT${NC}"
    local FW_CHECK; FW_CHECK=$(fw_detect)
    if [ "$FW_CHECK" != none ] && [ "$(fw_running "$FW_CHECK")" = active ]; then info "防火墙运行中"; else warn "防火墙未运行"; WARNINGS=$((WARNINGS+1)); fi
    if [ "$(f2b_status)" = running ]; then info "Fail2ban 运行中"; else warn "Fail2ban 未运行"; WARNINGS=$((WARNINGS+1)); fi
    command -v ss >/dev/null 2>&1 && { echo -e "  ${DIM}公网监听端口：${NC}"; ss -H -lntup 2>/dev/null | awk '$5 ~ /(^|\]):[0-9]+$/ {print "    " $5 "  " $7}' | sort -u | head -20; }
    echo ""; echo -e "  ${BOLD}账户与更新${NC}"
    local UID0; UID0=$(awk -F: '$3==0 {print $1}' /etc/passwd | paste -sd, -)
    if [ "$UID0" = root ]; then info "未发现额外 UID 0 账户"; else warn "UID 0 账户：$UID0"; WARNINGS=$((WARNINGS+1)); fi
    if command -v apt-get >/dev/null 2>&1; then
        local UPDATES; UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
        if [ "$UPDATES" -eq 0 ]; then info "未发现待更新软件包"; else warn "有 $UPDATES 个软件包可更新"; WARNINGS=$((WARNINGS+1)); fi
    fi
    echo ""; menu_div
    if [ "$WARNINGS" -eq 0 ]; then info "未发现明显风险"; else warn "发现 $WARNINGS 项需要关注"; fi
    audit_action "执行系统安全体检，警告 $WARNINGS 项" SUCCESS
}

login_security_logs() {
    while true; do
        print_header "登录记录与安全日志"
        menu_pair "1" "最近成功登录" "2" "最近失败登录"
        menu_pair "3" "当前在线会话" "4" "SSH 安全日志"
        menu_pair "5" "Fail2ban 封禁状态" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择记录 [0-5]: ')" CH
        case "$CH" in
            1) last -ai 2>/dev/null | head -30 ;;
            2) if command -v lastb >/dev/null 2>&1; then lastb -ai 2>/dev/null | head -30; else warn "系统没有 lastb 数据"; fi ;;
            3) who -uH 2>/dev/null; echo ""; w 2>/dev/null ;;
            4) if command -v journalctl >/dev/null 2>&1; then journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | tail -80; else grep -Ei 'sshd.*(accepted|failed|invalid)' /var/log/auth.log /var/log/secure 2>/dev/null | tail -80; fi ;;
            5) fail2ban-client status 2>/dev/null || warn "Fail2ban 未运行" ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        audit_action "查看登录安全日志选项 $CH" SUCCESS
        ui_pause
    done
}

network_diagnostics() {
    print_header "网络诊断工具箱"
    local TARGET
    read -rp "  目标域名或 IP（默认 1.1.1.1）: " TARGET
    TARGET=${TARGET:-1.1.1.1}
    echo ""; echo -e "  ${BOLD}地址与默认路由${NC}"
    ip -brief address 2>/dev/null || ip addr 2>/dev/null | head -40
    ip route 2>/dev/null | head -10
    ip -6 route 2>/dev/null | head -10
    echo ""; echo -e "  ${BOLD}DNS 解析${NC}"
    if command -v getent >/dev/null 2>&1; then getent ahosts "$TARGET" 2>/dev/null | head -8; else nslookup "$TARGET" 2>/dev/null | head -15; fi
    echo ""; echo -e "  ${BOLD}连通性${NC}"
    ping -c 4 -W 2 "$TARGET" 2>/dev/null || warn "IPv4/默认协议 Ping 失败"
    command -v ping6 >/dev/null 2>&1 && ping6 -c 2 -W 2 "$TARGET" 2>/dev/null || true
    echo ""; echo -e "  ${BOLD}公网出口${NC}"
    command -v curl >/dev/null 2>&1 && { printf '  IPv4: '; curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "不可用"; echo ""; printf '  IPv6: '; curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || echo "不可用"; echo ""; }
    echo ""; echo -e "  ${BOLD}MTU 探测${NC}"
    if ping -c 1 -W 2 -M "do" -s 1472 "$TARGET" >/dev/null 2>&1; then info "路径 MTU 至少为 1500"; else warn "1500 MTU 探测失败，可能需要降低 MTU"; fi
    audit_action "网络诊断 $TARGET" SUCCESS
}

audit_log_view() {
    print_header "脚本操作记录"
    if [ -s "$QUENCH_AUDIT_LOG" ]; then
        tail -100 "$QUENCH_AUDIT_LOG" | column -t -s $'\t' 2>/dev/null || tail -100 "$QUENCH_AUDIT_LOG"
    else
        warn "暂无操作记录"
    fi
}

resource_health_check() {
    print_header "系统资源与健康检查"
    local CPU_COUNT LOAD MEM_TOTAL MEM_AVAIL MEM_USED
    CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
    LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || uptime)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    MEM_TOTAL=${MEM_TOTAL:-0}; MEM_AVAIL=${MEM_AVAIL:-0}; MEM_USED=$((MEM_TOTAL-MEM_AVAIL))

    echo -e "  ${BOLD}概览${NC}"
    echo -e "  运行时间：$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
    echo -e "  CPU：${CPU_COUNT} 核   负载：${LOAD}"
    if [ "$MEM_TOTAL" -gt 0 ]; then
        printf '  内存：%.1f / %.1f MiB（%.0f%%）\n' \
            "$(awk "BEGIN {print $MEM_USED/1024}")" "$(awk "BEGIN {print $MEM_TOTAL/1024}")" \
            "$(awk "BEGIN {print $MEM_USED*100/$MEM_TOTAL}")"
    fi
    echo ""; echo -e "  ${BOLD}磁盘空间${NC}"
    df -hP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}inode 使用${NC}"
    df -iP 2>/dev/null | awk 'NR==1 || $1 ~ /^\/dev\// {print "  " $0}'
    echo ""; echo -e "  ${BOLD}网络连接${NC}"
    if command -v ss >/dev/null 2>&1; then ss -s 2>/dev/null | sed 's/^/  /'; else netstat -s 2>/dev/null | head -12 | sed 's/^/  /'; fi
    echo ""; echo -e "  ${BOLD}资源占用最高的进程${NC}"
    ps aux 2>/dev/null | awk 'NR==1 {print; next} {print}' | sort -rk3 | head -6 | sed 's/^/  /'
    if command -v systemctl >/dev/null 2>&1; then
        echo ""; echo -e "  ${BOLD}失败的 systemd 服务${NC}"
        systemctl --failed --no-pager --plain 2>/dev/null | sed -n '1,15p' | sed 's/^/  /'
    fi
    echo ""; echo -e "  ${BOLD}时间与 NTP${NC}"
    ts_time_health_inline || true
    audit_action "执行系统资源健康检查" SUCCESS
}

config_health_check() {
    print_header "配置体检"
    local WARNINGS=0
    echo -e "  ${BOLD}脚本基础${NC}"
    if [ -x "${LOCAL_SCRIPT:-/usr/local/bin/vps-quench}" ]; then info "本地脚本可执行"; else warn "本地脚本不可执行或不存在"; WARNINGS=$((WARNINGS+1)); fi
    if [ -f "$QUENCH_AUDIT_LOG" ]; then info "审计日志存在"; else warn "审计日志尚未生成"; fi
    if command -v bash >/dev/null 2>&1; then info "bash 已可用"; else warn "未检测到 bash"; WARNINGS=$((WARNINGS+1)); fi

    echo ""; echo -e "  ${BOLD}系统服务${NC}"
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then info "SSH 配置语法正常"; else warn "SSH 配置语法检查失败"; WARNINGS=$((WARNINGS+1)); fi
    if systemd_available; then
        if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then info "SSH 服务运行中"; else warn "SSH 服务未运行"; WARNINGS=$((WARNINGS+1)); fi
        if command -v fail2ban-client >/dev/null 2>&1; then
            if [ "$(f2b_status 2>/dev/null || echo stopped)" = running ]; then info "Fail2ban 正常"; else warn "Fail2ban 未运行"; WARNINGS=$((WARNINGS+1)); fi
        fi
    fi

    echo ""; echo -e "  ${BOLD}更新与备份${NC}"
    if [ -f "${LOCAL_SCRIPT:-/usr/local/bin/vps-quench}.sha256" ]; then info "更新校验文件存在"; else warn "本地校验文件不存在"; fi
    if [ -d "$QUENCH_VERSION_DIR" ]; then info "历史版本目录存在"; else warn "历史版本目录不存在"; fi
    if [ -d "$QUENCH_BACKUP_DIR" ]; then info "配置备份目录存在"; else warn "配置备份目录不存在"; fi

    echo ""; menu_div
    if [ "$WARNINGS" -eq 0 ]; then info "未发现明显配置问题"; else warn "发现 $WARNINGS 项需要关注"; fi
    audit_action "执行配置体检，警告 $WARNINGS 项" SUCCESS
}

diagnostic_bundle_create() {
    print_header "生成诊断包"
    local OUTDIR TMPDIR BUNDLE
    OUTDIR="$QUENCH_DATA_DIR/diagnostics"
    TMPDIR=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-diagnostic.XXXXXX") || return 1
    mkdir -p "$OUTDIR" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建诊断包目录"; return 1; }
    BUNDLE="$OUTDIR/diagnostic_$(date +%Y%m%d_%H%M%S).tar.gz"

    {
        echo "Quench diagnostic bundle"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host: $(hostname 2>/dev/null || echo unknown)"
        echo "Kernel: $(uname -a 2>/dev/null || true)"
        echo "Local time: $(date '+%Y-%m-%d %H:%M:%S %Z %z' 2>/dev/null || true)"
        echo "UTC time: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || true)"
        echo "Timezone: $(ts_current_timezone 2>/dev/null || echo unknown)"
        echo "NTP backend: $(ts_backend_detect 2>/dev/null || echo unknown)"
        if ts_ntp_synchronized "$(ts_backend_detect 2>/dev/null || echo none)"; then
            echo "NTP synchronized: yes"
        else
            echo "NTP synchronized: no"
        fi
        echo
        echo "[Services]"
        if systemd_available; then
            systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
            systemctl is-active fail2ban 2>/dev/null || true
            systemctl is-active caddy 2>/dev/null || true
            systemctl is-active nftables 2>/dev/null || true
            systemctl is-active systemd-timesyncd 2>/dev/null || true
            systemctl is-active chrony 2>/dev/null || systemctl is-active chronyd 2>/dev/null || true
        fi
        if command -v chronyc >/dev/null 2>&1; then
            echo
            echo "[Chrony tracking]"
            LC_ALL=C chronyc tracking 2>/dev/null || true
        elif command -v timedatectl >/dev/null 2>&1; then
            echo
            echo "[Timesync status]"
            timedatectl show-timesync --no-pager 2>/dev/null || true
        fi
        echo
        echo "[Disk]"
        df -hP 2>/dev/null || true
        echo
        echo "[Memory]"
        free -h 2>/dev/null || true
        echo
        echo "[Network]"
        ip route 2>/dev/null || true
        ip -6 route 2>/dev/null || true
        echo
        echo "[Recent audit]"
        tail -100 "$QUENCH_AUDIT_LOG" 2>/dev/null || true
    } > "$TMPDIR/summary.txt"

    [ -f "$SSHD_CONFIG" ] && cp "$SSHD_CONFIG" "$TMPDIR/sshd_config" 2>/dev/null || true
    [ -d /etc/ssh/sshd_config.d ] && { mkdir -p "$TMPDIR/ssh" && cp -a /etc/ssh/sshd_config.d "$TMPDIR/ssh/" 2>/dev/null || true; }
    [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile "$TMPDIR/" 2>/dev/null || true
    [ -d /etc/caddy/sites.d ] && { mkdir -p "$TMPDIR/caddy" && cp -a /etc/caddy/sites.d "$TMPDIR/caddy/" 2>/dev/null || true; }
    [ -f /etc/nftables.conf ] && cp /etc/nftables.conf "$TMPDIR/" 2>/dev/null || true
    [ -f /etc/sysctl.d/98-vps-quench-network-security.conf ] && cp /etc/sysctl.d/98-vps-quench-network-security.conf "$TMPDIR/" 2>/dev/null || true
    [ -f /etc/sysctl.d/99-quench-bbr.conf ] && cp /etc/sysctl.d/99-quench-bbr.conf "$TMPDIR/" 2>/dev/null || true
    [ -d "$QUENCH_VERSION_DIR" ] && ls -1 "$QUENCH_VERSION_DIR" > "$TMPDIR/version-files.txt" 2>/dev/null || true
    [ -d "$QUENCH_BACKUP_DIR" ] && ls -1 "$QUENCH_BACKUP_DIR" > "$TMPDIR/backup-files.txt" 2>/dev/null || true
    if [ -f "$TMPDIR/summary.txt" ]; then
        sed -E 's/((PASSWORD|SECRET|PRIVATE_KEY|API_TOKEN)[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/I' "$TMPDIR/summary.txt" > "$TMPDIR/summary.redacted" 2>/dev/null || cp "$TMPDIR/summary.txt" "$TMPDIR/summary.redacted"
        mv "$TMPDIR/summary.redacted" "$TMPDIR/summary.txt"
    fi

    tar -czf "$BUNDLE" -C "$TMPDIR" . >/dev/null 2>&1 || { rm -rf "$TMPDIR"; error "诊断包打包失败"; return 1; }
    rm -rf "$TMPDIR"
    chmod 600 "$BUNDLE" 2>/dev/null || true
    audit_action "生成诊断包 $(basename "$BUNDLE")" SUCCESS
    info "诊断包已生成：$BUNDLE"
    printf '%s\n' "$BUNDLE"
}

system_hostname_current() {
    hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown
}

system_hostname_valid() {
    local NAME="$1" PART
    local -a HOSTNAME_PARTS
    [ -n "$NAME" ] || return 1
    [ "${#NAME}" -le 253 ] || return 1
    [[ "$NAME" != .* && "$NAME" != *. ]] || return 1
    [[ "$NAME" != *..* ]] || return 1
    [[ "$NAME" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -r -a HOSTNAME_PARTS <<< "$NAME"
    for PART in "${HOSTNAME_PARTS[@]}"; do
        [ -n "$PART" ] || return 1
        [ "${#PART}" -le 63 ] || return 1
        [[ "$PART" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

system_hostname_sed_escape() {
    printf '%s' "$1" | sed 's/[][\/.^$*+?{}|()]/\\&/g'
}

system_hostname_sync_hosts() {
    local OLD_NAME="$1" NEW_NAME="$2" OLD_ESC NEW_ESC
    [ -f /etc/hosts ] || printf '127.0.0.1 localhost\n' > /etc/hosts
    if [ -n "$OLD_NAME" ] && [ "$OLD_NAME" != "$NEW_NAME" ]; then
        OLD_ESC=$(system_hostname_sed_escape "$OLD_NAME")
        NEW_ESC=$(system_hostname_sed_escape "$NEW_NAME")
        sed -i.quench-hostname.bak -E "s/(^|[[:space:]])${OLD_ESC}([[:space:]#]|$)/\\1${NEW_NAME}\\2/g" /etc/hosts 2>/dev/null || true
    fi
    NEW_ESC=$(system_hostname_sed_escape "$NEW_NAME")
    if grep -Eq "(^|[[:space:]])${NEW_ESC}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        return 0
    fi
    if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sed -i.quench-hostname.bak -E "/^[[:space:]]*127\.0\.1\.1[[:space:]]/s/$/ ${NEW_NAME}/" /etc/hosts 2>/dev/null \
            || printf '127.0.1.1 %s\n' "$NEW_NAME" >> /etc/hosts
    else
        printf '127.0.1.1 %s\n' "$NEW_NAME" >> /etc/hosts
    fi
}

system_hostname_apply() {
    local OLD_NAME NEW_NAME
    OLD_NAME=$(system_hostname_current)
    print_header "修改系统 Hostname"
    echo -e "  当前 hostname：${BOLD}${OLD_NAME}${NC}"
    echo -e "  示例：${DIM}GreenCloud.HK6666 / ali-hkg-01 / relay01${NC}"
    menu_div
    read -rp "$(ui_prompt '新的系统 hostname: ')" NEW_NAME
    NEW_NAME=${NEW_NAME//[[:space:]]/}
    [ -n "$NEW_NAME" ] || { warn "已取消"; return; }
    if ! system_hostname_valid "$NEW_NAME"; then
        error "hostname 格式不合法：仅支持字母、数字、点和短横线；不能以点/短横线开头或结尾"
        return 1
    fi
    if [ "$OLD_NAME" = "$NEW_NAME" ]; then
        info "hostname 未变化"
        return 0
    fi
    confirm_change_preview "修改系统 hostname" \
        "当前：$OLD_NAME" \
        "修改为：$NEW_NAME" \
        "写入 /etc/hostname，并同步 /etc/hosts 中的本机映射" \
        "SSH 连接不会因此断开，但新终端提示符、日志和 hostname 命令会显示新名称" || { warn "已取消"; return; }
    [ "$(id -u)" = "0" ] || { error "需要 root 权限"; return 1; }
    config_backup_create before_hostname_change true >/dev/null || warn "配置备份失败，仍继续尝试修改"
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$NEW_NAME" 2>/dev/null || {
            printf '%s\n' "$NEW_NAME" > /etc/hostname || return 1
            hostname "$NEW_NAME" 2>/dev/null || true
        }
    else
        printf '%s\n' "$NEW_NAME" > /etc/hostname || return 1
        hostname "$NEW_NAME" 2>/dev/null || true
    fi
    system_hostname_sync_hosts "$OLD_NAME" "$NEW_NAME"
    audit_action "修改系统 hostname：$OLD_NAME -> $NEW_NAME" SUCCESS
    info "系统 hostname 已修改为：$NEW_NAME"
    warn "已打开的 SSH 会话提示符可能不会立刻刷新，重新登录后会看到新名称"
}

system_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v opkg >/dev/null 2>&1; then echo opkg
    else echo unknown
    fi
}

system_auto_updates_supported() {
    case "$(system_package_manager)" in apt|dnf|yum) return 0 ;; *) return 1 ;; esac
}

system_auto_updates_enabled() {
    local PM PERIODIC REBOOT_CFG DNF_CFG
    PM=$(system_package_manager)
    PERIODIC="${QUENCH_APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
    REBOOT_CFG="${QUENCH_APT_UNATTENDED_FILE:-/etc/apt/apt.conf.d/52quench-unattended-upgrades}"
    DNF_CFG="${QUENCH_DNF_AUTOMATIC_FILE:-/etc/dnf/automatic.conf}"
    case "$PM" in
        apt)
            command -v unattended-upgrade >/dev/null 2>&1 \
                && grep -Eq 'APT::Periodic::Update-Package-Lists[[:space:]]+"1";' "$PERIODIC" 2>/dev/null \
                && grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1";' "$PERIODIC" 2>/dev/null \
                && grep -Eq 'Unattended-Upgrade::Automatic-Reboot[[:space:]]+"false";' "$REBOOT_CFG" 2>/dev/null \
                || return 1
            if systemd_available; then
                systemctl is-enabled --quiet apt-daily.timer 2>/dev/null \
                    && systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null
            fi
            ;;
        dnf)
            grep -Eq '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*yes[[:space:]]*$' "$DNF_CFG" 2>/dev/null \
                && { ! systemd_available || systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null; }
            ;;
        yum) svc_is_active yum-cron ;;
        *) return 1 ;;
    esac
}

system_enable_auto_security_updates() {
    local PM PERIODIC REBOOT_CFG DNF_CFG TMP1 TMP2
    PM=$(system_package_manager)
    PERIODIC="${QUENCH_APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
    REBOOT_CFG="${QUENCH_APT_UNATTENDED_FILE:-/etc/apt/apt.conf.d/52quench-unattended-upgrades}"
    DNF_CFG="${QUENCH_DNF_AUTOMATIC_FILE:-/etc/dnf/automatic.conf}"
    case "$PM" in
        apt)
            pkg_install unattended-upgrades || { error "unattended-upgrades 安装失败"; return 1; }
            mkdir -p "$(dirname "$PERIODIC")" "$(dirname "$REBOOT_CFG")" || return 1
            TMP1=$(quench_mktemp) || return 1
            TMP2=$(quench_mktemp) || { rm -f "$TMP1"; return 1; }
            printf '%s\n' \
                'APT::Periodic::Update-Package-Lists "1";' \
                'APT::Periodic::Unattended-Upgrade "1";' > "$TMP1"
            printf '%s\n' \
                '// Managed by Quench. Production reboots remain an explicit administrator action.' \
                'Unattended-Upgrade::Automatic-Reboot "false";' > "$TMP2"
            if ! cp "$TMP1" "$PERIODIC" || ! cp "$TMP2" "$REBOOT_CFG"; then
                rm -f "$TMP1" "$TMP2"
                error "自动安全更新配置写入失败"
                return 1
            fi
            rm -f "$TMP1" "$TMP2"
            chmod 0644 "$PERIODIC" "$REBOOT_CFG"
            if systemd_available; then
                systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 \
                    || { error "APT 自动更新 timer 启用失败"; return 1; }
            fi
            ;;
        dnf)
            pkg_install dnf-automatic || { error "dnf-automatic 安装失败"; return 1; }
            if grep -qE '^[[:space:]]*apply_updates[[:space:]]*=' "$DNF_CFG" 2>/dev/null; then
                sed -i 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' "$DNF_CFG" || return 1
            else
                printf '\napply_updates = yes\n' >> "$DNF_CFG" || return 1
            fi
            if systemd_available; then
                systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 \
                    || { error "dnf-automatic.timer 启用失败"; return 1; }
            fi
            ;;
        yum)
            pkg_install yum-cron || { error "yum-cron 安装失败"; return 1; }
            svc_enable yum-cron || return 1
            svc_start yum-cron || return 1
            ;;
        apk)
            warn "Alpine 不自动创建升级任务，请按维护窗口自行配置 cron"
            return 1
            ;;
        opkg)
            warn "OpenWrt 不建议自动升级基础系统，请使用固件维护策略"
            return 1
            ;;
        *) error "不支持当前包管理器"; return 1 ;;
    esac
    system_auto_updates_enabled || { error "自动安全更新写入后验证失败"; return 1; }
    audit_action "启用自动安全更新（禁止自动重启）" SUCCESS
    info "自动安全更新已启用；自动重启保持关闭"
}

system_update_manager() {
    while true; do
        print_header "系统更新管理"
        local PM="unknown" PENDING="未知"
        PM=$(system_package_manager)
        case "$PM" in
            apt) PENDING=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l) ;;
            dnf) PENDING=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}') ;;
            yum) PENDING=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {n++} END {print n+0}') ;;
            apk) PENDING=$(apk version -l '<' 2>/dev/null | wc -l) ;;
            opkg) PENDING=$(opkg list-upgradable 2>/dev/null | wc -l) ;;
        esac
        echo -e "  包管理器：${BOLD}$PM${NC}   待更新：${BOLD}$PENDING${NC}"
        menu_div
        menu_pair "1" "刷新并检查更新" "2" "安装安全更新"
        menu_pair "3" "安装全部更新" "4" "自动安全更新" "$YELLOW" "$GREEN"
        menu_pair "5" "清理软件包缓存" "0" "返回上级" "$GREEN" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
        case "$CH" in
            1)
                case "$PM" in
                    apt) apt-get update ;;
                    dnf) dnf check-update || [ "$?" -eq 100 ] ;;
                    yum) yum check-update || [ "$?" -eq 100 ] ;;
                    apk) apk update ;;
                    opkg) opkg update; opkg list-upgradable ;;
                    *) error "不支持当前包管理器" ;;
                esac
                audit_action "刷新系统软件包索引" SUCCESS
                ;;
            2)
                confirm_change_preview "安全更新" "包管理器：$PM" "仅安装安全修复（Alpine 安装仓库可用更新）" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) pkg_install unattended-upgrades && unattended-upgrade -d ;;
                    dnf) dnf upgrade --security -y ;;
                    yum) yum update --security -y ;;
                    apk) apk upgrade ;;
                    opkg) warn "OpenWrt 不区分安全更新，请按包逐项升级"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装系统安全更新" SUCCESS
                ;;
            3)
                confirm_change_preview "全部系统更新" "将更新所有已安装软件包" "可能需要重启服务器" || { warn "已取消"; continue; }
                case "$PM" in
                    apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y ;;
                    dnf) dnf upgrade -y ;;
                    yum) yum update -y ;;
                    apk) apk update && apk upgrade ;;
                    opkg) warn "OpenWrt 不建议无差别升级全部基础包，请使用固件升级或逐包维护"; continue ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "安装全部系统更新" SUCCESS
                ;;
            4)
                confirm_change_preview "自动安全更新" \
                    "启用发行版提供的定时安全更新" \
                    "Debian / Ubuntu 明确禁止自动重启" \
                    "更新行为由系统包管理器维护" || { warn "已取消"; continue; }
                system_enable_auto_security_updates || continue
                ;;
            5)
                case "$PM" in
                    apt) apt-get autoremove -y && apt-get clean ;;
                    dnf) dnf autoremove -y; dnf clean all ;;
                    yum) yum autoremove -y; yum clean all ;;
                    apk) rm -rf /var/cache/apk/* ;;
                    opkg) rm -rf /tmp/opkg-lists/* ;;
                    *) error "不支持当前包管理器"; continue ;;
                esac
                audit_action "清理软件包缓存" SUCCESS
                info "清理完成"
                ;;
            0) return ;;
            *) warn "无效选项"; continue ;;
        esac
        ui_pause
    done
}

system_toolbox_menu() {
    while true; do
        print_header "安全与诊断工具箱"
        menu_pair "1" "系统安全体检" "2" "登录与安全日志"
        menu_pair "3" "网络诊断" "4" "配置备份与恢复"
        menu_pair "5" "脚本操作记录" "6" "系统资源健康"
        menu_pair "7" "系统更新管理" "8" "配置导出 / 导入"
        menu_pair "9" "统一回滚中心" "10" "配置体检中心" "$CYAN" "$GREEN"
        menu_pair "11" "生成诊断包" "12" "修改系统 Hostname" "$YELLOW" "$CYAN"
        menu_item "13" "STUN / NAT 检测" "$GREEN"
        menu_item "0" "返回主菜单" "$RED"
        menu_div
        ui_hint "Hostname 是系统名，会影响 root@主机名 提示符和系统日志标识"
        echo ""
        read -rp "$(ui_prompt '选择工具 [0-13]: ')" CH
        case "$CH" in
            1) security_audit ;;
            2) login_security_logs; continue ;;
            3) network_diagnostics ;;
            4) config_backup_menu; continue ;;
            5) audit_log_view ;;
            6) resource_health_check ;;
            7) system_update_manager; continue ;;
            8) config_transfer_menu; continue ;;
            9) rollback_center_menu; continue ;;
            10) config_health_check ;;
            11) diagnostic_bundle_create ;;
            12) system_hostname_apply ;;
            13) stun_nat_menu; continue ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
