#Requires -Version 5.1
<#
  Windows Defender 配置工具 — 红队工作站
  以管理员运行。菜单式，可逆。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'Windows Security Config'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Head($t) {
    Write-Host ''
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
    Write-Host ('   ' + $t) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}
function Write-Ok($t)   { Write-Host ('   [+] ' + $t) -ForegroundColor Green }
function Write-Warn2($t){ Write-Host ('   [!] ' + $t) -ForegroundColor Yellow }
function Write-Err2($t) { Write-Host ('   [X] ' + $t) -ForegroundColor Red }
function Write-Info($t) { Write-Host ('       ' + $t) -ForegroundColor Gray }
function Pause2 { Write-Host ''; Write-Host '   按回车继续...' -ForegroundColor DarkGray; [void](Read-Host) }

function Set-Reg($path, $name, $value, $type = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

if (-not (Test-Admin)) {
    Write-Err2 '需要管理员权限。请右键 -> 以管理员身份运行。'
    exit 1
}

# ---------------------------------------------------------------
function Show-Status {
    Write-Head '当前状态'
    $s = Get-MpComputerStatus
    if ($s) {
        Write-Host ('   实时保护      : ' + $s.RealTimeProtectionEnabled)
        Write-Host ('   行为监控      : ' + $s.BehaviorMonitorEnabled)
        Write-Host ('   防篡改        : ' + $s.IsTamperProtected)
        Write-Host ('   引擎版本      : ' + $s.AMEngineVersion)
    } else {
        Write-Warn2 'Get-MpComputerStatus 无返回（Defender 可能已禁用）'
    }
    Write-Host ''
    foreach ($v in (Get-Service WinDefend, WdNisSvc, WdFilter, Sense, mpssvc -ErrorAction SilentlyContinue)) {
        $c = if ($v.Status -eq 'Running') { 'Green' } else { 'DarkGray' }
        Write-Host ('   ' + $v.Name.PadRight(18) + $v.Status) -ForegroundColor $c
    }
    Write-Host ''
    $p = Get-Process MsMpEng, MsSense, NisSrv, MpDefenderCoreService, SecurityHealthService -ErrorAction SilentlyContinue
    if ($p) {
        $sum = 0
        foreach ($x in $p) {
            Write-Host ('   ' + $x.ProcessName.PadRight(26) + ('{0,9:N1} MB' -f ($x.WorkingSet64/1MB)))
            $sum += $x.WorkingSet64
        }
        Write-Host ('   ' + '合计'.PadRight(24) + ('{0,11:N1} MB' -f ($sum/1MB))) -ForegroundColor Yellow
    } else { Write-Host '   Defender 进程未运行' -ForegroundColor Green }
    Write-Host ''
    Write-Host '   排除路径:' -ForegroundColor DarkGray
    $pref = Get-MpPreference
    if ($pref.ExclusionPath) { $pref.ExclusionPath | ForEach-Object { Write-Info $_ } }
    else { Write-Info '(无)' }
    Pause2
}

# ---------------------------------------------------------------
function Add-Exclusions {
    Write-Head '方案 A：添加排除项'
    $paths = @(
        'D:\security-tools',
        'D:\dsh',
        "$env:USERPROFILE\.dsh",
        "$env:APPDATA\dsh-desktop",
        "$env:APPDATA\@deepseek-ai",
        "$env:LOCALAPPDATA\@deepseek-ai",
        "$env:USERPROFILE\Downloads"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { Add-MpPreference -ExclusionPath $p; Write-Ok $p }
    }
    $procs = @('wsl.exe','wslhost.exe','wslservice.exe','nmap.exe','fscan.exe','gogo.exe',
               'nuclei.exe','frpc.exe','frps.exe','chisel.exe','ffuf.exe','httpx.exe',
               'subfinder.exe','dnsx.exe','suo5.exe','ksubdomain.exe','python.exe','python3.exe',
               'node.exe','pwsh.exe','powershell.exe')
    foreach ($n in $procs) { Add-MpPreference -ExclusionProcess $n }
    Write-Ok ('进程排除 ' + $procs.Count + ' 个')
    foreach ($e in @('.exe','.dll','.ps1','.bat','.cmd','.py','.sh','.gz','.go')) { Add-MpPreference -ExclusionExtension $e }
    Write-Ok '扩展名排除 9 个'
    Write-Host ''
    Write-Warn2 'Defender 仍在运行（保留防护），只是不再扫这些路径。'
    Write-Host ''
    Write-Info '重新下载 chisel 的命令：'
    Write-Info 'wsl -d Ubuntu-22.04 -e bash -lc "cd /tmp && curl -sL -o c.gz https://github.com/jpillora/chisel/releases/download/v1.12.0/chisel_1.12.0_linux_amd64.gz && gunzip -c c.gz > chisel && chmod 755 chisel && cp -f chisel /mnt/d/security-tools/bin/chisel"'
    Pause2
}

# ---------------------------------------------------------------
function Disable-RealtimeOnly {
    Write-Head '方案 B：只关实时保护'
    Set-MpPreference -DisableRealtimeMonitoring $true
    Set-MpPreference -DisableBehaviorMonitoring $true
    Set-MpPreference -DisableScriptScanning $true
    Set-MpPreference -DisableArchiveScanning $true
    Set-MpPreference -DisableIOAVProtection $true
    Set-MpPreference -DisableRemovableDriveScanning $true
    Set-MpPreference -MAPSReporting 0
    Set-MpPreference -SubmitSamplesConsent 2
    Write-Ok '实时保护已关'
    Write-Warn2 '重启后可能自动恢复。要持久请用方案 C。'
    Pause2
}

# ---------------------------------------------------------------
function Disable-AllDefender {
    Write-Head '方案 C：彻底禁用 Defender'
    Write-Host ''
    Write-Err2 '这会永久禁用 Windows 安全中心。'
    Write-Err2 '本机将无任何病毒防护，勒索/挖矿木马可直接落地。'
    Write-Host ''
    Write-Info '恢复方法见菜单 [5]。'
    Write-Host ''
    $ok = Read-Host '   输入 YES 确认'
    if ($ok -cne 'YES') { Write-Warn2 '已取消'; Start-Sleep 1; return }

    Write-Head '1/7 关闭防篡改'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtectionSource' 0
    Write-Ok '防篡改已关'

    Write-Head '2/7 组策略禁用键'
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    Set-Reg $pol 'DisableAntiSpyware' 1
    Set-Reg $pol 'DisableAntiVirus' 1
    $rt = "$pol\Real-Time Protection"
    foreach ($k in 'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
                   'DisableScanOnRealtimeEnable','DisableIOAVProtection') { Set-Reg $rt $k 1 }
    Set-Reg "$pol\Spynet" 'SpynetReporting' 0
    Set-Reg "$pol\Spynet" 'SubmitSamplesConsent' 2
    Set-Reg "$pol\Signature Updates" 'ForceUpdateFromMU' 0
    Set-Reg "$pol\MpEngine" 'MpEnablePus' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
    Write-Ok '13 项策略已写入'

    Write-Head '3/7 停用服务'
    $svcs = 'WinDefend','WdNisSvc','WdNisDrv','WdFilter','Sense',
            'SecurityHealthService','wscsvc','MsMpSvc','SgrmBroker','SgrmAgent'
    foreach ($s in $svcs) {
        Stop-Service $s -Force -ErrorAction SilentlyContinue
        Set-Service  $s -StartupType Disabled -ErrorAction SilentlyContinue
        Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\$s" 'Start' 4
        & sc.exe failure $s 'reset=' '0' 'actions=' '' | Out-Null
        Write-Ok $s
    }

    Write-Head '4/7 禁用计划任务'
    $n = 0
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '*Windows Defender*' -or $_.TaskName -match 'Defender|MpCmdRun'
    } | ForEach-Object {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
        $n++
    }
    Write-Ok "已禁用 $n 个计划任务"

    Write-Head '5/7 禁用内核驱动'
    foreach ($d in 'WdFilter','WdNisDrv','WdBoot') {
        Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\$d" 'Start' 4
        Write-Ok "$d 重启后不加载"
    }

    Write-Head '6/7 关闭通知与自动清理'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' 'NoToastApplicationNotification' 1
    $scp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
    Set-Reg "$scp\Notifications" 'DisableEnhancedNotifications' 1
    Set-Reg "$scp\Notifications" 'DisableNotifications' 1
    Set-Reg "$scp\Systray" 'HideSystray' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'AutoCleanup' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Scan' 'DisableRemovableDriveScanning' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Scan' 'DisableScanningNetworkFiles' 1
    Write-Ok '完成'

    Write-Head '7/7 清空隔离区'
    Remove-Item 'C:\ProgramData\Microsoft\Windows Defender\Quarantine' -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok '完成'

    Write-Head '全部完成'
    Write-Ok '请重启让驱动层改动生效'
    Write-Host ''
    Write-Info '重启后验证：'
    Write-Info '  Get-MpComputerStatus'
    Write-Info '  sc query WinDefend'
    Write-Info '  Get-Process MsMpEng,NisSrv | Measure-Object WorkingSet64 -Sum'
    Pause2
}

