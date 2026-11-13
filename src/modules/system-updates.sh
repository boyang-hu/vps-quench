# ══════════════════════════════════════════════════════════
#  系统与软件更新：发行版内更新与大版本迁移严格分离
# ══════════════════════════════════════════════════════════
QUENCH_UPDATE_APT_DIR="${QUENCH_UPDATE_APT_DIR:-/etc/apt}"
QUENCH_UPDATE_OS_FILE="${QUENCH_UPDATE_OS_FILE:-/etc/os-release}"
QUENCH_UPDATE_STATE_DIR="${QUENCH_UPDATE_STATE_DIR:-$QUENCH_DATA_DIR/updates}"

system_update_os_value() {
    local VALUE
    VALUE=$(awk -F= -v key="$1" '$1==key {sub(/^[^=]*=/, ""); print; exit}' "$QUENCH_UPDATE_OS_FILE") || return 1
    VALUE=${VALUE#\"}; VALUE=${VALUE%\"}; VALUE=${VALUE#\'}; VALUE=${VALUE%\'}
    printf '%s\n' "$VALUE"
}

system_update_debian_code() {
    [ "$(system_update_os_value ID)" = debian ] || return 1
    case "$(system_update_os_value VERSION_ID):$(system_update_os_value VERSION_CODENAME)" in
        12:bookworm) echo bookworm ;;
        13:trixie) echo trixie ;;
        *) error "此更新中心的 APT 安全检查目前支持 Debian 12/13"; return 1 ;;
    esac
}

system_update_python_ready() {
    command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import pathlib, re, shlex, sys' >/dev/null 2>&1
}

# Called under the update transaction lock, with QUENCH_UPDATE_RUN prepared.
# The source parser cannot validate user repositories until Python exists.
# Bootstrap using only signed, fixed-codename Debian sources and private lists;
# then run the full original-source checks before any requested system upgrade.
system_update_require_python() {
    system_update_python_ready && return 0
    local CODE BOOTSTRAP PLAN
    local APT_ARGS=()
    CODE=$(system_update_debian_code) || return 1
    [ -z "${APT_CONFIG:-}" ] || { error "检测到 APT_CONFIG 自定义配置，请先在标准环境下执行"; return 1; }
    system_update_terminal_ready || { error "缺少更新检查依赖 python3；请从交互终端进入更新流程以自动安装"; return 1; }
    info "检测到缺少可用的 python3，将在本流程中补齐软件源检查依赖"
    confirm_change_preview "补齐更新检查依赖" \
        "从当前 Debian ${CODE} 的官方签名仓库安装 python3 及必要依赖" \
        "不改写现有软件源、不执行整机升级；安装完成后继续刚才选择的操作" || return 2
    system_update_apt_health || return 1
    BOOTSTRAP="$QUENCH_UPDATE_RUN/python-bootstrap"
    mkdir -p "$BOOTSTRAP/lists/partial" || return 1
    # HTTP also works on minimal images without CA certificates; APT verifies
    # both repository metadata and package hashes with the Debian archive keyring.
    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian $CODE main" \
        "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian $CODE-updates main" \
        "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian-security $CODE-security main" \
        > "$BOOTSTRAP/sources.list" || return 1
    APT_ARGS=(-o "Dir::Etc::sourcelist=$BOOTSTRAP/sources.list" -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$BOOTSTRAP/lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=
        -o Dir::Etc::preferences=- -o Dir::Etc::preferencesparts=- -o APT::Default-Release=
        -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false
        -o Acquire::AllowWeakRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false
        -o APT::Update::Error-Mode=any -o DPkg::Lock::Timeout=60)
    if ! system_update_logged env LC_ALL=C apt-get "${APT_ARGS[@]}" update; then
        error "依赖仓库刷新失败；未启动所选系统更新，可重新进入当前步骤重试"
        return 1
    fi
    PLAN="$BOOTSTRAP/plan.txt"
    if ! LC_ALL=C apt-get "${APT_ARGS[@]}" -s --no-remove --no-install-recommends install python3 > "$PLAN" 2>&1; then
        cat "$PLAN"; error "python3 依赖计划生成失败；未启动所选系统更新"; return 1
    fi
    cat "$PLAN"
    if grep -Eq '^Remv |^Inst (openssh-server|sudo|systemd|systemd-sysv|apt|dpkg|libc6|linux-image[^ ]*|grub[^ ]*|initramfs-tools[^ ]*)( |:)' "$PLAN"; then
        error "依赖计划涉及删除或变更系统关键包，已停止自动安装；所选系统更新尚未启动"
        return 1
    fi
    # Use APT's own final confirmation. No implicit -y/forced conffile policy.
    if ! system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get "${APT_ARGS[@]}" \
        --no-remove --no-install-recommends install python3; then
        error "python3 安装未完成；未启动所选系统更新，可在当前步骤重试"
        return 1
    fi
    if ! system_update_python_ready; then
        error "安装后 python3 仍不可用；请检查 $QUENCH_UPDATE_RUN/commands.log"
        return 1
    fi
    info "更新检查依赖已就绪，继续检查现有软件源并执行所选操作"
}

