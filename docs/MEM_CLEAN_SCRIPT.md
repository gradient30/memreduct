# MEM.REDUCT 内存清理脚本接入指南

> `scripts/mem-clean.ps1` — 把本项目的清理方案（与 `bin/64/memreduct.exe --clean` 完全同源的 NT 层机制）抽成了**零依赖、可被任意项目调用**的独立脚本。
> 适用于：Web 后端、CI/CD、定时任务、运维脚本、任何能起子进程或触发计划任务的环境。

- 依赖：仅 Windows PowerShell 5.1+（系统自带），无需安装任何组件
- 权限：需要管理员令牌（脚本内部自动启用 `SeProfileSingleProcessPrivilege` / `SeIncreaseQuotaPrivilege`）
- 平台：Windows 10/11（注册表缓存需 Win8.1+，合并内存列表需 Win10+，低于时自动标记 `skipped`）

---

## 1. 快速开始

```powershell
# 管理员 PowerShell — 默认区域清理（0xE7，同 GUI 默认），人类可读输出
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mem-clean.ps1
```

```powershell
# 全部 8 个区域 + 单行 JSON 输出（stdout 纯 JSON，UTF-8）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\mem-clean.ps1 -All -Json
```

实测输出示例（本机 48GB 内存）：

```json
{"ok":true,"elevated":true,"mask":255,"maskHex":"0xFF","beforeGB":38.02,"afterGB":31.47,
 "freedGB":7,"memLoadBefore":79,"memLoadAfter":65,"durationMs":25676,"failedCount":0,
 "regions":{"workingSet":{"state":"success","status":"0x00000000","note":""},
            "systemFileCache":{"state":"success","status":"0x00000000","note":""},
            "modifiedFileCache":{"state":"success","status":"0x00000000","note":"flushed 7/8 volumes"},
            "modifiedList":{"state":"success","status":"0x00000000","note":""},
            "standbyList":{"state":"success","status":"0x00000000","note":""},
            "standbyPriority0":{"state":"success","status":"0x00000000","note":""},
            "registryCache":{"state":"success","status":"0x00000000","note":""},
            "combineMemoryLists":{"state":"success","status":"0x00000000","note":""}},"ts":1791377223309}
```

> 本机已实测（2026-10-07，Win10 19045 / 48GB）：全区域清理释放 7 GB；计划任务桥非提权触发释放 2 GB；webui HTTP 调用释放 1 GB。三次均为 8 区域 0 失败。

## 2. 清理了什么（与 exe 同源）

| 区域 | mask 位 | 底层机制 | 说明 |
|---|---|---|---|
| 工作集 | `0x01` | `NtSetSystemInformation(SystemMemoryListInformation, MemoryEmptyWorkingSets)` | 清空所有进程工作集 |
| 系统文件缓存 | `0x02` | `NtSetSystemInformation(SystemFileCacheInformationEx, {MAXSIZE_T, MAXSIZE_T})` | 收缩系统文件缓存 |
| 备用列表优先级 0 | `0x04` | `MemoryPurgeLowPriorityStandbyList` | 丢弃低优先级预取页 |
| 备用列表 | `0x08` | `MemoryPurgeStandbyList` | 丢弃全部缓存页（激进，触发磁盘重读） |
| 已修改列表 | `0x10` | `MemoryFlushModifiedList` | 脏页写回磁盘 |
| 合并内存列表 | `0x20` | `NtSetSystemInformation(SystemCombinePhysicalMemoryInformation)` | 合并重复物理页（Win10+） |
| 注册表缓存 | `0x40` | `NtSetSystemInformation(SystemRegistryReconciliationInformation)` | 刷新注册表 hive（Win8.1+） |
| 已修改文件缓存 | `0x80` | 枚举全部卷 → `FlushFileBuffers` 逐卷刷新 | 卷缓存落盘 |

默认 `-Mask 0xE7`（= exe 的 `REDUCT_MASK_DEFAULT`，不含 `0x08`/`0x10` 两个激进项）；`-All` = `0xFF`。

