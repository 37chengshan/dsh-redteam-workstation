<#
  Step 5 - Self-hosted VPS infrastructure
  =======================================
  Load-balancing the reality: most cloud security groups already allow 80/443.
  We serve payloads on 80 AND 9100, and put reverse-shell listeners on 443
  plus 9000-9999.

  If the user cannot open 9000-9999, everything still works through 443 -
  just with a single concurrent shell.

  Files pushed from ./vps/:
    rt                 -> /usr/local/bin/rt
    rt-bootstrap       -> /usr/local/bin/rt-bootstrap
    rt-listeners.service -> /etc/systemd/system/
#>
[CmdletBinding()]
param(
    [string]$VpsHost   = '',
    [string]$SshKey    = '',
    [string]$SshUser   = 'root',
    [int]   $SshPort   = 22,
    [switch]$SkipUpload
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 5 / 6  -  VPS infrastructure'

# ---------------------------------------------------------------- 0. params
Head '0. Connection parameters'

$envFile = Join-Path ${script}:WS.DshHome '.env'
if (Test-Path $envFile) {
    foreach ($line in ([IO.File]::ReadAllLines($envFile))) {
        if ($line -match '^\s*REDTEAM_VPS_HOST\s*=\s*(.+)$') { if (-not $VpsHost) { $VpsHost = $Matches[1].Trim() } }
        if ($line -match '^\s*REDTEAM_VPS_USER\s*=\s*(.+)$') { $SshUser  = $Matches[1].Trim() }
        if ($line -match '^\s*REDTEAM_VPS_KEY\s*=\s*(.+)$')  { if (-not $SshKey)  { $SshKey  = $Matches[1].Trim() } }
    }
}

if (-not $VpsHost) {
    Write-Host ''
    $VpsHost = Read-Host '   VPS public IP or hostname'
}
if (-not $VpsHost) { Fail 'no VPS host given'; exit 1 }
Ok ('vps : ' + $SshUser + '@' + $VpsHost + ':' + $SshPort)

# resolve the key to a WSL-friendly path
if (-not $SshKey) { $SshKey = "$env:USERPROFILE\.ssh\id_rsa_vps" }
$keyWin = $SshKey -replace '^~', $env:USERPROFILE
$keyWin = $keyWin -replace '/', '\'
if (-not (Test-Path $keyWin)) {
    Warn ('key not found: ' + $keyWin)
    Info 'SSH requires a key with 0600 permissions. On DrvFs chmod is ignored,'
    Info 'so copy it into the WSL filesystem first:'
    Info '   wsl -d Ubuntu-22.04 -e bash -lc "cp /mnt/c/.../id_rsa ~/.ssh/id_rsa_vps && chmod 600 ~/.ssh/id_rsa_vps"'
    exit 1
}
$keyWsl = '/mnt/' + $keyWin.Substring(0,1).ToLower() + $keyWin.Substring(2).Replace('\','/')
Ok ('key : ' + $keyWin)

# ---------------------------------------------------------------- 1. ssh
Head '1. Test SSH'

$probe = Invoke-Wsl -Command ("ssh -i '" + $keyWsl + "' -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 " + $SshUser + '@' + $VpsHost + " 'echo SSH_OK; hostname; uname -m'") -TimeoutSec 40
if ($probe.Out -match 'SSH_OK') {
    $lines = @($probe.Out -split "`n" | Where-Object { $_.Trim() })
    Ok ('connected : ' + ($lines -join ' / '))
    Add-Report -Item 'SSH' -State 'ok'
} else {
    Fail 'SSH failed'
    Info $probe.Out
    Add-Report -Item 'SSH' -State 'fail'
    exit 1
}

function Invoke-Vps {
    param([string]$Command, [int]$TimeoutSec = 300)
    $escaped = $Command -replace "'", "'\''"
    return Invoke-Wsl -Command ("ssh -i '" + $keyWsl + "' -o BatchMode=yes -o StrictHostKeyChecking=accept-new " + $SshUser + '@' + $VpsHost + " '" + $escaped + "'") -TimeoutSec $TimeoutSec
}

# ---------------------------------------------------------------- 2. base
Head '2. Base packages'

$osInfo = Invoke-Vps -Command '. /etc/os-release 2>/dev/null; echo $PRETTY_NAME'
Info ('os : ' + $osInfo.Out.Trim())

$needPkg = (Invoke-Vps -Command 'command -v tmux >/dev/null && command -v nc >/dev/null && echo HAVE || echo NEED').Out.Trim()
if ($needPkg -eq 'NEED') {
    Step 'installing tmux / ncat / socat'
    $r = Invoke-Vps -Command 'if command -v dnf >/dev/null 2>&1; then dnf install -y -q tmux nmap-ncat socat lsof 2>&1 | tail -3; elif command -v apt-get >/dev/null 2>&1; then apt-get install -y -qq tmux netcat-openbsd socat lsof 2>&1 | tail -3; fi; echo DONE' -TimeoutSec 600
    foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
}
foreach ($t in @('tmux','nc','socat')) {
    $p = (Invoke-Vps -Command ("command -v $t || echo MISSING")).Out.Trim()
    if ($p -eq 'MISSING') { Warn ($t + ' missing') } else { Ok ("$t  $p") }
}

# ---------------------------------------------------------------- 3. payload svc
Head '3. Payload service  (nginx on :80 and :9100)'

$nginxCheck = (Invoke-Vps -Command 'command -v nginx >/dev/null && echo YES || echo NO').Out.Trim()
if ($nginxCheck -eq 'NO') {
    Step 'installing nginx'
    $r = Invoke-Vps -Command 'if command -v dnf >/dev/null 2>&1; then dnf install -y -q nginx 2>&1 | tail -2; else apt-get install -y -qq nginx 2>&1 | tail -2; fi; echo DONE' -TimeoutSec 600
}

$nginxConf = @'
server {
    listen 9100;
    listen 80;
    server_name _;
    root /opt/payload;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    access_log /var/log/nginx/payload.log;
    location / {
        add_header Access-Control-Allow-Origin *;
        try_files $uri $uri/ =404;
    }
}
'@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nginxConf))
$r = Invoke-Vps -Command ("mkdir -p /opt/payload/linux /opt/payload/windows /opt/payload/webshell /opt/payload/misc /opt/payload/.logs; " +
                          "echo '" + $b64 + "' | base64 -d > /etc/nginx/conf.d/payload.conf; " +
                          "nginx -t 2>&1 | tail -1; systemctl enable nginx >/dev/null 2>&1; systemctl restart nginx; sleep 2; systemctl is-active nginx")
foreach ($line in ($r.Out -split "`n")) { if ($line.Trim()) { Info $line.TrimEnd() } }

$code = (Invoke-Vps -Command "curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9100/").Out.Trim()
if ($code -eq '200') { Ok 'payload service :200'; Add-Report -Item 'payload service' -State 'ok' }
else { Warn ('payload service returned ' + $code); Add-Report -Item 'payload service' -State 'warn' }

# ---------------------------------------------------------------- 4. bootstrap
Head '4. Listener bootstrap'

$rootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vpsDir  = Join-Path $rootDir 'vps'

if (-not $SkipUpload -and (Test-Path $vpsDir)) {
    # the .ps1 files are UTF-8; the shell scripts must stay LF
    $rtBootstrap = [IO.File]::ReadAllText((Join-Path $vpsDir 'rt-bootstrap')) -replace "`r`n", "`n"
    $rtMain      = [IO.File]::ReadAllText((Join-Path $vpsDir 'rt'))           -replace "`r`n", "`n"
    $unitFile    = [IO.File]::ReadAllText((Join-Path $vpsDir 'rt-listeners.service')) -replace "`r`n", "`n"

    $b1 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rtBootstrap))
    $b2 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rtMain))
    $b3 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($unitFile))

    Step 'uploading rt tooling'
    $cmd = "echo '$b1' | base64 -d > /usr/local/bin/rt-bootstrap; " +
           "echo '$b2' | base64 -d > /usr/local/bin/rt; " +
           "echo '$b3' | base64 -d > /etc/systemd/system/rt-listeners.service; " +
           "chmod +x /usr/local/bin/rt /usr/local/bin/rt-bootstrap; " +
           "sed -i 's/\r$//' /usr/local/bin/rt /usr/local/bin/rt-bootstrap /etc/systemd/system/rt-listeners.service; " +
           "systemctl daemon-reload; systemctl enable rt-listeners >/dev/null 2>&1; systemctl restart rt-listeners; " +
           "sleep 3; tmux ls 2>/dev/null | wc -l"
    $r = Invoke-Vps -Command $cmd -TimeoutSec 120
    $sessions = ($r.Out -split "`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
    Ok ("rt tooling installed  ($sessions tmux session(s))")
    Add-Report -Item 'rt tooling' -State 'ok'
} else {
    Warn 'vps/ directory not found - skipping upload'
    Add-Report -Item 'rt tooling' -State 'skip'
}

