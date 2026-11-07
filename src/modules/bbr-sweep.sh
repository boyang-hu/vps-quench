# Quench 实测限速器扫描。采样状态只在本轮向导子 shell 内使用。
# 扫描阶段只写结果；持久化整形由向导统一处理。
# 参数公式及扫描流程按 tcpfit v0.5.9（38fbf5af30daf87735f2ffbc5e0905033ee2b86e）适配。
# https://github.com/Kylin010/tcpfit
#
# MIT License
# Copyright (c) 2026 Kylin010
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

bbr_sweep_finish() {
    local STATUS="$1" BW="$2" GOOD="$3" KNEE="${4:-}" RATE="${5:-}"
    bbr_calibration_write_result "$STATUS" "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" \
        "$QUENCH_PERF_FAMILY" "$BW" "$GOOD" "$KNEE" "$RATE" || return 1
    bbr_calibration_restore_qdisc || return 1
    QUENCH_PERF_RESTORE=0
}

bbr_sweep_sample() {
    bbr_calibration_measure "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" 12 "${1:-1}" "$2" || return 1
    bbr_measure_record "$2" "${1:-1}" 12
}

bbr_sweep_spike() {
    bbr_calibration_is_spike "$1" "${QUENCH_SWEEP_BASE:-0}"
}

# 粗/细扫共用判定：超过 0.1% / 五倍本底（阈值封顶 1%）时复核，三次至少两次。
bbr_sweep_range() {
    local LOW="$1" HIGH="$2" STEP="$3" RATE HITS TRY CLEAN_RATE CLEAN_LOSS CLEAN_RETRANS MIN_LOSS
    [ "$LOW" -le "$HIGH" ] || return 0
    RATE=$LOW
    while [ "$RATE" -le "$HIGH" ]; do
        bbr_measure_route_check || return 1
        if ! bbr_calibration_apply_shaper "$QUENCH_PERF_DEV" "$RATE" "$BBR_CAL_TC_BIN"; then
            QUENCH_SWEEP_INCOMPLETE=1
            warn "${RATE}Mbps 临时整形失败，本档不能计入已验证范围"
            return 1
        elif ! bbr_sweep_sample 1 "scan-${RATE}"; then
            QUENCH_SWEEP_INCOMPLETE=1
            warn "${RATE}Mbps 未取得有效样本"
        else
            if [ -z "$QUENCH_SWEEP_BASE" ] && awk -v l="$BBR_CAL_LOSS" 'BEGIN {exit !(l<=0.1)}'; then
                QUENCH_SWEEP_BASE=$BBR_CAL_LOSS
            fi
            if bbr_sweep_spike "$BBR_CAL_LOSS"; then
                HITS=1; MIN_LOSS=$BBR_CAL_LOSS; CLEAN_RATE=""; CLEAN_LOSS=""; CLEAN_RETRANS=""
                for TRY in 2 3; do
                    sleep 3
                    bbr_sweep_sample 1 "recheck-${RATE}-${TRY}" || continue
                    if awk -v a="$BBR_CAL_LOSS" -v b="$MIN_LOSS" 'BEGIN {exit !(a<b)}'; then MIN_LOSS=$BBR_CAL_LOSS; fi
                    if bbr_sweep_spike "$BBR_CAL_LOSS"; then HITS=$((HITS+1))
                    else
                        CLEAN_RATE=$BBR_CAL_RECEIVER; CLEAN_LOSS=$BBR_CAL_LOSS; CLEAN_RETRANS=$BBR_CAL_RETRANS
                        [ -n "$QUENCH_SWEEP_BASE" ] || QUENCH_SWEEP_BASE=$CLEAN_LOSS
                    fi
                done
                if [ "$HITS" -ge 2 ]; then
                    QUENCH_SWEEP_BROKE=$RATE; QUENCH_SWEEP_SPIKE_MIN=$MIN_LOSS
                    info "${RATE}Mbps：${HITS}/3 次出现重传跳变"
                    return 0
                fi
                if [ -z "$CLEAN_RATE" ]; then
                    QUENCH_SWEEP_INCOMPLETE=1
                    RATE=$((RATE+STEP)); sleep 3; continue
                fi
                BBR_CAL_RECEIVER=$CLEAN_RATE; BBR_CAL_LOSS=$CLEAN_LOSS; BBR_CAL_RETRANS=$CLEAN_RETRANS
            fi
            printf '  %sMbps → 接收 %sMbps，重传 %s，估算比例 %s%%\n' "$RATE" "$BBR_CAL_RECEIVER" "$BBR_CAL_RETRANS" "$BBR_CAL_LOSS"
            if awk -v g="$BBR_CAL_RECEIVER" -v r="$RATE" -v l="$BBR_CAL_LOSS" 'BEGIN {exit !(g<r*0.7 && l<=0.1)}'; then
                QUENCH_SWEEP_SLOW=$((QUENCH_SWEEP_SLOW+1))
                if [ "$QUENCH_SWEEP_SLOW" -ge 3 ]; then QUENCH_SWEEP_TOO_SLOW=1; return 0; fi
            else QUENCH_SWEEP_SLOW=0; fi
            QUENCH_SWEEP_LAST=$RATE
        fi
        [ "$RATE" -lt "$HIGH" ] || break
        RATE=$((RATE+STEP)); [ "$RATE" -le "$HIGH" ] || RATE=$HIGH
        sleep 3
    done
}

