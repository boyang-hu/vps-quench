# ── Debian 用户改名：独立维护会话、持久记录、保留 UID/GID ──
# Python is embedded to keep the distributed script self-contained. Never eval
# journal contents or restore the entire account database over concurrent edits.
quench_rename_engine() {
    python3 - "$@" <<'QUENCH_RENAME_PY'
import base64, contextlib, datetime, hashlib, json, os, pathlib, re, shutil, signal, stat, subprocess, sys, tempfile, uuid

class RenameError(Exception):
    pass

class Rename:
    def __init__(self, root='/'):
        self.root = pathlib.Path(root).resolve()
        self.state = self.p('/var/lib/quench/user-rename')
        self.owner = os.geteuid()

    def p(self, name):
        return self.root / name.lstrip('/')

    def run(self, *args, missing=False):
        result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if missing and result.returncode == 2:
            return ''
        if result.returncode:
            raise RenameError('%s 失败：%s' % (args[0], result.stderr.strip() or result.returncode))
        return result.stdout

    def plain(self, path, directory=False, owned=False):
        path = pathlib.Path(path)
        if not path.is_relative_to(self.root):
            raise RenameError('路径超出范围：' + str(path))
        for part in [path, *path.parents]:
            if part == self.root:
                break
            if part.is_symlink():
                raise RenameError('不接管符号链接：' + str(part))
        s = path.stat()
        if not (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)):
            raise RenameError('不是预期的普通文件/目录：' + str(path))
        if owned and (s.st_uid != self.owner or s.st_mode & 0o022):
            raise RenameError('属主或写入权限不安全：' + str(path))
        return s

    def setup(self):
        for name in ('/var/lib/quench', '/var/lib/quench/user-rename'):
            path = self.p(name)
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.plain(path, directory=True, owned=True)
        os.chmod(self.state, 0o700)

    def atomic(self, path, data, mode=0o600, uid=None, gid=None):
        path = pathlib.Path(path)
        self.plain(path.parent, directory=True, owned=True)
        if path.exists() or path.is_symlink():
            self.plain(path, owned=True)
        fd, tmp = tempfile.mkstemp(prefix='.quench-rename.', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
                f.flush()
                os.fchmod(f.fileno(), mode)
                if uid is not None:
                    os.fchown(f.fileno(), uid, gid)
                os.fsync(f.fileno())
            os.replace(tmp, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def save(self, rec):
        self.atomic(self.state / (rec['id'] + '.json'), json.dumps(rec, ensure_ascii=False, indent=2).encode())

    def load(self, ident):
        if not re.fullmatch(r'(rename|maint)-[0-9a-f]{12}', ident):
            raise RenameError('记录编号无效')
        path = self.state / (ident + '.json')
        self.plain(path, owned=True)
        rec = json.loads(path.read_text())
        if rec['id'] != ident:
            raise RenameError('记录身份不一致')
        return rec

    def records(self):
        return [self.load(p.stem) for p in sorted(self.state.glob('*.json'))]

    def pending(self, own=None):
        for rec in self.records():
            if rec['id'] != own and rec['status'] in ('applying', 'recovery-required'):
                raise RenameError('先在改名菜单恢复未完成记录：' + rec['id'])

    def name(self, value):
        if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', value) or value == 'root':
            raise RenameError('拒绝 root 或无效用户名')
        return value

    def entry(self, name, db='passwd'):
        text = self.run('getent', db, name, missing=True).strip()
        if not text:
            return None
        rows = text.splitlines()
        if len(rows) != 1:
            raise RenameError('账户数据库返回不唯一：' + name)
        return rows[0].split(':')

    def account(self, name):
        self.name(name)
        entry = self.entry(name)
        local = [l.split(':') for l in self.p('/etc/passwd').read_text().splitlines() if l.split(':')[0] == name]
        if not entry or local != [entry]:
            raise RenameError('只接管本机 /etc/passwd 账户：' + name)
        limits = dict(re.findall(r'^\s*(UID_MIN|UID_MAX)\s+(\d+)', self.p('/etc/login.defs').read_text(), re.M))
        uid = int(entry[2])
        if not int(limits.get('UID_MIN', 1000)) <= uid <= int(limits.get('UID_MAX', 60000)):
            raise RenameError('拒绝系统账户/保留 UID')
        if len([l for l in self.run('getent', 'passwd').splitlines() if l.split(':')[2] == str(uid)]) != 1:
            raise RenameError('存在共享 UID，不支持改名')
        shadow = self.entry(name, 'shadow')
        if not shadow or len(shadow) != 9:
            raise RenameError('无法读取本地密码与过期策略')
        return {'name': name, 'uid': uid, 'gid': int(entry[3]), 'home': entry[5],
                'shell': entry[6], 'comment': entry[4], 'shadow': shadow[1:],
                'groups': sorted(int(x) for x in self.run('id', '-G', name).split())}

    def idle(self, uid):
        # Both real and effective UIDs matter, including login shells and tmux.
        text = self.run('ps', '-eo', 'pid=,ruid=,euid=,comm=')
        busy = [l for l in text.splitlines() if str(uid) in l.split()[1:3]]
        if busy:
            raise RenameError('用户仍有进程；请退出其全部 SSH/tmux/screen 会话，不会自动杀进程：\n' + '\n'.join(busy[:12]))

    def keys(self, account):
        home = self.p(account['home'])
        self.plain(home, directory=True)
        self.plain(home / '.ssh', directory=True)
        key = home / '.ssh/authorized_keys'
        self.plain(key)
        self.run('ssh-keygen', '-l', '-f', str(key))
        return hashlib.sha256(key.read_bytes()).hexdigest()

    def home_owner(self, home, uid):
        s = self.plain(self.p(home), directory=True)
        if s.st_uid != uid or s.st_mode & 0o022:
            raise RenameError('家目录属主/写入权限不安全：' + home)

    def ssh_guard(self, name):
        self.run('sshd', '-t')
        cfg = dict(line.split(' ', 1) for line in self.run('sshd', '-T', '-C',
                   'user=%s,host=localhost,addr=127.0.0.1' % name).splitlines() if ' ' in line)
        for key in ('allowusers', 'denyusers', 'allowgroups', 'denygroups'):
            if cfg.get(key):
                raise RenameError('存在 SSH 用户/组访问限制，需先人工迁移：' + key)
        if cfg.get('usepam') != 'yes' or cfg.get('pubkeyauthentication') != 'yes':
            raise RenameError('向导需要 UsePAM yes 和公钥认证；不会修改 SSH 策略')
        if cfg.get('authorizedkeyscommand', 'none') != 'none' or cfg.get('authorizedkeysfile') not in (
                '.ssh/authorized_keys', '.ssh/authorized_keys .ssh/authorized_keys2'):
            raise RenameError('自定义 SSH 公钥来源需要人工迁移')
        if cfg.get('authenticationmethods', 'any') not in ('any', 'publickey'):
            raise RenameError('多因素/定制认证策略需要人工处理')

    def fingerprint(self):
        out = {}
        for name in ('passwd', 'shadow', 'group', 'gshadow', 'subuid', 'subgid', 'login.defs'):
            path = self.p('/etc/' + name)
            if path.exists() or path.is_symlink():
                self.plain(path, owned=True)
                out[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        return out

    def mailbox(self, old, new, uid):
        config = self.p('/etc/login.defs').read_text()
        layout = re.findall(r'^\s*MAIL_(DIR|FILE)\s+(\S+)', config, re.M)
        if any(kind == 'FILE' or value != '/var/mail' for kind, value in layout):
            raise RenameError('自定义邮箱布局需人工迁移')
        source, target = self.p('/var/mail/' + old), self.p('/var/mail/' + new)
        if target.exists() or target.is_symlink():
            raise RenameError('目标邮箱已存在')
        if not source.exists() and not source.is_symlink():
            return None
        s = self.plain(source)
        if s.st_uid != uid or s.st_size or s.st_nlink != 1:
            raise RenameError('仅自动迁移归属正确的空邮箱；非空/共享邮箱请人工处理')
        return {'uid': s.st_uid, 'gid': s.st_gid, 'mode': stat.S_IMODE(s.st_mode)}

    def move_mail(self, rec, restore=False):
        source = self.p('/var/mail/' + (rec['new'] if restore else rec['old']))
        target = self.p('/var/mail/' + (rec['old'] if restore else rec['new']))
        paths = [p for p in (source, target) if p.exists() or p.is_symlink()]
        expected = rec.get('mail')
        if not expected:
            if paths:
                raise RenameError('迁移期间意外出现邮箱，请人工确认')
            return
        if len(paths) != 1:
            raise RenameError('邮箱迁移状态异常')
        s = self.plain(paths[0])
        if s.st_size or s.st_nlink != 1 or {'uid': s.st_uid, 'gid': s.st_gid, 'mode': stat.S_IMODE(s.st_mode)} != expected:
            raise RenameError('邮箱发生变化，请人工处理，不会覆盖邮件')
        if paths[0] == source:
            os.rename(source, target)

    def references(self, old, new, group=False, skip=None):
        """Only simple ALL sudo rules and cloud-init default_user.name migrate.
        Everything else naming the account in these known locations blocks.
        This is deliberately not a promise to discover arbitrary app databases.
        """
        token = re.compile(r'(?<![\w-])' + re.escape(old) + r'(?![\w-])')
        patches, inventory, blocked = [], {}, []
        roots = ['/etc/sudoers', '/etc/sudoers.d', '/etc/ssh/sshd_config', '/etc/ssh/sshd_config.d',
                 '/etc/subuid', '/etc/subgid',
                 '/etc/cloud/cloud.cfg', '/etc/cloud/cloud.cfg.d', '/etc/systemd/system',
                 '/usr/lib/systemd/system', '/etc/crontab', '/etc/cron.d', '/etc/cron.daily',
                 '/etc/cron.hourly', '/etc/cron.weekly', '/etc/cron.monthly', '/etc/security',
                 '/var/lib/cloud/instance/user-data.txt', '/var/lib/cloud/instance/vendor-data.txt']
        paths = set()
        for name in roots:
            path = self.p(name)
            if path.is_dir():
                paths.update(p for p in path.rglob('*') if not p.is_dir())
            elif path.exists() or path.is_symlink():
                paths.add(path)
        for path in sorted(paths):
            rel = '/' + str(path.relative_to(self.root))
            if rel == skip:
                continue
            # A systemd mask is a unit symlink to /dev/null, not a config to
            # read. Track it so unmasking during confirmation still invalidates
            # the plan; other special files remain unsupported.
            if (rel.startswith(('/etc/systemd/system/', '/usr/lib/systemd/system/')) and
                    path.is_symlink() and path.resolve() == pathlib.Path('/dev/null')):
                inventory[rel] = 'systemd-mask:/dev/null'
                continue
            if not path.exists():
                if path.is_symlink():
                    continue  # disabled/dangling systemd aliases
                raise RenameError('引用扫描期间文件消失：' + rel)
            if not path.is_file():
                raise RenameError('无法扫描非普通配置：' + rel)
            if path.stat().st_size > 2 * 1024 * 1024:
                raise RenameError('配置过大，需人工检查：' + rel)
            data = path.read_bytes()
            inventory[rel] = hashlib.sha256(data).hexdigest()
            text = data.decode('utf-8', errors='replace')
            if rel in ('/etc/subuid', '/etc/subgid') and old != new and any(l.split(':')[0] == new for l in text.splitlines()):
                raise RenameError('目标名字已有 subordinate ID 分配：' + rel)
            output, cloud_indent = [], None
            for number, line in enumerate(text.splitlines(keepends=True), 1):
                stripped = line.strip()
                active = stripped and not stripped.startswith('#')
                # sudo includes starting with # are real directives.
                if rel.startswith('/etc/sudoers') and re.match(r'^[#@]include', stripped):
                    if stripped not in ('@includedir /etc/sudoers.d', '#includedir /etc/sudoers.d'):
                        blocked.append('%s:%s 自定义 sudo include' % (rel, number))
                    active = False
                if rel.startswith('/etc/ssh/') and active:
                    if re.match(r'(?i)^match\s', stripped) and stripped.lower() != 'match all':
                        blocked.append('%s:%s SSH Match 条件需人工确认' % (rel, number))
                    if re.match(r'(?i)^include\s', stripped) and stripped.lower() != 'include /etc/ssh/sshd_config.d/*.conf':
                        blocked.append('%s:%s 自定义 SSH Include' % (rel, number))
                changed = line
                if rel in ('/etc/subuid', '/etc/subgid') and re.fullmatch(re.escape(old) + r':\d+:\d+\n?', line):
                    changed = new + line[len(old):]
                if rel.startswith('/etc/cloud/') and active:
                    indent = len(line) - len(line.lstrip(' '))
                    if cloud_indent is not None and indent <= cloud_indent:
                        cloud_indent = None
                    if re.fullmatch(r'default_user:\s*(?:#.*)?', stripped):
                        cloud_indent = indent
                    match = re.fullmatch(r'(\s*name:\s*)([\'\"]?)' + re.escape(old) + r'\2(\s*(?:#.*)?)(\r?\n)?', line)
                    if match and cloud_indent is not None:
                        changed = match[1] + match[2] + new + match[2] + match[3] + (match[4] or '')
                if rel.startswith('/etc/sudoers') and active:
                    match = re.fullmatch(r'(\s*)(%?)' + re.escape(old) + r'(\s+ALL\s*=\s*\(ALL(?::ALL)?\)\s*(?:NOPASSWD:\s*)?ALL\s*(?:#.*)?)(\r?\n)?', line)
                    if match and (not match[2] or group):
                        changed = match[1] + match[2] + new + match[3] + (match[4] or '')
                # The cloud image's default login is often literally 'debian'.
                # Its distro field / official archive URI are not user references.
                distro_value = rel.startswith('/etc/cloud/') and old == 'debian' and (
                    re.fullmatch(r'distro:\s*[\'\"]?debian[\'\"]?\s*(?:#.*)?', stripped) or
                    re.fullmatch(r'(?:-\s*)?(?:uri|primary|security):\s*[\'\"]?https?://(?:deb|security|archive)\.debian\.org/debian(?:-security)?/?[\'\"]?\s*(?:#.*)?', stripped))
                if active and token.search(line) and changed == line and not distro_value:
                    blocked.append('%s:%s 引用了旧用户名' % (rel, number))
                output.append(changed)
            candidate = ''.join(output).encode()
            if candidate != data:
                s = self.plain(path, owned=True)
                target = rel
                if rel == '/etc/sudoers.d/91-quench-nopasswd-' + old:
                    target = '/etc/sudoers.d/91-quench-nopasswd-' + new
                    if self.p(target).exists() or self.p(target).is_symlink():
                        raise RenameError('目标 sudoers 文件已存在：' + target)
                patches.append({'path': rel, 'target': target, 'before': base64.b64encode(data).decode(),
                                'after': base64.b64encode(candidate).decode(), 'mode': stat.S_IMODE(s.st_mode),
                                'uid': s.st_uid, 'gid': s.st_gid})
        for name in ('/var/spool/cron/crontabs/', '/var/lib/systemd/linger/'):
            if self.p(name + old).exists() or self.p(name + old).is_symlink():
                blocked.append(name + old + ' 需要先人工迁移/清理')
        if blocked:
            raise RenameError('检测到不支持自动迁移的引用：\n' + '\n'.join(blocked[:30]))
        return patches, inventory

    def home_guard(self, home, target=None):
        if not re.fullmatch(r'/home/[a-z_][a-z0-9_-]{0,31}', home):
            raise RenameError('自动处理仅支持 /home/<用户名> 普通家目录')
        path = self.p(home)
        self.plain(path, directory=True)
        self.plain(path.parent, directory=True, owned=True)
        # Moving/removing mounted home directories could lose unrelated data.
        if path.stat().st_dev != path.parent.stat().st_dev or path.is_mount():
            raise RenameError('家目录是独立挂载点，需人工迁移')
        mountinfo = self.p('/proc/self/mountinfo')
        if mountinfo.exists():
            for line in mountinfo.read_text().splitlines():
                point = line.split()[4].replace('\\040', ' ')
                if point == home or point.startswith(home + '/'):
                    raise RenameError('家目录含挂载点，需先卸载：' + point)
        if target and (self.p(target).exists() or self.p(target).is_symlink()):
            raise RenameError('目标家目录已存在：' + target)

    def plan(self, old, new, move, actor):
        self.pending()
        self.name(new)
        if old == new or old == actor or old.startswith('quench-maint-'):
            raise RenameError('不能改名当前登录用户/临时维护账号，或使用相同名字')
        account = self.account(old)
        if account['shell'].endswith(('nologin', '/false')):
            raise RenameError('拒绝服务账户')
        if self.entry(new) or self.entry(new, 'group'):
            raise RenameError('目标用户或组已存在')
        self.idle(account['uid'])
        keys = self.keys(account)
        self.ssh_guard(old)
        self.ssh_guard(new)
        self.run('visudo', '-c')
        home = '/home/' + new if move else account['home']
        if move and account['home'] != '/home/' + old:
            raise RenameError('自定义家目录请选“不移动家目录”或人工迁移')
        self.home_guard(account['home'], home if move else None)
        self.home_owner(account['home'], account['uid'])
        mail = self.mailbox(old, new, account['uid'])
        primary = self.entry(old, 'group')
        local_group = [l.split(':') for l in self.p('/etc/group').read_text().splitlines() if l.split(':')[0] == old]
        private = bool(primary and local_group == [primary] and int(primary[2]) == account['gid'] and
                       set(filter(None, primary[3].split(','))) <= {old} and
                       all(l.split(':')[0] == old or int(l.split(':')[3]) != account['gid']
                           for l in self.run('getent', 'passwd').splitlines()))
        patches, inventory = self.references(old, new, private)
        rec = {'id': 'rename-' + uuid.uuid4().hex[:12], 'status': 'prepared', 'old': old, 'new': new,
               'account': account, 'new_home': home, 'group': private, 'keys': keys, 'mail': mail,
               'patches': patches, 'inventory': inventory, 'database': self.fingerprint()}
        self.save(rec)
        print('保持 UID %s / GID %s，家目录 %s → %s，同名私有组改名：%s' %
              (account['uid'], account['gid'], account['home'], home, '是' if private else '否'))
        for patch in patches:
            print('迁移配置：%s → %s' % (patch['path'], patch['target']))
        print('记录：' + rec['id'])
        return rec['id']

    @contextlib.contextmanager
    def subid_lock(self, path):
        # shadow-utils uses a PID-bearing .lock file. O_EXCL respects its
        # exclusion protocol; never guess at or delete someone else's lock.
        if path.name not in ('subuid', 'subgid') or path.parent != self.p('/etc'):
            yield
            return
        lock = pathlib.Path(str(path) + '.lock')
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        inode = os.fstat(fd).st_ino
        try:
            os.write(fd, (str(os.getpid()) + '\0').encode())
            os.close(fd)
            fd = None
            yield
        finally:
            if fd is not None:
                os.close(fd)
            if lock.exists() and lock.lstat().st_ino == inode:
                lock.unlink()

    def write_patches(self, rec, restore=False):
        for patch in (reversed(rec['patches']) if restore else rec['patches']):
            with self.subid_lock(self.p(patch['path'])):
                self.write_patch(patch, restore)

    def write_patch(self, patch, restore=False):
        src, dst = self.p(patch['path']), self.p(patch['target'])
        before, after = (base64.b64decode(patch[k]) for k in ('before', 'after'))
        for path in {src, dst}:
            if path.exists() or path.is_symlink():
                self.plain(path, owned=True)
                if path.read_bytes() not in (before, after):
                    raise RenameError('配置已被其他程序修改，保留现场：' + str(path))
        if not restore and (not src.exists() or src.read_bytes() not in (before, after)):
            raise RenameError('原配置已变化：' + str(src))
        self.atomic(src if restore else dst, before if restore else after,
                    patch['mode'], patch['uid'], patch['gid'])
        extra = dst if restore else src
        if src != dst and extra.exists():
            extra.unlink()

    def verify(self, rec, restored=False):
        expected = dict(rec['account'])
        if not restored:
            expected.update(name=rec['new'], home=rec['new_home'])
        if self.account(expected['name']) != expected:
            raise RenameError('UID/GID、组成员、密码策略、shell 或家目录验证失败')
        if self.entry(rec['new'] if restored else rec['old']):
            raise RenameError('旧/新账户意外同时存在')
        if self.keys(expected) != rec['keys']:
            raise RenameError('SSH 公钥内容发生变化')
        self.home_owner(expected['home'], expected['uid'])
        other = rec['new'] if restored else rec['old']
        if self.mailbox(expected['name'], other, expected['uid']) != rec.get('mail'):
            raise RenameError('邮箱状态验证失败')
        for patch in rec['patches']:
            path = self.p(patch['path'] if restored else patch['target'])
            wanted = base64.b64decode(patch['before'] if restored else patch['after'])
            if not path.is_file() or path.read_bytes() != wanted:
                raise RenameError('迁移配置验证失败：' + str(path))
        if rec['group']:
            group = self.entry(expected['name'], 'group')
            if not group or int(group[2]) != expected['gid']:
                raise RenameError('私有组 GID 验证失败')
        self.run('visudo', '-c')
        self.ssh_guard(expected['name'])

    def restore(self, rec):
        old, new, account = rec['old'], rec['new'], rec['account']
        self.idle(account['uid'])
        current = self.entry(new) or self.entry(old)
        if not current or int(current[2]) != account['uid'] or int(current[3]) != account['gid']:
            raise RenameError('账户身份变化，拒绝自动恢复')
        if self.entry(new) and self.entry(old):
            raise RenameError('两个账户同时存在，拒绝覆盖')
        self.run('usermod', '-e', '1', current[0])
        if current[0] == new:
            self.run('usermod', '-l', old, '-d', account['home'], new)
        self.move_mail(rec, restore=True)
        if rec['group'] and self.entry(new, 'group'):
            if self.entry(old, 'group') or int(self.entry(new, 'group')[2]) != account['gid']:
                raise RenameError('组身份变化，拒绝恢复')
            self.run('groupmod', '-n', old, new)
        if rec['new_home'] != account['home'] and self.p(rec['new_home']).exists():
            self.home_guard(rec['new_home'], account['home'])
            os.rename(self.p(rec['new_home']), self.p(account['home']))
        self.write_patches(rec, restore=True)
        self.run('usermod', '-e', account['shadow'][6], old)
        self.verify(rec, restored=True)
        rec['status'] = 'rolled-back'
        self.save(rec)

    def apply(self, ident, actor):
        rec = self.load(ident)
        self.pending(ident)
        if rec['status'] != 'prepared' or actor in (rec['old'], rec['new']):
            raise RenameError('记录状态或当前会话不允许执行')
        if self.account(rec['old']) != rec['account'] or self.fingerprint() != rec['database']:
            raise RenameError('确认期间账户数据库变化，请重新生成计划')
        if self.entry(rec['new']) or self.entry(rec['new'], 'group') or self.keys(rec['account']) != rec['keys']:
            raise RenameError('确认期间目标身份或公钥变化，请重新生成计划')
        if self.mailbox(rec['old'], rec['new'], rec['account']['uid']) != rec.get('mail'):
            raise RenameError('确认期间邮箱发生变化，请重新生成计划')
        if self.references(rec['old'], rec['new'], rec['group']) != (rec['patches'], rec['inventory']):
            raise RenameError('确认期间配置变化，请重新生成计划')
        self.idle(rec['account']['uid'])
        self.home_guard(rec['account']['home'], rec['new_home'] if rec['new_home'] != rec['account']['home'] else None)
        self.home_owner(rec['account']['home'], rec['account']['uid'])
        backup = self.state / (ident + '-backup')
        backup.mkdir(mode=0o700)
        for name in rec['database']:
            shutil.copy2(self.p('/etc/' + name), backup / name)
            os.chmod(backup / name, 0o600)
        rec['status'] = 'applying'
        self.save(rec)
        try:
            # Account expiration blocks new PAM logins, including keys. Do not
            # kill existing sessions or weaken SSH authentication to get around it.
            self.run('usermod', '-e', '1', rec['old'])
            self.idle(rec['account']['uid'])
            if rec['new_home'] != rec['account']['home']:
                os.rename(self.p(rec['account']['home']), self.p(rec['new_home']))
            self.run('usermod', '-l', rec['new'], '-d', rec['new_home'], rec['old'])
            self.move_mail(rec)
            if rec['group']:
                self.run('groupmod', '-n', rec['new'], rec['old'])
            self.write_patches(rec)
            self.run('visudo', '-c')
            self.run('usermod', '-e', rec['account']['shadow'][6], rec['new'])
            self.verify(rec)
            rec['status'] = 'renamed'
            self.save(rec)
        except BaseException as exc:
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, signal.SIG_IGN)
            try:
                self.restore(rec)
                detail = '已验证恢复原账户'
            except BaseException as recovery:
                rec['status'] = 'recovery-required'
                self.save(rec)
                detail = '恢复未确认，请保留维护会话并使用恢复入口：%s (%s)' % (ident, recovery)
            raise RenameError('%s；%s' % (exc, detail))
        print('改名完成，UID/GID 未变。请另开终端用新名字登录并测试 sudo，再清理临时账号。')

    def temp_create(self, source, key):
        self.pending()
        account = self.account(source)
        for rec in self.records():
            if rec['id'].startswith('maint-') and rec.get('source_uid') == account['uid'] and rec['status'] != 'deleted':
                raise RenameError('已有临时账号记录，请先查看/清理：' + rec['id'])
        if not self.entry('sudo', 'group'):
            raise RenameError('缺少 Debian sudo 管理员组')
        if not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+(?: [^\r\n]*)?', key):
            raise RenameError('只接受单行、无附加选项的 SSH 公钥')
        ident = 'maint-' + uuid.uuid4().hex[:12]
        name = 'quench-' + ident
        home = '/home/' + name
        rule = '/etc/sudoers.d/92-' + name
        comment = 'Quench temporary maintenance ' + ident
        if self.entry(name) or self.entry(name, 'group') or self.p(home).exists() or self.p(home).is_symlink() or self.p(rule).exists() or self.p('/var/mail/' + name).exists() or self.p('/var/mail/' + name).is_symlink():
            raise RenameError('临时账号目标冲突，请重试')
        self.ssh_guard(name)
        self.references(name, name, skip=rule)
        self.run('visudo', '-c')
        keyfile = self.state / (ident + '.pub')
        self.atomic(keyfile, (key + '\n').encode())
        self.run('ssh-keygen', '-l', '-f', str(keyfile))
        rec = {'id': ident, 'status': 'creating', 'name': name, 'source_uid': account['uid'],
               'home': home, 'rule': rule, 'comment': comment}
        self.save(rec)  # Before useradd, so interruption cannot hide the account.
        try:
            skeleton = self.state / 'empty-skel'
            skeleton.mkdir(mode=0o700, exist_ok=True)
            self.plain(skeleton, directory=True, owned=True)
            if any(skeleton.iterdir()):
                raise RenameError('临时账号专用 skeleton 目录不是空目录')
            expiry = str(datetime.date.today() + datetime.timedelta(days=3))
            self.run('useradd', '-m', '-U', '-s', '/bin/bash', '-G', 'sudo', '-c', comment,
                     '-k', str(skeleton), '-e', expiry, '-K', 'SUB_UID_COUNT=0', '-K', 'SUB_GID_COUNT=0', name)
            entry = self.account(name)
            rec.update(uid=entry['uid'], gid=entry['gid'])
            self.save(rec)
            sshdir = self.p(home + '/.ssh')
            sshdir.mkdir(mode=0o700)
            auth = sshdir / 'authorized_keys'
            self.atomic(auth, (key + '\n').encode(), 0o600)
            os.chown(auth, entry['uid'], entry['gid'])
            os.chown(sshdir, entry['uid'], entry['gid'])
            rule_data = ('# Managed by Quench: temporary maintenance %s\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' % (ident, name)).encode()
            self.atomic(self.p(rule), rule_data, 0o440)
            self.run('visudo', '-c')
            self.run('runuser', '-u', name, '--', 'sudo', '-n', 'true')
            rec['status'] = 'temporary'
            self.save(rec)
        except BaseException:
            rec['status'] = 'creation-incomplete'
            self.save(rec)
            raise RenameError('临时账号创建未完成，未执行改名。请从清理入口处理记录：' + ident)
        print('临时账号：%s（UID %s，%s 到期；无密码，仅公钥，免密 sudo）' % (name, rec['uid'], expiry))
        print('另开终端登录该账号，执行 sudo -n true，再用 sudo v → 1 → r → 1 改名。')
        print('请退出原账号的所有 SSH/tmux/screen 会话；不会自动关闭你的连接。')
        print('记录：' + ident)

    def residue(self, rec):
        # Scan each mounted local filesystem, not just /home. Never delete by
        # numeric UID: the user reviews unexpected files instead of losing data.
        mounts = {'/'}
        info = self.p('/proc/self/mountinfo')
        if info.exists():
            for line in info.read_text().splitlines():
                left, right = line.split(' - ', 1)
                if right.split()[0] in ('ext2', 'ext3', 'ext4', 'xfs', 'btrfs', 'zfs', 'overlay', 'f2fs', 'tmpfs'):
                    mounts.add(left.split()[4].replace('\\040', ' '))
        unexpected = []
        for mount in sorted(mounts):
            found = self.run('find', str(self.p(mount)), '-xdev', '(', '-uid', str(rec['uid']), '-o',
                             '-gid', str(rec['gid']), ')', '-print')
            for name in found.splitlines():
                path = pathlib.Path(name)
                home = self.p(rec['home'])
                if path != home and not path.is_relative_to(home) and path != self.p('/var/mail/' + rec['name']):
                    unexpected.append(name)
        if unexpected:
            raise RenameError('临时 UID/GID 在家目录外仍拥有文件，请先人工处理（不会按 UID 全盘删除）：\n' + '\n'.join(unexpected[:30]))

    def temp_clean(self, ident, actor):
        self.pending()
        rec = self.load(ident)
        if not ident.startswith('maint-') or rec['status'] == 'deleted' or actor == rec['name']:
            raise RenameError('不是待清理临时账号，或仍在使用它登录')
        keeper = self.account(actor)  # Must actually be back in the retained UID.
        if keeper['uid'] != rec['source_uid']:
            raise RenameError('请先用原账号/改名后的账号登录并通过 sudo 进入 Quench，再清理临时账号')
        self.keys(keeper)
        self.ssh_guard(actor)
        self.run('sudo', '-l', '-U', actor)
        entry = self.entry(rec['name'])
        if entry:
            account = self.account(rec['name'])
            if account['comment'] != rec['comment'] or account['home'] != rec['home']:
                raise RenameError('临时账号身份或家目录变化，拒绝删除')
            if 'uid' in rec and (account['uid'], account['gid']) != (rec['uid'], rec['gid']):
                raise RenameError('临时 UID/GID 已变化，拒绝删除')
            rec.update(uid=account['uid'], gid=account['gid'])
            self.save(rec)
            self.idle(rec['uid'])
            self.home_guard(rec['home'])
            self.home_owner(rec['home'], rec['uid'])
            mail = self.p('/var/mail/' + rec['name'])
            if mail.exists() or mail.is_symlink():
                s = self.plain(mail)
                if s.st_uid != rec['uid'] or s.st_nlink != 1:
                    raise RenameError('临时邮箱属主或链接异常，拒绝清理')
            self.references(rec['name'], rec['name'], skip=rec['rule'])
            self.residue(rec)
        elif 'uid' not in rec:
            if self.p(rec['home']).exists() or self.entry(rec['name'], 'group'):
                raise RenameError('创建中断且身份无法确认，请人工清理')
        rule = self.p(rec['rule'])
        expected = ('# Managed by Quench: temporary maintenance %s\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' % (ident, rec['name'])).encode()
        if rule.exists() or rule.is_symlink():
            self.plain(rule, owned=True)
            if rule.read_bytes() != expected:
                raise RenameError('临时 sudo 授权被改动，拒绝删除')
        if entry:
            self.run('usermod', '-e', '1', rec['name'])
            self.idle(rec['uid'])
        # Revoke our grant before userdel, so a partial userdel failure cannot
        # leave a passwordless grant for a future account reusing the name.
        if rule.exists():
            rule.unlink()
        self.run('visudo', '-c')
        if entry:
            self.run('userdel', '-r', rec['name'])
        if self.entry(rec['name']):
            raise RenameError('账户仍存在，清理未完成')
        if self.p(rec['home']).exists() or self.p(rec['home']).is_symlink():
            raise RenameError('家目录仍存在，清理未完成；请人工核对，不会递归强删')
        if self.p('/var/mail/' + rec['name']).exists() or self.p('/var/mail/' + rec['name']).is_symlink():
            raise RenameError('临时邮箱仍存在，清理未完成')
        group = self.entry(rec['name'], 'group')
        if group:
            if int(group[2]) != rec.get('gid') or group[3] or any(int(l.split(':')[3]) == rec['gid'] for l in self.run('getent', 'passwd').splitlines()):
                raise RenameError('同名组仍被使用，拒绝删除')
            self.run('groupdel', rec['name'])
        if rule.exists():
            rule.unlink()
        self.run('visudo', '-c')
        if 'uid' in rec:
            self.residue(rec)
        pub = self.state / (ident + '.pub')
        if pub.exists():
            pub.unlink()
        rec['status'] = 'deleted'
        self.save(rec)
        print('临时账号、专属组、家目录和 sudo 授权已清理；保留审计记录，不占用 UID。')

    def recover(self, ident, actor):
        rec = self.load(ident)
        self.pending(ident)
        if rec['status'] not in ('applying', 'recovery-required') or actor in (rec['old'], rec['new']):
            raise RenameError('没有可恢复改名，或当前会话不是独立维护账号')
        try:
            self.restore(rec)
        except BaseException:
            rec['status'] = 'recovery-required'
            self.save(rec)
            raise
        print('已验证恢复原账户；保留历史记录和备份。')

    def main(self, args):
        self.setup()
        mode, *values = args
        if mode == 'list':
            for rec in self.records():
                print('%s  %s  %s' % (rec['id'], rec['status'], rec.get('name') or rec['old'] + ' → ' + rec['new']))
        elif mode == 'plan':
            old, new, move, actor = values
            self.plan(old, new, move == 'yes', actor)
        elif mode == 'apply':
            self.apply(*values)
        elif mode == 'temp-create':
            # Public key arrives via an inherited file descriptor, not argv.
            self.temp_create(values[0], os.fdopen(3).read().strip())
        elif mode == 'temp-clean':
            self.temp_clean(*values)
        elif mode == 'recover':
            self.recover(*values)
        else:
            raise RenameError('未知操作')

if __name__ == '__main__':
    def interrupted(sig, frame):
        raise RenameError('操作被信号中断')
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        Rename().main(sys.argv[1:])
    except (Exception, KeyboardInterrupt) as exc:
        print('用户改名向导：' + str(exc), file=sys.stderr)
        sys.exit(1)
QUENCH_RENAME_PY
}

quench_rename_supported() {
    local TOOL
    [ "$(system_update_os_value ID)" = debian ] || { error "用户改名向导目前仅支持 Debian 12/13"; return 1; }
    case "$(system_update_os_value VERSION_ID)" in 12|13) ;; *) error "需要 Debian 12/13"; return 1 ;; esac
    for TOOL in python3 useradd usermod userdel groupmod groupdel getent id ps find sshd ssh-keygen sudo visudo runuser; do
        command -v "$TOOL" >/dev/null 2>&1 || { error "缺少 ${TOOL}，请先安装相关系统工具"; return 1; }
    done
}

