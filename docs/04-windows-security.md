# 04 · Windows 安全配置

> Defender 在本机实测占用 **540.9 MB**（`MsMpEng` 单个就 484 MB）。
> 本文给三个方案，从最安全到最彻底。

---

## 三个方案

| 方案 | 效果 | 内存释放 | 可恢复 |
|---|---|---|---|
| **A 加排除项** | 只放过工具目录，防护保留 | 0 MB | — |
| **B 只关实时保护** | 全机关防护 | 部分 | 重启可能恢复 |
| **C 彻底禁用** | 服务 + 驱动 + 策略全禁 | ~478 MB | 改注册表可回 |

**A 就够解决 90% 的问题。** Defender 吃你的工具（chisel 被隔离 5 次）是因为它在扫目录，加排除即可。

---

## 方案 A：排除项

```
Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 添加或删除排除项
```

要加的目录：

```
D:\security-tools
D:\dsh
%USERPROFILE%\.dsh
%APPDATA%\dsh-desktop
%APPDATA%\@deepseek-ai
%LOCALAPPDATA%\@deepseek-ai
```

或用安装器的 `4-defender.cmd` 选 1，自动加**目录 + 进程 + 扩展名**三类排除。

**验证**：

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
```

---

## 方案 C：彻底禁用

Windows 11 从 2021 年起**忽略 `DisableAntiSpyware` 策略**，纯注册表改不干净。
必须多管齐下：

```
1. 关防篡改        HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection = 0
2. 组策略键        16 项（见脚本）
3. 停服务 + 禁启动  WinDefend / WdNisSvc / WdFilter / Sense / SecurityHealthService ...
4. 禁计划任务       \Microsoft\Windows\Windows Defender\*
5. 禁内核驱动       WdFilter / WdNisDrv / WdBoot   Start=4
6. 关通知与自动清理
7. 清空隔离区
```

跑安装器的 `4-defender.cmd` 选 3，或直接用 `scripts/disable-defender.cmd`。

> ⚠️ **必须重启** —— 服务注册表的 `Start` 值只在启动时读取。

### 常见陷阱

**① 服务停不掉**

```
sc stop WinDefend
# → 拒绝访问
```

Win11 有自我保护。正确顺序是：**先关防篡改 → 写注册表 `Start=4` → 重启**。
运行中的服务不会被立即停掉，重启后才真正不加载。

**② 计划任务状态还是 Ready**

```powershell
Get-ScheduledTask | Where-Object { $_.TaskPath -like '*Windows Defender*' } |
  Disable-ScheduledTask
```

**③ 部分服务项不存在**

`SecurityHealthService` / `wscsvc` / `MsMpSvc` / `SgrmBroker` / `SgrmAgent`
在部分版本上已被移除。脚本会跳过，不影响结果。

---

## 恢复

```powershell
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Recurse -Force
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection

foreach ($pair in @(@('WinDefend',2), @('WdNisSvc',2), @('WdFilter',1),
                    @('WdNisDrv',1), @('Sense',2), @('mpssvc',2))) {
    Set-Service $pair[0] -StartupType Automatic
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($pair[0])" -Name Start -Value $pair[1]
}
Get-ScheduledTask | Where-Object { $_.TaskPath -like '*Windows Defender*' } |
  Enable-ScheduledTask
# 然后重启
```

或跑 `4-defender.cmd` 选 4。

---

## 第三方方案

| 项目 | ⭐ | 说明 |
|---|---|---|
| [ionuttbara/windows-defender-remover](https://github.com/ionuttbara/windows-defender-remover) | 8.5k | **移除**而不只是禁用。最彻底，**基本不可逆** |
| [es3n1n/defendnot](https://github.com/es3n1n/defendnot) | 3.7k | 注册假杀软让系统自己关掉 Defender，走正规机制 |
| [AndyFul/ConfigureDefender](https://github.com/AndyFul/ConfigureDefender) | 1.6k | 只调策略等级，不卸载 |
| [Sordum Defender Control](https://www.sordum.org/9480/defender-control-v2-1/) | — | GUI 一键开关（官网，非 GitHub） |

**本项目安装器做的是「禁用」而非「移除」—— 保留可恢复性。**

---

## 实测数据

```
禁用前    540.9 MB    MsMpEng 484.9 + MpDefenderCoreService 18.6
                     + NisSrv 16.0 + SecurityHealthService 21.4

部分后    176.1 MB    （只停了部分服务，未重启）

完全后     63.3 MB    （重启后 WdFilter / WdNisDrv 不再加载）
```

净释放约 **478 MB**。
