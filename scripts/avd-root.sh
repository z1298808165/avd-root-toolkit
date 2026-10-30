#!/usr/bin/env bash
#
# avd-root.sh - 部署并 Root Android 模拟器（AVD），与 avd-root.ps1 行为一致。
#
# 用法：
#   ./avd-root.sh doctor
#   ./avd-root.sh install --api 34
#   ./avd-root.sh create  --api 34 --avd-name Android14_Magisk --avd-home /Volumes/SSD/avd
#   ./avd-root.sh start   --avd-name Android14_Magisk
#   ./avd-root.sh root-magisk   --avd-name Android14_Magisk --api 34
#   ./avd-root.sh root-kernelsu --avd-name Android17_KSU   --api 37
#   ./avd-root.sh zygisk-next   --avd-name Android17_KSU
#   ./avd-root.sh restore --api 34
#
# ACTIONS: doctor install create start root-magisk root-kernelsu zygisk-next restore
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------

ACTION=""
API=34
VARIANT="google_apis"
ABI="x86_64"
AVD_NAME=""
AVD_HOME=""
RAM_MB=4096
CORES=4
DATA_GB=8
SDK_ROOT="${ANDROID_SDK_ROOT:-}"
MAGISK_APK=""
KERNELSU_APK=""
ZYGISK_NEXT_ZIP=""
FORCE=0
DRY_RUN=0

WORK_DIR="${TMPDIR:-/tmp}/avd-root-toolkit"
BOOT_TIMEOUT=420
GITHUB_API="https://api.github.com/repos"

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_RESET="$(printf '\033[0m')"
  C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
else
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ok] %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '    %s[警告] %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
fail() { printf '    %s[失败] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

die() {
  fail "$*"
  exit 1
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --action)       ACTION="${2:-}"; shift 2 ;;
    --api)          API="${2:-}"; shift 2 ;;
    --variant)      VARIANT="${2:-}"; shift 2 ;;
    --abi)          ABI="${2:-}"; shift 2 ;;
    --avd-name)     AVD_NAME="${2:-}"; shift 2 ;;
    --avd-home)     AVD_HOME="${2:-}"; shift 2 ;;
    --ram-mb)       RAM_MB="${2:-}"; shift 2 ;;
    --cores)        CORES="${2:-}"; shift 2 ;;
    --data-gb)      DATA_GB="${2:-}"; shift 2 ;;
    --sdk-root)     SDK_ROOT="${2:-}"; shift 2 ;;
    --magisk-apk)   MAGISK_APK="${2:-}"; shift 2 ;;
    --kernelsu-apk) KERNELSU_APK="${2:-}"; shift 2 ;;
    --zygisk-next-zip) ZYGISK_NEXT_ZIP="${2:-}"; shift 2 ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    doctor|install|create|start|root-magisk|root-kernelsu|zygisk-next|restore)
                    ACTION="$1"; shift ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

if [ -z "$ACTION" ]; then
  usage
fi

case "$API" in
  33|34|35|36|37) ;;
  *) die "不支持的 API Level：$API（可选 33/34/35/36/37）" ;;
esac

# ---------------------------------------------------------------------------
# SDK 工具定位
# ---------------------------------------------------------------------------

resolve_sdk() {
  [ -n "$SDK_ROOT" ] || die "未设置 ANDROID_SDK_ROOT，请用 --sdk-root 指定或先导出环境变量"
  [ -d "$SDK_ROOT" ] || die "SDK 目录不存在：$SDK_ROOT"
  printf '%s\n' "$SDK_ROOT"
}

tool_path() {
  local name="$1" sdk candidate
  sdk="$(resolve_sdk)"
  case "$name" in
    adb)        candidate="$sdk/platform-tools/adb" ;;
    emulator)   candidate="$sdk/emulator/emulator" ;;
    sdkmanager) candidate="$sdk/cmdline-tools/latest/bin/sdkmanager" ;;
    avdmanager) candidate="$sdk/cmdline-tools/latest/bin/avdmanager" ;;
    *)          die "未知工具：$name" ;;
  esac
  [ -x "$candidate" ] || die "找不到工具 $name（期望路径：$candidate）"
  printf '%s\n' "$candidate"
}

