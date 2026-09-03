#!/bin/bash
# 由 build.sh 从 src/ 生成；请修改模块源码后重新构建发行脚本。

# ============================================================
#  Quench V0.1.0 — VPS 初始化与管理工具
#  作者：Boyang
#
#  项目说明：
#  - 为新 VPS 提供可重复执行的首次开荒与安全基线向导
#  - 管理用户、SSH、Fail2ban 与防火墙，并在高风险变更中验证和回滚
#  - 提供 BBR/tc、DNS、网络、系统、容器及服务管理工具
#  - 支持配置备份、操作审计、离线安装、完整性校验和脚本自更新
#
#  发布版本：
#  V0.1.0: 首个完整版本，提供 VPS 初始化、安全接管、网络调优与日常服务管理
# ============================================================

# ── 解释器守卫：本脚本依赖 bash（数组 / [[ ]] / here-string 等）──
# 仅用 POSIX 语法编写，确保在 ash/dash 下也能解析并 fail-fast。
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "本脚本需要 bash 运行，当前 shell 不是 bash 且系统未安装 bash。"
    echo "请先安装 bash 后重试："
    echo "  Alpine:   apk add bash"
    echo "  OpenWrt:  opkg update && opkg install bash"
    echo "  Debian:   apt-get install -y bash"
    echo "  CentOS:   yum install -y bash"
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_MANAGED_BEGIN="# BEGIN QUENCH SSH SETTINGS"
SSHD_MANAGED_END="# END QUENCH SSH SETTINGS"
# 优先使用 /root/.ssh/authorized_keys，兼容系统预装公钥路径
AUTH_KEYS="${HOME}/.ssh/authorized_keys"
[ "$(id -u)" = "0" ] && AUTH_KEYS="/root/.ssh/authorized_keys"
QUENCH_DATA_DIR="/var/lib/quench"
# shellcheck disable=SC2034 # used by management modules in the concatenated release script
QUENCH_BACKUP_DIR="$QUENCH_DATA_DIR/backups"
# shellcheck disable=SC2034 # used by management modules in the concatenated release script
QUENCH_VERSION_DIR="$QUENCH_DATA_DIR/versions"
QUENCH_AUDIT_LOG="/var/log/quench-audit.log"
QUENCH_BACKUP_KEEP="${QUENCH_BACKUP_KEEP:-20}"
case "$QUENCH_BACKUP_KEEP" in ''|*[!0-9]*) QUENCH_BACKUP_KEEP=20 ;; esac
[ "$QUENCH_BACKUP_KEEP" -ge 1 ] || QUENCH_BACKUP_KEEP=20

if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" NC=""
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
fi

info()  { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}!${NC}  $1"; }
error() { echo -e "  ${RED}×${NC}  $1"; }

audit_action() {
    local ACTION="$1" RESULT="${2:-INFO}" SOURCE_IP="local"
    [ -n "${SSH_CONNECTION:-}" ] && SOURCE_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    mkdir -p "$(dirname "$QUENCH_AUDIT_LOG")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RESULT" "$SOURCE_IP" "$ACTION" \
        2>/dev/null >> "$QUENCH_AUDIT_LOG" || true
    chmod 600 "$QUENCH_AUDIT_LOG" 2>/dev/null || true
}

# 兼容 dumb 终端（OpenWrt / tmux 等不支持 clear 的环境）
safe_clear() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# 主菜单品牌字幅
quench_art_banner() {
    ui_refresh_dimensions
    printf '%s' "${RED}${BOLD}"
    if [ "$BOX_W" -ge 56 ]; then
        cat << 'BANNER_WIDE_EOF'
 ██████╗ ██╗   ██╗███████╗███╗   ██╗ ██████╗██╗  ██╗
██╔═══██╗██║   ██║██╔════╝████╗  ██║██╔════╝██║  ██║
██║   ██║██║   ██║█████╗  ██╔██╗ ██║██║     ███████║
██║▄▄ ██║██║   ██║██╔══╝  ██║╚██╗██║██║     ██╔══██║
╚██████╔╝╚██████╔╝███████╗██║ ╚████║╚██████╗██║  ██║
 ╚══▀▀═╝  ╚═════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝
BANNER_WIDE_EOF
    else
        local TITLE="QUENCH" PAD=$(( (BOX_W - 6) / 2 ))
        [ "$PAD" -lt 0 ] && PAD=0
        printf '%*s%s\n' "$PAD" '' "$TITLE"
    fi
    printf '%s' "${NC}"
}

