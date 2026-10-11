# 06 · 排障手册

> 这里每一条都是**真实踩过的坑**，不是理论。

---

## A. 脚本闪退 / 中文乱码

### A1. `.cmd` 闪退，什么都看不到 ⭐

**症状**：双击就关，来不及看输出。

**根因**：cmd 的批处理解析器**按 OEM 代码页逐字节读文件**，`chcp` 对它无效。
文件里如果有 UTF-8 多字节字符（中文、`─` `═` 这类制表符），
解析会**错位**，连换行都被吞掉：

```
'??────' is not recognized as an internal or external command
'─────────────' is not recognized as an internal or external command
'The syntax of the command is incorrect.'
```

脚本在**解析阶段**就崩了，**根本执行不到 `pause`** —— 所以闪退。

**解法**：`.cmd` 里只写 **ASCII**。中文逻辑挪到 `.ps1`。

```bat
REM 错：echo ═══ 开始安装 ═══
REM 对：echo   === Starting ===

REM 正确的架构：cmd 只做提权和转发
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0step.ps1"
```

**自查**：

```bash
python3 -c "
b = open('install.cmd','rb').read()
try:
    b.decode('ascii'); print('ASCII OK')
except Exception as e:
    print('NON-ASCII:', e)
"
```

### A2. `.ps1` 里中文变乱码

**根因**：PowerShell 5.1 读**无 BOM** 的文件时用 ANSI 代码页解码。

**解法**：**UTF-8 + BOM**。

```python
# 写
io.open(path, 'w', encoding='utf-8-sig').write(text)

# 事后补 BOM
raw = open(path, 'rb').read()
if not raw.startswith(b'\xef\xbb\xbf'):
    open(path, 'wb').write(b'\xef\xbb\xbf' + raw)
```

### A3. 一次性查完

```bash
python3 scripts/validate-package.py .
```

检查五项：非 ASCII、缺 BOM、`$host` 冲突、`$var:` 缺花括号、shell 里的 CRLF。

---

## B. PowerShell 自动变量陷阱

### B1. 赋值了但值没变 ⭐

```powershell
$host = 'dsh.example.com'
Write-Host $host
# → System.Management.Automation.Internal.Host.InternalHost
#   而不是你赋的字符串
```

**根因**：`$host` 是**只读自动变量**。赋值**静默失败**，旧值保留。

**真实后果**：本项目里这条产生了一条 Cloudflare DNS 记录：

```
CNAME system.management.automation.internal.host.internalhost.example.com
```

**保留字清单**（不要拿来当自己的变量名）：

```
$host  $input  $args  $error  $matches  $profile  $psitem
$true  $false  $home  $pid  $pwd  $pshome  $shellid
$stacktrace  $this  $foreach  $switch  $myinvocation
$executioncontext  $psversiontable  $psstyle
$iswindows  $islinux  $ismacos  $lastexitcode
```

> `$null = ...` 是**合法**的丢弃输出惯用法，是唯一例外。

**解法**：用描述性名字。

```powershell
$targetHost = 'dsh.example.com'
$hostName   = 'dsh.example.com'
$binDir     = 'D:\security-tools\bin'
```

### B2. `$var:` 后跟非变量名字符

```powershell
$srv = '10.0.0.1'
Write-Host "http://$srv:9100/"     # 错：$srv: 被当成 scope/drive 限定符
Write-Host "http://${srv}:9100/"   # 对
```

---

## C. 插件不加载

### C1. 插件装好了但界面没入口

**三查**（按顺序）：

```bash
# ① 有没有 dsh.client
node -e "console.log(require('./node_modules/PLUGIN/package.json').dsh?.client ? 'YES':'NO')"

# ② 有没有重复注册
grep PLUGIN ~/.dsh/profiles/desktop/cordis.patch.yml

# ③ 有没有被版本闸门跳过（见 C2）
```

### C2. 版本闸门静默跳过 ⭐ 最隐蔽

**症状**：插件在 `node_modules` ✅、在 `bundles` ✅、**启动零报错**、功能就是没有。

**根因**：dsh 0.2 检查插件 `peerDependencies`，不满足就**静默跳过** ——
不报错、不警告、不显示。

**必须前台跑一次才能看到**：

```powershell
# 先完全退出 DSH
cd D:\dsh
& ".\DeepSeek Harness.exe" --expose-internals `
  ".\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js" `
  ".\resources\app.asar\dsh" `
  "$env:USERPROFILE\.dsh\profiles\desktop" `
  ".\resources\runtime\primary-runtime" `
  ".\resources\runtime\pnpm\bin\pnpm.mjs" `
  ".\resources\runtime\bin"
```

