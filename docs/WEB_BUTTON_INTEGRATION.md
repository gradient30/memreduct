# WEB 页面接入内存清理按钮 · 技术文档

> 目标读者：**另一个项目**的开发者——想在你们自己的 web 页面上放一个「清理内存」按钮，点击后对指定 Windows 机器执行**真实的** MEM.REDUCT 同源清理（`NtSetSystemInformation` 全套机制）。
>
> 本文所有代码与结论均已在本机真实验证（Win10 19045 / Chrome headless / 48GB 内存），验证记录见 §8。

---

## 1. 架构与选型

清理能力位于目标 Windows 机器上，共三层，你的项目按场景任选其一：

```
┌─ 你的项目页面 (任意端口/域名) ─────────────────────────────┐
│                                                            │
│  [方式 A] 纯前端直连            [方式 B] 后端代理           │
│      fetch ──────────┐           页面 → 你的后端 ──┐        │
│                       ▼                            │        │
│              http://127.0.0.1:8765  ◄──────────────┤        │
│              (MEM.REDUCT webui 服务)               │        │
│                       │                            │        │
│                       ▼                            ▼        │
│              [方式 C] 计划任务桥 MemReduct-Clean (schtasks) │
│                       │                                     │
│                       ▼                                     │
│              scripts\mem-clean.ps1 (提权, NT 层真实清理)     │
└────────────────────────────────────────────────────────────┘
```

| 方式 | 你的项目需要 | 适用场景 | 推荐度 |
|---|---|---|---|
| **A. 纯前端直连** | 页面在目标机器浏览器打开，或页面为 localhost/公网 HTTPS（见 §7） | 无后端 / 快速接入 | ⭐⭐⭐⭐⭐ |
| **B. 后端代理** | 你的后端能网络访问目标机器（同机或局域网/Tailnet） | 页面部署在其它设备；需要鉴权/审计 | ⭐⭐⭐⭐ |
| **C. 计划任务桥直连** | 你的后端跑在目标 Windows 机器上，不想启动 webui | 已有自己的后端服务 | ⭐⭐⭐ |

## 2. 目标机器前置条件（一次性，3 步）

```powershell
# ① 安装清理能力 + 计划任务桥（管理员 PowerShell，一次即可；-Test 会立即真清理一次以自检）
powershell -ExecutionPolicy Bypass -File <仓库路径>\scripts\install_clean_task.ps1 -Test

# ② 启动 webui 监控服务（方式 A/B 需要；方式 C 不需要）
powershell -NoProfile -ExecutionPolicy Bypass -File <仓库路径>\webui\server.ps1

# ③（仅远程设备访问时）放行防火墙（管理员，一次）
powershell -ExecutionPolicy Bypass -File <仓库路径>\webui\add_firewall_rule.ps1
```

**自检**（任何机器上）：

```bash
curl -X POST http://127.0.0.1:8765/api/clean
# 期待: {"ok":true,"mode":"task","freedGB":...}
```

> webui 服务无需管理员启动。已有计划任务桥时通过它触发清理；没有桥时，本机监控页面会请求 Windows 管理员授权。跨源或远程调用需使用计划任务桥或已提权的服务。

## 3. 方式 A · 纯前端直连（推荐）

webui 已内置 CORS（预检 OPTIONS 204 + `Access-Control-Allow-Origin`），**任意来源的页面可直接 fetch**。以下为已验证的标准接入代码：

### 3.1 核心 JS（可直接放进任意页面）

```javascript
/**
 * MEM.REDUCT 内存清理
 * @param {string} base 目标服务地址，默认本机
 * @returns {Promise<{ok:boolean, mode:string, freedGB:number, beforeGB:number, afterGB:number, durationMs:number, err?:string}>}
 */
async function memClean(base = 'http://127.0.0.1:8765') {
  const resp = await fetch(base + '/api/clean', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },  // 触发 CORS 预检, 服务端已支持
    body: '{}'
  });
  if (!resp.ok) throw new Error('HTTP ' + resp.status);
  return resp.json();
}
```

### 3.2 完整按钮组件（含加载态/结果/错误处理，即本文验证所用代码）

```html
<button id="btnClean">清理内存</button>
<div id="cleanOut"></div>

<script>
async function onCleanClick(button, output) {
  const old = button.textContent;
  button.disabled = true;
  button.textContent = '清理中…';
  output.textContent = '请求已发出, 等待结果 (清理通常 3–30 秒)…';
  try {
    const r = await memClean('http://127.0.0.1:8765');
    if (!r.ok) {
      output.textContent = '清理失败: ' + (r.err || '未知错误');
    } else {
      output.textContent = `✅ 清理成功 · 释放 ${r.freedGB} GB（${r.beforeGB} → ${r.afterGB} GB，${r.durationMs} ms）`;
    }
  } catch (e) {
    output.textContent = '❌ 无法连接清理服务: ' + e.message + '（确认 webui\\server.ps1 已在目标机器运行）';
  } finally {
    button.disabled = false;
    button.textContent = old;
  }
}
document.getElementById('btnClean').addEventListener('click', function () {
  onCleanClick(this, document.getElementById('cleanOut'));
});
</script>
```

