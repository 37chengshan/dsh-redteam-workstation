# 01 · 安装插件到官方 DSH Desktop

> 本文解决最容易踩坑的一环：**插件装好了、在 bundles 里、但就是不加载**。

---

## 前置：搞清楚是哪一套 DSH

Windows 上常同时存在多个 DSH 安装，**它们的 `DSH_HOME` 不同、profile 不同、核心版本也不同**。

| 发行版 | 安装位置 | `DSH_HOME` | profile 名 | 核心版本 |
|---|---|---|---|---|
| **官方版** ✅ | `D:\dsh\` | `~/.dsh` | `desktop` | `0.2.0-rc.2` |
| 社区版 | `D:\Program Files\DSH Desktop\` | `%APPDATA%\dsh-desktop\harness` | `web` | `0.1.5-rc.2` |

**怎么判断自己在用哪个：**

```powershell
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
  Select-Object ProcessId, CommandLine |
  Format-List
```

输出里会带 `--expose-internals <app路径> <profile路径>` —— 那就是实际的 profile。

> ⚠️ **社区版不适用本文**：它的核心是 0.1.5，装不了为 0.2 编译的插件；且 dsh-purge 的 README 明确写「社区桌面端暂不维护」。

---

## 1. 部署插件

插件的两个必要位置：

```
~/.dsh/profiles/desktop/
  ├─ package.json          ← dependencies + dsh.profile.bundles
  └─ node_modules/
       ├─ dsh-purge/       ← 实体或 junction
       └─ dsh-infinite-gen-4/
```

### 1.1 写 dependencies

```json
{
  "dependencies": {
    "dsh-purge": "file:../../plugins/dsh-purge",
    "dsh-infinite-gen-4": "file:../../plugins/dsh-infinite-gen-4"
  }
}
```

### 1.2 写 bundles

```json
{
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "dsh-purge",
        "dsh-infinite-gen-4"
      ]
    }
  }
}
```

### 1.3 安装依赖

```bash
cd ~/.dsh/profiles/desktop
pnpm install
```

---

## 2. ⚠️ 第一大坑：客户端声明缺失 → 界面里没有图标

**症状**：插件加载了、日志没报错，但界面上**没有任何入口**（badge / 侧栏 / 设置页）。

**根因**：DSH 客户端的发现机制是读 `package.json` 的 **`dsh.client`** 字段。缺了它，客户端插件那半**永远不会注册**。

```bash
# 检查
node -e "const j=require('./node_modules/dsh-purge/package.json');
         console.log('client:', j.dsh?.client ? 'YES' : 'NO (缺失!)')"
```

**修法** —— 在插件 `package.json` 里补：

```json
{
  "dsh": {
    "client": {
      "inject": ["@deepseek-ai/dsh-client-ui-conversation"],
      "platform": "web",
      "immediately": true
    },
    "bundle": { "patch": "./cordis.patch.yml" }
  }
}
```

> `inject` 要填该插件实际用到的客户端包。可以照抄同目录下其他可用插件的写法。

---

## 3. ⚠️ 第二大坑：bundles 与 cordis.patch.yml 双重注册

**症状**：

```
duplicate loader entry id: dsh-purge
```

**根因**：桌面端通过 **`dsh.profile.bundles`** 加载插件。如果**同时**在 profile 的 `cordis.patch.yml` 里也 `insert` 了同一个插件，就注册两次。

**修法** —— **二选一**：

- ✅ **桌面端**：只留 `bundles`，删掉 `cordis.patch.yml` 里的 `insert`
- 网页端：只留 `cordis.patch.yml` 的 `insert`

查有没有重复：

```bash
grep -n "dsh-purge" ~/.dsh/profiles/desktop/cordis.patch.yml
```

有就注释掉或删掉那一段。

---

## 4. ⚠️ 第三大坑（最隐蔽）：版本兼容闸门静默跳过

**症状**：

- 插件在 `node_modules` 里 ✅
- 在 `bundles` 里 ✅
- 启动日志**零报错**
- **但功能就是不出现**（比如市场不在设置页里）

**根因**：dsh 0.2 有**插件版本兼容检查**。不满足 `peerDependencies` 的插件会被**静默跳过** —— 不报错、不警告、界面上什么都不显示。

**怎么把它逼出来** —— 前台手动跑一次 harness，看 stdout：

```powershell
# 先完全退出 DSH，然后：
cd D:\dsh
& "D:\dsh\DeepSeek Harness.exe" --expose-internals `
  "D:\dsh\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js" `
  "D:\dsh\resources\app.asar\dsh" `
  "C:\Users\<你>\.dsh\profiles\desktop" `
  "D:\dsh\resources\runtime\primary-runtime" `
  "D:\dsh\resources\runtime\pnpm\bin\pnpm.mjs" `
  "D:\dsh\resources\runtime\bin"
```

会看到类似：

```
dsh: skipping profile bundle "dshmarket": Error: Plugin dshmarket@1.47.0 is
incompatible with dsh 0.2.0-rc.2: peerDependencies
{"@deepseek-ai/dsh-settings":"^0.1.0-rc.7 || ^0.1.1-rc.2 || ^0.1.2-alpha.2"}.
To accept this risk explicitly, grant the exact-version exemption for
dshmarket@1.47.0 on dsh 0.2.0-rc.2 with `dsh plugin allow-version`...
```

### 4.1 解法 A：升级插件（首选）

去 npm 查新版是否已支持目标版本：

```bash
curl -s "https://registry.npmjs.org/dshmarket" | \
  python3 -c "import sys,json; j=json.load(sys.stdin);
