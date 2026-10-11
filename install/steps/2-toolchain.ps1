<#
  Step 2 - Deploy the red-team toolchain
  ======================================
  Everything lands on D: . C: usage stays under 10 KB (junctions only).

  Targets:
    15/15 tools resolved by dsh-purge
    15/15 tools actually executable
    'toolbox complete' from setup.sh
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')

Show-Banner 'Step 2 / 6  -  Deploy toolchain'

$Bin = $script:WS.ToolsBin

# tool id -> release asset candidate names (used for existence checks only)
$Catalog = [ordered]@{
    nmap       = 'nmap'
    nuclei     = 'nuclei'
    masscan    = 'masscan'
    fscan      = 'fscan'
    gogo       = 'gogo'
    suo5       = 'suo5'
    chisel     = 'chisel'
    ffuf       = 'ffuf'
    httpx      = 'httpx'
    dnsx       = 'dnsx'
    subfinder  = 'subfinder'
    ksubdomain = 'ksubdomain'
    naabu      = 'naabu'
    gowitness  = 'gowitness'
    frpc       = 'frpc'
    frps       = 'frps'
    ligolo     = 'ligolo-proxy'
}

# ---------------------------------------------------------------- 0. WSL
Head '0. Check WSL'

if (-not (Test-Wsl)) {
    Fail ("WSL distro '" + $script:WS.WslDistro + "' not found.")
    Info 'Install it first:   wsl --install -d Ubuntu-22.04'
    exit 1
}
Ok ("WSL " + $script:WS.WslDistro + " ready")

$glibc = Invoke-Wsl -Command 'ldd --version 2>/dev/null | head -1'
Info ('   ' + $glibc.Out.Trim())

# ---------------------------------------------------------------- 1. dirs
Head '1. Prepare directories'

