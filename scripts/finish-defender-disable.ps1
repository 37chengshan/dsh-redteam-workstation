#Requires -Version 5.1
<#
  补完 Defender 禁用 —— 只做上次没生效的三件事
  1. 写服务注册表 Start=4（WinDefend / WdFilter / WdNisDrv / WdBoot）
  2. 禁用 4 个残留计划任务
  3. 补全剩余组策略键
  必须管理员运行，跑完重启。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

function Head($t) { Write-Host ''; Write-Host ('  ' + ('=' * 62)) -ForegroundColor DarkGray
                    Write-Host ('   ' + $t) -ForegroundColor Cyan
                    Write-Host ('  ' + ('=' * 62)) -ForegroundColor DarkGray }
function Ok($t)   { Write-Host ('   [+] ' + $t) -ForegroundColor Green }
function Bad($t)  { Write-Host ('   [X] ' + $t) -ForegroundColor Red }
function Info($t) { Write-Host ('       ' + $t) -ForegroundColor Gray }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Bad '需要管理员权限。右键 PowerShell -> 以管理员身份运行，再执行本脚本。'
    exit 1
}

Clear-Host
Write-Host ''
Write-Host '  补完 Defender 禁用' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

# ---------- 0. 先彻底关实时保护（写服务键的前提） ----------
Head '0/4 前置：关闭实时保护'
foreach ($k in 'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
               'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning') {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
    if (-not (Test-Path $p)) { New-Item $p -Force | Out-Null }
    New-ItemProperty $p -Name $k -Value 1 -PropertyType DWord -Force | Out-Null
}
Ok '实时保护策略已写'

# ---------- 1. 服务注册表 ----------
Head '1/4 写服务注册表 Start=4'
$targets = @{
    'WinDefend'  = 4
    'WdNisSvc'   = 4
    'WdNisDrv'   = 4
    'WdFilter'   = 4
    'WdBoot'     = 4
    'Sense'      = 4
    'mpssvc'     = 2      # 防火墙保留自动，要关就改 4
}
foreach ($s in $targets.Keys) {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path $path)) { Info "$s 服务项不存在，跳过"; continue }
    try {
        Set-ItemProperty -Path $path -Name 'Start' -Value $targets[$s] -Type DWord -Force -ErrorAction Stop
        $chk = (Get-ItemProperty $path).Start
        if ($chk -eq $targets[$s]) { Ok ("{0,-14} Start={1}" -f $s, $chk) }
        else { Bad ("{0,-14} 写入后仍是 Start={1}" -f $s, $chk) }
    } catch {
        Bad ("{0,-14} 写入失败: {1}" -f $s, $_.Exception.Message)
    }
    # 同时用 sc.exe 双保险
    & sc.exe config $s start= disabled 2>&1 | Out-Null
    & sc.exe failure $s reset= 0 actions= "" 2>&1 | Out-Null
}

# ---------- 2. 计划任务 ----------
Head '2/4 禁用残留计划任务'
$n = 0
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskPath -like '*Windows Defender*' -or $_.TaskName -match 'Defender|MpCmdRun'
} | ForEach-Object {
    $before = $_.State
    Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
    $after = (Get-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue).State
    Ok ("{0,-42} {1} -> {2}" -f $_.TaskName, $before, $after)
    $n++
}
if ($n -eq 0) { Info '没有找到 Defender 计划任务' }

# 额外：干掉 MpCmdRun 的 WMI 触发
Get-CimInstance -Namespace root/subscription -ClassName __EventFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Defender' } |
    ForEach-Object { Remove-CimInstance $_ -ErrorAction SilentlyContinue; Info ('移除 WMI 过滤器 ' + $_.Name) }

# ---------- 3. 剩余策略 ----------
Head '3/4 补全组策略键'
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
foreach ($kv in @(
        @("$pol", 'DisableAntiSpyware', 1),
        @("$pol", 'DisableAntiVirus', 1),
        @("$pol", 'ServiceKeepAlive', 0),
        @("$pol", 'DisableRoutinelyTakingAction', 1),
        @("$pol", 'PUAProtection', 0),
        @("$pol", 'AllowFastServiceStartup', 0),
        @("$pol\Spynet", 'SpynetReporting', 0),
        @("$pol\Spynet", 'SubmitSamplesConsent', 2),
        @("$pol\Signature Updates", 'ForceUpdateFromMU', 0),
        @("$pol\MpEngine", 'MpEnablePus', 0),
        @("$pol\Real-Time Protection", 'DisableRealtimeMonitoring', 1)
    )) {
    $path = $kv[0]
    if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
    New-ItemProperty $path -Name $kv[1] -Value $kv[2] -PropertyType DWord -Force | Out-Null
    Ok ("{0,-34} = {1}" -f $kv[1], $kv[2])
}

# ---------- 4. 验证 ----------
Head '4/4 重启前验证'
Write-Host ''
Write-Host '   服务（重启后才真正生效）:' -ForegroundColor DarkGray
foreach ($s in $targets.Keys) {
    $v = Get-Service $s -ErrorAction SilentlyContinue
    $reg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -ErrorAction SilentlyContinue).Start
    $m = @{0='Boot';1='System';2='Auto';3='Manual';4='Disabled'}[[int]$reg]
    if ($v) {
        $c = if ($reg -eq 4) { 'Green' } else { 'Yellow' }
        Write-Host ("      {0,-14} 当前={1,-9} 注册表=Start:{2} ({3})" -f $s, $v.Status, $reg, $m) -ForegroundColor $c
    } else {
        Write-Host ("      {0,-14} 不存在" -f $s) -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '   内存:' -ForegroundColor DarkGray
$p = Get-Process MsMpEng,MsSense,NisSrv,MpDefenderCoreService -ErrorAction SilentlyContinue
if ($p) { $p | ForEach-Object { Write-Host ("      {0,-26}{1,9:N1} MB" -f $_.ProcessName, ($_.WorkingSet64/1MB)) } }
else { Write-Host '      没有 Defender 进程' -ForegroundColor Green }

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host '   [+] 完成。请立即重启，服务注册表改动只在启动时读取。' -ForegroundColor Green
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''
$r = Read-Host '   现在重启？(Y/N)'
if ($r -eq 'Y' -or $r -eq 'y') { Restart-Computer -Force }
else { Write-Host '   已跳过。记得手动重启。' -ForegroundColor Yellow }
