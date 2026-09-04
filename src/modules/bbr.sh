# ══════════════════════════════════════════════════════════
#  网络性能调优模块
# ══════════════════════════════════════════════════════════

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SERVICE_TC_INIT="/etc/init.d/tc-fq"
TC_HELPER="/usr/local/libexec/quench-tc-fq"
TC_STATE_FILE="/var/lib/quench/tc-fq.state"
TC_BACKUP_DIR="/var/lib/quench/tc-backups"
SERVICE_CWND="/etc/systemd/system/initcwnd.service"
SERVICE_CWND_INIT="/etc/init.d/initcwnd"
CWND_HELPER="/usr/local/libexec/quench-initcwnd"
CWND_STATE_FILE="/var/lib/quench/initcwnd.state"
SYSCTL_FILE="/etc/sysctl.d/99-quench-bbr.conf"
BBR_BASELINE_FILE="/var/lib/quench/bbr-sysctl-baseline.conf"
BBR_CALIBRATION_RESULT_FILE="/var/lib/quench/tc-calibration.state"
BBR_CALIBRATION_LOCK_FILE="/run/lock/quench-tc-calibration.lock"

bbr_default_ipv6_iface() {
    local DEV
    DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$DEV" ] || DEV=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || DEV=""
    printf '%s\n' "$DEV"
}

bbr_scene_keys() {
    local IPV6_IFACE
    IPV6_IFACE=$(bbr_default_ipv6_iface)
    printf '%s\n' \
        net.ipv4.ip_forward \
        net.ipv6.conf.all.forwarding \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.netfilter.nf_conntrack_max \
        net.netfilter.nf_conntrack_tcp_timeout_established \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_max_tw_buckets \
        net.ipv6.conf.default.accept_ra \
        fs.file-max
    [ -n "$IPV6_IFACE" ] && printf 'net.ipv6.conf.%s.accept_ra\n' "$IPV6_IFACE"
}

bbr_managed_keys() {
    printf '%s\n' \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.udp_rmem_min
    bbr_scene_keys
}

bbr_kernel_at_least() {
    local WANT_MAJOR="$1" WANT_MINOR="$2" KVER KMAJOR KMINOR
    KVER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || true)
    KMAJOR=${KVER%%.*}
    KMINOR=${KVER#*.}
    case "$KMAJOR" in ''|*[!0-9]*) return 1 ;; esac
    case "$KMINOR" in ''|*[!0-9]*) return 1 ;; esac
    [ "$KMAJOR" -gt "$WANT_MAJOR" ] \
        || { [ "$KMAJOR" -eq "$WANT_MAJOR" ] && [ "$KMINOR" -ge "$WANT_MINOR" ]; }
}

bbr_initial_or_current_value() {
    local KEY="$1" VALUE
    VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null || true)
    [ -n "$VALUE" ] || VALUE=$(sysctl -n "$KEY" 2>/dev/null || true)
    printf '%s\n' "$VALUE"
}

bbr_capacity_floor() {
    local KEY="$1" TARGET="$2" INITIAL
    INITIAL=$(bbr_initial_or_current_value "$KEY")
    case "$INITIAL" in ''|*[!0-9]*) INITIAL=0 ;; esac
    if [ "$INITIAL" -gt "$TARGET" ]; then
        printf '%s\n' "$INITIAL"
    else
        printf '%s\n' "$TARGET"
    fi
}

bbr_port_range_union() {
    local TARGET_LOW="$1" TARGET_HIGH="$2" INITIAL LOW HIGH
    INITIAL=$(bbr_initial_or_current_value net.ipv4.ip_local_port_range)
    LOW=$(printf '%s\n' "$INITIAL" | awk '{print $1}')
    HIGH=$(printf '%s\n' "$INITIAL" | awk '{print $2}')
    case "$LOW" in ''|*[!0-9]*) LOW="$TARGET_LOW" ;; esac
    case "$HIGH" in ''|*[!0-9]*) HIGH="$TARGET_HIGH" ;; esac
    [ "$LOW" -le "$TARGET_LOW" ] || LOW="$TARGET_LOW"
    [ "$HIGH" -ge "$TARGET_HIGH" ] || HIGH="$TARGET_HIGH"
    printf '%s %s\n' "$LOW" "$HIGH"
}

bbr_tcp_fastopen_value() {
    local INITIAL CURRENT
    INITIAL=$(bbr_baseline_value net.ipv4.tcp_fastopen 2>/dev/null || true)
    CURRENT=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true)
    case "$INITIAL" in ''|*[!0-9]*) INITIAL=0 ;; esac
    case "$CURRENT" in ''|*[!0-9]*) CURRENT=0 ;; esac
    printf '%s\n' $(( INITIAL | CURRENT | 3 ))
}

bbr_runtime_snapshot() {
    local DEST="$1" EXTRA_CONFIG="${2:-}" DIR TMP KEY VALUE CAPTURED=0
    DIR=$(dirname "$DEST")
    mkdir -p "$DIR" 2>/dev/null || return 1
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    {
        echo "# Quench BBR sysctl runtime snapshot"
        echo "# captured: $(date '+%Y-%m-%d %H:%M:%S')"
        while IFS= read -r KEY; do
            [ -n "$KEY" ] || continue
            if VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
                printf '%s = %s\n' "$KEY" "$VALUE"
                CAPTURED=$(( CAPTURED + 1 ))
            fi
        done < <({ bbr_managed_keys; bbr_config_keys "$EXTRA_CONFIG"; } | awk '!seen[$0]++')
    } > "$TMP"
    if [ "$CAPTURED" -eq 0 ]; then
        rm -f "$TMP"
        return 1
    fi
    chmod 600 "$TMP" 2>/dev/null || true
    mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_ensure_baseline() {
    if [ ! -s "$BBR_BASELINE_FILE" ]; then
        bbr_runtime_snapshot "$BBR_BASELINE_FILE" || {
            error "无法保存 BBR 应用前运行参数基线"
            return 1
        }
        return 0
    fi

    local TMP KEY VALUE ADDED=0
    TMP=$(mktemp "${BBR_BASELINE_FILE}.tmp.XXXXXX") || return 1
    cp "$BBR_BASELINE_FILE" "$TMP" || { rm -f "$TMP"; return 1; }
    while IFS= read -r KEY; do
        [ -n "$KEY" ] || continue
        if ! bbr_baseline_value "$KEY" >/dev/null 2>&1 && VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
            printf '%s = %s\n' "$KEY" "$VALUE" >> "$TMP"
            ADDED=$(( ADDED + 1 ))
        fi
    done < <(bbr_managed_keys)
    if [ "$ADDED" -eq 0 ]; then
        rm -f "$TMP"
        return 0
    fi
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 600 "$TMP" && mv "$TMP" "$BBR_BASELINE_FILE" || {
        rm -f "$TMP"
        error "无法保存 BBR 应用前运行参数基线"
        return 1
    }
}

bbr_baseline_value() {
    local KEY="$1"
    [ -f "$BBR_BASELINE_FILE" ] || return 1
    awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$BBR_BASELINE_FILE"
}

bbr_restore_baseline_key() {
    local KEY="$1" VALUE
    VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null || true)
    [ -n "$VALUE" ] || { warn "基线中没有 ${KEY}，保持当前运行值"; return 1; }
    sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || {
        warn "无法恢复基线参数：${KEY}"
        return 1
    }
}

bbr_restore_runtime_snapshot() {
    local SNAPSHOT="$1" RESPECT_NFT="${2:-no}" KEY VALUE FAILED=0 NFT_SKIPPED=0
    [ -f "$SNAPSHOT" ] || return 1
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        VALUE=$(printf '%s' "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$KEY" in ""|\#*) continue ;; esac
        if [ "$RESPECT_NFT" = respect_nft ] && bbr_scene_key_owned_by_nft "$KEY"; then
            NFT_SKIPPED=1
            continue
        fi
        sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || FAILED=1
    done < "$SNAPSHOT"
    [ "$NFT_SKIPPED" -eq 0 ] \
        || warn "线路转发仍在使用 forwarding/IPv6 RA；恢复 BBR 基线时已保留这些参数"
    return "$FAILED"
}

bbr_config_has_key() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs == key) found=1
        }
        END { exit !found }
    '
}

bbr_config_value() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    '
}

bbr_config_keys() {
    printf '%s\n' "$1" | awk -F= '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs ~ /^[[:alnum:]_.-]+$/) print lhs
        }
    '
}

bbr_config_dynamic_scene_keys() {
    bbr_config_keys "$1" | awk '/^net\.ipv6\.conf\..+\.accept_ra$/ { print }'
}

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV TC_BIN RATE
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    RATE="未设置"
    [ -z "$TC_BIN" ] || RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND
    CWND=$(ip -4 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    [ -n "$CWND" ] || CWND=$(ip -6 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    [ -z "$CWND" ] && CWND="10（默认）"

    # 读取缓冲区大小
    local RMEM_MAX WMEM_MAX RMEM_MB WMEM_MB
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    RMEM_MB=$(( RMEM_MAX / 1048576 ))
    WMEM_MB=$(( WMEM_MAX / 1048576 ))

    # tcp_rmem / tcp_wmem 的 max 字段
    local TCP_RMEM_MAX TCP_WMEM_MAX TCP_RMEM_MB TCP_WMEM_MB
    TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    TCP_RMEM_MB=$(( ${TCP_RMEM_MAX:-0} / 1048576 ))
    TCP_WMEM_MB=$(( ${TCP_WMEM_MAX:-0} / 1048576 ))

    echo -e "  ${CYAN}网卡${NC} ${BOLD}$DEV${NC}  ${CYAN}CC${NC} ${BOLD}$BBR${NC}  ${CYAN}cwnd${NC} ${BOLD}$CWND${NC}  ${CYAN}限速${NC} ${BOLD}$RATE${NC}"
    # 检测缓冲区是否超过物理内存四分之一（显示警告）
    local MEM_TOTAL_MB
    MEM_TOTAL_MB=$(bbr_physical_memory_mb)
    local RMEM_COLOR WMEM_COLOR
    RMEM_COLOR="$BOLD"
    WMEM_COLOR="$BOLD"
    if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
        [ "$RMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && RMEM_COLOR="${YELLOW}${BOLD}"
        [ "$WMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && WMEM_COLOR="${YELLOW}${BOLD}"
    fi
    echo -e "  ${CYAN}缓冲${NC} rmem ${RMEM_COLOR}${RMEM_MB}MB${NC}  wmem ${WMEM_COLOR}${WMEM_MB}MB${NC}  tcp_r ${BOLD}${TCP_RMEM_MB}MB${NC}  tcp_w ${BOLD}${TCP_WMEM_MB}MB${NC}  ${DIM}物理内存 ${MEM_TOTAL_MB}MB${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    local BAK CURRENT_CONFIG=""
    BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    [ -e "$BAK" ] && BAK="${BAK}.$$"
    [ ! -f "$SYSCTL_FILE" ] || CURRENT_CONFIG=$(cat "$SYSCTL_FILE")
    if bbr_runtime_snapshot "$BAK" "$CURRENT_CONFIG"; then
        info "已备份当前运行参数至：$BAK"
    else
        error "BBR 运行参数备份失败"
        return 1
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 TCP sysctl 配置"

    local LIST_FILE
    LIST_FILE=$(quench_mktemp "${TMPDIR:-/tmp}/quench_bbr_backup.XXXXXX") || { error "无法创建备份列表"; return 1; }
    ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null > "$LIST_FILE"

    if [ ! -s "$LIST_FILE" ]; then
        rm -f "$LIST_FILE"
        warn "未找到任何备份文件"
        return
    fi

    local i=1
    while IFS= read -r f; do
        # stat 兼容：BusyBox stat 用 -c '%y'，但格式有差异，改用 ls -l 更通用
        local FDATE
        # shellcheck disable=SC2012 # 同上：这里要的正是 ls -l 的列，且文件名由本脚本生成
        FDATE=$(ls -l "$f" 2>/dev/null | awk '{print $6, $7}')
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}${FDATE}${NC}"
        i=$(( i + 1 ))
    done < "$LIST_FILE"

    local TOTAL=$(( i - 1 ))
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "$(ui_prompt '选择备份编号: ')" CH

    case "$CH" in
        0) rm -f "$LIST_FILE"; return ;;
        00) rm -f "$LIST_FILE"; safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${TOTAL} 个备份？(Y/n，默认Y): " C
            [ -z "$C" ] && C="y"
            if echo "$C" | grep -qiE '^y(es)?$'; then
                rm -f "${SYSCTL_FILE}.bak."*
                info "已清除全部备份 ✓"
            else
                warn "已取消"
            fi
            ;;
        *)
            # 纯数字且在范围内
            if echo "$CH" | grep -qE '^[0-9]+$' && [ "$CH" -ge 1 ] && [ "$CH" -le "$TOTAL" ]; then
                local T CONFIG
                T=$(sed -n "${CH}p" "$LIST_FILE")
                CONFIG=$(cat "$T")
                if bbr_apply_sysctl "$CONFIG" baseline; then
                    info "已还原运行参数：$(basename "$T") ✓"
                else
                    error "还原未完全成功，请查看上方失败参数"
                fi
            else
                error "无效选项"
            fi
            ;;
    esac
    rm -f "$LIST_FILE"
}