# Conservative parser: reject unknown formats rather than silently miss a source.
# Python is used only by this advanced module, not by startup or the UI.
# major prints the single source file it can atomically replace; stage writes a
# candidate outside /etc. Only active source fields are changed, never comments,
# disabled stanzas or third-party sources. Live writes belong to the transaction.
system_update_sources() {
    local MODE="$1" CODE="$2" DEST="${3:-}"
    command -v python3 >/dev/null 2>&1 || { error "软件源检查依赖 python3 未就绪，请重新进入更新流程自动补齐"; return 1; }
    python3 - "$QUENCH_UPDATE_APT_DIR" "$MODE" "$CODE" "$DEST" <<'PY'
import pathlib, re, shlex, sys
root, mode, code, dest = pathlib.Path(sys.argv[1]), *sys.argv[2:]

def official_archive(uri):
    if re.fullmatch(r'https?://deb\.debian\.org/debian/?', uri):
        return 'debian'
    if re.fullmatch(r'https?://(security|deb)\.debian\.org/debian-security/?', uri):
        return 'debian-security'
    return None

def resolve_mirror(uri):
    if official_archive(uri):
        return uri
    match = re.fullmatch(r'mirror\+file:/{1,3}(etc/apt/mirrors/[A-Za-z0-9_.-]+)', uri)
    if not match:
        raise ValueError('无法自动迁移源地址 ' + uri + '；请核对其 Debian 13 支持，或改用 deb.debian.org 官方直接地址')
    # Map the standard /etc/apt prefix through root so fixtures never read /etc.
    path = root / match[1][len('etc/apt/'):]
    if path.name in ('.', '..') or path.parent.is_symlink() or path.is_symlink() or not path.is_file():
        raise ValueError('镜像列表必须是 /etc/apt/mirrors/ 下可读取的普通文件：' + str(path))
    archives = set()
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        # Metadata can restrict suite/architecture selection. Do not discard it
        # silently while converting a list to one direct URL.
        items = line.split()
        archive = official_archive(items[0])
        if not archive or len(items) != 1:
            raise ValueError('镜像列表含非官方地址或选择条件，需人工核对：' + str(path) + '：' + line)
        archives.add(archive)
    if len(archives) != 1:
        raise ValueError('镜像列表为空或混合了主仓库与安全仓库：' + str(path))
    return 'https://deb.debian.org/' + archives.pop()

def replace_field(block, name, value):
    lines, active, found = [], False, False
    for line in block.splitlines(keepends=True):
        if re.match(r'^' + re.escape(name) + r':', line, re.I):
            lines.append(name + ': ' + value + ('\n' if line.endswith('\n') else ''))
            active, found = True, True
        elif line.lstrip().startswith('#') or not line.strip():
            lines.append(line)
        elif line[:1].isspace() and active:
            continue
        else:
            active = False
            lines.append(line)
    if not found:
        return name + ': ' + value + '\n' + block
    return ''.join(lines)

try:
    if mode not in ('check', 'major', 'stage') or (mode == 'stage' and code != 'bookworm'):
        raise ValueError('不支持的源检查/迁移模式')
    paths = [root / 'sources.list'] + sorted((root / 'sources.list.d').glob('*.list')) + sorted((root / 'sources.list.d').glob('*.sources'))
    records, chunks = [], {}
    for path in paths:
        if not path.exists():
            continue
        if not path.is_file() or path.is_symlink():
            raise ValueError('源文件必须是普通文件：' + str(path))
        text = path.read_text()
        if path.suffix == '.sources':
            chunks[path] = re.split(r'(\n[ \t]*\n)', text)
            for index, paragraph in enumerate(chunks[path]):
                fields, key = {}, None
                for line in paragraph.splitlines():
                    if not line.strip() or line.lstrip().startswith('#'):
                        continue
                    if line[:1].isspace() and key:
                        fields[key] += ' ' + line.strip()
                    else:
                        match = re.match(r'^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$', line)
                        if not match or match[1].lower() in fields:
                            raise ValueError('无效或重复的 deb822 字段：' + str(path))
                        key = match[1].lower()
                        fields[key] = match[2]
                if not fields or fields.get('enabled', 'yes').lower() == 'no':
                    continue
                if fields.get('enabled', 'yes').lower() != 'yes':
                    raise ValueError('无法确认源是否启用：' + str(path))
                if not all(fields.get(k) for k in ('types', 'uris', 'suites')):
                    raise ValueError('软件源缺少必要字段：' + str(path))
                if set(fields['types'].split()) - {'deb', 'deb-src'}:
                    raise ValueError('未知源类型：' + str(path))
                for unsafe in ('trusted', 'allow-insecure', 'allow-weak', 'allow-downgrade-to-insecure'):
                    if fields.get(unsafe, 'no').lower() not in ('no', 'false', '0'):
                        raise ValueError('拒绝绕过仓库签名验证：' + str(path))
                records.append((path, index, fields['uris'].split(), fields['suites'].split(), fields.get('components', '').split(), 'deb' in fields['types'].split()))
        else:
            chunks[path] = text.splitlines(keepends=True)
            for index, line in enumerate(chunks[path]):
                tokens = shlex.split(line, comments=True)
                if not tokens:
                    continue
                source_type = tokens.pop(0)
                if source_type not in ('deb', 'deb-src'):
                    raise ValueError('未知 list 源类型：' + str(path))
                binary = source_type == 'deb'
                if tokens and tokens[0].startswith('['):
                    opts = []
                    while tokens:
                        token = tokens.pop(0); opts.append(token)
                        if token.endswith(']'):
                            break
                    if not opts[-1].endswith(']'):
                        raise ValueError('未闭合的源选项：' + str(path))
                    if re.search(r'(trusted|allow-insecure|allow-weak|allow-downgrade-to-insecure)=(yes|true|1)', ' '.join(opts), re.I):
                        raise ValueError('拒绝绕过仓库签名验证：' + str(path))
                if len(tokens) < 2:
                    raise ValueError('不完整的源条目：' + str(path))
                records.append((path, index, [tokens[0]], [tokens[1]], tokens[2:], binary))
    if not records:
        raise ValueError('没有启用的软件源')
    base = security = False
    for path, index, uris, suites, components, binary in records:
        try:
            resolved = [resolve_mirror(uri) for uri in uris] if mode in ('major', 'stage') else uris
        except ValueError as exc:
            raise ValueError(str(exc) + '（源文件：' + str(path) + '）') from exc
        for suite in suites:
            if re.match(r'^(stable|oldstable|oldoldstable|testing|unstable|sid)(-|$)', suite):
                raise ValueError('拒绝浮动发行版 ' + suite + '；请使用明确代号：' + str(path))
            if re.match(r'^(bullseye|bookworm|trixie|forky)(-|$)', suite) and suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                raise ValueError('检测到混合或不支持的发行版 ' + suite + '：' + str(path))
            if any(re.search(r'/debian(-security)?/?$', uri) for uri in uris) and suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                raise ValueError('Debian 仓库代号不属于当前发行版：' + str(path))
            if mode in ('major', 'stage'):
                allowed = (code, code+'-updates', code+'-security') + ((code+'-backports',) if code == 'bookworm' else ())
                if suite not in allowed:
                    raise ValueError('无法自动迁移 Suites: ' + suite + '：' + str(path))
                if 'main' not in components:
                    raise ValueError('官方源 Components 缺少 main：' + str(path))
                expected = 'debian-security' if suite == code+'-security' else 'debian'
                if any(official_archive(uri) != expected for uri in resolved):
                    raise ValueError('源地址与 Suites 不匹配：' + suite + '：' + str(path))
            elif suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                # Vendor suites such as Caddy any-version are allowed, never rewritten.
                print('提示：保留第三方源 ' + str(path) + ' (' + suite + ')', file=sys.stderr)
            if binary and 'main' in components and suite == code:
                base = True
            if binary and 'main' in components and suite == code+'-security':
                security = True
        if mode == 'major' and code == 'bookworm':
            for old, new in zip(uris, resolved):
                if old != new:
                    print('升级计划：镜像列表 ' + old + ' → ' + new, file=sys.stderr)
            if 'bookworm-backports' in suites:
                print('升级计划：停用 bookworm-backports，不启用 trixie-backports（已安装包另行检查）', file=sys.stderr)
        if mode == 'stage':
            block = chunks[path][index]
            target_suites = [s.replace('bookworm', 'trixie', 1) for s in suites if s != 'bookworm-backports']
            if path.suffix == '.sources':
                if target_suites:
                    block = replace_field(block, 'Suites', ' '.join(target_suites))
                    if resolved != uris:
                        block = replace_field(block, 'URIs', ' '.join(resolved))
                else:
                    block = replace_field(block, 'Enabled', 'no')
            elif not target_suites:
                block = '# quench: disabled bookworm-backports for release upgrade\n# ' + block
            else:
                line = re.fullmatch(r'(\s*deb(?:-src)?\s+(?:\[[^\]]*\]\s+)?)(\S+)(\s+)(\S+)([^\n]*)(\n?)', block)
                if not line or line[2] != uris[0] or line[4] != suites[0]:
                    raise ValueError('无法无损修改 list 源条目：' + str(path))
                block = line[1] + resolved[0] + line[3] + target_suites[0] + line[5] + line[6]
            chunks[path][index] = block
    if not base or not security:
        raise ValueError('缺少当前发行版的 main 或 security 源')
    if mode in ('major', 'stage'):
        active = set(r[0] for r in records)
        if len(active) != 1:
            raise ValueError('大版本向导要求启用的 Debian 源集中在一个文件，避免非原子地切换多个文件；请先合并：' + ', '.join(str(p) for p in sorted(active)))
        path = active.pop()
        if mode == 'major':
            print(path)
        else:
            pathlib.Path(dest).write_text(''.join(chunks[path]))
except (OSError, ValueError) as exc:
    print('软件源预检失败：' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

system_update_apt_layout_guard() {
    local CFG
    [ -z "${APT_CONFIG:-}" ] || { error "检测到 APT_CONFIG 自定义配置，请先在标准环境下执行"; return 1; }
    CFG=$(apt-config dump) || return 1
    # Alternate source locations would bypass the source parser.
    printf '%s\n' "$CFG" | python3 -c '
import re, sys
d = dict(re.findall(r"^([\w:.-]+)\s+\"([^\"]*)\";", sys.stdin.read(), re.M))
expected = {"Dir":"/", "Dir::Etc":"etc/apt", "Dir::Etc::sourcelist":"sources.list", "Dir::Etc::sourceparts":"sources.list.d", "Dir::Etc::parts":"apt.conf.d", "Dir::Etc::main":"apt.conf"}
safe = all(d.get(k, v).rstrip("/") == v.rstrip("/") for k,v in expected.items())
for key in ("APT::Get::AllowUnauthenticated", "Acquire::AllowInsecureRepositories", "Acquire::AllowDowngradeToInsecureRepositories"):
    safe = safe and d.get(key, "false").lower() in ("false", "no", "0")
sys.exit(0 if safe else 1)
' || { error "检测到自定义 APT 源路径或禁用签名验证的设置，已停止"; return 1; }
}

system_update_apt_health() {
    local AUDIT
    AUDIT=$(LC_ALL=C dpkg --audit 2>&1) || { error "$AUDIT"; return 1; }
    [ -z "$AUDIT" ] || { error "dpkg 有未完成事务，请先人工修复：$AUDIT"; return 1; }
    LC_ALL=C apt-get -o DPkg::Lock::Timeout=60 check
}

system_update_apt_origins_guard() {
    local CODE="$1" POLICY
    POLICY=$(LC_ALL=C apt-cache policy) || return 1
    printf '%s\n' "$POLICY" | python3 -c '
import sys
code = sys.argv[1]
for line in sys.stdin:
    if not line.strip().startswith("release "):
        continue
    fields = dict(x.strip().split("=",1) for x in line.strip()[8:].split(",") if "=" in x)
    if fields.get("o") in ("Debian", "Debian-Security") and fields.get("n") not in (code,code+"-updates",code+"-security",code+"-backports"):
        print("仓库 Release 元数据不属于当前发行版：" + line.strip(), file=sys.stderr)
        sys.exit(1)
' "$CODE"
}

system_update_terminal_ready() {
    [ -t 0 ] && [ -t 1 ]
}

system_update_needs_tmux() {
    # Update-center actions get session protection even when sudo/su strips
    # SSH_*. Onboarding uses an explicit foreground context instead.
    [ -z "${TMUX:-}${STY:-}" ]
}

system_update_session_ready() {
    system_update_terminal_ready || { error "更新需要交互终端，不能从 cron 或无输入管道执行"; return 1; }
    if system_update_needs_tmux; then
        error "更新中心需要 tmux 或 screen 会话；请从更新中心入口自动准备会话"
        return 1
    fi
}

# tmux handoff stays outside the update transaction: the child must acquire its
# own lock, and detaching the client must never fall through to a second update.
system_update_tmux_available() {
    command -v tmux >/dev/null 2>&1
}

system_update_tmux_install() (
    local PM RC=0
    PM=$(system_package_manager)
    case "$PM" in
        apt|dnf|yum|apk) : ;;
        *) error "当前包管理器不支持引导安装 tmux，请先从常用软件管理安装"; return 1 ;;
    esac
    txn_write_begin "安装升级会话依赖 tmux" || return 1
    trap 'txn_write_end' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # Only bootstrap tmux and its dependencies, never a whole-system upgrade.
    case "$PM" in
        apt)
            system_update_apt_health || return 1
            apt-get -o APT::Update::Error-Mode=any update || return 1
            apt-get -o DPkg::Lock::Timeout=60 --no-remove install -y tmux || RC=$?
            ;;
        dnf|yum) "$PM" install -y tmux || RC=$? ;;
        apk) apk add --no-cache tmux || RC=$? ;;
    esac
    if [ "$RC" -ne 0 ] || ! system_update_tmux_available; then
        audit_action "安装升级会话依赖 tmux" FAILED
        error "tmux 安装未完成；本次系统升级未启动，请检查包管理器输出"
        return 1
    fi
    audit_action "安装升级会话依赖 tmux" SUCCESS
)

system_update_tmux_hint() {
    info "断线或分离后，用同一 root 身份执行：tmux -L quench attach -t quench-update"
    ui_hint "临时离开：先按 Ctrl+B，再按 D；不要输入 exit 或杀掉会话。服务器重启后会话不会保留。"
}

# A consumed pipe cannot be copied. With explicit handoff consent, fetch the
# commit-pinned, SHA256-checked script through the existing downloader. Keep the
# private file after client detach: the live tmux child still needs its script.
system_update_tmux_stage_script() (
    umask 077
    local STAGE
    mkdir -p "$QUENCH_UPDATE_STATE_DIR" || return 1
    chmod 700 "$QUENCH_UPDATE_STATE_DIR" || return 1
    STAGE=$(mktemp -d "$QUENCH_UPDATE_STATE_DIR/quench-session.XXXXXX") || return 1
    if ! self_fetch_script "$STAGE/vps-quench.sh" >&2; then
        rm -f "$STAGE/vps-quench.sh"
        rmdir "$STAGE" 2>/dev/null || true
        error "续接脚本下载或校验失败；未开始系统更新，可留在此入口重试" >&2
        return 1
    fi
    printf '%s\n' "$STAGE/vps-quench.sh"
)

system_update_tmux_launch() {
    local MODE="$1" SCRIPT NEED_INSTALL=no SOURCE_NOTE="" VERSION
    if [ "${QUENCH_TXN_LOCK_HELD:-0}" = 1 ] || [ "${QUENCH_TXN_WRITE_DEPTH:-0}" -gt 0 ] || safety_timer_pending; then
        error "请先完成当前配置事务/防断联确认，再进入升级会话"
        return 1
    fi
    if system_update_tmux_available && tmux -L quench has-session -t '=quench-update' 2>/dev/null; then
        confirm_change_preview "重新连接已有升级会话" \
            "只连接 quench-update，不重新执行刚才选择的操作，不中断其他客户端" || return 0
        system_update_tmux_hint
        tmux -L quench attach-session -t '=quench-update'
        return $?
    fi
    SCRIPT=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -z "$SCRIPT" ]; then
        SOURCE_NOTE="当前为在线启动：将下载并校验仓库脚本，保存为私有会话副本后继续，不改动已安装的 Quench"
    else
        SOURCE_NOTE="使用当前本地脚本进入会话，不重复下载"
    fi
    system_update_tmux_available || NEED_INSTALL=yes
    if [ "$NEED_INSTALL" = yes ]; then
        info "未检测到 tmux，将在这里安装并继续"
        confirm_change_preview "安装 tmux 并进入升级会话" \
            "安装 tmux 及其必要依赖（可能联网、运行软件包安装钩子）；不执行整机升级" \
            "$SOURCE_NOTE" \
            "进入独立 quench-update 会话后继续所选操作，仍保留全部预检和升级确认" || return 0
    else
        confirm_change_preview "进入 tmux 升级会话" \
            "$SOURCE_NOTE" \
            "进入独立 quench-update 会话后继续所选操作，仍保留全部预检和升级确认" || return 0
    fi
    if [ -z "$SCRIPT" ]; then
        info "正在准备续接脚本，无需退出当前向导安装 Quench"
        SCRIPT=$(system_update_tmux_stage_script) || return 1
        VERSION=$(awk -F'"' '/^APP_VERSION="/ {print $2; exit}' "$SCRIPT")
        if [ "$VERSION" != "$APP_VERSION" ]; then
            confirm_change_preview "续接脚本版本发生变化" \
                "当前运行 ${APP_VERSION}，校验后的会话副本为 ${VERSION}；确认后使用该版本继续所选操作" || return 0
        fi
    fi
    if [ "$NEED_INSTALL" = yes ]; then system_update_tmux_install || return 1; fi
    system_update_tmux_hint
    # Dedicated server ignores user tmux hooks/options. Multiple command args
    # are exec'd directly, not interpolated into a shell command string. -A
    # attaches instead of executing again if another launcher wins the race.
    if ! tmux -L quench -f /dev/null new-session -A -s quench-update \
        bash "$SCRIPT" --system-update-resume "$MODE"; then
        error "tmux 创建或连接失败；不会在当前 SSH 会话继续升级"
        system_update_tmux_hint
        return 1
    fi
    info "已离开升级会话；这不代表升级已完成。如任务仍在运行，请重新连接查看。"
}

