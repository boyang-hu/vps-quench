# ══════════════════════════════════════════════════════════
#  脚本自我管理模块
# ══════════════════════════════════════════════════════════

# 后台版本提示只读这份 manifest（几百字节），不再为一行版本号拉整份脚本。
QUENCH_MANIFEST_URL="${QUENCH_MANIFEST_URL:-https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.manifest.json}"
GITHUB_REF_URL="https://api.github.com/repos/boyang-hu/vps-quench/git/ref/heads/main"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-/usr/local/bin}"
LOCAL_SCRIPT="${LOCAL_SCRIPT:-${LOCAL_BIN_DIR}/vps-quench}"
QUENCH_UPDATE_HINT_FILE="${QUENCH_UPDATE_HINT_FILE:-/run/quench/new-version}"

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
    fi
}

self_atomic_replace() {
    local SOURCE="$1" DEST="$2" INSTALL_TMP DIR
    DIR=$(dirname "$DEST")
    mkdir -p "$DIR" || return 1
    INSTALL_TMP=$(mktemp "$DIR/.vps-quench.update.XXXXXX") || return 1
    if ! install -m 755 "$SOURCE" "$INSTALL_TMP" || ! mv "$INSTALL_TMP" "$DEST"; then
        rm -f "$INSTALL_TMP"
        return 1
    fi
}

self_script_valid() {
    local FILE="$1"
    [ -f "$FILE" ] && [ -r "$FILE" ] || return 1
    bash -n "$FILE" >/dev/null 2>&1 || return 1
    grep -qE '^APP_VERSION="V[0-9]+\.[0-9]+(\.[0-9]+)?"' "$FILE" 2>/dev/null
}

self_resolve_script_source() {
    local CANDIDATE="${1:-$0}" RESOLVED
    case "$CANDIDATE" in -|/dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;; esac
    RESOLVED=$(readlink -f "$CANDIDATE" 2>/dev/null) || return 1
    case "$RESOLVED" in /dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;; esac
    self_script_valid "$RESOLVED" || return 1
    printf '%s\n' "$RESOLVED"
}

self_reconcile_tc_after_update() {
    local STATE_FILE="${TC_STATE_FILE:-/var/lib/quench/tc-fq.state}"
    [ -s "$STATE_FILE" ] || return 0
    [ -f "$LOCAL_SCRIPT" ] || return 1
    QUENCH_TEST_MODE=0 BBR_TUNE_TEST_MODE=0 bash "$LOCAL_SCRIPT" --bbr-reconcile-tc
}

self_remote_main_sha() {
    curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$GITHUB_REF_URL" 2>/dev/null \
        | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1
}

