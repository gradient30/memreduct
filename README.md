<h1 align="center">Mem Reduct</h1>

<p align="center">
	<a href="https://github.com/gradient30/memreduct/releases"><img src="https://img.shields.io/github/v/release/gradient30/memreduct?style=flat-square&include_prereleases&label=版本" /></a>
	<a href="https://github.com/gradient30/memreduct/releases"><img src="https://img.shields.io/github/downloads/gradient30/memreduct/total.svg?style=flat-square&label=下载" /></a>
	<a href="https://github.com/gradient30/memreduct/issues"><img src="https://img.shields.io/github/issues-raw/gradient30/memreduct.svg?style=flat-square&label=议题" /></a>
	<a href="https://github.com/gradient30/memreduct/blob/master/LICENSE"><img src="https://img.shields.io/github/license/gradient30/memreduct?style=flat-square&label=许可" /></a>
</p>

<p align="center">
	<strong>简体中文界面 · 基于 <a href="https://github.com/henrypp/memreduct">henrypp/memreduct</a> 维护</strong>
</p>

-------

<p align="center">
	<img src="/images/memreduct.png?cachefix" />
</p>

### 简介

Mem Reduct 是一款轻量级的实时内存管理工具，用于监控并清理系统内存。

程序通过未公开的 Native API 清理系统缓存（系统工作集、工作集、待机页列表、已修改页列表等），效果因环境而异，通常约为 10%–50%。支持 Windows 10 及更高版本（x64 / ARM64）。

本仓库在 [Henry++ 原版](https://github.com/henrypp/memreduct) 基础上提供**完整简体中文界面**，并包含本地构建与打包脚本改进。内存清理等部分功能需要**管理员权限**。

```
便携模式：在程序目录创建 memreduct.ini，或从 "%APPDATA%\Henry++\Mem Reduct" 复制到程序目录。
```

### 系统要求

- Windows 10 / 11（64 位或 ARM64）
- 支持 SSE2 的 CPU

### 下载

| 类型 | 说明 |
|------|------|
| [Releases](https://github.com/gradient30/memreduct/releases) | 安装包 `memreduct-x.y.z-setup.exe` 或便携包 `memreduct-x.y.z-bin.7z` |
| 自行构建 | 见 [docs/BUILD.md](docs/BUILD.md) |

### 从源码构建

依赖 [routine](https://github.com/henrypp/routine) 与 [builder](https://github.com/henrypp/builder) SDK（与原版相同，需放在本仓库同级目录）：

```bat
scripts\init_submodules.bat
build_all.bat
```

详细步骤、环境要求与验收清单见 [docs/BUILD.md](docs/BUILD.md) 与 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

### 参与贡献

欢迎通过 [Issue](https://github.com/gradient30/memreduct/issues) 反馈问题或提出功能建议。构建与提交流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。

### 上游与致谢

- 原版作者：[Henry++](https://github.com/henrypp) · [henrypp/memreduct](https://github.com/henrypp/memreduct)
- 许可：[GNU GPL v3](LICENSE)

### 捐赠（上游作者）

- [Bitcoin](https://www.blockchain.com/btc/address/1LrRTXPsvHcQWCNZotA9RcwjsGcRghG96c) (BTC)
- [Ethereum](https://www.blockchain.com/explorer/addresses/eth/0xe2C84A62eb2a4EF154b19bec0c1c106734B95960) (ETH)
- [Yandex Money](https://yoomoney.ru/to/4100115776040583) (RUB)
- [Paypal](https://paypal.me/henrypp) (USD)

### GPG 签名

官方发行版二进制文件可能附带 `memreduct.exe.sig`。本 fork 自行构建的版本**不一定**包含有效签名。

- 公钥：[pubkey.asc](https://raw.githubusercontent.com/henrypp/builder/master/pubkey.asc)
- Key ID: 0x5635B5FD

---

(c) 2011–2026 [Henry++](https://github.com/henrypp) · 简体中文维护 [gradient30/memreduct](https://github.com/gradient30/memreduct)