system_update_dispatch() {
    local MODE="$1"
    case "$MODE" in current|security|packages|autoremove|full|major) : ;;
        *) error "无效的更新操作：$MODE"; return 2 ;;
    esac
    system_update_terminal_ready || { error "更新需要交互终端，不能从 cron 或无输入管道执行"; return 1; }
    if system_update_needs_tmux; then
        system_update_tmux_launch "$MODE"
        return $?
    fi
    case "$MODE" in
        major) system_update_debian_major ;;
        *) system_update_action "$MODE" ;;
    esac
}

system_update_resume() {
    local MODE="${1:-}" RC=0
    case "$MODE" in current|security|packages|autoremove|full|major) : ;;
        *) error "无效的会话续接操作：$MODE"; return 2 ;;
    esac
    [ -n "${TMUX:-}" ] || { error "此内部入口只能在 tmux 会话中使用"; return 1; }
    system_update_terminal_ready || { error "会话续接需要交互终端"; return 1; }
    system_update_dispatch "$MODE" || RC=$?
    [ "$RC" -eq 0 ] || warn "所选更新未完成，请检查上方输出；不会自动重试"
    # Keep results visible and the session available after the selected action.
    ui_pause
    system_update_manager
}

system_update_apt_preflight() {
    local CODE
    CODE=$(system_update_debian_code) || return 1
    system_update_sources check "$CODE" || return 1
    system_update_apt_layout_guard || return 1
    system_update_apt_health
}

# Capture command output and preserve both the package manager and log write status.
# No set -e assumption; callers must not report a failed command as SUCCESS.
system_update_logged() {
    local -a QUENCH_COMMAND_STATUS
    "$@" 2>&1 | tee -a "$QUENCH_UPDATE_RUN/commands.log"
    QUENCH_COMMAND_STATUS=("${PIPESTATUS[@]}")
    [ "${QUENCH_COMMAND_STATUS[0]}" -eq 0 ] && [ "${QUENCH_COMMAND_STATUS[1]}" -eq 0 ]
}

system_update_run_prepare() {
    mkdir -p "$QUENCH_UPDATE_STATE_DIR" || return 1
    chmod 700 "$QUENCH_UPDATE_STATE_DIR" || return 1
    QUENCH_UPDATE_RUN=$(mktemp -d "$QUENCH_UPDATE_STATE_DIR/run-$(date +%Y%m%d_%H%M%S).XXXXXX") || return 1
    chmod 700 "$QUENCH_UPDATE_RUN" || return 1
    info "本次记录：$QUENCH_UPDATE_RUN"
}

system_update_reboot_required() {
    [ -f /var/run/reboot-required ]
}

# Stable unit names, not localized descriptions or the optional failure bullet.
# A failed query/parser must never look like an empty (healthy) snapshot.
system_update_failed_units() {
    local OUTPUT UNITS
    OUTPUT=$(LC_ALL=C SYSTEMD_COLORS=0 systemctl --failed --plain --no-legend --no-pager 2>&1) \
        || { error "无法读取 systemd 失败单元：$OUTPUT" >&2; return 1; }
    UNITS=$(printf '%s\n' "$OUTPUT" | awk 'NF {if (NF < 4 || $3 != "failed") exit 1; print $1}') \
        || { error "无法解析 systemd 失败单元：$OUTPUT" >&2; return 1; }
    [ -n "$UNITS" ] || return 0
    printf '%s\n' "$UNITS" | LC_ALL=C sort -u
}

system_update_postcheck() {
    # Only a caller-supplied snapshot from this transaction allows comparison.
    # Standalone health checks and major upgrades remain strict.
    local BASELINE="${1:-}" RC=0 FAILED NEW EXISTING AFTER
    if [ "$(system_package_manager)" = apt ]; then
        system_update_apt_health || RC=1
    fi
    if command -v sshd >/dev/null 2>&1; then
        sshd -t || { warn "sshd 配置验证失败；保持当前连接，先修复再重启"; RC=1; }
    fi
    if systemd_available; then
        FAILED=$(system_update_failed_units) || return 1
        if [ -n "$BASELINE" ]; then
            [ -f "$BASELINE" ] && [ -r "$BASELINE" ] || { error "更新前服务状态记录不可读，无法确认后检查结果"; return 1; }
            AFTER="${BASELINE%/*}/services-after.txt"
            : > "$AFTER" || return 1
            if [ -n "$FAILED" ]; then printf '%s\n' "$FAILED" > "$AFTER" || return 1; fi
            NEW=$(LC_ALL=C comm -13 "$BASELINE" "$AFTER") || return 1
            EXISTING=$(LC_ALL=C comm -12 "$BASELINE" "$AFTER") || return 1
            printf '%s' "$NEW" > "${BASELINE%/*}/services-new.txt" || return 1
            if [ -n "$EXISTING" ]; then
                warn "以下单元在更新前已失败，当前仍未恢复；需单独排查，不据此判定本次软件包更新失败："
                printf '%s\n' "$EXISTING"
            fi
            if [ -n "$NEW" ]; then
                warn "更新期间新增失败单元，后检查未通过，请核对服务日志："
                printf '%s\n' "$NEW"
                RC=1
            fi
        elif [ -n "$FAILED" ]; then
            warn "当前存在失败单元；没有本次更新前的状态记录，不能判断何时发生："
            printf '%s\n' "$FAILED"
            RC=1
        fi
    elif [ -n "$BASELINE" ]; then
        error "更新前使用 systemd，但更新后不可用，无法完成服务状态检查"
        RC=1
    fi
    if system_update_reboot_required; then
        warn "系统提示需要重启；请安排维护窗口，Quench 不会自动重启"
    else
        info "未发现 reboot-required 标记；这不保证无需重启，内核更新后请人工确认"
    fi
    printf '当前运行内核：%s\n' "$(uname -r)"
    return "$RC"
}

system_update_backup() {
    # Recovery evidence, NOT an OS rollback image. Never restore dpkg status over
    # already upgraded files. Full recovery requires the provider disk snapshot.
    cp -a "$QUENCH_UPDATE_APT_DIR" "$QUENCH_UPDATE_RUN/apt-before" || return 1
    dpkg --get-selections > "$QUENCH_UPDATE_RUN/packages-before.txt" || return 1
    cp -p /var/lib/dpkg/status "$QUENCH_UPDATE_RUN/dpkg-status-before" || return 1
    [ ! -f /var/lib/apt/extended_states ] || cp -p /var/lib/apt/extended_states "$QUENCH_UPDATE_RUN/extended-states-before" || return 1
    chmod -R go-rwx "$QUENCH_UPDATE_RUN"
}

system_update_package_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]] && [[ "$1" != *- ]]
}

