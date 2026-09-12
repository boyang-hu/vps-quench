# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════

f2b_config_file() {
    printf '%s\n' "${QUENCH_F2B_JAIL_LOCAL:-${F2B_JAIL_LOCAL:-/etc/fail2ban/jail.local}}"
}

f2b_advanced_file() { printf '%s/jail.d/90-quench-sshd.local\n' "$(dirname "$(f2b_config_file)")"; }
f2b_legacy_file() { printf '%s/jail.d/zz-vps-quench.local\n' "$(dirname "$(f2b_config_file)")"; }

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
    [[ "$INPUT" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
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

f2b_backend_detect() {
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
        echo systemd
    else
        echo auto
    fi
}

f2b_ensure_managed_config() {
    f2b_configure_shared "$1" "" preserve
}

# 只对候选副本做合并。保留 jail.local 中其他段落的原文；旧 Quench 文件只在
# 确认来源和结构后迁移。高级 bantime.* 独立存放，避免 1Panel v2.2.5 的
# HasPrefix("bantime") 把它们当作 bantime 编辑。第三方高优先级覆盖不擅自删除。
f2b_merge_shared_candidate() {
    local WORK="$1" PORTS="$2" BACKEND="$3"
    python3 - "$WORK" "$(dirname "$(f2b_config_file)")" "$PORTS" "$BACKEND" <<'PY'
import configparser, pathlib, re, sys
work, root = map(pathlib.Path, sys.argv[1:3])
ports, backend = sys.argv[3:]
basic = {'enabled', 'port', 'bantime', 'findtime', 'maxretry', 'banaction', 'logpath', 'ignoreip'}
marker = '# Managed by Quench: SSH advanced settings; base settings live in jail.local.'
def read(path):
    return path.read_text() if path.exists() else ''
def parse(text):
    cfg = configparser.ConfigParser(interpolation=None, strict=True, inline_comment_prefixes=(';', '#'))
    cfg.read_string(text)
    return cfg
def own(cfg, section):
    return dict(cfg.defaults() if section == 'DEFAULT' else cfg._sections.get(section, {}))
def advanced(key):
    return key.startswith('bantime.') or key.startswith('banaction_')
def section_parts(text):
    # Preserve all non-sshd blocks verbatim, including comments and INCLUDES.
    chunks = re.split(r'(?m)(?=^[ \t]*\[)', text)
    other, ssh = [], []
    for chunk in chunks:
        m = re.match(r'^[ \t]*\[([^]]+)\]', chunk)
        (ssh if m and m[1] == 'sshd' else other).append(chunk)
    return ''.join(other), ''.join(ssh)
try:
    base_text, old_text, adv_text = (read(work / x) for x in ('base', 'legacy', 'advanced'))
    base, old, adv = map(parse, (base_text, old_text, adv_text))
    if old_text:
        if '# Managed by Quench.' not in old_text.splitlines()[:1][0]:
            raise ValueError('旧 drop-in 没有 Quench 标记，拒绝接管')
        if set(old.sections()) - {'sshd'} or set(old.defaults()) - {'allowipv6'}:
            raise ValueError('旧 drop-in 包含额外 jail/全局配置，请人工迁移，原文件未改动')
    if adv_text and (not adv_text.startswith(marker + '\n') or set(adv.sections()) - {'sshd'} or adv.defaults()
                     or any(not advanced(k) for k in own(adv, 'sshd'))):
        raise ValueError('高级配置文件并非纯 Quench 高级参数，拒绝覆盖')
    for path in sorted((root / 'jail.d').glob('*.local')):
        if path.name in ('zz-vps-quench.local', '90-quench-sshd.local'):
            continue
        cfg = parse(path.read_text())
        conflicts = basic & (set(own(cfg, 'sshd')) | set(cfg.defaults()))
        if conflicts or cfg.has_section('INCLUDES'):
            raise ValueError('后加载配置可能覆盖面板参数：%s (%s)，请先人工合并' % (path, ','.join(sorted(conflicts))))
    if base.has_section('INCLUDES') and own(base, 'INCLUDES').get('after', '').strip():
        raise ValueError('jail.local 使用 INCLUDES after，需先核对后加载覆盖，拒绝自动迁移')
    values = own(base, 'sshd')
    values.update(own(adv, 'sshd'))
    values.update(own(old, 'sshd'))  # legacy was loaded after jail.local
    # Keep the distribution's existing action when no .local explicitly sets it.
    # In particular, merely having an inactive UFW installed must not select ufw.
    prior = configparser.ConfigParser(inline_comment_prefixes=(';', '#'))
    prior.read([str(root / 'jail.conf')] + [str(p) for p in sorted((root / 'jail.d').glob('*.conf'))])
    action = prior.get('sshd', 'banaction', fallback=prior.defaults().get('banaction', 'iptables-multiport'))
    for key, value in {'bantime': '3600', 'findtime': '600', 'maxretry': '5', 'backend': backend,
                       'mode': 'aggressive', 'banaction': action,
                       'bantime.increment': 'true', 'bantime.maxtime': '1w'}.items():
        values.setdefault(key, base.defaults().get(key, value))
    values.update(enabled='true', port=ports)
    if values['backend'] == 'systemd':
        values.setdefault('journalmatch', '_SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd')
        values['logpath'] = ''  # journal backend: do not display an unused auth.log
    else:
        values.setdefault('logpath', base.defaults().get('logpath', '%(sshd_log)s'))
    for key in ('bantime', 'findtime'):
        value = values[key]
        if re.fullmatch(r'-?\d+', value):
            continue
        m = re.fullmatch(r'(\d+)([smhdw])', value)
        if not m:
            raise ValueError('%s=%s 无法安全转成面板所需秒数，请先改成整数秒' % (key, value))
        values[key] = str(int(m[1]) * dict(s=1, m=60, h=3600, d=86400, w=604800)[m[2]])
    if not re.fullmatch(r'[1-9]\d*', values['maxretry']):
        raise ValueError('maxretry 必须是正整数')
    for key in basic:
        if key in values and ('\n' in values[key] or '%(' in values[key] and key != 'logpath'):
            raise ValueError('%s 使用多行/插值，需先人工转换为面板可编辑值' % key)
    # Keep unknown sshd settings/comments, normalize only the keys being managed.
    other, ssh = section_parts(base_text)
    lines, skipping = [], False
    for line in ssh.splitlines(keepends=True):
        if re.match(r'^\s*\[sshd\]', line):
            continue
        m = re.match(r'^\s*([^#;\s][^=:\s]*)\s*[=:]', line)
        if m:
            skipping = m[1].lower() in values
        elif skipping and line[:1].isspace() and line.strip() and not line.lstrip().startswith(('#', ';')):
            continue
        else:
            skipping = False
        if not skipping:
            lines.append(line)
    base_out = other.rstrip('\n') + '\n\n[sshd]\n' + ''.join(lines)
    if not base_out.endswith('\n'):
        base_out += '\n'
    for key, value in values.items():
        if not advanced(key):
            base_out += '%s = %s\n' % (key, value.replace('\n', '\n    '))
    adv_out = marker + '\n[sshd]\n'
    for key, value in values.items():
        if advanced(key):
            adv_out += '%s = %s\n' % (key, value.replace('\n', '\n    '))
    (work / 'base.new').write_text(base_out.lstrip('\n'))
    (work / 'advanced.new').write_text(adv_out)
except (OSError, ValueError, configparser.Error) as exc:
    print('Fail2ban 配置合并失败：%s' % exc, file=sys.stderr)
    sys.exit(1)
PY
}

# 不只检查配置文件里的一行：通过 Fail2ban 的合并配置确认高优先级文件没有
# 改写参数，再从运行中的 sshd jail/action 回读。此过程不执行封禁测试。
f2b_shared_effective_check() {
    local RUNNING="${1:-no}" TARGET DUMP PLAN KEY VALUE ACTUAL ACTION PORTS RC=0
    TARGET=$(f2b_config_file)
    DUMP=$(quench_mktemp) || return 1
    PLAN=$(quench_mktemp) || { rm -f "$DUMP"; return 1; }
    fail2ban-client -d > "$DUMP" 2>/dev/null || { rm -f "$DUMP" "$PLAN"; return 1; }
    if ! python3 - "$TARGET" "$DUMP" > "$PLAN" <<'PY'
import ast, configparser, sys
try:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(sys.argv[1])
    wanted = cfg['sshd']
    commands = [ast.literal_eval(x) for x in open(sys.argv[2]) if x.startswith('[')]
    settings, actions = {}, {}
    for c in commands:
        if len(c) >= 4 and c[:2] == ['set', 'sshd']:
            settings[c[2]] = c[3]
            if c[2] == 'addaction':
                actions.setdefault(c[3], {})
        if len(c) >= 5 and c[:3] == ['multi-set', 'sshd', 'action']:
            actions.setdefault(c[3], {}).update(dict(c[4]))
        if len(c) >= 6 and c[:3] == ['set', 'sshd', 'action']:
            actions.setdefault(c[3], {})[c[4]] = c[5]
    for key in ('bantime', 'findtime', 'maxretry'):
        if str(settings.get(key)) != wanted[key]:
            raise ValueError('合并后的 %s 与 jail.local 不一致' % key)
        print(key + '|' + wanted[key])
    ports = lambda p: set(str(p).replace(' ', '').split(','))
    if not actions:
        raise ValueError('sshd 没有封禁 action')
    for name, props in actions.items():
        # Standard command actions carry the jail port even for ufw/allports.
        # Custom Python/notification actions without port are not proof of SSH protection.
        if 'port' not in props:
            continue
        if ports(props['port']) != ports(wanted['port']):
            raise ValueError('action %s 的端口与 jail.local 不一致' % name)
        print('action|' + name)
    if not any('port' in props for props in actions.values()):
        raise ValueError('没有可核验端口的 action，需人工检查自定义封禁配置')
except (OSError, ValueError, KeyError, configparser.Error, SyntaxError) as exc:
    print('Fail2ban 生效检查失败：%s' % exc, file=sys.stderr)
    sys.exit(1)
PY
    then
        rm -f "$DUMP" "$PLAN"; return 1
    fi
    if [ "$RUNNING" = yes ]; then
        f2b_runtime_healthy || { rm -f "$DUMP" "$PLAN"; return 1; }
        PORTS=$(f2b_get_section_param sshd port "$TARGET" | tr -d '[:space:]')
        while IFS='|' read -r KEY VALUE; do
            if [ "$KEY" = action ]; then
                ACTION="$VALUE"
                ACTUAL=$(fail2ban-client get sshd action "$ACTION" port 2>/dev/null) \
                    || { RC=1; break; }
                [ "$(printf '%s' "$ACTUAL" | tr -d '[:space:]')" = "$PORTS" ] \
                    || { error "运行中 action $ACTION 的端口不一致"; RC=1; break; }
            else
                ACTUAL=$(fail2ban-client get sshd "$KEY" 2>/dev/null) \
                    || { RC=1; break; }
                [ "$ACTUAL" = "$VALUE" ] \
                    || { error "运行中 sshd jail 的 $KEY 不一致"; RC=1; break; }
            fi
        done < "$PLAN"
    fi
    rm -f "$DUMP" "$PLAN"
    return "$RC"
}

f2b_shared_restore() {
    local WORK="$1" TARGET="$2" ADVANCED="$3" LEGACY="$4" WAS_RUNNING="$5" NAME FILE RC=0
    for NAME in base advanced legacy; do
        case "$NAME" in base) FILE="$TARGET" ;; advanced) FILE="$ADVANCED" ;; legacy) FILE="$LEGACY" ;; esac
        if [ -f "$WORK/$NAME" ]; then
            atomic_restore_file "$WORK/$NAME" "$FILE" || RC=1
        else
            rm -f "$FILE" || RC=1
        fi
    done
    if [ "$RC" = 0 ] && [ -f "$WORK/service-attempted" ]; then
        if [ "$WAS_RUNNING" = running ]; then
            restart_fail2ban >/dev/null 2>&1 && f2b_runtime_healthy || RC=1
        else
            stop_fail2ban >/dev/null 2>&1 || RC=1
        fi
    fi
    [ "$RC" = 0 ] || error "恢复未确认，请保留并人工检查备份：$WORK"
    return "$RC"
}

