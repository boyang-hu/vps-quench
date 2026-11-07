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
    ui_read_yes_no ANSWER "  $1 " "${2:-n}" || return 1
    [ "$ANSWER" = y ]
}

bbr_measure_dependencies() {
    local TOOL
    for TOOL in iperf3 timeout ip tc; do
        if [ "$TOOL" = iperf3 ] && [ "${QUENCH_PERF_HAVE_IPERF:-1}" = 0 ]; then continue; fi
        command -v "$TOOL" >/dev/null 2>&1 && continue
        if ! bbr_measure_yes "需要安装 ${TOOL}，继续？(Y/n):" y; then
            if [ "$TOOL" = iperf3 ]; then QUENCH_PERF_HAVE_IPERF=0; continue; fi
            return 1
        fi
        case "$TOOL" in
            iperf3) pkg_install iperf3 || { QUENCH_PERF_HAVE_IPERF=0; continue; } ;;
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
        speedtest.nyc1.us.leaseweb.net sgp.proof.ovh.net \
        ams.speedtest.clouvider.net lon.speedtest.clouvider.net \
        speedtest.sfo12.us.leaseweb.net speedtest.chi11.us.leaseweb.net \
        speedtest.mia11.us.leaseweb.net speedtest.mtl2.ca.leaseweb.net
}

# 仅为内置公共候选列出服务端口；用户填写的主机严格使用指定端口。
bbr_measure_peer_ports() {
    case "$1" in
        *.clouvider.net) printf '%s\n' 5201 5202 5203 5204 5205 5206 5207 5208 5209 5200 ;;
        *) printf '%s\n' 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 ;;
    esac
}

bbr_measure_default_family() {
    if [ -z "$(ip -4 route show default 2>/dev/null)" ] && [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
        printf '6\n'
    else
        printf '4\n'
    fi
}

bbr_measure_log() {
    [ -n "${QUENCH_PERF_REPORT:-}" ] || return 0
    printf '%s\n' "$*" >> "$QUENCH_PERF_REPORT/connections.log"
}

bbr_measure_error_kind() {
    if [ "$2" = 124 ]; then printf 'timeout\n'
    elif grep -qiE 'server is busy|server busy' "$1"; then printf 'busy\n'
    elif grep -qiE 'connect|refused|unreachable|timed out|control (socket|message)|broken pipe|reset by peer' "$1"; then printf 'connection\n'
    else printf 'other\n'; fi
}

bbr_measure_log_result() {
    local FILE="$1" LABEL="$2" PEER="$3" PORT="$4" RC="$5"
    [ -n "${QUENCH_PERF_REPORT:-}" ] || return 0
    bbr_measure_log "[$LABEL] peer=$PEER port=$PORT exit=$RC" || return 1
    cat "$FILE" >> "$QUENCH_PERF_REPORT/connections.log"
}

# DNS/ICMP 最多 18 路，短 TCP 连接每批最多 4 路。退出时等有硬超时的
# 当前批次收尾（DNS/ICMP 最多 20 秒），再删除临时目录，不留下后台测速。
bbr_measure_probe_wait() {
    local PID
    for PID in ${QUENCH_PERF_PROBE_PIDS:-}; do wait "$PID" 2>/dev/null || true; done
    QUENCH_PERF_PROBE_PIDS=""
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
    if ! OUTPUT=$(LC_ALL=C timeout 5 ping "-$FAMILY" -n -c 2 "$ADDR" 2>&1); then
        # 一些 BusyBox ping 不支持 -4/-6；IPv6 使用独立 ping6。
        case "$OUTPUT" in
            *'invalid option'*|*'unrecognized option'*|*'illegal option'*)
                if [ "$FAMILY" = 4 ]; then
                    OUTPUT=$(LC_ALL=C timeout 5 ping -n -c 2 "$ADDR" 2>/dev/null) || return 1
                else
                    OUTPUT=$(LC_ALL=C timeout 5 ping6 -n -c 2 "$ADDR" 2>/dev/null) || return 1
                fi ;;
            *) return 1 ;;
        esac
    fi
    printf '%s\n' "$OUTPUT" | awk '/rtt|round-trip/ {
        sub(/^.*=[[:space:]]*/, ""); split($0, values, "/")
        if (values[2] ~ /^[0-9]+([.][0-9]+)?$/) {printf "%.2f\n",values[2]; found=1; exit}
    } END {if(!found) exit 1}'
}

bbr_measure_peer_ready() {
    # 与正式对端预检一致：3 秒单流，最多 25 秒等待；不扩展自有节点端口。
    local RC=0 KIND
    BBR_CAL_TEMP_FILE=$(quench_mktemp "${TMPDIR:-/tmp}/quench-peer-iperf.XXXXXX") || return 1
    LC_ALL=C timeout 25 iperf3 "-$3" -c "$1" -p "$2" -t 3 -P 1 > "$BBR_CAL_TEMP_FILE" 2>&1 &
    BBR_CAL_IPERF_PID=$!
    wait "$BBR_CAL_IPERF_PID" || RC=$?
    BBR_CAL_IPERF_PID=""
    bbr_measure_log_result "$BBR_CAL_TEMP_FILE" handshake "$1" "$2" "$RC" || RC=1
    if [ "$RC" -ne 0 ]; then
        KIND=$(bbr_measure_error_kind "$BBR_CAL_TEMP_FILE" "$RC")
        warn "${1}:${2} 握手失败（${KIND}）：$(tail -n 1 "$BBR_CAL_TEMP_FILE")"
    fi
    rm -f "$BBR_CAL_TEMP_FILE"; BBR_CAL_TEMP_FILE=""
    return "$RC"
}

