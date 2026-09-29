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

# Conservative parser: reject unknown formats rather than silently miss a source.
# Python is used only by this advanced module, not by startup or the UI.
# major prints the single source file it can atomically replace; stage writes a
# candidate outside /etc. No global search/replace across third-party sources.
system_update_sources() {
    local MODE="$1" CODE="$2" DEST="${3:-}"
    command -v python3 >/dev/null 2>&1 || { error "需要 python3 解析软件源；请先从常用软件管理安装"; return 1; }
    python3 - "$QUENCH_UPDATE_APT_DIR" "$MODE" "$CODE" "$DEST" <<'PY'
import pathlib, re, shlex, sys
root, mode, code, dest = pathlib.Path(sys.argv[1]), *sys.argv[2:]
try:
    paths = [root / 'sources.list'] + sorted((root / 'sources.list.d').glob('*.list')) + sorted((root / 'sources.list.d').glob('*.sources'))
    records, originals = [], {}
    for path in paths:
        if not path.exists():
            continue
        if not path.is_file() or path.is_symlink():
            raise ValueError('源文件必须是普通文件：' + str(path))
        text = path.read_text()
        originals[path] = text
        if path.suffix == '.sources':
            for paragraph in re.split(r'\n\s*\n', text):
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
                records.append((path, fields['uris'].split(), fields['suites'].split(), fields.get('components', '').split(), 'deb' in fields['types'].split()))
        else:
            for line in text.splitlines():
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
                records.append((path, [tokens[0]], [tokens[1]], tokens[2:], binary))
    if not records:
        raise ValueError('没有启用的软件源')
    base = security = False
    for path, uris, suites, components, binary in records:
        for suite in suites:
            if re.match(r'^(stable|oldstable|oldoldstable|testing|unstable|sid)(-|$)', suite):
                raise ValueError('拒绝浮动发行版 ' + suite + '；请使用明确代号：' + str(path))
            if re.match(r'^(bullseye|bookworm|trixie|forky)(-|$)', suite) and suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                raise ValueError('检测到混合或不支持的发行版 ' + suite + '：' + str(path))
            official = all(re.match(r'^https?://(deb\.debian\.org/debian|security\.debian\.org/debian-security|deb\.debian\.org/debian-security)/?$', uri) for uri in uris)
            if any(re.search(r'/debian(-security)?/?$', uri) for uri in uris) and suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                raise ValueError('Debian 仓库代号不属于当前发行版：' + str(path))
            if mode in ('major', 'stage'):
                if not official or suite not in (code, code+'-updates', code+'-security') or 'main' not in components:
                    raise ValueError('大版本向导只接管官方标准源；第三方源/backports/自定义源需先人工处理：' + str(path))
            elif suite not in (code, code+'-updates', code+'-security', code+'-backports'):
                # Vendor suites such as Caddy any-version are allowed, never rewritten.
                print('提示：保留第三方源 ' + str(path) + ' (' + suite + ')', file=sys.stderr)
            if binary and 'main' in components and suite == code:
                base = True
            if binary and 'main' in components and suite == code+'-security':
                security = True
    if not base or not security:
        raise ValueError('缺少当前发行版的 main 或 security 源')
    if mode in ('major', 'stage'):
        active = set(r[0] for r in records)
        if len(active) != 1:
            raise ValueError('大版本向导要求启用的 Debian 源集中在一个文件，避免非原子地切换多个文件')
        path = active.pop()
        if mode == 'major':
            print(path)
        else:
            # Only whitespace-delimited suite tokens; never URI substrings.
            candidate = re.sub(r'(?<!\S)bookworm(-updates|-security)?(?!\S)', lambda m: 'trixie' + (m[1] or ''), originals[path])
            pathlib.Path(dest).write_text(candidate)
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
expected = {"Dir":"/", "Dir::Etc":"etc/apt", "Dir::Etc::sourcelist":"sources.list", "Dir::Etc::sourceparts":"sources.list.d"}
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

system_update_session_ready() {
    [ -t 0 ] && [ -t 1 ] || { error "更新需要交互终端，不能从 cron 或无输入管道执行"; return 1; }
    if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && [ -z "${TMUX:-}${STY:-}" ]; then
        error "远程更新请先进入 tmux 或 screen，再运行 Quench，避免断线中断软件包配置"
        return 1
    fi
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

system_update_postcheck() {
    local RC=0 FAILED
    if [ "$(system_package_manager)" = apt ]; then
        system_update_apt_health || RC=1
    fi
    if command -v sshd >/dev/null 2>&1; then
        sshd -t || { warn "sshd 配置验证失败；保持当前连接，先修复再重启"; RC=1; }
    fi
    if systemd_available; then
        FAILED=$(systemctl --failed --no-legend --no-pager 2>&1) || { warn "$FAILED"; return 1; }
        if [ -n "$FAILED" ]; then
            warn "存在失败服务（也可能在更新前已失败，请核对）："
            printf '%s\n' "$FAILED"
            RC=1
        fi
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
    CFG=$(apt-config dump) || return 1
    # shellcheck disable=SC2016 # ${distro_codename} is an unattended-upgrades macro, not a shell variable.
    printf '%s\n' "$CFG" | python3 -c '
import re,sys
text = sys.stdin.read()
def values(key):
    return re.findall(r"^"+re.escape(key)+r"(?:::)?\s+\"([^\"]*)\";", text, re.M)
expected = "origin=Debian,codename=${distro_codename}-security,label=Debian-Security"
patterns = [v for v in values("Unattended-Upgrade::Origins-Pattern") if v]
allowed = [v for v in values("Unattended-Upgrade::Allowed-Origins") if v]
ok = patterns == [expected] and not allowed
ok = ok and values("Unattended-Upgrade::Automatic-Reboot") == ["false"]
ok = ok and values("APT::Periodic::Unattended-Upgrade") == ["1"]
sys.exit(0 if ok else 1)
' || { error "有效 APT 配置被其他文件覆盖，不能确认仅安全更新且禁止自动重启"; return 1; }
}

system_update_apt_locked() {
    local MODE="$1" CODE PLAN PACKAGE STATUS INPUT
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
            system_update_postcheck
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
    grep -Eq '^(Inst|Remv) ' "$PLAN" || { info "没有符合条件的更新；请留意保留/锁定的软件包"; return 0; }
    confirm_change_preview "执行以上软件包计划" "保持当前 Debian 大版本，不修改软件源" \
        "可能重启相关服务；配置文件冲突交由你选择，不自动覆盖" \
        "记录不是系统快照，升级不能自动撤销；不会自动重启机器" || return 2
    system_update_backup || return 1
    # Recheck sources after the user spends time reviewing the plan.
    system_update_sources check "$CODE" || return 1
    # Let APT show its final plan and ask again; no -y, no forced conffile policy.
    system_update_logged env LC_ALL=C NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=60 "${ARGS[@]}" || return 1
    system_update_postcheck
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
    local MODE="$1" RC=0
    umask 077
    [ "$MODE" = check ] || system_update_session_ready || return 1
    txn_write_begin "系统与软件更新：$MODE" || return 1
    trap 'txn_write_end' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    system_update_run_prepare || return 1
    if [ "$(system_package_manager)" = apt ]; then
        system_update_apt_locked "$MODE" || RC=$?
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
            if [ "$(system_package_manager)" = apt ]; then system_update_apt_preflight || return 1; fi
            confirm_change_preview "启用自动安全更新" "安装必要依赖，启用系统 timer；不自动重启" || return 0
            system_enable_auto_security_updates
            ;;
        2) system_update_auto_disable ;;
    esac
}

# Deliberately narrow first implementation. Complex hosts stay on the official
# manual path instead of being force-converted by a blind suite replacement.
system_update_major_preflight() {
    local ARCH HELD FOREIGN PREF FREE PATH_CHECK STATUS META PACKAGE
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
    META=""
    for PACKAGE in "linux-image-$ARCH" "linux-image-cloud-$ARCH"; do
        STATUS=$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null || true)
        [ "$STATUS" != 'install ok installed' ] || META="$PACKAGE"
    done
    [ -n "$META" ] || { error "没有标准内核元包；自定义/厂商内核请人工升级"; return 1; }
    dpkg-query -S "/boot/vmlinuz-$(uname -r)" >/dev/null 2>&1 \
        || { error "当前运行内核无法追溯到 dpkg 软件包，请人工确认引导环境"; return 1; }
    for PATH_CHECK in / /var /boot; do
        [ -d "$PATH_CHECK" ] || continue
        FREE=$(df -Pk "$PATH_CHECK" | awk 'NR==2 {print $4}')
        [[ "$FREE" =~ ^[0-9]+$ ]] || return 1
        if { [ "$PATH_CHECK" = /boot ] && [ "$FREE" -lt 262144 ]; } || { [ "$PATH_CHECK" != /boot ] && [ "$FREE" -lt 2097152 ]; }; then
            error "$PATH_CHECK 空间不足（/ 与 /var 至少 2GiB，/boot 至少 256MiB）；实际需求仍由 APT 检查"; return 1
        fi
    done
    system_update_logged env LC_ALL=C apt-get -o APT::Update::Error-Mode=any update || return 1
    system_update_apt_origins_guard bookworm || return 1
    FOREIGN=$(LC_ALL=C apt list '?narrow(?installed,?not(?origin(Debian)))' 2>/dev/null) || return 1
    if printf '%s\n' "$FOREIGN" | grep -qE '^[^ /]+/'; then
        error "发现非 Debian 或仓库已不可追溯的软件包，需先人工处理：$FOREIGN"; return 1
    fi
    LC_ALL=C apt-get -s dist-upgrade > "$QUENCH_UPDATE_RUN/bookworm-plan.txt" 2>&1 || return 1
    if grep -Eq '^(Inst|Remv) ' "$QUENCH_UPDATE_RUN/bookworm-plan.txt"; then
        cat "$QUENCH_UPDATE_RUN/bookworm-plan.txt"
        error "请先完成 Debian 12 当前版本更新并检查重启需求，再执行跨版本升级"; return 1
    fi
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
    system_update_major_preflight || return 1
    local ANSWER TIMER
    confirm_change_preview "升级前必须由你确认" \
        "已创建可恢复的供应商磁盘快照及独立业务数据备份，控制台/救援系统确实可用" \
        "已核对 1Panel、Docker、数据库、代理及网站对 Debian 13 的兼容性" \
        "已有维护窗口；软件包配置问题需要人工选择，Quench 不自动重启" || return 0
    read -rp "输入 UPGRADE 12 TO 13 确认开始（其他输入取消）: " ANSWER || return 0
    [ "$ANSWER" = 'UPGRADE 12 TO 13' ] || { info "已取消"; return 0; }
    system_update_backup || return 1
    cp -p "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before" || return 1
    system_update_sources stage bookworm "$QUENCH_UPDATE_RUN/source-new" || return 1
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
            2) system_update_action current ;;
            3) system_update_action security ;;
            4) system_update_action packages ;;
            5) system_update_auto_menu ;;
            6) system_update_postcheck ;;
            7) system_update_clean_cache ;;
            8) system_update_action autoremove ;;
            f|F) system_update_action full ;;
            v|V) system_update_debian_major ;;
            0) return 0 ;;
            *) warn "无效选项"; continue ;;
        esac
        ui_pause
    done
}