### 3.3 框架适配

- **React**：`onClick={async () => { const [busy, setBusy] = useState(false); … }}`，`memClean()` 原样放 `lib/memclean.js` 导入即可。
- **Vue**：`methods: { async clean() { this.result = await memClean(); } }`。
- 别在 `fetch` 外再包一层 30 秒短超时——真实清理最长 150 秒（服务端上限），见 §7 排查表。

### 3.4 附赠：内存/CPU 状态展示（可选）

```javascript
const stats = await (await fetch('http://127.0.0.1:8765/api/stats')).json();
// stats.memPct / stats.memUsedGB / stats.memTotalGB / stats.cpu / stats.ts
```

## 4. 方式 B · 后端代理

你的后端能访问目标机器（同机 `127.0.0.1:8765`，或远程 `<tailscale-ip>:8765`）。后端转发请求，页面只同源调你自己的后端——无 CORS、可加鉴权审计。

**Node (Express)**：

```javascript
const express = require('express');
const app = express();

const TARGET = 'http://127.0.0.1:8765'; // 或目标机器的 Tailscale IP

app.post('/api/mem-clean', async (_req, res) => {
  try {
    const r = await fetch(TARGET + '/api/clean', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
      signal: AbortSignal.timeout(160000)
    });
    res.status(r.status).json(await r.json());
  } catch (e) {
    res.status(502).json({ ok: false, err: '目标清理服务不可达: ' + e.message });
  }
});
app.listen(3000);
```

**Python (Flask)**：

```python
import requests
from flask import Flask, jsonify

app = Flask(__name__)
TARGET = "http://127.0.0.1:8765"

@app.post("/api/mem-clean")
def mem_clean():
    try:
        r = requests.post(TARGET + "/api/clean", json={}, timeout=160)
        return jsonify(r.json()), r.status_code
    except requests.RequestException as e:
        return jsonify(ok=False, err=f"目标清理服务不可达: {e}"), 502
```

后端代理的另一个用途：**后端直接跑在目标 Windows 机器上时**，可以不走 webui，改调脚本本身（拿到更细的逐区域结果）：

```python
p = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", r"<仓库路径>\scripts\mem-clean.ps1", "-All", "-Json"],
                   capture_output=True, timeout=180)
result = json.loads(p.stdout.decode("utf-8"))
```

## 5. 方式 C · 计划任务桥直连（不依赖 webui）

只要执行过 `install_clean_task.ps1`，任何跑在目标机器上的后端（任意语言）都可用 `schtasks` 触发，通过结果文件 `ts` 字段变化取回结果：

```
1. 读 C:\ProgramData\memreduct\clean-result.json 记下当前 ts（无文件则记 0）
2. 执行: schtasks /run /tn MemReduct-Clean        （非提权进程即可，无需 UAC）
3. 每 0.5s 重读该文件, 直到 ts > 步骤1的值 或超时 150s
4. 解析 JSON: ok / freedGB / beforeGB / afterGB / durationMs / failedCount / regions.*
```

```python
import json, time, subprocess, pathlib

RESULT = pathlib.Path(r"C:\ProgramData\memreduct\clean-result.json")

def read():
    try: return json.loads(RESULT.read_text(encoding="utf-8"))
    except Exception: return None

def clean(timeout=150):
    old_ts = (read() or {}).get("ts", 0)
    subprocess.run(["schtasks", "/run", "/tn", "MemReduct-Clean"], check=True,
                   capture_output=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.5)
        r = read()
        if r and r.get("ts", 0) > old_ts:
            return r
    raise TimeoutError("清理任务 150s 内未返回结果")
```

## 6. API 契约

### `POST /api/clean`

| 字段 | 类型 | 说明 |
|---|---|---|
| `ok` | bool | `false` 时看 `err` |
| `mode` | string | `direct`（webui 已提权直跑脚本）/ `task`（计划任务桥）/ `uac`（本机授权）/ `exe`（回退）/ `none`（不可用） |
| `beforeGB` / `afterGB` / `freedGB` | number | 清理前后已用内存与释放量 |
| `durationMs` | int | 清理耗时 |
| `detail.maskHex` | string | 本次清理的区域掩码（默认 `0xE7`） |
| `detail.regions.<区域>` | object | 8 个区域各自的 `state`(`success/failed/skipped/not_run`)、`status`(NTSTATUS hex)、`note` |
| `detail.failedCount` | int | 失败区域数 |
| `err` | string | 失败原因（含修复指引） |

