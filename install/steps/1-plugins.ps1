<#
  Step 1 - Install plugins into the OFFICIAL DSH Desktop profile
  =============================================================
  Solves the three silent-failure modes:
    A. missing dsh.client  -> no UI entry at all
    B. bundles + cordis.patch.yml double registration -> duplicate loader id
    C. version gate silently skips incompatible plugins -> feature invisible
#>
[CmdletBinding()]
param()

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 1 / 6  -  Install plugins'

# ---------------------------------------------------------------- 0. locate
Head '0. Locate DSH Desktop'

$dshExe = $script:WS.DshExe
if (-not (Test-Path $dshExe)) {
    $found = @()
    foreach ($cand in @('D:\dsh\DeepSeek Harness.exe',
                        "$env:LOCALAPPDATA\Programs\DeepSeek Harness\DeepSeek Harness.exe",
                        "$env:ProgramFiles\DeepSeek Harness\DeepSeek Harness.exe")) {
        if (Test-Path $cand) { $found += $cand }
    }
    if ($found.Count -gt 0) { $dshExe = $found[0] } else { $dshExe = '' }
}

if (-not $dshExe) {
    Fail 'DeepSeek Harness.exe not found.'
    Info 'Install the OFFICIAL desktop build first (community build is not supported).'
    Info 'Expected: D:\dsh\DeepSeek Harness.exe'
    exit 1
}
Ok ("official exe : " + $dshExe)
$script:WS.DshExe  = $dshExe
$script:WS.DshRoot = Split-Path -Parent $dshExe
Info ("install root  : " + $script:WS.DshRoot)

# live process check - which profile is actually in use
$proc = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'expose-internals' } | Select-Object -First 1
if ($proc) {
    if ($proc.CommandLine -match '(\S+\.dsh\S*profiles\S+)') {
        Info ("live profile  : " + $Matches[1])
    }
    Warn 'DSH is running. Close it before applying changes.'
} else {
    Info 'DSH is not running (good).'
}

$profileDir = $script:WS.Profile
$pkgPath    = Join-Path $profileDir 'package.json'

if (-not (Test-Path $pkgPath)) {
    Fail ("profile package.json missing: " + $pkgPath)
    exit 1
}
Ok ("profile       : " + $profileDir)

# ---------------------------------------------------------------- 1. inspect
Head '1. Inspect current profile'

$pkg = Read-JsonFile -Path $pkgPath
if (-not $pkg) { Fail 'cannot parse package.json'; exit 1 }

$bundles = @()
if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) {
    $bundles = @($pkg.dsh.profile.bundles)
}
$deps = @()
if ($pkg.dependencies) { $deps = @($pkg.dependencies.PSObject.Properties.Name) }

Info ("bundles : " + $bundles.Count)
Info ("deps    : " + $deps.Count)

# ---------------------------------------------------------------- 2. dry run
Head '2. Foreground load test  (find silent skips)'

$manifest = Join-Path $script:WS.DshRoot 'resources\app.asar'
$hostJs   = Join-Path $manifest 'dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js'
$innerDir = Join-Path $manifest 'dsh'
$runtime  = Join-Path $script:WS.DshRoot 'resources\runtime\primary-runtime'
$pnpm     = Join-Path $script:WS.DshRoot 'resources\runtime\pnpm\bin\pnpm.mjs'
$binDir   = Join-Path $script:WS.DshRoot 'resources\runtime\bin'

$filesOk = (Test-Path $hostJs) -and (Test-Path $innerDir)
if ($filesOk) {
    Step 'running harness in foreground for ~35s ...'
    $job = Start-Job -ScriptBlock {
        param($exe, $a, $b, $c, $d, $e, $f)
        & $exe --expose-internals $a $b $c $d $e $f 2>&1
    } -ArgumentList $script:WS.DshExe, $hostJs, $innerDir, $profileDir, $runtime, $pnpm, $binDir

    $null = Wait-Job $job -Timeout 35
    $log  = @(Receive-Job $job -ErrorAction SilentlyContinue) -join "`n"
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $skipLines = @($log -split "`n" | Where-Object { $_ -match 'skipping profile bundle|did not activate|failed to import' })

    if ($skipLines.Count -eq 0) {
        Ok 'no skipped bundles'
        Add-Report -Item 'bundle load test' -State 'ok'
    } else {
        Warn ("$($skipLines.Count) problem line(s):")
        foreach ($line in $skipLines) { Info $line.Trim() }

        # parse exemptions out of the messages
        $exemptions = @()
        foreach ($line in $skipLines) {
            if ($line -match 'grant the exact-version exemption for\s+([^\s]+@[^\s]+)\s+on dsh\s+([0-9a-zA-Z.\-]+)') {
                $exemptions += [pscustomobject]@{ Spec = $Matches[1]; DshVersion = $Matches[2] }
            }
        }
        $exemptions = @($exemptions | Sort-Object Spec -Unique)

        if ($exemptions.Count -gt 0) {
            Write-Host ''
            Info ("$($exemptions.Count) plugin(s) blocked by the version gate:")
            foreach ($e in $exemptions) { Info ('   ' + $e.Spec) }
            Write-Host ''
            Info 'Recommended fix: upgrade them (they may already publish a 0.2-compatible build).'
            Info 'Fallback: grant a per-version exemption, then re-run this step to see what still breaks.'

            if (Confirm-Action -Prompt 'Auto-upgrade these plugins with pnpm?' -Word 'UPGRADE') {
                $names = @($exemptions | ForEach-Object { ($_.Spec -split '@')[0] } | Sort-Object -Unique)
                Step ("pnpm add " + ($names -join ' '))
                Push-Location $profileDir
                $env:CI = 'true'
                & pnpm add @($names | ForEach-Object { "$_@latest" }) 2>&1 | ForEach-Object { Info $_ }
                Pop-Location
                Ok 'upgrade attempted - re-run step 1 to verify'
            }
        }
        Add-Report -Item 'bundle load test' -State 'warn' -Detail "$($skipLines.Count) issue(s) - see above"
    }
} else {
    Warn 'cannot locate harness entry (app.asar paths missing)'
    Add-Report -Item 'bundle load test' -State 'skip' -Detail 'entry not found'
}

