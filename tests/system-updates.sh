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
            'Unattended-Upgrade::Automatic-Reboot "false";' \
            'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
        case "$QUENCH_TEST_POLICY_VARIANT" in
            broad) echo 'Unattended-Upgrade::Allowed-Origins:: "Debian:stable";' ;;
            reboot) echo 'Unattended-Upgrade::Automatic-Reboot "true";' ;;
        esac
    }
    if [ "$1" = valid ]; then assert_ok system_update_auto_policy_verify
    else assert_fail system_update_auto_policy_verify; fi
    :
}
for POLICY in valid broad reboot; do run_test "Effective automatic-update policy: $POLICY" t_auto_effective "$POLICY"; done

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
    system_update_major_preflight() { QUENCH_UPDATE_MAJOR_SOURCE="$QUENCH_UPDATE_APT_DIR/sources.list"; }
    systemctl() { [ "$1" != is-active ]; }
    system_update_apt_origins_guard() { :; }
    confirm_change_preview() {
        if [ "$QUENCH_TEST_MAJOR_MODE" = cancel_after_source ] && [[ "$1" == *trixie* ]]; then return 1; fi
        return 0
    }
    apt-get() {
        printf 'apt-get %s\n' "$*" >> "$QUENCH_TEST_UPDATE_CASE/calls"
        if [[ " $* " == *' update '* ]]; then
            [ "$QUENCH_TEST_MAJOR_MODE" != refresh_fail ]; return $?
        fi
        if [[ " $* " == *' -s '* ]]; then return 0; fi
        if [ "$QUENCH_TEST_MAJOR_MODE" = install_fail ]; then return 100; fi
        if [[ " $* " == *' dist-upgrade '* ]]; then
            printf '%s\n' ID=debian VERSION_ID=13 VERSION_CODENAME=trixie > "$QUENCH_UPDATE_OS_FILE"
        fi
    }
    if [ "$1" = refresh_fail ] || [ "$1" = install_fail ]; then
        assert_fail system_update_debian_major <<< 'UPGRADE 12 TO 13'
    else
        assert_ok system_update_debian_major <<< 'UPGRADE 12 TO 13'
    fi
    case "$1" in
        refresh_fail|cancel_after_source)
            assert_file_contains "$QUENCH_UPDATE_APT_DIR/sources.list" bookworm
            ! grep -q 'Lock::Timeout' "$QUENCH_TEST_UPDATE_CASE/calls" || fail 'installed after cancellation/failure before package phase'
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
for PHASE in refresh_fail cancel_after_source install_fail success; do run_test "Major orchestration and EXIT recovery: $PHASE" t_major_flow "$PHASE"; done

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
    case "$1" in
        valid) : ;;
        unsupported_arch) dpkg() { echo i386; } ;;
        held) apt-mark() { echo openssh-server; } ;;
        pinning) echo 'Package: *' > "$QUENCH_UPDATE_APT_DIR/preferences" ;;
        backports) echo 'deb https://deb.debian.org/debian bookworm-backports main' >> "$QUENCH_UPDATE_APT_DIR/sources.list" ;;
        foreign) apt() { echo 'vendor/stable 1.0 amd64 [installed]'; } ;;
        pending) echo 'Inst curl [1.0] (1.1 Debian)' > "$QUENCH_TEST_UPDATE_CASE/plan" ;;
        kernel) dpkg-query() { return 1; } ;;
        space) df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1024 1 1023 1%% /\n'; } ;;
        container) systemd-detect-virt() { return 0; } ;;
        pending_reboot) system_update_reboot_required() { return 0; } ;;
        active_updater) systemctl() { return 0; } ;;
        already_13) printf '%s\n' ID=debian VERSION_ID=13 VERSION_CODENAME=trixie > "$QUENCH_UPDATE_OS_FILE" ;;
    esac
    if [ "$1" = valid ]; then assert_ok system_update_major_preflight
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

test_summary 'System and software updates'
