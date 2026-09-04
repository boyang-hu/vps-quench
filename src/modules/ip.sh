# ══════════════════════════════════════════════════════════
#  IP 状态、地址选择与出口管理
# ══════════════════════════════════════════════════════════

IP_GAI_CONF="${QUENCH_GAI_CONF:-/etc/gai.conf}"
IP_GAI_BEGIN="# BEGIN QUENCH ADDRESS SELECTION"
IP_GAI_END="# END QUENCH ADDRESS SELECTION"
IP_V6_SYSCTL_FILE="${QUENCH_IPV6_SYSCTL_FILE:-/etc/sysctl.d/99-quench-ipv6.conf}"
IP_V6_CONF_MARKER="# Managed by Quench: kernel IPv6 state"
IP_V6_PROC_ROOT="${QUENCH_IPV6_PROC_ROOT:-/proc/sys/net/ipv6/conf}"
IP_SYSCTL_CONF="${QUENCH_SYSCTL_CONF:-/etc/sysctl.conf}"
IP_SYSCTL_DIR="${QUENCH_SYSCTL_DIR:-/etc/sysctl.d}"
IP_STATE_DIR="${QUENCH_IP_STATE_DIR:-$QUENCH_DATA_DIR/ip}"

ip_gai_supported() {
    getconf GNU_LIBC_VERSION >/dev/null 2>&1 && return 0
    command -v ldd >/dev/null 2>&1 || return 1
    LC_ALL=C ldd --version 2>&1 | head -1 | grep -Eqi 'glibc|GNU libc|GNU C Library'
}

ip_gai_markers_valid() {
    local FILE="$1"
    [ -f "$FILE" ] || return 0
    awk -v begin="$IP_GAI_BEGIN" -v end="$IP_GAI_END" '
        $0 == begin {
            if (active || begin_count || end_count) invalid=1
            active=1; begin_count++; next
        }
        $0 == end {
            if (!active || end_count) invalid=1
            active=0; end_count++; next
        }
        END {
            if (active) invalid=1
            if (!((begin_count == 0 && end_count == 0) || (begin_count == 1 && end_count == 1))) invalid=1
            exit invalid
        }
    ' "$FILE"
}

ip_gai_managed() {
    [ -f "$IP_GAI_CONF" ] || return 1
    grep -Fqx "$IP_GAI_BEGIN" "$IP_GAI_CONF" \
        && grep -Fqx "$IP_GAI_END" "$IP_GAI_CONF"
}

ip_gai_strip_managed() {
    local SOURCE="$1" DEST="$2"
    [ -f "$SOURCE" ] || { : > "$DEST"; return; }
    ip_gai_markers_valid "$SOURCE" || return 1
    awk -v begin="$IP_GAI_BEGIN" -v end="$IP_GAI_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        !managed {print}
    ' "$SOURCE" > "$DEST"
}

ip_gai_has_external_precedence() {
    local FILE="$1"
    [ -f "$FILE" ] || return 1
    awk -v begin="$IP_GAI_BEGIN" -v end="$IP_GAI_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        !managed && $0 ~ /^[[:space:]]*precedence[[:space:]]+/ {found=1}
        END {exit !found}
    ' "$FILE"
}

# gai.conf 中出现任意 precedence 行后，glibc 不再使用内置表，因此必须写完整表。
ip_gai_render_v4() {
    local SOURCE="$1" DEST="$2"
    ip_gai_markers_valid "$SOURCE" || return 1
    ip_gai_has_external_precedence "$SOURCE" && return 2
    ip_gai_strip_managed "$SOURCE" "$DEST" || return 1
    [ ! -s "$DEST" ] || printf '\n' >> "$DEST"
    cat >> "$DEST" <<EOF
$IP_GAI_BEGIN
# Full glibc precedence table; IPv4-mapped destinations are intentionally raised.
precedence ::1/128       50
precedence ::/0          40
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 100
$IP_GAI_END
EOF
}

ip_gai_validate_v4() {
    local FILE="$1"
    ip_gai_markers_valid "$FILE" || return 1
    [ "$(grep -Fxc "$IP_GAI_BEGIN" "$FILE" 2>/dev/null)" -eq 1 ] || return 1
    [ "$(grep -Ec '^[[:space:]]*precedence[[:space:]]+' "$FILE" 2>/dev/null)" -eq 5 ] || return 1
    grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100[[:space:]]*$' "$FILE"
}

ip_gai_policy_label() {
    if ! ip_gai_supported; then
        echo "当前 libc 不支持 gai.conf"
    elif ip_gai_managed; then
        echo "glibc 双栈目标优先 IPv4（Quench）"
    elif ip_gai_has_external_precedence "$IP_GAI_CONF"; then
        echo "外部自定义 precedence"
    else
        echo "glibc 系统默认地址选择"
    fi
}