# ── 可见宽度计算（用 python3，中文=2，ASCII=1）────────────
vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

# ── 响应式终端布局 ────────────────────────────────────────
BOX_W=64
UI_COMPACT=0
APP_UI_TITLE="VPS INIT/MANAGEMENT TOOLS"
APP_VERSION="V0.1.0"
APP_AUTHOR="Boyang"

ui_refresh_dimensions() {
    local COLS="${COLUMNS:-}"
    if ! echo "$COLS" | grep -qE '^[0-9]+$'; then
        COLS=$(tput cols 2>/dev/null || echo 80)
    fi
    [ "$COLS" -gt 76 ] && COLS=76
    [ "$COLS" -lt 36 ] && COLS=36
    BOX_W=$COLS
    UI_COMPACT=0
    if [ "$BOX_W" -lt 66 ]; then UI_COMPACT=1; fi
}

ui_repeat() {
    local CHAR="$1" COUNT="$2" i
    for ((i=0; i<COUNT; i++)); do printf '%s' "$CHAR"; done
}

box_top() { ui_refresh_dimensions; printf '%s' "${BOLD}${CYAN}"; ui_repeat "━" "$BOX_W"; printf '%s\n' "$NC"; }
box_bot() { printf '%s' "${BOLD}${CYAN}"; ui_repeat "━" "$BOX_W"; printf '%s\n' "$NC"; }
box_sep() { printf '%s' "${DIM}${CYAN}"; ui_repeat "─" "$BOX_W"; printf '%s\n' "$NC"; }

# 居中标题行（只传纯文本，自动居中）
box_title() {
    local TEXT="$1"
    local LEN; LEN=$(vis_len "$TEXT")
    local INNER=$((BOX_W - 2))
    local PAD_TOTAL=$(( INNER - LEN ))
    [ "$PAD_TOTAL" -lt 0 ] && PAD_TOTAL=0
    local PAD_L=$(( PAD_TOTAL / 2 ))
    local PAD_R=$(( PAD_TOTAL - PAD_L ))
    printf '%*s' "$PAD_L" ''
    printf "${BOLD}${CYAN}%s${NC}" "$TEXT"
    printf '%*s' "$PAD_R" ''
    printf "\n"
}

# 普通内容行：PLAIN=纯文本(算宽度)  COLORED=带色码(显示用)
# 用法: box_line "纯文本" "带色码文本"
box_line() {
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
}

# 空行
box_empty() {
    echo ""
}

# ── 内层分隔线（与主框线同宽对齐，dim 青，统一替代各处 seq 1 38）──
menu_div() { ui_refresh_dimensions; printf '%s' "${DIM}${CYAN}"; ui_repeat "─" "$BOX_W"; printf '%s\n' "$NC"; }

app_header_line() {
    echo -e "  ${DIM}${APP_UI_TITLE}  ·  ${APP_VERSION}  ·  ${APP_AUTHOR}${NC}"
}

# ── 段标题（❯ 前缀，统一替代 [xxx] 方括号风格）──
menu_group() { echo -e "  ${CYAN}${BOLD}◆ ${1}${NC}"; }

# ── 菜单项（统一缩进与配色）。用法: menu_item "1" "用户管理" [颜色]──
menu_item() {
    local KEY="$1" LABEL="$2" COL="${3:-$GREEN}"
    echo -e "    ${COL}${BOLD}${KEY}${NC}  ${LABEL}"
}

menu_pair() {
    local K1="$1" L1="$2" K2="${3:-}" L2="${4:-}" COL1="${5:-$GREEN}" COL2="${6:-$GREEN}"
    ui_refresh_dimensions
    if [ "$UI_COMPACT" = "1" ] || [ -z "$K2" ]; then
        menu_item "$K1" "$L1" "$COL1"
        [ -n "$K2" ] && menu_item "$K2" "$L2" "$COL2"
        return
    fi
    local LEFT="${K1}  ${L1}" TARGET=$((BOX_W / 2 - 3)) LEN PAD
    LEN=$(vis_len "$LEFT"); PAD=$((TARGET - LEN)); [ "$PAD" -lt 2 ] && PAD=2
    printf '    %s%s%s' "$COL1$BOLD" "$K1" "$NC"
    printf '  %s' "$L1"
    printf '%*s' "$PAD" ''
    printf '%s%s%s  %s\n' "$COL2$BOLD" "$K2" "$NC" "$L2"
}

