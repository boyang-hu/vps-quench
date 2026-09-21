# ══════════════════════════════════════════════════════════
#  实测调优：出口带宽测量与业务 RTT 分离，不把预设当实测结果。
#  所有持久化操作仍经过 bbr/事务模块；测速不执行对端提供的内容。
# ══════════════════════════════════════════════════════════
QUENCH_PERF_REPORT_DIR="/var/lib/quench/performance"

bbr_measure_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 7 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

bbr_measure_yes() {
    local ANSWER
    read -rp "  $1 " ANSWER || return 1
    case "${ANSWER:-${2:-n}}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

bbr_measure_dependencies() {
    local TOOL
    for TOOL in iperf3 timeout ip tc; do
        command -v "$TOOL" >/dev/null 2>&1 && continue
        bbr_measure_yes "需要安装 ${TOOL}，继续？(Y/n):" y || return 1
        case "$TOOL" in
            iperf3) pkg_install iperf3 || return 1 ;;
            timeout) pkg_install coreutils || return 1 ;;
            ip|tc) pkg_install iproute2 || return 1 ;;
        esac
        command -v "$TOOL" >/dev/null 2>&1 || { error "请手动安装 ${TOOL}"; return 1; }
    done
}

# 仅提供候选，不承诺公共节点可用或容量足够；必须先获测速许可再调用。
bbr_measure_peer_pool() {
    printf '%s\n' \
        speedtest.hkg12.hk.leaseweb.net speedtest.sin1.sg.leaseweb.net \
        speedtest.tyo11.jp.leaseweb.net speedtest.syd12.au.leaseweb.net \
        speedtest.fra1.de.leaseweb.net speedtest.ams2.nl.leaseweb.net \
        speedtest.lon12.uk.leaseweb.net speedtest.lax12.us.leaseweb.net \
        speedtest.sea11.us.leaseweb.net speedtest.dal13.us.leaseweb.net \
        speedtest.nyc1.us.leaseweb.net
}

# 固定协议族和字面地址，后续 ping、route get、iperf 必须使用同一个目标。
bbr_measure_resolve() {
    local HOST="$1" FAMILY="$2" ADDR LOOKUP OUTPUT
    bbr_calibration_host_valid "$HOST" || return 1
    if ip_address_valid "$FAMILY" "$HOST" 2>/dev/null; then
        case "$HOST" in ::ffff:*|::FFFF:*) return 1 ;; esac
        printf '%s\n' "$HOST"; return 0
    fi
    LOOKUP=ahostsv4; [ "$FAMILY" != 6 ] || LOOKUP=ahostsv6
    OUTPUT=$(timeout 5 getent "$LOOKUP" "$HOST" 2>/dev/null || true)
    [ -n "$OUTPUT" ] || OUTPUT=$(timeout 5 getent hosts "$HOST" 2>/dev/null || true)
    while read -r ADDR _; do
        case "$ADDR" in ::ffff:*|::FFFF:*) continue ;; esac
        if ip_address_valid "$FAMILY" "$ADDR" 2>/dev/null; then
            printf '%s\n' "$ADDR"; return 0
        fi
    done <<< "$OUTPUT"
    error "无法解析 ${HOST} 的 IPv${FAMILY} 地址；可直接填写对应协议的 IP" >&2
    return 1
}

bbr_measure_rtt() {
    local ADDR="$1" FAMILY="$2" OUTPUT
    OUTPUT=$(LC_ALL=C timeout 5 ping "-$FAMILY" -n -c 2 "$ADDR" 2>/dev/null) || return 1
    printf '%s\n' "$OUTPUT" | awk -F/ '/rtt|round-trip/ {
        if ($5+0>0) {printf "%.2f\n",$5; found=1; exit}
    } END {if(!found) exit 1}'
}