foreach ($d in @($script:WS.Tools, $Bin, $script:WS.Wordlists, (Join-Path $script:WS.Tools 'tmp'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Ok ("tool root : " + $script:WS.Tools)

# ---------------------------------------------------------------- 2. download
if (-not $VerifyOnly) {
    Head '2. Download tools  (Python, no unzip / no sudo)'

    $downloader = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\install_toolchain.py'
    if (-not (Test-Path $downloader)) {
        # fall back to an inline copy
        $downloader = Join-Path $PSScriptRoot 'install_toolchain.py'
    }

    if (Test-Path $downloader) {
        $wslPath = '/mnt/' + $downloader.Substring(0,1).ToLower() + $downloader.Substring(2).Replace('\','/')
        Step ("running " + (Split-Path -Leaf $downloader))
        $r = Invoke-Wsl -Command ("python3 '" + $wslPath + "'") -TimeoutSec 900
        foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
    } else {
        Warn 'install_toolchain.py not found - skipping download'
        Info 'Copy it next to the installer, then re-run this step.'
    }

    # --- gap fillers the main script does not cover ---
    Head '2b. Extra tools  (naabu / gowitness / ligolo / masscan)'

    $fillers = @(
        @{ Id='naabu';     Repo='projectdiscovery/naabu'; Asset='naabu_{v}_linux_amd64.zip'; Member='naabu' }
        @{ Id='gowitness'; Repo='sensepost/gowitness';    Asset='gowitness-{v}-linux-amd64';    Member='' }
    )

    foreach ($t in $fillers) {
        if (Test-Path (Join-Path $Bin $t.Id)) { Ok ($t.Id + ' already present'); continue }
        Step ('fetching ' + $t.Id)
        $cmd = @"
set -e
BIN=$('/mnt/' + $Bin.Substring(0,1).ToLower() + $Bin.Substring(2).Replace('\','/'))
TAG=`$(curl -sL -o /dev/null -w '%{url_effective}' https://github.com/$($t.Repo)/releases/latest | grep -oE 'tag/[^/]+`$' | cut -d/ -f2)
[ -z "`$TAG" ] && { echo '  cannot resolve tag'; exit 1; }
V=`${TAG#v}
URL="https://github.com/$($t.Repo)/releases/download/`$TAG/$($t.Asset)".Replace('{v}', '`$V')
echo "  url: `$URL"
curl -sL -m 300 -o /tmp/dl "`$URL"
[ -s /tmp/dl ] || { echo '  download failed'; exit 1; }
if file -b /tmp/dl | grep -q ELF; then
  cp -f /tmp/dl "`$BIN/$($t.Id)"; chmod +x "`$BIN/$($t.Id)"
else
  python3 -c "
import zipfile,shutil,os
z=zipfile.ZipFile('/tmp/dl')
for n in z.namelist():
    if os.path.basename(n)=='$($t.Member)':
        open('`$BIN/$($t.Id)','wb').write(z.read(n)); os.chmod('`$BIN/$($t.Id)',0o755); break
"
fi
[ -x "`$BIN/$($t.Id)" ] && echo "  ok `$(stat -c%s `$BIN/$($t.Id)) bytes" || echo '  failed'
"@
        $r = Invoke-Wsl -Command $cmd -TimeoutSec 400
        foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
    }

    # ligolo-ng
    if (-not (Test-Path (Join-Path $Bin 'ligolo-proxy'))) {
        Step 'fetching ligolo-ng'
        $cmd = @"
BIN=$('/mnt/' + $Bin.Substring(0,1).ToLower() + $Bin.Substring(2).Replace('\','/'))
LV=`$(curl -sL https://api.github.com/repos/nicocha30/ligolo-ng/releases/latest | grep -oE '"tag_name":[^,]*' | grep -oE 'v[0-9.]+')
[ -z "`$LV" ] && { echo '  cannot resolve tag'; exit 1; }
for K in agent proxy; do
  curl -sL -m 300 -o /tmp/lg.tgz "https://github.com/nicocha30/ligolo-ng/releases/download/`$LV/ligolo-ng_`${K}_`${LV#v}_linux_amd64.tar.gz"
  rm -rf /tmp/lgx && mkdir /tmp/lgx
  tar xzf /tmp/lg.tgz -C /tmp/lgx 2>/dev/null
  F=`$(find /tmp/lgx -type f -name "`$K" | head -1)
  [ -n "`$F" ] && cp -f "`$F" "`$BIN/ligolo-`$K" && chmod +x "`$BIN/ligolo-`$K" && echo "  ligolo-`$K ok"
done
"@
        $r = Invoke-Wsl -Command $cmd -TimeoutSec 400
        foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
    }

    # masscan via .deb (no static build exists)
    if (-not (Test-Path (Join-Path $Bin 'masscan'))) {
        Step 'fetching masscan from Ubuntu pool'
        $cmd = @"
BIN=$('/mnt/' + $Bin.Substring(0,1).ToLower() + $Bin.Substring(2).Replace('\','/'))
cd /tmp
DEB=`$(curl -sL 'http://archive.ubuntu.com/ubuntu/pool/universe/m/masscan/' | grep -oE 'masscan_1\.3\.2\+ds1-[12]_amd64\.deb' | sort -u | tail -1)
[ -z "`$DEB" ] && { echo '  cannot resolve deb name'; exit 1; }
curl -sL -m 180 -o m.deb "http://archive.ubuntu.com/ubuntu/pool/universe/m/masscan/`$DEB"
rm -rf mx && mkdir mx && cd mx && ar x ../m.deb 2>/dev/null
python3 -m pip install --user --quiet zstandard 2>/dev/null
python3 - <<'PY'
import zstandard, tarfile, io, os
d = zstandard.ZstdDecompressor().decompress(open('data.tar.zst','rb').read(), max_output_size=300*1024*1024)
tf = tarfile.open(fileobj=io.BytesIO(d))
for m in tf.getmembers():
    if os.path.basename(m.name) == 'masscan' and m.isfile():
        out = os.environ['BIN'] + '/masscan'
        open(out,'wb').write(tf.extractfile(m).read()); os.chmod(out,0o755)
        print('  ok', os.path.getsize(out), 'bytes'); break
PY
"@
        $r = Invoke-Wsl -Command ("export BIN='" + ('/mnt/' + $Bin.Substring(0,1).ToLower() + $Bin.Substring(2).Replace('\','/')) + "'; " + $cmd) -TimeoutSec 400
        foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
    }

    # impacket via get-pip bootstrap (no sudo)
    Head '2c. impacket'
    $chk = Invoke-Wsl -Command "python3 -c 'import impacket' 2>/dev/null && echo YES || echo NO"
    if ($chk.Out.Trim() -eq 'YES') {
        Ok 'impacket already installed'
    } else {
        Step 'bootstrapping pip + installing impacket'
        $cmd = @"
curl -sL -o /tmp/gp.py https://bootstrap.pypa.io/get-pip.py
python3 /tmp/gp.py --user --quiet 2>&1 | tail -2
python3 -m pip install --user --quiet impacket 2>&1 | tail -2
python3 -c 'import impacket; print("  impacket ok")'
"@
        $r = Invoke-Wsl -Command $cmd -TimeoutSec 600
        foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
    }
}

# ---------------------------------------------------------------- 3. wrappers
Head '3. Generate Windows .cmd wrappers'

$wrapperMap = [ordered]@{}
foreach ($id in $Catalog.Keys) {
    if (Test-Path (Join-Path $Bin $Catalog[$id])) { $wrapperMap[$id] = $Catalog[$id] }
}

$wrapperBody = "@echo off`r`nREM Windows wrapper -> WSL linux binary. ASCII only.`r`nwsl.exe -d $($script:WS.WslDistro) -e /mnt/d/security-tools/bin/{T} %*`r`n"

$made = 0
foreach ($id in $wrapperMap.Keys) {
    $real = $wrapperMap[$id]
    $text = $wrapperBody.Replace('{T}', $real)
    Write-AsciiCrlf -Path (Join-Path $Bin "$id.cmd") -Content $text
    $made++
}
Ok ("$made launcher(s) written")

# impacket launchers
$impacket = [ordered]@{
    'impacket-secretsdump' = 'secretsdump.py'
    'impacket-psexec'      = 'psexec.py'
    'impacket-wmiexec'     = 'wmiexec.py'
    'impacket-smbexec'     = 'smbexec.py'
    'impacket-ntlmrelayx'  = 'ntlmrelayx.py'
    'impacket-GetNPUsers'  = 'GetNPUsers.py'
    'impacket-GetUserSPNs' = 'GetUserSPNs.py'
}
foreach ($k in $impacket.Keys) {
    $text = "@echo off`r`nREM Windows wrapper -> impacket in WSL (~/.local/bin). ASCII only.`r`nwsl.exe -d $($script:WS.WslDistro) -e bash -lc `"python3 ~/.local/bin/$($impacket[$k]) %*`"`r`n"
    Write-AsciiCrlf -Path (Join-Path $Bin "$k.cmd") -Content $text
}
Ok 'impacket launchers written'

# ---------------------------------------------------------------- 4. junctions
Head '4. Toolkit junction tree  (satisfies setup.sh)'

$tk = Join-Path $script:WS.DshHome 'redteam\toolkit'
New-Item -ItemType Directory -Path $tk -Force | Out-Null

# aliases live on D: so C: stays empty
$alias = Join-Path $script:WS.Tools 'aliases'
$aliasMap = [ordered]@{
    suo5   = @{ 'suo5-linux-amd64' = 'suo5'; 'suo5' = 'suo5' }
    ligolo = @{ 'proxy' = 'ligolo-proxy'; 'agent' = 'ligolo-agent' }
}
foreach ($sub in $aliasMap.Keys) {
    $dir = Join-Path $alias $sub
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($aliasName in $aliasMap[$sub].Keys) {
        $srcName = $aliasMap[$sub][$aliasName]
        $src = Join-Path $Bin $srcName
        $dst = Join-Path $dir $aliasName
        if (-not (Test-Path $src)) { continue }
        if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType SymbolicLink -Path $dst -Target $src -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path $dst)) { Copy-Item $src $dst -Force -ErrorAction SilentlyContinue }
    }
}

$subs = @('nuclei','httpx','dnsx','subfinder','naabu','fscan','gogo','suo5','chisel',
          'ffuf','ksubdomain','gowitness','frp','ligolo','nmap','masscan')
$junc = 0
foreach ($s in $subs) {
    $link = Join-Path $tk $s
    if (Test-Path $link) { Remove-Item $link -Recurse -Force -ErrorAction SilentlyContinue }
    $target = if ($s -eq 'suo5' -or $s -eq 'ligolo') { Join-Path $alias $s } else { $Bin }
    New-Item -ItemType Junction -Path $link -Target $target -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path $link) { $junc++ }
}
Ok ("$junc junction(s) created")

$size = (Get-ChildItem $tk -Recurse -Force -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum).Sum
if ($size -and $size -gt 50MB) {
    Warn ('toolkit dir is {0:N1} MB - symlinks fell back to copy?' -f ($size/1MB))
    Info 'Delete it and re-run; junctions should keep this under 1 MB.'
} else {
    Ok ('toolkit dir size: {0:N1} KB' -f ($size/1KB))
}

# ---------------------------------------------------------------- 5. templates
Head '5. nuclei templates'

$tpl = $script:WS.Templates
if (Test-Path (Join-Path $tpl '.done')) {
    Ok 'templates already present'
} else {
    Step 'downloading nuclei-templates (about 60 MB)'
    $cmd = @"
BIN=/mnt/d/security-tools
mkdir -p "`$BIN/nuclei-templates"
cd "`$BIN"
curl -sL -m 600 -o nt.tar.gz https://github.com/projectdiscovery/nuclei-templates/archive/refs/heads/main.tar.gz
tar xzf nt.tar.gz -C "`$BIN/nuclei-templates" --strip-components=1 2>/dev/null
touch "`$BIN/nuclei-templates/.done"
find "`$BIN/nuclei-templates" -name '*.yaml' | wc -l
mkdir -p ~/.config/nuclei
echo 'templates-directory: /mnt/d/security-tools/nuclei-templates' > ~/.config/nuclei/config.yaml
"@
    $r = Invoke-Wsl -Command $cmd -TimeoutSec 900
    foreach ($line in ($r.Out -split "`n")) { Info $line.TrimEnd() }
}
if (Test-Path $tpl) { Ok 'templates ready' }

# ---------------------------------------------------------------- 6. wordlists
Head '6. Wordlists'

$wl = @(
    @{ N='common.txt';                       U='https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/common.txt' }
    @{ N='raft-medium-directories.txt';      U='https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/raft-medium-directories.txt' }
    @{ N='subdomains-top1million-20000.txt'; U='https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/subdomains-top1million-20000.txt' }
)
foreach ($w in $wl) {
    $dest = Join-Path $script:WS.Wordlists $w.N
    if (Test-Path $dest) { Ok ($w.N + ' present'); continue }
    try { Invoke-WebRequest -Uri $w.U -OutFile $dest -TimeoutSec 180 -UseBasicParsing; Ok $w.N }
    catch { Warn ($w.N + ' failed') }
}

# ---------------------------------------------------------------- 7. config
Head '7. Write dsh-purge config'

$cfgPath = Join-Path $script:WS.DshHome 'redteam\config.json'
Backup-File -Path $cfgPath -Tag 'bak' | Out-Null

$toolMap = [ordered]@{
    nmap = 'nmap'; nuclei = 'nuclei'; masscan = 'masscan'; fscan = 'fscan'; gogo = 'gogo'
    suo5 = 'suo5'; frpc = 'frpc'; frps = 'frps'; chisel = 'chisel'; ffuf = 'ffuf'
    httpx = 'httpx'; dnsx = 'dnsx'; subfinder = 'subfinder'; ksubdomain = 'ksubdomain'
    impacket = 'impacket-secretsdump'
}
$toolsOut = [ordered]@{}
foreach ($k in $toolMap.Keys) {
    $cmdPath = Join-Path $Bin ($toolMap[$k] + '.cmd')
    $toolsOut[$k] = if (Test-Path $cmdPath) { $cmdPath } else { '' }
}

$existing = Read-JsonFile -Path $cfgPath
$vpsHost = if ($existing -and $existing.env) { $existing.env.REDTEAM_VPS_HOST } else { '' }
$vpsKey  = if ($existing -and $existing.env) { $existing.env.REDTEAM_VPS_KEY  } else { '~/.ssh/id_rsa_vps' }
$fofaKey = if ($existing -and $existing.env) { $existing.env.FOFA_KEY         } else { '' }

$config = [ordered]@{
    version              = 1
    platform             = 'windows'
    toolkitDir           = $script:WS.Tools
    nucleiTemplatesDir   = $script:WS.Templates
    binDirs              = @($Bin)
    tools                = $toolsOut
    env                  = [ordered]@{
        FOFA_KEY          = $fofaKey
        REDTEAM_VPS_HOST  = $vpsHost
        REDTEAM_VPS_KEY   = $vpsKey
    }
    notes                = 'Windows .cmd wrappers forward to WSL. Binaries live on D:.'
    envAdaptSkip         = $false
    envAdaptConfigured   = $true
    updated_at           = (Get-Date).ToUniversalTime().ToString('o')
}
Save-JsonFile -Path $cfgPath -Object $config -NoBackup
Ok ("config written: " + $cfgPath)

# ---------------------------------------------------------------- 8. resolve
Head '8. Resolve check  (the 0/15 killer)'

$pluginCfg = Join-Path $script:WS.DshHome 'plugins\dsh-purge\lib\redteam\platform-config.js'
if (Test-Path $pluginCfg) {
    $uri = ([Uri]$pluginCfg).AbsoluteUri
    $js = @"
import { pathToFileURL } from 'node:url';
const m = await import('$uri');
const r = m.resolveAllTools();
let ok = 0;
for (const x of r) { if (x.path) ok++; else console.log('   MISSING ' + x.id); }
console.log('   RESULT ' + ok + '/' + r.length);
"@
    $tmp = Join-Path $env:TEMP ('resolve_' + [guid]::NewGuid().ToString('N') + '.mjs')
    Write-Utf8NoBom -Path $tmp -Content $js
    $out = & node $tmp 2>&1
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    foreach ($line in $out) {
        if ($line -match 'RESULT') { Ok $line.Trim() } else { Info $line.Trim() }
    }
    $resolved = ($out | Where-Object { $_ -match 'RESULT' }) -replace '.*RESULT\s*', ''
    if ($resolved -match '^(\d+)/(\d+)$') {
        $got = [int]$Matches[1]; $total = [int]$Matches[2]
        Add-Report -Item 'dsh-purge resolve' -State $(if ($got -eq $total) { 'ok' } else { 'warn' }) -Detail "$got/$total"
    }
} else {
    Warn 'dsh-purge platform-config.js not found'
    Info 'Install dsh-purge into the desktop profile first (step 1).'
    Add-Report -Item 'dsh-purge resolve' -State 'skip'
}

# ---------------------------------------------------------------- 9. smoke
Head '9. Smoke test  (each tool really runs)'

$smoke = 0
$total = 0
foreach ($id in $Catalog.Keys) {
    $cmdFile = Join-Path $Bin ($id + '.cmd')
    if (-not (Test-Path $cmdFile)) { continue }
    $total++
    $probe = @()
    foreach ($flag in @('--version','-version','-V','-h','--help')) {
        $probe = & cmd /c "`"$cmdFile`" $flag" 2>&1 | Select-Object -First 1
        if ($probe) { break }
    }
    if ($probe) { $smoke++; Write-Host ('   [ok]  ' + $id) -ForegroundColor Green }
    else        { Write-Host ('   [!!]  ' + $id + '  no response') -ForegroundColor Yellow }
}
Add-Report -Item 'tool smoke test' -State $(if ($smoke -eq $total -and $total -gt 0) { 'ok' } else { 'warn' }) -Detail "$smoke/$total"

# ---------------------------------------------------------------- report
Show-Report
Write-Host ''
Info 'Next: step 3 (phone access).'
exit 0