# ---------------------------------------------------------------- 5. ports
Head '5. Port reachability'

$portState = @{}
foreach ($p in @(22, 80, 443, 9000, 9001, 9002, 9100)) {
    $open = Test-TcpPort -ComputerName $VpsHost -Port $p -TimeoutMs 5000
    $portState[$p] = $open
    if ($open) { Ok ("$p  open") } else { Warn ("$p  blocked") }
}

if (-not $portState[9100]) {
    Write-Host ''
    Warn 'Security group rule needed for 9100 (payload download).'
    Info 'Console > ECS > instance > Security Group > Inbound > Add rule'
    Info '   Protocol  : Custom TCP'
    Info '   Port range: 9100/9100'
    Info '   Source    : 0.0.0.0/0'
}
if (-not $portState[9000]) {
    Write-Host ''
    Warn 'Security group rule needed for 9000/9999 (reverse shell listeners).'
    Info '   Port range: 9000/9999'
    Info 'Payloads on :80 still work without it.'
}
Add-Report -Item 'port 9100' -State $(if ($portState[9100]) { 'ok' } else { 'warn' })
Add-Report -Item 'port 9000-9999' -State $(if ($portState[9000]) { 'ok' } else { 'warn' })

# ---------------------------------------------------------------- 6. .env
Head '6. Write .env'