self_fetch_script() {
    local DEST="$1" WORK REMOTE_SHA SCRIPT_FETCH CHECKSUM_FETCH EXPECTED ACTUAL
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/quench-fetch.XXXXXX") || return 1
    REMOTE_SHA=$(self_remote_main_sha || true)
    printf '%s\n' "$REMOTE_SHA" | grep -qE '^[0-9a-f]{40}$' \
        || { rm -rf "$WORK"; error "无法锁定 GitHub main commit，已拒绝非原子更新"; return 1; }
    SCRIPT_FETCH="https://raw.githubusercontent.com/boyang-hu/vps-quench/${REMOTE_SHA}/vps-quench.sh"
    CHECKSUM_FETCH="https://raw.githubusercontent.com/boyang-hu/vps-quench/${REMOTE_SHA}/vps-quench.sh.sha256"
    if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$SCRIPT_FETCH" -o "$WORK/vps-quench.sh" \
        || ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$CHECKSUM_FETCH" -o "$WORK/vps-quench.sh.sha256"; then
        rm -rf "$WORK"
        return 1
    fi
    EXPECTED=$(awk 'NR==1{print tolower($1)}' "$WORK/vps-quench.sh.sha256")
    ACTUAL=$(file_sha256 "$WORK/vps-quench.sh" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    printf '%s\n' "$EXPECTED" | grep -qE '^[0-9a-fA-F]{64}$' \
        && [ "$EXPECTED" = "$ACTUAL" ] \
        && self_script_valid "$WORK/vps-quench.sh" \
        && install -m 700 "$WORK/vps-quench.sh" "$DEST"
    local RC=$?
    rm -rf "$WORK"
    return "$RC"
}

self_shortcut_path() { printf '%s/%s\n' "$LOCAL_BIN_DIR" "$1"; }

self_shortcut_owned() {
    local TARGET LINK
    TARGET=$(self_shortcut_path "$1")
    [ -L "$TARGET" ] || return 1
    LINK=$(readlink "$TARGET" 2>/dev/null || true)
    [ "$LINK" = "$LOCAL_SCRIPT" ]
}

self_managed_script_file() {
    [ -f "$1" ] || return 1
    grep -qE 'VPS INIT/MANAGEMENT TOOLS|APP_UI_TITLE="VPS INIT/MANAGEMENT TOOLS"' "$1" 2>/dev/null
}

self_install_shortcut() {
    local CMD="$1" TARGET LINK
    TARGET=$(self_shortcut_path "$CMD")
    mkdir -p "$LOCAL_BIN_DIR" || return 1
    if self_shortcut_owned "$CMD"; then
        ln -sfn "$LOCAL_SCRIPT" "$TARGET" || return 1
        info "系统命令 ${CMD} 已创建 ✓"
        return 0
    fi
    if [ -L "$TARGET" ]; then
        LINK=$(readlink "$TARGET" 2>/dev/null || true)
        if [ ! -e "$TARGET" ] || self_managed_script_file "$TARGET"; then
            warn "快捷键 ${CMD} 的旧链接将更新（${LINK:-未知}）"
        else
            warn "快捷键 ${CMD} 已被其他程序占用，未覆盖"
            return 0
        fi
    elif [ -e "$TARGET" ]; then
        if self_managed_script_file "$TARGET"; then warn "将已有 Quench 命令替换为软链接"
        else warn "命令 ${CMD} 已被独立文件占用，未覆盖"; return 0; fi
    fi
    ln -sfn "$LOCAL_SCRIPT" "$TARGET" || return 1
    info "系统命令 ${CMD} 已创建 ✓"
}

self_remove_shortcut() {
    local TARGET
    TARGET=$(self_shortcut_path "$1")
    if self_shortcut_owned "$1" || self_managed_script_file "$TARGET"; then rm -f "$TARGET"; fi
}

self_install() {
    print_header "安装脚本到本地"
    local SOURCE="" DOWNLOAD_TMP="" SELF
    SELF=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -n "$SELF" ]; then SOURCE="$SELF"
    else
        info "当前通过管道运行，正在下载并校验完整脚本与 SHA256..."
        DOWNLOAD_TMP=$(mktemp "${TMPDIR:-/tmp}/quench-install.XXXXXX") || return 1
        self_fetch_script "$DOWNLOAD_TMP" || {
            rm -f "$DOWNLOAD_TMP"; error "下载或 SHA256 校验失败，已拒绝安装"; return 1;
        }
        SOURCE="$DOWNLOAD_TMP"
    fi
    if [ "$SOURCE" != "$LOCAL_SCRIPT" ]; then
        self_atomic_replace "$SOURCE" "$LOCAL_SCRIPT" || {
            rm -f "$DOWNLOAD_TMP"; error "安装失败，原文件未被替换"; return 1;
        }
    fi
    rm -f "$DOWNLOAD_TMP"
    self_script_valid "$LOCAL_SCRIPT" || { error "安装后校验失败"; return 1; }
    self_install_shortcut v || warn "快捷键 v 创建失败"
    self_install_shortcut V || warn "快捷键 V 创建失败"
    audit_action "安装 Quench 到 $LOCAL_SCRIPT" SUCCESS
    info "已安装到 ${LOCAL_SCRIPT}；新终端可输入 v 启动 ✓"
}

