<div align="center">

# AVD Root Toolkit

[![English](https://img.shields.io/badge/English-red)](README_EN.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

![Android](https://img.shields.io/badge/Android-13%20~%2017-3DDC84?logo=android&logoColor=white)
![Root](https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU-critical)
![Host](https://img.shields.io/badge/Host-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)

Deployment + rooting toolkit for Android Studio Virtual Devices (AVD):
pick **Magisk or KernelSU**, get Zygisk support, hardware GPU rendering,
and a cure for the "SystemUI isn't responding" popups.

</div>

## Quick Navigation

- [What This Solves](#what-this-solves)
- [Support Matrix](#support-matrix)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Choosing A Root Method](#choosing-a-root-method)
- [Hardware & Performance](#hardware--performance)
- [Verification](#verification)
- [FAQ](#faq)
- [Acknowledgements](#acknowledgements)

## What This Solves

- A rootable Android emulator for reverse engineering, traffic inspection, module development and CI.
- Switching between API 33–37 to validate compatibility.
- Switching between KernelSU and Magisk to compare module behaviour (Zygisk / LSPosed / Shamiko).
- Re-deploying on a new machine without rediscovering the same kernel/GPU/path pitfalls.

> **IMPORTANT**
> Only the **official Android Emulator (AVD)** is supported. Third-party emulators
> (MuMu, LDPlayer, BlueStacks) use different images and ramdisk layouts.

## Support Matrix

`✅ verified` / `⚠️ expected, untested` / `❌ verified as impossible`

| Android | API | Image example | Kernel | Magisk | KernelSU | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 13 | 33 | `system-images;android-33;google_apis;x86_64` | 5.15 | ✅ | ❌ | 5.15 lacks `EXTENDED_MODVERSIONS`, same LKM blocker |
| 14 | 34 | `system-images;android-34;google_apis;x86_64` | 6.1 | ✅ | ❌ | Reference environment; see [docs/kernelsu-limits.md](docs/kernelsu-limits.md) |
| 15 | 35 | `system-images;android-35;google_apis;x86_64` | 6.6 | ⚠️ | ❌ | 6.6 still has no extended symbol versions |
| 16 | 36 | `system-images;android-36;google_apis;x86_64` | 6.12 | ⚠️ | ⚠️ | 6.12 supports extended modversions |
| 17 | 37 | `system-images;android-37.0;google_apis;x86_64` | 6.12 / 6.18 | ⚠️ | ✅ | KernelSU 3.3.1 + Zygisk Next 1.5.2 verified |

KernelSU is not "broken by configuration" on API 33–35 — the emulator kernel genuinely cannot
load the official x86_64 LKM. Workarounds are compiling a kernel with `CONFIG_KSU=y`,
or using an arm64 image (TCG software translation, too slow for daily use).

## Prerequisites

- Hardware virtualization enabled on the host (Hyper-V/WHPX or AEHD on Windows, KVM on Linux).
- Android SDK installed and `ANDROID_SDK_ROOT` exported.
- ≥ 25 GB free disk (each system image ≈ 5 GB, each AVD data ≥ 8 GB).

```powershell
.\scripts\avd-root.ps1 -Action doctor
```

```bash
./scripts/avd-root.sh doctor
```

## Quick Start

Android 17 + KernelSU (Windows):

```powershell
.\scripts\avd-root.ps1 -Action install      -Api 37
.\scripts\avd-root.ps1 -Action create       -Api 37 -AvdName Android17_KSU -AvdHome D:\AndroidAVD\avd
.\scripts\avd-root.ps1 -Action start        -AvdName Android17_KSU
.\scripts\avd-root.ps1 -Action root-kernelsu -AvdName Android17_KSU -Api 37
.\scripts\avd-root.ps1 -Action zygisk-next  -AvdName Android17_KSU
```

Android 14 + Magisk:

```powershell
.\scripts\avd-root.ps1 -Action install     -Api 34
.\scripts\avd-root.ps1 -Action create      -Api 34 -AvdName Android14_Magisk
.\scripts\avd-root.ps1 -Action start       -AvdName Android14_Magisk
.\scripts\avd-root.ps1 -Action root-magisk -AvdName Android14_Magisk -Api 34
```

> **NOTE**
> Both methods patch `system-images/<api>/<variant>/<abi>/ramdisk.img` and keep a
> `ramdisk.img.backup` next to it. Restore with `-Action restore -Api <api>`.

## Choosing A Root Method

| | Magisk | KernelSU |
| --- | --- | --- |
| Injection | Replaces `/init` with `magiskinit`, userspace daemon | Kernel LKM loaded by `ksuinit` during init |
| Works on AVD | Android 13–17 | Android 16/17 (kernel 6.12+) |
| Module ecosystem | Widest (Magisk + Zygisk modules) | KernelSU modules + Zygisk Next |
| ARM translation | Zygisk takes over `ro.dalvik.vm.native.bridge`; ARM-only apps may break | Untouched |
| Recommendation | API 33–35, maximum module compatibility | API 36/37, kernel-level root |

## Hardware & Performance

The emulator forces SwiftShader whenever it cannot detect a usable Vulkan driver, which causes
SystemUI ANRs and launcher crashes. Force host OpenGL instead:

```text
-gpu host -feature -ForceSwiftshader
```

Measured on Intel HD 4600 (no Vulkan):

| Config | Renderer | Result |
| --- | --- | --- |
| default | SwiftShader (CPU) | boot-time ANR, launcher crash, laggy UI |
| `-gpu host -feature -ForceSwiftshader` | `Intel(R) HD Graphics 4600, OpenGL ES 3.0 (4.3.0)` | smooth, zero ANR |

Also silence residual dialogs (persists in the AVD data partition):

```bash
adb shell settings put global hide_error_dialogs 1
adb shell settings put global anr_show_background 0
adb shell settings put global show_first_crash_dialog 0
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
```

Recommended: 4 GB RAM, 4 vCPU, 8 GB data partition, SSD. See [docs/hardware.md](docs/hardware.md).

## Verification

```bash
# Magisk
adb shell su -c id            # uid=0(root) ... context=u:r:magisk:s0
adb shell magisk -v           # 31.1:MAGISK:R

# KernelSU
adb shell su 0 id             # uid=0(root) ... context=u:r:ksu:s0
adb shell su 0 /data/adb/ksu/bin/znctl status   # inject_state:1

# Proof that Zygisk really injects (install a minimal Zygisk module first)
adb logcat -d | grep ZYPROOF | wc -l
```

## FAQ

| Symptom | Cause | Fix |
| --- | --- | --- |
| `SystemUI isn't responding` | SwiftShader software rendering | add `-gpu host -feature -ForceSwiftshader` |
| KernelSU `Unknown symbol sidtab_search_entry` | kernel does not export SELinux internals | use Magisk or compile your own kernel |
| KernelSU `no symbol version for module_layout` | `CONFIG_MODVERSIONS=y` without `EXTENDED_MODVERSIONS` | same as above |
| Magisk `Incomplete Magisk install` | `/data/adb/magisk` not provisioned | the script provisions it automatically |
| `Another emulator instance is running` | leftover qemu process / lock files | kill `qemu-system-x86_64`, delete `*.lock` |
| 6.12 kernel with Android 14 image → `virtio_blk.ko: Exec format error` | modules are built for 6.1 | don't mix kernels across images |

## Acknowledgements

| Project | Author | Used for |
| --- | --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | tiann / weishu | LKM, `ksud boot-patch --ramdisk`, symbol relocation in `ksuinit` |
| [KernelSU-AVD](https://github.com/HChenX/KernelSU-AVD) | HChenX | end-to-end AVD ramdisk patching flow |
| [rootAVD](https://gitlab.com/newbit/rootAVD) | newbit | AVD + Magisk ramdisk approach, env-fix experience |
| [Magisk](https://github.com/topjohnwu/Magisk) | topjohnwu | `magiskboot`, ramdisk patch sequence from `boot_patch.sh` |
| [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) | LSPosed / Dr-TSNG | Zygisk implementation for KernelSU |
| [Android Emulator](https://developer.android.com/studio/run/emulator) | Google / AOSP | AVD, `-feature` and `-prop` runtime switches |

## License

[MIT](LICENSE). Upstream projects keep their own licenses (KernelSU, KernelSU-AVD, Magisk and
Zygisk Next are GPL-3.0).