# ---------------------------------------------------------------- 3. dsh.client
Head '3. Check dsh.client declarations'

$pluginDirs = @()
$nm = Join-Path $profileDir 'node_modules'
if (Test-Path $nm) {
    Get-ChildItem $nm -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like '@*') {
            Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $pluginDirs += $_.FullName }
        } else { $pluginDirs += $_.FullName }
    }
}

$missingClient = @()
foreach ($dir in $pluginDirs) {
    $pj = Join-Path $dir 'package.json'
    if (-not (Test-Path $pj)) { continue }
    $meta = Read-JsonFile -Path $pj
    if (-not $meta) { continue }
    if (-not $meta.dsh) { continue }
    # only third-party plugins that ship a client bundle matter
    $hasClientFile = (Test-Path (Join-Path $dir 'client.js')) -or
                     (Test-Path (Join-Path $dir 'client\client.js'))
    if ($meta.dsh.client) {
        Ok ("{0,-34} client=Y" -f $meta.name)
    } elseif ($hasClientFile) {
        Warn ("{0,-34} has client.js but NO dsh.client" -f $meta.name)
        $missingClient += [pscustomobject]@{ Dir = $dir; Meta = $meta }
    }
}

if ($missingClient.Count -gt 0) {
    Write-Host ''
    Warn ("$($missingClient.Count) plugin(s) ship a client bundle but do not declare dsh.client.")
    Info 'They will load on the host side but NEVER register any UI.'
    Add-Report -Item 'dsh.client declarations' -State 'warn' -Detail "$($missingClient.Count) missing"
} else {
    Add-Report -Item 'dsh.client declarations' -State 'ok'
}

# ---------------------------------------------------------------- 4. duplicates
Head '4. Check duplicate registration'

$patchFile = Join-Path $profileDir 'cordis.patch.yml'
if (Test-Path $patchFile) {
    $patchText = [IO.File]::ReadAllText($patchFile)
    $dupes = @()
    foreach ($b in $bundles) {
        if ($b -like '@*') { continue }
        if ($patchText -match [regex]::Escape($b)) { $dupes += $b }
    }
    if ($dupes.Count -gt 0) {
        Warn 'these appear BOTH in bundles and cordis.patch.yml:'
        foreach ($d in $dupes) { Info ('   ' + $d) }
        Info 'Desktop builds must use bundles only. Remove the insert from cordis.patch.yml.'
        Add-Report -Item 'duplicate registration' -State 'warn' -Detail ($dupes -join ', ')
    } else {
        Ok 'no duplicates'
        Add-Report -Item 'duplicate registration' -State 'ok'
    }
} else {
    Ok 'no cordis.patch.yml (fine)'
    Add-Report -Item 'duplicate registration' -State 'ok'
}

# ---------------------------------------------------------------- 5. bundles sanity
Head '5. Bundles sanity'

$bad = @()
foreach ($b in $bundles) {
    $probe = Join-Path $nm $b
    $pj = Join-Path $probe 'package.json'
    if (-not (Test-Path $pj)) {
        if ($b -like '@deepseek-ai/*') { continue }   # core, shipped inside the app
        $bad += "$b  (not installed)"
        continue
    }
    $meta = Read-JsonFile -Path $pj
    if (-not $meta) { continue }
    if (-not $meta.dsh.bundle) {
        $bad += "$b  (declares no dsh.bundle)"
    }
}

if ($bad.Count -gt 0) {
    Warn 'these bundles entries are invalid:'
    foreach ($x in $bad) { Info ('   ' + $x) }
    Add-Report -Item 'bundles sanity' -State 'warn' -Detail "$($bad.Count) invalid"
} else {
    Ok 'all bundles entries valid'
    Add-Report -Item 'bundles sanity' -State 'ok'
}

# ---------------------------------------------------------------- 6. prompt protection
Head '6. Protect prompt-inject.md'

$inject = Join-Path $script:WS.DshHome 'prompt-inject.md'
$keep   = Join-Path $script:WS.DshHome 'dsh-purge\prompt-inject.custom.md'
$restore = Join-Path $script:WS.DshHome 'dsh-purge\restore-prompt.cmd'

if (Test-Path $inject) {
    $size = (Get-Item $inject).Length
    Ok ("prompt-inject.md present ($size bytes)")
    Copy-Item $inject $keep -Force
    Ok ("snapshot saved -> " + $keep)

    # ASCII-only restore launcher
    $body = @"
@echo off
REM ASCII-only. Restores the saved prompt-inject.md snapshot.
copy /Y "$keep" "$inject" >nul
echo Restored prompt-inject.md from snapshot.
echo Re-open the dsh-purge panel so the UI reads the new text.
pause
"@
    Write-AsciiCrlf -Path $restore -Content $body
    Ok ('restore helper -> ' + $restore)
    Add-Report -Item 'prompt snapshot' -State 'ok'
} else {
    Warn 'prompt-inject.md not found (dsh-purge may not be installed yet)'
    Add-Report -Item 'prompt snapshot' -State 'skip'
}

# ---------------------------------------------------------------- report
Show-Report
Write-Host ''
Info 'Next: step 2 (toolchain).  Or run INSTALL-ALL.cmd for everything.'
exit 0
