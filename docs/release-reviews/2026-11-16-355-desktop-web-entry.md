# 发布审核记录 — 3.5.5 桌面 Web 入口

## 审核元数据

| 字段 | 内容 |
| --- | --- |
| 审核时间 | 2026-11-16T13:35:32+08:00 |
| 仓库 / 分支 | `D:\workspace_test\github_desk\memreduct` / `main` |
| 修订基线 | `7690715` 与本次桌面入口和版本修改；工作区另有未提交的 Web MagicDNS 修复 |
| 变更范围 | 桌面程序、托盘菜单、版本元数据、3.5.5 安装包 |
| 审核人 | 主审核 Agent |

## 审查档位判定依据

- 选定档位：`完整审核`。涉及安装、版本和公开发布。

## 证据清单

| 来源 | 状态 | 可证明的事项 | 链接或路径 |
| --- | --- | --- | --- |
| 用户需求 | `可用` | 隐藏托盘“关于”“项目网站”，主窗口及托盘增加 Web 首页入口，验收后发布并安装 | 本次对话 |
| 源码和资源 | `可用` | 两个入口指向 `http://127.0.0.1:8765/` | `src/main.c`、`src/resource.rc` |
| 自动化测试和安装记录 | `可用` | 本机 x64 构建、菜单资源、托盘行为、安装载荷 | `tests/test_desktop_web_entry.py`、`tests/test_tray_integration.py` |
| 托管 CI 和其他设备 | `证据缺失` | 无法据本机测试判断托管 CI 或 ARM64 硬件结果 | 无 |

## 五维审核矩阵

| 维度 | 状态 | 证据 | 发现 | 后续动作 |
| --- | --- | --- | --- | --- |
| 规格审核 | `已验证` | 菜单及对话框资源测试、两个安装版命令及浏览器标题 | 两个入口对应同一首页 | 保持 Web 服务运行 |
| 事实审核 | `已验证` | 安装程序和已安装 EXE 版本及哈希 | 均为 3.5.5，安装文件与构建载荷一致 | 上传后核验下载文件 |
| 质量审核 | `发现风险` | `Get-AuthenticodeSignature`；构建输出 | 安装包未签名；ARM64 使用 x64 回退；构建有既有 SDK 警告 | 发布说明明确支持范围 |
| 回归审核 | `已验证` | 本机托盘回归、资源测试、版本检查、安装包测试 | 具体本机检查通过；没有托管 CI 与 ARM64 硬件结果 | 后续补充目标设备验收 |
| 用户反馈审核 | `证据缺失` | 用户需求和本机验收 | 未取得用户对 3.5.5 实际使用后的反馈 | 后续收集使用反馈 |

## 已执行命令与日志

| 原始命令 | 退出码 | 原始输出 | 中文解读 |
| --- | --- | --- | --- |
| `cmd /c scripts\verify_version.bat` | 0 | `Version 3.5.5 verified` | 版本元数据一致。 |
| `python tests\test_desktop_web_entry.py build\release-355\memreduct.exe` | 0 | `PASS: compiled tray menu and main dialog contain the requested Web entry` | 编译资源满足菜单及按钮布局要求。 |
| `python tests\test_tray_integration.py --exe build\release-355-test\memreduct.exe` | 0 | `Ran 1 test in 1.639s` / `OK` | 独立测试程序验证最小化、关闭及托盘恢复。 |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_smoke_script.ps1` | 0 | `PASS: smoke script rejects missing binaries and executes fixture commands` | 冒烟测试脚本的隔离假程序检查通过。 |
| `7z t build\memreduct-3.5.5-setup.exe` | 0 | `Everything is Ok` | 安装包完整。 |
| `python tests\test_desktop_web_entry.py 'C:\Program Files\Mem Reduct\memreduct.exe'` | 0 | `PASS: compiled tray menu and main dialog contain the requested Web entry` | 安装后的程序资源检查通过。 |

安装程序退出码为 0。已安装程序 `ProductVersion` 和 `FileVersion` 为 `3.5.5`，其 SHA-256 与包内 EXE 一致：

```text
BEAF0398CF63093BAA44054DD7B2BE0C7ADE498AA0EF536DC9C6AD1D3A14E24C
```

安装包 SHA-256：

```text
91A6C87271F4F232BA714F2B186609F51DF9EA89430B0E780CBDBAD8473914E2
```

安装版 PID 51744 的主窗口存在、托盘图标已注册。分别向安装版发送两个入口的 `WM_COMMAND` 后，Chrome 显示 `MEM·REDUCT 系统监控台 - Google Chrome`；Web 首页 HTTP 200。此验证没有模拟鼠标点击托盘菜单。

## 证据缺口与风险登记

- 安装包未签名，NSIS 报告缺少可选签名文件及语言 ID 回退警告。
- 安装包中的 ARM64 槽位使用 x64 二进制；没有原生 ARM64 构建或硬件测试。
- 安装包只包含桌面程序，不包含单独的 Web 服务；首页入口依赖该服务运行。
- 托管 CI、跨设备使用及用户实际体验反馈尚未取得。

## 发布建议

- 建议：`可发布，但存在已列明风险`；用户已要求验收通过后直接发布并安装。
- 本记录生成时公开发布资产尚未上传；上传后需验证下载及哈希。

## 历史与用户反馈跟进

- 上次审核：`docs/release-reviews/2026-11-06-717fce2-web-clash.md`。
- 本次安装和界面要求来自当前对话；之前的 Web 服务风险不因桌面入口发布而自动关闭。

## 技能改进建议 — 需人工确认

- 无。
