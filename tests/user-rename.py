#!/usr/bin/env python3
"""Exercise the shipped embedded engine on fake account DBs; no host mutations."""
import contextlib
import datetime
import io
import os
import pathlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = (ROOT / 'src/modules/user-rename.sh').read_text()
CODE = MODULE.split("<<'QUENCH_RENAME_PY'\n", 1)[1].split('\nQUENCH_RENAME_PY\n', 1)[0]
NS = {'__name__': 'quench_rename_fixture'}
exec(compile(CODE, str(ROOT / 'src/modules/user-rename.sh'), 'exec'), NS)
Rename, RenameError = NS['Rename'], NS['RenameError']

class Fixture(Rename):
    def __init__(self, root):
        super().__init__(root)
        self.calls, self.busy, self.leftovers = [], [], []
        self.failure = None
        self.after_failure = None
        self.hook = None
        for path in ('/etc/sudoers.d', '/etc/ssh/sshd_config.d', '/etc/cloud/cloud.cfg.d',
                     '/etc/systemd/system', '/home/alice/.ssh', '/var/lib/quench'):
            self.p(path).mkdir(parents=True)
        self.put('/etc/passwd', 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000:Alice:/home/alice:/bin/bash\n')
        self.put('/etc/shadow', 'root:!:19000:0:99999:7:::\nalice:$hash:19000:0:99999:7:::\n', 0o600)
        self.put('/etc/group', 'root:x:0:\nsudo:x:27:alice\nalice:x:1000:\n')
        self.put('/etc/gshadow', 'root:*::\nsudo:*::alice\nalice:!::\n', 0o600)
        self.put('/etc/subuid', 'alice:100000:65536\n')
        self.put('/etc/subgid', 'alice:100000:65536\n')
        self.put('/etc/login.defs', 'UID_MIN 1000\nUID_MAX 60000\n')
        self.put('/etc/sudoers', 'root ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n', 0o440)
        self.put('/etc/sudoers.d/90-cloud-init-users', '# Created by cloud-init\nalice ALL=(ALL) NOPASSWD:ALL\n', 0o440)
        self.put('/etc/ssh/sshd_config', 'Include /etc/ssh/sshd_config.d/*.conf\nUsePAM yes\nPubkeyAuthentication yes\n')
        self.put('/etc/cloud/cloud.cfg', 'users:\n  - default\nsystem_info:\n  default_user:\n    name: alice\n    lock_passwd: true\n')
        self.put('/home/alice/.ssh/authorized_keys', 'ssh-ed25519 Zml4dHVyZQ== test\n', 0o600)
        self.ssh_cfg = 'usepam yes\npubkeyauthentication yes\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\nauthorizedkeyscommand none\nauthenticationmethods any\n'
        self.setup()

    def put(self, name, data, mode=0o644):
        path = self.p(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            path.chmod(path.stat().st_mode | 0o200)
        path.write_text(data)
        path.chmod(mode)

    def rows(self, db):
        return [l.split(':') for l in self.p('/etc/' + db).read_text().splitlines()]

    def write_rows(self, db, rows):
        self.p('/etc/' + db).write_text(''.join(':'.join(r) + '\n' for r in rows))

    def home_owner(self, home, uid):
        # Test files belong to the developer/CI user; IDs in fake passwd do not.
        self.plain(self.p(home), directory=True)

    def mailbox(self, old, new, uid):
        # Same fixture ownership distinction as home_owner, while exercising
        # the real mailbox validation/move logic on real temporary files.
        return super().mailbox(old, new, self.owner)

    def run(self, *args, missing=False):
        self.calls.append(args)
        if self.hook:
            self.hook(args)
        if self.failure and args[:len(self.failure)] == self.failure:
            self.failure = None
            raise RenameError('injected before ' + args[0])
        result = self.fake_run(args)
        if self.after_failure and args[:len(self.after_failure)] == self.after_failure:
            self.after_failure = None
            raise RenameError('injected after ' + args[0])
        return result

    def fake_run(self, args):
        if args[0] == 'getent':
            rows = self.rows(args[1])
            if len(args) == 3:
                rows = [r for r in rows if r[0] == args[2]]
            return ''.join(':'.join(r) + '\n' for r in rows)
        if args[0] == 'id':
            row = next(r for r in self.rows('passwd') if r[0] == args[2])
            return ' '.join(sorted({row[3]} | {r[2] for r in self.rows('group') if args[2] in r[3].split(',')}))
        if args[0] == 'ps':
            return ''.join('123 %s %s bash\n' % (u, u) for u in self.busy)
        if args[0] == 'sshd':
            return self.ssh_cfg if '-T' in args else ''
        if args[0] in ('ssh-keygen', 'visudo', 'runuser', 'sudo'):
            return ''
        if args[0] == 'find':
            return '\n'.join(str(self.p(p)) for p in self.leftovers)
        if args[0] == 'usermod':
            user = args[-1]
            if args[1] == '-e':
                rows = self.rows('shadow')
                for row in rows:
                    if row[0] == user:
                        row[7] = args[2]
                self.write_rows('shadow', rows)
            else:
                new, home = args[2], args[4]
                # Debian 12's usermod does not rename subordinate ID entries.
                for db in ('passwd', 'shadow'):
                    rows = self.rows(db)
                    for row in rows:
                        if row[0] == user:
                            row[0] = new
                            if db == 'passwd':
                                row[5] = home
                    self.write_rows(db, rows)
                for db in ('group', 'gshadow'):
                    rows = self.rows(db)
                    for row in rows:
                        row[3] = ','.join(new if member == user else member for member in row[3].split(','))
                    self.write_rows(db, rows)
            return ''
        if args[0] == 'groupmod':
            for db in ('group', 'gshadow'):
                rows = self.rows(db)
                for row in rows:
                    if row[0] == args[-1]:
                        row[0] = args[2]
                self.write_rows(db, rows)
            return ''
        if args[0] == 'useradd':
            name = args[-1]
            uid = max(int(r[2]) for r in self.rows('passwd')) + 1
            comment = args[args.index('-c') + 1]
            expiry = str((datetime.date.fromisoformat(args[args.index('-e') + 1]) - datetime.date(1970, 1, 1)).days)
            for db, row in [('passwd', [name, 'x', str(uid), str(uid), comment, '/home/' + name, '/bin/bash']),
                            ('shadow', [name, '!', '19000', '0', '99999', '7', '', expiry, '']),
                            ('group', [name, 'x', str(uid), '']), ('gshadow', [name, '!', '', ''])]:
                self.write_rows(db, self.rows(db) + [row])
            rows = self.rows('group')
            next(r for r in rows if r[0] == 'sudo')[3] += ',' + name
            self.write_rows('group', rows)
            self.p('/home/' + name).mkdir()
            return ''
        if args[0] == 'userdel':
            name = args[-1]
            for db in ('passwd', 'shadow', 'subuid', 'subgid'):
                self.write_rows(db, [r for r in self.rows(db) if r[0] != name])
            for db in ('group', 'gshadow'):
                rows = self.rows(db)
                for row in rows:
                    row[3] = ','.join(m for m in row[3].split(',') if m != name)
                self.write_rows(db, rows)
            shutil.rmtree(self.p('/home/' + name))
            return ''
        if args[0] == 'groupdel':
            for db in ('group', 'gshadow'):
                self.write_rows(db, [r for r in self.rows(db) if r[0] != args[-1]])
            return ''
        raise AssertionError('Unmocked host command: ' + repr(args))

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='quench-test-rename-')
        self.addCleanup(self.tmp.cleanup)
        self.e = Fixture(self.tmp.name)
        self.out = io.StringIO()
        redirect = contextlib.redirect_stdout(self.out)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def plan(self, move=True):
        return self.e.plan('alice', 'boyang', move, 'root')

    def temp(self):
        with patch.object(NS['os'], 'chown'):
            self.e.temp_create('alice', 'ssh-ed25519 Zml4dHVyZQ== test')
        return next(r for r in self.e.records() if r['id'].startswith('maint-'))

    def assert_original(self, ident):
        rec = self.e.load(ident)
        self.assertEqual(rec['status'], 'rolled-back')
        self.e.verify(rec, restored=True)
        self.assertIn('name: alice', self.e.p('/etc/cloud/cloud.cfg').read_text())

    def test_uid_gid_password_keys_and_cloud_sudo_preserved(self):
        ident = self.plan()
        before = self.e.load(ident)['account']
        self.e.apply(ident, 'root')
        self.assertEqual(self.e.account('boyang'), dict(before, name='boyang', home='/home/boyang'))
        self.assertFalse(self.e.p('/home/alice').exists())
        self.assertIn('name: boyang', self.e.p('/etc/cloud/cloud.cfg').read_text())
        self.assertIn('boyang ALL=(ALL)', self.e.p('/etc/sudoers.d/90-cloud-init-users').read_text())
        self.assertEqual(self.e.p('/etc/subuid').read_text(), 'boyang:100000:65536\n')

    def test_keep_home(self):
        ident = self.plan(False)
        self.e.apply(ident, 'root')
        self.assertEqual(self.e.account('boyang')['home'], '/home/alice')

    def test_shared_primary_group_not_renamed(self):
        rows = self.e.rows('group')
        next(r for r in rows if r[0] == 'alice')[3] = 'someone'
        self.e.write_rows('group', rows)
        ident = self.plan()
        self.assertFalse(self.e.load(ident)['group'])
        self.e.apply(ident, 'root')
        self.assertIsNotNone(self.e.entry('alice', 'group'))

    def test_quench_nopasswd_filename_migrates(self):
        self.e.put('/etc/sudoers.d/91-quench-nopasswd-alice', '# Managed by Quench: passwordless sudo\nalice ALL=(ALL:ALL) NOPASSWD: ALL\n', 0o440)
        ident = self.plan()
        self.e.apply(ident, 'root')
        self.assertFalse(self.e.p('/etc/sudoers.d/91-quench-nopasswd-alice').exists())
        self.assertIn('boyang ALL', self.e.p('/etc/sudoers.d/91-quench-nopasswd-boyang').read_text())

    def test_sudo_collision(self):
        self.e.put('/etc/sudoers.d/91-quench-nopasswd-alice', 'alice ALL=(ALL) ALL\n', 0o440)
        self.e.put('/etc/sudoers.d/91-quench-nopasswd-boyang', 'root ALL=(ALL) ALL\n', 0o440)
        with self.assertRaises(RenameError): self.plan()

    def test_refuse_current_user(self):
        with self.assertRaises(RenameError): self.e.plan('alice', 'boyang', True, 'alice')

    def test_refuse_root(self):
        with self.assertRaises(RenameError): self.e.plan('root', 'boyang', True, 'alice')

    def test_refuse_destination(self):
        with self.assertRaises(RenameError): self.e.plan('alice', 'sudo', True, 'root')

    def test_refuse_busy(self):
        self.e.busy = [1000]
        with self.assertRaises(RenameError): self.plan()

    def test_busy_after_confirmation(self):
        ident = self.plan()
        self.e.busy = [1000]
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assertEqual(self.e.load(ident)['status'], 'prepared')

    def test_database_concurrent_change(self):
        ident = self.plan()
        self.e.p('/etc/passwd').write_text(self.e.p('/etc/passwd').read_text() + 'someone:x:1010:1010::/home/someone:/bin/bash\n')
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assertIsNotNone(self.e.entry('someone'))

    def test_config_concurrent_change(self):
        ident = self.plan()
        self.e.put('/etc/sudoers.d/98-other', 'bob ALL=(ALL) ALL\n', 0o440)
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')

    def test_home_symlink(self):
        home = self.e.p('/home/alice')
        home.rename(self.e.p('/home/elsewhere'))
        home.symlink_to(self.e.p('/home/elsewhere'))
        with self.assertRaises(RenameError): self.plan()

    def test_home_destination_exists(self):
        self.e.p('/home/boyang').mkdir()
        with self.assertRaises(RenameError): self.plan()

    def test_mount_in_home(self):
        self.e.put('/proc/self/mountinfo', '1 2 0:1 / /home/alice/data rw - ext4 /dev/test rw\n')
        with self.assertRaises(RenameError): self.plan()

    def test_empty_mailbox_moves(self):
        self.e.put('/var/mail/alice', '', 0o600)
        ident = self.plan()
        self.e.apply(ident, 'root')
        self.assertTrue(self.e.p('/var/mail/boyang').is_file())
        self.assertFalse(self.e.p('/var/mail/alice').exists())

    def test_empty_mailbox_restores(self):
        self.e.put('/var/mail/alice', '', 0o600)
        ident = self.plan()
        self.e.after_failure = ('groupmod',)
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assert_original(ident)
        self.assertTrue(self.e.p('/var/mail/alice').is_file())

    def test_mailbox_with_mail_refused(self):
        self.e.put('/var/mail/alice', 'keep this mail\n', 0o600)
        with self.assertRaises(RenameError): self.plan()

    def test_custom_mailbox_layout_refused(self):
        self.e.put('/etc/login.defs', 'UID_MIN 1000\nMAIL_DIR /custom/mail\n')
        with self.assertRaises(RenameError): self.plan()

    def test_wrong_home_owner(self):
        self.e.home_owner = lambda home, uid: Rename.home_owner(self.e, home, uid)
        self.e.p('/home/alice').chmod(0o777)
        with self.assertRaises(RenameError): self.plan()

    def test_unknown_service_reference(self):
        self.e.put('/etc/systemd/system/app.service', '[Service]\nUser=alice\n')
        with self.assertRaises(RenameError): self.plan()

    def test_custom_sudo_rule(self):
        self.e.put('/etc/sudoers.d/custom', 'alice ALL=(root) /bin/ls\n', 0o440)
        with self.assertRaises(RenameError): self.plan()

    def test_external_sudo_include(self):
        self.e.put('/etc/sudoers.d/custom', '@include /opt/other-sudo\n', 0o440)
        with self.assertRaises(RenameError): self.plan()

    def test_cloud_custom_user_list(self):
        self.e.put('/etc/cloud/cloud.cfg.d/custom.cfg', 'users:\n  - name: alice\n')
        with self.assertRaises(RenameError): self.plan()

    def test_cloud_debian_name_does_not_change_distro(self):
        self.e.put('/etc/cloud/cloud.cfg', 'system_info:\n  distro: debian\n  default_user:\n    name: debian\n  package_mirrors:\n    - uri: https://deb.debian.org/debian\n')
        patches, _ = self.e.references('debian', 'boyang')
        import base64
        text = base64.b64decode(next(p for p in patches if p['path'] == '/etc/cloud/cloud.cfg')['after']).decode()
        self.assertIn('name: boyang', text)
        self.assertIn('distro: debian', text)
        self.assertIn('https://deb.debian.org/debian', text)

    def test_subid_lock_not_stolen(self):
        ident = self.plan()
        self.e.put('/etc/subuid.lock', '99999\0', 0o600)
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assertEqual(self.e.p('/etc/subuid.lock').read_bytes(), b'99999\0')
        self.assertEqual(self.e.load(ident)['status'], 'recovery-required')
        self.e.p('/etc/subuid.lock').unlink()
        self.e.recover(ident, 'root')
        self.assert_original(ident)

    def test_subid_target_stale_allocation_refused(self):
        self.e.put('/etc/subuid', 'alice:100000:65536\nboyang:200000:65536\n')
        with self.assertRaises(RenameError): self.plan()

    def test_key_change_after_confirmation_refused(self):
        ident = self.plan()
        self.e.put('/home/alice/.ssh/authorized_keys', 'ssh-ed25519 Y2hhbmdlZA==\n', 0o600)
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assertEqual(self.e.load(ident)['status'], 'prepared')

    def test_crontab_blocks(self):
        self.e.put('/var/spool/cron/crontabs/alice', '* * * * * true\n')
        with self.assertRaises(RenameError): self.plan()

    def test_linger_blocks(self):
        self.e.put('/var/lib/systemd/linger/alice', '')
        with self.assertRaises(RenameError): self.plan()

    def test_ssh_match_blocks(self):
        self.e.put('/etc/ssh/sshd_config.d/match.conf', 'Match User alice\n  PasswordAuthentication no\n')
        with self.assertRaises(RenameError): self.plan()

    def test_ssh_effective_restriction(self):
        self.e.ssh_cfg += 'allowusers alice\n'
        with self.assertRaises(RenameError): self.plan()

    def test_rollback_partial_usermod(self):
        ident = self.plan()
        self.e.after_failure = ('usermod', '-l')
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assert_original(ident)

    def test_rollback_groupmod(self):
        ident = self.plan()
        self.e.after_failure = ('groupmod',)
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assert_original(ident)

    def test_rollback_config_partial_write(self):
        ident = self.plan()
        real = self.e.atomic
        def atomic(path, *args):
            if pathlib.Path(path) == self.e.p('/etc/sudoers.d/90-cloud-init-users'):
                self.e.atomic = real
                raise RenameError('write failed')
            return real(path, *args)
        self.e.atomic = atomic
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assert_original(ident)

    def test_rollback_expiration_failure(self):
        ident = self.plan()
        self.e.failure = ('usermod', '-e', '', 'boyang')
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assert_original(ident)

    def test_external_edit_preserved_and_manual_recovery(self):
        ident = self.plan()
        def hook(args):
            if args == ('usermod', '-e', '', 'boyang'):
                self.e.hook = None
                self.e.put('/etc/sudoers.d/90-cloud-init-users', 'external ALL=(ALL) ALL\n', 0o440)
                raise RenameError('concurrent edit')
        self.e.hook = hook
        with self.assertRaises(RenameError): self.e.apply(ident, 'root')
        self.assertEqual(self.e.load(ident)['status'], 'recovery-required')
        self.assertIn('external', self.e.p('/etc/sudoers.d/90-cloud-init-users').read_text())
        with self.assertRaises(RenameError): self.e.pending()
        self.e.put('/etc/sudoers.d/90-cloud-init-users', '# Created by cloud-init\nboyang ALL=(ALL) NOPASSWD:ALL\n', 0o440)
        self.e.recover(ident, 'root')
        self.assert_original(ident)

    def test_hard_interruption_recovery(self):
        ident = self.plan()
        rec = self.e.load(ident)
        rec['status'] = 'applying'
        self.e.save(rec)
        self.e.run('usermod', '-e', '1', 'alice')
        self.e.p('/home/alice').rename(self.e.p('/home/boyang'))
        self.e.recover(ident, 'root')
        self.assert_original(ident)

    def test_private_record_and_backup(self):
        ident = self.plan()
        self.e.apply(ident, 'root')
        self.assertEqual((self.e.state / (ident + '.json')).stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.e.state / (ident + '-backup/shadow')).stat().st_mode & 0o777, 0o600)

    def test_temp_prepare_and_cleanup_preserve_original_uid(self):
        rec = self.temp()
        self.assertEqual(rec['uid'], 1001)
        self.e.temp_clean(rec['id'], 'alice')
        self.assertIsNone(self.e.entry(rec['name']))
        self.assertIsNone(self.e.entry(rec['name'], 'group'))
        self.assertFalse(self.e.p(rec['home']).exists())
        self.assertFalse(self.e.p(rec['rule']).exists())
        self.assertEqual(self.e.account('alice')['uid'], 1000)
        self.assertEqual(self.e.load(rec['id'])['status'], 'deleted')
        self.assertEqual(self.temp()['uid'], 1001)  # no UID high-water counter

    def test_temp_cleanup_after_rename(self):
        rec = self.temp()
        ident = self.e.plan('alice', 'boyang', True, rec['name'])
        self.e.apply(ident, rec['name'])
        self.e.temp_clean(rec['id'], 'boyang')
        self.assertEqual(self.e.account('boyang')['uid'], 1000)

    def test_temp_duplicate_refused(self):
        self.temp()
        with self.assertRaises(RenameError): self.temp()

    def test_temp_self_cleanup_refused(self):
        rec = self.temp()
        with self.assertRaises(RenameError): self.e.temp_clean(rec['id'], rec['name'])

    def test_temp_busy_cleanup_refused(self):
        rec = self.temp()
        self.e.busy = [rec['uid']]
        with self.assertRaises(RenameError): self.e.temp_clean(rec['id'], 'alice')
        self.assertIsNotNone(self.e.entry(rec['name']))

    def test_temp_external_files_refused(self):
        rec = self.temp()
        self.e.leftovers = ['/opt/owned-by-temp']
        with self.assertRaises(RenameError): self.e.temp_clean(rec['id'], 'alice')
        self.assertIsNotNone(self.e.entry(rec['name']))

    def test_temp_changed_grant_refused(self):
        rec = self.temp()
        self.e.put(rec['rule'], 'external ALL=(ALL) ALL\n', 0o440)
        with self.assertRaises(RenameError): self.e.temp_clean(rec['id'], 'alice')

    def test_temp_failed_create_keeps_record(self):
        self.e.after_failure = ('useradd',)
        with self.assertRaises(RenameError): self.temp()
        rec = self.e.records()[0]
        self.assertEqual(rec['status'], 'creation-incomplete')
        self.e.temp_clean(rec['id'], 'alice')
        self.assertEqual(self.e.load(rec['id'])['status'], 'deleted')

    def test_temp_failed_delete_revokes_grant_and_can_retry(self):
        rec = self.temp()
        self.e.failure = ('userdel',)
        with self.assertRaises(RenameError): self.e.temp_clean(rec['id'], 'alice')
        self.assertFalse(self.e.p(rec['rule']).exists())
        self.e.temp_clean(rec['id'], 'alice')
        self.assertIsNone(self.e.entry(rec['name']))

    def test_record_path_traversal_refused(self):
        with self.assertRaises(RenameError): self.e.load('../../etc/passwd')

    def test_engine_wired_into_build_and_menu(self):
        self.assertIn('src/modules/user-rename.sh', (ROOT / 'build.sh').read_text())
        self.assertIn('r|R) quench_user_rename_menu', (ROOT / 'src/modules/user-menu.sh').read_text())
        self.assertIn('txn_write_begin', MODULE)
        self.assertIn('quench_rename_change rename', MODULE)

if __name__ == '__main__':
    unittest.main(verbosity=2)
