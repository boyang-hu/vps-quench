#!/usr/bin/env bash
# No root, network access, package installation or real /etc writes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUENCH_TEST_TEMP_BASE="${TMPDIR:-/tmp}"
QUENCH_TEST_UPDATES_ROOT=$(mktemp -d "${QUENCH_TEST_TEMP_BASE%/}/quench-test-updates.XXXXXX")
trap 'rm -rf "$QUENCH_TEST_UPDATES_ROOT"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
source "$ROOT/tests/lib/harness.sh"
QUENCH_TEST_REAL_POSTCHECK=$(declare -f system_update_postcheck)

setup_update() {
    QUENCH_TEST_UPDATE_CASE="$QUENCH_TEST_UPDATES_ROOT/$1"
    mkdir -p "$QUENCH_TEST_UPDATE_CASE/apt/sources.list.d" "$QUENCH_TEST_UPDATE_CASE/state"
    QUENCH_UPDATE_APT_DIR="$QUENCH_TEST_UPDATE_CASE/apt"
    QUENCH_UPDATE_STATE_DIR="$QUENCH_TEST_UPDATE_CASE/state"
    QUENCH_UPDATE_RUN="$QUENCH_TEST_UPDATE_CASE/run"
    mkdir -p "$QUENCH_UPDATE_RUN"
    QUENCH_UPDATE_OS_FILE="$QUENCH_TEST_UPDATE_CASE/os-release"
    printf '%s\n' 'ID=debian' 'VERSION_ID="12"' 'VERSION_CODENAME=bookworm' > "$QUENCH_UPDATE_OS_FILE"
    printf '%s\n' 'deb https://deb.debian.org/debian bookworm main' \
        'deb https://deb.debian.org/debian bookworm-updates main' \
        'deb https://security.debian.org/debian-security bookworm-security main' > "$QUENCH_UPDATE_APT_DIR/sources.list"
    : > "$QUENCH_TEST_UPDATE_CASE/calls"
    : > "$QUENCH_TEST_UPDATE_CASE/audit"
    txn_write_begin() { echo lock >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    txn_write_end() { echo unlock >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    system_package_manager() { echo apt; }
    system_update_session_ready() { :; }
    systemd_available() { return 1; }
    system_update_backup() { echo backup >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    system_update_postcheck() { [ ! -e "$QUENCH_TEST_UPDATE_CASE/post-fail" ]; }
    system_update_reboot_required() { return 1; }
    system_update_apt_health() { [ ! -e "$QUENCH_TEST_UPDATE_CASE/broken" ]; }
    audit_action() { printf '%s %s\n' "$2" "$1" >> "$QUENCH_TEST_UPDATE_CASE/audit"; }
    confirm_change_preview() { [ ! -e "$QUENCH_TEST_UPDATE_CASE/cancel" ]; }
    # env shim executes shell fixtures, never host commands with elevated rights.
    env() { while [[ "${1:-}" == *=* ]]; do shift; done; "$@"; }
    apt-config() {
        printf '%s\n' 'Dir "/";' 'Dir::Etc "etc/apt";' \
            'Dir::Etc::sourcelist "sources.list";' 'Dir::Etc::sourceparts "sources.list.d";' \
            'Unattended-Upgrade::Automatic-Reboot "true";'
    }
    apt-cache() { echo ' release o=Debian,n=bookworm,l=Debian'; }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [[ " $* " == *' update '* ]]; then
            [ ! -e "$QUENCH_TEST_UPDATE_CASE/refresh-fail" ]; return $?
        fi
        if [[ " $* " == *' -s '* ]]; then
            [ ! -e "$QUENCH_TEST_UPDATE_CASE/sim-fail" ] || return 10
            if [ -f "$QUENCH_TEST_UPDATE_CASE/plan" ]; then cat "$QUENCH_TEST_UPDATE_CASE/plan"
            else echo 'Inst curl [7.1] (7.2 Debian:12.0/bookworm [amd64])'; fi
            return 0
        fi
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/apply-fail" ] || return 100
    }
    dpkg-query() { echo 'install ok installed'; }
    unattended-upgrade() { echo "unattended-upgrade $*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
}

t_source_check() {
    setup_update "source_$1"
    case "$1" in
        list) : ;;
        tabs) printf 'deb\thttps://deb.debian.org/debian\tbookworm\tmain\ndeb\thttps://deb.debian.org/debian-security\tbookworm-security\tmain\n' > "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        options) printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm main' 'deb https://deb.debian.org/debian-security bookworm-security main' > "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        deb822)
            : > "$QUENCH_UPDATE_APT_DIR/sources.list"
            printf '%s\n' 'Types: deb deb-src' 'URIs: https://deb.debian.org/debian' 'Suites: bookworm' ' bookworm-updates' 'Components: main contrib' '' \
                'Types: deb' 'URIs: https://deb.debian.org/debian-security' 'Suites: bookworm-security' 'Components: main' '' \
                'Enabled: no' 'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: sid' 'Components: main' > "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources"
            ;;
        trixie)
            printf '%s\n' 'ID=debian' 'VERSION_ID=13' 'VERSION_CODENAME=trixie' > "$QUENCH_UPDATE_OS_FILE"
            sed 's/bookworm/trixie/g' "$QUENCH_UPDATE_APT_DIR/sources.list" > "$QUENCH_TEST_UPDATE_CASE/new"
            cp "$QUENCH_TEST_UPDATE_CASE/new" "$QUENCH_UPDATE_APT_DIR/sources.list"
            ;;
    esac
    assert_ok system_update_sources check "$(system_update_debian_code)"
    :
}
for FORM in list tabs options deb822 trixie; do run_test "APT source parser accepts $FORM" t_source_check "$FORM"; done

t_bad_source() {
    setup_update "bad_$1"
    case "$1" in
        stable|oldstable|sid|trixie|buster|forky)
            printf 'deb https://deb.debian.org/debian %s main\n' "$1" >> "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        unsigned) echo 'deb [trusted=yes] https://deb.debian.org/debian bookworm main' >> "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        missing_security) echo 'deb https://deb.debian.org/debian bookworm main' > "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        malformed) echo 'nonsense' > "$QUENCH_UPDATE_APT_DIR/sources.list.d/bad.list" ;;
        deb822_duplicate) printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm\nSuites: sid\nComponents: main\n' > "$QUENCH_UPDATE_APT_DIR/sources.list.d/bad.sources" ;;
        symlink) ln -s "$QUENCH_UPDATE_APT_DIR/sources.list" "$QUENCH_UPDATE_APT_DIR/sources.list.d/link.list" ;;
    esac
    assert_fail system_update_sources check bookworm
    :
}
for BAD in stable oldstable sid trixie buster forky unsigned missing_security malformed deb822_duplicate symlink; do run_test "Source guard rejects $BAD" t_bad_source "$BAD"; done

t_major_source() {
    setup_update major_source
    assert_eq "$(system_update_sources major bookworm)" "$QUENCH_UPDATE_APT_DIR/sources.list"
    cp "$QUENCH_UPDATE_APT_DIR/sources.list" "$QUENCH_TEST_UPDATE_CASE/before"
    assert_ok system_update_sources stage bookworm "$QUENCH_TEST_UPDATE_CASE/stage"
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/stage" 'trixie-security'
    assert_ok cmp "$QUENCH_UPDATE_APT_DIR/sources.list" "$QUENCH_TEST_UPDATE_CASE/before"
    echo 'deb https://download.docker.com/linux/debian bookworm stable' > "$QUENCH_UPDATE_APT_DIR/sources.list.d/docker.list"
    assert_ok system_update_sources check bookworm
    assert_fail system_update_sources major bookworm
    :
}
run_test 'Major source staging does not change live files and refuses third-party takeover' t_major_source

# Reproduce common Debian cloud images, including a mixed-suite deb822 stanza.
setup_cloud_source() {
    mkdir -p "$QUENCH_UPDATE_APT_DIR/mirrors"
    printf '# Debian mirrors\nhttps://deb.debian.org/debian\nhttp://deb.debian.org/debian/\n' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list"
    echo 'https://security.debian.org/debian-security' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian-security.list"
    : > "$QUENCH_UPDATE_APT_DIR/sources.list"
    printf '%s\n' '# bookworm stays in this comment' 'Types: deb deb-src' \
        'URIs: mirror+file:///etc/apt/mirrors/debian.list' 'Suites: bookworm' ' bookworm-updates bookworm-backports' \
        'Components: main contrib non-free-firmware' 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' '' \
        'Types: deb deb-src' 'URIs: mirror+file:/etc/apt/mirrors/debian-security.list' \
        'Suites: bookworm-security' 'Components: main' '' \
        'Enabled: no' 'Types: deb' 'URIs: https://example.org/debian' 'Suites: bookworm' 'Components: main' \
        > "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources"
}

t_cloud_source() {
    setup_update "cloud_$1"
    setup_cloud_source
    local SOURCE="$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources"
    case "$1" in
        direct_backports) sed 's|mirror+file:///etc/apt/mirrors/debian.list|https://deb.debian.org/debian|' "$SOURCE" > "$QUENCH_TEST_UPDATE_CASE/new"; cp "$QUENCH_TEST_UPDATE_CASE/new" "$SOURCE" ;;
        separate_stanza)
            printf '\nTypes: deb deb-src\nEnabled: yes\nURIs: https://deb.debian.org/debian\nSuites: bookworm-backports\nComponents: main\n' >> "$SOURCE" ;;
        list)
            : > "$SOURCE"
            SOURCE="$QUENCH_UPDATE_APT_DIR/sources.list"
            printf '%s\n' '# bookworm stays in this comment' \
                'deb [arch=amd64 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] mirror+file:///etc/apt/mirrors/debian.list bookworm main contrib non-free-firmware # bookworm comment' \
                'deb-src mirror+file:/etc/apt/mirrors/debian.list bookworm-updates main' \
                'deb https://deb.debian.org/debian bookworm-backports main' \
                'deb-src https://deb.debian.org/debian bookworm-backports main' \
                'deb mirror+file:///etc/apt/mirrors/debian-security.list bookworm-security main' > "$SOURCE" ;;
    esac
    cp "$SOURCE" "$QUENCH_TEST_UPDATE_CASE/before"
    assert_ok system_update_sources check bookworm
    assert_eq "$(system_update_sources major bookworm)" "$SOURCE"
    assert_ok system_update_sources stage bookworm "$QUENCH_TEST_UPDATE_CASE/candidate"
    assert_ok cmp "$SOURCE" "$QUENCH_TEST_UPDATE_CASE/before"
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" '# bookworm stays in this comment'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'trixie-updates'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'https://deb.debian.org/debian-security'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'contrib non-free-firmware'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" '/usr/share/keyrings/debian-archive-keyring.gpg'
    if [ "$1" = list ]; then
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'arch=amd64'
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" '# bookworm comment'
    else
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'Types: deb deb-src'
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'URIs: https://example.org/debian'
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/candidate" 'Suites: bookworm'
    fi
    cp "$QUENCH_TEST_UPDATE_CASE/candidate" "$SOURCE"
    # Disabled backports and third-party stanzas must stay disabled and unchanged.
    assert_ok system_update_sources major trixie
    :
}
for FORM in deb822 direct_backports separate_stanza list; do
    run_test "Cloud sources stage mirror lists/backports without touching live files: $FORM" t_cloud_source "$FORM"
