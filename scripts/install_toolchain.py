#!/usr/bin/env python3
"""把红队工具链装到 D:\security-tools\（WSL 侧 /mnt/d/security-tools/）。
不依赖 unzip / sudo。"""
import json, os, subprocess, sys, zipfile, tarfile, io, urllib.request, shutil, stat

BASE = "/mnt/d/security-tools"
BIN  = os.path.join(BASE, "bin")
TMP  = os.path.join(BASE, "tmp")
os.makedirs(BIN, exist_ok=True)
os.makedirs(TMP, exist_ok=True)

def gh_latest(repo):
    try:
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",
                                     headers={"User-Agent": "curl/8"})
        j = json.load(urllib.request.urlopen(req, timeout=25))
        return j["tag_name"]
    except Exception as e:
        print(f"    [{repo}] 取版本失败: {e}")
        return None

def download(url, dest):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
        with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
        return os.path.getsize(dest)
    except Exception as e:
        print(f"    下载失败: {e}")
        return 0

def extract_member(archive, names, outname):
    """从 zip/tar 里找出名为 names 中任一者的文件，放到 BIN/outname。"""
    target = os.path.join(BIN, outname)
    try:
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as z:
                for n in z.namelist():
                    if os.path.basename(n) in names and not n.endswith("/"):
                        with z.open(n) as src, open(target, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        os.chmod(target, 0o755)
                        return os.path.getsize(target)
        else:
            with tarfile.open(archive) as t:
                for m in t.getmembers():
                    if os.path.basename(m.name) in names and m.isfile():
                        f = t.extractfile(m)
                        with open(target, "wb") as dst:
                            shutil.copyfileobj(f, dst)
                        os.chmod(target, 0o755)
                        return os.path.getsize(target)
    except Exception as e:
        print(f"    解压失败: {e}")
    return 0

# (输出名, repo, release 文件模板, 归档内候选名)
JOBS = [
    ("nuclei",    "projectdiscovery/nuclei",    "nuclei_{v}_linux_amd64.zip",   ["nuclei"]),
    ("httpx",     "projectdiscovery/httpx",     "httpx_{v}_linux_amd64.zip",    ["httpx"]),
    ("dnsx",      "projectdiscovery/dnsx",      "dnsx_{v}_linux_amd64.zip",     ["dnsx"]),
    ("subfinder", "projectdiscovery/subfinder", "subfinder_{v}_linux_amd64.zip",["subfinder"]),
    ("fscan",     "shadow1ng/fscan",            "fscan_{v}_linux_amd64.zip",    ["fscan"]),
    ("gogo",      "chainreactors/gogo",         "gogo_{v}_linux_amd64.tar.gz",  ["gogo"]),
    ("suo5",      "zema1/suo5",                 "suo5-{v}-linux-amd64.tar.gz",  ["suo5","suo5-linux-amd64"]),
    ("chisel",    "jpillora/chisel",            "chisel_{v}_linux_amd64.gz",    ["chisel_linux_amd64","chisel"]),
    ("ffuf",      "ffuf/ffuf",                  "ffuf_{v}_linux_amd64.tar.gz",  ["ffuf"]),
    ("ksubdomain","boy-hack/ksubdomain",        "ksubdomain_{v}_linux_amd64.zip",["ksubdomain"]),
]

print("=== 下载安装 ===")
for name, repo, tpl, cands in JOBS:
    out = os.path.join(BIN, name)
    if os.path.exists(out) and os.path.getsize(out) > 1_000_000:
        print(f"  {name:<12} 已存在 {os.path.getsize(out):>12,} 字节")
        continue
    tag = gh_latest(repo)
    if not tag:
        continue
    v = tag.lstrip("v")
    url = f"https://github.com/{repo}/releases/download/{tag}/" + tpl.format(v=v)
    arc = os.path.join(TMP, os.path.basename(url))
    sz = download(url, arc)
    if not sz:
        continue
    if url.endswith(".gz") and not url.endswith(".tar.gz"):
        import gzip
        try:
            with gzip.open(arc, "rb") as s, open(out, "wb") as d:
                shutil.copyfileobj(s, d)
            os.chmod(out, 0o755)
            print(f"  {name:<12} OK  {os.path.getsize(out):>12,} 字节")
            continue
        except Exception as e:
            print(f"  {name:<12} gz 解压失败 {e}")
            continue
    got = extract_member(arc, cands, name)
    print(f"  {name:<12} " + (f"OK  {got:>12,} 字节" if got else "失败"))
    try: os.remove(arc)
    except: pass

print()
print("=== 汇总 ===")
for f in sorted(os.listdir(BIN)):
    p = os.path.join(BIN, f)
    print(f"  {f:<14} {os.path.getsize(p):>12,} 字节")
