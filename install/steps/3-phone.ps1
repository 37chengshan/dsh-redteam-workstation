<#
  Step 3 - Phone remote access
  ============================
  Cloudflare named tunnel (outbound only, no inbound ports) + dsh-pocket PIN gate.

  LOOPHOLE EXPLOITED: ports 80/443 are open in most security groups already.
  If the user cannot open 9000-9999, fall back to serving payloads on 80.

  POWERSELL AUTOMATIC-VARIABLE TRAP:
    $host is a READ-ONLY automatic variable. Assigning to it silently fails and
    you end up creating a DNS record named
    "system.management.automation.internal.host...".
    This step uses $targetHost / $hostName instead.
#>
[CmdletBinding()]
param(
    [string]$Domain       = '',
    [string]$TunnelName   = 'dsh-desktop',
    [string]$DshSubdomain = 'dsh'
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 3 / 6  -  Phone remote access'

# ---------------------------------------------------------------- 0. creds
Head '0. Cloudflare credentials'

$apiToken = $env:CLOUDFLARE_API_TOKEN
$acctId   = $env:CLOUDFLARE_ACCOUNT_ID
$zoneId   = $env:CLOUDFLARE_ZONE_ID

if (-not $apiToken -or -not $acctId -or -not $zoneId) {
    Warn 'missing environment variables'
    Info '   CLOUDFLARE_API_TOKEN   (needs Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit)'
    Info '   CLOUDFLARE_ACCOUNT_ID'
    Info '   CLOUDFLARE_ZONE_ID'
    Write-Host ''
    Info 'Set them as USER environment variables, restart this window, then re-run.'
    Info 'PowerShell one-liner:'
    Info '  [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN","<token>","User")'
    exit 1
}
Ok 'credentials present'

$headers = @{ Authorization = "Bearer $apiToken"; 'Content-Type' = 'application/json' }

# ---------------------------------------------------------------- 1. zone
Head '1. Resolve zone'

try {
    $zones = Invoke-RestMethod -Uri 'https://api.cloudflare.com/client/v4/zones' -Headers $headers -TimeoutSec 25
} catch {
    Fail ('Cloudflare API unreachable: ' + $_.Exception.Message)
    exit 1
}

$zoneObj = $zones.result | Where-Object { $_.id -eq $zoneId } | Select-Object -First 1
if (-not $zoneObj) { $zoneObj = $zones.result | Select-Object -First 1 }

if (-not $zoneObj) { Fail 'no zone found for this token'; exit 1 }

$rootDomain = $zoneObj.name
if (-not $Domain) { $Domain = $rootDomain }
Ok ("zone     : " + $rootDomain + '  (' + $zoneObj.status + ')')

# hostName is the FULL fqdn; targetHost was the trap name we avoid
$hostName = if ($Domain -eq $rootDomain) { "$DshSubdomain.$rootDomain" } else { $Domain }
Ok ("hostname : " + $hostName)

if ($zoneObj.id -ne $zoneId) { $zoneId = $zoneObj.id }

# ---------------------------------------------------------------- 2. tunnel
Head '2. Create / find tunnel'

$tunnelId = ''
try {
    $existing = Invoke-RestMethod -Uri ("https://api.cloudflare.com/client/v4/accounts/$acctId/cfd_tunnel?name=$TunnelName&is_deleted=false") -Headers $headers -TimeoutSec 25
    if ($existing.result.Count -gt 0) {
        $tunnelId = $existing.result[0].id
        Ok ("existing tunnel: " + $tunnelId)
    }
} catch { }

if (-not $tunnelId) {
    $payload = [ordered]@{ name = $TunnelName; config_src = 'cloudflare' } | ConvertTo-Json -Compress
    try {
        $created = Invoke-RestMethod -Method Post -Uri ("https://api.cloudflare.com/client/v4/accounts/$acctId/cfd_tunnel") -Headers $headers -Body $payload -TimeoutSec 25
        if ($created.success) {
            $tunnelId = $created.result.id
            Ok ("created tunnel: " + $tunnelId)
        } else {
            Fail ('create failed: ' + ($created.errors | ConvertTo-Json -Compress))
            exit 1
        }
    } catch {
        Fail ('create failed: ' + $_.Exception.Message)
        if ($_.ErrorDetails) { Info $_.ErrorDetails.Message }
        exit 1
    }
}

# ---------------------------------------------------------------- 3. ingress
Head '3. Configure ingress  (hostname -> local PIN gate)'

$gatePort = 3081
$ingressObj = [ordered]@{
    config = [ordered]@{
        ingress = @(
            [ordered]@{ hostname = $hostName; service = "http://localhost:$gatePort" },
            [ordered]@{ service = 'http_status:404' }
        )
    }
}
$ingressJson = $ingressObj | ConvertTo-Json -Depth 8 -Compress

try {
    $r = Invoke-RestMethod -Method Put `
        -Uri ("https://api.cloudflare.com/client/v4/accounts/$acctId/cfd_tunnel/$tunnelId/configurations") `
        -Headers $headers -Body $ingressJson -TimeoutSec 25
    Ok ($hostName + '  ->  http://localhost:' + $gatePort)
} catch {
    Fail ('ingress failed: ' + $_.Exception.Message)
    if ($_.ErrorDetails) { Info $_.ErrorDetails.Message }
}

# ---------------------------------------------------------------- 4. DNS
Head '4. DNS record'

# IMPORTANT: 'name' must be the RELATIVE label, not the full fqdn.
$relativeLabel = $hostName -replace [regex]::Escape(".$rootDomain$"), ''
if ($relativeLabel -eq $hostName) { $relativeLabel = $DshSubdomain }

$existingDns = @()
try {
    $q = Invoke-RestMethod -Uri ("https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?name=$hostName") -Headers $headers -TimeoutSec 25
    $existingDns = @($q.result)
} catch { }

if ($existingDns.Count -gt 0) {
    Ok ('record already exists: ' + $existingDns[0].type + ' ' + $existingDns[0].name)
} else {
    $dnsObj = [ordered]@{
        type    = 'CNAME'
        name    = $relativeLabel
        content = "$tunnelId.cfargotunnel.com"
        proxied = $true
        ttl     = 1
    }
    $dnsJson = $dnsObj | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Method Post -Uri ("https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records") -Headers $headers -Body $dnsJson -TimeoutSec 25
        Ok ('CNAME ' + $r.result.name + ' -> ' + $r.result.content)
    } catch {
        Fail ('DNS failed: ' + $_.Exception.Message)
        if ($_.ErrorDetails) { Info $_.ErrorDetails.Message }
    }
}