**期望零 skip**。有 skip 会看到：

```
dsh: skipping profile bundle "dshmarket": Error: Plugin dshmarket@1.47.0 is
incompatible with dsh 0.2.0-rc.2: peerDependencies {...}
```

**解法**：升级（首选）或豁免。

```bash
dsh plugin --profile desktop allow-version PLUGIN@VER --dsh-version 0.2.0-rc.2 --accept-risk
```

> ⚠️ 豁免只是让加载器不拦。代码里用了改掉的 API 还是会炸。
> 例如 `settingsScope` 在 0.2 里没了 → `pending (waiting for service: settingsScope)`。
> 这类**必须移除**。

### C3. `duplicate loader entry id`

**根因**：`bundles` 和 `cordis.patch.yml` 同时注册。

**解法**：桌面端**只留 `bundles`**，删掉 `cordis.patch.yml` 里的 `insert`。

### C4. React #130

```
Minified React error #130
Element type is invalid ... got: undefined
```

**根因**：客户端插件引用的组件在核心版本里不存在 —— **版本不匹配**。

对 `dshmarket`：**1.47.0 → 1.66.14** 修复。

---

## D. 工具链

### D1. 显示 0/15 ⭐ 本项目最大的坑

**根因**：路径解析。

`dsh-purge` 是 **Windows Node 进程**，无法执行 Linux ELF。而且：

```js
const abs = isAbsolute(configured) ? configured : resolve(configured)
existsSync(abs)
```

Node 在 Windows 上把 `/mnt/d/security-tools/bin/nmap` 解析成
**`C:\mnt\d\...`** → 必然不存在 → 15/15 全部 missing。

**解法**：给每个工具生成 `.cmd` 包装器。

```bat
@echo off
wsl.exe -d Ubuntu-22.04 -e /mnt/d/security-tools/bin/nmap %*
```

`config.json` 指向 `D:\security-tools\bin\nmap.cmd`。

**验证**：

```bash
node --input-type=module -e "
import path from 'node:path'; import { pathToFileURL } from 'node:url';
const P = path.join(process.env.USERPROFILE,'.dsh','plugins','dsh-purge','lib','redteam','platform-config.js');
const m = await import(pathToFileURL(P).href);
const r = m.resolveAllTools();
console.log(r.filter(x=>x.path).length + '/' + r.length);
"
```

### D2. `unzip: command not found`

Ubuntu 22.04 最小安装没有 `unzip`，而你可能没有 sudo。

**解法**：用 Python。

```python
import zipfile
with zipfile.ZipFile('x.zip') as z:
    open('out', 'wb').write(z.read('binary_inside'))
```

或 `python3 -m zipfile -e x.zip out/`

### D3. `pip` 不存在

```bash
python3 -m pip --version      # → No module named pip
python3 -m ensurepip --version # → No module named ensurepip
```

**解法**：`get-pip.py` 引导（`--user`，不需要 sudo）。

```bash
curl -sL -o /tmp/gp.py https://bootstrap.pypa.io/get-pip.py
python3 /tmp/gp.py --user --quiet
python3 -m pip install --user impacket
```

### D4. `GLIBC_2.38 not found`

**根因**：从 Ubuntu **24.04** 的包源拿的二进制，在 **22.04**（glibc 2.35）上跑不了。

**解法**：换对应的包版本。masscan 例：

```
masscan_1.3.2+ds1-2build1_amd64.deb   ← 24.04 (noble)，需要 glibc 2.38
masscan_1.3.2+ds1-2_amd64.deb         ← 22.04 (jammy)，可用
```

### D5. 工具下下来是空文件

**根因**：release 资产名猜错了。GitHub 命名不统一：

```
fscan_2.2.2_linux_amd64    ← 错，实际是 linux_x64
fscan_2.2.2_linux_x64      ← 对
gogo_linux_amd64           ← 裸二进制，没有扩展名
suo5-linux-amd64           ← 裸二进制
KSubdomain-v2.4.0-linux-amd64.zip
```

**解法**：不要猜，用 API 查。

```bash
curl -s https://api.github.com/repos/OWNER/REPO/releases/latest |
  python3 -c "
import sys, json
j = json.load(sys.stdin)
for a in j['assets']:
    print(a['name'], a['size'])
"
```

### D6. C 盘被塞满

**根因**：symlink 创建失败，脚本**静默退化成 copy**。

Windows 创建 symlink **需要管理员权限或开发者模式**；junction 不需要。

**解法**：用 junction（只对目录有效）。

