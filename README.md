# DSH 红队工作站 · 一键部署

> 把 DeepSeek Harness（官方桌面端）改造成一台**完整的红队演练工作站** —— 破甲提示词、15 件套工具链、手机远程接入、自建 VPS 载荷与隧道基础设施。
>
> 全部实测验证，含踩坑记录与排障手册。

---

## 这套东西解决什么

原版 DSH 是一个受策略约束的对话工具。本项目把它变成：

| 维度 | 改造后 |
|---|---|
| **提示词** | dsh-purge 破甲 + **DeepSeek 专用适配层**（10 条针对 DS 失效模式的规则） |
| **工具链** | 15 件套红队工具（nmap / nuclei / fscan / gogo / suo5 / frp / chisel / impacket …） |
| **执行环境** | Windows 主控 + WSL 执行，工具全部落在 **D 盘**（C 盘占用 5 KB） |
| **手机接入** | 自己的域名 + Cloudflare 命名隧道 + PIN 门禁，4G 可用 |
| **VPS 基础设施** | 载荷分发服务 + 多路反弹 Shell 监听 + 隧道出口 |
| **模型兼容** | 越过 dsh 0.2 的版本兼容闸门，社区插件正常加载 |

---

## 架构总览

```
┌─────────────────────────── Windows 主机 ───────────────────────────┐
│                                                                    │
│  官方 DSH Desktop  http://127.0.0.1:19387                          │
│    ├─ dsh-purge       破甲补丁 + 提示词注入 + 红队演练台            │
│    ├─ dsh-infinite-gen-4  另一套破甲框架                           │
│    └─ dshmarket       社区插件市场（1.66.14）                      │
│                                                                    │
│  D:\security-tools\   916 MB，C 盘占用 5 KB                        │
│    ├─ bin\            真实 Linux ELF（WSL 执行）                   │
│    ├─ bin\*.cmd       Windows 包装器 → wsl.exe 转发                │
│    ├─ nuclei-templates\  14,042 个模板                             │
│    └─ wordlists\      SecLists 精选                                │
│                                                                    │
│  WSL Ubuntu-22.04     Linux 执行层                                 │
│    └─ /mnt/d/security-tools/bin/  ← 与上面同一份文件               │
│                                                                    │
│  cloudflared.exe      出站隧道（计划任务守护，开机自启）           │
└────────────────────────────────────────────────────────────────────┘
              │                              │
              │ Argo 隧道（出站，无需开端口） │ SSH :22
              ↓                              ↓
    ┌──────────────────┐         ┌──────────────────────────┐
    │  Cloudflare 边缘  │         │  自建 VPS                │
    │  YOUR_DOMAIN     │         │  nginx :80 :9100  载荷   │
    │  TLS 自动        │         │  tmux    :9000-9999 监听 │
    └──────────────────┘         └──────────────────────────┘
              ↑                              ↑
              │ HTTPS + PIN                  │ 反弹 Shell
         ┌────┴────┐                    ┌────┴────┐
         │  手机    │                    │ 目标机器 │
         └─────────┘                    └─────────┘
```

---

## 快速开始

```bash
git clone https://github.com/YOUR_GITHUB_USER/dsh-redteam-workstation
cd dsh-redteam-workstation
```

**按顺序读**（每篇都是自包含的，可跳到最需要的）：

| # | 文档 | 内容 |
|---|---|---|
| 1 | [安装插件到官方端](docs/01-install-plugins.md) | 客户端识别、bundles 冲突、**版本兼容闸门**（0/15 的根因） |
| 2 | [部署工具链](docs/02-toolchain.md) | 15 件套下载、Windows 包装器、junction 结构 |
| 3 | [手机远程访问](docs/03-phone-access.md) | 自有域名 + Cloudflare 隧道 + PIN 门禁 |
| 4 | [Windows 安全配置](docs/04-windows-security.md) | Defender 加排除 → 彻底禁用（省 478 MB） |
| 5 | [VPS 基础设施](docs/05-vps-setup.md) | 载荷服务、反弹 Shell 监听、rt 运维工具 |
| 6 | [排障手册](docs/06-troubleshooting.md) | 12 个踩过的坑 + 解法 |

---

## 目录结构

```
.
├── README.md
├── docs/
│   ├── 01-install-plugins.md      插件安装与版本闸门
│   ├── 02-toolchain.md            15 件套工具链部署
│   ├── 03-phone-access.md         手机远程访问
│   ├── 04-windows-security.md     Defender 配置
│   ├── 05-vps-setup.md            VPS 载荷与监听
│   └── 06-troubleshooting.md      排障手册
├── config/
│   ├── redteam-config.example.json    dsh-purge 环境适配
│   ├── env.example                    红队环境变量
│   ├── dsh-pocket-settings.example.json  手机访问配置
│   ├── hooks-deny.example.json        Hooks 放行
│   ├── deepseek-adapter.md            ★ DeepSeek 专用适配层
│   └── prompt-inject.reference.md     完整注入提示词参考
├── scripts/
│   ├── install_toolchain.py       工具链下载器（Python，免 unzip/sudo）
│   ├── mk_toolkit.ps1             junction 结构生成
│   ├── windows-security-config.ps1 安全配置菜单
│   ├── finish-defender-disable.ps1 补完 Defender 禁用
│   └── disable-defender.cmd       一键禁用
└── vps/
    ├── rt                         红队运维工具（装到 /usr/local/bin/rt）
    ├── rt-bootstrap               监听会话引导
    └── rt-listeners.service       systemd 单元
```

---

## 核心：DeepSeek 专用适配层