ip_prefer_v4() {
    local PARENT STAGE RC=0
    print_header "双栈目标优先使用 IPv4"
    ip_gai_supported || {
        error "当前系统不是 glibc，/etc/gai.conf 不会可靠生效"
        return 1
    }
    ip_gai_markers_valid "$IP_GAI_CONF" || { error "gai.conf 中的 Quench 标记不完整，拒绝修改"; return 1; }
    if ip_gai_has_external_precedence "$IP_GAI_CONF"; then
        error "检测到非 Quench 的 precedence 规则；为避免覆盖用户地址选择表，已拒绝修改"
        return 1
    fi
    PARENT=$(dirname "$IP_GAI_CONF")
    mkdir -p "$PARENT" || return 1
    STAGE=$(mktemp "${IP_GAI_CONF}.quench.XXXXXX") || return 1
    ip_gai_render_v4 "$IP_GAI_CONF" "$STAGE" || RC=$?
    if [ "$RC" -ne 0 ] || ! ip_gai_validate_v4 "$STAGE"; then
        rm -f "$STAGE"
        error "无法生成完整的 glibc 地址选择表"
        return 1
    fi
    confirm_file_diff "$IP_GAI_CONF" "$STAGE" "glibc 地址选择策略" || { rm -f "$STAGE"; warn "已取消"; return 0; }
    confirm_change_preview "双栈目标优先 IPv4" \
        "只影响使用 glibc getaddrinfo() 的新连接" \
        "不关闭 IPv6，也不修改默认路由" \
        "完整保留 glibc 默认 precedence 表，仅提高 IPv4-mapped 项" || { rm -f "$STAGE"; warn "已取消"; return 0; }
    safety_arm prefer_v4 "$IP_GAI_CONF" || { rm -f "$STAGE"; return 1; }
    chmod 644 "$STAGE" 2>/dev/null || true
    if ! mv "$STAGE" "$IP_GAI_CONF" || ! ip_gai_validate_v4 "$IP_GAI_CONF"; then
        rm -f "$STAGE"
        safety_rollback_now >/dev/null 2>&1 || true
        error "IPv4 地址选择策略写入失败，已恢复原配置"
        return 1
    fi
    audit_action "设置 glibc 双栈目标优先 IPv4" SUCCESS
    info "glibc 地址选择策略已设置为双栈目标优先 IPv4 ✓"
    warn "此设置不影响自行实现 DNS/Happy Eyeballs 的程序，也不会改变现有连接"
    safety_confirm
}

ip_prefer_v6() {
    local PARENT STAGE
    print_header "恢复系统默认地址选择"
    ip_gai_managed || { info "未检测到 Quench 地址选择规则，无需恢复"; return 0; }
    ip_gai_markers_valid "$IP_GAI_CONF" || { error "gai.conf 中的 Quench 标记不完整，拒绝修改"; return 1; }
    PARENT=$(dirname "$IP_GAI_CONF")
    STAGE=$(mktemp "${PARENT}/.gai.conf.quench.XXXXXX") || return 1
    ip_gai_strip_managed "$IP_GAI_CONF" "$STAGE" || { rm -f "$STAGE"; return 1; }
    confirm_file_diff "$IP_GAI_CONF" "$STAGE" "恢复 glibc 系统默认地址选择" || { rm -f "$STAGE"; warn "已取消"; return 0; }
    confirm_change_preview "恢复系统默认地址选择" \
        "只移除 Quench 管理区块" \
        "保留其他注释和用户配置" \
        "不等同于强制 IPv6；glibc 仍会结合可达性与源地址选择" || { rm -f "$STAGE"; warn "已取消"; return 0; }
    safety_arm restore_gai "$IP_GAI_CONF" || { rm -f "$STAGE"; return 1; }
    if grep -q '[^[:space:]]' "$STAGE"; then
        chmod 644 "$STAGE" 2>/dev/null || true
        mv "$STAGE" "$IP_GAI_CONF" || {
            rm -f "$STAGE"; safety_rollback_now >/dev/null 2>&1 || true
            error "恢复地址选择策略失败，已恢复原配置"; return 1;
        }
    else
        rm -f "$STAGE" "$IP_GAI_CONF"
    fi
    ip_gai_managed && {
        safety_rollback_now >/dev/null 2>&1 || true
        error "Quench 地址选择规则仍然存在，已撤销操作"
        return 1
    }
    audit_action "恢复 glibc 系统默认地址选择" SUCCESS
    info "已移除 Quench 地址选择规则，恢复 glibc 系统默认 ✓"
    safety_confirm
}

