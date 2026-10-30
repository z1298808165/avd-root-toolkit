# 硬件与性能

模拟器的流畅度取决于三件事：**虚拟化加速、GPU 渲染后端、内存/CPU 配额**。
任意一项缺失，表现都是「能开机但很难用」，并且会伴随 SystemUI ANR 弹窗。

## 1. 虚拟化加速

| 平台 | 后端 | 检查方式 |
| --- | --- | --- |
| Windows + Hyper-V/WSL2 | WHPX | `emulator -accel-check` 输出 `WHPX ... is installed and usable` |
| Windows 无 Hyper-V | AEHD 驱动 | 服务 `aehd` 处于 Running |
| macOS | Hypervisor.framework | 默认可用 |
| Linux | KVM | `ls -l /dev/kvm` 存在且当前用户在 kvm 组 |

Windows 上常见的两种状态：

```text
accel:
0
WHPX (10.0.22621) is installed and usable.
```

`0` 表示可用。若输出 `Please disable Hyper-V before using the Android Emulator`，
说明既没启用 WHPX 也没装 AEHD——二者装一个即可，不需要重装系统。

> **NOTE**
> Hyper-V 与 AEHD 互斥。装了 Hyper-V（或开了 WSL2 / Docker Desktop）就只能用 WHPX，
> 不要再装 AEHD；反之亦然。

## 2. GPU 渲染后端

模拟器启动时按以下顺序挑选渲染后端：

1. `-gpu host`：直接用宿主 OpenGL/Vulkan；
2. 检测不到可用 GPU（缺少 Vulkan、驱动版本过低）时**强制 SwiftShader**（CPU 渲染）；
3. `-gpu guest` / `swiftshader_indirect`：显式软件渲染。

问题就出在第 2 步：它不会报错，只是悄悄变慢，然后 SystemUI 撑不住超时就弹窗。

判断当前用的是哪种渲染：

```bash
adb shell "dumpsys SurfaceFlinger | grep -m1 '^GLES:'"
```

- 软件渲染：`Android Emulator OpenGL ES Translator (Google SwiftShader)`
- 硬件渲染：`Android Emulator OpenGL ES Translator (Intel(R) HD Graphics 4600), OpenGL ES 3.0 (4.3.0 - ...)`

强制硬件渲染的开关：

```text
-gpu host -feature -ForceSwiftshader
```

`-feature -ForceSwiftshader` 是**关闭**「强制 SwiftShader」这个 feature，
这是老显卡（如 Intel HD 4600，无 Vulkan 驱动）上唯一能吃到 OpenGL 加速的写法。

实测对比（i7-4790 + HD 4600 + 16GB）：

| 配置 | 冷启动 | 首屏 ANR | 桌面滑动 |
| --- | --- | --- | --- |
| 默认（SwiftShader） | 约 2 分钟 | 每次都有 | 明显掉帧 |
| `-gpu host -feature -ForceSwiftshader` | 约 1.5 分钟 | 无 | 流畅 |

`-gpu angle_indirect`（走 D3D11）在本机上仍然回退到 SwiftShader，不必浪费时间尝试。

## 3. 内存与 CPU

| 项目 | 建议 | 说明 |
| --- | --- | --- |
| AVD RAM | 4096 MB | 2048 MB 在 Android 13+ 首启动几乎必然 ANR |
| vCPU | 4 | 与宿主机物理核数一致即可；超过物理核数只会互相抢占 |
| data 分区 | 8 GB | 默认 6GB 容易被 GMS 缓存塞满 |
| 磁盘 | SSD / NVMe | AVD 是 qcow2 随机读写，机械盘会慢 3~5 倍 |
| 同时运行 | 1 台 | 16GB 机器开两台各 4GB 会开始换页 |

Android 17（API 37）镜像对内存更敏感：低于 3GB 时 `system_server` 容易触发 lowmemorykiller。

## 4. 分辨率

默认 `medium_phone` 是 1080×2400 @420dpi。软件渲染下这个分辨率是灾难，
即便开了硬件加速，老核显也可能吃力。可以临时降级：

```bash
adb shell wm size 720x1600
adb shell wm density 320
# 恢复
adb shell wm size reset
adb shell wm density reset
```

## 5. 16KB page size 镜像

Android 15 起提供 `*_ps16k` 镜像（16KB 内存页）。它会影响：

- 只按 4KB 对齐编译的旧 native 库（部分 App 直接崩溃）；
- 部分内核模块（KernelSU 的 LKM 需要 16KB 兼容版本）。

没有 16KB 兼容性测试需求时，一律选普通（4KB）镜像。

## 6. ARM 转译与 Zygisk 的冲突

x86_64 镜像自带 `libndk_translation.so`，通过 `ro.dalvik.vm.native.bridge` 让 ARM 应用可跑。
Magisk 的 Zygisk 需要接管这个属性来做注入，于是出现：

```text
nativebridge: Unsupported native bridge API in libzygisk.solibndk_translation.so
              (is version 2 not compatible with 3)
```

结果是：Zygisk 注入正常（可用模块验证），但 **ARM 转译失效**，纯 ARM 应用无法启动。
取舍：

- 需要跑 ARM 应用 → 关闭 Zygisk；
- 需要 Zygisk 模块 → 接受 ARM 应用不可用，或改用 KernelSU（不接管 native bridge）。

KernelSU 侧没有这个问题，这也是 Android 16/17 上优先 KernelSU 的原因之一。

## 7. 电源与散热

长时间跑模拟器时，CPU 会持续睿频。笔记本上建议插电并把电源计划设成「高性能」，
否则 Windows 降频后，硬件加速也救不回来。
