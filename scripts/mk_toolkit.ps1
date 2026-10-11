$ErrorActionPreference = 'Continue'
$TK    = 'C:\Users\YOURUSER\.dsh\redteam\toolkit'
$SRC   = 'D:\security-tools\bin'
New-Item -ItemType Directory -Path $TK -Force | Out-Null

# setup.sh 期望的子目录名 -> 该目录里应有的二进制名
$map = @{
  'nuclei'      = 'nuclei'
  'httpx'       = 'httpx'
  'dnsx'        = 'dnsx'
  'subfinder'   = 'subfinder'
  'naabu'       = 'naabu'
  'fscan'       = 'fscan'
  'gogo'        = 'gogo'
  'suo5'        = 'suo5'
  'chisel'      = 'chisel'
  'ffuf'        = 'ffuf'
  'ksubdomain'  = 'ksubdomain'
  'gowitness'   = 'gowitness'
  'frp'         = 'frpc'
  'ligolo'      = 'proxy'
  'nmap'        = 'nmap'
  'masscan'     = 'masscan'
}

# 每个工具建一个独立目录，里面用 junction 指向 D 盘的真实二进制
foreach ($k in $map.Keys) {
  $binName = $map[$k]
  $srcFile = Join-Path $SRC $binName
  $dir     = Join-Path $TK $k
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $link    = Join-Path $dir $binName
  if (Test-Path $link) { Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue }
  if (Test-Path $srcFile) {
    New-Item -ItemType SymbolicLink -Path $link -Target $srcFile -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path $link)) { Copy-Item $srcFile $link -Force -ErrorAction SilentlyContinue }
    Write-Output ("  $k/$binName")
  } else {
    Write-Output ("  $k/$binName  -- 源缺失")
  }
}

# frp 目录里还要有 frps
$frpsSrc = Join-Path $SRC 'frps'
$frpsLnk = Join-Path (Join-Path $TK 'frp') 'frps'
if (Test-Path $frpsSrc) {
  if (Test-Path $frpsLnk) { Remove-Item $frpsLnk -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType SymbolicLink -Path $frpsLnk -Target $frpsSrc -ErrorAction SilentlyContinue | Out-Null
  if (-not (Test-Path $frpsLnk)) { Copy-Item $frpsSrc $frpsLnk -Force -ErrorAction SilentlyContinue }
  Write-Output "  frp/frps"
}

# suo5 的特殊名字
$suo5Alt = Join-Path (Join-Path $TK 'suo5') 'suo5-linux-amd64'
if (Test-Path (Join-Path $SRC 'suo5')) {
  if (Test-Path $suo5Alt) { Remove-Item $suo5Alt -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType SymbolicLink -Path $suo5Alt -Target (Join-Path $SRC 'suo5') -ErrorAction SilentlyContinue | Out-Null
  if (-not (Test-Path $suo5Alt)) { Copy-Item (Join-Path $SRC 'suo5') $suo5Alt -Force -ErrorAction SilentlyContinue }
  Write-Output "  suo5/suo5-linux-amd64"
}

# ligolo: proxy + agent
foreach ($n in @('proxy','agent')) {
  $s = Join-Path $SRC ("ligolo-" + $n)
  $l = Join-Path (Join-Path $TK 'ligolo') $n
  if (Test-Path $s) {
    if (Test-Path $l) { Remove-Item $l -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType SymbolicLink -Path $l -Target $s -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path $l)) { Copy-Item $s $l -Force -ErrorAction SilentlyContinue }
    Write-Output "  ligolo/$n"
  }
}
