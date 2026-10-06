#!/usr/bin/env bash
# Real tmux + PTY handoff. Update actions are fixtures: no root/network/APT writes.
set -euo pipefail
command -v tmux >/dev/null || { echo 'SKIP: tmux is not installed'; exit 0; }
command -v python3 >/dev/null || { echo 'SKIP: python3 is not installed'; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
QUENCH_TEST_TMUX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/quench-test-tmux.XXXXXX")
export QUENCH_TEST_TMUX_ROOT
export QUENCH_TEST_TMUX_SCRIPT="$ROOT/vps-quench.sh"
export QUENCH_TEST_TMUX_SOCKET="$QUENCH_TEST_TMUX_ROOT/socket"
export QUENCH_TEST_TMUX_FIXTURE="$QUENCH_TEST_TMUX_ROOT/quench 'quoted' script.sh"
cleanup() {
    tmux -S "$QUENCH_TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
    rm -rf "$QUENCH_TEST_TMUX_ROOT"
}
trap cleanup EXIT
cat > "$QUENCH_TEST_TMUX_FIXTURE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export QUENCH_TEST_MODE=1
source "$QUENCH_TEST_TMUX_SCRIPT"
self_resolve_script_source() { printf '%s\n' "$QUENCH_TEST_TMUX_FIXTURE"; }
confirm_change_preview() { :; }
safety_timer_pending() { return 1; }
system_update_tmux_install() { echo 'Unexpected package installation' >&2; exit 9; }
ui_pause() { :; }
tmux() {
    # Keep all real tmux calls on this test's unique, owned socket.
    [ "$1" = -L ] && [ "$2" = quench ] || return 9
    shift 2
    command tmux -S "$QUENCH_TEST_TMUX_SOCKET" "$@"
}
system_update_action() {
    [ -n "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ] || return 9
    printf '%s\n' "$1" >> "$QUENCH_TEST_TMUX_ROOT/actions"
    printf '%s\n' "$0" > "$QUENCH_TEST_TMUX_ROOT/resumed-script"
}
system_update_debian_major() { system_update_action major; }
system_update_manager() {
    local ANSWER
    echo QUENCH_SESSION_READY
    read -r ANSWER
    [ "$ANSWER" = finish ]
}
if [ "${1:-}" = --system-update-resume ]; then
    system_update_resume "$2"
else
    system_update_dispatch "$1"
fi
SH
python3 - <<'PY'
import errno, fcntl, os, pathlib, pty, select, signal, struct, subprocess, termios, time

root = pathlib.Path(os.environ['QUENCH_TEST_TMUX_ROOT'])
fixture = os.environ['QUENCH_TEST_TMUX_FIXTURE']
socket = os.environ['QUENCH_TEST_TMUX_SOCKET']
clients = {}

def start(mode):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22')
        env.pop('TMUX', None)
        env.pop('STY', None)
        os.execvpe('bash', ['bash', fixture, mode], env)
    clients[pid] = fd
    return pid, fd

def ready(fd):
    output = b''
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.2)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            break
        if not chunk:
            break
        output += chunk
        if b'QUENCH_SESSION_READY' in output:
            return
    raise AssertionError('tmux session never became ready: ' + repr(output))

def exited(pid, fd):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            clients.pop(pid)
            os.close(fd)
            assert status == 0, ('client exit', status)
            return
        if select.select([fd], [], [], 0.1)[0]:
            try:
                os.read(fd, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
    raise AssertionError('tmux client did not exit')

try:
    pid, fd = start('current')
    ready(fd)
    assert (root / 'actions').read_text() == 'current\n'
    assert (root / 'resumed-script').read_text().strip() == fixture
    # Detach the client and exit its outer Quench process. The child must survive.
    os.write(fd, b'\x02d')
    exited(pid, fd)
    subprocess.run(['tmux', '-S', socket, 'has-session', '-t', '=quench-update'], check=True)
    # Selecting a DIFFERENT action must just attach to the original session.
    pid, fd = start('major')
    ready(fd)
    assert (root / 'actions').read_text() == 'current\n', 'upgrade executed twice'
    os.write(fd, b'finish\n')
    exited(pid, fd)
    assert subprocess.run(['tmux', '-S', socket, 'has-session', '-t', '=quench-update'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    print('Real tmux handoff, quoted argv, detach survival and reconnect passed.')
finally:
    for pid, fd in clients.items():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        os.close(fd)
PY
