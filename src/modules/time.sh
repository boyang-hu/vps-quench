# ══════════════════════════════════════════════════════════
#  时间、时区与 NTP 诊断修复模块
# ══════════════════════════════════════════════════════════

ts_current_timezone() {
    local ZONE="" TARGET=""
    if systemd_available && command -v timedatectl >/dev/null 2>&1; then
        ZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    fi
    if [ -z "$ZONE" ] && [ -s /etc/timezone ]; then
        ZONE=$(awk 'NF {print; exit}' /etc/timezone 2>/dev/null || true)
    fi
    if [ -z "$ZONE" ] && [ -L /etc/localtime ]; then
        TARGET=$(readlink -f /etc/localtime 2>/dev/null || readlink /etc/localtime 2>/dev/null || true)
        case "$TARGET" in */zoneinfo/*) ZONE=${TARGET#*/zoneinfo/} ;; esac
    fi
    printf '%s\n' "${ZONE:-$(date '+%Z' 2>/dev/null || echo 未知)}"
}

ts_timezone_syntax_valid() {
    local ZONE="$1"
    case "$ZONE" in
        UTC|Etc/UTC) return 0 ;;
        ""|/*|*..*|*//*|*[!A-Za-z0-9_+./-]*) return 1 ;;
    esac
    printf '%s\n' "$ZONE" | grep -qE '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'
}

ts_timezone_valid() {
    local ZONE="$1" BASE="" TARGET=""
    ts_timezone_syntax_valid "$ZONE" || return 1
    if systemd_available && command -v timedatectl >/dev/null 2>&1 \
        && timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$ZONE"; then
        return 0
    fi
    [ -e "/usr/share/zoneinfo/${ZONE}" ] || return 1
    BASE=$(readlink -f /usr/share/zoneinfo 2>/dev/null || printf '/usr/share/zoneinfo')
    TARGET=$(readlink -f "/usr/share/zoneinfo/${ZONE}" 2>/dev/null || true)
    [ -n "$TARGET" ] || return 1
    case "$TARGET" in "$BASE"/*) return 0 ;; *) return 1 ;; esac
}

ts_timesyncd_available() {
    systemd_available || return 1
    command -v timedatectl >/dev/null 2>&1 || return 1
    systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '$1 == "systemd-timesyncd.service" {found=1} END {exit !found}'
}

ts_timesyncd_active() {
    systemd_available && systemctl is-active --quiet systemd-timesyncd 2>/dev/null
}

ts_chrony_service() {
    local SERVICE=""
    for SERVICE in chrony chronyd; do
        svc_is_active "$SERVICE" 2>/dev/null && { printf '%s\n' "$SERVICE"; return 0; }
    done
    if systemd_available; then
        for SERVICE in chrony chronyd; do
            systemctl list-unit-files --no-legend 2>/dev/null \
                | awk -v unit="${SERVICE}.service" '$1 == unit {found=1} END {exit !found}' \
                && { printf '%s\n' "$SERVICE"; return 0; }
        done
    fi
    for SERVICE in chrony chronyd; do
        [ -x "/etc/init.d/${SERVICE}" ] && { printf '%s\n' "$SERVICE"; return 0; }
    done
    command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1 || return 1
    if [ -f /etc/debian_version ]; then printf 'chrony\n'; else printf 'chronyd\n'; fi
}

ts_chrony_active() {
    svc_is_active chrony 2>/dev/null || svc_is_active chronyd 2>/dev/null
}

ts_external_ntp_service() {
    local SERVICE=""
    for SERVICE in ntp ntpd openntpd; do
        svc_is_active "$SERVICE" 2>/dev/null && { printf '%s\n' "$SERVICE"; return 0; }
    done
    return 1
}

ts_backend_detect() {
    local TIMESYNCD=0 CHRONY=0 EXTERNAL=""
    ts_timesyncd_active && TIMESYNCD=1
    ts_chrony_active && CHRONY=1
    EXTERNAL=$(ts_external_ntp_service 2>/dev/null || true)
    if [ $((TIMESYNCD + CHRONY)) -gt 1 ] \
        || { [ -n "$EXTERNAL" ] && [ $((TIMESYNCD + CHRONY)) -gt 0 ]; }; then
        printf 'conflict\n'
    elif [ "$CHRONY" -eq 1 ]; then
        printf 'chrony\n'
    elif [ "$TIMESYNCD" -eq 1 ]; then
        printf 'timesyncd\n'
    elif [ -n "$EXTERNAL" ]; then
        printf 'external:%s\n' "$EXTERNAL"
    else
        printf 'none\n'
    fi
}

ts_ntp_synchronized() {
    local BACKEND="${1:-$(ts_backend_detect)}" TRACKING=""
    case "$BACKEND" in
        timesyncd)
            timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -qx yes
            ;;
        chrony)
            TRACKING=$(LC_ALL=C chronyc tracking 2>/dev/null || true)
            printf '%s\n' "$TRACKING" | awk -F: '
                /Stratum/ {gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[1-9][0-9]*$/) stratum=1}
                /Leap status/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 == "Normal") leap=1}
                END {exit !(stratum && leap)}
            '
            ;;
        external:*)
            if command -v timedatectl >/dev/null 2>&1 \
                && timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -qx yes; then
                return 0
            fi
            command -v ntpq >/dev/null 2>&1 && ntpq -pn 2>/dev/null | grep -q '^\*'
            ;;
        *) return 1 ;;
    esac
}

ts_backend_label() {
    case "$1" in
        timesyncd) printf 'systemd-timesyncd' ;;
        chrony) printf 'chrony' ;;
        conflict) printf '冲突：多个校时服务同时运行' ;;
        external:*) printf '外部 NTP（%s）' "${1#external:}" ;;
        *) printf '未检测到运行中的校时服务' ;;
    esac
}

ts_time_health_inline() {
    local BACKEND="" LABEL=""
    BACKEND=$(ts_backend_detect)
    LABEL=$(ts_backend_label "$BACKEND")
    echo -e "  时区：${BOLD}$(ts_current_timezone)${NC}  本地：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
    echo -e "  UTC ：$(date -u '+%Y-%m-%d %H:%M:%S UTC')  后端：${BOLD}${LABEL}${NC}"
    if [ "$BACKEND" = conflict ]; then
        warn "存在多个活动校时服务；请进入时间模块选择保留一个"
        return 1
    fi
    if ts_ntp_synchronized "$BACKEND"; then
        info "系统时间已由 $(ts_backend_label "$BACKEND") 同步"
        return 0
    fi
    warn "系统时间尚未确认同步"
    return 1
}

ts_diagnostics() {
    local BACKEND="" SERVICE=""
    print_header "时间与 NTP 诊断"
    BACKEND=$(ts_backend_detect)
    ts_time_health_inline || true
    echo ""
    case "$BACKEND" in
        timesyncd)
            echo -e "  ${BOLD}timesyncd 状态${NC}"
            timedatectl timesync-status --no-pager 2>/dev/null | sed 's/^/  /' \
                || timedatectl show-timesync --no-pager 2>/dev/null | sed 's/^/  /' \
                || warn "当前 systemd 版本不提供详细 timesync 状态"
            ;;
        chrony)
            echo -e "  ${BOLD}chrony 状态${NC}"
            LC_ALL=C chronyc tracking 2>/dev/null \
                | grep -E 'Reference ID|Stratum|Ref time|System time|Last offset|Root delay|Root dispersion|Leap status' \
                | sed 's/^/  /' || warn "无法读取 chrony tracking"
            echo ""
            LC_ALL=C chronyc sources -n 2>/dev/null | sed -n '1,15p' | sed 's/^/  /' || true
            ;;
        conflict)
            ts_timesyncd_active && echo "  systemd-timesyncd：运行中" || echo "  systemd-timesyncd：已停止"
            SERVICE=$(ts_chrony_service 2>/dev/null || true)
            if [ -n "$SERVICE" ] && ts_chrony_active; then
                echo "  chrony：运行中（${SERVICE}）"
            else
                echo "  chrony：已停止"
            fi
            ;;
        external:*)
            warn "检测到 ${BACKEND#external:}；Quench 只诊断，不接管外部 NTP 配置"
            ;;
        none)
            warn '没有运行中的 NTP 客户端，可选择「开启或修复自动同步」'
            ;;
    esac
    if command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container >/dev/null 2>&1; then
        warn "当前位于容器中；系统时间通常由宿主机控制，容器可能没有改时权限"
    fi
    audit_action "执行时间与NTP诊断：${BACKEND}" SUCCESS
}

ts_ntp_disable_chrony() {
    local SERVICE=""
    SERVICE=$(ts_chrony_service 2>/dev/null || true)
    [ -n "$SERVICE" ] || return 0
    svc_stop "$SERVICE" >/dev/null 2>&1 || return 1
    svc_disable "$SERVICE" >/dev/null 2>&1 || true
}

ts_ntp_disable_timesyncd() {
    systemd_available || return 0
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1
}

ts_resolve_ntp_conflict() {
    local CHOICE="" EXTERNAL=""
    print_header "处理时间同步服务冲突"
    warn "多个服务同时调整系统时钟会造成状态误判和相互干扰"
    EXTERNAL=$(ts_external_ntp_service 2>/dev/null || true)
    if [ -n "$EXTERNAL" ]; then
        warn "检测到外部 NTP 服务 ${EXTERNAL}；Quench 不会停止或覆盖它"
        menu_item "1" "保留 ${EXTERNAL}，停止 chrony / systemd-timesyncd"
        menu_item "0" "取消" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择处理方式 [0-1]: ')" CHOICE
        case "$CHOICE" in
            1)
                ts_ntp_disable_timesyncd || { error "无法停止 systemd-timesyncd"; return 1; }
                ts_ntp_disable_chrony || { error "无法停止 chrony"; return 1; }
                audit_action "解决NTP后端冲突，保留外部服务${EXTERNAL}" SUCCESS
                return 0
                ;;
            *) warn "已取消，未修改服务"; return 1 ;;
        esac
    fi
    menu_pair "1" "保留 chrony" "2" "保留 systemd-timesyncd"
    menu_item "0" "取消" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择保留的后端 [0-2]: ')" CHOICE
    case "$CHOICE" in
        1)
            ts_chrony_service >/dev/null 2>&1 || { error "chrony 不可用"; return 1; }
            ts_ntp_disable_timesyncd || { error "无法停止 systemd-timesyncd"; return 1; }
            ;;
        2)
            ts_timesyncd_available || { error "systemd-timesyncd 不可用"; return 1; }
            ts_ntp_disable_chrony || { error "无法停止 chrony"; return 1; }
            ;;
        *) warn "已取消，未修改服务"; return 1 ;;
    esac
    audit_action "解决NTP后端冲突，选择${CHOICE}" SUCCESS
}

ts_wait_synchronized() {
    local BACKEND="$1" REMAINING=15
    while [ "$REMAINING" -gt 0 ]; do
        ts_ntp_synchronized "$BACKEND" && return 0
        sleep 2
        REMAINING=$((REMAINING - 1))
    done
    return 1
}

ts_ntp_request_backend() {
    local BACKEND="$1" SERVICE=""
    case "$BACKEND" in
        timesyncd)
            timedatectl set-ntp true >/dev/null 2>&1 || return 1
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || return 1
            ;;
        chrony)
            SERVICE=$(ts_chrony_service 2>/dev/null || true)
            [ -n "$SERVICE" ] || return 1
            svc_start "$SERVICE" >/dev/null 2>&1 || return 1
            chronyc online >/dev/null 2>&1 || true
            chronyc burst 4/4 >/dev/null 2>&1 || true
            ;;
        *) return 1 ;;
    esac
    ts_wait_synchronized "$BACKEND"
}

ts_ntp_repair() {
    print_header "开启或修复自动时间同步"
    local BACKEND="" SERVICE="" ANSWER=""
    BACKEND=$(ts_backend_detect)
    if [ "$BACKEND" = conflict ]; then
        ts_resolve_ntp_conflict || return 1
        BACKEND=$(ts_backend_detect)
    fi
    case "$BACKEND" in
        external:*)
            warn "${BACKEND#external:} 正在管理系统时间；Quench 不会覆盖外部 NTP 后端"
            if ts_ntp_synchronized "$BACKEND"; then
                info "外部 NTP 已同步"
                return 0
            else
                warn "外部 NTP 尚未确认同步"
                return 1
            fi
            ;;
        chrony)
            SERVICE=$(ts_chrony_service) || return 1
            svc_enable "$SERVICE" >/dev/null 2>&1 || true
            svc_start "$SERVICE" >/dev/null 2>&1 || { error "chrony 启动失败"; return 1; }
            ;;
        timesyncd)
            timedatectl set-ntp true >/dev/null 2>&1 || { error "无法启用 systemd-timesyncd"; return 1; }
            systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || { error "systemd-timesyncd 启动失败"; return 1; }
            ;;
        none)
            SERVICE=$(ts_chrony_service 2>/dev/null || true)
            if [ -n "$SERVICE" ]; then
                svc_enable "$SERVICE" >/dev/null 2>&1 || true
                svc_start "$SERVICE" >/dev/null 2>&1 || { error "chrony 启动失败"; return 1; }
                BACKEND=chrony
            elif ts_timesyncd_available; then
                timedatectl set-ntp true >/dev/null 2>&1 || { error "无法启用 systemd-timesyncd"; return 1; }
                systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
                systemctl restart systemd-timesyncd >/dev/null 2>&1 || { error "systemd-timesyncd 启动失败"; return 1; }
                BACKEND=timesyncd
            else
                read -rp "  未找到可用时间服务，是否安装 chrony？(Y/n，默认Y): " ANSWER
                ANSWER=${ANSWER:-y}
                echo "$ANSWER" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
                pkg_install chrony || { error "chrony 安装失败"; return 1; }
                SERVICE=$(ts_chrony_service 2>/dev/null || true)
                [ -n "$SERVICE" ] || { error "安装后仍未识别 chrony 服务"; return 1; }
                svc_enable "$SERVICE" >/dev/null 2>&1 || true
                svc_start "$SERVICE" >/dev/null 2>&1 || { error "chrony 启动失败"; return 1; }
                BACKEND=chrony
            fi
            ;;
    esac
    info "已启用单一时间同步后端：$(ts_backend_label "$BACKEND")"
    if ts_ntp_request_backend "$BACKEND"; then
        info "自动时间同步已生效 ✓"
        audit_action "启用并验证时间同步后端：${BACKEND}" SUCCESS
    else
        warn "服务已启动，但 30 秒内尚未确认同步；请运行时间诊断检查网络和来源"
        audit_action "时间同步后端已启动但未确认同步：${BACKEND}" FAILED
        return 1
    fi
}

ts_request_sync() {
    print_header "立即请求 NTP 同步"
    local BACKEND=""
    BACKEND=$(ts_backend_detect)
    case "$BACKEND" in
        conflict) error '存在多个活动校时服务，请先执行「开启或修复自动同步」'; return 1 ;;
        none) error "没有运行中的 NTP 后端，请先开启自动同步"; return 1 ;;
        external:*) error "${BACKEND#external:} 不由 Quench 管理，请使用其原生工具请求同步"; return 1 ;;
    esac
    info "正在请求 $(ts_backend_label "$BACKEND") 获取新样本；小偏差由服务平滑校正"
    if ts_ntp_request_backend "$BACKEND"; then
        info "时间同步已确认 ✓"
        info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
        audit_action "立即请求NTP同步：${BACKEND}" SUCCESS
    else
        error "30 秒内未确认同步，请运行诊断检查 UDP/123、DNS 和服务日志"
        audit_action "立即请求NTP同步失败：${BACKEND}" FAILED
        return 1
    fi
}

ts_set_timezone() {
    local ZONE="$1" BEFORE="" AFTER="" ANSWER=""
    ts_timezone_syntax_valid "$ZONE" || { error "时区名称格式无效"; return 1; }
    if ! ts_timezone_valid "$ZONE"; then
        warn "系统缺少时区 ${ZONE}，可能尚未安装 tzdata"
        read -rp "  是否安装 tzdata 后重试？(Y/n，默认Y): " ANSWER
        ANSWER=${ANSWER:-y}
        echo "$ANSWER" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
        pkg_install tzdata || { error "tzdata 安装失败"; return 1; }
        ts_timezone_valid "$ZONE" || { error "时区 ${ZONE} 不存在"; return 1; }
    fi
    BEFORE=$(ts_current_timezone)
    if systemd_available && command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "$ZONE" >/dev/null 2>&1 || { error "timedatectl 设置时区失败"; return 1; }
    else
        ln -sfn "/usr/share/zoneinfo/${ZONE}" /etc/localtime || { error "更新 /etc/localtime 失败"; return 1; }
        printf '%s\n' "$ZONE" > /etc/timezone || { error "写入 /etc/timezone 失败"; return 1; }
    fi
    AFTER=$(ts_current_timezone)
    [ "$AFTER" = "$ZONE" ] || { error "时区回读不一致：期望 ${ZONE}，实际 ${AFTER}"; return 1; }
    info "时区已从 ${BEFORE} 设置为 ${ZONE} ✓"
    info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
    audit_action "设置时区：${BEFORE}→${ZONE}" SUCCESS
}

ts_set_custom_timezone() {
    print_header "设置 IANA 时区"
    local ZONE=""
    echo -e "  ${DIM}示例：Asia/Tokyo、America/New_York、Europe/London${NC}"
    echo -e "  ${DIM}城市时区会自动遵循当地夏令时规则，不按固定 UTC 偏移描述。${NC}"
    echo ""
    read -rp "  输入时区名称（直接回车取消）: " ZONE
    [ -n "$ZONE" ] || { warn "已取消"; return; }
    ts_set_timezone "$ZONE"
}

ts_https_date_epoch() {
    local HTTP_DATE="$1" WEEKDAY DAY MONTH YEAR CLOCK ZONE EXTRA MONTH_NUM DAY_NUM ISO EPOCH
    read -r WEEKDAY DAY MONTH YEAR CLOCK ZONE EXTRA <<< "$HTTP_DATE"
    [ -n "$WEEKDAY" ] && [ -z "$EXTRA" ] || return 1
    case "$DAY" in ''|*[!0-9]*) return 1 ;; esac
    case "$YEAR" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#DAY}" -le 2 ] && [ "${#YEAR}" -eq 4 ] || return 1
    [ "$(printf '%s' "$ZONE" | tr '[:lower:]' '[:upper:]')" = GMT ] || return 1
    printf '%s\n' "$CLOCK" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' || return 1
    case "$MONTH" in
        Jan) MONTH_NUM=1 ;; Feb) MONTH_NUM=2 ;; Mar) MONTH_NUM=3 ;; Apr) MONTH_NUM=4 ;;
        May) MONTH_NUM=5 ;; Jun) MONTH_NUM=6 ;; Jul) MONTH_NUM=7 ;; Aug) MONTH_NUM=8 ;;
        Sep) MONTH_NUM=9 ;; Oct) MONTH_NUM=10 ;; Nov) MONTH_NUM=11 ;; Dec) MONTH_NUM=12 ;;
        *) return 1 ;;
    esac
    DAY_NUM=$((10#$DAY)); [ "$DAY_NUM" -ge 1 ] && [ "$DAY_NUM" -le 31 ] || return 1
    printf -v ISO '%04d-%02d-%02d %s' "$YEAR" "$MONTH_NUM" "$DAY_NUM" "$CLOCK"
    EPOCH=$(date -u -d "$ISO" '+%s' 2>/dev/null || true)
    if ! printf '%s\n' "$EPOCH" | grep -qE '^[0-9]+$' && command -v python3 >/dev/null 2>&1; then
        EPOCH=$(python3 - "$ISO" <<'PYEOF'
from datetime import datetime, timezone
import sys
try:
    parsed = datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
except ValueError:
    raise SystemExit(1)
print(int(parsed.timestamp()))
PYEOF
        ) || return 1
    fi
    printf '%s\n' "$EPOCH" | grep -qE '^[0-9]+$' || return 1
    printf '%s\n' "$EPOCH"
}

ts_epoch_utc() {
    local EPOCH="$1" RESULT=""
    printf '%s\n' "$EPOCH" | grep -qE '^[0-9]+$' || return 1
    RESULT=$(date -u -d "@$EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    if [ -z "$RESULT" ] && command -v python3 >/dev/null 2>&1; then
        RESULT=$(python3 - "$EPOCH" <<'PYEOF'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
PYEOF
        ) || return 1
    fi
    [ -n "$RESULT" ] || return 1
    printf '%s\n' "$RESULT"
}

ts_https_fetch_epoch() {
    local URL="$1" HEADERS="" HTTP_DATE=""
    HEADERS=$(curl --proto '=https' -sS -I --connect-timeout 5 --max-time 8 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$URL" 2>/dev/null) || return 1
    HTTP_DATE=$(printf '%s\n' "$HEADERS" | awk '
        tolower($0) ~ /^date:[[:space:]]/ {
            sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0
        }
        END {if (value != "") print value}
    ')
    [ -n "$HTTP_DATE" ] || return 1
    ts_https_date_epoch "$HTTP_DATE"
}

ts_https_consensus() {
    local MAX_SKEW="${TS_HTTPS_MAX_SKEW:-10}" VALUE I J COUNT BEST_START=0 BEST_COUNT=0
    local FIRST LAST MID TARGET SPREAD SORTED_VALUE=""
    local VALUES=() SORTED_VALUES=()
    case "$MAX_SKEW" in ''|*[!0-9]*) MAX_SKEW=10 ;; esac
    [ "$MAX_SKEW" -ge 1 ] || MAX_SKEW=10
    for VALUE in "$@"; do
        printf '%s\n' "$VALUE" | grep -qE '^[0-9]+$' && VALUES+=("$VALUE")
    done
    [ "${#VALUES[@]}" -ge 2 ] || return 1
    while IFS= read -r SORTED_VALUE; do SORTED_VALUES+=("$SORTED_VALUE"); done \
        < <(printf '%s\n' "${VALUES[@]}" | sort -n)
    VALUES=("${SORTED_VALUES[@]}")
    for ((I=0; I<${#VALUES[@]}; I++)); do
        COUNT=0
        for ((J=I; J<${#VALUES[@]}; J++)); do
            [ $((VALUES[J] - VALUES[I])) -le "$MAX_SKEW" ] || break
            COUNT=$((COUNT + 1))
        done
        if [ "$COUNT" -gt "$BEST_COUNT" ]; then BEST_START=$I; BEST_COUNT=$COUNT; fi
    done
    [ "$BEST_COUNT" -ge 2 ] || return 1
    FIRST=${VALUES[BEST_START]}; LAST=${VALUES[$((BEST_START + BEST_COUNT - 1))]}
    MID=$((BEST_START + BEST_COUNT / 2))
    if [ $((BEST_COUNT % 2)) -eq 0 ]; then TARGET=$(( (VALUES[MID - 1] + VALUES[MID]) / 2 ))
    else TARGET=${VALUES[MID]}; fi
    SPREAD=$((LAST - FIRST))
    printf '%s %s %s\n' "$TARGET" "$BEST_COUNT" "$SPREAD"
}

ts_pause_backend() {
    local BACKEND="$1" SERVICE=""
    case "$BACKEND" in
        none) printf 'none\n' ;;
        timesyncd)
            systemctl stop systemd-timesyncd >/dev/null 2>&1 || return 1
            printf 'timesyncd\n'
            ;;
        chrony)
            SERVICE=$(ts_chrony_service 2>/dev/null || true)
            [ -n "$SERVICE" ] && svc_stop "$SERVICE" >/dev/null 2>&1 || return 1
            printf 'chrony:%s\n' "$SERVICE"
            ;;
        *) return 1 ;;
    esac
}

ts_resume_backend() {
    case "$1" in
        none|"") return 0 ;;
        timesyncd) systemctl start systemd-timesyncd >/dev/null 2>&1 ;;
        chrony:*) svc_start "${1#chrony:}" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ts_sync_https() {
    print_header "HTTPS 应急粗校时"
    local SOURCE LABEL URL EPOCH LOCAL_SAMPLE REFERENCE_LOCAL CONSENSUS COUNT SPREAD
    local TARGET_UTC BEFORE AFTER DRIFT ABS_DRIFT I BACKEND PAUSE_TOKEN="" CONFIRM="" RESUME_OK=1
    local SOURCES=(
        'Cloudflare|https://www.cloudflare.com/'
        'Aliyun|https://www.aliyun.com/'
        'Microsoft|https://www.microsoft.com/'
        'GitHub|https://github.com/'
        'Google|https://www.google.com/generate_204'
    )
    local SAMPLE_EPOCHS=() SAMPLE_LOCALS=() ADJUSTED=()
    warn "这不是 NTP，只用于 UDP/123 不通且系统时间明显错误时进行人工应急粗校准"
    echo -e "  ${DIM}HTTPS Date 精度和路径误差有限；不会创建 timer 或 cron。${NC}"
    echo ""
    command -v curl >/dev/null 2>&1 || { error "缺少 curl"; return 1; }
    for SOURCE in "${SOURCES[@]}"; do
        LABEL=${SOURCE%%|*}; URL=${SOURCE#*|}
        if EPOCH=$(ts_https_fetch_epoch "$URL") \
            && printf '%s\n' "$EPOCH" | grep -qE '^[0-9]+$' \
            && [ "$EPOCH" -ge 1577836800 ] && [ "$EPOCH" -le 4102444799 ]; then
            LOCAL_SAMPLE=$(date '+%s')
            SAMPLE_EPOCHS+=("$EPOCH"); SAMPLE_LOCALS+=("$LOCAL_SAMPLE")
            info "${LABEL}：$(ts_epoch_utc "$EPOCH") UTC"
            [ "${#SAMPLE_EPOCHS[@]}" -ge 3 ] && break
        else
            warn "${LABEL}：无法获取有效 HTTPS 时间"
        fi
    done
    if [ "${#SAMPLE_EPOCHS[@]}" -lt 2 ]; then
        error "有效 HTTPS 时间来源不足，至少需要两个"
        warn "若系统时间偏差过大导致 TLS 验证失败，请先通过 VPS 控制台粗略校时"
        return 1
    fi
    REFERENCE_LOCAL=$(date '+%s')
    for ((I=0; I<${#SAMPLE_EPOCHS[@]}; I++)); do
        ADJUSTED+=("$((SAMPLE_EPOCHS[I] + REFERENCE_LOCAL - SAMPLE_LOCALS[I]))")
    done
    CONSENSUS=$(ts_https_consensus "${ADJUSTED[@]}") || {
        error "HTTPS 来源时间差异超过 10 秒，已拒绝修改系统时间"; return 1;
    }
    read -r EPOCH COUNT SPREAD <<< "$CONSENSUS"
    TARGET_UTC=$(ts_epoch_utc "$EPOCH") || return 1
    BEFORE=$(date '+%s'); DRIFT=$((EPOCH - BEFORE)); ABS_DRIFT=${DRIFT#-}
    menu_div
    echo -e "  共识来源：${BOLD}${COUNT}${NC} · 最大差异：${BOLD}${SPREAD} 秒${NC}"
    echo -e "  目标时间：${BOLD}${TARGET_UTC} UTC${NC}"
    echo -e "  本机偏差：${BOLD}${DRIFT} 秒${NC}"
    menu_div
    if [ "$ABS_DRIFT" -le 2 ]; then
        info "本机与 HTTPS 共识偏差不超过 2 秒，无需粗校时"
        return 0
    fi
    BACKEND=$(ts_backend_detect)
    case "$BACKEND" in
        conflict) error "存在校时服务冲突，请先修复后再执行应急校时"; return 1 ;;
        external:*) error "检测到外部 NTP ${BACKEND#external:}，Quench 不会绕过它直接改时"; return 1 ;;
    esac
    echo ""
    warn "直接调整系统时间可能影响日志、数据库、证书验证和正在运行的定时任务"
    read -rp "  确认按 HTTPS 共识设置系统时间？(y/N，默认N): " CONFIRM
    echo "${CONFIRM:-n}" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    PAUSE_TOKEN=$(ts_pause_backend "$BACKEND") || { error "无法暂停当前时间同步后端"; return 1; }
    if ! date -u -s "$TARGET_UTC" >/dev/null 2>&1; then
        ts_resume_backend "$PAUSE_TOKEN" || true
        error "设置系统时间失败，当前环境可能没有 CAP_SYS_TIME"
        return 1
    fi
    AFTER=$(date '+%s'); ABS_DRIFT=$((AFTER - EPOCH)); ABS_DRIFT=${ABS_DRIFT#-}
    if ! ts_resume_backend "$PAUSE_TOKEN"; then
        warn "系统时间已设置，但原 NTP 后端恢复失败"
        RESUME_OK=0
    fi
    [ "$ABS_DRIFT" -le 5 ] || { error "设置后的回读偏差为 ${ABS_DRIFT} 秒"; return 1; }
    if [ "$RESUME_OK" -ne 1 ]; then
        audit_action "HTTPS应急粗校时完成但NTP后端恢复失败" FAILED
        return 1
    fi
    info "HTTPS 应急粗校时完成；后续应恢复标准 NTP 同步 ✓"
    audit_action "HTTPS应急粗校时，${COUNT}个来源共识，原偏差${DRIFT}秒" SUCCESS
}

timesync_menu() {
    local CH="" BACKEND=""
    while true; do
        print_header "时间、时区与 NTP"
        BACKEND=$(ts_backend_detect)
        echo -e "  当前时区：${BOLD}$(ts_current_timezone)${NC}"
        echo -e "  当前时间：${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${NC}  ${DIM}$(date '+%Z %z')${NC}"
        echo -e "  同步后端：${BOLD}$(ts_backend_label "$BACKEND")${NC}"
        if ts_ntp_synchronized "$BACKEND"; then
            echo -e "  同步状态：${GREEN}${BOLD}已同步${NC}"
        else
            echo -e "  同步状态：${YELLOW}${BOLD}未确认${NC}"
        fi
        echo ""
        menu_div
        menu_item "1" "时间与 NTP 诊断"
        menu_pair "2" "开启 / 修复自动同步" "3" "立即请求 NTP 同步" "$GREEN" "$CYAN"
        menu_pair "4" "设置 UTC  ${DIM}服务器推荐${NC}" "5" "设置 Asia/Shanghai"
        menu_item "6" "设置其他 IANA 时区"
        menu_item "7" "HTTPS 应急粗校时  ${DIM}仅 UDP/123 受限且时间明显错误时${NC}" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-7]: ')" CH
        case "$CH" in
            1) ts_diagnostics ;;
            2) ts_ntp_repair ;;
            3) ts_request_sync ;;
            4) ts_set_timezone UTC ;;
            5) ts_set_timezone Asia/Shanghai ;;
            6) ts_set_custom_timezone ;;
            7) ts_sync_https ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