bbr_measure_tcp_open() {
    # shellcheck disable=SC2016 # $1/$2 由子 Bash 展开；主机与端口通过参数传入。
    timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' quench-port "$1" "$2" >/dev/null 2>&1
}

bbr_measure_discover() (
    trap - EXIT INT TERM HUP
    local ADDR RTT
    ADDR=$(bbr_measure_resolve "$1" "$2" 2>/dev/null) || { printf 'dns_failed %s\n' "$1" > "$3.error"; exit 0; }
    RTT=$(bbr_measure_rtt "$ADDR" "$2") || RTT=999999
    printf '%s %s %s\n' "$RTT" "$ADDR" "$1" > "$3"
)

bbr_measure_public_ready() {
    local ADDR="$1" HOST="$2" FAMILY="$3" PORT DIR COUNT=0
    DIR=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-ports.XXXXXX") || return 1
    # 闭端口不逐个等待 iperf3 的长超时，短连接检查同样限制并发。
    while read -r PORT; do
        (trap - EXIT INT TERM HUP; bbr_measure_tcp_open "$ADDR" "$PORT" && : > "$DIR/$PORT") &
        QUENCH_PERF_PROBE_PIDS="${QUENCH_PERF_PROBE_PIDS:-} $!"
        COUNT=$((COUNT + 1))
        if [ "$((COUNT % 4))" = 0 ]; then bbr_measure_probe_wait; fi
    done < <(bbr_measure_peer_ports "$HOST")
    bbr_measure_probe_wait
    while read -r PORT; do
        if [ ! -f "$DIR/$PORT" ]; then
            bbr_measure_log "[tcp_unreachable] peer=$ADDR port=$PORT" || return 1
            continue
        fi
        if bbr_measure_peer_ready "$ADDR" "$PORT" "$FAMILY"; then
            QUENCH_PERF_PORT=$PORT
            QUENCH_PERF_PORTS=$(bbr_measure_peer_ports "$HOST")
            rm -rf "$DIR"; return 0
        fi
    done < <(bbr_measure_peer_ports "$HOST")
    rm -rf "$DIR"
    return 1
}

