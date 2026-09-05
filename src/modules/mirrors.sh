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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
mirror_apply_apt() {
    local RC
    txn_write_begin "切换 APT 软件源" || return 1
    mirror_apply_apt_locked "$@"
    RC=$?
    txn_write_end
    return "$RC"
}

mirror_apply_apt_locked() {
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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
mirror_restore_apt() {
    local RC
    txn_write_begin "恢复 APT 软件源" || return 1
    mirror_restore_apt_locked
    RC=$?
    txn_write_end
    return "$RC"
}

mirror_restore_apt_locked() {
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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
mirror_apply_rpm() {
    local RC
    txn_write_begin "切换 RPM 软件源" || return 1
    mirror_apply_rpm_locked "$@"
    RC=$?
    txn_write_end
    return "$RC"
}

mirror_apply_rpm_locked() {
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
        RC=$?
        if [ "$RC" -eq 2 ]; then
            warn "缺少 curl/wget，跳过 HTTP 预检"
        else
            error "候选 RPM 仓库不可访问"
            return 1
        fi
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

# 统一写入入口：取锁、核对遗留事务、拒绝在未确认回滚期间修改。见 txn_write_begin。
mirror_restore_rpm() {
    local RC
    txn_write_begin "恢复 RPM 软件源" || return 1
    mirror_restore_rpm_locked
    RC=$?
    txn_write_end
    return "$RC"
}

mirror_restore_rpm_locked() {
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