bbr_measure_peer_ready() {
    # 1 秒、1 Mbps 的协议握手测试；不扫描自有节点未指定的端口。
    LC_ALL=C timeout 8 iperf3 "-$3" -c "$1" -p "$2" -t 1 -P 1 -b 1M >/dev/null 2>&1
}

bbr_measure_pick_peer() {
    local FAMILY="$1" HOST ADDR RTT PORT LIST COUNT=0
    command -v ping >/dev/null 2>&1 || { error "自动选点需要 ping；请安装或手填自有节点"; return 1; }
    LIST=$(quench_mktemp "${TMPDIR:-/tmp}/quench-peer-list.XXXXXX") || return 1
    # 顺序探测有硬超时；逐节点反馈，避免后台进程在取消后继续运行。
    while IFS= read -r HOST; do
        info "检查公共候选：$HOST"
        ADDR=$(bbr_measure_resolve "$HOST" "$FAMILY" 2>/dev/null) || continue
        RTT=$(bbr_measure_rtt "$ADDR" "$FAMILY") || continue
        awk -v r="$RTT" 'BEGIN {exit !(r<=100)}' || continue
        printf '%s %s %s\n' "$RTT" "$ADDR" "$HOST" >> "$LIST" || return 1
    done < <(bbr_measure_peer_pool)
    while read -r RTT ADDR HOST; do
        COUNT=$((COUNT + 1)); [ "$COUNT" -le 4 ] || break
        for PORT in 5201 5202 5203 5200; do
            if bbr_measure_peer_ready "$ADDR" "$PORT" "$FAMILY"; then
                QUENCH_PERF_PEER=$ADDR; QUENCH_PERF_PORT=$PORT
                info "选中 ${HOST} → ${ADDR}:${PORT}，RTT ${RTT}ms（不代表带宽足够）"
                rm -f "$LIST"; return 0
            fi
        done
    done < <(sort -n "$LIST")
    rm -f "$LIST"
    error "没有找到 100ms 内可用的公共节点；可能是 ICMP 被禁、节点忙或距离远，请使用自有节点"
    return 1
}

bbr_measure_iface() {
    local ROUTE DEV
    ROUTE=$(ip "-$2" route get "$1" 2>/dev/null) || return 1
    DEV=$(printf '%s\n' "$ROUTE" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    printf '%s\n' "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    printf '%s\n' "$DEV"
}

bbr_measure_route_check() {
    local DEV
    DEV=$(bbr_measure_iface "$QUENCH_PERF_PEER" "$QUENCH_PERF_FAMILY") || return 1
    [ "$DEV" = "$QUENCH_PERF_DEV" ] || { error "测速出口已改变，停止操作；请重新开始"; return 1; }
}

bbr_measure_queue_guard() {
    local DEV="$1" TC_BIN="$2" QDISCS ROOT HANDLE FILTERS SAVED
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV") || return 1
    FILTERS=$("$TC_BIN" filter show dev "$DEV" root) || return 1
    [ -z "$FILTERS" ] || { error "出口已有 root filter，拒绝临时接管"; return 1; }
    if [ -s "$TC_STATE_FILE" ]; then
        SAVED=$(bbr_state_value "$TC_STATE_FILE" DEV)
        [ "$SAVED" = "$DEV" ] || { error "已有另一网卡的 Quench 整形，本向导不迁移或覆盖它"; return 1; }
    fi
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        bbr_tc_saved_matches_runtime || { error "现有 Quench 整形与保存值不同，请先检查"; return 1; }
        return 0
    fi
    bbr_fq_default_tree "$QDISCS" && return 0
    ROOT=$(bbr_tc_root_line "$QDISCS"); HANDLE=$(bbr_tc_qdisc_handle "$ROOT")
    # 接受内核默认 fq 或基础模式创建的队列，但拒绝外部限速/关闭 pacing。
    if bbr_fq_runtime_ready "$QDISCS" && ! printf '%s\n' "$QDISCS" | grep -Eq ' maxrate | nopacing'; then
        case "$HANDLE" in 0:|7ffd:|7ffe:) return 0 ;; esac
    fi
    error "出口存在自定义队列；可以只验证性能，实测调优不会覆盖外部 QoS"
    return 1
}

