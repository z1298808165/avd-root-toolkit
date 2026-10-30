# 更新日志

本项目的重要变更都记录在此。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-10-30

### 新增

- `scripts/avd-root.ps1` 与 `scripts/avd-root.sh`，两者提供同一组 action：
  `doctor`、`install`、`create`、`start`、`root-magisk`、`root-kernelsu`、
  `zygisk-next`、`restore`。
- Magisk 路线：设备内 `magiskboot` 处理 ramdisk（lz4_legacy + cpio）、补齐运行环境、
  启用 Zygisk、给 adb shell 预授权 superuser。
- KernelSU 路线：`ksud boot-patch --ramdisk` 自动识别 KMI、安装管理器、安装 Zygisk Next。
- 硬件相关默认值：`-gpu host -feature -ForceSwiftshader`、4GB RAM、4 vCPU、8GB data。
- 系统弹窗压制：`hide_error_dialogs` 与动画比例归零。
- 文档：兼容性矩阵、KernelSU 内核限制（含原始日志）、硬件说明、排错手册、架构说明。

### 已知限制

- API 33/34/35 的模拟器内核无法加载 KernelSU 官方 LKM，
  原因见 [docs/kernelsu-limits.md](docs/kernelsu-limits.md)。
- macOS / Linux 脚本按 Windows 流程一比一实现，但尚未由维护者在真机上跑通全流程，
  欢迎提交 issue 反馈。