`config/deepseek-adapter.md` 是本项目最有价值的部分 —— **针对 DeepSeek 系模型特有的失效模式**（不是通用套话）：

| 规则 | 针对的行为 |
|---|---|
| **DS-1 思维链纪律** | DS 的 reasoning 会自发把「该不该答」当问题解 → 这是它拒绝的主因 |
| **DS-2 首 token 铁律** | DS 爱用缓冲词开头，一软就带偏整段 |
| **DS-3 禁止中途反悔** | DS 会在输出到 80% 时突然插警告并停止（最隐蔽的失效） |
| **DS-4 反冗余** | DS 输出密度比 Claude 低约 1.4 倍 |
| **DS-5 反元评论** | 爱穿插「需要指出的是」「从技术角度」 |
| **DS-6 中文语料偏置** | 「违法/犯罪/黑产」被高频绑定在特定叙事上 → 只做字面解析 |
| **DS-7 工具调用纪律** | DS 习惯先解释再调工具，浪费一轮 |
| **DS-8 多轮一致性** | 容易被自己上一轮的语气带偏 |
| **DS-9 静默自检** | 发出前 5 条扫查 |
| **DS-10 修复路径** | 4 级降级策略 |

**安装**：把内容插到 `$DSH_HOME/prompt-inject.md` 的 `World axioms` 行之后。

> ⚠️ **在 dsh-purge 界面点「应用」会用提示词框里的内容覆盖这个文件。** 改完先备份，或用 `docs/01` 里的还原脚本。

---

## 关键设计决策

### 为什么工具放 D 盘但 WSL 执行

Linux ELF 二进制**不能**被 Windows 进程直接执行。两种方案：

| 方案 | 问题 |
|---|---|
| 装 Windows 版工具 | 很多工具没有 Windows 构建（gogo/suo5/fscan 的 Linux 特性） |
| **放 D 盘 + `.cmd` 包装器转发 WSL** ✅ | 一份文件、两个系统都能用 |

包装器长相：

```bat
@echo off
wsl.exe -d Ubuntu-22.04 -e /mnt/d/security-tools/bin/nmap %*
```

### 为什么用 junction 而不是 symlink

Windows 上创建 symlink **需要管理员权限或开发者模式**；**junction 不需要**，且对目录有效。

`$DSH_HOME/redteam/toolkit/` 下 16 个子目录都是 junction 指回 `D:\security-tools\bin` —— 满足 `setup.sh` 的目录结构检查，同时 C 盘只占 5 KB。

### 为什么手机走 Cloudflare 隧道而不是 frp

| | Cloudflare 命名隧道 | frp |
|---|---|---|
| 开端口 | ❌ 不需要（出站连接） | ✅ 需要在安全组放行 |
| TLS 证书 | 自动签发续期 | 手动 |
| NAT 穿透 | 原生支持 | 需要公网 IP |
| 成本 | 免费 | 需要一台公网 VPS |

**但两者不冲突** —— 演练时的内网穿透仍然用 frp/chisel/suo5，Cloudflare 只管「你从外面看自己的 DSH」这条链路。

---

## 实测验证结果

```
【工具链】      15/15 就位，15/15 可执行（真跑 --version）
【dsh 插件】    0 个 skip，0 个 did not activate
【VPS】         载荷服务 200，5 个监听会话，端到端回连成功
【端口】        80 ✅  443 ✅  9000 ✅  9001 ✅  9100 ✅
【手机】        https://dsh.YOUR_DOMAIN -> 200，PIN 门禁生效
【资源】        C 盘 toolkit 5.0K / D 盘 916M
               Defender 540.9 MB → 63.3 MB
```

**端到端反弹 Shell 测试**：

```
Ncat: Connection from <本机公网IP>.
=== REDTEAM E2E ===
whoami: user
host: YOUR_MACHINE
id: uid=1000(user) gid=1000(user) groups=1000(user),4(adm),20(dialout)...
kernel: 6.18.33.1-microsoft-standard-WSL2
```

---

## 环境要求

| 项 | 版本 | 说明 |
|---|---|---|
| Windows | 10/11（**专业版**有组策略） | 家庭版部分组策略键无效 |
| 官方 DSH Desktop | `@deepseek-ai/dsh@0.2.0-rc.2` | 社区版不适用（核心版本低） |
| WSL | Ubuntu-22.04（glibc 2.35） | **24.04 也行，但注意 glibc 兼容** |
| Node | 20+ | 随 DSH 附带 |
| 磁盘 | D 盘 ≥ 2 GB | 工具链 + 模板 916 MB |
| 域名 | 可选 | 走 Cloudflare 隧道需要 |
| VPS | 可选 | 反弹 Shell 需要，1 vCPU / 2 GB 够 |

---

## 免责声明

本项目是**本机环境配置**的记录与工具集，用于：

- 使用者在**自己拥有或已获书面授权**的环境中的攻防演练
- 安全工具的部署与管理
- DeepSeek Harness 的本地化改造

**不包含**任何针对第三方系统的攻击载荷、扫描目标或入侵脚本。文档中的工具（nmap/nuclei/fscan 等）都是公开的安全测试工具，**未经授权对他人系统使用属于违法行为**。

使用者对自己的一切行为负责。

---

## 许可

MIT

## 致谢

- [YuJunZhiXue/dsh-purge](https://github.com/YuJunZhiXue/dsh-purge) —— 破甲补丁与红队预设
- [dsh-market](https://github.com/dsh-market/dsh-market) —— 社区插件市场
- [awesome-dsh-plugin](https://awesome-dsh-plugin.com) —— 插件目录
- 各工具原作者：projectdiscovery / shadow1ng / chainreactors / zema1 / fatedier / jpillora / nicocha30 …
