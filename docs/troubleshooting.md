# 排错手册

按「症状 → 原因 → 处理」组织，错误信息尽量保留原文，方便直接搜索。

## 一、环境与启动

### `FATAL: Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host`

- **原因**：在 x86_64 宿主机上创建了 arm64 AVD。
- **处理**：改用 `x86_64` 镜像；确实需要 arm64 时只能用 `qemu-system-aarch64` + TCG，速度不可用。

### `Another emulator instance is running. Please close it or run all emulators with -read-only flag.`

- **原因**：上一次的 qemu 进程没有完全退出，或 AVD 目录里残留 `*.lock`。
- **处理**：

```powershell
Get-Process qemu-system-x86_64, emulator -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item "D:\AndroidAVD\avd\<AVD_NAME>.avd\*.lock" -Recurse -Force
```

### `emulator: ERROR: x86_64 emulation currently requires hardware acceleration!`

- **原因**：WHPX / AEHD 都没装好。
- **处理**：`emulator -accel-check` 看具体原因；Windows 装 WHPX（Hyper-V 平台）或 AEHD，二选一。

### `USER_WARNING | Suggested minimum system RAM to run avd ... is 16384 MiB`

- **原因**：API 37 镜像建议宿主机 ≥16GB。
- **处理**：只是建议，可忽略；但把 AVD RAM 降到 2GB 会更糟，不要用降内存来解决。

### `sdkmanager --sdk_root=D:\sdk` 把包安装到了 `cmdline-tools/latest/bin/sdk/emulator`

- **原因**：在 Git Bash 里调用 `.bat` 时，`D:\\sdk` 这类参数被 shell 改写，最终变成相对路径 `sdk`。
- **处理**：不要传 `--sdk_root`，改用环境变量 `ANDROID_SDK_ROOT`；若已经装歪，把目录整体 `cp -r` 回 SDK 根目录
  （直接 `mv` 目录可能因文件占用报 `Permission denied`）。

### Node/脚本里 `adb push /data/local/tmp/...` 变成 `C:/Program Files/Git/data/local/tmp/...`

- **原因**：MSYS/Git Bash 的路径自动转换。
- **处理**：`export MSYS_NO_PATHCONV=1`，或改用 PowerShell 执行。

## 二、界面与弹窗

### `SystemUI isn't responding` / `Launcher 屡次停止运行`

- **原因**：模拟器回退到 SwiftShader 软件渲染，首启动负载过高，ViewRootImpl 的同步屏障超时。
- **处理**：
  1. 启动参数加 `-gpu host -feature -ForceSwiftshader`；
  2. 确认 `dumpsys SurfaceFlinger` 里显示的是宿主 GPU 而非 SwiftShader；
  3. 仍偶发时，写入 `settings put global hide_error_dialogs 1` 并关闭动画。

### 打开 Magisk App 弹「Requires additional setup / Recovery mode cannot get correct device info」

- **原因**：AVD 没有 boot 分区，Magisk 无法查询「安装产物」信息，把自己当成 recovery 模式。
- **处理**：点 **Cancel** 即可，root、模块、Zygisk 都不受影响。
  想要彻底没有这个提示，只能换没有该检查的旧版 Magisk（不推荐）。

### `nativebridge: Unsupported native bridge API ... version 2 not compatible with 3`

- **原因**：Magisk Zygisk 接管了 `ro.dalvik.vm.native.bridge`，与模拟器自带的 ARM 转译桥版本不兼容。
- **处理**：Zygisk 本身仍工作；若必须跑 ARM 应用，关闭 Zygisk 或改用 KernelSU。
  详见 [hardware.md](hardware.md#6-arm-转译与-zygisk-的冲突)。

## 三、Magisk

### `Incomplete Magisk install`（执行 `magisk --install-module` 时）

- **原因**：打完补丁首次开机，`/data/adb/magisk` 还是空目录，缺少 `busybox`、`util_functions.sh` 等。
- **处理**：脚本会自动补齐；手工处理时从 APK 里取
  `lib/<abi>/libmagisk.so`、`libmagiskpolicy.so`、`libbusybox.so`、`libinit-ld.so` 与 `assets/*.sh`
  放进 `/data/adb/magisk` 并 `chmod 755`、`chcon u:object_r:magisk_file:s0`。

### `Incomplete Magisk install` 之后 `su: invalid uid/gid '-c'`

- **原因**：命中的是 toybox 的 `su`，不是 Magisk 的 `su`。
- **处理**：确认 `/debug_ramdisk/su`（或 `/system/bin/su`）存在；Magisk 的 su 路径是
  `/debug_ramdisk/su`，可用 `adb shell su -c id` 验证。

### `mount: preinit dir not found`

- **原因**：Magisk 找不到 `PREINITDEVICE`（AVD 的 metadata 分区路径与真机不同）。
- **处理**：仅告警，不影响 root 与 Zygisk；可在 `.backup/.magisk` 中补 `PREINITDEVICE=metadata`。

## 四、KernelSU

### `kernelsu: Unknown symbol sidtab_search_entry (err -2)`（以及 `ebitmap_cmp`、`cond_compute_av` 等）

- **原因**：内核没有 `EXPORT_SYMBOL` 这些 SELinux 内部函数。
- **处理**：`ksuinit` 本应在加载前把这些符号改写成绝对地址，但如果内核模块加载器不接受，
  就只能换 Magisk 或自编译内核。详见 [kernelsu-limits.md](kernelsu-limits.md)。

### `kernelsu: no symbol version for module_layout` → `init_module failed`

- **原因**：内核 `CONFIG_MODVERSIONS=y` 但没有 `EXTENDED_MODVERSIONS`，模块 `__versions` 为空时被拒绝。
- **处理**：同上。给模块补 CRC 只能过这一关，后面还有重定位校验。

### `ksuinit: Cannot load kernelsu.ko: init_module failed without vermagic mismatch`

- **原因**：`ksuinit` 判定失败原因不是 vermagic，说明是符号/版本/重定位层面的问题。
- **处理**：`adb shell dmesg | grep kernelsu` 或 `logcat -b all | grep -i kernelsu` 看前一行具体错误。

### `su 0 id` 提示 `su: invalid uid/gid '-c'`

- **原因**：KernelSU 的 `su` 不支持 `-c`，语法是 `su <uid> <command>`。
- **处理**：用 `su 0 id`、`su 0 sh -c '...'`。

## 五、跨版本操作

### 换内核引导旧镜像 → `Failed to insmod '/lib/modules/virtio_blk.ko': Exec format error`

- **原因**：系统镜像里的内核模块是按自带内核版本编译的，6.12 内核加载 6.1 的模块必然失败，
  随后找不到块设备，开机卡死。
- **处理**：不要跨版本替换 `kernel-ranchu`。需要更高内核就整包换镜像（升 API）。

### 修改 ramdisk 后启动没有变化

- **原因**：模拟器只在 QEMU 启动时读取 `ramdisk.img`，`adb reboot` 不会重新加载。
- **处理**：完全关闭模拟器再启动（脚本里的 `restart_emulator` 就是这么做的），
  必要时加 `-no-snapshot-load`。

## 六、快速自检命令

```bash
adb devices
adb shell getprop sys.boot_completed
adb shell uname -r
adb shell "dumpsys SurfaceFlinger | grep -m1 '^GLES:'"
adb logcat -d -b all | grep -iE 'ksuinit|kernelsu|Magisk'
adb shell su -c id          # Magisk
adb shell su 0 id           # KernelSU
```