self_update() {
    print_header "更新脚本"
    local WORK TMP_FILE CUR_VER NEW_VER SAVED=""
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/quench-update.XXXXXX") || return 1
    TMP_FILE="$WORK/vps-quench.sh"
    info "正在从 GitHub 下载同一提交的脚本与 SHA256..."
    if ! self_fetch_script "$TMP_FILE"; then
        rm -rf "$WORK"
        error "下载、语法或 SHA256 校验失败，当前版本未变更"
        audit_action "脚本更新校验失败" FAILED
        return 1
    fi
    NEW_VER=$(sed -nE 's/^APP_VERSION="(V[0-9]+[.][0-9]+([.][0-9]+)?)".*/\1/p' "$TMP_FILE" | head -1)
    CUR_VER=$(sed -nE 's/^APP_VERSION="(V[0-9]+[.][0-9]+([.][0-9]+)?)".*/\1/p' "$LOCAL_SCRIPT" 2>/dev/null | head -1)
    echo -e "  当前：${BOLD}${CUR_VER:-未知}${NC}  →  远端：${GREEN}${BOLD}${NEW_VER}${NC}"
    confirm_change_preview "安装已校验的 Quench 更新" "目标：$LOCAL_SCRIPT" \
        "覆盖前保存当前可执行版本，安装采用同目录原子替换" || { rm -rf "$WORK"; return 0; }
    if [ -f "$LOCAL_SCRIPT" ]; then
        mkdir -p "$QUENCH_VERSION_DIR" || { rm -rf "$WORK"; return 1; }
        chmod 700 "$QUENCH_VERSION_DIR" 2>/dev/null || true
        SAVED="$QUENCH_VERSION_DIR/${CUR_VER:-unknown}_$(date +%Y%m%d_%H%M%S).sh"
        cp -p "$LOCAL_SCRIPT" "$SAVED" && chmod 700 "$SAVED" \
            || { rm -rf "$WORK"; error "当前版本备份失败"; return 1; }
    fi
    if ! self_atomic_replace "$TMP_FILE" "$LOCAL_SCRIPT" || ! self_script_valid "$LOCAL_SCRIPT"; then
        [ -z "$SAVED" ] || self_atomic_replace "$SAVED" "$LOCAL_SCRIPT" || true
        rm -rf "$WORK"
        error "更新安装失败，已恢复原版本"
        audit_action "脚本更新安装失败" FAILED
        return 1
    fi
    rm -rf "$WORK"
    self_install_shortcut v || warn "快捷键 v 修复失败"
    self_install_shortcut V || warn "快捷键 V 修复失败"
    self_reconcile_tc_after_update || warn "tc 限速状态未能自动恢复，请进入网络性能调优检查"
    rm -f "$QUENCH_UPDATE_HINT_FILE" 2>/dev/null || true
    audit_action "脚本更新 ${CUR_VER:-未知} 到 $NEW_VER" SUCCESS
    info "更新完成，正在启动新版本..."
    exec "$LOCAL_SCRIPT"
}

self_rollback() {
    print_header "回滚脚本版本"
    mkdir -p "$QUENCH_VERSION_DIR" || return 1
    local FILES=() FILE INDEX=1 CHOICE SELECTED CURRENT_BACKUP
    while IFS= read -r FILE; do FILES+=("$FILE"); done \
        < <(find "$QUENCH_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r)
    [ "${#FILES[@]}" -gt 0 ] || { warn "暂无可回滚版本"; return 0; }
    for FILE in "${FILES[@]}"; do echo -e "  ${GREEN}[$INDEX]${NC} $(basename "$FILE")"; INDEX=$((INDEX+1)); done
    read -rp "  选择版本编号（回车取消）: " CHOICE
    case "$CHOICE" in '') return 0 ;; *[!0-9]*) error "编号无效"; return 1 ;; esac
    [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#FILES[@]}" ] || { error "编号无效"; return 1; }
    SELECTED="${FILES[$((CHOICE-1))]}"
    self_script_valid "$SELECTED" || { error "备份脚本完整性校验失败"; return 1; }
    confirm_change_preview "回滚 Quench" "版本文件：$(basename "$SELECTED")" \
        "当前版本也会保留为回滚点" || return 0
    CURRENT_BACKUP="$QUENCH_VERSION_DIR/before_rollback_$(date +%Y%m%d_%H%M%S).sh"
    [ ! -f "$LOCAL_SCRIPT" ] || cp -p "$LOCAL_SCRIPT" "$CURRENT_BACKUP" || return 1
    self_atomic_replace "$SELECTED" "$LOCAL_SCRIPT" && self_script_valid "$LOCAL_SCRIPT" || {
        [ ! -f "$CURRENT_BACKUP" ] || self_atomic_replace "$CURRENT_BACKUP" "$LOCAL_SCRIPT" || true
        error "回滚失败，已尝试恢复当前版本"; return 1;
    }
    audit_action "脚本回滚到 $(basename "$SELECTED")" SUCCESS
    info "回滚完成，正在启动..."
    exec "$LOCAL_SCRIPT"
}