# clean up garbage records produced by the $host trap, if any
try {
    $all = Invoke-RestMethod -Uri ("https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?per_page=100") -Headers $headers -TimeoutSec 25
    foreach ($rec in $all.result) {
        if ($rec.name -like '*internalhost*' -or $rec.name -like '*automation.internal*') {
            Invoke-RestMethod -Method Delete -Uri ("https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($rec.id)") -Headers $headers -TimeoutSec 25 | Out-Null
            Warn ('removed junk record: ' + $rec.name)
        }
    }
} catch { }

# ---------------------------------------------------------------- 5. token
Head '5. Tunnel token'

$tokenPath = Join-Path $script:WS.DshHome 'dsh-pocket\cf-token.txt'
try {
    $t = Invoke-RestMethod -Uri ("https://api.cloudflare.com/client/v4/accounts/$acctId/cfd_tunnel/$tunnelId/token") -Headers $headers -TimeoutSec 25
    if ($t.success) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $tokenPath) -Force | Out-Null
        Write-Utf8NoBom -Path $tokenPath -Content $t.result
        Ok ('token saved (' + $t.result.Length + ' chars)')
    }
} catch {
    Fail ('token fetch failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------- 6. pocket cfg
Head '6. dsh-pocket settings'

$settingsPath = Join-Path $script:WS.DshHome 'dsh-pocket\settings.json'
Backup-File -Path $settingsPath -Tag 'bak' | Out-Null

$settings = [ordered]@{}
if (Test-Path $settingsPath) {
    $old = Read-JsonFile -Path $settingsPath
    if ($old) { foreach ($p in $old.PSObject.Properties) { $settings[$p.Name] = $p.Value } }
}
$settings['tunnelMode']     = 'named'
$settings['tunnelHostname'] = $hostName
if (Test-Path $tokenPath) {
    $settings['tunnelToken'] = ([IO.File]::ReadAllText($tokenPath)).Trim()
}
if (-not $settings.Contains('lanEnabled'))     { $settings['lanEnabled']     = $true }
if (-not $settings.Contains('lanAuthEnabled')) { $settings['lanAuthEnabled'] = $true }

Save-JsonFile -Path $settingsPath -Object ([pscustomobject]$settings) -NoBackup
Ok 'tunnelMode     = named'
Ok ('tunnelHostname = ' + $hostName)
Ok ('tunnelToken    = <' + $settings['tunnelToken'].Length + ' chars>')

# ---------------------------------------------------------------- 7. autostart
Head '7. cloudflared autostart  (survives reboot)'

$cfLocal = Join-Path $script:WS.DshHome 'dsh-pocket\bin\cloudflared.exe'
if (-not (Test-Path $cfLocal)) {
    Step 'downloading cloudflared.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $cfLocal) -Force | Out-Null
    try {
        Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' `
            -OutFile $cfLocal -TimeoutSec 300 -UseBasicParsing
        Ok 'cloudflared downloaded'
    } catch { Fail ('download failed: ' + $_.Exception.Message) }
} else { Ok 'cloudflared already present' }

# ASCII-only watchdog script
$watch = Join-Path $script:WS.DshHome 'dsh-pocket\start-tunnel.cmd'
$watchBody = @"
@echo off
REM ASCII-only cloudflared watchdog. Restarts on exit.
setlocal
set "DH=%USERPROFILE%\.dsh"
set "CF=%DH%\dsh-pocket\bin\cloudflared.exe"
set "TK=%DH%\dsh-pocket\cf-token.txt"
set "LG=%DH%\dsh-pocket\tunnel.log"
if not exist "%CF%" exit /b 1
if not exist "%TK%" exit /b 1
set /p TOKEN=<"%TK%"
:loop
echo [%date% %time%] start >> "%LG%"
"%CF%" tunnel --no-autoupdate --protocol http2 run --token %TOKEN% >> "%LG%" 2>&1
echo [%date% %time%] exited, retry in 10s >> "%LG%"
timeout /t 10 /nobreak >nul
goto loop
"@
Write-AsciiCrlf -Path $watch -Content $watchBody
Ok ('watchdog -> ' + $watch)

if (Test-Admin) {
    $action    = New-ScheduledTaskAction -Execute $watch
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $setObj    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Unregister-ScheduledTask -TaskName 'DSH-Pocket-Tunnel' -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName 'DSH-Pocket-Tunnel' -Action $action -Trigger $trigger `
        -Settings $setObj -Principal $principal | Out-Null
    Ok 'scheduled task DSH-Pocket-Tunnel registered'

    Start-ScheduledTask -TaskName 'DSH-Pocket-Tunnel'
    Step 'waiting for tunnel to come up ...'
    Start-Sleep -Seconds 25
} else {
    Warn 'not elevated - scheduled task skipped'
    Info ('Run manually: ' + $watch)
}

# also drop the auto-restore marker so dsh-pocket starts it too
$marker = Join-Path $script:WS.DshHome 'dsh-pocket\tunnel-auto.json'
$markerObj = [ordered]@{ at = [int64]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalMilliseconds }
Write-Utf8NoBom -Path $marker -Content ($markerObj | ConvertTo-Json -Compress)
Ok 'auto-restore marker written'

# ---------------------------------------------------------------- 8. verify
Head '8. Verify'

Start-Sleep -Seconds 5

try {
    $t = Invoke-RestMethod -Uri ("https://api.cloudflare.com/client/v4/accounts/$acctId/cfd_tunnel/$tunnelId") -Headers @{ Authorization = "Bearer $apiToken" } -TimeoutSec 25
    $state = $t.result.status
    $conns = @($t.result.connections).Count
    if ($state -eq 'healthy' -and $conns -gt 0) {
        Ok ("tunnel $state with $conns connection(s)")
        Add-Report -Item 'tunnel' -State 'ok' -Detail "$state / $conns conn"
    } else {
        Warn ("tunnel $state / $conns connection(s)")
        Info 'If 0 connections, the cloudflared process is not running. Check tunnel.log'
        Add-Report -Item 'tunnel' -State 'warn' -Detail "$state / $conns conn"
    }
} catch { Warn 'cannot query tunnel status' }

# DNS via DoH (local resolver may hold a negative cache)
try {
    $doh = Invoke-RestMethod -Uri ("https://cloudflare-dns.com/dns-query?name=$hostName&type=A") `
             -Headers @{ accept = 'application/dns-json' } -TimeoutSec 20
    $ips = @($doh.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    if ($ips.Count -gt 0) {
        Ok ('DNS resolves: ' + ($ips -join ', '))
        Add-Report -Item 'DNS (DoH)' -State 'ok' -Detail ($ips -join ' ')
    } else {
        Warn 'DNS not resolving yet - allow a few minutes for propagation'
        Add-Report -Item 'DNS (DoH)' -State 'warn'
    }
} catch { Warn 'DoH query failed' }

# local PIN gate
if (Test-TcpPort -ComputerName '127.0.0.1' -Port $gatePort) {
    Ok ("PIN gate listening on :$gatePort")
    Add-Report -Item 'PIN gate' -State 'ok'
    $pinFile = Join-Path $script:WS.DshHome 'dsh-pocket\token'
    if (Test-Path $pinFile) {
        $pin = ([IO.File]::ReadAllText($pinFile)).Trim()
        Write-Host ''
        Ok ('  PUBLIC PIN = ' + $pin)
        Info '  (LAN PIN is in token-lan - use the PUBLIC one for the domain)'
    }
} else {
    Warn ("nothing on :$gatePort - start DSH first, then re-check")
    Add-Report -Item 'PIN gate' -State 'warn'
}

Show-Report
Write-Host ''
Info ('Phone URL:  https://' + $hostName)
Info 'Next: step 4 (Windows Defender).'
exit 0
