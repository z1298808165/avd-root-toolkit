# 架构与实现说明

## 1. 设计目标

| 目标 | 落实方式 |
| --- | --- |
| 换机器能照着跑 | 所有关键参数都走命令行开关，不依赖个人目录约定 |
| 两种 Root 方式可切换 | action 拆分，`root-magisk` / `root-kernelsu` 互不影响 |
| 失败可回退 | 改 `ramdisk.img` 前一定留 `ramdisk.img.backup`，`restore` 一键还原 |
| 两个平台行为一致 | `avd-root.ps1` 与 `avd-root.sh` 保持相同 action 与开关，CI 校验一致性 |
| 不隐藏细节 | 每个步骤打印实际执行的命令与真实输出，方便对照文档排错 |

## 2. 目录职责

```text
scripts/avd-root.ps1   Windows 入口，单文件、无外部依赖（除 SDK 本身）
scripts/avd-root.sh    macOS / Linux 入口，逻辑与 ps1 一一对应
docs/                  面向使用者的文档，不放代码
assets/                README 引用的截图
.github/               issue 模板、PR 模板、CI
```

> **NOTE**
> 两个入口脚本刻意保持**单文件**：部署工具最怕「少 clone 一个 lib 目录就跑不起来」。
> 代价是文件偏长，靠分区注释（常量 / SDK / 设备 / 下载 / Actions）维持可读性。

## 3. 数据流

```text
                    ┌──────────────────────────────┐
                    │  avd-root.{ps1,sh} <action>  │
                    └──────────────┬───────────────┘
                                   │
        ┌──────────────┬───────────┴───────────┬────────────────┐
        │              │                       │                │
   doctor/install  create/start         root-magisk       root-kernelsu
        │              │                       │                │
        ▼              ▼                       ▼                ▼
   SDK / 加速检查   avdmanager + config.ini   宿主机 → 设备    宿主机 → 设备
                                    │        magiskboot 补丁   ksud boot-patch
                                    │              │                │
                                    └──────────────┴────────────────┘
                                                   │
                                         替换 ramdisk.img
                                                   │
                                     完全重启模拟器（非 adb reboot）
                                                   │
                                    环境补齐 / 管理器 / Zygisk
                                                   │
                                              结果校验
```

关键点：**补丁在设备内完成**。宿主只负责把 `ramdisk.img` 与 APK 推进去，
真正的 cpio 操作交给设备上的 `magiskboot` / `ksud`——这样不用在宿主机准备 lz4、
cpio、magiskboot 的本地构建，也天然与设备 ABI 对齐。

## 4. Action 契约

| Action | 前置条件 | 副作用 | 幂等性 |
| --- | --- | --- | --- |
| `doctor` | SDK 可用 | 无 | 只读 |
| `install` | 网络、SDK | 写 SDK 目录 | 幂等（sdkmanager 会跳过已安装） |
| `create` | 系统镜像已安装 | 创建/覆盖 AVD、改 config.ini | `--force` 覆盖同名 AVD |
| `start` | AVD 存在 | 启动进程 | 重复执行会因 AVD 锁失败，先关旧的 |
| `root-magisk` | 设备在线 | 改 `ramdisk.img`、装 APK、改 Magisk 设置 | 已打过补丁时需 `--force` |
| `root-kernelsu` | 设备在线 | 改 `ramdisk.img`、装 APK | 已打过补丁时需 `--force` |
| `zygisk-next` | 设备已 root | 装模块 / 改设置、重启 | 幂等 |
| `restore` | 存在备份 | 覆盖 `ramdisk.img` | 幂等 |

## 5. 为什么改的是 ramdisk，不是 boot.img

AVD 没有传统意义上的 boot 分区，`system-images/<api>/<variant>/<abi>/ramdisk.img`
是模拟器启动时唯一可替换的引导载体。两种 Root 方式都落在它上面：

- **Magisk**：把 `/init` 换成 `magiskinit`，并在 `overlay.d/sbin/` 放 `magisk.xz`、`init-ld.xz`，
  由 `magiskinit` 在 init 阶段还原真正的 init 并挂载模块。
- **KernelSU**：把 `/init` 换成 `ksuinit`，它负责 insmod `kernelsu.ko`，随后 exec 真正的 init。

同一个 `ramdisk.img` 只能属于一种 Root 方式，所以脚本在替换前会检查
`magiskboot cpio ... test` 的返回值，避免两种补丁叠加。

## 6. 重启策略

模拟器进程在 QEMU 启动时把 ramdisk 读进内存，之后无论 `adb reboot` 还是软重启都不会重新读取。
因此脚本统一走「杀掉模拟器进程 → 重新 `start`」，这也是 `restart_emulator()` 存在的原因。

## 7. CI 约束

`.github/workflows/validate.yml` 四个 job：

| job | 检查内容 |
| --- | --- |
| `shell` | `bash -n` + `shellcheck`（规则见 `.shellcheckrc`） |
| `powershell` | AST 解析 + `PSScriptAnalyzer`（error 级） |
| `contract` | 两个脚本的 `ACTIONS:` 行必须完全一致 |
| `docs` | 所有 Markdown 相对链接必须能解析 |

新增 action 时，必须同时改两个脚本的 `ACTIONS:` 行、`switch/case` 分发与本文档的契约表，
否则 CI 的 `contract` job 会失败。

## 8. 扩展点

- **新增 API 版本**：在 `ImageDirByApi` / `image_dir_for_api` 里加映射
  （注意 API 37 的目录名是 `android-37.0`），再更新兼容性矩阵。
- **支持自定义内核**：在 `root-kernelsu` 里给 `ksud boot-patch` 传 `--kernel <path>`。
- **支持自定义 LKM**：`ksud boot-patch -m <kernelsu.ko>`；本项目在排查 6.1 内核问题时用过这条路。
- **接入其它 Root 方案**（APatch 等）：新增一个 `root-apatch` action，复用 `restart_emulator`
  与 `install_ramdisk` 即可，注意同步更新契约表与 `ACTIONS:` 行。