self_offline_bundle_create() {
    print_header "生成离线安装包"
    local SOURCE WORK BUNDLE ARCHIVE HASH
    SOURCE="${LOCAL_SCRIPT:-}"
    [ -f "$SOURCE" ] || SOURCE=$(self_resolve_script_source "$0" 2>/dev/null || true)
    self_script_valid "$SOURCE" || { error "找不到有效的 Quench 脚本"; return 1; }
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/quench-offline.XXXXXX") || return 1
    ARCHIVE="$WORK/vps-quench.sh"
    install -m 755 "$SOURCE" "$ARCHIVE" || { rm -rf "$WORK"; return 1; }
    HASH=$(file_sha256 "$ARCHIVE") || { rm -rf "$WORK"; error "缺少 SHA256 工具"; return 1; }
    printf '%s  vps-quench.sh\n' "$HASH" > "$WORK/vps-quench.sh.sha256"
    BUNDLE="$QUENCH_DATA_DIR/offline/quench-offline-${APP_VERSION}.tar.gz"
    mkdir -p "$(dirname "$BUNDLE")" || { rm -rf "$WORK"; return 1; }
    tar -czf "$BUNDLE" -C "$WORK" vps-quench.sh vps-quench.sh.sha256 \
        || { rm -rf "$WORK"; error "打包失败"; return 1; }
    rm -rf "$WORK"
    chmod 600 "$BUNDLE" 2>/dev/null || true
    audit_action "生成离线安装包 $(basename "$BUNDLE")" SUCCESS
    info "离线包已生成：$BUNDLE"
}

self_offline_bundle_install() {
    local PACKAGE="$1" WORK SOURCE EXPECTED ACTUAL LISTING
    [ -f "$PACKAGE" ] || { error "离线包不存在"; return 1; }
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/quench-offline-install.XXXXXX") || return 1
    case "$PACKAGE" in
        *.tar.gz|*.tgz)
            LISTING=$(tar -tzf "$PACKAGE" 2>/dev/null) || { rm -rf "$WORK"; error "无法读取离线包"; return 1; }
            [ "$LISTING" = $'vps-quench.sh\nvps-quench.sh.sha256' ] \
                || { rm -rf "$WORK"; error "离线包结构异常或包含额外路径"; return 1; }
            tar -xzf "$PACKAGE" -C "$WORK" || { rm -rf "$WORK"; error "解包失败"; return 1; }
            SOURCE="$WORK/vps-quench.sh"
            [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] \
                && [ -f "$WORK/vps-quench.sh.sha256" ] && [ ! -L "$WORK/vps-quench.sh.sha256" ] \
                || { rm -rf "$WORK"; error "离线包必须包含两个普通文件"; return 1; }
            EXPECTED=$(awk 'NR==1{print tolower($1)}' "$WORK/vps-quench.sh.sha256")
            ACTUAL=$(file_sha256 "$SOURCE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
            printf '%s\n' "$EXPECTED" | grep -qE '^[0-9a-fA-F]{64}$' \
                && [ "$EXPECTED" = "$ACTUAL" ] \
                || { rm -rf "$WORK"; error "离线包 SHA256 校验失败"; return 1; }
            ;;
        *.sh) SOURCE="$PACKAGE" ;;
        *) rm -rf "$WORK"; error "仅支持 .sh / .tar.gz / .tgz"; return 1 ;;
    esac
    self_script_valid "$SOURCE" || { rm -rf "$WORK"; error "脚本语法或身份校验失败"; return 1; }
    self_atomic_replace "$SOURCE" "$LOCAL_SCRIPT" || { rm -rf "$WORK"; error "原子安装失败"; return 1; }
    rm -rf "$WORK"
    self_install_shortcut v || warn "快捷键 v 创建失败"
    self_install_shortcut V || warn "快捷键 V 创建失败"
    audit_action "离线安装脚本 $(basename "$PACKAGE")" SUCCESS
    info "离线安装完成：$LOCAL_SCRIPT"
}