# 与 tool_path 相同，但缺失时返回空串而不是退出，供体检使用
existing_tool() {
  local name="$1" sdk candidate
  sdk="$(resolve_sdk)" || return 0
  case "$name" in
    adb)        candidate="$sdk/platform-tools/adb" ;;
    emulator)   candidate="$sdk/emulator/emulator" ;;
    sdkmanager) candidate="$sdk/cmdline-tools/latest/bin/sdkmanager" ;;
    avdmanager) candidate="$sdk/cmdline-tools/latest/bin/avdmanager" ;;
    *)          return 0 ;;
  esac
  [ -x "$candidate" ] && printf '%s\n' "$candidate"
  return 0
}

image_dir_for_api() {
  case "$1" in
    33) printf 'android-33\n' ;;
    34) printf 'android-34\n' ;;
    35) printf 'android-35\n' ;;
    36) printf 'android-36\n' ;;
    37) printf 'android-37.0\n' ;;
    *)  die "不支持的 API Level：$1" ;;
  esac
}

ramdisk_path() {
  printf '%s/system-images/%s/%s/%s/ramdisk.img\n' \
    "$(resolve_sdk)" "$(image_dir_for_api "$API")" "$VARIANT" "$ABI"
}

resolve_avd_name() {
  if [ -n "$AVD_NAME" ]; then
    printf '%s\n' "$AVD_NAME"
    return
  fi
  if [ "$ACTION" = "root-kernelsu" ]; then
    printf 'Android%s_KernelSU\n' "$API"
  else
    printf 'Android%s_Magisk\n' "$API"
  fi
}

# ---------------------------------------------------------------------------
# 设备
# ---------------------------------------------------------------------------

adb_device_serial() {
  local adb wanted serial name
  adb="$(tool_path adb)"
  wanted="$(resolve_avd_name)"

  local serials=()
  while read -r serial state; do
    if [ "${state:-}" = "device" ]; then
      serials+=("$serial")
    fi
  done < <("$adb" devices | tail -n +2)

  if [ "${#serials[@]}" -eq 0 ]; then
    die "没有正在运行的模拟器。先执行：$0 start --avd-name $wanted"
  fi
  if [ "${#serials[@]}" -eq 1 ]; then
    printf '%s\n' "${serials[0]}"
    return
  fi

  for serial in "${serials[@]}"; do
    name="$("$adb" -s "$serial" shell getprop ro.boot.qemu.avd_name 2>/dev/null | tr -d '\r' || true)"
    if [ "$name" = "$wanted" ]; then
      printf '%s\n' "$serial"
      return
    fi
  done
  die "当前有多台模拟器（${serials[*]}），没有一台叫 $wanted"
}

wait_boot() {
  local serial="$1" timeout="${2:-$BOOT_TIMEOUT}" adb deadline
  adb="$(tool_path adb)"
  info "等待 $serial 开机完成（超时 ${timeout}s）"

  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      ok "设备已开机"
      return 0
    fi
    sleep 5
  done
  die "设备在 ${timeout}s 内没有完成开机"
}

restart_emulator() {
  local serial="$1" adb
  adb="$(tool_path adb)"

  # 模拟器只在 QEMU 启动时读取 ramdisk.img，必须整体重启，adb reboot 无效
  info "关闭模拟器"
  "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  sleep 6
  pkill -f 'qemu-system' >/dev/null 2>&1 || true
  sleep 2

  start_avd "$(resolve_avd_name)"
}