bbr_restore_initial_baseline() {
    print_header "恢复首次调优前状态"
    [ -s "$BBR_BASELINE_FILE" ] || {
        warn "未找到首次调优前基线：${BBR_BASELINE_FILE}"
        return 1
    }

    echo -e "  将恢复首次运行本模块前保存的 sysctl，并移除本工具的持久化配置。"
    echo -e "  ${YELLOW}注意：这会覆盖其他工具后来对同名 sysctl 的修改。${NC}"
    local ANSWER FAILED=0
    read -rp "  确认继续？(y/N，默认N): " ANSWER
    [ -n "$ANSWER" ] || ANSWER=n
    echo "$ANSWER" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }

    bbr_backup_sysctl || {
        error "无法保存当前运行快照，已取消恢复"
        return 1
    }
    if bbr_restore_runtime_snapshot "$BBR_BASELINE_FILE" respect_nft; then
        rm -f "$SYSCTL_FILE"
        info "sysctl 已恢复到首次调优前基线"
    else
        error "部分 sysctl 无法恢复；已保留基线文件供重试"
        FAILED=1
    fi

    if [ -s "$TC_STATE_FILE" ] || [ -e "$TC_HELPER" ] || [ -e "$SERVICE_TC" ] || [ -e "$SERVICE_TC_INIT" ]; then
        read -rp "  同时取消本工具的 tc 出口整形？(Y/n，默认Y): " ANSWER
        [ -n "$ANSWER" ] || ANSWER=y
        echo "$ANSWER" | grep -qiE '^y(es)?$' && bbr_remove_tc || true
    fi
    if [ -s "$CWND_STATE_FILE" ] || [ -e "$CWND_HELPER" ] || [ -e "$SERVICE_CWND" ] || [ -e "$SERVICE_CWND_INIT" ]; then
        read -rp "  同时恢复 initcwnd/initrwnd 内核默认？(Y/n，默认Y): " ANSWER
        [ -n "$ANSWER" ] || ANSWER=y
        echo "$ANSWER" | grep -qiE '^y(es)?$' && bbr_remove_initcwnd || true
    fi

    if [ "$FAILED" -eq 0 ]; then
        rm -f "$BBR_BASELINE_FILE"
        info "首次基线恢复完成；下次调优会重新采集基线 ✓"
    fi
    return "$FAILED"
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1" STALE_MODE="${2:-ask}" TX_SNAPSHOT SNAPSHOT_CONFIG="$1"
    ensure_sysctl || return 1
    bbr_ensure_baseline || return 1
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || return 1
    TX_SNAPSHOT=$(quench_mktemp "${TMPDIR:-/tmp}/quench-bbr-transaction.XXXXXX") || {
        error "无法创建 BBR 回滚快照"
        return 1
    }
    [ ! -f "$SYSCTL_FILE" ] || SNAPSHOT_CONFIG="${SNAPSHOT_CONFIG}"$'\n'"$(cat "$SYSCTL_FILE")"
    if ! bbr_runtime_snapshot "$TX_SNAPSHOT" "$SNAPSHOT_CONFIG"; then
        rm -f "$TX_SNAPSHOT"
        error "无法保存 BBR 应用前快照"
        return 1
    fi

    # ── 切换预设时复位「当前配置写过、但新配置不再包含」的场景专有键 ──
    # 否则从中转/落地降级回普通预设后，ip_forward / conntrack 等会一直残留在内核里。
    # 仅复位本脚本场景预设管理的键，且新配置确实不含该键时才动；ip_forward 谨慎处理。
    if [ -f "$SYSCTL_FILE" ]; then
        local SCENE_KEYS
        SCENE_KEYS=$({ bbr_scene_keys; bbr_config_dynamic_scene_keys "$(cat "$SYSCTL_FILE")"; } | awk '!seen[$0]++')
        local k STALE=""
        for k in $SCENE_KEYS; do
            # 当前文件里有该键，但新配置里没有 → 视为需要清理的残留
            if bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$k" && ! bbr_config_has_key "$CONFIG" "$k"; then
                STALE="$STALE $k"
            fi
        done
        if [ -n "$STALE" ]; then
            local FILTERED_STALE="" NFT_OWNED=0
            for k in $STALE; do
                if bbr_scene_key_owned_by_nft "$k"; then
                    NFT_OWNED=1
                    continue
                fi
                FILTERED_STALE="$FILTERED_STALE $k"
            done
            STALE="$FILTERED_STALE"
            [ "$NFT_OWNED" -eq 0 ] \
                || warn "Quench 线路转发正在使用 forwarding/IPv6 RA，相关参数由转发模块继续管理"
        fi
        if [ -n "$STALE" ]; then
            warn "检测到上次场景预设遗留参数，新预设不再需要："
            for k in $STALE; do echo -e "    ${DIM}${k}${NC}"; done
            # ip_forward 如被关闭可能影响 NFT/iptables 转发，单独警告
            if echo "$STALE" | grep -q 'ip_forward'; then
                warn "其中 ip_forward 复位后将关闭内核转发，若本机仍在做端口转发/中转请勿复位"
            fi
            local DORST="n"
            if [ "$STALE_MODE" = baseline ]; then
                DORST="y"
            else
                read -rp "  是否恢复这些残留参数到首次调优前基线？(y/N，默认N): " DORST
                [ -z "$DORST" ] && DORST="n"
            fi
            if echo "$DORST" | grep -qiE '^y(es)?$'; then
                local RESTORE_FAILED=0
                for k in $STALE; do
                    bbr_restore_baseline_key "$k" || RESTORE_FAILED=1
                done
                if [ "$RESTORE_FAILED" -eq 0 ]; then
                    info "残留场景参数已恢复到首次调优前基线"
                else
                    warn "部分残留参数缺少基线或恢复失败，已保持原值"
                fi
            else
                warn "保留残留参数（仍生效于当前内核）"
            fi
        fi
    fi

    # 逐行应用并生成持久化文件；不支持的参数写成注释，避免重启时 sysctl 报错。
    local SKIPPED=0 CORE_FAILED=0 QDISC_FAILED=0 TMP_FILE
    TMP_FILE=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX") || {
        rm -f "$TX_SNAPSHOT"
        error "无法创建 sysctl 临时配置"
        return 1
    }
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^[[:space:]]*#|^[[:space:]]*$'; then
            echo "$line" >> "$TMP_FILE"
            continue
        fi
        local KEY VAL
        KEY=$(printf '%s' "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        VAL=$(printf '%s' "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if sysctl -w "${KEY}=${VAL}" > /dev/null 2>&1; then
            echo "$line" >> "$TMP_FILE"
        else
            warn "跳过不支持的参数：${KEY}"
            echo "# skipped unsupported: $line" >> "$TMP_FILE"
            SKIPPED=$(( SKIPPED + 1 ))
            case "$KEY" in
                net.ipv4.tcp_congestion_control) CORE_FAILED=1 ;;
                net.core.default_qdisc) QDISC_FAILED=1 ;;
            esac
        fi
    done <<< "$CONFIG"

    if [ "$CORE_FAILED" -eq 0 ]; then
        local EXPECTED_CC EXPECTED_QDISC ACTIVE_CC ACTIVE_QDISC
        EXPECTED_CC=$(bbr_config_value "$CONFIG" net.ipv4.tcp_congestion_control 2>/dev/null || true)
        EXPECTED_QDISC=$(bbr_config_value "$CONFIG" net.core.default_qdisc 2>/dev/null || true)
        if [ -n "$EXPECTED_CC" ]; then
            ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
            [ "$ACTIVE_CC" = "$EXPECTED_CC" ] || CORE_FAILED=1
        fi
        if [ -n "$EXPECTED_QDISC" ]; then
            ACTIVE_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
            [ "$ACTIVE_QDISC" = "$EXPECTED_QDISC" ] || QDISC_FAILED=1
        fi
        if [ "$CORE_FAILED" -ne 0 ]; then
            error "BBR 拥塞控制写入后回读不一致：cc=${ACTIVE_CC:-未校验}/${EXPECTED_CC:-未设置}"
        fi
    fi

    if [ "$QDISC_FAILED" -ne 0 ]; then
        if bbr_kernel_at_least 4 20; then
            warn "fq 默认队列未能启用；Linux 4.20+ 的 BBR 仍有内部 pacing，将继续应用其余参数"
        else
            CORE_FAILED=1
            error "当前内核低于 4.20，fq 默认队列未能启用，无法安全启用 BBR pacing"
        fi
    fi

    if [ "$CORE_FAILED" -eq 1 ]; then
        rm -f "$TMP_FILE"
        bbr_restore_runtime_snapshot "$TX_SNAPSHOT" || warn "部分运行参数自动回滚失败"
        rm -f "$TX_SNAPSHOT"
        error "BBR 核心参数未能安全启用，已回滚本次参数修改"
        return 1
    fi
    if ! mv "$TMP_FILE" "$SYSCTL_FILE"; then
        rm -f "$TMP_FILE"
        bbr_restore_runtime_snapshot "$TX_SNAPSHOT" || warn "部分运行参数自动回滚失败"
        rm -f "$TX_SNAPSHOT"
        error "无法更新 ${SYSCTL_FILE}，已回滚本次参数修改"
        return 1
    fi
    rm -f "$TX_SNAPSHOT"

    if [ "$SKIPPED" -gt 0 ]; then
        warn "共跳过 ${SKIPPED} 个不支持的参数（已在配置文件中注释，重启后不报错）"
    fi
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
    info "sysctl 配置已应用到 ${SYSCTL_FILE} ✓"
    return 0
}

bbr_nft_forwarding_family_active() {
    local family="$1" rules="${NFT_RULES_FILE:-/etc/quench/nft-forward/rules.db}"
    [ -s "$rules" ] || return 1
    awk -F'|' -v family="$family" \
        '$1 ~ /^[0-9]+$/ && $2 == family && $15 == "yes" {found=1} END {exit !found}' "$rules"
}

bbr_scene_key_owned_by_nft() {
    local key="$1"
    case "$key" in
        net.ipv4.ip_forward)
            bbr_nft_forwarding_family_active ipv4
            ;;
        net.ipv6.conf.all.forwarding|net.ipv6.conf.default.accept_ra|net.ipv6.conf.*.accept_ra)
            bbr_nft_forwarding_family_active ipv6
            ;;
        *) return 1 ;;
    esac
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_tc_qdisc_type() {
    awk 'NR==1 { print $2 }' <<< "$1"
}

bbr_tc_qdisc_handle() {
    awk 'NR==1 { print $3 }' <<< "$1"
}

bbr_tc_root_line() {
    awk '
        $1 == "qdisc" {
            for (i = 4; i <= NF; i++) {
                if ($i == "root") { print; exit }
            }
        }
    ' <<< "$1"
}

bbr_tc_qdisc_safe_to_replace() {
    case "$1" in
        ""|mq|fq|fq_codel|noqueue|pfifo_fast) return 0 ;;
        *) return 1 ;;
    esac
}

bbr_tc_current_rate() {
    local DEV="$1" TC_BIN="$2" RATE
    RATE=$("$TC_BIN" class show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'maxrate [^ ]+' | head -1 | awk '{print $2}')
    printf '%s\n' "$RATE"
}

bbr_tc_owned_rate() {
    local DEV="$1" TC_BIN="$2" RATE QDISCS CLASSES
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    RATE=$(printf '%s\n' "$CLASSES" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" {
            for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit }
        }
    ')
    if [ -z "$RATE" ]; then
        QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
        RATE=$(printf '%s\n' "$QDISCS" | awk '
            $1 == "qdisc" && $2 == "fq" && $3 == "100:" {
                for (i = 1; i < NF; i++) if ($i == "maxrate") { print $(i + 1); exit }
            }
        ')
    fi
    printf '%s\n' "$RATE"
}

bbr_tc_rate_token_mbps() {
    local RAW
    RAW=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    awk -v raw="$RAW" 'BEGIN {
        if (raw !~ /^[0-9]+([.][0-9]+)?(kbit|mbit|gbit|tbit|bit)$/) exit 1
        value = raw
        sub(/(kbit|mbit|gbit|tbit|bit)$/, "", value)
        unit = raw
        sub(/^[0-9]+([.][0-9]+)?/, "", unit)
        multiplier = 1
        if (unit == "bit") multiplier = 0.000001
        else if (unit == "kbit") multiplier = 0.001
        else if (unit == "gbit") multiplier = 1000
        else if (unit == "tbit") multiplier = 1000000
        printf "%.6f\n", value * multiplier
    }'
}

bbr_tc_rate_mbps_from_output() {
    local OUTPUT="$1" TOKEN
    TOKEN=$(printf '%s\n' "$OUTPUT" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" {
            for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit }
        }
    ')
    [ -n "$TOKEN" ] || return 1
    bbr_tc_rate_token_mbps "$TOKEN"
}

bbr_tc_rate_matches() {
    local DEV="$1" TC_BIN="$2" EXPECTED="$3" OUTPUT ACTUAL
    OUTPUT=$("$TC_BIN" class show dev "$DEV" 2>/dev/null) || return 1
    ACTUAL=$(bbr_tc_rate_mbps_from_output "$OUTPUT") || return 1
    awk -v actual="$ACTUAL" -v expected="$EXPECTED" 'BEGIN {
        tolerance = expected * 0.01
        if (tolerance < 1) tolerance = 1
        delta = actual - expected
        if (delta < 0) delta = -delta
        exit !(delta <= tolerance)
    }'
}

bbr_tc_burst_kb() {
    local RATE="$1"
    case "$RATE" in ''|*[!0-9]*) return 1 ;; esac
    [ "$RATE" -gt 0 ] || return 1
    # 约 4ms 线速数据量；tc 的 kb 单位向上取整，低速保留 32KB 下限。
    local BURST_KB=$(( (RATE * 500 + 1023) / 1024 ))
    [ "$BURST_KB" -ge 32 ] || BURST_KB=32
    printf '%s\n' "$BURST_KB"
}

bbr_tc_saved_values() {
    local DEV RATE BURST_KB FORCE
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    RATE=$(bbr_state_value "$TC_STATE_FILE" RATE 2>/dev/null || true)
    BURST_KB=$(bbr_state_value "$TC_STATE_FILE" BURST_KB 2>/dev/null || true)
    FORCE=$(bbr_state_value "$TC_STATE_FILE" FORCE 2>/dev/null || true)
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    echo "$RATE" | grep -qE '^[0-9]+$' || return 1
    echo "$BURST_KB" | grep -qE '^[0-9]+$' || return 1
    [ "$RATE" -gt 0 ] && [ "$BURST_KB" -gt 0 ] || return 1
    case "$FORCE" in 0|1) : ;; *) FORCE=0 ;; esac
    printf '%s %s %s %s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE"
}

bbr_tc_saved_rate_display() {
    local CURRENT_DEV="$1" SAVED_VALUES SAVED_DEV SAVED_RATE
    SAVED_VALUES=$(bbr_tc_saved_values) || return 1
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_RATE=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_RATE%% *}
    if [ "$SAVED_DEV" = "$CURRENT_DEV" ]; then
        printf '%sMbit（已保存，未生效）\n' "$SAVED_RATE"
    else
        printf '%sMbit（保存于 %s，当前未生效）\n' "$SAVED_RATE" "$SAVED_DEV"
    fi
}

bbr_tc_rate_display() {
    local DEV="$1" TC_BIN="$2" RATE QDISCS LINE TYPE SAVED_RATE
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        RATE=$(bbr_tc_owned_rate "$DEV" "$TC_BIN")
        if [ -n "$RATE" ]; then
            printf '%s\n' "$RATE"
        else
            SAVED_RATE=$(bbr_tc_saved_rate_display "$DEV" 2>/dev/null || true)
            if [ -n "$SAVED_RATE" ]; then
                SAVED_RATE=${SAVED_RATE%%（*}
                printf '%s（已生效，速率读取异常）\n' "$SAVED_RATE"
            else
                printf '已生效（速率读取异常）\n'
            fi
        fi
        return
    fi
    RATE=$(bbr_tc_current_rate "$DEV" "$TC_BIN")
    if [ -z "$RATE" ]; then
        SAVED_RATE=$(bbr_tc_saved_rate_display "$DEV" 2>/dev/null || true)
        [ -z "$SAVED_RATE" ] && echo "未设置" || echo "$SAVED_RATE"
        return
    fi
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if ! bbr_tc_is_owned "$DEV" "$TC_BIN" \
        && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        printf '%s（外部 %s）\n' "$RATE" "${TYPE:-未知}"
    else
        printf '%s\n' "$RATE"
    fi
}

bbr_tc_snapshot_foreign() {
    local DEV="$1" TC_BIN="$2" TMP SNAPSHOT STAMP
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    mkdir -p "$TC_BACKUP_DIR" 2>/dev/null || return 1
    chmod 700 "$TC_BACKUP_DIR" 2>/dev/null || true
    STAMP=$(date '+%Y%m%d_%H%M%S')
    SNAPSHOT="$TC_BACKUP_DIR/${DEV}_${STAMP}_$$.txt"
    TMP="${SNAPSHOT}.tmp"
    {
        printf 'Quench foreign tc snapshot\n'
        printf 'Captured: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'Device: %s\n\n' "$DEV"
        printf '[qdisc]\n'
        "$TC_BIN" qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class]\n'
        "$TC_BIN" class show dev "$DEV" 2>&1 || true
        printf '\n[filter]\n'
        "$TC_BIN" filter show dev "$DEV" 2>&1 || true
        printf '\n[qdisc-json]\n'
        "$TC_BIN" -j qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class-json]\n'
        "$TC_BIN" -j class show dev "$DEV" 2>&1 || true
        printf '\n[filter-json]\n'
        "$TC_BIN" -j filter show dev "$DEV" 2>&1 || true
    } > "$TMP" || { rm -f "$TMP"; return 1; }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 600 "$TMP" && mv "$TMP" "$SNAPSHOT" || { rm -f "$TMP"; return 1; }
    printf '%s\n' "$SNAPSHOT"
}

bbr_tc_force_confirm() {
    local DEV="$1" RATE="$2" TC_BIN="$3" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "强制接管会删除 ${DEV} 的全部 root qdisc、子 class 和 filter"
    warn "现有 QoS 无法通用自动恢复；重启后本工具仍会覆盖外部 qdisc"
    echo -e "  ${DIM}目标限速：${RATE} Mbps${NC}"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 FORCE ${DEV} 确认强制覆盖: " CONFIRM
    if [ "$CONFIRM" != "FORCE ${DEV}" ]; then
        warn "确认词不匹配，已取消强制覆盖"
        return 1
    fi
    return 0
}

bbr_tc_remove_confirm() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "检测到 ${DEV} 仍有非本工具管理的 root qdisc"
    warn "删除会清除该 root qdisc 的全部子 class 和 filter；clsact 不受影响"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 DELETE ${DEV} 确认删除外部限速: " CONFIRM
    if [ "$CONFIRM" != "DELETE ${DEV}" ]; then
        warn "确认词不匹配，外部 qdisc 已保留"
        return 1
    fi
    return 0
}

bbr_state_value() {
    local FILE="$1" KEY="$2"
    [ -f "$FILE" ] || return 1
    awk -F= -v key="$KEY" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$FILE"
}

bbr_tc_topology_matches() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null) || return 1
    printf '%s\n' "$QDISCS" | awk '
        $1 == "qdisc" && $2 == "htb" && $3 == "1:" {
            for (i = 4; i <= NF; i++) if ($i == "root") root = 1
        }
        $1 == "qdisc" && $2 == "fq" && $3 == "100:" {
            for (i = 4; i < NF; i++) if ($i == "parent" && $(i + 1) == "1:10") leaf = 1
        }
        END { exit !(root && leaf) }
    ' || return 1
    printf '%s\n' "$CLASSES" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" { found = 1 }
        END { exit !found }
    '
}

bbr_tc_is_owned() {
    local DEV="$1" TC_BIN="$2" STATE_DEV
    STATE_DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ "$STATE_DEV" = "$DEV" ] || return 1
    bbr_tc_topology_matches "$DEV" "$TC_BIN"
}