self_uninstall() {
    print_header "卸载 Quench 启动器"
    warn "将删除本地脚本 $LOCAL_SCRIPT 以及 Quench 管理的 v/V 软链接"
    ui_hint "不会删除 /var/lib/quench 中的备份、审计记录或已应用的系统配置"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return 0; }
    if [ -e "$LOCAL_SCRIPT" ] && ! rm -f "$LOCAL_SCRIPT"; then error "无法删除 $LOCAL_SCRIPT"; return 1; fi
    self_remove_shortcut v
    self_remove_shortcut V
    audit_action "卸载 Quench 启动器" SUCCESS
    info "本地脚本和 v/V 启动命令已删除；数据与系统配置已保留 ✓"
}

self_check_first_run() {
    self_shortcut_owned v && return
    [ -f "$LOCAL_SCRIPT" ] && return
    print_header "首次运行设置"
    menu_item "1" "安装到本地并设置 v/V 快捷命令" "$GREEN"
    menu_item "0" "跳过并进入主菜单" "$RED"
    read -rp "$(ui_prompt '选择操作 [0-1]: ')" CH
    [ "$CH" != 1 ] || { self_install; ui_pause; }
}

self_manage_menu() {
    while true; do
        print_header "脚本管理"
        local STATUS="未安装" VERSION="" HAS_CMD="未设置"
        if [ -f "$LOCAL_SCRIPT" ]; then
            STATUS="已安装"
            VERSION=$(sed -nE 's/^APP_VERSION="([^"]+)".*/\1/p' "$LOCAL_SCRIPT" | head -1)
        fi
        self_shortcut_owned v && HAS_CMD="已设置"
        echo -e "  本地路径：${BOLD}$LOCAL_SCRIPT${NC}"
        echo -e "  状态：${BOLD}$STATUS${NC}  ${VERSION:+版本：$VERSION  }快捷键 v：$HAS_CMD"
        echo ""; menu_div
        menu_pair "1" "安装并设置快捷键" "2" "校验并更新最新版"
        menu_pair "3" "卸载本地启动器" "4" "回滚历史版本" "$YELLOW" "$YELLOW"
        menu_item "5" "离线安装包"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
        case "$CH" in
            1) self_install; ui_pause ;; 2) self_update ;;
            3) self_uninstall; ui_pause ;; 4) self_rollback ;;
            5)
                print_header "离线安装包"
                menu_item "1" "生成离线安装包" "$GREEN"
                menu_item "2" "安装本地离线包" "$YELLOW"
                menu_item "0" "返回上级" "$RED"
                read -rp "$(ui_prompt '选择操作 [0-2]: ')" ACTION
                case "$ACTION" in
                    1) self_offline_bundle_create; ui_pause ;;
                    2) read -rp "$(ui_prompt '输入离线包路径 (.sh/.tar.gz): ')" PACKAGE; [ -z "$PACKAGE" ] || self_offline_bundle_install "$PACKAGE"; ui_pause ;;
                esac
                ;;
            0) return ;; 00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