done

t_bad_mirror() {
    setup_update "mirror_$1"
    setup_cloud_source
    case "$1" in
        empty) : > "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        missing) rm "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        symlink)
            mv "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" "$QUENCH_TEST_UPDATE_CASE/mirror"
            ln -s "$QUENCH_TEST_UPDATE_CASE/mirror" "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        parent_symlink)
            mv "$QUENCH_UPDATE_APT_DIR/mirrors" "$QUENCH_TEST_UPDATE_CASE/mirrors"
            ln -s "$QUENCH_TEST_UPDATE_CASE/mirrors" "$QUENCH_UPDATE_APT_DIR/mirrors" ;;
        third_party) echo 'https://example.org/debian' >> "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        mixed_archive) echo 'https://deb.debian.org/debian-security' >> "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        wrong_archive) echo 'https://deb.debian.org/debian-security' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        metadata) printf 'https://deb.debian.org/debian\tsuite:bookworm\n' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list" ;;
        remote|outside)
            local URI='mirror+https://example.org/mirrors'
            [ "$1" != outside ] || URI='mirror+file:///tmp/mirrors.list'
            printf '\nTypes: deb\nURIs: %s\nSuites: bookworm\nComponents: main\n' "$URI" >> "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources" ;;
    esac
    assert_fail system_update_sources major bookworm
    assert_fail system_update_sources stage bookworm "$QUENCH_TEST_UPDATE_CASE/candidate"
    [ ! -e "$QUENCH_TEST_UPDATE_CASE/candidate" ] || fail 'wrote an unsafe candidate'
    :
}
for BAD in empty missing symlink parent_symlink third_party mixed_archive wrong_archive metadata remote outside; do
    run_test "Unrecognized mirror lists fail before staging: $BAD" t_bad_mirror "$BAD"
done

t_backports_packages() {
    setup_update "backports_packages_$1"
    QUENCH_TEST_BACKPORTS="$1"
    dpkg-query() {
        case "$QUENCH_TEST_BACKPORTS" in
            installed) printf 'ii \tlinux-image-6.12.1-cloud-amd64\t6.12.1-1~bpo12+1\n' ;;
            removed) printf 'rc \told-package\t1.0~bpo12+1\n' ;;
            plain) printf 'ii \tcurl\t7.88.1-10+deb12u1\n' ;;
            failed) return 2 ;;
        esac
    }
    case "$1" in
        installed|failed) assert_fail system_update_backports_guard ;;
        *) assert_ok system_update_backports_guard ;;
    esac
    :
}
for CASE in installed removed plain failed; do run_test "Backports package guard: $CASE" t_backports_packages "$CASE"; done

t_retired_kernel() {
    setup_update "retired_$1"
    QUENCH_TEST_KERNEL_CASE="$1"
    uname() { echo 6.1.0-53-cloud-amd64; }
    apt() {
        case "$QUENCH_TEST_KERNEL_CASE" in
            current) echo 'linux-image-6.1.0-53-cloud-amd64/now 6.1.200-1 amd64 [installed,local]' ;;
            newer) echo 'linux-image-6.1.0-54-cloud-amd64/now 6.1.201-1 amd64 [installed,local]' ;;
            meta) echo 'linux-image-cloud-amd64/now 6.1.170-1 amd64 [installed,local]' ;;
            custom_name) echo 'linux-image-6.1.0-custom/now 6.1.170-1 amd64 [installed,local]' ;;
            apt_fail) return 100 ;;
            *) echo 'linux-image-6.1.0-45-cloud-amd64/now 6.1.170-1 amd64 [installed,local]' ;;
        esac
        if [ "$QUENCH_TEST_KERNEL_CASE" = mixed ]; then echo 'vendor/now 1.0 amd64 [installed,local]'; fi
        if [ "$QUENCH_TEST_KERNEL_CASE" = missing_current ]; then echo 'linux-image-6.1.0-53-cloud-amd64/now 6.1.200-1 amd64 [installed,local]'; fi
        return 0
    }
    dpkg-query() {
        local VERSION=6.1.170-1 SOURCE=linux MAINTAINER='Debian Kernel Team <debian-kernel@lists.debian.org>' STATUS='install ok installed'
        case "$*" in *linux-image-6.1.0-53-cloud-amd64) VERSION=6.1.200-1 ;; *linux-image-6.1.0-54-cloud-amd64) VERSION=6.1.201-1 ;; esac
        case "$QUENCH_TEST_KERNEL_CASE" in
            vendor) MAINTAINER='Vendor' ;;
            custom_source) SOURCE=custom-linux ;;
            custom_version) VERSION=6.1.170-1+custom ;;
            removed) STATUS='deinstall ok config-files' ;;
            query_fail) return 1 ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$STATUS" "$SOURCE" "$VERSION" "$MAINTAINER"
    }
    dpkg() {
        [ "$QUENCH_TEST_KERNEL_CASE" != compare_fail ] || return 2
        [ "$*" = '--compare-versions 6.1.170-1 lt 6.1.200-1' ]
    }
    if [ "$1" = old ]; then
        assert_ok system_update_foreign_guard
    else
        assert_fail system_update_foreign_guard
    fi
    [ ! -s "$QUENCH_TEST_UPDATE_CASE/calls" ] || fail 'kernel classification changed packages'
    :
}
for CASE in old current newer meta custom_name vendor custom_source custom_version removed query_fail compare_fail apt_fail mixed missing_current; do
    run_test "Unindexed kernel classification preserves fallback without blanket exemptions: $CASE" t_retired_kernel "$CASE"
done

t_apt_layout() {
    setup_update layout
    assert_ok system_update_apt_layout_guard
    APT_CONFIG=/tmp/custom
    assert_fail system_update_apt_layout_guard
    unset APT_CONFIG
    apt-config() { echo 'Dir::Etc::sourceparts "/custom";'; }
    assert_fail system_update_apt_layout_guard
    apt-config() { echo 'APT::Get::AllowUnauthenticated "true";'; }
    assert_fail system_update_apt_layout_guard
    apt-cache() { echo ' release o=Debian,n=trixie,l=Debian'; }
    assert_fail system_update_apt_origins_guard bookworm
    :
}
run_test 'Custom APT paths/environment and mismatching Release metadata cannot bypass guard' t_apt_layout

t_update_success() {
    setup_update success
    assert_ok system_update_action current
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove --with-new-pkgs upgrade'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" backup
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" 'SUCCESS'
    ! grep -Eq 'dist-upgrade|-y|force-conf|reboot' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unsafe implicit operation'
    assert_eq "$(tail -1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
    :
}
run_test 'Current-release update previews, backs up, never removes packages or auto-confirms' t_update_success

t_update_failure() {
    setup_update "failure_$1"
    : > "$QUENCH_TEST_UPDATE_CASE/$1"
    assert_fail system_update_action current
    ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'failure audited as success'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" FAILED
    if [ "$1" = refresh-fail ] || [ "$1" = sim-fail ] || [ "$1" = broken ]; then
        ! grep -q backup "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'apply reached after failed preflight'
    fi
    assert_eq "$(tail -1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
    :
}
for POINT in refresh-fail sim-fail apply-fail post-fail broken; do run_test "Update failure at $POINT is not success and releases lock" t_update_failure "$POINT"; done

t_cancel() {
    setup_update cancel
    : > "$QUENCH_TEST_UPDATE_CASE/cancel"
    assert_ok system_update_action current
    ! grep -q backup "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'canceled update applied'
    ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'cancel audited as success'
    :
}
run_test 'Declining preview never installs packages' t_cancel

t_critical_removal() {
    setup_update removal
    echo 'Remv openssh-server [9.2]' > "$QUENCH_TEST_UPDATE_CASE/plan"
    assert_fail system_update_action full
    ! grep -q backup "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'critical removal reached apply'
    :
}
run_test 'Full update refuses remote-access package deletion' t_critical_removal

t_selected() {
    setup_update "selected_$1"
    if [ "$1" = valid ]; then
        assert_ok system_update_action packages <<< 'curl openssh-client:amd64'
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove --only-upgrade install curl openssh-client:amd64'
    else
        assert_fail system_update_action packages <<< "$1"
        ! grep -q backup "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'invalid package reached apply'
    fi
    :
}
for PKG in valid --allow-unauthenticated curl- 'curl=1' 'curl/sid' 'curl;reboot' 'curl*'; do run_test "Selected package validation: $PKG" t_selected "$PKG"; done

t_cache() {
    setup_update cache
    assert_ok system_update_clean_cache
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'apt-get clean'
    ! grep -q autoremove "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'cache cleanup removed packages'
    :
}
run_test 'Cache cleanup does not uninstall packages' t_cache

t_security() {
    setup_update security
    assert_ok system_update_action security
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'unattended-upgrade --dry-run --debug'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'unattended-upgrade --verbose'
    local CONF
    CONF=$(find "$QUENCH_UPDATE_STATE_DIR" -name security.conf)
    assert_file_contains "$CONF" 'codename=bookworm-security'
    assert_file_contains "$CONF" '#clear Unattended-Upgrade::Allowed-Origins;'
    assert_file_contains "$CONF" 'Dir::Etc::parts "-";'
    assert_file_contains "$CONF" 'Unattended-Upgrade::Automatic-Reboot "false";'
    :
}
run_test 'Manual security update uses isolated restricted origins and disables reboot/removal' t_security

t_auto_effective() {
    setup_update "effective_$1"
    QUENCH_TEST_POLICY_VARIANT="$1"
    apt-config() {
        printf '%s\n' 'APT::Periodic::Unattended-Upgrade "1";' \
            'APT::Periodic::Update-Package-Lists "1";' \
            'Unattended-Upgrade::Remove-Unused-Dependencies "false";' \
            'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";' \
            'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";' \
            'Unattended-Upgrade::Automatic-Reboot "false";' \
            'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
        case "$QUENCH_TEST_POLICY_VARIANT" in
            broad) echo 'Unattended-Upgrade::Allowed-Origins:: "Debian:stable";' ;;
            reboot) echo 'Unattended-Upgrade::Automatic-Reboot "true";' ;;
            global_off) echo 'APT::Periodic::Enable "0";' ;;
            refresh_off) echo 'APT::Periodic::Update-Package-Lists "0";' ;;
            remove_kernel) echo 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' ;;
        esac
    }
    if [ "$1" = valid ]; then assert_ok system_update_auto_policy_verify
    else assert_fail system_update_auto_policy_verify; fi
    :
}
for POLICY in valid broad reboot global_off refresh_off remove_kernel; do run_test "Effective automatic-update policy: $POLICY" t_auto_effective "$POLICY"; done

