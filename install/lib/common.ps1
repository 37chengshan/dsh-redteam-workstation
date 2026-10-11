<#
  DSH Red Team Workstation - common library
  ==========================================================
  This file MUST be saved as UTF-8 with BOM, CRLF line endings.

  ESCAPING RULES BAKED INTO THIS FILE
  -----------------------------------
  1. NEVER use PowerShell AUTOMATIC VARIABLES as your own names.
     Reserved (read-only or auto-assigned):
       $host $input $args $error $matches $profile $psitem $true $false
       $null $HOME $PID $PWD $PSHOME $ShellId $StackTrace $this
       $foreach $switch $MyInvocation $ExecutionContext $PSVersionTable
       $PSStyle $IsWindows $IsLinux $IsMacOS
     Use descriptive alternatives: $targetHost, $hostName, $binDir ...
     (This exact trap produced a corrupted Cloudflare DNS record.)

  2. NEVER build JSON with string concatenation + escaped quotes.
     Use [ordered]@{} | ConvertTo-Json -Depth N -Compress

  3. Paths with spaces must be quoted:  & $exe "arg with space"
     Never do:  cmd /c "x \"y z\""

  4. Write-Host with non-ASCII is fine in .ps1 (UTF-8 BOM).
  5. Write files with [IO.File]::WriteAllText + UTF8Encoding($false) to
     avoid PowerShell 5.1 adding a BOM where the consumer cannot read it.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- paths
$script:WS = [ordered]@{
    Home        = $env:USERPROFILE
    DshHome     = Join-Path $env:USERPROFILE '.dsh'
    DshExe      = 'D:\dsh\DeepSeek Harness.exe'
    DshRoot     = 'D:\dsh'
    Profile     = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
    Tools       = 'D:\security-tools'
    ToolsBin    = 'D:\security-tools\bin'
    Templates   = 'D:\security-tools\nuclei-templates'
    Wordlists   = 'D:\security-tools\wordlists'
    WslDistro   = 'Ubuntu-22.04'
}

# ------------------------------------------------------------- output
function Say      { param([string]$m) Write-Host $m }
function Head     { param([string]$m)
    Write-Host ''
    Write-Host ('  ' + ('=' * 64)) -ForegroundColor DarkGray
    Write-Host ('   ' + $m) -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 64)) -ForegroundColor DarkGray
}
function Ok       { param([string]$m) Write-Host ('   [ok]  ' + $m) -ForegroundColor Green }
function Warn     { param([string]$m) Write-Host ('   [!!]  ' + $m) -ForegroundColor Yellow }
function Fail     { param([string]$m) Write-Host ('   [xx]  ' + $m) -ForegroundColor Red }
function Info     { param([string]$m) Write-Host ('         ' + $m) -ForegroundColor Gray }
function Step     { param([string]$m) Write-Host ('   >> ' + $m) -ForegroundColor White }

function Pause-Here {
    Write-Host ''
    Read-Host '   Press Enter to continue' | Out-Null
}

function Confirm-Action {
    param([string]$Prompt, [string]$Word = 'YES')
    Write-Host ''
    $answer = Read-Host ('   ' + $Prompt + " (type $Word to confirm)")
    return ($answer -ceq $Word)
}

# ------------------------------------------------------------ guards
function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        Fail 'Administrator privileges required.'
        Info 'Close this window, right-click the .cmd, choose "Run as administrator".'
        return $false
    }
    return $true
}

function Test-Wsl {
    try {
        $out = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $list = @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        return ($list -contains $script:WS.WslDistro)
    } catch { return $false }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string]$Command,
        [switch]$AsRoot,
        [int]$TimeoutSec = 0
    )
    $wslArgs = @('-d', $script:WS.WslDistro)
    if ($AsRoot) { $wslArgs += @('-u', 'root') }
    $wslArgs += @('-e', 'bash', '-lc', $Command)
    if ($TimeoutSec -gt 0) {
        $job = Start-Job -ScriptBlock {
            param($a) & wsl.exe @a 2>&1
        } -ArgumentList (,$wslArgs)
        $done = Wait-Job $job -Timeout $TimeoutSec
        if (-not $done) { Stop-Job $job; Remove-Job $job -Force; return @{ Ok = $false; Out = 'timeout' } }
        $out = Receive-Job $job
        Remove-Job $job -Force
        return @{ Ok = $true; Out = ($out -join "`n") }
    }
    $out = & wsl.exe @wslArgs 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Out = ($out -join "`n") }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 5000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $ok    = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $client.EndConnect($async) }
        return $ok
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ----------------------------------------------------------- fs utils
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($true)))
}

function Write-AsciiCrlf {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $normalized = ($Content -replace "`r`n", "`n") -replace "`n", "`r`n"
    [IO.File]::WriteAllText($Path, $normalized, (New-Object Text.ASCIIEncoding))
}

function Backup-File {
    param([string]$Path, [string]$Tag = 'bak')
    if (-not (Test-Path $Path)) { return $null }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = "$Path.$Tag-$stamp"
    Copy-Item $Path $target -Force
    return $target
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Save-JsonFile {
    param([string]$Path, $Object, [switch]$NoBackup)
    if (-not $NoBackup) { Backup-File -Path $Path -Tag 'bak' | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 20
    Write-Utf8NoBom -Path $Path -Content ($json + "`n")
}

# ---------------------------------------------------------- registry
function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','QWord','MultiString')][string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        return $true
    } catch {
        Fail ("registry write failed: {0}\{1} - {2}" -f $Path, $Name, $_.Exception.Message)
        return $false
    }
}

# ------------------------------------------------------------- report
$script:Report = New-Object System.Collections.ArrayList

function Add-Report {
    param([string]$Item, [ValidateSet('ok','warn','fail','skip')][string]$State, [string]$Detail = '')
    [void]$script:Report.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail })
}

function Show-Report {
    Head 'Result'
    foreach ($row in $script:Report) {
        $tag = switch ($row.State) {
            'ok'   { '[ok]  ' }
            'warn' { '[!!]  ' }
            'fail' { '[xx]  ' }
            'skip' { '[--]  ' }
        }
        $color = switch ($row.State) {
            'ok'   { 'Green' }
            'warn' { 'Yellow' }
            'fail' { 'Red' }
            default { 'DarkGray' }
        }
        $line = '   ' + $tag + $row.Item.PadRight(34)
        if ($row.Detail) { $line += $row.Detail }
        Write-Host $line -ForegroundColor $color
    }
    $bad = @($script:Report | Where-Object { $_.State -eq 'fail' }).Count
    Write-Host ''
    if ($bad -eq 0) { Ok 'All good.' } else { Warn "$bad item(s) need attention." }
}

function Show-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host ('  ' + ('=' * 64)) -ForegroundColor Cyan
    Write-Host ('    ' + $Title) -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 64)) -ForegroundColor Cyan
}