bbr_measure_pick_peer() {
    local FAMILY="$1" HOST ADDR RTT DIR FILE COUNT=0 FALLBACK=n
    DIR=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-peers.XXXXXX") || return 1
    info "并行筛选 18 个公共候选（IPv${FAMILY}）"
    while IFS= read -r HOST; do
        COUNT=$((COUNT + 1))
        bbr_measure_discover "$HOST" "$FAMILY" "$DIR/$COUNT.peer" &
        QUENCH_PERF_PROBE_PIDS="${QUENCH_PERF_PROBE_PIDS:-} $!"
        if [ "$((COUNT % 18))" = 0 ]; then bbr_measure_probe_wait; fi
    done < <(bbr_measure_peer_pool)
    bbr_measure_probe_wait
    : > "$DIR/list" || return 1
    for FILE in "$DIR"/*.peer; do
        [ ! -f "$FILE" ] || cat "$FILE" >> "$DIR/list" || return 1
    done
    for FILE in "$DIR"/*.error; do
        [ ! -f "$FILE" ] || bbr_measure_log "$(cat "$FILE")" || return 1
    done
    # 候选使用独立 fd，保留用户输入供失败后重选对端。
    while read -r RTT ADDR HOST <&3; do
        if awk -v r="$RTT" 'BEGIN {exit !(r>100)}' && [ "$FALLBACK" = n ]; then
            warn "100ms 内没有可用节点；余下节点较远或无法测得 ICMP 延迟，结果可能低估本机容量。"
            info "放宽距离限制，继续尝试最近的候选"
            FALLBACK=y
        fi
        if [ "$RTT" = 999999 ]; then RTT=unknown; fi
        info "检查 iperf3：${HOST}（RTT ${RTT}ms）"
        bbr_measure_log "[candidate] host=$HOST peer=$ADDR rtt_ms=$RTT" || return 1
        if bbr_measure_public_ready "$ADDR" "$HOST" "$FAMILY"; then
            QUENCH_PERF_PEER=$ADDR
            info "选中 ${HOST} → ${ADDR}:${QUENCH_PERF_PORT}（不代表带宽足够）"
            rm -rf "$DIR"; return 0
        fi
    done 3< <(sort -n "$DIR/list")
    rm -rf "$DIR"
    error "未选中可用公共节点；连接原因已记录，也可使用自有 iperf3 节点重试"
    return 1
}

bbr_measure_next_port() {
    local TRIED="$1" PORT
    while read -r PORT; do
        [ -n "$PORT" ] || continue
        case " $TRIED " in *" $PORT "*) continue ;; esac
        if bbr_measure_tcp_open "$QUENCH_PERF_PEER" "$PORT"; then
            printf '%s\n' "$PORT"; return 0
        fi
        bbr_measure_log "[retry_tcp_unreachable] peer=$QUENCH_PERF_PEER port=$PORT" || return 1
    done <<< "${QUENCH_PERF_PORTS:-}"
    return 1
}

bbr_measure_connect() {
    local HOST="$1" PORT="$2" FAMILY="$3" INPUT
    while true; do
        if [ -z "$HOST" ]; then
            bbr_measure_pick_peer "$FAMILY" && return 0
        else
            QUENCH_PERF_PORTS=""
            QUENCH_PERF_PORT=$PORT
            if QUENCH_PERF_PEER=$(bbr_measure_resolve "$HOST" "$FAMILY"); then
                bbr_measure_peer_ready "$QUENCH_PERF_PEER" "$PORT" "$FAMILY" && return 0
                info "等待 3 秒后重试指定端口"; sleep 3
                bbr_measure_peer_ready "$QUENCH_PERF_PEER" "$PORT" "$FAMILY" && return 0
            else
                bbr_measure_log "[dns_failed] host=$HOST family=$FAMILY" || return 1
            fi
        fi
        warn "对端不可用，可以更换节点；尚未修改网络参数"
        while true; do
            read -rp "  新对端（回车重选公共节点，0退出）: " INPUT || return 1
            [ "$INPUT" != 0 ] || return 1
            if [ -z "$INPUT" ]; then HOST=""; PORT=5201; break; fi
            if bbr_measure_endpoint "$INPUT"; then
                HOST=$QUENCH_PERF_INPUT_HOST; PORT=$QUENCH_PERF_INPUT_PORT; break
            fi
            error "主机或端口无效，请重新输入"
        done
    done
}

bbr_measure_sample_retry() {
    local PEER="$1" FIRST="$2" FAMILY="$3" ROUND PORT PORTS SEEN
    FIRST=${QUENCH_PERF_PORT:-$FIRST}
    PORTS="${QUENCH_PERF_PORTS:-}"
    for ((ROUND=1; ROUND<=${QUENCH_PERF_SAMPLE_ROUNDS:-3}; ROUND++)); do
        SEEN=""
        for PORT in $FIRST $PORTS; do
            case " $SEEN " in *" $PORT "*) continue ;; esac
            SEEN="$SEEN $PORT"
            if bbr_calibration_measure_once "$PEER" "$PORT" "$FAMILY" "$4" "$5" "$6"; then
                QUENCH_PERF_PORT=$PORT
                return 0
            fi
            [ "${QUENCH_PERF_RETRYABLE:-0}" = 1 ] || return 1
        done
        [ "$ROUND" = "${QUENCH_PERF_SAMPLE_ROUNDS:-3}" ] && break
        warn "本轮端口均未获得有效结果，等待 ${QUENCH_PERF_SAMPLE_WAIT:-8} 秒后重试（${ROUND}/${QUENCH_PERF_SAMPLE_ROUNDS:-3}）"
        sleep "${QUENCH_PERF_SAMPLE_WAIT:-8}"
    done
    return 1
}

bbr_measure_swap_active() {
    [ -r /proc/swaps ] || return 2
    awk 'NR>1 {found=1} END {exit !found}' /proc/swaps
}

bbr_measure_swap_advice() {
    local MEM RC=0 SIZE AVAILABLE
    MEM=$(bbr_physical_memory_mb)
    bbr_measure_uint "$MEM" 1 1024 || return 0
    bbr_measure_swap_active || RC=$?
    [ "$RC" = 1 ] || return 0
    warn "物理内存 ${MEM}MB，未启用 Swap；可增加内存紧张时的余量，但不会直接提高 TCP 吞吐。"
    echo "  可选创建 1–20GiB Swap，默认 2GiB；创建成功后设置 swappiness=10。输入 0 跳过。"
    while true; do
        read -rp "  Swap 大小 GiB（默认2，0跳过）: " SIZE || return 0
        SIZE=${SIZE:-2}
        [ "$SIZE" != 0 ] || return 0
        bbr_measure_uint "$SIZE" 1 20 && break
        error "请输入 1–20 或 0"
    done
    SIZE=$((10#$SIZE))
    AVAILABLE=$(df -Pm "$(dirname "$(swap_managed_path)")" | awk 'NR==2{print $4}')
    bbr_measure_uint "$AVAILABLE" 1 9999999 || return 1
    [ "$AVAILABLE" -ge "$((SIZE*1024+512))" ] || { error "磁盘不足，需额外保留 512MiB"; return 1; }
    swap_create_apply "$((SIZE*1024))" || return 1
    swap_set_swappiness_apply 10 || { error "Swap 已创建，但使用倾向设置失败"; return 1; }
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
        cap=mem*1048576/32; if(cap>268435456) cap=268435456
        if(cap<4194304) cap=4194304
        max=target; if(max<4194304) max=4194304; if(max>cap) max=cap
        def=1048576
        if(role=="mixed") def=2097152
        if(role=="bulk") {def=bdp; if(def<1048576) def=1048576; if(def>8388608) def=8388608}
        printf "%.0f %.0f %.0f\n",max,def,target
    }'
}

bbr_measure_generate_config() {
    local BW="$1" RTT="$2" MEM="$3" ROLE="$4" PLAN MAX DEFAULT TARGET LOWAT TCP_MEM
    PLAN=$(bbr_measure_buffer_plan "$BW" "$RTT" "$MEM" "$ROLE") || return 1
    read -r MAX DEFAULT TARGET <<< "$PLAN"
    printf '# Quench 实测方案：带宽基准=%sMbps 目标RTT=%sms 内存上限=%sMB 用途=%s\n' "$BW" "$RTT" "$MEM" "$ROLE"
    printf 'net.core.rmem_max = %s\nnet.core.wmem_max = %s\n' "$MAX" "$MAX"
    printf 'net.core.rmem_default = %s\nnet.core.wmem_default = %s\n' "$DEFAULT" "$DEFAULT"
    printf 'net.ipv4.tcp_rmem = 4096 %s %s\nnet.ipv4.tcp_wmem = 4096 %s %s\n' "$DEFAULT" "$MAX" "$DEFAULT" "$MAX"
    TCP_MEM=$(awk -v m="$MEM" 'BEGIN {
        pages=m*256; lo=int(pages/16); pressure=int(pages/8); hi=int(pages/4)
        if(lo<4096)lo=4096; if(pressure<8192)pressure=8192; if(hi<16384)hi=16384
        printf "%.0f %.0f %.0f",lo,pressure,hi
    }')
    printf 'net.ipv4.tcp_mem = %s\n' "$TCP_MEM"
    printf '%s\n' 'net.ipv4.tcp_window_scaling = 1' 'net.ipv4.tcp_moderate_rcvbuf = 1' \
        'net.ipv4.tcp_adv_win_scale = 1' \
        'net.core.netdev_max_backlog = 16384' 'net.core.netdev_budget = 600' \
        'net.core.optmem_max = 65536' 'net.core.somaxconn = 8192' \
        'net.ipv4.tcp_max_syn_backlog = 8192' 'net.ipv4.tcp_no_metrics_save = 0' \
        'net.ipv4.tcp_sack = 1' 'net.ipv4.tcp_dsack = 1' 'net.ipv4.tcp_timestamps = 1' \
        'net.ipv4.tcp_syncookies = 1' 'net.ipv4.tcp_tw_reuse = 1' \
        'net.ipv4.tcp_fin_timeout = 15' 'net.ipv4.tcp_keepalive_time = 600' \
        'net.ipv4.ip_local_port_range = 1024 65535' 'vm.min_free_kbytes = 32768' \
        'fs.file-max = 1000000' 'net.ipv4.tcp_fastopen = 3' \
        'net.ipv4.tcp_mtu_probing = 1' 'net.ipv4.tcp_slow_start_after_idle = 0'
    # 拥塞控制/FQ 和路由窗口由独立、可回读的应用函数负责。
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
    local LABEL="$1" STREAMS="$2" DURATION="${3:-10}"
    [ -n "${QUENCH_PERF_REPORT:-}" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LABEL" "$STREAMS" "$DURATION" "$BBR_CAL_SENDER" "$BBR_CAL_RECEIVER" "$BBR_CAL_RETRANS" "$BBR_CAL_LOSS" "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" \
        >> "$QUENCH_PERF_REPORT/samples.tsv"
}

bbr_measure_pair() {
    local LABEL="$1" STREAMS FAILED=0
    QUENCH_PERF_SINGLE=""; QUENCH_PERF_MULTI=""
    QUENCH_PERF_SINGLE_LOSS=""; QUENCH_PERF_MULTI_LOSS=""
    for STREAMS in 1 4; do
        bbr_measure_route_check || return 1
        if bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 10 "$STREAMS" "$LABEL"; then
            bbr_measure_record "$LABEL" "$STREAMS" || return 1
            printf '  %s %s流：接收 %sMbps，重传 %s，估算重传比例 %s%%\n' \
                "$LABEL" "$STREAMS" "$BBR_CAL_RECEIVER" "$BBR_CAL_RETRANS" "$BBR_CAL_LOSS"
            if [ "$STREAMS" = 1 ]; then
                QUENCH_PERF_SINGLE=$BBR_CAL_RECEIVER; QUENCH_PERF_SINGLE_LOSS=$BBR_CAL_LOSS
            else
                QUENCH_PERF_MULTI=$BBR_CAL_RECEIVER; QUENCH_PERF_MULTI_LOSS=$BBR_CAL_LOSS
            fi
        else
            FAILED=1
        fi
        sleep 3
    done
    return "$FAILED"
}

bbr_measure_probe() {
    local BW
    bbr_measure_route_check || return 1
    bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    bbr_calibration_capture_qdisc "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    QUENCH_PERF_RESTORE=1
    bbr_calibration_set_fq "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    # 自动带宽：10 秒四流，拿到有效样本即结束；失败重试由公共测量入口负责。
    if ! bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 10 4 "估计出口带宽"; then
        error "带宽测量失败，不猜测套餐速率"; return 1
    fi
    bbr_measure_record probe 4 10 || return 1
    BW=$(awk -v g="$BBR_CAL_RECEIVER" 'BEGIN {
        step=(g<50?1:(g<200?10:50)); v=int(g/step+0.5)*step
        if(v<1)v=1; printf "%.0f",v
    }')
    bbr_calibration_restore_qdisc || { error "测速后队列恢复失败，停止调优"; return 1; }
    QUENCH_PERF_RESTORE=0
    bbr_measure_uint "$BW" 1 100000 || return 1
    QUENCH_PERF_BW=$BW
    info "本轮出口估计：${BW}Mbps；用于参数推导，实际限速器另行扫描"
}

bbr_measure_estimate_gb() {
    awk -v b="$1" 'BEGIN {
        step=int(b/300+0.5)*10; if(step<20)step=20
        points=int(b*0.4/step)+1
        printf "%.1f",(b*10/8+b*0.4+(points+3)*b*12/8+b*10/8*2)/1024
    }'
}

bbr_measure_apply_core() {
    local CC=bbr
    bbr_preflight || return 1
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        CC=cubic; warn "内核没有 BBR，使用 cubic；不安装或替换内核"
    fi
    bbr_apply_sysctl "net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $CC" core || return 1
    bbr_fq_apply_interface "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN"
}

bbr_measure_cwnd() {
    local BW="$1" FAMILY="$QUENCH_PERF_FAMILY" ROUTE CURRENT
    if [ "$BW" -le 100 ]; then
        if [ -f "$CWND_STATE_FILE" ]; then bbr_remove_initcwnd_locked owned || return 1; fi
        info "带宽 ≤100Mbps，保留内核初始窗口，避免小带宽线路突发"
        return 0
    fi
    ROUTE=$(ip "-$FAMILY" route show default 2>/dev/null | awk 'NR==1 {print}')
    if [ -z "$ROUTE" ] || [ "$(bbr_route_token "$ROUTE" dev)" != "$QUENCH_PERF_DEV" ]; then
        warn "测速出口不对应主表默认路由，跳过初始窗口；其余参数继续应用"
        return 0
    fi
    if ! bbr_apply_initcwnd_route "$FAMILY" "$ROUTE" 32 32; then
        warn "当前网络环境不支持修改初始窗口，其余调优继续"
        return 0
    fi
    CURRENT=$(ip "-$FAMILY" route show default 2>/dev/null | awk 'NR==1 {print}')
    [ "$(bbr_route_token "$CURRENT" initcwnd)" = 32 ] && [ "$(bbr_route_token "$CURRENT" initrwnd)" = 32 ] || return 1
    bbr_cwnd_write_persistence "$FAMILY" 32 32 || return 1
    info "initcwnd / initrwnd = 32，已持久化"
}

bbr_measure_path_check() {
    local RATE=$(( $1 * 40 / 100 )) RC=0
    local QUENCH_PERF_SAMPLE_ROUNDS=2 QUENCH_PERF_SAMPLE_WAIT=5
    [ "$RATE" -ge 1 ] || RATE=1
    bbr_measure_route_check || return 1
    bbr_calibration_capture_qdisc "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    QUENCH_PERF_RESTORE=1
    bbr_calibration_apply_shaper "$QUENCH_PERF_DEV" "$RATE" "$BBR_CAL_TC_BIN" || return 1
    if bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 8 2 "40% 带宽线路检查"; then
        bbr_measure_record path 2 8 || return 1
        if awk -v l="$BBR_CAL_LOSS" 'BEGIN {exit !(l>0.05)}'; then
            warn "低速测试已有重传，路径本身可能丢包，拐点结果可能偏低"
        elif awk -v g="$BBR_CAL_RECEIVER" -v r="$RATE" 'BEGIN {exit !(g<r*0.7)}'; then
            warn "对端低于检查速率的 70%，后续扫描将判断是否足以得出结论"
        else info "线路检查通过"; fi
    else
        warn "线路预检查未取得样本，继续由拐点扫描判断"; RC=0
    fi
    bbr_calibration_restore_qdisc || return 1
    QUENCH_PERF_RESTORE=0
    return "$RC"
}

bbr_measure_verdict() {
    local TARGET LOSS STREAMS RATE LABEL
    TARGET=$(bbr_tc_current_rate "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN")
    info "验证完成：单流 ${QUENCH_PERF_SINGLE:-无有效样本}Mbps，四流 ${QUENCH_PERF_MULTI:-无有效样本}Mbps；当前整形 ${TARGET:-无}"
    for STREAMS in 1 4; do
        if [ "$STREAMS" = 1 ]; then LOSS=${QUENCH_PERF_SINGLE_LOSS:-}; RATE=${QUENCH_PERF_SINGLE:-}
        else LOSS=${QUENCH_PERF_MULTI_LOSS:-}; RATE=${QUENCH_PERF_MULTI:-}; fi
        [ -n "$LOSS" ] || continue
        if awk -v l="$LOSS" 'BEGIN {exit !(l<0.05)}'; then LABEL=干净
        elif awk -v l="$LOSS" 'BEGIN {exit !(l<0.5)}'; then LABEL=轻微重传
        elif awk -v l="$LOSS" 'BEGIN {exit !(l<1)}'; then LABEL=重传偏高
        else LABEL=严重重传; fi
        info "${STREAMS} 流：估算重传比例 ${LOSS}%（${LABEL}）"
        if awk -v t="$TARGET" 'BEGIN {exit !(t+0>0)}'; then
            awk -v r="$RATE" -v t="$TARGET" 'BEGIN {printf "  接收吞吐为当前整形速率的 %.1f%%\n",r*100/t}'
        fi
    done
}

bbr_measure_cleanup() {
    local RC=$?
    trap - EXIT
    trap '' INT TERM HUP
    bbr_calibration_stop_child
    bbr_measure_probe_wait
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
    export LC_ALL=C
    local MEM CONFIG BW ESTIMATE SCAN_RC=0 STATUS RECOMMEND PREVIOUS UNSHAPED SKIP_VERIFY=0
    QUENCH_PERF_PEER=$HOST; QUENCH_PERF_PORT=$PORT; QUENCH_PERF_FAMILY=$FAMILY
    QUENCH_PERF_WIZARD=1
    QUENCH_PERF_PORTS=""; QUENCH_PERF_PROBE_PIDS=""
    QUENCH_PERF_DEV=""; QUENCH_PERF_REPORT=""; QUENCH_PERF_RESTORE=0
    QUENCH_PERF_SINGLE=""; QUENCH_PERF_MULTI=""; QUENCH_PERF_BW=""
    QUENCH_TMP_REGISTRY=""
    txn_write_begin "网络调优向导" || exit 1
    trap bbr_measure_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    quench_tmp_registry_init || exit 1
    bbr_calibration_lock_acquire || exit 1
    bbr_measure_dependencies || exit 1
    mkdir -p "$QUENCH_PERF_REPORT_DIR" || exit 1
    chmod 700 "$QUENCH_PERF_REPORT_DIR" || exit 1
    QUENCH_PERF_REPORT=$(mktemp -d "$QUENCH_PERF_REPORT_DIR/run-$(date +%Y%m%d-%H%M%S).XXXXXX") || exit 1
    printf 'phase\tstreams\tduration_seconds\tsender_mbps\treceiver_mbps\tretransmits\testimated_retrans_pct\tpeer\tport\n' > "$QUENCH_PERF_REPORT/samples.tsv" || exit 1
    printf 'requested_host=%s\nrequested_port=%s\nfamily=%s\n' "$HOST" "$PORT" "$FAMILY" > "$QUENCH_PERF_REPORT/context.txt" || exit 1
    if [ "${QUENCH_PERF_HAVE_IPERF:-1}" = 0 ]; then
        [ "$MODE" = tune ] && [ -n "$NOMINAL" ] || { error "无 iperf3 时需要手填带宽，只能做基础调优"; exit 1; }
        SHAPE=keep; SKIP_VERIFY=1
        QUENCH_PERF_DEV=$(ip "-$FAMILY" route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
    else
        bbr_measure_connect "$HOST" "$PORT" "$FAMILY" || exit 1
        QUENCH_PERF_DEV=$(bbr_measure_iface "$QUENCH_PERF_PEER" "$FAMILY") || exit 1
    fi
    [ -n "$QUENCH_PERF_DEV" ] || exit 1
    BBR_CAL_DEV=$QUENCH_PERF_DEV; BBR_CAL_TC_BIN=$(command -v tc)
    bbr_calibration_traffic_mark "$QUENCH_PERF_DEV"
    printf 'peer=%s\nport=%s\nfamily=%s\ndev=%s\nmode=%s\nnominal=%s\ntarget_rtt=%s\nrole=%s\nversion=%s\nshaping=%s\n' \
        "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$FAMILY" "$QUENCH_PERF_DEV" "$MODE" "$NOMINAL" "$RTT" "$ROLE" "$APP_VERSION" "$SHAPE" >> "$QUENCH_PERF_REPORT/context.txt" || exit 1
    if [ "$MODE" = verify ]; then
        bbr_measure_pair verify || exit 1
        bbr_measure_verdict
        info "验证未修改网络参数或队列"
        exit 0
    fi
    bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || exit 1
    BW=$NOMINAL
    if [ "$MODE" = tune ]; then
        bbr_runtime_snapshot "$QUENCH_PERF_REPORT/before.conf" || exit 1
        bbr_default_routes > "$QUENCH_PERF_REPORT/routes-before.txt" || exit 1
        if [ -f "$SYSCTL_FILE" ]; then cp "$SYSCTL_FILE" "$QUENCH_PERF_REPORT/saved-before.conf" || exit 1; fi
        bbr_backup_sysctl || exit 1
        info "[1/5] 基础调优"
        BW=$NOMINAL
        if [ -z "$BW" ]; then
            bbr_measure_probe || exit 1
            BW=$QUENCH_PERF_BW
            ESTIMATE=$(bbr_measure_estimate_gb "$BW")
            info "按实测带宽估计，扫描和验证约 ${ESTIMATE}GiB"
            if [ "$SHAPE" = auto ] && awk -v n="$ESTIMATE" 'BEGIN {exit !(n>50)}'; then
                if ! bbr_measure_yes "预计流量超过 50GiB，继续扫描和验证？(y/N):" n; then
                    SHAPE=keep; SKIP_VERIFY=1
                fi
            fi
        fi
        MEM=$(bbr_physical_memory_mb)
        CONFIG=$(bbr_measure_generate_config "$BW" "$RTT" "$MEM" "$ROLE") || exit 1
        printf '%s\n' "$CONFIG" > "$QUENCH_PERF_REPORT/proposed.conf" || exit 1
        printf 'measured_mbps=%s\nbuffer_basis_mbps=%s\n' "$QUENCH_PERF_BW" "$BW" >> "$QUENCH_PERF_REPORT/context.txt" || exit 1
        if [ "$CORE" = y ]; then bbr_measure_apply_core || exit 1; fi
        bbr_apply_sysctl "$CONFIG" measured || exit 1
        bbr_measure_cwnd "$BW" || { error "基础参数已应用，但初始窗口持久化未完成"; exit 1; }
    fi
    case "$SHAPE" in y) SHAPE=auto ;; n) SHAPE=keep ;; esac
    if [ "$SHAPE" = auto ]; then
        info "[2/5] 40% 带宽检查路径"
        bbr_measure_path_check "$BW" || exit 1
        info "[3/5] 实测限速器拐点"
        QUENCH_PERF_AGREED_GB=$(bbr_measure_estimate_gb "$BW")
        bbr_sweep_run "$BW" || SCAN_RC=$?
        [ "$SCAN_RC" = 0 ] || { error "基础参数已应用，但扫描失败；已有整形已尝试恢复，请查看报告"; exit 1; }
        STATUS=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" STATUS)
        case "$STATUS" in
            KNEE|NO_KNEE|CANCELLED|INCONCLUSIVE|ABOVE_CAP|OUT_OF_RANGE) : ;;
            *) error "本轮扫描结果无效，保留原整形"; exit 1 ;;
        esac
        UNSHAPED=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" UNSHAPED_MBPS)
        PREVIOUS=$(bbr_state_value "$TC_STATE_FILE" RATE 2>/dev/null || true)
        if [ "$STATUS" = NO_KNEE ] && [ -n "$PREVIOUS" ] && \
            awk -v u="$UNSHAPED" -v p="$PREVIOUS" 'BEGIN {exit !(p>0 && u<p*0.7)}'; then
            STATUS=INCONCLUSIVE
            bbr_calibration_write_result "$STATUS" "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$FAMILY" "$BW" "$UNSHAPED" || exit 1
        fi
        cp "$BBR_CALIBRATION_RESULT_FILE" "$QUENCH_PERF_REPORT/calibration.state" || exit 1
        info "[4/5] 根据本轮结果处理整形：$STATUS"
        case "$STATUS" in
            KNEE)
                RECOMMEND=$(bbr_state_value "$BBR_CALIBRATION_RESULT_FILE" RECOMMEND_MBPS)
                bbr_tc_apply_selected_rate "$QUENCH_PERF_DEV" "$RECOMMEND" || exit 1
                sleep 15 ;;
            NO_KNEE)
                bbr_tc_remove_selected "$QUENCH_PERF_DEV" || exit 1 ;;
            CANCELLED) SKIP_VERIFY=1 ;;
            *)
                warn "本轮未取得可用拐点，保留已有整形"
                case "$STATUS" in ABOVE_CAP|OUT_OF_RANGE) sleep 15 ;; esac ;;
        esac
    elif [ "$SHAPE" = off ]; then
        info "按选择关闭 Quench 整形，保留 FQ"
        bbr_tc_remove_selected "$QUENCH_PERF_DEV" || exit 1
    elif [ "$SHAPE" != keep ]; then
        bbr_measure_uint "$SHAPE" 1 100000 || exit 1
        bbr_tc_apply_selected_rate "$QUENCH_PERF_DEV" "$SHAPE" || exit 1
        sleep 15
    fi
    if [ "$SKIP_VERIFY" = 0 ]; then
        info "[5/5] 验证最终状态：10 秒单流 + 10 秒四流"
        bbr_measure_pair after || { error "配置已应用，但验证未完成；请查看报告"; exit 1; }
        bbr_measure_verdict
    else
        info "本轮仅应用基础方案，已跳过扫描和验证"
    fi
    if [ "$MODE" = tune ]; then
        bbr_runtime_snapshot "$QUENCH_PERF_REPORT/after.conf" || exit 1
        bbr_measure_swap_advice || exit 1
    fi
    bbr_calibration_traffic_report "$QUENCH_PERF_DEV"
    info "网络调优完成；参数备份、有效样本与实际状态已保存"
)

bbr_measure_endpoint() {
    local INPUT="$1" HOST="$1" PORT=5201
    case "$INPUT" in
        \[*\]:*) PORT=${INPUT##*]:}; HOST=${INPUT%%]:*}; HOST=${HOST#\[} ;;
        \[*\]) HOST=${INPUT#\[}; HOST=${HOST%\]} ;;
        *:*:*) : ;;
        *:*) PORT=${INPUT##*:}; HOST=${INPUT%:*} ;;
    esac
    bbr_calibration_host_valid "$HOST" && bbr_calibration_port_valid "$PORT" || return 1
    QUENCH_PERF_INPUT_HOST=$HOST; QUENCH_PERF_INPUT_PORT=$PORT
}

bbr_measure_menu() {
    local MODE="${1:-tune}" HOST="" PORT=5201 FAMILY NOMINAL="" ROLE=proxy SHAPE=auto INPUT RTT=150 CORE=y
    local LC_ALL=C
    export LC_ALL
    print_header "一键网络调优"
    echo "  带宽 → 测速对端 → 机器用途；确认后自动完成基础参数、扫描、整形和验证。"
    echo "  RTT 使用 150ms 的业务估计值，不用近端测速延迟冒充业务延迟。"
    FAMILY=$(bbr_measure_default_family)
    if [ -n "$(ip -4 route show default 2>/dev/null)" ] && [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
        while true; do
            read -rp "  双栈机器，选择测速协议 4/6（默认4）: " INPUT || return 1
            case "$INPUT" in ''|4|v4) FAMILY=4; break ;; 6|v6) FAMILY=6; break ;; *) error "请输入 4 或 6" ;; esac
        done
    fi
    info "测速协议：IPv${FAMILY}"
    QUENCH_PERF_HAVE_IPERF=1
    bbr_measure_dependencies || return 1
    if [ "$MODE" = tune ]; then
        echo "  1. 带宽：手填套餐值 / 回车实测 / 0 不整形 / m 手动指定整形值"
        while true; do
            read -rp "  带宽（支持 400M / 600M / 1G）: " INPUT || return 1
            case "$INPUT" in
                '') [ "$QUENCH_PERF_HAVE_IPERF" = 1 ] && break; error "没有 iperf3，请手填带宽" ;;
                0) [ "$QUENCH_PERF_HAVE_IPERF" = 1 ] || { error "没有 iperf3，请手填带宽"; continue; }; SHAPE=off; break ;;
                m|M)
                    read -rp "  指定整形速率（0 不整形）: " INPUT || return 1
                    if [ "$INPUT" = 0 ]; then
                        [ "$QUENCH_PERF_HAVE_IPERF" = 1 ] || continue
                        SHAPE=off; break
                    fi
                    NOMINAL=$(bbr_parse_bandwidth_mbps "$INPUT") || { error "无效带宽"; continue; }
                    SHAPE=$NOMINAL; break ;;
                *)
                    NOMINAL=$(bbr_parse_bandwidth_mbps "$INPUT") && break
                    error "请输入有效带宽或 m / 0" ;;
            esac
        done
    else
        [ "$QUENCH_PERF_HAVE_IPERF" = 1 ] || { error "性能验证需要 iperf3"; return 1; }
        CORE=n; SHAPE=keep
    fi
    if [ "$QUENCH_PERF_HAVE_IPERF" = 1 ]; then
        echo "  2. 测速对端：回车使用公共候选；自有对端填写 IP、域名或 host:端口 / [IPv6]:端口"
        while true; do
            read -rp "  iperf3 对端（默认公共节点）: " INPUT || return 1
            [ -n "$INPUT" ] || break
            if bbr_measure_endpoint "$INPUT"; then
                HOST=$QUENCH_PERF_INPUT_HOST; PORT=$QUENCH_PERF_INPUT_PORT; break
            fi
            error "主机或端口无效，请重新输入"
        done
    else
        SHAPE=keep
        warn "iperf3 不可用：仅应用手填带宽推导的基础参数，不做测速或整形"
    fi
    if [ "$MODE" = tune ]; then
        while true; do
            read -rp "  3. 用途：1 代理/加速（默认） 2 大文件/备份 3 网站/API/混合: " INPUT || return 1
            case "$INPUT" in ''|1) ROLE=proxy; break ;; 2) ROLE=bulk; break ;; 3) ROLE=mixed; break ;; *) error "请选择 1、2 或 3" ;; esac
        done
        echo "  将应用完整 TCP 参数；带宽 >100Mbps 时设置初始窗口 32，≤100Mbps 移除 Quench 窗口设置。"
        echo "  自动整形会按本轮拐点应用速率，确认无拐点时取消旧 Quench 整形；测不准则保留。"
    fi
    if [ -n "$NOMINAL" ]; then info "带宽 ${NOMINAL}Mbps；完整扫描估计约 $(bbr_measure_estimate_gb "$NOMINAL")GiB（重试可能更多）"
    else warn "自动测量后才能估计流量，整套测试可能消耗数十至数百 GiB"; fi
    echo "  会连接所选对端或公共节点；公共节点将看到本机 IP。"
    bbr_measure_yes "确认按上述方案开始？(Y/n):" y || return 0
    bbr_measure_session "$MODE" "$HOST" "$PORT" "$FAMILY" "$NOMINAL" "$RTT" "$ROLE" "$CORE" "$SHAPE"
}