t_auto_templates_scan() {
    setup_update "templates_scan_$1"
    local PARTS="$QUENCH_UPDATE_APT_DIR/apt.conf.d" FILE OUT
    mkdir -p "$PARTS"
    FILE="$PARTS/99zz-ppflight-no-auto-upgrades"
    printf '%s\n' '// image policy' 'APT::Periodic::Enable "0";' \
        'APT::Periodic::Update-Package-Lists "0";' 'APT::Periodic::Download-Upgradeable-Packages "0";' \
        'APT::Periodic::Unattended-Upgrade "0";' 'Unattended-Upgrade::Automatic-Reboot "false";' > "$FILE"
    case "$1" in
        vendor) : ;;
        multiple)
            cp "$FILE" "$PARTS/80-image.conf"
            cp "$FILE" "$QUENCH_UPDATE_APT_DIR/apt.conf" ;;
        comments)
            printf '%s\n' '' '  // APT::Get::AllowUnauthenticated "true";' \
                '  APT::Periodic::AutocleanInterval "0"; // no cleanup' >> "$FILE" ;;
        no_reboot_only) echo 'Unattended-Upgrade::Automatic-Reboot "false";' > "$FILE" ;;
        optional_only) printf '%s\n' 'APT::Periodic::Download-Upgradeable-Packages "0";' 'APT::Periodic::AutocleanInterval "0";' > "$FILE" ;;
        mixed) echo 'Acquire::http::Proxy "http://example.invalid:8080";' >> "$FILE" ;;
        hook) echo 'DPkg::Post-Invoke { "echo keep"; };' >> "$FILE" ;;
        include) echo '#include "/etc/apt/other.conf";' >> "$FILE" ;;
        clear) echo '#clear APT::Periodic;' >> "$FILE" ;;
        reboot_true) echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "$FILE" ;;
        enable_true) echo 'APT::Periodic::Enable "1";' >> "$FILE" ;;
        nested) printf '%s\n' 'APT::Periodic { Enable "0"; };' > "$FILE" ;;
        ignored)
            mv "$FILE" "$FILE.disabled"
            cp "$FILE.disabled" "$PARTS/.hidden"
            cp "$FILE.disabled" "$PARTS/name with spaces" ;;
        managed)
            mv "$FILE" "$PARTS/20auto-upgrades"
            cp "$PARTS/20auto-upgrades" "$PARTS/52quench-unattended-upgrades" ;;
        symlink)
            mv "$FILE" "$QUENCH_TEST_UPDATE_CASE/external"
            ln -s "$QUENCH_TEST_UPDATE_CASE/external" "$FILE" ;;
        linked_dir)
            mv "$PARTS" "$QUENCH_TEST_UPDATE_CASE/parts"
            ln -s "$QUENCH_TEST_UPDATE_CASE/parts" "$PARTS" ;;
    esac
    case "$1" in
        mixed|hook|include|clear|reboot_true|enable_true|linked_dir)
            assert_fail system_update_auto_templates_scan ;;
        *)
            OUT=$(system_update_auto_templates_scan) || fail 'scan failed'
            case "$1" in
                vendor|comments) assert_eq "$OUT" 'apt.conf.d/99zz-ppflight-no-auto-upgrades' ;;
                multiple) assert_eq "$OUT" $'apt.conf.d/80-image.conf\napt.conf.d/99zz-ppflight-no-auto-upgrades\napt.conf' ;;
                *) assert_eq "$OUT" '' ;;
            esac ;;
    esac
    :
}
for CASE in vendor multiple comments no_reboot_only optional_only mixed hook include clear reboot_true enable_true nested ignored managed symlink linked_dir; do
    run_test "Automatic update template discovery: $CASE" t_auto_templates_scan "$CASE"
done

t_auto_candidate_staging() {
    setup_update "candidate_staging_$1"
    local PARTS="$QUENCH_UPDATE_APT_DIR/apt.conf.d" PLAN="$QUENCH_TEST_UPDATE_CASE/templates.list" STAGE="$QUENCH_TEST_UPDATE_CASE/candidate"
    mkdir -p "$PARTS"
    echo 'APT::Periodic::Enable "0";' > "$PARTS/99zz-ppflight-no-auto-upgrades"
    echo 'APT::Periodic::Unattended-Upgrade "0";' > "$QUENCH_UPDATE_APT_DIR/apt.conf"
    echo 'Acquire::Retries "3";' > "$PARTS/99-network"
    cp -a "$QUENCH_UPDATE_APT_DIR" "$QUENCH_TEST_UPDATE_CASE/apt-before"
    system_update_auto_templates_scan > "$PLAN" || fail 'scan failed'
    # Test the real staging/file operations, not APT itself. Real precedence is
    # separately tested with apt-config in the disposable Debian CI containers.
    apt-config() { [ -f "$APT_CONFIG" ] || return 1; echo fixture; }
    system_update_auto_policy_verify() { echo verified >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    case "$1" in
        multiple) : ;;
        empty) : > "$PLAN" ;;
        missing) rm "$PLAN" ;;
        traversal) echo 'apt.conf.d/../../apt.conf' > "$PLAN" ;;
    esac
    case "$1" in
        missing|traversal)
            assert_fail system_update_auto_candidate_check "$STAGE" "$PLAN"
            ! grep -q verified "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'invalid plan reached verification' ;;
        *)
            assert_ok system_update_auto_candidate_check "$STAGE" "$PLAN"
            assert_ok cmp "$STAGE/parts/99-network" "$PARTS/99-network"
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" verified
            if [ "$1" = multiple ]; then
                [ ! -e "$STAGE/parts/99zz-ppflight-no-auto-upgrades" ] || fail 'staged template retained'
                [ ! -s "$STAGE/main" ] || fail 'staged main template retained'
            else
                assert_ok cmp "$STAGE/parts/99zz-ppflight-no-auto-upgrades" "$PARTS/99zz-ppflight-no-auto-upgrades"
                assert_ok cmp "$STAGE/main" "$QUENCH_UPDATE_APT_DIR/apt.conf"
            fi ;;
    esac
    assert_ok diff -r "$QUENCH_UPDATE_APT_DIR" "$QUENCH_TEST_UPDATE_CASE/apt-before"
    :
}
for CASE in multiple empty missing traversal; do
    run_test "Automatic update candidate staging: $CASE" t_auto_candidate_staging "$CASE"
done