bbr_tc_restore_owned() {
    if [ -x "$TC_HELPER" ] && "$TC_HELPER" apply >/dev/null 2>&1; then
        return 0
    fi
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        systemctl restart tc-fq >/dev/null 2>&1 && return 0
    elif command -v rc-service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        rc-service tc-fq restart >/dev/null 2>&1 && return 0
    elif command -v service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        service tc-fq restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

bbr_tc_persistence_current() {
    [ -x "$TC_HELPER" ] \
        && grep -qxF '# QUENCH_TC_HELPER_VERSION=3' "$TC_HELPER" 2>/dev/null
}

bbr_tc_reconcile_saved() {
    local CURRENT_DEV SAVED_VALUES SAVED_REST SAVED_DEV SAVED_RATE SAVED_BURST SAVED_FORCE TC_BIN
    [ "${QUENCH_TEST_MODE:-0}" != 1 ] || return 2
    [ "${BBR_TUNE_TEST_MODE:-0}" != 1 ] || return 2
    SAVED_VALUES=$(bbr_tc_saved_values) || return 2
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_REST=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_REST%% *}
    SAVED_REST=${SAVED_REST#* }
    SAVED_BURST=${SAVED_REST%% *}
    SAVED_FORCE=${SAVED_REST##* }
    CURRENT_DEV=$(default_iface)
    if [ "$SAVED_DEV" != "$CURRENT_DEV" ]; then
        warn "已保存 ${SAVED_DEV} 的 ${SAVED_RATE}Mbps 限速，但当前默认网卡为 ${CURRENT_DEV:-未知}，未自动迁移"
        return 1
    fi
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { warn "已保存 ${SAVED_RATE}Mbps 限速，但 tc 命令不可用"; return 1; }
    if bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN" \
        && bbr_tc_rate_matches "$SAVED_DEV" "$TC_BIN" "$SAVED_RATE"; then
        bbr_tc_persistence_current && return 0
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN" \
            && bbr_tc_rate_matches "$SAVED_DEV" "$TC_BIN" "$SAVED_RATE"; then
            info "tc 持久化配置已刷新 ✓"
            return 0
        fi
        warn "tc 限速当前有效，但持久化配置刷新失败"
        return 1
    fi
    if bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
        warn "tc 拓扑存在，但实际 HTB 速率与已保存的 ${SAVED_RATE}Mbps 不一致，正在修复"
    fi
    if bbr_tc_persistence_current \
        && bbr_tc_restore_owned \
        && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN" \
        && bbr_tc_rate_matches "$SAVED_DEV" "$TC_BIN" "$SAVED_RATE"; then
        info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复 ✓"
        return 0
    fi
    if bbr_tc_apply_runtime "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$TC_BIN" "$SAVED_FORCE"; then
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN" \
            && bbr_tc_rate_matches "$SAVED_DEV" "$TC_BIN" "$SAVED_RATE"; then
            info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复并刷新持久化配置 ✓"
            return 0
        fi
        warn "tc 限速已恢复运行，但持久化配置更新失败"
        return 1
    fi
    warn "已保存 ${SAVED_RATE}Mbps 限速，但自动恢复失败"
    echo -e "  ${DIM}可检查：${TC_HELPER} apply && tc -s qdisc show dev ${SAVED_DEV}${NC}"
    return 1
}

bbr_tc_apply_runtime() {
    local DEV="$1" RATE="$2" BURST_KB="$3" TC_BIN="$4" FORCE="${5:-0}"
    local QDISCS LINE TYPE WAS_OWNED=0 FORCED_FOREIGN=0 SNAPSHOT="" ROOT_ACTION=add
    if ! QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null); then
        error "无法读取 ${DEV} 的当前 tc 配置，已拒绝修改"
        return 1
    fi
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        WAS_OWNED=1
    fi
    if [ "$WAS_OWNED" -eq 0 ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        if [ "$FORCE" != 1 ]; then
            error "检测到非本工具管理的 root qdisc：${TYPE:-未知}，需要强制确认"
            echo -e "  ${DIM}默认不会覆盖；确认后可由本工具强制接管${NC}"
            return 2
        fi
        SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || {
            error "无法保存现有 tc 诊断快照，已拒绝强制覆盖"
            return 1
        }
        FORCED_FOREIGN=1
        warn "已保存现有 tc 诊断快照：${SNAPSHOT}"
    fi

    if [ -n "$LINE" ]; then
        if [ "$WAS_OWNED" -eq 0 ] && [ "$FORCED_FOREIGN" -eq 0 ]; then
            # mq/noqueue 等内核默认 qdisc 不能可靠 del，replace 可原子接管 root。
            ROOT_ACTION=replace
        elif ! "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null; then
            error "无法删除 ${DEV} 的现有 root qdisc"
            return 1
        fi
    fi

    if ! "$TC_BIN" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 2>/dev/null; then
        error "无法在 ${DEV} 安装 HTB root qdisc（内核可能缺 sch_htb 模块）"
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "原 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    if ! "$TC_BIN" class add dev "$DEV" parent 1: classid 1:10 htb \
                rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        || ! "$TC_BIN" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null; then
        error "tc 规则应用失败（内核可能缺 sch_htb / sch_fq 模块）"
        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || true
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "原 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    [ "$FORCED_FOREIGN" -eq 0 ] || warn "已强制接管 ${DEV} 的 root qdisc"
    return 0
}

bbr_tc_write_persistence() {
    local DEV="$1" RATE="$2" BURST_KB="$3" FORCE="${4:-0}" TMP
    mkdir -p "$(dirname "$TC_HELPER")" "$(dirname "$TC_STATE_FILE")" 2>/dev/null || {
        error "无法创建 tc 持久化目录"
        return 1
    }
    TMP=$(mktemp "${TC_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'DEV=%s\nRATE=%s\nBURST_KB=%s\nFORCE=%s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 600 "$TMP" && mv "$TMP" "$TC_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${TC_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'TC_HELPER_EOF'
#!/bin/sh
# QUENCH_TC_HELPER_VERSION=3
STATE=/var/lib/quench/tc-fq.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
DEV=$(state_value DEV)
RATE=$(state_value RATE)
BURST_KB=$(state_value BURST_KB)
FORCE=$(state_value FORCE)
[ "$FORCE" = 1 ] || FORCE=0
TC=$(command -v tc 2>/dev/null || echo /sbin/tc)
[ -n "$DEV" ] && echo "$RATE" | grep -qE '^[0-9]+$' && echo "$BURST_KB" | grep -qE '^[0-9]+$' || exit 1
QDISCS=$("$TC" qdisc show dev "$DEV" 2>/dev/null)
CLASSES=$("$TC" class show dev "$DEV" 2>/dev/null)
LINE=$(printf '%s\n' "$QDISCS" | awk '$1 == "qdisc" { for (i=4; i<=NF; i++) if ($i == "root") { print; exit } }')
TYPE=$(printf '%s\n' "$LINE" | awk 'NR==1 { print $2 }')
OWNED=0
if printf '%s\n' "$QDISCS" | awk '
    $1 == "qdisc" && $2 == "htb" && $3 == "1:" { for (i=4; i<=NF; i++) if ($i == "root") root=1 }
    $1 == "qdisc" && $2 == "fq" && $3 == "100:" { for (i=4; i<NF; i++) if ($i == "parent" && $(i+1) == "1:10") leaf=1 }
    END { exit !(root && leaf) }
' && printf '%s\n' "$CLASSES" | awk '$1 == "class" && $2 == "htb" && $3 == "1:10" { found=1 } END { exit !found }'; then
    OWNED=1
fi
if [ "${1:-apply}" = remove ]; then
    [ "$OWNED" -eq 0 ] || "$TC" qdisc del dev "$DEV" root
    exit $?
fi
if [ "${1:-apply}" = status ]; then
    [ "$OWNED" -eq 1 ]
    exit $?
fi
ROOT_ACTION=add
case "$TYPE" in
    ""|mq|fq|fq_codel|noqueue|pfifo_fast) ROOT_ACTION=replace ;;
    htb) [ "$OWNED" -eq 1 ] || [ "$FORCE" -eq 1 ] || exit 1 ;;
    *) [ "$FORCE" -eq 1 ] || exit 1 ;;
esac
if [ "$OWNED" -eq 1 ] || { [ -n "$LINE" ] && [ "$ROOT_ACTION" != replace ]; }; then
    "$TC" qdisc del dev "$DEV" root 2>/dev/null || exit 1
fi
"$TC" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 && \
"$TC" class add dev "$DEV" parent 1: classid 1:10 htb rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" && \
"$TC" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" || exit 1
TOKEN=$("$TC" class show dev "$DEV" 2>/dev/null | awk '
    $1 == "class" && $2 == "htb" && $3 == "1:10" {
        for (i=1; i<NF; i++) if ($i == "rate") { print $(i+1); exit }
    }
')
ACTUAL=$(awk -v raw="$TOKEN" 'BEGIN {
    raw=tolower(raw)
    if (raw !~ /^[0-9]+([.][0-9]+)?(kbit|mbit|gbit|tbit|bit)$/) exit 1
    value=raw; sub(/(kbit|mbit|gbit|tbit|bit)$/, "", value)
    unit=raw; sub(/^[0-9]+([.][0-9]+)?/, "", unit)
    multiplier=1
    if (unit == "bit") multiplier=0.000001
    else if (unit == "kbit") multiplier=0.001
    else if (unit == "gbit") multiplier=1000
    else if (unit == "tbit") multiplier=1000000
    printf "%.6f", value*multiplier
}') || exit 1
awk -v actual="$ACTUAL" -v expected="$RATE" 'BEGIN {
    tolerance=expected*0.01; if (tolerance<1) tolerance=1
    delta=actual-expected; if (delta<0) delta=-delta
    exit !(delta<=tolerance)
}'
TC_HELPER_EOF
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 700 "$TMP" && mv "$TMP" "$TC_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_TC}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=Quench TC egress shaping
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${TC_HELPER} apply
ExecStop=${TC_HELPER} remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_TC" || { rm -f "$TMP"; return 1; }
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable tc-fq --quiet >/dev/null 2>&1 \
            && systemctl restart tc-fq >/dev/null 2>&1 || {
                error "tc 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" openrc || return 1
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        rc-update add tc-fq default >/dev/null 2>&1 \
            && rc-service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" sysv || return 1
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        update-rc.d tc-fq defaults >/dev/null 2>&1 \
            && service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "tc 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_write_init_script() {
    local DEST="$1" HELPER="$2" MODE="$3" TMP
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    if [ "$MODE" = openrc ]; then
        cat > "$TMP" << EOF
#!/sbin/openrc-run
description="Quench network tuning"
depend() { need net; }
start() { ebegin "Applying Quench network tuning"; ${HELPER} apply; eend \$?; }
stop() { ebegin "Stopping Quench network tuning"; ${HELPER} remove; eend \$?; }
status() { ${HELPER} status; }
EOF
    else
        cat > "$TMP" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $(basename "$DEST")
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Quench network tuning
### END INIT INFO
case "\${1:-start}" in
    start|restart) ${HELPER} apply ;;
    stop) ${HELPER} remove ;;
    status) ${HELPER} status ;;
    *) echo "Usage: \$0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
EOF
    fi
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 755 "$TMP" && mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_apply_tc() {
    local RATE="$1" FORCE="${2:-0}" APPLY_RC WAS_MANAGED=0
    local DEV; DEV=$(default_iface)
    [ -z "$DEV" ] && { error "无法确定默认出口网卡"; return 1; }
    local TC_BIN
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { error "tc 命令不可用，请先安装 iproute2"; return 1; }

    # burst/cburst 按约 4ms 线速数据量计算，兼顾高速吞吐和整形精度。
    local BURST_KB
    BURST_KB=$(bbr_tc_burst_kb "$RATE") || return 1
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        WAS_MANAGED=1
    fi

    bbr_tc_apply_runtime "$DEV" "$RATE" "$BURST_KB" "$TC_BIN" "$FORCE"
    APPLY_RC=$?
    [ "$APPLY_RC" -eq 0 ] || return "$APPLY_RC"
    if ! bbr_tc_topology_matches "$DEV" "$TC_BIN" \
        || ! bbr_tc_rate_matches "$DEV" "$TC_BIN" "$RATE"; then
        error "tc 写入后回读不一致，未确认 ${RATE}Mbps 已生效"
        if [ "$WAS_MANAGED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "原 tc 限速规则自动恢复失败"
        else
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || true
            [ "$FORCE" != 1 ] || warn "强制接管前的外部 qdisc 无法通用恢复，请使用已保存的诊断快照重建"
        fi
        return 1
    fi
    bbr_tc_write_persistence "$DEV" "$RATE" "$BURST_KB" "$FORCE" || {
        error "tc 已立即生效，但持久化配置未完成"
        return 1
    }
    if ! bbr_tc_rate_matches "$DEV" "$TC_BIN" "$RATE"; then
        error "持久化服务重载后 HTB 速率回读不一致，请运行网络性能诊断"
        return 1
    fi
    info "tc 限速已应用并回读确认：${RATE}Mbps（htb 聚合整形 + fq pacing，burst ${BURST_KB}KB）✓"
    return 0
}

bbr_remove_tc() {
    local FORCE="${1:-0}" TC_BIN DEV FAILED=0 FOREIGN=0 QDISCS LINE TYPE SNAPSHOT=""
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ -n "$DEV" ] || DEV=$(default_iface)
    if [ -x "$TC_BIN" ] && [ -n "$DEV" ]; then
        if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
        else
            QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
            LINE=$(bbr_tc_root_line "$QDISCS")
            TYPE=$(bbr_tc_qdisc_type "$LINE")
            if [ -n "$LINE" ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
                if [ "$FORCE" = 1 ]; then
                    SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || FAILED=1
                    if [ "$FAILED" -eq 0 ]; then
                        warn "已保存外部 tc 诊断快照：${SNAPSHOT}"
                        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
                    fi
                else
                    FOREIGN=1
                fi
            fi
        fi
    fi

    if systemd_available; then
        systemctl disable --now tc-fq >/dev/null 2>&1 || true
        rm -f "$SERVICE_TC"
        systemctl daemon-reload >/dev/null 2>&1 || FAILED=1
    elif command -v rc-update >/dev/null 2>&1; then
        rc-service tc-fq stop >/dev/null 2>&1 || true
        rc-update del tc-fq default >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null 2>&1; then
        service tc-fq stop >/dev/null 2>&1 || true
        update-rc.d -f tc-fq remove >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_TC_INIT" "$TC_HELPER" "$TC_STATE_FILE"
    if [ "$FAILED" -ne 0 ]; then
        error "取消 tc 限速时发生错误"
        return 1
    fi
    if [ "$FOREIGN" -eq 1 ]; then
        warn "本工具的 tc 持久化已取消，但外部 root qdisc ${TYPE:-未知} 仍在生效"
        return 2
    fi
    [ "$FORCE" != 1 ] || info "外部 root qdisc 已删除 ✓"
    info "已取消本工具管理的 tc 限速 ✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_physical_memory_mb() {
    local MEM_KB
    MEM_KB=$(awk '/MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
    case "$MEM_KB" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo $(( MEM_KB / 1024 )) ;;
    esac
}

bbr_effective_memory_mb() {
    local REQUESTED_MB="$1" ACTUAL_MB="${2:-}"
    [ -n "$ACTUAL_MB" ] || ACTUAL_MB=$(bbr_physical_memory_mb)
    case "$REQUESTED_MB" in ''|*[!0-9]*) return 1 ;; esac
    case "$ACTUAL_MB" in ''|*[!0-9]*) ACTUAL_MB=0 ;; esac
    if [ "$ACTUAL_MB" -gt 0 ] && [ "$REQUESTED_MB" -gt "$ACTUAL_MB" ]; then
        echo "$ACTUAL_MB"
    else
        echo "$REQUESTED_MB"
    fi
}

bbr_buffer_cap_bytes() {
    local MEM_MB="$1" ROLE="${2:-mixed}" DIVISOR CAP
    case "$MEM_MB" in ''|*[!0-9]*) return 1 ;; esac
    [ "$MEM_MB" -gt 0 ] || return 1
    case "$ROLE" in
        proxy|relay|line_landing|latency) DIVISOR=32 ;;
        bulk|throughput|landing|mixed|balanced|default) DIVISOR=16 ;;
        *) return 1 ;;
    esac
    CAP=$(( MEM_MB * 1048576 / DIVISOR ))
    [ "$CAP" -ge 4194304 ] || CAP=4194304
    [ "$CAP" -le 268435456 ] || CAP=268435456
    printf '%s\n' "$CAP"
}

bbr_conntrack_max_for_memory() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 1024 ]; then
        echo 131072
    elif [ "$MEM_MB" -lt 2048 ]; then
        echo 262144
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo 524288
    else
        echo 1048576
    fi
}

bbr_generate_config() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 \
          PROFILE_NAME="${4:-default}" ENABLE_FORWARD="${5:-0}"
    local FASTOPEN UDP_RMEM
    FASTOPEN=$(bbr_tcp_fastopen_value)
    UDP_RMEM=$(bbr_capacity_floor net.ipv4.udp_rmem_min 16384)
    cat << EOF
# VPS Quench 网络性能调优配置 — 生成时间：$(date)
# 预设：${PROFILE_NAME}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 4096 131072 ${RMEM}
net.ipv4.tcp_wmem = 4096 16384 ${WMEM}
net.ipv4.tcp_notsent_lowat = ${NOTSENT}

# ── 连接质量 ──
net.ipv4.tcp_fastopen = ${FASTOPEN}
net.ipv4.tcp_mtu_probing = 1

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = ${UDP_RMEM}
EOF

    # 场景预设的并发参数不依赖内核转发，用户态代理同样受益。
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            local SOMAX BACKLOG SYN_BACKLOG PORT_RANGE TW_BUCKETS FILE_MAX
            SOMAX=$(bbr_capacity_floor net.core.somaxconn 8192)
            BACKLOG=$(bbr_capacity_floor net.core.netdev_max_backlog 16384)
            SYN_BACKLOG=$(bbr_capacity_floor net.ipv4.tcp_max_syn_backlog 8192)
            PORT_RANGE=$(bbr_port_range_union 10000 65535)
            TW_BUCKETS=$(bbr_capacity_floor net.ipv4.tcp_max_tw_buckets 500000)
            FILE_MAX=$(bbr_capacity_floor fs.file-max 1048576)
            cat << EOF

# ── 代理并发 ──
net.core.somaxconn = ${SOMAX}
net.core.netdev_max_backlog = ${BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = ${PORT_RANGE}
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
fs.file-max = ${FILE_MAX}
EOF
            ;;
    esac

    if [ "$ENABLE_FORWARD" = 1 ]; then
        local IPV6_IFACE
        IPV6_IFACE=$(bbr_default_ipv6_iface)
        cat << EOF

# ── 内核路由 / NAT ──
net.ipv6.conf.default.accept_ra = 2
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
        if [ -n "$IPV6_IFACE" ]; then
            cat << EOF
net.ipv6.conf.${IPV6_IFACE}.accept_ra = 2
EOF
        fi
    fi

    if [ "$ENABLE_FORWARD" = 1 ]; then
        local MEM_MB CONNTRACK_MAX
        MEM_MB=$(bbr_physical_memory_mb)
        CONNTRACK_MAX=$(bbr_conntrack_max_for_memory "$MEM_MB")
        CONNTRACK_MAX=$(bbr_capacity_floor net.netfilter.nf_conntrack_max "$CONNTRACK_MAX")
        cat << EOF

# ── conntrack（按物理内存分档）──
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    fi
}

# ── 确认并应用参数 ────────────────────────────────────────
bbr_preflight() {
    ensure_sysctl || return 1
    if ! has_sysctl_write; then
        error "当前容器无 sysctl 写入权限，无法应用配置"
        echo -e "  ${DIM}需要宿主机开启 privileged 模式或 sysctl 白名单${NC}"
        return 1
    fi
    bbr_check_kernel || return 1
    if ! modprobe sch_fq >/dev/null 2>&1 \
        && ! sysctl -n net.core.default_qdisc 2>/dev/null | grep -qw fq; then
        if bbr_kernel_at_least 4 20; then
            warn "未能预加载 sch_fq；现代内核的 BBR 仍可使用内部 pacing，fq 将按实际支持情况应用"
        else
            error "内核低于 4.20 且 sch_fq 不可用，无法安全启用 BBR pacing"
            return 1
        fi
    fi
}

