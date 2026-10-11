# 02 · 部署 15 件套工具链

> 目标：`dsh-purge` 的 `环境适配` 页面显示 **15/15 工具就位**，且每个都能真跑。
>
> 全部装在 **D 盘**，C 盘占用 5 KB。

---

## 工具清单

| # | 工具 | 版本 | 用途 | 来源 |
|---|---|---|---|---|
| 1 | **nmap** | 6.49BETA1 | 端口/服务扫描 | andrew-d/static-binaries |
| 2 | **nuclei** | 3.11.1 | 模板化漏洞扫描 | projectdiscovery |
| 3 | **masscan** | 1.3.2 | 大规模端口扫描 | Ubuntu .deb |
| 4 | **fscan** | 2.2.2 | 内网综合扫描/爆破 | shadow1ng |
| 5 | **gogo** | 2.15.0 | 内网资产测绘 | chainreactors |
| 6 | **suo5** | 2.2.0 | 内存马隧道 | zema1 |
| 7 | **frpc** | 0.71.0 | frp 客户端 | fatedier |
| 8 | **frps** | 0.71.0 | frp 服务端 | fatedier |
| 9 | **chisel** | 1.12.0 | HTTP 隧道 | jpillora |
| 10 | **ffuf** | 2.3.0 | 目录/参数爆破 | ffuf |
| 11 | **httpx** | latest | 存活探测/指纹 | projectdiscovery |
| 12 | **dnsx** | latest | DNS 工具集 | projectdiscovery |
| 13 | **subfinder** | 2.17.0 | 子域枚举 | projectdiscovery |
| 14 | **ksubdomain** | 2.4.0 | 无状态子域爆破 | boy-hack |
| 15 | **impacket** | 0.13.1 | AD 攻击套件 | Fortra |

**额外装机（catalog 里没有但技能会用到）**：naabu、gowitness、ligolo-ng（proxy + agent）

---

## 前置

```bash
# WSL 必须有
wsl -l -v
# → Ubuntu-22.04  Running  2
```

> **glibc 注意**：Ubuntu 22.04 = glibc 2.35；24.04 = 2.39。从 24.04 的包源拿的二进制在 22.04 上会报 `GLIBC_2.38 not found`。

---

## 步骤 1 · 下载工具

用仓库里的 `scripts/install_toolchain.py`（**纯 Python，不依赖 unzip，不需要 sudo**）：

```bash
wsl -d Ubuntu-22.04 -e bash -lc "python3 /mnt/d/dsh-redteam-workstation/scripts/install_toolchain.py"
```

它做的事：
- 走 GitHub API 拿真实 release 资产名（**不猜 URL**）
- 用 Python `zipfile`/`tarfile` 解压（**绕开没装的 `unzip`**）
- 逐个写入 `/mnt/d/security-tools/bin/`

**预期输出**：

```
nuclei       OK   143,294,626 字节
httpx        OK    54,444,194 字节
dnsx         OK    28,569,784 字节
subfinder    OK    30,474,402 字节
...
```

### 手动补装（脚本覆盖不到的）

```bash
# naabu
curl -sL -o /tmp/n.zip "https://github.com/projectdiscovery/naabu/releases/latest/download/naabu_<ver>_linux_amd64.zip"
# gowitness（注意仓库是 sensepost，不是 senhasegura）
TAG=$(curl -sL -o /dev/null -w "%{url_effective}" https://github.com/sensepost/gowitness/releases/latest | grep -oE 'tag/[^/]+$' | cut -d/ -f2)
curl -sL -o /mnt/d/security-tools/bin/gowitness \
  "https://github.com/sensepost/gowitness/releases/download/$TAG/gowitness-${TAG#v}-linux-amd64"

# ligolo-ng
LV=$(curl -sL https://api.github.com/repos/nicocha30/ligolo-ng/releases/latest | grep -oE '"tag_name":[^,]*' | grep -oE 'v[0-9.]+')
curl -sL -o /tmp/a.tgz "https://github.com/nicocha30/ligolo-ng/releases/download/$LV/ligolo-ng_agent_${LV#v}_linux_amd64.tar.gz"
```

### masscan 特殊处理

masscan 没有静态构建。从 Ubuntu 源拿 `.deb` 解包：