t_auto_enable() {
    setup_update "auto_enable_$1"
    QUENCH_TEST_AUTO_CASE="$1"
    mkdir -p "$QUENCH_UPDATE_APT_DIR/apt.conf.d" "$QUENCH_TEST_UPDATE_CASE/units"
    local PARTS="$QUENCH_UPDATE_APT_DIR/apt.conf.d" UNIT STATE FILE RC=0
    printf '%s\n' 'APT::Periodic::Enable "0";' 'APT::Periodic::Update-Package-Lists "0";' \
        'APT::Periodic::Unattended-Upgrade "0";' 'APT::Periodic::Download-Upgradeable-Packages "0";' \
        'APT::Periodic::AutocleanInterval "0";' > "$PARTS/99-template-no-auto-upgrades"
    echo '// original periodic' > "$PARTS/20auto-upgrades"
    echo '// original quench policy' > "$PARTS/52quench-unattended-upgrades"
    for UNIT in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do
        case "$UNIT" in *.service) STATE=masked ;; *) STATE=disabled ;; esac
        [ "$1" != runtime ] || STATE=masked-runtime
        if [ "$1" = unmasked ]; then
            case "$UNIT" in apt-*.service) STATE=static ;; *) STATE=disabled ;; esac
        fi
        printf '%s\n' "$STATE" > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state"
        echo inactive > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active"
    done
    case "$1" in
        no_template) rm "$PARTS/99-template-no-auto-upgrades" ;;
        vendor)
            mv "$PARTS/99-template-no-auto-upgrades" "$PARTS/99zz-ppflight-no-auto-upgrades"
            echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> "$PARTS/99zz-ppflight-no-auto-upgrades" ;;
        multiple|multi_timer_fail|multi_remove_fail|multi_external_edit)
            cp "$PARTS/99-template-no-auto-upgrades" "$PARTS/99zz-ppflight-no-auto-upgrades"
            cp "$PARTS/99-template-no-auto-upgrades" "$QUENCH_UPDATE_APT_DIR/apt.conf" ;;
        missing_unit) echo not-found > "$QUENCH_TEST_UPDATE_CASE/units/unattended-upgrades.service.state" ;;
        new_files|write_fail) rm "$PARTS/20auto-upgrades" "$PARTS/52quench-unattended-upgrades" ;;
        extra_template) echo 'APT::Get::AllowUnauthenticated "true";' >> "$PARTS/99-template-no-auto-upgrades" ;;
        linked_template)
            mv "$PARTS/99-template-no-auto-upgrades" "$QUENCH_TEST_UPDATE_CASE/template"
            ln -s "$QUENCH_TEST_UPDATE_CASE/template" "$PARTS/99-template-no-auto-upgrades" ;;
        active_updater) echo active > "$QUENCH_TEST_UPDATE_CASE/units/apt-daily-upgrade.service.active" ;;
        existing_timers)
            for UNIT in apt-daily.timer apt-daily-upgrade.timer; do
                echo enabled > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state"
                echo active > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active"
            done ;;
    esac
    cp -a "$PARTS" "$QUENCH_TEST_UPDATE_CASE/parts-before"
    [ ! -f "$QUENCH_UPDATE_APT_DIR/apt.conf" ] || cp -p "$QUENCH_UPDATE_APT_DIR/apt.conf" "$QUENCH_TEST_UPDATE_CASE/main-before"
    cp -a "$QUENCH_TEST_UPDATE_CASE/units" "$QUENCH_TEST_UPDATE_CASE/units-before"
    systemd_available() { return 0; }
    # Never probe the runner's real dpkg locks from this service fixture.
    system_update_auto_workers_idle() {
        local WORKER
        for WORKER in apt-daily.service apt-daily-upgrade.service; do
            [ "$(cat "$QUENCH_TEST_UPDATE_CASE/units/$WORKER.active")" = inactive ] || return 1
        done
    }
    if [ "$1" = write_fail ]; then
        eval "$(declare -f atomic_replace_file | sed '1s/atomic_replace_file/quench_test_real_replace/')"
        atomic_replace_file() {
            case "$2" in */52quench-unattended-upgrades) return 1 ;; esac
            quench_test_real_replace "$@"
        }
    fi
    if [ "$1" = multi_remove_fail ]; then
        rm() {
            [ "$*" != "$QUENCH_UPDATE_APT_DIR/apt.conf" ] || return 1
            command rm "$@"
        }
    fi
    confirm_change_preview() {
        echo confirm >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [ "$QUENCH_TEST_AUTO_CASE" = cancel ]; then return 1; fi
        if [ "$QUENCH_TEST_AUTO_CASE" = template_edit ]; then echo '// external' >> "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"; fi
        if [ "$QUENCH_TEST_AUTO_CASE" = template_added ]; then echo 'APT::Periodic::Enable "0";' > "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-new-template"; fi
        if [ "$QUENCH_TEST_AUTO_CASE" = template_linked ]; then
            mv "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades" "$QUENCH_TEST_UPDATE_CASE/external"
            ln -s "$QUENCH_TEST_UPDATE_CASE/external" "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"
        fi
        return 0
    }
    system_update_auto_install_dependency() {
        echo install >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [ "$QUENCH_TEST_AUTO_CASE" = missing_unit ]; then echo disabled > "$QUENCH_TEST_UPDATE_CASE/units/unattended-upgrades.service.state"; fi
        if [ "$QUENCH_TEST_AUTO_CASE" = install_template_edit ]; then echo '// package change' >> "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"; fi
        [ "$QUENCH_TEST_AUTO_CASE" != install_fail ]
    }
    # Real APT precedence is covered by the Debian integration suite. Here use
    # deterministic service/package failures without accessing host systemd/APT.
    system_update_auto_candidate_check() {
        mkdir -p "$1/parts"
        system_update_auto_config_write "$1/parts/20auto-upgrades" "$1/parts/52quench-unattended-upgrades"
        echo candidate >> "$QUENCH_TEST_UPDATE_CASE/calls"
        case "$QUENCH_TEST_AUTO_CASE" in candidate_fail|linked_template) return 1 ;; esac
        return 0
    }
    apt-config() {
        printf '%s\n' 'APT::Periodic::Enable "1";' 'APT::Periodic::Update-Package-Lists "1";' \
            'APT::Periodic::Unattended-Upgrade "1";' 'Unattended-Upgrade::Automatic-Reboot "false";' \
            'Unattended-Upgrade::Remove-Unused-Dependencies "false";' \
            'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";' \
            'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";' \
            'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
        if [ "$QUENCH_TEST_AUTO_CASE" = policy_fail ]; then echo 'APT::Periodic::Enable "0";'; fi
        return 0
    }
    systemctl() {
        local OP="$1" UNIT PROP STATE MODE=persistent START=no
        shift
        printf 'systemctl %s %s\n' "$OP" "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [ "$OP" = show ]; then
            UNIT="$1"; PROP="$3"
            case "$PROP" in
                UnitFileState) cat "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state" ;;
                ActiveState) cat "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active" ;;
                LoadState)
                    STATE=$(cat "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state")
                    case "$STATE" in masked*) echo masked ;; not-found) echo not-found; return 1 ;; *) echo loaded ;; esac ;;
            esac
            return 0
        fi
        for UNIT in "$@"; do
            case "$UNIT" in
                --runtime) MODE=runtime; continue ;;
                --now) START=yes; continue ;;
                --quiet) continue ;;
            esac
            STATE=$(cat "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state")
            case "$OP" in
                is-enabled) [ "$STATE" = enabled ] || [ "$STATE" = enabled-runtime ] || return 1 ;;
                is-active) [ "$(cat "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active")" = active ] || return 1 ;;
                stop) echo inactive > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active" ;;
                mask) if [ "$MODE" = runtime ]; then echo masked-runtime; else echo masked; fi > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state" ;;
                unmask)
                    if [ "$QUENCH_TEST_AUTO_CASE" = unmask_fail ] && [ "$UNIT" = apt-daily-upgrade.service ]; then return 1; fi
                    echo disabled > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state" ;;
                disable) echo disabled > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state" ;;
                enable)
                    if [ "$MODE" = runtime ]; then echo enabled-runtime; else echo enabled; fi > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.state"
                    [ "$START" != yes ] || echo active > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active" ;;
                start)
                    if [ "$UNIT" = apt-daily-upgrade.timer ] && [ ! -e "$QUENCH_TEST_UPDATE_CASE/failure-fired" ]; then
                        case "$QUENCH_TEST_AUTO_CASE" in
                            timer_fail|existing_timers|external_edit|busy|multi_timer_fail|multi_external_edit)
                                : > "$QUENCH_TEST_UPDATE_CASE/failure-fired"
                                if [ "$QUENCH_TEST_AUTO_CASE" = external_edit ]; then echo '// external change' > "$QUENCH_UPDATE_APT_DIR/apt.conf.d/52quench-unattended-upgrades"; fi
                                if [ "$QUENCH_TEST_AUTO_CASE" = busy ]; then echo active > "$QUENCH_TEST_UPDATE_CASE/units/apt-daily-upgrade.service.active"; fi
                                if [ "$QUENCH_TEST_AUTO_CASE" = multi_external_edit ]; then echo '// external replacement' > "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99zz-ppflight-no-auto-upgrades"; fi
                                return 1 ;;
                        esac
                    fi
                    echo active > "$QUENCH_TEST_UPDATE_CASE/units/$UNIT.active" ;;
            esac
        done
        return 0
    }
    # The transaction runs in a subshell; resolve its one private run directory
    # instead of relying on QUENCH_UPDATE_RUN leaking back into this fixture.
    system_enable_auto_security_updates || RC=$?
    for FILE in "$QUENCH_UPDATE_STATE_DIR"/run-*; do
        [ ! -d "$FILE" ] || QUENCH_UPDATE_RUN="$FILE"
    done
    case "$1" in
        success|runtime|unmasked|no_template|new_files|missing_unit|vendor|multiple)
            assert_eq "$RC" 0
            assert_file_contains "$PARTS/20auto-upgrades" 'APT::Periodic::Enable "1";'
            [ ! -e "$PARTS/99-template-no-auto-upgrades" ] || fail 'template still effective'
            [ ! -e "$PARTS/99zz-ppflight-no-auto-upgrades" ] || fail 'vendor template still effective'
            [ ! -e "$QUENCH_UPDATE_APT_DIR/apt.conf" ] || fail 'pure main template still effective'
            for FILE in "$QUENCH_TEST_UPDATE_CASE/parts-before/"*; do
                case "${FILE##*/}" in 20auto-upgrades|52quench-unattended-upgrades) continue ;; esac
                assert_ok cmp "$FILE" "$QUENCH_UPDATE_RUN/templates-before/apt.conf.d/${FILE##*/}"
            done
            if [ -f "$QUENCH_TEST_UPDATE_CASE/main-before" ]; then
                assert_ok cmp "$QUENCH_TEST_UPDATE_CASE/main-before" "$QUENCH_UPDATE_RUN/templates-before/apt.conf"
            fi
            assert_ok system_update_auto_units_ready
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" SUCCESS
            ;;
        *)
            assert_ne "$RC" 0
            ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'failure logged as success'
            case "$1" in
                template_edit) assert_file_contains "$PARTS/99-template-no-auto-upgrades" '// external' ;;
                template_added) assert_file_contains "$PARTS/99-new-template" 'Enable "0";' ;;
                template_linked) [ -L "$PARTS/99-template-no-auto-upgrades" ] || fail 'external symlink removed' ;;
                install_template_edit)
                    assert_file_contains "$PARTS/99-template-no-auto-upgrades" '// package change'
                    assert_ok diff -r "$QUENCH_TEST_UPDATE_CASE/units" "$QUENCH_TEST_UPDATE_CASE/units-before" ;;
                multi_external_edit)
                    assert_file_contains "$PARTS/99zz-ppflight-no-auto-upgrades" '// external replacement'
                    assert_ok cmp "$PARTS/99-template-no-auto-upgrades" "$QUENCH_TEST_UPDATE_CASE/parts-before/99-template-no-auto-upgrades"
                    assert_ok cmp "$QUENCH_UPDATE_APT_DIR/apt.conf" "$QUENCH_TEST_UPDATE_CASE/main-before"
                    assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/units/apt-daily.timer.active")" inactive ;;
                external_edit)
                    assert_file_contains "$PARTS/52quench-unattended-upgrades" '// external change'
                    assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/units/apt-daily.timer.active")" inactive ;;
                busy)
                    assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/units/apt-daily-upgrade.service.active")" active
                    assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/units/apt-daily.timer.active")" inactive
                    ! grep -q 'systemctl stop apt-daily-upgrade.service' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'killed APT'
                    ;;
                *) assert_ok diff -r "$PARTS" "$QUENCH_TEST_UPDATE_CASE/parts-before"
                   if [ -f "$QUENCH_TEST_UPDATE_CASE/main-before" ]; then
                       assert_ok cmp "$QUENCH_UPDATE_APT_DIR/apt.conf" "$QUENCH_TEST_UPDATE_CASE/main-before"
                   fi
                   assert_ok diff -r "$QUENCH_TEST_UPDATE_CASE/units" "$QUENCH_TEST_UPDATE_CASE/units-before" ;;
            esac
            ;;
    esac
    case "$1" in
        cancel|extra_template|linked_template|active_updater|candidate_fail|template_edit|template_added|template_linked)
            ! grep -q '^install$' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'installed before approval/valid preflight'
            ! grep -Eq '^systemctl (stop|start|enable|disable|mask|unmask)' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'mutated units before approval'
            ;;
        *) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" install ;;
    esac
    case "$1" in
        cancel|template_edit|template_added|template_linked)
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" confirm ;;
        multi_timer_fail|multi_external_edit)
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'systemctl start apt-daily.timer apt-daily-upgrade.timer'
            assert_file_contains "$QUENCH_UPDATE_RUN/templates-touched" apt.conf
            assert_file_contains "$QUENCH_UPDATE_RUN/templates-touched" apt.conf.d/99zz-ppflight-no-auto-upgrades ;;
        multi_remove_fail)
            assert_file_contains "$QUENCH_UPDATE_RUN/templates-touched" apt.conf.d/99-template-no-auto-upgrades
            assert_file_contains "$QUENCH_UPDATE_RUN/templates-touched" apt.conf.d/99zz-ppflight-no-auto-upgrades ;;
    esac
    assert_eq "$(grep -c '^unlock$' "$QUENCH_TEST_UPDATE_CASE/calls")" 1
    :
}
for CASE in success runtime unmasked no_template new_files missing_unit vendor multiple write_fail cancel extra_template linked_template active_updater candidate_fail template_edit template_added template_linked install_template_edit install_fail policy_fail unmask_fail timer_fail existing_timers external_edit busy multi_timer_fail multi_remove_fail multi_external_edit; do
    run_test "Automatic update enable transaction: $CASE" t_auto_enable "$CASE"
