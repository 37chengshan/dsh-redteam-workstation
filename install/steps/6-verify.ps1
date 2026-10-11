<#
  Step 6 - Verify everything (read-only, changes nothing)
  ======================================================
  Produces one consolidated report across all five layers.
#>
[CmdletBinding()]
param()

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 6 / 6  -  Full verification'

# ---------------------------------------------------------------- 1. DSH
Head '1. DSH Desktop'

$procCount = @(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count
if ($procCount -gt 0) { Ok ("running  ($procCount processes)") } else { Warn 'not running' }

$exeOk = Test-Path $script:WS.DshExe
if ($exeOk) { Ok ('exe : ' + $script:WS.DshExe) } else { Fail 'exe not found' }

$manifest = Join-Path $script:WS.DshRoot 'resources\app.asar'
$appDir   = Join-Path $script:WS.DshRoot 'resources\app'
$asarThere = Test-Path $manifest
$appThere  = Test-Path $appDir
if ($asarThere -and $appThere) {
    Warn 'app.asar AND resources/app both exist'
    Info 'dsh-purge patches go into resources/app, but Electron prefers app.asar.'
    Info 'Patches will NOT take effect until app.asar is moved aside.'
} elseif ($asarThere) {
    Info 'running from app.asar (dsh-purge patches not applied)'
} elseif ($appThere) {
    Ok 'running from unpacked resources/app (patches active)'
}
Add-Report -Item 'DSH process' -State $(if ($procCount -gt 0) { 'ok' } else { 'warn' }) -Detail "$procCount proc"

# ---------------------------------------------------------------- 2. plugins
Head '2. Plugins'

$pkgPath = Join-Path $script:WS.Profile 'package.json'
$bundles = @()
if (Test-Path $pkgPath) {
    $meta = Read-JsonFile -Path $pkgPath
    if ($meta.dsh.profile.bundles) { $bundles = @($meta.dsh.profile.bundles) }
}
Info ('bundles : ' + $bundles.Count)

$dupes = @()
$patchFile = Join-Path $script:WS.Profile 'cordis.patch.yml'
if (Test-Path $patchFile) {
    $pt = [IO.File]::ReadAllText($patchFile)
    foreach ($b in $bundles) {
        if ($b -like '@*') { continue }
        if ($pt -match [regex]::Escape($b)) { $dupes += $b }
    }
}
if ($dupes.Count -gt 0) { Warn ('duplicates : ' + ($dupes -join ', ')) } else { Ok 'no duplicate registration' }

$thirdParty = @($bundles | Where-Object { $_ -notlike '@deepseek-ai/*' })
foreach ($b in $thirdParty) {
    $pj = Join-Path $script:WS.Profile "node_modules\$b\package.json"
    if (-not (Test-Path $pj)) { Warn ("{0,-32} not installed" -f $b); continue }
    $m = Read-JsonFile -Path $pj
    $tag = if ($m.dsh.client) { 'client=Y' } else { 'client=-' }
    Write-Host ('   [ok]  ' + $b.PadRight(32) + $m.version.PadRight(12) + $tag) -ForegroundColor Green
}
Add-Report -Item 'bundles' -State $(if ($dupes.Count -eq 0) { 'ok' } else { 'warn' }) -Detail "$($bundles.Count) entries"

# ---------------------------------------------------------------- 3. tools
Head '3. Toolchain'

$cfgPath = Join-Path $script:WS.DshHome 'redteam\config.json'
$resolved = 0
$total = 0
if (Test-Path $cfgPath) {
    $cfg = Read-JsonFile -Path $cfgPath
    foreach ($p in $cfg.tools.PSObject.Properties) {
        $total++
        if ($p.Value -and (Test-Path $p.Value)) { $resolved++ }
        else { Warn ('missing : ' + $p.Name) }
    }
}
Ok ("dsh-purge resolve : $resolved/$total")
Add-Report -Item 'config tool paths' -State $(if ($resolved -eq $total -and $total -gt 0) { 'ok' } else { 'warn' }) -Detail "$resolved/$total"

# real execution check on a few
$smoke = @()
foreach ($t in @('nmap','nuclei','fscan','gogo')) {
    $c = Join-Path $script:WS.ToolsBin ($t + '.cmd')
    if (-not (Test-Path $c)) { continue }
    $out = & cmd /c "`"$c`" --version" 2>&1 | Select-Object -First 1
    if (-not $out) { $out = & cmd /c "`"$c`" -h" 2>&1 | Select-Object -First 1 }
    if ($out) { $smoke += $t }
}
Ok ('executable : ' + ($smoke -join ' '))

# C: footprint
$tk = Join-Path $script:WS.DshHome 'redteam\toolkit'
if (Test-Path $tk) {
    $sz = (Get-ChildItem $tk -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sz) {
        $kb = [math]::Round($sz/1KB, 1)
        if ($kb -gt 1024) { Warn ('toolkit on C: = {0:N1} MB (junctions broken?)' -f ($sz/1MB)) }
        else { Ok ('toolkit on C: = ' + $kb + ' KB') }
        Add-Report -Item 'C: footprint' -State $(if ($kb -lt 1024) { 'ok' } else { 'warn' }) -Detail "$kb KB"
    }
}

# D: footprint
if (Test-Path $script:WS.Tools) {
    $d = (Get-ChildItem $script:WS.Tools -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Ok ('D: toolchain = {0:N0} MB' -f ($d/1MB))
}

# ---------------------------------------------------------------- 4. prompt
Head '4. Prompt adapter'

$inject = Join-Path $script:WS.DshHome 'prompt-inject.md'
if (Test-Path $inject) {
    $txt = [IO.File]::ReadAllText($inject)
    $n = ([regex]::Matches($txt, '【DS-\d+】')).Count
    if ($n -ge 10) { Ok ("DeepSeek adapter: $n rules") }
    else { Warn ("DeepSeek adapter: only $n rules (expected 12)") }
    Ok ('size : ' + $txt.Length + ' chars')

    $state = Read-JsonFile -Path (Join-Path $script:WS.DshHome 'dsh-purge\override-state.json')
    if ($state -and $state.customized -eq $true) { Ok 'override lock : customized=true' }
    else { Warn 'override lock not set - UI Apply may overwrite' }
    Add-Report -Item 'DS adapter' -State $(if ($n -ge 10) { 'ok' } else { 'warn' }) -Detail "$n rules"
} else {
    Warn 'prompt-inject.md not found'
    Add-Report -Item 'DS adapter' -State 'skip'
}

# ---------------------------------------------------------------- 5. defender
Head '5. Windows Defender'

$procs = Get-Process MsMpEng, MsSense, NisSrv, MpDefenderCoreService, SecurityHealthService -ErrorAction SilentlyContinue
if ($procs) {
    $sum = ($procs | Measure-Object WorkingSet64 -Sum).Sum
    foreach ($p in $procs) { Info ('{0,-28}{1,9:N1} MB' -f $p.ProcessName, ($p.WorkingSet64/1MB)) }
    Write-Host ('   {0,-28}{1,9:N1} MB' -f 'TOTAL', ($sum/1MB)) -ForegroundColor Yellow
    Add-Report -Item 'Defender memory' -State 'warn' -Detail ('{0:N0} MB' -f ($sum/1MB))
} else {
    Ok 'Defender not running'
    Add-Report -Item 'Defender memory' -State 'ok' -Detail '0 MB'
}

$svc = Get-Service WinDefend -ErrorAction SilentlyContinue
if ($svc) { Info ('WinDefend : ' + $svc.Status + ' / ' + $svc.StartType) }

$tamper = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction SilentlyContinue).TamperProtection
if ($null -ne $tamper) { Info ('TamperProtection reg = ' + $tamper) }

# ---------------------------------------------------------------- 6. phone
Head '6. Phone access'

$settingsPath = Join-Path $script:WS.DshHome 'dsh-pocket\settings.json'
if (Test-Path $settingsPath) {
    $ps = Read-JsonFile -Path $settingsPath
    $hn = $ps.tunnelHostname
    if ($hn) {
        Ok ('hostname : ' + $hn)

        # DoH (local resolver may hold a negative cache)
        try {
            $doh = Invoke-RestMethod -Uri ("https://cloudflare-dns.com/dns-query?name=$hn&type=A") `
                     -Headers @{ accept = 'application/dns-json' } -TimeoutSec 20
            $ips = @($doh.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
            if ($ips.Count -gt 0) { Ok ('DNS      : ' + ($ips -join ', ')) } else { Warn 'DNS not resolving' }
        } catch { Warn 'DoH query failed' }

        try {
            $code = (Invoke-WebRequest -Uri ("https://$hn/") -TimeoutSec 25 -UseBasicParsing).StatusCode
            Ok ('https    : ' + $code)
            Add-Report -Item 'phone entry' -State 'ok' -Detail "https://$hn -> $code"
        } catch {
            $resp = $_.Exception.Response
            if ($resp) { Ok ('https    : ' + [int]$resp.StatusCode) }
            else { Warn ('https unreachable : ' + $_.Exception.Message) }
        }
    }
} else { Warn 'dsh-pocket settings not found' }

if (Test-TcpPort -ComputerName '127.0.0.1' -Port 3081) { Ok 'PIN gate :3081 up' } else { Warn 'PIN gate down' }
if (Test-TcpPort -ComputerName '127.0.0.1' -Port 19387) { Ok 'DSH web  :19387 up' } else { Warn 'DSH web down' }

$cfCount = @(Get-Process cloudflared -ErrorAction SilentlyContinue).Count
Ok ("cloudflared : $cfCount process(es)")
$task = Get-ScheduledTask -TaskName 'DSH-Pocket-Tunnel' -ErrorAction SilentlyContinue
if ($task) { Ok ('autostart task : ' + $task.State) } else { Warn 'autostart task missing' }

# ---------------------------------------------------------------- 7. vps
Head '7. VPS'

$envPath = Join-Path $script:WS.DshHome '.env'
$vps = ''
if (Test-Path $envPath) {
    foreach ($line in [IO.File]::ReadAllLines($envPath)) {
        if ($line -match '^\s*REDTEAM_VPS_HOST\s*=\s*(\S+)') { $vps = $Matches[1] }
    }
}
if ($vps) {
    Ok ('vps : ' + $vps)
    $openPorts = @()
    foreach ($p in @(80, 443, 9100, 9000)) {
        if (Test-TcpPort -ComputerName $vps -Port $p -TimeoutMs 4000) { $openPorts += $p }
    }
    Ok ('open : ' + ($openPorts -join ' '))
    try {
        $r = Invoke-WebRequest -Uri ("http://$vps`:9100/") -TimeoutSec 20 -UseBasicParsing
        Ok ('payload : ' + $r.StatusCode)
        Add-Report -Item 'VPS payload' -State 'ok' -Detail ($openPorts -join ' ')
    } catch { Warn 'payload service unreachable'; Add-Report -Item 'VPS payload' -State 'warn' }
} else {
    Warn 'VPS not configured'
    Add-Report -Item 'VPS' -State 'skip'
}

# ---------------------------------------------------------------- summary
Show-Report

Write-Host ''
Head 'Summary'
Info ('toolkit    : ' + $script:WS.Tools)
Info ('plugins    : ' + $script:WS.Profile)
Info ('prompt     : ' + $inject)
if ($vps) { Info ('phone      : https://' + $hn) }
Write-Host ''
exit 0
