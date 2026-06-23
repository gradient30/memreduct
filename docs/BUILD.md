# 构建指南

本文说明如何从源码编译 Mem Reduct 并生成安装包/便携包。

## 环境要求

| 组件 | 要求 |
|------|------|
| 操作系统 | Windows 10 / 11（x64 开发机） |
| 编译器 | Visual Studio 2022 或更新 Build Tools，含「使用 C++ 的桌面开发」工作负载 |
| SDK 依赖 | 同级目录下的 `routine`、`builder`（见下文） |
| 打包（可选） | [NSIS 3.10+](https://nsis.sourceforge.io/Download)，用于生成 `setup.exe` |

## 获取依赖

在仓库根目录执行：

```bat
scripts/init_submodules.bat
```

将在 `../routine` 与 `../builder` 克隆 [henrypp/routine](https://github.com/henrypp/routine) 与 [henrypp/builder](https://github.com/henrypp/builder)。若已手动放置，可跳过克隆步骤。

> **说明**：本 fork 使用 `src/mountmgr_compat.c` 兼容较旧 routine SDK，无需等待上游 routine 更新即可本地编译。

## 构建流程

### 一键构建（推荐）

```bat
build_all.bat
```

依次执行：语言包 → 编译 → 打包。

### 分步构建

```bat
build_locale.bat
build_vc.bat
build.bat
```

- `build_locale.bat` — 合并 i18n，生成 `bin/memreduct.lng`
- `build_vc.bat` — MSBuild Release x64（及 ARM64，若工具链可用）
- `build.bat` — 调用 builder，输出到 `build/`

### NSIS 路径

若 `makensis.exe` 不在 PATH 中，可运行：

```bat
scripts/install_nsis.bat
scripts/setup_build_paths.bat
```

未安装 NSIS 时仍会生成 `build/memreduct-<version>-bin.7z` 便携包，但可能没有 `setup.exe`。

## 输出位置

| 路径 | 内容 |
|------|------|
| `bin/64/memreduct.exe` | x64 可执行文件（本地测试） |
| `bin/ARM64/memreduct.exe` | ARM64 构建结果；无 ARM64 工具链时用 x64 二进制填充打包槽位 |
| `build/memreduct-<version>-setup.exe` | NSIS 安装包 |
| `build/memreduct-<version>-bin.7z` | 便携压缩包 |

## 版本校验

```bat
scripts/verify_version.bat
scripts/smoke_test.bat bin/64/memreduct.exe
```

## 常见问题

**MSBuild 未找到**  
安装 VS Build Tools 并勾选 C++ 桌面开发，或确认 `vswhere` 能定位到 MSBuild。

**链接失败：memreduct.exe 正在运行**  
从托盘退出 Mem Reduct 后重试；`build_vc.bat` 会尝试自动结束进程。

**ARM64 编译跳过**  
未安装 ARM64 工具链时属正常行为，打包仍可使用 x64 回退二进制。

**GPG 签名警告**  
本地构建通常无 Henry++ 私钥，可忽略 `.sig` 相关警告。

## 相关文档

- [ACCEPTANCE.md](ACCEPTANCE.md) — 发布前验收清单
- [CONTRIBUTING.md](../CONTRIBUTING.md) — 贡献与 PR 说明