done

t_auto_dependency() {
    setup_update "dependency_$1"
    if [ "$1" != installed ]; then dpkg-query() { return 1; }; fi
    case "$1" in refresh-fail|apply-fail) : > "$QUENCH_TEST_UPDATE_CASE/$1" ;; esac
    case "$1" in
        refresh-fail|apply-fail) assert_fail system_update_auto_install_dependency ;;
        *) assert_ok system_update_auto_install_dependency ;;
    esac
    case "$1" in
        installed) [ ! -s "$QUENCH_TEST_UPDATE_CASE/calls" ] || fail 'reinstalled an installed dependency' ;;
        refresh-fail) ! grep -q ' install ' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'installed with stale indexes' ;;
        *) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove install -y unattended-upgrades' ;;
    esac
    :
}
for CASE in installed new refresh-fail apply-fail; do run_test "Automatic update dependency: $CASE" t_auto_dependency "$CASE"; done

t_auto_units_verify() {
    setup_update "auto_units_$1"
    QUENCH_TEST_UNIT_MODE="$1"
    systemctl() {
        case "$1" in
            show)
                [ "$QUENCH_TEST_UNIT_MODE" != query_fail ] || return 1
                if [ "$QUENCH_TEST_UNIT_MODE" = masked ] && [ "$2" = apt-daily-upgrade.service ]; then echo masked
                else echo loaded; fi ;;
            is-enabled) [ "$QUENCH_TEST_UNIT_MODE" != disabled ] ;;
            is-active) [ "$QUENCH_TEST_UNIT_MODE" != inactive ] ;;
            *) fail 'readiness check mutated unit state' ;;
        esac
    }
    if [ "$1" = valid ]; then assert_ok system_update_auto_units_ready
    else assert_fail system_update_auto_units_ready; fi
    :
}
for CASE in valid masked disabled inactive query_fail; do run_test "Automatic update scheduler readiness: $CASE" t_auto_units_verify "$CASE"; done

t_major_cleanup() {
    setup_update "cleanup_$1"
    QUENCH_UPDATE_MAJOR_SOURCE="$QUENCH_UPDATE_APT_DIR/sources.list"
    QUENCH_UPDATE_MAJOR_PHASE="$1"
    QUENCH_UPDATE_MAJOR_TIMERS='apt-daily.timer'
    cp "$QUENCH_UPDATE_MAJOR_SOURCE" "$QUENCH_UPDATE_RUN/source-before"
    system_update_sources stage bookworm "$QUENCH_UPDATE_RUN/source-new"
    cp "$QUENCH_UPDATE_RUN/source-new" "$QUENCH_UPDATE_MAJOR_SOURCE"
    systemctl() { echo "systemctl $*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    assert_fail system_update_major_cleanup 1
    if [ "$1" = sources-switched ]; then
        assert_file_contains "$QUENCH_UPDATE_MAJOR_SOURCE" bookworm
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'systemctl start apt-daily.timer'
    else
        assert_file_contains "$QUENCH_UPDATE_MAJOR_SOURCE" trixie
        ! grep -q 'systemctl start' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'restarted auto updates on partial release upgrade'
    fi
    :
}
run_test 'Major failure before package writes restores the source' t_major_cleanup sources-switched
run_test 'Major failure after package writes never downgrades source or resumes auto updates' t_major_cleanup packages-started

t_major_external_edit() {
    setup_update external_edit
    QUENCH_UPDATE_MAJOR_SOURCE="$QUENCH_UPDATE_APT_DIR/sources.list"
    QUENCH_UPDATE_MAJOR_PHASE=sources-switched
    QUENCH_UPDATE_MAJOR_TIMERS=''
    echo old > "$QUENCH_UPDATE_RUN/source-before"
    echo proposed > "$QUENCH_UPDATE_RUN/source-new"
    echo external > "$QUENCH_UPDATE_MAJOR_SOURCE"
    assert_fail system_update_major_cleanup 1
    assert_eq "$(cat "$QUENCH_UPDATE_MAJOR_SOURCE")" external
    :
}
run_test 'Major source recovery preserves concurrent external changes' t_major_external_edit

t_major_flow() {
    setup_update "flow_$1"
    QUENCH_TEST_MAJOR_MODE="$1"
    if [ "$1" = cloud_restore ]; then setup_cloud_source; fi
    system_update_major_preflight() { QUENCH_UPDATE_MAJOR_SOURCE=$(system_update_sources major bookworm); }
    systemctl() { [ "$1" != is-active ]; }
    system_update_apt_origins_guard() { :; }
    confirm_change_preview() {
        if [ "$QUENCH_TEST_MAJOR_MODE" = cancel_after_source ] && [[ "$1" == *trixie* ]]; then return 1; fi
        if [ "$QUENCH_TEST_MAJOR_MODE" = cancel_before_source ]; then return 1; fi
        if [ "$QUENCH_TEST_MAJOR_MODE" = source_edited ]; then echo '# external edit' >> "$QUENCH_UPDATE_APT_DIR/sources.list"; fi
        return 0
    }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [[ " $* " == *' update '* ]]; then
            [ "$QUENCH_TEST_MAJOR_MODE" != refresh_fail ] && [ "$QUENCH_TEST_MAJOR_MODE" != cloud_restore ]; return $?
        fi
        if [[ " $* " == *' -s '* ]]; then return 0; fi
        if [ "$QUENCH_TEST_MAJOR_MODE" = install_fail ]; then return 100; fi
        if [[ " $* " == *' dist-upgrade '* ]]; then
            printf '%s\n' ID=debian VERSION_ID=13 VERSION_CODENAME=trixie > "$QUENCH_UPDATE_OS_FILE"
        fi
    }
    if [ "$1" = refresh_fail ] || [ "$1" = install_fail ] || [ "$1" = cloud_restore ] || [ "$1" = source_edited ]; then
        assert_fail system_update_debian_major <<< 'UPGRADE 12 TO 13'
    else
        assert_ok system_update_debian_major <<< 'UPGRADE 12 TO 13'
    fi
    case "$1" in
        refresh_fail|cancel_after_source|cancel_before_source|source_edited)
            assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list" bookworm
            ! grep -q 'Lock::Timeout' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'installed after cancellation/failure before package phase'
            ;;
        cloud_restore)
            assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources" 'URIs: mirror+file:///etc/apt/mirrors/debian.list'
            assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources" 'bookworm-updates bookworm-backports'
            assert_ok cmp "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources" "$(find "$QUENCH_UPDATE_STATE_DIR" -name source-before)"
            ;;
        install_fail) assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list" trixie ;;
        success)
            assert_eq "$(system_update_debian_code)" trixie
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove upgrade'
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '60 dist-upgrade'
            ;;
    esac
    assert_eq "$(tail -1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
    :
}
for PHASE in refresh_fail cancel_after_source cancel_before_source source_edited cloud_restore install_fail success; do run_test "Major orchestration and EXIT recovery: $PHASE" t_major_flow "$PHASE"; done

t_disable() {
    setup_update disable
    QUENCH_APT_AUTO_UPGRADES_FILE="$QUENCH_UPDATE_APT_DIR/20auto-upgrades"
    systemd_available() { return 0; }
    systemctl() { printf 'systemctl %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    apt-config() { echo 'APT::Periodic::Unattended-Upgrade "0";'; }
    assert_ok system_update_auto_disable
    assert_file_contains "$QUENCH_APT_AUTO_UPGRADES_FILE" 'Unattended-Upgrade "0";'
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'disable --now apt-daily.timer apt-daily-upgrade.timer'
    ! grep -q '\.service' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'stopped a running package job'
    :
}
run_test 'Disable automatic updates changes timers, never kills running services' t_disable

t_log_failure() {
    setup_update log_failure
    QUENCH_UPDATE_RUN="$QUENCH_TEST_UPDATE_CASE/does-not-exist"
    assert_fail system_update_logged true
    QUENCH_UPDATE_RUN="$QUENCH_TEST_UPDATE_CASE/run"
    assert_fail system_update_logged false
    :
}
run_test 'Neither logging failures nor package-manager failures are swallowed' t_log_failure

t_major_preflight() {
    setup_update "preflight_$1"
    dpkg() { echo amd64; }
    apt-mark() { :; }
    apt() { echo 'Listing...'; }
    systemd_available() { return 0; }
    systemd-detect-virt() { return 1; }
    systemctl() { return 1; }
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 9999999 1 9999998 1%% /\n'; }
    : > "$QUENCH_TEST_UPDATE_CASE/plan"
    system_update_kernel_meta() { echo linux-image-cloud-amd64; }
    system_update_bookworm_prepare() { return 0; }
    case "$1" in
        valid) : ;;
        unsupported_arch) dpkg() { echo i386; } ;;
        held) apt-mark() { echo openssh-server; } ;;
        pinning) echo 'Package: *' > "$QUENCH_UPDATE_APT_DIR/preferences" ;;
        backports) echo 'deb https://deb.debian.org/debian bookworm-backports main' >> "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        foreign) apt() { echo 'vendor/stable 1.0 amd64 [installed]'; } ;;
        pending) system_update_bookworm_prepare() { return 1; } ;;
        kernel) system_update_kernel_meta() { return 1; } ;;
        space) df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1024 1 1023 1%% /\n'; } ;;
        container) systemd-detect-virt() { return 0; } ;;
        pending_reboot) system_update_reboot_required() { return 0; } ;;
        active_updater) systemctl() { return 0; } ;;
        already_13) printf '%s\n' ID=debian VERSION_ID=13 VERSION_CODENAME=trixie > "$QUENCH_UPDATE_OS_FILE" ;;
    esac
    if [ "$1" = valid ] || [ "$1" = backports ]; then assert_ok system_update_major_preflight
    else assert_fail system_update_major_preflight; fi
    :
}
for GUARD in valid unsupported_arch held pinning backports foreign pending kernel space container pending_reboot active_updater already_13; do
    run_test "Major preflight: $GUARD" t_major_preflight "$GUARD"
done

t_eof() {
    setup_update eof
    print_header() { :; }; ui_hint() { :; }; menu_pair() { :; }; menu_item() { :; }
    assert_ok system_update_manager < /dev/null
    :
}
run_test 'Update menu exits safely on EOF' t_eof