## 3. 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Mask <int>` | `-1` → `0xE7` | 区域位掩码（见上表）；`0` 合法 = 只测状态不清理 |
| `-Regions <names>` | — | 逗号分隔区域名：`ws,cache,sb0,sb,mod,combine,reg,mfc`（提供时优先于 `-Mask`），支持别名如 `workingset`/`standby` |
| `-All` | — | 全部区域（0xFF），优先于 `-Mask`/`-Regions` |
| `-Json` | 关 | 单行 JSON 到 stdout（stdout 无任何其它输出） |
| `-Quiet` | 关 | 不输出人类可读日志 |
| `-ResultFile <path>` | — | JSON 结果原子写入该文件（UTF-8 无 BOM）——供跨进程/计划任务回传 |

## 4. 退出码与 JSON 字段

退出码：`0` 成功（无失败区域）· `2` 未以管理员运行 · `3` 部分区域失败 · `4` 参数/环境错误

JSON 字段：`ok` · `elevated` · `mask`/`maskHex` · `beforeGB`/`afterGB`/`freedGB` · `memLoadBefore`/`memLoadAfter` · `durationMs` · `failedCount` · `regions.<名>.{state,status,note}`（state ∈ `success|failed|skipped|not_run`，status 为 NTSTATUS 十六进制）· `ts`（Unix 毫秒）

## 5. 各语言调用示例

### Python

```python
import json, subprocess

def mem_clean(all_regions=True):
    p = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
         "-File", r"D:\path\to\memreduct\scripts\mem-clean.ps1"]
        + (["-All"] if all_regions else []) + ["-Json"],
        capture_output=True, timeout=180)
    return json.loads(p.stdout.decode("utf-8")), p.returncode

result, code = mem_clean()
if code == 2:
    raise PermissionError("需要管理员权限运行")
print(f"释放 {result['freedGB']} GB, 用时 {result['durationMs']} ms")
```

### Node.js

```javascript
const { execFile } = require('child_process');

execFile('powershell.exe', [
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', 'D:\\path\\to\\memreduct\\scripts\\mem-clean.ps1', '-All', '-Json'
], { timeout: 180000, maxBuffer: 1 << 20 }, (err, stdout) => {
  if (stdout) {
    const r = JSON.parse(stdout); // 注意按 UTF-8 解码（默认即 UTF-8）
    console.log(`释放 ${r.freedGB} GB, 失败区域 ${r.failedCount}`);
  } else {
    console.error('执行失败:', err.message);
  }
});
```

### Java

```java
ProcessBuilder pb = new ProcessBuilder("powershell.exe", "-NoProfile",
    "-ExecutionPolicy", "Bypass", "-File",
    "D:\\path\\to\\memreduct\\scripts\\mem-clean.ps1", "-All", "-Json");
pb.redirectErrorStream(false);
Process p = pb.start();
String json = new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
int code = p.waitFor(); // 0=成功 2=未提权 3=部分失败 4=参数错误
```

### CI（GitHub Actions / Jenkins Windows 节点等，以管理员服务账户运行时）

```yaml
- run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mem-clean.ps1 -All -Json
  shell: powershell
```

## 6. Web / 非提权服务调用（计划任务桥）

**问题**：`NtSetSystemInformation` 清理需要管理员令牌；Web 服务通常非提权运行，直接调 exe/脚本只会得到"无权限"。

**方案**：一次性注册一个 `RunLevel=Highest` 的计划任务，之后任何非提权进程触发它即可获得真实清理，无 UAC 弹窗、无需存储密码：

```powershell
# 管理员 PowerShell 运行一次（安装 + 自动冒烟测试）
powershell -ExecutionPolicy Bypass -File scripts\install_clean_task.ps1 -Test

# 可选：同时接管每日 23:00 定时清理（重建为真正生效的 Highest 任务）
powershell -ExecutionPolicy Bypass -File scripts\install_clean_task.ps1 -Daily 23:00

# 卸载
powershell -ExecutionPolicy Bypass -File scripts\install_clean_task.ps1 -Uninstall
```