ip_v6_state_summary() {
    local FILE IFACE VALUE ENABLED=0 DISABLED=0 TOTAL=0
    [ -d "$IP_V6_PROC_ROOT" ] || { echo "内核 IPv6 不可用"; return; }
    for FILE in "$IP_V6_PROC_ROOT"/*/disable_ipv6; do
        [ -f "$FILE" ] || continue
        IFACE=$(basename "$(dirname "$FILE")")
        case "$IFACE" in all|default) continue ;; esac
        VALUE=$(cat "$FILE" 2>/dev/null || echo unknown)
        case "$VALUE" in
            0) ENABLED=$((ENABLED+1)) ;;
            1) DISABLED=$((DISABLED+1)) ;;
        esac
        TOTAL=$((TOTAL+1))
    done
    if [ "$TOTAL" -eq 0 ]; then
        echo "未检测到接口状态"
    elif [ "$DISABLED" -eq 0 ]; then
        echo "所有接口已启用"
    elif [ "$ENABLED" -eq 0 ]; then
        echo "所有接口已禁用"
    else
        echo "混合状态（启用 ${ENABLED} / 禁用 ${DISABLED}）"
    fi
}

ip_v6_external_disable_sources() {
    local FILE
    for FILE in "$IP_SYSCTL_CONF" "$IP_SYSCTL_DIR"/*.conf; do
        [ -f "$FILE" ] || continue
        [ "$FILE" = "$IP_V6_SYSCTL_FILE" ] && continue
        awk -v file="$FILE" '
            /^[[:space:]]*#/ {next}
            /^[[:space:]]*net\.ipv6\.conf\.[^[:space:]]+\.disable_ipv6[[:space:]]*=[[:space:]]*1([[:space:]]|$)/ {
                print file ":" NR ":" $0
            }
        ' "$FILE"
    done
}

ip_v6_config_managed() {
    [ -f "$IP_V6_SYSCTL_FILE" ] && [ ! -L "$IP_V6_SYSCTL_FILE" ] || return 1
    grep -Fqx "$IP_V6_CONF_MARKER" "$IP_V6_SYSCTL_FILE"
}

ip_state_prepare() {
    mkdir -p "$IP_STATE_DIR" || return 1
    chmod 700 "$IP_STATE_DIR" 2>/dev/null || true
}

ip_state_prune() {
    local DIR COUNT=0
    while IFS= read -r DIR; do
        [ "$DIR" = "${IP_V6_SNAPSHOT:-}" ] && continue
        COUNT=$((COUNT+1))
        [ "$COUNT" -le 10 ] || {
            case "$DIR" in "$IP_STATE_DIR"/v6-backup.*) rm -rf -- "$DIR" ;; esac
        }
    done < <(find "$IP_STATE_DIR" -maxdepth 1 -type d -name 'v6-backup.*' 2>/dev/null | sort -r)
}

ip_v6_snapshot_create() {
    local DEST FILE IFACE VALUE COUNT=0
    ip_state_prepare || return 1
    [ -d "$IP_V6_PROC_ROOT" ] || return 1
    DEST=$(mktemp -d "$IP_STATE_DIR/v6-backup.$(date +%Y%m%d_%H%M%S).XXXXXX") || return 1
    if [ -f "$IP_V6_SYSCTL_FILE" ]; then
        cp -a "$IP_V6_SYSCTL_FILE" "$DEST/managed.conf" || { rm -rf "$DEST"; return 1; }
        echo yes > "$DEST/had-managed"
    else
        echo no > "$DEST/had-managed"
    fi
    : > "$DEST/runtime.state"
    for FILE in "$IP_V6_PROC_ROOT"/*/disable_ipv6; do
        [ -f "$FILE" ] || continue
        IFACE=$(basename "$(dirname "$FILE")")
        [[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || { rm -rf "$DEST"; return 1; }
        VALUE=$(cat "$FILE" 2>/dev/null) || { rm -rf "$DEST"; return 1; }
        [[ "$VALUE" =~ ^[01]$ ]] || { rm -rf "$DEST"; return 1; }
        printf '%s|%s\n' "$IFACE" "$VALUE" >> "$DEST/runtime.state" || { rm -rf "$DEST"; return 1; }
        COUNT=$((COUNT+1))
    done
    [ "$COUNT" -gt 0 ] || { rm -rf "$DEST"; return 1; }
    chmod -R go-rwx "$DEST" 2>/dev/null || true
    IP_V6_SNAPSHOT="$DEST"
    ip_state_prune
}

ip_v6_rollback_script_create() {
    local SNAPSHOT="$1" SCRIPT="$2" DELAY="$3"
    local SNAPSHOT_Q SCRIPT_Q PROC_Q CONF_Q
    printf -v SNAPSHOT_Q '%q' "$SNAPSHOT"
    printf -v SCRIPT_Q '%q' "$SCRIPT"
    printf -v PROC_Q '%q' "$IP_V6_PROC_ROOT"
    printf -v CONF_Q '%q' "$IP_V6_SYSCTL_FILE"
    cat > "$SCRIPT" <<EOF
#!/bin/bash
SNAPSHOT=$SNAPSHOT_Q
SELF=$SCRIPT_Q
PROC_ROOT=$PROC_Q
MANAGED_CONF=$CONF_Q
ROLLBACK_SLEEP_PID=""
rollback_cancel_wait() {
    [ -z "\$ROLLBACK_SLEEP_PID" ] || kill "\$ROLLBACK_SLEEP_PID" 2>/dev/null || true
    exit 0
}
trap rollback_cancel_wait TERM INT
if [ "\${1:-}" != --now ]; then
    sleep $DELAY & ROLLBACK_SLEEP_PID=\$!
    wait "\$ROLLBACK_SLEEP_PID" || exit 0
fi
trap - TERM INT
RC=0
HAD=\$(cat "\$SNAPSHOT/had-managed" 2>/dev/null)
if [ "\$HAD" = yes ]; then
    mkdir -p "\$(dirname "\$MANAGED_CONF")" || RC=1
    cp -a "\$SNAPSHOT/managed.conf" "\$MANAGED_CONF" || RC=1
elif [ "\$HAD" = no ]; then
    rm -f "\$MANAGED_CONF" || RC=1
else
    RC=1
fi
restore_iface() {
    WANT="\$1"
    while IFS='|' read -r IFACE VALUE; do
        [ "\$IFACE" = "\$WANT" ] || continue
        case "\$IFACE" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
        case "\$VALUE" in 0|1) ;; *) return 1 ;; esac
        TARGET="\$PROC_ROOT/\$IFACE/disable_ipv6"
        if [ ! -f "\$TARGET" ]; then
            case "\$WANT" in all|default) return 1 ;; *) return 0 ;; esac
        fi
        printf '%s\n' "\$VALUE" > "\$TARGET" 2>/dev/null
        return
    done < "\$SNAPSHOT/runtime.state"
}
restore_iface all || RC=1
restore_iface default || RC=1
while IFS='|' read -r IFACE VALUE; do
    case "\$IFACE" in all|default) continue ;; esac
    restore_iface "\$IFACE" || RC=1