setup_tmux() {
    setup_update "tmux_$1"
    SSH_CONNECTION='192.0.2.1 12345 192.0.2.2 22'
    SSH_TTY=/dev/pts/fixture
    TMUX= STY=
    QUENCH_TXN_LOCK_HELD=0 QUENCH_TXN_WRITE_DEPTH=0
    system_update_terminal_ready() { [ ! -e "$QUENCH_TEST_UPDATE_CASE/no-tty" ]; }
    system_update_tmux_available() { [ ! -e "$QUENCH_TEST_UPDATE_CASE/no-tmux" ]; }
    self_resolve_script_source() {
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/stream" ] || return 1
        printf '%s\n' "/tmp/quench path with 'quote/\$(literal).sh"
    }
    safety_timer_pending() { [ -e "$QUENCH_TEST_UPDATE_CASE/pending" ]; }
    system_update_tmux_install() {
        echo install >> "$QUENCH_TEST_UPDATE_CASE/calls"
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/install-fail" ] || return 1
        rm -f "$QUENCH_TEST_UPDATE_CASE/no-tmux"
    }
    tmux() {
        printf 'tmux %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        case " $* " in
            *' has-session '*) [ -e "$QUENCH_TEST_UPDATE_CASE/existing" ]; return $? ;;
            *' new-session '*)
                [ "$#" = 12 ] || fail 'tmux argv was not preserved'
                assert_eq "$9" bash
                if [ -e "$QUENCH_TEST_UPDATE_CASE/stream" ]; then
                    assert_eq "${10}" "$QUENCH_TEST_UPDATE_CASE/staged.sh"
                else
                    assert_eq "${10}" "/tmp/quench path with 'quote/\$(literal).sh"
                fi
                assert_eq "${11}" --system-update-resume
                ;;
        esac
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/tmux-fail" ]
    }
    system_update_tmux_stage_script() {
        echo download >> "$QUENCH_TEST_UPDATE_CASE/calls"
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/download-fail" ] || return 1
        printf 'APP_VERSION="%s"\n' "$APP_VERSION" > "$QUENCH_TEST_UPDATE_CASE/staged.sh"
        printf '%s\n' "$QUENCH_TEST_UPDATE_CASE/staged.sh"
    }
    system_update_action() { echo "action $1" >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    system_update_debian_major() { echo major >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    ui_pause() { echo pause >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
}

t_tmux_handoff() {
    setup_tmux "$1"
    case "$1" in
        tmux) TMUX=already-inside ;;
        screen) STY=already-inside ;;
        local) SSH_CONNECTION= SSH_TTY= ;;
        tty-only) SSH_CONNECTION= ;;
        install|install-fail|cancel-install|stream-install) touch "$QUENCH_TEST_UPDATE_CASE/no-tmux" ;;
    esac
    case "$1" in
        no-tty|cancel|stream|install-fail|tmux-fail|pending) touch "$QUENCH_TEST_UPDATE_CASE/$1" ;;
        cancel-install) touch "$QUENCH_TEST_UPDATE_CASE/cancel" ;;
        stream-install) touch "$QUENCH_TEST_UPDATE_CASE/stream" ;;
        stream-cancel) touch "$QUENCH_TEST_UPDATE_CASE/stream" "$QUENCH_TEST_UPDATE_CASE/cancel" ;;
        download-fail) touch "$QUENCH_TEST_UPDATE_CASE/stream" "$QUENCH_TEST_UPDATE_CASE/download-fail" ;;
        held) QUENCH_TXN_LOCK_HELD=1 ;;
        nested) QUENCH_TXN_WRITE_DEPTH=1 ;;
        existing|existing-stream|attach-fail)
            touch "$QUENCH_TEST_UPDATE_CASE/existing"
            touch "$QUENCH_TEST_UPDATE_CASE/stream"
            [ "$1" != attach-fail ] || touch "$QUENCH_TEST_UPDATE_CASE/tmux-fail"
            ;;
    esac
    case "$1" in
        no-tty|download-fail|install-fail|tmux-fail|attach-fail|held|nested|pending) assert_fail system_update_dispatch current ;;
        *) assert_ok system_update_dispatch current ;;
    esac
    case "$1" in
        tmux|screen)
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" 'action current'
            ;;
        *) ! grep -q '^action\|^major' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'handoff fell through to a duplicate update' ;;
    esac
    case "$1" in
        launch|tty-only|local|install|tmux-fail|stream|stream-install)
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'new-session -A -s quench-update'
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--system-update-resume current'
            ;;
        existing|existing-stream|attach-fail)
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'attach-session -t =quench-update'
            ! grep -q 'new-session\|^install' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'existing session was recreated'
            ;;
        no-tty|cancel|cancel-install|stream-cancel|download-fail|install-fail|held|nested|pending)
            ! grep -q 'new-session\|attach-session' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unsafe handoff'
            ;;
    esac
    case "$1" in
        install|install-fail|stream-install) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" install ;;
        *) ! grep -q '^install' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unrequested installation' ;;
    esac
    case "$1" in
        stream|stream-install|download-fail) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" download ;;
        *) ! grep -q '^download' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unrequested download' ;;
    esac
    :
}
for FORM in launch tty-only tmux screen local install existing existing-stream cancel cancel-install stream stream-install stream-cancel download-fail no-tty install-fail tmux-fail attach-fail held nested pending; do
    run_test "tmux update handoff: $FORM" t_tmux_handoff "$FORM"
done

t_tmux_resume() {
    setup_tmux "resume_$1"
    system_update_manager() { echo menu >> "$QUENCH_TEST_UPDATE_CASE/calls"; }
    TMUX=inside
    case "$1" in
        outside) TMUX= ;;
        no-tty) touch "$QUENCH_TEST_UPDATE_CASE/no-tty" ;;
        failed) system_update_action() { echo 'failed action' >> "$QUENCH_TEST_UPDATE_CASE/calls"; return 1; } ;;
    esac
    case "$1" in
        outside|no-tty)
            assert_fail system_update_resume current
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" ''
            ;;
        invalid)
            assert_fail system_update_resume 'current; reboot'
            assert_fail system_update_dispatch 'current; reboot'
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" ''
            ;;
        failed)
            assert_ok system_update_resume current
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" $'failed action\npause\nmenu'
            ;;
        major)
            assert_ok system_update_resume major
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" $'major\npause\nmenu'
            ;;
        *)
            assert_ok system_update_resume "$1"
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" "$(printf 'action %s\npause\nmenu' "$1")"
            ;;
    esac
    :
}
for MODE in current security packages autoremove full major invalid outside no-tty failed; do
    run_test "tmux update resume: $MODE" t_tmux_resume "$MODE"
done

t_tmux_dependency() {
    setup_update "tmux_dependency_$1"
    system_update_tmux_available() { [ -e "$QUENCH_TEST_UPDATE_CASE/installed" ]; }
    system_package_manager() { echo "${QUENCH_TEST_PM:-apt}"; }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        case " $* " in
            *' update '*) [ ! -e "$QUENCH_TEST_UPDATE_CASE/refresh-fail" ]; return $? ;;
        esac
        [ ! -e "$QUENCH_TEST_UPDATE_CASE/apply-fail" ] || return 100
        [ -e "$QUENCH_TEST_UPDATE_CASE/missing-binary" ] || touch "$QUENCH_TEST_UPDATE_CASE/installed"
        return 0
    }
    dnf() { echo "dnf $*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; touch "$QUENCH_TEST_UPDATE_CASE/installed"; }
    yum() { echo "yum $*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; touch "$QUENCH_TEST_UPDATE_CASE/installed"; }
    apk() { echo "apk $*" >> "$QUENCH_TEST_UPDATE_CASE/calls"; touch "$QUENCH_TEST_UPDATE_CASE/installed"; }
    QUENCH_TEST_PM=apt
    case "$1" in
        dnf|yum|apk|pacman) QUENCH_TEST_PM="$1" ;;
        refresh-fail|apply-fail|broken|missing-binary) touch "$QUENCH_TEST_UPDATE_CASE/$1" ;;
        lock-fail) txn_write_begin() { return 1; } ;;
    esac
    case "$1" in
        apt|dnf|yum|apk) assert_ok system_update_tmux_install ;;
        *) assert_fail system_update_tmux_install ;;
    esac
    case "$1" in
        apt) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove install -y tmux' ;;
        dnf|yum) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" "$1 install -y tmux" ;;
        apk) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'apk add --no-cache tmux' ;;
        pacman|lock-fail) assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" '' ;;
        broken|refresh-fail)
            ! grep -q 'install -y' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'install after failed preflight'
            ;;
    esac
    case "$1" in
        pacman|lock-fail) : ;;
        *) assert_eq "$(tail -n 1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock ;;
    esac
    ! grep -Eq 'dist-upgrade| upgrade| remove|pacman' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'bootstrap performed whole-system mutation'
    :
}
for FORM in apt dnf yum apk pacman refresh-fail apply-fail broken missing-binary lock-fail; do
    run_test "tmux dependency bootstrap: $FORM" t_tmux_dependency "$FORM"
done


# Run the real action/preview wrapper with a missing-interpreter fixture. The
# env shim above keeps apt-get in-process and no test installs host packages.
t_python_bootstrap() {
    setup_update "python_$1"
    local FORM="$1" RC=0
    system_update_terminal_ready() { [ "$FORM" != no_tty ]; }
    system_update_python_ready() { [ -f "$QUENCH_TEST_UPDATE_CASE/python-ready" ]; }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [[ " $* " == *'python-bootstrap/'* ]]; then
            [[ " $* " == *' Dir::Etc::sourceparts=- '* ]] || fail 'bootstrap used global sources'
            [[ " $* " == *' Dir::State::lists='*'/python-bootstrap/lists '* ]] || fail 'bootstrap used global indices'
            [[ " $* " == *' APT::Get::AllowUnauthenticated=false '* ]] || fail 'bootstrap disabled authentication'
            if [[ " $* " == *' update '* ]]; then
                [ "$FORM" != refresh_fail ]; return $?
            fi
            [[ " $* " == *' --no-remove --no-install-recommends install python3 '* ]] || fail 'unexpected bootstrap action'
            if [[ " $* " == *' -s '* ]]; then
                [ "$FORM" != plan_fail ] || return 1
                case "$FORM" in
                    removal) echo 'Remv old-package [1]' ;;
                    critical) echo 'Inst libc6 [1] (2 Debian:12/bookworm [amd64])' ;;
                    *) echo 'Inst python3 (3.11 Debian:12/bookworm [amd64])' ;;
                esac
                return 0
            fi
            [ "$FORM" != install_fail ] || return 100
            [ "$FORM" = still_missing ] || touch "$QUENCH_TEST_UPDATE_CASE/python-ready"
        elif [[ " $* " == *' -s '* ]]; then
            system_update_python_ready || fail 'full update preview ran without interpreter'
            echo 'Inst curl [7.1] (7.2 Debian:12/bookworm [amd64])'
        fi
    }
    case "$FORM" in
        present) touch "$QUENCH_TEST_UPDATE_CASE/python-ready" ;;
        cancel) touch "$QUENCH_TEST_UPDATE_CASE/cancel" ;;
        broken) touch "$QUENCH_TEST_UPDATE_CASE/broken" ;;
        custom_env) APT_CONFIG=/tmp/quench-custom-apt ;;
        unsafe_original) echo 'deb http://deb.debian.org/debian sid main' > "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        lock_fail) txn_write_begin() { return 1; } ;;
    esac
    cp -a "$QUENCH_UPDATE_APT_DIR" "$QUENCH_TEST_UPDATE_CASE/original-sources"
    system_update_action full || RC=$?
    assert_ok diff -r "$QUENCH_UPDATE_APT_DIR" "$QUENCH_TEST_UPDATE_CASE/original-sources"
    case "$FORM" in
        success|present)
            assert_eq "$RC" 0
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'dist-upgrade'
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" SUCCESS
            ;;
        cancel)
            assert_eq "$RC" 0
            ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'declined dependency audited as success'
            ;;
        *) assert_ne "$RC" 0 ;;
    esac
    if [ "$FORM" != success ] && [ "$FORM" != present ]; then
        ! grep -q dist-upgrade "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'failed bootstrap reached whole-system upgrade'
    fi
    case "$FORM" in
        present|cancel|broken|custom_env|no_tty|lock_fail)
            ! grep -q 'install python3' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unexpected Python install' ;;
        *)
            local SOURCES
            SOURCES=$(find "$QUENCH_UPDATE_STATE_DIR" -name sources.list -print)
            assert_file_contains "$SOURCES" 'signed-by=/usr/share/keyrings/debian-archive-keyring.gpg'
            assert_file_contains "$SOURCES" 'bookworm-security main'
            ! grep -qE 'sid|stable|trixie' "$SOURCES" || fail 'bootstrap selected another release'
            ;;
    esac
    [ "$FORM" != unsafe_original ] || system_update_python_ready || fail 'fixture never finished bootstrap'
    ! grep -Eq 'install (-y|--assume-yes)|force-conf|allow-unauthenticated' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'bootstrap bypassed consent'
}
for FORM in success present cancel no_tty custom_env broken lock_fail refresh_fail plan_fail removal critical install_fail still_missing unsafe_original; do
    run_test "Missing Python is handled before the selected update: $FORM" t_python_bootstrap "$FORM"