quench_rename_change() (
    local ACTION="$1" ACTOR OLD NEW MOVE PLAN IDENT KEY TOKEN RC=0
    quench_rename_supported || return 1
    ACTOR=$(user_current_actor)
    txn_write_begin "用户改名向导：$ACTION" || return 1
    trap 'txn_write_end' EXIT
    case "$ACTION" in
        rename)
            OLD=$(user_select no "选择要改名的用户") || return 0
            [ "$OLD" != "$ACTOR" ] || { error "请先创建临时维护账号并切换登录；不能给当前登录账号改名"; return 1; }
            read -rp "新用户名（回车取消）: " NEW || return 0
            [ -n "$NEW" ] || return 0
            read -rp "同时将标准家目录 /home/$OLD 改为 /home/${NEW}？(Y/n): " MOVE || return 0
            case "$MOVE" in ''|y|Y) MOVE=yes ;; n|N) MOVE=no ;; *) error "无效选择"; return 1 ;; esac
            PLAN=$(quench_rename_engine plan "$OLD" "$NEW" "$MOVE" "$ACTOR") || return 1
            printf '%s\n' "$PLAN"
            IDENT=$(printf '%s\n' "$PLAN" | sed -n 's/^记录：//p')
            warn "请确认这是新机器或已核对业务配置；无法扫描应用数据库、远程配置或任意自定义脚本中的用户名引用"
            read -rp "已从独立维护账号操作；输入 RENAME $OLD TO $NEW 确认: " TOKEN || return 0
            [ "$TOKEN" = "RENAME $OLD TO $NEW" ] || { info "已取消"; return 0; }
            quench_rename_engine apply "$IDENT" "$ACTOR" || RC=$?
            ;;
        prepare)
            OLD=$(user_select no "选择需要保留/改名的原账号") || return 0
            read -rp "粘贴用于临时账号登录的一行 SSH 公钥（不会生成私钥）: " KEY || return 0
            [ -n "$KEY" ] || return 0
            confirm_change_preview "创建临时维护管理员" "仅公钥登录，免密 sudo 等同完整 root 权限；账号 3 天后到期但不会自动删除" \
                "测试临时账号登录后再退出原账号；改名后必须返回此菜单清理临时账号" || return 0
            quench_rename_engine temp-create "$OLD" 3<<< "$KEY" || RC=$?
            ;;
        cleanup|recover)
            quench_rename_engine list || return 1
            read -rp "输入要处理的完整记录编号（回车取消）: " IDENT || return 0
            [ -n "$IDENT" ] || return 0
            if [ "$ACTION" = cleanup ]; then
                confirm_change_preview "删除本向导的临时账号" "确认已用保留的账号登录并通过 sudo 进入 Quench，且已退出临时账号的全部会话" \
                    "删除临时账号、独占组、家目录（含公钥）、邮箱及专属 sudo 授权；不会抹除审计日志" || return 0
                quench_rename_engine temp-clean "$IDENT" "$ACTOR" || RC=$?
            else
                confirm_change_preview "恢复未完成的改名" "保持当前独立维护会话；尝试恢复原名字、家目录及本次变更的配置" \
                    "身份或配置被外部改动时停止，不覆盖整个 passwd/shadow 数据库" || return 0
                quench_rename_engine recover "$IDENT" "$ACTOR" || RC=$?
            fi
            ;;
        *) return 2 ;;
    esac
    if [ "$RC" -eq 0 ]; then audit_action "用户改名向导：$ACTION" SUCCESS
    else audit_action "用户改名向导未完成：$ACTION" FAILED; fi
    return "$RC"
)

quench_user_rename_menu() {
    local CH
    quench_rename_supported || return 1
    while true; do
        print_header "用户改名向导 · 保留 UID/GID"
        ui_hint "无 root SSH：2 准备临时账号 → 切换登录 → 1 改名 → 用新名字登录 → 3 清理"
        ui_hint "不修改 root，不强杀进程，不开启 root SSH 或密码登录；备份/记录：/var/lib/quench/user-rename"
        menu_item 1 "修改用户名（独立维护会话）"
        menu_item 2 "准备临时维护账号"
        menu_item 3 "清理临时维护账号"
        menu_item 4 "查看记录"
        menu_item 5 "恢复未完成的改名"
        menu_item 0 "返回"
        read -rp "$(ui_prompt '选择 [0-5]: ')" CH || return 0
        case "$CH" in
            1) quench_rename_change rename ;;
            2) quench_rename_change prepare ;;
            3) quench_rename_change cleanup ;;
            4) quench_rename_engine list ;;
            5) quench_rename_change recover ;;
            0) return 0 ;;
            *) continue ;;
        esac
        ui_pause
    done
}
