# 兼容性矩阵

本文记录「Android 版本 × 系统镜像 × Root 方式」的实际可用性。
`✅ 实测通过`、`⚠️ 理论可行（未实测）`、`❌ 实测不可行`。

## 总表

| Android | API | 镜像 tag | 内核 | Magisk | KernelSU | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 13 | 33 | `google_apis` | 5.15 | ✅ | ❌ | 5.15 与 6.1 同样缺 `EXTENDED_MODVERSIONS` |
| 14 | 34 | `google_apis` | 6.1.23 | ✅ | ❌ | 本文档的基准环境 |
| 15 | 35 | `google_apis` | 6.6 | ⚠️ | ❌ | 6.6 仍未引入扩展符号版本 |
| 16 | 36 | `google_apis` | 6.12 | ⚠️ | ⚠️ | 6.12 起 KernelSU 有戏 |
| 17 | 37 | `google_apis` | 6.12.81 | ⚠️ | ✅ | KernelSU 3.3.1 + Zygisk Next 1.5.2 |

> **IMPORTANT**
> 上表中 Magisk 的 ⚠️ 只表示「未在本机跑完整流程」，机制上与已实测的 API 34 相同
> （ramdisk 补丁 + 环境补齐），不涉及内核能力差异。

## 镜像 tag 怎么选

| tag | Play 服务 | adb root | 适用 |
| --- | --- | --- | --- |
| `google_apis` | 无 | 可用 | 需要 root、需要干净系统的场景（**推荐**） |
| `google_apis_playstore` | 有 | 受限 | 需要登录 Google 账号或测试 GMS 相关逻辑 |
| `default` | 无 | 可用 | 最精简的 AOSP 镜像，启动最快 |

- `*_ps16k` 后缀表示 **16KB page size** 镜像（Android 15 起提供）。
  16KB 镜像对老应用与部分内核模块不友好，除非你在测试 16KB 兼容性，否则选普通镜像。
- 带 Play Store 的镜像不允许 `adb root`，部分脚本步骤需要改用 `su`，本项目默认使用 `google_apis`。

## ABI 怎么选

| ABI | 宿主机 | 速度 | 说明 |
| --- | --- | --- | --- |
| `x86_64` | x86_64 | 硬件虚拟化，快 | 默认，绝大部分场景 |
| `arm64-v8a` | x86_64 | TCG 软件翻译，极慢 | 冷启动 20~40 分钟，仅用于必须跑 ARM 原生库的场景 |
| `arm64-v8a` | Apple Silicon | 硬件虚拟化，快 | macOS 上的默认真实选择 |

> **NOTE**
> arm64 镜像在 x86_64 宿主机上无法用 `emulator` 直接启动（会提示
> `Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host`），
> 只能直接调用 `qemu-system-aarch64` 并关掉硬件加速。

## 逐版本说明

### Android 13（API 33，内核 5.15）

- Magisk：可用。ramdisk 结构与 14 基本一致，脚本参数不用改。
- KernelSU：不可用。原因与 6.1 相同：LKM 依赖的绝对地址重定位不被 5.15 的模块加载器接受，
  且内核没有 `EXTENDED_MODVERSIONS` 放行缺失的符号版本。

### Android 14（API 34，内核 6.1.23）

- Magisk：**已实测**。`su -c id` 返回 `u:r:magisk:s0`，Zygisk 注入经 50 个进程验证。
- KernelSU：**已实测失败**。日志与原因见 [kernelsu-limits.md](kernelsu-limits.md)。
- 已知副作用：Zygisk 会接管 `ro.dalvik.vm.native.bridge`，纯 ARM 应用可能无法启动。

### Android 15（API 35，内核 6.6）

- Magisk：预期可用，流程与 14 相同。
- KernelSU：预期不可用（6.6 无 `EXTENDED_MODVERSIONS`）。

### Android 16（API 36，内核 6.12）

- KernelSU：预期可用。6.12 内核对缺失的符号版本只告警不拒绝，这是 14 与 16 的分水岭。
- 想稳一点：先在 16 上验证 `-Action root-kernelsu`，再迁到 17。

### Android 17（API 37，内核 6.12.81）

- KernelSU：**已实测**。`uname -r` = `6.12.81-android16-6-...`，
  `su 0 id` 返回 `u:r:ksu:s0`，Zygisk Next 1.5.2 `inject_state:1`。
- 要求 emulator ≥ 37.x，旧版 34.1.20 直接启动失败。

## 提交你的实测结果

新机器上跑通或失败后，请用
[Compatibility report](../.github/ISSUE_TEMPLATE/compatibility_report.yml)
提交一条记录，附上 `uname -r` 与关键命令输出，我会更新这张表。