```bash
cd /tmp
curl -sLO "http://archive.ubuntu.com/ubuntu/pool/universe/m/masscan/masscan_1.3.2+ds1-2_amd64.deb"
mkdir mx && cd mx && ar x ../masscan_*.deb
# 包内是 zstd，需要 zstandard
python3 -m pip install --user zstandard
python3 - <<'PY'
import zstandard, tarfile, io, os
d = zstandard.ZstdDecompressor().decompress(open("data.tar.zst","rb").read(), max_output_size=300*1024*1024)
tf = tarfile.open(fileobj=io.BytesIO(d))
for m in tf.getmembers():
    if os.path.basename(m.name)=="masscan":
        out="/mnt/d/security-tools/bin/masscan"
        open(out,"wb").write(tf.extractfile(m).read()); os.chmod(out,0o755)
PY
```

> ⚠️ **版本要选对**：`+ds1-2build1` 是 Ubuntu 24.04 的（需要 glibc 2.38），用 `+ds1-2` 或 `+ds1-1`。

---

## 步骤 2 · 建 Windows 包装器 ⭐ 关键

**这是「0/15」的根因所在。**

`dsh-purge` 是 **Windows Node 进程**，无法直接执行 Linux ELF。而且：

```js
const abs = isAbsolute(configured) ? configured : resolve(configured)
existsSync(abs)
```

Node 在 Windows 上把 `/mnt/d/security-tools/bin/nmap` 解析成 **`C:\mnt\d\...`** → 必然不存在。

**解法：给每个工具生成 `.cmd` 包装器。**

```python
import os, io
BIN, W, DIST = r'D:\security-tools\bin', '/mnt/d/security-tools/bin', 'Ubuntu-22.04'
TOOLS = ['nmap','nuclei','masscan','fscan','gogo','suo5','chisel','ffuf','httpx',
         'dnsx','subfinder','ksubdomain','gowitness','frpc','frps','ligolo-proxy','ligolo-agent']
for t in TOOLS:
    if not os.path.exists(os.path.join(BIN, t)): continue
    io.open(os.path.join(BIN, t+'.cmd'), 'w', encoding='ascii', newline='').write(
        f'@echo off\r\nwsl.exe -d {DIST} -e {W}/{t} %*\r\n')

# impacket 是 Python 脚本，单独处理
for name, script in [('impacket-secretsdump','secretsdump.py'),
                     ('impacket-psexec','psexec.py'),
                     ('impacket-wmiexec','wmiexec.py'),
                     ('impacket-GetNPUsers','GetNPUsers.py')]:
    io.open(os.path.join(BIN, name+'.cmd'), 'w', encoding='ascii', newline='').write(
        f'@echo off\r\nwsl.exe -d {DIST} -e bash -lc "python3 ~/.local/bin/{script} %*"\r\n')
```

**验证**：

```powershell
& cmd /c 'D:\security-tools\bin\nmap.cmd --version'
# → Nmap version 6.49BETA1
```

---

## 步骤 3 · impacket（无 sudo 安装）

WSL 里 `pip` 可能没装，也没有 `ensurepip`。用 `get-pip.py` 引导：

```bash
wsl -d Ubuntu-22.04 -e bash -lc '
curl -sL -o /tmp/gp.py https://bootstrap.pypa.io/get-pip.py
python3 /tmp/gp.py --user --quiet
python3 -m pip install --user --quiet impacket
python3 -c "import impacket; print(\"impacket ok\")"
'
```

脚本落在 `~/.local/bin/secretsdump.py` 等。

---

## 步骤 4 · 建 toolkit junction 结构

`$DSH_HOME/redteam/setup.sh` 硬编码检查 `$DSH_HOME/redteam/toolkit/<工具名>/<二进制>` 的结构。用 **junction**（不需要管理员权限）指回 D 盘：

```powershell
$TK  = "$env:USERPROFILE\.dsh\redteam\toolkit"
$SRC = 'D:\security-tools\bin'
New-Item -ItemType Directory -Path $TK -Force | Out-Null
foreach ($s in @('nuclei','httpx','dnsx','subfinder','naabu','fscan','gogo','suo5',
                 'chisel','ffuf','ksubdomain','gowitness','frp','ligolo','nmap','masscan')) {
  New-Item -ItemType Junction -Path (Join-Path $TK $s) -Target $SRC -Force | Out-Null
}
```

**为什么不用 symlink**：Windows 创建 symlink **需要管理员或开发者模式**；junction 不需要。用 symlink 失败后很多脚本会静默退化成 **copy** —— 那就把 300 MB 复制到 C 盘了。

**验证 C 盘占用**：

```bash
du -sh ~/.dsh/redteam/toolkit
# → 5.0K   ✅
```

### 别名目录

