# 贡献指南

感谢愿意一起把这套部署流程打磨得更可靠。以下规则是为了让**任何人拿到仓库都能复现结果**。

## 基本原则

- 一个 PR 只做一件事。文档、重构、行为变更不要混在同一个 PR 里。
- 任何行为变更都必须能在一台干净机器上复现，并在 PR 里写清：
  Android 版本 / API、镜像 tag、内核版本（`adb shell uname -r`）、Root 方式。
- 不要提交二进制：`*.apk`、`*.zip`、`*.img`、日志都不要进仓库，`.gitignore` 已经拦截。
- 两个入口脚本必须保持功能对等：action 与参数一一对应，`ACTIONS:` 行完全相同（CI 会校验）。

## 仓库结构

```text
docs/       面向使用者的文档，不放代码
scripts/    两个入口脚本，各自单文件、无共享状态
assets/     README 引用的截图
.github/    issue 模板、PR 模板、CI
```

## 代码规范

### Shell（`scripts/avd-root.sh`）

- `#!/usr/bin/env bash` + `set -euo pipefail`。
- 必须通过 `shellcheck`（规则见 `.shellcheckrc`，severity=warning）。
- 所有变量展开加引号；禁止 `eval`；禁止解析 `ls` 输出。
- 兼容 GNU 与 BSD（macOS）：避免 `sed -i` 的平台差异，用 `sed ... > tmp && mv`。
- 函数命名 `snake_case`，单一职责；除文档化的 `CFG_*` 之外不引入全局可变状态。
- 面向用户的输出走 stdout，诊断信息走 stderr。

### PowerShell（`scripts/avd-root.ps1`）

- 入口加 `[CmdletBinding()]`，启用 `Set-StrictMode -Version Latest`。
- 只用标准动词，`Verb-Noun` 命名，不写别名。
- 参数必须带类型与校验（`[ValidateSet]`、`[ValidateRange]`）。
- `$ErrorActionPreference = 'Stop'`；调用外部程序后显式检查退出码。
- 优先用数组 splatting（`& $exe @args`），不要拼字符串。

### Markdown

- 每个文件只有一个 `H1`，用 `##` 分节，标题用陈述式短语。
- 内部链接必须可解析（CI 会检查）。
- 矩阵、对照关系用表格；叙述不要塞进表格。
- 代码块必须标语言（`text`、`bash`、`powershell`、`yaml`）。

## 提交信息

使用 Conventional Commits：

```text
feat(kernelsu): 支持为新镜像指定自定义 LKM
fix(magisk): 环境未初始化时自动补齐 /data/adb/magisk
docs: 补充 native bridge 与 Zygisk 冲突的说明
chore(ci): 增加 action 一致性检查
```

## PR 检查清单

- [ ] `shellcheck scripts/avd-root.sh` 无告警。
- [ ] `pwsh -File scripts/avd-root.ps1 -Action doctor` 仍可运行。
- [ ] 两个脚本的 action 列表仍然一致。
- [ ] 行为变更同步更新了 `docs/`。
- [ ] 在 `CHANGELOG.md` 的 `Unreleased` 下补了条目。
