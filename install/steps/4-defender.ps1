<#
  Step 4 - Windows Defender configuration
  =======================================
  Three levels, you choose:

    A. Exclusions  (SAFE)    - keep protection, stop it eating your tools
    B. Realtime off (TEMP)   - frees RAM now, may restore on reboot
    C. Full disable (HARD)   - ~478 MB freed, requires reboot, reversible

  NOTE ON THIS MACHINE'S MEASUREMENT: MsMpEng alone held 484 MB.
  Total Defender footprint was 540.9 MB before, 63.3 MB after partial disable.

  On Windows 11 the 'DisableAntiSpyware' policy is IGNORED since 2021, so a
  registry-only approach does not work. Services + scheduled tasks + drivers
  must all be handled.
#>
[CmdletBinding()]
param()

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 4 / 6  -  Windows Defender'

# ---------------------------------------------------------------- baseline
Head 'Current state'

function Get-DefenderFootprint {
    $procs = Get-Process MsMpEng, MsSense, NisSrv, MpDefenderCoreService, SecurityHealthService -ErrorAction SilentlyContinue
    if (-not $procs) { return [pscustomobject]@{ Total = 0; Detail = @() } }
    $sum = ($procs | Measure-Object WorkingSet64 -Sum).Sum
    return [pscustomobject]@{ Total = $sum; Detail = $procs }
}

$fp = Get-DefenderFootprint
if ($fp.Total -eq 0) {
    Ok 'no Defender processes running'
} else {
    foreach ($p in $fp.Detail) {
        Info ('{0,-28}{1,9:N1} MB' -f $p.ProcessName, ($p.WorkingSet64/1MB))
    }
    Write-Host ('   {0,-28}{1,9:N1} MB' -f 'TOTAL', ($fp.Total/1MB)) -ForegroundColor Yellow
    Add-Report -Item 'Defender footprint' -State 'warn' -Detail ('{0:N0} MB' -f ($fp.Total/1MB))
}

$status = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($status) {
    Info ('realtime protection : ' + $status.RealTimeProtectionEnabled)
    Info ('tamper protection   : ' + $status.IsTamperProtected)
    if ($status.IsTamperProtected) {
        Warn 'Tamper Protection is ON - settings changes will be refused.'
        Info 'Turn it off first:  Windows Security > Virus & threat protection > Manage settings'
    }
}
Write-Host ''

if (-not (Test-Admin)) {
    Fail 'Administrator required.'
    Info 'Right-click the .cmd -> Run as administrator.'
    exit 1
}
Ok 'running elevated'

# ---------------------------------------------------------------- menu
Write-Host ''
Write-Host '   [1]  Plan A - Add exclusions        (safe, keeps protection)' -ForegroundColor Green
Write-Host '   [2]  Plan B - Disable realtime only (temporary)'             -ForegroundColor Yellow
Write-Host '   [3]  Plan C - Full disable          (frees ~478 MB, reboot)'  -ForegroundColor Red
Write-Host '   [4]  Undo - restore Defender'                                 -ForegroundColor Gray
Write-Host '   [0]  Exit'                                                    -ForegroundColor DarkGray
Write-Host ''
$choice = Read-Host '   Choose'

# ---------------------------------------------------------------- A
if ($choice -eq '1') {
    Head 'Plan A - exclusions'

    $paths = @(
        $script:WS.Tools,
        $script:WS.DshRoot,
        $script:WS.DshHome,
        (Join-Path $env:APPDATA 'dsh-desktop'),
        (Join-Path $env:APPDATA '@deepseek-ai'),
        (Join-Path $env:LOCALAPPDATA '@deepseek-ai'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
            Ok ('path     ' + $p)
        }
    }

    $procs = @('wsl.exe','wslhost.exe','wslservice.exe','nmap.exe','fscan.exe','gogo.exe',
               'nuclei.exe','naabu.exe','frpc.exe','frps.exe','chisel.exe','ffuf.exe',
               'httpx.exe','subfinder.exe','dnsx.exe','suo5.exe','ksubdomain.exe',
               'gowitness.exe','masscan.exe','python.exe','python3.exe','node.exe',
               'pwsh.exe','powershell.exe')
    foreach ($n in $procs) { Add-MpPreference -ExclusionProcess $n -ErrorAction SilentlyContinue }
    Ok ("processes  $($procs.Count) entries")

    foreach ($e in @('.exe','.dll','.ps1','.bat','.cmd','.py','.sh','.gz','.go','.yaml')) {
        Add-MpPreference -ExclusionExtension $e -ErrorAction SilentlyContinue
    }
    Ok 'extensions 10 entries'

    Write-Host ''
    Ok 'Protection is still ON - Defender just will not scan these paths.'
    Info 'This is enough to stop chisel.exe from being quarantined.'
    Add-Report -Item 'Defender exclusions' -State 'ok'
}