done < "\$SNAPSHOT/runtime.state"
if [ "\$RC" -eq 0 ]; then
    logger -t quench "未确认连接，已恢复 IPv6 内核运行时与持久化状态"
    rm -f "\$SELF"
else
    logger -t quench "IPv6 自动恢复失败，请立即检查网络状态；回滚脚本已保留：\$SELF"
fi
exit "\$RC"
EOF
    chmod 700 "$SCRIPT"
}

ip_v6_safety_arm() {
    local LABEL="$1" DELAY="${SAFETY_DELAY_SECONDS:-180}" SCRIPT
    [[ "$DELAY" =~ ^[0-9]+$ ]] && [ "$DELAY" -ge 1 ] || DELAY=180
    txn_lock_acquire || return 1
    if safety_timer_pending; then
        warn "检测到上一笔未确认的网络变更，先恢复上一笔配置"
        safety_rollback_now || return 1
    fi
    ip_v6_snapshot_create || return 1
    SCRIPT="$QUENCH_DATA_DIR/rollback_ipv6_$$_$(date +%s)_${RANDOM}.sh"
    ip_v6_rollback_script_create "$IP_V6_SNAPSHOT" "$SCRIPT" "$DELAY" || { rm -f "$SCRIPT"; return 1; }
    safety_launch_timer "$SCRIPT" \
        || { rm -f "$SCRIPT"; txn_lock_release; error "无法启动防断联回滚计时器"; return 1; }
    txn_record_begin "$LABEL" "$SCRIPT"
    audit_action "启动防断联保护 $LABEL" SUCCESS
    warn "IPv6 精确回滚保护已启动：${DELAY} 秒内未确认将恢复原运行时与配置状态。"
}

ip_v6_write_runtime() {
    local VALUE="$1" FILE IFACE RC=0
    [ -d "$IP_V6_PROC_ROOT" ] || return 1
    for IFACE in all default; do
        FILE="$IP_V6_PROC_ROOT/$IFACE/disable_ipv6"
        [ -f "$FILE" ] || return 1
        printf '%s\n' "$VALUE" > "$FILE" 2>/dev/null || RC=1
    done
    for FILE in "$IP_V6_PROC_ROOT"/*/disable_ipv6; do
        [ -f "$FILE" ] || continue
        IFACE=$(basename "$(dirname "$FILE")")
        case "$IFACE" in all|default) continue ;; esac
        printf '%s\n' "$VALUE" > "$FILE" 2>/dev/null || RC=1
    done
    return "$RC"
}

ip_v6_runtime_matches() {
    local VALUE="$1" FILE IFACE CURRENT COUNT=0
    [ -f "$IP_V6_PROC_ROOT/default/disable_ipv6" ] || return 1
    [ "$(cat "$IP_V6_PROC_ROOT/default/disable_ipv6" 2>/dev/null)" = "$VALUE" ] || return 1
    for FILE in "$IP_V6_PROC_ROOT"/*/disable_ipv6; do
        [ -f "$FILE" ] || continue
        IFACE=$(basename "$(dirname "$FILE")")
        case "$IFACE" in all|default) continue ;; esac
        CURRENT=$(cat "$FILE" 2>/dev/null) || return 1
        [ "$CURRENT" = "$VALUE" ] || return 1
        COUNT=$((COUNT+1))
    done
    [ "$COUNT" -gt 0 ]
}

ip_apply_v6_state() {
    local VALUE="$1" PARENT TEMP
    [ "$VALUE" = 0 ] || [ "$VALUE" = 1 ] || return 1
    if { [ -e "$IP_V6_SYSCTL_FILE" ] || [ -L "$IP_V6_SYSCTL_FILE" ]; } && ! ip_v6_config_managed; then
        return 1
    fi
    PARENT=$(dirname "$IP_V6_SYSCTL_FILE")
    mkdir -p "$PARENT" || return 1
    if [ "$VALUE" = 1 ]; then
        TEMP=$(mktemp "${IP_V6_SYSCTL_FILE}.tmp.XXXXXX") || return 1
        cat > "$TEMP" <<EOF
$IP_V6_CONF_MARKER
# Disable IPv6 on current and future interfaces.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
        chmod 644 "$TEMP" 2>/dev/null || true
        mv "$TEMP" "$IP_V6_SYSCTL_FILE" || { rm -f "$TEMP"; return 1; }
    else
        rm -f "$IP_V6_SYSCTL_FILE" || return 1
    fi
    ip_v6_write_runtime "$VALUE" || return 1
    ip_v6_runtime_matches "$VALUE"
}