# 内存仅作单 socket 上限，不据此选择带宽/用途。默认窗口按用途计算而非内存档位。
bbr_measure_buffer_plan() {
    local BW="$1" RTT="$2" MEM="$3" ROLE="$4"
    bbr_measure_uint "$BW" 1 100000 || return 1
    bbr_measure_uint "$RTT" 1 2000 || return 1
    bbr_measure_uint "$MEM" 1 4194304 || return 1
    case "$ROLE" in proxy|mixed|bulk) : ;; *) return 1 ;; esac
    awk -v bw="$BW" -v rtt="$RTT" -v mem="$MEM" -v role="$ROLE" 'BEGIN {
        bdp=bw*rtt*125; target=2*bdp+2097152
        target=int((target+65535)/65536)*65536
        cap=mem*1048576/32; if(cap>268435456) cap=268435456
        if(cap<4194304) cap=4194304
        max=target; if(max<4194304) max=4194304; if(max>cap) max=cap
        def=1048576
        if(role=="mixed") def=2097152
        if(role=="bulk") {def=bdp; if(def<1048576) def=1048576; if(def>8388608) def=8388608}
        if(def>max) def=max
        printf "%.0f %.0f %.0f\n",max,def,target
    }'
}

bbr_measure_generate_config() {
    local BW="$1" RTT="$2" MEM="$3" ROLE="$4" PLAN MAX DEFAULT TARGET LOWAT
    PLAN=$(bbr_measure_buffer_plan "$BW" "$RTT" "$MEM" "$ROLE") || return 1
    read -r MAX DEFAULT TARGET <<< "$PLAN"
    printf '# Quench 实测方案：带宽基准=%sMbps 目标RTT=%sms 内存上限=%sMB 用途=%s\n' "$BW" "$RTT" "$MEM" "$ROLE"
    printf 'net.core.rmem_max = %s\nnet.core.wmem_max = %s\n' "$MAX" "$MAX"
    printf 'net.ipv4.tcp_rmem = 4096 %s %s\nnet.ipv4.tcp_wmem = 4096 %s %s\n' "$DEFAULT" "$MAX" "$DEFAULT" "$MAX"
    printf '%s\n' 'net.ipv4.tcp_window_scaling = 1' 'net.ipv4.tcp_moderate_rcvbuf = 1' \
        'net.ipv4.tcp_mtu_probing = 1' 'net.ipv4.tcp_slow_start_after_idle = 0'
    printf 'net.ipv4.tcp_fastopen = %s\n' "$(bbr_tcp_fastopen_value)"
    # 不臆设 tcp_mem/min_free_kbytes/废弃的 adv_win_scale，不碰转发或 initcwnd。
    # 老预设压低过 notsent 时，恢复记录的原始值；无基线时不猜内核默认。
    if [ -f "$SYSCTL_FILE" ] && bbr_config_has_key "$(cat "$SYSCTL_FILE")" net.ipv4.tcp_notsent_lowat; then
        LOWAT=$(bbr_baseline_value net.ipv4.tcp_notsent_lowat 2>/dev/null || true)
        if [ -n "$LOWAT" ]; then
            printf 'net.ipv4.tcp_notsent_lowat = %s\n' "$LOWAT"
        else
            warn "旧 notsent_lowat 没有原始基线，保持原值；本轮结果受它影响" >&2
        fi
    fi
}

bbr_measure_record() {
    local LABEL="$1" STREAMS="$2"
    printf '%s\t%s\t8\t%s\t%s\t%s\t%s\n' "$LABEL" "$STREAMS" "$BBR_CAL_SENDER" "$BBR_CAL_RECEIVER" "$BBR_CAL_RETRANS" "$BBR_CAL_LOSS" \
        >> "$QUENCH_PERF_REPORT/samples.tsv"
}

