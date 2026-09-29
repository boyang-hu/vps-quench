#!/usr/bin/env python3
"""Regression tests for the heuristic inventory itself; never execute shell code."""
import contextlib
import glob
import io
import os
import runpy
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.path.join(ROOT, 'tests', 'txn-inventory.py')
ROOTS = '''config_backup_allowed_roots() {
    local p
    for p in etc/ssh etc/apt etc/sysctl.d; do
        printf '%s\\n' "$p"
    done
}
'''


def scan(sources=None, reverse=False):
    original_glob, original_open = glob.glob, io.open
    fixture = None if sources is None else {
        os.path.join(ROOT, 'src', 'modules', name): body
        for name, body in dict({'toolbox.sh': ROOTS}, **sources).items()
    }

    def paths(pattern):
        if fixture is None:
            result = original_glob(pattern)
        else:
            result = list(fixture) if '/modules/' in pattern else []
        return list(reversed(result)) if reverse else result

    def read(path, *args, **kwargs):
        if fixture is not None and path in fixture:
            return io.StringIO(fixture[path])
        return original_open(path, *args, **kwargs)

    output = io.StringIO()
    with patch.object(glob, 'glob', paths), patch.object(io, 'open', read):
        with contextlib.redirect_stdout(output):
            state = runpy.run_path(INVENTORY)
    return output.getvalue(), state


class InventoryTests(unittest.TestCase):
    def test_local_target_does_not_leak_from_subshell(self):
        sources = {'update.sh': '''disable_updates() (
    local PM TARGET
    txn_write_begin "disable" || return 1
    TARGET="${QUENCH_APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
    cp "$STAGE" "$TARGET"
)
updates_menu() {
    disable_updates
}
''', 'export.sh': '''export_file() {
    local TARGET="$1"
    cp "$ARCHIVE" "$TARGET"
}
export_menu() {
    export_file
}
'''}
        for reverse in (False, True):
            output, state = scan(sources, reverse)
            self.assertEqual(output, '')
            self.assertIn('disable_updates', state['funcs'])
            self.assertNotIn('TARGET', state['pathvars'])
            self.assertIn('disable_updates', state['writers'])

    def test_unguarded_subshell_local_write_is_reported(self):
        output, _ = scan({'update.sh': '''disable_updates() (
    local TARGET="${QUENCH_APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
    cp "$STAGE" "$TARGET"
)
updates_menu() {
    disable_updates
}
'''})
        self.assertIn('update.sh:disable_updates', output)
        self.assertIn('TARGET', output)

    def test_local_shadow_does_not_hide_global_writes_elsewhere(self):
        output, _ = scan({'paths.sh': '''TARGET="/etc/ssh/sshd_config"
export_menu() {
    local TARGET="/tmp/quench-export"
    cp "$ARCHIVE" "$TARGET"
}
unsafe_menu() {
    cp "$STAGE" "$TARGET"
}
'''})
        self.assertNotIn('export_menu', output)
        self.assertIn('unsafe_menu', output)

    def test_all_possible_global_paths_are_checked(self):
        for first, second in (('/tmp/quench-export', '/etc/ssh/sshd_config'),
                              ('/etc/ssh/sshd_config', '/tmp/quench-export')):
            sources = {'a.sh': 'TARGET="%s"\n' % first,
                       'z.sh': 'TARGET="%s"\n' % second,
                       'main.sh': 'unsafe_menu() {\n    cp "$STAGE" "$TARGET"\n}\n'}
            output, _ = scan(sources)
            self.assertIn('unsafe_menu', output)
            self.assertEqual(output, scan(sources, reverse=True)[0])

    def test_local_derived_paths_are_detected_without_leaking(self):
        output, state = scan({'derived.sh': '''unsafe_menu() {
    local BASE="/etc/ssh" TARGET
    TARGET="$BASE/sshd_config"
    cp "$STAGE" "$TARGET"
}
export_menu() {
    local TARGET="$1"
    cp "$STAGE" "$TARGET"
}
'''})
        self.assertIn('unsafe_menu', output)
        self.assertNotIn('export_menu', output)
        self.assertNotIn('BASE', state['pathvars'])

    def test_guarded_wrapper_protects_callees(self):
        output, _ = scan({'guard.sh': '''writer() {
    cp "$STAGE" /etc/ssh/sshd_config
}
guarded() (
    txn_write_begin "change" || return 1
    writer
)
settings_menu() {
    guarded
}
'''})
        self.assertEqual(output, '')

    def test_unprotected_runtime_routes_are_still_reported(self):
        output, _ = scan({'route.sh': '''route_menu() {
    ip -4 route replace default via 192.0.2.1
}
'''})
        self.assertIn('runtime:default-route', output)

    def test_actual_sources_are_clean_and_order_independent(self):
        output, _ = scan()
        self.assertEqual(output, '')
        self.assertEqual(scan(reverse=True)[0], output)

    def test_removing_real_update_guard_is_detected(self):
        sources = {}
        for path in glob.glob(ROOT + '/src/lib/*.sh') + glob.glob(ROOT + '/src/modules/*.sh'):
            with open(path, encoding='utf-8') as source:
                sources[os.path.basename(path)] = source.read()
        original = sources['system-updates.sh']
        sources['system-updates.sh'] = original.replace(
            'txn_write_begin "关闭自动安全更新" || return 1', ': # deliberately removed by regression test')
        self.assertNotEqual(sources['system-updates.sh'], original)
        output, _ = scan(sources)
        self.assertIn('system-updates.sh:system_update_auto_disable', output)


if __name__ == '__main__':
    unittest.main()
