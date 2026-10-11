# 03 · 手机远程访问 DSH

> 目标：手机在 **4G 网络**下打开 `https://dsh.YOUR_DOMAIN`，输入 PIN 进入完整 DSH 界面。
>
> 不需要开任何入站端口，TLS 自动，走你自己的域名。

---

## 架构

```
手机 (4G / WiFi)
  ↓  https://dsh.YOUR_DOMAIN          你自己的域名
Cloudflare 边缘                        TLS 终止，证书自动
  ↓  Argo 隧道（出站建立，4 条连接）
cloudflared.exe                       Windows 侧，计划任务守护
  ↓  localhost:3081
dsh-pocket PIN 门禁                   密码保护
  ↓  localhost:19387
DSH Web UI
```

**关键**：隧道是**从本机出站**连到 Cloudflare，**不需要公网 IP、不需要 NAT 映射、不需要开端口**。

---

## 前置

| 项 | 要求 |
|---|---|
| 域名 | 托管在 Cloudflare（NS 已切换） |
| Cloudflare API Token | 权限 `Zone:DNS:Edit` + `Account:Cloudflare Tunnel:Edit` |
| Account ID / Zone ID | Cloudflare 控制台右下角 |
| dsh-pocket | v2.10.6+ |

---

## 步骤 1 · 安装 dsh-pocket

```bash
cd ~/.dsh/profiles/desktop
pnpm add dsh-pocket@latest
```

加入 bundles（`package.json` 的 `dsh.profile.bundles`）。

**注意**：dsh-pocket 会警告「桌面端 advanced 模式：手机访问暂不支持」。它检查 `$DSH_HOME/settings.yaml` 里有没有 `dsh-plugin-desktop: mode: advanced`。普通模式不受影响。

---

## 步骤 2 · 建 Cloudflare 隧道

```powershell
$tok   = $env:CLOUDFLARE_API_TOKEN
$acc   = $env:CLOUDFLARE_ACCOUNT_ID
$zone  = $env:CLOUDFLARE_ZONE_ID
$H = @{Authorization="Bearer $tok"; 'Content-Type'='application/json'}

# ① 建隧道
$c = Invoke-RestMethod -Method Post `
  -Uri "https://api.cloudflare.com/client/v4/accounts/$acc/cfd_tunnel" `
  -Headers $H -Body '{"name":"dsh-desktop","config_src":"cloudflare"}'
$tunId = $c.result.id
Write-Host "隧道 ID: $tunId"

# ② ingress：域名 -> 本地 PIN 门禁端口
$cfg = '{"config":{"ingress":[{"hostname":"dsh.YOUR_DOMAIN","service":"http://localhost:3081"},{"service":"http_status:404"}]}}'
Invoke-RestMethod -Method Put `
  -Uri "https://api.cloudflare.com/client/v4/accounts/$acc/cfd_tunnel/$tunId/configurations" `
  -Headers $H -Body $cfg | Out-Null

# ③ DNS CNAME（⚠️ name 用相对名 "dsh"，不是全名！）
$dns = "{`"type`":`"CNAME`",`"name`":`"dsh`",`"content`":`"$tunId.cfargotunnel.com`",`"proxied`":true,`"ttl`":1}"
Invoke-RestMethod -Method Post `
  -Uri "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" `
  -Headers $H -Body $dns | Out-Null