bbr_measure_pair() {
    local LABEL="$1" STREAMS FAILED=0
    QUENCH_PERF_SINGLE=""; QUENCH_PERF_MULTI=""
    for STREAMS in 1 4; do
        bbr_measure_route_check || return 1
        if bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 8 "$STREAMS" "$LABEL"; then
            bbr_measure_record "$LABEL" "$STREAMS" || return 1
            printf '  %s %s流：接收 %sMbps，重传 %s，估算重传比例 %s%%\n' \
                "$LABEL" "$STREAMS" "$BBR_CAL_RECEIVER" "$BBR_CAL_RETRANS" "$BBR_CAL_LOSS"
            if [ "$STREAMS" = 1 ]; then QUENCH_PERF_SINGLE=$BBR_CAL_RECEIVER
            else QUENCH_PERF_MULTI=$BBR_CAL_RECEIVER; fi
        else
            FAILED=1
        fi
        sleep 3
    done
    return "$FAILED"
}

bbr_measure_probe() {
    local ROUND VALUES="" COUNT=0 BW
    bbr_measure_route_check || return 1
    bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    bbr_calibration_capture_qdisc "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    QUENCH_PERF_RESTORE=1
    bbr_calibration_set_fq "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    # 三次聚合样本取中位数，保留每份原始统计，不把单次峰值当稳定带宽。
    for ROUND in 1 2 3; do
        bbr_measure_route_check || return 1
        if bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 8 4 "不限速带宽估计 $ROUND/3"; then
            bbr_measure_record probe 4 || return 1
            VALUES="${VALUES}${BBR_CAL_RECEIVER}"$'\n'
            COUNT=$((COUNT + 1))
        fi
        sleep 3
    done
    bbr_calibration_restore_qdisc || { error "测速后队列恢复失败，停止调优"; return 1; }
    QUENCH_PERF_RESTORE=0
    [ "$COUNT" -ge 2 ] || { error "有效带宽样本不足，不生成参数方案"; return 1; }
    BW=$(printf '%s' "$VALUES" | sort -n | awk 'NF {a[++n]=$1} END {
        if(n<2) exit 1
        # 两份时使用较低值，三份时中位数。
        v=a[int((n+1)/2)]; if(v<1) v=1
        printf "%.0f",v
    }') || return 1
    bbr_measure_uint "$BW" 1 100000 || return 1
    QUENCH_PERF_BW=$BW
    info "本轮可用带宽估计：${BW}Mbps（不是套餐保证值，也不是跨境速度）"
    if printf '%s' "$VALUES" | awk 'NF {if(!n++ || $1<lo) lo=$1; if($1>hi) hi=$1} END {exit !(hi>lo*1.3)}'; then
        warn "样本波动超过 30%，公共节点或线路可能繁忙；建议换节点复测"
        bbr_measure_yes "仍使用本轮估计生成建议？(y/N):" n || return 1
    fi
}

bbr_measure_compare() {
    local BEFORE="$1" AFTER="$2" LABEL="$3"
    if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
        warn "${LABEL}：缺少有效对照，无法判断收益"; return 0
    fi
    awk -v b="$BEFORE" -v a="$AFTER" -v label="$LABEL" 'BEGIN {
        printf "  %s：%.2f → %.2f Mbps（%+.1f%%）\n",label,b,a,b>0?(a/b-1)*100:0
    }'
    if awk -v b="$BEFORE" -v a="$AFTER" 'BEGIN {exit !(a<b*0.9)}'; then
        warn "${LABEL}本轮下降超过 10%；不能判定优化成功，请换时段复测或恢复参数快照"
    fi
}