# ── 检测常见代理 service 的 LimitNOFILE，偏低则提示写 drop-in ──
# fs.file-max 只是系统总上限，单进程 fd 上限由 systemd 的 LimitNOFILE 决定。
bbr_check_limitnofile() {
    command -v systemctl >/dev/null 2>&1 || return 0   # 非 systemd 跳过
    local SVCS="xray sing-box hysteria hysteria-server tuic v2ray trojan trojan-go mihomo clash"
    local svc found=0
    for svc in $SVCS; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
        found=1
        local CUR
        CUR=$(systemctl show -p LimitNOFILE --value "${svc}.service" 2>/dev/null)
        # 默认值通常为 1024 / 524288；低于 1048576 视为偏低
        if [ -n "$CUR" ] && [ "$CUR" -lt 1048576 ] 2>/dev/null; then
            echo ""
            warn "检测到代理服务 ${svc}.service 的 LimitNOFILE=${CUR} 偏低"
            echo -e "  ${DIM}fs.file-max 已抬高，但单进程 fd 上限受 systemd LimitNOFILE 限制${NC}"
            read -rp "  是否为 ${svc} 写入 LimitNOFILE=1048576 的 drop-in？(y/N，默认N): " DOLN
            [ -z "$DOLN" ] && DOLN="n"
            if echo "$DOLN" | grep -qiE '^y(es)?$'; then
                local DROPDIR="/etc/systemd/system/${svc}.service.d"
                mkdir -p "$DROPDIR" 2>/dev/null
                printf '[Service]\nLimitNOFILE=1048576\n' > "${DROPDIR}/99-nofile.conf"
                systemctl daemon-reload 2>/dev/null
                info "已写入 ${DROPDIR}/99-nofile.conf，重启 ${svc} 后生效：systemctl restart ${svc}"
            fi
        fi
    done
    [ "$found" -eq 0 ] && return 0
}

bbr_kernel_forwarding_confirm() {
    local ANSWER
    read -rp "  是否启用内核 IPv4/IPv6 转发？仅路由或 NAT 需要 (y/N，默认N): " ANSWER
    [ -z "$ANSWER" ] && ANSWER="n"
    echo "$ANSWER" | grep -qiE '^y(es)?$'
}

bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 \
          LABEL_MODE=$4 LABEL_BUF=$5 PROFILE_NAME="${6:-default}" ENABLE_FORWARD=0

    bbr_preflight || return 1
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            echo ""
            bbr_kernel_forwarding_confirm && ENABLE_FORWARD=1
            ;;
    esac

    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  TCP min/default  : ${BOLD}接收 4KB/128KB · 发送 4KB/16KB${NC}"
    echo -e "  全局 TCP 内存    : ${BOLD}由内核自动管理${NC}"
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            [ "$ENABLE_FORWARD" = 1 ] \
                && echo -e "  内核转发     : ${BOLD}启用${NC}" \
                || echo -e "  内核转发     : ${BOLD}不修改${NC}"
            ;;
    esac
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""

    # 先提示备份（默认Y）
    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  备份当前 sysctl 配置？(Y/n，默认Y): " DO_BAK
        [ -z "$DO_BAK" ] && DO_BAK="y"
        if echo "$DO_BAK" | grep -qiE '^y(es)?$' && ! bbr_backup_sysctl; then
            error "无法安全备份，已取消应用"
            return 1
        fi
        echo ""
    fi
    read -rp "  确认应用以上配置？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    [ "$ENABLE_FORWARD" != 1 ] \
        || ensure_conntrack_module \
        || warn "无法预加载 nf_conntrack，将按内核实际支持情况应用"
    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$NOTSENT" "$PROFILE_NAME" "$ENABLE_FORWARD")
    bbr_apply_sysctl "$CONFIG" || {
        error "网络性能调优配置应用失败"
        return 1
    }
    # 场景预设（转发机）额外检测代理 service 的 fd 上限
    case "$PROFILE_NAME" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    echo ""
    info "网络性能调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
    return 0
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_bdp_mb() {
    awk -v bw="$1" -v lat="$2" 'BEGIN { printf "%.2f", bw * lat / 8000 }'
}


bbr_buffer_target_bytes() {
    local BW_MBPS="$1" LAT_MS="$2" TARGET
    case "$BW_MBPS:$LAT_MS" in *[!0-9:]*) return 1 ;; esac
    [ "$BW_MBPS" -gt 0 ] && [ "$LAT_MS" -gt 0 ] || return 1
    # 精确目标：2 × BDP + 2MiB 余量，再向上对齐到 64KiB。
    TARGET=$(( BW_MBPS * LAT_MS * 250 + 2097152 ))
    TARGET=$(( (TARGET + 65535) / 65536 * 65536 ))
    printf '%s\n' "$TARGET"
}

bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6
    local ACTUAL_MEM_MB EFFECTIVE_MEM_MB
    ACTUAL_MEM_MB=$(bbr_physical_memory_mb)
    EFFECTIVE_MEM_MB=$(bbr_effective_memory_mb "$MEM_MB" "$ACTUAL_MEM_MB") || return 1
    if [ "$EFFECTIVE_MEM_MB" -lt "$MEM_MB" ]; then
        warn "所选内存 ${MEM_MB}MB 超过实际内存 ${ACTUAL_MEM_MB}MB，按实际内存计算"
        MEM_LBL="${MEM_LBL}，按实际 ${ACTUAL_MEM_MB}MB"
    fi
    MEM_MB=$EFFECTIVE_MEM_MB

    local BDP_MB TARGET_BYTES
    BDP_MB=$(bbr_bdp_mb "$BW_MBPS" "$LAT_MS")
    TARGET_BYTES=$(bbr_buffer_target_bytes "$BW_MBPS" "$LAT_MS") || return 1

    local RMEM WMEM NOTSENT
    RMEM=$TARGET_BYTES
    WMEM=$RMEM

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB" mixed) || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "精确 BDP 目标 $(( (RMEM + 1048575) / 1048576 ))MB 超过当前场景内存预算，自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
    fi
    if [ "$RMEM" -le 16777216 ]; then NOTSENT=131072
    elif [ "$RMEM" -le 67108864 ]; then NOTSENT=262144
    else NOTSENT=524288
    fi

    local BUF_MB=$(( (RMEM + 1048575) / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  2×BDP+2MiB：${BOLD}$(( (TARGET_BYTES + 1048575) / 1048576 ))MB${NC}"
    echo -e "  实际采用：${BOLD}${BUF_MB}MB${NC}  ${DIM}受内存预算与 256MB 绝对上限约束${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    menu_pair "1" "100 Mbps" "2" "200 Mbps"
    menu_pair "3" "500 Mbps" "4" "1 Gbps"
    menu_pair "5" "2 Gbps" "6" "5 Gbps"
    menu_item "7" "10 Gbps"
    menu_item "c" "自定义带宽  ${DIM}如 400、600M、1.5G${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择带宽 [0-7/c]: ')" CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 100   "$MEM_LBL" "$LAT_LBL" "100Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200   "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500   "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1000  "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        5) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2000  "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
        6) bbr_auto_calc "$MEM_MB" "$LAT_MS" 5000  "$MEM_LBL" "$LAT_LBL" "5Gbps" ;;
        7) bbr_auto_calc "$MEM_MB" "$LAT_MS" 10000 "$MEM_LBL" "$LAT_LBL" "10Gbps" ;;
        c|C)
            local INPUT CUSTOM_BW
            read -rp "  输入带宽（默认 Mbps，可用 M/G）: " INPUT
            CUSTOM_BW=$(bbr_parse_bandwidth_mbps "$INPUT") \
                || { error "无效带宽；示例：400、600M、1.5G"; return 1; }
            bbr_auto_calc "$MEM_MB" "$LAT_MS" "$CUSTOM_BW" "$MEM_LBL" "$LAT_LBL" "${CUSTOM_BW}Mbps"
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：延迟子菜单 ─────────────────────────────────
bbr_menu_latency() {
    local MEM_MB=$1 MEM_LBL=$2
    print_header "BBR 自动配置 — 选择延迟"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}"
    echo ""
    menu_item "1" "100ms 以内  ${DIM}国内 / 亚洲${NC}"
    menu_item "2" "100-200ms  ${DIM}跨国线路${NC}"
    menu_item "3" "200ms 以上  ${DIM}跨洲长距离${NC}"
    menu_item "4" "自定义目标 RTT  ${DIM}1-2000ms${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择延迟 [0-4]: ')" CH
    case "$CH" in
        1) bbr_menu_bandwidth "$MEM_MB" 50  "$MEM_LBL" "100ms以内" ;;
        2) bbr_menu_bandwidth "$MEM_MB" 150 "$MEM_LBL" "100-200ms" ;;
        3) bbr_menu_bandwidth "$MEM_MB" 250 "$MEM_LBL" "200ms以上" ;;
        4)
            local CUSTOM_RTT
            read -rp "  输入目标 RTT（ms，1-2000）: " CUSTOM_RTT
            printf '%s\n' "$CUSTOM_RTT" | grep -qE '^[0-9]+$' \
                && [ "$CUSTOM_RTT" -ge 1 ] && [ "$CUSTOM_RTT" -le 2000 ] \
                || { error "RTT 必须是 1-2000 的整数"; return 1; }
            bbr_menu_bandwidth "$MEM_MB" "$CUSTOM_RTT" "$MEM_LBL" "${CUSTOM_RTT}ms"
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：内存子菜单 ─────────────────────────────────
bbr_menu_auto() {
    # 自动检测系统内存并标注推荐档位
    local SYS_MEM_MB
    SYS_MEM_MB=$(bbr_physical_memory_mb)

    print_header "BBR 自动配置 — 选择内存"
    echo -e "  系统检测内存：${BOLD}${SYS_MEM_MB}MB${NC}"
    echo ""
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB" "4" "4 GB"
    menu_pair "5" "8 GB" "6" "16 GB+"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择内存 [0-6]: ')" CH
    local SELECTED_MB SELECTED_LABEL EFFECTIVE_MB
    case "$CH" in
        1) SELECTED_MB=512;   SELECTED_LABEL="512MB" ;;
        2) SELECTED_MB=1024;  SELECTED_LABEL="1GB" ;;
        3) SELECTED_MB=2048;  SELECTED_LABEL="2GB" ;;
        4) SELECTED_MB=4096;  SELECTED_LABEL="4GB" ;;
        5) SELECTED_MB=8192;  SELECTED_LABEL="8GB" ;;
        6) SELECTED_MB=16384; SELECTED_LABEL="16GB+" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    EFFECTIVE_MB=$(bbr_effective_memory_mb "$SELECTED_MB" "$SYS_MEM_MB") || return 1
    if [ "$EFFECTIVE_MB" -lt "$SELECTED_MB" ]; then
        warn "所选内存 ${SELECTED_LABEL} 超过实际内存 ${SYS_MEM_MB}MB，后续按实际内存计算"
        SELECTED_LABEL="${SELECTED_LABEL}（实际 ${SYS_MEM_MB}MB）"
    fi
    bbr_menu_latency "$EFFECTIVE_MB" "$SELECTED_LABEL"
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_MB
    MEM_MB=$(bbr_physical_memory_mb)
    [ "$MEM_MB" -gt 0 ] || { error "无法读取物理内存"; return 1; }

    # ── 第一层：选择用途 ──
    print_header "BBR 手动配置 — 选择用途"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}"
    echo ""
    menu_div
    echo -e "  ${BOLD}请选择 VPS 用途（决定并发与队列参数）${NC}"
    echo ""
    menu_item "1" "中转机  ${DIM}双向转发 / 大并发${NC}"
    menu_item "2" "落地机  ${DIM}跨境上行 / 大缓冲${NC}"
    menu_item "3" "线路落地机  ${DIM}低延迟优先${NC}"
    menu_item "4" "通用单机  ${DIM}网页 / SSH / 服务${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择用途 [0-4]: ')" SCENE
    local PROFILE SCENE_LABEL
    case "$SCENE" in
        1) PROFILE="relay";        SCENE_LABEL="中转机" ;;
        2) PROFILE="landing";      SCENE_LABEL="落地机" ;;
        3) PROFILE="line_landing"; SCENE_LABEL="线路落地机" ;;
        4) PROFILE="default";      SCENE_LABEL="通用单机" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # ── 第二层：根据场景给出推荐档位提示 + 缓冲区选择 ──
    local RECOMMEND
    case "$PROFILE" in
        relay)
            if   [ "$MEM_MB" -le 512 ];  then RECOMMEND="推荐 2 (16MB)"
            elif [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 4 (32MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB，上限)"
            fi ;;
        landing)
            if   [ "$MEM_MB" -le 512 ];  then RECOMMEND="推荐 4 (32MB)"
            elif [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB，上限)"
            fi ;;
        line_landing)
            if   [ "$MEM_MB" -le 512 ];  then RECOMMEND="推荐 2 (16MB)"
            elif [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 4 (32MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB，上限)"
            fi ;;
        default)
            if   [ "$MEM_MB" -le 512 ];  then RECOMMEND="推荐 4 (32MB)"
            elif [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB，上限)"
            fi ;;
    esac

    print_header "BBR 手动配置 — ${SCENE_LABEL} · 选择缓冲区"
    echo -e "  场景：${BOLD}${SCENE_LABEL}${NC}    内存：${BOLD}${MEM_MB}MB${NC}"
    echo -e "  ${YELLOW}${RECOMMEND}${NC}"
    echo ""
    menu_div
    menu_pair "1" "12 MB · 低带宽" "2" "16 MB · 小内存"
    menu_pair "3" "20 MB · 中低带宽" "4" "32 MB · 跨境推荐"
    menu_pair "5" "40 MB · 1G" "6" "64 MB · 1G+"
    menu_pair "7" "128 MB · 2G" "8" "256 MB · 5G"
    menu_pair "9" "512 MB · 10G" "10" "1024 MB · 极限"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择缓冲区 [0-10]: ')" CH

    local RMEM WMEM BUF_LBL
    case "$CH" in
        1)  RMEM=12582912;   BUF_LBL=12   ;;
        2)  RMEM=16777216;   BUF_LBL=16   ;;
        3)  RMEM=20971520;   BUF_LBL=20   ;;
        4)  RMEM=33554432;   BUF_LBL=32   ;;
        5)  RMEM=41943040;   BUF_LBL=40   ;;
        6)  RMEM=67108864;   BUF_LBL=64   ;;
        7)  RMEM=134217728;  BUF_LBL=128  ;;
        8)  RMEM=268435456;  BUF_LBL=256  ;;
        9)  RMEM=536870912;  BUF_LBL=512  ;;
        10) RMEM=1073741824; BUF_LBL=1024 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    WMEM=$RMEM

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB" "$PROFILE") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "缓冲区 ${BUF_LBL}MB 超过 ${SCENE_LABEL} 的建议内存预算，高并发时可能造成内存压力"
        read -rp "  是否继续？(y/N，默认N): " GO
        [ -z "$GO" ] && GO="n"
        echo "$GO" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    fi

    # ── 根据场景调整待发送队列 ──
    local NOTSENT
    case "$PROFILE" in
        relay)
            # 中转机：NOTSENT 小（降低单连接延迟）
            NOTSENT=262144
            ;;
        landing)
            # 落地机：NOTSENT 大（高吞吐）
            NOTSENT=2097152
            ;;
        line_landing)
            # 线路落地机：NOTSENT 极小（响应优先）
            NOTSENT=131072
            ;;
        default)
            # 通用：跟着缓冲区档位走
            if   [ "$BUF_LBL" -le 32 ];  then NOTSENT=262144
            elif [ "$BUF_LBL" -le 64 ];  then NOTSENT=524288
            elif [ "$BUF_LBL" -le 256 ]; then NOTSENT=1048576
            else                              NOTSENT=2097152
            fi ;;
    esac

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" \
        "${SCENE_LABEL}（内存 ${MEM_MB}MB）" "$BUF_LBL" "$PROFILE"
}

# ── 线路容量与 policer 拐点实测 ──────────────────────────
BBR_CAL_QDISC_MODE=""
BBR_CAL_QDISC_TYPE=""
BBR_CAL_QDISC_LEAVES=""
BBR_CAL_DEV=""
BBR_CAL_TC_BIN=""
BBR_CAL_IPERF_PID=""
BBR_CAL_TEMP_FILE=""
# 固定 fd 7，编号见 core.sh 的 fd 分配表（exec {VAR}> 在 bash 3.2 下不可用）。
BBR_CAL_LOCK_HELD=0
BBR_CAL_LOCK_MODE=""
BBR_CAL_SENDER=""
BBR_CAL_RECEIVER=""
BBR_CAL_RETRANS=""
BBR_CAL_LOSS=""
BBR_CAL_TRAFFIC_RX0=""
BBR_CAL_TRAFFIC_TX0=""

bbr_calibration_host_valid() {
    local HOST="$1"
    [ -n "$HOST" ] && [ "${#HOST}" -le 253 ] || return 1
    [[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || return 1
    [[ "$HOST" != *..* ]] || return 1
}

bbr_calibration_port_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

bbr_calibration_margin() {
    local RATE="$1"
    case "$RATE" in ''|*[!0-9]*) return 1 ;; esac
    awk -v rate="$RATE" 'BEGIN {
        margin=int(rate*0.025+0.5)
        if (margin<1) margin=1
        if (margin>40) margin=40
        print margin
    }'
}

bbr_calibration_estimate_gb() {
    local NOMINAL="$1" DURATION="$2"
    awk -v rate="$NOMINAL" -v duration="$DURATION" 'BEGIN {
        # 上限按 25 个样本、最高 2 倍标称速率估算，覆盖基线、复测、控制点和细扫。
        printf "%.1f\n", rate * 2 * duration * 25 / 8000
    }'
}

