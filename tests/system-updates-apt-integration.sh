#!/usr/bin/env bash
# Run in disposable Debian CI containers only. Never installs/upgrades packages;
# exercise real APT config parsing/source parsing, not fixtures pretending to be apt.
set -euo pipefail
[ "${QUENCH_TEST_APT_CONTAINER:-}" = 1 ] || { echo 'Run only in an explicit disposable Debian container.' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUENCH_TEST_TEMP_BASE="${TMPDIR:-/tmp}"
QUENCH_TEST_APT_ROOT=$(mktemp -d "${QUENCH_TEST_TEMP_BASE%/}/quench-test-apt.XXXXXX")
trap 'rm -rf "$QUENCH_TEST_APT_ROOT"' EXIT
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
CODE=$(system_update_debian_code)
system_update_apt_preflight
system_update_apt_origins_guard "$CODE"
system_update_security_config "$QUENCH_TEST_APT_ROOT/security.conf" "$CODE"
APT_CONFIG="$QUENCH_TEST_APT_ROOT/security.conf" python3 - "$CODE" <<'PY'
import apt_pkg, sys
apt_pkg.init_config()
c = apt_pkg.config
assert c.value_list('Unattended-Upgrade::Origins-Pattern') == ['origin=Debian,codename='+sys.argv[1]+'-security,label=Debian-Security']
assert not c.value_list('Unattended-Upgrade::Allowed-Origins')
for key in ('Automatic-Reboot','Remove-Unused-Dependencies','Remove-New-Unused-Dependencies','Remove-Unused-Kernel-Packages'):
    assert not c.find_b('Unattended-Upgrade::'+key, True), key
PY
# Real APT can parse the proposed trixie source, without fetching/installing it.
QUENCH_UPDATE_APT_DIR="$QUENCH_TEST_APT_ROOT/apt"
mkdir -p "$QUENCH_UPDATE_APT_DIR/sources.list.d"
printf '%s\n' 'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: bookworm bookworm-updates' 'Components: main' '' \
    'Types: deb' 'URIs: https://deb.debian.org/debian-security' 'Suites: bookworm-security' 'Components: main' > "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources"
system_update_sources stage bookworm "$QUENCH_TEST_APT_ROOT/trixie.sources"
mkdir -p "$QUENCH_TEST_APT_ROOT/lists/partial"
apt-get -o Dir::Etc::sourcelist="$QUENCH_TEST_APT_ROOT/trixie.sources" -o Dir::Etc::sourceparts=- \
    -o Dir::State::lists="$QUENCH_TEST_APT_ROOT/lists" --print-uris update > "$QUENCH_TEST_APT_ROOT/uris"
grep -q '/dists/trixie/' "$QUENCH_TEST_APT_ROOT/uris"
grep -q '/dists/trixie-security/' "$QUENCH_TEST_APT_ROOT/uris"
! grep -q bookworm "$QUENCH_TEST_APT_ROOT/uris"

# Cloud-image mirror+file references and mixed backports suites must produce a
# candidate that real APT interprets exactly as the reviewed source plan.
mkdir -p "$QUENCH_UPDATE_APT_DIR/mirrors"
echo 'https://deb.debian.org/debian' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian.list"
echo 'https://security.debian.org/debian-security' > "$QUENCH_UPDATE_APT_DIR/mirrors/debian-security.list"
printf '%s\n' 'Types: deb deb-src' 'URIs: mirror+file:///etc/apt/mirrors/debian.list' \
    'Suites: bookworm bookworm-updates bookworm-backports' 'Components: main' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' '' \
    'Types: deb deb-src' 'URIs: mirror+file:/etc/apt/mirrors/debian-security.list' \
    'Suites: bookworm-security' 'Components: main' '' \
    'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: bookworm-backports' 'Components: main' '' \
    'Enabled: no' 'Types: deb' 'URIs: https://example.invalid/debian' 'Suites: bookworm' 'Components: main' \
    > "$QUENCH_UPDATE_APT_DIR/sources.list.d/debian.sources"
system_update_sources stage bookworm "$QUENCH_TEST_APT_ROOT/cloud.sources"
apt-get -o Dir::Etc::sourcelist="$QUENCH_TEST_APT_ROOT/cloud.sources" -o Dir::Etc::sourceparts=- \
    -o Dir::State::lists="$QUENCH_TEST_APT_ROOT/lists" --print-uris update > "$QUENCH_TEST_APT_ROOT/cloud-uris"
grep -q '/dists/trixie/' "$QUENCH_TEST_APT_ROOT/cloud-uris"
grep -q '/dists/trixie-updates/' "$QUENCH_TEST_APT_ROOT/cloud-uris"
grep -q '/dists/trixie-security/' "$QUENCH_TEST_APT_ROOT/cloud-uris"
! grep -Eq 'bookworm|backports|example.invalid|mirror\+file' "$QUENCH_TEST_APT_ROOT/cloud-uris"

# The auto-enable preflight must use real APT merge order (parts, then apt.conf),
# not merely grep the two files Quench writes. Nothing is written to host /etc.
mkdir -p "$QUENCH_UPDATE_APT_DIR/apt.conf.d"
printf '%s\n' 'APT::Periodic::Enable "0";' 'APT::Periodic::Update-Package-Lists "0";' \
    'APT::Periodic::Unattended-Upgrade "0";' > "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"
system_update_auto_template_safe "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"
system_update_auto_candidate_check "$QUENCH_TEST_APT_ROOT/auto-good" yes
if system_update_auto_candidate_check "$QUENCH_TEST_APT_ROOT/auto-disabled" no; then
    echo 'Real APT ignored the late template override' >&2; exit 1
fi
echo 'APT::Periodic::Enable "0";' > "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-admin-policy"
if system_update_auto_candidate_check "$QUENCH_TEST_APT_ROOT/auto-admin" yes; then
    echo 'Candidate validation bypassed an administrator override' >&2; exit 1
fi
rm "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-admin-policy"
echo 'Unattended-Upgrade::Automatic-Reboot "true";' > "$QUENCH_UPDATE_APT_DIR/apt.conf"
if system_update_auto_candidate_check "$QUENCH_TEST_APT_ROOT/auto-main" yes; then
    echo 'Candidate validation bypassed the main apt.conf' >&2; exit 1
fi
grep -q '"0"' "$QUENCH_UPDATE_APT_DIR/apt.conf.d/99-template-no-auto-upgrades"
echo "Real APT parsing and security-policy isolation passed on $CODE."