magisk_sqlite() {
  # 在设备侧执行 SQL。$MAGISK 需要由设备的 shell 展开，因此这里对 $ 做转义。
  local serial="$1" sql="$2" adb
  adb="$(tool_path adb)"
  "$adb" -s "$serial" shell \
    "M=\$(command -v magisk || echo /debug_ramdisk/magisk); \$M --sqlite \"$sql\""
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------

download_release_asset() {
  # $1 仓库（owner/name） $2 文件名通配符 $3 目标路径
  local repo="$1" pattern="$2" dest="$3" url

  if [ -f "$dest" ]; then
    info "使用已缓存：$(basename "$dest")"
    printf '%s\n' "$dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  command -v python3 >/dev/null 2>&1 || \
    die "需要 python3 解析 GitHub API 响应；或手动下载后用参数指定本地文件"

  info "查询 $repo 的最新 release"
  url="$(curl -fsSL -H 'User-Agent: avd-root-toolkit' \
      "$GITHUB_API/$repo/releases/latest" \
      | python3 -c '
import json, sys, fnmatch
pattern = sys.argv[1]
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    if fnmatch.fnmatch(asset["name"], pattern):
        print(asset["browser_download_url"])
        break
' "$pattern")"

  [ -n "$url" ] || die "$repo 的最新 release 里没有匹配 $pattern 的资产"

  info "下载 $(basename "$url")"
  curl -fL --retry 3 -o "$dest" "$url"
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_doctor() {
  step "环境体检"
  local sdk
  sdk="$(resolve_sdk)"
  ok "SDK 根目录：$sdk"

  local tool path
  for tool in adb emulator sdkmanager avdmanager; do
    path="$(existing_tool "$tool")"
    if [ -n "$path" ]; then
      ok "$tool：$path"
    else
      warn "$tool：缺失"
    fi
  done

  local emu
  emu="$(existing_tool emulator)"
  if [ -n "$emu" ]; then
    ok "$("$emu" -version 2>&1 | grep -m1 'emulator version' || echo '版本未知')"
    if "$emu" -accel-check 2>&1 | grep -q 'is installed and usable'; then
      ok "硬件加速：可用"
    else
      warn "硬件加速：需人工确认（运行 $emu -accel-check）"
    fi
  fi

  info "当前连接的设备："
  "$(tool_path adb)" devices | tail -n +2 | sed 's/^/      /'

  local free_gb
  free_gb=$(df -Pk "$sdk" | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
  if [ "${free_gb:-0}" -ge 25 ]; then
    ok "SDK 所在分区剩余 ${free_gb} GB"
  else
    warn "SDK 所在分区只剩 ${free_gb:-0} GB（建议 ≥25 GB）"
  fi

  local avd_home="${AVD_HOME:-$HOME/.android/avd}"
  if [ -d "$avd_home" ]; then
    info "已有 AVD（$avd_home）："
    find "$avd_home" -maxdepth 1 -name '*.ini' -exec basename {} .ini \; | sed 's/^/      /'
  else
    info "$avd_home 下还没有 AVD"
  fi
}

action_install() {
  step "安装 API $API 所需组件（$VARIANT / $ABI）"
  local sdkmanager packages
  sdkmanager="$(tool_path sdkmanager)"
  packages="emulator platform-tools system-images;android-$API;$VARIANT;$ABI"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run：$sdkmanager --sdk_root=$(resolve_sdk) $packages"
    return
  fi

  info "待安装：$packages"
  # shellcheck disable=SC2086
  yes | "$sdkmanager" --sdk_root="$(resolve_sdk)" $packages >/dev/null || \
    die "sdkmanager 执行失败，若提示 license 未接受请先手动运行一次"
  ok "SDK 组件安装完成"
}

action_create() {
  local name image_package avdmanager
  name="$(resolve_avd_name)"
  image_package="system-images;android-$API;$VARIANT;$ABI"
  avdmanager="$(tool_path avdmanager)"

  step "创建 AVD：$name（API $API）"

  local args=(create avd -n "$name" -k "$image_package" -d medium_phone --force)
  if [ -n "$AVD_HOME" ]; then
    mkdir -p "$AVD_HOME"
    args+=(-p "$AVD_HOME/$name.avd")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run：$avdmanager ${args[*]}"
    return
  fi

  printf 'no\n' | "$avdmanager" "${args[@]}" >/dev/null || die "avdmanager 执行失败"

  local config
  config="$(avd_config_path "$name")"
  tune_avd_config "$config"
  ok "AVD 已创建：$config"
}

avd_config_path() {
  local name="$1" ini avd_path
  for ini in "$HOME/.android/avd/$name.ini" "${ANDROID_AVD_HOME:-}/$name.ini"; do
    [ -n "$ini" ] || continue
    [ -f "$ini" ] || continue
    avd_path="$(sed -n 's/^path=//p' "$ini" | head -n1 | tr -d '\r')"
    [ -n "$avd_path" ] || continue
    printf '%s/config.ini\n' "$avd_path"
    return
  done
  die "找不到 AVD $name 的 config.ini"
}

tune_avd_config() {
  local config="$1" tmp
  [ -f "$config" ] || die "配置文件不存在：$config"

  step "调整 AVD 配置"
  tmp="$(mktemp)"
  cp "$config" "$tmp"

  set_key() {
    local key="$1" value="$2"
    if grep -q "^$key=" "$tmp"; then
      sed -e "s|^$key=.*|$key=$value|" "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    else
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    info "$key=$value"
  }

  set_key hw.ramSize "$RAM_MB"
  set_key hw.cpu.ncore "$CORES"
  set_key vm.heapSize 512
  set_key hw.gpu.enabled yes
  set_key hw.gpu.mode host
  set_key hw.keyboard yes
  set_key disk.dataPartition.size "${DATA_GB}G"
  set_key fastboot.forceColdBoot yes
  set_key firstboot.bootFromDownloadableSnapshot no
  set_key firstboot.saveToLocalSnapshot no

  mv "$tmp" "$config"
  ok "配置已写入：$config"
}

start_avd() {
  local name="$1" emulator
  emulator="$(tool_path emulator)"

  step "启动 $name（硬件 GPU 渲染）"
  local args=(-avd "$name" -gpu host -feature -ForceSwiftshader -netdelay none -netspeed full)
  if [ "$FORCE" -eq 1 ]; then
    args+=(-no-snapshot-load)
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run：$emulator ${args[*]}"
    return
  fi

  ( cd "$(dirname "$emulator")" && nohup "$emulator" "${args[@]}" >/dev/null 2>&1 & )

  info "等待 adb 识别设备"
  local deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 5
    if "$(tool_path adb)" devices | grep -qE 'emulator-[0-9]+[[:space:]]+device'; then
      ok "设备已上线"
      return
    fi
  done
  warn "120s 内没有识别到设备，请检查模拟器窗口"
}

action_start() {
  start_avd "$(resolve_avd_name)"
}

pristine_ramdisk() {
  # 返回未打补丁的 ramdisk；首次调用时创建备份
  local ramdisk="$1"
  if [ -f "$ramdisk.backup" ]; then
    info "使用原始备份：$ramdisk.backup"
    printf '%s\n' "$ramdisk.backup"
    return
  fi
  [ -f "$ramdisk" ] || die "找不到 ramdisk：$ramdisk（先执行 install）"
  if [ "$DRY_RUN" -eq 0 ]; then
    cp -f "$ramdisk" "$ramdisk.backup"
    info "已创建备份：$ramdisk.backup"
  fi
  printf '%s\n' "$ramdisk"
}

install_ramdisk() {
  local patched="$1" ramdisk="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run：将用 $patched 替换 $ramdisk"
    return
  fi
  cp -f "$patched" "$ramdisk"
  ok "ramdisk 已替换：$ramdisk"
}

action_root_magisk() {
  local serial kernel apk ramdisk pristine remote libdir adb
  adb="$(tool_path adb)"
  serial="$(adb_device_serial)"
  wait_boot "$serial"

  kernel="$("$adb" -s "$serial" shell uname -r | tr -d '\r')"
  step "用 Magisk 打补丁（内核 $kernel）"

  if [ -n "$MAGISK_APK" ]; then
    apk="$MAGISK_APK"
  else
    apk="$(download_release_asset topjohnwu/Magisk 'Magisk-v*.apk' "$WORK_DIR/Magisk.apk")"
  fi
  [ -f "$apk" ] || die "找不到 Magisk APK：$apk"

  ramdisk="$(ramdisk_path)"
  pristine="$(pristine_ramdisk "$ramdisk")"
  remote="/data/local/tmp/avdroot"
  libdir="lib/$ABI"

  "$adb" -s "$serial" shell "rm -rf $remote && mkdir -p $remote" >/dev/null
  info "推送 payload"
  "$adb" -s "$serial" push "$apk" "$remote/Magisk.apk" >/dev/null
  "$adb" -s "$serial" push "$pristine" "$remote/ramdisk.img" >/dev/null

  "$adb" -s "$serial" shell "cd $remote && unzip -o -q Magisk.apk '$libdir/*' 'assets/*.sh' -d ." >/dev/null || \
    die "解压 Magisk payload 失败"

  "$adb" -s "$serial" shell "cd $remote \
    && cp -f $libdir/libmagiskboot.so magiskboot \
    && cp -f $libdir/libmagisk.so magisk \
    && cp -f $libdir/libmagiskinit.so magiskinit \
    && cp -f $libdir/libinit-ld.so init-ld \
    && chmod 755 magiskboot magisk magiskinit init-ld" >/dev/null

  step "用 magiskboot 打补丁"
  local decompress
  decompress="$("$adb" -s "$serial" shell "cd $remote && ./magiskboot decompress ramdisk.img ramdisk.cpio" 2>&1 || true)"
  case "$decompress" in
    *"Detected format"*) ;;
    *) die "解压 ramdisk 失败：$decompress" ;;
  esac

  local format
  format="$(printf '%s\n' "$decompress" | sed -n 's/.*Detected format:[[:space:]]*//p' | head -n1)"
  [ -n "$format" ] || format="lz4_legacy"
  info "ramdisk 压缩格式：$format"

  local status
  status="$("$adb" -s "$serial" shell "cd $remote && ./magiskboot cpio ramdisk.cpio test" 2>&1 || true)"
  case "$status" in
    *"Magisk patched"*)
      [ "$FORCE" -eq 1 ] || die "这个 ramdisk 已被 Magisk 打过补丁；确需重打请加 --force"
      ;;
  esac

  local sha config_file
  sha="$("$adb" -s "$serial" shell "cd $remote && ./magiskboot sha1 ramdisk.img" | tr -d '\r')"
  config_file="$WORK_DIR/magisk-config"
  mkdir -p "$WORK_DIR"
  {
    printf 'KEEPVERITY=true\n'
    printf 'KEEPFORCEENCRYPT=true\n'
    printf 'RECOVERYMODE=false\n'
    printf 'VENDORBOOT=false\n'
    printf 'SHA1=%s\n' "$sha"
  } > "$config_file"
  "$adb" -s "$serial" push "$config_file" "$remote/config" >/dev/null

  "$adb" -s "$serial" shell "cd $remote \
    && ./magiskboot compress=xz magisk magisk.xz \
    && ./magiskboot compress=xz init-ld init-ld.xz" >/dev/null

  "$adb" -s "$serial" shell "cd $remote \
    && export KEEPVERITY=true KEEPFORCEENCRYPT=true \
    && ./magiskboot cpio ramdisk.cpio \
       'add 0750 init magiskinit' \
       'mkdir 0750 overlay.d' \
       'mkdir 0750 overlay.d/sbin' \
       'add 0644 overlay.d/sbin/magisk.xz magisk.xz' \
       'add 0644 overlay.d/sbin/init-ld.xz init-ld.xz' \
       'patch' \
       'mkdir 000 .backup' \
       'add 000 .backup/.magisk config'" >/dev/null || die "cpio 操作失败"

  "$adb" -s "$serial" shell "cd $remote && ./magiskboot compress=$format ramdisk.cpio patched.img" >/dev/null || \
    die "重新打包失败"

  local local_img="$WORK_DIR/ramdisk-magisk.img"
  "$adb" -s "$serial" pull "$remote/patched.img" "$local_img" >/dev/null
  install_ramdisk "$local_img" "$ramdisk"

  restart_emulator "$serial"
  local new_serial
  new_serial="$(adb_device_serial)"
  wait_boot "$new_serial"

  complete_magisk_setup "$new_serial" "$apk"
}