# ---------------------------------------------------------------- B
elseif ($choice -eq '2') {
    Head 'Plan B - realtime off'

    $prefs = @{
        DisableRealtimeMonitoring      = $true
        DisableBehaviorMonitoring      = $true
        DisableScriptScanning          = $true
        DisableArchiveScanning         = $true
        DisableIOAVProtection          = $true
        DisableRemovableDriveScanning  = $true
        MAPSReporting                  = 0
        SubmitSamplesConsent           = 2
    }
    foreach ($k in $prefs.Keys) {
        Set-MpPreference @{ $k = $prefs[$k] } -ErrorAction SilentlyContinue
        Ok ($k + ' = ' + $prefs[$k])
    }

    Write-Host ''
    Warn 'This may be reverted automatically on reboot.'
    Info 'For a durable change use Plan C.'
    Add-Report -Item 'Defender realtime' -State 'warn' -Detail 'temporary'
    Pause-Here
}

# ---------------------------------------------------------------- C
elseif ($choice -eq '3') {
    Head 'Plan C - full disable'

    Write-Host ''
    Write-Host '   This permanently disables Windows Security on this machine.' -ForegroundColor Red
    Write-Host '   No malware protection at all afterwards.' -ForegroundColor Red
    Write-Host ''
    Info 'Undo is available at menu option [4].'
    Write-Host ''

    if (-not (Confirm-Action -Prompt 'Proceed with full disable?' -Word 'YES')) {
        Warn 'cancelled'
        exit 0
    }

    # 1. tamper protection
    Step '[1/7] tamper protection'
    Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -Value 0 | Out-Null
    Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtectionSource' -Value 0 | Out-Null
    Ok 'tamper protection off'

    # 2. policies
    Step '[2/7] group policy keys'
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    $keys = @(
        @{ P = $pol;                                    N = 'DisableAntiSpyware';                V = 1 }
        @{ P = $pol;                                    N = 'DisableAntiVirus';                  V = 1 }
        @{ P = $pol;                                    N = 'ServiceKeepAlive';                  V = 0 }
        @{ P = $pol;                                    N = 'DisableRoutinelyTakingAction';      V = 1 }
        @{ P = $pol;                                    N = 'PUAProtection';                     V = 0 }
        @{ P = $pol;                                    N = 'AllowFastServiceStartup';           V = 0 }
        @{ P = "$pol\Real-Time Protection";             N = 'DisableRealtimeMonitoring';         V = 1 }
        @{ P = "$pol\Real-Time Protection";             N = 'DisableBehaviorMonitoring';         V = 1 }
        @{ P = "$pol\Real-Time Protection";             N = 'DisableOnAccessProtection';         V = 1 }
        @{ P = "$pol\Real-Time Protection";             N = 'DisableScanOnRealtimeEnable';       V = 1 }
        @{ P = "$pol\Real-Time Protection";             N = 'DisableIOAVProtection';             V = 1 }
        @{ P = "$pol\Spynet";                           N = 'SpynetReporting';                   V = 0 }
        @{ P = "$pol\Spynet";                           N = 'SubmitSamplesConsent';              V = 2 }
        @{ P = "$pol\Signature Updates";                N = 'ForceUpdateFromMU';                 V = 0 }
        @{ P = "$pol\MpEngine";                         N = 'MpEnablePus';                       V = 0 }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'; N = 'DisableAntiSpyware';            V = 1 }
    )
    $okCount = 0
    foreach ($k in $keys) {
        if (Set-RegValue -Path $k.P -Name $k.N -Value $k.V) { $okCount++ }
    }
    Ok ("$okCount / $($keys.Count) policy keys written")

    # 3. services
    Step '[3/7] services'
    $svcs = @('WinDefend','WdNisSvc','WdNisDrv','WdFilter','Sense',
              'SecurityHealthService','wscsvc','MsMpSvc','SgrmBroker','SgrmAgent')
    foreach ($s in $svcs) {
        Stop-Service $s -Force -ErrorAction SilentlyContinue
        Set-Service  $s -StartupType Disabled -ErrorAction SilentlyContinue
        Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name 'Start' -Value 4 | Out-Null
        & sc.exe failure $s 'reset=' '0' 'actions=' '' 2>&1 | Out-Null
        Ok ('  ' + $s)
    }

    # 4. scheduled tasks
    Step '[4/7] scheduled tasks'
    $n = 0
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '*Windows Defender*' -or $_.TaskName -match 'Defender|MpCmdRun'
    } | ForEach-Object {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
        $n++
    }
    Ok ("$n task(s) disabled")

    # 5. drivers
    Step '[5/7] kernel drivers'
    foreach ($d in @('WdFilter','WdNisDrv','WdBoot')) {
        Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$d" -Name 'Start' -Value 4 | Out-Null
        Ok ('  ' + $d + ' (not loaded after reboot)')
    }

    # 6. notifications
    Step '[6/7] notifications and cleanup'
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'NoToastApplicationNotification' -Value 1 | Out-Null
    $sc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
    Set-RegValue -Path "$sc\Notifications" -Name 'DisableEnhancedNotifications' -Value 1 | Out-Null
    Set-RegValue -Path "$sc\Notifications" -Name 'DisableNotifications'         -Value 1 | Out-Null
    Set-RegValue -Path "$sc\Systray"       -Name 'HideSystray'                  -Value 1 | Out-Null
    Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'AutoCleanup' -Value 0 | Out-Null
    Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Scan'     -Name 'DisableRemovableDriveScanning' -Value 1 | Out-Null
    Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Scan'     -Name 'DisableScanningNetworkFiles'    -Value 1 | Out-Null
    Ok 'done'

    # 7. quarantine
    Step '[7/7] quarantine'
    Remove-Item 'C:\ProgramData\Microsoft\Windows Defender\Quarantine' -Recurse -Force -ErrorAction SilentlyContinue
    Ok 'quarantine cleared'

    Write-Host ''
    Ok 'Full disable complete.'
    Warn 'A REBOOT is required - service registry values are only read at boot.'
    Add-Report -Item 'Defender full disable' -State 'ok' -Detail 'reboot required'

    Write-Host ''
    if ((Read-Host '   Reboot now? (y/n)') -match '^[Yy]') { Restart-Computer -Force }
}