bbr_sweep_run() {
    local BW="$1" GOOD SENDER RETRANS LOSS ATTEMPT AGG LOW HIGH STEP POINTS GB REASON=""
    local KNOWN_BROKE KNOWN_LOSS CONTROL CONTROL_LOSS COARSE_BROKE WIDTH FINE MARGIN RECOMMEND
    QUENCH_SWEEP_BASE=""; QUENCH_SWEEP_LAST=""; QUENCH_SWEEP_BROKE=""; QUENCH_SWEEP_SPIKE_MIN=""
    QUENCH_SWEEP_INCOMPLETE=0; QUENCH_SWEEP_SLOW=0; QUENCH_SWEEP_TOO_SLOW=0
    bbr_measure_queue_guard "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    bbr_calibration_capture_qdisc "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    QUENCH_PERF_RESTORE=1
    bbr_calibration_write_result RUNNING "$QUENCH_PERF_PEER" "$QUENCH_PERF_PORT" "$QUENCH_PERF_FAMILY" "$BW" 0 || return 1
    bbr_calibration_set_fq "$QUENCH_PERF_DEV" "$BBR_CAL_TC_BIN" || return 1
    if ! bbr_sweep_sample 1 unshaped; then
        bbr_sweep_finish ERROR "$BW" 0 || return 1
        return 2
    fi
    GOOD=$BBR_CAL_RECEIVER; SENDER=$BBR_CAL_SENDER; RETRANS=$BBR_CAL_RETRANS; LOSS=$BBR_CAL_LOSS
    if [ "$BW" -lt 2500 ] && awk -v g="$GOOD" -v b="$BW" 'BEGIN {exit !(g<b*0.7)}'; then
        for ATTEMPT in 2 3; do
            sleep 3
            bbr_sweep_sample 1 "unshaped-${ATTEMPT}" || continue
            if awk -v now="$BBR_CAL_RECEIVER" -v best="$GOOD" 'BEGIN {exit !(now>best)}'; then
                GOOD=$BBR_CAL_RECEIVER; SENDER=$BBR_CAL_SENDER; RETRANS=$BBR_CAL_RETRANS; LOSS=$BBR_CAL_LOSS
            fi
        done
    fi
    if [ "$BW" -ge 2500 ] && awk -v g="$GOOD" -v l="$LOSS" 'BEGIN {exit !(g<=10000 && l>0.1)}'; then
        if bbr_sweep_sample 8 unshaped-aggregate; then
            AGG=$BBR_CAL_RECEIVER
            if awk -v g="$AGG" 'BEGIN {exit !(g>10000)}'; then
                bbr_sweep_finish ABOVE_CAP "$BW" "$AGG"; return $?
            fi
            if awk -v l="$BBR_CAL_LOSS" 'BEGIN {exit !(l<=0.1)}'; then
                if awk -v g="$AGG" -v b="$BW" 'BEGIN {exit !(g<b*0.7)}'; then
                    bbr_sweep_finish INCONCLUSIVE "$BW" "$AGG"
                else bbr_sweep_finish NO_KNEE "$BW" "$AGG"; fi
                return $?
            fi
        fi
    fi
    if awk -v g="$GOOD" 'BEGIN {exit !(g>10000)}'; then bbr_sweep_finish ABOVE_CAP "$BW" "$GOOD"; return $?; fi
    if awk -v l="$LOSS" 'BEGIN {exit !(l<=0.1)}'; then
        if awk -v g="$GOOD" -v b="$BW" 'BEGIN {exit !(g<b*0.7)}'; then
            bbr_sweep_finish INCONCLUSIVE "$BW" "$GOOD"
        else bbr_sweep_finish NO_KNEE "$BW" "$GOOD"; fi
        return $?
    fi
    BBR_CAL_RECEIVER=$GOOD; BBR_CAL_SENDER=$SENDER; BBR_CAL_RETRANS=$RETRANS; BBR_CAL_LOSS=$LOSS
    LOW=$(awk -v g="$GOOD" 'BEGIN {v=int(g*0.95); if(v<1)v=1; print v}')
    HIGH=$(awk -v g="$GOOD" -v l="$LOSS" 'BEGIN {k=1.25+l/100*2; if(k>2.5)k=2.5; v=int(g*k); if(v>10000)v=10000; print v}')
    [ "$HIGH" -gt "$LOW" ] || HIGH=$((LOW+2))
    STEP=$(awk -v lo="$LOW" -v hi="$HIGH" 'BEGIN {s=int((hi-lo)/10+0.5); if(s<1)s=1; print s}')
    POINTS=$(((HIGH-LOW)/STEP+10))
    GB=$(awk -v p="$POINTS" -v lo="$LOW" -v hi="$HIGH" 'BEGIN {printf "%.0f",p*(lo+hi)/2*12/8/1024}')
    if awk -v g="$GOOD" -v n="$BW" 'BEGIN {exit !(g>n*3)}'; then REASON=over
    elif awk -v g="$GB" -v a="${QUENCH_PERF_AGREED_GB:-0}" 'BEGIN {exit !(g>50 && (a==0 || g>a*1.5))}'; then REASON=large; fi
    if [ -n "$REASON" ]; then
        warn "按实际吞吐推算，扫描约 ${GB}GiB，超过先前预期"
        if ! bbr_measure_yes "继续扫描？(y/N，取消也会跳过后续验证):" n; then
            bbr_sweep_finish CANCELLED "$BW" "$GOOD"; return $?
        fi
    fi
    info "扫描 ${LOW}-${HIGH}Mbps，步长 ${STEP}Mbps；每档 12 秒，冷却 15 秒后开始"
    sleep 15
    bbr_sweep_range "$LOW" "$HIGH" "$STEP" || return 1
    if [ -z "$QUENCH_SWEEP_LAST" ] && [ -n "$QUENCH_SWEEP_BROKE" ]; then
        KNOWN_BROKE=$QUENCH_SWEEP_BROKE; KNOWN_LOSS=$QUENCH_SWEEP_SPIKE_MIN
        for ATTEMPT in 1 2 3; do
            CONTROL=$((KNOWN_BROKE*3/4)); [ "$CONTROL" -ge 1 ] || CONTROL=1
            [ "$CONTROL" -lt "$KNOWN_BROKE" ] || break
            QUENCH_SWEEP_LAST=""; QUENCH_SWEEP_BROKE=""; QUENCH_SWEEP_BASE=""; QUENCH_SWEEP_SPIKE_MIN=""
            bbr_sweep_range "$CONTROL" "$CONTROL" 1 || return 1
            if [ -n "$QUENCH_SWEEP_LAST" ]; then QUENCH_SWEEP_BROKE=$KNOWN_BROKE; break; fi
            CONTROL_LOSS=$QUENCH_SWEEP_SPIKE_MIN
            if [ -n "$CONTROL_LOSS" ] && [ -n "$KNOWN_LOSS" ] && awk -v a="$CONTROL_LOSS" -v b="$KNOWN_LOSS" 'BEGIN {
                d=a-b; if(d<0)d=-d; exit !(a<=0.5 && b<=0.5 && d<=0.1)
            }'; then
                QUENCH_SWEEP_BASE=$(awk -v a="$CONTROL_LOSS" -v b="$KNOWN_LOSS" 'BEGIN {print (a<b?a:b)}')
                QUENCH_SWEEP_LAST=$CONTROL; QUENCH_SWEEP_BROKE=""
                bbr_sweep_range "$KNOWN_BROKE" "$HIGH" "$STEP" || return 1
                break
            fi
            [ -n "$CONTROL_LOSS" ] || break
            KNOWN_BROKE=$CONTROL; KNOWN_LOSS=$CONTROL_LOSS
        done
    fi
    if [ "$QUENCH_SWEEP_TOO_SLOW" = 1 ]; then
        warn "连续三档低于目标 70%，可能是对端、路径或本机 HTB 性能不足"
        bbr_sweep_finish INCONCLUSIVE "$BW" "$GOOD"; return $?
    fi
    if [ -n "$QUENCH_SWEEP_LAST" ] && [ -n "$QUENCH_SWEEP_BROKE" ]; then
        COARSE_BROKE=$QUENCH_SWEEP_BROKE; WIDTH=$((COARSE_BROKE-QUENCH_SWEEP_LAST))
        if [ "$WIDTH" -gt 1 ]; then
            FINE=$((STEP/4)); [ "$FINE" -ge $(((WIDTH+7)/8)) ] || FINE=$(((WIDTH+7)/8))
            [ "$FINE" -ge 1 ] || FINE=1
            QUENCH_SWEEP_BROKE=""
            bbr_sweep_range "$((QUENCH_SWEEP_LAST+FINE))" "$((COARSE_BROKE-FINE))" "$FINE" || return 1
            [ -n "$QUENCH_SWEEP_BROKE" ] || QUENCH_SWEEP_BROKE=$COARSE_BROKE
        fi
    fi
    if [ "$QUENCH_SWEEP_INCOMPLETE" = 1 ] || [ "$QUENCH_SWEEP_TOO_SLOW" = 1 ] || [ -z "$QUENCH_SWEEP_LAST" ]; then
        bbr_sweep_finish INCONCLUSIVE "$BW" "$GOOD"; return $?
    fi
    if [ -z "$QUENCH_SWEEP_BROKE" ]; then bbr_sweep_finish OUT_OF_RANGE "$BW" "$GOOD"; return $?; fi
    MARGIN=$(bbr_calibration_margin "$BW") || return 1
    RECOMMEND=$((QUENCH_SWEEP_LAST-MARGIN)); [ "$RECOMMEND" -ge 1 ] || RECOMMEND=$QUENCH_SWEEP_LAST
    info "干净上限 ${QUENCH_SWEEP_LAST}Mbps，按带宽档位退让 ${MARGIN}Mbps，建议 ${RECOMMEND}Mbps"
    bbr_sweep_finish KNEE "$BW" "$GOOD" "$QUENCH_SWEEP_LAST" "$RECOMMEND"
}
