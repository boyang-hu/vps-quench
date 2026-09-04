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

# ── 临时资源登记表与信号处理 ──────────────────────────────
# 主程序原来没有 EXIT trap：Ctrl+C 会把 mktemp 出来的中间文件留在 /tmp，
# 其中包括 sshd_config 的完整副本。这里登记，退出时兜底清理。
# 各处原有的显式 rm 一律保留，重复删除无害。
#
# 登记表必须落在文件里，不能放变量：调用方几乎都是 X=$(mktemp ...) 这种命令
# 替换，子 shell 里对变量的追加出了子 shell 就没了；追加到文件则父进程可见。
QUENCH_TMP_REGISTRY=""

quench_tmp_registry_init() {
    [ -z "$QUENCH_TMP_REGISTRY" ] || return 0
    # 登记表自身用裸 mktemp：它就是登记的载体，不能反过来登记自己。
    QUENCH_TMP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.quench-registry.XXXXXX" 2>/dev/null) || {
        QUENCH_TMP_REGISTRY=""
        return 1
    }
    chmod 600 "$QUENCH_TMP_REGISTRY" 2>/dev/null || true
}

quench_tmp_register() {
    [ -n "$QUENCH_TMP_REGISTRY" ] || return 0
    local ENTRY
    for ENTRY in "$@"; do
        [ -n "$ENTRY" ] || continue
        printf '%s\n' "$ENTRY" >> "$QUENCH_TMP_REGISTRY" 2>/dev/null || true
    done
}

# 只清理确实位于临时目录下的路径，绝不按登记表盲删：
# 登记表里可能混入同目录暂存文件（/etc、/var/lib 下），那些由各自的显式 rm 负责。
quench_tmp_cleanup() {
    local ENTRY BASE REGISTRY="$QUENCH_TMP_REGISTRY"
    [ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] || return 0
    BASE="${TMPDIR:-/tmp}"; BASE="${BASE%/}"
    QUENCH_TMP_REGISTRY=""
    while IFS= read -r ENTRY; do
        [ -n "$ENTRY" ] || continue
        case "$ENTRY" in
            *'..'*) continue ;;
            "$BASE"/*|/tmp/*|/var/tmp/*) ;;
            *) continue ;;
        esac
        rm -rf -- "$ENTRY" 2>/dev/null || true
    done < "$REGISTRY"
    rm -f "$REGISTRY" 2>/dev/null || true
}

# mktemp 包装：创建并登记。参数与 mktemp 一致。
quench_mktemp() {
    local PATH_VALUE
    PATH_VALUE=$(mktemp "$@") || return 1
    quench_tmp_register "$PATH_VALUE"
    printf '%s\n' "$PATH_VALUE"
}

quench_mktemp_d() {
    local PATH_VALUE
    PATH_VALUE=$(mktemp -d "$@") || return 1
    quench_tmp_register "$PATH_VALUE"
    printf '%s\n' "$PATH_VALUE"
}

# 信号处理。安装一次，模块临时接管 INT 后必须用 quench_restore_signal_traps
# 恢复，而不是 `trap - INT`——后者会重置成默认动作，把兜底清理一起丢掉。
QUENCH_TRAPS_INSTALLED=0

quench_signal_cleanup() {
    quench_tmp_cleanup
    exit 130
}

quench_install_signal_traps() {
    quench_tmp_registry_init || return 0
    trap quench_tmp_cleanup EXIT
    trap quench_signal_cleanup INT TERM HUP
    QUENCH_TRAPS_INSTALLED=1
}

quench_restore_signal_traps() {
    if [ "$QUENCH_TRAPS_INSTALLED" = 1 ]; then
        trap quench_signal_cleanup INT TERM HUP
    else
        trap - INT TERM HUP
    fi
}

# ── 防断联回滚计时器：启动与句柄 ──────────────────────────
# 计时器必须活过“当前登录会话消失”，那正是它存在的唯一理由。
# nohup 只让进程忽略 SIGHUP；systemd-logind 在 KillUserProcesses=yes 时
# 是按会话 cgroup 整片回收的，非 root 用户 sudo 进来时连 root 进程一起带走
# （KillExcludeUsers 默认只排除 root 自己登录的会话）。
# setsid 只改 POSIX 会话、不改 cgroup 归属，挡不住这种回收，因此不作为修复手段；
# 且 `setsid cmd &` 的 $! 可能是 setsid 自身的 PID，会破坏取消逻辑。
# 所以：systemd 环境交给 system 级 transient unit（落在 system.slice 自己的
# cgroup 里，与登录会话无关）；非 systemd 环境没有 logind，nohup 已经足够。
SAFETY_PID=""
SAFETY_SCRIPT=""
SAFETY_UNIT=""

# ── 配置变更事务锁 ────────────────────────────────────────
# 两个 Quench 会话同时改 sshd_config / 防火墙会互相覆盖，而且各自的防断联
# 计时器会回滚掉对方的快照。所有走 safety_arm 的高危变更共用这一把锁。
# 只在“变更事务”期间持有：只读菜单、状态刷新、后台版本检测都不受影响。
# 用固定 fd：bash 3.2 不支持 exec {VAR}>（实测报 exec: {FD}: not found），
# 而本脚本的解释器守卫允许在老 bash 上运行。全脚本的 fd 分配集中记在这里，
# 因为这几把锁可能同时持有，编号不能撞车：
#   7 = BBR 线路校准锁（bbr.sh）
#   8 = nft 转发锁（nft.sh）
#   9 = 配置变更事务锁（本文件）
# 同一进程重复进入直接复用（Quench 同时只维护一笔事务，不存在真正的嵌套）。
QUENCH_TXN_LOCK_FILE="${QUENCH_TXN_LOCK_FILE:-/run/lock/quench-config.lock}"
QUENCH_TXN_LOCK_HELD=0

txn_lock_acquire() {
    # 系统没有 flock 时退化为不加锁：宁可失去互斥，也不能让高危变更无法进行。
    command -v flock >/dev/null 2>&1 || return 0
    [ "$QUENCH_TXN_LOCK_HELD" = 1 ] && return 0
    mkdir -p "$(dirname "$QUENCH_TXN_LOCK_FILE")" 2>/dev/null || true
    exec 9>"$QUENCH_TXN_LOCK_FILE" 2>/dev/null || return 0
    if ! flock -w "${QUENCH_TXN_LOCK_WAIT:-10}" 9 2>/dev/null; then
        exec 9>&-
        error "另一个 Quench 会话正在修改配置，请等它结束后重试"
        return 1
    fi
    QUENCH_TXN_LOCK_HELD=1
}

txn_lock_release() {
    [ "$QUENCH_TXN_LOCK_HELD" = 1 ] || return 0
    flock -u 9 2>/dev/null || true
    exec 9>&-
    QUENCH_TXN_LOCK_HELD=0
}

# ── 事务记录（只写盘，不打扰）──────────────────────────────
# 崩溃或断线的会话不会留下任何进程内线索，新进程也就看不见它布下的回滚计时器。
# 这里把事务落到磁盘，供“回滚中心 → 检查未完成的变更”事后查看。
# 启动时不扫描、不提示、不自动删除任何回滚脚本：那些脚本可能仍会正常触发。
# 记录失败一律不影响事务本身——它是诊断信息，不是安全前提。
QUENCH_TXN_DIR="${QUENCH_TXN_DIR:-$QUENCH_DATA_DIR/transactions}"
QUENCH_TXN_FILE=""

txn_record_begin() {
    local LABEL="$1" SCRIPT="$2"
    mkdir -p "$QUENCH_TXN_DIR" 2>/dev/null || return 0
    chmod 700 "$QUENCH_TXN_DIR" 2>/dev/null || true
    QUENCH_TXN_FILE="$QUENCH_TXN_DIR/$$-$(date +%s)-${RANDOM}.txn"
    {
        printf 'LABEL=%s\n' "$LABEL"
        printf 'SCRIPT=%s\n' "$SCRIPT"
        printf 'UNIT=%s\n' "${SAFETY_UNIT:-}"
        printf 'TIMER_PID=%s\n' "${SAFETY_PID:-}"
        printf 'QUENCH_PID=%s\n' "$$"
        printf 'STARTED=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$QUENCH_TXN_FILE" 2>/dev/null || { QUENCH_TXN_FILE=""; return 0; }
    chmod 600 "$QUENCH_TXN_FILE" 2>/dev/null || true
}

txn_record_end() {
    [ -n "${QUENCH_TXN_FILE:-}" ] || return 0
    rm -f "$QUENCH_TXN_FILE" 2>/dev/null || true
    QUENCH_TXN_FILE=""
}

txn_record_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

safety_launch_timer() {
    local SCRIPT="$1" UNIT
    SAFETY_PID="" SAFETY_SCRIPT="" SAFETY_UNIT=""
    [ -f "$SCRIPT" ] || return 1
    if systemd_available && command -v systemd-run >/dev/null 2>&1; then
        UNIT="quench-rollback-$$-$(date +%s)-${RANDOM}"
        # --collect 需要 systemd 236+，不支持时退回不带该参数的写法。
        if systemd-run --quiet --collect --unit="$UNIT" /bin/bash "$SCRIPT" >/dev/null 2>&1 \
            || systemd-run --quiet --unit="$UNIT" /bin/bash "$SCRIPT" >/dev/null 2>&1; then
            SAFETY_UNIT="$UNIT"
            SAFETY_SCRIPT="$SCRIPT"
            return 0
        fi
        warn "systemd-run 启动失败，回退到 nohup；若登录会话被 logind 回收，自动回滚可能不会执行"
    fi
    nohup bash "$SCRIPT" >/dev/null 2>&1 &
    SAFETY_PID=$!
    SAFETY_SCRIPT="$SCRIPT"
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

# ── 可见宽度计算（纯 bash，中文=2，ASCII=1）────────────────
# 原来每次调用起一个 python3；一屏菜单调 14 次，低配 VPS 上要一两秒。
# 而 Alpine / OpenWrt 常常没有 python3，旧的退化分支 ${#1} 把中文按 1 列算，
# 整个界面会错位 —— 恰恰是本脚本主打支持的系统。
#
# 这里按 UTF-8 首字节分段判宽，不需要码点（bash 3.2 的 printf %d "'c"
# 只给首字节而非码点），也不需要 awk 的多字节支持：
#   <0x80        ASCII                      宽 1
#   0x80-0xBF    UTF-8 续字节                宽 0（仅在非 UTF-8 locale 按字节
#                                           遍历时出现，这样两种模式结果一致）
#   0xC2-0xE2    拉丁/希腊/西里尔、符号、制表、几何图形   宽 1
#   0xE3-0xED    CJK 标点、假名、汉字、谚文    宽 2
#   0xEE         私用区                      宽 1
#   0xEF         全角标点（，：（）等）        宽 2
#   >=0xF0       四字节（emoji 等）            宽 2
# 已知近似：BMP 内的 emoji（0xE2 段）和阿拉伯表现形式（0xEF 段）会各差 1 列。
# 对本脚本实际用到的字符集（ASCII + 汉字 + 全角标点 + ● ✓ ◆ › ━ ─ ×）结果精确。
vis_len() {
    local TEXT="$1" LEN=0 I CH B
    for ((I=0; I<${#TEXT}; I++)); do
        CH="${TEXT:I:1}"
        printf -v B '%d' "'$CH" 2>/dev/null || B=63
        B=$(( B & 255 ))
        if [ "$B" -lt 128 ]; then LEN=$((LEN + 1))
        elif [ "$B" -le 191 ]; then :
        elif [ "$B" -le 226 ]; then LEN=$((LEN + 1))
        elif [ "$B" -le 237 ]; then LEN=$((LEN + 2))
        elif [ "$B" -eq 238 ]; then LEN=$((LEN + 1))
        elif [ "$B" -eq 239 ]; then LEN=$((LEN + 2))
        else LEN=$((LEN + 2))
        fi
    done
    printf '%s\n' "$LEN"
}

# ── 响应式终端布局 ────────────────────────────────────────
BOX_W=64
UI_COMPACT=0
APP_UI_TITLE="VPS INIT/MANAGEMENT TOOLS"
APP_VERSION="V0.1.0"
APP_AUTHOR="Boyang"

# 一屏菜单会调用本函数约 20 次。原来每次都 fork 一个 grep 判断格式、
# 再 fork 一个 tput 取宽度。宽度在两次 SIGWINCH 之间不会变，缓存即可。
QUENCH_COLS_CACHE=""

ui_invalidate_dimensions() { QUENCH_COLS_CACHE=""; }

ui_refresh_dimensions() {
    local COLS="${COLUMNS:-}"
    # COLUMNS 可用就直接用：读变量不 fork，而且调用方（含测试）可以逐次改它。
    # 只有 COLUMNS 不可用时才退回 tput，并把那次结果缓存到下一个 SIGWINCH。
    case "$COLS" in
        ''|*[!0-9]*)
            if [ -z "$QUENCH_COLS_CACHE" ]; then
                QUENCH_COLS_CACHE=$(tput cols 2>/dev/null || echo 80)
                case "$QUENCH_COLS_CACHE" in ''|*[!0-9]*) QUENCH_COLS_CACHE=80 ;; esac
            fi
            COLS="$QUENCH_COLS_CACHE"
            ;;
    esac
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

# 普通内容行：PLAIN=纯文本(算宽度)  COLORED=带色码(显示用)
# 用法: box_line "纯文本" "带色码文本"
box_line() {
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
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
    sshd_effective_reset
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

# ── 权限检查 ──────────────────────────────────────────────
case "${1:-}" in
    --help|-h|help|--version|-v) QUENCH_NO_ROOT_NEEDED=1 ;;
    *) QUENCH_NO_ROOT_NEEDED=0 ;;
esac
if [ "$EUID" -ne 0 ] && [ "${QUENCH_TEST_MODE:-0}" != "1" ] && [ "$QUENCH_NO_ROOT_NEEDED" != "1" ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 通用工具函数 ──────────────────────────────────────────
# sshd -T 每次都要解析整份配置，是主菜单最贵的一次 fork，而一屏要问三次
# （Port / PasswordAuthentication / PubkeyAuthentication）。缓存整份输出，
# 在改写 sshd_config（restart_ssh）和每轮主菜单开头失效即可。
QUENCH_SSHD_EFFECTIVE_CACHE=""
QUENCH_SSHD_CACHE_LOADED=0

sshd_effective_reset() {
    QUENCH_SSHD_EFFECTIVE_CACHE=""
    QUENCH_SSHD_CACHE_LOADED=0
}

# 调用方几乎都是 VALUE=$(get_config X) 这种命令替换，子 shell 里填好的缓存
# 出了子 shell 就没了。所以热路径必须在父 shell 里先装载一次，之后的子 shell
# 才能继承到已填好的变量、直接命中。
sshd_effective_reload() {
    QUENCH_SSHD_EFFECTIVE_CACHE=""
    QUENCH_SSHD_CACHE_LOADED=1
    command -v sshd >/dev/null 2>&1 || return 0
    QUENCH_SSHD_EFFECTIVE_CACHE=$(sshd -T 2>/dev/null || true)
}

sshd_effective_value() {
    local KEY="$1" VALUE
    command -v sshd >/dev/null 2>&1 || return 1
    if [ "$QUENCH_SSHD_CACHE_LOADED" != 1 ]; then
        QUENCH_SSHD_EFFECTIVE_CACHE=$(sshd -T 2>/dev/null || true)
        QUENCH_SSHD_CACHE_LOADED=1
    fi
    [ -n "$QUENCH_SSHD_EFFECTIVE_CACHE" ] || return 1
    VALUE=$(printf '%s\n' "$QUENCH_SSHD_EFFECTIVE_CACHE" \
        | awk -v k="$KEY" 'tolower($1) == tolower(k) {print $2; exit}')
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

# 目标 authorized_keys 一律显式传入；省略时才回落到全局 AUTH_KEYS。
# 以前这些函数只读全局变量，调用方靠 `local AUTH_KEYS` 的动态作用域来“换用户”，
# 谁改动一下调用顺序，公钥就会被写到 root 头上。
ssh_key_count() {
    local AUTH_FILE="${1:-$AUTH_KEYS}" COUNT
    COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_FILE" 2>/dev/null || true)
    case "$COUNT" in
        ''|*[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$COUNT" ;;
    esac
}

set_config_file() {
    local FILE="$1" KEY="$2" VALUE="$3"
    local BODY BLOCK TMP
    [ -f "$FILE" ] || : > "$FILE"
    BODY=$(quench_mktemp) || return 1
    BLOCK=$(quench_mktemp) || { rm -f "$BODY"; return 1; }
    TMP=$(quench_mktemp) || { rm -f "$BODY" "$BLOCK"; return 1; }

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

# 回滚被 Quench 覆盖的配置文件，并接管备份文件的生命周期。
# EXISTED != yes 表示改动前本就没有该文件，删掉新写入的内容即可。
# 恢复失败时保留备份并明确告警，绝不因为 cp 失败而删掉用户原有配置。
restore_backup_or_remove() {
    local BACKUP="$1" TARGET="$2" EXISTED="$3"
    if [ "$EXISTED" != yes ]; then
        rm -f "$TARGET" "$BACKUP"
        return 0
    fi
    if cp "$BACKUP" "$TARGET"; then
        rm -f "$BACKUP"
        return 0
    fi
    error "无法恢复 ${TARGET}，已保留备份：${BACKUP}"
    error "请立即手动执行：cp ${BACKUP} ${TARGET}"
    return 1
}

# 用同目录临时文件 + rename 原子替换目标文件。
# 直接 cp 覆盖活配置时，写到一半失败会留下被截断的文件（把 sshd_config 写坏 = 断联）；
# rename(2) 保证目标在任何时刻要么是旧内容、要么是新内容。
# 临时文件必须与目标同目录：跨文件系统的 mv 会退化成 copy+unlink，重新引入非原子窗口。
# rename 会换掉 inode，所以显式沿用目标原有权限与属主；目标不存在时用 DEFAULT_MODE。
# 已知不保留：ACL 与 xattr；SELinux 上下文靠 restorecon 尽力恢复。
atomic_replace_file() {
    local SOURCE="$1" TARGET="$2" DEFAULT_MODE="${3:-0644}" DIR TMP MODE OWNER
    [ -f "$SOURCE" ] || return 1
    DIR=$(dirname "$TARGET")
    mkdir -p "$DIR" || return 1
    TMP=$(mktemp "$DIR/.quench-stage.XXXXXX") || return 1
    if ! cat "$SOURCE" > "$TMP"; then
        rm -f "$TMP"
        return 1
    fi
    if [ -e "$TARGET" ]; then
        MODE=$(stat -c '%a' "$TARGET" 2>/dev/null || stat -f '%Lp' "$TARGET" 2>/dev/null || true)
        OWNER=$(stat -c '%u:%g' "$TARGET" 2>/dev/null || stat -f '%u:%g' "$TARGET" 2>/dev/null || true)
    fi
    chmod "${MODE:-$DEFAULT_MODE}" "$TMP" 2>/dev/null || true
    if [ -n "${OWNER:-}" ]; then
        chown "$OWNER" "$TMP" 2>/dev/null || true
    fi
    if ! mv "$TMP" "$TARGET"; then
        rm -f "$TMP"
        return 1
    fi
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$TARGET" >/dev/null 2>&1 || true
    fi
    return 0
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
            if ! atomic_replace_file "$LAST_SSHD_BACKUP" "$SSHD_CONFIG"; then
                error "回滚写入失败，sshd_config 保持原样，请立即手动恢复备份：$LAST_SSHD_BACKUP"
                return 1
            fi
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
    local AUTH_FILE="${1:-$AUTH_KEYS}"
    if [ ! -f "$AUTH_FILE" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$AUTH_FILE" 2>/dev/null; then
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
    done < "$AUTH_FILE"
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
# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：show_keys 未收到目标 authorized_keys 路径"; return 1; }
    print_header "查看已有公钥"
    list_keys "$AUTH_FILE"
}

add_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：add_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴完成后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 结束输入："
    echo ""
    menu_div
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    menu_div
    echo ""

    PUBKEY_INPUT=${PUBKEY_INPUT%$'\r'}
    if [ -z "$PUBKEY_INPUT" ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if [ "$(printf '%s\n' "$PUBKEY_INPUT" | wc -l | tr -d ' ')" -ne 1 ] \
        || ! printf '%s\n' "$PUBKEY_INPUT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+([[:space:]].*)?$'; then
        error "公钥格式不正确；每次只能添加一把 Ed25519/RSA/ECDSA/FIDO 公钥。"
        return
    fi

    mkdir -p "$(dirname "$AUTH_FILE")"
    chmod 700 "$(dirname "$AUTH_FILE")"

    # 检查是否已存在相同公钥（取类型+主体比较，忽略备注差异）
    local KEY_BODY
    KEY_BODY=$(echo "$PUBKEY_INPUT" | awk '{print $1, $2}')
    if grep -qF "$KEY_BODY" "$AUTH_FILE" 2>/dev/null; then
        warn "该公钥已存在，跳过添加（避免重复）"
        return
    fi

    echo "$PUBKEY_INPUT" >> "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"

    local TOTAL
    TOTAL=$(ssh_key_count "$AUTH_FILE")
    info "公钥已添加！当前共 $TOTAL 个公钥 ✓"
}

delete_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：delete_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "删除 SSH 公钥"

    if ! list_keys "$AUTH_FILE"; then
        return
    fi

    menu_div
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_FILE"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"; return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 取公钥主体（类型+base64）作为匹配依据，避免尾部空格/备注差异导致删除失败
    local KEY_BODY
    KEY_BODY=$(echo "$TARGET_LINE" | awk '{print $1, $2}')
    grep -vF "$KEY_BODY" "$AUTH_FILE" > "${AUTH_FILE}.tmp" || true
    mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    info "公钥已删除 ✓"
}

generate_key() {
    local AUTH_FILE="${1:-}"
    [ -n "$AUTH_FILE" ] || { error "内部错误：generate_key 未收到目标 authorized_keys 路径"; return 1; }
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    menu_item "1" "Ed25519  ${DIM}推荐，更安全更短${NC}"
    menu_item "2" "RSA 4096"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择密钥类型 [0-2]: ')" KEY_TYPE_CHOICE

    case "$KEY_TYPE_CHOICE" in
        0) return ;;
        1) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        2) KEY_TYPE="rsa";     KEY_BITS="-b 4096" ;;
        *) warn "无效选项，已取消。"; return ;;
    esac

    echo ""
    read -rp "  输入密钥备注（如 mypc@home，直接回车跳过）: " KEY_COMMENT
    KEY_COMMENT="${KEY_COMMENT:-ssh-key-$(date +%Y%m%d)}"

    local TMP_DIR KEY_FILE OLD_UMASK
    # 私钥只允许落在 mktemp -d 创建的 0700 目录里。
    # 可预测的 /tmp/quench_tmp_$$ 兜底会让本机攻击者预建目录并读走私钥，故不再保留。
    OLD_UMASK=$(umask)
    umask 077
    if ! TMP_DIR=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-keygen.XXXXXX"); then
        umask "$OLD_UMASK"
        error "无法创建安全的临时目录，已中止密钥生成。"
        return 1
    fi
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    # shellcheck disable=SC2086 # KEY_BITS intentionally expands to "-b 4096" for RSA only.
    if ! ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "$KEY_FILE" -N "" -q 2>/dev/null; then
        error "密钥生成失败。"; rm -rf "$TMP_DIR"; umask "$OLD_UMASK"; return 1
    fi

    local PUBKEY PRIVKEY FINGER
    PUBKEY=$(cat "${KEY_FILE}.pub")
    PRIVKEY=$(cat "$KEY_FILE")
    FINGER=$(ssh-keygen -lf "${KEY_FILE}.pub" 2>/dev/null | awk '{print $2}')

    print_header "密钥生成完成 — 请复制保存"

    echo -e "  ${DIM}类型：${NC}${BOLD}$KEY_TYPE${NC}   ${DIM}备注：${NC}${YELLOW}$KEY_COMMENT${NC}"
    echo -e "  ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
    echo ""
    echo -e "  ${BOLD}${RED}┌─── 私钥（仅显示一次，请立即复制！）───┐${NC}"
    echo ""
    echo "$PRIVKEY"
    echo ""
    echo -e "  ${BOLD}${RED}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}┌─── 公钥（可添加到服务器）─────────────┐${NC}"
    echo ""
    echo "$PUBKEY"
    echo ""
    echo -e "  ${BOLD}${GREEN}└────────────────────────────────────────┘${NC}"
    echo ""
    menu_div
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    menu_div
    echo ""

    read -rp "  是否将公钥添加到本服务器？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        mkdir -p "$(dirname "$AUTH_FILE")"; chmod 700 "$(dirname "$AUTH_FILE")"
        local KEY_BODY
        KEY_BODY=$(echo "$PUBKEY" | awk '{print $1, $2}')
        if grep -qF "$KEY_BODY" "$AUTH_FILE" 2>/dev/null; then
            warn "该公钥已存在于服务器，跳过添加"
        else
            echo "$PUBKEY" >> "$AUTH_FILE"; chmod 600 "$AUTH_FILE"
            local TOTAL
            TOTAL=$(ssh_key_count "$AUTH_FILE")
            echo ""
            info "公钥已添加到服务器！当前共 $TOTAL 个公钥 ✓"
        fi
    else
        warn "已跳过，公钥未添加到服务器。"
    fi

    rm -rf "$TMP_DIR"
    umask "$OLD_UMASK"
}

ssh_restore_last_backup() {
    [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ] || return 1
    atomic_replace_file "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" || return 1
    restart_ssh >/dev/null 2>&1 || true
}

ssh_apply_policy() {
    local LABEL="$1" PASSWORD="$2" KEYBOARD="$3" PUBKEY="$4" ROOT_LOGIN="$5" CANDIDATE
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    set_config_file "$CANDIDATE" PasswordAuthentication "$PASSWORD"
    set_config_file "$CANDIDATE" KbdInteractiveAuthentication "$KEYBOARD"
    set_config_file "$CANDIDATE" PubkeyAuthentication "$PUBKEY"
    set_config_file "$CANDIDATE" PermitRootLogin "$ROOT_LOGIN"
    set_config_file "$CANDIDATE" PermitEmptyPasswords no
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "$LABEL"; then
        rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return 1
    fi
    backup_config
    safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"; cancel_safety_timer; error "SSH 配置写入失败"; return 1
    fi
    rm -f "$CANDIDATE"
    if ! apply_and_restart; then cancel_safety_timer; return 1; fi
    local EFFECTIVE_ROOT
    EFFECTIVE_ROOT=$(get_config PermitRootLogin)
    [ "$ROOT_LOGIN" != prohibit-password ] || [ "$EFFECTIVE_ROOT" != without-password ] || EFFECTIVE_ROOT=prohibit-password
    if [ "$(get_config PasswordAuthentication)" != "$PASSWORD" ] \
        || [ "$(get_config KbdInteractiveAuthentication)" != "$KEYBOARD" ] \
        || [ "$(get_config PubkeyAuthentication)" != "$PUBKEY" ] \
        || [ "$EFFECTIVE_ROOT" != "$ROOT_LOGIN" ]; then
        error "sshd 最终生效值与目标策略不一致，正在恢复"
        ssh_restore_last_backup
        cancel_safety_timer
        return 1
    fi
    audit_action "$LABEL" SUCCESS
    info "$LABEL 已生效 ✓"
    safety_confirm
}

ssh_apply_recommended_policy() {
    local ADMIN="$1"
    user_ready_admin "$ADMIN" || { error "$ADMIN 不是已配置公钥的非 root 管理员"; return 1; }
    ssh_apply_policy "SSH 仅密钥并禁止 root 登录" no no yes no
}

set_login_mode() {
    print_header "SSH 登录策略"
    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT MODE ADMIN TOKEN
    CURRENT_PWD=$(get_config PasswordAuthentication)
    CURRENT_PUBKEY=$(get_config PubkeyAuthentication)
    CURRENT_ROOT=$(get_config PermitRootLogin)
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo -e "  可接管管理员           : ${BOLD}$(user_ready_admin_count)${NC}"
    echo ""
    menu_div
    menu_item "1" "仅密钥 + 禁止 root SSH  ${DIM}推荐${NC}"
    menu_item "2" "密码 + 密钥，root 仅允许密钥"
    menu_item "3" "仅密钥，允许 root 使用密钥"
    menu_item "4" "密码 + 密钥并允许 root  ${RED}高风险${NC}" "$YELLOW"
    menu_item "0" "返回上级" "$RED"
    menu_div
    read -rp "$(ui_prompt '选择策略 [0-4]: ')" MODE
    case "$MODE" in
        1)
            ADMIN=$(user_select_ready_admin) || return
            warn "请先在另一个终端用 $ADMIN 的密钥登录，并成功执行 sudo -v。"
            read -rp "  测试完成后输入管理员用户名 $ADMIN: " TOKEN
            [ "$TOKEN" = "$ADMIN" ] || { warn "未确认，配置未修改"; return; }
            ssh_apply_recommended_policy "$ADMIN"
            ;;
        2) ssh_apply_policy "SSH 密码和密钥登录（root 仅密钥）" yes yes yes prohibit-password ;;
        3)
            ADMIN=$(user_select_ready_admin) || return
            ssh_apply_policy "SSH 仅密钥登录（允许 root 密钥）" no no yes prohibit-password
            ;;
        4)
            warn "该策略会允许 root 使用密码直接登录，暴力破解风险显著增加。"
            read -rp "  输入 ALLOW-ROOT 继续: " TOKEN
            [ "$TOKEN" = ALLOW-ROOT ] || { warn "已取消"; return; }
            ssh_apply_policy "SSH 密码和密钥登录（允许 root）" yes yes yes yes
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

SSH_PORT_STATE_FILE="${SSH_PORT_STATE_FILE:-$QUENCH_DATA_DIR/ssh-port-migration.state}"

ssh_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

ssh_port_number_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

ssh_port_listening() {
    local PORT="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk -v port=":$PORT" '$4 ~ port "$" {found=1} END {exit !found}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v port=":$PORT" '$4 ~ port "$" {found=1} END {exit !found}'
    else
        return 1
    fi
}

ssh_set_ports_file() {
    local FILE="$1" FIRST BODY SETTINGS PORT
    shift
    FIRST="$1"; shift
    BODY=$(quench_mktemp) || return 1
    SETTINGS=$(quench_mktemp) || { rm -f "$BODY"; return 1; }
    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        managed && $0 !~ /^[[:space:]]*Port[[:space:]]+/ {print}
    ' "$FILE" > "$SETTINGS" || { rm -f "$BODY" "$SETTINGS"; return 1; }
    awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        managed {next}
        /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?$/ {
            print "# Disabled by Quench SSH port migration: " $0
            next
        }
        {print}
    ' "$FILE" > "$BODY" || { rm -f "$BODY" "$SETTINGS"; return 1; }
    {
        echo "$SSHD_MANAGED_BEGIN"
        echo "Port $FIRST"
        for PORT in "$@"; do echo "Port $PORT"; done
        cat "$SETTINGS"
        echo "$SSHD_MANAGED_END"
        echo ""
        cat "$BODY"
    } > "$FILE"
    rm -f "$BODY" "$SETTINGS"
    return 0
}

ssh_apply_ports() {
    local LABEL="$1" CANDIDATE
    shift
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    ssh_set_ports_file "$CANDIDATE" "$@" || { rm -f "$CANDIDATE"; return 1; }
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "$LABEL"; then
        rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return 1
    fi
    backup_config
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"; error "SSH 配置写入失败"; return 1
    fi
    rm -f "$CANDIDATE"
    apply_and_restart || return 1
    audit_action "$LABEL" SUCCESS
}

ssh_write_port_state() {
    local OLD_PORT="$1" NEW_PORT="$2"
    mkdir -p "$(dirname "$SSH_PORT_STATE_FILE")" || return 1
    printf 'OLD_PORT=%s\nNEW_PORT=%s\n' "$OLD_PORT" "$NEW_PORT" > "$SSH_PORT_STATE_FILE"
    chmod 600 "$SSH_PORT_STATE_FILE"
}

ssh_read_port_state() {
    [ -r "$SSH_PORT_STATE_FILE" ] || return 1
    OLD_PORT=$(awk -F= '$1 == "OLD_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$SSH_PORT_STATE_FILE")
    NEW_PORT=$(awk -F= '$1 == "NEW_PORT" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$SSH_PORT_STATE_FILE")
    ssh_port_number_valid "$OLD_PORT" && ssh_port_valid "$NEW_PORT"
}

ssh_sync_fail2ban_ports() {
    local PORTS="$1" JAIL_FILE WAS_RUNNING BACKUP EXISTED=no FAILED=false
    declare -F f2b_config_file >/dev/null 2>&1 || return 0
    # 保留配置但已卸载 Fail2ban 时，新装流程会按实时 SSH 端口重建配置；
    # 此处不能让一份休眠配置阻断 SSH 端口迁移。
    command -v fail2ban-client >/dev/null 2>&1 || return 0
    declare -F f2b_ensure_managed_config >/dev/null 2>&1 || return 1
    declare -F f2b_set_param_jail >/dev/null 2>&1 || return 1
    declare -F f2b_runtime_healthy >/dev/null 2>&1 || return 1
    f2b_ports_valid "$PORTS" || { warn "Fail2ban 端口列表无效"; return 1; }
    JAIL_FILE=$(f2b_config_file)
    BACKUP=$(quench_mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    WAS_RUNNING=$(f2b_status)
    if ! f2b_ensure_managed_config "$PORTS" \
        || ! f2b_set_param_jail port "$PORTS" \
        || ! f2b_managed_ports_match "$PORTS"; then
        FAILED=true
    elif [ "$WAS_RUNNING" = running ] \
        && { ! restart_fail2ban >/dev/null 2>&1 || ! f2b_runtime_healthy; }; then
        FAILED=true
    elif [ "$WAS_RUNNING" != running ] && ! f2b_validate_config; then
        FAILED=true
    fi
    if [ "$FAILED" = true ]; then
        restore_backup_or_remove "$BACKUP" "$JAIL_FILE" "$EXISTED" || return 1
        if [ "$WAS_RUNNING" = running ]; then
            restart_fail2ban >/dev/null 2>&1 && f2b_runtime_healthy \
                || warn "Fail2ban 原配置恢复后仍未正常运行，请立即检查服务"
        fi
        warn "Fail2ban 端口同步或 sshd jail 验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
    [ "$WAS_RUNNING" = running ] \
        && info "Fail2ban sshd jail 已验证：端口 ${PORTS} ✓" \
        || info "Fail2ban 配置已验证：端口 ${PORTS}（服务保持停止）"
}

ssh_firewall_close_port() {
    local PORT="$1" FAILED=false FIREWALLD_ZONE=""
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1 || true
        ufw --force delete limit "$PORT/tcp" >/dev/null 2>&1 || true
        if ufw_port_rule_present "$PORT" 'ALLOW|LIMIT' broad; then
            error "ufw 的 $PORT/tcp 宽泛放行规则仍然存在"
            FAILED=true
        else
            info "ufw 已清理 $PORT/tcp 的 Quench 宽泛放行规则"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && svc_is_active firewalld; then
        FIREWALLD_ZONE=$(fw_firewalld_zone)
        firewall-cmd --permanent --zone="$FIREWALLD_ZONE" --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
        if ! firewall-cmd --reload >/dev/null 2>&1 \
            || firewall-cmd --zone="$FIREWALLD_ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then
            error "firewalld 的 $PORT/tcp 放行规则清理失败"
            FAILED=true
        else
            info "firewalld 已清理 $PORT/tcp 放行规则"
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null || break
        done
        [ -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        if iptables -C INPUT -p tcp --dport "$PORT" -m comment --comment vps-quench-ssh -j ACCEPT 2>/dev/null; then
            error "Quench 标记的 iptables $PORT/tcp 规则仍然存在"
            FAILED=true
        fi
    fi
    [ "$FAILED" = false ]
}

ssh_port_finalize() {
    local TOKEN CLOSE_OLD OLD_PORT NEW_PORT
    ssh_read_port_state || { warn "没有待完成的 SSH 端口迁移"; return 1; }
    warn "必须已在另一个终端通过端口 $NEW_PORT 成功登录。"
    read -rp "  确认测试成功请输入 TESTED: " TOKEN
    [ "$TOKEN" = TESTED ] || { warn "未确认，继续同时保留 $OLD_PORT 和 $NEW_PORT"; return; }
    ssh_port_listening "$NEW_PORT" || { error "没有检测到端口 $NEW_PORT 正在监听"; return 1; }
    firewall_port_ready "$NEW_PORT" || { error "新端口 $NEW_PORT 的防火墙放行规则验证失败"; return 1; }
    ssh_apply_ports "SSH 端口完成迁移 $OLD_PORT → $NEW_PORT" "$NEW_PORT" || return 1
    ssh_port_listening "$NEW_PORT" || { error "切换后新端口 $NEW_PORT 未监听，正在恢复双端口"; ssh_restore_last_backup; return 1; }
    if ssh_port_listening "$OLD_PORT"; then
        error "旧端口 $OLD_PORT 仍被监听，可能有其他 sshd 配置声明 Port；暂不关闭防火墙"
        return 1
    fi
    if ! ssh_sync_fail2ban_ports "$NEW_PORT"; then
        error "Fail2ban 未能切换到新端口，正在恢复 SSH 双端口"
        ssh_restore_last_backup || true
        ssh_sync_fail2ban_ports "$OLD_PORT,$NEW_PORT" || true
        return 1
    fi
    read -rp "  关闭旧端口 $OLD_PORT 的防火墙放行？(Y/n): " CLOSE_OLD
    CLOSE_OLD="${CLOSE_OLD:-y}"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$' && ! ssh_firewall_close_port "$OLD_PORT"; then
        error "旧端口防火墙规则未完全清理，迁移状态已保留以便重试"
        return 1
    fi
    rm -f "$SSH_PORT_STATE_FILE"
    info "SSH 已仅监听新端口 $NEW_PORT ✓"
}

ssh_port_rollback() {
    local CLOSE_NEW OLD_PORT NEW_PORT
    ssh_read_port_state || { warn "没有待回滚的 SSH 端口迁移"; return 1; }
    if ! firewall_port_ready "$OLD_PORT"; then
        warn "旧 SSH 端口缺少有效防火墙规则，正在补齐"
        firewall_allow_port "$OLD_PORT" || return 1
    fi
    ssh_apply_ports "回滚 SSH 端口迁移到 $OLD_PORT" "$OLD_PORT" || return 1
    ssh_port_listening "$OLD_PORT" || { error "回滚后旧端口 $OLD_PORT 未恢复监听"; ssh_restore_last_backup; return 1; }
    if ! ssh_sync_fail2ban_ports "$OLD_PORT"; then
        error "Fail2ban 未能恢复旧端口保护，正在恢复 SSH 双端口"
        ssh_restore_last_backup || true
        return 1
    fi
    read -rp "  清理新端口 $NEW_PORT 的防火墙放行？(y/N): " CLOSE_NEW
    if echo "$CLOSE_NEW" | grep -qiE '^y(es)?$' && ! ssh_firewall_close_port "$NEW_PORT"; then
        error "新端口防火墙规则未完全清理，迁移状态已保留以便重试"
        return 1
    fi
    rm -f "$SSH_PORT_STATE_FILE"
    info "SSH 端口迁移已回滚 ✓"
}

change_port() {
    print_header "SSH 端口双端口迁移"
    local CURRENT_PORT INPUT_PORT CHOICE OLD_PORT NEW_PORT TEST_NOW
    if ssh_read_port_state; then
        warn "检测到未完成迁移：$OLD_PORT → $NEW_PORT"
        menu_item "1" "已测试新端口，完成切换"
        menu_item "2" "回滚到旧端口"
        menu_item "0" "暂不处理，继续保留双端口" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CHOICE
        case "$CHOICE" in 1) ssh_port_finalize ;; 2) ssh_port_rollback ;; esac
        return
    fi
    CURRENT_PORT=$(get_config Port); CURRENT_PORT="${CURRENT_PORT:-22}"
    echo -e "  当前端口：${BOLD}$CURRENT_PORT${NC}"
    read -rp "  新端口（1024-65535，回车取消）: " INPUT_PORT
    [ -n "$INPUT_PORT" ] || return
    ssh_port_valid "$INPUT_PORT" || { error "端口必须在 1024-65535 之间"; return 1; }
    [ "$INPUT_PORT" != "$CURRENT_PORT" ] || { warn "端口没有变化"; return; }
    ssh_port_listening "$INPUT_PORT" && { error "端口 $INPUT_PORT 已被其他服务监听"; return 1; }
    warn "请先在云厂商安全组放行 TCP ${INPUT_PORT}；旧端口 ${CURRENT_PORT} 暂时不会关闭。"
    read -rp "  已放行并继续？(y/N): " CHOICE
    echo "$CHOICE" | grep -qiE '^y(es)?$' || return
    firewall_allow_port "$INPUT_PORT" || return 1
    if ! ssh_apply_ports "SSH 双端口迁移 $CURRENT_PORT + $INPUT_PORT" "$CURRENT_PORT" "$INPUT_PORT"; then
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_port_listening "$CURRENT_PORT" || ! ssh_port_listening "$INPUT_PORT"; then
        error "双端口监听验证失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! firewall_port_ready "$INPUT_PORT"; then
        error "新端口防火墙规则生效验证失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_write_port_state "$CURRENT_PORT" "$INPUT_PORT"; then
        error "迁移状态保存失败，正在恢复旧端口"
        ssh_restore_last_backup || true
        ssh_firewall_close_port "$INPUT_PORT" || true
        return 1
    fi
    if ! ssh_sync_fail2ban_ports "$CURRENT_PORT,$INPUT_PORT"; then
        error "Fail2ban 新旧端口同步失败，正在回滚 SSH 配置与防火墙"
        ssh_restore_last_backup || true
        ssh_sync_fail2ban_ports "$CURRENT_PORT" || true
        ssh_firewall_close_port "$INPUT_PORT"
        rm -f "$SSH_PORT_STATE_FILE"
        return 1
    fi
    info "SSH 现同时监听 $CURRENT_PORT 和 $INPUT_PORT ✓"
    echo -e "  请保持当前连接，并新开终端测试：${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    read -rp "  已测试成功，现在完成切换？(y/N): " TEST_NOW
    echo "$TEST_NOW" | grep -qiE '^y(es)?$' && ssh_port_finalize
}

ssh_security_status() {
    print_header "SSH 状态与安全检查"
    local VALUE WARNINGS=0
    for KEY in Port PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication PubkeyAuthentication MaxAuthTries LoginGraceTime; do
        VALUE=$(get_config "$KEY")
        printf '  %-34s %s\n' "$KEY" "${VALUE:-未确认}"
    done
    echo ""
    echo -e "  非 root 管理员：${BOLD}$(user_admin_count)${NC}"
    echo -e "  可安全接管管理员：${BOLD}$(user_ready_admin_count)${NC}"
    [ "$(user_ready_admin_count)" -gt 0 ] || { warn "没有同时具备管理员权限和 SSH 公钥的非 root 用户"; WARNINGS=$((WARNINGS + 1)); }
    [ "$(get_config PermitRootLogin)" = no ] || { warn "root SSH 尚未完全禁止"; WARNINGS=$((WARNINGS + 1)); }
    [ "$(get_config PasswordAuthentication)" = no ] || { warn "SSH 密码认证仍允许"; WARNINGS=$((WARNINGS + 1)); }
    if command -v ss >/dev/null 2>&1; then
        echo ""
        echo "  SSH 监听："
        ss -lntp 2>/dev/null | awk '/sshd/ {print "  " $0}' || true
    fi
    if ssh_read_port_state; then warn "存在未完成端口迁移：$OLD_PORT → $NEW_PORT"; WARNINGS=$((WARNINGS + 1)); fi
    echo ""
    [ "$WARNINGS" -eq 0 ] && info "SSH 访问链路检查通过" || warn "发现 $WARNINGS 项需要确认"
}
# ══════════════════════════════════════════════════════════
#  用户生命周期与权限管理
# ══════════════════════════════════════════════════════════

USER_PASSWD_FILE="${USER_PASSWD_FILE:-/etc/passwd}"
USER_GROUP_FILE="${USER_GROUP_FILE:-/etc/group}"
USER_SUDOERS_DIR="${USER_SUDOERS_DIR:-/etc/sudoers.d}"
USER_ADMIN_SUDOERS_FILE="${USER_ADMIN_SUDOERS_FILE:-$USER_SUDOERS_DIR/90-quench-admins}"
USER_NOPASSWD_MARKER="# Managed by Quench: passwordless sudo"

user_passwd_entries() {
    if [ "$USER_PASSWD_FILE" != /etc/passwd ] && [ -r "$USER_PASSWD_FILE" ]; then
        cat "$USER_PASSWD_FILE"
    elif command -v getent >/dev/null 2>&1; then
        getent passwd
    else
        cat /etc/passwd
    fi
}

user_group_entries() {
    if [ "$USER_GROUP_FILE" != /etc/group ] && [ -r "$USER_GROUP_FILE" ]; then
        cat "$USER_GROUP_FILE"
    elif command -v getent >/dev/null 2>&1; then
        getent group
    else
        cat /etc/group
    fi
}

user_uid_min() {
    local VALUE
    VALUE=$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/login.defs 2>/dev/null || true)
    case "$VALUE" in ''|*[!0-9]*) echo 1000 ;; *) echo "$VALUE" ;; esac
}

user_valid_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

user_exists() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {found=1} END {exit !found}'
}

user_home() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $6; exit}'
}

user_uid() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $3; exit}'
}

user_shell() {
    local USERNAME="$1"
    user_passwd_entries | awk -F: -v user="$USERNAME" '$1 == user {print $7; exit}'
}

user_list_names() {
    local UID_MIN
    UID_MIN=$(user_uid_min)
    user_passwd_entries | awk -F: -v min="$UID_MIN" '
        $1 == "root" {print $1; next}
        $3 >= min && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1}
    '
}

user_count() {
    local COUNT
    COUNT=$(user_list_names | awk 'NF {count++} END {print count+0}')
    printf '%s\n' "$COUNT"
}

user_group_exists() {
    local GROUP="$1"
    user_group_entries | awk -F: -v group="$GROUP" '$1 == group {found=1} END {exit !found}'
}

user_groups() {
    local USERNAME="$1" USER_GROUP_LIST=""
    if command -v id >/dev/null 2>&1 && id "$USERNAME" >/dev/null 2>&1; then
        id -nG "$USERNAME" 2>/dev/null || true
        return
    fi
    USER_GROUP_LIST=$(user_group_entries | awk -F: -v user="$USERNAME" '
        $4 != "" {
            count=split($4, members, ",")
            for (i=1; i<=count; i++) if (members[i] == user) {printf "%s%s", sep, $1; sep=" "; break}
        }
        END {if (sep != "") print ""}
    ')
    printf '%s\n' "$USER_GROUP_LIST"
}

user_is_admin() {
    local USERNAME="$1" USER_GROUP_LIST
    [ "$USERNAME" = root ] && return 0
    USER_GROUP_LIST=" $(user_groups "$USERNAME") "
    [[ "$USER_GROUP_LIST" == *" sudo "* || "$USER_GROUP_LIST" == *" wheel "* ]]
}

user_admin_count() {
    local USERNAME COUNT=0
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        [ "$USERNAME" = root ] && continue
        user_is_admin "$USERNAME" && COUNT=$((COUNT + 1))
    done < <(user_list_names)
    printf '%s\n' "$COUNT"
}

user_authorized_keys() {
    local USERNAME="$1" HOME_DIR
    HOME_DIR=$(user_home "$USERNAME")
    [ -n "$HOME_DIR" ] || HOME_DIR="/home/$USERNAME"
    [ "$USERNAME" = root ] && [ -z "$(user_home root)" ] && HOME_DIR=/root
    printf '%s/.ssh/authorized_keys\n' "$HOME_DIR"
}

user_key_count() {
    local USERNAME="$1" KEY_FILE COUNT
    KEY_FILE=$(user_authorized_keys "$USERNAME")
    COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) ' "$KEY_FILE" 2>/dev/null || true)
    case "$COUNT" in ''|*[!0-9]*) echo 0 ;; *) echo "$COUNT" ;; esac
}

user_has_ssh_key() {
    [ "$(user_key_count "$1")" -gt 0 ]
}

user_ready_admin() {
    local USERNAME="$1"
    [ "$USERNAME" != root ] && user_exists "$USERNAME" && user_is_admin "$USERNAME" && user_has_ssh_key "$USERNAME"
}

user_ready_admin_count() {
    local USERNAME COUNT=0
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        user_ready_admin "$USERNAME" && COUNT=$((COUNT + 1))
    done < <(user_list_names)
    printf '%s\n' "$COUNT"
}

user_current_actor() {
    local CANDIDATE
    for CANDIDATE in "${SUDO_USER:-}" "${LOGNAME:-}" "${USER:-}"; do
        [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != root ] && user_exists "$CANDIDATE" && { echo "$CANDIDATE"; return; }
    done
    CANDIDATE=$(who -m 2>/dev/null | awk 'NR == 1 {print $1}')
    [ -n "$CANDIDATE" ] && user_exists "$CANDIDATE" && { echo "$CANDIDATE"; return; }
    echo root
}

user_password_state() {
    local USERNAME="$1" STATE
    STATE=$(passwd -S "$USERNAME" 2>/dev/null | awk 'NR == 1 {print $2}' || true)
    case "$STATE" in
        L|LK) echo "已锁定" ;;
        P|PS) echo "已设置" ;;
        NP) echo "无密码" ;;
        *) echo "未知" ;;
    esac
}

user_primary_group() {
    local USERNAME="$1" GROUP
    GROUP=$(id -gn "$USERNAME" 2>/dev/null || true)
    [ -n "$GROUP" ] && { echo "$GROUP"; return; }
    echo "$USERNAME"
}

user_fix_ssh_permissions() {
    local USERNAME="$1" HOME_DIR KEY_FILE GROUP
    HOME_DIR=$(user_home "$USERNAME")
    KEY_FILE=$(user_authorized_keys "$USERNAME")
    GROUP=$(user_primary_group "$USERNAME")
    [ -d "$HOME_DIR/.ssh" ] || return 0
    chmod 700 "$HOME_DIR/.ssh" 2>/dev/null || return 1
    chown "$USERNAME:$GROUP" "$HOME_DIR/.ssh" 2>/dev/null || return 1
    if [ -f "$KEY_FILE" ]; then
        chmod 600 "$KEY_FILE" 2>/dev/null || return 1
        chown "$USERNAME:$GROUP" "$KEY_FILE" 2>/dev/null || return 1
    fi
}

user_admin_group() {
    if user_group_exists sudo; then echo sudo
    elif user_group_exists wheel; then echo wheel
    elif command -v apt-get >/dev/null 2>&1; then echo sudo
    else echo wheel
    fi
}

user_ensure_admin_backend() {
    local GROUP SUDOERS_FILE TMP
    GROUP=$(user_admin_group)
    if ! user_group_exists "$GROUP"; then
        if command -v groupadd >/dev/null 2>&1; then groupadd "$GROUP"
        elif command -v addgroup >/dev/null 2>&1; then addgroup "$GROUP"
        else error "无法创建管理员组 $GROUP"; return 1
        fi
    fi
    command -v sudo >/dev/null 2>&1 || pkg_install sudo || { error "sudo 安装失败"; return 1; }
    mkdir -p "$USER_SUDOERS_DIR" || return 1
    SUDOERS_FILE="$USER_ADMIN_SUDOERS_FILE"
    # 暂存文件建在 sudoers.d 内，mv 才是同文件系统的原子 rename；
    # 名字带点号，sudo 会忽略它，不会在替换前被当成一条生效规则读入。
    TMP=$(mktemp "$USER_SUDOERS_DIR/.90-quench-admins.XXXXXX") || return 1
    printf '%%%s ALL=(ALL:ALL) ALL\n' "$GROUP" > "$TMP"
    chmod 440 "$TMP"
    if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$TMP" >/dev/null 2>&1; then
        rm -f "$TMP"
        error "sudoers 语法校验失败"
        return 1
    fi
    if ! mv "$TMP" "$SUDOERS_FILE"; then
        rm -f "$TMP"
        error "sudoers 写入失败"
        return 1
    fi
    chmod 440 "$SUDOERS_FILE"
    printf '%s\n' "$GROUP"
}

user_nopasswd_file() {
    local USERNAME="$1"
    user_valid_name "$USERNAME" || return 1
    printf '%s/91-quench-nopasswd-%s\n' "$USER_SUDOERS_DIR" "$USERNAME"
}

user_file_mode() {
    local FILE="$1" MODE
    MODE=$(stat -c '%a' "$FILE" 2>/dev/null || stat -f '%Lp' "$FILE" 2>/dev/null || true)
    printf '%s\n' "$MODE"
}

user_nopasswd_file_valid() {
    local USERNAME="$1" FILE="${2:-}" EXPECTED COUNT
    [ -n "$FILE" ] || FILE=$(user_nopasswd_file "$USERNAME") || return 1
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || return 1
    EXPECTED="$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL"
    [ "$(sed -n '1p' "$FILE" 2>/dev/null)" = "$USER_NOPASSWD_MARKER" ] \
        && [ "$(sed -n '2p' "$FILE" 2>/dev/null)" = "$EXPECTED" ] || return 1
    COUNT=$(wc -l < "$FILE" 2>/dev/null | tr -d '[:space:]')
    [ "$COUNT" = 2 ] && [ "$(user_file_mode "$FILE")" = 440 ]
}

user_nopasswd_enabled() {
    local FILE
    FILE=$(user_nopasswd_file "$1") || return 1
    user_nopasswd_file_valid "$1" "$FILE"
}

user_nopasswd_path_exists() {
    local FILE
    FILE=$(user_nopasswd_file "$1") || return 1
    [ -e "$FILE" ] || [ -L "$FILE" ]
}

user_nopasswd_runtime_valid() {
    local USERNAME="$1"
    command -v sudo >/dev/null 2>&1 || return 1
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USERNAME" -- sudo -n true >/dev/null 2>&1
    else
        sudo -n -u "$USERNAME" -- sudo -n true >/dev/null 2>&1
    fi
}

user_nopasswd_status() {
    local USERNAME="$1"
    if user_nopasswd_enabled "$USERNAME"; then
        echo "已开启（Quench）"
    elif user_nopasswd_runtime_valid "$USERNAME"; then
        echo "已开启（其他规则）"
    else
        echo "未开启"
    fi
}

user_nopasswd_enable() {
    local USERNAME="$1" TARGET TMP
    [ "$USERNAME" != root ] || { error "root 不需要免密 sudo"; return 1; }
    user_valid_name "$USERNAME" && user_exists "$USERNAME" \
        || { error "用户名无效或用户不存在"; return 1; }
    user_is_admin "$USERNAME" \
        || { error "请先授予 $USERNAME sudo/wheel 管理员权限"; return 1; }
    command -v sudo >/dev/null 2>&1 && command -v visudo >/dev/null 2>&1 \
        || { error "系统缺少 sudo 或 visudo"; return 1; }
    TARGET=$(user_nopasswd_file "$USERNAME") || return 1
    mkdir -p "$USER_SUDOERS_DIR" || return 1
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        user_nopasswd_file_valid "$USERNAME" "$TARGET" \
            || { error "$TARGET 已存在且不属于 Quench，拒绝覆盖"; return 1; }
        if user_nopasswd_runtime_valid "$USERNAME"; then
            info "$USERNAME 的 Quench 免密 sudo 已经生效"
            return 0
        fi
        error "Quench 免密 sudo 文件存在但未实际生效，请查看最终 sudo 权限"
        return 1
    fi
    TMP=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    {
        printf '%s\n' "$USER_NOPASSWD_MARKER"
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USERNAME"
    } > "$TMP"
    chmod 440 "$TMP"
    if ! user_nopasswd_file_valid "$USERNAME" "$TMP" \
        || ! visudo -cf "$TMP" >/dev/null 2>&1 \
        || ! mv "$TMP" "$TARGET"; then
        rm -f "$TMP"
        error "免密 sudo 配置校验或写入失败"
        return 1
    fi
    if ! chmod 440 "$TARGET" \
        || ! user_nopasswd_file_valid "$USERNAME" "$TARGET" \
        || ! user_nopasswd_runtime_valid "$USERNAME"; then
        rm -f "$TARGET"
        error "免密 sudo 运行验证失败，已恢复原配置"
        return 1
    fi
    audit_action "为用户 $USERNAME 开启免密 sudo" SUCCESS
    info "$USERNAME 已获得免密 sudo 权限 ✓"
    warn "该权限等同完整 root 控制；安装任务结束后可从本菜单关闭"
}

user_nopasswd_disable() {
    local USERNAME="$1" TARGET
    TARGET=$(user_nopasswd_file "$USERNAME") \
        || { error "用户名不适用于 Quench sudoers 文件"; return 1; }
    if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
        info "$USERNAME 没有 Quench 管理的免密 sudo 配置"
        user_nopasswd_runtime_valid "$USERNAME" \
            && warn "其他 sudoers 规则仍然允许该用户免密提权" || true
        return 0
    fi
    user_nopasswd_file_valid "$USERNAME" "$TARGET" \
        || { error "$TARGET 不属于 Quench，拒绝删除"; return 1; }
    rm -f "$TARGET" || { error "无法删除免密 sudo 配置"; return 1; }
    [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] \
        || { error "免密 sudo 配置仍然存在"; return 1; }
    audit_action "为用户 $USERNAME 关闭免密 sudo" SUCCESS
    info "$USERNAME 的 Quench 免密 sudo 权限已关闭 ✓"
    user_nopasswd_runtime_valid "$USERNAME" \
        && warn "其他 sudoers 规则仍然允许该用户免密提权，请运行权限查看确认来源" || true
}

user_sudo_permissions_show() {
    local USERNAME="$1"
    print_header "$USERNAME · sudo 权限"
    echo -e "  管理员组：${BOLD}$(user_is_admin "$USERNAME" && echo 是 || echo 否)${NC}"
    echo -e "  免密 sudo：${BOLD}$(user_nopasswd_status "$USERNAME")${NC}"
    echo ""
    if command -v sudo >/dev/null 2>&1; then
        sudo -l -U "$USERNAME" 2>&1 | sed 's/^/  /' \
            || warn "无法读取 sudo 的最终权限列表"
    else
        warn "sudo 尚未安装"
    fi
}

user_grant_admin() {
    local USERNAME="$1" GROUP
    GROUP=$(user_ensure_admin_backend) || return 1
    if command -v usermod >/dev/null 2>&1; then
        usermod -aG "$GROUP" "$USERNAME" || return 1
    elif command -v adduser >/dev/null 2>&1; then
        adduser "$USERNAME" "$GROUP" || return 1
    else
        error "系统缺少 usermod/adduser"
        return 1
    fi
    user_is_admin "$USERNAME" || { error "管理员权限验证失败"; return 1; }
    audit_action "授予用户 $USERNAME 管理员权限" SUCCESS
    info "$USERNAME 已加入 $GROUP 管理员组 ✓"
}

user_remove_from_group() {
    local USERNAME="$1" GROUP="$2"
    user_group_exists "$GROUP" || return 0
    case " $(user_groups "$USERNAME") " in *" $GROUP "*) ;; *) return 0 ;; esac
    if command -v gpasswd >/dev/null 2>&1; then gpasswd -d "$USERNAME" "$GROUP" >/dev/null 2>&1
    elif command -v delgroup >/dev/null 2>&1; then delgroup "$USERNAME" "$GROUP" >/dev/null 2>&1
    elif command -v deluser >/dev/null 2>&1; then deluser "$USERNAME" "$GROUP" >/dev/null 2>&1
    else return 1
    fi
}

user_revoke_admin() {
    local USERNAME="$1" ACTOR
    if user_nopasswd_path_exists "$USERNAME"; then
        if user_nopasswd_enabled "$USERNAME"; then
            error "请先关闭 $USERNAME 的免密 sudo，再移除管理员权限"
        else
            error "检测到未通过所有权或权限校验的免密 sudo 文件，请先人工检查"
        fi
        return 1
    fi
    if user_nopasswd_runtime_valid "$USERNAME"; then
        error "$USERNAME 仍通过其他 sudoers 规则拥有免密 sudo，请先清理该授权"
        return 1
    fi
    ACTOR=$(user_current_actor)
    [ "$USERNAME" != "$ACTOR" ] || { error "不能移除当前登录用户 $USERNAME 的管理员权限"; return 1; }
    [ "$(user_admin_count)" -gt 1 ] || { error "不能移除最后一个非 root 管理员"; return 1; }
    if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
        error "不能移除最后一个可通过 SSH 公钥接管的管理员"
        return 1
    fi
    user_remove_from_group "$USERNAME" sudo || return 1
    user_remove_from_group "$USERNAME" wheel || return 1
    user_is_admin "$USERNAME" && { error "管理员权限仍然存在，请人工检查用户组"; return 1; }
    audit_action "移除用户 $USERNAME 管理员权限" SUCCESS
    info "$USERNAME 的管理员权限已移除 ✓"
}

user_select() {
    local ALLOW_ROOT="${1:-yes}" PROMPT="${2:-选择用户}" USERNAME INDEX=1 INPUT
    local -a USERS=()
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        [ "$ALLOW_ROOT" = yes ] || [ "$USERNAME" != root ] || continue
        USERS+=("$USERNAME")
        printf '  %s[%d]%s %-18s UID %-6s %s\n' "$GREEN" "$INDEX" "$NC" "$USERNAME" "$(user_uid "$USERNAME")" "$(user_is_admin "$USERNAME" && echo 管理员 || echo 普通用户)" >&2
        INDEX=$((INDEX + 1))
    done < <(user_list_names)
    [ "${#USERS[@]}" -gt 0 ] || { warn "没有可选择的用户"; return 1; }
    read -rp "  ${PROMPT}（回车取消）: " INPUT
    [ -n "$INPUT" ] || return 1
    [[ "$INPUT" =~ ^[0-9]+$ ]] || { error "无效编号"; return 1; }
    [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#USERS[@]}" ] || { error "编号不存在"; return 1; }
    printf '%s\n' "${USERS[$((INPUT - 1))]}"
}

user_show_list() {
    print_header "用户与权限"
    local USERNAME ROLE STATE KEYS HOME_DIR LOGIN_SHELL
    printf '  %-18s %-7s %-9s %-8s %s\n' "用户" "UID" "权限" "密码" "公钥"
    menu_div
    while IFS= read -r USERNAME; do
        [ -n "$USERNAME" ] || continue
        user_is_admin "$USERNAME" && ROLE=管理员 || ROLE=普通用户
        STATE=$(user_password_state "$USERNAME")
        KEYS=$(user_key_count "$USERNAME")
        printf '  %-18s %-7s %-9s %-8s %s\n' "$USERNAME" "$(user_uid "$USERNAME")" "$ROLE" "$STATE" "$KEYS"
        HOME_DIR=$(user_home "$USERNAME"); LOGIN_SHELL=$(user_shell "$USERNAME")
        echo -e "  ${DIM}  ${HOME_DIR:-未知} · ${LOGIN_SHELL:-未知}${NC}"
    done < <(user_list_names)
    menu_div
    ui_hint "当前登录身份：$(user_current_actor)"
}

user_default_shell() {
    local CANDIDATE_SHELL
    for CANDIDATE_SHELL in /bin/bash /bin/ash /bin/sh; do
        [ -x "$CANDIDATE_SHELL" ] && { echo "$CANDIDATE_SHELL"; return; }
    done
    echo /bin/sh
}

user_create_account() {
    local USERNAME="$1" LOGIN_SHELL
    LOGIN_SHELL=$(user_default_shell)
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$LOGIN_SHELL" "$USERNAME"
    elif command -v adduser >/dev/null 2>&1; then
        if adduser --help 2>&1 | grep -q -- '--disabled-password'; then
            adduser --disabled-password --gecos "" --shell "$LOGIN_SHELL" "$USERNAME"
        else
            adduser -D -s "$LOGIN_SHELL" "$USERNAME"
        fi
    else
        error "系统缺少 useradd/adduser"
        return 1
    fi
}

user_set_password() {
    local USERNAME="$1"
    info "正在调用系统 passwd，为 $USERNAME 设置密码"
    passwd "$USERNAME" || { error "密码设置失败"; return 1; }
    audit_action "修改用户 $USERNAME 密码" SUCCESS
}

user_key_menu_for() {
    local USERNAME="$1" CHOICE AUTH_FILE
    while true; do
        AUTH_FILE=$(user_authorized_keys "$USERNAME")
        print_header "$USERNAME · SSH 公钥"
        echo -e "  路径：${DIM}${AUTH_FILE}${NC}"
        echo -e "  公钥：${BOLD}$(user_key_count "$USERNAME")${NC}"
        echo ""
        menu_pair "1" "查看公钥" "2" "添加公钥"
        menu_pair "3" "删除公钥" "4" "生成密钥对"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CHOICE
        case "$CHOICE" in
            1) show_keys "$AUTH_FILE"; ui_pause ;;
            2) add_key "$AUTH_FILE"; user_fix_ssh_permissions "$USERNAME"; audit_action "为用户 $USERNAME 添加 SSH 公钥" SUCCESS; ui_pause ;;
            3)
                if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ] \
                    && [ "$(get_config PasswordAuthentication)" = no ]; then
                    error "不能删除最后一个可接管管理员的最后一组公钥"
                else
                    delete_key "$AUTH_FILE"
                    user_fix_ssh_permissions "$USERNAME"
                    audit_action "删除用户 $USERNAME 的 SSH 公钥" SUCCESS
                fi
                ui_pause
                ;;
            4) generate_key "$AUTH_FILE"; user_fix_ssh_permissions "$USERNAME"; audit_action "为用户 $USERNAME 生成 SSH 密钥" SUCCESS; ui_pause ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

user_create() {
    local FORCE_ADMIN="${1:-no}" USERNAME TYPE SET_PASSWORD ADD_KEY
    print_header "创建用户"
    read -rp "  新用户名（回车取消）: " USERNAME
    [ -n "$USERNAME" ] || { warn "已取消"; return 1; }
    user_valid_name "$USERNAME" || { error "用户名只能使用小写字母、数字、下划线和短横线，且不能以数字开头"; return 1; }
    [ "$USERNAME" != root ] || { error "不能创建 root"; return 1; }
    ! user_exists "$USERNAME" || { error "用户 $USERNAME 已存在"; return 1; }
    if [ "$FORCE_ADMIN" = yes ]; then TYPE=2
    else
        menu_item "1" "普通用户"
        menu_item "2" "sudo/wheel 管理员"
        read -rp "$(ui_prompt '用户类型 [1-2，默认 1]: ')" TYPE
        TYPE="${TYPE:-1}"
        [[ "$TYPE" =~ ^[12]$ ]] || { error "无效用户类型"; return 1; }
    fi
    user_create_account "$USERNAME" || { error "用户创建失败"; return 1; }
    if [ "$TYPE" = 2 ] && ! user_grant_admin "$USERNAME"; then
        warn "用户已创建，但管理员授权失败"
        return 1
    fi
    read -rp "  现在设置密码？(y/N): " SET_PASSWORD
    echo "$SET_PASSWORD" | grep -qiE '^y(es)?$' && user_set_password "$USERNAME"
    read -rp "  现在添加 SSH 公钥？(Y/n): " ADD_KEY
    ADD_KEY="${ADD_KEY:-y}"
    if echo "$ADD_KEY" | grep -qiE '^y(es)?$'; then
        local AUTH_FILE
        AUTH_FILE=$(user_authorized_keys "$USERNAME")
        add_key "$AUTH_FILE"
        user_fix_ssh_permissions "$USERNAME"
    fi
    audit_action "创建用户 $USERNAME" SUCCESS
    info "用户 $USERNAME 已创建 ✓"
    [ "$TYPE" = 2 ] && warn "请在另一个终端测试：ssh $USERNAME@服务器地址，然后执行 sudo -v"
    CREATED_USER="$USERNAME"
}

user_admin_manage() {
    print_header "管理员权限"
    local USERNAME CHOICE TOKEN CONFIRM
    USERNAME=$(user_select no "选择要管理的用户") || return
    if user_is_admin "$USERNAME"; then
        echo -e "  ${BOLD}$USERNAME${NC} 当前是管理员。"
        echo -e "  免密 sudo：${BOLD}$(user_nopasswd_status "$USERNAME")${NC}"
        menu_pair "1" "开启免密 sudo" "2" "关闭免密 sudo" "$YELLOW" "$GREEN"
        menu_pair "3" "查看实际 sudo 权限" "4" "移除管理员权限" "$CYAN" "$YELLOW"
        menu_item "0" "取消" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-4]: ')" CHOICE
        case "$CHOICE" in
            1)
                warn "免密 sudo 允许 $USERNAME 无需密码执行任意 root 命令"
                read -rp "  输入用户名 $USERNAME 确认开启: " TOKEN
                if [ "$TOKEN" = "$USERNAME" ]; then
                    user_nopasswd_enable "$USERNAME"
                else
                    warn "确认不匹配，已取消"
                fi
                ;;
            2)
                read -rp "  关闭 $USERNAME 的 Quench 免密 sudo？(Y/n): " CONFIRM
                CONFIRM="${CONFIRM:-y}"
                echo "$CONFIRM" | grep -qiE '^y(es)?$' && user_nopasswd_disable "$USERNAME"
                ;;
            3) user_sudo_permissions_show "$USERNAME" ;;
            4) user_revoke_admin "$USERNAME" ;;
        esac
    else
        echo -e "  ${BOLD}$USERNAME${NC} 当前是普通用户。"
        menu_item "1" "授予 sudo/wheel 管理员权限"
        menu_item "2" "查看实际 sudo 权限" "$CYAN"
        menu_item "0" "取消" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CHOICE
        case "$CHOICE" in
            1) user_grant_admin "$USERNAME" ;;
            2) user_sudo_permissions_show "$USERNAME" ;;
        esac
    fi
}

user_password_manage() {
    print_header "密码与账户锁定"
    local USERNAME CHOICE TOKEN ACTOR
    USERNAME=$(user_select yes "选择用户") || return
    ACTOR=$(user_current_actor)
    echo -e "  当前状态：${BOLD}$(user_password_state "$USERNAME")${NC}"
    menu_item "1" "设置/修改密码"
    menu_item "2" "锁定密码登录" "$YELLOW"
    menu_item "3" "解除密码锁定"
    menu_item "0" "取消" "$RED"
    read -rp "$(ui_prompt '选择操作 [0-3]: ')" CHOICE
    case "$CHOICE" in
        1) user_set_password "$USERNAME" ;;
        2)
            [ "$USERNAME" != "$ACTOR" ] || { error "不能锁定当前登录用户 $USERNAME"; return 1; }
            if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
                error "不能锁定最后一个可通过 SSH 公钥接管的管理员"
                return 1
            fi
            read -rp "  输入用户名 $USERNAME 确认锁定: " TOKEN
            [ "$TOKEN" = "$USERNAME" ] || { warn "确认不匹配，已取消"; return; }
            passwd -l "$USERNAME" && audit_action "锁定用户 $USERNAME" SUCCESS && info "$USERNAME 已锁定 ✓"
            ;;
        3) passwd -u "$USERNAME" && audit_action "解锁用户 $USERNAME" SUCCESS && info "$USERNAME 已解锁 ✓" ;;
    esac
}

user_delete() {
    print_header "删除用户"
    local USERNAME USER_ID ACTOR TOKEN REMOVE_HOME
    USERNAME=$(user_select no "选择要删除的用户") || return
    USER_ID=$(user_uid "$USERNAME"); ACTOR=$(user_current_actor)
    [ "$USERNAME" != "$ACTOR" ] || { error "不能删除当前登录用户 $USERNAME"; return 1; }
    [ "$USER_ID" -ge "$(user_uid_min)" ] || { error "拒绝删除系统账户 $USERNAME"; return 1; }
    if user_is_admin "$USERNAME" && [ "$(user_admin_count)" -le 1 ]; then
        error "不能删除最后一个非 root 管理员"
        return 1
    fi
    if user_ready_admin "$USERNAME" && [ "$(user_ready_admin_count)" -le 1 ]; then
        error "不能删除最后一个可通过 SSH 公钥接管的管理员"
        return 1
    fi
    pgrep -u "$USERNAME" >/dev/null 2>&1 && warn "该用户仍有运行中的进程，删除可能失败"
    read -rp "  输入用户名 $USERNAME 确认删除: " TOKEN
    [ "$TOKEN" = "$USERNAME" ] || { warn "确认不匹配，已取消"; return; }
    read -rp "  同时删除家目录 $(user_home "$USERNAME")？(y/N): " REMOVE_HOME
    if command -v userdel >/dev/null 2>&1; then
        if echo "$REMOVE_HOME" | grep -qiE '^y(es)?$'; then userdel -r "$USERNAME"; else userdel "$USERNAME"; fi
    elif command -v deluser >/dev/null 2>&1; then
        if echo "$REMOVE_HOME" | grep -qiE '^y(es)?$'; then deluser --remove-home "$USERNAME"; else deluser "$USERNAME"; fi
    else
        error "系统缺少 userdel/deluser"
        return 1
    fi
    if user_nopasswd_path_exists "$USERNAME"; then
        if user_nopasswd_enabled "$USERNAME"; then
            user_nopasswd_disable "$USERNAME" || {
                error "用户已删除，但其免密 sudo 文件清理失败，请立即人工检查"
                return 1
            }
        else
            warn "用户已删除，但同名 sudoers 文件不属于 Quench，已保留并需要人工检查"
        fi
    fi
    audit_action "删除用户 $USERNAME" SUCCESS
    info "用户 $USERNAME 已删除 ✓"
}

user_ssh_keys_manage() {
    print_header "用户 SSH 公钥"
    local USERNAME
    USERNAME=$(user_select yes "选择用户") || return
    user_key_menu_for "$USERNAME"
}

user_select_ready_admin() {
    local USERNAME INDEX=1 INPUT
    local -a USERS=()
    while IFS= read -r USERNAME; do
        user_ready_admin "$USERNAME" || continue
        USERS+=("$USERNAME")
        printf '  %s[%d]%s %s · %s 个公钥\n' "$GREEN" "$INDEX" "$NC" "$USERNAME" "$(user_key_count "$USERNAME")" >&2
        INDEX=$((INDEX + 1))
    done < <(user_list_names)
    [ "${#USERS[@]}" -gt 0 ] || { error "没有同时满足非 root、管理员、有公钥这三个条件的用户"; return 1; }
    read -rp "  选择已测试登录的管理员（回车取消）: " INPUT
    [[ "$INPUT" =~ ^[0-9]+$ ]] && [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "${#USERS[@]}" ] || return 1
    printf '%s\n' "${USERS[$((INPUT - 1))]}"
}

user_recommended_wizard() {
    print_header "推荐安全配置向导"
    local ADMIN="" CONFIRM
    echo "  1. 创建 sudo/wheel 管理员"
    echo "  2. 为管理员安装 SSH 公钥"
    echo "  3. 在另一个终端验证登录和 sudo"
    echo "  4. 可选迁移 SSH 端口"
    echo "  5. 禁止 root SSH 和密码认证"
    echo ""
    read -rp "  开始向导？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    CREATED_USER=""
    user_create yes || return
    ADMIN="$CREATED_USER"
    user_ready_admin "$ADMIN" || { warn "$ADMIN 尚未配置可用公钥，向导停止以避免锁死"; return; }
    warn "请保持当前窗口，并在另一个终端以 $ADMIN 登录后执行 sudo -v"
    read -rp "  测试成功后输入管理员用户名 $ADMIN: " CONFIRM
    [ "$CONFIRM" = "$ADMIN" ] || { warn "未确认，未修改 SSH 策略"; return; }
    read -rp "  是否迁移 SSH 端口？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' && change_port
    ssh_apply_recommended_policy "$ADMIN"
}
# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════

f2b_config_file() {
    printf '%s\n' "${F2B_JAIL_LOCAL:-/etc/fail2ban/jail.d/zz-vps-quench.local}"
}

f2b_validate_config() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null 2>&1
    else
        fail2ban-server -t >/dev/null 2>&1
    fi
}

f2b_ports_valid() {
    local INPUT="$1" ITEM
    local -a ITEMS=()
    [ -n "$INPUT" ] || return 1
    IFS=',' read -r -a ITEMS <<< "$INPUT"
    for ITEM in "${ITEMS[@]}"; do
        [[ "$ITEM" =~ ^[0-9]+$ ]] && [ "$ITEM" -ge 1 ] && [ "$ITEM" -le 65535 ] || return 1
    done
}

f2b_get_section_param() {
    local SECTION="$1" KEY="$2" FILE="${3:-$(f2b_config_file)}"
    awk -v section="$SECTION" -v key="$KEY" '
        /^\[[^]]+\][[:space:]]*$/ {
            current=$0
            gsub(/^[[:space:]]*\[/, "", current)
            gsub(/\][[:space:]]*$/, "", current)
            in_section=(current == section)
            next
        }
        in_section {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" key "[[:space:]]*=") {
                sub("^" key "[[:space:]]*=[[:space:]]*", "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                value=line
            }
        }
        END {if (value != "") print value}
    ' "$FILE" 2>/dev/null
}

f2b_render_managed_config() {
    local DEST="$1" BACKEND="$2" PORTS="$3" ALLOW_IPV6_LINE="$4"
    {
        echo "# Managed by Quench. Keep unrelated jails in jail.local or separate jail.d files."
        if [ -n "$ALLOW_IPV6_LINE" ]; then
            echo "[DEFAULT]"
            echo "$ALLOW_IPV6_LINE"
            echo ""
        fi
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ${PORTS}"
        echo "mode     = aggressive"
        echo "backend  = ${BACKEND}"
        echo "bantime  = 1h"
        echo "findtime = 10m"
        echo "maxretry = 5"
        echo "bantime.increment = true"
        echo "bantime.maxtime = 1w"
        if [ "$BACKEND" = systemd ]; then
            echo "journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd"
        else
            echo "logpath  = %(sshd_log)s"
        fi
    } > "$DEST"
}

f2b_backend_detect() {
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
        echo systemd
    else
        echo auto
    fi
}

f2b_allow_ipv6_line() {
    local MAJOR
    MAJOR=$(fail2ban-client version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ "${MAJOR:-0}" -ge 1 ] && echo 'allowipv6 = auto'
}

f2b_ensure_managed_config() {
    local PORTS="$1" TARGET STAGED BACKEND ALLOW_IPV6_LINE=""
    TARGET=$(f2b_config_file)
    [ -f "$TARGET" ] && return 0
    mkdir -p "$(dirname "$TARGET")" || return 1
    STAGED=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    BACKEND=$(f2b_backend_detect)
    ALLOW_IPV6_LINE=$(f2b_allow_ipv6_line || true)
    f2b_render_managed_config "$STAGED" "$BACKEND" "$PORTS" "$ALLOW_IPV6_LINE" \
        || { rm -f "$STAGED"; return 1; }
    info "正在创建 Quench 托管的 sshd drop-in"
    chmod 0644 "$STAGED"
    mv "$STAGED" "$TARGET" || { rm -f "$STAGED"; return 1; }
    if ! f2b_validate_config; then
        rm -f "$TARGET"
        error "Fail2ban 配置创建失败，已撤销新 drop-in"
        return 1
    fi
}

f2b_managed_ports_match() {
    local EXPECTED="$1" ACTUAL
    ACTUAL=$(f2b_get_section_param sshd port "$(f2b_config_file)" | tr -d '[:space:]')
    [ "$ACTUAL" = "$(printf '%s' "$EXPECTED" | tr -d '[:space:]')" ]
}

f2b_runtime_healthy() {
    f2b_ping && fail2ban-client status sshd >/dev/null 2>&1
}

# 把 Fail2ban 时间格式转为秒（支持 3600、1h、1d、-1 等）。
f2b_to_seconds() {
    local VAL="$1" NUM UNIT
    if echo "$VAL" | grep -qE '^-?[0-9]+$'; then
        echo "$VAL"
        return
    fi
    NUM=$(echo "$VAL" | grep -oE '[0-9]+' | head -1)
    UNIT=$(echo "$VAL" | grep -oE '[smhdw]' | tail -1)
    case "$UNIT" in
        s) echo "$NUM" ;;
        m) echo $((NUM * 60)) ;;
        h) echo $((NUM * 3600)) ;;
        d) echo $((NUM * 86400)) ;;
        w) echo $((NUM * 604800)) ;;
        *) echo "${NUM:-0}" ;;
    esac
}

f2b_seconds_to_human() {
    local SEC="$1"
    [ "$SEC" = -1 ] && { echo "永久"; return; }
    [ "$SEC" -ge 86400 ] && { echo "$((SEC / 86400))天"; return; }
    [ "$SEC" -ge 3600 ] && { echo "$((SEC / 3600))小时"; return; }
    [ "$SEC" -ge 60 ] && { echo "$((SEC / 60))分钟"; return; }
    echo "${SEC}秒"
}

f2b_ping() {
    local SOCK
    for SOCK in /run/fail2ban/fail2ban.sock /var/run/fail2ban/fail2ban.sock /tmp/fail2ban.sock; do
        [ -S "$SOCK" ] && fail2ban-client -s "$SOCK" ping >/dev/null 2>&1 && return 0
    done
    fail2ban-client ping >/dev/null 2>&1
}

f2b_status() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo not_installed
    elif f2b_ping || svc_is_active fail2ban 2>/dev/null; then
        echo running
    else
        echo stopped
    fi
}

f2b_install() {
    print_header "安装 Fail2ban"
    info "正在安装 fail2ban..."
    if ! pkg_install fail2ban; then
        error "安装失败，请检查网络或手动安装 fail2ban"
        return 1
    fi

    local BACKEND=auto
    if python3 -c "import systemd.journal" >/dev/null 2>&1; then
        BACKEND=systemd
        info "检测到 python3-systemd，使用 systemd backend ✓"
    elif pkg_install python3-systemd >/dev/null 2>&1 \
        && python3 -c "import systemd.journal" >/dev/null 2>&1; then
        BACKEND=systemd
        info "python3-systemd 安装成功，使用 systemd backend ✓"
    else
        warn "python3-systemd 不可用，使用 auto backend"
        if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
            info "安装 rsyslog 以生成 SSH 认证日志..."
            pkg_install rsyslog >/dev/null 2>&1 || true
            svc_enable rsyslog >/dev/null 2>&1 || true
            svc_start rsyslog >/dev/null 2>&1 || true
        fi
    fi

    local F2B_MAJOR ALLOW_IPV6_LINE="" PORTS TARGET STAGED BACKUP EXISTED=no WAS_RUNNING i
    F2B_MAJOR=$(fail2ban-client version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ "${F2B_MAJOR:-0}" -ge 1 ] && ALLOW_IPV6_LINE="allowipv6 = auto"
    PORTS=$(ssh_effective_ports_csv)
    f2b_ports_valid "$PORTS" || { error "无法确定有效的 SSH 端口"; return 1; }

    TARGET=$(f2b_config_file)
    mkdir -p "$(dirname "$TARGET")" || return 1
    STAGED=$(mktemp "${TARGET}.tmp.XXXXXX") || return 1
    BACKUP=$(quench_mktemp) || { rm -f "$STAGED"; return 1; }
    if [ -f "$TARGET" ]; then
        cp "$TARGET" "$BACKUP" || { rm -f "$STAGED" "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    WAS_RUNNING=$(f2b_status)
    f2b_render_managed_config "$STAGED" "$BACKEND" "$PORTS" "$ALLOW_IPV6_LINE" \
        || { rm -f "$STAGED" "$BACKUP"; return 1; }
    chmod 0644 "$STAGED"
    mv "$STAGED" "$TARGET" || { rm -f "$STAGED" "$BACKUP"; return 1; }
    info "已生成 $(basename "$TARGET")（端口=${PORTS}, backend=${BACKEND}, mode=aggressive）✓"

    info "验证 Fail2ban 配置..."
    if ! f2b_validate_config; then
        restore_backup_or_remove "$BACKUP" "$TARGET" "$EXISTED" || return 1
        error "Fail2ban 配置验证失败，已恢复原配置"
        fail2ban-client -t 2>&1 | sed 's/^/  /' || true
        return 1
    fi

    svc_enable fail2ban >/dev/null 2>&1 || true
    if [ "$WAS_RUNNING" = running ]; then
        restart_fail2ban >/dev/null 2>&1 || true
    else
        rm -f /run/fail2ban/fail2ban.sock /var/run/fail2ban/fail2ban.sock 2>/dev/null || true
        start_fail2ban >/dev/null 2>&1 || true
    fi
    i=0
    while [ "$i" -lt 10 ]; do
        f2b_ping && break
        sleep 1
        i=$((i + 1))
    done
    if ! f2b_ping || ! fail2ban-client status sshd >/dev/null 2>&1; then
        restore_backup_or_remove "$BACKUP" "$TARGET" "$EXISTED" || return 1
        if [ "$WAS_RUNNING" = running ]; then
            restart_fail2ban >/dev/null 2>&1 || true
        else
            stop_fail2ban >/dev/null 2>&1 || true
        fi
        error "Fail2ban 未能使用新配置启动，已恢复原配置"
        command -v journalctl >/dev/null 2>&1 && journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || true
        return 1
    fi
    rm -f "$BACKUP"
    info "Fail2ban 安装并启动成功 ✓"
}

f2b_write_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE="${F2B_JAIL_LOCAL:-$(f2b_config_file)}" TMP
    mkdir -p "$(dirname "$JAIL_FILE")" || return 1
    TMP=$(mktemp "${JAIL_FILE}.tmp.XXXXXX") || return 1
    [ -f "$JAIL_FILE" ] || : > "$JAIL_FILE"
    awk -v section="$SECTION" -v key="$KEY" -v value="$VAL" '
        function section_line(name) { return "[" name "]" }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_target && !written) print key " = " value
            current=$0
            gsub(/[[:space:]]+$/, "", current)
            in_target=(current == section_line(section))
            if (in_target) found_section=1
            written=0
            print
            next
        }
        in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!written) print key " = " value
            written=1
            next
        }
        {print}
        END {
            if (in_target && !written) print key " = " value
            if (!found_section) {
                if (NR > 0) print ""
                print section_line(section)
                print key " = " value
            }
        }
    ' "$JAIL_FILE" > "$TMP" || { rm -f "$TMP"; return 1; }
    mv "$TMP" "$JAIL_FILE" || { rm -f "$TMP"; return 1; }
}

f2b_set_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE="${F2B_JAIL_LOCAL:-$(f2b_config_file)}" BACKUP EXISTED=no
    BACKUP=$(quench_mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    if ! f2b_write_section_param "$SECTION" "$KEY" "$VAL" || ! f2b_validate_config; then
        restore_backup_or_remove "$BACKUP" "$JAIL_FILE" "$EXISTED" || return 1
        error "Fail2ban 配置验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
}

# 参数只作用于 Quench 管理的 sshd jail，不改变用户的其他 jail。
f2b_set_param() {
    local KEY="$1" VAL="$2"
    f2b_set_section_param sshd "$KEY" "$VAL" || return 1
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

f2b_set_param_jail() {
    local KEY="$1" VAL="$2" JAIL_FILE BACKUP EXISTED=no
    JAIL_FILE=$(f2b_config_file)
    BACKUP=$(quench_mktemp) || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    if ! f2b_write_section_param sshd enabled true \
        || ! f2b_write_section_param sshd "$KEY" "$VAL" \
        || ! f2b_validate_config; then
        restore_backup_or_remove "$BACKUP" "$JAIL_FILE" "$EXISTED" || return 1
        error "Fail2ban 配置验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

f2b_config_params() {
    print_header "Fail2ban SSH 防护参数"
    local JAIL_FILE CUR_BAN CUR_FIND CUR_MAX CUR_PORT BAN_SEC FIND_SEC CH VAL PRESET
    local APPLY_BAN="" APPLY_FIND="" APPLY_MAX="" APPLY_PORT="" BACKUP WAS_RUNNING
    JAIL_FILE=$(f2b_config_file)
    CUR_BAN=$(f2b_get_section_param sshd bantime "$JAIL_FILE"); CUR_BAN="${CUR_BAN:-1h}"
    CUR_FIND=$(f2b_get_section_param sshd findtime "$JAIL_FILE"); CUR_FIND="${CUR_FIND:-10m}"
    CUR_MAX=$(f2b_get_section_param sshd maxretry "$JAIL_FILE"); CUR_MAX="${CUR_MAX:-5}"
    CUR_PORT=$(f2b_get_section_param sshd port "$JAIL_FILE"); CUR_PORT="${CUR_PORT:-$(ssh_effective_ports_csv)}"
    BAN_SEC=$(f2b_to_seconds "$CUR_BAN")
    FIND_SEC=$(f2b_to_seconds "$CUR_FIND")
    echo -e "  封禁时长  : ${BOLD}${CUR_BAN}${NC}  （$(f2b_seconds_to_human "$BAN_SEC")）"
    echo -e "  时间窗口  : ${BOLD}${CUR_FIND}${NC}  （$(f2b_seconds_to_human "$FIND_SEC")）"
    echo -e "  最大重试  : ${BOLD}${CUR_MAX}${NC} 次"
    echo -e "  SSH 端口  : ${BOLD}${CUR_PORT}${NC}"
    echo ""
    menu_div
    menu_pair "1" "封禁时长" "2" "时间窗口"
    menu_pair "3" "最大重试次数" "4" "SSH 端口"
    menu_item "5" "快速预设"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    read -rp "$(ui_prompt '选择参数 [0-5]: ')" CH
    case "$CH" in
        1)
            read -rp "  新 bantime（秒，-1=永久）: " VAL
            echo "$VAL" | grep -qE '^-?[0-9]+$' || { error "无效数值"; return; }
            APPLY_BAN="$VAL"
            ;;
        2)
            read -rp "  新 findtime（秒）: " VAL
            echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
            APPLY_FIND="$VAL"
            ;;
        3)
            read -rp "  新 maxretry（次）: " VAL
            echo "$VAL" | grep -qE '^[1-9][0-9]*$' || { error "无效数值"; return; }
            APPLY_MAX="$VAL"
            ;;
        4)
            VAL=$(ssh_effective_ports_csv)
            echo -e "  当前 sshd 端口：${BOLD}${VAL}${NC}"
            read -rp "  输入逗号分隔的数字端口（回车使用当前值）: " CUR_PORT
            CUR_PORT="${CUR_PORT:-$VAL}"
            f2b_ports_valid "$CUR_PORT" || { error "端口必须为 1-65535 的数字，多个用逗号分隔"; return; }
            APPLY_PORT="$CUR_PORT"
            ;;
        5)
            menu_item "1" "严格 · 1天 / 10分钟 / 3次"
            menu_item "2" "标准 · 1小时 / 10分钟 / 5次"
            menu_item "3" "宽松 · 30分钟 / 5分钟 / 10次"
            menu_item "4" "永久 · 永久 / 10分钟 / 3次" "$YELLOW"
            read -rp "$(ui_prompt '选择预设 [1-4]: ')" PRESET
            case "$PRESET" in
                1) VAL="86400 600 3" ;;
                2) VAL="3600 600 5" ;;
                3) VAL="1800 300 10" ;;
                4) VAL="-1 600 3" ;;
                *) warn "无效选项"; return ;;
            esac
            read -r APPLY_BAN APPLY_FIND APPLY_MAX <<< "$VAL"
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    [ -f "$JAIL_FILE" ] || { error "Quench Fail2ban 配置不存在，请先安装/修复"; return 1; }
    BACKUP=$(quench_mktemp) || return 1
    cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    WAS_RUNNING=$(f2b_status)
    if { [ -z "$APPLY_BAN" ] || f2b_set_param bantime "$APPLY_BAN"; } \
        && { [ -z "$APPLY_FIND" ] || f2b_set_param findtime "$APPLY_FIND"; } \
        && { [ -z "$APPLY_MAX" ] || f2b_set_param maxretry "$APPLY_MAX"; } \
        && { [ -z "$APPLY_PORT" ] || f2b_set_param_jail port "$APPLY_PORT"; }; then
        :
    else
        cp "$BACKUP" "$JAIL_FILE"
        rm -f "$BACKUP"
        error "参数写入失败，已恢复修改前配置"
        return 1
    fi

    if [ "$WAS_RUNNING" != running ]; then
        rm -f "$BACKUP"
        info "配置已保存；Fail2ban 当前未运行，因此未自动启动"
    elif restart_fail2ban && f2b_ping; then
        rm -f "$BACKUP"
        info "Fail2ban 已重启 ✓"
    else
        cp "$BACKUP" "$JAIL_FILE"
        restart_fail2ban >/dev/null 2>&1 || true
        rm -f "$BACKUP"
        error "Fail2ban 无法使用新参数运行，已恢复修改前配置"
        return 1
    fi
}

f2b_edit_config() {
    print_header "编辑 Quench Fail2ban 配置"
    local JAIL_FILE BACKUP RESTART
    JAIL_FILE=$(f2b_config_file)
    mkdir -p "$(dirname "$JAIL_FILE")"
    [ -f "$JAIL_FILE" ] || { warn "请先执行 Fail2ban 安装/修复"; return 1; }
    BACKUP=$(quench_mktemp) || return 1
    cp "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    warn "即将编辑 ${JAIL_FILE}；保存后会先验证，失败自动恢复"
    ui_continue
    open_editor "$JAIL_FILE"
    if ! f2b_validate_config; then
        cp "$BACKUP" "$JAIL_FILE"
        rm -f "$BACKUP"
        error "配置验证失败，已恢复编辑前版本"
        return 1
    fi
    read -rp "  验证通过，是否重启 Fail2ban？(Y/n): " RESTART
    RESTART="${RESTART:-y}"
    if echo "$RESTART" | grep -qiE '^y(es)?$'; then
        if ! restart_fail2ban || ! f2b_ping; then
            cp "$BACKUP" "$JAIL_FILE"
            restart_fail2ban >/dev/null 2>&1 || true
            rm -f "$BACKUP"
            error "新配置无法启动服务，已恢复原配置"
            return 1
        fi
        info "Fail2ban 已重启 ✓"
    fi
    rm -f "$BACKUP"
}

f2b_uninstall() {
    print_header "卸载 Fail2ban"
    local CONFIRM PURGE TARGET
    TARGET=$(f2b_config_file)
    warn "卸载会停止动态封禁；默认保留所有配置，方便恢复"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    stop_fail2ban >/dev/null 2>&1 || true
    svc_disable fail2ban >/dev/null 2>&1 || true
    pkg_remove fail2ban || { error "卸载失败"; return 1; }
    info "Fail2ban 已卸载，配置已保留 ✓"
    if [ -f "$TARGET" ]; then
        read -rp "  如需删除 Quench 配置，输入 PURGE（其他 Fail2ban 配置不会删除）: " PURGE
        if [ "$PURGE" = PURGE ]; then
            rm -f "$TARGET"
            info "已删除 Quench 托管的 Fail2ban drop-in"
        fi
    fi
}

f2b_jail_name() {
    local JAIL
    JAIL=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 -E '^sshd?$' || true)
    printf '%s\n' "${JAIL:-sshd}"
}

f2b_banned_ips() {
    local JAIL="$1"
    fail2ban-client status "$JAIL" 2>/dev/null \
        | sed -n 's/.*Banned IP list:[[:space:]]*//p'
}

f2b_banned_list() {
    local JAIL="${1:-sshd}" RAW IP i=1
    print_header "封禁 IP 列表 — $JAIL"
    RAW=$(f2b_banned_ips "$JAIL")
    [ -n "$RAW" ] || { echo -e "  ${GREEN}当前没有封禁的 IP${NC}"; return; }
    for IP in $RAW; do
        echo -e "  ${RED}[$i]${NC} $IP"
        i=$((i + 1))
    done
    echo -e "\n  ${DIM}共 $((i - 1)) 个封禁 IP${NC}"
}

f2b_unban() {
    local JAIL="${1:-sshd}" RAW UNBAN_IP
    while true; do
        print_header "手动解封 IP — $JAIL"
        RAW=$(f2b_banned_ips "$JAIL")
        [ -n "$RAW" ] || { echo -e "  ${GREEN}当前没有封禁的 IP${NC}"; return; }
        for UNBAN_IP in $RAW; do
            printf '  %s\n' "$UNBAN_IP"
        done
        read -rp "  输入要解封的 IP（回车返回）: " UNBAN_IP
        [ -n "$UNBAN_IP" ] || return
        fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" >/dev/null 2>&1 \
            && info "IP $UNBAN_IP 已解封 ✓" || error "解封失败"
        sleep 1
    done
}

f2b_logs() {
    print_header "Fail2ban 实时日志"
    echo -e "  ${DIM}显示最近 30 条，按 Ctrl+C 退出实时模式${NC}"
    if [ -f /var/log/fail2ban.log ]; then
        tail -n 30 /var/log/fail2ban.log
        read -r -p "  按 Enter 开始实时跟踪..." _
        tail -f /var/log/fail2ban.log
    elif command -v journalctl >/dev/null 2>&1; then
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null
        read -r -p "  按 Enter 开始实时跟踪..." _
        journalctl -u fail2ban -f
    else
        warn "未找到 Fail2ban 日志"
    fi
}

fail2ban_menu() {
    while true; do
        local F2B_ST F2B_COLOR BANNED_COUNT TOTAL_FAIL JAIL_NAME JAIL_FILE
        local CUR_BAN CUR_FIND CUR_MAX CUR_PORT BAN_SEC FIND_SEC CHOICE
        F2B_ST=$(f2b_status)
        if [ "$F2B_ST" = not_installed ]; then
            print_header "Fail2ban 管理"
            warn "Fail2ban 未安装"
            menu_item "1" "立即安装 Fail2ban"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            read -rp "$(ui_prompt '选择操作 [0-1]: ')" CHOICE
            case "$CHOICE" in
                1) f2b_install; ui_continue ;;
                0) return ;;
                00) safe_clear; exit 0 ;;
                *) warn "无效选项" ;;
            esac
            continue
        fi

        [ "$F2B_ST" = running ] && F2B_COLOR="$GREEN" || F2B_COLOR="$RED"
        JAIL_NAME=$(f2b_jail_name)
        if [ "$F2B_ST" = running ]; then
            BANNED_COUNT=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | sed -n 's/.*Currently banned:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            TOTAL_FAIL=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | sed -n 's/.*Total failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
            BANNED_COUNT="${BANNED_COUNT:-0}"; TOTAL_FAIL="${TOTAL_FAIL:-0}"
        else
            BANNED_COUNT="-"; TOTAL_FAIL="-"
        fi
        JAIL_FILE=$(f2b_config_file)
        CUR_BAN=$(f2b_get_section_param sshd bantime "$JAIL_FILE"); CUR_BAN="${CUR_BAN:-1h}"
        CUR_FIND=$(f2b_get_section_param sshd findtime "$JAIL_FILE"); CUR_FIND="${CUR_FIND:-10m}"
        CUR_MAX=$(f2b_get_section_param sshd maxretry "$JAIL_FILE"); CUR_MAX="${CUR_MAX:-5}"
        CUR_PORT=$(f2b_get_section_param sshd port "$JAIL_FILE"); CUR_PORT="${CUR_PORT:-未托管}"
        BAN_SEC=$(f2b_to_seconds "$CUR_BAN"); FIND_SEC=$(f2b_to_seconds "$CUR_FIND")

        safe_clear
        echo ""
        box_top
        app_header_line
        echo -e "  ${BOLD}${CYAN}Fail2ban 管理${NC}"
        box_sep
        box_line "  服务: ${F2B_ST}  jail: ${JAIL_NAME}" "  服务: ${F2B_COLOR}${BOLD}${F2B_ST}${NC}  jail: ${BOLD}${JAIL_NAME}${NC}"
        box_line "  封禁IP: ${BANNED_COUNT}  总失败: ${TOTAL_FAIL}  端口: ${CUR_PORT}" "  封禁IP: ${RED}${BOLD}${BANNED_COUNT}${NC}  总失败: ${YELLOW}${BOLD}${TOTAL_FAIL}${NC}  端口: ${BOLD}${CUR_PORT}${NC}"
        box_line "  封禁: $(f2b_seconds_to_human "$BAN_SEC")  窗口: $(f2b_seconds_to_human "$FIND_SEC")  重试: ${CUR_MAX}次" "  封禁: ${BOLD}$(f2b_seconds_to_human "$BAN_SEC")${NC}  窗口: ${BOLD}$(f2b_seconds_to_human "$FIND_SEC")${NC}  重试: ${BOLD}${CUR_MAX}${NC}次"
        box_sep
        menu_pair "1" "查看封禁 IP" "2" "手动解封"
        menu_pair "3" "实时日志" "4" "SSH 防护参数"
        menu_pair "5" "编辑 Quench 配置" "6" "卸载 Fail2ban" "$GREEN" "$YELLOW"
        menu_item "u" "安装 / 修复 / 更新 Fail2ban" "$CYAN"
        [ "$F2B_ST" = running ] && menu_item "7" "停止服务" "$YELLOW" || menu_item "7" "启动服务"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        box_bot
        read -rp "$(ui_prompt '选择操作 [0-7 / u]: ')" CHOICE
        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            u|U) f2b_install ;;
            7)
                if [ "$F2B_ST" = running ]; then
                    stop_fail2ban && info "Fail2ban 已停止" || error "停止失败"
                else
                    f2b_validate_config && start_fail2ban && f2b_ping \
                        && info "Fail2ban 已启动 ✓" || error "启动失败，请检查配置和日志"
                fi
                ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        [ "$CHOICE" != 0 ] && ui_pause
    done
}
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
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable tc-fq --quiet >/dev/null 2>&1 \
            && systemctl restart tc-fq >/dev/null 2>&1 || {
                error "tc 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" openrc || return 1
        rc-update add tc-fq default >/dev/null 2>&1 \
            && rc-service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" sysv || return 1
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
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable initcwnd --quiet >/dev/null 2>&1 \
            && systemctl restart initcwnd >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" openrc || return 1
        rc-update add initcwnd default >/dev/null 2>&1 \
            && rc-service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" sysv || return 1
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
# ══════════════════════════════════════════════════════════
#  防火墙模块
# ══════════════════════════════════════════════════════════

fw_running() {
    local TYPE="$1"
    case "$TYPE" in
        ufw) LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active' && echo active || echo inactive ;;
        firewalld) svc_is_active firewalld && echo active || echo inactive ;;
        conflict) echo conflict ;;
        *) echo none ;;
    esac
}

# 优先返回正在运行的后端；两者同时存在则显式报告冲突。
fw_detect() {
    local HAS_UFW=false HAS_FWD=false ACTIVE_UFW=false ACTIVE_FWD=false
    command -v ufw >/dev/null 2>&1 && HAS_UFW=true
    command -v firewall-cmd >/dev/null 2>&1 && HAS_FWD=true
    [ "$HAS_UFW" = true ] && [ "$(fw_running ufw)" = active ] && ACTIVE_UFW=true
    [ "$HAS_FWD" = true ] && [ "$(fw_running firewalld)" = active ] && ACTIVE_FWD=true
    if { [ "$ACTIVE_UFW" = true ] && [ "$ACTIVE_FWD" = true ]; } \
        || { [ "$HAS_UFW" = true ] && [ "$HAS_FWD" = true ] && [ "$ACTIVE_UFW" = false ] && [ "$ACTIVE_FWD" = false ]; }; then
        echo conflict
    elif [ "$ACTIVE_UFW" = true ]; then
        echo ufw
    elif [ "$ACTIVE_FWD" = true ]; then
        echo firewalld
    elif [ "$HAS_UFW" = true ]; then
        echo ufw
    elif [ "$HAS_FWD" = true ]; then
        echo firewalld
    else
        echo none
    fi
}

fw_port_spec_normalize() {
    local INPUT="$1" TYPE="$2" BASE PROTO START END SEP OUT_SEP
    [[ "$INPUT" =~ ^[0-9]+([:-][0-9]+)?(/(tcp|udp))?$ ]] || return 1
    if [[ "$INPUT" == */* ]]; then
        PROTO="${INPUT##*/}"; BASE="${INPUT%/*}"
    else
        PROTO=tcp; BASE="$INPUT"
    fi
    if [[ "$BASE" == *:* ]]; then SEP=:; elif [[ "$BASE" == *-* ]]; then SEP=-; else SEP=""; fi
    if [ -n "$SEP" ]; then
        START="${BASE%%"$SEP"*}"; END="${BASE##*"$SEP"}"
    else
        START="$BASE"; END="$BASE"
    fi
    [ "$START" -ge 1 ] && [ "$START" -le 65535 ] \
        && [ "$END" -ge "$START" ] && [ "$END" -le 65535 ] || return 1
    [ "$TYPE" = ufw ] && OUT_SEP=: || OUT_SEP=-
    if [ "$START" = "$END" ]; then
        printf '%s/%s\n' "$START" "$PROTO"
    else
        printf '%s%s%s/%s\n' "$START" "$OUT_SEP" "$END" "$PROTO"
    fi
}

fw_ipv4_valid() {
    local VALUE="${1%%/*}" PREFIX="" OCTET
    local -a OCTETS=()
    [[ "$1" == */* ]] && PREFIX="${1##*/}"
    [[ "$VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a OCTETS <<< "$VALUE"
    for OCTET in "${OCTETS[@]}"; do
        [[ "$OCTET" =~ ^[0-9]+$ ]] && [ "$OCTET" -le 255 ] || return 1
    done
    [ -z "$PREFIX" ] || { [[ "$PREFIX" =~ ^[0-9]+$ ]] && [ "$PREFIX" -le 32 ]; }
}

fw_ip_family() {
    local VALUE="$1" PREFIX
    if [[ "$VALUE" == *:* ]]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$VALUE" >/dev/null 2>&1 || return 1
        else
            [[ "$VALUE" =~ ^[0-9A-Fa-f:]+(/[0-9]+)?$ ]] || return 1
            if [[ "$VALUE" == */* ]]; then
                PREFIX="${VALUE##*/}"
                [ "$PREFIX" -le 128 ] || return 1
            fi
        fi
        echo ipv6
    elif fw_ipv4_valid "$VALUE"; then
        echo ipv4
    else
        return 1
    fi
}

fw_firewalld_zone() {
    local ZONE="" IFACE=""
    if command -v firewall-cmd >/dev/null 2>&1 && svc_is_active firewalld; then
        IFACE=$(default_iface 2>/dev/null || true)
        [ -n "$IFACE" ] && ZONE=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>/dev/null || true)
    fi
    if [ -z "$ZONE" ] && command -v firewall-cmd >/dev/null 2>&1; then
        ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    fi
    [ -z "$ZONE" ] && [ -f /etc/firewalld/firewalld.conf ] \
        && ZONE=$(awk -F= '$1 == "DefaultZone" {print $2; exit}' /etc/firewalld/firewalld.conf)
    printf '%s\n' "${ZONE:-public}"
}

fw_warn_environment() {
    if svc_is_active docker 2>/dev/null || { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
        warn "检测到 Docker：容器发布端口可能绕过 UFW，请同时检查绑定地址与 DOCKER-USER 规则"
    fi
    warn "本机防火墙不会修改云厂商安全组，请确保 SSH 端口已在云端放行"
}

fw_ufw_allow_ssh() {
    local PORT PORTS COUNT=0
    PORTS=$(ssh_effective_ports)
    [ -n "$PORTS" ] || { error "无法确定 SSH 端口，拒绝启用 UFW"; return 1; }
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        ufw limit "${PORT}/tcp" >/dev/null 2>&1 \
            || { error "ufw 无法限速放行 SSH ${PORT}/tcp"; return 1; }
        COUNT=$((COUNT + 1))
    done <<< "$PORTS"
    [ "$COUNT" -gt 0 ]
}

fw_firewalld_allow_ssh() {
    local MODE="$1" ZONE="$2" PORT PORTS COUNT=0
    PORTS=$(ssh_effective_ports)
    [ -n "$PORTS" ] || { error "无法确定 SSH 端口，拒绝启用 firewalld"; return 1; }
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        if [ "$MODE" = offline ]; then
            firewall-offline-cmd --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 \
                || { error "firewalld 无法预先放行 SSH ${PORT}/tcp"; return 1; }
        else
            firewall-cmd --permanent --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 \
                || { error "firewalld 无法放行 SSH ${PORT}/tcp"; return 1; }
        fi
        COUNT=$((COUNT + 1))
    done <<< "$PORTS"
    [ "$COUNT" -gt 0 ] || return 1
    [ "$MODE" = offline ] || firewall-cmd --reload >/dev/null 2>&1
}

fw_allow_web_ports() {
    local TYPE="$1" MODE="${2:-online}" ZONE="${3:-public}" PORT
    for PORT in 80 443; do
        case "$TYPE:$MODE" in
            ufw:*) ufw allow "${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
            firewalld:offline) firewall-offline-cmd --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
            firewalld:online) firewall-cmd --permanent --zone="$ZONE" --add-port="${PORT}/tcp" >/dev/null 2>&1 || return 1 ;;
        esac
    done
    if [ "$TYPE:$MODE" = firewalld:online ]; then
        firewall-cmd --reload >/dev/null 2>&1 || return 1
    fi
}

fw_install() {
    local TYPE="$1" WEB_CONFIRM=n MODE=offline ZONE PORT
    print_header "安装并配置防火墙"
    fw_warn_environment
    echo -e "  ${BOLD}必须放行：${NC}SSH $(ssh_effective_ports_csv)/tcp"
    read -rp "  这台机器是否对外提供 HTTP/HTTPS？(y/N): " WEB_CONFIRM || WEB_CONFIRM=n
    echo "$WEB_CONFIRM" | grep -qiE '^y(es)?$' && WEB_CONFIRM=y || WEB_CONFIRM=n

    pkg_install "$TYPE" || { error "安装 $TYPE 失败"; return 1; }
    safety_arm "${TYPE}_install" || return 1
    case "$TYPE" in
        ufw)
            ufw default deny incoming >/dev/null 2>&1 \
                && ufw default allow outgoing >/dev/null 2>&1 \
                && ufw logging low >/dev/null 2>&1 \
                && fw_ufw_allow_ssh \
                || { cancel_safety_timer; error "UFW 基础策略写入失败，未启用"; return 1; }
            if [ "$WEB_CONFIRM" = y ] && ! fw_allow_web_ports ufw; then
                cancel_safety_timer
                error "HTTP/HTTPS 放行失败，未启用 UFW"
                return 1
            fi
            ufw --force enable >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ] \
                || { cancel_safety_timer; error "UFW 启用失败"; return 1; }
            while IFS= read -r PORT; do
                LC_ALL=C ufw status 2>/dev/null | grep -Eq "${PORT}/tcp.*LIMIT" \
                    || { error "UFW 启用后未找到 SSH ${PORT}/tcp 限速规则"; return 1; }
            done < <(ssh_effective_ports)
            ;;
        firewalld)
            ZONE=$(fw_firewalld_zone)
            if [ "$(fw_running firewalld)" = active ]; then
                MODE=online
            elif ! command -v firewall-offline-cmd >/dev/null 2>&1; then
                cancel_safety_timer
                error "缺少 firewall-offline-cmd，拒绝在 SSH 规则写入前启动 firewalld"
                return 1
            fi
            fw_firewalld_allow_ssh "$MODE" "$ZONE" \
                || { cancel_safety_timer; return 1; }
            if [ "$WEB_CONFIRM" = y ] && ! fw_allow_web_ports firewalld "$MODE" "$ZONE"; then
                cancel_safety_timer
                error "HTTP/HTTPS 放行失败，未启用 firewalld"
                return 1
            fi
            svc_enable firewalld
            if [ "$MODE" != online ] && ! svc_start firewalld; then
                cancel_safety_timer
                error "firewalld 启动失败"
                return 1
            fi
            [ "$(fw_running firewalld)" = active ] \
                || { cancel_safety_timer; error "firewalld 未进入运行状态"; return 1; }
            while IFS= read -r PORT; do
                firewall-cmd --zone="$ZONE" --query-port="${PORT}/tcp" >/dev/null 2>&1 \
                    || { error "firewalld 启动后未放行 SSH ${PORT}/tcp"; return 1; }
            done < <(ssh_effective_ports)
            ;;
        *) cancel_safety_timer; return 1 ;;
    esac
    info "$TYPE 已使用最小开放策略启用 ✓"
    [ "$WEB_CONFIRM" = y ] && info "HTTP 80/tcp 与 HTTPS 443/tcp 已放行"
    safety_confirm
}

ufw_show_rules() {
    print_header "防火墙规则 — UFW"
    ufw status verbose 2>/dev/null
    echo ""
    ufw status numbered 2>/dev/null
}

ufw_add_port() {
    local INPUT SPEC DIR
    print_header "添加端口规则 — UFW"
    read -rp "  端口（如 80、53/udp、3000:3010/tcp）: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" ufw) || { error "端口或协议格式无效"; return 1; }
    read -rp "  方向 [in/out，默认 in]: " DIR
    DIR="${DIR:-in}"
    [[ "$DIR" =~ ^(in|out)$ ]] || { error "方向只能是 in 或 out"; return 1; }
    ufw allow "$DIR" "$SPEC" >/dev/null 2>&1 && info "已放行 $DIR $SPEC ✓" || error "添加失败"
}

ufw_delete_numbered_rule() {
    local TITLE="$1" NUM
    while true; do
        print_header "$TITLE — UFW"
        ufw status numbered 2>/dev/null
        read -rp "  输入规则编号（回车返回）: " NUM
        [ -n "$NUM" ] || return
        [[ "$NUM" =~ ^[0-9]+$ ]] || { error "无效编号"; continue; }
        echo y | ufw delete "$NUM" >/dev/null 2>&1 && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
}

ufw_del_port() { ufw_delete_numbered_rule "删除端口规则"; }
ufw_del_ip() { ufw_delete_numbered_rule "删除 IP 规则"; }

ufw_block_ip() {
    local IP FAMILY
    print_header "拉黑 IP — UFW"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    ufw deny from "$IP" to any >/dev/null 2>&1 \
        && info "已拉黑 ${IP}（${FAMILY}）✓" || error "操作失败"
}

fw_prompt_allow_scope() {
    local TYPE="$1" CH INPUT SPEC
    FW_ALLOW_SCOPE=""
    menu_item "1" "仅 SSH（推荐）"
    menu_item "2" "指定端口/协议"
    menu_item "3" "所有服务" "$YELLOW"
    read -rp "$(ui_prompt '选择放行范围 [1-3]: ')" CH
    case "$CH" in
        1)
            FW_ALLOW_SCOPE=ssh
            ;;
        2)
            read -rp "  端口（如 443/tcp、53/udp）: " INPUT
            SPEC=$(fw_port_spec_normalize "$INPUT" "$TYPE") || return 1
            FW_ALLOW_SCOPE="$SPEC"
            ;;
        3) FW_ALLOW_SCOPE=all ;;
        *) return 1 ;;
    esac
}

ufw_allow_ip() {
    local IP FAMILY SCOPE BASE PROTO PORT FAILED=false
    print_header "放行来源 IP — UFW"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    fw_prompt_allow_scope ufw || { error "放行范围无效"; return 1; }
    SCOPE="$FW_ALLOW_SCOPE"
    if [ "$SCOPE" = all ]; then
        warn "这将允许 $IP 访问所有服务"
        ufw allow from "$IP" to any >/dev/null 2>&1 || FAILED=true
    elif [ "$SCOPE" = ssh ]; then
        while IFS= read -r PORT; do
            [ -n "$PORT" ] || continue
            ufw allow from "$IP" to any port "$PORT" proto tcp >/dev/null 2>&1 || FAILED=true
        done < <(ssh_effective_ports)
    else
        BASE="${SCOPE%/*}"; PROTO="${SCOPE##*/}"
        ufw allow from "$IP" to any port "$BASE" proto "$PROTO" >/dev/null 2>&1 || FAILED=true
    fi
    [ "$FAILED" = false ] && info "已放行 ${IP}（${FAMILY}，范围 ${SCOPE}）✓" || error "操作失败"
}

ufw_quick_allow() {
    local CONFIRM
    print_header "快速放行 Web 服务 — UFW"
    echo -e "  将保证 SSH $(ssh_effective_ports_csv)/tcp，并放行 80/tcp、443/tcp"
    read -rp "  确认？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    fw_ufw_allow_ssh && fw_allow_web_ports ufw \
        && info "SSH / HTTP / HTTPS 已放行 ✓" || error "放行失败"
}

fwd_show_rules() {
    local ZONE
    ZONE=$(fw_firewalld_zone)
    print_header "防火墙规则 — firewalld"
    firewall-cmd --zone="$ZONE" --list-all 2>/dev/null
}

fwd_add_port() {
    local INPUT SPEC ZONE
    print_header "添加端口规则 — firewalld"
    read -rp "  端口（如 80/tcp、53/udp、3000-3010/tcp）: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" firewalld) || { error "端口或协议格式无效"; return 1; }
    ZONE=$(fw_firewalld_zone)
    firewall-cmd --permanent --zone="$ZONE" --add-port="$SPEC" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已放行 $SPEC ✓" || error "添加失败"
}

fwd_del_port() {
    local INPUT SPEC ZONE
    print_header "删除端口规则 — firewalld"
    ZONE=$(fw_firewalld_zone)
    firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null
    read -rp "  输入要删除的端口/协议: " INPUT
    [ -n "$INPUT" ] || return
    SPEC=$(fw_port_spec_normalize "$INPUT" firewalld) || { error "格式无效"; return 1; }
    firewall-cmd --permanent --zone="$ZONE" --remove-port="$SPEC" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "端口 $SPEC 已删除 ✓" || error "删除失败"
}

fwd_block_ip() {
    local IP FAMILY ZONE RULE
    print_header "拉黑 IP — firewalld"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    ZONE=$(fw_firewalld_zone)
    RULE="rule family='${FAMILY}' source address='${IP}' reject"
    firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已拉黑 $IP ✓" || error "操作失败"
}

fwd_allow_ip() {
    local IP FAMILY SCOPE BASE PROTO ZONE RULE PORT FAILED=false
    print_header "放行来源 IP — firewalld"
    read -rp "  IP 或 CIDR: " IP
    [ -n "$IP" ] || return
    FAMILY=$(fw_ip_family "$IP") || { error "IP/CIDR 格式无效"; return 1; }
    fw_prompt_allow_scope firewalld || { error "放行范围无效"; return 1; }
    SCOPE="$FW_ALLOW_SCOPE"
    ZONE=$(fw_firewalld_zone)
    if [ "$SCOPE" = all ]; then
        warn "这将允许 $IP 访问所有服务"
        RULE="rule family='${FAMILY}' source address='${IP}' accept"
        firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
    elif [ "$SCOPE" = ssh ]; then
        while IFS= read -r PORT; do
            [ -n "$PORT" ] || continue
            RULE="rule family='${FAMILY}' source address='${IP}' port port='${PORT}' protocol='tcp' accept"
            firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
        done < <(ssh_effective_ports)
    else
        BASE="${SCOPE%/*}"; PROTO="${SCOPE##*/}"
        RULE="rule family='${FAMILY}' source address='${IP}' port port='${BASE}' protocol='${PROTO}' accept"
        firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" >/dev/null 2>&1 || FAILED=true
    fi
    [ "$FAILED" = false ] && firewall-cmd --reload >/dev/null 2>&1 \
        && info "已放行 ${IP}（范围 ${SCOPE}）✓" || error "操作失败"
}

fwd_del_ip() {
    local ZONE NUM i=1
    local RULES=() RULE
    ZONE=$(fw_firewalld_zone)
    while IFS= read -r RULE; do [ -n "$RULE" ] && RULES+=("$RULE"); done < <(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null)
    [ "${#RULES[@]}" -gt 0 ] || { warn "暂无 Rich Rule"; return; }
    print_header "删除 IP 规则 — firewalld"
    for RULE in "${RULES[@]}"; do echo -e "  ${YELLOW}[$i]${NC} $RULE"; i=$((i + 1)); done
    read -rp "  输入要删除的规则编号: " NUM
    [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "${#RULES[@]}" ] \
        || { error "无效编号"; return 1; }
    firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="${RULES[$((NUM - 1))]}" >/dev/null 2>&1 \
        && firewall-cmd --reload >/dev/null 2>&1 \
        && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
}

fwd_quick_allow() {
    local CONFIRM ZONE
    print_header "快速放行 Web 服务 — firewalld"
    echo -e "  将保证 SSH $(ssh_effective_ports_csv)/tcp，并放行 80/tcp、443/tcp"
    read -rp "  确认？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || return
    ZONE=$(fw_firewalld_zone)
    fw_firewalld_allow_ssh online "$ZONE" && fw_allow_web_ports firewalld online "$ZONE" \
        && info "SSH / HTTP / HTTPS 已放行 ✓" || error "放行失败"
}

fw_uninstall() {
    local TYPE="$1" CONFIRM PURGE CONFIG_DIR
    print_header "卸载 $TYPE"
    warn "卸载会停止该防火墙，主机将交由云安全组或其他防火墙保护"
    warn "默认保留配置；不会 flush iptables/nftables，也不会删除其他管理器的规则"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    case "$TYPE" in
        ufw) ufw --force disable >/dev/null 2>&1 || true; CONFIG_DIR=/etc/ufw ;;
        firewalld) svc_stop firewalld >/dev/null 2>&1 || true; svc_disable firewalld >/dev/null 2>&1 || true; CONFIG_DIR=/etc/firewalld ;;
        *) return 1 ;;
    esac
    pkg_remove "$TYPE" || { error "卸载 $TYPE 失败"; return 1; }
    info "$TYPE 已卸载，配置目录已保留 ✓"
    if [ -d "$CONFIG_DIR" ]; then
        read -rp "  输入 PURGE 才会删除整个 ${CONFIG_DIR}（含非 Quench 规则）: " PURGE
        if [ "$PURGE" = PURGE ]; then
            rm -rf "$CONFIG_DIR"
            info "已删除 ${CONFIG_DIR}；该操作需从配置备份恢复"
        fi
    fi
}

ufw_menu() {
    while true; do
        local STATUS ST_COLOR CH OK=true
        STATUS=$(fw_running ufw); [ "$STATUS" = active ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"
        print_header "防火墙管理 — UFW"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        [ "$STATUS" = active ] && menu_item "1" "关闭防火墙" "$YELLOW" || menu_item "1" "开启防火墙"
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行来源 IP" "7" "删除 IP 规则"
        menu_item "8" "快速放行 SSH + Web"
        menu_pair "u" "安装 / 修复" "9" "安全卸载 UFW" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-9 / u]: ')" CH
        case "$CH" in 1|3|4|5|6|7|8) safety_arm ufw || continue ;; esac
        case "$CH" in
            1)
                if [ "$STATUS" = active ]; then
                    ufw --force disable >/dev/null 2>&1 || OK=false
                else
                    ufw --force enable >/dev/null 2>&1 || OK=false
                fi
                ;;
            2) ufw_show_rules; OK=false ;;
            3) ufw_add_port || OK=false ;;
            4) ufw_del_port || OK=false ;;
            5) ufw_block_ip || OK=false ;;
            6) ufw_allow_ip || OK=false ;;
            7) ufw_del_ip || OK=false ;;
            8) ufw_quick_allow || OK=false ;;
            u|U) fw_install ufw; OK=false ;;
            9) fw_uninstall ufw; return ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; OK=false ;;
        esac
        case "$CH" in 1|3|4|5|6|7|8) [ "$OK" = true ] && safety_confirm || cancel_safety_timer ;; esac
        [ "$CH" != 0 ] && ui_pause
    done
}

fwd_menu() {
    while true; do
        local STATUS ST_COLOR CH OK=true
        STATUS=$(fw_running firewalld); [ "$STATUS" = active ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"
        print_header "防火墙管理 — firewalld"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        [ "$STATUS" = active ] && menu_item "1" "关闭防火墙" "$YELLOW" || menu_item "1" "开启防火墙"
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行来源 IP" "7" "删除 IP 规则"
        menu_item "8" "快速放行 SSH + Web"
        menu_pair "u" "安装 / 修复" "9" "安全卸载 firewalld" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择操作 [0-9 / u]: ')" CH
        case "$CH" in 1|3|4|5|6|7|8) safety_arm firewalld || continue ;; esac
        case "$CH" in
            1)
                if [ "$STATUS" = active ]; then
                    svc_stop firewalld || OK=false
                else
                    svc_start firewalld || OK=false
                fi
                ;;
            2) fwd_show_rules; OK=false ;;
            3) fwd_add_port || OK=false ;;
            4) fwd_del_port || OK=false ;;
            5) fwd_block_ip || OK=false ;;
            6) fwd_allow_ip || OK=false ;;
            7) fwd_del_ip || OK=false ;;
            8) fwd_quick_allow || OK=false ;;
            u|U) fw_install firewalld; OK=false ;;
            9) fw_uninstall firewalld; return ;;
            0) return ;;
            00) safe_clear; exit 0 ;;
            *) warn "无效选项"; OK=false ;;
        esac
        case "$CH" in 1|3|4|5|6|7|8) [ "$OK" = true ] && safety_confirm || cancel_safety_timer ;; esac
        [ "$CH" != 0 ] && ui_pause
    done
}

firewall_menu() {
    while true; do
        local FW_TYPE CH
        FW_TYPE=$(fw_detect)
        case "$FW_TYPE" in
            none)
                print_header "防火墙管理"
                warn "未检测到已安装的防火墙"
                menu_item "1" "UFW  Ubuntu / Debian 推荐"
                menu_item "2" "firewalld  Rocky / Fedora 推荐"
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                read -rp "$(ui_prompt '选择防火墙 [0-2]: ')" CH
                case "$CH" in
                    1) fw_install ufw; ui_continue ;;
                    2) fw_install firewalld; ui_continue ;;
                    0) return ;;
                    00) safe_clear; exit 0 ;;
                    *) warn "无效选项" ;;
                esac
                ;;
            conflict)
                print_header "防火墙冲突"
                warn "同时检测到 UFW 与 firewalld，拒绝自动选择以避免管理错误后端"
                echo -e "  UFW: $(fw_running ufw)    firewalld: $(fw_running firewalld)"
                menu_pair "1" "管理 UFW" "2" "管理 firewalld"
                menu_item "0" "返回主菜单"
                read -rp "$(ui_prompt '选择要管理的后端 [0-2]: ')" CH
                case "$CH" in 1) ufw_menu ;; 2) fwd_menu ;; *) return ;; esac
                ;;
            ufw) ufw_menu; return ;;
            firewalld) fwd_menu; return ;;
        esac
    done
}
# ── 用户与 SSH 访问管理子菜单 ──────────────────────────────
user_management_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY AUTH_LABEL ROOT_LOGIN CHOICE
        CUR_PORT=$(get_config Port)
        CUR_PWD=$(get_config PasswordAuthentication)
        CUR_PUBKEY=$(get_config PubkeyAuthentication)
        ROOT_LOGIN=$(get_config PermitRootLogin)
        if [ "$CUR_PWD" = no ] && [ "$CUR_PUBKEY" = yes ]; then AUTH_LABEL="仅密钥"
        elif [ "$CUR_PWD" = yes ]; then AUTH_LABEL="允许密码"
        else AUTH_LABEL="未确认"; fi

        print_header "用户与 SSH 访问管理"
        status_pair "用户" "$(user_count) · 管理员 $(user_admin_count)" "active" \
                    "SSH" "${CUR_PORT:-22} · $AUTH_LABEL" "active"
        status_pair "root SSH" "${ROOT_LOGIN:-未确认}" "$([ "$ROOT_LOGIN" = no ] && echo active || echo warning)" \
                    "当前用户" "$(user_current_actor)" "active"
        echo ""
        menu_div
        menu_pair "1" "查看用户与权限" "2" "创建用户"
        menu_pair "3" "管理 sudo 权限" "4" "修改/锁定密码"
        menu_pair "5" "管理用户公钥" "6" "删除用户"
        menu_pair "7" "SSH 登录策略" "8" "修改 SSH 端口"
        menu_pair "9" "SSH 状态与检查" "w" "推荐安全向导"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9 / w]: ')" CHOICE

        case "$CHOICE" in
            1) user_show_list; ui_pause ;;
            2) user_create; ui_pause ;;
            3) user_admin_manage; ui_pause ;;
            4) user_password_manage; ui_pause ;;
            5) user_ssh_keys_manage ;;
            6) user_delete; ui_pause ;;
            7) set_login_mode; ui_pause ;;
            8) change_port; ui_pause ;;
            9) ssh_security_status; ui_pause ;;
            w|W) user_recommended_wizard; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
# ══════════════════════════════════════════════════════════
#  DNS 管理与诊断模块
# ══════════════════════════════════════════════════════════

dns_resolv_file() { printf '%s\n' "${DNS_RESOLV_FILE:-/etc/resolv.conf}"; }
dns_resolved_dropin() { printf '%s\n' "${DNS_RESOLVED_DROPIN:-/etc/systemd/resolved.conf.d/99-quench.conf}"; }
dns_resolvconf_head() { printf '%s\n' "${DNS_RESOLVCONF_HEAD:-/etc/resolvconf/resolv.conf.d/head}"; }

dns_nm_default_iface() {
    default_iface 2>/dev/null || true
}

dns_nm_connection_uuid() {
    local IFACE="${1:-}" UUID
    [ -n "$IFACE" ] || return 1
    UUID=$(nmcli -g GENERAL.CON-UUID device show "$IFACE" 2>/dev/null | awk 'NF && $0 != "--" {print; exit}')
    if [ -z "$UUID" ]; then
        UUID=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v iface="$IFACE" '$2 == iface {print $1; exit}')
    fi
    [ -n "$UUID" ] || return 1
    printf '%s\n' "$UUID"
}

dns_backend_detect() {
    local RESOLV IFACE
    RESOLV=$(dns_resolv_file)
    IFACE=$(dns_nm_default_iface)
    if command -v nmcli >/dev/null 2>&1 && svc_is_active NetworkManager \
        && [ -n "$IFACE" ] && dns_nm_connection_uuid "$IFACE" >/dev/null 2>&1; then
        echo NetworkManager
    elif command -v resolvectl >/dev/null 2>&1 \
        && { svc_is_active systemd-resolved \
            || { [ -L "$RESOLV" ] && readlink "$RESOLV" 2>/dev/null | grep -q 'systemd/resolve'; }; }; then
        echo systemd-resolved
    elif command -v resolvconf >/dev/null 2>&1; then
        echo resolvconf
    elif [ -L "$RESOLV" ]; then
        echo managed-symlink
    else
        echo static
    fi
}

dns_backend_label() {
    case "$1" in
        NetworkManager) echo 'NetworkManager（默认连接）' ;;
        systemd-resolved) echo systemd-resolved ;;
        resolvconf) echo resolvconf ;;
        managed-symlink) echo '未知托管后端（符号链接）' ;;
        *) echo '静态 /etc/resolv.conf' ;;
    esac
}

dns_effective_servers() {
    local BACKEND="$1" IFACE="${2:-}" RESOLV
    RESOLV=$(dns_resolv_file)
    case "$BACKEND" in
        NetworkManager)
            nmcli -g IP4.DNS,IP6.DNS device show "$IFACE" 2>/dev/null | awk 'NF && !seen[$0]++'
            ;;
        systemd-resolved)
            resolvectl dns 2>/dev/null \
                | awk '{sub(/^.*: /, ""); for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-Fa-f:.]+$/ && !seen[$i]++) print $i}'
            ;;
        *)
            awk '$1 == "nameserver" && NF >= 2 && !seen[$2]++ {print $2}' "$RESOLV" 2>/dev/null
            ;;
    esac
}

dns_show_current() {
    local BACKEND IFACE UUID SERVER COUNT=0
    BACKEND=$(dns_backend_detect)
    IFACE=$(dns_nm_default_iface)
    echo -e "  ${BOLD}DNS 后端：${NC}$(dns_backend_label "$BACKEND")"
    if [ "$BACKEND" = NetworkManager ]; then
        UUID=$(dns_nm_connection_uuid "$IFACE" 2>/dev/null || true)
        echo -e "  ${BOLD}默认连接：${NC}${IFACE:-未知}${UUID:+  ${DIM}$UUID${NC}}"
    elif [ -n "$IFACE" ]; then
        echo -e "  ${BOLD}默认网卡：${NC}$IFACE"
    fi
    echo -e "  ${BOLD}当前有效上游：${NC}"
    while IFS= read -r SERVER; do
        [ -n "$SERVER" ] || continue
        COUNT=$((COUNT + 1))
        if [[ "$SERVER" == *:* ]]; then
            echo -e "    ${YELLOW}$SERVER${NC}  ${DIM}(IPv6)${NC}"
        else
            echo -e "    ${CYAN}$SERVER${NC}  ${DIM}(IPv4)${NC}"
        fi
    done < <(dns_effective_servers "$BACKEND" "$IFACE")
    [ "$COUNT" -gt 0 ] || echo -e "    ${YELLOW}未能读取有效上游 DNS${NC}"
    [ "$BACKEND" != managed-symlink ] \
        || warn "无法识别 /etc/resolv.conf 的管理程序；为避免配置被覆盖，Quench 不会直接写入该链接"
}

# 只有同时具备全局地址和可用路由，才启用对应协议族的 DNS。
dns_detect_network() {
    local HAS_V4=false HAS_V6=false V6_DISABLED
    if ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' \
        && ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        HAS_V4=true
    fi
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
    if [ "$V6_DISABLED" != 1 ] \
        && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' \
        && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_V6=true
    fi
    echo "${HAS_V4}:${HAS_V6}"
}

dns_ipv4_valid() {
    local VALUE="$1" OCTET
    local -a OCTETS=()
    [[ "$VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a OCTETS <<< "$VALUE"
    [ "${#OCTETS[@]}" -eq 4 ] || return 1
    for OCTET in "${OCTETS[@]}"; do
        [[ "$OCTET" =~ ^[0-9]+$ ]] && [ "$OCTET" -le 255 ] || return 1
    done
}

dns_ipv6_valid() {
    local VALUE="$1"
    [[ "$VALUE" == *:* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$VALUE" >/dev/null 2>&1
    else
        [[ "$VALUE" =~ ^[0-9A-Fa-f:]+$ ]] \
            && ip -6 route get "$VALUE" >/dev/null 2>&1
    fi
}

dns_list_validate() {
    local LIST="$1" FAMILY="$2" SERVER
    [ -n "$LIST" ] || return 0
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $LIST; do
        case "$FAMILY" in
            4) dns_ipv4_valid "$SERVER" || return 1 ;;
            6) dns_ipv6_valid "$SERVER" || return 1 ;;
            *) return 1 ;;
        esac
    done
}

# 返回 0=直连查询成功，1=失败，2=系统缺少直连查询工具。
dns_probe_server() {
    local SERVER="$1"
    if command -v dig >/dev/null 2>&1; then
        dig @"$SERVER" example.com A +time=2 +tries=1 +short 2>/dev/null | grep -qE '^[0-9]+\.' \
            && dig @"$SERVER" example.com A +tcp +time=2 +tries=1 +short 2>/dev/null | grep -qE '^[0-9]+\.'
    elif command -v nslookup >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 nslookup example.com "$SERVER" >/dev/null 2>&1
        else
            nslookup example.com "$SERVER" >/dev/null 2>&1
        fi
    else
        return 2
    fi
}

dns_filter_reachable() {
    local LIST="$1" FAMILY="$2" SERVER RC
    DNS_FILTERED=""
    [ -n "$LIST" ] || return 0
    if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
        warn "未安装 dig/nslookup，跳过逐台 DNS 直连预检"
        DNS_FILTERED="$LIST"
        return 0
    fi
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $LIST; do
        RC=0
        dns_probe_server "$SERVER" || RC=$?
        if [ "$RC" -eq 0 ]; then
            DNS_FILTERED="${DNS_FILTERED:+$DNS_FILTERED }$SERVER"
            info "IPv${FAMILY} DNS 直连正常：$SERVER"
        else
            warn "IPv${FAMILY} DNS 无法完成直连查询，已从本次配置排除：$SERVER"
        fi
    done
}

dns_atomic_write() {
    local TARGET="$1" CONTENT="$2" DIR TMP
    DIR=$(dirname "$TARGET")
    mkdir -p "$DIR" || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    printf '%s\n' "$CONTENT" > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 644 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$TARGET" || { rm -f "$TMP"; return 1; }
}

dns_apply_resolved() {
    local ALL_DNS="$1" DROPIN CONTENT
    DROPIN=$(dns_resolved_dropin)
    CONTENT="[Resolve]
DNS=$ALL_DNS
FallbackDNS=
Domains=~."
    dns_atomic_write "$DROPIN" "$CONTENT" || return 1
    svc_restart systemd-resolved || return 1
    resolvectl flush-caches >/dev/null 2>&1 || true
}

dns_apply_nm() {
    local V4_LIST="$1" V6_LIST="$2" IFACE UUID
    IFACE=$(dns_nm_default_iface)
    UUID=$(dns_nm_connection_uuid "$IFACE") || return 1
    if [ -n "$V4_LIST" ]; then
        nmcli connection modify "$UUID" ipv4.ignore-auto-dns yes ipv4.dns "$V4_LIST" \
            ipv4.dns-priority 10 +ipv4.dns-search '~.' >/dev/null 2>&1 || return 1
    else
        nmcli connection modify "$UUID" ipv4.ignore-auto-dns yes ipv4.dns '' ipv4.dns-priority 10 >/dev/null 2>&1 || return 1
        nmcli connection modify "$UUID" -ipv4.dns-search '~.' >/dev/null 2>&1 || true
    fi
    if [ -n "$V6_LIST" ]; then
        nmcli connection modify "$UUID" ipv6.ignore-auto-dns yes ipv6.dns "$V6_LIST" \
            ipv6.dns-priority 10 +ipv6.dns-search '~.' >/dev/null 2>&1 || return 1
    else
        nmcli connection modify "$UUID" ipv6.ignore-auto-dns yes ipv6.dns '' ipv6.dns-priority 10 >/dev/null 2>&1 || return 1
        nmcli connection modify "$UUID" -ipv6.dns-search '~.' >/dev/null 2>&1 || true
    fi
    nmcli device reapply "$IFACE" >/dev/null 2>&1 || return 1
}

dns_apply_resolvconf() {
    local ALL_DNS="$1" HEAD DIR TMP SERVER
    HEAD=$(dns_resolvconf_head)
    DIR=$(dirname "$HEAD")
    mkdir -p "$DIR" || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    awk '$1 != "nameserver"' "$HEAD" 2>/dev/null > "$TMP" || true
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $ALL_DNS; do printf 'nameserver %s\n' "$SERVER" >> "$TMP"; done
    chmod 644 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$HEAD" || { rm -f "$TMP"; return 1; }
    resolvconf -u >/dev/null 2>&1
}

dns_apply_static() {
    local ALL_DNS="$1" RESOLV DIR TMP SERVER IMMUTABLE=false
    RESOLV=$(dns_resolv_file)
    [ ! -L "$RESOLV" ] || return 1
    DIR=$(dirname "$RESOLV")
    mkdir -p "$DIR" || return 1
    if command -v lsattr >/dev/null 2>&1 \
        && lsattr -d "$RESOLV" 2>/dev/null | awk '{print $1}' | grep -q i; then
        IMMUTABLE=true
    fi
    [ "$IMMUTABLE" = false ] || chattr -i "$RESOLV" 2>/dev/null || return 1
    TMP=$(mktemp "$DIR/.quench-dns.XXXXXX") || return 1
    [ ! -e "$RESOLV" ] || cp -a "$RESOLV" "$TMP" 2>/dev/null || true
    awk '$1 != "nameserver"' "$RESOLV" 2>/dev/null > "$TMP" || true
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $ALL_DNS; do printf 'nameserver %s\n' "$SERVER" >> "$TMP"; done
    chmod 644 "$TMP" 2>/dev/null || true
    if ! mv -f "$TMP" "$RESOLV"; then
        rm -f "$TMP"
        [ "$IMMUTABLE" = false ] || chattr +i "$RESOLV" 2>/dev/null || true
        return 1
    fi
    [ "$IMMUTABLE" = false ] || chattr +i "$RESOLV" 2>/dev/null || return 1
}

dns_flush_caches() {
    resolvectl flush-caches >/dev/null 2>&1 || true
    if command -v nscd >/dev/null 2>&1; then nscd -i hosts >/dev/null 2>&1 || true; fi
}

dns_system_resolves() {
    local DOMAIN
    for DOMAIN in github.com example.com; do
        if command -v getent >/dev/null 2>&1; then
            getent ahosts "$DOMAIN" >/dev/null 2>&1 || return 1
        elif command -v host >/dev/null 2>&1; then
            host "$DOMAIN" >/dev/null 2>&1 || return 1
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup "$DOMAIN" >/dev/null 2>&1 || return 1
        else
            return 2
        fi
    done
}

dns_effective_matches() {
    local BACKEND="$1" IFACE="$2" EXPECTED="$3" EFFECTIVE SERVER
    EFFECTIVE=$(dns_effective_servers "$BACKEND" "$IFACE")
    # shellcheck disable=SC2086 # DNS lists are intentionally space-delimited.
    for SERVER in $EXPECTED; do
        printf '%s\n' "$EFFECTIVE" | grep -Fxq "$SERVER" && return 0
    done
    return 1
}

dns_fail_and_rollback() {
    local MESSAGE="$1" BACKEND="$2"
    error "$MESSAGE"
    audit_action "DNS 更新失败，后端 $BACKEND" FAILED
    if safety_rollback_now; then
        warn "已立即恢复本次 DNS 修改前的配置"
    fi
    return 1
}

dns_write() {
    local V4_LIST="$1" V6_LIST="$2" HAS_V6="$3"
    local BACKEND IFACE ALL_DNS CURRENT_DNS NET_INFO HAS_V4_ROUTE HAS_V6_ROUTE EFFECTIVE_PATHS=() RESOLVE_RC=0
    dns_list_validate "$V4_LIST" 4 || { error "IPv4 DNS 地址格式不正确"; return 1; }
    dns_list_validate "$V6_LIST" 6 || { error "IPv6 DNS 地址格式不正确"; return 1; }
    NET_INFO=$(dns_detect_network)
    HAS_V4_ROUTE=${NET_INFO%%:*}
    HAS_V6_ROUTE=${NET_INFO##*:}
    if [ "$HAS_V4_ROUTE" != true ] && [ -n "$V4_LIST" ]; then
        warn "当前没有可用 IPv4 路由，本次不写入 IPv4 DNS"
        V4_LIST=""
    fi
    if { [ "$HAS_V6" != true ] || [ "$HAS_V6_ROUTE" != true ]; } && [ -n "$V6_LIST" ]; then
        warn "当前没有可用 IPv6 路由，本次不写入 IPv6 DNS"
        V6_LIST=""
    fi

    dns_filter_reachable "$V4_LIST" 4
    V4_LIST="$DNS_FILTERED"
    dns_filter_reachable "$V6_LIST" 6
    V6_LIST="$DNS_FILTERED"
    ALL_DNS="$V4_LIST${V4_LIST:+${V6_LIST:+ }}$V6_LIST"
    [ -n "$ALL_DNS" ] || { error "候选 DNS 均无法直连，未修改系统配置"; return 1; }

    BACKEND=$(dns_backend_detect)
    IFACE=$(dns_nm_default_iface)
    [ "$BACKEND" != managed-symlink ] || {
        error "无法识别 /etc/resolv.conf 的托管后端，拒绝直接覆盖符号链接"
        return 1
    }
    CURRENT_DNS=$(dns_effective_servers "$BACKEND" "$IFACE" | awk '{printf "%s%s", sep, $0; sep=" "}')
    confirm_change_preview "DNS 管理" \
        "后端：$(dns_backend_label "$BACKEND")" \
        "作用范围：${IFACE:-全局}" \
        "当前上游：${CURRENT_DNS:-未读取到}" \
        "目标上游：$ALL_DNS" || { warn "已取消"; return 0; }

    case "$BACKEND" in
        systemd-resolved) EFFECTIVE_PATHS+=("$(dns_resolved_dropin)") ;;
        resolvconf) EFFECTIVE_PATHS+=("$(dns_resolvconf_head)") ;;
        static) EFFECTIVE_PATHS+=("$(dns_resolv_file)") ;;
    esac
    safety_arm dns "${EFFECTIVE_PATHS[@]}" || return 1

    case "$BACKEND" in
        systemd-resolved) dns_apply_resolved "$ALL_DNS" \
            || { dns_fail_and_rollback "systemd-resolved 配置应用失败" "$BACKEND"; return 1; } ;;
        NetworkManager) dns_apply_nm "$V4_LIST" "$V6_LIST" \
            || { dns_fail_and_rollback "NetworkManager 默认连接的 DNS 应用失败" "$BACKEND"; return 1; } ;;
        resolvconf) dns_apply_resolvconf "$ALL_DNS" \
            || { dns_fail_and_rollback "resolvconf 配置应用失败" "$BACKEND"; return 1; } ;;
        static) dns_apply_static "$ALL_DNS" \
            || { dns_fail_and_rollback "静态 resolv.conf 写入失败" "$BACKEND"; return 1; } ;;
        *) dns_fail_and_rollback "不支持的 DNS 后端：$BACKEND" "$BACKEND"; return 1 ;;
    esac

    dns_flush_caches
    dns_effective_matches "$BACKEND" "$IFACE" "$ALL_DNS" \
        || { dns_fail_and_rollback "后端未报告本次设置的 DNS，上游可能没有真正生效" "$BACKEND"; return 1; }
    dns_system_resolves || RESOLVE_RC=$?
    if [ "$RESOLVE_RC" -eq 1 ]; then
        dns_fail_and_rollback "系统域名解析测试失败" "$BACKEND"
        return 1
    elif [ "$RESOLVE_RC" -eq 2 ]; then
        warn "系统缺少 getent/host/nslookup，仅完成了后端生效检查"
    fi

    info "DNS 已通过 $BACKEND 持久化，且有效上游检查通过 ✓"
    audit_action "更新 DNS，后端 ${BACKEND}，上游 $ALL_DNS" SUCCESS
    echo ""
    dns_show_current
    safety_confirm
}

dns_custom_prompt() {
    local HAS_V6="$1" V4_LIST V6_LIST=""
    echo -e "  ${DIM}多个地址用空格或英文逗号分隔；可以只填一个协议族。${NC}"
    read -rp "  IPv4 DNS（可留空）: " V4_LIST
    V4_LIST=$(printf '%s' "$V4_LIST" | tr ',' ' ' | awk '{$1=$1; print}')
    if [ "$HAS_V6" = true ]; then
        read -rp "  IPv6 DNS（可留空）: " V6_LIST
        V6_LIST=$(printf '%s' "$V6_LIST" | tr ',' ' ' | awk '{$1=$1; print}')
    fi
    [ -n "$V4_LIST$V6_LIST" ] || { warn "没有输入 DNS 地址"; return 1; }
    dns_write "$V4_LIST" "$V6_LIST" "$HAS_V6"
}

dns_menu() {
    while true; do
        print_header "DNS 管理与诊断"
        dns_show_current
        echo ""

        local NET_INFO HAS_V4 HAS_V6 V4_LABEL V6_LABEL CH
        NET_INFO=$(dns_detect_network)
        HAS_V4=${NET_INFO%%:*}
        HAS_V6=${NET_INFO##*:}
        [ "$HAS_V4" = true ] && V4_LABEL="${GREEN}IPv4 路由可用${NC}" || V4_LABEL="${YELLOW}IPv4 不可用${NC}"
        [ "$HAS_V6" = true ] && V6_LABEL="${GREEN}IPv6 路由可用${NC}" || V6_LABEL="${DIM}IPv6 不可用${NC}"
        echo -e "  网络：$V4_LABEL  $V6_LABEL"
        echo -e "  ${DIM}应用前会逐台直连测试；失败的候选不会写入配置。${NC}"
        echo ""

        menu_div
        echo -e "  ${BOLD}国际公共 DNS：${NC}"
        menu_item "1" "Cloudflare  ${DIM}1.1.1.1 / 1.0.0.1${NC}"
        menu_item "2" "Google  ${DIM}8.8.8.8 / 8.8.4.4${NC}"
        menu_item "3" "跨运营商冗余  ${DIM}Cloudflare + Google${NC}"
        menu_div
        echo -e "  ${BOLD}中国大陆公共 DNS：${NC}"
        menu_item "4" "阿里云  ${DIM}223.5.5.5 / 223.6.6.6${NC}"
        menu_item "5" "腾讯 DNSPod  ${DIM}119.29.29.29${NC}"
        menu_item "6" "114 DNS  ${DIM}114.114.114.114 / 114.114.115.115${NC}"
        menu_div
        menu_item "7" "自定义 DNS 地址"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择 DNS [0-7]: ')" CH

        case "$CH" in
            1) dns_write "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001" "$HAS_V6" ;;
            2) dns_write "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844" "$HAS_V6" ;;
            3) dns_write "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888" "$HAS_V6" ;;
            4) dns_write "223.5.5.5 223.6.6.6" "2400:3200::1 2400:3200:baba::1" "$HAS_V6" ;;
            5) dns_write "119.29.29.29" "" "$HAS_V6" ;;
            6) dns_write "114.114.114.114 114.114.115.115" "" "$HAS_V6" ;;
            7) dns_custom_prompt "$HAS_V6" ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "$CH" != 0 ] && ui_pause
    done
}
# ══════════════════════════════════════════════════════════
#  软件源管理（APT / DNF）
# ══════════════════════════════════════════════════════════

MIRROR_STATE_DIR="${QUENCH_MIRROR_STATE_DIR:-$QUENCH_DATA_DIR/mirrors}"
MIRROR_APT_DIR="${QUENCH_MIRROR_APT_DIR:-/etc/apt}"
MIRROR_RPM_REPO_DIR="${QUENCH_MIRROR_RPM_REPO_DIR:-/etc/yum.repos.d}"
MIRROR_RPM_GPG_DIR="${QUENCH_MIRROR_RPM_GPG_DIR:-/etc/pki/rpm-gpg}"
MIRROR_OS_RELEASE_FILE="${QUENCH_MIRROR_OS_RELEASE_FILE:-/etc/os-release}"
MIRROR_SECURITY_POLICY="${QUENCH_MIRROR_SECURITY_POLICY:-official}"

mirror_os_release_value() {
    local KEY="$1" VALUE
    [ -f "$MIRROR_OS_RELEASE_FILE" ] || return 1
    VALUE=$(sed -n "s/^${KEY}=//p" "$MIRROR_OS_RELEASE_FILE" 2>/dev/null | head -1)
    VALUE=${VALUE#\"}; VALUE=${VALUE%\"}
    VALUE=${VALUE#\'}; VALUE=${VALUE%\'}
    [ -n "$VALUE" ] || return 1
    printf '%s\n' "$VALUE"
}

detect_os() {
    local ID_VALUE VERSION_VALUE
    ID_VALUE=$(mirror_os_release_value ID 2>/dev/null || echo unknown)
    VERSION_VALUE=$(mirror_os_release_value VERSION_ID 2>/dev/null || true)
    printf '%s:%s\n' "$ID_VALUE" "$VERSION_VALUE"
}

mirror_codename() {
    local VALUE
    VALUE=$(mirror_os_release_value VERSION_CODENAME 2>/dev/null || true)
    [ -n "$VALUE" ] || VALUE=$(mirror_os_release_value UBUNTU_CODENAME 2>/dev/null || true)
    if [ -z "$VALUE" ] && command -v lsb_release >/dev/null 2>&1; then
        VALUE=$(lsb_release -cs 2>/dev/null || true)
    fi
    [[ "$VALUE" =~ ^[a-z][a-z0-9]*$ ]] || return 1
    printf '%s\n' "$VALUE"
}

mirror_arch() {
    local ARCH_VALUE="${QUENCH_MIRROR_ARCH:-}"
    if [ -z "$ARCH_VALUE" ] && command -v dpkg >/dev/null 2>&1; then
        ARCH_VALUE=$(dpkg --print-architecture 2>/dev/null || true)
    fi
    if [ -z "$ARCH_VALUE" ] && command -v rpm >/dev/null 2>&1; then
        ARCH_VALUE=$(rpm --eval '%{_arch}' 2>/dev/null || true)
    fi
    [ -n "$ARCH_VALUE" ] || ARCH_VALUE=$(uname -m 2>/dev/null || echo unknown)
    case "$ARCH_VALUE" in
        x86_64) ARCH_VALUE=amd64 ;;
        aarch64) ARCH_VALUE=arm64 ;;
        armv7l|armv7) ARCH_VALUE=armhf ;;
        ppc64le) ARCH_VALUE=ppc64el ;;
    esac
    printf '%s\n' "$ARCH_VALUE"
}

mirror_rpm_basearch() {
    local ARCH_VALUE="${QUENCH_MIRROR_RPM_ARCH:-}"
    if [ -z "$ARCH_VALUE" ] && command -v rpm >/dev/null 2>&1; then
        ARCH_VALUE=$(rpm --eval '%{_arch}' 2>/dev/null || true)
    fi
    [ -n "$ARCH_VALUE" ] || ARCH_VALUE=$(uname -m 2>/dev/null || echo unknown)
    case "$ARCH_VALUE" in
        amd64) ARCH_VALUE=x86_64 ;;
        arm64) ARCH_VALUE=aarch64 ;;
        armhf) ARCH_VALUE=armv7hl ;;
        ppc64el) ARCH_VALUE=ppc64le ;;
    esac
    printf '%s\n' "$ARCH_VALUE"
}

mirror_ubuntu_archive_kind() {
    case "$1" in
        amd64|i386) echo ubuntu ;;
        arm64|armhf|ppc64el|s390x|riscv64) echo ubuntu-ports ;;
        *) return 1 ;;
    esac
}

mirror_apt_official_main() {
    local OS_ID="$1" ARCH_VALUE="$2" KIND
    case "$OS_ID" in
        ubuntu)
            KIND=$(mirror_ubuntu_archive_kind "$ARCH_VALUE") || return 1
            if [ "$KIND" = ubuntu ]; then
                echo "https://archive.ubuntu.com/ubuntu"
            else
                echo "https://ports.ubuntu.com/ubuntu-ports"
            fi
            ;;
        debian) echo "https://deb.debian.org/debian" ;;
        *) return 1 ;;
    esac
}

mirror_apt_official_security() {
    local OS_ID="$1" ARCH_VALUE="$2" KIND
    case "$OS_ID" in
        ubuntu)
            KIND=$(mirror_ubuntu_archive_kind "$ARCH_VALUE") || return 1
            if [ "$KIND" = ubuntu ]; then
                echo "https://security.ubuntu.com/ubuntu"
            else
                echo "https://ports.ubuntu.com/ubuntu-ports"
            fi
            ;;
        debian) echo "https://security.debian.org/debian-security" ;;
        *) return 1 ;;
    esac
}

# 输出：主仓库|镜像安全仓库|显示名
mirror_apt_candidate() {
    local OS_ID="$1" KEY="$2" ARCH_VALUE="${3:-$(mirror_arch)}" KIND SUFFIX
    if [ "$OS_ID" = ubuntu ]; then
        KIND=$(mirror_ubuntu_archive_kind "$ARCH_VALUE") || return 1
        [ "$KIND" = ubuntu ] && SUFFIX=ubuntu || SUFFIX=ubuntu-ports
        case "$KEY" in
            aliyun) echo "https://mirrors.aliyun.com/${SUFFIX}|https://mirrors.aliyun.com/${SUFFIX}|阿里云" ;;
            tencent) echo "https://mirrors.tencent.com/${SUFFIX}|https://mirrors.tencent.com/${SUFFIX}|腾讯云" ;;
            tuna) echo "https://mirrors.tuna.tsinghua.edu.cn/${SUFFIX}|https://mirrors.tuna.tsinghua.edu.cn/${SUFFIX}|清华 TUNA" ;;
            ustc) echo "https://mirrors.ustc.edu.cn/${SUFFIX}|https://mirrors.ustc.edu.cn/${SUFFIX}|中科大 USTC" ;;
            official) echo "$(mirror_apt_official_main ubuntu "$ARCH_VALUE")|$(mirror_apt_official_security ubuntu "$ARCH_VALUE")|Ubuntu 官方" ;;
            *) return 1 ;;
        esac
    elif [ "$OS_ID" = debian ]; then
        case "$KEY" in
            aliyun) echo "https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security|阿里云" ;;
            tencent) echo "https://mirrors.tencent.com/debian|https://mirrors.tencent.com/debian-security|腾讯云" ;;
            tuna) echo "https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security|清华 TUNA" ;;
            ustc) echo "https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security|中科大 USTC" ;;
            official) echo "$(mirror_apt_official_main debian "$ARCH_VALUE")|$(mirror_apt_official_security debian "$ARCH_VALUE")|Debian 官方" ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

mirror_url_probe() {
    local URL="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 4 --max-time 12 --range 0-2047 -o /dev/null "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=12 -O /dev/null "$URL"
    else
        return 2
    fi
}

mirror_apt_probe_candidate() {
    local MAIN_URI="$1" SECURITY_URI="$2" CODENAME="$3" MAIN_URL SECURITY_URL RC
    MAIN_URL="${MAIN_URI%/}/dists/${CODENAME}/InRelease"
    SECURITY_URL="${SECURITY_URI%/}/dists/${CODENAME}-security/InRelease"
    mirror_url_probe "$MAIN_URL" || { RC=$?; [ "$RC" -eq 2 ] && return 2; return 1; }
    mirror_url_probe "$SECURITY_URL" || { RC=$?; [ "$RC" -eq 2 ] && return 2; return 1; }
    return 0
}

mirror_apt_format() {
    local HAS_LIST=no HAS_DEB822=no FILE
    [ -s "$MIRROR_APT_DIR/sources.list" ] && HAS_LIST=yes
    for FILE in "$MIRROR_APT_DIR/sources.list.d/"*.list; do [ -s "$FILE" ] && HAS_LIST=yes; done
    for FILE in "$MIRROR_APT_DIR/sources.list.d/"*.sources; do [ -s "$FILE" ] && HAS_DEB822=yes; done
    case "$HAS_LIST:$HAS_DEB822" in
        yes:yes) echo mixed ;;
        yes:no) echo list ;;
        no:yes) echo deb822 ;;
        *) echo none ;;
    esac
}

mirror_apt_current_uris() {
    local FILE
    {
        for FILE in "$MIRROR_APT_DIR/sources.list" "$MIRROR_APT_DIR/sources.list.d/"*.list; do
            [ -f "$FILE" ] || continue
            awk '
                /^[[:space:]]*deb(-src)?[[:space:]]/ {
                    for (i=2; i<=NF; i++) {
                        if ($i ~ /^https?:\/\//) { print $i; break }
                    }
                }
            ' "$FILE"
        done
        for FILE in "$MIRROR_APT_DIR/sources.list.d/"*.sources; do
            [ -f "$FILE" ] || continue
            awk '/^[[:space:]]*URIs:[[:space:]]*/ {sub(/^[[:space:]]*URIs:[[:space:]]*/, ""); print}' "$FILE"
        done
    } | awk 'NF && !seen[$0]++' | head -8
}

mirror_safe_remove_dir() {
    local TARGET="$1"
    case "$TARGET" in
        "$MIRROR_STATE_DIR"/*|"$MIRROR_APT_DIR"/.quench-*|"$(dirname "$MIRROR_RPM_REPO_DIR")"/.quench-rpm-*)
            rm -rf -- "$TARGET"
            ;;
        *)
            error "拒绝清理非 Quench 临时目录：$TARGET"
            return 1
            ;;
    esac
}

mirror_state_prepare() {
    mkdir -p "$MIRROR_STATE_DIR" || return 1
    chmod 700 "$MIRROR_STATE_DIR" 2>/dev/null || true
}

mirror_apt_tree_capture() {
    local DEST="$1" HAD_LIST=no HAD_PARTS=no
    mkdir -p "$DEST" || return 1
    if [ -f "$MIRROR_APT_DIR/sources.list" ]; then
        cp -a "$MIRROR_APT_DIR/sources.list" "$DEST/sources.list" || return 1
        HAD_LIST=yes
    fi
    if [ -d "$MIRROR_APT_DIR/sources.list.d" ]; then
        cp -a "$MIRROR_APT_DIR/sources.list.d" "$DEST/sources.list.d" || return 1
        HAD_PARTS=yes
    fi
    printf 'HAD_SOURCES_LIST=%s\nHAD_SOURCES_PARTS=%s\n' "$HAD_LIST" "$HAD_PARTS" > "$DEST/tree.meta" || return 1
}

mirror_apt_snapshot_create() {
    local DEST
    mirror_state_prepare || return 1
    DEST=$(mktemp -d "$MIRROR_STATE_DIR/apt-backup.$(date +%Y%m%d_%H%M%S).XXXXXX") || return 1
    if ! mirror_apt_tree_capture "$DEST"; then
        mirror_safe_remove_dir "$DEST" >/dev/null 2>&1 || true
        return 1
    fi
    chmod -R go-rwx "$DEST" 2>/dev/null || true
    MIRROR_APT_BACKUP="$DEST"
}

mirror_tree_flag() {
    local TREE="$1" KEY="$2"
    sed -n "s/^${KEY}=//p" "$TREE/tree.meta" 2>/dev/null | head -1
}

# 仅改写当前发行版的系统仓库行；Docker/Caddy 等非 main 组件保持不变。
mirror_apt_rewrite_list_file() {
    local SOURCE="$1" DEST="$2" OS_ID="$3" CODENAME="$4" MAIN_URI="$5" SECURITY_URI="$6"
    awk -v os_id="$OS_ID" -v code="$CODENAME" -v main_uri="$MAIN_URI" -v security_uri="$SECURITY_URI" '
        function suite_ok(s) {
            return s == code || s == code "-updates" || s == code "-backports" || s == code "-security" || s == code "-proposed"
        }
        function has_main(start,    i) {
            for (i=start; i<=NF; i++) if ($i == "main") return 1
            return 0
        }
        function is_system_uri(uri, raw,    host) {
            if (os_id == "ubuntu" && raw ~ /signed-by=[^[:space:]]*ubuntu-archive-keyring\.gpg/) return 1
            if (os_id == "debian" && raw ~ /signed-by=[^[:space:]]*debian-archive-keyring\.gpg/) return 1
            host=uri
            sub(/^https?:\/\//, "", host); sub(/\/.*/, "", host); sub(/:.*/, "", host)
            if (os_id == "ubuntu") {
                if (host == "archive.ubuntu.com" || host == "security.ubuntu.com" || host == "ports.ubuntu.com" || host == "old-releases.ubuntu.com" || host ~ /\.archive\.ubuntu\.com$/) return 1
                if (host == "mirrors.aliyun.com" || host == "mirrors.tencent.com" || host == "mirrors.cloud.tencent.com" || host == "mirrors.tuna.tsinghua.edu.cn" || host == "mirrors.ustc.edu.cn") return uri ~ /\/ubuntu(-ports)?\/?$/
            }
            if (os_id == "debian") {
                if (host == "deb.debian.org" || host == "security.debian.org" || host == "ftp.debian.org" || host ~ /\.debian\.org$/) return 1
                if (host == "mirrors.aliyun.com" || host == "mirrors.tencent.com" || host == "mirrors.cloud.tencent.com" || host == "mirrors.tuna.tsinghua.edu.cn" || host == "mirrors.ustc.edu.cn") return uri ~ /\/debian(-security)?\/?$/
            }
            return 0
        }
        {
            if ($0 !~ /^[[:space:]]*deb(-src)?[[:space:]]/) { print; next }
            uri_i=2
            if ($uri_i ~ /^\[/) {
                while (uri_i <= NF && $uri_i !~ /\]$/) uri_i++
                uri_i++
            }
            suite_i=uri_i+1
            if (uri_i > NF || suite_i > NF || !suite_ok($suite_i) || !has_main(suite_i+1) || !is_system_uri($uri_i, $0)) { print; next }
            $uri_i=($suite_i == code "-security" ? security_uri : main_uri)
            print
        }
    ' "$SOURCE" > "$DEST"
}

# Deb822 一个 stanza 可能同时列出多个 suites；安全套件会被拆到官方安全源。
mirror_apt_rewrite_deb822_file() {
    local SOURCE="$1" DEST="$2" OS_ID="$3" CODENAME="$4" MAIN_URI="$5" SECURITY_URI="$6"
    awk -v os_id="$OS_ID" -v code="$CODENAME" -v main_uri="$MAIN_URI" -v security_uri="$SECURITY_URI" '
        BEGIN { RS=""; FS="\n" }
        function is_system_uri(uri, signed_by,    host) {
            if (os_id == "ubuntu" && signed_by ~ /(^|[[:space:]])\/usr\/share\/keyrings\/ubuntu-archive-keyring\.gpg([[:space:]]|$)/) return 1
            if (os_id == "debian" && signed_by ~ /(^|[[:space:]])\/usr\/share\/keyrings\/debian-archive-keyring\.gpg([[:space:]]|$)/) return 1
            host=uri
            sub(/[[:space:]].*/, "", host); sub(/^https?:\/\//, "", host); sub(/\/.*/, "", host); sub(/:.*/, "", host)
            if (os_id == "ubuntu") {
                if (host == "archive.ubuntu.com" || host == "security.ubuntu.com" || host == "ports.ubuntu.com" || host == "old-releases.ubuntu.com" || host ~ /\.archive\.ubuntu\.com$/) return 1
                if (host == "mirrors.aliyun.com" || host == "mirrors.tencent.com" || host == "mirrors.cloud.tencent.com" || host == "mirrors.tuna.tsinghua.edu.cn" || host == "mirrors.ustc.edu.cn") return uri ~ /\/ubuntu(-ports)?\/?([[:space:]]|$)/
            }
            if (os_id == "debian") {
                if (host == "deb.debian.org" || host == "security.debian.org" || host == "ftp.debian.org" || host ~ /\.debian\.org$/) return 1
                if (host == "mirrors.aliyun.com" || host == "mirrors.tencent.com" || host == "mirrors.cloud.tencent.com" || host == "mirrors.tuna.tsinghua.edu.cn" || host == "mirrors.ustc.edu.cn") return uri ~ /\/debian(-security)?\/?([[:space:]]|$)/
            }
            return 0
        }
        function emit(uri, suites,    i, line) {
            for (i=1; i<=NF; i++) {
                line=$i
                if (line ~ /^[[:space:]]*URIs:[[:space:]]*/) line="URIs: " uri
                else if (line ~ /^[[:space:]]*Suites:[[:space:]]*/) line="Suites: " suites
                print line
            }
            print ""
        }
        {
            suites=""; components=""; uri=""; signed_by=""
            for (i=1; i<=NF; i++) {
                line=$i
                if (line ~ /^[[:space:]]*Suites:[[:space:]]*/) { sub(/^[[:space:]]*Suites:[[:space:]]*/, "", line); suites=line }
                else if (line ~ /^[[:space:]]*Components:[[:space:]]*/) { sub(/^[[:space:]]*Components:[[:space:]]*/, "", line); components=line }
                else if (line ~ /^[[:space:]]*URIs:[[:space:]]*/) { sub(/^[[:space:]]*URIs:[[:space:]]*/, "", line); uri=line }
                else if (line ~ /^[[:space:]]*Signed-By:[[:space:]]*/) { sub(/^[[:space:]]*Signed-By:[[:space:]]*/, "", line); signed_by=line }
            }
            if (components !~ /(^|[[:space:]])main([[:space:]]|$)/ || suites == "" || uri == "" || !is_system_uri(uri, signed_by)) { print $0 "\n"; next }
            n=split(suites, suite_values, /[[:space:]]+/)
            main_suites=""; security_suites=""; other_suites=""
            for (i=1; i<=n; i++) {
                s=suite_values[i]
                if (s == code "-security") security_suites=security_suites (security_suites?" ":"") s
                else if (s == code || s == code "-updates" || s == code "-backports" || s == code "-proposed") main_suites=main_suites (main_suites?" ":"") s
                else other_suites=other_suites (other_suites?" ":"") s
            }
            if (other_suites != "" || (main_suites == "" && security_suites == "")) { print $0 "\n"; next }
            if (main_suites != "") emit(main_uri, main_suites)
            if (security_suites != "") emit(security_uri, security_suites)
        }
    ' "$SOURCE" > "$DEST"
}

mirror_apt_tree_has_entries() {
    local TREE="$1" FILE
    for FILE in "$TREE/sources.list" "$TREE/sources.list.d/"*.list; do
        [ -f "$FILE" ] || continue
        grep -Eq '^[[:space:]]*deb(-src)?[[:space:]]' "$FILE" && return 0
    done
    for FILE in "$TREE/sources.list.d/"*.sources; do
        [ -f "$FILE" ] || continue
        grep -Eiq '^[[:space:]]*Types:[[:space:]]*deb([[:space:]]|$)' "$FILE" && return 0
    done
    return 1
}

mirror_files_equal() {
    local LEFT="$1" RIGHT="$2" LEFT_SUM RIGHT_SUM
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$LEFT" "$RIGHT"
        return
    fi
    command -v cksum >/dev/null 2>&1 || return 1
    LEFT_SUM=$(cksum < "$LEFT") || return 1
    RIGHT_SUM=$(cksum < "$RIGHT") || return 1
    [ "$LEFT_SUM" = "$RIGHT_SUM" ]
}

mirror_apt_canonical_sources() {
    local DEST="$1" OS_ID="$2" CODENAME="$3" VERSION_VALUE="$4" MAIN_URI="$5" SECURITY_URI="$6" COMPONENTS KEYRING MAJOR
    case "$OS_ID" in
        ubuntu)
            COMPONENTS="main restricted universe multiverse"
            KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
            ;;
        debian)
            MAJOR=${VERSION_VALUE%%.*}
            if [[ "$MAJOR" =~ ^[0-9]+$ ]] && [ "$MAJOR" -ge 12 ]; then
                COMPONENTS="main contrib non-free non-free-firmware"
            else
                COMPONENTS="main contrib non-free"
            fi
            KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
            ;;
        *) return 1 ;;
    esac
    cat > "$DEST" <<EOF
Types: deb
URIs: ${MAIN_URI}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: ${COMPONENTS}
Signed-By: ${KEYRING}

Types: deb
URIs: ${SECURITY_URI}
Suites: ${CODENAME}-security
Components: ${COMPONENTS}
Signed-By: ${KEYRING}
EOF
}

mirror_apt_stage_create() {
    local MAIN_URI="$1" SECURITY_URI="$2" OS_ID="$3" CODENAME="$4" VERSION_VALUE="$5"
    local STAGE FILE TEMP CHANGED=0
    mirror_state_prepare || return 1
    STAGE=$(mktemp -d "$MIRROR_STATE_DIR/apt-stage.XXXXXX") || return 1
    if ! mirror_apt_tree_capture "$STAGE"; then
        mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true
        return 1
    fi
    for FILE in "$STAGE/sources.list" "$STAGE/sources.list.d/"*.list; do
        [ -f "$FILE" ] || continue
        TEMP="${FILE}.quench-tmp"
        mirror_apt_rewrite_list_file "$FILE" "$TEMP" "$OS_ID" "$CODENAME" "$MAIN_URI" "$SECURITY_URI" || {
            mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true; return 1;
        }
        if mirror_files_equal "$FILE" "$TEMP"; then rm -f "$TEMP"; else mv "$TEMP" "$FILE" && CHANGED=$((CHANGED+1)); fi
    done
    for FILE in "$STAGE/sources.list.d/"*.sources; do
        [ -f "$FILE" ] || continue
        TEMP="${FILE}.quench-tmp"
        mirror_apt_rewrite_deb822_file "$FILE" "$TEMP" "$OS_ID" "$CODENAME" "$MAIN_URI" "$SECURITY_URI" || {
            mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true; return 1;
        }
        if mirror_files_equal "$FILE" "$TEMP"; then rm -f "$TEMP"; else mv "$TEMP" "$FILE" && CHANGED=$((CHANGED+1)); fi
    done
    if [ "$CHANGED" -eq 0 ]; then
        if mirror_apt_tree_has_entries "$STAGE"; then
            mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true
            return 3
        fi
        mkdir -p "$STAGE/sources.list.d" || { mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true; return 1; }
        mirror_apt_canonical_sources "$STAGE/sources.list.d/quench-system.sources" "$OS_ID" "$CODENAME" "$VERSION_VALUE" "$MAIN_URI" "$SECURITY_URI" || {
            mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true; return 1;
        }
        if ! sed -i.bak 's/^HAD_SOURCES_PARTS=.*/HAD_SOURCES_PARTS=yes/' "$STAGE/tree.meta"; then
            mirror_safe_remove_dir "$STAGE" >/dev/null 2>&1 || true
            return 1
        fi
        rm -f "$STAGE/tree.meta.bak"
        CHANGED=1
    fi
    MIRROR_APT_STAGE="$STAGE"
    MIRROR_APT_REWRITE_COUNT="$CHANGED"
}

# 用同一文件系统内的目录移动替换配置；任一步失败都会恢复现场。
mirror_apt_install_tree() {
    local TREE="$1" HAD_LIST HAD_PARTS WORK LIVE MOVED_LIST=no MOVED_PARTS=no
    HAD_LIST=$(mirror_tree_flag "$TREE" HAD_SOURCES_LIST)
    HAD_PARTS=$(mirror_tree_flag "$TREE" HAD_SOURCES_PARTS)
    [ "$HAD_LIST" = yes ] || [ "$HAD_LIST" = no ] || return 1
    [ "$HAD_PARTS" = yes ] || [ "$HAD_PARTS" = no ] || return 1
    mkdir -p "$MIRROR_APT_DIR" || return 1
    WORK=$(mktemp -d "$MIRROR_APT_DIR/.quench-install.XXXXXX") || return 1
    LIVE=$(mktemp -d "$MIRROR_APT_DIR/.quench-live.XXXXXX") || { mirror_safe_remove_dir "$WORK"; return 1; }
    if [ "$HAD_LIST" = yes ]; then cp -a "$TREE/sources.list" "$WORK/sources.list" || { mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1; }; fi
    if [ "$HAD_PARTS" = yes ]; then cp -a "$TREE/sources.list.d" "$WORK/sources.list.d" || { mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1; }; fi

    if [ -e "$MIRROR_APT_DIR/sources.list" ] || [ -L "$MIRROR_APT_DIR/sources.list" ]; then
        mv "$MIRROR_APT_DIR/sources.list" "$LIVE/sources.list" || { mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1; }
        MOVED_LIST=yes
    fi
    if [ -e "$MIRROR_APT_DIR/sources.list.d" ] || [ -L "$MIRROR_APT_DIR/sources.list.d" ]; then
        mv "$MIRROR_APT_DIR/sources.list.d" "$LIVE/sources.list.d" || {
            [ "$MOVED_LIST" = yes ] && mv "$LIVE/sources.list" "$MIRROR_APT_DIR/sources.list" 2>/dev/null || true
            mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1;
        }
        MOVED_PARTS=yes
    fi

    if { [ "$HAD_LIST" = no ] || mv "$WORK/sources.list" "$MIRROR_APT_DIR/sources.list"; } \
        && { [ "$HAD_PARTS" = no ] || mv "$WORK/sources.list.d" "$MIRROR_APT_DIR/sources.list.d"; }; then
        mirror_safe_remove_dir "$WORK" >/dev/null 2>&1 || true
        mirror_safe_remove_dir "$LIVE" >/dev/null 2>&1 || true
        return 0
    fi

    rm -f "$MIRROR_APT_DIR/sources.list"
    [ -e "$MIRROR_APT_DIR/sources.list.d" ] && mv "$MIRROR_APT_DIR/sources.list.d" "$WORK/failed-sources.list.d" 2>/dev/null || true
    [ "$MOVED_LIST" = yes ] && mv "$LIVE/sources.list" "$MIRROR_APT_DIR/sources.list" 2>/dev/null || true
    [ "$MOVED_PARTS" = yes ] && mv "$LIVE/sources.list.d" "$MIRROR_APT_DIR/sources.list.d" 2>/dev/null || true
    mirror_safe_remove_dir "$WORK" >/dev/null 2>&1 || true
    mirror_safe_remove_dir "$LIVE" >/dev/null 2>&1 || true
    return 1
}

mirror_apt_validate() {
    local WORK LOG RC=0
    command -v apt-get >/dev/null 2>&1 || { error "未检测到 apt-get"; return 1; }
    mirror_state_prepare || return 1
    WORK=$(mktemp -d "$MIRROR_STATE_DIR/apt-lists.XXXXXX") || return 1
    mkdir -p "$WORK/lists/partial"
    LOG="$WORK/apt-update.log"
    LC_ALL=C apt-get \
        -o "Dir::Etc::sourcelist=$MIRROR_APT_DIR/sources.list" \
        -o "Dir::Etc::sourceparts=$MIRROR_APT_DIR/sources.list.d" \
        -o "Dir::State::lists=$WORK/lists" \
        -o "Acquire::Retries=0" \
        -o "APT::Update::Error-Mode=any" \
        update >"$LOG" 2>&1 || RC=$?
    if grep -Eq '^(E:|W: Failed to fetch|W: Some index files failed)' "$LOG" 2>/dev/null; then
        RC=1
    fi
    if [ "$RC" -ne 0 ]; then
        tail -20 "$LOG" 2>/dev/null | sed 's/^/  /' >&2
        mirror_safe_remove_dir "$WORK" >/dev/null 2>&1 || true
        return 1
    fi
    mirror_safe_remove_dir "$WORK" >/dev/null 2>&1 || true
    return 0
}

mirror_latest_write() {
    local TYPE="$1" PATH_VALUE="$2" POINTER
    POINTER="$MIRROR_STATE_DIR/latest-${TYPE}-backup"
    case "$PATH_VALUE" in "$MIRROR_STATE_DIR"/*) ;; *) return 1 ;; esac
    printf '%s\n' "$PATH_VALUE" > "$POINTER" || return 1
    chmod 600 "$POINTER" 2>/dev/null || true
}

mirror_latest_read() {
    local TYPE="$1" POINTER PATH_VALUE
    POINTER="$MIRROR_STATE_DIR/latest-${TYPE}-backup"
    [ -f "$POINTER" ] || return 1
    PATH_VALUE=$(head -1 "$POINTER" 2>/dev/null)
    case "$PATH_VALUE" in
        */../*|*/..) return 1 ;;
        "$MIRROR_STATE_DIR"/*) [ -d "$PATH_VALUE" ] || return 1 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$PATH_VALUE"
}

mirror_apply_apt() {
    local KEY="$1" OS_ID VERSION_VALUE CODENAME ARCH_VALUE CANDIDATE MAIN_URI MIRROR_SECURITY LABEL SECURITY_URI OFFICIAL_SECURITY RC
    OS_ID=$(mirror_os_release_value ID 2>/dev/null || true)
    VERSION_VALUE=$(mirror_os_release_value VERSION_ID 2>/dev/null || true)
    CODENAME=$(mirror_codename 2>/dev/null || true)
    ARCH_VALUE=$(mirror_arch)
    [[ "$OS_ID" = ubuntu || "$OS_ID" = debian ]] || { error "当前系统不支持 APT 软件源管理"; return 1; }
    [ -n "$CODENAME" ] || { error "无法获得可信的发行版代号，拒绝修改软件源"; return 1; }
    CANDIDATE=$(mirror_apt_candidate "$OS_ID" "$KEY" "$ARCH_VALUE") || { error "当前架构不支持所选软件源"; return 1; }
    IFS='|' read -r MAIN_URI MIRROR_SECURITY LABEL <<< "$CANDIDATE"
    OFFICIAL_SECURITY=$(mirror_apt_official_security "$OS_ID" "$ARCH_VALUE") || return 1
    if [ "$MIRROR_SECURITY_POLICY" = mirror ]; then SECURITY_URI="$MIRROR_SECURITY"; else SECURITY_URI="$OFFICIAL_SECURITY"; fi

    confirm_change_preview "切换软件源" \
        "系统：${OS_ID} ${VERSION_VALUE} (${CODENAME})" \
        "架构：${ARCH_VALUE}" \
        "主仓库：${LABEL} · ${MAIN_URI}" \
        "安全更新：${SECURITY_URI}" \
        "保留第三方仓库与现有 list / Deb822 结构" \
        "失败时恢复完整软件源快照" || return 1

    info "正在检查主仓库和安全仓库的 InRelease..."
    if mirror_apt_probe_candidate "$MAIN_URI" "$SECURITY_URI" "$CODENAME"; then
        info "候选软件源可访问 ✓"
    else
        RC=$?
        if [ "$RC" -eq 2 ]; then
            warn "缺少 curl/wget，跳过预检；仍会用 APT 独立索引严格验证"
        else
            error "候选软件源不可访问或当前版本已不在该镜像中"
            return 1
        fi
    fi

    RC=0
    mirror_apt_stage_create "$MAIN_URI" "$SECURITY_URI" "$OS_ID" "$CODENAME" "$VERSION_VALUE" || RC=$?
    if [ "$RC" -ne 0 ]; then
        if [ "$RC" -eq 3 ]; then
            error "未识别出可安全改写的发行版系统源；为避免误改第三方仓库，已取消操作"
        else
            error "无法生成软件源暂存配置"
        fi
        return 1
    fi
    info "已识别并暂存 ${MIRROR_APT_REWRITE_COUNT} 个系统源配置文件"
    mirror_apt_snapshot_create || {
        mirror_safe_remove_dir "$MIRROR_APT_STAGE" >/dev/null 2>&1 || true
        error "软件源完整备份失败，未修改任何配置"
        return 1
    }
    if ! mirror_apt_install_tree "$MIRROR_APT_STAGE"; then
        mirror_safe_remove_dir "$MIRROR_APT_STAGE" >/dev/null 2>&1 || true
        error "软件源配置替换失败，原配置保持不变"
        return 1
    fi
    mirror_safe_remove_dir "$MIRROR_APT_STAGE" >/dev/null 2>&1 || true

    info "使用独立索引目录验证签名与全部仓库..."
    if ! mirror_apt_validate; then
        error "新软件源验证失败，正在恢复原配置"
        mirror_apt_install_tree "$MIRROR_APT_BACKUP" || error "自动恢复失败，请从 $MIRROR_APT_BACKUP 手动恢复"
        return 1
    fi
    mirror_latest_write apt "$MIRROR_APT_BACKUP" || warn "无法记录最近备份位置：$MIRROR_APT_BACKUP"
    {
        echo "OS=$OS_ID"
        echo "VERSION=$VERSION_VALUE"
        echo "CODENAME=$CODENAME"
        echo "ARCH=$ARCH_VALUE"
        echo "LABEL=$LABEL"
        echo "MAIN_URI=$MAIN_URI"
        echo "SECURITY_URI=$SECURITY_URI"
    } > "$MIRROR_STATE_DIR/apt-current"
    chmod 600 "$MIRROR_STATE_DIR/apt-current" 2>/dev/null || true
    audit_action "APT 软件源切换为 ${LABEL}，安全源 $SECURITY_URI" SUCCESS
    info "软件源切换完成并通过签名/索引验证 ✓"
    info "恢复点：$MIRROR_APT_BACKUP"
}

mirror_restore_apt() {
    local TARGET CURRENT
    TARGET=$(mirror_latest_read apt 2>/dev/null || true)
    [ -n "$TARGET" ] || { warn "没有可恢复的 APT 软件源快照"; return 1; }
    confirm_change_preview "恢复上一次 APT 软件源" \
        "恢复点：$TARGET" \
        "当前配置也会先建立快照" \
        "恢复后重新执行严格 apt update 验证" || return 1
    mirror_apt_snapshot_create || { error "当前配置备份失败，已取消恢复"; return 1; }
    CURRENT="$MIRROR_APT_BACKUP"
    mirror_apt_install_tree "$TARGET" || { error "恢复快照失败，当前配置保持不变"; return 1; }
    if ! mirror_apt_validate; then
        error "恢复后的软件源不可用，正在撤销恢复"
        mirror_apt_install_tree "$CURRENT" || error "撤销恢复失败，请检查 $CURRENT"
        return 1
    fi
    mirror_latest_write apt "$CURRENT" || true
    audit_action "恢复 APT 软件源快照 $(basename "$TARGET")" SUCCESS
    info "APT 软件源已恢复；可再次选择恢复撤销本次操作 ✓"
}

mirror_test_apt_candidates() {
    local OS_ID CODENAME ARCH_VALUE KEY DATA MAIN_URI MIRROR_SECURITY LABEL SECURITY_URI RC
    OS_ID=$(mirror_os_release_value ID 2>/dev/null || true)
    CODENAME=$(mirror_codename 2>/dev/null || true)
    ARCH_VALUE=$(mirror_arch)
    [ -n "$CODENAME" ] || { error "无法识别发行版代号"; return 1; }
    print_header "候选 APT 软件源健康检查"
    for KEY in aliyun tencent tuna ustc official; do
        DATA=$(mirror_apt_candidate "$OS_ID" "$KEY" "$ARCH_VALUE" 2>/dev/null) || continue
        IFS='|' read -r MAIN_URI MIRROR_SECURITY LABEL <<< "$DATA"
        if [ "$MIRROR_SECURITY_POLICY" = mirror ]; then SECURITY_URI="$MIRROR_SECURITY"; else SECURITY_URI=$(mirror_apt_official_security "$OS_ID" "$ARCH_VALUE"); fi
        if mirror_apt_probe_candidate "$MAIN_URI" "$SECURITY_URI" "$CODENAME"; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${LABEL}${NC}  ${DIM}${MAIN_URI}${NC}"
        else
            RC=$?
            [ "$RC" -eq 2 ] && { warn "需要 curl 或 wget 才能执行候选源检查"; return 1; }
            echo -e "  ${RED}●${NC} ${LABEL}  ${DIM}不可用或缺少当前版本${NC}"
        fi
    done
}

mirror_security_policy_toggle() {
    if [ "$MIRROR_SECURITY_POLICY" = official ]; then
        confirm_change_preview "使用镜像站安全更新源" \
            "第三方镜像同步可能延迟安全更新" \
            "只建议官方安全源确实无法访问时临时启用" \
            "下一次进入软件源菜单会恢复默认的官方策略" || return 1
        MIRROR_SECURITY_POLICY=mirror
        warn "本次菜单会将 security 套件切到所选镜像"
    else
        MIRROR_SECURITY_POLICY=official
        info "已恢复官方 security 源策略"
    fi
}

mirror_rpm_candidate() {
    local OS_ID="$1" KEY="$2"
    case "$OS_ID:$KEY" in
        rocky:aliyun) echo "https://mirrors.aliyun.com/rockylinux|阿里云" ;;
        almalinux:aliyun) echo "https://mirrors.aliyun.com/almalinux|阿里云" ;;
        centos:aliyun) echo "https://mirrors.aliyun.com/centos-stream|阿里云" ;;
        centos:tuna) echo "https://mirrors.tuna.tsinghua.edu.cn/centos-stream|清华 TUNA" ;;
        *) return 1 ;;
    esac
}

mirror_first_existing_file() {
    local FILE
    for FILE in "$@"; do [ -f "$FILE" ] && { printf '%s\n' "$FILE"; return 0; }; done
    return 1
}

mirror_rpm_gpgkey() {
    local OS_ID="$1" MAJOR="$2" FILE
    case "$OS_ID" in
        rocky) FILE=$(mirror_first_existing_file "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-Rocky-${MAJOR}" "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-rockyofficial") || return 1 ;;
        almalinux) FILE=$(mirror_first_existing_file "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-AlmaLinux-${MAJOR}" "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-AlmaLinux") || return 1 ;;
        centos) FILE=$(mirror_first_existing_file "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-centosofficial" "$MIRROR_RPM_GPG_DIR/RPM-GPG-KEY-CentOS-Official") || return 1 ;;
        *) return 1 ;;
    esac
    printf 'file://%s\n' "$FILE"
}

mirror_rpm_repo_render() {
    local OS_ID="$1" MAJOR="$2" BASE="$3" LABEL="$4" GPGKEY="$5" PREFIX CRB_PATH
    if [ "$OS_ID" = centos ]; then PREFIX="${MAJOR}-stream"; else PREFIX="$MAJOR"; fi
    if [ "$MAJOR" = 8 ]; then CRB_PATH=PowerTools; else CRB_PATH=CRB; fi
    cat <<EOF
[quench-baseos]
name=${LABEL} - BaseOS
baseurl=${BASE}/${PREFIX}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}

[quench-appstream]
name=${LABEL} - AppStream
baseurl=${BASE}/${PREFIX}/AppStream/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}

[quench-crb]
name=${LABEL} - ${CRB_PATH}
baseurl=${BASE}/${PREFIX}/${CRB_PATH}/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
EOF
    if [ "$OS_ID" = centos ]; then
        cat <<EOF

[quench-extras-common]
name=${LABEL} - Extras Common
baseurl=${BASE}/SIGs/${PREFIX}/extras/\$basearch/extras-common/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
EOF
    else
        cat <<EOF

[quench-extras]
name=${LABEL} - Extras
baseurl=${BASE}/${PREFIX}/extras/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
EOF
    fi
}

mirror_rpm_enabled_ids() {
    local OUTPUT
    OUTPUT=$(LC_ALL=C dnf repolist --enabled 2>/dev/null) || return 1
    printf '%s\n' "$OUTPUT" | awk '
        /^[[:space:]]*repo id[[:space:]]/ {header=1; next}
        header && NF && $1 !~ /^Last/ {print $1}
        END {exit !header}
    '
}

mirror_rpm_snapshot_create() {
    local DEST
    mirror_state_prepare || return 1
    DEST=$(mktemp -d "$MIRROR_STATE_DIR/rpm-backup.$(date +%Y%m%d_%H%M%S).XXXXXX") || return 1
    mkdir -p "$DEST/repos" || { mirror_safe_remove_dir "$DEST"; return 1; }
    if [ -d "$MIRROR_RPM_REPO_DIR" ]; then
        cp -a "$MIRROR_RPM_REPO_DIR/." "$DEST/repos/" || { mirror_safe_remove_dir "$DEST"; return 1; }
        echo yes > "$DEST/had-repo-dir"
    else
        echo no > "$DEST/had-repo-dir"
    fi
    if ! mirror_rpm_enabled_ids > "$DEST/enabled-ids" 2>/dev/null; then
        mirror_safe_remove_dir "$DEST"
        return 1
    fi
    chmod -R go-rwx "$DEST" 2>/dev/null || true
    MIRROR_RPM_BACKUP="$DEST"
}

mirror_rpm_restore_snapshot() {
    local SNAPSHOT="$1" PARENT WORK LIVE HAD
    case "$SNAPSHOT" in "$MIRROR_STATE_DIR"/*) ;; *) return 1 ;; esac
    HAD=$(cat "$SNAPSHOT/had-repo-dir" 2>/dev/null)
    [ "$HAD" = yes ] || [ "$HAD" = no ] || return 1
    PARENT=$(dirname "$MIRROR_RPM_REPO_DIR")
    mkdir -p "$PARENT" || return 1
    WORK=$(mktemp -d "$PARENT/.quench-rpm-install.XXXXXX") || return 1
    LIVE=$(mktemp -d "$PARENT/.quench-rpm-live.XXXXXX") || { mirror_safe_remove_dir "$WORK"; return 1; }
    [ "$HAD" = no ] || cp -a "$SNAPSHOT/repos" "$WORK/repos" || { mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1; }
    if [ -e "$MIRROR_RPM_REPO_DIR" ]; then mv "$MIRROR_RPM_REPO_DIR" "$LIVE/repos" || { mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1; }; fi
    if [ "$HAD" = yes ] && ! mv "$WORK/repos" "$MIRROR_RPM_REPO_DIR"; then
        [ -e "$LIVE/repos" ] && mv "$LIVE/repos" "$MIRROR_RPM_REPO_DIR" 2>/dev/null || true
        mirror_safe_remove_dir "$WORK"; mirror_safe_remove_dir "$LIVE"; return 1
    fi
    mirror_safe_remove_dir "$WORK" >/dev/null 2>&1 || true
    mirror_safe_remove_dir "$LIVE" >/dev/null 2>&1 || true
}

mirror_rpm_core_id() {
    case "$1" in baseos|appstream|crb|powertools|extras|extras-common) return 0 ;; *) return 1 ;; esac
}

mirror_apply_rpm() {
    local KEY="$1" OS_ID VERSION_VALUE MAJOR ARCH_VALUE DATA BASE LABEL GPGKEY PREFIX PROBE_URL RC RID
    OS_ID=$(mirror_os_release_value ID 2>/dev/null || true)
    VERSION_VALUE=$(mirror_os_release_value VERSION_ID 2>/dev/null || true)
    MAJOR=${VERSION_VALUE%%.*}
    ARCH_VALUE=$(mirror_rpm_basearch)
    [[ "$OS_ID" = rocky || "$OS_ID" = almalinux || "$OS_ID" = centos ]] || { error "当前 RPM 发行版不支持自动换源"; return 1; }
    [[ "$MAJOR" =~ ^(8|9|10)$ ]] || { error "暂不支持 ${OS_ID} ${VERSION_VALUE}，拒绝猜测仓库路径"; return 1; }
    if [ "$OS_ID" = centos ] && [ "$MAJOR" = 8 ]; then
        error "CentOS Stream 8 已结束维护，当前镜像不再提供完整仓库；拒绝写入失效路径"
        return 1
    fi
    DATA=$(mirror_rpm_candidate "$OS_ID" "$KEY") || return 1
    IFS='|' read -r BASE LABEL <<< "$DATA"
    GPGKEY=$(mirror_rpm_gpgkey "$OS_ID" "$MAJOR" 2>/dev/null || true)
    [ -n "$GPGKEY" ] || { error "找不到发行版自带的 RPM GPG 公钥，拒绝换源"; return 1; }
    [ "$OS_ID" = centos ] && PREFIX="${MAJOR}-stream" || PREFIX="$MAJOR"
    PROBE_URL="${BASE}/${PREFIX}/BaseOS/${ARCH_VALUE}/os/repodata/repomd.xml"

    confirm_change_preview "切换 RPM 软件源" \
        "系统：${OS_ID} ${VERSION_VALUE}" \
        "架构：${ARCH_VALUE}" \
        "主仓库：${LABEL} · ${BASE}" \
        "GPG 校验保持开启：${GPGKEY}" \
        "记录完整 repo 文件和真实启用状态" \
        "只在新仓库独立验证成功后禁用原核心仓库" || return 1

    if mirror_url_probe "$PROBE_URL"; then info "候选 RPM 元数据可访问 ✓"; else
        RC=$?; [ "$RC" -eq 2 ] && warn "缺少 curl/wget，跳过 HTTP 预检" || { error "候选 RPM 仓库不可访问"; return 1; }
    fi
    command -v dnf >/dev/null 2>&1 || { error "当前系统缺少 dnf"; return 1; }
    if ! dnf config-manager --help >/dev/null 2>&1; then
        dnf install -y dnf-plugins-core >/dev/null 2>&1 || { error "无法安装 dnf config-manager"; return 1; }
    fi
    mirror_rpm_snapshot_create || { error "RPM 仓库完整备份失败，未修改配置"; return 1; }
    mkdir -p "$MIRROR_RPM_REPO_DIR" || return 1
    if ! mirror_rpm_repo_render "$OS_ID" "$MAJOR" "$BASE" "$LABEL" "$GPGKEY" > "$MIRROR_RPM_REPO_DIR/.quench-base.repo.tmp" \
        || ! mv "$MIRROR_RPM_REPO_DIR/.quench-base.repo.tmp" "$MIRROR_RPM_REPO_DIR/quench-base.repo"; then
        mirror_rpm_restore_snapshot "$MIRROR_RPM_BACKUP" || true
        error "生成 RPM 仓库配置失败，已恢复"
        return 1
    fi
    if ! dnf --disablerepo='*' --enablerepo='quench-*' makecache --refresh -q; then
        mirror_rpm_restore_snapshot "$MIRROR_RPM_BACKUP" || error "RPM 仓库自动恢复失败：$MIRROR_RPM_BACKUP"
        error "新 RPM 仓库独立验证失败，已恢复原配置"
        return 1
    fi
    while IFS= read -r RID; do
        mirror_rpm_core_id "$RID" || continue
        if ! dnf config-manager --set-disabled "$RID" >/dev/null 2>&1; then
            mirror_rpm_restore_snapshot "$MIRROR_RPM_BACKUP" || error "RPM 仓库自动恢复失败：$MIRROR_RPM_BACKUP"
            error "无法禁用原仓库 ${RID}，已恢复原配置"
            return 1
        fi
    done < "$MIRROR_RPM_BACKUP/enabled-ids"
    mirror_latest_write rpm "$MIRROR_RPM_BACKUP" || warn "无法记录最近 RPM 备份"
    if ! dnf makecache --refresh -q; then warn "Quench 核心仓库已验证，但其他第三方 RPM 仓库仍有错误，请单独检查"; fi
    audit_action "RPM 软件源切换为 $LABEL" SUCCESS
    info "RPM 软件源切换完成，GPG 校验保持开启 ✓"
    info "恢复点：$MIRROR_RPM_BACKUP"
}

mirror_restore_rpm() {
    local TARGET CURRENT
    TARGET=$(mirror_latest_read rpm 2>/dev/null || true)
    [ -n "$TARGET" ] || { warn "没有可恢复的 RPM 软件源快照"; return 1; }
    confirm_change_preview "恢复上一次 RPM 软件源" \
        "恢复点：$TARGET" \
        "将精确恢复 repo 文件及启用状态" \
        "当前状态会先建立快照" || return 1
    mirror_rpm_snapshot_create || { error "当前 RPM 配置备份失败"; return 1; }
    CURRENT="$MIRROR_RPM_BACKUP"
    mirror_rpm_restore_snapshot "$TARGET" || { error "RPM 快照恢复失败"; return 1; }
    if ! dnf makecache --refresh -q; then
        error "恢复后的 RPM 源不可用，正在撤销恢复"
        mirror_rpm_restore_snapshot "$CURRENT" || error "撤销失败，请检查 $CURRENT"
        return 1
    fi
    mirror_latest_write rpm "$CURRENT" || true
    audit_action "恢复 RPM 软件源快照 $(basename "$TARGET")" SUCCESS
    info "RPM 软件源已恢复；可再次选择恢复撤销本次操作 ✓"
}

mirror_test_rpm_candidates() {
    local OS_ID VERSION_VALUE MAJOR ARCH_VALUE KEY DATA BASE LABEL PREFIX URL RC
    OS_ID=$(mirror_os_release_value ID 2>/dev/null || true)
    VERSION_VALUE=$(mirror_os_release_value VERSION_ID 2>/dev/null || true)
    MAJOR=${VERSION_VALUE%%.*}; ARCH_VALUE=$(mirror_rpm_basearch)
    [ "$OS_ID" = centos ] && PREFIX="${MAJOR}-stream" || PREFIX="$MAJOR"
    print_header "候选 RPM 软件源健康检查"
    for KEY in aliyun tuna; do
        DATA=$(mirror_rpm_candidate "$OS_ID" "$KEY" 2>/dev/null) || continue
        IFS='|' read -r BASE LABEL <<< "$DATA"
        URL="${BASE}/${PREFIX}/BaseOS/${ARCH_VALUE}/os/repodata/repomd.xml"
        if mirror_url_probe "$URL"; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${LABEL}${NC}  ${DIM}${BASE}${NC}"
        else
            RC=$?; [ "$RC" -eq 2 ] && { warn "需要 curl 或 wget 才能执行检查"; return 1; }
            echo -e "  ${RED}●${NC} ${LABEL}  ${DIM}不可用或缺少当前版本/架构${NC}"
        fi
    done
}

mirror_menu() {
    local OS_INFO OS_ID OS_VER ARCH_VALUE CODENAME FORMAT CH CURRENT_URI
    MIRROR_SECURITY_POLICY=official
    while true; do
        OS_INFO=$(detect_os); OS_ID=${OS_INFO%%:*}; OS_VER=${OS_INFO#*:}
        ARCH_VALUE=$(mirror_arch); CODENAME=$(mirror_codename 2>/dev/null || echo unknown)
        print_header "软件源管理"
        echo -e "  系统：${BOLD}${OS_ID} ${OS_VER}${NC}   架构：${BOLD}${ARCH_VALUE}${NC}   代号：${BOLD}${CODENAME}${NC}"
        echo ""
        case "$OS_ID" in
            ubuntu|debian)
                FORMAT=$(mirror_apt_format)
                echo -e "  配置格式：${BOLD}${FORMAT}${NC}"
                echo -e "  安全更新：${BOLD}$([ "$MIRROR_SECURITY_POLICY" = official ] && echo '官方源（推荐）' || echo '随所选镜像')${NC}"
                echo -e "  当前启用的仓库："
                CURRENT_URI=$(mirror_apt_current_uris)
                if [ -n "$CURRENT_URI" ]; then while IFS= read -r LINE; do echo -e "    ${DIM}${LINE}${NC}"; done <<< "$CURRENT_URI"; else echo -e "    ${DIM}未识别${NC}"; fi
                menu_div
                menu_pair "1" "阿里云" "2" "腾讯云"
                menu_pair "3" "清华 TUNA" "4" "中科大 USTC"
                menu_item "5" "$([ "$OS_ID" = ubuntu ] && echo Ubuntu || echo Debian) 官方源"
                menu_pair "6" "测试全部候选源" "7" "恢复上一次配置" "$CYAN" "$YELLOW"
                menu_item "p" "切换安全源策略" "$YELLOW"
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-7 / p]: ')" CH
                case "$CH" in
                    1) mirror_apply_apt aliyun ;;
                    2) mirror_apply_apt tencent ;;
                    3) mirror_apply_apt tuna ;;
                    4) mirror_apply_apt ustc ;;
                    5) mirror_apply_apt official ;;
                    6) mirror_test_apt_candidates ;;
                    7) mirror_restore_apt ;;
                    p|P) mirror_security_policy_toggle; continue ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            rocky|almalinux)
                ARCH_VALUE=$(mirror_rpm_basearch)
                echo -e "  RPM 架构：${BOLD}${ARCH_VALUE}${NC}"
                echo -e "  当前启用的仓库 ID：${DIM}$(mirror_rpm_enabled_ids | tr '\n' ' ')${NC}"
                menu_div
                menu_item "1" "阿里云"
                menu_pair "2" "测试全部候选源" "3" "恢复上一次配置" "$CYAN" "$YELLOW"
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-3]: ')" CH
                case "$CH" in
                    1) mirror_apply_rpm aliyun ;;
                    2) mirror_test_rpm_candidates ;;
                    3) mirror_restore_rpm ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            centos)
                ARCH_VALUE=$(mirror_rpm_basearch)
                echo -e "  RPM 架构：${BOLD}${ARCH_VALUE}${NC}"
                echo -e "  当前启用的仓库 ID：${DIM}$(mirror_rpm_enabled_ids | tr '\n' ' ')${NC}"
                menu_div
                menu_pair "1" "阿里云" "2" "清华 TUNA"
                menu_pair "3" "测试全部候选源" "4" "恢复上一次配置" "$CYAN" "$YELLOW"
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div; echo ""
                read -rp "$(ui_prompt '选择操作 [0-4]: ')" CH
                case "$CH" in
                    1) mirror_apply_rpm aliyun ;;
                    2) mirror_apply_rpm tuna ;;
                    3) mirror_test_rpm_candidates ;;
                    4) mirror_restore_rpm ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            rhel)
                warn "RHEL 订阅仓库不支持自动替换，请使用 subscription-manager"
                ui_pause; return
                ;;
            *)
                warn "暂不支持自动管理 ${OS_ID} ${OS_VER} 的软件源"
                ui_hint "Quench 不会猜测 Alpine/OpenWrt 或厂商定制 feeds 的路径"
                ui_pause; return
                ;;
        esac
        ui_pause
    done
}
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
# ══════════════════════════════════════════════════════════
#  Caddy 轻量网站入口管理
# ══════════════════════════════════════════════════════════

CADDYFILE="${QUENCH_CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_CONFIG_DIR="${QUENCH_CADDY_CONFIG_DIR:-$(dirname "$CADDYFILE")}"
CADDY_SITES_DIR="${QUENCH_CADDY_SITES_DIR:-$CADDY_CONFIG_DIR/sites.d}"
CADDY_DATA_DIR="${QUENCH_CADDY_DATA_DIR:-/var/lib/caddy}"
CADDY_LOG_DIR="${QUENCH_CADDY_LOG_DIR:-/var/log/caddy}"
CADDY_STATE_DIR="${QUENCH_CADDY_STATE_DIR:-$QUENCH_DATA_DIR/caddy}"
CADDY_INSTALL_METHOD_FILE="$CADDY_STATE_DIR/install-method"
CADDY_LOCK_DIR="$CADDY_STATE_DIR/config.lock"
CADDY_SERVICE_FILE="${QUENCH_CADDY_SERVICE_FILE:-/etc/systemd/system/caddy.service}"
CADDY_IMPORT_BEGIN="# BEGIN QUENCH CADDY SITE IMPORT"
CADDY_IMPORT_END="# END QUENCH CADDY SITE IMPORT"
CADDY_SITE_MARKER="# Managed by Quench: Caddy site"
CADDY_RELEASE_API="https://api.github.com/repos/caddyserver/caddy/releases/latest"
CADDY_LAST_ERROR=""
CADDY_FIREWALL_TYPE=""
CADDY_FIREWALL_ZONE=""
CADDY_FIREWALL_ADDED_RULES=()

caddy_status() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo not_installed
    elif caddy_service_active; then
        echo running
    elif command -v pgrep >/dev/null 2>&1 && pgrep -x caddy >/dev/null 2>&1; then
        echo unmanaged
    else
        echo stopped
    fi
}

caddy_service_available() {
    if systemd_available; then
        systemctl cat caddy >/dev/null 2>&1
    else
        [ -x /etc/init.d/caddy ] || [ -x /etc/rc.d/caddy ]
    fi
}

caddy_service_active() {
    if ! systemd_available && ! command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy status >/dev/null 2>&1
    else
        svc_is_active caddy
    fi
}

caddy_service_enable() {
    if ! systemd_available && ! command -v rc-update >/dev/null 2>&1 \
        && ! command -v update-rc.d >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy enable >/dev/null 2>&1
    else
        svc_enable caddy
    fi
}

caddy_service_disable() {
    if ! systemd_available && ! command -v rc-update >/dev/null 2>&1 \
        && ! command -v update-rc.d >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy disable >/dev/null 2>&1
    else
        svc_disable caddy
    fi
}

caddy_service_start() {
    if ! systemd_available && ! command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy start >/dev/null 2>&1
    else
        svc_start caddy
    fi
}

caddy_service_stop() {
    if ! systemd_available && ! command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy stop >/dev/null 2>&1
    else
        svc_stop caddy
    fi
}

caddy_service_restart() {
    if ! systemd_available && ! command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/caddy ]; then
        /etc/init.d/caddy restart >/dev/null 2>&1
    else
        svc_restart caddy
    fi
}

caddy_state_prepare() {
    mkdir -p "$CADDY_STATE_DIR" || return 1
    chmod 700 "$CADDY_STATE_DIR" 2>/dev/null || true
}

caddy_lock_acquire() {
    local PID
    caddy_state_prepare || return 1
    if mkdir "$CADDY_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$CADDY_LOCK_DIR/pid"
        return 0
    fi
    PID=$(cat "$CADDY_LOCK_DIR/pid" 2>/dev/null || true)
    if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
        error "另一项 Caddy 配置操作正在执行（PID ${PID}）"
        return 1
    fi
    rmdir "$CADDY_LOCK_DIR" 2>/dev/null || {
        error "Caddy 配置锁异常：$CADDY_LOCK_DIR"
        return 1
    }
    mkdir "$CADDY_LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$CADDY_LOCK_DIR/pid"
}

caddy_lock_release() {
    rm -f "$CADDY_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$CADDY_LOCK_DIR" 2>/dev/null || true
}

caddy_sha256() {
    local FILE="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$FILE" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$FILE" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$FILE" | awk '{print $NF}'
    else
        return 1
    fi
}

caddy_sha512() {
    local FILE="$1"
    if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$FILE" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 512 "$FILE" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha512 "$FILE" | awk '{print $NF}'
    else
        return 1
    fi
}

caddy_release_checksum_verify() {
    local FILE="$1" CHECKSUM_FILE="$2" ARCHIVE="$3" EXPECTED ACTUAL EXPECTED_LOWER ACTUAL_LOWER
    EXPECTED=$(awk -v name="$ARCHIVE" '$2 == name || $2 == "*" name {print $1}' "$CHECKSUM_FILE")
    [ "$(printf '%s\n' "$EXPECTED" | awk 'NF {count++} END {print count+0}')" -eq 1 ] || return 1
    [[ "$EXPECTED" =~ ^[0-9a-fA-F]+$ ]] || return 1
    case "${#EXPECTED}" in
        128) ACTUAL=$(caddy_sha512 "$FILE") || return 1 ;;
        64) ACTUAL=$(caddy_sha256 "$FILE") || return 1 ;;
        *) return 1 ;;
    esac
    EXPECTED_LOWER=$(printf '%s' "$EXPECTED" | tr 'A-F' 'a-f')
    ACTUAL_LOWER=$(printf '%s' "$ACTUAL" | tr 'A-F' 'a-f')
    [ "$EXPECTED_LOWER" = "$ACTUAL_LOWER" ]
}

caddy_release_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv5l|armv5) echo armv5 ;;
        armv6l|armv6) echo armv6 ;;
        armv7l|armv7) echo armv7 ;;
        ppc64le) echo ppc64le ;;
        riscv64) echo riscv64 ;;
        s390x) echo s390x ;;
        *) return 1 ;;
    esac
}

caddy_latest_release() {
    local RESPONSE VERSION
    RESPONSE=$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 "$CADDY_RELEASE_API") || return 1
    VERSION=$(printf '%s\n' "$RESPONSE" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' | head -1)
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$VERSION"
}

caddy_binary_service_install() {
    local CADDY_BIN="$1" STAGE NOLOGIN
    systemd_available || {
        error "通用二进制回退只支持 systemd；当前系统请使用发行版 Caddy 软件包"
        return 1
    }
    if [ -e "$CADDY_SERVICE_FILE" ] && ! grep -Fqx '# Managed by Quench: Caddy service' "$CADDY_SERVICE_FILE"; then
        if systemctl cat caddy >/dev/null 2>&1; then
            warn "检测到现有 Caddy systemd 服务，Quench 不会覆盖"
            return 0
        fi
        error "$CADDY_SERVICE_FILE 已存在且不受 Quench 管理"
        return 1
    fi
    getent group caddy >/dev/null 2>&1 || groupadd --system caddy || return 1
    if ! id caddy >/dev/null 2>&1; then
        NOLOGIN=$(command -v nologin 2>/dev/null || true)
        [ -n "$NOLOGIN" ] || NOLOGIN=/usr/sbin/nologin
        useradd --system --gid caddy --create-home --home-dir "$CADDY_DATA_DIR" \
            --shell "$NOLOGIN" --comment 'Caddy web server' caddy || return 1
    fi
    mkdir -p "$CADDY_DATA_DIR" "$CADDY_LOG_DIR" || return 1
    chown caddy:caddy "$CADDY_DATA_DIR" "$CADDY_LOG_DIR" || return 1
    chmod 750 "$CADDY_DATA_DIR" "$CADDY_LOG_DIR" 2>/dev/null || true
    STAGE=$(mktemp "${CADDY_SERVICE_FILE}.tmp.XXXXXX") || return 1
    cat > "$STAGE" <<EOF
# Managed by Quench: Caddy service
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=$CADDY_DATA_DIR/.local/share
Environment=XDG_CONFIG_HOME=$CADDY_DATA_DIR/.config
ExecStart=$CADDY_BIN run --environ --config $CADDYFILE --adapter caddyfile
ExecReload=$CADDY_BIN reload --force --config $CADDYFILE --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ReadWritePaths=$CADDY_DATA_DIR $CADDY_LOG_DIR

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$STAGE"
    mv "$STAGE" "$CADDY_SERVICE_FILE" || { rm -f "$STAGE"; return 1; }
    svc_daemon_reload
}

caddy_install_binary() {
    local ARCH VERSION PLAIN ARCHIVE CHECKSUMS BASE TMP CADDY_BIN
    info "从 Caddy 官方 GitHub Release 下载并校验二进制..."
    ARCH=$(caddy_release_arch) || { error "不支持的架构：$(uname -m)"; return 1; }
    VERSION="${QUENCH_CADDY_VERSION:-}"
    [ -n "$VERSION" ] || VERSION=$(caddy_latest_release) \
        || { error "无法解析 Caddy 最新稳定版本"; return 1; }
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || { error "Caddy 版本格式不安全：$VERSION"; return 1; }
    PLAIN=${VERSION#v}
    ARCHIVE="caddy_${PLAIN}_linux_${ARCH}.tar.gz"
    CHECKSUMS="caddy_${PLAIN}_checksums.txt"
    BASE="https://github.com/caddyserver/caddy/releases/download/$VERSION"
    TMP=$(quench_mktemp_d) || return 1
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 2 --max-time 120 "$BASE/$ARCHIVE" -o "$TMP/$ARCHIVE" \
        || ! curl --proto '=https' --tlsv1.2 -fL --retry 2 --max-time 30 "$BASE/$CHECKSUMS" -o "$TMP/$CHECKSUMS"; then
        rm -rf "$TMP"
        error "Caddy Release 或校验文件下载失败"
        return 1
    fi
    caddy_release_checksum_verify "$TMP/$ARCHIVE" "$TMP/$CHECKSUMS" "$ARCHIVE" || {
        rm -rf "$TMP"
        error "Caddy Release 官方 checksum 校验失败或系统缺少对应哈希工具"
        return 1
    }
    tar -tzf "$TMP/$ARCHIVE" 2>/dev/null | grep -qx 'caddy' \
        || { rm -rf "$TMP"; error "Caddy Release 未包含预期的 caddy 入口"; return 1; }
    tar -xzf "$TMP/$ARCHIVE" -C "$TMP" caddy \
        || { rm -rf "$TMP"; error "Caddy Release 解压失败"; return 1; }
    chmod 755 "$TMP/caddy"
    "$TMP/caddy" version 2>/dev/null | grep -Fq "$PLAIN" \
        || { rm -rf "$TMP"; error "Caddy 二进制版本与 Release 不一致"; return 1; }
    install -m 755 "$TMP/caddy" /usr/local/bin/caddy \
        || { rm -rf "$TMP"; error "Caddy 二进制安装失败"; return 1; }
    rm -rf "$TMP"
    CADDY_BIN=/usr/local/bin/caddy
    caddy_binary_service_install "$CADDY_BIN" || return 1
    caddy_state_prepare || return 1
    printf 'binary\n' > "$CADDY_INSTALL_METHOD_FILE"
    chmod 600 "$CADDY_INSTALL_METHOD_FILE" 2>/dev/null || true
    info "Caddy $VERSION 已完成校验并安装 ✓"
}

caddy_install_package() {
    local MODE="${1:-install}" TMP
    if command -v apt-get >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then
            apt-get update -qq && apt-get install --only-upgrade -y caddy || return 1
            caddy_state_prepare || return 1
            printf 'package\n' > "$CADDY_INSTALL_METHOD_FILE"
            chmod 600 "$CADDY_INSTALL_METHOD_FILE" 2>/dev/null || true
            return 0
        fi
        apt-get update -qq || return 1
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1
        TMP=$(quench_mktemp_d) || return 1
        curl --proto '=https' --tlsv1.2 -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$TMP/caddy.gpg.key" \
            && curl --proto '=https' --tlsv1.2 -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$TMP/caddy.list" \
            && gpg --dearmor --yes -o "$TMP/caddy.gpg" "$TMP/caddy.gpg.key" \
            && grep -Fq 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian' "$TMP/caddy.list" \
            || { rm -rf "$TMP"; return 1; }
        install -m 644 "$TMP/caddy.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
            && install -m 644 "$TMP/caddy.list" /etc/apt/sources.list.d/caddy-stable.list \
            || { rm -rf "$TMP"; return 1; }
        rm -rf "$TMP"
        apt-get update -qq && apt-get install -y caddy || return 1
    elif command -v dnf >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then
            dnf upgrade -y caddy || return 1
        else
            dnf install -y dnf-plugins-core || return 1
            dnf copr enable @caddy/caddy -y || return 1
            dnf install -y caddy || return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then
            yum update -y caddy || return 1
        else
            yum install -y yum-plugin-copr || return 1
            yum copr enable @caddy/caddy -y || return 1
            yum install -y caddy || return 1
        fi
    elif command -v apk >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then apk upgrade --no-cache caddy || return 1
        else apk add --no-cache caddy curl || return 1; fi
    elif command -v opkg >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then opkg update && opkg upgrade caddy || return 1
        else opkg update && opkg install caddy curl || return 1; fi
    elif command -v pacman >/dev/null 2>&1; then
        if [ "$MODE" = update ]; then pacman -Syu --needed --noconfirm caddy || return 1
        else pacman -Syu --needed --noconfirm caddy curl || return 1; fi
    else
        return 1
    fi
    command -v caddy >/dev/null 2>&1 || return 1
    caddy_state_prepare || return 1
    printf 'package\n' > "$CADDY_INSTALL_METHOD_FILE"
    chmod 600 "$CADDY_INSTALL_METHOD_FILE" 2>/dev/null || true
}

caddy_package_owns_binary() {
    local BIN="$1"
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$BIN" >/dev/null 2>&1; then
        return 0
    elif command -v rpm >/dev/null 2>&1 && rpm -qf "$BIN" >/dev/null 2>&1; then
        return 0
    elif command -v apk >/dev/null 2>&1 && apk info -W "$BIN" >/dev/null 2>&1; then
        return 0
    elif command -v opkg >/dev/null 2>&1 && opkg search "$BIN" 2>/dev/null | grep -q '^caddy '; then
        return 0
    elif command -v pacman >/dev/null 2>&1 && pacman -Qo "$BIN" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

caddy_detect_install_method() {
    local BIN RECORDED=""
    BIN=$(command -v caddy 2>/dev/null || true)
    [ -n "$BIN" ] || { echo none; return; }
    [ ! -f "$CADDY_INSTALL_METHOD_FILE" ] || RECORDED=$(cat "$CADDY_INSTALL_METHOD_FILE" 2>/dev/null || true)
    if caddy_package_owns_binary "$BIN"; then
        echo package
    elif [ "$RECORDED" = binary ] && [ "$BIN" = /usr/local/bin/caddy ]; then
        echo binary
    else
        echo external
    fi
}

caddy_import_markers_valid() {
    [ -f "$CADDYFILE" ] || return 0
    awk -v begin="$CADDY_IMPORT_BEGIN" -v end="$CADDY_IMPORT_END" '
        $0 == begin {if (active || b || e) bad=1; active=1; b++; next}
        $0 == end {if (!active || e) bad=1; active=0; e++; next}
        END {
            if (active) bad=1
            if (!((b == 0 && e == 0) || (b == 1 && e == 1))) bad=1
            exit bad
        }
    ' "$CADDYFILE"
}

caddy_import_present() {
    local WANTED="import $CADDY_SITES_DIR/*.caddy" RELATIVE=""
    [ -f "$CADDYFILE" ] || return 1
    case "$CADDY_SITES_DIR" in
        "$CADDY_CONFIG_DIR"/*) RELATIVE="import ${CADDY_SITES_DIR#"$CADDY_CONFIG_DIR"/}/*.caddy" ;;
    esac
    awk -v wanted="$WANTED" -v relative="$RELATIVE" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            if (line == wanted || (relative != "" && line == relative)) found=1
        }
        END {exit !found}
    ' "$CADDYFILE"
}

caddy_validate() {
    local FILE="${1:-$CADDYFILE}" OUTPUT RC=0 CADDY_BIN
    CADDY_LAST_ERROR=""
    command -v caddy >/dev/null 2>&1 || { CADDY_LAST_ERROR="缺少 caddy 命令"; return 1; }
    CADDY_BIN=$(command -v caddy)
    if id caddy >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 \
        && runuser -u caddy -- test -r "$FILE" >/dev/null 2>&1; then
        OUTPUT=$(runuser -u caddy -- env \
            "XDG_DATA_HOME=$CADDY_DATA_DIR/.local/share" \
            "XDG_CONFIG_HOME=$CADDY_DATA_DIR/.config" \
            "$CADDY_BIN" validate --config "$FILE" --adapter caddyfile 2>&1) || RC=$?
    else
        OUTPUT=$("$CADDY_BIN" validate --config "$FILE" --adapter caddyfile 2>&1) || RC=$?
    fi
    CADDY_LAST_ERROR="$OUTPUT"
    if ! caddy_log_permissions; then
        CADDY_LAST_ERROR="${CADDY_LAST_ERROR}${CADDY_LAST_ERROR:+$'\n'}无法修正 Caddy 访问日志权限"
        [ "$RC" -ne 0 ] || RC=1
    fi
    return "$RC"
}

caddy_show_last_error() {
    local LINE
    [ -n "$CADDY_LAST_ERROR" ] || return 0
    while IFS= read -r LINE; do echo -e "  ${RED}${LINE}${NC}"; done <<< "$CADDY_LAST_ERROR"
}

caddy_reload_active() {
    caddy_validate "$CADDYFILE" || return 1
    caddy reload --force --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1
}

caddy_wait_running() {
    local ATTEMPT
    for ((ATTEMPT=1; ATTEMPT<=10; ATTEMPT++)); do
        caddy_service_active && return 0
        sleep 1
    done
    return 1
}

caddy_reload_or_start() {
    if caddy_service_active; then
        caddy_reload_active
    else
        caddy_service_available || { error "未找到可持久运行的 Caddy 服务"; return 1; }
        caddy_service_enable
        caddy_service_start && caddy_wait_running
    fi
}

caddy_config_permissions() {
    mkdir -p "$CADDY_CONFIG_DIR" "$CADDY_SITES_DIR" "$CADDY_LOG_DIR" "$CADDY_DATA_DIR" || return 1
    chmod 755 "$CADDY_CONFIG_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_SITES_DIR" "$CADDY_LOG_DIR" "$CADDY_DATA_DIR" 2>/dev/null || true
    if id caddy >/dev/null 2>&1; then
        chown caddy:caddy "$CADDY_LOG_DIR" "$CADDY_DATA_DIR" 2>/dev/null || return 1
        chgrp caddy "$CADDY_SITES_DIR" 2>/dev/null || true
    fi
    caddy_log_permissions
}

caddy_log_permissions() {
    local FILE
    id caddy >/dev/null 2>&1 || return 0
    for FILE in "$CADDY_LOG_DIR"/*.access.log "$CADDY_LOG_DIR"/*.access.log.*; do
        [ -f "$FILE" ] || continue
        [ ! -L "$FILE" ] || return 1
        chown -h caddy:caddy "$FILE" 2>/dev/null || return 1
    done
}

caddy_backup_before_change() {
    local LABEL="$1"
    case "$CADDYFILE" in
        /etc/caddy/*)
            declare -F config_backup_create >/dev/null 2>&1 \
                && config_backup_create "caddy_${LABEL}" true >/dev/null \
                || warn "无法建立统一配置备份；仍保留本次即时文件回滚"
            ;;
    esac
}

caddy_ensure_layout() {
    local REPLACE_EXISTING="${1:-false}" STAGE BACKUP ACTIVE=false NEW=false APPLY_FAILED=false
    caddy_config_permissions || return 1
    caddy_import_markers_valid || { error "Caddyfile 中的 Quench import 标记不完整"; return 1; }
    caddy_import_present && return 0
    STAGE=$(mktemp "$CADDY_CONFIG_DIR/.Caddyfile.quench.XXXXXX") || return 1
    if [ -f "$CADDYFILE" ] && [ "$REPLACE_EXISTING" = false ]; then
        cp "$CADDYFILE" "$STAGE" || { rm -f "$STAGE"; return 1; }
    else
        [ -f "$CADDYFILE" ] || NEW=true
        cat > "$STAGE" <<'EOF'
# Caddy 主配置 — Quench 仅维护下方站点 import，站点分别存放于 sites.d。
EOF
    fi
    [ ! -s "$STAGE" ] || printf '\n' >> "$STAGE"
    cat >> "$STAGE" <<EOF
$CADDY_IMPORT_BEGIN
import $CADDY_SITES_DIR/*.caddy
$CADDY_IMPORT_END
EOF
    chmod 640 "$STAGE" 2>/dev/null || true
    id caddy >/dev/null 2>&1 && chgrp caddy "$STAGE" 2>/dev/null || true
    caddy_validate "$STAGE" || {
        rm -f "$STAGE"
        error "无法建立 Caddy sites.d 布局"
        caddy_show_last_error
        return 1
    }
    if [ "$NEW" = false ]; then
        confirm_file_diff "$CADDYFILE" "$STAGE" "加入 Quench 独立站点目录" \
            || { rm -f "$STAGE"; warn "未接管现有 Caddyfile；引导式站点管理暂不可用"; return 1; }
    fi
    caddy_lock_acquire || { rm -f "$STAGE"; return 1; }
    BACKUP=$(mktemp "$CADDY_STATE_DIR/Caddyfile.before.XXXXXX") || { caddy_lock_release; rm -f "$STAGE"; return 1; }
    if [ -f "$CADDYFILE" ]; then
        cp -p "$CADDYFILE" "$BACKUP" || {
            rm -f "$BACKUP" "$STAGE"
            caddy_lock_release
            return 1
        }
    else
        : > "$BACKUP.absent" || {
            rm -f "$BACKUP" "$STAGE"
            caddy_lock_release
            return 1
        }
    fi
    caddy_service_active && ACTIVE=true
    caddy_backup_before_change layout
    mv "$STAGE" "$CADDYFILE" || APPLY_FAILED=true
    [ "$APPLY_FAILED" = true ] || caddy_validate "$CADDYFILE" || APPLY_FAILED=true
    if [ "$ACTIVE" = true ] && [ "$APPLY_FAILED" = false ]; then
        caddy_reload_active || APPLY_FAILED=true
    fi
    if [ "$APPLY_FAILED" = true ]; then
        if [ -f "$BACKUP.absent" ]; then rm -f "$CADDYFILE"; else cp -p "$BACKUP" "$CADDYFILE"; fi
        [ "$ACTIVE" = false ] || caddy_reload_active >/dev/null 2>&1 || true
        rm -f "$STAGE" "$BACKUP" "$BACKUP.absent"
        caddy_lock_release
        error "Caddy sites.d 布局应用失败，已恢复原配置"
        caddy_show_last_error
        return 1
    fi
    rm -f "$BACKUP" "$BACKUP.absent"
    caddy_lock_release
    audit_action "建立 Caddy 独立站点目录" SUCCESS
}

caddy_post_install() {
    local MODE="${1:-install}" WAS_ACTIVE="${2:-false}" REPLACE_FRESH="${3:-false}"
    command -v caddy >/dev/null 2>&1 || { error "Caddy 可执行文件不存在"; return 1; }
    caddy_service_available || {
        [ "$(caddy_detect_install_method)" = binary ] \
            && caddy_binary_service_install "$(command -v caddy)" \
            || { error "Caddy 已安装，但没有受支持的持久服务"; return 1; }
    }
    caddy_config_permissions || return 1
    if ! caddy_ensure_layout "$REPLACE_FRESH"; then
        warn "Caddy 已安装，但引导式 sites.d 管理尚未启用"
    fi
    if [ -f "$CADDYFILE" ] && caddy_validate "$CADDYFILE"; then
        if [ "$MODE" = update ]; then
            if [ "$WAS_ACTIVE" = true ] && ! { caddy_service_restart && caddy_wait_running; }; then
                error "Caddy 更新后服务重启失败"
                return 1
            fi
        else
            caddy_service_enable
            if ! caddy_service_active && ! { caddy_service_start && caddy_wait_running; }; then
                error "Caddy 服务启动失败"
                return 1
            fi
        fi
    else
        error "Caddy 主配置无效，服务未启动"
        caddy_show_last_error
        return 1
    fi
    if [ "$MODE" = update ] && [ "$WAS_ACTIVE" = false ]; then
        info "Caddy $(caddy version 2>/dev/null | awk '{print $1}') 已更新；服务保持停止状态 ✓"
    elif [ "$MODE" = update ]; then
        info "Caddy $(caddy version 2>/dev/null | awk '{print $1}') 已更新并重启验证 ✓"
    else
        info "Caddy $(caddy version 2>/dev/null | awk '{print $1}') 已安装并由服务管理 ✓"
    fi
}

caddy_install() {
    local MODE="${1:-install}" METHOD BIN_BACKUP="" WAS_ACTIVE=false HAD_CONFIG=false REPLACE_FRESH=false
    print_header "安装 / 更新 Caddy"
    [ -e "$CADDYFILE" ] && HAD_CONFIG=true
    METHOD=$(caddy_detect_install_method)
    if command -v caddy >/dev/null 2>&1 && [ "$MODE" != update ]; then
        info "检测到现有 Caddy $(caddy version 2>/dev/null | awk '{print $1}')，将安全接入配置管理"
        caddy_post_install install
        return
    fi
    if [ "$MODE" = update ] && [ "$METHOD" = external ]; then
        error "当前 Caddy 不受 Quench 或系统包管理器管理，拒绝覆盖自定义构建/插件"
        warn "请先自行更新该二进制，再回到 Quench 检查服务与配置"
        return 1
    fi
    caddy_service_active && WAS_ACTIVE=true
    if [ "$METHOD" = binary ] && [ "$MODE" = update ]; then
        [ "$(command -v caddy)" = /usr/local/bin/caddy ] || {
            error "Quench 二进制安装记录与当前路径不一致，拒绝覆盖：$(command -v caddy)"
            return 1
        }
        caddy_state_prepare || return 1
        BIN_BACKUP=$(mktemp "$CADDY_STATE_DIR/caddy-binary.before.XXXXXX") || return 1
        cp "$(command -v caddy)" "$BIN_BACKUP" || { rm -f "$BIN_BACKUP"; return 1; }
        chmod 700 "$BIN_BACKUP" 2>/dev/null || true
    fi
    info "优先使用发行版/官方软件包安装 Caddy..."
    if [ "$METHOD" = binary ] && [ "$MODE" = update ]; then
        if ! caddy_install_binary; then
            install -m 755 "$BIN_BACKUP" /usr/local/bin/caddy >/dev/null 2>&1 || true
            rm -f "$BIN_BACKUP"
            return 1
        fi
    elif ! caddy_install_package "$MODE"; then
        if [ "$MODE" = update ] && [ "$METHOD" = package ]; then
            error "系统软件包更新失败；为避免混用安装来源，不会回退到手动二进制"
            return 1
        fi
        warn "软件包安装不可用，切换到带官方 checksum 校验的二进制回退"
        caddy_install_binary || return 1
    fi
    if [ "$MODE" = install ] && [ "$METHOD" = none ] && [ "$HAD_CONFIG" = false ] && [ -f "$CADDYFILE" ]; then
        REPLACE_FRESH=true
    fi
    if ! caddy_post_install "$MODE" "$WAS_ACTIVE" "$REPLACE_FRESH"; then
        if [ -n "$BIN_BACKUP" ]; then
            install -m 755 "$BIN_BACKUP" /usr/local/bin/caddy >/dev/null 2>&1 || true
            [ "$WAS_ACTIVE" = false ] || { caddy_service_restart >/dev/null 2>&1 && caddy_wait_running; } || true
            error "已恢复更新前的 Caddy 二进制"
        fi
        rm -f "$BIN_BACKUP"
        return 1
    fi
    rm -f "$BIN_BACKUP"
}

caddy_parse_config_file() {
    local FILE="$1"
    [ -f "$FILE" ] || return 0
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value
        }
        function without_comment(value) {
            sub(/[[:space:]]+#.*$/, "", value); return value
        }
        {
            line=trim(without_comment($0))
            if (line == "" || line ~ /^#/) next
            work=line; opens=gsub(/\{/, "{", work); closes=gsub(/\}/, "}", work)
            if (depth == 0 && line ~ /\{[[:space:]]*$/) {
                header=line; sub(/[[:space:]]*\{[[:space:]]*$/, "", header); header=trim(header)
                active=(header != "" && header !~ /^\([^)]*\)$/)
                if (active) print "site\t" header
            } else if (depth > 0 && active) {
                directive=line; sub(/[[:space:]].*$/, "", directive)
                if (directive ~ /^(reverse_proxy|php_fastcgi|root|file_server|redir)$/) {
                    target=line; sub(/^[^[:space:]]+[[:space:]]*/, "", target)
                    sub(/[[:space:]]*\{[[:space:]]*$/, "", target)
                    print "directive\t" directive "\t" trim(target)
                }
            }
            depth += opens - closes
            if (depth <= 0) {depth=0; active=0}
        }
    ' "$FILE"
}

caddy_site_records() {
    local FILE
    caddy_parse_config_file "$CADDYFILE"
    for FILE in "$CADDY_SITES_DIR"/*.caddy; do
        [ -f "$FILE" ] || continue
        caddy_parse_config_file "$FILE"
    done
}

caddy_site_count() {
    caddy_site_records | awk -F '\t' '$1 == "site" {count++} END {print count+0}'
}

caddy_managed_site_files() {
    local FILE
    for FILE in "$CADDY_SITES_DIR"/*.caddy; do
        [ -f "$FILE" ] && [ ! -L "$FILE" ] || continue
        [ "$(sed -n '1p' "$FILE")" = "$CADDY_SITE_MARKER" ] && printf '%s\n' "$FILE"
    done
}

caddy_managed_site_count() {
    caddy_managed_site_files | awk 'NF {count++} END {print count+0}'
}

caddy_site_meta() {
    local FILE="$1" KEY="$2"
    awk -v key="# $KEY: " 'index($0, key) == 1 {print substr($0, length(key)+1); exit}' "$FILE"
}

caddy_domain_valid() {
    local DOMAIN="${1%.}" LABEL
    local LABELS=()
    [ "${#DOMAIN}" -ge 3 ] && [ "${#DOMAIN}" -le 253 ] || return 1
    [[ "$DOMAIN" == *.* ]] || return 1
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
    IFS=. read -r -a LABELS <<< "$DOMAIN"
    for LABEL in "${LABELS[@]}"; do
        [ -n "$LABEL" ] && [ "${#LABEL}" -le 63 ] || return 1
        [[ "$LABEL" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

caddy_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

caddy_site_address_parse() {
    local INPUT="$1" VALUE SCHEME="" HOST PORT="" BRACKETED=false
    CADDY_SITE_ADDRESS="" CADDY_SITE_HOST="" CADDY_SITE_PORT="" CADDY_SITE_SCHEME=""
    CADDY_SITE_DOMAIN=false CADDY_SITE_HTTPS=false
    [[ "$INPUT" != *[$'\n\r\t {}#"\\,']* ]] || return 1
    VALUE=$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')
    case "$VALUE" in
        http://*) SCHEME=http; VALUE=${VALUE#http://} ;;
        https://*) SCHEME=https; VALUE=${VALUE#https://} ;;
        *://*) return 1 ;;
    esac
    [ -n "$VALUE" ] || return 1
    if [[ "$VALUE" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
        HOST=${BASH_REMATCH[1]}; PORT=${BASH_REMATCH[3]}; BRACKETED=true
        ip_address_valid 6 "$HOST" || return 1
    elif [[ "$VALUE" == *:* ]]; then
        [ "${VALUE//[^:]/}" = : ] || return 1
        HOST=${VALUE%%:*}; PORT=${VALUE##*:}
    else
        HOST="$VALUE"
    fi
    [ -z "$PORT" ] || caddy_port_valid "$PORT" || return 1
    if ip_address_valid 4 "$HOST"; then
        [ "$SCHEME" != https ] || return 1
        SCHEME=http
    elif caddy_domain_valid "$HOST"; then
        HOST=${HOST%.}
        CADDY_SITE_DOMAIN=true
        if [ -z "$SCHEME" ]; then
            [ "$PORT" = 80 ] && SCHEME=http || SCHEME=https
        fi
    elif [ "$BRACKETED" = true ] && ip_address_valid 6 "$HOST"; then
        [ "$SCHEME" != https ] || return 1
        SCHEME=http
    else
        return 1
    fi
    { [ "$SCHEME" = https ] && [ "$PORT" = 80 ]; } && return 1
    { [ "$SCHEME" = http ] && [ "$PORT" = 443 ]; } && return 1
    [ "$SCHEME" = https ] && CADDY_SITE_HTTPS=true
    if [ "$BRACKETED" = true ]; then
        CADDY_SITE_ADDRESS="http://[$HOST]${PORT:+:$PORT}"
    elif [ "$CADDY_SITE_DOMAIN" = true ] && [ "$SCHEME" = https ]; then
        if [ -z "$PORT" ] || [ "$PORT" = 443 ]; then
            CADDY_SITE_ADDRESS="$HOST"
        else
            CADDY_SITE_ADDRESS="https://$HOST:$PORT"
        fi
    elif [ "$CADDY_SITE_DOMAIN" = true ] && [ "$SCHEME" = http ]; then
        if [ -z "$PORT" ] || [ "$PORT" = 80 ]; then
            CADDY_SITE_ADDRESS="http://$HOST"
        else
            CADDY_SITE_ADDRESS="http://$HOST:$PORT"
        fi
    else
        CADDY_SITE_ADDRESS="$SCHEME://$HOST${PORT:+:$PORT}"
    fi
    CADDY_SITE_HOST="$HOST"
    CADDY_SITE_SCHEME="$SCHEME"
    if [ -n "$PORT" ]; then CADDY_SITE_PORT="$PORT"; elif [ "$SCHEME" = https ]; then CADDY_SITE_PORT=443; else CADDY_SITE_PORT=80; fi
}

caddy_backend_valid() {
    local VALUE="$1" REST HOST PORT
    [[ "$VALUE" != *[$'\n\r\t {}#"\\,']* ]] || return 1
    case "$VALUE" in
        unix//*)
            REST=${VALUE#unix//}
            [[ "$REST" == /* && "$REST" != *'/../'* && "$REST" != */.. \
                && "$REST" =~ ^/[A-Za-z0-9_./@+-]+$ ]]
            return
            ;;
        http://*) REST=${VALUE#http://} ;;
        https://*) REST=${VALUE#https://} ;;
        *://*) return 1 ;;
        *) REST="$VALUE" ;;
    esac
    [[ "$REST" != */* ]] || return 1
    if [[ "$REST" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        HOST=${BASH_REMATCH[1]}; PORT=${BASH_REMATCH[2]}
        ip_address_valid 6 "$HOST" || return 1
    elif [[ "$REST" == *:* ]] && [ "${REST//[^:]/}" = : ]; then
        HOST=${REST%%:*}; PORT=${REST##*:}
        { [ "$HOST" = localhost ] || caddy_domain_valid "$HOST" || ip_address_valid 4 "$HOST"; } || return 1
    else
        return 1
    fi
    caddy_port_valid "$PORT"
}

caddy_webroot_valid() {
    local VALUE="$1"
    [[ "$VALUE" == /* && "$VALUE" != *'/../'* && "$VALUE" != */.. \
        && "$VALUE" =~ ^/[A-Za-z0-9_./@+-]+$ ]] || return 1
    case "$VALUE" in /var/www|/var/www/*|/srv|/srv/*) return 0 ;; *) return 1 ;; esac
}

caddy_redirect_target_valid() {
    local VALUE="$1" REST HOST PORT=""
    [[ "$VALUE" != *[$'\n\r\t {}#"\\']* ]] || return 1
    case "$VALUE" in https://*) REST=${VALUE#https://} ;; http://*) REST=${VALUE#http://} ;; *) return 1 ;; esac
    [[ "$REST" != */* ]] || return 1
    if [[ "$REST" == *:* ]]; then HOST=${REST%%:*}; PORT=${REST##*:}; else HOST="$REST"; fi
    caddy_domain_valid "$HOST" || ip_address_valid 4 "$HOST" || return 1
    [ -z "$PORT" ] || caddy_port_valid "$PORT"
}

caddy_php_gateway_valid() {
    case "$1" in
        unix//*) caddy_backend_valid "$1" ;;
        http://*|https://*) return 1 ;;
        *) caddy_backend_valid "$1" ;;
    esac
}

caddy_site_slug() {
    local VALUE="$1" PREFIX=""
    case "$VALUE" in
        http://*) PREFIX=http-; VALUE=${VALUE#http://} ;;
        https://*) VALUE=${VALUE#https://} ;;
    esac
    VALUE="$PREFIX$VALUE"
    VALUE=$(printf '%s' "$VALUE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g; s/--*/-/g; s/^-//; s/-$//')
    [ -n "$VALUE" ] || return 1
    printf '%s\n' "$VALUE"
}

caddy_site_address_exists() {
    local WANTED="$1" KIND VALUES TARGET ENTRY CANON WANTED_LOWER CANON_LOWER
    local ENTRIES=()
    WANTED_LOWER=$(printf '%s' "$WANTED" | tr '[:upper:]' '[:lower:]')
    while IFS=$'\t' read -r KIND VALUES TARGET; do
        [ "$KIND" = site ] || continue
        IFS=, read -r -a ENTRIES <<< "$VALUES"
        for ENTRY in "${ENTRIES[@]}"; do
            ENTRY=${ENTRY#"${ENTRY%%[![:space:]]*}"}
            ENTRY=${ENTRY%"${ENTRY##*[![:space:]]}"}
            CANON="$ENTRY"
            caddy_site_address_parse "$ENTRY" && CANON="$CADDY_SITE_ADDRESS"
            CANON_LOWER=$(printf '%s' "$CANON" | tr '[:upper:]' '[:lower:]')
            [ "$CANON_LOWER" = "$WANTED_LOWER" ] && return 0
        done
    done < <(caddy_site_records)
    return 1
}

caddy_backend_reachable() {
    local BACKEND="$1" URL
    command -v curl >/dev/null 2>&1 || return 0
    case "$BACKEND" in
        unix//*) [ -S "${BACKEND#unix//}" ] ;;
        http://*|https://*)
            curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 -o /dev/null "$BACKEND"
            ;;
        *)
            URL="http://$BACKEND"
            curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 -o /dev/null "$URL"
            ;;
    esac
}

caddy_php_gateway_ready() {
    local GATEWAY="$1" REST HOST PORT SOCKET
    case "$GATEWAY" in
        unix//*)
            SOCKET=${GATEWAY#unix//}
            [ -S "$SOCKET" ] || return 1
            if id caddy >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
                runuser -u caddy -- test -r "$SOCKET" -a -w "$SOCKET"
            fi
            ;;
        *)
            REST="$GATEWAY"
            if [[ "$REST" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
                HOST=${BASH_REMATCH[1]}; PORT=${BASH_REMATCH[2]}
            else
                HOST=${REST%%:*}; PORT=${REST##*:}
            fi
            if command -v nc >/dev/null 2>&1; then
                nc -z -w 3 "$HOST" "$PORT" >/dev/null 2>&1
            elif command -v timeout >/dev/null 2>&1; then
                # shellcheck disable=SC2016 # $1/$2 由 bash -c 的位置参数提供，不能在外层展开
                timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$HOST" "$PORT" >/dev/null 2>&1
            else
                warn "缺少 nc/timeout，无法主动探测 PHP-FPM TCP 网关"
                return 0
            fi
            ;;
    esac
}

caddy_domain_addresses() {
    local DOMAIN="$1"
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u
    elif command -v dig >/dev/null 2>&1; then
        { dig +short A "$DOMAIN"; dig +short AAAA "$DOMAIN"; } 2>/dev/null | sort -u
    else
        return 1
    fi
}

caddy_listener_conflicts() {
    local PROTO="$1" PORT LINE SS_ARGS
    shift
    command -v ss >/dev/null 2>&1 || return 0
    [ "$PROTO" = tcp ] && SS_ARGS=-ltnp || SS_ARGS=-lunp
    for PORT in "$@"; do
        while IFS= read -r LINE; do
            [ -n "$LINE" ] || continue
            if [[ "$LINE" != *caddy* ]]; then
                error "端口 ${PORT}/${PROTO} 已被其他进程监听：$LINE"
                return 1
            fi
        done < <(ss -H "$SS_ARGS" 2>/dev/null | awk -v port="$PORT" '$4 ~ (":" port "$") {print}')
    done
}

caddy_raw_iptables_active() {
    command -v iptables >/dev/null 2>&1 || return 1
    local COUNT
    COUNT=$(iptables -L INPUT --line-numbers 2>/dev/null \
        | grep -vc "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere" || true)
    [ "$COUNT" -gt 0 ]
}

caddy_firewall_prepared_reset() {
    CADDY_FIREWALL_TYPE=""
    CADDY_FIREWALL_ZONE=""
    CADDY_FIREWALL_ADDED_RULES=()
}

caddy_firewall_rollback_prepared() {
    local RULE
    [ "${#CADDY_FIREWALL_ADDED_RULES[@]}" -gt 0 ] || { caddy_firewall_prepared_reset; return 0; }
    case "$CADDY_FIREWALL_TYPE" in
        ufw)
            for RULE in "${CADDY_FIREWALL_ADDED_RULES[@]}"; do
                ufw --force delete allow "$RULE" >/dev/null 2>&1 || true
            done
            ;;
        firewalld)
            for RULE in "${CADDY_FIREWALL_ADDED_RULES[@]}"; do
                firewall-cmd --permanent --zone="$CADDY_FIREWALL_ZONE" \
                    --remove-port="$RULE" >/dev/null 2>&1 || true
            done
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
    esac
    audit_action "撤销未成功站点新增的 Caddy Web 规则 ${CADDY_FIREWALL_ADDED_RULES[*]}" ROLLBACK
    caddy_firewall_prepared_reset
}

caddy_firewall_commit_prepared() {
    caddy_firewall_prepared_reset
}

caddy_ufw_rule_present() {
    local PORT="$1" PROTO="$2" ACTIONS="${3:-ALLOW}" SCOPE="${4:-any}"
    LC_ALL=C ufw status 2>/dev/null | awk -v spec="${PORT}/${PROTO}" -v actions="$ACTIONS" -v scope="$SCOPE" '
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

caddy_firewall_rule_ready() {
    local TYPE="$1" RULE="$2" PORT PROTO ZONE
    PORT=${RULE%/*}; PROTO=${RULE##*/}
    case "$TYPE" in
        ufw)
            caddy_ufw_rule_present "$PORT" "$PROTO" ALLOW broad \
                && ! caddy_ufw_rule_present "$PORT" "$PROTO" 'DENY|REJECT' broad
            ;;
        firewalld)
            ZONE=$(fw_firewalld_zone)
            firewall-cmd --zone="$ZONE" --query-port="$RULE" >/dev/null 2>&1
            ;;
        iptables)
            iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

caddy_firewall_prepare_rules() {
    local RULE TYPE ZONE ACTIVE_UFW=false ACTIVE_FWD=false MISSING=()
    local RULES=()
    caddy_firewall_prepared_reset
    for RULE in "$@"; do
        [[ "$RULE" =~ ^[0-9]+/(tcp|udp)$ ]] || return 1
        caddy_port_valid "${RULE%/*}" || return 1
        [[ " ${RULES[*]} " == *" $RULE "* ]] || RULES+=("$RULE")
    done
    command -v ufw >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ] && ACTIVE_UFW=true
    command -v firewall-cmd >/dev/null 2>&1 && [ "$(fw_running firewalld)" = active ] && ACTIVE_FWD=true
    if [ "$ACTIVE_UFW" = true ] && [ "$ACTIVE_FWD" = true ]; then
        error "UFW 与 firewalld 同时运行，拒绝自动修改 Web 端口"
        return 1
    fi
    if [ "$ACTIVE_UFW" = true ]; then TYPE=ufw
    elif [ "$ACTIVE_FWD" = true ]; then TYPE=firewalld
    elif caddy_raw_iptables_active; then
        TYPE=iptables
        for RULE in "${RULES[@]}"; do caddy_firewall_rule_ready "$TYPE" "$RULE" || MISSING+=("$RULE"); done
        [ "${#MISSING[@]}" -eq 0 ] || {
            error "检测到原生 iptables，但以下 Web 规则没有可验证的放行：${MISSING[*]}"
            warn "请手动放行后再添加站点"
            return 1
        }
        return 0
    else
        info "未检测到活跃本机防火墙；不自动安装或启用防火墙"
        return 0
    fi
    for RULE in "${RULES[@]}"; do caddy_firewall_rule_ready "$TYPE" "$RULE" || MISSING+=("$RULE"); done
    [ "${#MISSING[@]}" -eq 0 ] && { info "本机防火墙已放行：${RULES[*]}"; return 0; }
    confirm_change_preview "放行 Caddy Web 入口" \
        "防火墙：$TYPE" "新增规则：${MISSING[*]}" \
        "不会修改云厂商安全组" || { warn "未放行所需 Web 端口"; return 1; }
    CADDY_FIREWALL_TYPE="$TYPE"
    case "$TYPE" in
        ufw)
            for RULE in "${MISSING[@]}"; do
                if ! ufw allow "$RULE" >/dev/null 2>&1; then
                    caddy_firewall_rollback_prepared
                    return 1
                fi
                CADDY_FIREWALL_ADDED_RULES+=("$RULE")
            done
            ;;
        firewalld)
            ZONE=$(fw_firewalld_zone)
            CADDY_FIREWALL_ZONE="$ZONE"
            for RULE in "${MISSING[@]}"; do
                if ! firewall-cmd --permanent --zone="$ZONE" --add-port="$RULE" >/dev/null 2>&1; then
                    caddy_firewall_rollback_prepared
                    return 1
                fi
                CADDY_FIREWALL_ADDED_RULES+=("$RULE")
            done
            firewall-cmd --reload >/dev/null 2>&1 || { caddy_firewall_rollback_prepared; return 1; }
            ;;
    esac
    for RULE in "${RULES[@]}"; do
        caddy_firewall_rule_ready "$TYPE" "$RULE" || { caddy_firewall_rollback_prepared; return 1; }
    done
    audit_action "为 Caddy 放行 Web 规则 ${MISSING[*]}" SUCCESS
}

caddy_prepare_ingress() {
    local RESOLVED
    local TCP_PORTS=("$CADDY_SITE_PORT") UDP_PORTS=() RULES=("$CADDY_SITE_PORT/tcp")
    if [ "$CADDY_SITE_DOMAIN" = true ]; then
        RESOLVED=$(caddy_domain_addresses "$CADDY_SITE_HOST" 2>/dev/null || true)
        if [ -z "$RESOLVED" ]; then
            warn "域名 $CADDY_SITE_HOST 当前无法解析"
            confirm_change_preview "在 DNS 尚未就绪时继续" \
                "Caddy 会持续重试证书申请" "DNS 配置完成前网站不可访问" \
                || return 1
        else
            echo -e "  DNS 解析：${DIM}$(tr '\n' ' ' <<< "$RESOLVED")${NC}"
        fi
        if [ "$CADDY_SITE_HTTPS" = true ]; then
            TCP_PORTS=(80 "$CADDY_SITE_PORT")
            UDP_PORTS=("$CADDY_SITE_PORT")
            RULES=(80/tcp "$CADDY_SITE_PORT/tcp" "$CADDY_SITE_PORT/udp")
        fi
    fi
    caddy_listener_conflicts tcp "${TCP_PORTS[@]}" || return 1
    [ "${#UDP_PORTS[@]}" -eq 0 ] || caddy_listener_conflicts udp "${UDP_PORTS[@]}" || return 1
    caddy_firewall_prepare_rules "${RULES[@]}" || return 1
    warn "还需在云厂商安全组放行：${RULES[*]}"
}

caddy_render_log_block() {
    local SLUG="$1"
    cat <<EOF
    log {
        output file $CADDY_LOG_DIR/${SLUG}.access.log {
            roll_size 10MiB
            roll_keep 10
            roll_keep_for 720h
        }
        format json
    }
EOF
}

caddy_render_proxy_site() {
    local ADDRESS="$1" BACKEND="$2" SLUG="$3"
    cat <<EOF
$CADDY_SITE_MARKER
# Type: proxy
# Address: $ADDRESS
# Target: $BACKEND
$ADDRESS {
    encode zstd gzip
    reverse_proxy $BACKEND
$(caddy_render_log_block "$SLUG")
}
EOF
}

caddy_render_static_site() {
    local ADDRESS="$1" WEBROOT="$2" SLUG="$3"
    cat <<EOF
$CADDY_SITE_MARKER
# Type: static
# Address: $ADDRESS
# Target: $WEBROOT
$ADDRESS {
    root * $WEBROOT
    encode zstd gzip
    file_server
$(caddy_render_log_block "$SLUG")
}
EOF
}

caddy_render_redirect_site() {
    local ADDRESS="$1" TARGET="$2" SLUG="$3"
    cat <<EOF
$CADDY_SITE_MARKER
# Type: redirect
# Address: $ADDRESS
# Target: $TARGET
$ADDRESS {
    redir $TARGET{uri} permanent
$(caddy_render_log_block "$SLUG")
}
EOF
}

caddy_render_php_site() {
    local ADDRESS="$1" WEBROOT="$2" GATEWAY="$3" SLUG="$4"
    cat <<EOF
$CADDY_SITE_MARKER
# Type: php
# Address: $ADDRESS
# Target: $WEBROOT | $GATEWAY
$ADDRESS {
    root * $WEBROOT
    encode zstd gzip
    php_fastcgi $GATEWAY
    file_server
$(caddy_render_log_block "$SLUG")
}
EOF
}

caddy_local_health() {
    local ADDRESS="$1" HOST PORT SCHEME HOST_HEADER
    command -v curl >/dev/null 2>&1 || return 0
    caddy_site_address_parse "$ADDRESS" || return 1
    HOST="$CADDY_SITE_HOST" PORT="$CADDY_SITE_PORT" SCHEME="$CADDY_SITE_SCHEME"
    HOST_HEADER="$HOST"
    [[ "$HOST" == *:* ]] && HOST_HEADER="[$HOST]"
    if [ "$CADDY_SITE_DOMAIN" = true ] && [ "$SCHEME" = https ]; then
        curl --noproxy '*' -sS --connect-timeout 3 --max-time 6 -o /dev/null \
            -H "Host: $HOST_HEADER" http://127.0.0.1:80/ && return 0
        curl --noproxy '*' -k -sS --connect-timeout 3 --max-time 6 -o /dev/null \
            --resolve "$HOST:$PORT:127.0.0.1" "https://$HOST:$PORT/"
    else
        curl --noproxy '*' -sS --connect-timeout 3 --max-time 6 -o /dev/null \
            -H "Host: $HOST_HEADER" "http://127.0.0.1:$PORT/"
    fi
}

caddy_apply_managed_site() {
    local TYPE="$1" ADDRESS="$2" TARGET="$3" CONTENT="$4"
    local SLUG FILE STAGE WAS_ACTIVE=false STARTED=false
    caddy_ensure_layout || return 1
    caddy_site_address_exists "$ADDRESS" && { error "站点地址已经存在：$ADDRESS"; return 1; }
    SLUG=$(caddy_site_slug "$ADDRESS") || return 1
    FILE="$CADDY_SITES_DIR/${SLUG}.caddy"
    [ ! -e "$FILE" ] || { error "站点文件已存在：$FILE"; return 1; }
    caddy_lock_acquire || return 1
    if [ -e "$FILE" ] || caddy_site_address_exists "$ADDRESS"; then
        caddy_lock_release
        error "锁定配置期间检测到同名站点，未覆盖任何文件：$ADDRESS"
        return 1
    fi
    STAGE=$(mktemp "$CADDY_SITES_DIR/.site-stage.XXXXXX") || { caddy_lock_release; return 1; }
    printf '%s\n' "$CONTENT" > "$STAGE" || { rm -f "$STAGE"; caddy_lock_release; return 1; }
    chmod 640 "$STAGE" 2>/dev/null || true
    id caddy >/dev/null 2>&1 && chgrp caddy "$STAGE" 2>/dev/null || true
    if ! caddy_validate "$STAGE"; then
        rm -f "$STAGE"; caddy_lock_release
        error "站点配置本身无效"; caddy_show_last_error; return 1
    fi
    caddy_service_active && WAS_ACTIVE=true
    caddy_backup_before_change "add_${TYPE}"
    if ! mv "$STAGE" "$FILE" || ! caddy_validate "$CADDYFILE" || ! caddy_reload_or_start; then
        rm -f "$FILE" "$STAGE"
        if [ "$WAS_ACTIVE" = true ]; then
            caddy_reload_active >/dev/null 2>&1 || true
        else
            caddy_service_stop >/dev/null 2>&1 || true
        fi
        caddy_lock_release
        error "站点应用失败，已恢复应用前配置"
        caddy_show_last_error
        return 1
    fi
    [ "$WAS_ACTIVE" = true ] || STARTED=true
    if ! caddy_local_health "$ADDRESS"; then
        rm -f "$FILE"
        if [ "$WAS_ACTIVE" = true ]; then caddy_reload_active >/dev/null 2>&1 || true
        elif [ "$STARTED" = true ]; then caddy_service_stop >/dev/null 2>&1 || true
        fi
        caddy_lock_release
        error "Caddy 本机入口健康检查失败，已撤销站点"
        return 1
    fi
    caddy_lock_release
    audit_action "添加 Caddy $TYPE 站点 $ADDRESS -> $TARGET" SUCCESS
    info "站点 $ADDRESS 已事务式应用 ✓"
    echo -e "  配置：${DIM}${FILE}${NC}"
}

caddy_prompt_address() {
    local INPUT
    read -rp "  域名或 HTTP IP（如 example.com、example.com:8443、198.51.100.10）: " INPUT
    [ -n "$INPUT" ] || return 1
    caddy_site_address_parse "$INPUT" || {
        error "站点地址无效；域名请使用 ASCII/punycode，IP 引导模式只提供 HTTP"
        return 1
    }
}

caddy_add_proxy() {
    local BACKEND CONTENT SLUG
    print_header "添加反向代理站点"
    caddy_prompt_address || { warn "已取消"; return; }
    read -rp "  后端（如 127.0.0.1:8080、https://app.internal:8443）: " BACKEND
    caddy_backend_valid "$BACKEND" || { error "后端格式无效或包含不安全字符"; return 1; }
    if [[ "$BACKEND" == unix//* ]] && ! caddy_php_gateway_ready "$BACKEND"; then
        error "Unix socket 不存在，或 caddy 用户没有读写权限：${BACKEND#unix//}"
        return 1
    fi
    if ! caddy_backend_reachable "$BACKEND"; then
        warn "当前无法连接后端 $BACKEND"
        confirm_change_preview "在后端尚未就绪时继续" \
            "Caddy 可能暂时返回 502" "后端启动后无需重载 Caddy" || return 1
    fi
    SLUG=$(caddy_site_slug "$CADDY_SITE_ADDRESS") || return 1
    CONTENT=$(caddy_render_proxy_site "$CADDY_SITE_ADDRESS" "$BACKEND" "$SLUG")
    confirm_change_preview "添加 Caddy 反向代理" \
        "地址：$CADDY_SITE_ADDRESS" "后端：$BACKEND" \
        "自动 HTTPS：$CADDY_SITE_HTTPS" "启用压缩、JSON 访问日志和轮转" || return 0
    caddy_prepare_ingress || return 1
    if caddy_apply_managed_site proxy "$CADDY_SITE_ADDRESS" "$BACKEND" "$CONTENT"; then
        caddy_firewall_commit_prepared
    else
        caddy_firewall_rollback_prepared
        return 1
    fi
}

caddy_add_static() {
    local WEBROOT CONTENT SLUG CREATED=false
    print_header "添加静态网站"
    caddy_prompt_address || { warn "已取消"; return; }
    read -rp "  网站根目录（默认 /var/www/${CADDY_SITE_HOST}）: " WEBROOT
    WEBROOT=${WEBROOT:-/var/www/$CADDY_SITE_HOST}
    caddy_webroot_valid "$WEBROOT" || { error "网站目录必须位于 /var/www 或 /srv，且不能包含空格、.. 或配置字符"; return 1; }
    if [ -e "$WEBROOT" ] && [ ! -d "$WEBROOT" ]; then
        error "网站根目录路径已存在，但不是目录：$WEBROOT"
        return 1
    fi
    if [ -d "$WEBROOT" ] && id caddy >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 \
        && ! runuser -u caddy -- test -r "$WEBROOT" -a -x "$WEBROOT"; then
        error "caddy 用户无法读取网站目录：$WEBROOT"
        return 1
    fi
    SLUG=$(caddy_site_slug "$CADDY_SITE_ADDRESS") || return 1
    CONTENT=$(caddy_render_static_site "$CADDY_SITE_ADDRESS" "$WEBROOT" "$SLUG")
    confirm_change_preview "添加 Caddy 静态网站" \
        "地址：$CADDY_SITE_ADDRESS" "目录：$WEBROOT" \
        "启用自动 HTTPS、压缩、JSON 访问日志和轮转" || return 0
    caddy_prepare_ingress || return 1
    if [ ! -d "$WEBROOT" ]; then
        mkdir -p "$WEBROOT" || { caddy_firewall_rollback_prepared; return 1; }
        chmod 755 "$WEBROOT" || {
            rmdir "$WEBROOT" 2>/dev/null || true
            caddy_firewall_rollback_prepared
            return 1
        }
        CREATED=true
    fi
    if ! caddy_apply_managed_site static "$CADDY_SITE_ADDRESS" "$WEBROOT" "$CONTENT"; then
        [ "$CREATED" = false ] || rmdir "$WEBROOT" 2>/dev/null || true
        caddy_firewall_rollback_prepared
        return 1
    fi
    caddy_firewall_commit_prepared
}

caddy_add_redirect() {
    local TARGET CONTENT SLUG
    print_header "添加重定向站点"
    caddy_prompt_address || { warn "已取消"; return; }
    read -rp "  跳转目标（如 https://www.example.com）: " TARGET
    caddy_redirect_target_valid "$TARGET" || { error "跳转目标必须是无路径的安全 HTTP/HTTPS 地址"; return 1; }
    SLUG=$(caddy_site_slug "$CADDY_SITE_ADDRESS") || return 1
    CONTENT=$(caddy_render_redirect_site "$CADDY_SITE_ADDRESS" "$TARGET" "$SLUG")
    confirm_change_preview "添加 Caddy 永久重定向" \
        "地址：$CADDY_SITE_ADDRESS" "目标：${TARGET}{uri}" \
        "保留原请求路径和查询参数" || return 0
    caddy_prepare_ingress || return 1
    if caddy_apply_managed_site redirect "$CADDY_SITE_ADDRESS" "$TARGET" "$CONTENT"; then
        caddy_firewall_commit_prepared
    else
        caddy_firewall_rollback_prepared
        return 1
    fi
}

caddy_php_socket_candidates() {
    local SOCKET
    for SOCKET in /run/php/php*-fpm.sock /run/php-fpm/www.sock /run/php-fpm/php-fpm.sock; do
        [ -S "$SOCKET" ] && printf 'unix//%s\n' "$SOCKET"
    done
}

caddy_add_php() {
    local WEBROOT GATEWAY CONTENT SLUG CANDIDATES
    print_header "添加 PHP-FPM 网站"
    warn "此入口只接入已经安装并运行的 PHP-FPM，不安装 PHP、扩展或数据库。"
    caddy_prompt_address || { warn "已取消"; return; }
    read -rp "  网站根目录（默认 /var/www/${CADDY_SITE_HOST}/public）: " WEBROOT
    WEBROOT=${WEBROOT:-/var/www/$CADDY_SITE_HOST/public}
    caddy_webroot_valid "$WEBROOT" || { error "PHP 网站目录必须位于 /var/www 或 /srv"; return 1; }
    CANDIDATES=$(caddy_php_socket_candidates)
    [ -z "$CANDIDATES" ] || echo -e "  检测到：${DIM}$(tr '\n' ' ' <<< "$CANDIDATES")${NC}"
    read -rp "  PHP-FPM 网关（如 unix//run/php/php8.4-fpm.sock 或 127.0.0.1:9000）: " GATEWAY
    [ -n "$GATEWAY" ] || GATEWAY=$(head -1 <<< "$CANDIDATES")
    caddy_php_gateway_valid "$GATEWAY" || { error "PHP-FPM 网关格式无效"; return 1; }
    if ! caddy_php_gateway_ready "$GATEWAY"; then
        error "PHP-FPM 网关不可连接，或 caddy 用户没有 socket 读写权限"
        return 1
    fi
    [ -d "$WEBROOT" ] || { error "PHP 网站目录不存在：$WEBROOT"; return 1; }
    if id caddy >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 \
        && ! runuser -u caddy -- test -r "$WEBROOT" -a -x "$WEBROOT"; then
        error "caddy 用户无法读取 PHP 网站目录：$WEBROOT"
        return 1
    fi
    SLUG=$(caddy_site_slug "$CADDY_SITE_ADDRESS") || return 1
    CONTENT=$(caddy_render_php_site "$CADDY_SITE_ADDRESS" "$WEBROOT" "$GATEWAY" "$SLUG")
    confirm_change_preview "添加 Caddy PHP-FPM 网站" \
        "地址：$CADDY_SITE_ADDRESS" "目录：$WEBROOT" "PHP-FPM：$GATEWAY" \
        "Quench 不管理 PHP 与数据库生命周期" || return 0
    caddy_prepare_ingress || return 1
    if caddy_apply_managed_site php "$CADDY_SITE_ADDRESS" "$WEBROOT | $GATEWAY" "$CONTENT"; then
        caddy_firewall_commit_prepared
    else
        caddy_firewall_rollback_prepared
        return 1
    fi
}

caddy_list_sites() {
    local KIND VALUE TARGET INDEX=0
    print_header "Caddy 站点"
    if [ ! -f "$CADDYFILE" ]; then warn "Caddyfile 不存在"; return; fi
    menu_div
    while IFS=$'\t' read -r KIND VALUE TARGET; do
        case "$KIND" in
            site)
                [ "$INDEX" -eq 0 ] || echo ""
                INDEX=$((INDEX+1))
                echo -e "  ${GREEN}[$INDEX]${NC} ${BOLD}${VALUE}${NC}"
                ;;
            directive)
                [ -n "$TARGET" ] \
                    && echo -e "      ${DIM}${VALUE}${NC} → ${CYAN}${TARGET}${NC}" \
                    || echo -e "      ${DIM}${VALUE}${NC}"
                ;;
        esac
    done < <(caddy_site_records)
    [ "$INDEX" -gt 0 ] || warn "暂无站点配置"
    echo ""
    echo -e "  Quench 管理：${BOLD}$(caddy_managed_site_count)${NC}  总站点：${BOLD}${INDEX}${NC}"
    menu_div
}

caddy_delete_site() {
    local FILE ADDRESS TYPE TARGET INDEX=0 CHOICE BACKUP WAS_ACTIVE=false APPLY_FAILED=false
    local FILES=()
    print_header "删除 Quench 管理的 Caddy 站点"
    while IFS= read -r FILE; do FILES+=("$FILE"); done < <(caddy_managed_site_files)
    [ "${#FILES[@]}" -gt 0 ] || { warn "没有可由 Quench 删除的站点；外部配置请使用高级编辑"; return; }
    for FILE in "${FILES[@]}"; do
        INDEX=$((INDEX+1)); ADDRESS=$(caddy_site_meta "$FILE" Address); TYPE=$(caddy_site_meta "$FILE" Type)
        printf '  %2d) %-34s %s\n' "$INDEX" "$ADDRESS" "$TYPE"
    done
    read -rp "  选择站点 [1-${#FILES[@]}，回车取消]: " CHOICE
    [ -n "$CHOICE" ] || return 0
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#FILES[@]}" ] \
        || { error "无效编号"; return 1; }
    FILE=${FILES[$((CHOICE-1))]}
    ADDRESS=$(caddy_site_meta "$FILE" Address); TYPE=$(caddy_site_meta "$FILE" Type); TARGET=$(caddy_site_meta "$FILE" Target)
    confirm_change_preview "删除 Caddy 站点" \
        "地址：$ADDRESS" "类型：$TYPE" "保留网站目录、后端数据、证书缓存和历史日志" || return 0
    caddy_lock_acquire || return 1
    BACKUP=$(mktemp "$CADDY_STATE_DIR/site-delete.XXXXXX") || { caddy_lock_release; return 1; }
    cp -p "$FILE" "$BACKUP" || { rm -f "$BACKUP"; caddy_lock_release; return 1; }
    caddy_service_active && WAS_ACTIVE=true
    caddy_backup_before_change "delete_${TYPE}"
    rm -f "$FILE" || {
        rm -f "$BACKUP"
        caddy_lock_release
        error "无法删除站点配置：$FILE"
        return 1
    }
    caddy_validate "$CADDYFILE" || APPLY_FAILED=true
    if [ "$WAS_ACTIVE" = true ] && [ "$APPLY_FAILED" = false ]; then
        caddy_reload_active || APPLY_FAILED=true
    fi
    if [ "$APPLY_FAILED" = true ]; then
        cp -p "$BACKUP" "$FILE"
        [ "$WAS_ACTIVE" = false ] || caddy_reload_active >/dev/null 2>&1 || true
        rm -f "$BACKUP"; caddy_lock_release
        error "站点删除失败，已恢复配置"; caddy_show_last_error; return 1
    fi
    rm -f "$BACKUP"; caddy_lock_release
    audit_action "删除 Caddy $TYPE 站点 $ADDRESS -> $TARGET" SUCCESS
    info "站点 $ADDRESS 已删除；网站数据和日志均已保留 ✓"
}

caddy_ssl_status() {
    local CERT_ROOT CERT DOMAIN EXP FOUND=0
    print_header "Caddy 证书状态"
    for CERT_ROOT in "$CADDY_DATA_DIR/.local/share/caddy/certificates" \
        /var/lib/caddy/.local/share/caddy/certificates /root/.local/share/caddy/certificates; do
        [ -d "$CERT_ROOT" ] || continue
        while IFS= read -r CERT; do
            FOUND=$((FOUND+1)); DOMAIN=$(basename "$(dirname "$CERT")")
            if command -v openssl >/dev/null 2>&1; then
                EXP=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
            else EXP=""; fi
            echo -e "  ${GREEN}•${NC} ${BOLD}${DOMAIN}${NC}${EXP:+  到期：$EXP}"
        done < <(find "$CERT_ROOT" -type f -name '*.crt' 2>/dev/null | sort)
        [ "$FOUND" -gt 0 ] && break
    done
    [ "$FOUND" -gt 0 ] || warn "未发现已落盘证书；请运行站点诊断并查看 Caddy 服务日志"
    echo ""
    echo -e "  ${DIM}Caddy 在配置加载后申请并持续续期证书，不依赖首次访问触发。${NC}"
}

caddy_site_diagnostics() {
    local FILE ADDRESS TYPE TARGET DNS URL CODE PORTS
    print_header "Caddy 站点与入口诊断"
    echo -e "  服务：${BOLD}$(caddy_status)${NC}  版本：${BOLD}$(caddy version 2>/dev/null | awk '{print $1}')${NC}"
    if caddy_validate "$CADDYFILE"; then info "完整 Caddy 配置验证通过"; else error "Caddy 配置验证失败"; caddy_show_last_error; fi
    if command -v ss >/dev/null 2>&1; then
        PORTS=$({
            ss -H -ltnp 2>/dev/null | awk '$4 ~ /:(80|443)$/ || /caddy/ {print "tcp  " $0}'
            ss -H -lunp 2>/dev/null | awk '$4 ~ /:443$/ || /caddy/ {print "udp  " $0}'
        } | head -20)
        [ -z "$PORTS" ] || { echo -e "  ${DIM}Caddy / Web TCP+UDP 监听：${NC}"; printf '%s\n' "$PORTS" | sed 's/^/    /'; }
    fi
    while IFS= read -r FILE; do
        ADDRESS=$(caddy_site_meta "$FILE" Address); TYPE=$(caddy_site_meta "$FILE" Type); TARGET=$(caddy_site_meta "$FILE" Target)
        echo ""; echo -e "  ${BOLD}${ADDRESS}${NC}  ${DIM}${TYPE} → ${TARGET}${NC}"
        if caddy_site_address_parse "$ADDRESS" && [ "$CADDY_SITE_DOMAIN" = true ]; then
            DNS=$(caddy_domain_addresses "$CADDY_SITE_HOST" 2>/dev/null || true)
            [ -n "$DNS" ] && echo -e "    DNS：${DIM}$(tr '\n' ' ' <<< "$DNS")${NC}" || warn "${CADDY_SITE_HOST} 无 DNS 结果"
        fi
        if caddy_local_health "$ADDRESS"; then info "本机 Caddy 入口可响应"; else error "本机 Caddy 入口无响应"; fi
        if command -v curl >/dev/null 2>&1; then
            if [[ "$ADDRESS" == http://* || "$ADDRESS" == https://* ]]; then URL="$ADDRESS"; else URL="https://$ADDRESS"; fi
            CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10 "$URL" 2>/dev/null || true)
            [[ "$CODE" =~ ^[1-5][0-9][0-9]$ ]] \
                && echo -e "    公网 HTTP：${BOLD}${CODE}${NC}" \
                || warn "公网 HTTPS/HTTP 暂不可验证"
        fi
    done < <(caddy_managed_site_files)
    echo ""; warn "本机检查无法判断云厂商安全组；公网失败时请同时检查安全组、DNS/CDN 和后端。"
}

caddy_show_log_file() {
    local FILE="$1" CH
    [ -f "$FILE" ] || { warn "日志文件不存在"; return; }
    echo -e "  ${DIM}${FILE}${NC}"
    if command -v jq >/dev/null 2>&1; then
        tail -n 40 "$FILE" 2>/dev/null | jq -r '[(.ts // ""|tostring), (.request.method // ""), (.request.uri // ""), (.status // ""|tostring)] | @tsv' 2>/dev/null \
            || tail -n 40 "$FILE"
    else
        tail -n 40 "$FILE"
    fi
    menu_item "1" "实时跟踪（Ctrl+C 返回）"
    menu_item "0" "返回" "$RED"
    read -rp "$(ui_prompt '选择操作: ')" CH
    [ "$CH" = 1 ] || return 0
    trap 'echo ""; quench_restore_signal_traps' INT
    tail -f "$FILE"
    quench_restore_signal_traps
}

caddy_view_logs() {
    local FILE CH INDEX=0
    local FILES=()
    print_header "Caddy 日志"
    for FILE in "$CADDY_LOG_DIR"/*.access.log; do [ -f "$FILE" ] && FILES+=("$FILE"); done
    for FILE in "${FILES[@]}"; do INDEX=$((INDEX+1)); printf '  %2d) %s\n' "$INDEX" "$(basename "$FILE")"; done
    systemd_available && printf '   j) Caddy 服务日志（journalctl）\n'
    read -rp "  选择日志 [编号/j，回车返回]: " CH
    [ -n "$CH" ] || return 0
    if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 1 ] && [ "$CH" -le "${#FILES[@]}" ]; then
        caddy_show_log_file "${FILES[$((CH-1))]}"
    elif [[ "$CH" =~ ^[jJ]$ ]] && systemd_available; then
        journalctl -u caddy -n 100 --no-pager 2>/dev/null
    else
        warn "无效选项"
    fi
}

caddy_reload_config() {
    print_header "验证并重载 Caddy"
    if ! caddy_validate "$CADDYFILE"; then
        error "Caddy 配置验证失败"; caddy_show_last_error; return 1
    fi
    if caddy_reload_or_start; then
        info "Caddy 配置已验证并无中断应用 ✓"
        audit_action "验证并重载 Caddy 配置" SUCCESS
    else
        error "Caddy 配置应用失败"
        return 1
    fi
}

caddy_edit_raw() {
    local BACKUP WAS_ACTIVE=false APPLY_FAILED=false
    print_header "高级：编辑 Caddy 主配置"
    warn "Quench 管理的站点位于 ${CADDY_SITES_DIR}；此入口编辑主 Caddyfile。"
    ui_continue
    caddy_lock_acquire || return 1
    BACKUP=$(mktemp "$CADDY_STATE_DIR/Caddyfile-edit.XXXXXX") || { caddy_lock_release; return 1; }
    cp -p "$CADDYFILE" "$BACKUP" || { rm -f "$BACKUP"; caddy_lock_release; return 1; }
    caddy_service_active && WAS_ACTIVE=true
    caddy_backup_before_change raw_edit
    open_editor "$CADDYFILE" || APPLY_FAILED=true
    [ "$APPLY_FAILED" = true ] || caddy_import_markers_valid || APPLY_FAILED=true
    if [ "$APPLY_FAILED" = false ] && [ "$(caddy_managed_site_count)" -gt 0 ]; then
        caddy_import_present || APPLY_FAILED=true
    fi
    [ "$APPLY_FAILED" = true ] || caddy_validate "$CADDYFILE" || APPLY_FAILED=true
    [ "$APPLY_FAILED" = true ] || caddy_reload_or_start || APPLY_FAILED=true
    if [ "$APPLY_FAILED" = true ]; then
        cp -p "$BACKUP" "$CADDYFILE"
        if [ "$WAS_ACTIVE" = true ]; then
            caddy_reload_active >/dev/null 2>&1 || true
        else
            caddy_service_stop >/dev/null 2>&1 || true
        fi
        rm -f "$BACKUP"; caddy_lock_release
        error "编辑结果未通过完整验证，已恢复原 Caddyfile"
        caddy_show_last_error
        return 1
    fi
    rm -f "$BACKUP"; caddy_lock_release
    audit_action "高级编辑 Caddy 主配置" SUCCESS
    info "Caddy 主配置已验证并应用 ✓"
}

caddy_config_backup() {
    config_backup_create caddy_manual
}

caddy_uninstall() {
    local METHOD BIN
    print_header "卸载 Caddy"
    METHOD=$(caddy_detect_install_method); BIN=$(command -v caddy 2>/dev/null || true)
    [ "$(caddy_status)" != unmanaged ] || {
        error "检测到不受服务管理的 Caddy 进程；请先确认并停止该进程，再卸载"
        return 1
    }
    [ "$METHOD" != external ] || {
        error "当前 Caddy 是外部/自定义构建，Quench 不会自动删除"
        return 1
    }
    confirm_change_preview "卸载 Caddy" \
        "停止并禁用 Caddy 服务" "保留 $CADDY_CONFIG_DIR" \
        "保留证书数据 $CADDY_DATA_DIR 和访问日志 $CADDY_LOG_DIR" || return 0
    caddy_service_stop >/dev/null 2>&1 || true
    caddy_service_disable >/dev/null 2>&1 || true
    case "$METHOD" in
        package)
            if command -v opkg >/dev/null 2>&1; then
                opkg remove caddy || { error "软件包卸载失败"; return 1; }
            elif command -v pacman >/dev/null 2>&1; then
                pacman -R --noconfirm caddy || { error "软件包卸载失败"; return 1; }
            else
                pkg_remove caddy || { error "软件包卸载失败"; return 1; }
            fi
            ;;
        binary)
            [ "$BIN" = /usr/local/bin/caddy ] || { error "二进制路径异常，拒绝删除：$BIN"; return 1; }
            rm -f /usr/local/bin/caddy
            if [ -f "$CADDY_SERVICE_FILE" ] && grep -Fqx '# Managed by Quench: Caddy service' "$CADDY_SERVICE_FILE"; then
                rm -f "$CADDY_SERVICE_FILE"; svc_daemon_reload
            fi
            ;;
        *) error "无法确认 Caddy 安装来源"; return 1 ;;
    esac
    rm -f "$CADDY_INSTALL_METHOD_FILE"
    audit_action "卸载 Caddy（保留配置、证书与日志）" SUCCESS
    info "Caddy 已卸载；配置、证书数据和日志均已保留 ✓"
}

caddy_menu() {
    local STATUS COLOR VERSION TOTAL MANAGED CH
    while true; do
        STATUS=$(caddy_status)
        case "$STATUS" in running) COLOR="$GREEN" ;; stopped|unmanaged) COLOR="$YELLOW" ;; *) COLOR="$RED" ;; esac
        print_header "Caddy 轻量网站入口管理"
        if [ "$STATUS" = not_installed ]; then
            echo -e "  状态：${COLOR}${BOLD}未安装${NC}"
            echo -e "  ${DIM}用于静态站、反向代理、重定向和接入现有 PHP-FPM；不管理数据库与应用数据。${NC}"
            menu_div
            menu_item "1" "安装 Caddy"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            read -rp "$(ui_prompt '选择操作 [0-1]: ')" CH
            case "$CH" in 1) caddy_install; ui_pause ;; 0) return ;; 00) exit 0 ;; *) warn "无效选项" ;; esac
            continue
        fi
        VERSION=$(caddy version 2>/dev/null | awk '{print $1}')
        TOTAL=$(caddy_site_count); MANAGED=$(caddy_managed_site_count)
        echo -e "  服务：${COLOR}${BOLD}${STATUS}${NC}  版本：${BOLD}${VERSION:-未知}${NC}"
        echo -e "  站点：${BOLD}${TOTAL}${NC}  Quench 管理：${BOLD}${MANAGED}${NC}"
        menu_div
        menu_pair "1" "查看所有站点" "2" "添加反向代理"
        menu_pair "3" "添加静态网站" "4" "添加永久重定向"
        menu_pair "5" "接入 PHP-FPM" "6" "删除管理站点"
        menu_pair "7" "站点与入口诊断" "8" "访问/服务日志"
        menu_pair "9" "证书状态" "r" "验证并重载"
        menu_pair "e" "高级编辑主配置" "b" "备份 Caddy 配置"
        if [ "$STATUS" = running ]; then
            menu_pair "t" "停止服务" "u" "安全更新 Caddy" "$YELLOW" "$CYAN"
        else
            menu_pair "t" "启动服务" "u" "安全更新 Caddy" "$GREEN" "$CYAN"
        fi
        menu_pair "d" "卸载（保留数据）" "0" "返回主菜单" "$YELLOW" "$RED"
        menu_item "00" "退出脚本" "$RED"
        menu_div
        read -rp "$(ui_prompt '选择操作: ')" CH
        case "$CH" in
            1) caddy_list_sites ;;
            2) caddy_add_proxy ;;
            3) caddy_add_static ;;
            4) caddy_add_redirect ;;
            5) caddy_add_php ;;
            6) caddy_delete_site ;;
            7) caddy_site_diagnostics ;;
            8) caddy_view_logs ;;
            9) caddy_ssl_status ;;
            r|R) caddy_reload_config ;;
            e|E) caddy_edit_raw ;;
            b|B) caddy_config_backup ;;
            t|T)
                if [ "$STATUS" = running ]; then
                    caddy_service_stop && info "Caddy 已停止"
                elif [ "$STATUS" = unmanaged ]; then
                    error "检测到不受服务管理的 Caddy 进程；请先人工确认该进程来源"
                else
                    caddy_service_start && caddy_wait_running && info "Caddy 已启动"
                fi
                ;;
            u|U) caddy_install update ;;
            d|D) caddy_uninstall ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}
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
    FSTAB_BACKUP=$(quench_mktemp "${TMPDIR:-/tmp}/quench-fstab-before.XXXXXX") || { rm -f "$STAGE"; return 1; }
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
    FSTAB_BACKUP=$(quench_mktemp "${TMPDIR:-/tmp}/quench-fstab-before.XXXXXX") || return 1
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
        BACKUP=$(quench_mktemp "${TMPDIR:-/tmp}/quench-swap-sysctl.XXXXXX") || { rm -f "$STAGE"; return 1; }
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
# ══════════════════════════════════════════════════════════
#  STUN / UDP / NAT 检测
# ══════════════════════════════════════════════════════════

stun_ports_normalize() {
    local RAW="${1//,/ }" TOKEN OUT="" SEEN="," COUNT=0
    RAW="${RAW//;/ }"
    for TOKEN in $RAW; do
        case "$TOKEN" in ''|*[!0-9]*) return 1 ;; esac
        [ "$TOKEN" -ge 1 ] && [ "$TOKEN" -le 65535 ] || return 1
        case "$SEEN" in
            *",${TOKEN},"*) continue ;;
        esac
        COUNT=$((COUNT + 1))
        [ "$COUNT" -le 12 ] || return 1
        SEEN="${SEEN}${TOKEN},"
        if [ -n "$OUT" ]; then OUT="${OUT},${TOKEN}"; else OUT="$TOKEN"; fi
    done
    [ -n "$OUT" ] || return 1
    printf '%s\n' "$OUT"
}

stun_host_valid() {
    local HOST="$1"
    [ -n "$HOST" ] && [ "${#HOST}" -le 253 ] || return 1
    [[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$HOST" != *..* ]]
}

stun_nat_type_label() {
    case "$1" in
        open_internet)       echo "公网直连（无 NAT）" ;;
        public_udp_firewall) echo "公网直连 + UDP 过滤" ;;
        full_cone)           echo "Full Cone（全锥型）" ;;
        restricted_cone)     echo "Restricted Cone（地址限制锥型）" ;;
        port_restricted)     echo "Port-Restricted Cone（端口限制锥型）" ;;
        symmetric)           echo "Symmetric NAT（对称型倾向）" ;;
        nat_unknown)         echo "检测到 NAT（细分未知）" ;;
        udp_unavailable)     echo "UDP / STUN 无有效响应" ;;
        *)                   echo "未知" ;;
    esac
}

stun_mapping_label() {
    case "$1" in
        eim)                echo "Endpoint-Independent" ;;
        adm)                echo "Address-Dependent" ;;
        apdm)               echo "Address-and-Port-Dependent" ;;
        endpoint_dependent) echo "Endpoint-Dependent" ;;
        *)                  echo "未知（证据不足）" ;;
    esac
}

stun_filtering_label() {
    case "$1" in
        eif)  echo "Endpoint-Independent" ;;
        adf)  echo "Address-Dependent" ;;
        apdf) echo "Address-and-Port-Dependent" ;;
        *)    echo "未知（服务器不支持或响应不足）" ;;
    esac
}

stun_confidence_label() {
    case "$1" in high) echo "高" ;; medium) echo "中" ;; *) echo "低" ;; esac
}

stun_udp_explanation() {
    local OK_COUNT="$1" TOTAL_COUNT="$2"
    if [ "$OK_COUNT" -eq 0 ]; then
        echo "无节点响应，请检查 UDP 出站、防火墙或上游网络"
    elif [ "$OK_COUNT" -eq "$TOTAL_COUNT" ]; then
        echo "全部节点响应，UDP 出站和返回流量正常"
    else
        echo "${OK_COUNT}/${TOTAL_COUNT} 节点响应，UDP 可用；失败多为节点或路由差异"
    fi
}

stun_nat_explanation() {
    case "$1" in
        open_internet)       echo "本机直接使用公网 IPv4，没有上游 NAT" ;;
        public_udp_firewall) echo "没有 NAT，但 UDP 返回流量受到防火墙限制" ;;
        full_cone)           echo "固定公网映射，外部来源均可回包，P2P 条件较好" ;;
        restricted_cone)     echo "固定映射，仅已联系过的目标 IP 可以回包" ;;
        port_restricted)     echo "固定映射，仅已联系过的目标 IP:端口可以回包" ;;
        symmetric)           echo "映射随目标改变，UDP 打洞和 P2P 直连较困难" ;;
        nat_unknown)         echo "确认存在 NAT，但证据不足，无法继续细分" ;;
        udp_unavailable)     echo "没有 STUN 响应，暂时无法判定 NAT" ;;
        *)                   echo "当前证据无法判断 NAT 类型" ;;
    esac
}

stun_mapping_explanation() {
    case "$1" in
        eim)                echo "访问不同目标时保持同一公网 IP:端口" ;;
        adm)                echo "目标 IP 改变时，公网映射会改变" ;;
        apdm)               echo "目标 IP 或端口改变时，公网映射会改变" ;;
        endpoint_dependent) echo "公网映射随目标变化，依赖类型尚无法细分" ;;
        *)                  echo "响应不足，无法确定公网端口映射规律" ;;
    esac
}

stun_filtering_explanation() {
    case "$1" in
        eif)  echo "建立映射后，任意外部来源均可回包" ;;
        adf)  echo "仅已主动访问的目标 IP 可以回包" ;;
        apdf) echo "仅已主动访问的目标 IP:端口可以回包" ;;
        *)    echo "服务器缺少辅助能力，暂时无法确定回包限制" ;;
    esac
}

stun_confidence_explanation() {
    case "$1" in
        high)   echo "映射和过滤证据完整，判定可靠性较高" ;;
        medium) echo "已获得公网映射，但部分辅助证据不足" ;;
        *)      echo "有效响应或辅助证据不足，结果仅供参考" ;;
    esac
}

stun_recommendation() {
    case "$1" in
        open_internet)       echo "入站仍需确认本机防火墙和服务监听" ;;
        public_udp_firewall) echo "检查本机或上游防火墙的 UDP 入站规则" ;;
        full_cone|restricted_cone|port_restricted)
                             echo "需要公网入站时，优先配置固定端口转发" ;;
        symmetric|nat_unknown)
                             echo "入站服务需端口转发、DMZ、1:1 NAT 或公网 IP" ;;
        *)                   echo "先确认服务商是否允许 UDP，再检查本机防火墙" ;;
    esac
}

stun_ensure_python() {
    command -v python3 >/dev/null 2>&1 && return 0
    info "正在安装 Python 3..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install python3 >/dev/null 2>&1
    else
        pkg_install python3 >/dev/null 2>&1
    fi
    command -v python3 >/dev/null 2>&1 || {
        error "STUN 检测需要 Python 3"
        return 1
    }
}

stun_probe_engine() {
    local MODE="$1" HOST="${2:--}" PORTS="${3:--}"
    python3 - "$MODE" "$HOST" "$PORTS" <<'PY'
import ipaddress
import secrets
import socket
import struct
import sys
import time

COOKIE = 0x2112A442
COOKIE_BYTES = struct.pack("!I", COOKIE)


def emit(*values):
    clean = []
    for value in values:
        text = str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")
        clean.append(text if text else "-")
    print("\t".join(clean))


def decode_address(value, txid, xor_address=False):
    if len(value) < 4:
        raise ValueError("short address")
    family = value[1]
    port = struct.unpack("!H", value[2:4])[0]
    if xor_address:
        port ^= COOKIE >> 16
    if family == 0x01:
        size = 4
        af = socket.AF_INET
    elif family == 0x02:
        size = 16
        af = socket.AF_INET6
    else:
        raise ValueError("unsupported address family")
    if len(value) < 4 + size:
        raise ValueError("short address value")
    packed = value[4:4 + size]
    if xor_address:
        key = COOKIE_BYTES + txid
        packed = bytes(a ^ b for a, b in zip(packed, key[:size]))
    return socket.inet_ntop(af, packed), port


def parse_message(data, expected_txid):
    if len(data) < 20:
        raise ValueError("short STUN header")
    msg_type, msg_len, cookie, txid = struct.unpack("!HHI12s", data[:20])
    if cookie != COOKIE or txid != expected_txid or msg_len > len(data) - 20:
        raise ValueError("invalid STUN response")
    result = {"type": msg_type, "txid": txid}
    offset = 20
    end = 20 + msg_len
    while offset + 4 <= end:
        attr_type, attr_len = struct.unpack("!HH", data[offset:offset + 4])
        value_start = offset + 4
        value_end = value_start + attr_len
        if value_end > end:
            raise ValueError("invalid STUN attribute length")
        value = data[value_start:value_end]
        try:
            if attr_type == 0x0020:
                result["xor_mapped"] = decode_address(value, txid, True)
            elif attr_type == 0x0001:
                result["mapped"] = decode_address(value, txid, False)
            elif attr_type == 0x0005:
                result["changed"] = decode_address(value, txid, False)
            elif attr_type == 0x802B:
                result["response_origin"] = decode_address(value, txid, False)
            elif attr_type == 0x802C:
                result["other"] = decode_address(value, txid, False)
            elif attr_type == 0x0009 and len(value) >= 4:
                result["error"] = (value[2] & 0x07) * 100 + value[3]
        except (OSError, ValueError):
            pass
        offset = value_start + ((attr_len + 3) // 4) * 4
    result["mapped_address"] = result.get("xor_mapped") or result.get("mapped")
    return result


def binding_request(sock, address, change_flags=0, timeout=1.0, retries=2):
    txid = secrets.token_bytes(12)
    attrs = struct.pack("!HHI", 0x0003, 4, change_flags) if change_flags else b""
    packet = struct.pack("!HHI12s", 0x0001, len(attrs), COOKIE, txid) + attrs
    started = time.monotonic()
    last_error = "timeout"
    for _ in range(retries):
        try:
            sock.sendto(packet, address)
        except OSError as exc:
            return None, exc.__class__.__name__, int((time.monotonic() - started) * 1000)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, source = sock.recvfrom(4096)
            except socket.timeout:
                break
            except OSError as exc:
                last_error = exc.__class__.__name__
                break
            try:
                response = parse_message(data, txid)
            except ValueError:
                continue
            response["source"] = (source[0], source[1])
            elapsed = int((time.monotonic() - started) * 1000)
            if response.get("type") == 0x0101 and response.get("mapped_address"):
                return response, "ok", elapsed
            if response.get("type") == 0x0111:
                return response, "stun_error", elapsed
    return None, last_error, int((time.monotonic() - started) * 1000)


def route_source_ip(address):
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(address)
        return probe.getsockname()[0]
    except OSError:
        return "-"
    finally:
        probe.close()


def safe_other_address(address):
    if not address:
        return False
    try:
        ip = ipaddress.ip_address(address[0])
        return ip.version == 4 and ip.is_global and 1 <= int(address[1]) <= 65535
    except (ValueError, TypeError):
        return False


def classify_nat(success_count, has_nat, mapping, filtering):
    if success_count == 0:
        return "udp_unavailable"
    if has_nat is False:
        if filtering in ("adf", "apdf"):
            return "public_udp_firewall"
        return "open_internet"
    if mapping in ("adm", "apdm", "endpoint_dependent"):
        return "symmetric"
    if mapping == "eim":
        if filtering == "eif":
            return "full_cone"
        if filtering == "adf":
            return "restricted_cone"
        if filtering == "apdf":
            return "port_restricted"
    return "nat_unknown"


def self_test():
    txid = bytes(range(12))
    expected_ip = "203.0.113.7"
    expected_port = 54321
    raw_ip = socket.inet_pton(socket.AF_INET, expected_ip)
    encoded_ip = bytes(a ^ b for a, b in zip(raw_ip, COOKIE_BYTES))
    encoded_port = expected_port ^ (COOKIE >> 16)
    value = b"\x00\x01" + struct.pack("!H", encoded_port) + encoded_ip
    attribute = struct.pack("!HH", 0x0020, len(value)) + value
    packet = struct.pack("!HHI12s", 0x0101, len(attribute), COOKIE, txid) + attribute
    parsed = parse_message(packet, txid)
    assert parsed["mapped_address"] == (expected_ip, expected_port)
    try:
        parse_message(packet, b"wrong-tx-id!")
        raise AssertionError("transaction ID mismatch was accepted")
    except ValueError:
        pass
    assert classify_nat(2, True, "eim", "eif") == "full_cone"
    assert classify_nat(2, True, "eim", "adf") == "restricted_cone"
    assert classify_nat(2, True, "eim", "apdf") == "port_restricted"
    assert classify_nat(2, True, "apdm", "unknown") == "symmetric"
    assert classify_nat(2, False, "eim", "apdf") == "public_udp_firewall"
    assert classify_nat(0, None, "unknown", "unknown") == "udp_unavailable"
    emit("SELFTEST", "ok")


def endpoint_list(mode, host, ports):
    if mode == "quick":
        return [
            ("stun.nextcloud.com", 443),
            ("stun.nextcloud.com", 3478),
            ("stun.cloudflare.com", 3478),
            ("stun.l.google.com", 19302),
            ("stun.miwifi.com", 3478),
        ]
    return [(host, int(port)) for port in ports.split(",")]


def main(mode, host, ports):
    if mode == "selftest":
        self_test()
        return
    endpoints = endpoint_list(mode, host, ports)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    local_port = sock.getsockname()[1]
    results = []
    for endpoint_host, endpoint_port in endpoints:
        record = {"host": endpoint_host, "port": endpoint_port, "status": "dns_error"}
        try:
            answers = socket.getaddrinfo(endpoint_host, endpoint_port, socket.AF_INET, socket.SOCK_DGRAM)
            resolved_ip = answers[0][4][0]
            address = (resolved_ip, endpoint_port)
            record.update({"resolved": resolved_ip, "address": address})
            response, status, elapsed = binding_request(sock, address)
            record.update({"response": response, "status": status, "elapsed": elapsed})
            if response and response.get("mapped_address"):
                record["mapped"] = response["mapped_address"]
        except (OSError, ValueError) as exc:
            record["error"] = exc.__class__.__name__
        results.append(record)

    successful = [record for record in results if record.get("mapped")]
    local_ip = route_source_ip(successful[0]["address"]) if successful else "-"
    external = successful[0]["mapped"] if successful else None

    evidence = []
    for index, left in enumerate(successful):
        for right in successful[index + 1:]:
            if left["address"] != right["address"]:
                evidence.append((left["address"], left["mapped"], right["address"], right["mapped"]))

    for record in successful:
        other = record["response"].get("other") or record["response"].get("changed")
        if safe_other_address(other) and other != record["address"]:
            other_response, _, _ = binding_request(sock, other)
            if other_response and other_response.get("mapped_address"):
                evidence.append((record["address"], record["mapped"], other, other_response["mapped_address"]))

    same_ip_equal = same_ip_diff = cross_ip_equal = cross_ip_diff = False
    for first_address, first_mapping, second_address, second_mapping in evidence:
        same_mapping = first_mapping == second_mapping
        if first_address[0] == second_address[0] and first_address[1] != second_address[1]:
            same_ip_equal |= same_mapping
            same_ip_diff |= not same_mapping
        elif first_address[0] != second_address[0]:
            cross_ip_equal |= same_mapping
            cross_ip_diff |= not same_mapping
    if same_ip_diff:
        mapping = "apdm"
    elif cross_ip_diff:
        mapping = "adm" if same_ip_equal else "endpoint_dependent"
    elif same_ip_equal or cross_ip_equal:
        mapping = "eim"
    else:
        mapping = "unknown"

    filtering = "unknown"
    filtering_evidence = False
    for record in successful:
        response = record["response"]
        other = response.get("other") or response.get("changed")
        if not safe_other_address(other):
            continue
        origin = response.get("source")
        alternate_ip_available = bool(origin and other[0] != origin[0])
        changed, changed_status, _ = binding_request(sock, record["address"], 0x06)
        if changed and origin and changed.get("source") != origin:
            changed_source = changed["source"]
            if changed_source[0] != origin[0]:
                filtering = "eif"
                filtering_evidence = True
                break
            # A port-only source change does not prove that the server honored CHANGE-IP.
            continue
        if changed and origin and changed.get("source") == origin:
            continue
        changed_port, port_status, _ = binding_request(sock, record["address"], 0x02)
        if alternate_ip_available and changed_port and origin and changed_port.get("source") != origin:
            port_source = changed_port["source"]
            filtering = "eif" if port_source[0] != origin[0] else "adf"
            filtering_evidence = True
            break
        if changed_port and origin and changed_port.get("source") == origin:
            continue
        if alternate_ip_available and changed_status == "timeout" and port_status == "timeout":
            filtering = "apdf"
            filtering_evidence = True
            break

    has_nat = None
    if external and local_ip != "-":
        has_nat = external[0] != local_ip
    nat_type = classify_nat(len(successful), has_nat, mapping, filtering)
    if nat_type in ("open_internet", "public_udp_firewall") and filtering_evidence:
        confidence = "high"
    elif mapping != "unknown" and filtering_evidence:
        confidence = "high"
    elif len(successful) >= 2 or has_nat is not None:
        confidence = "medium"
    else:
        confidence = "low"

    for record in results:
        mapped = record.get("mapped")
        mapped_text = f"{mapped[0]}:{mapped[1]}" if mapped else "-"
        emit(
            "PROBE", record["host"], record["port"], record.get("resolved", "-"),
            "ok" if mapped else record.get("status", "error"), mapped_text,
            record.get("elapsed", "-"), record.get("error", "-"),
        )
    for port in sorted({record["port"] for record in results}):
        port_records = [record for record in results if record["port"] == port]
        ok_count = sum(1 for record in port_records if record.get("mapped"))
        emit("PORT", port, ok_count, len(port_records))
    external_text = f"{external[0]}:{external[1]}" if external else "-"
    emit(
        "SUMMARY", local_ip, local_port, external_text, mapping, filtering, nat_type,
        confidence, len(successful), len(results),
    )
    sock.close()


try:
    main(sys.argv[1], sys.argv[2], sys.argv[3])
except Exception as exc:
    emit("FATAL", exc.__class__.__name__)
    raise SystemExit(1)
PY
}

stun_render_results() {
    local OUTPUT="$1" KIND A B C D E F G H I
    local LOCAL_IP="-" LOCAL_PORT="-" EXTERNAL="-" MAPPING="unknown" FILTERING="unknown"
    local NAT_TYPE="unknown" CONFIDENCE="low" OK_COUNT=0 TOTAL_COUNT=0

    echo -e "  ${BOLD}STUN 端点${NC}"
    while IFS=$'\t' read -r KIND A B C D E F G H I; do
        case "$KIND" in
            PROBE)
                if [ "$D" = "ok" ]; then
                    echo -e "  ${GREEN}✓${NC}  ${A}:${B}  ${BOLD}${E}${NC}  ${DIM}${F}ms${NC}"
                else
                    echo -e "  ${RED}×${NC}  ${A}:${B}  ${YELLOW}${D}${NC}"
                fi
                ;;
            PORT)
                printf '  UDP/%-5s  %s/%s 响应\n' "$A" "$B" "$C"
                ;;
            SUMMARY)
                LOCAL_IP="$A"; LOCAL_PORT="$B"; EXTERNAL="$C"; MAPPING="$D"; FILTERING="$E"
                NAT_TYPE="$F"; CONFIDENCE="$G"; OK_COUNT="$H"; TOTAL_COUNT="$I"
                ;;
            FATAL)
                error "STUN 协议引擎执行失败：${A}"
                return 1
                ;;
        esac
    done <<< "$OUTPUT"

    echo ""
    menu_div
    echo -e "  本地出口 : ${BOLD}${LOCAL_IP}:${LOCAL_PORT}${NC}"
    echo -e "  公网映射 : ${BOLD}${EXTERNAL}${NC}"
    echo -e "  有效响应 : ${BOLD}${OK_COUNT}/${TOTAL_COUNT}${NC}"
    echo -e "  IPv4 NAT : ${CYAN}${BOLD}$(stun_nat_type_label "$NAT_TYPE")${NC}"
    echo -e "  映射行为 : ${BOLD}$(stun_mapping_label "$MAPPING")${NC}"
    echo -e "  过滤行为 : ${BOLD}$(stun_filtering_label "$FILTERING")${NC}"
    echo -e "  判定置信 : ${BOLD}$(stun_confidence_label "$CONFIDENCE")${NC}"
    menu_div
    echo -e "  ${BOLD}结果解释${NC}"
    echo -e "  ${CYAN}UDP${NC}  : $(stun_udp_explanation "$OK_COUNT" "$TOTAL_COUNT")"
    echo -e "  ${CYAN}NAT${NC}  : $(stun_nat_explanation "$NAT_TYPE")"
    echo -e "  ${CYAN}映射${NC} : $(stun_mapping_explanation "$MAPPING")"
    echo -e "  ${CYAN}过滤${NC} : $(stun_filtering_explanation "$FILTERING")"
    echo -e "  ${CYAN}置信${NC} : $(stun_confidence_explanation "$CONFIDENCE")"
    echo -e "  ${CYAN}建议${NC} : $(stun_recommendation "$NAT_TYPE")"
    menu_div
}

stun_probe_execute() {
    local MODE="$1" HOST="${2:--}" PORTS="${3:--}" OUTPUT
    stun_ensure_python || return 1
    info "正在执行 STUN 与多端口 UDP 探测..."
    if ! OUTPUT=$(stun_probe_engine "$MODE" "$HOST" "$PORTS"); then
        error "STUN 检测执行失败"
        return 1
    fi
    stun_render_results "$OUTPUT" || return 1
    audit_action "STUN NAT 检测 ${MODE} ${HOST} ${PORTS}" SUCCESS
}

stun_nat_quick() {
    print_header "STUN / NAT 检测"
    stun_probe_execute quick
}

stun_nat_custom() {
    print_header "自定义 STUN 多端口"
    local HOST PORT_INPUT PORTS
    read -rp "  STUN 主机（默认 stun.nextcloud.com）: " HOST
    HOST=${HOST:-stun.nextcloud.com}
    stun_host_valid "$HOST" || { error "STUN 主机格式无效"; return 1; }
    read -rp "  UDP 端口（逗号分隔，默认 443,3478）: " PORT_INPUT
    PORT_INPUT=${PORT_INPUT:-443,3478}
    PORTS=$(stun_ports_normalize "$PORT_INPUT") || {
        error "端口格式无效，仅支持 1-65535，最多 12 个"
        return 1
    }
    echo ""
    stun_probe_execute custom "$HOST" "$PORTS"
}

stun_nat_menu() {
    while true; do
        print_header "STUN / NAT 检测"
        menu_item "1" "快速检测"
        menu_item "2" "自定义 STUN 多端口" "$CYAN"
        menu_item "0" "返回上级" "$RED"
        menu_div
        echo ""
        local CH
        read -rp "$(ui_prompt '选择操作 [0-2]: ')" CH
        case "$CH" in
            1) stun_nat_quick; ui_pause ;;
            2) stun_nat_custom; ui_pause ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
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
# ══════════════════════════════════════════════════════════
#  首次开荒向导
# ══════════════════════════════════════════════════════════

FIRST_RUN_NETWORK_SECURITY_FILE="${FIRST_RUN_NETWORK_SECURITY_FILE:-/etc/sysctl.d/98-vps-quench-network-security.conf}"

first_run_route_ok() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -4 route get 1.1.1.1 >/dev/null 2>&1 \
        || ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
}

first_run_dns_ok() {
    if command -v getent >/dev/null 2>&1; then
        getent ahosts github.com >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup github.com >/dev/null 2>&1
    else
        ping -c 1 -W 3 github.com >/dev/null 2>&1
    fi
}

first_run_access_ready() {
    [ "$(user_ready_admin_count)" -gt 0 ] \
        && [ "$(get_config PasswordAuthentication)" = no ] \
        && [ "$(get_config KbdInteractiveAuthentication)" = no ] \
        && [ "$(get_config PubkeyAuthentication)" = yes ] \
        && [ "$(get_config PermitRootLogin)" = no ] \
        && ! ssh_read_port_state
}

first_run_firewall_ready() {
    local TYPE PORT
    TYPE=$(fw_detect)
    case "$TYPE" in
        ufw|firewalld) [ "$(fw_running "$TYPE")" = active ] || return 1 ;;
        *) return 1 ;;
    esac
    while IFS= read -r PORT; do
        [ -n "$PORT" ] || continue
        firewall_port_ready "$PORT" || return 1
    done < <(ssh_effective_ports)
}

first_run_fail2ban_ready() {
    [ "$(f2b_status)" = running ] \
        && f2b_managed_ports_match "$(ssh_effective_ports_csv)" \
        && f2b_runtime_healthy
}

first_run_ssh_baseline_ready() {
    [ "$(get_config PubkeyAuthentication)" = yes ] \
        && [ "$(get_config PermitEmptyPasswords)" = no ] \
        && [ "$(get_config MaxAuthTries)" = 4 ] \
        && [ "$(get_config LoginGraceTime)" = 30 ] \
        && [ "$(get_config X11Forwarding)" = no ]
}

first_run_network_security_pairs() {
    cat <<'EOF'
net.ipv4.tcp_syncookies|1
net.ipv4.conf.all.accept_redirects|0
net.ipv4.conf.default.accept_redirects|0
net.ipv4.conf.all.send_redirects|0
net.ipv4.conf.default.send_redirects|0
net.ipv4.conf.all.accept_source_route|0
net.ipv4.conf.default.accept_source_route|0
net.ipv4.icmp_echo_ignore_broadcasts|1
net.ipv4.icmp_ignore_bogus_error_responses|1
net.ipv6.conf.all.accept_redirects|0
net.ipv6.conf.default.accept_redirects|0
EOF
}

first_run_sysctl_file_value() {
    local KEY="$1" FILE="${2:-$FIRST_RUN_NETWORK_SECURITY_FILE}"
    awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            value=$0
        }
        END {if (value != "") print value}
    ' "$FILE" 2>/dev/null
}

first_run_network_security_ready() {
    local KEY EXPECTED CURRENT PERSISTED SUPPORTED=0
    command -v sysctl >/dev/null 2>&1 || return 1
    [ -f "$FIRST_RUN_NETWORK_SECURITY_FILE" ] || return 1
    while IFS='|' read -r KEY EXPECTED; do
        [ -n "$KEY" ] || continue
        CURRENT=$(sysctl -n "$KEY" 2>/dev/null) || continue
        SUPPORTED=$((SUPPORTED + 1))
        PERSISTED=$(first_run_sysctl_file_value "$KEY")
        [ "$CURRENT" = "$EXPECTED" ] && [ "$PERSISTED" = "$EXPECTED" ] || return 1
    done < <(first_run_network_security_pairs)
    [ "$SUPPORTED" -gt 0 ]
}

first_run_status_label() {
    "$@" >/dev/null 2>&1 && printf '已完成\n' || printf '需配置\n'
}

first_run_status_state() {
    "$@" >/dev/null 2>&1 && printf 'active\n' || printf 'warning\n'
}

first_run_print_status() {
    local DNS_LABEL DNS_STATE ACCESS_LABEL ACCESS_STATE FW_LABEL FW_STATE
    local F2B_LABEL F2B_STATE SSH_LABEL SSH_STATE UPDATE_LABEL UPDATE_STATE
    local NET_LABEL NET_STATE BBR_LABEL BBR_STATE TIME_LABEL TIME_STATE TIME_BACKEND
    if first_run_route_ok && first_run_dns_ok; then DNS_LABEL="正常"; DNS_STATE=active
    else DNS_LABEL="需检查"; DNS_STATE=warning; fi
    ACCESS_LABEL=$(first_run_status_label first_run_access_ready)
    ACCESS_STATE=$(first_run_status_state first_run_access_ready)
    FW_LABEL=$(first_run_status_label first_run_firewall_ready)
    FW_STATE=$(first_run_status_state first_run_firewall_ready)
    F2B_LABEL=$(first_run_status_label first_run_fail2ban_ready)
    F2B_STATE=$(first_run_status_state first_run_fail2ban_ready)
    SSH_LABEL=$(first_run_status_label first_run_ssh_baseline_ready)
    SSH_STATE=$(first_run_status_state first_run_ssh_baseline_ready)
    if system_auto_updates_supported; then
        UPDATE_LABEL=$(first_run_status_label system_auto_updates_enabled)
        UPDATE_STATE=$(first_run_status_state system_auto_updates_enabled)
    else
        UPDATE_LABEL="不支持"; UPDATE_STATE=unknown
    fi
    NET_LABEL=$(first_run_status_label first_run_network_security_ready)
    NET_STATE=$(first_run_status_state first_run_network_security_ready)
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_LABEL="已启用"; BBR_STATE=active
    else
        BBR_LABEL="可选"; BBR_STATE=unknown
    fi
    TIME_BACKEND=$(ts_backend_detect)
    if ts_ntp_synchronized "$TIME_BACKEND"; then
        TIME_LABEL="已同步"; TIME_STATE=active
    elif [ "$TIME_BACKEND" = conflict ]; then
        TIME_LABEL="后端冲突"; TIME_STATE=warning
    else
        TIME_LABEL="需检查"; TIME_STATE=warning
    fi

    status_pair "网络 / DNS" "$DNS_LABEL" "$DNS_STATE" "用户 / SSH" "$ACCESS_LABEL" "$ACCESS_STATE"
    status_pair "防火墙" "$FW_LABEL" "$FW_STATE" "Fail2ban" "$F2B_LABEL" "$F2B_STATE"
    status_pair "SSH 基线" "$SSH_LABEL" "$SSH_STATE" "自动更新" "$UPDATE_LABEL" "$UPDATE_STATE"
    status_pair "网络安全" "$NET_LABEL" "$NET_STATE" "时间同步" "$TIME_LABEL" "$TIME_STATE"
    status_pair "BBR" "$BBR_LABEL" "$BBR_STATE"
}

first_run_preflight() {
    print_header "首次开荒 · 环境、DNS 与时间预检"
    local OS_INFO KERNEL VIRT IFACE ROUTE_STATE=warning DNS_STATE=warning TIME_STATE=warning
    local TIME_BACKEND ANSWER
    OS_INFO=$(detect_os 2>/dev/null || echo unknown)
    KERNEL=$(uname -r 2>/dev/null || echo unknown)
    VIRT=$(systemd-detect-virt 2>/dev/null || true)
    VIRT=${VIRT:-unknown}
    IFACE=$(default_iface 2>/dev/null || true)
    first_run_route_ok && ROUTE_STATE=active
    first_run_dns_ok && DNS_STATE=active
    TIME_BACKEND=$(ts_backend_detect)
    ts_ntp_synchronized "$TIME_BACKEND" && TIME_STATE=active
    status_pair "系统" "$OS_INFO · $KERNEL" active "虚拟化" "$VIRT" unknown
    status_pair "默认网卡" "${IFACE:-未检测到}" "$ROUTE_STATE" "DNS 解析" "$([ "$DNS_STATE" = active ] && echo 正常 || echo 失败)" "$DNS_STATE"
    status_pair "时间同步" "$([ "$TIME_STATE" = active ] && echo 正常 || echo 需检查)" "$TIME_STATE" "NTP 后端" "$(ts_backend_label "$TIME_BACKEND")" "$TIME_STATE"
    echo ""
    if [ "$ROUTE_STATE" != active ]; then
        error "没有可用的 IPv4/IPv6 默认路由，请先修复网络"
        audit_action "首次开荒环境预检：默认路由失败" FAILED
        return 1
    fi
    if [ "$DNS_STATE" = active ]; then
        info "当前 DNS 解析正常，按安全默认保持现有配置不变"
        if [ "$TIME_STATE" != active ]; then
            warn "系统时间尚未确认同步；建议完成向导后进入时间模块诊断或修复"
        fi
        audit_action "首次开荒环境与 DNS 预检" SUCCESS
        return 0
    fi
    warn "当前 DNS 无法解析 github.com；继续安装软件前建议先修复"
    read -rp "  是否进入 DNS 管理进行修复？(Y/n，默认Y): " ANSWER
    ANSWER=${ANSWER:-y}
    if echo "$ANSWER" | grep -qiE '^y(es)?$'; then
        dns_menu
        if first_run_dns_ok; then
            info "DNS 解析已恢复"
            [ "$TIME_STATE" = active ] || warn "系统时间尚未确认同步；建议进入时间模块诊断或修复"
            return 0
        fi
    fi
    audit_action "首次开荒环境预检：DNS 失败" FAILED
    return 1
}

first_run_ssh_baseline_render() {
    local FILE="$1"
    set_config_file "$FILE" PubkeyAuthentication yes
    set_config_file "$FILE" PermitEmptyPasswords no
    set_config_file "$FILE" MaxAuthTries 4
    set_config_file "$FILE" LoginGraceTime 30
    set_config_file "$FILE" X11Forwarding no
}

first_run_ssh_baseline_apply() {
    print_header "首次开荒 · SSH 基础加固"
    first_run_ssh_baseline_ready && { info "SSH 基础加固已经生效，无需重复修改"; return 0; }
    command -v sshd >/dev/null 2>&1 || { error "未找到 sshd，无法应用 SSH 基线"; return 1; }
    [ -f "$SSHD_CONFIG" ] || { error "SSH 主配置不存在：$SSHD_CONFIG"; return 1; }
    local CANDIDATE
    CANDIDATE=$(quench_mktemp) || return 1
    cp "$SSHD_CONFIG" "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    first_run_ssh_baseline_render "$CANDIDATE" || { rm -f "$CANDIDATE"; return 1; }
    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 基础加固"; then
        rm -f "$CANDIDATE"
        warn "已取消，SSH 配置未修改"
        return 0
    fi
    backup_config || { rm -f "$CANDIDATE"; return 1; }
    if ! atomic_replace_file "$CANDIDATE" "$SSHD_CONFIG"; then
        rm -f "$CANDIDATE"
        error "SSH 配置写入失败"
        return 1
    fi
    rm -f "$CANDIDATE"
    if ! apply_and_restart || ! first_run_ssh_baseline_ready; then
        error "SSH 基础参数未完全生效，正在恢复"
        ssh_restore_last_backup
        return 1
    fi
    audit_action "应用首次开荒 SSH 基础加固" SUCCESS
    info "SSH 基础加固已生效：认证尝试 4 次、登录等待 30 秒、关闭 X11 转发"
}

first_run_network_security_restore() {
    local EXISTED="$1" BACKUP="$2" RUNTIME="$3" KEY VALUE
    if [ "$EXISTED" = yes ]; then
        cp "$BACKUP" "$FIRST_RUN_NETWORK_SECURITY_FILE" 2>/dev/null || true
    else
        rm -f "$FIRST_RUN_NETWORK_SECURITY_FILE"
    fi
    while IFS='|' read -r KEY VALUE; do
        [ -n "$KEY" ] || continue
        sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || true
    done < "$RUNTIME"
}

first_run_network_security_apply() {
    print_header "首次开荒 · 内核网络安全基线"
    first_run_network_security_ready && { info "内核网络安全基线已经生效"; return 0; }
    ensure_sysctl || return 1
    has_sysctl_write || { error "当前容器或宿主机不允许写入 sysctl"; return 1; }
    local CANDIDATE RUNTIME BACKUP EXISTED=no KEY EXPECTED CURRENT COUNT=0
    CANDIDATE=$(quench_mktemp) || return 1
    RUNTIME=$(quench_mktemp) || { rm -f "$CANDIDATE"; return 1; }
    BACKUP=$(quench_mktemp) || { rm -f "$CANDIDATE" "$RUNTIME"; return 1; }
    {
        echo "# Managed by Quench first-run network security baseline."
        echo "# Performance tuning remains in /etc/sysctl.d/99-quench-bbr.conf."
        while IFS='|' read -r KEY EXPECTED; do
            [ -n "$KEY" ] || continue
            if CURRENT=$(sysctl -n "$KEY" 2>/dev/null); then
                printf '%s|%s\n' "$KEY" "$CURRENT" >> "$RUNTIME"
                printf '%s = %s\n' "$KEY" "$EXPECTED"
                COUNT=$((COUNT + 1))
            fi
        done < <(first_run_network_security_pairs)
    } > "$CANDIDATE"
    if [ "$COUNT" -eq 0 ]; then
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        error "当前内核没有可应用的网络安全参数"
        return 1
    fi
    if ! confirm_change_preview "内核网络安全基线" \
        "关闭 ICMP redirect、source route 与 IPv6 redirect 接受" \
        "启用 SYN cookies，并忽略广播 ICMP 与异常 ICMP 错误" \
        "只写入当前内核实际支持的 ${COUNT} 个参数" \
        "不修改 BBR、缓冲区、转发和 swappiness"; then
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        warn "已取消，内核网络参数未修改"
        return 0
    fi
    if [ -f "$FIRST_RUN_NETWORK_SECURITY_FILE" ]; then
        cp "$FIRST_RUN_NETWORK_SECURITY_FILE" "$BACKUP" || { rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"; return 1; }
        EXISTED=yes
    fi
    safety_arm first_run_network_security || { rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"; return 1; }
    if ! { mkdir -p "$(dirname "$FIRST_RUN_NETWORK_SECURITY_FILE")" \
        && cp "$CANDIDATE" "$FIRST_RUN_NETWORK_SECURITY_FILE" \
        && chmod 0644 "$FIRST_RUN_NETWORK_SECURITY_FILE"; } \
        || ! sysctl -p "$FIRST_RUN_NETWORK_SECURITY_FILE" >/dev/null 2>&1 \
        || ! first_run_network_security_ready; then
        error "网络安全基线应用失败，正在恢复原参数"
        first_run_network_security_restore "$EXISTED" "$BACKUP" "$RUNTIME"
        cancel_safety_timer
        rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
        audit_action "应用首次开荒内核网络安全基线" FAILED
        return 1
    fi
    rm -f "$CANDIDATE" "$RUNTIME" "$BACKUP"
    audit_action "应用首次开荒内核网络安全基线" SUCCESS
    info "内核网络安全基线已应用，BBR 性能配置未被改动"
    safety_confirm
}

first_run_access_setup() {
    print_header "首次开荒 · 用户与 SSH 安全接管"
    first_run_access_ready && { info "非 root 公钥管理员和推荐 SSH 登录策略已经就绪"; return 0; }
    if ssh_read_port_state; then
        warn "检测到未完成的 SSH 端口迁移：$OLD_PORT → $NEW_PORT"
        change_port
        ssh_read_port_state && { warn "请先完成或回滚 SSH 端口迁移"; return 1; }
    fi
    if [ "$(user_ready_admin_count)" -eq 0 ]; then
        user_recommended_wizard
        first_run_access_ready
        return $?
    fi

    local ADMIN CONFIRM
    info "检测到可通过公钥接管的非 root 管理员，可直接完成 SSH 安全策略"
    ADMIN=$(user_select_ready_admin) || { warn "未选择管理员"; return 1; }
    warn "请先在另一个终端用 $ADMIN 的密钥登录，并成功执行 sudo -v"
    read -rp "  测试成功后输入管理员用户名 $ADMIN: " CONFIRM
    [ "$CONFIRM" = "$ADMIN" ] || { warn "未确认，SSH 策略未修改"; return 1; }
    read -rp "  是否先迁移 SSH 端口？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' && change_port
    ssh_apply_recommended_policy "$ADMIN" || return 1
    first_run_access_ready
}

first_run_recommended_firewall() {
    if command -v apt-get >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; then
        printf 'ufw\n'
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        printf 'firewalld\n'
    else
        printf 'unknown\n'
    fi
}

first_run_firewall_fail2ban_setup() {
    print_header "首次开荒 · 防火墙与 Fail2ban"
    local TYPE RECOMMENDED
    TYPE=$(fw_detect)
    case "$TYPE" in
        conflict)
            error "检测到 UFW 与 firewalld 冲突，请先选择并整理防火墙后端"
            firewall_menu
            ;;
        ufw|firewalld)
            if [ "$(fw_running "$TYPE")" != active ] || ! first_run_firewall_ready; then
                fw_install "$TYPE" || return 1
            else
                info "$TYPE 已运行，SSH 端口规则验证通过"
            fi
            ;;
        none)
            RECOMMENDED=$(first_run_recommended_firewall)
            if [ "$RECOMMENDED" = unknown ]; then
                warn "无法自动推荐防火墙后端，请手动选择"
                firewall_menu
            else
                info "根据当前发行版推荐安装 $RECOMMENDED"
                fw_install "$RECOMMENDED" || return 1
            fi
            ;;
    esac
    first_run_firewall_ready || { error "防火墙尚未达到最小开放并保护 SSH 的状态"; return 1; }
    if safety_timer_pending; then
        warn "防火墙防断联回滚仍在计时；确认连接后再继续配置 Fail2ban"
        return 1
    fi
    if first_run_fail2ban_ready; then
        info "Fail2ban sshd jail 已运行，端口与当前 SSH 一致"
    else
        f2b_install || return 1
    fi
    first_run_fail2ban_ready || { error "Fail2ban 尚未通过运行状态与端口检查"; return 1; }
    audit_action "完成首次开荒防火墙与 Fail2ban" SUCCESS
}

first_run_auto_updates_apply() {
    print_header "首次开荒 · 自动安全更新"
    system_auto_updates_supported \
        || { warn "当前发行版不支持由 Quench 自动托管安全更新"; return 1; }
    system_auto_updates_enabled && { info "自动安全更新已经启用"; return 0; }
    confirm_change_preview "自动安全更新" \
        "启用发行版提供的定时安全更新" \
        "Debian / Ubuntu 明确禁止 unattended-upgrades 自动重启" \
        "更新安装后如需重启，将由系统提示并交给管理员安排" \
        || { warn "已取消"; return 0; }
    system_enable_auto_security_updates
}

first_run_final_audit() {
    security_audit
    echo ""
    menu_group "首次开荒基线"
    first_run_print_status
    audit_action "执行首次开荒最终体检" SUCCESS
}

first_run_offer_step() {
    local LABEL="$1" DEFAULT="$2" FUNCTION="$3" ANSWER
    read -rp "  ${LABEL}？($([ "$DEFAULT" = y ] && echo 'Y/n，默认Y' || echo 'y/N，默认N')): " ANSWER
    ANSWER=${ANSWER:-$DEFAULT}
    echo "$ANSWER" | grep -qiE '^y(es)?$' || { info "已跳过：$LABEL"; return 0; }
    "$FUNCTION"
}

first_run_recommended_flow() {
    print_header "首次开荒 · 推荐流程"
    echo "  环境与 DNS 预检 → 配置备份 → 用户与 SSH → 防火墙与 Fail2ban"
    echo "  → SSH 基线 → 自动安全更新 → 网络安全基线 → 可选 BBR → 最终体检"
    echo ""
    ui_hint "每一步都会单独确认；已完成项目按实时状态跳过，可随时退出后重新进入"
    local ANSWER BACKUP
    read -rp "  开始推荐流程？(y/N): " ANSWER
    echo "$ANSWER" | grep -qiE '^y(es)?$' || return 0

    first_run_preflight || { warn "预检未通过，推荐流程已停止"; return 1; }
    BACKUP=$(config_backup_create first_run_wizard true) \
        && info "配置快照已创建：$BACKUP" \
        || { error "配置备份失败，推荐流程已停止"; return 1; }

    first_run_access_ready \
        || first_run_offer_step "配置用户与 SSH 安全接管" y first_run_access_setup \
        || { warn "用户与 SSH 步骤未完成，可稍后继续"; return 1; }
    first_run_firewall_ready && first_run_fail2ban_ready \
        || first_run_offer_step "配置防火墙与 Fail2ban" y first_run_firewall_fail2ban_setup \
        || { warn "防火墙与 Fail2ban 步骤未完成，可稍后继续"; return 1; }
    first_run_ssh_baseline_ready \
        || first_run_offer_step "应用 SSH 基础加固" y first_run_ssh_baseline_apply \
        || { warn "SSH 基础加固未完成，可稍后继续"; return 1; }
    if system_auto_updates_supported; then
        system_auto_updates_enabled \
            || first_run_offer_step "启用自动安全更新" y first_run_auto_updates_apply \
            || { warn "自动安全更新未完成，可稍后继续"; return 1; }
    else
        info "当前发行版不支持由 Quench 自动托管安全更新，已跳过"
    fi
    first_run_network_security_ready \
        || first_run_offer_step "应用内核网络安全基线" y first_run_network_security_apply \
        || { warn "内核网络安全基线未完成，可稍后继续"; return 1; }
    if safety_timer_pending; then
        warn "防断联回滚仍在计时；确认网络正常后再继续 BBR"
        return 1
    fi
    if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
        first_run_offer_step "进入 BBR 智能向导（可选）" n bbr_smart_wizard || true
    fi
    first_run_final_audit
    info "首次开荒推荐流程已执行完成；请处理体检中仍显示的警告"
}

first_run_wizard() {
    local CHOICE BACKUP
    while true; do
        print_header "首次开荒向导"
        menu_group "实时状态"
        first_run_print_status
        echo ""
        menu_group "开荒步骤"
        menu_pair "1" "环境与 DNS 预检" "2" "创建配置备份"
        menu_pair "3" "用户与 SSH 安全接管" "4" "防火墙与 Fail2ban"
        menu_pair "5" "SSH 基础加固" "6" "自动安全更新"
        menu_pair "7" "内核网络安全基线" "8" "BBR 智能向导"
        menu_pair "9" "最终安全体检" "r" "按推荐顺序执行" "$CYAN" "$GREEN"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择步骤 [0-9 / r]: ')" CHOICE
        case "$CHOICE" in
            1) first_run_preflight; ui_pause ;;
            2)
                BACKUP=$(config_backup_create first_run_wizard true) \
                    && info "配置快照已创建：$BACKUP" \
                    || error "配置备份失败"
                ui_pause
                ;;
            3) first_run_access_setup; ui_pause ;;
            4) first_run_firewall_fail2ban_setup; ui_pause ;;
            5) first_run_ssh_baseline_apply; ui_pause ;;
            6) first_run_auto_updates_apply; ui_pause ;;
            7) first_run_network_security_apply; ui_pause ;;
            8) bbr_smart_wizard; ui_pause ;;
            9) first_run_final_audit; ui_pause ;;
            r|R) first_run_recommended_flow; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
# ══════════════════════════════════════════════════════════
#  常用软件管理
# ══════════════════════════════════════════════════════════

software_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v opkg >/dev/null 2>&1; then echo opkg
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown
    fi
}

software_group_packages() {
    local PM="$1" GROUP="$2"
    case "$PM:$GROUP" in
        apt:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apt:network) echo "iproute2 dnsutils mtr-tiny traceroute tcpdump netcat-openbsd socat nmap" ;;
        apt:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apt:develop) echo "build-essential python3 python3-pip" ;;
        dnf:base|yum:base) echo "curl wget git jq unzip zip tar nano vim-enhanced tmux screen ca-certificates" ;;
        dnf:network|yum:network) echo "iproute bind-utils mtr traceroute tcpdump nmap-ncat socat nmap" ;;
        dnf:monitor|yum:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        dnf:develop|yum:develop) echo "gcc gcc-c++ make python3 python3-pip" ;;
        apk:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apk:network) echo "iproute2 bind-tools mtr traceroute tcpdump netcat-openbsd socat nmap" ;;
        apk:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apk:develop) echo "build-base python3 py3-pip" ;;
        opkg:base) echo "curl wget-ssl git git-http jq unzip zip tar nano-full vim-fuller tmux screen ca-bundle" ;;
        opkg:network) echo "ip-full bind-dig mtr traceroute tcpdump netcat socat nmap" ;;
        opkg:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        opkg:develop) echo "python3 python3-pip make gcc" ;;
        pacman:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        pacman:network) echo "iproute2 bind mtr traceroute tcpdump openbsd-netcat socat nmap" ;;
        pacman:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        pacman:develop) echo "base-devel python python-pip" ;;
    esac
}

software_refresh_index() {
    case "$1" in
        apt) apt-get update -qq ;;
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
        apk) apk update ;;
        opkg) opkg update ;;
        pacman) return 0 ;; # pacman 必须在安装时使用 -Syu，禁止单独 -Sy。
        *) return 1 ;;
    esac
}

software_install_transaction() {
    local PM="$1" PACKAGES="$2"
    # PACKAGES 仅来自内置清单或严格的软件包名校验，需要在此按词传给包管理器。
    # shellcheck disable=SC2086
    case "$PM" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES ;;
        dnf) dnf install -y $PACKAGES ;;
        yum) yum install -y $PACKAGES ;;
        apk) apk add --no-cache $PACKAGES ;;
        opkg) opkg install $PACKAGES ;;
        pacman) pacman -Syu --noconfirm --needed $PACKAGES ;;
        *) return 1 ;;
    esac
}

software_install_packages() {
    local PM="$1" PACKAGES="$2" COUNT
    COUNT=$(printf '%s\n' "$PACKAGES" | wc -w | tr -d ' ')
    if [ "$PM" != pacman ]; then
        info "正在刷新软件包索引..."
        software_refresh_index "$PM" || {
            error "软件包索引刷新失败，已停止安装，避免使用过期或不一致的元数据"
            audit_action "常用软件索引刷新失败：${PM}" FAILED
            return 1
        }
    else
        warn "Arch Linux 将执行完整 pacman -Syu，避免不受支持的部分升级"
    fi
    info "正在通过单个包管理器事务安装 ${COUNT} 个软件包..."
    if software_install_transaction "$PM" "$PACKAGES"; then
        info "软件安装完成 ✓"
        audit_action "安装常用软件：${PM}，${COUNT}个包" SUCCESS
    else
        error "软件包事务失败；请查看上方包管理器输出确认是否留下待处理状态"
        audit_action "安装常用软件失败：${PM}，${COUNT}个包" FAILED
        return 1
    fi
}

common_software_menu() {
    while true; do
        print_header "常用软件管理"
        local PM; PM=$(software_package_manager)
        echo -e "  包管理器：${BOLD}$PM${NC}"
        ui_hint "可多选，例如 1 2 3；重复软件会自动去重"
        echo ""; menu_div
        menu_item "1" "基础工具  ${DIM}curl / wget / git / jq / tmux / 编辑器${NC}"
        menu_item "2" "网络诊断  ${DIM}mtr / tcpdump / socat / nmap / DNS${NC}"
        menu_item "3" "系统监控  ${DIM}htop / iftop / iotop / sysstat / ncdu${NC}"
        menu_item "4" "开发环境  ${DIM}编译工具 / Python / pip${NC}"
        menu_item "5" "全部推荐软件"
        menu_item "6" "安装自定义软件包"
        menu_item "0" "返回主菜单" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择分类 [0-6，可多选]: ')" CHOICES
        [ "$CHOICES" = "0" ] && return
        [ "$PM" != unknown ] || { error "未识别到支持的包管理器"; ui_pause; return; }

        local PACKAGES="" CH GROUP PKG G
        CHOICES=${CHOICES//,/ }
        for CH in $CHOICES; do
            case "$CH" in
                1) GROUP=base ;;
                2) GROUP=network ;;
                3) GROUP=monitor ;;
                4) GROUP=develop ;;
                5) GROUP="base network monitor develop" ;;
                6)
                    read -rp "$(ui_prompt '输入软件包名称: ')" PKG
                    if ! printf '%s\n' "$PKG" | grep -qE '^[A-Za-z0-9.+_-]+$'; then
                        error "软件包名称格式无效"; continue
                    fi
                    PACKAGES="$PACKAGES $PKG"
                    continue
                    ;;
                *) warn "忽略无效分类：$CH"; continue ;;
            esac
            for G in $GROUP; do
                for PKG in $(software_group_packages "$PM" "$G"); do
                    case " $PACKAGES " in *" $PKG "*) ;; *) PACKAGES="$PACKAGES $PKG" ;; esac
                done
            done
        done
        PACKAGES=${PACKAGES# }
        [ -n "$PACKAGES" ] || { warn "没有选择可安装的软件"; sleep 1; continue; }
        echo ""; echo -e "  ${BOLD}准备安装：${NC}"
        printf '%s\n' "$PACKAGES" | fold -s -w "$((BOX_W-4))" | sed 's/^/  /'
        confirm_change_preview "安装常用软件" "包管理器：$PM" \
            "单次事务包数量：$(printf '%s\n' "$PACKAGES" | wc -w | tr -d ' ')" \
            || { warn "已取消"; continue; }
        software_install_packages "$PM" "$PACKAGES"
        ui_pause
    done
}

software_menu() {
    common_software_menu
}
# ============================================================
#  Docker 生产环境安装与容器管理
# ============================================================

QUENCH_DOCKER_CONFIG="${QUENCH_DOCKER_CONFIG:-/etc/docker/daemon.json}"
QUENCH_DOCKER_STATE_DIR="${QUENCH_DOCKER_STATE_DIR:-$QUENCH_DATA_DIR/docker}"
QUENCH_COMPOSE_ROOT="${QUENCH_COMPOSE_ROOT:-/opt/quench/compose}"

docker_is_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

docker_status() {
    if ! command -v docker >/dev/null 2>&1; then echo not_installed
    elif docker info >/dev/null 2>&1; then echo running
    else echo stopped
    fi
}

docker_download_file() {
    local URL="$1" DEST="$2"
    case "$URL" in https://*) ;; *) error "只允许 HTTPS 下载"; return 1 ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 10 "$URL" -o "$DEST"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -O "$DEST" "$URL"
    else
        error "需要先安装 curl 或 wget"
        return 1
    fi
}

docker_os_load() {
    [ -r /etc/os-release ] || { error "无法识别系统发行版"; return 1; }
    local ID="" VERSION_CODENAME="" VERSION_ID=""
    # os-release 是系统供应商提供的 shell 兼容键值文件。
    # shellcheck disable=SC1091
    . /etc/os-release
    DOCKER_OS_ID=$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')
    DOCKER_OS_VERSION="$VERSION_ID"
    DOCKER_OS_CODENAME="$VERSION_CODENAME"
    if [ -z "$DOCKER_OS_CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
        DOCKER_OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
    fi
}

docker_apt_conflicts() {
    local PACKAGE
    for PACKAGE in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        dpkg-query -W -f='${db:Status-Abbrev}' "$PACKAGE" 2>/dev/null | grep -q '^ii ' && printf '%s\n' "$PACKAGE"
    done
}

docker_install_apt() {
    local DISTRO="$DOCKER_OS_ID" ARCH KEYRING SOURCE STAGE CONFLICTS
    case "$DISTRO" in debian|ubuntu) ;; *) error "APT 系统不在 Docker 官方支持清单：$DISTRO"; return 1 ;; esac
    [ -n "$DOCKER_OS_CODENAME" ] || { error "无法识别发行版代号"; return 1; }
    ARCH=$(dpkg --print-architecture 2>/dev/null) || return 1
    KEYRING=/etc/apt/keyrings/docker.asc
    SOURCE=/etc/apt/sources.list.d/docker.sources
    CONFLICTS=$(docker_apt_conflicts)
    if [ -n "$CONFLICTS" ]; then
        warn "检测到与 Docker CE 冲突的软件包：$(tr '\n' ' ' <<< "$CONFLICTS")"
        read -rp "  输入 REMOVE-CONFLICTS 确认移除这些包（不会删除 /var/lib/docker）: " ACK
        [ "$ACK" = REMOVE-CONFLICTS ] || { warn "已取消安装"; return 1; }
        # shellcheck disable=SC2086 # values are from the fixed package list above
        apt-get remove -y $CONFLICTS || return 1
    fi
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 || return 1
    install -m 0755 -d /etc/apt/keyrings || return 1
    STAGE=$(mktemp /etc/apt/keyrings/.docker.asc.XXXXXX) || return 1
    docker_download_file "https://download.docker.com/linux/$DISTRO/gpg" "$STAGE" \
        || { rm -f "$STAGE"; return 1; }
    chmod 0644 "$STAGE" || { rm -f "$STAGE"; return 1; }
    mv "$STAGE" "$KEYRING" || return 1
    STAGE=$(mktemp /etc/apt/sources.list.d/.docker.sources.XXXXXX) || return 1
    cat > "$STAGE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DISTRO
Suites: $DOCKER_OS_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: $KEYRING
EOF
    chmod 0644 "$STAGE" && mv "$STAGE" "$SOURCE" || { rm -f "$STAGE"; return 1; }
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

docker_install_rpm() {
    local PM="$1" DISTRO="$DOCKER_OS_ID" REPO_DISTRO
    case "$DISTRO" in
        centos|rhel|fedora) REPO_DISTRO="$DISTRO" ;;
        rocky|almalinux)
            REPO_DISTRO=centos
            warn "$DISTRO 使用 Docker 的 CentOS 兼容仓库；这属于兼容安装路径"
            read -rp "  输入 USE-CENTOS-REPO 继续: " ACK
            [ "$ACK" = USE-CENTOS-REPO ] || return 1
            ;;
        *) error "RPM 系统不在当前支持清单：$DISTRO"; return 1 ;;
    esac
    "$PM" -y install "${PM}-plugins-core" ca-certificates curl python3 || {
        "$PM" -y install dnf-plugins-core ca-certificates curl python3 || return 1
    }
    "$PM" config-manager --add-repo "https://download.docker.com/linux/$REPO_DISTRO/docker-ce.repo" \
        || "$PM" config-manager addrepo \
            --from-repofile="https://download.docker.com/linux/$REPO_DISTRO/docker-ce.repo" \
        || return 1
    "$PM" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

docker_install_alpine() {
    warn "Alpine 使用发行版仓库包，不是 Docker CE 官方仓库包"
    apk update && apk add --no-cache docker docker-cli-compose docker-cli-buildx python3 ca-certificates curl
}

docker_install() {
    local PM
    docker_os_load || return 1
    PM=$(software_package_manager)
    if docker_is_ready; then
        info "Docker 已运行：$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        return 0
    fi
    confirm_change_preview "安装 / 修复 Docker Engine" \
        "系统：$DOCKER_OS_ID ${DOCKER_OS_VERSION:-}" \
        "Debian/Ubuntu/RPM 系优先使用 Docker 官方软件仓库" \
        "安装 Compose 与 Buildx 插件；不会自动把用户加入 docker 组" || return 0
    case "$PM" in
        apt) docker_install_apt || { audit_action "通过官方仓库安装 Docker" FAILED; return 1; } ;;
        dnf|yum) docker_install_rpm "$PM" || { audit_action "通过官方仓库安装 Docker" FAILED; return 1; } ;;
        apk) docker_install_alpine || { audit_action "通过 Alpine 仓库安装 Docker" FAILED; return 1; } ;;
        *) error "当前包管理器不支持自动安装 Docker：$PM"; return 1 ;;
    esac
    svc_enable docker
    svc_start docker || true
    if ! docker_is_ready; then
        error "Docker 包已安装，但守护进程未正常运行"
        audit_action "安装 Docker Engine" FAILED
        return 1
    fi
    docker compose version >/dev/null 2>&1 || { error "Docker Compose 插件不可用"; return 1; }
    audit_action "安装 Docker Engine" SUCCESS
    info "Docker Engine 与 Compose 插件安装完成 ✓"
    warn "尚未修改 daemon.json；建议继续应用生产基线"
}

docker_require_ready() {
    docker_is_ready && return 0
    error "Docker 未安装或服务未运行，请先执行安装 / 修复"
    return 1
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1
}

docker_config_render() {
    local SOURCE="$1" DEST="$2"
    command -v python3 >/dev/null 2>&1 || { error "生成 JSON 配置需要 python3"; return 1; }
    python3 - "$SOURCE" "$DEST" <<'PY'
import json, pathlib, sys
source, dest = map(pathlib.Path, sys.argv[1:])
data = {}
if source.is_file():
    try:
        data = json.loads(source.read_text())
    except Exception as exc:
        raise SystemExit(f"现有 daemon.json 不是有效 JSON：{exc}")
if not isinstance(data, dict):
    raise SystemExit("daemon.json 顶层必须是对象")
data["log-driver"] = "local"
options = data.get("log-opts", {})
if not isinstance(options, dict):
    options = {}
options.update({"max-size": "20m", "max-file": "5"})
data["log-opts"] = options
data["live-restore"] = True
dest.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

docker_config_validate() {
    local FILE="$1"
    if command -v dockerd >/dev/null 2>&1; then
        dockerd --validate --config-file="$FILE" >/dev/null 2>&1
    else
        python3 -m json.tool "$FILE" >/dev/null 2>&1
    fi
}

docker_apply_production_baseline() {
    docker_require_ready || return 1
    command -v python3 >/dev/null 2>&1 || pkg_install python3 || { error "无法安装 python3"; return 1; }
    local DIR STAGE BACKUP="" HAD_CONFIG=false RUNNING_COUNT FAILED=false
    DIR=$(dirname "$QUENCH_DOCKER_CONFIG")
    mkdir -p "$DIR" "$QUENCH_DOCKER_STATE_DIR" || return 1
    chmod 700 "$QUENCH_DOCKER_STATE_DIR" 2>/dev/null || true
    STAGE=$(mktemp "$DIR/.daemon.json.quench.XXXXXX") || return 1
    docker_config_render "$QUENCH_DOCKER_CONFIG" "$STAGE" || { rm -f "$STAGE"; return 1; }
    docker_config_validate "$STAGE" || { rm -f "$STAGE"; error "Docker 配置预检失败"; return 1; }
    RUNNING_COUNT=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    confirm_change_preview "应用 Docker 生产基线" \
        "日志：local 驱动，单文件 20MB，最多 5 个" \
        "守护进程：live-restore=true" \
        "将重启 Docker；当前运行容器：$RUNNING_COUNT" || { rm -f "$STAGE"; return 0; }
    if [ -f "$QUENCH_DOCKER_CONFIG" ]; then
        HAD_CONFIG=true
        BACKUP=$(mktemp "$QUENCH_DOCKER_STATE_DIR/daemon.before.XXXXXX") || { rm -f "$STAGE"; return 1; }
        cp -p "$QUENCH_DOCKER_CONFIG" "$BACKUP" || { rm -f "$STAGE" "$BACKUP"; return 1; }
    fi
    chmod 0644 "$STAGE" && mv "$STAGE" "$QUENCH_DOCKER_CONFIG" || FAILED=true
    if [ "$FAILED" = false ]; then
        svc_restart docker || FAILED=true
        if [ "$FAILED" = false ]; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do docker_is_ready && break; sleep 1; done
            docker_is_ready || FAILED=true
        fi
    fi
    if [ "$FAILED" = true ]; then
        if [ "$HAD_CONFIG" = true ]; then cp -p "$BACKUP" "$QUENCH_DOCKER_CONFIG"
        else rm -f "$QUENCH_DOCKER_CONFIG"; fi
        svc_restart docker || true
        rm -f "$STAGE" "$BACKUP"
        error "Docker 未能使用新配置启动，已恢复原 daemon.json"
        audit_action "应用 Docker 生产基线" FAILED
        return 1
    fi
    rm -f "$BACKUP"
    audit_action "应用 Docker 生产基线" SUCCESS
    info "Docker 生产基线已应用并通过服务回读 ✓"
}

docker_firewall_status() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; then echo firewalld
    else echo none
    fi
}

docker_diagnose() {
    print_header "Docker 生产诊断"
    local FAILED=0 DRIVER LIVE FIREWALL
    if docker_is_ready; then info "Docker 守护进程运行正常"; else error "Docker 守护进程不可用"; FAILED=1; fi
    if docker_compose_available; then info "Compose 插件可用"; else error "Compose 插件不可用"; FAILED=1; fi
    DRIVER=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || true)
    [ "$DRIVER" = local ] && info "默认日志驱动为 local" || { warn "默认日志驱动为 ${DRIVER:-未知}，建议应用生产基线"; FAILED=1; }
    LIVE=$(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || true)
    [ "$LIVE" = true ] && info "live-restore 已启用" || { warn "live-restore 未启用"; FAILED=1; }
    FIREWALL=$(docker_firewall_status)
    case "$FIREWALL" in
        ufw) warn "UFW 已启用：Docker 发布端口可能绕过 UFW 的 INPUT 规则；部署时必须复核 DOCKER-USER 链" ;;
        firewalld) info "firewalld 已运行；Docker 会使用自己的 zone / 转发策略，请复核发布端口" ;;
        none) warn "未检测到活动的 UFW/firewalld" ;;
    esac
    echo ""
    docker info --format '  Server: {{.ServerVersion}}  Storage: {{.Driver}}  Cgroup: {{.CgroupDriver}}' 2>/dev/null || true
    audit_action "Docker 生产诊断" "$([ "$FAILED" -eq 0 ] && echo SUCCESS || echo WARNING)"
    return "$FAILED"
}

docker_grant_group_access() {
    local USERNAME="${SUDO_USER:-}"
    [ -n "$USERNAME" ] && [ "$USERNAME" != root ] || read -rp "  要授权的用户名: " USERNAME
    id "$USERNAME" >/dev/null 2>&1 || { error "用户不存在：$USERNAME"; return 1; }
    warn "docker 组可通过挂载宿主机文件或启动特权容器获得 root 级权限"
    read -rp "  输入 GRANT-DOCKER-ROOT 确认授权 $USERNAME: " ACK
    [ "$ACK" = GRANT-DOCKER-ROOT ] || { warn "已取消"; return 0; }
    usermod -aG docker "$USERNAME" || return 1
    audit_action "授予用户 $USERNAME docker 组权限" SUCCESS
    info "已授权；用户重新登录后生效"
}

docker_list_containers() {
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_select_container() {
    local IDS=() NAMES=() ID NAME STATUS IMAGE I CH
    while IFS='|' read -r ID NAME STATUS IMAGE; do
        [ -n "$ID" ] || continue
        IDS+=("$ID"); NAMES+=("$NAME")
        printf '  %2d) %-20s %-18s %s\n' "${#IDS[@]}" "$NAME" "$STATUS" "$IMAGE"
    done < <(docker ps -a --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Image}}')
    [ "${#IDS[@]}" -gt 0 ] || { warn "当前没有容器"; return 1; }
    echo ""
    read -rp "$(ui_prompt '选择容器编号（0 返回）: ')" CH
    [ "$CH" = 0 ] && return 1
    case "$CH" in ''|*[!0-9]*) error "编号无效"; return 1 ;; esac
    I=$((CH-1))
    [ "$I" -ge 0 ] && [ "$I" -lt "${#IDS[@]}" ] || { error "编号超出范围"; return 1; }
    DOCKER_SELECTED_ID="${IDS[$I]}"
    DOCKER_SELECTED_NAME="${NAMES[$I]}"
}

docker_container_details() {
    docker inspect --format '名称: {{.Name}}
镜像: {{.Config.Image}}
状态: {{.State.Status}}
创建: {{.Created}}
重启策略: {{.HostConfig.RestartPolicy.Name}}
网络: {{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}
挂载: {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$1" | sed 's#名称: /#名称: #'
}

docker_compose_url_valid() {
    local URL="$1" AUTHORITY
    case "$URL" in https://*) ;; *) return 1 ;; esac
    case "$URL" in *[[:space:]]*) return 1 ;; esac
    AUTHORITY=${URL#https://}; AUTHORITY=${AUTHORITY%%/*}; AUTHORITY=${AUTHORITY%%\?*}
    [ -n "$AUTHORITY" ] || return 1
    case "$AUTHORITY" in *@*) return 1 ;; esac
}

docker_compose_risk_report() {
    local JSON_FILE="$1"
    python3 - "$JSON_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
services = data.get("services", {})
for name, service in services.items():
    high = []
    if service.get("privileged"): high.append("privileged")
    for key in ("network_mode", "pid", "ipc", "userns_mode"):
        if service.get(key) == "host": high.append(f"{key}=host")
    if service.get("cap_add"): high.append("cap_add")
    if service.get("devices"): high.append("devices")
    if any("unconfined" in str(item).lower() for item in service.get("security_opt") or []):
        high.append("security_opt=unconfined")
    if service.get("build"):
        high.append("build-context")
    for volume in service.get("volumes") or []:
        if isinstance(volume, str):
            source, _, target = volume.partition(":")
            volume_type = "bind" if source.startswith("/") else "volume"
        else:
            source, target = str(volume.get("source", "")), str(volume.get("target", ""))
            volume_type = volume.get("type", "")
        if volume_type == "bind" or source == "/" or target == "/" or "docker.sock" in source or "docker.sock" in target:
            high.append(f"mount={source}:{target}")
    for reason in sorted(set(high)):
        print("HIGH\t%s\t%s" % (name, reason))
    for port in service.get("ports") or []:
        if isinstance(port, str):
            print("PORT\t%s\t%s" % (name, port))
        elif isinstance(port, dict):
            host = port.get("host_ip") or "0.0.0.0/::"
            published = port.get("published", "dynamic")
            target = port.get("target", "?")
            protocol = port.get("protocol", "tcp")
            print("PORT\t%s\t%s:%s->%s/%s" % (name, host, published, target, protocol))
PY
}

docker_compose_fetch_and_deploy() {
    docker_require_ready || return 1
    docker_compose_available || { error "缺少 Docker Compose 插件"; return 1; }
    command -v python3 >/dev/null 2>&1 || { error "Compose 风险检查需要 python3"; return 1; }
    local URL PROJECT DEST_DIR TMP JSON RISK HIGH_COUNT PORT_COUNT SAFE_URL BACKUP="" HAD_OLD=false FAILED=false
    read -rp "$(ui_prompt '输入 Compose 文件 HTTPS URL: ')" URL
    docker_compose_url_valid "$URL" || { error "只允许无用户凭据的 HTTPS URL"; return 1; }
    read -rp "$(ui_prompt '输入项目名（小写字母/数字/_/-）: ')" PROJECT
    printf '%s\n' "$PROJECT" | grep -qE '^[a-z0-9][a-z0-9_-]{0,62}$' || { error "项目名格式无效"; return 1; }
    DEST_DIR="$QUENCH_COMPOSE_ROOT/$PROJECT"
    mkdir -p "$DEST_DIR" "$QUENCH_DOCKER_STATE_DIR" || return 1
    TMP=$(mktemp "$DEST_DIR/.compose.download.XXXXXX") || return 1
    JSON=$(mktemp "$DEST_DIR/.compose.config.XXXXXX") || { rm -f "$TMP"; return 1; }
    docker_download_file "$URL" "$TMP" || { rm -f "$TMP" "$JSON"; return 1; }
    if ! docker compose --project-directory "$DEST_DIR" -f "$TMP" config --format json > "$JSON" 2>/dev/null; then
        rm -f "$TMP" "$JSON"; error "Compose 完整配置展开失败"; return 1
    fi
    RISK=$(docker_compose_risk_report "$JSON") || { rm -f "$TMP" "$JSON"; error "Compose 风险解析失败"; return 1; }
    rm -f "$JSON"
    HIGH_COUNT=$(printf '%s\n' "$RISK" | awk -F '\t' '$1=="HIGH"{n++} END{print n+0}')
    PORT_COUNT=$(printf '%s\n' "$RISK" | awk -F '\t' '$1=="PORT"{n++} END{print n+0}')
    if [ -n "$RISK" ]; then echo ""; echo -e "  ${BOLD}风险清单：${NC}"; printf '%s\n' "$RISK" | sed 's/^/  /'; fi
    if [ "$HIGH_COUNT" -gt 0 ]; then
        read -rp "  检测到 $HIGH_COUNT 项高权限配置，输入 DEPLOY-PRIVILEGED-COMPOSE 继续: " ACK
        [ "$ACK" = DEPLOY-PRIVILEGED-COMPOSE ] || { rm -f "$TMP"; warn "已取消"; return 0; }
    fi
    if [ "$PORT_COUNT" -gt 0 ]; then
        warn "Docker 发布端口可能绕过 UFW INPUT 规则，必须单独确认公网暴露"
        read -rp "  输入 EXPOSE-DOCKER-PORTS 继续: " ACK
        [ "$ACK" = EXPOSE-DOCKER-PORTS ] || { rm -f "$TMP"; warn "已取消"; return 0; }
    fi
    SAFE_URL=${URL%%[?#]*}
    confirm_change_preview "部署 Compose 项目 $PROJECT" "来源：$SAFE_URL" \
        "固定目录：$DEST_DIR" "先 pull，再 up -d --wait；失败自动恢复旧配置" \
        || { rm -f "$TMP"; return 0; }
    if [ -f "$DEST_DIR/compose.yaml" ]; then
        HAD_OLD=true
        BACKUP=$(mktemp "$QUENCH_DOCKER_STATE_DIR/${PROJECT}.compose.before.XXXXXX") || { rm -f "$TMP"; return 1; }
        cp -p "$DEST_DIR/compose.yaml" "$BACKUP" || { rm -f "$TMP" "$BACKUP"; return 1; }
    fi
    chmod 0600 "$TMP" && mv "$TMP" "$DEST_DIR/compose.yaml" || FAILED=true
    if [ "$FAILED" = false ]; then
        docker compose --project-directory "$DEST_DIR" -p "$PROJECT" -f "$DEST_DIR/compose.yaml" pull || FAILED=true
    fi
    if [ "$FAILED" = false ]; then
        docker compose --project-directory "$DEST_DIR" -p "$PROJECT" -f "$DEST_DIR/compose.yaml" \
            up -d --remove-orphans --wait --wait-timeout 120 || FAILED=true
    fi
    if [ "$FAILED" = true ]; then
        if [ "$HAD_OLD" = true ]; then
            cp -p "$BACKUP" "$DEST_DIR/compose.yaml"
            docker compose --project-directory "$DEST_DIR" -p "$PROJECT" -f "$DEST_DIR/compose.yaml" up -d --remove-orphans || true
        else
            docker compose --project-directory "$DEST_DIR" -p "$PROJECT" -f "$DEST_DIR/compose.yaml" down --remove-orphans || true
            rm -f "$DEST_DIR/compose.yaml"
        fi
        rm -f "$BACKUP"
        error "Compose 部署或健康等待失败，已恢复部署前状态"
        audit_action "部署 Compose：$SAFE_URL -> $PROJECT" FAILED
        return 1
    fi
    rm -f "$BACKUP"
    audit_action "部署 Compose：$SAFE_URL -> $PROJECT" SUCCESS
    info "Compose 项目已部署并通过健康等待：$DEST_DIR ✓"
}

docker_inspect_label() {
    local VALUE
    VALUE=$(docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true)
    [ "$VALUE" = "<no value>" ] && VALUE=""
    printf '%s\n' "$VALUE"
}

docker_upgrade_container() {
    local ID="$1" NAME="$2" PROJECT SERVICE WORKDIR CONFIG_FILES IMAGE OLD_ID NEW_ID FILE
    PROJECT=$(docker_inspect_label "$ID" com.docker.compose.project)
    SERVICE=$(docker_inspect_label "$ID" com.docker.compose.service)
    WORKDIR=$(docker_inspect_label "$ID" com.docker.compose.project.working_dir)
    CONFIG_FILES=$(docker_inspect_label "$ID" com.docker.compose.project.config_files)
    if [ -n "$PROJECT" ] && [ -n "$SERVICE" ]; then
        docker_compose_available || { error "缺少 Docker Compose 插件"; return 1; }
        [ -d "$WORKDIR" ] || { error "Compose 工作目录不存在：${WORKDIR:-未记录}"; return 1; }
        local ARGS=(-p "$PROJECT") FILES=()
        IFS=',' read -r -a FILES <<< "$CONFIG_FILES"
        for FILE in "${FILES[@]}"; do
            [ -f "$FILE" ] || FILE="$WORKDIR/$FILE"
            [ -f "$FILE" ] && ARGS+=(-f "$FILE")
        done
        [ "${#ARGS[@]}" -gt 2 ] || { error "找不到 Compose 配置文件"; return 1; }
        (cd "$WORKDIR" && docker compose "${ARGS[@]}" config >/dev/null) || { error "Compose 配置预检失败"; return 1; }
        IMAGE=$(docker inspect --format '{{.Config.Image}}' "$ID" 2>/dev/null)
        OLD_ID=$(docker inspect --format '{{.Image}}' "$ID" 2>/dev/null)
        confirm_change_preview "升级 Compose 服务 $NAME" "项目：$PROJECT / 服务：$SERVICE" \
            "只重建该服务，等待健康状态；失败时尝试恢复旧镜像" || return 0
        if (cd "$WORKDIR" && docker compose "${ARGS[@]}" pull "$SERVICE" \
            && docker compose "${ARGS[@]}" up -d --no-deps --wait --wait-timeout 120 "$SERVICE"); then
            audit_action "升级 Docker Compose：$PROJECT/$SERVICE" SUCCESS
            info "Compose 服务已升级并通过健康等待"
            return 0
        fi
        if [[ "$IMAGE" != *@* ]] && [ -n "$OLD_ID" ]; then docker image tag "$OLD_ID" "$IMAGE" 2>/dev/null || true; fi
        (cd "$WORKDIR" && docker compose "${ARGS[@]}" up -d --no-deps "$SERVICE") || true
        error "升级失败，已尝试恢复旧镜像"
        audit_action "升级 Docker Compose：$PROJECT/$SERVICE" FAILED
        return 1
    fi
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$ID" 2>/dev/null)
    OLD_ID=$(docker inspect --format '{{.Image}}' "$ID" 2>/dev/null)
    [ -n "$IMAGE" ] || { error "无法读取容器镜像"; return 1; }
    confirm_change_preview "检查普通容器 $NAME 的镜像更新" "镜像：$IMAGE" \
        "仅拉取镜像，不删除或猜测原 docker run 参数" || return 0
    docker pull "$IMAGE" || return 1
    NEW_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)
    if [ "$OLD_ID" = "$NEW_ID" ]; then info "容器已使用当前镜像"
    else warn "新镜像已下载；普通容器需用原始参数人工重建，Quench 不会冒险删除现有容器"; fi
}

docker_container_action() {
    local ACTION="$1"
    docker_require_ready || return 1
    print_header "选择 Docker 容器"
    docker_select_container || return 0
    case "$ACTION" in
        inspect) docker_container_details "$DOCKER_SELECTED_ID" ;;
        start|stop|restart) docker "$ACTION" "$DOCKER_SELECTED_ID" && info "容器 $DOCKER_SELECTED_NAME 已执行 $ACTION" ;;
        logs) docker logs --tail 200 --timestamps "$DOCKER_SELECTED_ID" ;;
        shell) docker exec -it "$DOCKER_SELECTED_ID" sh 2>/dev/null || docker exec -it "$DOCKER_SELECTED_ID" bash ;;
        upgrade) docker_upgrade_container "$DOCKER_SELECTED_ID" "$DOCKER_SELECTED_NAME" ;;
        remove)
            if confirm_change_preview "删除容器 $DOCKER_SELECTED_NAME" "不会自动删除数据卷"; then
                read -rp "  输入容器名 $DOCKER_SELECTED_NAME 确认: " ACK
                [ "$ACK" = "$DOCKER_SELECTED_NAME" ] && docker rm -f "$DOCKER_SELECTED_ID" && info "容器已删除"
            fi
            ;;
    esac
    ui_pause
}

docker_menu() {
    while true; do
        local STATE LABEL COUNT=0
        STATE=$(docker_status)
        case "$STATE" in
            running) LABEL="运行中"; COUNT=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ') ;;
            stopped) LABEL="已安装 · 服务停止" ;;
            *) LABEL="未安装" ;;
        esac
        print_header "Docker 管理"
        echo -e "  状态：${BOLD}$LABEL${NC}    容器：${BOLD}$COUNT${NC}"
        echo ""; menu_div
        menu_pair "1" "官方仓库安装 / 修复" "2" "生产环境诊断"
        menu_pair "3" "应用生产基线" "4" "查看全部容器"
        menu_pair "5" "查看容器详情" "6" "启动容器"
        menu_pair "7" "停止容器" "8" "重启容器"
        menu_pair "9" "查看最近日志" "10" "进入容器 Shell"
        menu_pair "11" "升级容器镜像" "12" "部署 HTTPS Compose" "$CYAN" "$BLUE"
        menu_pair "g" "授予 docker 组权限" "d" "删除容器" "$YELLOW" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        read -rp "$(ui_prompt '选择功能 [0-12 / g / d]: ')" CH
        case "$CH" in
            1) docker_install; ui_pause ;; 2) docker_diagnose; ui_pause ;;
            3) docker_apply_production_baseline; ui_pause ;; 4) docker_require_ready && docker_list_containers; ui_pause ;;
            5) docker_container_action inspect ;; 6) docker_container_action start ;;
            7) docker_container_action stop ;; 8) docker_container_action restart ;;
            9) docker_container_action logs ;; 10) docker_container_action shell ;;
            11) docker_container_action upgrade ;; 12) docker_compose_fetch_and_deploy; ui_pause ;;
            g|G) docker_grant_group_access; ui_pause ;; d|D) docker_container_action remove ;;
            0) return ;; 00) safe_clear; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
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
    WORK=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-fetch.XXXXXX") || return 1
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
        DOWNLOAD_TMP=$(quench_mktemp "${TMPDIR:-/tmp}/quench-install.XXXXXX") || return 1
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
    WORK=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-update.XXXXXX") || return 1
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
    WORK=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-offline.XXXXXX") || return 1
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
    WORK=$(quench_mktemp_d "${TMPDIR:-/tmp}/quench-offline-install.XXXXXX") || return 1
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
# ══════════════════════════════════════════════════════════
#  Quench 四层端口转发（线路机 → 落地机）
# ══════════════════════════════════════════════════════════

NFT_STATE_DIR="${NFT_STATE_DIR:-/etc/quench/nft-forward}"
NFT_RUNTIME_DIR="${NFT_RUNTIME_DIR:-/var/lib/quench/nft-forward}"
NFT_RULES_FILE="${NFT_RULES_FILE:-$NFT_STATE_DIR/rules.db}"
NFT_ACCESS_FILE="${NFT_ACCESS_FILE:-$NFT_STATE_DIR/access.db}"
NFT_FIREWALL_STATE="${NFT_FIREWALL_STATE:-$NFT_STATE_DIR/firewall.db}"
NFT_MANAGED_FILE="${NFT_MANAGED_FILE:-/etc/nftables.d/quench-nft-forward.nft}"
NFT_SYSCTL_FILE="${NFT_SYSCTL_FILE:-/etc/sysctl.d/98-quench-nft-forward.conf}"
NFT_SYSCTL_BASELINE="${NFT_SYSCTL_BASELINE:-$NFT_RUNTIME_DIR/sysctl-baseline}"
NFT_BBR_SYSCTL_FILE="${NFT_BBR_SYSCTL_FILE:-/etc/sysctl.d/99-quench-bbr.conf}"
NFT_APPLY_HELPER="${NFT_APPLY_HELPER:-/usr/local/libexec/quench-nft-forward-apply}"
NFT_SERVICE_FILE="${NFT_SERVICE_FILE:-/etc/systemd/system/quench-nft-forward.service}"
NFT_OPENRC_FILE="${NFT_OPENRC_FILE:-/etc/init.d/quench-nft-forward}"
NFT_REFRESH_SERVICE_FILE="${NFT_REFRESH_SERVICE_FILE:-/etc/systemd/system/quench-nft-target-refresh.service}"
NFT_REFRESH_TIMER_FILE="${NFT_REFRESH_TIMER_FILE:-/etc/systemd/system/quench-nft-target-refresh.timer}"
NFT_LOCK_FILE="${NFT_LOCK_FILE:-/run/lock/quench-nft-forward.lock}"
NFT_RENDER_VERSION="2"
NFT_CT_MARK_BIT="0x40000000"
NFT_OFFSET_RANGE_MAX="4096"

# rules.db:
# id|family|protocol|listen_ip|lstart|lend|target_type|target_host|resolved_ip|
# target_start|target_end|map_mode|snat_mode|acl_mode|enabled|comment
# access.db: rule_id|family|IP-or-CIDR

nft_ensure_state_dir() {
    mkdir -p "$NFT_STATE_DIR" "$NFT_RUNTIME_DIR" "$(dirname "$NFT_MANAGED_FILE")" \
        "$(dirname "$NFT_LOCK_FILE")" || return 1
    touch "$NFT_RULES_FILE" "$NFT_ACCESS_FILE" "$NFT_FIREWALL_STATE" || return 1
    chmod 700 "$NFT_STATE_DIR" "$NFT_RUNTIME_DIR" 2>/dev/null || true
    chmod 600 "$NFT_RULES_FILE" "$NFT_ACCESS_FILE" "$NFT_FIREWALL_STATE" 2>/dev/null || true
}

# 固定 fd 8，编号见 core.sh 的 fd 分配表（exec {VAR}> 在 bash 3.2 下不可用）。
NFT_LOCK_HELD=0

nft_lock_acquire() {
    nft_ensure_state_dir || return 1
    command -v flock >/dev/null 2>&1 || return 0
    [ "$NFT_LOCK_HELD" = 1 ] && return 0
    exec 8>"$NFT_LOCK_FILE" || return 1
    if ! flock -w 30 8; then
        # 原实现在这里直接 return，把已打开的 fd 留着不关。
        exec 8>&-
        error "另一个 Quench 转发任务正在运行"
        return 1
    fi
    NFT_LOCK_HELD=1
}

nft_lock_release() {
    [ "$NFT_LOCK_HELD" = 1 ] || return 0
    flock -u 8 2>/dev/null || true
    exec 8>&-
    NFT_LOCK_HELD=0
}

nft_install() {
    command -v nft >/dev/null 2>&1 && return 0
    info "正在安装 nftables..."
    pkg_install nftables || return 1
    command -v nft >/dev/null 2>&1
}

nft_check_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

nft_ip_family() {
    local value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import ipaddress, sys
try:
    print("ipv4" if ipaddress.ip_address(sys.argv[1]).version == 4 else "ipv6")
except ValueError:
    raise SystemExit(1)
PY
        return $?
    fi
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.' octet
        read -r -a _nft_octets <<< "$value"
        for octet in "${_nft_octets[@]}"; do [ "$octet" -le 255 ] || return 1; done
        echo ipv4
    elif [[ "$value" == *:* ]] && [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]]; then
        echo ipv6
    else
        return 1
    fi
}

nft_is_ipv6() { [ "$(nft_ip_family "$1" 2>/dev/null)" = ipv6 ]; }

nft_is_hostname() {
    local name="$1"
    [ -n "$name" ] && [ ${#name} -le 253 ] || return 1
    [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$name" == *.* ]] || return 1
    [[ "$name" != *..* ]]
}

nft_target_type() {
    if nft_ip_family "$1" >/dev/null 2>&1; then echo ip
    elif nft_is_hostname "$1"; then echo domain
    else echo invalid
    fi
}

nft_ip_usable_target() {
    local value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if ip.is_unspecified or ip.is_multicast or ip.is_loopback:
    raise SystemExit(1)
PY
        return $?
    fi
    case "$value" in 0.0.0.0|127.*|::|::1|ff*|FF*) return 1 ;; esac
}

nft_resolve_domain() {
    local domain="$1" family="$2" result=""
    if [ "$family" = ipv4 ]; then
        result=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
    else
        result=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')
    fi
    [ "$(nft_ip_family "$result" 2>/dev/null)" = "$family" ] || return 1
    nft_ip_usable_target "$result" || return 1
    printf '%s\n' "$result"
}

nft_family_flag() { [ "$1" = ipv6 ] && echo -6 || echo -4; }
nft_family_table() { [ "$1" = ipv6 ] && echo ip6 || echo ip; }
nft_family_addr_expr() { [ "$1" = ipv6 ] && echo ip6 || echo ip; }
nft_family_addr_type() { [ "$1" = ipv6 ] && echo ipv6_addr || echo ipv4_addr; }

nft_protocols() {
    case "$1" in
        tcp) echo tcp ;;
        udp) echo udp ;;
        both) printf 'tcp\nudp\n' ;;
        *) return 1 ;;
    esac
}

nft_protocol_label() {
    case "$1" in tcp) echo TCP ;; udp) echo UDP ;; both) echo TCP+UDP ;; esac
}

nft_protocols_overlap() {
    [ "$1" = both ] || [ "$2" = both ] || [ "$1" = "$2" ]
}

nft_next_rule_id() {
    local max=0 id
    while IFS='|' read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$max" ] && max=$id
    done < "$NFT_RULES_FILE"
    echo $((max + 1))
}

nft_rule_count() {
    awk -F'|' '$1 ~ /^[0-9]+$/ && $15 == "yes" {n++} END {print n+0}' "$NFT_RULES_FILE" 2>/dev/null
}

nft_rules_has_family() {
    local family="$1"
    awk -F'|' -v f="$family" '$1 ~ /^[0-9]+$/ && $2 == f && $15 == "yes" {found=1} END {exit !found}' \
        "$NFT_RULES_FILE" 2>/dev/null
}

nft_find_rule() {
    local target="$1" line
    NFT_FOUND_RULE=""
    while IFS= read -r line; do
        [ "${line%%|*}" = "$target" ] || continue
        NFT_FOUND_RULE="$line"
        return 0
    done < "$NFT_RULES_FILE"
    return 1
}

nft_access_entries_for() {
    local id="$1" family="$2"
    awk -F'|' -v id="$id" -v f="$family" '$1 == id && $2 == f {print $3}' "$NFT_ACCESS_FILE" 2>/dev/null
}

nft_access_elements() {
    local id="$1" family="$2" entry out="" sep=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        out="${out}${sep}${entry}"; sep=", "
    done < <(nft_access_entries_for "$id" "$family")
    printf '%s\n' "$out"
}

nft_validate_access_entry() {
    local entry="$1" family="$2" base prefix max
    base="${entry%%/*}"
    [ "$base" != "$entry" ] && prefix="${entry##*/}" || prefix=""
    [ "$(nft_ip_family "$base" 2>/dev/null)" = "$family" ] || return 1
    if [ -n "$prefix" ]; then
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        [ "$family" = ipv6 ] && max=128 || max=32
        [ "$prefix" -le "$max" ] || return 1
    fi
}

nft_validate_record() {
    local id="$1" family="$2" proto="$3" lip="$4" ls="$5" le="$6" ttype="$7" \
        thost="$8" tip="$9" ts="${10}" te="${11}" mode="${12}" snat="${13}" \
        acl="${14}" enabled="${15}" comment="${16}"
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    [[ "$family" =~ ^ipv[46]$ ]] || return 1
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || return 1
    [ -z "$lip" ] || [ "$(nft_ip_family "$lip" 2>/dev/null)" = "$family" ] || return 1
    nft_check_port "$ls" && nft_check_port "$le" && [ "$ls" -le "$le" ] || return 1
    [[ "$ttype" =~ ^(ip|domain)$ ]] || return 1
    [ "$(nft_ip_family "$tip" 2>/dev/null)" = "$family" ] && nft_ip_usable_target "$tip" || return 1
    [ "$ttype" = ip ] || nft_is_hostname "$thost" || return 1
    nft_check_port "$ts" && nft_check_port "$te" && [ "$ts" -le "$te" ] || return 1
    [[ "$mode" =~ ^(single|range_1_to_1|range_offset)$ ]] || return 1
    case "$mode" in
        single)
            [ "$ls" -eq "$le" ] && [ "$ts" -eq "$te" ] || return 1
            ;;
        range_1_to_1)
            [ "$ls" -eq "$ts" ] && [ "$le" -eq "$te" ] || return 1
            ;;
        range_offset)
            [ $((le - ls)) -eq $((te - ts)) ] \
                && [ $((le - ls + 1)) -le "$NFT_OFFSET_RANGE_MAX" ] || return 1
            ;;
    esac
    if [ "$ttype" = ip ]; then
        [ "$(nft_ip_family "$thost" 2>/dev/null)" = "$family" ] && [ "$thost" = "$tip" ] || return 1
    fi
    [[ "$snat" =~ ^(masquerade|preserve)$ ]] || return 1
    [[ "$acl" =~ ^(off|whitelist|blacklist)$ ]] || return 1
    [[ "$enabled" =~ ^(yes|no)$ ]] || return 1
    [[ "$comment" != *'|'* ]] && [[ "$comment" != *$'\n'* ]]
}

nft_validate_database() {
    local id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment entry_id entry_family entry rule_family
    local seen
    seen=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-ids.XXXXXX") || return 1
    while IFS='|' read -r id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ -z "$id" ] && continue
        nft_validate_record "$id" "$family" "$proto" "$lip" "$ls" "$le" "$ttype" \
            "$thost" "$tip" "$ts" "$te" "$mode" "$snat" "$acl" "$enabled" "$comment" \
            || { error "规则数据库中 ID ${id:-?} 的字段无效"; rm -f "$seen"; return 1; }
        grep -qxF "$id" "$seen" && { error "规则数据库存在重复 ID：$id"; rm -f "$seen"; return 1; }
        echo "$id" >> "$seen"
        if [ "$acl" != off ] && [ -z "$(nft_access_elements "$id" "$family")" ]; then
            error "规则 $id 已启用访问控制但名单为空"; rm -f "$seen"; return 1
        fi
    done < "$NFT_RULES_FILE"
    while IFS='|' read -r entry_id entry_family entry; do
        [ -n "$entry_id" ] || continue
        grep -qxF "$entry_id" "$seen" \
            || { error "访问名单引用了不存在的规则：$entry_id"; rm -f "$seen"; return 1; }
        rule_family=$(awk -F'|' -v id="$entry_id" '$1 == id {print $2; exit}' "$NFT_RULES_FILE")
        [ "$entry_family" = "$rule_family" ] \
            || { error "规则 $entry_id 的访问名单协议族不一致"; rm -f "$seen"; return 1; }
        nft_validate_access_entry "$entry" "$entry_family" \
            || { error "规则 $entry_id 的访问地址无效：$entry"; rm -f "$seen"; return 1; }
    done < "$NFT_ACCESS_FILE"
    rm -f "$seen"
}

nft_rule_conflict_id() {
    local exclude="$1" family="$2" proto="$3" lip="$4" ls="$5" le="$6"
    local id f p old_lip old_ls old_le _rest
    while IFS='|' read -r id f p old_lip old_ls old_le _rest; do
        [ "$id" = "$exclude" ] && continue
        [ "$f" = "$family" ] || continue
        nft_protocols_overlap "$proto" "$p" || continue
        { [ -z "$lip" ] || [ -z "$old_lip" ] || [ "$lip" = "$old_lip" ]; } || continue
        [ "$ls" -le "$old_le" ] && [ "$le" -ge "$old_ls" ] || continue
        echo "$id"; return 0
    done < <(awk -F'|' '$1 ~ /^[0-9]+$/ && $15 == "yes"' "$NFT_RULES_FILE")
    return 1
}

nft_format_host_port() {
    local host="$1" port="$2"
    nft_is_ipv6 "$host" && printf '[%s]:%s\n' "$host" "$port" || printf '%s:%s\n' "$host" "$port"
}

nft_dnat_target() {
    local family="$1" ip="$2" port="$3"
    if [ -n "$port" ]; then nft_format_host_port "$ip" "$port"; else printf '%s\n' "$ip"; fi
}

nft_port_map() {
    local ls="$1" le="$2" ts="$3" lp="$1" rp="$3" out="{ " sep=""
    while [ "$lp" -le "$le" ]; do
        out="${out}${sep}${lp} : ${rp}"; sep=", "
        lp=$((lp + 1)); rp=$((rp + 1))
    done
    printf '%s }\n' "$out"
}

nft_rule_match() {
    local family="$1" proto="$2" lip="$3" ls="$4" le="$5" addr="" ports
    [ -z "$lip" ] || addr="$(nft_family_addr_expr "$family") daddr $lip "
    [ "$ls" = "$le" ] && ports="$ls" || ports="$ls-$le"
    printf '%s%s dport %s' "$addr" "$proto" "$ports"
}

nft_render_access_sets_for() {
    local family="$1" id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment entries
    while IFS='|' read -r id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ "$f" = "$family" ] && [ "$enabled" = yes ] && [ "$acl" != off ] || continue
        entries=$(nft_access_elements "$id" "$family")
        cat <<EOF
    set acl_${id} {
        type $(nft_family_addr_type "$family")
        flags interval
        elements = { $entries }
    }
EOF
    done < "$NFT_RULES_FILE"
}

nft_render_access_rules_for() {
    local family="$1" addr id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment p match
    addr=$(nft_family_addr_expr "$family")
    while IFS='|' read -r id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ "$f" = "$family" ] && [ "$enabled" = yes ] && [ "$acl" != off ] || continue
        while IFS= read -r p; do
            match=$(nft_rule_match "$family" "$p" "$lip" "$ls" "$le")
            if [ "$acl" = whitelist ]; then
                echo "        $match $addr saddr != @acl_${id} counter drop comment \"quench-acl-${id}-${p}\""
            else
                echo "        $match $addr saddr @acl_${id} counter drop comment \"quench-acl-${id}-${p}\""
            fi
        done < <(nft_protocols "$proto")
    done < "$NFT_RULES_FILE"
}

nft_render_nat_rules_for() {
    local family="$1" id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment p match dnat map mark_stmt
    while IFS='|' read -r id f proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ "$f" = "$family" ] && [ "$enabled" = yes ] || continue
        [ "$snat" = masquerade ] && mark_stmt="ct mark set ct mark | $NFT_CT_MARK_BIT " || mark_stmt=""
        while IFS= read -r p; do
            match=$(nft_rule_match "$family" "$p" "$lip" "$ls" "$le")
            case "$mode" in
                single)
                    dnat=$(nft_dnat_target "$family" "$tip" "$ts")
                    echo "        $match ${mark_stmt}counter dnat to $dnat comment \"quench-forward-${id}-${p}\""
                    ;;
                range_1_to_1)
                    dnat=$(nft_dnat_target "$family" "$tip" "")
                    echo "        $match ${mark_stmt}counter dnat to $dnat comment \"quench-forward-${id}-${p}\""
                    ;;
                range_offset)
                    dnat=$(nft_dnat_target "$family" "$tip" "")
                    map=$(nft_port_map "$ls" "$le" "$ts")
                    echo "        $match ${mark_stmt}counter dnat to $dnat : $p dport map $map comment \"quench-forward-${id}-${p}\""
                    ;;
            esac
        done < <(nft_protocols "$proto")
    done < "$NFT_RULES_FILE"
}

nft_generate_family_table() {
    local family="$1" table_family suffix
    nft_rules_has_family "$family" || return 0
    table_family=$(nft_family_table "$family")
    [ "$family" = ipv6 ] && suffix=6 || suffix=4
    echo "table $table_family quench_nft${suffix} {"
    nft_render_access_sets_for "$family"
    cat <<EOF
    chain access_prerouting {
        type filter hook prerouting priority -120; policy accept;
EOF
    nft_render_access_rules_for "$family"
    cat <<EOF
    }

    chain nat_prerouting {
        type nat hook prerouting priority -110; policy accept;
EOF
    nft_render_nat_rules_for "$family"
    cat <<EOF
    }

    chain nat_postrouting {
        type nat hook postrouting priority 90; policy accept;
        ct mark & $NFT_CT_MARK_BIT != 0 counter masquerade comment "quench-forward-snat"
    }
}

EOF
}

nft_generate_config() {
    cat <<EOF
#!/usr/sbin/nft -f
# QUENCH_NFT_FORWARD_VERSION=$NFT_RENDER_VERSION
# Generated by Quench and loaded only by its dedicated service.

EOF
    nft_generate_family_table ipv4
    nft_generate_family_table ipv6
}

nft_table_names() { printf 'ip quench_nft4\nip6 quench_nft6\n'; }

nft_build_apply_batch() {
    local config="$1" batch="$2" family table
    : > "$batch" || return 1
    while read -r family table; do
        nft list table "$family" "$table" >/dev/null 2>&1 \
            && printf 'delete table %s %s\n' "$family" "$table" >> "$batch"
    done < <(nft_table_names)
    cat "$config" >> "$batch"
}

nft_apply_config_file() {
    local config="$1" batch
    batch=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-batch.XXXXXX") || return 1
    nft_build_apply_batch "$config" "$batch" || { rm -f "$batch"; return 1; }
    if ! nft -c -f "$batch"; then
        rm -f "$batch"; error "nftables 规则语法或内核兼容性校验失败"; return 1
    fi
    if ! nft -f "$batch"; then
        rm -f "$batch"; error "nftables 原子应用失败，旧规则保持不变"; return 1
    fi
    rm -f "$batch"
}

nft_check_config_file() {
    local config="$1" batch
    batch=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-check.XXXXXX") || return 1
    nft_build_apply_batch "$config" "$batch" || { rm -f "$batch"; return 1; }
    nft -c -f "$batch"
    local rc=$?
    rm -f "$batch"
    return "$rc"
}

nft_write_managed_file() {
    local candidate backup existed=no
    candidate=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-config.XXXXXX") || return 1
    backup=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-backup.XXXXXX") || { rm -f "$candidate"; return 1; }
    nft_generate_config > "$candidate" || { rm -f "$candidate" "$backup"; return 1; }
    nft_check_config_file "$candidate" \
        || { rm -f "$candidate" "$backup"; error "nftables 候选规则校验失败"; return 1; }
    if [ -f "$NFT_MANAGED_FILE" ]; then
        cp "$NFT_MANAGED_FILE" "$backup" || { rm -f "$candidate" "$backup"; return 1; }
        existed=yes
    fi
    mkdir -p "$(dirname "$NFT_MANAGED_FILE")" || { rm -f "$candidate" "$backup"; return 1; }
    install -m 600 "$candidate" "$NFT_MANAGED_FILE" \
        || { rm -f "$candidate" "$backup"; return 1; }
    if ! nft_apply_config_file "$NFT_MANAGED_FILE"; then
        if [ "$existed" = yes ]; then
            install -m 600 "$backup" "$NFT_MANAGED_FILE" || true
        else
            rm -f "$NFT_MANAGED_FILE"
        fi
        rm -f "$candidate" "$backup"
        return 1
    fi
    rm -f "$candidate" "$backup"
}

nft_write_apply_helper() {
    local nft_bin tmp
    nft_bin=$(command -v nft) || return 1
    mkdir -p "$(dirname "$NFT_APPLY_HELPER")" || return 1
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-helper.XXXXXX") || return 1
    cat > "$tmp" <<EOF
#!/bin/sh
set -eu
NFT_BIN='$nft_bin'
CONFIG='$NFT_MANAGED_FILE'
TMP=\$(mktemp /tmp/quench-nft-boot.XXXXXX)
trap 'rm -f "\$TMP"' EXIT
for pair in 'ip quench_nft4' 'ip6 quench_nft6'; do
    set -- \$pair
    if "\$NFT_BIN" list table "\$1" "\$2" >/dev/null 2>&1; then
        printf 'delete table %s %s\n' "\$1" "\$2" >> "\$TMP"
    fi
done
cat "\$CONFIG" >> "\$TMP"
"\$NFT_BIN" -c -f "\$TMP"
"\$NFT_BIN" -f "\$TMP"
EOF
    install -m 700 "$tmp" "$NFT_APPLY_HELPER" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

nft_install_persistence_service() {
    nft_write_apply_helper || return 1
    if systemd_available; then
        local tmp
        tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-service.XXXXXX") || return 1
        cat > "$tmp" <<EOF
[Unit]
Description=Quench four-layer port forwarding
After=network-pre.target nftables.service ufw.service firewalld.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=$NFT_APPLY_HELPER
ExecReload=$NFT_APPLY_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        install -m 644 "$tmp" "$NFT_SERVICE_FILE" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable quench-nft-forward.service >/dev/null 2>&1 || return 1
    elif command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        local tmp
        tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-openrc.XXXXXX") || return 1
        cat > "$tmp" <<EOF
#!/sbin/openrc-run
description="Quench four-layer port forwarding"
command="$NFT_APPLY_HELPER"
command_background="no"

depend() {
    need net
    after nftables ufw firewalld
    before docker
}
EOF
        install -m 755 "$tmp" "$NFT_OPENRC_FILE" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        rc-update add quench-nft-forward default >/dev/null 2>&1 || return 1
    else
        warn "当前系统没有受支持的持久服务管理器；运行规则已生效，但重启后需要手动应用"
    fi
}

nft_sysctl_get() { sysctl -n "$1" 2>/dev/null; }
nft_sysctl_set() { sysctl -w "$1=$2" >/dev/null 2>&1; }

nft_sysctl_baseline_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$NFT_SYSCTL_BASELINE" 2>/dev/null | head -1
}

nft_bbr_sysctl_value() {
    local key="$1"
    [ -f "$NFT_BBR_SYSCTL_FILE" ] || return 1
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ {next}
        {
            k=$1; sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*$/, "", k)
            if (k == key) {
                v=substr($0, index($0, "=") + 1)
                sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v)
                print v; found=1; exit
            }
        }
        END {exit !found}
    ' "$NFT_BBR_SYSCTL_FILE"
}

nft_ipv6_default_iface() {
    local iface
    iface=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$iface" ] || iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
    printf '%s\n' "$iface"
}

nft_sysctl_capture_baseline() {
    [ -s "$NFT_SYSCTL_BASELINE" ] && return 0
    local iface tmp
    iface=$(nft_ipv6_default_iface)
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-sysctl.XXXXXX") || return 1
    {
        printf 'ipv4=%s\n' "$(nft_sysctl_get net.ipv4.ip_forward || echo 0)"
        printf 'ipv6=%s\n' "$(nft_sysctl_get net.ipv6.conf.all.forwarding || echo 0)"
        printf 'ra_default=%s\n' "$(nft_sysctl_get net.ipv6.conf.default.accept_ra || echo 1)"
        printf 'iface=%s\n' "$iface"
        if [ -n "$iface" ]; then
            printf 'ra_iface=%s\n' "$(nft_sysctl_get "net.ipv6.conf.${iface}.accept_ra" || echo 1)"
        fi
    } > "$tmp"
    mkdir -p "$(dirname "$NFT_SYSCTL_BASELINE")" || { rm -f "$tmp"; return 1; }
    install -m 600 "$tmp" "$NFT_SYSCTL_BASELINE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

nft_sysctl_restore_family() {
    local family="$1" value iface ra
    [ -s "$NFT_SYSCTL_BASELINE" ] || return 0
    if [ "$family" = ipv4 ]; then
        value=$(nft_bbr_sysctl_value net.ipv4.ip_forward 2>/dev/null \
            || nft_sysctl_baseline_value ipv4)
        [ -n "$value" ] && nft_sysctl_set net.ipv4.ip_forward "$value"
    else
        iface=$(nft_sysctl_baseline_value iface)
        value=$(nft_bbr_sysctl_value net.ipv6.conf.all.forwarding 2>/dev/null \
            || nft_sysctl_baseline_value ipv6)
        ra=$(nft_bbr_sysctl_value net.ipv6.conf.default.accept_ra 2>/dev/null \
            || nft_sysctl_baseline_value ra_default)
        [ -n "$value" ] && nft_sysctl_set net.ipv6.conf.all.forwarding "$value"
        [ -n "$ra" ] && nft_sysctl_set net.ipv6.conf.default.accept_ra "$ra"
        if [ -n "$iface" ]; then
            ra=$(nft_bbr_sysctl_value "net.ipv6.conf.${iface}.accept_ra" 2>/dev/null \
                || nft_sysctl_baseline_value ra_iface)
        else
            ra=""
        fi
        [ -n "$iface" ] && [ -n "$ra" ] && nft_sysctl_set "net.ipv6.conf.${iface}.accept_ra" "$ra"
    fi
}

nft_sysctl_reconcile() {
    local need4=no need6=no iface tmp
    nft_rules_has_family ipv4 && need4=yes
    nft_rules_has_family ipv6 && need6=yes
    if [ "$need4" = yes ] || [ "$need6" = yes ]; then
        nft_sysctl_capture_baseline || { error "无法记录内核转发参数基线"; return 1; }
    fi
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-sysctl-file.XXXXXX") || return 1
    {
        echo '# Managed by Quench four-layer port forwarding'
        [ "$need4" = yes ] && echo 'net.ipv4.ip_forward = 1'
        if [ "$need6" = yes ]; then
            iface=$(nft_ipv6_default_iface)
            echo 'net.ipv6.conf.default.accept_ra = 2'
            echo 'net.ipv6.conf.all.forwarding = 1'
            [ -n "$iface" ] && printf 'net.ipv6.conf.%s.accept_ra = 2\n' "$iface"
        fi
    } > "$tmp"
    if [ "$need4" = yes ] || [ "$need6" = yes ]; then
        install -m 644 "$tmp" "$NFT_SYSCTL_FILE" || { rm -f "$tmp"; return 1; }
        sysctl -p "$NFT_SYSCTL_FILE" >/dev/null 2>&1 \
            || { rm -f "$tmp"; error "内核转发参数应用失败"; return 1; }
    else
        rm -f "$NFT_SYSCTL_FILE"
    fi
    rm -f "$tmp"
    [ "$need4" = yes ] || nft_sysctl_restore_family ipv4 || return 1
    [ "$need6" = yes ] || nft_sysctl_restore_family ipv6 || return 1
    if [ "$need4" = no ] && [ "$need6" = no ]; then
        rm -f "$NFT_SYSCTL_BASELINE"
    fi
}

nft_firewall_backend() {
    local ufw_active=no firewalld_active=no
    command -v ufw >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ] && ufw_active=yes
    command -v firewall-cmd >/dev/null 2>&1 \
        && [ "$(fw_running firewalld)" = active ] && firewalld_active=yes
    if [ "$ufw_active" = yes ] && [ "$firewalld_active" = yes ]; then echo conflict
    elif [ "$ufw_active" = yes ]; then echo ufw
    elif [ "$firewalld_active" = yes ]; then echo firewalld
    else echo none
    fi
}

nft_listen_iface() {
    local family="$1" lip="$2" flag iface
    flag=$(nft_family_flag "$family")
    if [ -n "$lip" ]; then
        iface=$(ip -o "$flag" addr show 2>/dev/null \
            | awk -v ip="$lip" '$4 == ip || index($4, ip "/") == 1 {print $2; exit}')
    elif [ "$family" = ipv6 ]; then
        iface=$(nft_ipv6_default_iface)
    else
        iface=$(default_iface)
    fi
    printf '%s\n' "$iface"
}

nft_target_iface() {
    local family="$1" target="$2" flag
    flag=$(nft_family_flag "$family")
    ip "$flag" route get "$target" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

nft_firewall_specs() {
    local backend="$1" zone="$2" id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment
    local p ports target_ports rule listen_iface target_iface
    while IFS='|' read -r id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ "$enabled" = yes ] || continue
        [ "$ls" = "$le" ] && ports="$ls" || ports="$ls-$le"
        listen_iface=$(nft_listen_iface "$family" "$lip")
        target_iface=$(nft_target_iface "$family" "$tip")
        while IFS= read -r p; do
            if [ "$backend" = ufw ]; then
                [ "$ts" = "$te" ] && target_ports="$ts" || target_ports="$ts:$te"
                printf 'ufw|%s|%s|%s|%s|%s|%s|QUENCH_NFT_%s_%s\n' \
                    "$family" "$p" "$listen_iface" "$target_iface" "$tip" "$target_ports" "$id" "$p"
            else
                [ "$ts" = "$te" ] && target_ports="$ts" || target_ports="$ts-$te"
                rule="rule family=\"$family\""
                [ -n "$lip" ] && rule="$rule destination address=\"$lip\""
                rule="$rule forward-port port=\"$ports\" protocol=\"$p\" to-port=\"$target_ports\" to-addr=\"$tip\""
                printf 'firewalld|%s|%s\n' "$zone" "$rule"
            fi
        done < <(nft_protocols "$proto")
    done < "$NFT_RULES_FILE"
}

nft_ufw_add_spec() {
    local family="$1" proto="$2" in_iface="$3" out_iface="$4" target="$5" ports="$6" tag="$7"
    [ -n "$in_iface" ] && [ -n "$out_iface" ] || return 1
    ufw route allow in on "$in_iface" out on "$out_iface" proto "$proto" \
        from any to "$target" port "$ports" comment "$tag" >/dev/null 2>&1
}

nft_ufw_delete_spec() {
    local family="$1" proto="$2" in_iface="$3" out_iface="$4" target="$5" ports="$6" tag="$7"
    nft_ufw_has_tag "$tag" || return 0
    ufw --force route delete allow in on "$in_iface" out on "$out_iface" proto "$proto" \
        from any to "$target" port "$ports" comment "$tag" >/dev/null 2>&1
}

nft_ufw_has_tag() {
    local tag="$1"
    LC_ALL=C ufw status numbered 2>/dev/null | grep -Fq -- "$tag"
}

nft_firewall_line_present() {
    local line="$1" backend a b c d e f g
    IFS='|' read -r backend a b c d e f g <<< "$line"
    case "$backend" in
        ufw) nft_ufw_has_tag "$g" ;;
        firewalld)
            firewall-cmd --permanent --zone="$a" --query-rich-rule="$b" >/dev/null 2>&1 \
                && firewall-cmd --zone="$a" --query-rich-rule="$b" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

nft_firewall_remove_line() {
    local line="$1" backend a b c d e f g
    IFS='|' read -r backend a b c d e f g <<< "$line"
    case "$backend" in
        ufw)
            command -v ufw >/dev/null 2>&1 || return 0
            nft_ufw_delete_spec "$a" "$b" "$c" "$d" "$e" "$f" "$g"
            ;;
        firewalld)
            command -v firewall-cmd >/dev/null 2>&1 || return 0
            if firewall-cmd --permanent --zone="$a" --query-rich-rule="$b" >/dev/null 2>&1; then
                firewall-cmd --permanent --zone="$a" --remove-rich-rule="$b" >/dev/null 2>&1 || return 1
            fi
            if firewall-cmd --zone="$a" --query-rich-rule="$b" >/dev/null 2>&1; then
                firewall-cmd --zone="$a" --remove-rich-rule="$b" >/dev/null 2>&1 || return 1
            fi
            ;;
    esac
}

nft_firewall_add_line() {
    local line="$1" backend a b c d e f g
    IFS='|' read -r backend a b c d e f g <<< "$line"
    case "$backend" in
        ufw) nft_ufw_add_spec "$a" "$b" "$c" "$d" "$e" "$f" "$g" ;;
        firewalld)
            firewall-cmd --permanent --zone="$a" --add-rich-rule="$b" >/dev/null 2>&1 || return 1
            firewall-cmd --zone="$a" --add-rich-rule="$b" >/dev/null 2>&1 || {
                firewall-cmd --permanent --zone="$a" --remove-rich-rule="$b" >/dev/null 2>&1 || true
                return 1
            }
            ;;
        *) return 1 ;;
    esac
}

nft_firewall_preserve_retry_state() {
    local additions="$1" retry line remove_failed
    retry=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-fw-retry.XXXXXX") || return 1
    cp "$NFT_FIREWALL_STATE" "$retry" || { rm -f "$retry"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qxF "$line" "$NFT_FIREWALL_STATE" 2>/dev/null && continue
        remove_failed=no
        nft_firewall_remove_line "$line" || remove_failed=yes
        if [ "$remove_failed" = yes ] || nft_firewall_line_present "$line"; then
            grep -qxF "$line" "$retry" || echo "$line" >> "$retry"
        fi
    done < "$additions"
    install -m 600 "$retry" "$NFT_FIREWALL_STATE" || { rm -f "$retry"; return 1; }
    rm -f "$retry"
}

nft_firewall_reconcile() {
    local backend zone="" desired new_state line failed=no
    backend=$(nft_firewall_backend)
    [ "$backend" != conflict ] || { error "UFW 与 firewalld 同时存在且状态冲突，拒绝写入转发规则"; return 1; }
    if [ "$backend" = firewalld ]; then zone=$(fw_firewalld_zone); fi
    desired=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-fw-desired.XXXXXX") || return 1
    new_state=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-fw-state.XXXXXX") || { rm -f "$desired"; return 1; }
    if [ "$backend" != none ]; then nft_firewall_specs "$backend" "$zone" > "$desired"; else : > "$desired"; fi

    # 先添加新规则，全部成功后再删除旧规则，避免修改时先中断现有线路。
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if grep -qxF "$line" "$NFT_FIREWALL_STATE" 2>/dev/null \
            && nft_firewall_line_present "$line"; then
            echo "$line" >> "$new_state"
        elif ! grep -qxF "$line" "$NFT_FIREWALL_STATE" 2>/dev/null \
            && nft_firewall_line_present "$line"; then
            # 完全相同的外部规则已经存在，不取得其所有权，也不在卸载时删除。
            continue
        elif nft_firewall_add_line "$line"; then
            echo "$line" >> "$new_state"
            if ! nft_firewall_line_present "$line"; then
                error "${backend} 命令已返回成功，但转发放行规则未生效"
                failed=yes
                break
            fi
        else
            error "${backend} 无法加入转发放行规则"
            failed=yes
            break
        fi
    done < "$desired"
    if [ "$failed" = yes ]; then
        nft_firewall_preserve_retry_state "$new_state" \
            || error "无法保存防火墙清理重试状态"
        rm -f "$desired" "$new_state"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! grep -qxF "$line" "$desired" && ! nft_firewall_remove_line "$line"; then
            error "无法删除旧的 ${backend} 转发放行规则"
            failed=yes
        fi
    done < "$NFT_FIREWALL_STATE"
    if [ "$failed" = yes ]; then
        nft_firewall_preserve_retry_state "$new_state" \
            || error "无法保存防火墙清理重试状态"
        rm -f "$desired" "$new_state"
        return 1
    fi
    install -m 600 "$new_state" "$NFT_FIREWALL_STATE" || { rm -f "$desired" "$new_state"; return 1; }
    rm -f "$desired" "$new_state"
}

nft_reconcile() {
    nft_ensure_state_dir || return 1
    nft_validate_database || return 1
    nft_firewall_reconcile || return 1
    nft_sysctl_reconcile || return 1
    nft_write_managed_file || return 1
    nft_install_persistence_service || return 1
    info "Quench 四层转发规则已原子应用 ✓"
}

# 保留内部函数名，供测试调用；行为已改为完整协调。
nft_rule_summary() {
    local id="$1" family="$2" proto="$3" lip="$4" ls="$5" le="$6" ttype="$7" thost="$8" tip="$9" \
        ts="${10}" te="${11}" mode="${12}" snat="${13}" acl="${14}" enabled="${15}" comment="${16}"
    local listen target ports target_ports state note=""
    [ -n "$lip" ] || { [ "$family" = ipv6 ] && lip="::" || lip="0.0.0.0"; }
    [ "$ls" = "$le" ] && ports="$ls" || ports="$ls-$le"
    [ "$ts" = "$te" ] && target_ports="$ts" || target_ports="$ts-$te"
    listen=$(nft_format_host_port "$lip" "$ports")
    target=$(nft_format_host_port "$thost" "$target_ports")
    [ "$ttype" = domain ] && note=" → $tip"
    [ "$enabled" = yes ] && state="启用" || state="停用"
    printf '[%s] [%s/%s] [%s] %s → %s%s · SNAT:%s · ACL:%s%s\n' \
        "$id" "$family" "$(nft_protocol_label "$proto")" "$state" "$listen" "$target" "$note" \
        "$snat" "$acl" "${comment:+ · $comment}"
}

nft_list_rules() {
    local count=0 id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment
    while IFS='|' read -r id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ -n "$id" ] || continue
        nft_rule_summary "$id" "$family" "$proto" "$lip" "$ls" "$le" "$ttype" "$thost" "$tip" \
            "$ts" "$te" "$mode" "$snat" "$acl" "$enabled" "$comment"
        count=$((count + 1))
    done < "$NFT_RULES_FILE"
    [ "$count" -gt 0 ]
}

nft_choose_protocol() {
    local choice
    menu_pair "1" "仅 TCP" "2" "仅 UDP"
    menu_item "3" "TCP + UDP"
    read -rp "  协议 [1/2/3]，默认 1: " choice
    [ -z "$choice" ] && choice=1
    case "$choice" in 1) echo tcp ;; 2) echo udp ;; 3) echo both ;; *) return 1 ;; esac
}

nft_choose_family() {
    local lip="$1" choice family
    if [ -n "$lip" ]; then
        family=$(nft_ip_family "$lip" 2>/dev/null) || return 1
        echo "$family"; return
    fi
    menu_pair "4" "IPv4" "6" "IPv6"
    read -rp "  监听协议族 [4/6]，默认 4: " choice
    [ -z "$choice" ] && choice=4
    case "$choice" in 4) echo ipv4 ;; 6) echo ipv6 ;; *) return 1 ;; esac
}

nft_choose_snat() {
    local choice
    echo -e "  ${DIM}masquerade：回程稳定，落地机看到线路机 IP（推荐）${NC}"
    echo -e "  ${DIM}保留源 IP：落地机必须把客户端回程路由指回本机，否则连接失败${NC}"
    menu_pair "1" "masquerade" "2" "保留客户端 IP"
    read -rp "  回程模式 [1/2]，默认 1: " choice
    [ -z "$choice" ] && choice=1
    case "$choice" in 1) echo masquerade ;; 2) echo preserve ;; *) return 1 ;; esac
}

nft_prompt_acl() {
    local id="$1" family="$2" choice raw entry tmp count=0
    menu_pair "1" "不限制来源" "2" "来源白名单"
    menu_item "3" "来源黑名单"
    read -rp "  访问控制 [1/2/3]，默认 1: " choice
    [ -z "$choice" ] && choice=1
    case "$choice" in
        1) NFT_PROMPT_ACL=off; return 0 ;;
        2) NFT_PROMPT_ACL=whitelist ;;
        3) NFT_PROMPT_ACL=blacklist ;;
        *) return 1 ;;
    esac
    echo -e "  ${DIM}多个 IP/CIDR 用空格或逗号分隔；名单只作用于这条转发规则${NC}"
    read -rp "  来源 IP/CIDR: " raw
    [ -n "$raw" ] || return 1
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-acl.XXXXXX") || return 1
    for entry in $(tr ',' ' ' <<< "$raw"); do
        nft_validate_access_entry "$entry" "$family" || { error "来源地址无效或协议族不一致：$entry"; rm -f "$tmp"; return 1; }
        grep -qxF "$id|$family|$entry" "$tmp" || { echo "$id|$family|$entry" >> "$tmp"; count=$((count + 1)); }
    done
    [ "$count" -gt 0 ] || { rm -f "$tmp"; return 1; }
    NFT_PROMPT_ACCESS_TMP="$tmp"
}

nft_local_listener_conflicts() {
    local proto="$1" ls="$2" le="$3" ss_flag port
    command -v ss >/dev/null 2>&1 || return 1
    [ "$proto" = tcp ] && ss_flag=-lntH || ss_flag=-lnuH
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [ "$port" -ge "$ls" ] && [ "$port" -le "$le" ] && { echo "$port"; return 0; }
    done < <(ss "$ss_flag" 2>/dev/null | awk '{a=$4; sub(/^.*:/,"",a); gsub(/[^0-9]/,"",a); if(a!="") print a}')
    return 1
}

nft_route_preflight() {
    local family="$1" target="$2" flag route
    flag=$(nft_family_flag "$family")
    route=$(ip "$flag" route get "$target" 2>/dev/null | head -1) || true
    [ -n "$route" ] || { error "本机没有到目标 $target 的 $family 路由"; return 1; }
    echo -e "  ${DIM}目标路由：$route${NC}"
}

nft_tcp_probe() {
    local host="$1" port="$2"
    command -v timeout >/dev/null 2>&1 || return 2
    # shellcheck disable=SC2016 # $1/$2 由 bash -c 的位置参数提供，不能在外层展开
    timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1
}

nft_rule_preflight() {
    local family="$1" proto="$2" lip="$3" ls="$4" le="$5" tip="$6" ts="$7" conflict p local_port answer
    nft_route_preflight "$family" "$tip" || return 1
    if [ -n "$lip" ] && ! ip -o "$(nft_family_flag "$family")" addr show 2>/dev/null \
        | awk -v ip="$lip" '$4 == ip || index($4, ip "/") == 1 {found=1} END {exit !found}'; then
        error "监听 IP $lip 当前不在本机任何接口上"
        return 1
    fi
    conflict=$(nft_rule_conflict_id "${NFT_EDIT_ID:-}" "$family" "$proto" "$lip" "$ls" "$le" || true)
    [ -z "$conflict" ] || { error "监听范围与现有规则 [$conflict] 冲突"; return 1; }
    while IFS= read -r p; do
        local_port=$(nft_local_listener_conflicts "$p" "$ls" "$le" || true)
        if [ -n "$local_port" ]; then
            warn "本机已有 $p 服务监听端口 ${local_port}；转发会截获外部访问"
            read -rp "  仍然继续？(y/N，默认N): " answer
            echo "$answer" | grep -qiE '^y(es)?$' || return 1
        fi
    done < <(nft_protocols "$proto")
    if [ "$proto" != udp ] && nft_tcp_probe "$tip" "$ts"; then
        info "目标 TCP ${tip}:${ts} 当前可连接"
    elif [ "$proto" != udp ]; then
        warn "目标 TCP ${tip}:${ts} 暂不可连接；可继续保存，但转发暂时不会可用"
    fi
}

nft_rule_record_replace() {
    local id="$1" record="$2" tmp rc=0
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-rules.XXXXXX") || return 1
    awk -F'|' -v id="$id" '$1 != id' "$NFT_RULES_FILE" > "$tmp" || rc=1
    [ "$rc" -ne 0 ] || echo "$record" >> "$tmp" || rc=1
    [ "$rc" -ne 0 ] || install -m 600 "$tmp" "$NFT_RULES_FILE" || rc=1
    rm -f "$tmp"
    return "$rc"
}

nft_restore_snapshot() {
    local rules="$1" access="$2"
    install -m 600 "$rules" "$NFT_RULES_FILE" || true
    install -m 600 "$access" "$NFT_ACCESS_FILE" || true
    nft_reconcile >/dev/null 2>&1 || true
}

nft_add_rule() {
    local kind="$1" id lip family proto ls le thost ttype tip ts te map_mode snat acl comment count
    local rules_backup access_backup choice confirm
    print_header "添加线路机 → 落地机转发"
    nft_install || { error "nftables 安装失败"; return 1; }
    nft_ensure_state_dir || return 1
    id=$(nft_next_rule_id)
    read -rp "  监听本机 IP（留空=该协议族全部地址）: " lip
    if [ -n "$lip" ] && ! nft_ip_family "$lip" >/dev/null 2>&1; then
        error "监听地址必须是本机 IP，不能填写域名"; return 1
    fi
    family=$(nft_choose_family "$lip") || { error "协议族无效"; return 1; }
    proto=$(nft_choose_protocol) || { error "协议无效"; return 1; }
    if [ "$kind" = single ]; then
        read -rp "  线路机监听端口: " ls
        nft_check_port "$ls" || { error "端口无效"; return 1; }
        le="$ls"
    else
        read -rp "  线路机监听起始端口: " ls
        read -rp "  线路机监听结束端口: " le
        nft_check_port "$ls" && nft_check_port "$le" && [ "$ls" -le "$le" ] \
            || { error "端口段无效"; return 1; }
    fi
    read -rp "  落地机 IP / 域名: " thost
    ttype=$(nft_target_type "$thost")
    [ "$ttype" != invalid ] || { error "目标地址格式无效"; return 1; }
    if [ "$ttype" = domain ]; then
        tip=$(nft_resolve_domain "$thost" "$family") || { error "域名没有可用的 $family 地址"; return 1; }
    else
        [ "$(nft_ip_family "$thost" 2>/dev/null)" = "$family" ] \
            || { error "监听与目标必须使用同一协议族"; return 1; }
        nft_ip_usable_target "$thost" || { error "目标不能是回环、未指定或组播地址"; return 1; }
        tip="$thost"
    fi
    if [ "$kind" = single ]; then
        read -rp "  落地机目标端口（留空=同监听端口）: " ts
        [ -n "$ts" ] || ts="$ls"
        nft_check_port "$ts" || { error "目标端口无效"; return 1; }
        te="$ts"; map_mode=single
    else
        menu_pair "1" "端口段 1:1" "2" "端口段偏移"
        read -rp "  映射模式 [1/2]，默认 1: " choice
        [ -n "$choice" ] || choice=1
        count=$((le - ls + 1))
        if [ "$choice" = 2 ]; then
            [ "$count" -le "$NFT_OFFSET_RANGE_MAX" ] \
                || { error "偏移映射最多 $NFT_OFFSET_RANGE_MAX 个端口"; return 1; }
            read -rp "  落地机目标起始端口: " ts
            nft_check_port "$ts" || { error "目标端口无效"; return 1; }
            te=$((ts + count - 1))
            [ "$te" -le 65535 ] || { error "目标结束端口超过 65535"; return 1; }
            map_mode=range_offset
        else
            ts="$ls"; te="$le"; map_mode=range_1_to_1
        fi
    fi
    snat=$(nft_choose_snat) || { error "回程模式无效"; return 1; }
    NFT_PROMPT_ACCESS_TMP=""; NFT_PROMPT_ACL=""
    nft_prompt_acl "$id" "$family" \
        || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; error "访问名单无效"; return 1; }
    acl="$NFT_PROMPT_ACL"
    read -rp "  备注（可留空）: " comment
    comment="${comment//|/-}"
    NFT_EDIT_ID=""
    nft_rule_preflight "$family" "$proto" "$lip" "$ls" "$le" "$tip" "$ts" \
        || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; return 1; }
    echo ""
    nft_rule_summary "$id" "$family" "$proto" "$lip" "$ls" "$le" "$ttype" "$thost" "$tip" \
        "$ts" "$te" "$map_mode" "$snat" "$acl" yes "$comment"
    [ "$snat" = preserve ] && warn "保留源 IP 模式要求落地机回程经过本线路机"
    warn "还需在云厂商安全组放行线路机监听端口；Quench 无法自动修改云防火墙"
    read -rp "  确认添加？(Y/n，默认Y): " confirm
    [ -z "$confirm" ] && confirm=y
    echo "$confirm" | grep -qiE '^y(es)?$' \
        || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; warn "已取消"; return; }

    nft_lock_acquire || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; return 1; }
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; return 1; }
    if ! echo "$id|$family|$proto|$lip|$ls|$le|$ttype|$thost|$tip|$ts|$te|$map_mode|$snat|$acl|yes|$comment" \
        >> "$NFT_RULES_FILE"; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup" "${NFT_PROMPT_ACCESS_TMP:-}"
        return 1
    fi
    if [ -n "${NFT_PROMPT_ACCESS_TMP:-}" ] \
        && ! cat "$NFT_PROMPT_ACCESS_TMP" >> "$NFT_ACCESS_FILE"; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup" "${NFT_PROMPT_ACCESS_TMP:-}"
        return 1
    fi
    rm -f "${NFT_PROMPT_ACCESS_TMP:-}"
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"
        nft_lock_release
        rm -f "$rules_backup" "$access_backup"
        error "添加失败，规则、内核参数与防火墙已尝试恢复"
        return 1
    fi
    nft_lock_release
    rm -f "$rules_backup" "$access_backup"
}

nft_edit_rule() {
    local id rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment
    local value old_family new_family new_ttype count record rules_backup access_backup confirm
    print_header "修改线路转发规则"
    nft_list_rules || { warn "暂无规则"; return; }
    read -rp "  规则 ID（0 取消）: " id
    [ "$id" != 0 ] && [ -n "$id" ] || return
    nft_find_rule "$id" || { error "未找到规则"; return 1; }
    IFS='|' read -r rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment <<< "$NFT_FOUND_RULE"
    old_family="$family"
    echo -e "  ${DIM}直接回车保留原值；监听 IP 输入 * 表示全部地址，备注输入 - 表示清空${NC}"

    read -rp "  协议 tcp/udp/both [$proto]: " value
    [ -z "$value" ] || proto="$value"
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || { error "协议无效"; return 1; }
    read -rp "  监听 IP [${lip:-全部}]: " value
    if [ "$value" = '*' ]; then lip=""; elif [ -n "$value" ]; then lip="$value"; fi
    if [ -n "$lip" ]; then
        new_family=$(nft_ip_family "$lip" 2>/dev/null) || { error "监听 IP 无效"; return 1; }
    else
        read -rp "  协议族 ipv4/ipv6 [$family]: " value
        [ -n "$value" ] && family="$value"
        [[ "$family" =~ ^ipv[46]$ ]] || { error "协议族无效"; return 1; }
        new_family="$family"
    fi
    read -rp "  监听起始端口 [$ls]: " value; [ -z "$value" ] || ls="$value"
    if [ "$mode" = single ]; then
        le="$ls"
    else
        read -rp "  监听结束端口 [$le]: " value; [ -z "$value" ] || le="$value"
    fi
    nft_check_port "$ls" && nft_check_port "$le" && [ "$ls" -le "$le" ] \
        || { error "监听端口范围无效"; return 1; }

    read -rp "  落地机 IP/域名 [$thost]: " value; [ -z "$value" ] || thost="$value"
    new_ttype=$(nft_target_type "$thost")
    [ "$new_ttype" != invalid ] || { error "落地机地址无效"; return 1; }
    if [ "$new_ttype" = domain ]; then
        tip=$(nft_resolve_domain "$thost" "$new_family") || { error "域名没有可用的 $new_family 地址"; return 1; }
    else
        [ "$(nft_ip_family "$thost" 2>/dev/null)" = "$new_family" ] \
            || { error "监听与目标必须使用同一协议族"; return 1; }
        nft_ip_usable_target "$thost" || { error "目标地址不可用于远程转发"; return 1; }
        tip="$thost"
    fi
    if [ "$mode" = range_1_to_1 ]; then
        ts="$ls"; te="$le"
    else
        read -rp "  落地机目标起始端口 [$ts]: " value; [ -z "$value" ] || ts="$value"
        nft_check_port "$ts" || { error "目标端口无效"; return 1; }
        if [ "$mode" = single ]; then
            te="$ts"
        else
            count=$((le - ls + 1))
            [ "$count" -le "$NFT_OFFSET_RANGE_MAX" ] \
                || { error "偏移映射最多 $NFT_OFFSET_RANGE_MAX 个端口"; return 1; }
            te=$((ts + count - 1)); [ "$te" -le 65535 ] || { error "目标结束端口超过 65535"; return 1; }
        fi
    fi
    read -rp "  回程模式 masquerade/preserve [$snat]: " value
    [ -z "$value" ] || snat="$value"
    [[ "$snat" =~ ^(masquerade|preserve)$ ]] || { error "回程模式无效"; return 1; }
    read -rp "  备注 [${comment:-无}]: " value
    if [ "$value" = '-' ]; then comment=""; elif [ -n "$value" ]; then comment="${value//|/-}"; fi

    # 协议族变化后旧名单不再有效，先关闭 ACL，用户可从独立菜单重新设置。
    if [ "$new_family" != "$old_family" ]; then
        family="$new_family"; acl=off
        warn "协议族已变化，原来源访问名单将被清除"
    else
        family="$new_family"
    fi
    ttype="$new_ttype"
    NFT_EDIT_ID="$id"
    [ "$enabled" = no ] || nft_rule_preflight "$family" "$proto" "$lip" "$ls" "$le" "$tip" "$ts" || return 1
    record="$rid|$family|$proto|$lip|$ls|$le|$ttype|$thost|$tip|$ts|$te|$mode|$snat|$acl|$enabled|$comment"
    echo ""; IFS='|' read -r -a fields <<< "$record"; nft_rule_summary "${fields[@]}"
    read -rp "  确认修改？(Y/n，默认Y): " confirm
    [ -z "$confirm" ] && confirm=y
    echo "$confirm" | grep -qiE '^y(es)?$' || return

    nft_lock_acquire || return 1
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; return 1; }
    nft_rule_record_replace "$id" "$record" \
        || { nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release; rm -f "$rules_backup" "$access_backup"; return 1; }
    if [ "$new_family" != "$old_family" ]; then
        nft_replace_access_for_rule "$id" "" \
            || { nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release; rm -f "$rules_backup" "$access_backup"; return 1; }
    fi
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup"; error "修改失败，已尝试恢复"; return 1
    fi
    nft_lock_release; rm -f "$rules_backup" "$access_backup"
}

nft_delete_rule() {
    local id rules_backup access_backup confirm
    print_header "删除线路转发规则"
    nft_list_rules || { warn "暂无规则"; return; }
    read -rp "  规则 ID（0 取消）: " id
    [ "$id" != 0 ] && [ -n "$id" ] || return
    nft_find_rule "$id" || { error "未找到规则"; return 1; }
    echo ""
    IFS='|' read -r -a fields <<< "$NFT_FOUND_RULE"
    nft_rule_summary "${fields[@]}"
    read -rp "  确认删除？(y/N，默认N): " confirm
    echo "$confirm" | grep -qiE '^y(es)?$' || return
    nft_lock_acquire || return 1
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; return 1; }
    if ! awk -F'|' -v id="$id" '$1 != id' "$NFT_RULES_FILE" > "${rules_backup}.new" \
        || ! awk -F'|' -v id="$id" '$1 != id' "$NFT_ACCESS_FILE" > "${access_backup}.new" \
        || ! install -m 600 "${rules_backup}.new" "$NFT_RULES_FILE" \
        || ! install -m 600 "${access_backup}.new" "$NFT_ACCESS_FILE"; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup" "${rules_backup}.new" "${access_backup}.new"
        return 1
    fi
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup" "${rules_backup}.new" "${access_backup}.new"
        error "删除失败，已尝试恢复"
        return 1
    fi
    nft_lock_release
    rm -f "$rules_backup" "$access_backup" "${rules_backup}.new" "${access_backup}.new"
}

nft_toggle_rule() {
    local id record rules_backup access_backup rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment
    print_header "启用 / 停用转发规则"
    nft_list_rules || { warn "暂无规则"; return; }
    read -rp "  规则 ID（0 取消）: " id
    [ "$id" != 0 ] && [ -n "$id" ] || return
    nft_find_rule "$id" || { error "未找到规则"; return 1; }
    IFS='|' read -r rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment <<< "$NFT_FOUND_RULE"
    [ "$enabled" = yes ] && enabled=no || enabled=yes
    if [ "$enabled" = yes ]; then
        NFT_EDIT_ID="$id"
        nft_rule_preflight "$family" "$proto" "$lip" "$ls" "$le" "$tip" "$ts" || return 1
    fi
    record="$rid|$family|$proto|$lip|$ls|$le|$ttype|$thost|$tip|$ts|$te|$mode|$snat|$acl|$enabled|$comment"
    nft_lock_acquire || return 1
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; return 1; }
    nft_rule_record_replace "$id" "$record" \
        || { nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release; rm -f "$rules_backup" "$access_backup"; return 1; }
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup"; return 1
    fi
    nft_lock_release; rm -f "$rules_backup" "$access_backup"
}

nft_replace_access_for_rule() {
    local id="$1" replacement="$2" tmp rc=0
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-access-db.XXXXXX") || return 1
    awk -F'|' -v id="$id" '$1 != id' "$NFT_ACCESS_FILE" > "$tmp" || rc=1
    if [ "$rc" -eq 0 ] && [ -n "$replacement" ]; then
        cat "$replacement" >> "$tmp" || rc=1
    fi
    [ "$rc" -ne 0 ] || install -m 600 "$tmp" "$NFT_ACCESS_FILE" || rc=1
    rm -f "$tmp"
    return "$rc"
}

nft_edit_access() {
    local id rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment record
    local rules_backup access_backup
    print_header "修改规则访问名单"
    nft_list_rules || { warn "暂无规则"; return; }
    read -rp "  规则 ID（0 取消）: " id
    [ "$id" != 0 ] && [ -n "$id" ] || return
    nft_find_rule "$id" || { error "未找到规则"; return 1; }
    IFS='|' read -r rid family proto lip ls le ttype thost tip ts te mode snat acl enabled comment <<< "$NFT_FOUND_RULE"
    NFT_PROMPT_ACCESS_TMP=""; NFT_PROMPT_ACL=""
    nft_prompt_acl "$id" "$family" \
        || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; error "访问名单无效"; return 1; }
    acl="$NFT_PROMPT_ACL"
    record="$rid|$family|$proto|$lip|$ls|$le|$ttype|$thost|$tip|$ts|$te|$mode|$snat|$acl|$enabled|$comment"
    nft_lock_acquire || { rm -f "${NFT_PROMPT_ACCESS_TMP:-}"; return 1; }
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; rm -f "$rules_backup" "$access_backup" "${NFT_PROMPT_ACCESS_TMP:-}"; return 1; }
    if ! nft_rule_record_replace "$id" "$record" \
        || ! nft_replace_access_for_rule "$id" "${NFT_PROMPT_ACCESS_TMP:-}"; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup" "${NFT_PROMPT_ACCESS_TMP:-}"
        return 1
    fi
    rm -f "${NFT_PROMPT_ACCESS_TMP:-}"
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup"; return 1
    fi
    nft_lock_release; rm -f "$rules_backup" "$access_backup"
}

nft_refresh_domain_targets() {
    local tmp rules_backup access_backup changed=0 domains=0
    local id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment new_ip
    nft_ensure_state_dir || return 1
    nft_lock_acquire || return 1
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-refresh.XXXXXX") || { nft_lock_release; return 1; }
    while IFS='|' read -r id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ -n "$id" ] || continue
        if [ "$ttype" = domain ]; then
            domains=$((domains + 1))
            if new_ip=$(nft_resolve_domain "$thost" "$family"); then
                if [ "$new_ip" != "$tip" ]; then
                    info "[$id] $thost: $tip → $new_ip"
                    tip="$new_ip"; changed=$((changed + 1))
                fi
            else
                warn "[$id] $thost 解析失败，继续使用 $tip"
            fi
        fi
        echo "$id|$family|$proto|$lip|$ls|$le|$ttype|$thost|$tip|$ts|$te|$mode|$snat|$acl|$enabled|$comment" >> "$tmp"
    done < "$NFT_RULES_FILE"
    if [ "$domains" -eq 0 ] || [ "$changed" -eq 0 ]; then
        [ "$domains" -eq 0 ] && warn "没有域名目标" || info "域名目标没有变化"
        rm -f "$tmp"; nft_lock_release; return 0
    fi
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { rm -f "$tmp" "$rules_backup" "$access_backup"; nft_lock_release; return 1; }
    install -m 600 "$tmp" "$NFT_RULES_FILE" \
        || { rm -f "$tmp" "$rules_backup" "$access_backup"; nft_lock_release; return 1; }
    rm -f "$tmp"
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"
        rm -f "$rules_backup" "$access_backup"; nft_lock_release; return 1
    fi
    rm -f "$rules_backup" "$access_backup"; nft_lock_release
}

nft_refresh_interval_valid() {
    local value="$1" number unit seconds
    [[ "$value" =~ ^([0-9]+)(s|m|h)$ ]] || return 1
    number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in s) seconds=$number ;; m) seconds=$((number * 60)) ;; h) seconds=$((number * 3600)) ;; esac
    [ "$seconds" -ge 10 ] && [ "$seconds" -le 86400 ]
}

nft_ensure_runtime_script() {
    [ -x "${LOCAL_SCRIPT:-}" ] && return 0
    local source
    source=$(self_resolve_script_source "$0" 2>/dev/null || true)
    [ -n "$source" ] \
        || { error "请先从脚本管理中将 Quench 安装到本机，再启用定时刷新"; return 1; }
    self_atomic_replace "$source" "$LOCAL_SCRIPT" || return 1
}

nft_refresh_timer_status() {
    systemd_available && systemctl is-active --quiet quench-nft-target-refresh.timer 2>/dev/null \
        && echo active || echo inactive
}

nft_refresh_timer_enable() {
    local interval tmp
    systemd_available || { error "自动刷新当前仅支持 systemd"; return 1; }
    nft_ensure_runtime_script || return 1
    read -rp "  刷新间隔（10s～24h，默认 5m）: " interval
    [ -n "$interval" ] || interval=5m
    nft_refresh_interval_valid "$interval" || { error "间隔格式无效，例如 30s、5m、2h"; return 1; }
    tmp=$(quench_mktemp "${TMPDIR:-/tmp}/quench-nft-refresh-service.XXXXXX") || return 1
    cat > "$tmp" <<EOF
[Unit]
Description=Quench NFT domain target refresh
After=network-online.target

[Service]
Type=oneshot
ExecStart=$LOCAL_SCRIPT --nft-refresh-targets
EOF
    install -m 644 "$tmp" "$NFT_REFRESH_SERVICE_FILE" || { rm -f "$tmp"; return 1; }
    cat > "$tmp" <<EOF
[Unit]
Description=Quench NFT domain target refresh timer

[Timer]
OnBootSec=$interval
OnUnitActiveSec=$interval
AccuracySec=1s
Unit=quench-nft-target-refresh.service

[Install]
WantedBy=timers.target
EOF
    install -m 644 "$tmp" "$NFT_REFRESH_TIMER_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now quench-nft-target-refresh.timer >/dev/null 2>&1 \
        && info "域名目标自动刷新已启用（${interval}）✓" \
        || { error "自动刷新启用失败"; return 1; }
}

nft_refresh_timer_disable() {
    systemd_available && systemctl disable --now quench-nft-target-refresh.timer >/dev/null 2>&1 || true
    rm -f "$NFT_REFRESH_TIMER_FILE" "$NFT_REFRESH_SERVICE_FILE"
    systemd_available && systemctl daemon-reload >/dev/null 2>&1 || true
    info "域名目标自动刷新已关闭"
}

nft_table_present() {
    local family="$1" table
    [ "$family" = ipv6 ] && table="ip6 quench_nft6" || table="ip quench_nft4"
    # shellcheck disable=SC2086 # family and table are fixed internal tokens
    nft list table $table >/dev/null 2>&1
}

nft_diagnostics() {
    local backend count id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment flag route
    print_header "线路转发诊断"
    count=$(nft_rule_count); backend=$(nft_firewall_backend)
    echo -e "  启用规则：${BOLD}$count${NC}    防火墙后端：${BOLD}$backend${NC}"
    echo -e "  IPv4 转发：${BOLD}$(nft_sysctl_get net.ipv4.ip_forward || echo 不可用)${NC}"
    echo -e "  IPv6 转发：${BOLD}$(nft_sysctl_get net.ipv6.conf.all.forwarding || echo 不可用)${NC}"
    for family in ipv4 ipv6; do
        if nft_rules_has_family "$family"; then
            nft_table_present "$family" && info "$family Quench 规则表已加载" || error "$family Quench 规则表缺失"
        fi
    done
    if systemd_available; then
        systemctl is-enabled --quiet quench-nft-forward.service 2>/dev/null \
            && info "Quench 独立持久服务已启用" || warn "Quench 持久服务未启用"
    fi
    echo ""
    while IFS='|' read -r id family proto lip ls le ttype thost tip ts te mode snat acl enabled comment; do
        [ "$enabled" = yes ] || continue
        flag=$(nft_family_flag "$family")
        route=$(ip "$flag" route get "$tip" 2>/dev/null | head -1 || true)
        [ -n "$route" ] && info "[$id] 目标路由存在：$route" || error "[$id] 目标 $tip 没有路由"
        if [ "$proto" != udp ] && nft_tcp_probe "$tip" "$ts"; then
            info "[$id] TCP 目标 ${tip}:${ts} 可连接"
        elif [ "$proto" != udp ]; then
            warn "[$id] TCP 目标 ${tip}:${ts} 当前不可连接"
        fi
        [ "$snat" = preserve ] && warn "[$id] 保留源 IP：请确认落地机回程指向本线路机"
    done < "$NFT_RULES_FILE"
    echo ""
    echo -e "  ${DIM}规则计数器：${NC}"
    nft list table ip quench_nft4 2>/dev/null | grep -E 'quench-forward-[0-9]+|quench-acl-[0-9]+' || true
    nft list table ip6 quench_nft6 2>/dev/null | grep -E 'quench-forward-[0-9]+|quench-acl-[0-9]+' || true
    echo ""
    warn "本模块不提供加密、线路选择或健康切换；链路质量仍由实际路由决定"
    warn "云厂商安全组必须另行放行监听端口"
}

nft_reapply() {
    nft_install || return 1
    nft_lock_acquire || return 1
    nft_reconcile
    local rc=$?
    nft_lock_release
    return "$rc"
}

nft_clear_all_rules() {
    local rules_backup access_backup confirm
    warn "这会删除 Quench 管理的全部线路转发规则"
    read -rp "  输入 CLEAR 确认: " confirm
    [ "$confirm" = CLEAR ] || return
    nft_lock_acquire || return 1
    rules_backup=$(quench_mktemp); access_backup=$(quench_mktemp)
    cp "$NFT_RULES_FILE" "$rules_backup" && cp "$NFT_ACCESS_FILE" "$access_backup" \
        || { nft_lock_release; return 1; }
    if ! : > "$NFT_RULES_FILE" || ! : > "$NFT_ACCESS_FILE"; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup"; return 1
    fi
    if ! nft_reconcile; then
        nft_restore_snapshot "$rules_backup" "$access_backup"; nft_lock_release
        rm -f "$rules_backup" "$access_backup"; return 1
    fi
    nft_lock_release; rm -f "$rules_backup" "$access_backup"
}

nft_remove_services() {
    nft_refresh_timer_disable >/dev/null 2>&1 || true
    if systemd_available; then
        systemctl disable --now quench-nft-forward.service >/dev/null 2>&1 || true
        rm -f "$NFT_SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-service quench-nft-forward stop >/dev/null 2>&1 || true
        rc-update del quench-nft-forward default >/dev/null 2>&1 || true
    fi
    rm -f "$NFT_OPENRC_FILE" "$NFT_APPLY_HELPER"
}

nft_uninstall() {
    local confirm family table cleanup_failed=0
    print_header "卸载 Quench 线路转发模块"
    warn "只删除 Quench 自己的规则、服务和参数；不会卸载 nftables 或清空其他规则"
    read -rp "  输入 PURGE 确认: " confirm
    [ "$confirm" = PURGE ] || return
    nft_ensure_state_dir || return 1
    nft_lock_acquire || return 1
    : > "$NFT_RULES_FILE"; : > "$NFT_ACCESS_FILE"
    nft_firewall_reconcile || { warn "部分防火墙联动规则未能清理，可修复防火墙后重试卸载"; cleanup_failed=1; }
    nft_sysctl_reconcile || { warn "内核转发参数未完全恢复，可修复 sysctl 后重试卸载"; cleanup_failed=1; }
    while read -r family table; do
        nft delete table "$family" "$table" >/dev/null 2>&1 || true
    done < <(nft_table_names)
    if [ "$cleanup_failed" -ne 0 ]; then
        nft_lock_release
        error "卸载未完成：已停用转发，但保留状态与服务供下次重试"
        return 1
    fi
    nft_remove_services
    rm -f "$NFT_MANAGED_FILE" "$NFT_SYSCTL_FILE"
    nft_lock_release
    rm -rf "$NFT_STATE_DIR" "$NFT_RUNTIME_DIR"
    info "Quench 线路转发模块已卸载；其他 nftables/防火墙规则保持不变 ✓"
}

nft_menu() {
    nft_ensure_state_dir || return 1
    while true; do
        local count backend timer choice
        count=$(nft_rule_count); backend=$(nft_firewall_backend); timer=$(nft_refresh_timer_status)
        print_header "四层端口转发（线路机 → 落地机）"
        echo -e "  启用规则 : ${BOLD}$count${NC}    防火墙联动: ${BOLD}$backend${NC}"
        [ "$timer" = active ] \
            && echo -e "  域名刷新 : ${GREEN}运行中${NC}" \
            || echo -e "  域名刷新 : ${DIM}未启用${NC}"
        echo -e "  ${DIM}DNAT 转发 TCP/UDP；默认 masquerade 保证对称回程${NC}"
        echo -e "  ${DIM}不是 VPN/隧道，不会让整机出站自动经过落地机${NC}"
        if [ -s "$NFT_RULES_FILE" ]; then menu_div; nft_list_rules; fi
        menu_div
        menu_pair "1" "添加单端口转发" "2" "添加端口段转发"
        menu_pair "3" "启用/停用规则" "e" "修改规则参数"
        menu_pair "4" "修改规则访问名单" "5" "删除规则" "" "$YELLOW"
        menu_item "6" "清空全部规则" "$YELLOW"
        echo ""
        menu_group "检查与维护"
        menu_pair "d" "线路转发诊断" "r" "校验并重新应用"
        menu_pair "f" "立即刷新域名目标" "a" "$([ "$timer" = active ] && echo 关闭域名自动刷新 || echo 启用域名自动刷新)"
        menu_item "u" "卸载 Quench 转发模块" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" choice
        case "$choice" in
            1) nft_add_rule single ;;
            2) nft_add_rule range ;;
            3) nft_toggle_rule ;;
            e|E) nft_edit_rule ;;
            4) nft_edit_access ;;
            5) nft_delete_rule ;;
            6) nft_clear_all_rules ;;
            d|D) nft_diagnostics ;;
            r|R) nft_reapply ;;
            f|F) nft_refresh_domain_targets ;;
            a|A) [ "$timer" = active ] && nft_refresh_timer_disable || nft_refresh_timer_enable ;;
            u|U) nft_uninstall ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        echo ""; ui_continue
    done
}
# ══════════════════════════════════════════════════════════
#  Quench 主菜单与命令行入口
# ══════════════════════════════════════════════════════════
# ── 后台版本检测 ────────────────────────────────────────
# 只为读一行版本号而下载整份 700KB 脚本太浪费，而且每次启动都做。
# build.sh 会同步生成 vps-quench.manifest.json（几百字节，带 version 字段），
# 改读它即可。拉不到就直接跳过：这只是个提示，真正的更新走 self_update，
# 那条路径仍然锁定 commit 并校验 SHA256。
self_check_update() {
    local REMOTE_VER CUR_VER HINT_DIR HINT_STAGE
    REMOTE_VER=$(curl -fsSL --max-time 5 "$QUENCH_MANIFEST_URL" 2>/dev/null \
        | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"(V[0-9]+[.][0-9]+([.][0-9]+)?)".*/\1/p' \
        | head -1)
    [ -z "$REMOTE_VER" ] && return
    CUR_VER=$(sed -nE 's/^APP_VERSION="(V[0-9]+[.][0-9]+([.][0-9]+)?)".*/\1/p' "$0" 2>/dev/null \
        | head -1)
    [ -z "$CUR_VER" ] && return
    if [ "$REMOTE_VER" = "$CUR_VER" ]; then
        rm -f "$QUENCH_UPDATE_HINT_FILE" 2>/dev/null || true
        return
    fi
    HINT_DIR=$(dirname "$QUENCH_UPDATE_HINT_FILE")
    mkdir -p "$HINT_DIR" 2>/dev/null || return
    HINT_STAGE=$(mktemp "$HINT_DIR/.new-version.XXXXXX") || return
    printf '%s\n' "$REMOTE_VER" > "$HINT_STAGE" && chmod 600 "$HINT_STAGE" \
        && mv "$HINT_STAGE" "$QUENCH_UPDATE_HINT_FILE" || rm -f "$HINT_STAGE"
}

show_cli_help() {
    cat <<'EOF'
Quench CLI — VPS 初始化与管理工具

用法:
  bash vps-quench.sh [命令]

常用命令:
  --help                 显示此帮助
  --version              显示版本号
  --first-run            首次开荒向导
  --user-menu            用户与 SSH 访问管理
  --fail2ban-menu        Fail2ban 管理
  --bbr-menu             网络性能调优（BBR / tc / initcwnd）
  --bbr-calibrate        线路实测与 policer 拐点校准
  --bbr-reconcile-tc     按已保存状态恢复 tc 限速（内部入口）
  --firewall-menu        防火墙管理
  --dns-menu             DNS 管理与诊断
  --mirror-menu          软件源管理
  --ip-menu              IP 状态与出口管理
  --caddy-menu           Caddy 网站入口管理
  --nft-menu             线路机四层端口转发
  --time-menu            时间、时区与 NTP
  --https-time-sync      手动执行 HTTPS 应急粗校时
  --swap-menu            Swap 管理
  --system-toolbox-menu  安全与诊断
  --stun-test            STUN / UDP / NAT 检测
  --hostname-menu        修改系统 hostname
  --docker-menu          Docker 管理
  --software-menu        常用软件管理
  --self-manage-menu     脚本管理
  --config-backup-menu   配置备份
  --config-transfer-menu 配置迁移
  --rollback-center-menu 回滚中心
  --nft-refresh-targets  NFT 域名目标刷新（内部入口）
EOF
}

main_menu() {
    while true; do
        # 每轮在父 shell 里读一次真实状态；本轮内的多次 get_config（都是命令
        # 替换、跑在子 shell 里）继承这份已装载的缓存，不再各自 fork sshd -T。
        sshd_effective_reload
        local CUR_PORT CUR_PWD CUR_PUBKEY USER_TOTAL ADMIN_TOTAL
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        USER_TOTAL=$(user_count)
        ADMIN_TOTAL=$(user_admin_count)
        local F2B_STAT; F2B_STAT=$(f2b_status)

        safe_clear
        echo ""
        quench_art_banner
        echo ""
        box_top
        app_header_line
        echo -e "  ${DIM}SSH · BBR · DNS · Caddy · Firewall · NFT · Docker${NC}"
        box_sep
        # 收集状态数据
        local FW_TYPE FW_STAT FW_STATE
        FW_TYPE=$(fw_detect)
        if [ "$FW_TYPE" = "none" ]; then
            FW_STAT="未安装"; FW_STATE="unknown"
        elif [ "$FW_TYPE" = "conflict" ]; then
            FW_STAT="UFW / firewalld 冲突"; FW_STATE="warning"
        elif [ "$(fw_running "$FW_TYPE")" = "active" ]; then
            FW_STAT="${FW_TYPE} 运行中"; FW_STATE="active"
        else
            FW_STAT="${FW_TYPE} 已停止"; FW_STATE="inactive"
        fi
        local BBR_CC; BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved >/dev/null 2>&1 || true
        local TC_RATE TC_DEV TC_BIN
        TC_DEV=$(default_iface)
        TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
        TC_RATE=$(bbr_tc_rate_display "$TC_DEV" "$TC_BIN")
        [ "$TC_RATE" = "未设置" ] && TC_RATE="无限速"
        local CADDY_ST; CADDY_ST=$(caddy_status)
        local CADDY_LABEL
        case "$CADDY_ST" in
            running)       CADDY_LABEL="运行中" ;;
            stopped)       CADDY_LABEL="已停止" ;;
            unmanaged)     CADDY_LABEL="外部进程" ;;
            not_installed) CADDY_LABEL="未安装" ;;
        esac
        local DOCKER_ST DOCKER_LABEL DOCKER_STATE
        DOCKER_ST=$(docker_status)
        case "$DOCKER_ST" in
            running) DOCKER_LABEL="运行中"; DOCKER_STATE="active" ;;
            stopped) DOCKER_LABEL="已停止"; DOCKER_STATE="inactive" ;;
            *) DOCKER_LABEL="未安装"; DOCKER_STATE="unknown" ;;
        esac
        local SYS_TIME SYS_TZ
        SYS_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        SYS_TZ=$(ts_current_timezone)

        # 状态仪表盘
        local AUTH_LABEL AUTH_STATE CADDY_STATE BBR_STATE F2B_LABEL F2B_STATE
        if [ "$CUR_PWD" = "no" ] && [ "$CUR_PUBKEY" = "yes" ]; then AUTH_LABEL="仅密钥"; AUTH_STATE="active"
        elif [ "$CUR_PWD" = "yes" ]; then AUTH_LABEL="允许密码"; AUTH_STATE="warning"
        else AUTH_LABEL="未确认"; AUTH_STATE="unknown"; fi
        [ "$CADDY_ST" = "running" ] && CADDY_STATE="active" || CADDY_STATE="$CADDY_ST"
        [ "$BBR_CC" = "bbr" ] && BBR_STATE="active" || BBR_STATE="unknown"
        case "$F2B_STAT" in
            running) F2B_LABEL="运行中"; F2B_STATE="active" ;;
            stopped) F2B_LABEL="已停止"; F2B_STATE="inactive" ;;
            *) F2B_LABEL="未安装"; F2B_STATE="unknown" ;;
        esac

        menu_group "系统概览"
        status_pair "用户" "$USER_TOTAL · 管理员 $ADMIN_TOTAL" "active" "SSH" "${CUR_PORT:-22} · $AUTH_LABEL" "$AUTH_STATE"
        status_pair "BBR" "$BBR_CC · $TC_RATE" "$BBR_STATE" "Fail2ban" "$F2B_LABEL" "$F2B_STATE"
        status_pair "防火墙" "$FW_STAT" "$FW_STATE" "Caddy" "$CADDY_LABEL" "$CADDY_STATE"
        status_pair "Docker" "$DOCKER_LABEL" "$DOCKER_STATE" "时间" "$SYS_TIME" "active"
        ui_hint "时区 $SYS_TZ"
        # 更新提示
        if [ -f "$QUENCH_UPDATE_HINT_FILE" ]; then
            local NEW_VER; NEW_VER=$(cat "$QUENCH_UPDATE_HINT_FILE" 2>/dev/null)
            [ -n "$NEW_VER" ] && echo -e "  ${YELLOW}${BOLD}! 新版本 ${NEW_VER} 可用${NC}  ${DIM}输入 m 后选择 2 更新${NC}"
        fi
        box_sep
        menu_group "初始化与诊断"
        menu_pair "w" "首次开荒向导" "h" "安全与诊断" "$GREEN" "$CYAN"
        echo ""
        menu_group "安全与网络"
        menu_pair "1" "用户管理" "2" "Fail2ban 管理"
        menu_pair "3" "网络性能调优" "4" "防火墙管理"
        menu_item "5" "DNS 管理"
        echo ""
        menu_group "系统与服务"
        menu_pair "6" "软件源管理" "7" "IP 状态与出口"
        menu_pair "8" "Caddy 网站入口" "n" "线路机端口转发"
        menu_pair "t" "时间与 NTP" "s" "Swap 管理"
        menu_pair "a" "常用软件管理" "d" "Docker 管理"
        menu_item "m" "脚本管理"
        echo ""
        menu_item "0" "退出脚本" "$RED"
        box_bot
        echo ""
        read -rp "$(ui_prompt '选择功能 [0-8 / w / h / n / t / s / a / d / m]: ')" CHOICE
        audit_action "主菜单选择 $CHOICE" INFO

        case "$CHOICE" in
            1) user_management_menu ;;
            2) fail2ban_menu ;;
            3) bbr_menu ;;
            4) firewall_menu ;;
            5) dns_menu ;;
            6) mirror_menu ;;
            7) ip_config_menu ;;
            8) caddy_menu ;;
            w|W) first_run_wizard ;;
            n|N) nft_menu ;;
            t|T) timesync_menu ;;
            s|S) swap_menu ;;
            h|H) system_toolbox_menu ;;
            a|A) software_menu ;;
            d|D) docker_menu ;;
            m|M) self_manage_menu ;;
            0) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
        continue
    done
}

# 测试模式只加载函数，不启动菜单或后台任务。
if [ "${QUENCH_TEST_MODE:-0}" = "1" ]; then
    # shellcheck disable=SC2317 # exit fallback is used when the script is executed instead of sourced
    return 0 2>/dev/null || exit 0
fi

# 安装兜底清理：Ctrl+C / kill 时删掉登记过的临时文件。
# 放在 CLI 分发之前，命令行入口同样受保护。
quench_install_signal_traps

# CLI 处理：菜单入口
case "${1:-}" in
    --help|-h|help)
        show_cli_help
        exit 0
        ;;
    --first-run)
        first_run_wizard
        exit $?
        ;;
    --user-menu)
        user_management_menu
        exit $?
        ;;
    --fail2ban-menu)
        fail2ban_menu
        exit $?
        ;;
    --bbr-menu)
        bbr_menu
        exit $?
        ;;
    --bbr-calibrate)
        bbr_menu_calibration
        exit $?
        ;;
    --bbr-reconcile-tc)
        bbr_tc_reconcile_saved
        exit $?
        ;;
    --firewall-menu)
        firewall_menu
        exit $?
        ;;
    --dns-menu)
        dns_menu
        exit $?
        ;;
    --nft-refresh-targets)
        nft_refresh_domain_targets
        exit $?
        ;;
    --mirror-menu)
        mirror_menu
        exit $?
        ;;
    --ip-menu)
        ip_config_menu
        exit $?
        ;;
    --caddy-menu)
        caddy_menu
        exit $?
        ;;
    --nft-menu)
        nft_menu
        exit $?
        ;;
    --time-menu)
        timesync_menu
        exit $?
        ;;
    --https-time-sync)
        ts_sync_https
        exit $?
        ;;
    --swap-menu)
        swap_menu
        exit $?
        ;;
    --system-toolbox-menu)
        system_toolbox_menu
        exit $?
        ;;
    --stun-test)
        stun_nat_quick
        exit $?
        ;;
    --hostname-menu)
        system_hostname_apply
        exit $?
        ;;
    --docker-menu)
        docker_menu
        exit $?
        ;;
    --software-menu)
        software_menu
        exit $?
        ;;
    --self-manage-menu)
        self_manage_menu
        exit $?
        ;;
    --config-backup-menu)
        config_backup_menu
        exit $?
        ;;
    --config-transfer-menu)
        config_transfer_menu
        exit $?
        ;;
    --rollback-center-menu)
        rollback_center_menu
        exit $?
        ;;
    --version|-v)
        printf 'Quench %s\n' "$APP_VERSION"
        exit 0
        ;;
    '')
        ;;
    *)
        # 没有兜底分支时，拼错的参数会静默掉进交互菜单：
        # 脚本化或 cron 调用会卡在 read 上，而不是报错退出。
        printf 'Quench: 未知参数 %s\n' "$1" >&2
        printf "用 '--help' 查看可用命令。\n" >&2
        exit 2
        ;;
esac

self_check_first_run
# 终端 resize 后让宽度缓存失效，否则布局会停在旧宽度上。
trap ui_invalidate_dimensions WINCH
# 后台检测新版本（不阻塞主菜单）
self_check_update &
main_menu
