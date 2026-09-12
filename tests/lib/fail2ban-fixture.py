"""File-backed Fail2ban protocol fixture. Never installs rules or starts services."""
import ast
import configparser
import os
from pathlib import Path
import sys

root = Path(os.environ['QUENCH_TEST_F2B_ROOT'])
operation = sys.argv[1]
cfg = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(';', '#'))
try:
    cfg.read([root / 'jail.conf', *sorted((root / 'jail.d').glob('*.conf')),
              root / 'jail.local', *sorted((root / 'jail.d').glob('*.local'))])
    jail = dict(cfg['sshd'])
    if operation == 'validate':
        if jail.get('port') == 'broken':
            raise ValueError('invalid port')
    elif operation == 'dump':
        for key in ('bantime', 'findtime', 'maxretry'):
            print(['set', 'sshd', key, int(jail[key])])
        print(['set', 'sshd', 'addaction', jail['banaction']])
        print(['multi-set', 'sshd', 'action', jail['banaction'], [['port', jail['port']]]])
    elif operation == 'restart':
        (root / 'runtime').write_text(repr(jail))
    elif operation == 'get':
        jail = ast.literal_eval((root / 'runtime').read_text())
        if sys.argv[2] == 'action':
            if sys.argv[3] != jail['banaction']:
                raise ValueError('action not running')
            print(jail[sys.argv[4]])
        else:
            print(jail[sys.argv[2]])
except (OSError, ValueError, KeyError, configparser.Error) as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
