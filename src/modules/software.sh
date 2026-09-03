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
