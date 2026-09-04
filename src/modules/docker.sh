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
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
    svc_enable docker || warn "Docker 开机自启设置失败：重启后需要手动启动"
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
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
    [ "$DRIVER" = local ] && info "默认日志驱动为 local" || { warn "默认日志驱动为 ${DRIVER:-未知}，建议应用生产基线"; FAILED=1; }
    LIVE=$(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || true)
    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