f2b_configure_shared() {
    local RC
    txn_write_begin "同步 Fail2ban 共享 SSH 配置" || return 1
    f2b_configure_shared_locked "$@"
    RC=$?
    txn_write_end
    return "$RC"
}

f2b_configure_shared_locked() {
    local PORTS="$1" BACKEND="${2:-}" MODE="${3:-preserve}" TARGET ADVANCED LEGACY STATE WORK
    local NAME FILE WAS_RUNNING RESTORE_CMD
    f2b_ports_valid "$PORTS" || { error "无效 SSH 端口列表"; return 1; }
    command -v python3 >/dev/null 2>&1 || { error "Fail2ban 配置迁移/合并需要 python3，请先安装"; return 1; }
    TARGET=$(f2b_config_file); ADVANCED=$(f2b_advanced_file); LEGACY=$(f2b_legacy_file)
    STATE="${QUENCH_F2B_STATE_DIR:-$QUENCH_DATA_DIR/fail2ban}"
    f2b_require_no_pending || return 1
    for FILE in "$TARGET" "$ADVANCED" "$LEGACY"; do
        if [ -L "$FILE" ] || { [ -e "$FILE" ] && [ ! -f "$FILE" ]; }; then
            error "拒绝覆盖非普通配置文件：$FILE"; return 1
        fi
    done
    mkdir -p "$STATE" "$(dirname "$ADVANCED")" || return 1
    chmod 700 "$STATE" || return 1
    WORK=$(mktemp -d "$STATE/quench-config.XXXXXX") || return 1
    for NAME in base advanced legacy; do
        case "$NAME" in base) FILE="$TARGET" ;; advanced) FILE="$ADVANCED" ;; legacy) FILE="$LEGACY" ;; esac
        [ ! -f "$FILE" ] || cp -p "$FILE" "$WORK/$NAME" || return 1
    done
    [ -n "$BACKEND" ] || BACKEND=$(f2b_backend_detect)
    f2b_merge_shared_candidate "$WORK" "$PORTS" "$BACKEND" || return 1
    # 1Panel 不遵守 Quench 的锁；至少在落盘前发现确认/合并期间的外部修改。
    for NAME in base advanced legacy; do
        case "$NAME" in base) FILE="$TARGET" ;; advanced) FILE="$ADVANCED" ;; legacy) FILE="$LEGACY" ;; esac
        if [ -f "$WORK/$NAME" ]; then
            cmp -s "$WORK/$NAME" "$FILE" || { error "配置被外部修改，请重试：$FILE"; return 1; }
        else
            [ ! -e "$FILE" ] || { error "出现新的外部配置，请重试：$FILE"; return 1; }
        fi
    done
    WAS_RUNNING=$(f2b_status)
    printf '%s\n' "$WORK" > "$STATE/pending" || return 1
    printf -v RESTORE_CMD 'if f2b_shared_restore %q %q %q %q %q; then rm -f %q; fi' \
        "$WORK" "$TARGET" "$ADVANCED" "$LEGACY" "$WAS_RUNNING" "$STATE/pending"
    # 不登记为临时文件：失败、断电或被 kill -9 后，恢复材料必须跨会话保留。
    (
        # shellcheck disable=SC2064 # %q 已安全引用路径；立即固化参数，不能在函数局部变量失效后再展开。
        trap "$RESTORE_CMD" EXIT
        trap 'exit 1' INT TERM HUP
        atomic_replace_file "$WORK/base.new" "$TARGET" 0640 || exit 1
        atomic_replace_file "$WORK/advanced.new" "$ADVANCED" 0640 || exit 1
        rm -f "$LEGACY" || exit 1
        f2b_validate_config && f2b_shared_effective_check no || exit 1
        if [ "$WAS_RUNNING" = running ]; then
            : > "$WORK/service-attempted" || exit 1
            restart_fail2ban >/dev/null 2>&1 || exit 1
            f2b_shared_effective_check yes || exit 1
        elif [ "$MODE" = start ]; then
            : > "$WORK/service-attempted" || exit 1
            start_fail2ban >/dev/null 2>&1 || exit 1
            f2b_shared_effective_check yes || exit 1
        fi
        rm -f "$STATE/pending" || exit 1
        trap - EXIT INT TERM HUP
    ) || { error "Fail2ban 同步未完成；原配置备份：$WORK"; return 1; }
    info "Fail2ban 共享配置已验证：端口 ${PORTS}；备份：$WORK"
    [[ "$PORTS" != *,* ]] || warn "双端口保护已保留；1Panel 单整数端口框无法完整显示，请完成 SSH 迁移后刷新"
    return 0
}

