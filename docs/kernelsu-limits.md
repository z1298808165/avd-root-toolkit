# 为什么 Android 13/14/15 的 AVD 用不了 KernelSU

> 结论先行：不是脚本写错，也不是 KMI 选错，而是**模拟器内核（kernel-ranchu）的能力限制**。
> Android 16/17（6.12+ 内核）可以正常使用 KernelSU LKM。

本文记录实测过程与原始日志，供后续排查参考。测试环境：`system-images;android-34;google_apis;x86_64`，
内核 `6.1.23-android14-4-00257-g7e35917775b8-ab9964412`，KernelSU v3.3.1。

## 1. LKM 的加载机制

KernelSU 3.x 在 AVD 上走 LKM 模式：

1. `ksud boot-patch --ramdisk` 把 `ksuinit` 写成 ramdisk 的 `/init`，并放入 `kernelsu.ko`；
2. 开机时 `ksuinit`（PID 1）解析 `/proc/kallsyms`，把 `.ko` 里**所有未定义符号**改写成
   `SHN_ABS` + 内核里的真实地址，再调用 `init_module()`；
3. 这一步是为了绕开「内核只允许模块引用 `EXPORT_SYMBOL` 符号」的限制。

关键点：**第 2 步依赖目标内核的模块加载器接受「绝对地址符号」**。6.12 接受，6.1 不接受。

## 2. 第一道坎：符号没有导出

直接 `insmod` 官方 LKM（不经过 ksuinit 的改写）会看到：

```text
insmod: failed to load /data/local/tmp/ko-6.12.ko: No such file or directory
[  459.476346] kernelsu: Unknown symbol mls_compute_context_len (err -2)
[  459.477247] kernelsu: Unknown symbol mls_sid_to_context (err -2)
[  459.477998] kernelsu: Unknown symbol sidtab_sid2str_put (err -2)
[  459.479170] kernelsu: Unknown symbol cond_compute_av (err -2)
[  459.480197] kernelsu: Unknown symbol ebitmap_cmp (err -2)
[  459.480645] kernelsu: Unknown symbol ebitmap_contains (err -2)
```

这些是 SELinux 内部函数。它们**存在于内核符号表**（`/proc/kallsyms` 里能看到 `T sidtab_search_entry`），
但没有 `EXPORT_SYMBOL`，所以模块无法直接引用——这正是 `ksuinit` 要做符号改写的原因。

## 3. 第二道坎：模块版本校验（MODVERSIONS）

即使符号能解决，6.1 内核还会拦一次：

```text
ksuinit[1]: Loading kernelsu.ko..
ksuinit[1]: load kernelsu with params "allow_shell=1"
kernelsu: no symbol version for module_layout
kernelsu: loading out-of-tree module taints kernel.
kernelsu: module verification failed: signature and/or required key missing - tainting kernel
ksuinit[1]: Cannot load kernelsu.ko: init_module failed without vermagic mismatch
```

- 6.1 内核 `CONFIG_MODVERSIONS=y` 但**没有** `CONFIG_EXTENDED_MODVERSIONS`，
  模块的 `__versions` 节为空 → `check_version()` 直接判 `no symbol version for module_layout` 并拒绝加载。
- 6.12 内核有 `EXTENDED_MODVERSIONS`，同样缺 `__versions` 时只打印
  `no extended symbol version for module_layout` 警告，然后**继续加载**：

```text
kernelsu: no extended symbol version for module_layout
kernelsu: loading out-of-tree module taints kernel.
KernelSU: welcome to KernelSU version 32680, package name me.weishu.kernelsu
KernelSU: shell is allowed at init!
KernelSU: sys_call_table=0xffffffffb7800270
```

这就是「同一个 LKM，Android 17 能起、Android 14 起不来」的直接原因。

## 4. 试过的补救方式（都不彻底）

| 尝试 | 结果 |
| --- | --- |
| 给 `kernelsu.ko` 补 `module_layout` 的 CRC（从设备自带 `6lowpan.ko` 的 `__versions` 里取） | 版本校验通过，但接着被下一道坎拦住 |
| 手工把符号绑成绝对地址后 `insmod` | `module: x86/modules: Skipping invalid relocation target, existing value is nonzero for type 1` |
| 用 6.12 内核引导 Android 14 镜像 | `init: Failed to insmod '/lib/modules/virtio_blk.ko': Exec format error`，找不到块设备，开机卡死 |
| 用 6.12 内核 + 6.12 ramdisk 引导 Android 14 系统 | 第一段 init 与 Android 14 的 system 分区不匹配，卡在启动 |

也就是：**6.1 的 x86 模块加载器不接受绝对地址重定位**，而 KernelSU 3.x 的 LKM 完全依赖这个技巧。

## 5. 为什么官方还提供 `android13-5.15` / `android14-6.1` 的 LKM

因为这些 LKM 是给**真机**（GKI 内核）用的：
真机的 android14-6.1 内核由 Google 打补丁、导出了上述 SELinux 符号，并且模块加载路径与模拟器不同。
模拟器用的是 `kernel-ranchu`（为 goldfish/virtio 定制的裁剪构建），两者不可混用。

官方 issue 里 tiann 也明确说过：*"I don't think AVD will work with LKM mode"*
（[tiann/KernelSU#2091](https://github.com/tiann/KernelSU/issues/2091)）。

## 6. 真要在 Android 14 上用 KernelSU，有哪些路

| 方案 | 代价 | 可行性 |
| --- | --- | --- |
| 自编译 `kernel/common` android14-6.1 + `CONFIG_KSU=y`，替换 `kernel-ranchu` | 需要 Linux 环境、30GB 源码、数小时编译 | 可行，最正统 |
| 自编译内核并给 8 个 SELinux 函数加 `EXPORT_SYMBOL` | 同上，且仍需解决重定位问题 | 可行但更绕 |
| 改用 arm64 镜像（`system-images;android-34;google_apis;arm64-v8a`） | 宿主机是 x86_64 时只能 TCG 软件翻译，冷启动 20~40 分钟，不可日用 | 可行但体验差 |
| 回退到 Android 16/17（6.12 内核） | 需要接受更高 API 的镜像 | 推荐 |
| **改用 Magisk** | 无 KernelSU 特性（如内核级 su、KernelSU 模块） | **本项目推荐** |

## 7. 给后续部署者的判断口诀

```text
内核 >= 6.12  → KernelSU 可以（EXTENDED_MODVERSIONS 放行）
内核 <= 6.6   → KernelSU LKM 不可用，直接上 Magisk
arm64 镜像    → 能加载 6.1 的 arm64 LKM，但 TCG 慢到无法使用
```

查内核版本：

```bash
adb shell uname -r
# 6.12.81-android16-6-...  → 可用
# 6.1.23-android14-4-...   → 不可用，用 Magisk
```