`setup.sh` 期望的名字和实际文件名不完全一致，需要额外目录：

| 期望路径 | 实际文件 |
|---|---|
| `suo5/suo5-linux-amd64` | `suo5` |
| `ligolo/proxy` | `ligolo-proxy` |
| `ligolo/agent` | `ligolo-agent` |

在 D 盘建 `aliases/` 目录放这些别名，再 junction 过去 —— **别直接 copy 到 C 盘**。

---

## 步骤 5 · nuclei 模板

```bash
wsl -d Ubuntu-22.04 -e bash -lc '
cd /mnt/d/security-tools
curl -sL -o nt.tar.gz https://github.com/projectdiscovery/nuclei-templates/archive/refs/heads/main.tar.gz
mkdir -p nuclei-templates
tar xzf nt.tar.gz -C nuclei-templates --strip-components=1
find nuclei-templates -name "*.yaml" | wc -l
'
# → 14042
```

让 nuclei 用这个目录：

```bash
wsl -d Ubuntu-22.04 -e bash -lc '
mkdir -p ~/.config/nuclei
echo "templates-directory: /mnt/d/security-tools/nuclei-templates" > ~/.config/nuclei/config.yaml
'
```

---

## 步骤 6 · 写 dsh-purge 配置

`~/.dsh/redteam/config.json`：

```json
{
  "version": 1,
  "platform": "windows",
  "toolkitDir": "D:\\security-tools",
  "nucleiTemplatesDir": "D:\\security-tools\\nuclei-templates",
  "binDirs": ["D:\\security-tools\\bin"],
  "tools": {
    "nmap":       "D:\\security-tools\\bin\\nmap.cmd",
    "nuclei":     "D:\\security-tools\\bin\\nuclei.cmd",
    "masscan":    "D:\\security-tools\\bin\\masscan.cmd",
    "fscan":      "D:\\security-tools\\bin\\fscan.cmd",
    "gogo":       "D:\\security-tools\\bin\\gogo.cmd",
    "suo5":       "D:\\security-tools\\bin\\suo5.cmd",
    "frpc":       "D:\\security-tools\\bin\\frpc.cmd",
    "frps":       "D:\\security-tools\\bin\\frps.cmd",
    "chisel":     "D:\\security-tools\\bin\\chisel.cmd",
    "ffuf":       "D:\\security-tools\\bin\\ffuf.cmd",
    "httpx":      "D:\\security-tools\\bin\\httpx.cmd",
    "dnsx":       "D:\\security-tools\\bin\\dnsx.cmd",
    "subfinder":  "D:\\security-tools\\bin\\subfinder.cmd",
    "ksubdomain": "D:\\security-tools\\bin\\ksubdomain.cmd",
    "impacket":   "D:\\security-tools\\bin\\impacket-secretsdump.cmd"
  },
  "env": {
    "FOFA_KEY": "",
    "REDTEAM_VPS_HOST": "YOUR_VPS_IP",
    "REDTEAM_VPS_KEY": "~/.ssh/id_rsa_vps"
  },
  "envAdaptSkip": false,
  "envAdaptConfigured": true
}
```

> ⚠️ **`platform` 只能是 `auto` / `windows` / `linux`。** 填别的值（比如 `wsl`）会落到 `osPlatform() === 'win32'` 分支，虽然不是致命错，但语义混乱。

---

## 验收

```bash
cd /d/dsh
node --input-type=module -e "
import path from 'node:path'; import { pathToFileURL } from 'node:url';
const P = path.join(process.env.USERPROFILE,'.dsh','plugins','dsh-purge','lib','redteam','platform-config.js');
const m = await import(pathToFileURL(P).href);
const r = m.resolveAllTools();
console.log(r.filter(x=>x.path).length + '/' + r.length + ' 就位');
r.filter(x=>!x.path).forEach(x=>console.log('  缺: '+x.id));
"
```

**期望**：`15/15 就位`

再跑 `setup.sh` 的冒烟测试（**必须在 WSL 内跑**，因为它检查 Linux 二进制）：

```bash
wsl -d Ubuntu-22.04 -e bash -lc '
export DSH_HOME=/mnt/c/Users/<你>/.dsh
export REDTEAM_NO_VM_WARN=1
bash $DSH_HOME/redteam/setup.sh --check
'
```

**期望**：`✓ 工具箱完整（全部二进制冒烟通过）`

---

## 相关文档

- 插件安装 → [01-install-plugins.md](01-install-plugins.md)
- 排障手册 → [06-troubleshooting.md](06-troubleshooting.md)
