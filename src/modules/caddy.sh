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
        svc_enable caddy || warn "Caddy 开机自启设置失败：重启后需要手动启动"
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
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        curl --proto '=https' --tlsv1.2 -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$TMP/caddy.gpg.key" \
            && curl --proto '=https' --tlsv1.2 -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$TMP/caddy.list" \
            && gpg --dearmor --yes -o "$TMP/caddy.gpg" "$TMP/caddy.gpg.key" \
            && grep -Fq 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian' "$TMP/caddy.list" \
            || { rm -rf "$TMP"; return 1; }
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
            # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
        if atomic_restore_file "$BACKUP" "$FILE"; then
            [ "$WAS_ACTIVE" = false ] || caddy_reload_active >/dev/null 2>&1 || true
            rm -f "$BACKUP"
            error "站点删除失败，已恢复配置"
        else
            error "站点删除失败，且配置恢复也失败，备份已保留：$BACKUP"
        fi
        caddy_lock_release
        caddy_show_last_error; return 1
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
            # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
            [ -n "$DNS" ] && echo -e "    DNS：${DIM}$(tr '\n' ' ' <<< "$DNS")${NC}" || warn "${CADDY_SITE_HOST} 无 DNS 结果"
        fi
        if caddy_local_health "$ADDRESS"; then info "本机 Caddy 入口可响应"; else error "本机 Caddy 入口无响应"; fi
        if command -v curl >/dev/null 2>&1; then
            if [[ "$ADDRESS" == http://* || "$ADDRESS" == https://* ]]; then URL="$ADDRESS"; else URL="https://$ADDRESS"; fi
            CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10 "$URL" 2>/dev/null || true)
            # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
