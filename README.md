# Quench — VPS 初始化与管理工具 V0.1.0

> 首次开荒 · 用户与 SSH · Fail2ban · Firewall · BBR/FQ · DNS · Caddy 网站入口 · 系统与服务管理

Quench 面向自行维护 Linux VPS 的用户，把首次初始化、安全接管、网络调优和日常运维集中到一个可审计的 Bash 工具中。它支持 Debian、Ubuntu、CentOS、Alpine 与 OpenWrt，并提供单文件在线运行和带校验的离线安装包。

项目优先保证远程管理通道可恢复：用户、SSH、防火墙、Fail2ban 和关键网络配置尽量采用“备份 → 校验 → 应用 → 健康检查 → 必要时回滚”的流程；已有配置会先识别边界，再决定保留、接管或提示人工处理。

### 设计原则

- **先保证可登录，再做加固：** 禁用 root 或密码登录前，必须确认可接管的非 root 管理员、公钥和 sudo 能力。
- **以系统现状为准：** 首次开荒向导可重复运行，完成状态来自实时检查，不依赖一次性标记。
- **性能参数可解释：** BBR、FQ、tc、缓冲和内核参数按机器资源、链路和场景选择，并提供状态检查与恢复入口。
- **变更可追踪：** 关键操作写入审计日志，配置支持备份、迁移、延迟回滚和脚本版本回退。

> **运行依赖：** 脚本需 **bash** 运行（使用了数组 / `[[ ]]` / here-string 等特性）。Debian/Ubuntu/CentOS 默认自带；**Alpine 需 `apk add bash`，OpenWrt 需 `opkg install bash`**。脚本头部带解释器守卫：非 bash 环境会自动尝试切到 bash，缺失时给出清晰安装提示而非报一堆语法错。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.sh)
```

### 离线安装包

适合不能访问 GitHub 的中国内地 VPS。先在一台可以访问 GitHub 的电脑或跳板机下载：

```bash
curl -fLO https://github.com/boyang-hu/vps-quench/releases/download/v0.1.0/quench-offline-V0.1.0.tar.gz
curl -fLO https://github.com/boyang-hu/vps-quench/releases/download/v0.1.0/quench-offline-V0.1.0.tar.gz.sha256
sha256sum -c quench-offline-V0.1.0.tar.gz.sha256
```

再通过 `scp`、SFTP 或 WinSCP 将两个文件传到 VPS。Linux/macOS 示例：

```bash
scp quench-offline-V0.1.0.tar.gz* root@你的VPS地址:/root/
```

登录 VPS 后离线安装：

```bash
cd /root
sha256sum -c quench-offline-V0.1.0.tar.gz.sha256
tar -xzf quench-offline-V0.1.0.tar.gz
cd quench-offline-V0.1.0
bash install.sh
v
```

安装阶段不会访问网络。安装包包含完整脚本、内部 SHA256 和独立安装器；不会覆盖其他程序已经占用的 `v` / `V` 命令。安装第三方软件和自更新等功能仍需要相应网络连接。

开发者也可以从仓库源码自行构建同样的安装包：

```bash
./build-offline-package.sh
```

## 命令行合集

所有入口都可以直接从 GitHub 调用，也可以在安装到本地后用 `v --命令` 调用。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.sh) --help
```

| 命令 | 功能 |
|------|------|
| `--first-run` | 首次开荒向导 |
| `--user-menu` | 用户与 SSH 访问管理 |
| `--fail2ban-menu` | Fail2ban 管理 |
| `--bbr-menu` | 网络性能调优（BBR / tc / initcwnd） |
| `--bbr-calibrate` | 直接进入线路实测与 policer 拐点校准 |
| `--firewall-menu` | 防火墙管理 |
| `--dns-menu` | DNS 管理与诊断 |
| `--mirror-menu` | 软件源管理 |
| `--ip-menu` | IP 状态与出口管理 |
| `--caddy-menu` | Caddy 网站入口管理 |
| `--nft-menu` | 线路机四层端口转发 |
| `--time-menu` | 时间、时区与 NTP 诊断修复 |
| `--https-time-sync` | 手动执行 HTTPS 应急粗校时 |
| `--swap-menu` | Swap 管理 |
| `--system-toolbox-menu` | 安全与诊断 |
| `--stun-test` | STUN、多端口 UDP 与 NAT 类型检测 |
| `--hostname-menu` | 修改系统 hostname |
| `--docker-menu` | Docker 管理 |
| `--software-menu` | 常用软件管理 |
| `--self-manage-menu` | 脚本管理 |
| `--config-backup-menu` | 配置备份 |
| `--config-transfer-menu` | 配置迁移 |
| `--rollback-center-menu` | 回滚中心 |
| `--nft-refresh-targets` | NFT 域名目标刷新内部入口 |

**安装到本地后用快捷键 `v` / `V` 呼出：**

进入脚本 → `m) 脚本管理` → `1) 安装脚本 + 设置快捷键`

之后任意终端输入 `v` 即可启动。快捷键基于 `/usr/local/bin/` 软链接，不会污染 alias，与其他脚本（如 `volss`）完全隔离。

---

## 主界面