# A private, consolidated APT config keeps local proxies/hooks/blacklists but
# replaces allowed origins, forbids automatic reboot and automatic removals.
# Dir::Etc::parts/main prevent later defaults from re-appending broader origins.
system_update_security_config() {
    local DEST="$1" CODE="$2"
    apt-config dump > "$DEST" || return 1
    cat >> "$DEST" <<EOF
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern { "origin=Debian,codename=${CODE}-security,label=Debian-Security"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Dir::Etc::parts "-";
Dir::Etc::main "-";
EOF
    chmod 600 "$DEST"
}

system_update_auto_policy_verify() {
    local CFG
    if [ -n "${1:-}" ]; then CFG=$(cat "$1") || return 1
    else CFG=$(apt-config dump) || { error "无法读取有效 APT 配置"; return 1; }; fi
    # shellcheck disable=SC2016 # ${distro_codename} is an unattended-upgrades macro, not a shell variable.
    printf '%s\n' "$CFG" | python3 -c '
import re,sys
text = sys.stdin.read()
def values(key):
    return re.findall(r"^"+re.escape(key)+r"(?:::)?\s+\"([^\"]*)\";", text, re.M | re.I)
expected = "origin=Debian,codename=${distro_codename}-security,label=Debian-Security"
patterns = [v for v in values("Unattended-Upgrade::Origins-Pattern") if v]
allowed = [v for v in values("Unattended-Upgrade::Allowed-Origins") if v]
problems = []
def check(key, valid, default=None):
    actual = values(key)
    effective = actual if actual else ([default] if default is not None else [])
    if len(effective) != 1 or effective[0].lower() not in valid:
        problems.append(key + " = " + repr(actual) + "; 需要 " + "/".join(valid))
if patterns != [expected]:
    problems.append("Unattended-Upgrade::Origins-Pattern = " + repr(patterns) + "; 需要仅 Debian security 来源")
if allowed:
    problems.append("Unattended-Upgrade::Allowed-Origins 仍有额外来源：" + repr(allowed))
check("APT::Periodic::Enable", ("1",), "1")
check("APT::Periodic::Update-Package-Lists", ("1",))
check("APT::Periodic::Unattended-Upgrade", ("1",))
for key in ("Automatic-Reboot", "Remove-Unused-Dependencies", "Remove-New-Unused-Dependencies", "Remove-Unused-Kernel-Packages"):
    check("Unattended-Upgrade::" + key, ("false", "no", "0"))
for problem in problems:
    print("APT 策略不符合：" + problem, file=sys.stderr)
sys.exit(1 if problems else 0)
' || { error "自动安全更新策略未通过验证；请核对以上具体键值及 /etc/apt/apt.conf.d、/etc/apt/apt.conf"; return 1; }
}

# Discover by content, not vendor filename. Only whole, regular files containing
# flat disabling switches (and optional no-reboot/root-zero entries) can be taken over.
# Unknown syntax, includes and mixed administrator settings stay untouched;
# real APT candidate validation remains authoritative about effective policy.
system_update_auto_templates_scan() {
    python3 - "$QUENCH_UPDATE_APT_DIR" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
periodic = re.compile(r'APT::Periodic::(Enable|Update-Package-Lists|Download-Upgradeable-Packages|Unattended-Upgrade|AutocleanInterval)\s+"0"\s*;\s*(?://.*)?', re.I)
no_reboot = re.compile(r'Unattended-Upgrade::Automatic-Reboot\s+"(?:false|no|0)"\s*;\s*(?://.*)?', re.I)
# Some image templates append this scalar. It is not the periodic switch and
# does not disable its child options. Permit it only alongside real disabling
# settings; a standalone root value never makes a file eligible for removal.
root_zero = re.compile(r'Unattended-Upgrade\s+"0"\s*;\s*(?://.*)?', re.I)
required = {'enable', 'update-package-lists', 'unattended-upgrade'}
try:
    parts = root / 'apt.conf.d'
    if root.is_symlink() or parts.is_symlink() or not parts.is_dir():
        raise ValueError('APT 配置目录必须是普通目录：' + str(parts))
    paths = [p for p in sorted(parts.iterdir())
             if re.fullmatch(r'[A-Za-z0-9_.-]+', p.name) and not p.name.startswith('.')
             and p.suffix in ('', '.conf')
             and p.name not in ('20auto-upgrades', '52quench-unattended-upgrades')]
    if (root / 'apt.conf').exists() or (root / 'apt.conf').is_symlink():
        paths.append(root / 'apt.conf')
    selected, blocked = [], []
    for p in paths:
        if p.is_symlink() or not p.is_file():
            print(str(p) + '：不是普通文件，保留并交由最终 APT 策略校验', file=sys.stderr)
            continue
        disables_required, other = False, []
        for number, line in enumerate(p.read_text().splitlines(), 1):
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            match = periodic.fullmatch(line)
            if match:
                disables_required |= match[1].lower() in required
            elif not (no_reboot.fullmatch(line) or root_zero.fullmatch(line)):
                other.append(number)
        # Download/cleanup disabled alone, or no-reboot alone, is not a
        # conflicting template. Never discard it just because it looks familiar.
        if not disables_required:
            continue
        if other:
            blocked.append(str(p) + '：含禁用开关及其他配置（行 ' + ', '.join(map(str, other)) + '），需人工核对，不自动移除')
        else:
            selected.append(str(p.relative_to(root)))
    if blocked:
        raise ValueError('\n'.join(blocked))
    for rel in selected:
        print(rel)
except (OSError, ValueError, UnicodeError) as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

# Recheck both the approved set and each backed-up file. New/changed templates
# during confirmation or dependency installation require a fresh preview.
system_update_auto_templates_recheck() {
    local REL FILE
    system_update_auto_templates_scan > "$QUENCH_UPDATE_RUN/templates-recheck" || return 1
    cmp -s "$QUENCH_UPDATE_RUN/templates.list" "$QUENCH_UPDATE_RUN/templates-recheck" \
        || { error "禁用配置清单发生变化，请重新预览并确认"; return 1; }
    while IFS= read -r REL; do
        FILE="$QUENCH_UPDATE_APT_DIR/$REL"
        if [ -L "$FILE" ] || [ ! -f "$FILE" ] || ! cmp -s "$FILE" "$QUENCH_UPDATE_RUN/templates-before/$REL"; then
            error "禁用配置发生变化，不接管：$FILE"; return 1
        fi
    done < "$QUENCH_UPDATE_RUN/templates.list"
}

system_update_auto_config_write() {
    printf '%s\n' 'APT::Periodic::Enable "1";' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' > "$1" || return 1
    cat > "$2" <<'EOF'
// Managed by Quench. Only security updates; no automatic reboot or removal.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern { "origin=Debian,codename=${distro_codename}-security,label=Debian-Security"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
EOF
}

system_update_auto_candidate_check() {
    local DIR="$1" TEMPLATES="$2" REL NAME
    mkdir -p "$DIR/parts" || return 1
    cp -a "$QUENCH_UPDATE_APT_DIR/apt.conf.d/." "$DIR/parts/" || return 1
    if [ -f "$QUENCH_UPDATE_APT_DIR/apt.conf" ]; then
        cp -p "$QUENCH_UPDATE_APT_DIR/apt.conf" "$DIR/main" || return 1
    else : > "$DIR/main" || return 1; fi
    # Never follow target symlinks in the staged copy.
    rm -f "$DIR/parts/20auto-upgrades" "$DIR/parts/52quench-unattended-upgrades" || return 1
    while IFS= read -r REL; do
        case "$REL" in
            apt.conf) : > "$DIR/main" || return 1 ;;
            apt.conf.d/*)
                NAME=${REL#apt.conf.d/}
                [[ "$NAME" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$ ]] || return 1
                rm -f "$DIR/parts/$NAME" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$TEMPLATES" || return 1
    system_update_auto_config_write "$DIR/parts/20auto-upgrades" "$DIR/parts/52quench-unattended-upgrades" || return 1
    # APT_CONFIG is read before config fragments, unlike late command-line -o.
    printf 'Dir::Etc::parts "%s/parts";\nDir::Etc::main "%s/main";\n' "$DIR" "$DIR" > "$DIR/bootstrap" || return 1
    APT_CONFIG="$DIR/bootstrap" apt-config dump > "$DIR/effective" || return 1
    system_update_auto_policy_verify "$DIR/effective"
}

system_update_auto_units_ready() {
    local UNIT STATE
    for UNIT in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        STATE=$(systemctl show "$UNIT" -p LoadState --value) || return 1
        [ "$STATE" = loaded ] || { error "$UNIT 的 LoadState=${STATE}，自动更新不可用"; return 1; }
    done
    for UNIT in apt-daily.timer apt-daily-upgrade.timer; do
        if ! systemctl is-enabled --quiet "$UNIT" || ! systemctl is-active --quiet "$UNIT"; then
            error "$UNIT 未启用或未运行"; return 1
        fi
    done
}

system_update_auto_install_dependency() {
    local STATUS
    STATUS=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null) || STATUS=""
    [ "$STATUS" != 'install ok installed' ] || return 0
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_logged env LC_ALL=C apt-get -o DPkg::Lock::Timeout=60 --no-remove install -y unattended-upgrades
}

system_update_auto_units_snapshot() {
    local UNIT STATE ACTIVE LOAD
    for UNIT in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        LOAD=$(systemctl show "$UNIT" -p LoadState --value) || {
            [ "$UNIT:$LOAD" = unattended-upgrades.service:not-found ] || return 1;
        }
        if [ "$UNIT:$LOAD" = unattended-upgrades.service:not-found ]; then
            printf '%s\tnot-found\tinactive\n' "$UNIT"
            continue
        fi
        case "$LOAD" in loaded|masked) : ;; *) error "$UNIT 的 LoadState=${LOAD}，请先修复服务" >&2; return 1 ;; esac
        STATE=$(systemctl show "$UNIT" -p UnitFileState --value) || return 1
        ACTIVE=$(systemctl show "$UNIT" -p ActiveState --value) || return 1
        case "$STATE" in masked|masked-runtime|disabled|enabled|enabled-runtime|static|not-found) : ;; *) error "无法自动恢复 $UNIT 的状态 $STATE" >&2; return 1 ;; esac
        case "$ACTIVE" in active|inactive|failed) : ;; *) error "$UNIT 正在切换状态，请稍后再试" >&2; return 1 ;; esac
        case "$UNIT:$ACTIVE" in apt-daily.service:active|apt-daily-upgrade.service:active) error "$UNIT 正在执行软件包任务，请等待完成" >&2; return 1 ;; esac
        printf '%s\t%s\t%s\n' "$UNIT" "$STATE" "$ACTIVE"
    done
}

system_update_auto_workers_idle() {
    local UNIT ACTIVE
    for UNIT in apt-daily.service apt-daily-upgrade.service; do
        ACTIVE=$(systemctl show "$UNIT" -p ActiveState --value) || return 1
        case "$ACTIVE" in inactive|failed) : ;; *) return 1 ;; esac
    done
    # Also cover manually started APT/dpkg processes outside systemd services.
    # Probe existing POSIX locks without creating/deleting any lock files.
    python3 - <<'PY'
import fcntl, os, sys
handles = []
try:
    for path in ('/var/lib/dpkg/lock', '/var/lib/dpkg/lock-frontend', '/var/cache/apt/archives/lock'):
        try:
            fd = os.open(path, os.O_RDWR)
        except FileNotFoundError:
            continue
        handles.append(fd)
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
finally:
    for fd in handles:
        os.close(fd)
PY
}

# EXIT recovery uses the local QUENCH_AUTO_* transaction state of the caller.
# Packages installed by APT are deliberately not uninstalled on failure.
system_update_auto_enable_cleanup() {
    local RC="$1" UNIT STATE ACTIVE I FILE REL FAILED=0
    if [ "$RC" -eq 0 ] || [ "$QUENCH_AUTO_MUTATED" != yes ]; then return "$RC"; fi
    warn "启用未完成，尝试恢复配置和原服务状态；已安装的软件包不会卸载"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer || FAILED=1
    # A timer may already have fired. Never kill an APT/dpkg job to roll back.
    if [ "$FAILED" -ne 0 ] || ! system_update_auto_workers_idle; then
        error "timer 无法暂停、APT 任务仍在运行或状态不可确认：不终止任务、不回写配置。请等待完成后核对备份"
        FAILED=1
    else
        for I in 0 1; do
            [ "${QUENCH_AUTO_TOUCHED[$I]}" = yes ] || continue
            FILE=${QUENCH_AUTO_TARGETS[$I]}
            if [ ! -L "$FILE" ] && cmp -s "$FILE" "${QUENCH_AUTO_CANDIDATES[$I]}"; then
                if [ -f "$QUENCH_UPDATE_RUN/before-$I" ]; then
                    atomic_restore_file "$QUENCH_UPDATE_RUN/before-$I" "$FILE" || FAILED=1
                else rm -f "$FILE" || FAILED=1; fi
            elif [ ! -L "$FILE" ] && cmp -s "$FILE" "$QUENCH_UPDATE_RUN/before-$I"; then
                : # Replacement failed before changing the file.
            elif [ ! -e "$FILE" ] && [ ! -L "$FILE" ] && [ ! -e "$QUENCH_UPDATE_RUN/before-$I" ]; then
                :
            else
                error "不覆盖外部改动：$FILE"; FAILED=1
            fi
        done
        if [ -f "$QUENCH_UPDATE_RUN/templates-touched" ]; then
            while IFS= read -r REL; do
                FILE="$QUENCH_UPDATE_APT_DIR/$REL"
                if [ ! -e "$FILE" ] && [ ! -L "$FILE" ]; then
                    atomic_restore_file "$QUENCH_UPDATE_RUN/templates-before/$REL" "$FILE" || FAILED=1
                elif [ ! -L "$FILE" ] && cmp -s "$FILE" "$QUENCH_UPDATE_RUN/templates-before/$REL"; then :
                else error "禁用配置被外部修改，不覆盖：$FILE"; FAILED=1; fi
            done < "$QUENCH_UPDATE_RUN/templates-touched" || FAILED=1
        fi
        while IFS=$'\t' read -r UNIT STATE ACTIVE; do
            case "$UNIT" in
                unattended-upgrades.service)
                    [ "$QUENCH_AUTO_UNITS_TOUCHED" = yes ] || continue
                    [ "$ACTIVE" = active ] || systemctl stop "$UNIT" || FAILED=1 ;;
                *.service) [ "$QUENCH_AUTO_UNITS_TOUCHED" = yes ] || continue ;;
            esac
            case "$STATE" in
                masked) systemctl mask "$UNIT" || FAILED=1 ;;
                masked-runtime) systemctl mask --runtime "$UNIT" || FAILED=1 ;;
                disabled|not-found) systemctl disable "$UNIT" || FAILED=1 ;;
                enabled-runtime)
                    systemctl disable "$UNIT" || FAILED=1
                    systemctl enable --runtime "$UNIT" || FAILED=1 ;;
                enabled) systemctl enable "$UNIT" || FAILED=1 ;;
            esac
        done < "$QUENCH_UPDATE_RUN/units-before"
        # A failed package installation may have left dpkg half-configured.
        # Do not resume automatic scheduling into that state.
        system_update_apt_health >/dev/null 2>&1 || FAILED=1
        if [ "$FAILED" -eq 0 ]; then
            while IFS=$'\t' read -r UNIT STATE ACTIVE; do
                [ "$ACTIVE" != active ] || systemctl start "$UNIT" || FAILED=1
            done < "$QUENCH_UPDATE_RUN/units-before"
        fi
    fi
    if [ "$FAILED" -eq 0 ]; then warn "已恢复本次配置/服务变更（软件包安装不回退）"
    elif systemctl stop apt-daily.timer apt-daily-upgrade.timer; then
        error "恢复未完全完成；已暂停后续 timer，请检查 $QUENCH_UPDATE_RUN"
    else error "恢复未完全完成且 timer 无法暂停，请立即人工核对 $QUENCH_UPDATE_RUN"; fi
    printf 'operation=auto-security-enable\nexit_code=%s\nrecovery_failed=%s\n' "$RC" "$FAILED" > "$QUENCH_UPDATE_RUN/result.txt" || true
    audit_action "自动安全更新启用失败；恢复状态 ${FAILED}；$QUENCH_UPDATE_RUN" FAILED
    return "$RC"
}

system_update_auto_enable_apt() (
    umask 077
    systemd_available || { error "Debian 自动安全更新入口需要 systemd；其他调度方式请人工配置"; return 1; }
    system_update_run_prepare || return 1
    system_update_require_python || return $?
    system_update_apt_preflight || return 1
    local QUENCH_AUTO_MUTATED=no QUENCH_AUTO_UNITS_TOUCHED=no
    local QUENCH_AUTO_TARGETS=("${QUENCH_APT_AUTO_UPGRADES_FILE:-$QUENCH_UPDATE_APT_DIR/apt.conf.d/20auto-upgrades}" "${QUENCH_APT_UNATTENDED_FILE:-$QUENCH_UPDATE_APT_DIR/apt.conf.d/52quench-unattended-upgrades}")
    local QUENCH_AUTO_TOUCHED=(no no) QUENCH_AUTO_CANDIDATES=()
    local MASKS="" UNIT STATE ACTIVE FILE I REL
    # Candidate validation must use exactly the files we intend to install.
    [ "${QUENCH_AUTO_TARGETS[0]}" = "$QUENCH_UPDATE_APT_DIR/apt.conf.d/20auto-upgrades" ] \
        && [ "${QUENCH_AUTO_TARGETS[1]}" = "$QUENCH_UPDATE_APT_DIR/apt.conf.d/52quench-unattended-upgrades" ] \
        || { error "自动启用不接管自定义 APT 配置文件路径"; return 1; }
    for FILE in "${QUENCH_AUTO_TARGETS[@]}"; do
        if [ -L "$FILE" ] || { [ -e "$FILE" ] && [ ! -f "$FILE" ]; }; then
            error "配置不是普通文件：$FILE"; return 1
        fi
    done
    system_update_auto_templates_scan > "$QUENCH_UPDATE_RUN/templates.list" || return 1
    system_update_auto_units_snapshot > "$QUENCH_UPDATE_RUN/units-before" || { error "无法安全读取自动更新服务状态"; return 1; }
    while IFS= read -r REL; do
        FILE="$QUENCH_UPDATE_APT_DIR/$REL"
        [ ! -L "$FILE" ] && [ -f "$FILE" ] || return 1
        mkdir -p "$(dirname "$QUENCH_UPDATE_RUN/templates-before/$REL")" || return 1
        cp -p "$FILE" "$QUENCH_UPDATE_RUN/templates-before/$REL" || return 1
    done < "$QUENCH_UPDATE_RUN/templates.list" || return 1
    system_update_auto_templates_recheck || return 1
    while IFS=$'\t' read -r UNIT STATE ACTIVE; do
        case "$STATE" in masked|masked-runtime) MASKS="$MASKS $UNIT ($STATE)" ;; esac
    done < "$QUENCH_UPDATE_RUN/units-before"
    # Check precedence before installing anything. Only the reviewed pure
    # disabling files are excluded; all other administrator policies remain.
    if ! system_update_auto_candidate_check "$QUENCH_UPDATE_RUN/candidate" "$QUENCH_UPDATE_RUN/templates.list"; then
        info "候选策略仍被其他配置影响；以下为相关设置的位置："
        grep -RnsE 'APT::Periodic|Origins-Pattern|Allowed-Origins|Automatic-Reboot|Remove-.*Dependencies|Remove-Unused-Kernel' \
            "$QUENCH_UPDATE_APT_DIR/apt.conf.d" "$QUENCH_UPDATE_APT_DIR/apt.conf" 2>/dev/null || true
        return 1
    fi
    while IFS= read -r REL; do
        warn "检测到纯禁用配置：${QUENCH_UPDATE_APT_DIR}/${REL}（确认后移出生效配置，原件保存在 templates-before/${REL}）"
    done < "$QUENCH_UPDATE_RUN/templates.list"
    [ -z "$MASKS" ] || warn "检测到服务/定时器屏蔽：$MASKS"
    confirm_change_preview "启用自动安全更新及处理以上冲突" \
        "仅处理列出的纯禁用配置与屏蔽项，其他管理员配置保留；备份：$QUENCH_UPDATE_RUN" \
        "只安装安全更新，不自动重启或清理软件包；timer 启用后可能很快执行，服务可能重启" \
        "失败时尝试恢复配置和服务状态，不卸载本次安装的软件包，不终止正在运行的 APT 任务" || return 1
    system_update_auto_units_snapshot > "$QUENCH_UPDATE_RUN/units-recheck" || return 1
    cmp -s "$QUENCH_UPDATE_RUN/units-before" "$QUENCH_UPDATE_RUN/units-recheck" || { error "确认期间服务状态变化，请重试"; return 1; }
    system_update_auto_templates_recheck || return 1
    trap 'QUENCH_AUTO_RC=$?; trap - EXIT; system_update_auto_enable_cleanup "$QUENCH_AUTO_RC"; exit "$QUENCH_AUTO_RC"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    QUENCH_AUTO_MUTATED=yes
    systemctl stop apt-daily.timer apt-daily-upgrade.timer || return 1
    system_update_auto_workers_idle || { error "APT/dpkg 任务已启动或锁状态不可确认，请等待完成"; return 1; }
    # Keep masks during installation. Package postinst may report them; this is
    # expected. Unmask only after the live security-only policy has been verified.
    [ -z "$MASKS" ] || info "安装依赖时暂保留屏蔽，安装器可能提示 masked；策略验证成功后才解除"
    system_update_auto_install_dependency || { error "unattended-upgrades 安装失败；详情见 $QUENCH_UPDATE_RUN/commands.log"; return 1; }
    # Package-created defaults form the rollback baseline; installation itself
    # is not reversible. Save them before overwriting, including file absence.
    QUENCH_AUTO_CANDIDATES=("$QUENCH_UPDATE_RUN/candidate/parts/20auto-upgrades" "$QUENCH_UPDATE_RUN/candidate/parts/52quench-unattended-upgrades")
    for I in 0 1; do
        FILE=${QUENCH_AUTO_TARGETS[$I]}
        [ ! -L "$FILE" ] && { [ ! -e "$FILE" ] || [ -f "$FILE" ]; } || return 1
        if [ -f "$FILE" ]; then cp -p "$FILE" "$QUENCH_UPDATE_RUN/before-$I" || return 1; fi
    done
    # Revalidate after package installation added its own default fragments.
    system_update_auto_templates_recheck || return 1
    system_update_auto_candidate_check "$QUENCH_UPDATE_RUN/recheck" "$QUENCH_UPDATE_RUN/templates.list" || return 1
    for I in 0 1; do
        QUENCH_AUTO_TOUCHED[$I]=yes
        atomic_replace_file "${QUENCH_AUTO_CANDIDATES[$I]}" "${QUENCH_AUTO_TARGETS[$I]}" || return 1
    done
    while IFS= read -r REL; do
        FILE="$QUENCH_UPDATE_APT_DIR/$REL"
        if [ -L "$FILE" ] || [ ! -f "$FILE" ] || ! cmp -s "$FILE" "$QUENCH_UPDATE_RUN/templates-before/$REL"; then
            error "禁用配置被修改，不移除：$FILE"; return 1
        fi
        printf '%s\n' "$REL" >> "$QUENCH_UPDATE_RUN/templates-touched" || return 1
        rm "$FILE" || return 1
        info "禁用配置已移出 APT：${FILE}；备份：$QUENCH_UPDATE_RUN/templates-before/$REL"
    done < "$QUENCH_UPDATE_RUN/templates.list" || return 1
    system_update_auto_policy_verify || return 1
    QUENCH_AUTO_UNITS_TOUCHED=yes
    while IFS=$'\t' read -r UNIT STATE ACTIVE; do
        case "$STATE" in
            masked) systemctl unmask "$UNIT" || return 1 ;;
            masked-runtime) systemctl unmask --runtime "$UNIT" || return 1 ;;
        esac
    done < "$QUENCH_UPDATE_RUN/units-before"
    systemctl enable --now unattended-upgrades.service || return 1
    systemctl enable apt-daily.timer apt-daily-upgrade.timer || return 1
    systemctl start apt-daily.timer apt-daily-upgrade.timer || return 1
    system_update_auto_policy_verify && system_update_auto_units_ready || return 1
    printf 'operation=auto-security-enable\nexit_code=0\n' > "$QUENCH_UPDATE_RUN/result.txt" || return 1
    audit_action "启用自动安全更新；备份 $QUENCH_UPDATE_RUN" SUCCESS
    info "自动安全更新已启用并验证；禁止自动重启，配置/服务状态备份：$QUENCH_UPDATE_RUN"
)

system_update_apt_locked() {
    local MODE="$1" BASELINE="${2:-}" CODE PLAN PACKAGE STATUS INPUT
    local PKG_NAMES=() ARGS=()
    CODE=$(system_update_debian_code) || return 1
    system_update_apt_preflight || return 1
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_apt_origins_guard "$CODE" || return 1
    case "$MODE" in
        check)
            # The simulation includes current/candidate versions and archive origin.
            system_update_logged env LC_ALL=C apt-get -s --with-new-pkgs upgrade
            return $?
            ;;
        current) ARGS=(--no-remove --with-new-pkgs upgrade) ;;
        full) ARGS=(dist-upgrade) ;;
        packages)
            LC_ALL=C apt-get -s --with-new-pkgs upgrade || return 1
            read -rp "输入已安装的软件包名（空格分隔，回车取消）: " INPUT || return 2
            [ -n "$INPUT" ] || return 2
            read -r -a PKG_NAMES <<< "$INPUT"
            [ "${#PKG_NAMES[@]}" -gt 0 ] || return 2
            for PACKAGE in "${PKG_NAMES[@]}"; do
                system_update_package_valid "$PACKAGE" || { error "无效包名：$PACKAGE"; return 1; }
                STATUS=$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null) || return 1
                [ "$STATUS" = 'install ok installed' ] || { error "只更新已安装的软件包：$PACKAGE"; return 1; }
            done
            ARGS=(--no-remove --only-upgrade install "${PKG_NAMES[@]}")
            ;;
        autoremove) ARGS=(autoremove) ;;
        security)
            command -v unattended-upgrade >/dev/null 2>&1 || {
                error "请先启用自动安全更新以安装 unattended-upgrades，或自行安装该包后重试"
                return 1
            }
            system_update_security_config "$QUENCH_UPDATE_RUN/security.conf" "$CODE" || return 1
            system_update_logged env APT_CONFIG="$QUENCH_UPDATE_RUN/security.conf" unattended-upgrade --dry-run --debug || return 1
            confirm_change_preview "仅安装 Debian 安全更新" "只允许 ${CODE}-security；不自动重启、不自动移除包" \
                "服务可能重启，软件包配置发生冲突时可能保留旧版本；请检查更新日志" || return 2
            system_update_backup || return 1
            system_update_logged env APT_CONFIG="$QUENCH_UPDATE_RUN/security.conf" unattended-upgrade --verbose || return 1
            system_update_postcheck "$BASELINE"
            return $?
            ;;
        *) return 1 ;;
    esac
    PLAN="$QUENCH_UPDATE_RUN/plan.txt"
    LC_ALL=C apt-get -s "${ARGS[@]}" > "$PLAN" 2>&1 || { cat "$PLAN"; return 1; }
    cat "$PLAN"
    # No automatic removals of remote access, boot or package-management essentials.
    if grep -Eq '^Remv (openssh-server|sudo|systemd|systemd-sysv|apt|dpkg|libc6|linux-image[^ ]*|grub[^ ]*|initramfs-tools[^ ]*)( |:)' "$PLAN"; then
        error "计划删除访问/引导/包管理关键包，拒绝自动执行；请人工核对"
        return 1
    fi
    grep -Eq '^(Inst|Remv) ' "$PLAN" || {
        info "没有符合条件的更新；请留意保留/锁定的软件包"
        system_update_postcheck "$BASELINE"
        return $?
    }
    confirm_change_preview "执行以上软件包计划" "保持当前 Debian 大版本，不修改软件源" \
        "可能重启相关服务；配置文件冲突交由你选择，不自动覆盖" \
        "记录不是系统快照，升级不能自动撤销；不会自动重启机器" || return 2
    system_update_backup || return 1
    # Recheck sources after the user spends time reviewing the plan.
    system_update_sources check "$CODE" || return 1
    # Let APT show its final plan and ask again; no -y, no forced conffile policy.
    system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 "${ARGS[@]}" || return 1
    system_update_postcheck "$BASELINE"
}

system_update_other_locked() {
    local MODE="$1" PM RC=0
    PM=$(system_package_manager)
    case "$MODE:$PM" in
        check:dnf|check:yum)
            "$PM" check-update || RC=$?
            [ "$RC" -eq 0 ] || [ "$RC" -eq 100 ]; return $? ;;
        check:apk) apk update && apk version -l '<'; return $? ;;
        check:opkg) opkg update && opkg list-upgradable; return $? ;;
    esac
    confirm_change_preview "通过 $PM 更新" "不修改发行版软件源，不自动重启" "由包管理器展示最终计划并确认，服务可能重启" || return 2
    case "$MODE:$PM" in
        current:dnf|full:dnf|current:yum|full:yum) system_update_logged "$PM" upgrade ;;
        security:dnf|security:yum) system_update_logged "$PM" upgrade --security ;;
        current:apk|full:apk) system_update_logged apk update && system_update_logged apk --interactive upgrade ;;
        *) error "该操作目前仅支持 Debian 12/13；OpenWrt 请使用逐包维护或固件升级"; return 1 ;;
    esac
}

system_update_action() (
    local MODE="$1" CONTEXT="${2:-protected}" RC=0 BASELINE=""
    umask 077
    case "$CONTEXT" in
        protected) [ "$MODE" = check ] || system_update_session_ready || return 1 ;;
        onboarding)
            # A deliberate foreground exception for initial provisioning only.
            # No environment flag or general CLI bypass for major/removal actions.
            case "$MODE" in current|full) : ;; *) error "开荒更新不支持该操作：$MODE"; return 2 ;; esac
            system_update_terminal_ready || { error "开荒更新需要交互终端"; return 1; }
            ;;
        *) error "无效的更新入口：$CONTEXT"; return 2 ;;
    esac
    txn_write_begin "系统与软件更新：$MODE" || return 1
    trap 'txn_write_end' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    system_update_run_prepare || return 1
    if [ "$(system_package_manager)" = apt ]; then
        # Snapshot before even bootstrapping Python: dependency installation can
        # also change service state. Never reuse a previous run's baseline.
        if [ "$MODE" != check ] && systemd_available; then
            BASELINE="$QUENCH_UPDATE_RUN/services-before.txt"
            system_update_failed_units > "$BASELINE" || RC=1
            if [ "$RC" -eq 0 ] && [ -s "$BASELINE" ]; then
                warn "更新前已存在失败单元；更新后将对比状态，这些故障仍需单独排查："
                cat "$BASELINE" || RC=1
            fi
        fi
        if [ "$RC" -eq 0 ]; then system_update_require_python || RC=$?; fi
        if [ "$RC" -eq 0 ]; then system_update_apt_locked "$MODE" "$BASELINE" || RC=$?; fi
    else
        system_update_other_locked "$MODE" || RC=$?
    fi
    printf 'operation=%s\nexit_code=%s\n' "$MODE" "$RC" > "$QUENCH_UPDATE_RUN/result.txt" || RC=1
    case "$RC" in
        0) audit_action "系统更新：$MODE" SUCCESS; info "操作已完成；详情：$QUENCH_UPDATE_RUN" ;;
        2) audit_action "取消系统更新：$MODE" INFO; info "已取消，未执行该更新计划" ;;
        *) audit_action "系统更新未完成：$MODE" FAILED; error "操作或后检查失败；不视为升级成功，请检查 $QUENCH_UPDATE_RUN 和 /var/log/apt/" ;;
    esac
    [ "$RC" -ne 2 ] || RC=0
    return "$RC"
)

system_update_clean_cache() (
    local PM RC=0
    confirm_change_preview "仅清理下载缓存" "不会执行 autoremove，不卸载任何软件包" || return 0
    txn_write_begin "清理软件包下载缓存" || return 1
    trap 'txn_write_end' EXIT
    PM=$(system_package_manager)
    case "$PM" in
        apt) apt-get clean || RC=$? ;;
        dnf|yum) "$PM" clean packages || RC=$? ;;
        apk) apk cache clean || RC=$? ;;
        *) error "当前包管理器暂不提供此操作"; RC=1 ;;
    esac
    if [ "$RC" -eq 0 ]; then audit_action "清理下载缓存" SUCCESS; info "下载缓存已清理"
    else audit_action "清理下载缓存" FAILED; fi
    return "$RC"
)

system_update_auto_disable() (
    local PM TARGET
    confirm_change_preview "关闭系统自动更新" "保留已安装软件包与配置，不停止正在执行的软件包事务" \
        "只禁用后续周期执行；已有任务如正在运行，需要等它正常结束" || return 0
    txn_write_begin "关闭自动安全更新" || return 1
    QUENCH_UPDATE_DISABLE_STAGE=""
    trap 'QUENCH_UPDATE_DISABLE_RC=$?; [ -z "$QUENCH_UPDATE_DISABLE_STAGE" ] || rm -f "$QUENCH_UPDATE_DISABLE_STAGE"; txn_write_end; if [ "$QUENCH_UPDATE_DISABLE_RC" -ne 0 ]; then audit_action "关闭自动安全更新失败" FAILED; fi; exit "$QUENCH_UPDATE_DISABLE_RC"' EXIT
    PM=$(system_package_manager)
    case "$PM" in
        apt)
            TARGET="${QUENCH_APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
            QUENCH_UPDATE_DISABLE_STAGE=$(mktemp "${TARGET}.quench.XXXXXX") || return 1
            printf '%s\n' 'APT::Periodic::Update-Package-Lists "0";' 'APT::Periodic::Unattended-Upgrade "0";' > "$QUENCH_UPDATE_DISABLE_STAGE" || return 1
            chmod 644 "$QUENCH_UPDATE_DISABLE_STAGE" && mv "$QUENCH_UPDATE_DISABLE_STAGE" "$TARGET" || return 1
            if systemd_available; then
                systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || return 1
            fi
            apt-config dump | awk '$0=="APT::Periodic::Unattended-Upgrade \"0\";" {ok=1} END {exit !ok}' \
                || { error "其他 APT 配置覆盖了关闭设置，请人工检查"; return 1; }
            ;;
        dnf) systemctl disable --now dnf-automatic.timer || return 1 ;;
        yum) warn "yum-cron 的关闭请通过发行版服务管理执行，避免中断正在运行的更新"; return 1 ;;
        *) return 1 ;;
    esac
    audit_action "关闭自动安全更新" SUCCESS
    info "后续自动更新已关闭；这不取消已在运行的任务"
)

system_update_auto_menu() {
    local CH
    print_header "自动安全更新设置"
    if system_auto_updates_enabled; then info "当前符合 Quench 自动更新配置要求"; else warn "未启用或配置不符合 Quench 要求"; fi
    menu_item 1 "启用自动安全更新（禁止自动重启）"
    menu_item 2 "关闭后续自动更新"
    menu_item 0 "返回"
    read -rp "选择 [0-2]: " CH || return 0
    case "$CH" in
        1)
            confirm_change_preview "启用自动安全更新" "安装必要依赖，启用系统 timer；不自动重启" || return 0
            system_enable_auto_security_updates
            ;;
        2) system_update_auto_disable ;;
    esac
}

# Removing a backports source must not hide installed backports packages. Keep
# them on the manual path; never silently downgrade or uninstall them.
system_update_backports_guard() {
    local PACKAGES BACKPORTS
    PACKAGES=$(dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n') || {
        error "无法读取已安装软件包，不能确认 backports 使用情况"; return 1;
    }
    BACKPORTS=$(printf '%s\n' "$PACKAGES" | awk '$1 == "ii" && $3 ~ /~bpo12/ {print $2 " " $3}') || return 1
    if [ -n "$BACKPORTS" ]; then
        error "已安装 Debian 12 backports 软件包，需先核对其 Debian 13 迁移路径："
        printf '%s\n' "$BACKPORTS"
        info "不会自动卸载或降级这些包；仅启用 backports 源且没有安装相关包时，向导可自动停用该源"
        return 1
    fi
}

# APT's !origin(Debian) also lists old official kernels removed from the index.
# This is classification using installed metadata, not proof of provenance.
# Only recognize an older, non-running Debian 12 kernel of the same flavour;
# leave it installed as a fallback. Never exempt arbitrary linux-* packages.
system_update_retired_kernel() {
    local PACKAGE="$1" RUNNING="$2" FLAVOUR META STATUS SOURCE VERSION MAINTAINER CURRENT_VERSION ITEM
    [[ "$RUNNING" =~ ^6\.1\.0-[0-9]+-(cloud-)?(amd64|arm64)$ ]] || return 1
    [ "$PACKAGE" != "linux-image-$RUNNING" ] || return 1
    FLAVOUR=${RUNNING#6.1.0-}; FLAVOUR=${FLAVOUR#*-}
    [[ "$PACKAGE" =~ ^linux-image-6\.1\.0-[0-9]+-${FLAVOUR}$ ]] || return 1
    for ITEM in "linux-image-$RUNNING" "$PACKAGE"; do
        META=$(dpkg-query -W -f='${Status}\t${source:Package}\t${Version}\t${Maintainer}\n' "$ITEM") || return 1
        IFS=$'\t' read -r STATUS SOURCE VERSION MAINTAINER <<< "$META"
        [ "$STATUS" = 'install ok installed' ] || return 1
        case "$SOURCE" in linux|"linux-signed-${FLAVOUR##*-}") : ;; *) return 1 ;; esac
        [ "$MAINTAINER" = 'Debian Kernel Team <debian-kernel@lists.debian.org>' ] || return 1
        [[ "$VERSION" =~ ^6\.1\.[0-9]+(-[0-9]+(\+deb12u[0-9]+)?|\+[0-9]+)$ ]] || return 1
        if [ "$ITEM" = "linux-image-$RUNNING" ]; then CURRENT_VERSION="$VERSION"; fi
    done
    dpkg --compare-versions "$VERSION" lt "$CURRENT_VERSION"
}

system_update_foreign_guard() {
    local FOREIGN RUNNING LINE PACKAGE BLOCKED=0 RETIRED=""
    FOREIGN=$(LC_ALL=C apt list '?narrow(?installed,?not(?origin(Debian)))' 2>/dev/null) || {
        error "无法检查软件包来源；请先运行 apt-cache policy 和 dpkg --audit 排查"; return 1;
    }
    RUNNING=$(uname -r) || return 1
    while IFS= read -r LINE; do
        [[ "$LINE" =~ ^[^\ /]+/ ]] || continue
        PACKAGE=${LINE%%/*}
        if system_update_retired_kernel "$PACKAGE" "$RUNNING"; then
            RETIRED="${RETIRED}${LINE}"$'\n'
        else
            if [ "$BLOCKED" -eq 0 ]; then
                error "以下已安装包在当前 Debian 仓库中无法确认来源（不一定是第三方包）："
            fi
            printf '  %s\n' "$LINE"
            printf '  排查：apt-cache policy %s\n' "$PACKAGE"
            BLOCKED=1
        fi
    done <<< "$FOREIGN"
    if [ -n "$RETIRED" ]; then
        warn "识别到较旧的备用内核（依据包元数据），保留它们并继续预检："
        printf '%s' "$RETIRED"
        info "当前运行 ${RUNNING}；不会自动清理内核，请等 Debian 13 新内核启动正常后再处理"
    fi
    [ "$BLOCKED" -eq 0 ]
}

# Identify the running Debian 12 kernel before installing a matching metapackage.
# Local package metadata is a compatibility check, not a provenance attestation.
system_update_kernel_meta() {
    local ARCH="$1" RUNNING PACKAGE OWNER DATA STATUS SOURCE VERSION MAINTAINER FLAVOUR
    RUNNING=$(uname -r) || return 1
    [[ "$RUNNING" =~ ^6\.1\.0-[0-9]+-(cloud-)?${ARCH}$ ]] || {
        error "运行内核 $RUNNING 不是支持的 Debian 12 标准类型；不会自动替换自定义内核" >&2; return 1;
    }
    PACKAGE="linux-image-$RUNNING"
    OWNER=$(dpkg-query -S "/boot/vmlinuz-$RUNNING" 2>/dev/null) || return 1
    case "$OWNER" in "$PACKAGE: /boot/vmlinuz-$RUNNING"|"$PACKAGE:$ARCH: /boot/vmlinuz-$RUNNING") : ;;
        *) error "当前内核文件与软件包归属不匹配" >&2; return 1 ;; esac
    DATA=$(dpkg-query -W -f='${Status}\t${source:Package}\t${Version}\t${Maintainer}\n' "$PACKAGE") || return 1
    IFS=$'\t' read -r STATUS SOURCE VERSION MAINTAINER <<< "$DATA"
    [ "$STATUS" = 'install ok installed' ] && [ "$MAINTAINER" = 'Debian Kernel Team <debian-kernel@lists.debian.org>' ] || {
        error "当前内核包状态或维护者无法确认，不自动补装内核" >&2; return 1;
    }
    case "$SOURCE" in linux|"linux-signed-$ARCH") : ;; *) error "当前内核不是标准 Debian 源包" >&2; return 1 ;; esac
    [[ "$VERSION" =~ ^6\.1\.[0-9]+(-[0-9]+(\+deb12u[0-9]+)?|\+[0-9]+)$ ]] || {
        error "当前内核版本不在标准 bookworm 范围内" >&2; return 1;
    }
    FLAVOUR=${RUNNING#6.1.0-}; FLAVOUR=${FLAVOUR#*-}
    printf 'linux-image-%s\n' "$FLAVOUR"
}

system_update_kernel_image_present() {
    [ -s "/boot/vmlinuz-$1" ]
}

system_update_kernel_boot_target() {
    local META="$1" DEP TARGET STATUS
    STATUS=$(dpkg-query -W -f='${Status}' "$META" 2>/dev/null) || return 1
    [ "$STATUS" = 'install ok installed' ] || return 1
    DEP=$(dpkg-query -W -f='${Depends}' "$META") || return 1
    [[ "$DEP" != *'|'* ]] || return 1
    TARGET=$(printf '%s\n' "$DEP" | grep -oE "linux-image-6\.1\.0-[0-9]+-${META#linux-image-}([[:space:],]|$)" | sed 's/[[:space:],]*$//') || return 1
    [ -n "$TARGET" ] && [[ "$TARGET" != *$'\n'* ]] || return 1
    [[ "$TARGET" =~ ^linux-image-6\.1\.0-[0-9]+-(cloud-)?(amd64|arm64)$ ]] || return 1
    STATUS=$(dpkg-query -W -f='${Status}' "$TARGET" 2>/dev/null) || return 1
    [ "$STATUS" = 'install ok installed' ] || return 1
    system_update_kernel_image_present "${TARGET#linux-image-}" || return 1
    printf '%s\n' "${TARGET#linux-image-}"
}

system_update_bookworm_plan_guard() {
    [ -f "$1" ] && [ -r "$1" ] || return 1
    if grep -Eq '^Remv (openssh-server|sudo|systemd|systemd-sysv|apt|dpkg|libc6|linux-image[^ ]*|grub[^ ]*|initramfs-tools[^ ]*)( |:)|^Inst .*~bpo12' "$1"; then
        error "准备计划涉及删除访问/引导/包管理关键包或安装 backports，已停止"
        return 1
    fi
}

# Called under the major-upgrade transaction lock. Separate evidence/backup
# directory prevents the later trixie phase from overwriting bookworm evidence.
# 2 = declined, 3 = preparation complete but a manual reboot is required.
system_update_bookworm_prepare() {
    local QUENCH_UPDATE_RUN="$QUENCH_UPDATE_RUN/bookworm-preparation"
    system_update_bookworm_prepare_locked "$1"
}

system_update_bookworm_result() {
    local RESULT="$1"
    printf 'operation=bookworm-preparation\nexit_code=%s\n' "$RESULT" > "$QUENCH_UPDATE_RUN/result.txt" || RESULT=1
    return "$RESULT"
}

system_update_bookworm_prepare_locked() (
    local META="$1" NEED_META=no NEED_UPDATE=no STATUS TARGET
    umask 077
    mkdir -p "$QUENCH_UPDATE_RUN" || return 1
    trap 'QUENCH_BOOKWORM_RESULT=$?; trap - EXIT; system_update_bookworm_result "$QUENCH_BOOKWORM_RESULT"; exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # Record both configuration and the exact source layout before confirmation.
    # Repository/pinning changes while the user reviews the plan require a retry.
    cp -a "$QUENCH_UPDATE_APT_DIR" "$QUENCH_UPDATE_RUN/apt-plan" || return 1
    STATUS=$(dpkg-query -W -f='${Status}' "$META" 2>/dev/null || true)
    if [ "$STATUS" != 'install ok installed' ]; then
        NEED_META=yes
        info "将补齐与当前内核匹配的元包：$META"
        LC_ALL=C apt-get -s --no-remove install "$META" > "$QUENCH_UPDATE_RUN/kernel-plan.txt" 2>&1 || { cat "$QUENCH_UPDATE_RUN/kernel-plan.txt"; return 1; }
        cat "$QUENCH_UPDATE_RUN/kernel-plan.txt"
        system_update_bookworm_plan_guard "$QUENCH_UPDATE_RUN/kernel-plan.txt" || return 1
    fi
    LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_UPDATE_RUN/full-plan.txt" 2>&1 || { cat "$QUENCH_UPDATE_RUN/full-plan.txt"; return 1; }
    system_update_bookworm_plan_guard "$QUENCH_UPDATE_RUN/full-plan.txt" || return 1
    if grep -Eq '^(Inst|Remv) ' "$QUENCH_UPDATE_RUN/full-plan.txt"; then
        NEED_UPDATE=yes
        cat "$QUENCH_UPDATE_RUN/full-plan.txt"
    fi
    if [ "$NEED_META:$NEED_UPDATE" != no:no ]; then
        confirm_change_preview "先准备 Debian 12，再升级到 13" \
            "按以上计划补齐 $META 并完成 bookworm 全部更新；APT 仍会展示最终计划并确认" \
            "此阶段不切换软件源、不删除旧内核、不自动重启；配置冲突由你选择" \
            "请确认已有供应商快照、业务备份和可用控制台；包更新可能重启服务，Quench 不能回滚软件包" || return 2
        system_update_backup || return 1
        diff -qr "$QUENCH_UPDATE_RUN/apt-plan" "$QUENCH_UPDATE_APT_DIR" >/dev/null || {
            error "确认期间 APT 配置发生变化，请重新进入向导生成计划"; return 1;
        }
        system_update_apt_preflight || return 1
        system_update_sources major bookworm >/dev/null || return 1
        system_update_backports_guard || return 1
        if [ "$NEED_META" = yes ]; then
            LC_ALL=C apt-get -s --no-remove install "$META" > "$QUENCH_UPDATE_RUN/kernel-plan-final.txt" 2>&1 || return 1
            system_update_bookworm_plan_guard "$QUENCH_UPDATE_RUN/kernel-plan-final.txt" || return 1
            system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 --no-remove install "$META" || return 1
        fi
        # The metapackage may change the dependency plan: regenerate before use.
        system_update_sources major bookworm >/dev/null || return 1
        system_update_apt_health || return 1
        LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_UPDATE_RUN/full-plan.txt" 2>&1 || return 1
        system_update_bookworm_plan_guard "$QUENCH_UPDATE_RUN/full-plan.txt" || return 1
        if grep -Eq '^(Inst|Remv) ' "$QUENCH_UPDATE_RUN/full-plan.txt"; then
            system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 dist-upgrade || return 1
        fi
        system_update_postcheck || return 1
    fi
    system_update_apt_health || return 1
    LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_UPDATE_RUN/remaining.txt" 2>&1 || return 1
    if grep -Eq '^(Inst|Remv) ' "$QUENCH_UPDATE_RUN/remaining.txt"; then
        cat "$QUENCH_UPDATE_RUN/remaining.txt"
        error "Debian 12 仍有待更新软件包，未进入 Debian 13 升级"; return 1
    fi
    system_update_backports_guard || return 1
    TARGET=$(system_update_kernel_boot_target "$META") || {
        error "无法确认 $META 对应的内核已安装完整；请检查 $QUENCH_UPDATE_RUN"; return 1;
    }
    printf 'metapackage=%s\nboot_target=%s\nrunning=%s\n' "$META" "$TARGET" "$(uname -r)" > "$QUENCH_UPDATE_RUN/kernel.txt" || return 1
    if [ "$TARGET" != "$(uname -r)" ] || system_update_reboot_required; then
        warn "Debian 12 准备已完成，等待你手动重启；当前 $(uname -r)，目标内核 $TARGET"
        info "重启并确认 SSH/业务正常后，重新进入 Debian 12 → 13 向导，将自动复检后继续"
        info "尚未切换 trixie 软件源；记录：$QUENCH_UPDATE_RUN"
        return 3
    fi
    info "Debian 12 软件包与运行内核已就绪，继续大版本预检"
)

# Complex hosts stay on the official manual path. Common cloud-image source
# formats are normalized only in the reviewed candidate, not during preflight.
system_update_major_preflight() {
    local ARCH HELD PREF FREE PATH_CHECK STATUS META
    [ "$(system_update_debian_code)" = bookworm ] || { error "此向导只支持 Debian 12 → 13；13 的日常更新请选择 2"; return 1; }
    system_update_session_ready || return 1
    system_update_apt_preflight || return 1
    ARCH=$(dpkg --print-architecture) || return 1
    case "$ARCH" in amd64|arm64) : ;; *) error "大版本向导暂只验证 amd64/arm64"; return 1 ;; esac
    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
        error "容器/LXC/OpenVZ 不走此完整系统升级流程，请按宿主机策略维护"; return 1
    fi
    systemd_available || { error "此向导需要标准 systemd Debian 系统"; return 1; }
    HELD=$(apt-mark showhold) || return 1
    [ -z "$HELD" ] || { error "存在锁定包，请先人工核对，不会自动解除：$HELD"; return 1; }
    for PREF in "$QUENCH_UPDATE_APT_DIR/preferences" "$QUENCH_UPDATE_APT_DIR/preferences.d/"*; do
        [ -f "$PREF" ] || continue
        if grep -qE '^[[:space:]]*[^#[:space:]]' "$PREF"; then
            error "存在 APT pinning，请先人工处理：$PREF"; return 1
        fi
    done
    # We never remove/rewrite third-party repositories on the user's behalf.
    QUENCH_UPDATE_MAJOR_SOURCE=$(system_update_sources major bookworm) || return 1
    META=$(system_update_kernel_meta "$ARCH") || return 1
    for PATH_CHECK in / /var /boot; do
        [ -d "$PATH_CHECK" ] || continue
        FREE=$(df -Pk "$PATH_CHECK" | awk 'NR==2 {print $4}')
        [[ "$FREE" =~ ^[0-9]+$ ]] || return 1
        if { [ "$PATH_CHECK" = /boot ] && [ "$FREE" -lt 262144 ]; } || { [ "$PATH_CHECK" != /boot ] && [ "$FREE" -lt 2097152 ]; }; then
            error "$PATH_CHECK 空间不足（/ 与 /var 至少 2GiB，/boot 至少 256MiB）；实际需求仍由 APT 检查"; return 1
        fi
    done
    for STATUS in apt-daily.service apt-daily-upgrade.service; do
        if systemctl is-active --quiet "$STATUS"; then error "$STATUS 正在运行，请等其完成"; return 1; fi
    done
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_apt_origins_guard bookworm || return 1
    system_update_backports_guard || return 1
    system_update_bookworm_prepare "$META" || return $?
    # Package hooks may have changed repository configuration during preparation.
    system_update_apt_preflight || return 1
    QUENCH_UPDATE_MAJOR_SOURCE=$(system_update_sources major bookworm) || return 1
    system_update_foreign_guard || return 1
    if system_update_reboot_required; then
        error "当前系统已要求重启，请先重启并验证服务正常"; return 1
    fi
    for STATUS in apt-daily.service apt-daily-upgrade.service; do
        if systemctl is-active --quiet "$STATUS"; then error "$STATUS 正在运行，请等其完成"; return 1; fi
    done
}

system_update_major_phase() {
    printf '%s\n' "$1" > "$QUENCH_UPDATE_RUN/major-phase" || return 1
    QUENCH_UPDATE_MAJOR_PHASE="$1"
}

system_update_major_cleanup() {
    local RC="$1" TMP_RESTORE TIMER
    [ -z "${QUENCH_UPDATE_MAJOR_STAGE:-}" ] || rm -f "$QUENCH_UPDATE_MAJOR_STAGE"
    # This trap runs in a dedicated subshell. State uses namespaced globals so
    # it remains available after a function returns (including Bash 3.2 EXIT).
    if [ "$QUENCH_UPDATE_MAJOR_PHASE" = sources-switched ]; then
        # No package write has been attempted. Restoring only the source file is
        # safe, but only when nobody has edited the candidate in the meantime.
        if cmp -s "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-new"; then
            TMP_RESTORE=$(mktemp "${QUENCH_UPDATE_MAJOR_SOURCE}.quench-restore.XXXXXX")
            if [ -n "$TMP_RESTORE" ] && cp -p "$QUENCH_UPDATE_RUN/source-before" "$TMP_RESTORE" && mv "$TMP_RESTORE" "$QUENCH_UPDATE_MAJOR_SOURCE"; then
                warn "尚未安装新版本软件包，已恢复原源文件；下次操作须先刷新索引"
                system_update_major_phase sources-restored || RC=1
            else
                [ -z "$TMP_RESTORE" ] || rm -f "$TMP_RESTORE"
                error "恢复源文件失败，请使用备份人工恢复"
                RC=1
            fi
        else
            error "源文件与本次候选不一致，不覆盖外部修改；请人工核对"
            RC=1
        fi
    elif [ "$QUENCH_UPDATE_MAJOR_PHASE" = packages-started ]; then
        error "已进入软件包升级阶段，不自动切回 bookworm、不尝试软件包降级"
        error "请从控制台排查 dpkg/APT；完整恢复只能使用供应商快照。记录：$QUENCH_UPDATE_RUN"
        RC=1
    fi
    case "$QUENCH_UPDATE_MAJOR_PHASE" in
        prepared|sources-restored|complete)
            for TIMER in $QUENCH_UPDATE_MAJOR_TIMERS; do
                systemctl start "$TIMER" || RC=1
            done
            ;;
        *) [ -z "$QUENCH_UPDATE_MAJOR_TIMERS" ] || warn "自动更新 timer 暂时保持停止，请完成恢复后人工启动：$QUENCH_UPDATE_MAJOR_TIMERS" ;;
    esac
    printf 'operation=debian-12-to-13\nexit_code=%s\n' "$RC" > "$QUENCH_UPDATE_RUN/result.txt" || RC=1
    if [ "$RC" -eq 0 ]; then audit_action "Debian 大版本向导：$QUENCH_UPDATE_MAJOR_PHASE" SUCCESS
    else audit_action "Debian 大版本向导未完成：$QUENCH_UPDATE_MAJOR_PHASE" FAILED; fi
    txn_write_end
    return "$RC"
}

system_update_debian_major() (
    umask 077
    print_header "Debian 12 → 13 · 高风险升级向导"
    warn "升级不可由 Quench 配置备份或防断联计时器撤销；可能导致服务中断或重启后无法联网"
    echo '官方说明：https://www.debian.org/releases/trixie/release-notes/upgrading.en.html'
    echo '已知变化：https://www.debian.org/releases/trixie/release-notes/issues.en.html'
    system_update_session_ready || return 1
    txn_write_begin "Debian 12 → 13" || return 1
    trap 'txn_write_end' EXIT
    system_update_run_prepare || return 1
    system_update_require_python || return $?
    local ANSWER TIMER DIFF_RC=0 PREP_RC=0
    system_update_major_preflight || PREP_RC=$?
    case "$PREP_RC" in
        0) : ;;
        2|3)
            printf 'operation=debian-12-to-13\npreparation_exit_code=%s\nstatus=not-started\n' "$PREP_RC" > "$QUENCH_UPDATE_RUN/result.txt" || return 1
            if [ "$PREP_RC" = 2 ]; then info "已取消准备，尚未开始 Debian 13 升级"; fi
            return 0 ;;
        *) return "$PREP_RC" ;;
    esac
    # Freeze the exact candidate before asking. A changed live source must not
    # be silently re-staged after the user approved a different plan.
    cp -p "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before" || return 1
    system_update_sources stage bookworm "$QUENCH_UPDATE_RUN/source-new" || return 1
    cmp -s "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before" || { error "生成计划期间源文件发生变化，请重新运行向导"; return 1; }
    info "软件源变更预览（确认后才应用；镜像列表原文件不改动）："
    diff -u "$QUENCH_UPDATE_RUN/source-before" "$QUENCH_UPDATE_RUN/source-new" || DIFF_RC=$?
    [ "$DIFF_RC" -le 1 ] || { error "无法展示源变更，已停止"; return 1; }
    confirm_change_preview "升级前必须由你确认" \
        "已创建可恢复的供应商磁盘快照及独立业务数据备份，控制台/救援系统确实可用" \
        "已核对 1Panel、Docker、数据库、代理及网站对 Debian 13 的兼容性" \
        "同意以上源变更；已有维护窗口，配置冲突由你选择，Quench 不自动重启" || return 0
    read -rp "输入 UPGRADE 12 TO 13 确认开始（其他输入取消）: " ANSWER || return 0
    [ "$ANSWER" = 'UPGRADE 12 TO 13' ] || { info "已取消"; return 0; }
    cmp -s "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before" || { error "源文件在确认期间发生变化，请重新运行向导"; return 1; }
    system_update_backports_guard || return 1
    system_update_backup || return 1
    QUENCH_UPDATE_MAJOR_PHASE=prepared
    QUENCH_UPDATE_MAJOR_TIMERS=""
    QUENCH_UPDATE_MAJOR_STAGE=""
    trap 'QUENCH_UPDATE_MAJOR_RC=$?; trap - EXIT; system_update_major_cleanup "$QUENCH_UPDATE_MAJOR_RC"; exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    system_update_major_phase prepared || return 1
    for TIMER in apt-daily.timer apt-daily-upgrade.timer; do
        if systemctl is-active --quiet "$TIMER"; then
            QUENCH_UPDATE_MAJOR_TIMERS="$QUENCH_UPDATE_MAJOR_TIMERS $TIMER"
            printf '%s\n' "$TIMER" >> "$QUENCH_UPDATE_RUN/timers-before.txt" || return 1
            systemctl stop "$TIMER" || return 1
        fi
    done
    # Recheck no package updater started while the confirmation dialog was open.
    for TIMER in apt-daily.service apt-daily-upgrade.service; do
        if systemctl is-active --quiet "$TIMER"; then error "$TIMER 已启动，取消迁移，请等待完成"; return 1; fi
    done
    cmp -s "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before" || { error "源文件在确认期间发生变化"; return 1; }
    QUENCH_UPDATE_MAJOR_STAGE=$(mktemp "${QUENCH_UPDATE_MAJOR_SOURCE}.quench-upgrade.XXXXXX") || return 1
    cp "$QUENCH_UPDATE_RUN/source-new" "$QUENCH_UPDATE_MAJOR_STAGE" && chmod 644 "$QUENCH_UPDATE_MAJOR_STAGE" || return 1
    mv "$QUENCH_UPDATE_MAJOR_STAGE" "$QUENCH_UPDATE_MAJOR_SOURCE" || return 1
    # Assign phase before any fallible operation after the rename.
    QUENCH_UPDATE_MAJOR_PHASE=sources-switched
    system_update_major_phase sources-switched || return 1
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_apt_origins_guard trixie || return 1
    system_update_logged env LC_ALL=C apt-get -s dist-upgrade || return 1
    confirm_change_preview "已切换 trixie，是否进入软件包升级阶段？" \
        "先最小升级、再完整升级；APT 每阶段仍会列出计划并询问" \
        "从下一步开始，发生失败也不会自动把源改回 Debian 12" || return 0
    system_update_sources major trixie >/dev/null || return 1
    system_update_major_phase packages-started || return 1
    system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 --no-remove upgrade || return 1
    system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 dist-upgrade || return 1
    [ "$(system_update_debian_code)" = trixie ] || { error "发行版未升级到 Debian 13，不能确认完成"; return 1; }
    LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_UPDATE_RUN/trixie-remaining.txt" 2>&1 || return 1
    if grep -Eq '^(Inst|Remv) ' "$QUENCH_UPDATE_RUN/trixie-remaining.txt"; then
        cat "$QUENCH_UPDATE_RUN/trixie-remaining.txt"
        error "仍有待升级或删除的软件包，尚不能确认跨版本升级完成"; return 1
    fi
    system_update_postcheck || return 1
    system_update_major_phase complete || return 1
    info "Debian 13 软件包升级完成。请从维护窗口重启，再检查 SSH、网络及业务服务"
    warn "不要立即清理旧内核；先确认新内核正常启动。不会自动重启"
)

system_update_manager() {
    local CH
    while true; do
        print_header "系统与软件更新"
        printf '  系统：%s %s  包管理器：%s\n' "$(system_update_os_value ID)" "$(system_update_os_value VERSION_ID)" "$(system_package_manager)"
        ui_hint "更新到配置仓库的候选版本；不是追逐上游最新版本。容器镜像和手动安装程序由各自入口管理。"
        menu_pair 1 "刷新并检查更新" 2 "更新当前系统（推荐，不删包）"
        menu_pair 3 "仅安装安全更新" 4 "选择软件包更新"
        menu_pair 5 "自动安全更新设置" 6 "更新后健康检查"
        menu_pair 7 "仅清理下载缓存" 8 "预览并移除不再需要的依赖"
        menu_pair f "完整依赖更新（可能删包）" v "Debian 12 → 13 升级向导" "$YELLOW" "$RED"
        menu_item 0 "返回"
        read -rp "$(ui_prompt '选择 [0-8 / f / v]: ')" CH || return 0
        case "$CH" in
            1) system_update_action check ;;
            2) system_update_dispatch current ;;
            3) system_update_dispatch security ;;
            4) system_update_dispatch packages ;;
            5) system_update_auto_menu ;;
            6) system_update_postcheck ;;
            7) system_update_clean_cache ;;
            8) system_update_dispatch autoremove ;;
            f|F) system_update_dispatch full ;;
            v|V) system_update_dispatch major ;;
            0) return 0 ;;
            *) warn "无效选项"; continue ;;
        esac
        ui_pause
    done
}