lv=j['dist-tags']['latest']; v=j['versions'][lv];
print(lv, v.get('peerDependencies'))"
```

支持 0.2 的长这样：

```
1.66.15 {'@deepseek-ai/dsh-settings': '... || ^0.2.0-rc.1'}
```

升级：

```bash
cd ~/.dsh/profiles/desktop
pnpm add dshmarket@latest dsh-better-sidebar@latest ...
```

### 4.2 解法 B：版本豁免

```bash
cd D:\dsh
D:\dsh\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop `
  allow-version dshmarket@1.47.0 --dsh-version 0.2.0-rc.2 --accept-risk
```

**但要小心**：豁免只是**让加载器不拦**，插件代码里用到的 API 如果真在 0.2 里改了，运行时会炸：

```
dsh-vision-router:  pending (waiting for service: settingsScope)
dsh-loop-continue:  pending (waiting for service: settingsScope)
[modlens] scope.settings.register is not a function
```

**这类必须移除，豁免救不了。**

### 4.3 解法 C：从 bundles 移除

编辑 `~/.dsh/profiles/desktop/package.json`，把不兼容的从 `bundles` 数组里删掉（**别删 `node_modules`** —— 以后出兼容版还能加回来）。

---

## 5. ⚠️ 第四大坑：bundles 里放了没有 `dsh.bundle` 的包

**症状**：

```
dsh: skipping profile bundle "@deepseek-ai/dsh-mcp-client":
  Error: profile bundle "@deepseek-ai/dsh-mcp-client" declares no dsh.bundle
  in its package.json
```

**修法**：从 `bundles` 里移除该条目。

```bash
node -e "
const fs=require('fs'); const p=process.env.USERPROFILE+'\\\\.dsh\\\\profiles\\\\desktop\\\\package.json';
const j=JSON.parse(fs.readFileSync(p,'utf8'));
j.dsh.profile.bundles = j.dsh.profile.bundles.filter(x=>x!=='@deepseek-ai/dsh-mcp-client');
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log('已移除');
"
```

---

## 6. ⚠️ 第五大坑：MCP server 导入失败

**症状**：

```
mcp-figma (mcp-client): failed to import
```

**修法**：检查 profile 的 `cordis.patch.yml` 里有没有引用了不存在的 MCP server，删掉那段。

---

## 7. 完整验收流程

```bash
# ① 检查 package.json
node -e "
const j=require(process.env.USERPROFILE+'/.dsh/profiles/desktop/package.json');
console.log('bundles:', j.dsh.profile.bundles.length);
console.log('deps:', Object.keys(j.dependencies||{}).length);
"

# ② 检查每个插件的 dsh.client
for p in dsh-purge dsh-infinite-gen-4 dshmarket; do
  node -e "
  try{const j=require(process.env.USERPROFILE+'/.dsh/profiles/desktop/node_modules/$p/package.json');
  console.log('$p'.padEnd(24), j.version.padEnd(12), 'client=' + (j.dsh?.client?'Y':'-'));}catch(e){console.log('$p','缺失')}
  "
done

# ③ 前台跑 harness，数 skip 数量（应为 0）
& "D:\dsh\DeepSeek Harness.exe" --expose-internals ... 2>&1 | Select-String "skipping|did not activate"
```

**理想输出**：

```
[normify] dsh-normify 0.5.4 已加载：31 个 normify_* 工具 + normify-gen 技能
dsh web: http://127.0.0.1:19387/?token=...
（没有任何 skipping / did not activate）
```

---

## 8. 关于 dsh-purge 的两个特殊点

### 8.1 补丁在 `resources/app/` 但 Electron 读 `app.asar`

dsh-purge 的 `应用` 会把 `app.asar` 解开到 `resources/app/` 再打补丁。**但如果 `app.asar` 还在，Electron 优先读 asar** —— 补丁就不生效。

**检查**：

```bash
ls -la "D:/dsh/resources/" | grep -E 'asar|app$'
```

如果你看到 `app.asar`（121 MB）和 `app/` 同时存在，说明补丁**没生效**。

dsh-purge 会留 `app.dshpurge-prev-*` 备份。要让补丁生效需要把 `app.asar` 改名挪走 —— **有风险**（解包不完整会导致桌面端起不来），操作前确认备份在。

### 8.2 提示词会被界面「应用」覆盖

`$DSH_HOME/prompt-inject.md` 是你的注入提示词。但在 dsh-purge 界面点 **应用** 时，它会**把提示词框里的全文写回这个文件**。

**界面里显示的是内置默认 → 你的自定义内容就没了。**

**防护**：

```bash
# 备份当前版本
cp ~/.dsh/prompt-inject.md ~/.dsh/dsh-purge/prompt-inject.custom.md

# 一键还原脚本
cat > ~/.dsh/dsh-purge/restore.sh <<'EOF'
#!/bin/bash
cp ~/.dsh/dsh-purge/prompt-inject.custom.md ~/.dsh/prompt-inject.md
echo "已还原"
EOF
chmod +x ~/.dsh/dsh-purge/restore.sh
```

---

## 相关文档

- 工具链部署 → [02-toolchain.md](02-toolchain.md)
- 排障手册 → [06-troubleshooting.md](06-troubleshooting.md)