complete_magisk_setup() {
  local serial="$1" apk="$2" adb remote
  adb="$(tool_path adb)"
  remote="/data/local/tmp/avdroot"

  step "补齐 Magisk 运行环境"
  "$adb" -s "$serial" root >/dev/null 2>&1 || true
  sleep 4

  # 设备侧脚本单独推送，避免多层引号嵌套
  local provision="$WORK_DIR/provision-magisk.sh"
  mkdir -p "$WORK_DIR"
  cat > "$provision" <<'EOS'
#!/system/bin/sh
set -e
M=/data/adb/magisk
cd /data/local/tmp/avdroot || exit 1
mkdir -p "$M"
cp -f "lib/__ABI__/libmagisk.so"          "$M/magisk"
cp -f "lib/__ABI__/libmagiskinit.so"      "$M/magiskinit"
cp -f "lib/__ABI__/libmagiskpolicy.so"    "$M/magiskpolicy"
cp -f "lib/__ABI__/libbusybox.so"         "$M/busybox"
cp -f "lib/__ABI__/libinit-ld.so"         "$M/init-ld"
cp -f assets/*.sh                         "$M/"
chmod 755 "$M/magisk" "$M/magiskinit" "$M/magiskpolicy" "$M/busybox" "$M/init-ld" "$M"/*.sh
chcon -R u:object_r:magisk_file:s0 "$M" 2>/dev/null || true
EOS
  sed -e "s/__ABI__/$ABI/" "$provision" > "$provision.tmp" && mv "$provision.tmp" "$provision"

  "$adb" -s "$serial" push "$provision" "$remote/provision.sh" >/dev/null
  "$adb" -s "$serial" shell "sh $remote/provision.sh" >/dev/null || warn "环境补齐有告警，继续"

  info "安装 Magisk 管理器"
  "$adb" -s "$serial" install -r "$apk" >/dev/null || warn "管理器安装失败，可稍后手动安装"

  info "启用 Zygisk"
  magisk_sqlite "$serial" "REPLACE INTO settings (key,value) VALUES('zygisk',1)" \
    >/dev/null 2>&1 || warn "Zygisk 开关写入失败"

  info "给 adb shell（uid 2000）预授权 superuser"
  magisk_sqlite "$serial" "insert or replace into policies (uid,policy,until,logging,notification) values (2000,2,0,1,1)" \
    >/dev/null 2>&1 || warn "预授权写入失败"

  restart_emulator "$serial"
  local final
  final="$(adb_device_serial)"
  wait_boot "$final"

  step "结果校验"
  local id_out
  id_out="$("$adb" -s "$final" shell su -c id 2>&1 | tr -d '\r')"
  info "$id_out"
  case "$id_out" in
    uid=0*) ok "Magisk root 已生效" ;;
    *) warn "未能确认 root，请打开 Magisk App 完成一次 additional setup 后重试" ;;
  esac
}

action_root_kernelsu() {
  local serial kernel kmi apk ramdisk pristine remote adb
  adb="$(tool_path adb)"
  serial="$(adb_device_serial)"
  wait_boot "$serial"

  kernel="$("$adb" -s "$serial" shell uname -r | tr -d '\r')"
  kmi="$(printf '%s\n' "$kernel" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$kmi" ] || die "无法从内核版本推导 KMI：$kernel"
  step "用 KernelSU 打补丁（内核 $kernel，KMI $kmi）"

  case "$kernel" in
    6.1[2-9]*|6.[2-9][0-9]*|7.*) ;;
    *)
      warn "当前内核低于 6.12，官方 KernelSU LKM 极可能加载失败"
      warn "原因见 docs/kernelsu-limits.md，建议改用 root-magisk"
      ;;
  esac

  if [ -n "$KERNELSU_APK" ]; then
    apk="$KERNELSU_APK"
  else
    apk="$(download_release_asset tiann/KernelSU 'KernelSU_v*-release.apk' "$WORK_DIR/KernelSU.apk")"
  fi
  [ -f "$apk" ] || die "找不到 KernelSU APK：$apk"

  ramdisk="$(ramdisk_path)"
  pristine="$(pristine_ramdisk "$ramdisk")"
  remote="/data/local/tmp/avdroot"

  "$adb" -s "$serial" shell "rm -rf $remote && mkdir -p $remote" >/dev/null
  "$adb" -s "$serial" push "$apk" "$remote/KernelSU.apk" >/dev/null
  "$adb" -s "$serial" push "$pristine" "$remote/ramdisk.img" >/dev/null

  "$adb" -s "$serial" shell "cd $remote \
    && unzip -o -q KernelSU.apk 'lib/$ABI/libksud.so' -d . \
    && cp -f lib/$ABI/libksud.so ksud \
    && chmod 755 ksud" >/dev/null || die "解压 ksud 失败"

  info "执行 ksud boot-patch"
  "$adb" -s "$serial" shell "cd $remote \
    && ./ksud boot-patch -b ramdisk.img --ramdisk --kmi $kmi --allow-shell -o . --out-name patched.img" \
    >/dev/null || die "ksud boot-patch 失败"

  local local_img="$WORK_DIR/ramdisk-kernelsu.img"
  "$adb" -s "$serial" pull "$remote/patched.img" "$local_img" >/dev/null
  install_ramdisk "$local_img" "$ramdisk"

  restart_emulator "$serial"
  local final
  final="$(adb_device_serial)"
  wait_boot "$final"

  info "安装 KernelSU 管理器"
  "$adb" -s "$final" install -r "$apk" >/dev/null || warn "管理器安装失败，可稍后手动安装"

  step "结果校验"
  local id_out
  id_out="$("$adb" -s "$final" shell su 0 id 2>&1 | tr -d '\r')"
  info "$id_out"
  case "$id_out" in
    uid=0*) ok "KernelSU root 已生效"; info "下一步：$0 zygisk-next" ;;
    *) warn "KernelSU 没有加载成功，请对照 docs/kernelsu-limits.md" ;;
  esac
}

action_zygisk_next() {
  local serial adb
  adb="$(tool_path adb)"
  serial="$(adb_device_serial)"
  wait_boot "$serial"

  if "$adb" -s "$serial" shell test -d /data/adb/ksu >/dev/null 2>&1; then
    step "为 KernelSU 安装 Zygisk Next"
    local zip
    if [ -n "$ZYGISK_NEXT_ZIP" ]; then
      zip="$ZYGISK_NEXT_ZIP"
    else
      zip="$(download_release_asset Dr-TSNG/ZygiskNext '*release.zip' "$WORK_DIR/Zygisk-Next.zip")"
    fi
    "$adb" -s "$serial" push "$zip" /data/local/tmp/zygisk-next.zip >/dev/null
    "$adb" -s "$serial" shell "su 0 /data/adb/ksu/bin/ksud module install /data/local/tmp/zygisk-next.zip" \
      >/dev/null || die "ksud module install 失败"

    restart_emulator "$serial"
    local final
    final="$(adb_device_serial)"
    wait_boot "$final"
    "$adb" -s "$final" shell "su 0 /data/adb/ksu/bin/znctl status" 2>/dev/null | \
      grep -E 'version:|inject_state|root_status' | sed 's/^/      /' || true
    return
  fi

  if "$adb" -s "$serial" shell test -d /data/adb/magisk >/dev/null 2>&1; then
    step "为 Magisk 启用内置 Zygisk"
    "$adb" -s "$serial" root >/dev/null 2>&1 || true
    sleep 4
    magisk_sqlite "$serial" "REPLACE INTO settings (key,value) VALUES('zygisk',1)" \
      >/dev/null 2>&1 || die "Zygisk 开关写入失败"

    restart_emulator "$serial"
    local final2
    final2="$(adb_device_serial)"
    wait_boot "$final2"
    ok "Zygisk 已启用（Magisk 内置），可用 Zygisk 模块验证"
    return
  fi

  die "设备上没有检测到 Magisk 或 KernelSU"
}

action_restore() {
  local ramdisk
  ramdisk="$(ramdisk_path)"

  step "还原未 Root 的 ramdisk"
  [ -f "$ramdisk.backup" ] || die "没有找到备份：$ramdisk.backup"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run：cp $ramdisk.backup $ramdisk"
    return
  fi
  cp -f "$ramdisk.backup" "$ramdisk"
  ok "已还原，重启模拟器即可回到未 Root 状态"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

mkdir -p "$WORK_DIR"

case "$ACTION" in
  doctor)        action_doctor ;;
  install)       action_install ;;
  create)        action_create ;;
  start)         action_start ;;
  root-magisk)   action_root_magisk ;;
  root-kernelsu) action_root_kernelsu ;;
  zygisk-next)   action_zygisk_next ;;
  restore)       action_restore ;;
  *)             die "未知 action：$ACTION" ;;
esac