其余接口：`GET /api/stats`（CPU/内存，2s 缓存）· `GET /api/temp`（温度传感器）· `GET /api/drive`（磁盘）。均为 CORS 放行的 JSON。

### 服务端配置（`webui/server.ps1` 顶部）

```powershell
$Port       = 8765                     # 端口
$CorsOrigins = @('*')                  # 跨源白名单; 收紧示例: @('http://localhost:3000','https://myapp.example.com')
$ApiKey      = ''                      # 非空时 /api/* 需带头 X-Api-Key 或 ?key=
```

## 7. 安全与浏览器策略（接入前必读）

1. **默认 CORS 全开（`*`）**：便于其他页面接入，但也允许跨源页面读取监控数据；服务已提权或安装清理任务桥时，跨源页面还可能触发内存清理。
2. **CORS 不是身份验证**：`$CorsOrigins` 控制浏览器读取响应和预检，不会阻止所有跨源简单 POST。仅收紧来源白名单不足以保护清理接口。
3. **API Key**：设置 `$ApiKey = '你的密钥'` 后，所有 `/api/*` 调用均需携带密钥，例如：
   ```javascript
   headers: { 'Content-Type': 'application/json', 'X-Api-Key': '你的密钥' }
   ```
   内置监控页面目前没有密钥输入功能；启用后需同时调整可信调用端以携带密钥，改完重启 server.ps1。
4. **HTTPS 页面调本机 HTTP 服务**：现代浏览器（Chrome/Edge/Firefox）将 `http://127.0.0.1`、`http://localhost` 视为可信来源，**公网 HTTPS 页面可直接调用，不会被判 mixed content**。服务端已支持 Private Network Access 预检（`Access-Control-Allow-Private-Network: true`）。
5. **远程地址（Tailscale IP）没有此豁免**：HTTPS 页面直连 `http://100.x.x.x:8765` 会被 mixed content 拦截——远程场景请用方式 B（后端代理）。
6. **服务绑定范围**：服务监听回环以及本机 `100.64.0.0/10` 段的 IPv4 地址。若其他网卡也使用此地址段，它们同样会被监听；Tailnet 入站需一次性放行防火墙。

## 8. 真实验证记录（2026-10-07 · Win10 19045 · 48GB · Chrome 138 headless）

| # | 验证项 | 结果 |
|---|---|---|
| 1 | CORS 预检 `OPTIONS /api/clean`（Origin: localhost:9090） | `204` + `Allow-Origin/Methods/Headers/Max-Age` ✓ |
| 2 | PNA 预检（Origin: https://myapp.example.com + Private-Network: true） | 追加 `Access-Control-Allow-Private-Network: true` ✓ |
| 3 | 跨源 `POST /api/clean`（curl） | `mode=task`，释放 **4 GB**（29.58→25.27，9.4s，0 失败）✓ |
| 4 | **真实浏览器跨源按钮**：`localhost:9090` 页面 → Chrome headless 点击 → `127.0.0.1:8765` | 页面显示 `✅ 跨源清理成功 mode=task 释放 1 GB` ✓ |
| 5 | 跨源 `GET /api/stats` | 200 + CORS 头 ✓ |
| 6 | 提权直跑脚本 `-All`（§4 底层路径） | 8 区域全 success，释放 **7 GB** ✓ |

## 9. 故障排查

| 现象 | 原因 → 处理 |
|---|---|
| 页面报 `Failed to fetch` / TypeError | webui 未启动（目标机器跑 `webui\server.ps1`）或端口不对 |
| 预检 403 `origin not allowed` | `$CorsOrigins` 白名单未含你的页面来源 → 加上后重启服务 |
| 响应 401 `invalid api key` | 服务端启用了 `$ApiKey` → 前端带 `X-Api-Key` 头 |
| `mode=none` + 提示未就绪 | 本机页面可通过 Windows 授权清理；跨源或远程调用需安装计划任务桥或以管理员启动服务 |
| `ok=false, err=计划任务已触发但…未返回结果` | 任务被占用或脚本执行超 150s → 查任务状态 `Get-ScheduledTask MemReduct-Clean`，稍后重试 |
| `freedGB=0` 但 `ok=true` | 当前无可释放内存（正常现象，通常刚清理过） |
| 清理后短暂卡顿 | 备用列表被清空的预期代价；默认 mask（0xE7）已排除该项，被 `-All`/改 mask 打开后才会出现 |
| HTTPS 页面直连 Tailscale IP 失败 | mixed content 限制 → 改用方式 B 后端代理 |
| 远程设备打不开 8765 | 防火墙未放行 → 管理员跑 `webui\add_firewall_rule.ps1` |

---

**相关文档**：清理脚本本体与 CLI 接入 → [docs/MEM_CLEAN_SCRIPT.md](MEM_CLEAN_SCRIPT.md) · 本机监控台 → [webui/server.ps1](../webui/server.ps1)