status_dot() {
    local STATE="$1"
    case "$STATE" in
        active|running|yes|on|已启用|运行中) echo -e "${GREEN}●${NC}" ;;
        inactive|stopped|no|off|已停止) echo -e "${RED}●${NC}" ;;
        *) echo -e "${YELLOW}●${NC}" ;;
    esac
}

status_pair() {
    local L1="$1" V1="$2" S1="$3" L2="${4:-}" V2="${5:-}" S2="${6:-}" D1 D2 C1 C2
    case "$S1" in active|running|yes|on|已启用|运行中) C1="$GREEN" ;; inactive|stopped|no|off|已停止) C1="$RED" ;; *) C1="$YELLOW" ;; esac
    case "$S2" in active|running|yes|on|已启用|运行中) C2="$GREEN" ;; inactive|stopped|no|off|已停止) C2="$RED" ;; *) C2="$YELLOW" ;; esac
    D1="${C1}●${NC}"; D2="${C2}●${NC}"
    ui_refresh_dimensions
    if [ "$UI_COMPACT" = "1" ] || [ -z "$L2" ]; then
        echo -e "  $D1  ${DIM}${L1}${NC}  ${BOLD}${V1}${NC}"
        [ -n "$L2" ] && echo -e "  $D2  ${DIM}${L2}${NC}  ${BOLD}${V2}${NC}"
        return
    fi
    local PLAIN="●  ${L1}  ${V1}" TARGET=$((BOX_W / 2)) LEN PAD
    LEN=$(vis_len "$PLAIN"); PAD=$((TARGET - LEN)); [ "$PAD" -lt 2 ] && PAD=2
    echo -en "  $D1  ${DIM}${L1}${NC}  ${BOLD}${V1}${NC}"
    printf '%*s' "$PAD" ''
    echo -e "$D2  ${DIM}${L2}${NC}  ${BOLD}${V2}${NC}"
}

ui_hint() { echo -e "  ${DIM}› $1${NC}"; }
ui_prompt() { printf '  %s›%s %s' "$CYAN$BOLD" "$NC" "$1"; }
ui_pause() { echo ""; read -rp "$(ui_prompt '按 Enter 返回')" _; }
ui_continue() { echo ""; read -rp "$(ui_prompt '按 Enter 继续')" _; }


# ── 通用编辑器（兼容 Alpine/OpenWrt 等精简系统）────────────
get_editor() {
    for ed in nano vi vim; do
        command -v "$ed" &>/dev/null && echo "$ed" && return
    done
    echo "vi"  # 最后兜底，几乎所有系统都有 vi
}

open_editor() {
    local FILE="$1"
    local ED; ED=$(get_editor)
    if ! command -v "$ED" &>/dev/null; then
        # vi 也没有，尝试安装 nano
        warn "未找到编辑器，尝试安装 nano..."
        pkg_install nano &>/dev/null || pkg_install vim &>/dev/null || true
        ED=$(get_editor)
    fi
    "$ED" "$FILE"
}

# ── 确保 sysctl 可用（Alpine 需要 procps 或 sysctl 包）────
# 加载 nf_conntrack 模块（中转/落地机需要）
ensure_conntrack_module() {
    lsmod 2>/dev/null | grep -q "^nf_conntrack" && return 0
    modprobe nf_conntrack 2>/dev/null
}

ensure_sysctl() {
    command -v sysctl &>/dev/null && return 0
    warn "sysctl 未找到，正在安装..."
    if command -v apk &>/dev/null; then
        apk add --no-cache procps 2>/dev/null || apk add --no-cache sysctl 2>/dev/null || true
    else
        pkg_install procps 2>/dev/null || true
    fi
    command -v sysctl &>/dev/null && return 0
    error "sysctl 安装失败，请手动执行：apk add procps"
    return 1
}


