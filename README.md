<div align="center">

# AVD Root Toolkit

[![English](https://img.shields.io/badge/English-red)](README_EN.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

![Android](https://img.shields.io/badge/Android-13%20~%2017-3DDC84?logo=android&logoColor=white)
![Root](https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU-critical)
![Host](https://img.shields.io/badge/Host-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)

Android Studio 虚拟设备（AVD）部署 + Root 工具集：**Magisk / KernelSU 任选其一**，
内置 Zygisk 支持、GPU 硬件加速开关、以及模拟器启动弹窗的根治方案。

</div>

## 快速导航

- [适用场景](#适用场景)
- [支持矩阵](#支持矩阵)
- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [两种 Root 方式怎么选](#两种-root-方式怎么选)
- [硬件与性能](#硬件与性能)
- [启动参数](#启动参数)
- [验证清单](#验证清单)
- [常见问题](#常见问题)
- [目录结构](#目录结构)
- [脚本参数](#脚本参数)
- [架构说明](#架构说明)
- [参与贡献](#参与贡献)
- [致谢](#致谢)

## 适用场景

- 需要在本地跑一台**可 Root 的 Android 模拟器**做逆向、抓包、模块开发、自动化测试。
- 需要在 Android 13 / 14 / 15 / 16 / 17 之间**切换不同 API 版本**验证兼容性。
- 需要在 KernelSU 与 Magisk 之间切换，验证模块（Zygisk / LSPosed / Shamiko 等）行为差异。
- 换台机器重新部署时，不想再踩一遍「内核模块加载失败 / SystemUI 卡死 / 路径被转换」的坑。

> **IMPORTANT**
> 本项目只处理**官方 Android Emulator（AVD）**。第三方模拟器（MuMu、雷电、BlueStacks 等）
> 的镜像结构、ramdisk 与分区布局完全不同，不适用本文档的流程。

## 支持矩阵

`✅ 实测通过` / `⚠️ 理论可行（未实测）` / `❌ 实测不可行`

| Android | API | 镜像示例 | 内核 | Magisk | KernelSU | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| 13 | 33 | `system-images;android-33;google_apis;x86_64` | 5.15 | ✅ | ❌ | 5.15 内核与 6.1 同样缺 `EXTENDED_MODVERSIONS`，LKM 走不通 |
| 14 | 34 | `system-images;android-34;google_apis;x86_64` | 6.1 | ✅ | ❌ | 本项目实测环境；KernelSU 失败原因见 [docs/kernelsu-limits.md](docs/kernelsu-limits.md) |
| 15 | 35 | `system-images;android-35;google_apis;x86_64` | 6.6 | ⚠️ | ❌ | 6.6 仍无扩展符号版本，KernelSU 预期同样失败 |
| 16 | 36 | `system-images;android-36;google_apis;x86_64` | 6.12 | ⚠️ | ⚠️ | 6.12 起支持扩展符号版本，KernelSU 预期可用 |
| 17 | 37 | `system-images;android-37.0;google_apis;x86_64` | 6.12 / 6.18 | ⚠️ | ✅ | 本项目实测：KernelSU 3.3.1 + Zygisk Next 1.5.2 |

- 「❌」不是配置写错，而是**模拟器内核的客观限制**，详见 [docs/kernelsu-limits.md](docs/kernelsu-limits.md)。
- KernelSU 官方 LKM 从 v3.3.x 起才提供 x86_64 版本；更早的版本只有 arm64，x86_64 AVD 无解。
- 想让 Android 13/14/15 也用 KernelSU，只有两条路：自编译 `CONFIG_KSU=y` 的内核，或改用 arm64 镜像（TCG 软件翻译，慢到不可日用）。

## 前置条件

> **IMPORTANT**
> - 宿主机开启硬件虚拟化（Windows：Hyper-V / WHPX 或 AEHD；macOS：Hypervisor.framework；Linux：KVM）。
> - Android SDK 已安装，且 `ANDROID_SDK_ROOT` 指向 SDK 根目录。
> - 磁盘预留 ≥ 25GB（每个系统镜像约 5GB，每个 AVD 数据 8GB 起）。
> - 同一时间只跑一台模拟器（16GB 内存机器上两台会互相拖慢）。

检查环境：

```powershell
# Windows
.\scripts\avd-root.ps1 -Action doctor
```

```bash
# macOS / Linux
./scripts/avd-root.sh doctor
```

## 快速开始

以「Android 17 + KernelSU」为例（Windows，PowerShell）：

```powershell
# 1) 装好 SDK 组件与系统镜像（emulator 必须是 37.x，API 37 的硬性要求）
.\scripts\avd-root.ps1 -Action install -Api 37

# 2) 创建 AVD（数据目录可指定到其它盘）
.\scripts\avd-root.ps1 -Action create -Api 37 -AvdName Android17_KSU -AvdHome D:\AndroidAVD\avd

# 3) 启动（硬件 GPU + WHPX）
.\scripts\avd-root.ps1 -Action start -AvdName Android17_KSU

# 4) 注入 KernelSU（自动识别 KMI、下载对应 LKM、patch ramdisk、装管理器）
.\scripts\avd-root.ps1 -Action root-kernelsu -AvdName Android17_KSU -Api 37

# 5) 冷启动后安装 Zygisk Next
.\scripts\avd-root.ps1 -Action zygisk-next -AvdName Android17_KSU
```

换成 Magisk（以 Android 14 为例）：

```powershell
.\scripts\avd-root.ps1 -Action install -Api 34
.\scripts\avd-root.ps1 -Action create  -Api 34 -AvdName Android14_Magisk
.\scripts\avd-root.ps1 -Action start   -AvdName Android14_Magisk
.\scripts\avd-root.ps1 -Action root-magisk -AvdName Android14_Magisk -Api 34
```

> **NOTE**
> 两种方式都会修改 `system-images/<api>/<variant>/<abi>/ramdisk.img`，首次修改前会自动备份成
> `ramdisk.img.backup`。恢复未 Root 状态：`-Action restore -Api <api>`。

## 两种 Root 方式怎么选

| 维度 | Magisk | KernelSU |
| --- | --- | --- |
| 注入方式 | 替换 ramdisk 里的 `/init`（magiskinit），用户态守护进程 | 内核 LKM（`ksuinit` 在 init 阶段 insmod） |
| 模拟器可用性 | Android 13~17 均可 | 仅 6.12+ 内核（Android 16/17）稳定可用 |
| 模块生态 | 最全，Magisk 模块 + Zygisk 模块 | 支持 KernelSU 模块 + Zygisk Next |
| 隐藏能力 | 内置 DenyList，配合 Shamiko | 需 Zygisk Next + 隐藏方案 |
| 对 ARM 转译的影响 | Zygisk 会接管 `ro.dalvik.vm.native.bridge`，纯 ARM 应用可能失效 | 不接管，ARM 应用正常 |
| 推荐场景 | Android 13/14/15，或需要最大模块兼容性 | Android 16/17，或需要内核级 root |

一句话结论：**Android 14 及以下优先 Magisk；Android 16/17 且想用 KernelSU 生态就选 KernelSU。**
Android 14 用 KernelSU 并非「绝对不能」，而是要走自编译内核那条不便捷的路——原因见
[docs/kernelsu-limits.md](docs/kernelsu-limits.md)。

## 硬件与性能

### GPU 加速（最容易踩的坑）

模拟器默认会因为检测不到可用 Vulkan 而**强制 SwiftShader 软件渲染**，
表现为开机后 SystemUI 卡死、弹出「SystemUI isn't responding」「Launcher 屡次停止运行」。

正确做法是强制走宿主 GPU 的 OpenGL：

```text
-gpu host -feature -ForceSwiftshader
```

加参数前后的实测对比（Intel HD 4600，无 Vulkan 驱动）：

| 配置 | 渲染器 | 现象 |
| --- | --- | --- |
| 默认 | SwiftShader（CPU） | 冷启动 SystemUI ANR、Launcher 崩溃、操作卡顿 |
| `-gpu host -feature -ForceSwiftshader` | `Intel(R) HD Graphics 4600, OpenGL ES 3.0 (4.3.0)` | 界面流畅，ANR 归零 |

> **NOTE**
> `-gpu angle_indirect` 在本类老显卡上仍会退回 SwiftShader；关键开关是
> `-feature -ForceSwiftshader`（注意是**关闭**该 feature）。

### 系统级弹窗压制

即使硬件加速生效，首启动偶发的应用 ANR 仍会弹框。写入以下设置可彻底静音（保存在 AVD 的 data 分区，重启有效）：

```bash
adb shell settings put global hide_error_dialogs 1
adb shell settings put global anr_show_background 0
adb shell settings put global show_first_crash_dialog 0
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
```

### 资源建议

| 项目 | 建议值 | 说明 |
| --- | --- | --- |
| RAM | 4096 MB | 低于 2GB 首启动必 ANR；两台同开按 2×4GB 预留 |
| vCPU | 4 | 宿主机 4 核 8 线程以上再给 4；TCG（arm64 镜像）场景反而越少越好 |
| data 分区 | 8 GB | 默认 6GB 容易被 Play 服务缓存塞满 |
| 磁盘 | SSD | AVD 是随机读写的 qcow2，机械盘会拖慢 3~5 倍 |

详见 [docs/hardware.md](docs/hardware.md)。

## 启动参数

```text
emulator -avd <AVD_NAME> -gpu host -feature -ForceSwiftshader
```

常用可选参数：

| 参数 | 用途 |
| --- | --- |
| `-no-snapshot-load` | 强制冷启动（改了 ramdisk 之后必须用） |
| `-no-boot-anim` | 跳过开机动画，冷启动快 5~10 秒 |
| `-netdelay none -netspeed full` | 关闭模拟网络延迟/限速 |
| `-writable-system` | 需要改 /system 时使用（配 `adb remount`） |
| `-memory 4096 -cores 4` | 临时覆盖 AVD 配置 |
| `-read-only` | 同一 AVD 多开（调试用） |

## 验证清单

**Magisk**

```bash
adb shell su -c id
# uid=0(root) ... context=u:r:magisk:s0
adb shell magisk -v
# 31.1:MAGISK:R
adb shell magisk --sqlite "select * from settings"
# key=zygisk|value=1
```

**KernelSU**

```bash
adb shell su 0 id
# uid=0(root) ... context=u:r:ksu:s0
adb shell su 0 /data/adb/ksu/bin/znctl status
# version:1.5.2-... / inject_state:1 / root_status:✅KernelSU
```

**Zygisk 是否真的注入**（不信开关，看行为）

```bash
# 装一个最小 Zygisk 模块后重启，看是否有进程加载它
adb logcat -d | grep ZYPROOF | wc -l
```

## 常见问题

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| `SystemUI isn't responding` | SwiftShader 软件渲染 | 加 `-gpu host -feature -ForceSwiftshader` |
| `Launcher 屡次停止运行` | 同上，ViewRootImpl 同步屏障竞态 | 同上 + `hide_error_dialogs=1` |
| KernelSU 日志 `Unknown symbol sidtab_search_entry` | 内核未导出 SELinux 内部符号 | 换 Magisk，或自编译内核导出符号 |
| KernelSU 日志 `no symbol version for module_layout` | 内核 `CONFIG_MODVERSIONS=y` 但无 `EXTENDED_MODVERSIONS` | 同上（补 CRC 也过不了后续重定位校验） |
| Magisk `Incomplete Magisk install` | `/data/adb/magisk` 未初始化 | 脚本会自动补齐环境文件 |
| Magisk App 弹「Requires additional setup / recovery mode」 | AVD 无 boot 分区，App 拿不到安装产物信息 | 点 Cancel，root 不受影响 |
| `Another emulator instance is running` | 上一个 qemu 进程/锁文件残留 | 结束 `qemu-system-x86_64` 并删 `*.lock` |
| 6.12 内核 + Android 14 镜像 → `virtio_blk.ko: Exec format error` | 镜像里的模块是 6.1 编译的 | 不要跨版本换内核 |
| Git Bash 下 `adb push` 路径变成 `C:/Program Files/Git/data/...` | MSYS 路径自动转换 | `export MSYS_NO_PATHCONV=1` |
| `sdkmanager --sdk_root=D:\sdk` 把包装到 `cmdline-tools/latest/bin/sdk` | 旧版 cmdline-tools 解析问题 | 不传 `--sdk_root`，改用环境变量 |

更多细节与错误原文见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 目录结构

```text
avd-root-toolkit/
├─ scripts/
│  ├─ avd-root.ps1          # Windows 主脚本（doctor/install/create/start/root-*/zygisk-next/restore）
│  └─ avd-root.sh           # macOS / Linux 版（同一套 action 与参数）
├─ docs/
│  ├─ architecture.md       # 架构、数据流、action 契约、扩展点
│  ├─ compatibility.md      # 版本 × Root 方式矩阵与镜像 tag 选择
│  ├─ kernelsu-limits.md    # 为什么 Android 13/14/15 用不了 KernelSU（含原始日志）
│  ├─ hardware.md           # GPU / 虚拟化 / 内存 / 磁盘 / 16KB page
│  └─ troubleshooting.md    # 报错速查
├─ assets/                  # 实测截图
├─ .github/                 # issue 模板、PR 模板、CI 校验
├─ CONTRIBUTING.md          # 代码规范与 PR 要求
├─ CHANGELOG.md             # 变更记录
├─ LICENSE
└─ README.md / README_EN.md
```

## 脚本参数

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-Action` | `doctor` `install` `create` `start` `root-magisk` `root-kernelsu` `zygisk-next` `restore` | 必填 |
| `-Api` | Android API Level（33/34/35/36/37） | 34 |
| `-Variant` | 系统镜像 tag，如 `google_apis` / `google_apis_playstore` | `google_apis` |
| `-Abi` | `x86_64` / `arm64-v8a` | `x86_64` |
| `-AvdName` | AVD 名称 | `Android<Api>_<RootMode>` |
| `-AvdHome` | AVD 数据目录（放到非系统盘） | 默认 `%USERPROFILE%\.android\avd` |
| `-RamMb` / `-Cores` | 内存 / vCPU | 4096 / 4 |
| `-KernelSuApk` / `-MagiskApk` | 使用本地已下载的 APK，避免重复下载 | 自动下载最新 release |
| `-DryRun` | 只打印将要执行的命令，不修改 ramdisk | 关 |

## 架构说明

工具的核心思路是「**补丁在设备内完成**」：宿主机只负责把 `ramdisk.img` 与 APK 推进设备，
真正的 cpio 操作交给设备上的 `magiskboot`（Magisk）或 `ksud`（KernelSU）。
这样宿主机不需要准备 lz4 / cpio / magiskboot，也天然与设备 ABI 对齐。

```text
avd-root <action>
   ├─ doctor / install        → SDK 组件与镜像
   ├─ create / start          → AVD 配置与硬件渲染启动
   ├─ root-magisk             → magiskboot 改 /init + overlay.d，补齐环境，启用 Zygisk
   ├─ root-kernelsu           → ksud boot-patch --ramdisk，装管理器
   └─ zygisk-next / restore   → 装模块 / 还原 ramdisk
                                   ↓
                        替换 ramdisk.img → 完全重启模拟器 → 校验
```

两个脚本都是**单文件**，刻意不拆库：部署工具最怕「少 clone 一个目录就跑不起来」。
action 契约、幂等性、为什么改 ramdisk 而不是 boot.img、如何扩展新 API 或新 Root 方案，
都写在 [docs/architecture.md](docs/architecture.md)。

## 参与贡献

- 代码规范、提交信息格式、PR 检查清单见 [CONTRIBUTING.md](CONTRIBUTING.md)。
- CI 会校验：Shell 语法与 shellcheck、PowerShell AST 与 PSScriptAnalyzer、
  两个脚本的 action 一致性、Markdown 相对链接可解析。
- 新增或修改行为时，请同步更新 `docs/compatibility.md` 与 `CHANGELOG.md`。
- 在新机器上跑通（或失败）后，欢迎用兼容性报告模板提交实测结果。

## 致谢

本项目是把若干上游项目的机制拼装、验证并文档化的结果，核心能力来自它们：

| 项目 | 作者 | 本项目用到的部分 |
| --- | --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | tiann / weishu | LKM（`kernelsu.ko`）、`ksud boot-patch --ramdisk`、`ksuinit` 符号重定位机制 |
| [KernelSU-AVD](https://github.com/HChenX/KernelSU-AVD) | HChenX | AVD ramdisk patch 的完整流程与 `ksud` 调用方式 |
| [rootAVD](https://gitlab.com/newbit/rootAVD) | newbit | AVD + Magisk 的 ramdisk 思路、`EnvFixTask` 环境补齐经验 |
| [Magisk](https://github.com/topjohnwu/Magisk) | topjohnwu | `magiskboot`（cpio/lz4/xz）、`boot_patch.sh` 的 ramdisk 补丁序列 |
| [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) | LSPosed / Dr-TSNG | KernelSU 侧 Zygisk 实现 |
| [Android Emulator](https://developer.android.com/studio/run/emulator) | Google / AOSP | AVD、`-feature` 开关、`-prop` 等运行参数 |

以及 [Android 开源项目 (AOSP)](https://source.android.com/) 提供的 GKI 内核与 `CONFIG_MODVERSIONS` / `EXTENDED_MODVERSIONS` 机制说明。

## License

[MIT](LICENSE)。文档与脚本可自由使用；上游项目遵循其各自许可证（KernelSU / KernelSU-AVD 为 GPL-3.0，
Magisk 为 GPL-3.0，Zygisk Next 为 GPL-3.0），分发二进制时请一并遵守。