bbr_calibration_loss_pct() {
    local RETRANS="$1" SENDER="$2" DURATION="$3"
    awk -v retrans="$RETRANS" -v sender="$SENDER" -v duration="$DURATION" 'BEGIN {
        packets = sender * 1000000 * duration / 8 / 1448
        if (packets < 1) packets = 1
        printf "%.4f\n", retrans * 100 / packets
    }'
}

bbr_calibration_is_spike() {
    local LOSS="$1" BASELINE="${2:-0}" THRESHOLD="${3:-0.1}"
    awk -v loss="$LOSS" -v baseline="$BASELINE" -v threshold="$THRESHOLD" 'BEGIN {
        need = threshold
        if (baseline > 0 && baseline * 5 > need) need = baseline * 5
        if (need > 1) need = 1
        exit !(loss > need)
    }'
}

bbr_calibration_parse_iperf() {
    local FILE="$1" STREAMS="$2"
    awk -v streams="$STREAMS" '
        / sender$/ {
            if (streams > 1 && $0 !~ /\[SUM\]/) next
            rate=""; retrans=""
            for (i=1; i<NF; i++) if ($(i+1) == "Mbits/sec") { rate=$i; break }
            if (NF >= 2) retrans=$(NF-1)
            if (rate ~ /^[0-9]+([.][0-9]+)?$/ && retrans ~ /^[0-9]+$/) {
                sender=rate; retr=retrans
            }
        }
        / receiver$/ {
            if (streams > 1 && $0 !~ /\[SUM\]/) next
            rate=""
            for (i=1; i<NF; i++) if ($(i+1) == "Mbits/sec") { rate=$i; break }
            if (rate ~ /^[0-9]+([.][0-9]+)?$/) receiver=rate
        }
        END {
            if (sender == "" || retr == "") exit 1
            if (receiver == "") receiver=sender
            printf "%s %s %s\n", sender, retr, receiver
        }
    ' "$FILE"
}

bbr_calibration_lock_acquire() {
    local LOCK_DIR OWNER ATTEMPT
    mkdir -p "$(dirname "$BBR_CALIBRATION_LOCK_FILE")" 2>/dev/null || return 1
    if command -v flock >/dev/null 2>&1; then
        exec 7>"$BBR_CALIBRATION_LOCK_FILE" || return 1
        if ! flock -n 7; then
            exec 7>&-
            error "另一个 Quench 线路校准任务正在运行"
            return 1
        fi
        BBR_CAL_LOCK_HELD=1
        BBR_CAL_LOCK_MODE="flock"
    else
        LOCK_DIR="${BBR_CALIBRATION_LOCK_FILE}.d"
        for ATTEMPT in 1 2; do
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                printf '%s\n' "$$" > "${LOCK_DIR}/pid" || { rmdir "$LOCK_DIR" 2>/dev/null; return 1; }
                BBR_CAL_LOCK_MODE="mkdir"
                return 0
            fi
            OWNER=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
            if printf '%s\n' "$OWNER" | grep -qE '^[0-9]+$' && kill -0 "$OWNER" 2>/dev/null; then
                break
            fi
            rm -f "${LOCK_DIR}/pid"
            rmdir "$LOCK_DIR" 2>/dev/null || break
        done
        error "另一个 Quench 线路校准任务正在运行"
        return 1
    fi
}

bbr_calibration_lock_release() {
    if [ "$BBR_CAL_LOCK_HELD" = 1 ]; then
        flock -u 7 2>/dev/null || true
        exec 7>&-
        BBR_CAL_LOCK_HELD=0
    fi
    if [ "$BBR_CAL_LOCK_MODE" = mkdir ]; then
        rm -f "${BBR_CALIBRATION_LOCK_FILE}.d/pid"
        rmdir "${BBR_CALIBRATION_LOCK_FILE}.d" 2>/dev/null || true
    fi
    BBR_CAL_LOCK_MODE=""
}

bbr_calibration_mq_leaves() {
    local OUTPUT="$1" MAJOR="$2"
    printf '%s\n' "$OUTPUT" | awk -v major="$MAJOR" '
        $1 == "qdisc" && $0 ~ / parent / {
            parent=""
            for (i=1; i<NF; i++) if ($i == "parent") { parent=$(i+1); break }
            matched=0
            if (major == "0" && parent ~ /^(:|0:)[0-9a-fA-F]+$/) matched=1
            if (major != "0" && index(parent, major ":") == 1) matched=1
            if (matched) {
                sub(/^.*:/, "", parent)
                if (parent ~ /^[0-9a-fA-F]+$/) print parent "|" $2
            }
        }
    '
}

bbr_calibration_mq_addressable_major() {
    local DEV="$1" TC_BIN="$2" QDISCS ROOT_LINE HANDLE MAJOR
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    [ "$(bbr_tc_qdisc_type "$ROOT_LINE")" = mq ] || return 1
    HANDLE=$(bbr_tc_qdisc_handle "$ROOT_LINE")
    MAJOR=${HANDLE%:}
    if [ -z "$MAJOR" ] || [ "$MAJOR" = 0 ]; then
        "$TC_BIN" qdisc replace dev "$DEV" root handle 1: mq 2>/dev/null || return 1
        QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
        ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
        [ "$(bbr_tc_qdisc_type "$ROOT_LINE")" = mq ] || return 1
        HANDLE=$(bbr_tc_qdisc_handle "$ROOT_LINE")
        MAJOR=${HANDLE%:}
    fi
    printf '%s\n' "$MAJOR" | grep -qE '^[0-9a-fA-F]+$' || return 1
    printf '%s\n' "$MAJOR"
}

bbr_calibration_capture_qdisc() {
    local DEV="$1" TC_BIN="$2" QDISCS ROOT_LINE TYPE HANDLE MAJOR LEAF_TYPE
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$ROOT_LINE")
    BBR_CAL_QDISC_TYPE="$TYPE"
    BBR_CAL_QDISC_LEAVES=""
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        BBR_CAL_QDISC_MODE=managed
        return 0
    fi
    if ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        error "当前 root qdisc 为外部 ${TYPE:-未知}，线路实测不会覆盖无法精确恢复的 QoS"
        return 1
    fi
    BBR_CAL_QDISC_MODE=default
    if [ "$TYPE" = mq ]; then
        HANDLE=$(bbr_tc_qdisc_handle "$ROOT_LINE")
        MAJOR=${HANDLE%:}; [ -n "$MAJOR" ] || MAJOR=0
        BBR_CAL_QDISC_LEAVES=$(bbr_calibration_mq_leaves "$QDISCS" "$MAJOR")
        [ -n "$BBR_CAL_QDISC_LEAVES" ] || {
            error "没有读到 ${DEV} 的 mq 叶子，无法验证并恢复多队列 qdisc"
            return 1
        }
        while IFS='|' read -r _ LEAF_TYPE; do
            [ -n "$LEAF_TYPE" ] || continue
            if ! bbr_tc_qdisc_safe_to_replace "$LEAF_TYPE"; then
                error "${DEV} 的 mq 叶子存在外部 ${LEAF_TYPE}，无法无损临时接管"
                return 1
            fi
        done <<< "$BBR_CAL_QDISC_LEAVES"
    fi
}

bbr_calibration_set_fq() {
    local DEV="$1" TC_BIN="$2" QDISCS ROOT_LINE TYPE MAJOR INDEX LEAVES FOUND=0
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$ROOT_LINE")
    case "$TYPE" in
        fq) return 0 ;;
        mq)
            MAJOR=$(bbr_calibration_mq_addressable_major "$DEV" "$TC_BIN") || return 1
            QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
            LEAVES=$(bbr_calibration_mq_leaves "$QDISCS" "$MAJOR")
            while IFS='|' read -r INDEX _; do
                [ -n "$INDEX" ] || continue
                FOUND=1
                "$TC_BIN" qdisc replace dev "$DEV" parent "${MAJOR}:${INDEX}" fq 2>/dev/null || return 1
            done <<< "$LEAVES"
            [ "$FOUND" -eq 1 ]
            ;;
        *) "$TC_BIN" qdisc replace dev "$DEV" root fq 2>/dev/null ;;
    esac
}

bbr_calibration_apply_shaper() {
    local DEV="$1" RATE="$2" TC_BIN="$3" BURST_KB QDISCS ROOT_LINE TYPE HANDLE ROOT_ACTION=replace
    BURST_KB=$(bbr_tc_burst_kb "$RATE") || return 1
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$ROOT_LINE")
    HANDLE=$(bbr_tc_qdisc_handle "$ROOT_LINE")
    if [ "$TYPE" = htb ] && [ "$HANDLE" = 1: ]; then
        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || return 1
        ROOT_ACTION=add
    fi
    "$TC_BIN" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 2>/dev/null \
        && "$TC_BIN" class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        && "$TC_BIN" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null \
        && bbr_tc_topology_matches "$DEV" "$TC_BIN" \
        && bbr_tc_rate_matches "$DEV" "$TC_BIN" "$RATE"
}

bbr_calibration_restore_qdisc() {
    local INDEX LEAF_TYPE CURRENT CURRENT_QDISCS MAJOR
    [ -n "$BBR_CAL_DEV" ] && [ -n "$BBR_CAL_TC_BIN" ] || return 0
    if [ "$BBR_CAL_QDISC_MODE" = managed ]; then
        bbr_tc_restore_owned
        return $?
    fi
    "$BBR_CAL_TC_BIN" qdisc del dev "$BBR_CAL_DEV" root 2>/dev/null || true
    case "$BBR_CAL_QDISC_TYPE" in
        mq)
            CURRENT_QDISCS=$("$BBR_CAL_TC_BIN" qdisc show dev "$BBR_CAL_DEV" 2>/dev/null || true)
            CURRENT=$(bbr_tc_root_line "$CURRENT_QDISCS")
            [ "$(bbr_tc_qdisc_type "$CURRENT")" = mq ] \
                || "$BBR_CAL_TC_BIN" qdisc replace dev "$BBR_CAL_DEV" root handle 1: mq 2>/dev/null \
                || return 1
            MAJOR=$(bbr_calibration_mq_addressable_major "$BBR_CAL_DEV" "$BBR_CAL_TC_BIN") || return 1
            while IFS='|' read -r INDEX LEAF_TYPE; do
                [ -n "$INDEX" ] && [ -n "$LEAF_TYPE" ] || continue
                "$BBR_CAL_TC_BIN" qdisc replace dev "$BBR_CAL_DEV" parent "${MAJOR}:${INDEX}" "$LEAF_TYPE" 2>/dev/null \
                    || return 1
            done <<< "$BBR_CAL_QDISC_LEAVES"
            ;;
        fq|fq_codel|pfifo_fast)
            "$BBR_CAL_TC_BIN" qdisc replace dev "$BBR_CAL_DEV" root "$BBR_CAL_QDISC_TYPE" 2>/dev/null \
                || return 1
            ;;
        ""|noqueue) : ;;
        *) return 1 ;;
    esac
}

bbr_calibration_stop_child() {
    [ -n "$BBR_CAL_IPERF_PID" ] || return 0
    kill -TERM "$BBR_CAL_IPERF_PID" 2>/dev/null || true
    command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$BBR_CAL_IPERF_PID" 2>/dev/null || true
    wait "$BBR_CAL_IPERF_PID" 2>/dev/null || true
    BBR_CAL_IPERF_PID=""
}

bbr_calibration_interrupt() {
    quench_restore_signal_traps
    echo ""
    warn "线路实测被中断，正在恢复原 qdisc"
    bbr_calibration_stop_child
    [ -z "$BBR_CAL_TEMP_FILE" ] || rm -f "$BBR_CAL_TEMP_FILE"
    bbr_calibration_restore_qdisc || warn "原 qdisc 自动恢复失败，请立即运行网络性能诊断"
    bbr_calibration_lock_release
    exit 130
}