ip_disable_v6() {
    local SUMMARY
    print_header "高级：禁用内核 IPv6"
    if { [ -e "$IP_V6_SYSCTL_FILE" ] || [ -L "$IP_V6_SYSCTL_FILE" ]; } && ! ip_v6_config_managed; then
        error "$IP_V6_SYSCTL_FILE 已存在且不受 Quench 管理，拒绝覆盖"
        return 1
    fi
    SUMMARY=$(ip_v6_state_summary)
    if [ "$SUMMARY" = "所有接口已禁用" ] && [ -f "$IP_V6_SYSCTL_FILE" ]; then
        info "IPv6 已由 Quench 在所有接口持久禁用"
        return 0
    fi
    warn "内核会立即删除所有接口的 IPv6 地址和路由；这不是性能优化。"
    confirm_change_preview "禁用内核 IPv6" \
        "立即禁用当前与未来接口的 IPv6" \
        "写入 Quench 独立 sysctl 配置" \
        "保存每个接口的原始运行时值，失败或未确认时精确恢复" || { warn "已取消"; return 0; }
    ip_v6_safety_arm disable_v6 || { error "无法建立 IPv6 精确回滚快照"; return 1; }
    if ! ip_apply_v6_state 1; then
        safety_rollback_now >/dev/null 2>&1 || true
        error "IPv6 禁用失败，已尝试立即恢复原状态"
        return 1
    fi
    audit_action "禁用内核 IPv6" SUCCESS
    info "IPv6 已在当前及未来接口禁用 ✓"
    safety_confirm
}

ip_enable_v6() {
    local CONFLICTS V6_ADDRS LINE ATTEMPT
    print_header "高级：移除 Quench IPv6 禁用"
    if { [ -e "$IP_V6_SYSCTL_FILE" ] || [ -L "$IP_V6_SYSCTL_FILE" ]; } && ! ip_v6_config_managed; then
        error "$IP_V6_SYSCTL_FILE 已存在且不受 Quench 管理，拒绝删除"
        return 1
    fi
    CONFLICTS=$(ip_v6_external_disable_sources)
    if [ -n "$CONFLICTS" ]; then
        error "检测到其他配置仍要求禁用 IPv6；Quench 不会覆盖它们："
        while IFS= read -r LINE; do echo -e "  ${DIM}${LINE}${NC}"; done <<< "$CONFLICTS"
        return 1
    fi
    [ -f "$IP_V6_SYSCTL_FILE" ] || {
        [ "$(ip_v6_state_summary)" != "所有接口已启用" ] \
            || { info "未检测到 Quench IPv6 禁用配置，所有接口已经启用"; return 0; }
    }
    confirm_change_preview "移除 Quench IPv6 禁用" \
        "删除 Quench 管理的禁用配置" \
        "立即为当前与未来接口启用内核 IPv6" \
        "公网地址和默认路由仍取决于服务商及网络后端" || { warn "已取消"; return 0; }
    ip_v6_safety_arm enable_v6 || { error "无法建立 IPv6 精确回滚快照"; return 1; }
    if ! ip_apply_v6_state 0; then
        safety_rollback_now >/dev/null 2>&1 || true
        error "IPv6 启用失败，已尝试立即恢复原状态"
        return 1
    fi
    info "内核 IPv6 已在所有当前接口启用 ✓"
    V6_ADDRS=""
    for ((ATTEMPT=1; ATTEMPT<=10; ATTEMPT++)); do
        V6_ADDRS=$(ip -6 -o addr show scope global 2>/dev/null | awk '$3 == "inet6" {print $4}')
        [ -n "$V6_ADDRS" ] && break
        sleep 1
    done
    if [ -n "$V6_ADDRS" ]; then
        echo -e "  全局地址：${BOLD}$(tr '\n' ' ' <<< "$V6_ADDRS")${NC}"
    else
        warn "内核已启用，但暂未获得全局 IPv6 地址；请检查服务商配置、RA/DHCPv6 和网络后端"
    fi
    audit_action "移除 Quench IPv6 禁用并启用内核 IPv6" SUCCESS
    safety_confirm
}

ip_source_probe() {
    case "$1" in
        4) echo "1.1.1.1" ;;
        6) echo "2606:4700:4700::1111" ;;
        *) return 1 ;;
    esac
}

ip_source_policy_is_simple() {
    local FAMILY="$1" OUTPUT
    OUTPUT=$(ip "-$FAMILY" rule show 2>/dev/null) || return 1
    [ -n "$OUTPUT" ] || return 1
    awk '
        /^[[:space:]]*0:[[:space:]]+from all lookup local[[:space:]]*$/ {next}
        /^[[:space:]]*32766:[[:space:]]+from all lookup main[[:space:]]*$/ {next}
        /^[[:space:]]*32767:[[:space:]]+from all lookup default[[:space:]]*$/ {next}
        NF {custom=1}
        END {exit custom}
    ' <<< "$OUTPUT"
}

ip_source_default_iface() {
    local FAMILY="$1" PROBE ROUTE TABLE
    PROBE=$(ip_source_probe "$FAMILY") || return 1
    ROUTE=$(ip "-$FAMILY" route get "$PROBE" 2>/dev/null | head -1) || return 1
    TABLE=$(ip_route_token "$ROUTE" table)
    [ -z "$TABLE" ] || [ "$TABLE" = main ] || [ "$TABLE" = 254 ] || return 1
    awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$ROUTE"
}

ip_source_current() {
    local FAMILY="$1" PROBE ROUTE
    PROBE=$(ip_source_probe "$FAMILY") || return 1
    ROUTE=$(ip "-$FAMILY" route get "$PROBE" 2>/dev/null | head -1) || return 1
    awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$ROUTE"
}

ip_source_addresses() {
    local FAMILY="$1" IFACE="$2" KIND
    [ "$FAMILY" = 4 ] && KIND=inet || KIND=inet6
    ip "-$FAMILY" -o addr show dev "$IFACE" scope global 2>/dev/null | awk -v kind="$KIND" '
        $3 == kind && $0 !~ /(^|[[:space:]])(tentative|dadfailed|deprecated|temporary)([[:space:]]|$)/ {
            sub(/\/.*/, "", $4)
            if (!seen[$4]++) print $4
        }
    '
}