# 只清理 Quench 用 comment 显式标记的临时 iptables 规则。
clear_iptables_residue() {
    command -v iptables >/dev/null 2>&1 || return 0
    local RULE PORT
    while RULE=$(iptables -S INPUT 2>/dev/null | grep -m1 -E -- '--comment "?vps-quench-ssh"?' || true); do
        [ -n "$RULE" ] || break
        PORT=$(printf '%s\n' "$RULE" | sed -nE 's/.*--dport ([0-9]+).*/\1/p')
        [ -n "$PORT" ] || break
        iptables -D INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null || break
    done
    info "已清理 Quench 显式标记的临时 iptables 规则"
}

# 统一标题栏
print_header() {
    safe_clear
    echo ""
    box_top
    app_header_line
    echo -e "  ${BOLD}${CYAN}$1${NC}"
    box_bot
    echo ""
}


# ── 兼容工具函数（支持 BusyBox / Alpine）─────────────────

# 替代 grep -oP '(?:maxrate|rate) \K\S+'
# 替代 grep -oE 'initcwnd [0-9]+' | awk '{print $2}'
# 检测服务管理器并重启 SSH
restart_ssh() {
    if systemd_available; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null
    elif command -v service &>/dev/null; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    else
        return 1
    fi
}

# 检测服务管理器并重启 fail2ban
restart_fail2ban() {
    if systemd_available; then
        systemctl restart fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban restart 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban restart 2>/dev/null && return 0
    fi
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban restart 2>/dev/null
}

# 检测服务管理器并启动/停止 fail2ban
start_fail2ban() {
    # 确保 socket 目录存在（tmpfs 重启后会消失）
    mkdir -p /var/run/fail2ban 2>/dev/null
    chmod 755 /var/run/fail2ban 2>/dev/null

    # 写入 tmpfiles.d 确保重启后自动创建目录
    if command -v systemd-tmpfiles &>/dev/null; then
        echo "d /var/run/fail2ban 0755 root root -" > /etc/tmpfiles.d/fail2ban.conf 2>/dev/null
        systemd-tmpfiles --create /etc/tmpfiles.d/fail2ban.conf 2>/dev/null || true
    fi

    # 优先尝试 systemctl，失败则回退 service / rc-service
    if systemd_available; then
        systemctl start fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban start 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban start 2>/dev/null && return 0
    fi
    # 最后回退：直接调用 init.d 脚本
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban start 2>/dev/null
}
stop_fail2ban() {
    if systemd_available; then
        systemctl stop fail2ban 2>/dev/null && return 0
    fi
    if command -v rc-service &>/dev/null; then
        rc-service fail2ban stop 2>/dev/null && return 0
    fi
    if command -v service &>/dev/null; then
        service fail2ban stop 2>/dev/null && return 0
    fi
    [ -x /etc/init.d/fail2ban ] && /etc/init.d/fail2ban stop 2>/dev/null
}

# ── 系统检测工具 ──────────────────────────────────────────

# 检测包管理器
pkg_install() {
    local PKG="$1"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y "$PKG" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$PKG" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y "$PKG" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y "$PKG" 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Syu --needed --noconfirm "$PKG" 2>/dev/null
    else
        return 1
    fi
}

pkg_remove() {
    local PKG="$1"
    if command -v apt-get &>/dev/null; then
        apt-get remove -y "$PKG" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk del "$PKG" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum remove -y "$PKG" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf remove -y "$PKG" 2>/dev/null
    else
        return 1
    fi
}

# 通用服务启用（开机自启）
svc_enable() {
    local SVC="$1"
    if systemd_available; then
        systemctl unmask "$SVC" 2>/dev/null || true
        systemctl enable "$SVC" --quiet 2>/dev/null || true
    elif command -v rc-update &>/dev/null; then
        rc-update add "$SVC" default 2>/dev/null
    elif command -v update-rc.d &>/dev/null; then
        update-rc.d "$SVC" enable 2>/dev/null
    fi
}

svc_disable() {
    local SVC="$1"
    if command -v systemctl &>/dev/null; then
        systemctl disable "$SVC" --quiet 2>/dev/null
    elif command -v rc-update &>/dev/null; then
        rc-update del "$SVC" 2>/dev/null
    fi
}

# 通用服务 start/stop/restart 封装（systemd / OpenRC / sysvinit）
# OpenRC 服务名常带不同后缀，systemd 用 .service；调用方传裸名即可。
# 获取默认出口网卡：ip route get 比 awk '/^default/' 更准
# （多默认路由 / 策略路由 / IPv6-only 时不易取错），失败回退旧法
default_iface() {
    local DEV
    DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$DEV" ] && DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$DEV" ] && DEV=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    echo "$DEV"
}