bbr_calibration_measure() {
    local PEER="$1" PORT="$2" FAMILY="$3" DURATION="$4" STREAMS="$5" LABEL="$6"
    local RESULT RC
    local -a TIMEOUT_ARGS=()
    BBR_CAL_SENDER=""; BBR_CAL_RECEIVER=""; BBR_CAL_RETRANS=""; BBR_CAL_LOSS=""
    BBR_CAL_TEMP_FILE=$(quench_mktemp "${TMPDIR:-/tmp}/quench-iperf.XXXXXX") || return 1
    timeout --foreground 1 true >/dev/null 2>&1 && TIMEOUT_ARGS=(--foreground)
    echo -e "  ${CYAN}▸${NC} ${LABEL}：${DURATION}s × ${STREAMS} 流 → ${PEER}:${PORT}"
    LC_ALL=C timeout "${TIMEOUT_ARGS[@]}" $(( DURATION + 25 )) \
        iperf3 "-${FAMILY}" -c "$PEER" -p "$PORT" -t "$DURATION" -P "$STREAMS" -f m \
        > "$BBR_CAL_TEMP_FILE" 2>&1 &
    BBR_CAL_IPERF_PID=$!
    wait "$BBR_CAL_IPERF_PID"; RC=$?
    BBR_CAL_IPERF_PID=""
    if [ "$RC" -ne 0 ]; then
        warn "iperf3 测试失败：$(tail -n 1 "$BBR_CAL_TEMP_FILE" 2>/dev/null)"
        rm -f "$BBR_CAL_TEMP_FILE"; BBR_CAL_TEMP_FILE=""
        return 1
    fi
    RESULT=$(bbr_calibration_parse_iperf "$BBR_CAL_TEMP_FILE" "$STREAMS") || {
        warn "未能解析 iperf3 sender/receiver 汇总"
        rm -f "$BBR_CAL_TEMP_FILE"; BBR_CAL_TEMP_FILE=""
        return 1
    }
    rm -f "$BBR_CAL_TEMP_FILE"; BBR_CAL_TEMP_FILE=""
    BBR_CAL_SENDER=${RESULT%% *}
    RESULT=${RESULT#* }
    BBR_CAL_RETRANS=${RESULT%% *}
    BBR_CAL_RECEIVER=${RESULT##* }
    BBR_CAL_LOSS=$(bbr_calibration_loss_pct "$BBR_CAL_RETRANS" "$BBR_CAL_SENDER" "$DURATION")
}

bbr_calibration_test_rate() {
    local RATE="$1" PEER="$2" PORT="$3" FAMILY="$4" DURATION="$5" BASELINE="${6:-0}"
    local HITS=0 CLEANS=0 ATTEMPT
    bbr_calibration_apply_shaper "$BBR_CAL_DEV" "$RATE" "$BBR_CAL_TC_BIN" || {
        error "无法应用 ${RATE}Mbps 临时整形或回读速率不一致"
        return 2
    }
    for ATTEMPT in 1 2 3; do
        [ "$ATTEMPT" -eq 1 ] || sleep 3
        bbr_calibration_measure "$PEER" "$PORT" "$FAMILY" "$DURATION" 1 \
            "${RATE}Mbps 样本 ${ATTEMPT}" || continue
        printf '  %-10s %12s %9s %9s\n' "${RATE}M" "${BBR_CAL_RECEIVER}M" "$BBR_CAL_RETRANS" "${BBR_CAL_LOSS}%"
        if bbr_calibration_is_spike "$BBR_CAL_LOSS" "$BASELINE"; then
            HITS=$(( HITS + 1 ))
            [ "$ATTEMPT" -lt 3 ] && continue
        else
            [ "$ATTEMPT" -eq 1 ] && return 0
            CLEANS=$(( CLEANS + 1 ))
            [ "$CLEANS" -ge 2 ] && return 0
        fi
    done
    [ "$HITS" -ge 2 ] && return 10
    [ "$CLEANS" -ge 2 ] && return 0
    return 2
}

bbr_calibration_traffic_mark() {
    local DEV="$1"
    BBR_CAL_TRAFFIC_RX0=$(cat "/sys/class/net/${DEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    BBR_CAL_TRAFFIC_TX0=$(cat "/sys/class/net/${DEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
}

bbr_calibration_traffic_report() {
    local DEV="$1" RX TX DRX DTX
    RX=$(cat "/sys/class/net/${DEV}/statistics/rx_bytes" 2>/dev/null || echo 0)
    TX=$(cat "/sys/class/net/${DEV}/statistics/tx_bytes" 2>/dev/null || echo 0)
    DRX=$(( RX - ${BBR_CAL_TRAFFIC_RX0:-0} )); [ "$DRX" -ge 0 ] || DRX=0
    DTX=$(( TX - ${BBR_CAL_TRAFFIC_TX0:-0} )); [ "$DTX" -ge 0 ] || DTX=0
    awk -v rx="$DRX" -v tx="$DTX" 'BEGIN {
        printf "  测试期间接口流量：上传 %.2f GB · 下载 %.2f GB · 合计 %.2f GB\n", \
            tx/1073741824, rx/1073741824, (tx+rx)/1073741824
    }'
}

bbr_calibration_write_result() {
    local STATUS="$1" PEER="$2" PORT="$3" FAMILY="$4" NOMINAL="$5" UNSHAPED="$6" KNEE="${7:-}" RECOMMEND="${8:-}" TMP
    mkdir -p "$(dirname "$BBR_CALIBRATION_RESULT_FILE")" 2>/dev/null || return 1
    TMP=$(mktemp "${BBR_CALIBRATION_RESULT_FILE}.tmp.XXXXXX") || return 1
    {
        printf 'TIMESTAMP=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'DEV=%s\nFAMILY=ipv%s\nPEER=%s\nPORT=%s\n' "$BBR_CAL_DEV" "$FAMILY" "$PEER" "$PORT"
        printf 'NOMINAL_MBPS=%s\nUNSHAPED_MBPS=%s\nSTATUS=%s\n' "$NOMINAL" "$UNSHAPED" "$STATUS"
        [ -z "$KNEE" ] || printf 'KNEE_MBPS=%s\n' "$KNEE"
        [ -z "$RECOMMEND" ] || printf 'RECOMMEND_MBPS=%s\n' "$RECOMMEND"
    } > "$TMP"
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 600 "$TMP" && mv "$TMP" "$BBR_CALIBRATION_RESULT_FILE" || { rm -f "$TMP"; return 1; }
}

bbr_calibration_show_last() {
    [ -s "$BBR_CALIBRATION_RESULT_FILE" ] || return 0
    local WHEN STATUS FAMILY PEER PORT NOMINAL UNSHAPED KNEE RECOMMEND
    WHEN=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" TIMESTAMP 2>/dev/null || true)
    STATUS=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" STATUS 2>/dev/null || true)
    FAMILY=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" FAMILY 2>/dev/null || true)
    PEER=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" PEER 2>/dev/null || true)
    PORT=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" PORT 2>/dev/null || true)
    NOMINAL=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" NOMINAL_MBPS 2>/dev/null || true)
    UNSHAPED=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" UNSHAPED_MBPS 2>/dev/null || true)
    KNEE=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" KNEE_MBPS 2>/dev/null || true)
    RECOMMEND=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" RECOMMEND_MBPS 2>/dev/null || true)
    echo -e "  ${BOLD}最近线路校准${NC}"
    echo -e "  ${WHEN:-未知时间} · ${FAMILY:-未知协议族} · ${PEER:-未知}:${PORT:-?}"
    echo -e "  状态 ${BOLD}${STATUS:-UNKNOWN}${NC} · 标称 ${NOMINAL:-?}Mbps · 不限速送达 ${UNSHAPED:-?}Mbps"
    [ -z "$KNEE" ] || echo -e "  干净上限 ${BOLD}${KNEE}Mbps${NC} · 建议 HTB ${GREEN}${BOLD}${RECOMMEND}Mbps${NC}"
}

bbr_calibration_finish() {
    quench_restore_signal_traps
    bbr_calibration_stop_child
    [ -z "$BBR_CAL_TEMP_FILE" ] || rm -f "$BBR_CAL_TEMP_FILE"
    if bbr_calibration_restore_qdisc; then
        info "测试前 qdisc 已恢复"
    else
        error "测试前 qdisc 恢复失败，请立即运行网络性能诊断"
    fi
    bbr_calibration_traffic_report "$BBR_CAL_DEV"
    bbr_calibration_lock_release
}

bbr_calibration_run() {
    local PEER="$1" PORT="$2" FAMILY="$3" NOMINAL="$4" DURATION="$5"
    local ATTEMPT BEST_RECEIVER="" BEST_SENDER="" BEST_RETRANS="" BEST_LOSS=""
    local THRESHOLD=0.1 LOW HIGH FACTOR_HIGH NOMINAL_HIGH IDX RATE LAST_RATE=""
    local BASELINE="" LAST_CLEAN="" BROKE_AT="" SLOW_HITS=0 TEST_RC=0 CONTROL
    local FINE_LIMIT KNEE MARGIN RECOMMEND ANSWER STATUS=""

    BBR_CAL_DEV=$(default_iface)
    [ -n "$BBR_CAL_DEV" ] || { error "无法确定默认出口网卡"; return 1; }
    BBR_CAL_TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$BBR_CAL_TC_BIN" ] || { error "tc 命令不可用，请先安装 iproute2"; return 1; }
    bbr_calibration_lock_acquire || return 1
    if ! bbr_calibration_capture_qdisc "$BBR_CAL_DEV" "$BBR_CAL_TC_BIN"; then
        bbr_calibration_lock_release
        return 1
    fi
    bbr_calibration_traffic_mark "$BBR_CAL_DEV"
    trap 'bbr_calibration_interrupt' INT TERM HUP

    if ! bbr_calibration_set_fq "$BBR_CAL_DEV" "$BBR_CAL_TC_BIN"; then
        error "无法临时启用 fq pacing"
        bbr_calibration_finish
        return 1
    fi

    for ATTEMPT in 1 2 3; do
        bbr_calibration_measure "$PEER" "$PORT" "$FAMILY" "$DURATION" 1 "不限速基线 ${ATTEMPT}" || continue
        echo -e "  不限速样本：接收 ${BOLD}${BBR_CAL_RECEIVER}Mbps${NC} · 重传 ${BBR_CAL_RETRANS} · 估算损失 ${BBR_CAL_LOSS}%"
        if [ -z "$BEST_RECEIVER" ] || awk -v now="$BBR_CAL_RECEIVER" -v best="$BEST_RECEIVER" 'BEGIN {exit !(now > best)}'; then
            BEST_RECEIVER=$BBR_CAL_RECEIVER; BEST_SENDER=$BBR_CAL_SENDER
            BEST_RETRANS=$BBR_CAL_RETRANS; BEST_LOSS=$BBR_CAL_LOSS
        fi
        if awk -v now="$BBR_CAL_RECEIVER" -v nominal="$NOMINAL" 'BEGIN {exit !(now >= nominal*0.7)}'; then
            break
        fi
    done
    if [ -z "$BEST_RECEIVER" ]; then
        error "三次不限速测试均失败，请检查对端端口、防火墙和 iperf3 服务"
        bbr_calibration_write_result ERROR "$PEER" "$PORT" "$FAMILY" "$NOMINAL" 0 || true
        bbr_calibration_finish
        return 1
    fi
    BBR_CAL_RECEIVER=$BEST_RECEIVER; BBR_CAL_SENDER=$BEST_SENDER
    BBR_CAL_RETRANS=$BEST_RETRANS; BBR_CAL_LOSS=$BEST_LOSS

    if awk -v good="$BEST_RECEIVER" -v nominal="$NOMINAL" 'BEGIN {exit !(good < nominal*0.7)}'; then
        info "单流低于标称带宽 70%，增加一次 4 流对照，排除单流窗口或远端限制"
        if bbr_calibration_measure "$PEER" "$PORT" "$FAMILY" "$DURATION" 4 "不限速 4 流对照"; then
            echo -e "  4 流样本：接收 ${BOLD}${BBR_CAL_RECEIVER}Mbps${NC} · 重传 ${BBR_CAL_RETRANS} · 估算损失 ${BBR_CAL_LOSS}%"
            if awk -v now="$BBR_CAL_RECEIVER" -v best="$BEST_RECEIVER" 'BEGIN {exit !(now > best)}'; then
                BEST_RECEIVER=$BBR_CAL_RECEIVER; BEST_SENDER=$BBR_CAL_SENDER
                BEST_RETRANS=$BBR_CAL_RETRANS; BEST_LOSS=$BBR_CAL_LOSS
            fi
        fi
    fi

    if awk -v good="$BEST_RECEIVER" -v nominal="$NOMINAL" 'BEGIN {exit !(good < nominal*0.7)}' \
        && ! bbr_calibration_is_spike "$BEST_LOSS" 0 "$THRESHOLD"; then
        warn "对端或路径只能稳定送达 ${BEST_RECEIVER}Mbps，未达到标称带宽的 70%"
        warn "结果不足以区分本机限速与远端瓶颈，不会生成整形值"
        bbr_calibration_write_result INCONCLUSIVE "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
        bbr_calibration_finish
        return 2
    fi

    if ! bbr_calibration_is_spike "$BEST_LOSS" 0 "$THRESHOLD"; then
        info "不限速时损失率 ${BEST_LOSS}%：未检测到上游 policer"
        echo -e "  ${BOLD}建议：保留 BBR/fq，不增加 HTB 聚合上限。${NC}"
        bbr_calibration_write_result NO_KNEE "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
        bbr_calibration_finish
        if [ -s "$TC_STATE_FILE" ]; then
            read -rp "  当前存在 Quench HTB 限速，是否取消？(y/N，默认N): " ANSWER
            [ -n "$ANSWER" ] || ANSWER=n
            echo "$ANSWER" | grep -qiE '^y(es)?$' && bbr_tc_remove_selected "$BBR_CAL_DEV"
        fi
        return 0
    fi

    LOW=$(awk -v good="$BEST_RECEIVER" 'BEGIN {v=int(good*0.90); if(v<1)v=1; print v}')
    FACTOR_HIGH=$(awk -v good="$BEST_RECEIVER" -v loss="$BEST_LOSS" 'BEGIN {
        factor=1.25+loss/100*2; if(factor>2.5)factor=2.5
        printf "%d", good*factor
    }')
    NOMINAL_HIGH=$(( NOMINAL * 120 / 100 ))
    HIGH=$FACTOR_HIGH; [ "$HIGH" -ge "$NOMINAL_HIGH" ] || HIGH=$NOMINAL_HIGH
    [ "$HIGH" -le $(( NOMINAL * 2 )) ] || HIGH=$(( NOMINAL * 2 ))
    [ "$HIGH" -gt "$LOW" ] || HIGH=$(( LOW + 2 ))
    echo ""
    warn "不限速测试存在明显重传，开始寻找 policer 拐点"
    echo -e "  扫描区间：${BOLD}${LOW}-${HIGH}Mbps${NC} · 粗扫约 7 档 · 阈值 ${THRESHOLD}%"
    printf '  %-10s %12s %9s %9s\n' "目标" "接收" "重传" "损失"
    for IDX in 0 1 2 3 4 5 6; do
        RATE=$(( LOW + (HIGH - LOW) * IDX / 6 ))
        [ "$RATE" != "$LAST_RATE" ] || continue
        LAST_RATE=$RATE
        TEST_RC=0
        bbr_calibration_test_rate "$RATE" "$PEER" "$PORT" "$FAMILY" "$DURATION" "${BASELINE:-0}" || TEST_RC=$?
        if [ "$TEST_RC" -eq 10 ]; then
            if [ -z "$LAST_CLEAN" ]; then
                CONTROL=$(( RATE * 3 / 4 )); [ "$CONTROL" -ge 1 ] || CONTROL=1
                info "首档即出现重传跳变，向下测试 ${CONTROL}Mbps 控制点"
                TEST_RC=0
                bbr_calibration_test_rate "$CONTROL" "$PEER" "$PORT" "$FAMILY" "$DURATION" 0 || TEST_RC=$?
                if [ "$TEST_RC" -eq 0 ]; then
                    LAST_CLEAN=$CONTROL; BASELINE=$BBR_CAL_LOSS; BROKE_AT=$RATE
                else
                    warn "低速控制点仍有明显损失，无法安全归因于端口 policer"
                    STATUS=INCONCLUSIVE
                    break
                fi
            else
                BROKE_AT=$RATE
            fi
            break
        elif [ "$TEST_RC" -ne 0 ]; then
            STATUS=ERROR
            break
        fi
        LAST_CLEAN=$RATE
        [ -n "$BASELINE" ] || BASELINE=$BBR_CAL_LOSS
        if awk -v good="$BBR_CAL_RECEIVER" -v rate="$RATE" -v loss="$BBR_CAL_LOSS" \
            'BEGIN {exit !(good < rate*0.7 && loss <= 0.1)}'; then
            SLOW_HITS=$(( SLOW_HITS + 1 ))
            if [ "$SLOW_HITS" -ge 2 ]; then
                warn "连续两档吞吐远低于整形目标且没有重传，对端性能不足"
                STATUS=INCONCLUSIVE
                break
            fi
        else
            SLOW_HITS=0
        fi
    done

    if [ -n "$STATUS" ]; then
        bbr_calibration_write_result "$STATUS" "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
        bbr_calibration_finish
        return 2
    fi
    if [ -z "$BROKE_AT" ]; then
        warn "扫到 ${HIGH}Mbps 仍未定位拐点，但不限速样本存在损失"
        warn "可能是路径底噪、对端拥塞或拐点超出范围，不会猜测整形值"
        bbr_calibration_write_result OUT_OF_RANGE "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
        bbr_calibration_finish
        return 2
    fi
    if [ -z "$LAST_CLEAN" ]; then
        warn "没有获得可用的干净速率，不会生成整形值"
        bbr_calibration_write_result INCONCLUSIVE "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
        bbr_calibration_finish
        return 2
    fi

    FINE_LIMIT=$(( NOMINAL / 200 )); [ "$FINE_LIMIT" -ge 1 ] || FINE_LIMIT=1
    for IDX in 1 2 3 4; do
        [ $(( BROKE_AT - LAST_CLEAN )) -gt "$FINE_LIMIT" ] || break
        RATE=$(( (BROKE_AT + LAST_CLEAN) / 2 ))
        [ "$RATE" -gt "$LAST_CLEAN" ] && [ "$RATE" -lt "$BROKE_AT" ] || break
        info "细扫 ${LAST_CLEAN}-${BROKE_AT}Mbps：测试 ${RATE}Mbps"
        TEST_RC=0
        bbr_calibration_test_rate "$RATE" "$PEER" "$PORT" "$FAMILY" "$DURATION" "${BASELINE:-0}" || TEST_RC=$?
        if [ "$TEST_RC" -eq 10 ]; then
            BROKE_AT=$RATE
        elif [ "$TEST_RC" -eq 0 ]; then
            LAST_CLEAN=$RATE
        else
            warn "细扫测试失败，不会使用不完整结果"
            bbr_calibration_write_result ERROR "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" || true
            bbr_calibration_finish
            return 2
        fi
    done

    KNEE=$LAST_CLEAN
    MARGIN=$(bbr_calibration_margin "$KNEE") || MARGIN=1
    RECOMMEND=$(( KNEE - MARGIN )); [ "$RECOMMEND" -ge 1 ] || RECOMMEND=$KNEE
    bbr_calibration_write_result KNEE "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$BEST_RECEIVER" "$KNEE" "$RECOMMEND" || true
    bbr_calibration_finish
    echo ""
    info "实测干净上限 ${KNEE}Mbps，下一档 ${BROKE_AT}Mbps 出现重传跳变"
    echo -e "  建议退让 ${BOLD}${MARGIN}Mbps${NC} → HTB ${GREEN}${BOLD}${RECOMMEND}Mbps${NC}"
    read -rp "  是否应用建议整形值？(Y/n，默认Y): " ANSWER
    [ -n "$ANSWER" ] || ANSWER=y
    echo "$ANSWER" | grep -qiE '^y(es)?$' || { warn "已保留测量结果，未修改持久化整形"; return; }
    bbr_tc_apply_selected_rate "$BBR_CAL_DEV" "$RECOMMEND"
}

bbr_menu_calibration() {
    print_header "线路实测与 policer 拐点校准"
    [ "$(id -u)" -eq 0 ] || { error "线路校准需要 root 权限"; return 1; }
    if ! command -v iperf3 >/dev/null 2>&1; then
        read -rp "  需要安装 iperf3，是否安装？(Y/n，默认Y): " INSTALL
        [ -n "$INSTALL" ] || INSTALL=y
        echo "$INSTALL" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
        pkg_install iperf3 || { error "iperf3 安装失败，请手动安装后重试"; return 1; }
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        pkg_install coreutils || { error "缺少 timeout，无法为测速设置硬超时"; return 1; }
    fi

    echo -e "  ${DIM}请优先使用同地区、带宽高于本机的自有 iperf3 服务端。${NC}"
    echo -e "  ${DIM}对端启动示例：iperf3 -s；第三方公共节点可能繁忙或限流。${NC}"
    local PEER PORT FAMILY NOMINAL_INPUT NOMINAL DURATION CH ESTIMATE CONFIRM
    read -rp "  iperf3 对端主机或 IP: " PEER
    bbr_calibration_host_valid "$PEER" || { error "对端格式无效"; return 1; }
    read -rp "  对端端口（默认 5201）: " PORT
    [ -n "$PORT" ] || PORT=5201
    bbr_calibration_port_valid "$PORT" || { error "端口必须是 1-65535"; return 1; }
    echo ""
    menu_pair "1" "IPv4（默认）" "2" "IPv6"
    read -rp "$(ui_prompt '选择协议族 [1-2]: ')" CH
    case "$CH" in ""|1) FAMILY=4 ;; 2) FAMILY=6 ;; *) error "无效协议族"; return 1 ;; esac
    read -rp "  套餐/预期带宽（默认 Mbps，可用 M/G）: " NOMINAL_INPUT
    NOMINAL=$(bbr_parse_bandwidth_mbps "$NOMINAL_INPUT") \
        || { error "无效带宽；示例：400、600M、1.5G"; return 1; }
    echo ""
    menu_pair "1" "8 秒/档（推荐）" "2" "12 秒/档（更稳）"
    read -rp "$(ui_prompt '选择单档时长 [1-2]: ')" CH
    case "$CH" in ""|1) DURATION=8 ;; 2) DURATION=12 ;; *) error "无效时长"; return 1 ;; esac
    ESTIMATE=$(bbr_calibration_estimate_gb "$NOMINAL" "$DURATION")
    echo ""
    warn "校准会短暂替换出口 qdisc，并主动发送高带宽 TCP 流量"
    echo -e "  最坏流量估算：${YELLOW}${BOLD}约 ${ESTIMATE} GB${NC}  ${DIM}实际通常更低，按接口计数器复核${NC}"
    echo -e "  对端：${BOLD}${PEER}:${PORT}${NC} · IPv${FAMILY} · 标称 ${NOMINAL}Mbps · ${DURATION}s/档"
    read -rp "  确认开始？(y/N，默认N): " CONFIRM
    [ -n "$CONFIRM" ] || CONFIRM=n
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    bbr_calibration_run "$PEER" "$PORT" "$FAMILY" "$NOMINAL" "$DURATION"
}

# ── tc 智能整形菜单 ───────────────────────────────────────
bbr_parse_bandwidth_mbps() {
    local RAW NUMBER MULTIPLIER
    RAW=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]//g')
    case "$RAW" in
        *gbps) NUMBER=${RAW%gbps}; MULTIPLIER=1000 ;;
        *gbit) NUMBER=${RAW%gbit}; MULTIPLIER=1000 ;;
        *g)    NUMBER=${RAW%g};    MULTIPLIER=1000 ;;
        *mbps) NUMBER=${RAW%mbps}; MULTIPLIER=1 ;;
        *mbit) NUMBER=${RAW%mbit}; MULTIPLIER=1 ;;
        *m)    NUMBER=${RAW%m};    MULTIPLIER=1 ;;
        *)     NUMBER=$RAW;        MULTIPLIER=1 ;;
    esac
    printf '%s\n' "$NUMBER" | grep -qE '^([0-9]+([.][0-9]*)?|[.][0-9]+)$' || return 1
    awk -v number="$NUMBER" -v multiplier="$MULTIPLIER" 'BEGIN {
        value = int(number * multiplier + 0.000001)
        if (value < 1 || value > 100000) exit 1
        print value
    }'
}

