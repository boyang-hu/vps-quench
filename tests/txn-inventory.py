#!/usr/bin/env python3
# 事务保护盘点：从菜单可达的入口出发遍历调用图，找出会写入回滚快照覆盖路径、
# 却不经过 txn_write_begin / safety_arm 的函数。有输出即为违规（smoke 用例据此失败）。
# 只是静态启发式：写入模式按 "> $VAR"、cp/mv/rm/sed -i/atomic_replace_file 等识别。
import re,glob,io,collections
import os
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files=glob.glob(ROOT+"/src/lib/*.sh")+glob.glob(ROOT+"/src/modules/*.sh")
src={f:io.open(f,encoding='utf-8').read() for f in files}
funcs={}; where={}
for f,s in src.items():
    for m in re.finditer(r'(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\) \{\n(.*?)\n\}\n', s, re.S):
        funcs[m.group(1)]=m.group(2); where[m.group(1)]=f
# 快照根
tb=src[ROOT+'/src/modules/toolbox.sh']
m=re.search(r'config_backup_allowed_roots\(\) \{\n(.*?)\n\}\n',tb,re.S)
body=m.group(1); seg=body[body.index('for p in'):body.index('; do')]
roots=[t for t in seg.replace('\\','').split() if '/' in t or t.startswith('etc')]
roots=[r.rstrip('/') for r in roots]
# 路径变量：默认值以 /etc /var/spool 等开头
pathvars={}
for f,s in src.items():
    for v,p in re.findall(r'(?m)^\s*([A-Z][A-Z0-9_]*)=["\']?\$\{[A-Z0-9_]+:-(/[^"\'}]+)\}',s): pathvars.setdefault(v,p)
    for v,p in re.findall(r'(?m)^\s*([A-Z][A-Z0-9_]*)=["\']?(/(?:etc|var/spool|root)[^"\'\s]*)',s): pathvars.setdefault(v,p)
# 二级派生：VAR="$OTHER/sub"
for _ in range(3):
    for f,s in src.items():
        for v,o,sub in re.findall(r'(?m)^\s*([A-Z][A-Z0-9_]*)="\$\{?([A-Z][A-Z0-9_]*)\}?/([^"\s$]+)"',s):
            if o in pathvars: pathvars.setdefault(v,pathvars[o]+'/'+sub)
def covered(path):
    p=path.lstrip('/')
    return any(p==r or p.startswith(r+'/') or r.startswith(p+'/') for r in roots)
cov={v:p for v,p in pathvars.items() if covered(p)}
WRITE=re.compile(r'(?:(?<![<0-9])>>?\s*"?\$\{?(%s)\b|\b(?:cp|mv|install|tee|ln|truncate)\b[^\n|]*"?\$\{?(%s)\b|\brm\s+-[rf]+\s+[^\n]*"?\$\{?(%s)\b|\bsed\s+-i[^\n]*"?\$\{?(%s)\b|\b(?:atomic_replace_file|atomic_restore_file|set_config_file|restore_backup_or_remove)\b[^\n]*"?\$\{?(%s)\b|\bmkdir\b[^\n]*"?\$\{?(%s)\b)'%((('|'.join(map(re.escape,cov)) or 'NOPE'),)*6))
LIT=re.compile(r'(?:>>?\s*"?(/etc/[^\s"]+)|\b(?:cp|mv|tee|install|rm\s+-[rf]+|sed\s+-i)\b[^\n|]*\s"?(/etc/[^\s"]+))')
# 运行时写入：默认路由被出口源地址回滚整条替换，disable_ipv6 被 IPv6 回滚整体恢复
RUNTIME=re.compile(r'\bip\s+(?:"?-\$\{?FAMILY\}?"?|-4|-6)?\s*route\s+(?:replace|change|add|del|delete|flush)\b|disable_ipv6"?\s*$|>\s*"?\$\{?[A-Z_]*PROC[A-Z_]*\b')
writers={}
for n,b in funcs.items():
    hits=set()
    for line in b.split('\n'):
        ls=line.strip()
        if ls.startswith('#') or ls.startswith('echo ') or ls.startswith('info ') or ls.startswith('warn ') or ls.startswith('error '): continue
        for mm in WRITE.finditer(line):
            v=next(g for g in mm.groups() if g)
            # mkdir -p "$(dirname "$VAR")" 只是建父目录，不改受管路径本身
            if mm.group(0).lstrip().startswith('mkdir') and 'dirname' in line: continue
            hits.add(v)
        for mm in LIT.finditer(line):
            p=next(g for g in mm.groups() if g)
            if covered(p): hits.add(p)
        if RUNTIME.search(line) and not ls.startswith('#') and 'route show' not in line and 'route get' not in line:
            hits.add('runtime:'+('default-route' if 'route' in line else 'ipv6'))
    if hits: writers[n]=hits
GUARD=('txn_write_begin','safety_arm ','safety_arm_locked','ip_v6_safety_arm','ip_source_safety_arm','config_restore_transaction')
guarded={n for n,b in funcs.items() if any(g in b for g in GUARD)}
names=set(funcs)
calls={n:{w for w in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\b',b) if w in names and w!=n} for n,b in funcs.items()}
entries=set()
for n,b in funcs.items():
    if n.endswith('_menu') or n=='main' or 'first_run_offer_step' in b:
        entries|=calls[n]
# 生成脚本/只读/读取类误报
SKIP={'diagnostic_bundle_create','get_config','f2b_status','config_backup_create','config_backup_allowed_roots','ufw_port_rule_present','sshd_effective_reload'}
def reach(start):
    seen=set(); stack=[start]; found={}
    while stack:
        n=stack.pop()
        if n in seen or n in guarded or n in SKIP: continue
        seen.add(n)
        if n in writers: found[n]=writers[n]
        stack.extend(calls.get(n,()))
    return found
rep=collections.defaultdict(set)
for e in sorted(entries):
    if e in guarded or e in SKIP: continue
    for w,h in reach(e).items(): rep[(w,tuple(sorted(h)))].add(e)
for (w,h),es in sorted(rep.items()):
    print("%-40s %-32s <- 入口: %s"%(where[w].split('/')[-1]+':'+w,','.join(h),','.join(sorted(es))))