之后在任意非提权进程中触发并取结果：

```powershell
$old = if (Test-Path 'C:\ProgramData\memreduct\clean-result.json') {
    (Get-Content 'C:\ProgramData\memreduct\clean-result.json' -Raw | ConvertFrom-Json).ts } else { 0 }
schtasks /run /tn MemReduct-Clean          # 触发（无需管理员）
do { Start-Sleep -m 500; $r = Get-Content 'C:\ProgramData\memreduct\clean-result.json' -Raw | ConvertFrom-Json }
until ($r.ts -gt $old)                      # 轮询结果文件（首次出现也满足）
"释放 {0} GB" -f $r.freedGB
```

> 注意：`schtasks /run` 只触发不等待、不回传 stdout；结果一律通过 `clean-result.json` 的 `ts` 字段变化判断新一轮完成。触发后脚本典型耗时 3–30 秒（视内存量），建议轮询上限 150 秒。
> 任务以当前登录用户的 Interactive 会话运行；用户未登录时无法触发成功。

### 本项目 webui（现成示例）

`webui/server.ps1` 的 `POST /api/clean` 按以下顺序选择执行方式：

1. 服务进程已提权 → 直接执行 `mem-clean.ps1`（`mode=direct`）
2. 存在计划任务桥 → `Start-ScheduledTask` + 轮询结果文件（`mode=task`，非提权可用）
3. 本机同源页面且没有计划任务桥 → 请求 Windows 管理员授权后运行脚本（`mode=uac`，每次需确认）
4. 回退 `memreduct.exe --clean`（`mode=exe`，仅服务提权时有效）

UAC 授权窗口显示在运行服务的 Windows 桌面上；远程或跨源请求需使用计划任务桥或已提权的服务。

```bash
curl -X POST http://127.0.0.1:8765/api/clean
# {"ok":true,"mode":"task","beforeGB":23.62,"afterGB":22.13,"freedGB":1,...}
```

## 7. 稳定性设计

- **不会假报成功**：未提权立即返回 `ok=false` + 退出码 `2`，绝不把"没清成"当"清完了"（旧 `MemReduct-DailyClean` 任务即因 `RunLevel=Limited` 静默无效，被 `-Daily` 重建修复）
- **逐区域 NTSTATUS 上报**：每个区域独立 `success/failed/skipped/not_run`，单区域失败不影响其余区域（与 exe `_app_memoryclean` 行为一致）
- **stdout 纯净**：`-Json` 模式 stdout 仅一行 JSON，且强制 UTF-8 输出，跨语言解析无乱码
- **结果文件原子写**：`-ResultFile` 先写 `.tmp` 再 rename，读取方不会看到半截 JSON
- **stdout 编码/并发**：计划任务 `MultipleInstances=IgnoreNew` 防并发重入；执行限时 10 分钟
- **资源占用**：常驻为零（无进程/无服务），每次调用起一个 PowerShell 进程（约 1–3 秒开销 + 清理耗时），适合低频按需场景，不适合 >1 次/分钟的高频轮询

## 8. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 退出码 2 | 调用进程不是管理员 → 用 §6 计划任务桥 |
| `standbyList` 返回 `0xC0000022` | 令牌无 `SeProfileSingleProcessPrivilege`，确认以管理员运行 |
| `freedGB` 为 0 且全部 success | 当前本无可释放内存（正常）；或刚清理过（备用列表已空） |
| 卷刷新 `flushed N-1/N` | 有一卷无文件系统/未挂载，属正常（`regions.modifiedFileCache.note` 有明细） |
| 清理后短时变卡 | 备用列表（0x08）清空导致后续磁盘重读，属预期代价；默认 mask 已排除该项 |
| `Add-Type 编译失败` | 极少数裁剪系统缺 .NET 编译器；用官方完整版 Windows 或改走 exe |
