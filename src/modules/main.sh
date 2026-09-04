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