bbr_measure_cleanup() {
    local RC=$?
    trap - EXIT
    bbr_calibration_stop_child
    if [ "${QUENCH_PERF_RESTORE:-0}" = 1 ]; then
        bbr_calibration_restore_qdisc || { error "原队列恢复失败，请立即检查 tc"; RC=1; }
    fi
    if [ -n "${QUENCH_PERF_REPORT:-}" ]; then
        if ! printf 'exit_code=%s\n' "$RC" >> "$QUENCH_PERF_REPORT/outcome.txt"; then
            error "无法写入最终报告状态"; RC=1
        fi
        info "本轮报告与参数快照：$QUENCH_PERF_REPORT"
    fi
    bbr_calibration_lock_release
    txn_write_end
    quench_tmp_cleanup
    exit "$RC"
}

# 子 shell 隔离测速信号/EXIT trap，不污染主菜单；锁覆盖取样、修改和复测全过程。
bbr_measure_session() (
    local MODE="$1" HOST="$2" PORT="$3" FAMILY="$4" NOMINAL="$5" RTT="$6" ROLE="$7" CORE="$8" SHAPE="$9"
    local MEM PLAN MAX DEFAULT TARGET CONFIG BEFORE1 BEFORE4 SCAN_RC=0
    # EXIT 在某些 Bash 版本中会在函数 local 作用域销毁后执行；清理状态必须
    # 用子 shell 内的全局变量。外层菜单不受这些赋值影响。
    QUENCH_PERF_PEER=$HOST; QUENCH_PERF_PORT=$PORT; QUENCH_PERF_FAMILY=$FAMILY
    QUENCH_PERF_DEV=""; QUENCH_PERF_REPORT=""; QUENCH_PERF_RESTORE=0
    QUENCH_PERF_SINGLE=""; QUENCH_PERF_MULTI=""; QUENCH_PERF_BW=""
    # 父菜单可能也有登记中的临时资源，绝不能在子流程退出时清掉它们。
    QUENCH_TMP_REGISTRY=""
    txn_write_begin "实测性能流程" || exit 1
    trap bbr_measure_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    quench_tmp_registry_init || exit 1
    bbr_calibration_lock_acquire || exit 1
    bbr_measure_dependencies || exit 1
    if [ -z "$HOST" ]; then
        bbr_measure_pick_peer "$FAMILY" || exit 1
    else
        QUENCH_PERF_PEER=$(bbr_measure_resolve "$HOST" "$FAMILY") || exit 1
        bbr_measure_peer_ready "$QUENCH_PERF_PEER" "$PORT" "$FAMILY" || { error "对端忙或 iperf3 不可达"; exit 1; }
    fi
    QUENCH_PERF_DEV=$(bbr_measure_iface "$QUENCH_PERF_PEER" "$FAMILY") || exit 1
    BBR_CAL_DEV=$QUENCH_PERF_DEV; BBR_CAL_TC_BIN=$(command -v tc)
    mkdir -p "$QUENCH_PERF_REPORT_DIR" || exit 1
    chmod 700 "$QUENCH_PERF_REPORT_DIR" || exit 1
    QUENCH_PERF_REPORT=$(mktemp -d "$QUENCH_PERF_REPORT_DIR/run-$(date +%Y%m%d-%H%M%S).XXXXXX") || exit 1
    printf 'phase\tstreams\tduration_seconds\tsender_mbps\treceiver_mbps\tretransmits\testimated_retrans_pct\n' > "$QUENCH_PERF_REPORT/samples.tsv" || exit 1
    printf 'peer=%s\nport=%s\nfamily=%s\ndev=%s\nmode=%s\nnominal=%s\ntarget_rtt=%s\nrole=%s\n' \
        "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$FAMILY" "$QUENCH_PERF_DEV" "$MODE" "$NOMINAL" "$RTT" "$ROLE" > "$QUENCH_PERF_REPORT/context.txt" || exit 1
    printf 'version=%s\nenable_core=%s\ncalibrate_shaping=%s\n' "$APP_VERSION" "$CORE" "$SHAPE" >> "$QUENCH_PERF_REPORT/context.txt" || exit 1
    if [ "$MODE" = verify ]; then
        bbr_measure_pair verify || exit 1
        info "只做了吞吐测试，未修改 sysctl、拥塞算法、路由窗口或 tc 队列"
        exit 0
    fi
    bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || exit 1
    bbr_runtime_snapshot "$QUENCH_PERF_REPORT/before.conf" || exit 1
    if [ -f "$SYSCTL_FILE" ]; then
        cp "$SYSCTL_FILE" "$QUENCH_PERF_REPORT/saved-before.conf" || exit 1
    fi
    bbr_measure_pair before || { error "调优前对照不完整，请换节点后重试；未修改配置"; exit 1; }
    BEFORE1=$QUENCH_PERF_SINGLE; BEFORE4=$QUENCH_PERF_MULTI
    bbr_measure_probe || exit 1
    MEM=$(bbr_physical_memory_mb)
    bbr_measure_uint "$MEM" 1 4194304 || { error "无法确定物理内存安全上限"; exit 1; }
    # 用户知道套餐时，它比临时繁忙的公网测速更适合做 BDP 的容量基准。
    local BW=$QUENCH_PERF_BW
    if [ -n "$NOMINAL" ]; then
        info "实测 ${BW}Mbps；使用你指定的 ${NOMINAL}Mbps 作为缓冲计算基准"
        BW=$NOMINAL
    fi
    PLAN=$(bbr_measure_buffer_plan "$BW" "$RTT" "$MEM" "$ROLE") || exit 1
    read -r MAX DEFAULT TARGET <<< "$PLAN"
    printf '\n  带宽基准 %sMbps × 业务目标 RTT %sms\n  单连接缓冲上限 %.0fMiB，起点 %.0fKiB；内存仅用于封顶\n' \
        "$BW" "$RTT" "$(( MAX / 1048576 ))" "$(( DEFAULT / 1024 ))"
    [ "$MAX" -ge "$TARGET" ] || warn "BDP 目标超过单连接内存预算，本轮采用安全上限"
    CONFIG=$(bbr_measure_generate_config "$BW" "$RTT" "$MEM" "$ROLE") || exit 1
    printf '%s\n' "$CONFIG" > "$QUENCH_PERF_REPORT/proposed.conf" || exit 1
    printf 'measured_mbps=%s\nbuffer_basis_mbps=%s\n' "$QUENCH_PERF_BW" "$BW" >> "$QUENCH_PERF_REPORT/context.txt" || exit 1
    bbr_measure_yes "应用上述实测方案？(Y/n，选择 n 只保留报告):" y || exit 0
    bbr_measure_route_check || exit 1
    # 纳入现有「还原时间戳备份」入口；即使首次运行也能回到本轮之前。
    bbr_backup_sysctl || exit 1
    if [ "$CORE" = y ]; then
        bbr_enable_core_locked || { error "基础 BBR/FQ 未全部完成，停止后续调优"; exit 1; }
    fi
    bbr_apply_sysctl "$CONFIG" measured || exit 1
    if [ "$SHAPE" = y ]; then
        bbr_measure_route_check || exit 1
        info "下面寻找重传开始显著增加的速率；只有测准并确认后才持久化限速"
        # 复用独立校准，交出其专用锁；事务锁仍由整个向导持有。
        bbr_calibration_lock_release
        bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || exit 1
        sleep 15
        bbr_calibration_run "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$FAMILY" "$BW" 8 "$QUENCH_PERF_DEV" || SCAN_RC=$?
        trap 'exit 130' INT TERM HUP
        bbr_calibration_lock_acquire || exit 1
        if [ "$SCAN_RC" = 1 ]; then
            error "整形步骤出错；参数可能已生效，请检查报告与队列，不报告调优成功"
            exit 1
        fi
        [ "$SCAN_RC" = 0 ] || warn "本轮未得到可靠拐点，未应用新的限速值"
        if [ -f "$BBR_CALIBRATION_RESULT_FILE" ]; then
            cp "$BBR_CALIBRATION_RESULT_FILE" "$QUENCH_PERF_REPORT/calibration.state" || exit 1
        fi
    fi
    info "等待 15 秒让测试突发消退，再验证实际效果"
    sleep 15
    bbr_measure_pair after || { error "参数已应用，但复测不完整，不能判断收益"; exit 1; }
    bbr_measure_compare "$BEFORE1" "$QUENCH_PERF_SINGLE" 单流
    bbr_measure_compare "$BEFORE4" "$QUENCH_PERF_MULTI" 四流
    bbr_runtime_snapshot "$QUENCH_PERF_REPORT/after.conf" || exit 1
    info "以上只是本轮同节点对照，不是严格 A/B，也不代表跨境或 UDP 性能；忙闲变化会影响结果"
    info "若需撤回参数，可用「还原时间戳备份」选择本轮备份；tc 限速需在独立菜单取消/调整"
)