# ---------------------------------------------------------------
function Restore-Defender {
    Write-Head '恢复 Defender'
    Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' -ErrorAction SilentlyContinue
    $map = @{ 'WinDefend'=2; 'WdNisSvc'=2; 'WdFilter'=1; 'WdNisDrv'=1; 'Sense'=2; 'mpssvc'=2; 'SecurityHealthService'=2 }
    foreach ($k in $map.Keys) {
        Set-Service $k -StartupType Auto -ErrorAction SilentlyContinue
        Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\$k" 'Start' $map[$k]
    }
    Set-Service WdFilter  -StartupType Automatic -ErrorAction SilentlyContinue
    Set-Service WdNisDrv  -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service mpssvc -ErrorAction SilentlyContinue
    Start-Service WinDefend -ErrorAction SilentlyContinue
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like '*Windows Defender*' } |
        Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Write-Ok '已恢复。重启后 Defender 应重新生效。'
    Pause2
}

# ---------------------------------------------------------------
while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '        Windows 安全配置 -- 红队工作站' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    [1]  方案A  加排除项（推荐，保留防护）' -ForegroundColor Green
    Write-Host '    [2]  方案B  只关实时保护（临时）' -ForegroundColor Yellow
    Write-Host '    [3]  方案C  彻底禁用 Defender（约省 540 MB）' -ForegroundColor Red
    Write-Host '    [4]  查看当前状态与内存占用' -ForegroundColor Gray
    Write-Host '    [5]  恢复 Defender' -ForegroundColor Gray
    Write-Host '    [0]  退出' -ForegroundColor DarkGray
    Write-Host ''
    $c = Read-Host '   选择'
    switch ($c) {
        '1' { Add-Exclusions }
        '2' { Disable-RealtimeOnly }
        '3' { Disable-AllDefender }
        '4' { Show-Status }
        '5' { Restore-Defender }
        '0' { exit 0 }
        default { }
    }
}