svc_start() {
    local SVC="$1"
    if systemd_available; then
        systemctl start "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" start 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" start 2>/dev/null
    else
        return 1
    fi
}

svc_stop() {
    local SVC="$1"
    if systemd_available; then
        systemctl stop "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" stop 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" stop 2>/dev/null
    else
        return 1
    fi
}

svc_restart() {
    local SVC="$1"
    if systemd_available; then
        systemctl restart "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" restart 2>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" restart 2>/dev/null
    else
        return 1
    fi
}

# 通用服务 is-active 检测
svc_is_active() {
    local SVC="$1"
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet "$SVC" 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service "$SVC" status &>/dev/null
    elif command -v service &>/dev/null; then
        service "$SVC" status &>/dev/null
    else
        return 1
    fi
}

# systemctl daemon-reload 兼容（OpenRC 不需要）
svc_daemon_reload() {
    command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true
}

# 获取 OS codename（兼容无 lsb_release 的系统）
get_codename() {
    if command -v lsb_release &>/dev/null; then
        lsb_release -cs 2>/dev/null
    elif [ -f /etc/os-release ]; then
        grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"'
    elif [ -f /etc/debian_version ]; then
        cat /etc/debian_version | cut -d. -f1
    else
        echo "unknown"
    fi
}

# ── 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ] && [ "${QUENCH_TEST_MODE:-0}" != "1" ] && [ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ] && [ "${1:-}" != "help" ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 通用工具函数 ──────────────────────────────────────────
sshd_effective_value() {
    local KEY="$1" WANT VALUE
    command -v sshd >/dev/null 2>&1 || return 1
    WANT=$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')
    VALUE=$(sshd -T 2>/dev/null | awk -v k="$WANT" '$1 == k {print $2; exit}')
    [ -n "$VALUE" ] || return 1
    printf '%s\n' "$VALUE"
}

get_config() {
    local VALUE
    VALUE=$(sshd_effective_value "$1" 2>/dev/null || true)
    [ -n "$VALUE" ] && { printf '%s\n' "$VALUE"; return 0; }
    grep -E "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null \
        | tail -1 | awk '{print $2}'
}