```
 ██████╗ ██╗   ██╗███████╗███╗   ██╗ ██████╗██╗  ██╗
██╔═══██╗██║   ██║██╔════╝████╗  ██║██╔════╝██║  ██║
██║   ██║██║   ██║█████╗  ██╔██╗ ██║██║     ███████║
██║▄▄ ██║██║   ██║██╔══╝  ██║╚██╗██║██║     ██╔══██║
╚██████╔╝╚██████╔╝███████╗██║ ╚████║╚██████╗██║  ██║
 ╚══▀▀═╝  ╚═════╝ ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPS INIT/MANAGEMENT TOOLS  ·  V0.1.0  ·  Boyang
────────────────────────────────────────────────────────────────
  SSH · BBR · DNS · Caddy · Firewall · NFT · Docker

  ◆ 系统概览
  ● 用户  2 · 管理员 1       ● SSH  22 · 仅密钥
  ● BBR  bbr · 无限速        ● Fail2ban  运行中
  ● 防火墙  ufw active       ● Caddy  运行中
  ● Docker  运行中           ● 时间  2026-09-01 16:30:00

  ◆ 初始化与诊断
    w  首次开荒向导           h  安全与诊断

  ◆ 安全与网络
    1  用户管理                2  Fail2ban 管理
    3  网络性能调优             4  防火墙管理
    5  DNS 管理

  ◆ 系统与服务
    6  软件源管理              7  IP 状态与出口
    8  Caddy 网站入口          n  线路机端口转发
    t  时间与 NTP              s  Swap 管理
    a  常用软件管理             d  Docker 管理
    m  脚本管理
    0  退出脚本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 功能详解

### w. 首次开荒向导

面向新 VPS 的可重复运行配置向导。所有完成状态都根据当前系统实时检查，不依赖一次性的完成标记；中途退出后可重新进入继续处理未完成项目。

推荐流程为：环境、DNS 与时间预检 → 配置备份 → 用户与 SSH 安全接管 → 防火墙与 Fail2ban → SSH 基础加固 → 自动安全更新 → 内核网络安全基线 → 可选 BBR → 最终安全体检。

- DNS 正常时只报告结果并保留云厂商或现有解析配置；只有解析失败时才提供进入 DNS 管理修复的入口。
- 预检会显示时区、活动 NTP 后端和同步状态；未同步时给出警告，但不会在向导中擅自切换时间服务，修复统一从时间模块执行。
- SSH 基线设置 `PubkeyAuthentication yes`、`PermitEmptyPasswords no`、`MaxAuthTries 4`、`LoginGraceTime 30` 和 `X11Forwarding no`，不会单独关闭 root 或密码登录。
- Debian / Ubuntu 自动安全更新明确关闭自动重启，并验证 APT timer 已启用。
- 内核网络安全基线与 BBR 性能配置分文件管理，只写入当前内核支持的 redirect、source route、SYN cookies 和 ICMP 安全参数。
- 每一步均可单独执行或跳过；SSH、防火墙和网络变更继续使用配置备份、写后验证与防断联回滚。

### 1. 用户与 SSH 访问管理

| 功能 | 说明 |
|------|------|
| 查看用户与权限 | 列出 root 与可登录用户，显示 UID、管理员权限、密码锁定和公钥数量 |
| 创建用户 | 创建普通用户或 sudo/wheel 管理员，可设置密码并安装用户公钥 |
| 管理 sudo 权限 | 跨发行版管理 sudo/wheel；禁止移除当前用户、最后一个管理员或最后一个可接管管理员 |
| 免密 sudo | 为指定非 root 管理员单独开启或关闭 `NOPASSWD`，写入前经 `visudo` 校验并执行 `sudo -n` 验证；不会开放 root SSH |
| 修改/锁定密码 | 调用系统 `passwd` 修改、锁定或解锁账户，保护当前登录身份 |
| 管理用户公钥 | 先选择用户，再查看、添加、删除或生成密钥；自动修复 `.ssh` 属主与权限 |
| 删除用户 | 禁止删除 root、当前登录用户、系统账户和最后一个可用管理员；家目录单独确认 |
| SSH 登录策略 | 推荐“仅密钥 + 禁止 root SSH”；关闭密码前必须验证非 root 公钥管理员和 `sudo -v` |
| 修改 SSH 端口 | 新旧端口并行监听；验证 UFW/firewalld 生效规则，自动接管并验证 Fail2ban `sshd` jail；完成与回滚均为可恢复事务 |
| SSH 状态与检查 | 显示 sshd 最终生效参数、监听端口、管理员接管能力和未完成迁移 |
| 推荐安全向导 | 创建管理员 → 添加公钥 → 异地验证 → 可选迁移端口 → 禁止 root 与密码登录 |

公钥路径按用户家目录解析。已有 DSA 公钥可以查看和删除，但新增公钥只接受 Ed25519、RSA、ECDSA 与 FIDO 类型；默认推荐 Ed25519。

> 禁止 root 或密码登录前，脚本要求至少存在一个“非 root、具有管理员权限、已有 SSH 公钥”的用户，并要求从另一个终端完成密钥登录和 `sudo -v` 验证。

---

### 2. Fail2ban 管理

自动封禁 SSH 暴力破解 IP。安装时自动检测 backend 和 sshd 真实监听端口，支持 `python3-systemd` / `rsyslog` / `auto` 多种方式。Quench 只管理独立 drop-in，不覆盖用户的 `jail.local` 和其他 jail。

| 功能 | 说明 |
|------|------|
| 查看封禁 IP | 当前所有被封禁的 IP |
| 手动解封 | 立即解封指定 IP |
| 实时日志 | 彩色显示（UTF-8 兼容） |
| SSH 防护参数 | bantime / findtime / maxretry / 实际 SSH 端口 |
| 编辑配置 | 编辑后先验证，语法或重启失败自动恢复 |
| 安装 / 修复 / 更新 | 使用 `mode = aggressive`，重复攻击递增封禁至 1 周 |
| 安全卸载 | 默认保留配置；固定确认词只删除 Quench drop-in |

**快速预设：**

| 预设 | bantime | findtime | maxretry |
|------|---------|----------|----------|
| 严格 | 1 天 | 10 分钟 | 3 |
| 标准 | 1 小时 | 10 分钟 | 5 |
| 宽松 | 30 分钟 | 5 分钟 | 10 |
| 永久 | 永久 | 10 分钟 | 3 |

---

### 3. 网络性能调优

**智能向导（推荐）** — 自动检测内存推荐预设：

| 内存 | 推荐 |
|------|------|
| < 768 MB | `latency` 低延迟 |
| < 4 GB | `balanced` 均衡 |
| ≥ 4 GB | `throughput` 高吞吐 |

**通用预设：**

| 预设 | 缓冲区 | 适用 |
|------|--------|------|
| `latency` | 16-32 MB（按内存动态） | SSH / 游戏 / 远程桌面 |
| `balanced` | 16-64 MB（按内存动态） | 网页 / 代理 / 日常 |
| `throughput` | 32-256 MB（按内存动态） | 万兆 / 跨洋 |

场景化预设还包括 `relay`（中转机）、`landing`（跨境落地）和 `line_landing`（低延迟线路落地）；只有用户确认路由/NAT 用途时才开启内核转发与 conntrack 调优。

**自动配置（BDP 三维计算）：** 按 `2 × BDP + 2 MiB` 精确计算缓冲需求并对齐到 64 KiB，不再向固定档位取整；代理/低延迟场景按物理内存的 `1/32`、通用/大流场景按 `1/16` 控制单 socket 自动扩展上限，并统一设置 256 MiB 绝对上限。
- 内存：512MB / 1G / 2G / 4G / 8G / 16G+
- 延迟：100ms 以内 / 100-200ms / 200ms 以上 / 自定义目标 RTT（1-2000ms）
- 带宽：100M / 200M / 500M / 1G / 2G / 5G / 10G / 自定义

**手动配置（两步式：选用途 → 选缓冲）：** 12 / 16 / 20 / **32** / 40 / 64 / 128 / 256 / 512 / 1024 MB 共 10 档（新增 32MB 为 1G 跨境甜点区）

**安全保护：**
- 自动配置与智能预设按用途使用 `1/32` 或 `1/16` 内存预算，并设 256 MiB 绝对上限；手动配置超过场景预算时二次确认
- 自动配置误选高内存档位时按实际物理内存计算，例如 512MB 机器选择 16GB 仍按 512MB 限制
- TCP 每连接初始/默认缓冲保持内核保守值（接收 4KB/128KB、发送 4KB/16KB），仅提高自动扩展上限
- `tcp_mem`、`min_free_kbytes`、`tcp_adv_win_scale` 及高风险全局连接参数交还内核管理
- 无 sysctl 写入权限（无特权容器）自动检测并提示
- 内核 BBR 支持检测（kernel ≥ 4.9）
- 首次调优保存运行参数基线，每次应用保存运行快照；失败时自动回滚
- 切换预设时检测上一场景遗留的转发/conntrack 参数，并恢复到首次调优前基线（`ip_forward` 单独警告）
- NFT 与 BBR 双向识别对方持有的 `ip_forward` / IPv6 RA 参数：切换性能预设或删除最后一条转发规则时，不会复位另一模块仍在使用的转发能力
- 中转/落地场景默认不修改内核转发；仅在用户确认路由/NAT 用途后启用，并同时设置默认与当前出口 `accept_ra=2`
- 网络调优不再修改 `vm.swappiness`，Swap 策略统一由独立的 Swap 管理模块负责
- 逐行 `sysctl -w` 应用；BBR 写入失败或回读不一致时自动回滚。`fq` 在旧内核（< 4.20）上失败会回滚；现代内核会保留 BBR 内部 pacing 并明确告警
- 场景容量参数只会抬高到目标值，不会压低首次调优前已有的更高值；出站端口范围会取原范围与目标范围的并集

**其他功能：**
- 线路实测校准：由用户指定同协议族的近端 iperf3 对端、端口和标称带宽；先测单流不限速基线，异常低速时自动重复取优并补 4 流对照，再用粗扫、2/3 重复确认和最多四轮细扫定位 policer 拐点。测试前显示最坏流量估算，结束后按网卡计数器报告实际流量
- 实测不到拐点时建议保留 BBR/fq、不增加 HTB；对端过慢、路径底噪或扫描越界时标记为 `INCONCLUSIVE` / `OUT_OF_RANGE`，不会猜测或自动应用限速值。最近结果保存在 `/var/lib/quench/tc-calibration.state`
- 手动整形仍支持选择 100M / 200M / 300M / 400M / 500M / 600M / 800M / 1G / 2G / 2.5G / 5G / 10G 或自定义带宽，再选择 95% / 97% / 99%；也可直接填写最终速率。支持 `400`、`600M`、`1.5G`、`2.5G`，按十进制 `1G = 1000M` 换算
- tc 使用 `htb` 聚合整形 + `fq` 叶子，burst 按约 4ms 线速数据量计算；写入和持久化重载后会统一换算 bit/Kbit/Mbit/Gbit/Tbit 并回读核对真实 HTB rate。可查看 `tc -s` qdisc/class 统计
- 线路校准只临时接管可恢复的内核默认 qdisc 或已有 Quench 规则；检测到外部 CAKE/HTB、自定义 mq 叶子等 QoS 时拒绝测试。手动整形同样默认拒绝覆盖外部 QoS，输入精确确认词后才可接管或删除，操作前诊断快照保存到 `/var/lib/quench/tc-backups/`
- tc 限速状态保存在 `/var/lib/quench/tc-fq.state`；网卡重建导致运行规则丢失时，更新脚本、应用 BBR 配置或进入 BBR 菜单会自动恢复。若默认网卡名称变化，只显示保存状态并提示人工确认，不会静默迁移
- initcwnd（10 / 50 / 100 / 自定义）可分别应用到 IPv4、IPv6 或双栈；默认不修改 initrwnd，高级选项可单独设置；支持恢复内核默认及 systemd/OpenRC/SysV 持久化
- 诊断同时显示新接口默认 qdisc 与当前网卡实际 root qdisc、`tc -s` 统计、TCP 重传及 UDP 缓冲错误计数
- 支持按时间戳备份/还原 sysctl，也可一键恢复首次调优前基线并清理本工具的 tc/initcwnd 持久化

**代理专项参数：**
- 通用核心只提高内核实际支持的 UDP 接收保障 `udp_rmem_min`；不再写入 Linux 中无效的 `udp_wmem_min`
- 场景预设（中转/落地）额外含扩大出站端口范围、`tcp_max_tw_buckets`、`fs.file-max`，防高并发端口/fd 耗尽
- 用户确认启用内核转发后写入 conntrack 参数，`nf_conntrack_max` 按 512MB / 1GB / 2GB / 4GB 内存分档，且不低于首次基线
- 应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in

**写入位置：** `/etc/sysctl.d/99-quench-bbr.conf`（不污染主配置）

---

### 4. 防火墙管理

自动检测 **ufw**（Debian/Ubuntu）和 **firewalld**（CentOS/Rocky）。两者冲突时不会擅自选择后端。

| 功能 | 说明 |
|------|------|
| 开启 / 关闭 | 一键切换 |
| 查看规则 | 列出所有规则 |
| 添加 / 删除端口 | 支持端口段，按编号循环删除 |
| 拉黑 / 放行 IP | 校验 IPv4/IPv6/CIDR；可仅放行 SSH、指定端口或全部服务 |
| 快速放行 Web | 显式确认后放行 SSH + 80 + 443 |
| 安装 / 修复 | UFW 明确拒绝默认入站并限速放行 SSH；80/443 默认不开放 |
| 安全卸载 | 默认保留配置，不 flush iptables/nftables；完全清理需输入 `PURGE` |

**安全保护：** UFW 会在启用前放行当前 SSH 端口；firewalld 会用 `firewall-offline-cmd` 在首次启动前写入 SSH 永久规则。所有可能影响连接的操作保留 180 秒自动回滚，并提醒检查云安全组和 Docker 端口绕过。

---

### 5. DNS 管理与诊断

Quench 不假定更换公共 DNS 一定更快。模块会识别系统真正使用的 DNS 后端，显示有效上游，并在写入前按当前 IPv4/IPv6 路由逐台直连测试候选服务器；无法完成查询的地址会从本次配置排除。若系统没有 `dig` 或 `nslookup`，会明确提示跳过逐台预检，再依靠写入后的后端状态与系统解析测试把关。

| 选项 | IPv4 | IPv6 |
|------|------|------|
| Cloudflare | 1.1.1.1 / 1.0.0.1 | 2606:4700:4700::1111 |
| Google | 8.8.8.8 / 8.8.4.4 | 2001:4860:4860::8888 |
| 跨运营商冗余 | CF + Google | 双栈 |
| 阿里云 | 223.5.5.5 / 223.6.6.6 | 2400:3200::1 |
| 腾讯 DNSPod | 119.29.29.29 | — |
| 114 DNS | 114.114.114.114 / 114.114.115.115 | — |
| 自定义地址 | 支持一个或多个 IPv4 | 支持一个或多个 IPv6 |

- **后端感知：** 支持 NetworkManager、systemd-resolved、resolvconf 和静态 `/etc/resolv.conf`；未知程序管理的符号链接会被拒绝覆盖。
- **精确作用域：** NetworkManager 只修改默认路由所在的活动连接，不批量污染 VPN、Docker 或其他活动连接；切换为纯 IPv4 时会清除 Quench 设置中的 IPv6 DNS 残留。
- **确保接管：** systemd-resolved 使用全局 `~.` 路由域；NetworkManager 设置 DNS 优先级与 `~.` 路由域，避免 DHCP DNS 与目标上游并用。
- **两阶段验证：** 写入前验证候选 DNS 的直连查询；写入后同时核对后端报告的有效上游以及系统对 `github.com`、`example.com` 的解析。
- **事务回滚：** 应用失败会立即恢复；应用成功后仍保留 180 秒确认窗口。回滚会恢复旧配置、删除本次新建的 drop-in，并保留原有 `/etc/resolv.conf` immutable 属性。

---

### 6. 软件源管理

| 系统 | 支持的主仓库 |
|------|-------------|
| Ubuntu | 阿里 / 腾讯 / 清华 / 中科大 / 官方；自动区分 x86 `ubuntu` 与 ARM 等架构的 `ubuntu-ports` |
| Debian | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| Rocky / AlmaLinux | 阿里；支持 8/9/10，并可恢复切换前的完整仓库状态 |
| CentOS Stream | 阿里 / 清华；支持 9/10，已结束维护且镜像不完整的 Stream 8 会被拒绝 |

- 显示发行版、版本、代号、架构、APT 配置格式和当前启用仓库；未知代号、架构或仓库路径不会猜测写入。
- 同时识别传统 `.list` 与 Deb822 `.sources`，只改当前发行版的系统仓库，保留文件格式、组件、`Signed-By` 和 Docker/Caddy 等第三方仓库。
- security 套件默认使用发行版官方安全源，避免镜像同步延迟；只有经过风险确认后，才在本次菜单会话中随主仓库切换。
- 写入前检查 `InRelease` 或 `repomd.xml`；APT 使用全新临时索引、严格错误模式及失败索引检查来验证全部仓库与签名，DNF 会先隔离验证 Quench 仓库再禁用原核心仓库。
- 每次修改和恢复都会先建立完整快照；失败立即恢复。菜单中的“恢复上一次配置”可以在切换与恢复结果之间安全撤销。
- RHEL 订阅仓库、未知 EL 版本以及 Alpine/OpenWrt 厂商定制 feeds 不会被自动替换。

---

### 7. IP 状态与出口管理

| 功能 | 说明 |
|------|------|
| 状态与公网出口 | 分别显示 IPv4/IPv6 全局地址、默认路由、内核选出的源地址、公网出口和策略路由复杂度 |
| 双栈目标优先 IPv4 | 仅在 glibc 系统写入完整 RFC 3484/6724 风格 precedence 表，并提高 IPv4-mapped 项；不关闭 IPv6、不改变默认路由 |
| 恢复系统默认地址选择 | 只移除 Quench 管理的 `/etc/gai.conf` 区块，保留用户配置；检测到外部 precedence 表时拒绝覆盖 |
| 高级：禁用内核 IPv6 | 写入 Quench 独立 sysctl 文件，并立即作用于当前和未来接口；这不是性能优化 |
| 高级：启用内核 IPv6 | 只移除 Quench 的禁用文件；若其他 sysctl 配置仍在禁用 IPv6，则列出冲突并拒绝覆盖 |
| 高级：临时多 IP 出口 | 在同一默认网卡的多个稳定 IPv4 或 IPv6 地址之间切换 main 表默认路由的首选源地址 |

IPv4 优先功能面向仍需保留双栈、但希望多数使用 glibc `getaddrinfo()` 的新连接先尝试 IPv4 的场景。应用自行实现 DNS 解析或 Happy Eyeballs 时不一定遵循 `/etc/gai.conf`；该设置也不会影响现有连接。

内核 IPv6 开关属于高级故障规避入口，不进入首次开荒向导。变更前会保存 Quench 持久化文件以及 `all`、`default` 和每个现有接口的原始 `disable_ipv6` 值；写入失败或 180 秒内未确认时按接口精确恢复。重新启用内核 IPv6 不保证服务商会分配公网地址，脚本会等待并报告 SLAAC/DHCPv6 结果。

临时多 IP 出口只修改运行时 main 表默认路由，不重写 Netplan、NetworkManager、systemd-networkd 或发行版网络配置。脚本会拒绝自定义策略路由、多默认路由、ECMP 和网卡不一致的环境；变更会保留原路由的全部属性，随后核对内核选源及绑定地址的 HTTPS 公网出口。验证失败时立即恢复，直接恢复失败则继续执行独立回滚脚本；网络服务更新配置或 VPS 重启后，临时选择可能恢复为系统配置。

---

### 8. Caddy 网站入口管理

这是面向自维护 VPS 的轻量 Web 入口层：负责域名接入、自动 HTTPS、反向代理、静态文件、永久重定向和连接已有 PHP-FPM。它适合与 Docker 应用或本地服务配合使用，但不试图复制宝塔、1Panel 的数据库、PHP 扩展、文件管理、应用备份和图形界面。

| 功能 | 说明 |
|------|------|
| 安装 / 安全更新 | 优先使用系统或 Caddy 官方软件包；通用回退从官方 Release 解析明确版本并按发布清单校验 SHA-512（兼容 SHA-256），同时建立持久服务用户、数据目录和 systemd 服务 |
| 查看所有站点 | 同时读取主 Caddyfile 与 `sites.d`，区分总站点数和 Quench 托管站点数 |
| 添加反向代理 | 将公网域名或 HTTP IP 入口转发到本机/内网 HTTP(S) 后端，添加前探测后端连通性 |
| 添加静态网站 | 只接受 `/var/www` 或 `/srv` 下的安全路径，验证 Caddy 服务用户可读取目录 |
| 添加永久重定向 | 保留请求路径与查询参数，目标地址经过严格格式校验 |
| 接入 PHP-FPM | 连接现有 Unix socket 或 TCP 网关并检查可用性；不会自动安装 PHP、扩展或数据库 |
| 删除托管站点 | 只删除带 Quench 标记的独立站点文件；保留网站目录、应用数据、证书缓存和历史日志 |
| 入口诊断与证书状态 | 检查完整配置、服务、80/443 监听、DNS、本机/公网响应以及已落盘证书到期时间 |
| 访问与服务日志 | 每个托管站点使用独立 JSON 访问日志，按大小和保留期轮转，并可查看 systemd 服务日志 |
| 高级编辑与备份 | 主配置编辑后检查 import 边界、验证完整配置并应用；配置可进入 Quench 统一备份与恢复流程 |

引导式站点分别写入 `/etc/caddy/sites.d/*.caddy`，主 `/etc/caddy/Caddyfile` 只增加一个带边界标记的 import。已有手写站点保持原样；Quench 不会用文本行号去删除外部配置。每次新增、删除或高级编辑都执行“暂存 → Caddy 官方适配器验证 → 原子替换 → reload/start → 本机入口检查”，任一步失败都会恢复原文件；本次新增的防火墙端口和空网站目录也会随失败回退。

地址策略刻意保持明确：普通域名默认启用 HTTPS，`example.com:8443` 会生成为显式自定义 HTTPS 入口；公网 IPv4/IPv6 引导入口只提供 HTTP。为同时支持自动证书与 HTTP/3，标准 HTTPS 需要本机和云安全组放行 `80/tcp`、`443/tcp`、`443/udp`，自定义 HTTPS 则需要 `80/tcp` 以及自定义端口的 TCP/UDP。没有 UDP 时客户端仍可回退到 HTTP/2。脚本可以联动已启用的 UFW/firewalld，但不会修改云厂商安全组；域名还必须正确解析或由 CDN/NAT 转发到本机。

Caddy 在加载域名配置后就会申请并持续续期证书，不依赖第一次访问触发。卸载入口默认保留 `/etc/caddy`、`/var/lib/caddy` 和 `/var/log/caddy`，避免误删配置、证书与历史日志。

---

### n. 四层端口转发（线路机 → 落地机）

这个模块面向“客户端连接线路机公网端口，再由线路机送往落地机服务”的场景。它使用内核 nftables 对 TCP/UDP 做 DNAT，默认通过 scoped masquerade 保证回程仍经过线路机；不会解析 TLS 或其他应用层内容，转发开销远低于再启动一个用户态代理。

```text
客户端 → 线路机 IP:监听端口 → DNAT/SNAT → 落地机 IP:服务端口
```

这里的“透传”是四层 NAT，不是 VPN 或整机默认路由：它不会自动让线路机自己的全部出站流量经过落地机，也不会提供加密、线路选择、负载均衡或目标健康切换。默认 masquerade 下，落地机看到的客户端地址是线路机；选择“保留客户端 IP”时，落地机必须通过静态路由、策略路由或隧道把客户端网段的回程交还线路机，否则连接会因为非对称路由失败。

| 能力 | 行为 |
|------|------|
| 协议选择 | 每条规则独立选择 TCP、UDP 或两者，不再无条件开放两个协议 |
| 端口映射 | 单端口、端口段 1:1、最多 4096 个端口的偏移映射 |
| 地址范围 | IPv4/IPv6 分族管理；可监听全部地址或指定本机 IP，不做隐式 NAT64 |
| 目标地址 | 接受固定 IP 或域名；域名可立即刷新或由 systemd timer 每 10 秒至 24 小时重解析 |
| 回程模式 | 默认 scoped masquerade；高级模式可保留原始客户端地址 |
| 来源控制 | 每条规则独立关闭、设置白名单或黑名单，支持 IP/CIDR |
| 生命周期 | 规则可启停、修改、删除、重新应用，并显示路由、目标端口、服务和规则计数器诊断 |

安全和共存边界：

- Quench 只维护 `quench_nft4` / `quench_nft6` 表；应用时先运行 `nft -c`，再以单个 netlink batch 替换自己的表，不执行 `flush ruleset`。
- masquerade 只匹配带 Quench conntrack 标记的连接，不会再对 Docker、firewalld 或用户其他 DNAT 连接执行全局 SNAT。
- 检测到活动 UFW 时写入带网卡、目标和端口约束的 `ufw route` 规则；检测到 firewalld 时使用其 rich `forward-port` 接口。新增规则先写入，旧规则后删除；失败会尝试恢复数据库、内核参数和防火墙状态。
- 不接管 `/etc/nftables.conf`，也不启用或重载全局 `nftables.service`。Quench 使用独立 systemd/OpenRC 服务在 UFW、firewalld 和系统 nftables 之后恢复自己的表。
- 只为实际启用的协议族打开内核转发。IPv6 同时设置当前出口和默认接口的 `accept_ra=2`，首次值保存在基线中；最后一条对应规则删除或模块卸载后恢复。
- 添加或启用规则前检查重复监听、端口重叠、本机已有监听、目标路由和 TCP 目标可达性。UDP 不用伪造“探测成功”，只确认路由并在诊断中明确其无连接特性。
- 本机防火墙联动不等于云安全组放行；线路机监听端口仍需在云厂商控制台开放。

域名刷新只重新解析目标并更新转发、防火墙规则，不会修改公网 DNS 记录。解析失败时保留最近一次有效地址。Linux CI 通过独立 client/relay/landing network namespace 验证 TCP masquerade、UDP 源地址保留和外部 nftables 表不被清理。

---

### t. 时间、时区与 NTP

| 功能 | 说明 |
|------|------|
| 时间与 NTP 诊断 | 显示本地时间、UTC、IANA 时区、活动后端、同步状态和 timesyncd/chrony 详细数据 |
| 开启或修复自动同步 | 优先继续使用现有 chrony 或 systemd-timesyncd；没有后端时优先启用已安装服务，必要时安装 chrony |
| 立即请求 NTP 同步 | 请求当前 Quench 管理的后端获取新样本并等待同步确认，不直接粗暴跳变系统时钟 |
| 设置时区 | 支持 UTC、Asia/Shanghai 和经系统时区数据库校验的其他 IANA 时区 |
| HTTPS 应急粗校时 | 仅在 UDP/123 受限且系统时间明显错误时手动使用；修改前展示偏差并要求明确确认 |

执行修复时，Quench 会保证 chrony 与 systemd-timesyncd 只保留一个活动后端；检测到 `ntpd`、`ntp` 或 OpenNTPD 等外部服务时只诊断，不覆盖其配置。时间健康状态同时出现在首次开荒向导、系统资源健康检查和脱敏诊断包中。

HTTPS 应急校时保持证书验证开启，不使用 `curl -k`；依次探测 Cloudflare、阿里云、Microsoft、GitHub、Google，最多采纳 3 个有效来源，至少需要两个相差不超过 10 秒的来源才允许改时。它不会安装 `ntpdate`，也不会创建 systemd timer 或 root crontab；如果系统时间偏差大到 TLS 证书无法验证，应先通过 VPS 控制台粗略校时。

---

### s. Swap 管理

| 功能 | 说明 |
|------|------|
| 创建 / 更换 Swap | 使用独立 `/swapfile.quench`，支持 512MB / 1G / 2G / 4G / 动态推荐 / 自定义，并保留至少 512MB 磁盘空间 |
| 删除 Swap | 只删除有 Quench 管理记录的文件，不触碰 Swap 分区、zram 或第三方 Swap |
| Swappiness | 10 / 60 / 100 / 133 / 自定义 0–200，写入独立 sysctl 文件并回读验证 |

创建、更换与删除会一起事务式处理 Swap 文件和 `/etc/fstab`，任一步失败都会恢复原文件与启用状态。Btrfs 使用专用 `btrfs filesystem mkswapfile` 路径；LXC / OpenVZ 会提示宿主机可能禁止 `swapon`。

---

### h. 安全与诊断工具箱

| 功能 | 说明 |
|------|------|
| 系统安全体检 | 检查 SSH 登录策略、配置语法、防火墙、Fail2ban、UID 0 账户、监听端口及待更新软件包 |
| 登录安全日志 | 查看成功/失败登录、当前会话、SSH 日志和 Fail2ban 状态 |
| 网络诊断 | 地址、路由、DNS、Ping、公网出口和路径 MTU 检测 |
| STUN / NAT 检测 | 多 STUN 端点与 UDP 443 / 3478 / 19302 探测，输出公网 IPv4 映射、Mapping / Filtering Behavior、传统 NAT 类型及动态结果解释；支持自定义主机与多端口 |
| 配置备份恢复 | 统一备份 SSH、防火墙、DNS、sysctl、Caddy 和 NFT 配置 |
| 操作记录 | 将关键操作、来源 IP 和结果写入 `/var/log/quench-audit.log` |
| 系统资源健康 | CPU、负载、内存、磁盘、inode、连接、进程及失败服务 |
| 系统更新管理 | 检查更新、安全更新、完整更新、自动安全更新和缓存清理 |
| 修改系统 Hostname | 修改系统 hostname，并同步 `/etc/hostname` 与 `/etc/hosts`；用于改变 `root@主机名` 里的系统名 |
| 配置体检中心 | 汇总检查本地脚本、SSH、Fail2ban、备份与历史版本 |
| 生成诊断包 | 导出脱敏诊断包，包含系统概览、服务状态、路由、资源、最近审计记录和关键配置快照 |

SSH、防火墙、DNS、glibc 地址选择、IPv6 内核状态及临时多 IP 出口修改会启动 180 秒防断联保护。用户未确认新连接正常时，脚本自动恢复修改前配置、逐接口运行时状态或完整默认路由。

高风险配置修改会先显示变更计划或逐行差异；配置备份默认保留最近 20 份，可通过环境变量 `QUENCH_BACKUP_KEEP` 调整。

DNS 管理会识别 `systemd-resolved`、NetworkManager、resolvconf 或静态 `/etc/resolv.conf`，只修改实际生效的作用域，并在直连预检、后端生效检查和系统解析测试全部通过后保留配置。

---

### a. 常用软件管理

**常用软件安装：**

| 分类 | 主要软件 |
|------|----------|
| 基础工具 | curl、wget、git、jq、压缩工具、编辑器、tmux、screen |
| 网络诊断 | iproute、DNS 工具、mtr、traceroute、tcpdump、socat、nmap |
| 系统监控 | htop、iftop、iotop、sysstat、lsof、ncdu |
| 开发环境 | 编译工具、Python、pip |

支持 apt、dnf、yum、apk、opkg 和 pacman，可同时选择多个分类。每次选择会先刷新索引，再在单个包管理器事务中批量安装并准确记录成功或失败；Arch Linux 使用完整 `pacman -Syu`，不会执行不受支持的部分升级。

Quench 不提供 DD 或系统重装。整盘擦除、引导切换和云平台网络重建需要独立、可验证且针对供应商救援环境设计的流程，不适合混入日常 VPS 管理入口。

---

### d. Docker 生产环境与容器管理

| 功能 | 说明 |
|------|------|
| 安装 / 修复 | Debian、Ubuntu、CentOS、RHEL、Fedora 使用 Docker 官方软件仓库并安装 Engine、Compose、Buildx；Alpine 明确使用发行版包 |
| 生产基线 | 合并而非覆盖现有 `daemon.json`，使用 `local` 日志驱动、20MB × 5 轮转与 `live-restore`，预检、重启、回读失败时恢复 |
| 权限 | 不自动把登录用户加入 `docker` 组；单独授权时明确提示该组具备 root 级能力并要求确认短语 |
| Compose 部署 | 仅接受无内嵌凭据的 HTTPS URL，固定保存到 `/opt/quench/compose/<项目>/compose.yaml`，展开完整配置并检查特权、宿主网络、设备、敏感挂载和发布端口 |
| 容器维护 | 查看、启停、日志、Shell、删除与镜像升级；Compose 服务升级会等待健康状态并在失败时尝试恢复旧镜像 |

Docker 发布端口可能绕过 UFW 的常规 `INPUT` 规则。诊断入口会提示当前防火墙状态；含发布端口的远程 Compose 必须输入独立确认短语，部署后仍应检查绑定地址、云安全组和 `DOCKER-USER` 链。

---

### m. 脚本管理

| 功能 | 说明 |
|------|------|
| 安装 + 设置快捷键 | `/usr/local/bin/vps-quench` + `v` / `V` 软链接 |
| 从 GitHub 更新 | 锁定 main commit 后下载同一提交的脚本与 SHA256，执行身份和 Bash 语法校验，保存旧版本并原子替换 |
| 回滚脚本版本 | 从 `/var/lib/quench/versions` 选择更新前版本恢复 |
| 删除本地脚本 | 默认取消；只删除本地脚本和 Quench 管理的软链接，保留数据、备份和系统配置 |

**快捷键设计：**
- 只用 `/usr/local/bin/v` 和 `/V` 软链接
- **不写 alias**，避免拦截 `v` 开头的其他命令（如 `volss`）

**自动检测新版本：** 后台请求 GitHub，新版本时主界面显示 🔔 提示。

---

## 安全增强

| 项 | 说明 |
|----|------|
| 防火墙卸载警告 | 清空规则会暴露主机，2 秒延迟 + 警告 |
| pf_flush 警告 | 清空所有 NAT 规则会影响其他应用 |
| HTTPS 应急校时 | 强制校验证书并使用多来源时间共识，来源不足或差异过大时拒绝改时；仅允许人工确认，不创建定时任务 |
| 内核支持检测 | BBR 应用前检测内核版本和模块 |
| 容器权限检测 | 自动识别无特权容器，sysctl 操作受限时友好提示 |
| 防断联保护 | 高风险网络修改 180 秒未确认自动回滚 |
| 更新完整性 | 下载脚本必须匹配仓库中的 SHA256 校验文件 |

---

## 兼容性

| 特性 | 说明 |
|------|------|
| 发行版 | Debian / Ubuntu / CentOS / Alpine / OpenWrt |
| 架构 | x86_64 / aarch64 / armv7 |
| 服务管理 | systemd / OpenRC / SysV init |
| 容器 | KVM / LXC / OpenVZ / 无特权容器 |
| 终端 | 36-76 列响应式布局；标准 / dumb / tmux / OpenWrt；支持 `NO_COLOR=1` |
| Shell | **bash 必需**（Alpine: `apk add bash`，OpenWrt: `opkg install bash`；非 bash 环境自动切换 / fail-fast 提示） |

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/vps-quench` | 主脚本 |
| `/usr/local/bin/v` `/V` | 快捷命令（软链接） |
| `/var/lib/quench/backups` | 统一配置备份与防断联快照 |
| `/var/lib/quench/versions` | 更新前的历史脚本版本 |
| `/var/lib/quench/mirrors` | APT/DNF 软件源事务快照、最近恢复点和当前源状态（仅 root 可读） |
| `/var/lib/quench/ip` | IPv6 持久化配置与逐接口运行时状态快照（仅 root 可读） |
| `/var/lib/quench/ssh-port-migration.state` | 尚未完成的 SSH 双端口迁移状态（600） |
| `/var/log/quench-audit.log` | 脚本操作审计日志（600） |
| `/etc/sudoers.d/90-quench-admins` | Quench 管理员组授权（440，写入前经 `visudo` 校验） |
| `/etc/sudoers.d/91-quench-nopasswd-<用户名>` | 按用户管理的免密 sudo 授权（440，写入后执行无密码提权验证） |
| `vps-quench.sh.sha256` | 自更新完整性校验值 |
| `/etc/sysctl.d/99-quench-bbr.conf` | BBR TCP 配置 |
| `/etc/sysctl.d/99-quench-ipv6.conf` | Quench 管理的内核 IPv6 禁用配置 |
| `/etc/gai.conf` | glibc 地址选择策略；Quench 只维护带边界标记的独立区块 |
| `/etc/sysctl.d/98-vps-quench-network-security.conf` | 首次开荒内核网络安全基线 |
| `/var/lib/quench/bbr-sysctl-baseline.conf` | BBR 首次调优前运行参数基线（600） |
| `/var/lib/quench/tc-calibration.state` | 最近一次线路实测结果（600） |
| `/swapfile.quench` | Quench 独立管理的 Swap 文件；不会复用或删除其他 Swap |
| `/var/lib/quench/swap/managed-file` | Quench Swap 所有权记录（600） |
| `/etc/sysctl.d/99-quench-swap.conf` | 独立的 swappiness 持久化策略 |
| `/etc/docker/daemon.json` | Docker 守护进程配置；Quench 生产基线只合并自己管理的键 |
| `/opt/quench/compose/<项目>/compose.yaml` | 经完整展开和风险确认后部署的 Compose 项目 |
| `/var/lib/quench/docker` | Docker 配置事务的即时备份与状态文件 |
| `/etc/quench/nft-forward` | 线路转发规则、每规则访问名单及防火墙联动状态（仅 root 可读） |
| `/var/lib/quench/nft-forward/sysctl-baseline` | 启用转发前的 IPv4/IPv6 forwarding 与 RA 参数基线（600） |
| `/etc/nftables.d/quench-nft-forward.nft` | Quench 独立的 `quench_nft4` / `quench_nft6` 规则文件，不加入主 ruleset |
| `/etc/sysctl.d/98-quench-nft-forward.conf` | 按实际规则协议族生成的内核转发参数 |
| `/usr/local/libexec/quench-nft-forward-apply` | 只原子替换 Quench NFT 表的启动应用助手 |
| `/etc/systemd/system/quench-nft-forward.service` | Quench 独立线路转发持久服务 |
| `/etc/systemd/system/quench-nft-target-refresh.timer` | NFT 域名目标自动刷新 timer |
| `/etc/systemd/system/quench-nft-target-refresh.service` | NFT 域名目标刷新任务 |
| `/etc/fail2ban/jail.d/zz-vps-quench.local` | Quench 最后加载的 Fail2ban SSH jail（不覆盖用户 `jail.local`） |
| `/etc/caddy/Caddyfile` | Caddy 主配置；Quench 只维护带边界标记的 `sites.d` import |
| `/etc/caddy/sites.d/*.caddy` | 每个 Quench 托管站点的独立配置文件 |
| `/var/lib/caddy` | Caddy 持久数据与证书缓存（卸载时保留） |
| `/var/log/caddy/*.access.log` | 各托管站点的 JSON 访问日志与轮转文件 |
| `/var/lib/quench/caddy` | Caddy 安装来源记录、配置锁与即时事务文件（仅 root 可读） |

---

## 项目地址

```
https://github.com/boyang-hu/vps-quench
```

```bash
# 一行安装
bash <(curl -fsSL https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.sh)
```

### 开发与构建

仓库源码位于 `src/lib/` 和 `src/modules/`。用户安装的 `vps-quench.sh` 是由模块生成的完整单文件，运行时不下载任何模块：

```bash
./build.sh          # 生成单文件并刷新 SHA256
./build.sh --check  # 检查发行文件是否与模块源码一致
tests/smoke.sh
tests/fault-injection.sh
```

GitHub Actions 还会在 Debian、Ubuntu、Alpine、Rocky Linux 容器中加载生成脚本并执行冒烟测试，并在 Linux network namespace 中实际验证 TCP/UDP 线路转发。

### BBR 模块维护

BBR、FQ、tc 与 initcwnd 统一由 `src/modules/bbr.sh` 管理。修改网络调优模块后，需要重新生成单文件发行版，并执行 Bash 语法、冒烟、故障注入和离线安装测试。

---

## 更新日志

| 版本 | Quench 主要变更 |
|------|----------------|
| **V0.1.0** | 首个完整版本：提供可重复执行的 VPS 开荒向导、用户与 SSH 安全接管、Fail2ban、防火墙、BBR/FQ 与线路实测、DNS、软件源、IP 出口、Caddy、NFT 四层转发、时间同步、Swap、Docker、常用软件、系统诊断、配置备份和脚本更新；关键配置变更包含预检、确认、验证、审计与失败恢复。 |