f2b_panel_migrate() {
    local PORTS
    PORTS=$(ssh_effective_ports_csv)
    confirm_change_preview "同步 Fail2ban / 1Panel 配置" \
        "基础参数合并到 jail.local [sshd]，保留其他 jail/白名单" \
        "SSH 端口：${PORTS}；旧 Quench drop-in 将备份迁移" \
        "正在运行的 Fail2ban 会重启；请勿同时在 1Panel 编辑配置" || return 0
    f2b_configure_shared "$PORTS" "" preserve
}

f2b_require_no_pending() {
    local STATE="${QUENCH_F2B_STATE_DIR:-$QUENCH_DATA_DIR/fail2ban}"
    [ ! -e "$STATE/pending" ] || {
        error "存在未完成的 Fail2ban 配置事务，请先检查：$STATE/pending"
        return 1
    }
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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
f2b_install() {
    local RC
    txn_write_begin "安装 Fail2ban" || return 1
    f2b_install_locked
    RC=$?
    txn_write_end
    return "$RC"
}

f2b_install_locked() {
    f2b_require_no_pending || return 1
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

    local PORTS
    PORTS=$(ssh_effective_ports_csv)
    f2b_ports_valid "$PORTS" || { error "无法确定有效的 SSH 端口"; return 1; }
    f2b_configure_shared "$PORTS" "$BACKEND" start || return 1
    svc_enable fail2ban >/dev/null 2>&1 || true
    info "Fail2ban 安装并启动成功 ✓"
}

f2b_write_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE TMP
    JAIL_FILE=$(f2b_config_file)
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
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_FILE BACKUP EXISTED=no
    JAIL_FILE=$(f2b_config_file)
    mkdir -p "$(dirname "$JAIL_FILE")" || return 1
    # 恢复失败时不能被全局临时文件清理删掉；成功时由本函数显式删除。
    BACKUP=$(mktemp "$(dirname "$JAIL_FILE")/.quench-fail2ban-backup.XXXXXX") || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp -p "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
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
    mkdir -p "$(dirname "$JAIL_FILE")" || return 1
    BACKUP=$(mktemp "$(dirname "$JAIL_FILE")/.quench-fail2ban-backup.XXXXXX") || return 1
    if [ -f "$JAIL_FILE" ]; then
        cp -p "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
f2b_config_params() {
    local RC
    txn_write_begin "Fail2ban 参数" || return 1
    f2b_config_params_locked
    RC=$?
    txn_write_end
    return "$RC"
}

f2b_config_params_locked() {
    f2b_require_no_pending || return 1
    print_header "Fail2ban SSH 防护参数"
    if [ -f "$(f2b_legacy_file)" ]; then
        f2b_ensure_managed_config "$(ssh_effective_ports_csv)" || return 1
    fi
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
    BACKUP=$(mktemp "$(dirname "$JAIL_FILE")/.quench-fail2ban-backup.XXXXXX") || return 1
    cp -p "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    WAS_RUNNING=$(f2b_status)
    if { [ -z "$APPLY_BAN" ] || f2b_set_param bantime "$APPLY_BAN"; } \
        && { [ -z "$APPLY_FIND" ] || f2b_set_param findtime "$APPLY_FIND"; } \
        && { [ -z "$APPLY_MAX" ] || f2b_set_param maxretry "$APPLY_MAX"; } \
        && { [ -z "$APPLY_PORT" ] || f2b_set_param_jail port "$APPLY_PORT"; } \
        && f2b_shared_effective_check no; then
        :
    else
        if atomic_replace_file "$BACKUP" "$JAIL_FILE"; then
            rm -f "$BACKUP"
            error "参数写入失败，已恢复修改前配置"
        else
            error "参数写入失败，且恢复修改前配置也失败，备份已保留：$BACKUP"
            error "请立即手动执行：cp $BACKUP $JAIL_FILE"
        fi
        return 1
    fi

    if [ "$WAS_RUNNING" != running ]; then
        rm -f "$BACKUP"
        info "配置已保存；Fail2ban 当前未运行，因此未自动启动"
    elif restart_fail2ban && f2b_shared_effective_check yes; then
        rm -f "$BACKUP"
        info "Fail2ban 已重启 ✓"
    else
        if atomic_restore_file "$BACKUP" "$JAIL_FILE"; then
            if ! restart_fail2ban >/dev/null 2>&1 || ! f2b_runtime_healthy; then
                error "原配置已恢复，但服务恢复未确认；备份：$BACKUP"
                return 1
            fi
            rm -f "$BACKUP"
            error "Fail2ban 无法使用新参数运行，已恢复修改前配置"
        else
            error "恢复失败，请保留并人工检查备份：$BACKUP"
        fi
        return 1
    fi
}

# 统一写入入口：本文件写入的路径在回滚快照范围内，未确认的回滚到期会把它覆盖回去。见 txn_write_begin。
f2b_edit_config() {
    local RC
    txn_write_begin "编辑 Fail2ban 配置" || return 1
    f2b_edit_config_locked
    RC=$?
    txn_write_end
    return "$RC"
}

f2b_edit_config_locked() {
    f2b_require_no_pending || return 1
    print_header "编辑共享 Fail2ban 配置"
    if [ -f "$(f2b_legacy_file)" ]; then
        f2b_ensure_managed_config "$(ssh_effective_ports_csv)" || return 1
    fi
    local JAIL_FILE BACKUP RESTART
    JAIL_FILE=$(f2b_config_file)
    mkdir -p "$(dirname "$JAIL_FILE")"
    [ -f "$JAIL_FILE" ] || { warn "请先执行 Fail2ban 安装/修复"; return 1; }
    BACKUP=$(mktemp "$(dirname "$JAIL_FILE")/.quench-fail2ban-backup.XXXXXX") || return 1
    cp -p "$JAIL_FILE" "$BACKUP" || { rm -f "$BACKUP"; return 1; }
    warn "即将编辑 ${JAIL_FILE}；保存后会先验证，失败自动恢复"
    ui_continue
    open_editor "$JAIL_FILE"
    if ! f2b_validate_config || ! f2b_shared_effective_check no; then
        if atomic_restore_file "$BACKUP" "$JAIL_FILE"; then
            rm -f "$BACKUP"
            error "配置验证失败，已恢复编辑前版本"
        else
            error "恢复失败，请保留并人工检查备份：$BACKUP"
        fi
        return 1
    fi
    read -rp "  验证通过，是否重启 Fail2ban？(Y/n): " RESTART
    RESTART="${RESTART:-y}"
    if echo "$RESTART" | grep -qiE '^y(es)?$'; then
        if ! restart_fail2ban || ! f2b_shared_effective_check yes; then
            if atomic_restore_file "$BACKUP" "$JAIL_FILE"; then
                if ! restart_fail2ban >/dev/null 2>&1 || ! f2b_runtime_healthy; then
                    error "原配置已恢复，但服务恢复未确认；备份：$BACKUP"
                    return 1
                fi
                rm -f "$BACKUP"
                error "新配置无法启动服务，已恢复原配置"
            else
                error "恢复失败，请保留并人工检查备份：$BACKUP"
            fi
            return 1
        fi
        info "Fail2ban 已重启 ✓"
    fi
    rm -f "$BACKUP"
}

f2b_uninstall() {
    print_header "卸载 Fail2ban"
    local CONFIRM
    warn "卸载会停止动态封禁；默认保留所有配置，方便恢复"
    read -rp "  确认卸载？(y/N): " CONFIRM
    echo "$CONFIRM" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    stop_fail2ban >/dev/null 2>&1 || true
    svc_disable fail2ban >/dev/null 2>&1 || true
    pkg_remove fail2ban || { error "卸载失败"; return 1; }
    info "Fail2ban 已卸载，配置已保留 ✓"
    # jail.local 与面板/用户共享，卸载绝不能按旧的独占 drop-in 语义删除整份文件。
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
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
        [ ! -f "$(f2b_legacy_file)" ] || JAIL_FILE=$(f2b_legacy_file)
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
        menu_pair "5" "编辑共享配置" "6" "卸载 Fail2ban" "$GREEN" "$YELLOW"
        menu_item "u" "安装 / 修复 / 更新 Fail2ban" "$CYAN"
        menu_item "p" "同步 / 迁移 1Panel 共享配置" "$CYAN"
        # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
        [ "$F2B_ST" = running ] && menu_item "7" "停止服务" "$YELLOW" || menu_item "7" "启动服务"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        box_bot
        read -rp "$(ui_prompt '选择操作 [0-7 / u / p]: ')" CHOICE
        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            u|U) f2b_install ;;
            p|P) f2b_panel_migrate ;;
            7)
                if [ "$F2B_ST" = running ]; then
                    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
                    stop_fail2ban && info "Fail2ban 已停止" || error "停止失败"
                else
                    # shellcheck disable=SC2015 # 已逐条确认：|| 分支只在前面的命令失败时清理/兜底
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