bbr_shaping_rate_mbps() {
    local LINE_RATE="$1" PERCENT="$2"
    case "$LINE_RATE:$PERCENT" in *[!0-9:]*) return 1 ;; esac
    [ "$LINE_RATE" -ge 1 ] && [ "$PERCENT" -ge 1 ] && [ "$PERCENT" -le 100 ] || return 1
    local RATE=$(( LINE_RATE * PERCENT / 100 ))
    [ "$RATE" -ge 1 ] || RATE=1
    printf '%s\n' "$RATE"
}

bbr_tc_link_speed_reference() {
    local DEV="$1" SPEED=""
    [ -r "/sys/class/net/${DEV}/speed" ] && SPEED=$(cat "/sys/class/net/${DEV}/speed" 2>/dev/null || true)
    if ! printf '%s\n' "$SPEED" | grep -qE '^[0-9]+$' || [ "$SPEED" -le 0 ]; then
        SPEED=$(ethtool "$DEV" 2>/dev/null | awk -F: '/^[[:space:]]*Speed:/ { gsub(/[[:space:]]|Mb\/s/, "", $2); print $2; exit }')
    fi
    if printf '%s\n' "$SPEED" | grep -qE '^[0-9]+$' && [ "$SPEED" -gt 0 ]; then
        printf '%s Mbit（仅 vNIC 参考，不等于套餐带宽）\n' "$SPEED"
    else
        printf '未知（请以套餐或实测速率为准）\n'
    fi
}

bbr_tc_apply_selected_rate() {
    local DEV="$1" RATE="$2" APPLY_RC TC_BIN
    bbr_apply_tc "$RATE"
    APPLY_RC=$?
    if [ "$APPLY_RC" -eq 2 ]; then
        TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
        bbr_tc_force_confirm "$DEV" "$RATE" "$TC_BIN" || return
        bbr_apply_tc "$RATE" 1
    elif [ "$APPLY_RC" -ne 0 ]; then
        return "$APPLY_RC"
    fi
}

bbr_tc_remove_selected() {
    local DEV="$1" REMOVE_RC TC_BIN
    bbr_remove_tc
    REMOVE_RC=$?
    if [ "$REMOVE_RC" -eq 2 ]; then
        TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
        bbr_tc_remove_confirm "$DEV" "$TC_BIN" || return
        bbr_remove_tc 1
    elif [ "$REMOVE_RC" -ne 0 ]; then
        return "$REMOVE_RC"
    fi
}

bbr_tc_show_stats() {
    local DEV="$1" TC_BIN SAVED_VALUES SAVED_RATE CLASS_OUTPUT ACTUAL
    TC_BIN=$(command -v tc 2>/dev/null || true)
    [ -n "$TC_BIN" ] || { error "tc 命令不可用，请先安装 iproute2"; return 1; }
    CLASS_OUTPUT=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    ACTUAL=$(bbr_tc_rate_mbps_from_output "$CLASS_OUTPUT" 2>/dev/null || true)
    SAVED_VALUES=$(bbr_tc_saved_values 2>/dev/null || true)
    if [ -n "$SAVED_VALUES" ]; then
        SAVED_RATE=${SAVED_VALUES#* }; SAVED_RATE=${SAVED_RATE%% *}
        if [ -n "$ACTUAL" ] && bbr_tc_rate_matches "$DEV" "$TC_BIN" "$SAVED_RATE"; then
            info "HTB 速率回读一致：请求 ${SAVED_RATE}Mbps · 实际 ${ACTUAL}Mbps"
        elif [ -n "$ACTUAL" ]; then
            warn "HTB 速率回读不一致：请求 ${SAVED_RATE}Mbps · 实际 ${ACTUAL}Mbps"
        else
            warn "已保存 ${SAVED_RATE}Mbps，但没有读到 Quench HTB class 速率"
        fi
        echo ""
    elif [ -n "$ACTUAL" ]; then
        echo -e "  ${DIM}检测到未登记的 HTB 速率：${ACTUAL}Mbps${NC}"
        echo ""
    fi
    bbr_calibration_show_last
    [ ! -s "$BBR_CALIBRATION_RESULT_FILE" ] || echo ""
    echo -e "  ${BOLD}qdisc 统计${NC}"
    "$TC_BIN" -s qdisc show dev "$DEV" 2>/dev/null || warn "无法读取 qdisc 统计"
    echo ""
    echo -e "  ${BOLD}class 统计${NC}"
    "$TC_BIN" -s class show dev "$DEV" 2>/dev/null || true
}

bbr_tc_smart_rate() {
    local CH INPUT LINE_RATE PERCENT RATE
    print_header "tc 智能整形 — 线路带宽"
    echo -e "  ${DIM}按十进制换算：1G = 1000M。这里填写套餐带宽或稳定实测上限。${NC}"
    echo ""
    menu_pair "1" "100 Mbit" "2" "200 Mbit"
    menu_pair "3" "300 Mbit" "4" "400 Mbit"
    menu_pair "5" "500 Mbit" "6" "600 Mbit"
    menu_pair "7" "800 Mbit" "8" "1 Gbit"
    menu_pair "9" "2 Gbit" "10" "2.5 Gbit"
    menu_pair "11" "5 Gbit" "12" "10 Gbit"
    menu_item "c" "自定义输入  ${DIM}如 400、600M、1.5G、2.5G${NC}"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择带宽档位: ')" CH
    case "$CH" in
        1) LINE_RATE=100 ;; 2) LINE_RATE=200 ;; 3) LINE_RATE=300 ;; 4) LINE_RATE=400 ;;
        5) LINE_RATE=500 ;; 6) LINE_RATE=600 ;; 7) LINE_RATE=800 ;; 8) LINE_RATE=1000 ;;
        9) LINE_RATE=2000 ;; 10) LINE_RATE=2500 ;; 11) LINE_RATE=5000 ;; 12) LINE_RATE=10000 ;;
        c|C)
            read -rp "  输入线路带宽（默认单位 Mbps，可用 M/G）: " INPUT
            LINE_RATE=$(bbr_parse_bandwidth_mbps "$INPUT") || { error "无效带宽；示例：400、600M、1.5G"; return 1; }
            ;;
        0) return 2 ;;
        *) warn "无效选项"; return 1 ;;
    esac

    echo ""
    menu_item "1" "95% · 稳定  ${DIM}波动线路推荐${NC}"
    menu_item "2" "97% · 推荐  ${DIM}性能与余量平衡${NC}"
    menu_item "3" "99% · 极限  ${DIM}线路稳定时使用${NC}" "$YELLOW"
    menu_item "c" "自定义比例（50-100%）"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择整形比例: ')" CH
    case "$CH" in
        1) PERCENT=95 ;; 2) PERCENT=97 ;; 3) PERCENT=99 ;;
        c|C)
            read -rp "  输入比例（50-100）: " PERCENT
            printf '%s\n' "$PERCENT" | grep -qE '^[0-9]+$' \
                && [ "$PERCENT" -ge 50 ] && [ "$PERCENT" -le 100 ] \
                || { error "比例必须是 50-100 的整数"; return 1; }
            ;;
        0) return 2 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    RATE=$(bbr_shaping_rate_mbps "$LINE_RATE" "$PERCENT") || return 1
    BBR_TC_LINE_RATE=$LINE_RATE
    BBR_TC_PERCENT=$PERCENT
    BBR_TC_RATE=$RATE
}

bbr_menu_tc() {
    print_header "tc 出口智能整形"
    if is_openvz; then
        warn "检测到 OpenVZ/LXC 共享内核环境，tc 通常由宿主机限制"
        return
    fi

    local DEV TC_BIN QDISCS ROOT_LINE QTYPE CUR LINK_REF CH RESULT LINE_RATE PERCENT RATE CONFIRM
    DEV=$(default_iface)
    [ -n "$DEV" ] || { error "无法确定默认出口网卡"; return 1; }
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    QTYPE=$(bbr_tc_qdisc_type "$ROOT_LINE"); [ -n "$QTYPE" ] || QTYPE="未知"
    CUR=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    LINK_REF=$(bbr_tc_link_speed_reference "$DEV")
    echo -e "  网卡：${BOLD}${DEV}${NC}  root qdisc：${BOLD}${QTYPE}${NC}  当前整形：${BOLD}${CUR}${NC}"
    echo -e "  接口速率：${BOLD}${LINK_REF}${NC}"
    echo ""
    menu_div
    menu_item "1" "线路实测校准  ${DIM}iperf3 寻找 policer 拐点，推荐${NC}"
    menu_item "2" "按比例整形  ${DIM}线路带宽 × 95/97/99%${NC}"
    menu_item "3" "精确设置  ${DIM}直接填写最终 tc rate${NC}"
    menu_item "4" "查看当前 qdisc、回读速率与统计"
    menu_item "5" "取消本工具限速" "$YELLOW"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH
    case "$CH" in
        1) bbr_menu_calibration; return ;;
        2)
            bbr_tc_smart_rate; case $? in 2) return ;; 0) : ;; *) return 1 ;; esac
            LINE_RATE=$BBR_TC_LINE_RATE
            PERCENT=$BBR_TC_PERCENT
            RATE=$BBR_TC_RATE
            echo -e "  线路带宽 ${BOLD}${LINE_RATE}Mbit${NC} × ${BOLD}${PERCENT}%${NC} → tc ${BOLD}${RATE}Mbit${NC}"
            ;;
        3)
            read -rp "  输入最终整形速率（默认 Mbps，可用 M/G）: " RESULT
            RATE=$(bbr_parse_bandwidth_mbps "$RESULT") || { error "无效速率；示例：400、600M、1.5G"; return 1; }
            echo -e "  将直接设置 tc rate：${BOLD}${RATE}Mbit${NC}（不再乘比例）"
            ;;
        4) bbr_tc_show_stats "$DEV"; return ;;
        5) bbr_tc_remove_selected "$DEV"; return ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    read -rp "  确认应用到 ${DEV}？(Y/n，默认Y): " CONFIRM
    [ -n "$CONFIRM" ] || CONFIRM=y
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    bbr_tc_apply_selected_rate "$DEV" "$RATE"
}

# ── initcwnd 菜单 ─────────────────────────────────────────
# 检测是否在 LXC 容器内

# 检测 OpenVZ / LXC 等受限容器
is_openvz() {
    [ -f /proc/vz/veinfo ] && return 0
    grep -qaE 'openvz|lxc' /proc/1/environ 2>/dev/null && return 0
    grep -qaE 'openvz|lxc' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

is_lxc() {
    grep -qa "lxc" /proc/1/environ 2>/dev/null     || [ -f /run/systemd/container ]     || grep -qa "container=lxc" /proc/1/environ 2>/dev/null     || { [ -f /proc/1/cgroup ] && grep -qa "lxc" /proc/1/cgroup 2>/dev/null; }
}

bbr_default_routes() {
    local ROUTE
    ROUTE=$(ip -4 route show default 2>/dev/null | head -1)
    [ -z "$ROUTE" ] || printf '4|%s\n' "$ROUTE"
    ROUTE=$(ip -6 route show default 2>/dev/null | head -1)
    [ -z "$ROUTE" ] || printf '6|%s\n' "$ROUTE"
}

bbr_route_token() {
    local ROUTE="$1" TOKEN="$2"
    awk -v token="$TOKEN" '{ for (i=1; i<=NF; i++) if ($i == token) { print $(i+1); exit } }' <<< "$ROUTE"
}

bbr_route_strip_cwnd() {
    awk '
        {
            out=""
            for (i=1; i<=NF; i++) {
                if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
                out = out (out == "" ? "" : " ") $i
            }
            print out
        }
    ' <<< "$1"
}

bbr_apply_initcwnd_route() {
    local FAMILY="$1" ROUTE="$2" VAL="$3" RWND="${4:-0}" BASE_ROUTE
    local -a ROUTE_ARGS
    BASE_ROUTE=$(bbr_route_strip_cwnd "$ROUTE")
    read -r -a ROUTE_ARGS <<< "$BASE_ROUTE"
    [ "${ROUTE_ARGS[0]:-}" = default ] || return 1
    if [ "$RWND" -gt 0 ] 2>/dev/null; then
        ip "-${FAMILY}" route replace "${ROUTE_ARGS[@]}" initcwnd "$VAL" initrwnd "$RWND"
    else
        ip "-${FAMILY}" route replace "${ROUTE_ARGS[@]}" initcwnd "$VAL"
    fi
}

bbr_restore_initcwnd_route() {
    local FAMILY="$1" ROUTE="$2" BASE_ROUTE
    local -a ROUTE_ARGS
    BASE_ROUTE=$(bbr_route_strip_cwnd "$ROUTE")
    read -r -a ROUTE_ARGS <<< "$BASE_ROUTE"
    [ "${ROUTE_ARGS[0]:-}" = default ] || return 1
    ip "-${FAMILY}" route replace "${ROUTE_ARGS[@]}"
}

bbr_cwnd_write_persistence() {
    local FAMILIES="$1" VAL="$2" RWND="${3:-0}" TMP
    mkdir -p "$(dirname "$CWND_HELPER")" "$(dirname "$CWND_STATE_FILE")" 2>/dev/null || return 1
    TMP=$(mktemp "${CWND_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'FAMILIES=%s\nVALUE=%s\nINITRWND=%s\n' "$(printf '%s' "$FAMILIES" | tr ' ' ',')" "$VAL" "$RWND" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 600 "$TMP" && mv "$TMP" "$CWND_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${CWND_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'CWND_HELPER_EOF'
#!/bin/sh
STATE=/var/lib/quench/initcwnd.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
FAMILIES=$(state_value FAMILIES | tr ',' ' ')
VALUE=$(state_value VALUE)
INITRWND=$(state_value INITRWND)
echo "$VALUE" | grep -qE '^[0-9]+$' || exit 1
echo "$INITRWND" | grep -qE '^[0-9]+$' || INITRWND=0
strip_route() {
    awk '{
        out=""
        for (i=1; i<=NF; i++) {
            if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
            out = out (out == "" ? "" : " ") $i
        }
        print out
    }'
}
apply_one() {
    FAMILY=$1
    ROUTE=$(ip "-${FAMILY}" route show default 2>/dev/null | head -1 | strip_route)
    [ -n "$ROUTE" ] || return 1
    # shellcheck disable=SC2086
    set -- $ROUTE
    [ "${1:-}" = default ] || return 1
    if [ "$INITRWND" -gt 0 ]; then
        ip "-${FAMILY}" route replace "$@" initcwnd "$VALUE" initrwnd "$INITRWND"
    else
        ip "-${FAMILY}" route replace "$@" initcwnd "$VALUE"
    fi
}
remove_one() {
    FAMILY=$1
    ROUTE=$(ip "-${FAMILY}" route show default 2>/dev/null | head -1 | strip_route)
    [ -n "$ROUTE" ] || return 0
    # shellcheck disable=SC2086
    set -- $ROUTE
    [ "${1:-}" = default ] || return 1
    ip "-${FAMILY}" route replace "$@"
}
case "${1:-apply}" in
    apply)
        FAILED=0
        for FAMILY in $FAMILIES; do case "$FAMILY" in 4|6) apply_one "$FAMILY" || FAILED=1 ;; *) FAILED=1 ;; esac; done
        exit "$FAILED"
        ;;
    remove)
        FAILED=0
        for FAMILY in $FAMILIES; do case "$FAMILY" in 4|6) remove_one "$FAMILY" || FAILED=1 ;; *) FAILED=1 ;; esac; done
        exit "$FAILED"
        ;;
    status)
        for FAMILY in $FAMILIES; do
            case "$FAMILY" in 4|6) : ;; *) exit 1 ;; esac
            ip "-${FAMILY}" route show default 2>/dev/null | grep -q "initcwnd ${VALUE}" || exit 1
        done
        exit 0
        ;;
    *) exit 2 ;;
esac
CWND_HELPER_EOF
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    chmod 700 "$TMP" && mv "$TMP" "$CWND_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_CWND}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=Quench TCP initcwnd
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${CWND_HELPER} apply
ExecStop=${CWND_HELPER} remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_CWND" || { rm -f "$TMP"; return 1; }
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable initcwnd --quiet >/dev/null 2>&1 \
            && systemctl restart initcwnd >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" openrc || return 1
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        rc-update add initcwnd default >/dev/null 2>&1 \
            && rc-service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" sysv || return 1
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        update-rc.d initcwnd defaults >/dev/null 2>&1 \
            && service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "initcwnd 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_remove_initcwnd() {
    local FAMILY ROUTE FAILED=0
    while IFS='|' read -r FAMILY ROUTE; do
        [ -n "$FAMILY" ] || continue
        bbr_restore_initcwnd_route "$FAMILY" "$ROUTE" || FAILED=1
    done < <(bbr_default_routes)

    if systemd_available; then
        systemctl disable --now initcwnd >/dev/null 2>&1 || true
        rm -f "$SERVICE_CWND"
        systemctl daemon-reload >/dev/null 2>&1 || FAILED=1
    elif command -v rc-update >/dev/null 2>&1; then
        rc-service initcwnd stop >/dev/null 2>&1 || true
        rc-update del initcwnd default >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null 2>&1; then
        service initcwnd stop >/dev/null 2>&1 || true
        update-rc.d -f initcwnd remove >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_CWND_INIT" "$CWND_HELPER" "$CWND_STATE_FILE"
    if [ "$FAILED" -ne 0 ]; then
        error "部分默认路由无法恢复；持久化配置已移除"
        return 1
    fi
    info "initcwnd/initrwnd 已恢复为内核默认，持久化配置已移除 ✓"
}