ip_source_default_route() {
    local FAMILY="$1"
    ip "-$FAMILY" route show default 2>/dev/null
}

ip_route_token() {
    local ROUTE="$1" KEY="$2"
    awk -v key="$KEY" '{for (i=1; i<NF; i++) if ($i == key) {print $(i+1); exit}}' <<< "$ROUTE"
}

ip_source_route_replace() {
    local FAMILY="$1" ROUTE_LINE="$2" SELECTED="$3" TOKEN SKIP_NEXT=0
    local TOKENS=() OUTPUT=()
    read -r -a TOKENS <<< "$ROUTE_LINE"
    [ "${#TOKENS[@]}" -gt 0 ] && [ "${TOKENS[0]}" = default ] || return 1
    for TOKEN in "${TOKENS[@]}"; do
        if [ "$SKIP_NEXT" -eq 1 ]; then SKIP_NEXT=0; continue; fi
        case "$TOKEN" in
            src) SKIP_NEXT=1 ;;
            *) OUTPUT+=("$TOKEN") ;;
        esac
    done
    ip "-$FAMILY" route replace "${OUTPUT[@]}" src "$SELECTED"
}

ip_source_route_restore() {
    local FAMILY="$1" ROUTE_LINE="$2" TOKENS=()
    read -r -a TOKENS <<< "$ROUTE_LINE"
    [ "${#TOKENS[@]}" -gt 0 ] && [ "${TOKENS[0]}" = default ] || return 1
    ip "-$FAMILY" route replace "${TOKENS[@]}"
}

ip_source_safety_arm() {
    local FAMILY="$1" ROUTE_LINE="$2" SCRIPT DELAY="${SAFETY_DELAY_SECONDS:-180}" TOKEN
    local TOKENS=()
    [[ "$DELAY" =~ ^[0-9]+$ ]] && [ "$DELAY" -ge 1 ] || DELAY=180
    txn_lock_acquire || return 1
    if safety_timer_pending; then
        warn "检测到上一笔未确认的网络变更，先恢复上一笔配置"
        safety_rollback_now || return 1
    fi
    read -r -a TOKENS <<< "$ROUTE_LINE"
    [ "${#TOKENS[@]}" -gt 0 ] || return 1
    mkdir -p "$QUENCH_DATA_DIR" || return 1
    SCRIPT="$QUENCH_DATA_DIR/rollback_ip_source_$$_$(date +%s)_${RANDOM}.sh"
    # shellcheck disable=SC2016 # 这里是在“生成”回滚脚本：$ROLLBACK_SLEEP_PID / $! / $?
    # 必须原样写进文件、留到那个脚本自己运行时再展开，不能在这里展开。
    {
        echo '#!/bin/bash'
        echo 'ROLLBACK_SLEEP_PID=""'
        echo 'rollback_cancel_wait() {'
        echo '    [ -z "$ROLLBACK_SLEEP_PID" ] || kill "$ROLLBACK_SLEEP_PID" 2>/dev/null || true'
        echo '    exit 0'
        echo '}'
        echo 'trap rollback_cancel_wait TERM INT'
        printf 'if [ "${1:-}" != --now ]; then sleep %q & ROLLBACK_SLEEP_PID=$!; wait "$ROLLBACK_SLEEP_PID" || exit 0; fi\n' "$DELAY"
        echo 'trap - TERM INT'
        printf 'ip -%q route replace' "$FAMILY"
        for TOKEN in "${TOKENS[@]}"; do printf ' %q' "$TOKEN"; done
        echo ' >/dev/null 2>&1'
        printf 'RC=$?; if [ "$RC" -eq 0 ]; then logger -t quench %q; rm -f %q; else logger -t quench %q; fi; exit "$RC"\n' \
            "未确认连接，已自动恢复 IPv${FAMILY} 首选源地址" "$SCRIPT" \
            "IPv${FAMILY} 首选源地址自动恢复失败，请立即检查默认路由"
    } > "$SCRIPT" || { rm -f "$SCRIPT"; return 1; }
    chmod 700 "$SCRIPT" || { rm -f "$SCRIPT"; return 1; }
    safety_launch_timer "$SCRIPT" \
        || { rm -f "$SCRIPT"; txn_lock_release; error "无法启动防断联回滚计时器"; return 1; }
    txn_record_begin "IPv${FAMILY} 源地址切换" "$SCRIPT"
    audit_action "启动防断联保护 IPv${FAMILY} 源地址切换" SUCCESS
    warn "防断联保护已启动：${DELAY} 秒内未确认将自动恢复原默认路由。"
}