done


t_tmux_stage() {
    setup_update "tmux_stage_$1"
    local FORM="$1" RESULT RC=0
    self_fetch_script() {
        printf 'APP_VERSION="%s"\n' "$APP_VERSION" > "$1"
        chmod 700 "$1"
        [ "$FORM" != failed ]
    }
    RESULT=$(system_update_tmux_stage_script) || RC=$?
    if [ "$FORM" = failed ]; then
        assert_ne "$RC" 0
        assert_eq "$RESULT" ''
        assert_eq "$(find "$QUENCH_UPDATE_STATE_DIR" -type f -name vps-quench.sh -print)" ''
    else
        assert_eq "$RC" 0
        assert_file_contains "$RESULT" "APP_VERSION=\"$APP_VERSION\""
        assert_ok bash -n "$RESULT"
        [ -z "$(find "$RESULT" -perm -0044 -print)" ] || fail 'session script is publicly readable'
        case "$RESULT" in "$QUENCH_UPDATE_STATE_DIR"/quench-session.*/vps-quench.sh) : ;; *) fail 'script is outside the managed state directory' ;; esac
    fi
}
for FORM in success failed; do run_test "Private session staging: $FORM" t_tmux_stage "$FORM"; done

t_tmux_version_change() {
    setup_tmux "version_$1"
    local FORM="$1"
    touch "$QUENCH_TEST_UPDATE_CASE/stream"
    system_update_tmux_stage_script() {
        echo 'APP_VERSION="V99.0.0"' > "$QUENCH_TEST_UPDATE_CASE/staged.sh"
        printf '%s\n' "$QUENCH_TEST_UPDATE_CASE/staged.sh"
    }
    confirm_change_preview() {
        echo "$1" >> "$QUENCH_TEST_UPDATE_CASE/confirmations"
        [ "$1" != '续接脚本版本发生变化' ] || [ "$FORM" = accept ]
    }
    assert_ok system_update_dispatch current
    assert_file_contains "$QUENCH_TEST_UPDATE_CASE/confirmations" '续接脚本版本发生变化'
    if [ "$FORM" = accept ]; then
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" 'new-session'
    else
        ! grep -q new-session "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'changed version started without consent'
    fi
}
for FORM in accept decline; do run_test "Changed continuation script version: $FORM" t_tmux_version_change "$FORM"; done


t_onboarding_context() {
    setup_update "onboarding_context_$1"
    local FORM="$1" RC=0 MODE=current CONTEXT=onboarding
    SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22'; TMUX=''; STY=''
    system_update_session_ready() { return 1; }
    system_update_terminal_ready() { [ "$FORM" != no_tty ]; }
    case "$FORM" in
        full) MODE=full ;;
        protected) CONTEXT=protected ;;
        invalid) CONTEXT=unprotected ;;
        major|autoremove) MODE="$FORM" ;;
        broken) touch "$QUENCH_TEST_UPDATE_CASE/broken" ;;
    esac
    system_update_action "$MODE" "$CONTEXT" || RC=$?
    case "$FORM" in
        current|full)
            assert_eq "$RC" 0
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" backup
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" SUCCESS
            assert_eq "$(tail -n 1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
            ;;
        broken)
            assert_ne "$RC" 0
            ! grep -q backup "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'onboarding bypassed package health checks'
            ;;
        *)
            assert_ne "$RC" 0
            assert_eq "$(cat "$QUENCH_TEST_UPDATE_CASE/calls")" ''
            ;;
    esac
}
for FORM in current full protected invalid major autoremove broken no_tty; do
    run_test "Onboarding foreground exception preserves normal update guards: $FORM" t_onboarding_context "$FORM"
done


# Exercise the real postcheck through both onboarding APT entry points. Every
# systemctl/sshd call is a fixture; no host service is queried or modified.
t_service_baseline() {
    setup_update "service_baseline_$1"
    eval "$QUENCH_TEST_REAL_POSTCHECK"
    local FORM="$1" MODE=current RC=0 OUT RUN
    systemd_available() { return 0; }
    system_update_terminal_ready() { return 0; }
    sshd() { [ ! -f "$QUENCH_TEST_UPDATE_CASE/ssh-broken" ]; }
    printf '%s\n' 'networking.service loaded failed failed Raise network interfaces' > "$QUENCH_TEST_UPDATE_CASE/before"
    cp "$QUENCH_TEST_UPDATE_CASE/before" "$QUENCH_TEST_UPDATE_CASE/after"
    case "$FORM" in
        full) MODE=full ;;
        security) MODE=security ;;
        new|bootstrap-new) : > "$QUENCH_TEST_UPDATE_CASE/before" ;;
        mixed) echo 'ssh.service loaded failed failed OpenSSH server' >> "$QUENCH_TEST_UPDATE_CASE/after" ;;
        recovered) : > "$QUENCH_TEST_UPDATE_CASE/after" ;;
        healthy) : > "$QUENCH_TEST_UPDATE_CASE/before"; : > "$QUENCH_TEST_UPDATE_CASE/after" ;;
        no-updates) : > "$QUENCH_TEST_UPDATE_CASE/plan" ;;
        description) echo 'networking.service loaded failed failed Different translated description' > "$QUENCH_TEST_UPDATE_CASE/after" ;;
        reordered)
            echo 'a.service loaded failed failed Before' >> "$QUENCH_TEST_UPDATE_CASE/before"
            printf '%s\n' 'a.service loaded failed failed After' 'networking.service loaded failed failed Changed' > "$QUENCH_TEST_UPDATE_CASE/after"
            ;;
        malformed-before) echo 'unexpected output' > "$QUENCH_TEST_UPDATE_CASE/before" ;;
        malformed-after) echo 'unexpected output' > "$QUENCH_TEST_UPDATE_CASE/after" ;;
        ssh-error) touch "$QUENCH_TEST_UPDATE_CASE/ssh-broken" ;;
        apt-error) system_update_apt_health() { [ ! -f "$QUENCH_TEST_UPDATE_CASE/applied" ]; } ;;
        systemd-lost) systemd_available() { [ ! -f "$QUENCH_TEST_UPDATE_CASE/applied" ]; } ;;
    esac
    systemctl() {
        assert_eq "$*" '--failed --plain --no-legend --no-pager'
        local PHASE=before
        if [ -f "$QUENCH_TEST_UPDATE_CASE/queried" ]; then PHASE=after; fi
        touch "$QUENCH_TEST_UPDATE_CASE/queried"
        printf 'service-%s\n' "$PHASE" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        case "$FORM:$PHASE" in query-before:before|query-after:after) echo 'system bus unavailable'; return 1 ;; esac
        cat "$QUENCH_TEST_UPDATE_CASE/$PHASE"
    }
    system_update_require_python() {
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" service-before
        echo bootstrap >> "$QUENCH_TEST_UPDATE_CASE/calls"
    }
    # Package application remains stubbed but leaves evidence for postchecking.
    env() {
        while [[ "${1:-}" == *=* ]]; do shift; done
        if [[ " $* " == *' -o DPkg::Lock::Timeout=60 '* ]]; then
            touch "$QUENCH_TEST_UPDATE_CASE/applied"
            if [ "$FORM" = missing-baseline ]; then rm "$QUENCH_UPDATE_RUN/services-before.txt"; fi
        fi
        "$@"
    }
    if [ "$FORM" = security ]; then
        OUT=$(system_update_action "$MODE") || RC=$?
    else
        OUT=$(system_update_action "$MODE" onboarding) || RC=$?
    fi
    for RUN in "$QUENCH_UPDATE_STATE_DIR"/run-*; do :; done
    case "$FORM" in
        current|full|security|recovered|healthy|no-updates|description|reordered)
            assert_eq "$RC" 0
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" SUCCESS
            assert_file_contains "$RUN/result.txt" 'exit_code=0'
            test -f "$RUN/services-after.txt" || fail 'postcheck missing (including no-op update)'
            case "$FORM" in
                recovered|healthy) [[ "$OUT" != *'当前仍未恢复'* ]] || fail 'recovered unit reported as failing' ;;
                *) assert_contains "$OUT" '在更新前已失败'; assert_contains "$OUT" networking.service ;;
            esac
            ;;
        *)
            assert_ne "$RC" 0
            assert_file_contains "$QUENCH_TEST_UPDATE_CASE/audit" FAILED
            ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'failed health check audited as success'
            ;;
    esac
    case "$FORM" in
        new|mixed|bootstrap-new) assert_contains "$OUT" '新增失败单元'; test -s "$RUN/services-new.txt" || fail 'new failure not recorded' ;;
        query-before|malformed-before)
            ! grep -Eq 'bootstrap|apt-get' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'packages touched without reliable baseline'
            ;;
    esac
    assert_eq "$(tail -1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
}
for FORM in current full security recovered healthy no-updates description reordered new mixed bootstrap-new query-before query-after malformed-before malformed-after missing-baseline ssh-error apt-error systemd-lost; do
    run_test "Update service baseline: $FORM" t_service_baseline "$FORM"
