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
    seen=$(mktemp "${TMPDIR:-/tmp}/quench-nft-ids.XXXXXX") || return 1
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
    batch=$(mktemp "${TMPDIR:-/tmp}/quench-nft-batch.XXXXXX") || return 1
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
    batch=$(mktemp "${TMPDIR:-/tmp}/quench-nft-check.XXXXXX") || return 1
    nft_build_apply_batch "$config" "$batch" || { rm -f "$batch"; return 1; }
    nft -c -f "$batch"
    local rc=$?
    rm -f "$batch"
    return "$rc"
}

nft_write_managed_file() {
    local candidate backup existed=no
    candidate=$(mktemp "${TMPDIR:-/tmp}/quench-nft-config.XXXXXX") || return 1
    backup=$(mktemp "${TMPDIR:-/tmp}/quench-nft-backup.XXXXXX") || { rm -f "$candidate"; return 1; }
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-helper.XXXXXX") || return 1
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
        tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-service.XXXXXX") || return 1
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
        tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-openrc.XXXXXX") || return 1
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-sysctl.XXXXXX") || return 1
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-sysctl-file.XXXXXX") || return 1
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
    retry=$(mktemp "${TMPDIR:-/tmp}/quench-nft-fw-retry.XXXXXX") || return 1
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
    desired=$(mktemp "${TMPDIR:-/tmp}/quench-nft-fw-desired.XXXXXX") || return 1
    new_state=$(mktemp "${TMPDIR:-/tmp}/quench-nft-fw-state.XXXXXX") || { rm -f "$desired"; return 1; }
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-acl.XXXXXX") || return 1
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-rules.XXXXXX") || return 1
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-access-db.XXXXXX") || return 1
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-refresh.XXXXXX") || { nft_lock_release; return 1; }
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
    tmp=$(mktemp "${TMPDIR:-/tmp}/quench-nft-refresh-service.XXXXXX") || return 1
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
    rules_backup=$(mktemp); access_backup=$(mktemp)
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
