#!/usr/bin/env bash
# Mutates accounts ONLY in a disposable Debian container explicitly opted in.
set -euo pipefail
[ "${QUENCH_TEST_USER_CONTAINER:-}" = 1 ] && [ -f /.dockerenv ] && [ "$(id -u)" = 0 ] \
    || { echo 'Run only in an explicitly opted-in disposable Docker container.' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export QUENCH_TEST_MODE=1
source "$ROOT/vps-quench.sh"
quench_rename_supported
for NAME in quench-original quench-renamed 19990; do
    if getent passwd "$NAME" >/dev/null; then echo "Fixture identity already exists: $NAME" >&2; exit 1; fi
done
mkdir -p /run/sshd /etc/cloud/cloud.cfg.d
ssh-keygen -A
WORK=$(mktemp -d /tmp/quench-rename-integration.XXXXXX)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
useradd -u 19990 -m -U -s /bin/bash -G sudo quench-original
install -d -m 700 -o quench-original -g quench-original /home/quench-original/.ssh
install -m 600 -o quench-original -g quench-original "$WORK/key.pub" /home/quench-original/.ssh/authorized_keys
printf '%s\n' 'quench-original ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-quench-test-original
chmod 440 /etc/sudoers.d/90-quench-test-original
printf '%s\n' 'system_info:' '  distro: debian' '  default_user:' '    name: quench-original' > /etc/cloud/cloud.cfg
ORIGINAL_UID=$(id -u quench-original)
ORIGINAL_GID=$(id -g quench-original)
ORIGINAL_SHADOW=$(getent shadow quench-original | cut -d: -f2-)
SUBUID=$(awk -F: '$1=="quench-original" {print $2 ":" $3}' /etc/subuid)
KEY=$(cat "$WORK/key.pub")
quench_rename_engine temp-create quench-original 3<<< "$KEY"
MAINT_RECORD=$(python3 -c 'import glob,json; print(next(json.load(open(p))["id"] for p in glob.glob("/var/lib/quench/user-rename/maint-*.json")))')
MAINT_USER="quench-$MAINT_RECORD"
runuser -u "$MAINT_USER" -- sudo -n true
PLAN=$(quench_rename_engine plan quench-original quench-renamed yes "$MAINT_USER")
printf '%s\n' "$PLAN"
IDENT=$(printf '%s\n' "$PLAN" | sed -n 's/^记录：//p')
quench_rename_engine apply "$IDENT" "$MAINT_USER"
[ "$(id -u quench-renamed)" = "$ORIGINAL_UID" ]
[ "$(id -g quench-renamed)" = "$ORIGINAL_GID" ]
[ "$(getent shadow quench-renamed | cut -d: -f2-)" = "$ORIGINAL_SHADOW" ]
[ "$(awk -F: '$1=="quench-renamed" {print $2 ":" $3}' /etc/subuid)" = "$SUBUID" ]
if getent passwd quench-original >/dev/null; then echo 'Old identity survived rename' >&2; exit 1; fi
cmp "$WORK/key.pub" /home/quench-renamed/.ssh/authorized_keys
runuser -u quench-renamed -- sudo -n true
grep -q 'name: quench-renamed' /etc/cloud/cloud.cfg
quench_rename_engine temp-clean "$MAINT_RECORD" quench-renamed
if getent passwd "$MAINT_USER" >/dev/null; then echo 'Temporary user survived cleanup' >&2; exit 1; fi
if getent group "$MAINT_USER" >/dev/null; then echo 'Temporary group survived cleanup' >&2; exit 1; fi
[ ! -e "/home/$MAINT_USER" ]
[ ! -e "/etc/sudoers.d/92-$MAINT_USER" ]
visudo -c
sshd -t
echo 'Real Debian account rename, stable UID/GID, key/sudo preservation and temporary account cleanup passed.'