# 返回 sshd 当前应当对外开放的端口，每行一个。未完成迁移时优先返回新旧双端口。
ssh_effective_ports() {
    local STATE_FILE="${SSH_PORT_STATE_FILE:-$QUENCH_DATA_DIR/ssh-port-migration.state}"
    local OLD="" NEW="" PORTS=""
    if [ -r "$STATE_FILE" ]; then
        OLD=$(awk -F= '$1 == "OLD_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$STATE_FILE")
        NEW=$(awk -F= '$1 == "NEW_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$STATE_FILE")
        if [ -n "$OLD" ] && [ -n "$NEW" ]; then
            printf '%s\n%s\n' "$OLD" "$NEW"
            return 0
        fi
    fi
    if command -v sshd >/dev/null 2>&1; then
        PORTS=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ && !seen[$2]++ {print $2}')
    fi
    if [ -z "$PORTS" ]; then
        OLD=$(get_config Port 2>/dev/null || true)
        [ -n "$OLD" ] && PORTS="$OLD"
    fi
    if [ -z "$PORTS" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        OLD=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')
        [[ "$OLD" =~ ^[0-9]+$ ]] && PORTS="$OLD"
    fi
    printf '%s\n' "${PORTS:-22}"
}

ssh_effective_ports_csv() {
    ssh_effective_ports | awk 'NF && !seen[$1]++ {if (out != "") out=out ","; out=out $1} END {print out}'
}

ssh_key_count() {
    local COUNT
    COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || true)
    case "$COUNT" in
        ''|*[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$COUNT" ;;
    esac
}

set_config_file() {
    local FILE="$1" KEY="$2" VALUE="$3"
    local BODY BLOCK TMP
    [ -f "$FILE" ] || : > "$FILE"
    BODY=$(mktemp) || return 1
    BLOCK=$(mktemp) || { rm -f "$BODY"; return 1; }
    TMP=$(mktemp) || { rm -f "$BODY" "$BLOCK"; return 1; }

    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {in_block=1; next}
        $0 == end {in_block=0; next}
        !in_block {print}
    ' "$FILE" > "$BODY"

    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" -v key="$KEY" '
        $0 == begin {in_block=1; next}
        $0 == end {in_block=0; next}
        in_block {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            split(line, fields, /[[:space:]]+/)
            if (line != "" && fields[1] != key) print line
        }
    ' "$FILE" > "$BLOCK"

    {
        echo "$SSHD_MANAGED_BEGIN"
        cat "$BLOCK"
        echo "${KEY} ${VALUE}"
        echo "$SSHD_MANAGED_END"
        echo ""
        cat "$BODY"
    } > "$TMP"
    mv "$TMP" "$FILE"
    rm -f "$BODY" "$BLOCK"
}

set_config() {
    set_config_file "$SSHD_CONFIG" "$1" "$2"
}

backup_config() {
    local BACKUP
    BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP"
    LAST_SSHD_BACKUP="$BACKUP"   # 供 apply_and_restart 失败时回滚
    info "配置已备份：$BACKUP"
}

apply_and_restart() {
    # 失败时自动回滚到最近备份，避免把自己锁在外面
    _ssh_rollback() {
        if [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ]; then
            cp "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" 2>/dev/null
            warn "已回滚 sshd_config 到备份：$LAST_SSHD_BACKUP"
            if sshd -t 2>/dev/null && restart_ssh; then
                info "已用备份配置恢复 SSH 服务 ✓"
            else
                error "回滚后仍异常，请立即手动检查 sshd_config 与 SSH 服务！"
            fi
        else
            error "未找到可回滚的备份，请立即手动检查 SSH 配置！"
        fi
    }
    if ! sshd -t 2>/dev/null; then
        error "配置文件语法错误，自动回滚中..."
        _ssh_rollback
        return 1
    fi
    if restart_ssh; then
        info "SSH 服务已重启 ✓"
    else
        error "SSH 服务重启失败，自动回滚中..."
        _ssh_rollback
        return 1
    fi
}

list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}（暂无公钥）${NC}"
        return 1
    fi
    local i=1
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
            local TYPE COMMENT FINGER
            TYPE=$(echo "$line" | awk '{print $1}')
            COMMENT=$(echo "$line" | awk '{print $3}')
            FINGER=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || echo "N/A")
            echo -e "  ${GREEN}[$i]${NC} ${BOLD}$TYPE${NC}"
            echo -e "      ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
            echo -e "      ${DIM}备注：${NC}${YELLOW}${COMMENT:-（无备注）}${NC}"
            echo ""
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"
    return 0
}

ufw_port_rule_present() {
    local PORT="$1" ACTIONS="${2:-ALLOW|LIMIT}" SCOPE="${3:-any}"
    LC_ALL=C ufw status 2>/dev/null | awk -v spec="${PORT}/tcp" -v actions="$ACTIONS" -v scope="$SCOPE" '
        $1 == spec {
            action_pos=0
            for (i=2; i<=NF; i++) {
                if ($i ~ "^(" actions ")$") {action_pos=i; break}
            }
            broad=(action_pos && ($(action_pos + 1) == "Anywhere" || ($(action_pos + 1) == "IN" && $(action_pos + 2) == "Anywhere")))
            if (action_pos && (scope != "broad" || broad)) found=1
        }
        END {exit !found}
    '
}

firewall_port_ready() {
    local PORT="$1" CHECKED=false FAILED=false FIREWALLD_ZONE=""
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active'; then
        CHECKED=true
        if ! ufw_port_rule_present "$PORT" \
            || ufw_port_rule_present "$PORT" 'DENY|REJECT' broad; then
            FAILED=true
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && svc_is_active firewalld; then
        CHECKED=true
        declare -F fw_firewalld_zone >/dev/null 2>&1 && FIREWALLD_ZONE=$(fw_firewalld_zone)
        FIREWALLD_ZONE="${FIREWALLD_ZONE:-public}"
        firewall-cmd --zone="$FIREWALLD_ZONE" --query-port="${PORT}/tcp" >/dev/null 2>&1 || FAILED=true
    fi
    if [ "$CHECKED" = false ] && command -v iptables >/dev/null 2>&1; then
        local RULES
        RULES=$(iptables -L INPUT --line-numbers 2>/dev/null \
            | grep -vc "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere")
        if [ "$RULES" -gt 0 ]; then
            CHECKED=true
            iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 \
                || iptables -C INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT >/dev/null 2>&1 \
                || FAILED=true
        fi
    fi
    [ "$FAILED" = false ]
}