bbr_measure_menu() {
    local MODE="${1:-tune}" HOST PORT FAMILY NOMINAL="" RTT=150 ROLE=proxy CORE=n SHAPE=n INPUT
    print_header "实测网络性能（${MODE}）"
    echo "  出口测速用于估计本机容量，不等于到用户的跨境速度。"
    echo "  测试会产生高带宽流量、影响同机业务；建议在空闲时段运行。"
    read -rp "  协议族 4/6（默认4）: " FAMILY || return 1
    FAMILY=${FAMILY:-4}; case "$FAMILY" in 4|6) : ;; *) error "请选择 4 或 6"; return 1 ;; esac
    read -rp "  iperf3 主机/IP（回车自动挑公共节点，自有近端节点更可靠）: " HOST || return 1
    if [ -n "$HOST" ]; then bbr_calibration_host_valid "$HOST" || { error "无效主机"; return 1; }; fi
    read -rp "  对端端口（默认5201；自动选点时会检查候选端口）: " PORT || return 1
    PORT=${PORT:-5201}; bbr_calibration_port_valid "$PORT" || { error "无效端口"; return 1; }
    if [ "$MODE" = tune ]; then
        read -rp "  套餐带宽（留空实测；已知可填 400M / 600M / 1G）: " INPUT || return 1
        if [ -n "$INPUT" ]; then NOMINAL=$(bbr_parse_bandwidth_mbps "$INPUT") || { error "无效带宽"; return 1; }; fi
        read -rp "  业务目标 RTT（默认150ms，估计值；不是近端测速延迟）: " RTT || return 1
        RTT=${RTT:-150}; bbr_measure_uint "$RTT" 1 2000 || { error "RTT 必须为 1-2000ms"; return 1; }
        read -rp "  用途：1 代理/多连接（默认）  2 混合  3 少量大文件: " INPUT || return 1
        case "$INPUT" in ''|1) ROLE=proxy ;; 2) ROLE=mixed ;; 3) ROLE=bulk ;; *) return 1 ;; esac
        bbr_measure_yes "同时启用 BBR＋FQ？(Y/n，不会因此新增限速):" y && CORE=y
        bbr_measure_yes "同时实测是否需要 tc 整形？(Y/n，可独立跳过):" y && SHAPE=y
        echo "  RTT 为目标假设；带宽优先使用你填写的套餐值，否则使用本轮实测。"
        echo "  不自动改 initcwnd、tcp_mem、转发、Swap；原有外部 QoS 不接管。"
    fi
    echo "  未知带宽时无法预报流量：仅 8 秒 × 1Gbps 就约 1GB；整套可能消耗数十GB。"
    echo "  公共节点将看到本机 IP；没有可用节点时会停止，不会退回内存预设。"
    bbr_measure_yes "确认开始联网测试？(y/N):" n || return 0
    bbr_measure_session "$MODE" "$HOST" "$PORT" "$FAMILY" "$NOMINAL" "$RTT" "$ROLE" "$CORE" "$SHAPE"
}
