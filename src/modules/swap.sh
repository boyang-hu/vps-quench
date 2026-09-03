# ══════════════════════════════════════════════════════════
#  Swap 管理模块
# ══════════════════════════════════════════════════════════

QUENCH_SWAP_FILE="${QUENCH_SWAP_FILE:-/swapfile.quench}"
QUENCH_SWAP_STATE_DIR="${QUENCH_SWAP_STATE_DIR:-$QUENCH_DATA_DIR/swap}"
QUENCH_SWAP_STATE_FILE="${QUENCH_SWAP_STATE_FILE:-$QUENCH_SWAP_STATE_DIR/managed-file}"
QUENCH_SWAP_FSTAB="${QUENCH_SWAP_FSTAB:-/etc/fstab}"
QUENCH_SWAP_SYSCTL_FILE="${QUENCH_SWAP_SYSCTL_FILE:-/etc/sysctl.d/99-quench-swap.conf}"
QUENCH_SWAP_FSTAB_BEGIN="# BEGIN QUENCH SWAP"
QUENCH_SWAP_FSTAB_END="# END QUENCH SWAP"

swap_managed_path() {
    local PATH_VALUE=""
    [ ! -r "$QUENCH_SWAP_STATE_FILE" ] || IFS= read -r PATH_VALUE < "$QUENCH_SWAP_STATE_FILE"
    case "$PATH_VALUE" in
        /*) printf '%s\n' "$PATH_VALUE" ;;
        *) printf '%s\n' "$QUENCH_SWAP_FILE" ;;
    esac
}

swap_is_active() {
    local TARGET="$1"
    swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qxF "$TARGET"
}

swap_show_status() {
    local TOTAL USED FREE SWAPPINESS MANAGED
    echo -e "  ${BOLD}当前 Swap 状态：${NC}"
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show --bytes 2>/dev/null | while IFS= read -r LINE; do
            echo -e "  ${CYAN}${LINE}${NC}"
        done
        TOTAL=$(free -m 2>/dev/null | awk '/^Swap/{print $2}')
        USED=$(free -m 2>/dev/null | awk '/^Swap/{print $3}')
        FREE=$(free -m 2>/dev/null | awk '/^Swap/{print $4}')
        echo ""
        echo -e "  总计：${BOLD}${TOTAL:-0}MB${NC}  已用：${BOLD}${USED:-0}MB${NC}  空闲：${BOLD}${FREE:-0}MB${NC}"
    else
        echo -e "  ${YELLOW}当前未启用 Swap${NC}"
    fi
    echo ""
    SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")
    MANAGED=$(swap_managed_path)
    echo -e "  swappiness：${BOLD}${SWAPPINESS}${NC}  ${DIM}（值越高越积极换出匿名内存，范围 0–200）${NC}"
    if [ -f "$QUENCH_SWAP_STATE_FILE" ] || [ -f "$MANAGED" ]; then
        echo -e "  Quench 文件：${BOLD}${MANAGED}${NC}"
    else
        echo -e "  Quench 文件：${DIM}尚未创建；其他 Swap 不会被本模块删除${NC}"
    fi
}

swap_recommended_size_mb() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -le 512 ]; then echo 1024
    elif [ "$MEM_MB" -le 2048 ]; then echo 2048
    elif [ "$MEM_MB" -le 4096 ]; then echo 4096
    else echo 4096
    fi
}

swap_fstab_render() {
    local MODE="$1" TARGET="$2" SOURCE="$3"
    awk -v begin="$QUENCH_SWAP_FSTAB_BEGIN" -v end="$QUENCH_SWAP_FSTAB_END" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$SOURCE"
    if [ "$MODE" = add ]; then
        printf '%s\n%s none swap sw 0 0\n%s\n' \
            "$QUENCH_SWAP_FSTAB_BEGIN" "$TARGET" "$QUENCH_SWAP_FSTAB_END"
    fi
}

swap_fstab_markers_valid() {
    local SOURCE="$1" BEGIN_COUNT END_COUNT ORDER
    BEGIN_COUNT=$(grep -Fxc "$QUENCH_SWAP_FSTAB_BEGIN" "$SOURCE" 2>/dev/null || true)
    END_COUNT=$(grep -Fxc "$QUENCH_SWAP_FSTAB_END" "$SOURCE" 2>/dev/null || true)
    [ "$BEGIN_COUNT" -eq "$END_COUNT" ] || return 1
    [ "$BEGIN_COUNT" -le 1 ] || return 1
    [ "$BEGIN_COUNT" -eq 0 ] && return 0
    ORDER=$(awk -v begin="$QUENCH_SWAP_FSTAB_BEGIN" -v end="$QUENCH_SWAP_FSTAB_END" '
        $0 == begin && !start {start=NR}
        $0 == end && !finish {finish=NR}
        END {if (start && finish && start < finish) print "ok"}
    ' "$SOURCE")
    [ "$ORDER" = ok ]
}

swap_fstab_apply() {
    local MODE="$1" TARGET="$2" DIR STAGE SOURCE
    DIR=$(dirname "$QUENCH_SWAP_FSTAB")
    mkdir -p "$DIR" || return 1
    STAGE=$(mktemp "$DIR/.fstab.quench.XXXXXX") || return 1
    SOURCE="$QUENCH_SWAP_FSTAB"
    if [ ! -f "$SOURCE" ]; then
        SOURCE="$STAGE.empty"
        : > "$SOURCE"
    fi
    if ! swap_fstab_markers_valid "$SOURCE"; then
        rm -f "$STAGE" "$STAGE.empty"
        error "fstab 中的 Quench Swap 边界标记不完整或重复，已拒绝修改"
        return 1
    fi
    if ! swap_fstab_render "$MODE" "$TARGET" "$SOURCE" > "$STAGE"; then
        rm -f "$STAGE" "$STAGE.empty"
        return 1
    fi
    rm -f "$STAGE.empty"
    chmod 644 "$STAGE" || { rm -f "$STAGE"; return 1; }
    if command -v findmnt >/dev/null 2>&1 \
        && ! findmnt --verify --tab-file "$STAGE" >/dev/null 2>&1; then
        rm -f "$STAGE"
        error "生成的 fstab 未通过 findmnt 校验"
        return 1
    fi
    mv "$STAGE" "$QUENCH_SWAP_FSTAB"
}

swap_state_write() {
    local TARGET="$1" STAGE
    mkdir -p "$QUENCH_SWAP_STATE_DIR" || return 1
    chmod 700 "$QUENCH_SWAP_STATE_DIR" 2>/dev/null || true
    STAGE=$(mktemp "$QUENCH_SWAP_STATE_DIR/.managed-file.XXXXXX") || return 1
    printf '%s\n' "$TARGET" > "$STAGE" || { rm -f "$STAGE"; return 1; }
    chmod 600 "$STAGE" || { rm -f "$STAGE"; return 1; }
    mv "$STAGE" "$QUENCH_SWAP_STATE_FILE"
}

swap_filesystem_type() {
    local TARGET="$1" PARENT
    PARENT=$(dirname "$TARGET")
    findmnt -n -o FSTYPE --target "$PARENT" 2>/dev/null | head -1
}

swap_stage_file() {
    local TARGET="$1" SIZE_MB="$2" STAGE FSTYPE
    STAGE="${TARGET}.stage.$$"
    [ ! -e "$STAGE" ] || { error "临时文件已存在：$STAGE"; return 1; }
    FSTYPE=$(swap_filesystem_type "$TARGET")
    if [ "$FSTYPE" = btrfs ]; then
        command -v btrfs >/dev/null 2>&1 || {
            error "目标位于 Btrfs，但系统缺少 btrfs 工具，已拒绝创建不安全的 Swap 文件"
            return 1
        }
        btrfs filesystem mkswapfile --size "${SIZE_MB}m" "$STAGE" >/dev/null 2>&1 || {
            rm -f "$STAGE"; error "Btrfs Swap 文件创建失败"; return 1;
        }
    else
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${SIZE_MB}M" "$STAGE" 2>/dev/null \
                || dd if=/dev/zero of="$STAGE" bs=1M count="$SIZE_MB" status=none
        else
            dd if=/dev/zero of="$STAGE" bs=1M count="$SIZE_MB" status=none
        fi
        chmod 600 "$STAGE" || { rm -f "$STAGE"; return 1; }
        mkswap "$STAGE" >/dev/null 2>&1 || { rm -f "$STAGE"; error "Swap 格式化失败"; return 1; }
    fi
    chmod 600 "$STAGE" || { rm -f "$STAGE"; return 1; }
    printf '%s\n' "$STAGE"
}

swap_create_apply() {
    local SIZE_MB="$1" TARGET STAGE BACKUP="" FSTAB_BACKUP OLD_ACTIVE=false FAILED=false
    TARGET=$(swap_managed_path)
    case "$TARGET" in /*) ;; *) error "Swap 路径必须是绝对路径"; return 1 ;; esac
    mkdir -p "$(dirname "$TARGET")" || return 1
    STAGE=$(swap_stage_file "$TARGET" "$SIZE_MB") || return 1
    if [ -e "$TARGET" ] && [ ! -f "$QUENCH_SWAP_STATE_FILE" ]; then
        rm -f "$STAGE"
        error "$TARGET 已存在但没有 Quench 所有权记录，未执行 swapoff、覆盖或删除"
        return 1
    fi
    if [ -e "$TARGET" ] && { [ ! -f "$TARGET" ] || [ -L "$TARGET" ]; }; then
        rm -f "$STAGE"
        error "$TARGET 不是可安全替换的普通文件"
        return 1
    fi
    FSTAB_BACKUP=$(mktemp "${TMPDIR:-/tmp}/quench-fstab-before.XXXXXX") || { rm -f "$STAGE"; return 1; }
    if [ -f "$QUENCH_SWAP_FSTAB" ]; then cp -p "$QUENCH_SWAP_FSTAB" "$FSTAB_BACKUP" || FAILED=true
    else : > "$FSTAB_BACKUP.absent"; fi
    if [ "$FAILED" = false ] && swap_is_active "$TARGET"; then
        OLD_ACTIVE=true
        swapoff "$TARGET" >/dev/null 2>&1 || FAILED=true
    fi
    if [ "$FAILED" = false ] && [ -e "$TARGET" ]; then
        BACKUP="${TARGET}.before.$$"
        mv "$TARGET" "$BACKUP" || FAILED=true
    fi
    if [ "$FAILED" = false ]; then mv "$STAGE" "$TARGET" || FAILED=true; fi
    if [ "$FAILED" = false ]; then swapon "$TARGET" >/dev/null 2>&1 || FAILED=true; fi
    if [ "$FAILED" = false ]; then swap_fstab_apply add "$TARGET" || FAILED=true; fi
    if [ "$FAILED" = false ]; then swap_state_write "$TARGET" || FAILED=true; fi

    if [ "$FAILED" = true ]; then
        swapoff "$TARGET" >/dev/null 2>&1 || true
        rm -f "$TARGET" "$STAGE"
        if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
        if [ -f "$FSTAB_BACKUP.absent" ]; then rm -f "$QUENCH_SWAP_FSTAB"
        elif [ -f "$FSTAB_BACKUP" ]; then cp -p "$FSTAB_BACKUP" "$QUENCH_SWAP_FSTAB"; fi
        [ "$OLD_ACTIVE" = false ] || swapon "$TARGET" >/dev/null 2>&1 || true
        rm -f "$FSTAB_BACKUP" "$FSTAB_BACKUP.absent"
        error "Swap 变更失败，已恢复原文件和 fstab"
        audit_action "创建或更换 Quench Swap ${SIZE_MB}MB" FAILED
        return 1
    fi
    rm -f "$BACKUP" "$FSTAB_BACKUP" "$FSTAB_BACKUP.absent"
    audit_action "创建或更换 Quench Swap ${SIZE_MB}MB" SUCCESS
    info "Quench Swap 已事务式启用并写入 fstab ✓"
}

swap_create() {
    print_header "创建 / 更换 Swap"
    local MEM_MB DISK_FREE REC_SIZE CH SIZE_MB RESERVE_MB=512 TARGET_DIR
    MEM_MB=$(free -m 2>/dev/null | awk '/^Mem/{print $2}')
    MEM_MB=${MEM_MB:-0}
    TARGET_DIR=$(dirname "$(swap_managed_path)")
    mkdir -p "$TARGET_DIR" || return 1
    DISK_FREE=$(df -Pm "$TARGET_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    DISK_FREE=${DISK_FREE:-0}
    REC_SIZE=$(swap_recommended_size_mb "$MEM_MB")
    echo -e "  物理内存：${BOLD}${MEM_MB}MB${NC}  磁盘可用：${BOLD}${DISK_FREE}MB${NC}"
    echo -e "  推荐大小：${GREEN}${REC_SIZE}MB${NC}  ${DIM}完成后至少保留 ${RESERVE_MB}MB 磁盘空间${NC}"
    echo ""
    menu_div
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB" "4" "4 GB"
    menu_item "5" "使用动态推荐值 · ${REC_SIZE} MB" "$GREEN"
    menu_item "6" "自定义大小"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div; echo ""
    read -rp "$(ui_prompt '选择大小 [0-6]: ')" CH
    case "$CH" in
        1) SIZE_MB=512 ;; 2) SIZE_MB=1024 ;; 3) SIZE_MB=2048 ;; 4) SIZE_MB=4096 ;;
        5) SIZE_MB="$REC_SIZE" ;;
        6)
            read -rp "  请输入大小（MB，最小 64）: " SIZE_MB
            case "$SIZE_MB" in ''|*[!0-9]*) error "大小必须是整数"; return 1 ;; esac
            [ "$SIZE_MB" -ge 64 ] || { error "最小为 64MB"; return 1; }
            ;;
        0) return ;; 00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    if [ $((SIZE_MB + RESERVE_MB)) -gt "$DISK_FREE" ]; then
        error "磁盘空间不足：需要 ${SIZE_MB}MB，并需保留 ${RESERVE_MB}MB；当前可用 ${DISK_FREE}MB"
        return 1
    fi
    if grep -qaE '(^|/)lxc|openvz|container=lxc' /proc/1/environ 2>/dev/null || [ -f /proc/vz/veinfo ]; then
        warn "检测到受限容器，宿主机可能禁止 swapon；失败时会自动回滚"
    fi
    confirm_change_preview "创建或更换 Quench Swap" \
        "路径：$(swap_managed_path)" "大小：${SIZE_MB}MB" \
        "只替换 Quench 管理的 Swap，不影响 zram、分区或第三方 Swap" || return 0
    swap_create_apply "$SIZE_MB" && swap_show_status
}

swap_delete() {
    print_header "删除 Quench Swap"
    local TARGET FSTAB_BACKUP QUARANTINE="" WAS_ACTIVE=false FAILED=false CONFIRM
    TARGET=$(swap_managed_path)
    if [ ! -f "$QUENCH_SWAP_STATE_FILE" ]; then
        warn "没有 Quench 管理记录；为避免误删，其他 Swap 不会出现在删除入口"
        return 0
    fi
    [ -f "$TARGET" ] || { error "管理记录存在，但 Swap 文件不存在：$TARGET"; return 1; }
    confirm_change_preview "删除 Quench Swap" "目标：$TARGET" \
        "不会删除其他 Swap 分区、文件或 zram" || return 0
    read -rp "  输入 DELETE-SWAP 确认删除: " CONFIRM
    [ "$CONFIRM" = DELETE-SWAP ] || { warn "确认短语不匹配，已取消"; return 0; }
    FSTAB_BACKUP=$(mktemp "${TMPDIR:-/tmp}/quench-fstab-before.XXXXXX") || return 1
    if [ -f "$QUENCH_SWAP_FSTAB" ]; then cp -p "$QUENCH_SWAP_FSTAB" "$FSTAB_BACKUP" || FAILED=true
    else : > "$FSTAB_BACKUP.absent"; fi
    if [ "$FAILED" = false ] && swap_is_active "$TARGET"; then
        WAS_ACTIVE=true
        swapoff "$TARGET" >/dev/null 2>&1 || FAILED=true
    fi
    if [ "$FAILED" = false ]; then swap_fstab_apply remove "$TARGET" || FAILED=true; fi
    if [ "$FAILED" = false ]; then
        QUARANTINE="${TARGET}.delete.$$"
        mv "$TARGET" "$QUARANTINE" || FAILED=true
    fi
    if [ "$FAILED" = true ]; then
        [ -z "$QUARANTINE" ] || [ ! -f "$QUARANTINE" ] || mv "$QUARANTINE" "$TARGET"
        if [ -f "$FSTAB_BACKUP.absent" ]; then rm -f "$QUENCH_SWAP_FSTAB"
        elif [ -f "$FSTAB_BACKUP" ]; then cp -p "$FSTAB_BACKUP" "$QUENCH_SWAP_FSTAB"; fi
        [ "$WAS_ACTIVE" = false ] || swapon "$TARGET" >/dev/null 2>&1 || true
        rm -f "$FSTAB_BACKUP" "$FSTAB_BACKUP.absent"
        error "删除失败，已恢复 Swap 和 fstab"
        audit_action "删除 Quench Swap" FAILED
        return 1
    fi
    rm -f "$QUARANTINE" "$QUENCH_SWAP_STATE_FILE" "$FSTAB_BACKUP" "$FSTAB_BACKUP.absent"
    audit_action "删除 Quench Swap" SUCCESS
    info "Quench Swap 已删除；其他 Swap 未受影响 ✓"
}

swap_set_swappiness_apply() {
    local VALUE="$1" OLD_VALUE STAGE BACKUP="" HAD_FILE=false
    OLD_VALUE=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
    mkdir -p "$(dirname "$QUENCH_SWAP_SYSCTL_FILE")" || return 1
    STAGE=$(mktemp "$(dirname "$QUENCH_SWAP_SYSCTL_FILE")/.quench-swap.XXXXXX") || return 1
    printf '# Managed by Quench: Swap policy\nvm.swappiness = %s\n' "$VALUE" > "$STAGE" || { rm -f "$STAGE"; return 1; }
    chmod 644 "$STAGE" || { rm -f "$STAGE"; return 1; }
    if [ -f "$QUENCH_SWAP_SYSCTL_FILE" ]; then
        HAD_FILE=true
        BACKUP=$(mktemp "${TMPDIR:-/tmp}/quench-swap-sysctl.XXXXXX") || { rm -f "$STAGE"; return 1; }
        cp -p "$QUENCH_SWAP_SYSCTL_FILE" "$BACKUP" || { rm -f "$STAGE" "$BACKUP"; return 1; }
    fi
    if ! mv "$STAGE" "$QUENCH_SWAP_SYSCTL_FILE" \
        || ! sysctl -w "vm.swappiness=$VALUE" >/dev/null 2>&1 \
        || [ "$(sysctl -n vm.swappiness 2>/dev/null)" != "$VALUE" ]; then
        if [ "$HAD_FILE" = true ]; then cp -p "$BACKUP" "$QUENCH_SWAP_SYSCTL_FILE"
        else rm -f "$QUENCH_SWAP_SYSCTL_FILE"; fi
        sysctl -w "vm.swappiness=$OLD_VALUE" >/dev/null 2>&1 || true
        rm -f "$STAGE" "$BACKUP"
        error "swappiness 应用或回读失败，已恢复原值"
        audit_action "设置 swappiness=$VALUE" FAILED
        return 1
    fi
    rm -f "$BACKUP"
    audit_action "设置 swappiness=$VALUE" SUCCESS
    info "swappiness 已设置为 ${VALUE}，并写入独立 sysctl 配置 ✓"
}

swap_set_swappiness() {
    print_header "设置 Swappiness"
    local CUR CH VALUE
    CUR=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
    echo -e "  当前值：${BOLD}${CUR}${NC}"
    echo -e "  ${DIM}此参数是内存压力策略，不是性能等级；应按工作负载选择。${NC}"
    echo ""
    menu_item "1" "10 · 普通 VPS / 数据库"
    menu_item "2" "60 · Linux 常规默认"
    menu_item "3" "100 · 内存与 I/O 成本等权"
    menu_item "4" "133 · zram / zswap 常见起点"
    menu_item "5" "自定义 0–200"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择 Swappiness [0-5]: ')" CH
    case "$CH" in
        1) VALUE=10 ;; 2) VALUE=60 ;; 3) VALUE=100 ;; 4) VALUE=133 ;;
        5)
            read -rp "  请输入值（0–200）: " VALUE
            case "$VALUE" in ''|*[!0-9]*) error "值必须是整数"; return 1 ;; esac
            [ "$VALUE" -le 200 ] || { error "有效范围为 0–200"; return 1; }
            ;;
        0) return ;; 00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    confirm_change_preview "设置 Swap 使用倾向" "vm.swappiness = $VALUE" \
        "持久化文件：$QUENCH_SWAP_SYSCTL_FILE" || return 0
    swap_set_swappiness_apply "$VALUE"
}

swap_menu() {
    while true; do
        print_header "Swap 管理"
        swap_show_status
        menu_div
        menu_pair "1" "创建 / 更换 Quench Swap" "2" "删除 Quench Swap"
        menu_item "3" "设置 Swappiness"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" CH
        case "$CH" in
            1) swap_create ;; 2) swap_delete ;; 3) swap_set_swappiness ;;
            0) return ;; 00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