bbr_menu_initcwnd() {
    print_header "initcwnd 设置"

    # ── LXC 检测 ───────────────────────────────────────────
    if is_lxc; then
        echo ""
        warn "检测到当前运行于 ${BOLD}LXC 容器${NC} 中"
        warn "LXC 容器没有独立网络命名空间权限，无法执行 ip route change"
        echo ""
        echo -e "  ${DIM}initcwnd 需要在宿主机或独立网络命名空间（如 KVM/独立VPS）中设置${NC}"
        echo -e "  ${DIM}如需设置，请在宿主机执行：${NC}"
        echo -e "  ${CYAN}  ip route replace default ... initcwnd 50${NC}"
        echo ""
        return
    fi

    local ROUTES ROUTE4 ROUTE6 FAMILIES FAMILY ROLLBACK_FAMILY ROUTE DEV GW CH VAL RWND=0 ANSWER APPLIED="" CUR
    ROUTES=$(bbr_default_routes)
    [ -n "$ROUTES" ] || {
        error "未找到 IPv4 或 IPv6 默认路由"
        return 1
    }
    ROUTE4=$(printf '%s\n' "$ROUTES" | awk -F'|' '$1 == 4 { sub(/^[^|]*\|/, ""); print; exit }')
    ROUTE6=$(printf '%s\n' "$ROUTES" | awk -F'|' '$1 == 6 { sub(/^[^|]*\|/, ""); print; exit }')
    if [ -n "$ROUTE4" ]; then
        CUR=$(bbr_route_token "$ROUTE4" initcwnd); [ -n "$CUR" ] || CUR="内核默认"
        echo -e "  IPv4：${BOLD}$(bbr_route_token "$ROUTE4" dev)${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    fi
    if [ -n "$ROUTE6" ]; then
        CUR=$(bbr_route_token "$ROUTE6" initcwnd); [ -n "$CUR" ] || CUR="内核默认"
        echo -e "  IPv6：${BOLD}$(bbr_route_token "$ROUTE6" dev)${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    fi
    echo ""
    menu_div
    menu_item "1" "10 · 保守"
    menu_item "2" "50 · 激进，跨国高延迟"
    menu_item "3" "100 · 实验性，可能突发丢包" "$YELLOW"
    menu_item "4" "自定义输入"
    menu_item "5" "恢复内核默认  ${DIM}移除 initcwnd/initrwnd${NC}" "$YELLOW"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择 initcwnd [0-5]: ')" CH

    case "$CH" in
        1) VAL=10 ;;
        2) VAL=50 ;;
        3) VAL=100 ;;
        4)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        5) bbr_remove_initcwnd; return ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ -n "$ROUTE4" ] && [ -n "$ROUTE6" ]; then
        echo ""
        menu_item "1" "仅 IPv4"
        menu_item "2" "仅 IPv6"
        menu_item "3" "IPv4 + IPv6"
        read -rp "$(ui_prompt '选择应用协议 [1-3]: ')" ANSWER
        case "$ANSWER" in 1) FAMILIES=4 ;; 2) FAMILIES=6 ;; 3) FAMILIES="4 6" ;; *) error "无效选项"; return 1 ;; esac
    elif [ -n "$ROUTE4" ]; then
        FAMILIES=4
    else
        FAMILIES=6
    fi

    read -rp "  同时设置高级 initrwnd？(y/N，默认N): " ANSWER
    [ -n "$ANSWER" ] || ANSWER=n
    if echo "$ANSWER" | grep -qiE '^y(es)?$'; then
        read -rp "  initrwnd 值（回车与 initcwnd 相同）: " RWND
        [ -n "$RWND" ] || RWND=$VAL
        printf '%s\n' "$RWND" | grep -qE '^[0-9]+$' \
            && [ "$RWND" -ge 1 ] && [ "$RWND" -le 1000 ] \
            || { error "initrwnd 必须是 1-1000"; return 1; }
    fi

    for FAMILY in $FAMILIES; do
        [ "$FAMILY" = 4 ] && ROUTE=$ROUTE4 || ROUTE=$ROUTE6
        DEV=$(bbr_route_token "$ROUTE" dev)
        GW=$(bbr_route_token "$ROUTE" via)
        info "正在设置 IPv${FAMILY}（${DEV}，${GW:-直连}）"
        if bbr_apply_initcwnd_route "$FAMILY" "$ROUTE" "$VAL" "$RWND"; then
            APPLIED="$APPLIED $FAMILY"
        else
            error "IPv${FAMILY} 默认路由设置失败，正在撤销本次已应用协议"
            for ROLLBACK_FAMILY in $APPLIED; do
                [ "$ROLLBACK_FAMILY" = 4 ] && ROUTE=$ROUTE4 || ROUTE=$ROUTE6
                bbr_restore_initcwnd_route "$ROLLBACK_FAMILY" "$ROUTE" || true
            done
            return 1
        fi
    done

    bbr_cwnd_write_persistence "$FAMILIES" "$VAL" "$RWND" || {
        error "initcwnd 已立即生效，但持久化配置未完成"
        return 1
    }
    if [ "$RWND" -gt 0 ]; then
        info "initcwnd=${VAL}、initrwnd=${RWND} 已应用到 IPv${FAMILIES// /+IPv}，重启后自动生效 ✓"
    else
        info "initcwnd=${VAL} 已应用到 IPv${FAMILIES// /+IPv}，initrwnd 保持内核默认 ✓"
    fi
}

# ── BBR 主菜单 ────────────────────────────────────────────

# ── 一键 TCP 预设（三种场景）────────────────────────────
quench_tcp_profile() {
    local PROFILE="${1:-balanced}"
    local RMEM WMEM NOTSENT LABEL BUF_MB MEM_MB BUFFER_CAP
    MEM_MB=$(bbr_physical_memory_mb)
    if [ "$MEM_MB" -le 0 ]; then
        warn "无法读取物理内存，按 512MB 保守计算"
        MEM_MB=512
    fi
    case "$PROFILE" in
        balanced)
            if [ "$MEM_MB" -lt 512 ]; then
                RMEM=16777216; BUF_MB=16
            elif [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432; BUF_MB=32
            else
                RMEM=67108864; BUF_MB=64
            fi
            NOTSENT=262144
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            if [ "$MEM_MB" -lt 1024 ]; then RMEM=16777216; BUF_MB=16
            else RMEM=33554432; BUF_MB=32
            fi
            NOTSENT=131072
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;   BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;   BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128
            else
                RMEM=268435456;  BUF_MB=256
            fi
            NOTSENT=2097152
            LABEL="高吞吐传输 — 大带宽/万兆/下载上传优先" ;;
        relay)
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=16777216;  BUF_MB=16
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=67108864; BUF_MB=64
            elif [ "$MEM_MB" -lt 8192 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=262144
            LABEL="中转机 — 双向流量/大并发/均衡延迟与吞吐" ;;
        landing)
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;   BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128
            else
                RMEM=268435456;  BUF_MB=256
            fi
            NOTSENT=2097152
            LABEL="落地机 — 跨境上行/大缓冲吃满带宽" ;;
        line_landing)
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=16777216;  BUF_MB=16
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=67108864; BUF_MB=64
            elif [ "$MEM_MB" -lt 8192 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=131072
            LABEL="线路落地机 — CN2/IPLC/直连用户/低延迟优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    WMEM=$RMEM
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB" "$PROFILE") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "预设缓冲区 ${BUF_MB}MB 超过当前场景的内存预算，已自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
        BUF_MB=$(( RMEM / 1048576 ))
    fi

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$LABEL" "$BUF_MB" "$PROFILE"
}

# ── 智能 TCP 调优向导 ────────────────────────────────────
bbr_recommend_profile() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 768 ]; then
        echo latency
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo balanced
    else
        echo throughput
    fi
}

bbr_smart_wizard() {
    print_header "智能 TCP 调优向导"
    local MEM_MB KERNEL CUR_CC
    MEM_MB=$(bbr_physical_memory_mb)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    menu_group "当前环境"
    echo -e "  内存：${GREEN}${MEM_MB}MB${NC}  内核：${GREEN}${KERNEL}${NC}  拥塞控制：${GREEN}${CUR_CC}${NC}"
    echo ""
    menu_div
    menu_group "通用预设"
    menu_item "1" "均衡跨境  ${DIM}默认推荐${NC}"
    menu_item "2" "低延迟交互  ${DIM}SSH / 游戏 / 远程桌面${NC}"
    menu_item "3" "高吞吐传输  ${DIM}大带宽优先${NC}"
    echo ""
    menu_group "场景化预设"
    menu_item "4" "中转机  ${DIM}双向转发 / 大并发${NC}"
    menu_item "5" "落地机  ${DIM}跨境上行 / 大缓冲${NC}"
    menu_item "6" "线路落地机  ${DIM}低延迟优先${NC}"
    echo ""
    menu_item "7" "自动推荐  ${DIM}根据内存智能选择${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择预设 [0-7]: ')" CH

    local PROFILE=""
    case "$CH" in
        1) PROFILE="balanced" ;;
        2) PROFILE="latency" ;;
        3) PROFILE="throughput" ;;
        4) PROFILE="relay" ;;
        5) PROFILE="landing" ;;
        6) PROFILE="line_landing" ;;
        7)
            PROFILE=$(bbr_recommend_profile "$MEM_MB")
            case "$PROFILE" in
                latency) warn "小内存机器，推荐低延迟/轻量参数" ;;
                balanced) info "内存低于 4GB，推荐均衡模式" ;;
                throughput) info "内存达到 4GB，推荐高吞吐模式" ;;
            esac
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    quench_tcp_profile "$PROFILE" || return 1
}


# ── 检测是否有 sysctl 写入权限 ───────────────────────────
has_sysctl_write() {
    local CUR
    CUR=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null) || return 1
    [ -n "$CUR" ] || return 1
    # 写回原值来测试权限，避免探测动作改变系统 TCP 参数。
    sysctl -w "net.ipv4.tcp_fin_timeout=${CUR}" > /dev/null 2>&1 && return 0
    return 1
}

# ── 检测内核是否支持 BBR ─────────────────────────────────
bbr_check_kernel() {
    # 1. 检测内核版本 >= 4.9
    local KVER KMAJ KMIN
    KVER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
    KMAJ=$(echo "$KVER" | cut -d. -f1)
    KMIN=$(echo "$KVER" | cut -d. -f2)
    if [ "${KMAJ:-0}" -lt 4 ] || { [ "${KMAJ:-0}" -eq 4 ] && [ "${KMIN:-0}" -lt 9 ]; }; then
        error "内核版本 $(uname -r) 低于 4.9，不支持 BBR"
        echo -e "  ${DIM}Alpine: apk add linux-lts 或升级内核${NC}"
        return 1
    fi

    # 2. 检测 tcp_bbr 模块是否可用
    if lsmod 2>/dev/null | grep -q "tcp_bbr"; then
        return 0  # 已加载
    fi

    # 尝试加载模块
    if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块已加载 ✓"
        return 0
    fi

    # Alpine 上安装/切换内核包通常需要重启，交给用户确认后再动系统包。
    if command -v apk &>/dev/null; then
        warn "tcp_bbr 模块未加载。Alpine 可能需要安装/切换内核包并重启。"
        read -rp "  尝试安装 linux-lts 或 linux-virt？(y/N，默认N): " APK_KERNEL
        [ -z "$APK_KERNEL" ] && APK_KERNEL="n"
        if echo "$APK_KERNEL" | grep -qiE '^y(es)?$'; then
            apk add --no-cache linux-lts 2>/dev/null || apk add --no-cache linux-virt 2>/dev/null || true
            modprobe tcp_bbr 2>/dev/null && { info "tcp_bbr 模块已加载 ✓"; return 0; }
            warn "内核包安装后通常需要 reboot 才会生效"
        fi
    fi

    # 检查 sysctl 是否已设置 bbr（有些内核内置不需要模块）
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        return 0
    fi

    error "当前内核不支持 BBR（tcp_bbr 模块未找到）"
    echo -e "  ${DIM}Alpine 解决方案：${NC}"
    echo -e "  ${DIM}  apk add linux-lts && reboot${NC}"
    echo -e "  ${DIM}或检查：/proc/sys/net/ipv4/tcp_available_congestion_control${NC}"
    return 1
}

bbr_diagnose() {
    print_header "网络性能诊断"
    local DEV TC_BIN KERNEL CC AVAIL QDISC ACTIVE_QDISC RATE SYSCTL_WRITABLE SERVICE_STATE QDISCS
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    RATE="未设置"

    if [ -n "$DEV" ] && [ -n "$TC_BIN" ]; then
        RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
        QDISCS=$($TC_BIN qdisc show dev "$DEV" 2>/dev/null || true)
        ACTIVE_QDISC=$(bbr_tc_root_line "$QDISCS")
    fi
    [ -n "$ACTIVE_QDISC" ] || ACTIVE_QDISC="未知"

    SYSCTL_WRITABLE="否"
    has_sysctl_write && SYSCTL_WRITABLE="是"

    SERVICE_STATE="未安装"
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        SERVICE_STATE=$(systemctl is-enabled tc-fq 2>/dev/null || echo "已安装未启用")
    elif [ -f "$SERVICE_TC_INIT" ]; then
        if command -v rc-service >/dev/null 2>&1 && rc-service tc-fq status >/dev/null 2>&1; then
            SERVICE_STATE="已启用"
        else
            SERVICE_STATE="已安装未运行"
        fi
    fi

    echo -e "  内核版本: ${BOLD}${KERNEL}${NC}"
    echo -e "  默认网卡: ${BOLD}${DEV:-未知}${NC}"
    echo -e "  tc 命令: ${BOLD}${TC_BIN:-未安装}${NC}"
    echo -e "  拥塞算法: ${BOLD}${CC}${NC}"
    echo -e "  可用算法: ${BOLD}${AVAIL}${NC}"
    echo -e "  新接口默认 qdisc: ${BOLD}${QDISC}${NC}"
    echo -e "  ${DEV:-当前接口} 实际 root qdisc: ${BOLD}${ACTIVE_QDISC}${NC}"
    echo -e "  tc 限速: ${BOLD}${RATE}${NC}"
    echo -e "  tc-fq 服务: ${BOLD}${SERVICE_STATE}${NC}"
    echo -e "  sysctl 可写: ${BOLD}${SYSCTL_WRITABLE}${NC}"

    [ "$CC" = "bbr" ] || warn "当前未启用 BBR 拥塞算法"
    echo "$AVAIL" | grep -qw bbr || warn "可用拥塞算法里没有 bbr，可能需要升级/切换内核"
    if [ "$QDISC" != "fq" ]; then
        if bbr_kernel_at_least 4 20; then
            warn "新接口默认队列不是 fq；现代 BBR 仍有内部 pacing，但 fq 在高负载下通常更稳定"
        else
            warn "内核低于 4.20 且默认队列不是 fq，BBR pacing 可能不完整"
        fi
    fi
    if [ -f "$SYSCTL_FILE" ] && grep -q '^# skipped unsupported:' "$SYSCTL_FILE"; then
        warn "检测到不支持的 sysctl 参数已被注释："
        grep '^# skipped unsupported:' "$SYSCTL_FILE" | sed 's/^/    /'
    fi
    if command -v nstat >/dev/null 2>&1; then
        echo ""
        echo -e "  ${BOLD}累计网络错误计数${NC}"
        nstat -az TcpRetransSegs UdpInErrors UdpRcvbufErrors UdpSndbufErrors 2>/dev/null | sed 's/^/  /'
    fi
    if [ -n "$DEV" ] && [ -n "$TC_BIN" ]; then
        echo ""
        echo -e "  ${BOLD}当前 qdisc 统计${NC}"
        "$TC_BIN" -s qdisc show dev "$DEV" 2>/dev/null | sed 's/^/  /' || true
    fi
    echo ""
    echo -e "  ${DIM}拥塞控制变更只影响新建 TCP 连接；诊断时请重新建立测试连接。${NC}"
}

bbr_menu() {
    # 进入时检测一次 sysctl 写入权限
    local _BBR_NO_SYSCTL=0
    if ! ensure_sysctl || ! has_sysctl_write; then
        _BBR_NO_SYSCTL=1
    fi
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
    while true; do
        print_header "网络性能调优"
        bbr_print_status
        if [ "$_BBR_NO_SYSCTL" -eq 1 ]; then
            echo ""
            echo -e "  ${RED}${BOLD}⚠ 当前环境无 sysctl 写入权限${NC}"
            echo -e "  ${DIM}检测为无特权容器（unprivileged container）${NC}"
            echo -e "  ${DIM}sysctl 参数由宿主机控制，无法在容器内修改${NC}"
            echo -e "  ${DIM}请联系 VPS 提供商开启 sysctl 权限，或使用 KVM/独立VPS${NC}"
        fi
        echo ""
        menu_div
        menu_group "调优"
        menu_item "1" "智能向导  ${DIM}推荐${NC}"
        menu_pair "2" "自动配置" "3" "手动配置"
        menu_pair "4" "tc 智能整形" "5" "initcwnd 设置"
        echo ""
        menu_group "维护"
        menu_pair "6" "备份网络配置" "7" "还原时间戳备份"
        menu_item "8" "网络性能诊断"
        menu_item "9" "恢复首次调优前状态" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9]: ')" CH

        case "$CH" in
            1) bbr_smart_wizard ;;
            2) bbr_menu_auto ;;
            3) bbr_menu_manual ;;
            4) bbr_menu_tc ;;
            5) bbr_menu_initcwnd ;;
            6) bbr_backup_sysctl ;;
            7) bbr_restore_sysctl ;;
            8) bbr_diagnose ;;
            9) bbr_restore_initial_baseline ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