ip_address_valid() {
    local FAMILY="$1" VALUE="$2" OCTET
    local OCTETS=()
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$FAMILY" "$VALUE" <<'PY' >/dev/null 2>&1
import ipaddress, sys
family, value = sys.argv[1:]
parsed = ipaddress.ip_address(value)
raise SystemExit(0 if parsed.version == int(family) else 1)
PY
        return
    fi
    if [ "$FAMILY" = 6 ]; then [[ "$VALUE" == *:* && "$VALUE" =~ ^[0-9A-Fa-f:]+$ ]]; return; fi
    [[ "$VALUE" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a OCTETS <<< "$VALUE"
    for OCTET in "${OCTETS[@]}"; do ((10#$OCTET <= 255)) || return 1; done
}

ip_source_verify() {
    local FAMILY="$1" SELECTED="$2" ACTUAL ENDPOINT PUBLIC_IP
    ACTUAL=$(ip_source_current "$FAMILY" 2>/dev/null || true)
    [ "$ACTUAL" = "$SELECTED" ] || return 1
    [ "$FAMILY" = 4 ] && ENDPOINT="https://api.ipify.org" || ENDPOINT="https://api64.ipify.org"
    PUBLIC_IP=$(curl "-$FAMILY" --interface "$SELECTED" -fsS --max-time 8 "$ENDPOINT" 2>/dev/null) || return 1
    PUBLIC_IP=${PUBLIC_IP//$'\r'/}; PUBLIC_IP=${PUBLIC_IP//$'\n'/}
    ip_address_valid "$FAMILY" "$PUBLIC_IP" || return 1
    IP_SOURCE_PUBLIC_IP="$PUBLIC_IP"
}

ip_source_switch_family() {
    local FAMILY="$1" LABEL IFACE CURRENT ROUTES ROUTE_COUNT ROUTE_LINE ROUTE_IFACE SELECTED CHOICE PUBLIC_IP
    local ADDRESSES=() ADDR INDEX=0
    [ "$FAMILY" = 4 ] && LABEL=IPv4 || LABEL=IPv6
    command -v curl >/dev/null 2>&1 || { error "缺少 curl，无法在变更后验证绑定源地址的 HTTPS 出口"; return 1; }
    ip_source_policy_is_simple "$FAMILY" || {
        error "检测到自定义策略路由或无法读取路由规则，已拒绝修改"
        return 1
    }
    IFACE=$(ip_source_default_iface "$FAMILY" 2>/dev/null || true)
    [ -n "$IFACE" ] || { error "未检测到简单 main 表中的 ${LABEL} 默认出口网卡"; return 1; }
    ROUTES=$(ip_source_default_route "$FAMILY")
    ROUTE_COUNT=$(awk 'NF {count++} END {print count+0}' <<< "$ROUTES")
    if [ "$ROUTE_COUNT" -ne 1 ] || grep -qw nexthop <<< "$ROUTES"; then
        error "检测到多个或 ECMP ${LABEL} 默认路由，已拒绝修改"
        return 1
    fi
    ROUTE_LINE=$(head -1 <<< "$ROUTES")
    ROUTE_IFACE=$(ip_route_token "$ROUTE_LINE" dev)
    [ "$ROUTE_IFACE" = "$IFACE" ] || { error "路由查询与 main 默认路由网卡不一致，已拒绝修改"; return 1; }
    while IFS= read -r ADDR; do [ -n "$ADDR" ] && ADDRESSES+=("$ADDR"); done < <(ip_source_addresses "$FAMILY" "$IFACE")
    if [ "${#ADDRESSES[@]}" -lt 2 ]; then
        error "${IFACE} 上只有 ${#ADDRESSES[@]} 个可切换的稳定 ${LABEL} 地址"
        return 1
    fi
    CURRENT=$(ip_source_current "$FAMILY" 2>/dev/null || true)

    print_header "${LABEL} 临时首选源地址"
    echo -e "  网卡：${BOLD}${IFACE}${NC}"
    echo -e "  当前路由选源：${BOLD}${CURRENT:-未知}${NC}"
    echo -e "  ${DIM}仅修改 main 表运行时默认路由；DHCP/RA 更新或重启后可能恢复。${NC}"
    echo ""; menu_div
    for ADDR in "${ADDRESSES[@]}"; do
        INDEX=$((INDEX+1))
        if [ "$ADDR" = "$CURRENT" ]; then
            printf '  %2d) %-42s %b\n' "$INDEX" "$ADDR" "${GREEN}当前${NC}"
        else
            printf '  %2d) %s\n' "$INDEX" "$ADDR"
        fi
    done
    menu_item "0" "返回上级" "$RED"
    menu_div; echo ""
    read -rp "$(ui_prompt "选择地址 [0-${#ADDRESSES[@]}]: ")" CHOICE
    [ "$CHOICE" = 0 ] && return 0
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#ADDRESSES[@]}" ] \
        || { warn "无效选项"; return 1; }
    SELECTED=${ADDRESSES[$((CHOICE-1))]}
    [ "$SELECTED" != "$CURRENT" ] || { info "该地址已经是当前首选源地址"; return 0; }
    confirm_change_preview "切换 ${LABEL} 临时首选源地址" \
        "网卡：${IFACE}" "当前：${CURRENT:-自动选择}" "切换为：${SELECTED}" \
        "保留默认路由全部属性，仅替换 src" \
        "不写入 Netplan/NetworkManager/networkd 配置" || { warn "已取消"; return 0; }
    ip_source_safety_arm "$FAMILY" "$ROUTE_LINE" || { error "无法启动路由自动回滚保护"; return 1; }
    if ! ip_source_route_replace "$FAMILY" "$ROUTE_LINE" "$SELECTED"; then
        safety_rollback_now >/dev/null 2>&1 || true
        error "默认路由源地址切换失败，已执行原路由恢复"
        return 1
    fi
    if ! ip_source_verify "$FAMILY" "$SELECTED"; then
        if ip_source_route_restore "$FAMILY" "$ROUTE_LINE" >/dev/null 2>&1; then
            cancel_safety_timer
            error "新源地址无法完成路由或 HTTPS 出口验证，已恢复原默认路由"
        else
            error "新源地址验证失败且即时恢复失败，正在执行独立回滚脚本"
            safety_rollback_now >/dev/null 2>&1 || error "独立回滚也失败，请立即通过控制台恢复默认路由"
        fi
        return 1
    fi
    PUBLIC_IP="$IP_SOURCE_PUBLIC_IP"
    info "${LABEL} 临时首选源地址已切换为 ${SELECTED} ✓"
    echo -e "  公网出口：${BOLD}${PUBLIC_IP}${NC}"
    audit_action "切换 ${LABEL} 临时首选源地址 ${IFACE} ${SELECTED}" SUCCESS
    safety_confirm
}

ip_source_switch_menu() {
    local CH
    while true; do
        print_header "高级：临时多 IP 出口选择"
        echo -e "  IPv4 当前路由选源：${BOLD}$(ip_source_current 4 2>/dev/null || echo 未检测到)${NC}"
        echo -e "  IPv6 当前路由选源：${BOLD}$(ip_source_current 6 2>/dev/null || echo 未检测到)${NC}"
        echo ""; menu_div
        menu_pair "1" "选择 IPv4 源地址" "2" "选择 IPv6 源地址"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1) ip_source_switch_family 4; ui_pause ;;
            2) ip_source_switch_family 6; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

ip_public_egress() {
    local FAMILY="$1" ENDPOINT VALUE
    command -v curl >/dev/null 2>&1 || return 1
    [ "$FAMILY" = 4 ] && ENDPOINT=https://api.ipify.org || ENDPOINT=https://api64.ipify.org
    VALUE=$(curl "-$FAMILY" -fsS --max-time 5 "$ENDPOINT" 2>/dev/null) || return 1
    VALUE=${VALUE//$'\r'/}; VALUE=${VALUE//$'\n'/}
    ip_address_valid "$FAMILY" "$VALUE" || return 1
    printf '%s\n' "$VALUE"
}

ip_show_status() {
    local FAMILY LABEL COLOR ADDRS ROUTES SOURCE PUBLIC RULE_STATE V6_STATE LINE
    print_header "IP 状态与出口诊断"
    command -v ip >/dev/null 2>&1 || { error "缺少 iproute2 的 ip 命令"; return 1; }
    for FAMILY in 4 6; do
        if [ "$FAMILY" = 4 ]; then LABEL=IPv4; COLOR="$GREEN"; else LABEL=IPv6; COLOR="$CYAN"; fi
        echo -e "  ${BOLD}${LABEL}${NC}"
        ADDRS=$(ip "-$FAMILY" -o addr show scope global 2>/dev/null | awk '{print $2 "  " $4}')
        if [ -n "$ADDRS" ]; then
            while IFS= read -r LINE; do echo -e "    ${COLOR}地址${NC}  $LINE"; done <<< "$ADDRS"
        else
            echo -e "    ${DIM}无全局地址${NC}"
        fi
        ROUTES=$(ip "-$FAMILY" route show default 2>/dev/null)
        if [ -n "$ROUTES" ]; then
            while IFS= read -r LINE; do echo -e "    ${COLOR}路由${NC}  $LINE"; done <<< "$ROUTES"
        else
            echo -e "    ${DIM}无默认路由${NC}"
        fi
        SOURCE=$(ip_source_current "$FAMILY" 2>/dev/null || true)
        [ -z "$SOURCE" ] || echo -e "    ${COLOR}选源${NC}  $SOURCE"
        if PUBLIC=$(ip_public_egress "$FAMILY" 2>/dev/null); then
            echo -e "    ${COLOR}公网${NC}  $PUBLIC"
        else
            echo -e "    ${DIM}公网出口不可验证${NC}"
        fi
        if ip_source_policy_is_simple "$FAMILY"; then RULE_STATE="标准规则"; else RULE_STATE="自定义/不可读"; fi
        echo -e "    ${DIM}策略路由：${RULE_STATE}${NC}"
        echo ""
    done
    V6_STATE=$(ip_v6_state_summary)
    echo -e "  内核 IPv6：${BOLD}${V6_STATE}${NC}"
    echo -e "  地址选择：${BOLD}$(ip_gai_policy_label)${NC}"
}

ip_config_menu() {
    local CH V6_STATUS GAI_STATUS
    while true; do
        print_header "IP 状态与出口管理"
        V6_STATUS=$(ip_v6_state_summary)
        GAI_STATUS=$(ip_gai_policy_label)
        echo -e "  内核 IPv6：${BOLD}${V6_STATUS}${NC}"
        echo -e "  地址选择：${BOLD}${GAI_STATUS}${NC}"
        echo ""; menu_div
        menu_item "1" "查看 IP 状态与公网出口"
        menu_pair "2" "双栈目标优先 IPv4" "3" "恢复系统默认地址选择"
        menu_pair "4" "高级：禁用内核 IPv6" "5" "高级：启用内核 IPv6" "$YELLOW" "$YELLOW"
        menu_item "6" "高级：临时多 IP 出口选择" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择操作 [0-6]: ')" CH
        case "$CH" in
            1) ip_show_status ;;
            2) ip_prefer_v4 ;;
            3) ip_prefer_v6 ;;
            4) ip_disable_v6 ;;
            5) ip_enable_v6 ;;
            6) ip_source_switch_menu; continue ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
