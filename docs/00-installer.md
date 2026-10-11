# 00 · 安装器使用说明

> 双击 `install\INSTALL-ALL.cmd` 即可。**不需要 AI，不需要手敲命令。**

---

## 快速开始

```
1. 双击  install\INSTALL-ALL.cmd
2. UAC 弹窗 → 是（提权）
3. 菜单选 [A] 全装，或按需选单项
```

---

## 为什么要提权

| 步骤 | 是否需要管理员 | 原因 |
|---|---|---|
| 1 插件安装 | 否 | 只读写用户目录 |
| 2 工具链 | 否 | 只写 D 盘 |
| 3 手机访问 | **是** | 注册计划任务（cloudflared 自启） |
| 4 Defender | **是** | 改注册表 / 停服务 |
| 5 VPS | 否 | 走 SSH |
| 6 验证 | 否 | 只读 |
| 7 提示词 | 否 | 只写用户目录 |

启动器会**自动检测并请求 UAC**，拒绝提权也能跑不需要管理员的步骤。

---

## 前置条件

| 项 | 必需 | 说明 |
|---|---|---|
| Windows 10/11 | ✅ | 专业版可启用组策略 |
| WSL Ubuntu-22.04 | ✅（步骤 2） | `wsl --install -d Ubuntu-22.04` |
| 官方 DSH Desktop | ✅（步骤 1） | 默认路径 `D:\dsh\` |
| D 盘 ≥ 2 GB | ✅ | 工具链 916 MB |
| Cloudflare 域名 | 步骤 3 | 手机访问用 |
| 公网 VPS | 步骤 5 | 反弹 shell 用 |

**缺前置时脚本会提示具体命令，不会静默失败。**

---

## 架构：为什么是 .cmd + .ps1

```
INSTALL-ALL.cmd          ← 纯 ASCII，只做菜单 + 提权 + 转发
  └─ steps\N-xxx.cmd     ← 纯 ASCII，只做提权 + 转发
       └─ steps\N-xxx.ps1 ← UTF-8 + BOM，真正的逻辑
```

**原因**：cmd 按 OEM 代码页**逐字节**解析批处理文件，`chcp` 对它无效。
UTF-8 多字节字符（中文、`─`）会让解析错位，**连换行都被吞** ——
脚本在解析阶段就崩，**执行不到 `pause`**，表现为「闪退」。

PowerShell 则原生支持 UTF-8，只要文件带 BOM。

**所以铁律**：

| 文件类型 | 编码 | 行尾 |
|---|---|---|
| `.cmd` / `.bat` | **纯 ASCII** | CRLF |
| `.ps1` | **UTF-8 + BOM** | CRLF |
| `.sh` | UTF-8 | LF |

---

## 校验工具

改了脚本之后，跑一次：

```bash
python3 scripts/validate-package.py .
```

检查五项：

```
1. .cmd/.bat 里的非 ASCII 字节      → 会导致闪退
2. .ps1 缺 UTF-8 BOM                → 中文乱码
3. 赋值给 PowerShell 自动变量        → 静默失败（$host 是只读的）
4. $var: 缺花括号                    → 被当成 scope 限定符
5. shell 脚本里的 CRLF               → bash 报 $'\r': command not found
```

**期望输出**：

```
scanned 23 script file(s) under .
  ALL CHECKS PASSED
    .cmd / .bat : pure ASCII + CRLF
    .ps1        : UTF-8 + BOM + CRLF, no reserved-variable collisions
    .sh         : LF
```

---

## 各步骤做什么

### 1-plugins

- 定位官方 DSH（从 `D:\dsh\` 开始找）
- 读在跑进程的命令行，**确认真实 profile**
- **前台跑一次 harness**，数 `skipping profile bundle`（← 逼出版本闸门）
- 检查每个插件的 `dsh.client` 声明
- 检查 `bundles` vs `cordis.patch.yml` 重复注册
- 备份提示词 + 生成还原脚本

### 2-toolchain

- 检查 WSL 和 glibc 版本
- 下载 15 件套（Python，**免 unzip、免 sudo**）
- 生成 Windows `.cmd` 包装器 ← **这一步解决 0/15**
- 建 junction 结构（C 盘不占空间）
- 下 nuclei 模板 + 字典
- 写 `redteam/config.json`
- **跑解析验证 + 逐工具冒烟测试**

### 3-phone

- 建 Cloudflare 隧道
- 配 ingress（域名 → 本地 3081）
- 建 DNS CNAME
- 取隧道 token
- 写 dsh-pocket 配置
- 注册自启计划任务
- 用 DoH 验证 DNS（**绕开本地负缓存**）

### 4-defender

三选一菜单：

```
[1] 加排除项      保留防护，只放过工具目录     ← 推荐先跑这个
[2] 只关实时保护   临时
[3] 彻底禁用       ~478 MB，需重启
[4] 恢复
```

### 5-vps

- SSH 连通性测试
- 装基础包（tmux / nc / socat）
- 起 nginx 载荷服务（:80 + :9100）
- 上传 `rt` 运维工具 + systemd 单元
- 探测端口可达性，**清楚地告诉你要开哪些安全组规则**
- 写 `.env`

### 6-verify

只读，不改任何东西。汇总五层状态：

```
DSH 进程 / 插件 / 工具链 / 提示词 / Defender / 手机 / VPS
```

### 7-prompt

- 把 DeepSeek 适配层插到 `World axioms` 锚点之后
- 锁 `override-state.json: customized=true`
- 生成 `restore-prompt.cmd`
- 验证规则条数

---

## 常见问题

**Q: 双击闪退？**

A: 你的 `.cmd` 里混进了非 ASCII 字符。跑校验器：

```bash
python3 scripts/validate-package.py .
```

**Q: 菜单选项没反应？**

A: 可能被 UAC 拦了。右键 `.cmd` → 以管理员身份运行。

**Q: 步骤 2 显示 0/15？**

A: 见 [06-troubleshooting.md](06-troubleshooting.md) 的 D1 —— 路径解析问题。
安装器会自动生成包装器，如果是手动配的，检查 `config.json` 里是不是
`.cmd` 路径（不是 `/mnt/...`）。

**Q: 能只跑某一步吗？**

A: 可以。菜单直接选，或单独双击 `steps\N-xxx.cmd`。

**Q: 怎么撤销？**

A:
- Defender → `4-defender.cmd` 选 4
- 提示词 → `~/.dsh/dsh-purge/restore-prompt.cmd`
- 计划任务 → `Unregister-ScheduledTask -TaskName 'DSH-Pocket-Tunnel'`
- 全部 → 删 `D:\security-tools` 和 `~/.dsh/profiles/desktop/node_modules`
