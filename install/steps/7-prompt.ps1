<#
  Step 7 - Inject the DeepSeek adapter into prompt-inject.md
  ==========================================================
  WHY THIS IS A SEPARATE STEP
    dsh-purge rewrites prompt-inject.md from whatever text is in its UI
    textbox when you press Apply. If the box shows the built-in default,
    your custom content is destroyed.

    This step therefore:
      1. inserts the adapter at the right anchor
      2. flips override-state.json to customized=true
      3. drops a one-click restore script next to it
#>
[CmdletBinding()]
param(
    [string]$AdapterPath = ''
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 7  -  DeepSeek adapter prompt'

$anchor     = 'World axioms'
$injectPath = Join-Path $script:WS.DshHome 'prompt-inject.md'
$purgeDir   = Join-Path $script:WS.DshHome 'dsh-purge'
$keepPath   = Join-Path $purgeDir 'prompt-inject.custom.md'
$statePath  = Join-Path $purgeDir 'override-state.json'

# ---------------------------------------------------------------- adapter
Head '1. Locate adapter text'

if (-not $AdapterPath) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    foreach ($cand in @(
        (Join-Path $root 'config\deepseek-adapter.md'),
        (Join-Path $PSScriptRoot 'deepseek-adapter.md'),
        (Join-Path $PSScriptRoot '..\..\config\deepseek-adapter.md')
    )) {
        if (Test-Path $cand) { $AdapterPath = (Resolve-Path $cand).Path; break }
    }
}

if (-not $AdapterPath -or -not (Test-Path $AdapterPath)) {
    Fail 'deepseek-adapter.md not found.'
    Info 'Pass it explicitly:  -AdapterPath <path>'
    exit 1
}
Ok ('adapter : ' + $AdapterPath)
$adapterText = ([IO.File]::ReadAllText($AdapterPath)).TrimEnd()

# ---------------------------------------------------------------- inject
Head '2. Locate prompt-inject.md'

if (-not (Test-Path $injectPath)) {
    Fail ('not found: ' + $injectPath)
    Info 'Run step 1 first (installs dsh-purge and creates this file).'
    exit 1
}

$current = [IO.File]::ReadAllText($injectPath)
$sizeBefore = $current.Length
Ok ('prompt-inject.md  ' + $sizeBefore + ' chars')

if ($current -match 'DEEPSEEK ADAPTER') {
    Ok 'adapter already present - refreshing in place'

    # cut out the old block, between the banner and the closing rule
    $pattern = '(?s)════+\r?\nDEEPSEEK ADAPTER.*?════+\r?\n'
    $current = [regex]::Replace($current, $pattern, '')
}

# ---------------------------------------------------------------- anchor
Head '3. Insert at anchor'

$lines = $current -split "`r?`n"
$anchorIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith($anchor)) { $anchorIndex = $i; break }
}

if ($anchorIndex -lt 0) {
    Warn ("anchor '" + $anchor + "' not found")
    Info 'Falling back to: append at end of file.'
    $newText = $current.TrimEnd() + "`r`n`r`n" + $adapterText + "`r`n"
} else {
    Ok ('anchor at line ' + ($anchorIndex + 1))
    $head = $lines[0..$anchorIndex]
    $tail = @()
    if ($anchorIndex + 1 -lt $lines.Count) {
        $tail = $lines[($anchorIndex + 1)..($lines.Count - 1)]
    }
    $newText = (($head -join "`r`n") + "`r`n`r`n" + $adapterText + "`r`n`r`n" + ($tail -join "`r`n")).TrimEnd() + "`r`n"
}

# ---------------------------------------------------------------- backup
Head '4. Backup and write'

$backup = Backup-File -Path $injectPath -Tag 'bak-preDS'
if ($backup) { Ok ('backup : ' + (Split-Path -Leaf $backup)) }

Write-Utf8NoBom -Path $injectPath -Content $newText
$sizeAfter = $newText.Length
Ok ('written  ' + $sizeAfter + ' chars  (+' + ($sizeAfter - $sizeBefore) + ')')

# snapshot for restore
New-Item -ItemType Directory -Path $purgeDir -Force | Out-Null
Write-Utf8NoBom -Path $keepPath -Content $newText
Ok ('snapshot : ' + (Join-Path 'dsh-purge' 'prompt-inject.custom.md'))

# ---------------------------------------------------------------- lock
Head '5. Lock against UI overwrite'

$state = Read-JsonFile -Path $statePath
if (-not $state) { $state = [pscustomobject]@{} }

$merged = [ordered]@{}
foreach ($p in $state.PSObject.Properties) { $merged[$p.Name] = $p.Value }
$merged['customized'] = $true
$merged['note']       = 'DeepSeek adapter injected by installer - do not overwrite'
$merged['updatedAt']  = (Get-Date).ToUniversalTime().ToString('o')

Save-JsonFile -Path $statePath -Object ([pscustomobject]$merged) -NoBackup
Ok 'override-state.json: customized = true'

# ---------------------------------------------------------------- restore
Head '6. Restore helper'

$restoreCmd = Join-Path $purgeDir 'restore-prompt.cmd'
$body = @"
@echo off
REM ASCII-only. Restores the DeepSeek adapter snapshot over prompt-inject.md
setlocal
set "KEEP=%USERPROFILE%\.dsh\dsh-purge\prompt-inject.custom.md"
set "DEST=%USERPROFILE%\.dsh\prompt-inject.md"
if not exist "%KEEP%" (
  echo Snapshot not found: %KEEP%
  pause & exit /b 1
)
copy /Y "%KEEP%" "%DEST%" >nul
echo.
echo Restored prompt-inject.md from snapshot.
echo Re-open the dsh-purge panel so the UI reloads the text.
echo.
pause
"@
Write-AsciiCrlf -Path $restoreCmd -Content $body
Ok ('restore helper : ' + $restoreCmd)

# ---------------------------------------------------------------- verify
Head '7. Verify'

$check = [IO.File]::ReadAllText($injectPath)
$count = ([regex]::Matches($check, '【DS-\d+】')).Count
if ($count -ge 10) {
    Ok ("$count adapter rule(s) present")
    Add-Report -Item 'DS adapter rules' -State 'ok' -Detail "$count rules"
} else {
    Warn ("only $count rule(s) found - expected 10+")
    Add-Report -Item 'DS adapter rules' -State 'warn' -Detail "$count rules"
}

$firstLine = ($check -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
Info ('first line : ' + $firstLine)

if ($check -match 'World axioms') { Ok 'anchor intact' } else { Warn 'anchor missing' }

Write-Host ''
Info 'IMPORTANT: in the dsh-purge panel, do NOT press Apply while its prompt'
Info 'box shows stale text - that overwrites this file. If it happens, just'
Info ('run:  ' + $restoreCmd)

Show-Report
exit 0