```powershell
New-Item -ItemType Junction -Path $link -Target 'D:\security-tools\bin' -Force
```

**验证**：

```bash
du -sh ~/.dsh/redteam/toolkit
# 应该 5.0K 左右，不是 300M
```

### D7. Defender 吃掉工具

```powershell
Get-MpThreatDetection | Where-Object { $_.Resources -match 'security-tools' }
# → file:_D:\security-tools\bin\chisel   （重复出现）
```

**解法**：加排除项（见 [04-windows-security.md](04-windows-security.md)）。

---

## E. 手机访问

### E1. DNS 查不到

**不要用 `nslookup`** —— 它走本地解析器，可能有 NXDOMAIN 负缓存。

**用 DoH**：

```bash
curl -s -H 'accept: application/dns-json' \
  "https://cloudflare-dns.com/dns-query?name=dsh.example.com&type=A"
```

返回 `Status:0` + IP 就是正常的。

### E2. 503「无法完成登录握手」

**两个原因**：

**① 握手重试计数打满**（每 IP 60 秒窗口，上限 3 次）

```bash
curl -H "Host: dsh.example.com" "http://127.0.0.1:3081/?dsh-pocket-retry=1"
```

**② 浏览器不保存 cookie** —— iOS Safari 在 `http://` + 纯 IP 源上不持久化 cookie。
**HTTPS 域名上正常。**

### E3. PIN 一直不对

**两个不同的 PIN，按 host 分发**：

```bash
cat ~/.dsh/dsh-pocket/token       # 公网
cat ~/.dsh/dsh-pocket/token-lan   # 局域网
```

公网入口必须用 `token`。

**测试**：

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: dsh.example.com" -X POST -d "token=YOUR_PIN" \
  http://127.0.0.1:3081/pocket-login
# → 302 表示成功
```

### E4. `taskkill /T` 杀掉了隧道

```bat
taskkill /F /IM "DeepSeek Harness.exe" /T   REM /T 杀进程树，连带 cloudflared
taskkill /F /IM "DeepSeek Harness.exe"      REM 正确
```

---

## F. dsh-purge 专项

### F1. `EPERM ... @deepseek-ai\dsh\lib\...`

**根因**：dsh-purge 枚举**所有** `@deepseek-ai` 宿主，包括指向
`C:\Program Files`（只读）的 junction 农场。写不进去就**整体失败**。

**解法**：把农场重指向可写副本。

```powershell
# 复制到可写位置
robocopy "D:\Program Files\DSH Desktop\resources\app\node_modules\@deepseek-ai" `
         "D:\dsh-community-ai" /E

# 重指向
$linkRoot = "$env:APPDATA\dsh-desktop\harness\profiles\node_modules\@deepseek-ai"
Get-ChildItem $linkRoot -Force | ForEach-Object {
    $lnk = $_.FullName
    cmd /c "rmdir `"$lnk`""
    cmd /c "mklink /J `"$lnk`" `"D:\dsh-community-ai\$($_.Name)`""
}
```

### F2. 提示词被覆盖

dsh-purge 界面点 **应用** 时，会把**提示词框里的全文**写回
`$DSH_HOME/prompt-inject.md`。框里显示内置默认 → 你的内容没了。

**防护**：

```bash
cp ~/.dsh/prompt-inject.md ~/.dsh/dsh-purge/prompt-inject.custom.md
```

跑安装器的 `7-prompt.cmd` 会自动做这件事并生成 `restore-prompt.cmd`。

### F3. 补丁不生效

**根因**：dsh-purge 把补丁打在 `resources/app/`，但 **`app.asar` 还在** →
Electron 优先读 asar。

**检查**：

```bash
ls -la "D:/dsh/resources/" | grep -E 'asar|app$'
```

同时存在 `app.asar` 和 `app/` → 补丁**没生效**。

**解法**：把 `app.asar` 改名挪走（dsh-purge 会留 `app.dshpurge-prev-*` 备份）。
**有风险** —— 解包不完整会导致桌面端起不来。

---

## G. 快速诊断

```bash
# 编码 / 转义合规
python3 scripts/validate-package.py .
```

```powershell
# 前台跑 harness 数 skip
cd D:\dsh
& ".\DeepSeek Harness.exe" --expose-internals ... 2>&1 |
  Select-String "skipping|did not activate"
```

```bash
# 工具解析
node --input-type=module -e "..."

# 端口
for p in 22 80 443 9000 9100; do
  timeout 4 bash -c "echo > /dev/tcp/YOUR_VPS_IP/$p" 2>/dev/null && echo "$p open"
done
```