firewall_allow_port() {
    local PORT="$1"
    local UFW_ACTIVE=false FIREWALLD_ACTIVE=false IPTABLES_ACTIVE=false FAILED=false FIREWALLD_ZONE=""

    command -v ufw &>/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active" && UFW_ACTIVE=true
    command -v firewall-cmd &>/dev/null && svc_is_active firewalld && FIREWALLD_ACTIVE=true
    # UFW 与 firewalld 最终也会生成 iptables/nftables 规则；已有上层后端时，
    # 不再把这些规则误判成需要单独维护的“原生 iptables”。
    if [ "$UFW_ACTIVE" = false ] && [ "$FIREWALLD_ACTIVE" = false ] \
        && command -v iptables &>/dev/null; then
        local RULES
        RULES=$(iptables -L INPUT --line-numbers 2>/dev/null \
            | grep -vc "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere")
        [ "$RULES" -gt 0 ] && IPTABLES_ACTIVE=true
    fi

    if [ "$UFW_ACTIVE" = false ] && [ "$FIREWALLD_ACTIVE" = false ] && [ "$IPTABLES_ACTIVE" = false ]; then
        info "未检测到活跃防火墙，跳过端口放行"
        return 0
    fi

    echo ""
    warn "检测到活跃防火墙，是否自动放行新端口 ${PORT}/tcp？"
    read -rp "  自动放行？(Y/n，默认Y): " FW_CONFIRM
    FW_CONFIRM="${FW_CONFIRM:-y}"
    if ! echo "$FW_CONFIRM" | grep -qiE '^y(es)?$'; then
        if firewall_port_ready "$PORT"; then
            info "端口 ${PORT}/tcp 已有有效防火墙放行规则"
            return 0
        fi
        error "未检测到 ${PORT}/tcp 的有效放行规则，拒绝继续修改 SSH"
        return 1
    fi

    if [ "$UFW_ACTIVE" = true ]; then
        # 新 SSH 端口尚未监听，可安全把宽泛 ALLOW 转成 LIMIT；来源限定规则不受影响。
        ufw --force delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
        if ufw limit "${PORT}"/tcp 2>/dev/null \
            && ufw_port_rule_present "$PORT" LIMIT broad \
            && ! ufw_port_rule_present "$PORT" ALLOW broad \
            && ! ufw_port_rule_present "$PORT" 'DENY|REJECT' broad; then
            info "ufw 已限速放行 ${PORT}/tcp ✓"
        else
            error "ufw 未形成唯一有效的 ${PORT}/tcp 宽泛 LIMIT 规则"
            FAILED=true
        fi
    fi
    if [ "$FIREWALLD_ACTIVE" = true ]; then
        declare -F fw_firewalld_zone >/dev/null 2>&1 && FIREWALLD_ZONE=$(fw_firewalld_zone)
        FIREWALLD_ZONE="${FIREWALLD_ZONE:-public}"
        if firewall-cmd --permanent --zone="$FIREWALLD_ZONE" --add-port="${PORT}/tcp" 2>/dev/null \
            && firewall-cmd --reload 2>/dev/null \
            && firewall-cmd --zone="$FIREWALLD_ZONE" --query-port="${PORT}/tcp" >/dev/null 2>&1; then
            info "firewalld 已放行 ${PORT}/tcp ✓"
        else
            error "firewalld 放行 ${PORT}/tcp 失败"
            FAILED=true
        fi
    fi
    if [ "$IPTABLES_ACTIVE" = true ]; then
        if [ ! -f /etc/iptables/rules.v4 ]; then
            error "检测到原生 iptables 规则，但未找到 /etc/iptables/rules.v4 持久化文件"
            warn "请先手动持久放行 ${PORT}/tcp，否则重启后可能无法 SSH"
            FAILED=true
        elif iptables -I INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null \
            && iptables-save > /etc/iptables/rules.v4; then
            info "iptables 已放行并持久化 ${PORT}/tcp ✓"
        else
            error "iptables 放行 ${PORT}/tcp 失败"
            FAILED=true
        fi
    fi
    [ "$FAILED" = false ] && firewall_port_ready "$PORT"
}