# ④ 取隧道 token
$t = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$acc/cfd_tunnel/$tunId/token" -Headers $H
$t.result | Out-File -Encoding ascii -NoNewline "$env:USERPROFILE\.dsh\dsh-pocket\cf-token.txt"
Write-Host "token 长度: $($t.result.Length)"
```

> ⚠️ **不要用 `$host` 当变量名** —— PowerShell 的**自动变量**，赋值会被忽略，你会得到一条 `system.management.automation.internal.host...` 的垃圾 DNS 记录。

---

## 步骤 3 · 配置 dsh-pocket

配置存在 `$DSH_HOME/dsh-pocket/settings.json`：

```json
{
  "tunnelMode": "named",
  "tunnelToken": "<240 字符的隧道 token>",
  "tunnelHostname": "dsh.YOUR_DOMAIN",
  "lanEnabled": true,
  "lanAuthEnabled": true
}
```

**字段说明**（来自 `lib/settings.mjs`）：

| 键 | 值 | 说明 |
|---|---|---|
| `tunnelMode` | `named` / `quick` | `named` = 固定域名；`quick` = 随机 trycloudflare.com |
| `tunnelToken` | 240 字符 | 格式校验 `[A-Za-z0-9+/_=-]{20,}` |
| `tunnelHostname` | 主机名 | 小写，无协议、无端口、无路径 |

**写入后**：

```bash
python3 -c "
import json, os
p = os.path.expanduser('~/.dsh/dsh-pocket/settings.json')
j = json.load(open(p, encoding='utf-8'))
j.update({'tunnelMode':'named','tunnelToken':open(os.path.expanduser('~/.dsh/dsh-pocket/cf-token.txt')).read().strip(),'tunnelHostname':'dsh.YOUR_DOMAIN'})
json.dump(j, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
"
```

---

## 步骤 4 · 守护 cloudflared

### 4.1 触发首次启动

dsh-pocket 的自动恢复机制：启动时若存在标记文件 `$DSH_HOME/dsh-pocket/tunnel-auto.json` 且内容含 `"at":`，就自动拉起隧道。

```bash
python3 -c "
import json, os, time
p = os.path.expanduser('~/.dsh/dsh-pocket/tunnel-auto.json')
json.dump({'at': int(time.time()*1000)}, open(p,'w'))
"
```

然后重启 DSH。

### 4.2 ⚠️ 用计划任务做冗余守护（推荐）

dsh-pocket 的自动恢复**依赖 DSH 启动**。如果 DSH 没开，隧道就断。加一条独立的计划任务：

**`~/.dsh/dsh-pocket/start-tunnel.cmd`**：

```bat
@echo off
setlocal
set DSH_HOME=%USERPROFILE%\.dsh
set CF=%DSH_HOME%\dsh-pocket\bin\cloudflared.exe
set TOKF=%DSH_HOME%\dsh-pocket\cf-token.txt
set LOG=%DSH_HOME%\dsh-pocket\tunnel.log

if not exist "%CF%" exit /b 1
if not exist "%TOKF%" exit /b 1
set /p TOKEN=<"%TOKF%"

:loop
echo [%date% %time%] starting cloudflared >> "%LOG%"
"%CF%" tunnel --no-autoupdate --protocol http2 run --token %TOKEN% >> "%LOG%" 2>&1
echo [%date% %time%] exited, restart in 10s >> "%LOG%"
timeout /t 10 /nobreak >nul
goto loop
```

**注册**：

```powershell
$act = New-ScheduledTaskAction -Execute "$env:USERPROFILE\.dsh\dsh-pocket\start-tunnel.cmd"
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName 'DSH-Pocket-Tunnel' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'DSH-Pocket-Tunnel' -Action $act -Trigger $trg `
  -Settings $set -Principal $prn
```

> 脚本里的 `:loop` 是**断线自愈** —— cloudflared 挂掉 10 秒后自动重连。

> ⚠️ **不要用 `taskkill /T` 杀 DSH** —— `/T` 会连带杀掉 cloudflared。用 `taskkill /IM "DeepSeek Harness.exe" /F`（不带 `/T`）。

---

## 步骤 5 · 验证

### 5.1 DNS

```bash
curl -s -H 'accept: application/dns-json' \
  "https://cloudflare-dns.com/dns-query?name=dsh.YOUR_DOMAIN&type=A"
# 应返回 Cloudflare 的 IP（104.x / 172.67.x）
```

> ⚠️ **本地 DNS 可能有 NXDOMAIN 负缓存**。不要用 `nslookup`（走本地解析器）判断，**用 DoH 查**。

### 5.2 隧道状态

```powershell
$t = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$acc/cfd_tunnel/$tunId" -Headers $H
"$($t.result.status)  连接 $($t.result.connections.Count)"
# → healthy  连接 4
```

### 5.3 完整握手（模拟浏览器）

```bash
J=/tmp/cj.txt; rm -f $J
# ① 输 PIN
curl -s -c $J -b $J -o /dev/null -w "%{http_code}\n" \
  -H "Host: dsh.YOUR_DOMAIN" -X POST -d "token=YOUR_PUBLIC_PIN" \
  http://127.0.0.1:3081/pocket-login
# → 302

# ② 握手（拿 dsh-auth cookie）
curl -s -c $J -b $J -o /dev/null -w "%{http_code}\n" \
  -H "Host: dsh.YOUR_DOMAIN" "http://127.0.0.1:3081/?dsh-pocket-retry=1"
# → 200

# ③ 加载 DSH
curl -s -c $J -b $J -o /tmp/r.html -w "%{http_code} %{size_download}\n" \
  -H "Host: dsh.YOUR_DOMAIN" http://127.0.0.1:3081/
# → 200  42232
grep -c '__DSH_BOOT__' /tmp/r.html
# → 1
```

### 5.4 公网

```bash
curl -m 30 -o /dev/null -w "%{http_code}\n" https://dsh.YOUR_DOMAIN/
# → 200
```

---

## 排障

### PIN 是多少

两个不同的 PIN，按 host 分发：

```bash
cat ~/.dsh/dsh-pocket/token       # 公网 PIN
cat ~/.dsh/dsh-pocket/token-lan   # 局域网 PIN
```

**用错会一直显示验证页。** 公网入口必须用 `token`（不是 `token-lan`）。

### 503「无法完成登录握手」

```
🔁 无法完成登录握手
```

**两个原因**：

**① 握手重试计数打满**（每 IP 60 秒窗口，上限 3 次）

```bash
curl -H "Host: dsh.YOUR_DOMAIN" "http://127.0.0.1:3081/?dsh-pocket-retry=1"
```

`?dsh-pocket-retry=1` 会清空计数。

**② 浏览器不保存 cookie**

iOS Safari 在 `http://` + 纯 IP 源上不持久化 cookie。**HTTPS 域名上正常。**

### React #130（插件市场界面崩）

```
Minified React error #130
```

`Element type is invalid ... got: undefined` —— **插件版本与 dsh 核心不匹配**。见 [01-install-plugins.md](01-install-plugins.md) 的版本闸门章节。

对 `dshmarket` 而言，**1.47.0 → 1.66.14** 可修。

### 手机登录多久失效

- **30 天**（cookie `Max-Age=2592000`）
- 但 cookie 绑定进程级 `sessionKey` —— **DSH 重启后要重新输 PIN**

---

## 安全建议

1. **别用 `quick` 模式对外** —— `trycloudflare.com` 是公开可扫的
2. **PIN 用 8 位字母数字混合**，别纯数字
3. **用完关隧道**：删 `tunnel-auto.json` + 停计划任务
4. **Cloudflare Access**（可选）：在 Zero Trust 里给这个 hostname 加一层 SSO，比 PIN 更强

---

## 相关文档

- 工具链 → [02-toolchain.md](02-toolchain.md)
- VPS 隧道（frp/chisel）→ [05-vps-setup.md](05-vps-setup.md)
