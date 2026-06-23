# 参与贡献

感谢关注 [gradient30/memreduct](https://github.com/gradient30/memreduct)。本仓库基于 [henrypp/memreduct](https://github.com/henrypp/memreduct)，在保留上游功能的同时维护简体中文界面与本地构建体验。

## 报告问题

请先搜索 [已有 Issue](https://github.com/gradient30/memreduct/issues)，避免重复提交。新建 Issue 时请使用仓库提供的模板，并尽量提供：

- 应用版本（例如 3.5.3）
- Windows 版本与架构（x64 / ARM64）
- 复现步骤与预期/实际行为
- 截图、日志或崩溃转储（如有）

## 功能建议

功能请求请单独开一个 Issue，说明要解决的问题与期望方案。与上游通用的功能也可考虑先向 [henrypp/memreduct](https://github.com/henrypp/memreduct/issues) 反馈。

## 本地化（i18n）

- 内置字符串：`src/resource.h`、`.rc` 资源及 `bin/i18n/*.ini`
- 合并语言包：运行 `build_locale.bat`（依赖同级 `builder` 目录）
- 修改 `.ini` 后请保持 UTF-8 编码，并同步更新 `bin/i18n/!example.txt` 中的键说明（如有新增键）

## 从源码构建

完整说明见 [docs/BUILD.md](docs/BUILD.md)。简要流程：

```bat
scripts/init_submodules.bat
build_locale.bat
build_vc.bat
build.bat
```

构建产物默认输出到 `build/`，编译中间文件与 `bin/64/` 等已在 `.gitignore` 中排除，**请勿提交**。

## Pull Request 指南

1. 基于 `master` 分支创建功能分支
2. 保持改动聚焦，避免无关格式化
3. 若修改版本号，同步更新 `VERSION`、`CHANGELOG.md` 并运行 `scripts/verify_version.bat`
4. 在 PR 描述中说明变更动机与测试方式

## 代码许可

提交即表示您同意在 [GNU GPL v3](LICENSE) 下授权您的贡献。