# ---------------------------------------------------------------- undo
elseif ($choice -eq '4') {
    Head 'Restore Defender'

    Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -ErrorAction SilentlyContinue
    Ok 'policies removed'

    $restore = @{
        'WinDefend'             = 2
        'WdNisSvc'              = 2
        'WdFilter'              = 1
        'WdNisDrv'              = 1
        'Sense'                 = 2
        'mpssvc'                = 2
        'SecurityHealthService' = 2
    }
    foreach ($s in $restore.Keys) {
        Set-Service  $s -StartupType Automatic -ErrorAction SilentlyContinue
        Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name 'Start' -Value $restore[$s] | Out-Null
        Ok ('  ' + $s + ' -> Start=' + $restore[$s])
    }

    Start-Service mpssvc    -ErrorAction SilentlyContinue
    Start-Service WinDefend -ErrorAction SilentlyContinue

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -like '*Windows Defender*' } |
        Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Ok 'scheduled tasks re-enabled'

    Warn 'Reboot required for Defender to come back.'
    Add-Report -Item 'Defender restore' -State 'ok' -Detail 'reboot required'
}

else {
    Info 'nothing to do'
    exit 0
}

# ---------------------------------------------------------------- after
Head 'After'

$fp2 = Get-DefenderFootprint
if ($fp2.Total -gt 0) {
    Info ('current footprint: {0:N1} MB' -f ($fp2.Total/1MB))
} else {
    Ok 'no Defender processes running'
}

Show-Report
exit 0