done

t_service_standalone() {
    setup_update standalone_services
    eval "$QUENCH_TEST_REAL_POSTCHECK"
    systemd_available() { return 0; }
    sshd() { return 0; }
    systemctl() { echo 'networking.service loaded failed failed Raise network interfaces'; }
    # A stale previous run must not soften a standalone health check.
    echo networking.service > "$QUENCH_UPDATE_RUN/services-before.txt"
    assert_fail system_update_postcheck
}
run_test 'Standalone service check does not reuse a stale update baseline' t_service_standalone

t_kernel_matching() {
    setup_update "kernel_match_$1"
    local FORM="$1" ARCH=amd64 TEST_KERNEL=6.1.0-44-cloud-amd64 EXPECT=linux-image-cloud-amd64
    case "$FORM" in
        generic) TEST_KERNEL=6.1.0-44-amd64; EXPECT=linux-image-amd64 ;;
        arm64) ARCH=arm64; TEST_KERNEL=6.1.0-44-arm64; EXPECT=linux-image-arm64 ;;
        cloud-arm64) ARCH=arm64; TEST_KERNEL=6.1.0-44-cloud-arm64; EXPECT=linux-image-cloud-arm64 ;;
        custom) TEST_KERNEL=6.12.1-xanmod1 ;;
        arch-mismatch) ARCH=arm64 ;;
    esac
    uname() { echo "$TEST_KERNEL"; }
    dpkg-query() {
        if [ "$1" = -S ]; then
            [ "$FORM" != missing ] || return 1
            if [ "$FORM" = owner ]; then echo "vendor: $2"
            else echo "linux-image-$TEST_KERNEL: $2"; fi
        else
            local STATUS='install ok installed' SOURCE="linux-signed-$ARCH" VERSION=6.1.164-1 MAINT='Debian Kernel Team <debian-kernel@lists.debian.org>'
            case "$FORM" in source) SOURCE=vendor ;; version) VERSION='6.1.164-1~bpo12+1' ;; maintainer) MAINT=vendor ;; status) STATUS='install ok unpacked' ;; esac
            printf '%s\t%s\t%s\t%s\n' "$STATUS" "$SOURCE" "$VERSION" "$MAINT"
        fi
    }
    case "$FORM" in
        cloud|generic|arm64|cloud-arm64) assert_eq "$(system_update_kernel_meta "$ARCH")" "$EXPECT" ;;
        *) assert_fail system_update_kernel_meta "$ARCH" ;;
    esac
}
for FORM in cloud generic arm64 cloud-arm64 custom arch-mismatch missing owner source version maintainer status; do
    run_test "Match running Debian kernel to metapackage: $FORM" t_kernel_matching "$FORM"
done

t_kernel_target() {
    setup_update "kernel_target_$1"
    local FORM="$1"
    system_update_kernel_image_present() { [ "$FORM" != missing-image ]; }
    dpkg-query() {
        case "$*" in
            *'${Depends}'*)
                case "$FORM" in
                    missing) echo '' ;;
                    alternatives) echo 'linux-image-6.1.0-54-cloud-amd64 | linux-image-generic' ;;
                    wrong-flavour) echo 'linux-image-6.1.0-54-amd64 (= 6.1.170-1)' ;;
                    *) echo 'linux-image-6.1.0-54-cloud-amd64 (= 6.1.170-1)' ;;
                esac ;;
            *)
                if [ "$FORM" = broken ] && [[ "$*" == *linux-image-6.1.0* ]]; then echo 'install ok unpacked'
                else echo 'install ok installed'; fi ;;
        esac
    }
    if [ "$FORM" = valid ]; then assert_eq "$(system_update_kernel_boot_target linux-image-cloud-amd64)" 6.1.0-54-cloud-amd64
    else assert_fail system_update_kernel_boot_target linux-image-cloud-amd64; fi
}
for FORM in valid missing alternatives wrong-flavour broken missing-image; do
    run_test "Installed kernel metapackage boot target: $FORM" t_kernel_target "$FORM"
done

t_bookworm_prepare() {
    setup_update "bookworm_prepare_$1"
    local FORM="$1" RC=0 TEST_BOOT_TARGET=6.1.0-54-cloud-amd64 OUT
    uname() { echo 6.1.0-54-cloud-amd64; }
    system_update_kernel_boot_target() { [ "$FORM" != target-fail ] || return 1; echo "$TEST_BOOT_TARGET"; }
    system_update_sources() { echo sources-check >> "$QUENCH_TEST_UPDATE_CASE/calls"; [ "$FORM" != changed-source ]; }
    system_update_backports_guard() { return 0; }
    system_update_reboot_required() { [ "$FORM" = reboot-marker ]; }
    if [ "$FORM" = new-kernel ]; then TEST_BOOT_TARGET=6.1.0-55-cloud-amd64; fi
    case "$FORM" in missing-meta|install-fail|cancel|meta-critical) touch "$QUENCH_TEST_UPDATE_CASE/no-meta" ;; esac
    case "$FORM" in ready|reboot-marker|target-fail) touch "$QUENCH_TEST_UPDATE_CASE/updated" ;; esac
    if [ "$FORM" = config-race ]; then
        confirm_change_preview() { echo '# external change' >> "$QUENCH_UPDATE_APT_DIR/sources.list"; return 0; }
    fi
    [ "$FORM" != cancel ] || touch "$QUENCH_TEST_UPDATE_CASE/cancel"
    [ "$FORM" != post-fail ] || touch "$QUENCH_TEST_UPDATE_CASE/post-fail"
    dpkg-query() {
        [ ! -f "$QUENCH_TEST_UPDATE_CASE/no-meta" ] || return 1
        echo 'install ok installed'
    }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [[ " $* " == *' -s '* ]]; then
            [ "$FORM" != simulation-fail ] || return 1
            case "$*" in
                *install*)
                    if [ "$FORM" = meta-critical ]; then echo 'Remv openssh-server [1.0]'
                    else echo 'Inst linux-image-cloud-amd64 (6.1.170-1 Debian:12.0/bookworm [amd64])'; fi ;;
                *)
                    if [ "$FORM" = critical ]; then echo 'Remv linux-image-6.1.0-44-cloud-amd64 [6.1.164-1]'
                    elif [ "$FORM" = backports-plan ]; then echo 'Inst foo (1~bpo12+1 Debian)'
                    elif [ ! -f "$QUENCH_TEST_UPDATE_CASE/updated" ]; then echo 'Inst sudo [1.0] (1.1 Debian:12.0/bookworm [amd64])'; fi ;;
            esac
            return 0
        fi
        [ "$FORM" != install-fail ] && [ "$FORM" != full-fail ] || return 100
        case "$*" in
            *install*) rm -f "$QUENCH_TEST_UPDATE_CASE/no-meta" ;;
            *dist-upgrade*) [ "$FORM" = remaining ] || touch "$QUENCH_TEST_UPDATE_CASE/updated" ;;
        esac
        return 0
    }
    OUT=$(system_update_bookworm_prepare linux-image-cloud-amd64) || RC=$?
    case "$FORM" in
        ready|missing-meta|updates) assert_eq "$RC" 0 ;;
        cancel) assert_eq "$RC" 2 ;;
        new-kernel|reboot-marker) assert_eq "$RC" 3; assert_contains "$OUT" '等待你手动重启' ;;
        *) assert_eq "$RC" 1 ;;
    esac
    assert_file_contains "$QUENCH_UPDATE_RUN/bookworm-preparation/result.txt" "exit_code=$RC"
    assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list" bookworm
    ! grep -Eq ' -y |reboot|autoremove|trixie' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'unsafe preparation operation'
    case "$FORM" in
        ready|cancel|critical|meta-critical|simulation-fail|backports-plan|changed-source|config-race)
            ! grep -q 'Lock::Timeout' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'applied an unapproved/invalid package plan' ;;
        missing-meta) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '--no-remove install linux-image-cloud-amd64'; assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '60 dist-upgrade' ;;
        updates) assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" '60 dist-upgrade' ;;
    esac
}
for FORM in ready missing-meta updates cancel new-kernel reboot-marker target-fail install-fail full-fail critical meta-critical simulation-fail backports-plan changed-source config-race remaining post-fail; do
    run_test "Bookworm automatic preparation: $FORM" t_bookworm_prepare "$FORM"
done

t_major_preparation_stop() {
    setup_update "major_prepare_stop_$1"
    local RESULT="$1"
    system_update_major_preflight() { return "$RESULT"; }
    assert_ok system_update_debian_major
    ! grep -q 'apt-get' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'entered trixie after preparation stopped'
    assert_eq "$(tail -1 "$QUENCH_TEST_UPDATE_CASE/calls")" unlock
    local RUN
    for RUN in "$QUENCH_UPDATE_STATE_DIR"/run-*; do :; done
    assert_file_contains "$RUN/result.txt" status=not-started
    ! grep -q SUCCESS "$QUENCH_TEST_UPDATE_CASE/audit" || fail 'preparation stop audited as major-upgrade success'
}
for RESULT in 2 3; do run_test "Preparation cancellation/reboot does not start major upgrade: $RESULT" t_major_preparation_stop "$RESULT"; done

t_major_preparation_order() {
    setup_update "major_prepare_order_$1"
    local FORM="$1" RC=0
    dpkg() { echo amd64; }
    apt-mark() { :; }
    systemd_available() { return 0; }
    systemd-detect-virt() { return 1; }
    systemctl() { return 1; }
    system_update_kernel_meta() { echo linux-image-cloud-amd64; }
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 9999999 1 9999998 1%% /\n'; }
    system_update_bookworm_prepare() {
        echo prepare >> "$QUENCH_TEST_UPDATE_CASE/calls"
        case "$FORM" in
            reboot) return 3 ;;
            fail) return 1 ;;
            source-race) echo 'deb https://example.invalid bookworm main' >> "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        esac
        return 0
    }
    system_update_foreign_guard() {
        assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" prepare
        echo foreign-after >> "$QUENCH_TEST_UPDATE_CASE/calls"
    }
    system_update_major_preflight || RC=$?
    case "$FORM" in
        success) assert_eq "$RC" 0; assert_file_contains "$QUENCH_TEST_UPDATE_CASE/calls" foreign-after ;;
        reboot) assert_eq "$RC" 3 ;;
        *) assert_eq "$RC" 1 ;;
    esac
    if [ "$FORM" != success ]; then
        ! grep -q foreign-after "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'continued major preflight after failed preparation'
    fi
}
for FORM in success reboot fail source-race; do
    run_test "Major preparation ordering and post-preparation source check: $FORM" t_major_preparation_order "$FORM"
done

test_summary 'System and software updates'