$entries = [ordered]@{
    'REDTEAM_VPS_HOST'     = $VpsHost
    'REDTEAM_VPS_PORT'     = "$SshPort"
    'REDTEAM_VPS_USER'     = $SshUser
    'REDTEAM_VPS_KEY'      = $SshKey
    'REDTEAM_NO_VM_WARN'   = '1'
    'REDTEAM_PAYLOAD_PORT' = '9100'
    'REDTEAM_SHELL_PORTS'  = '9000-9999'
}

$existing = @{}
if (Test-Path $envFile) {
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $existing[$Matches[1]] = $Matches[2] }
    }
}
Backup-File -Path $envFile -Tag 'bak' | Out-Null

$out = @()
$out += '# dsh redteam environment - loaded at dsh startup'
$out += '# generated by the installer'
$out += ''
foreach ($k in $existing.Keys) {
    if (-not $entries.Contains($k)) { $out += ($k + '=' + $existing[$k]) }
}
$out += ''
foreach ($k in $entries.Keys) { $out += ($k + '=' + $entries[$k]) }

Write-Utf8NoBom -Path $envFile -Content (($out -join "`n") + "`n")
Ok ('written : ' + $envFile)
Info 'Applies after a DSH restart.'

# ---------------------------------------------------------------- 7. sync
Head '7. Sync tools to payload dir'

if (-not $SkipUpload) {
    $toSync = @('fscan','gogo','suo5','chisel','frpc','frps')
    $bins = @($toSync | Where-Object { Test-Path (Join-Path ${script}:WS.ToolsBin $_) })
    if ($bins.Count -gt 0) {
        $list = ($bins | ForEach-Object { "'/mnt/d/security-tools/bin/$_'" }) -join ' '
        $cmd = "for f in $list; do scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i '$keyWsl' `"`$f`" $SshUser@${VpsHost}:/opt/payload/linux/ && echo synced `$(basename `$f); done"
        $r = Invoke-Wsl -Command $cmd -TimeoutSec 600
        foreach ($line in ($r.Out -split "`n")) { if ($line.Trim()) { Ok $line.Trim() } }
    }
}

$size = (Invoke-Vps -Command 'du -sh /opt/payload 2>/dev/null | cut -f1').Out.Trim()
Ok ('payload size : ' + $size)

# ---------------------------------------------------------------- end
Show-Report
Write-Host ''
Info 'Useful commands on the VPS:'
Info '   rt status            overview'
Info '   rt listen 9005       start a listener'
Info '   rt read 9005 40      read captured output'
Info '   rt killall           clean everything up'
exit 0
