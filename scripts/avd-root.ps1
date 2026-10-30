#Requires -Version 7.0
<#
.SYNOPSIS
    部署并 Root 本地 Android 模拟器（AVD），支持 Magisk 与 KernelSU 两种方式。

.DESCRIPTION
    一个入口覆盖模拟器的完整生命周期：安装 SDK 组件、在指定磁盘创建 AVD、以硬件 GPU 渲染启动、
    用 Magisk 或 KernelSU 给 ramdisk 打补丁、安装 Zygisk 支持。

    所有 action 尽量保持幂等；修改 `ramdisk.img` 之前会在同目录留下 `ramdisk.img.backup`。

.PARAMETER Action
    doctor         体检：SDK、虚拟化、GPU、磁盘空间、已有 AVD。
    install        安装 emulator / platform-tools 与 -Api 对应的系统镜像。
    create         创建 AVD（数据目录由 -AvdHome 指定）并调整 config.ini。
    start          以硬件 GPU 渲染冷启动 AVD。
    root-magisk    用 Magisk 打 ramdisk、补齐运行环境、启用 Zygisk。
    root-kernelsu  用 KernelSU（LKM 模式）打 ramdisk 并安装管理器。
    zygisk-next    KernelSU 装 Zygisk Next；Magisk 则启用内置 Zygisk。
    restore        从 ramdisk.img.backup 还原未 Root 的 ramdisk。

.EXAMPLE
    .\avd-root.ps1 -Action doctor

.EXAMPLE
    .\avd-root.ps1 -Action install -Api 34
    .\avd-root.ps1 -Action create -Api 34 -AvdName Android14_Magisk -AvdHome D:\AndroidAVD\avd
    .\avd-root.ps1 -Action start -AvdName Android14_Magisk
    .\avd-root.ps1 -Action root-magisk -AvdName Android14_Magisk -Api 34
#>

# ACTIONS: doctor install create start root-magisk root-kernelsu zygisk-next restore

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('doctor', 'install', 'create', 'start', 'root-magisk', 'root-kernelsu', 'zygisk-next', 'restore')]
    [string]$Action,

    [ValidateSet(33, 34, 35, 36, 37)]
    [int]$Api = 34,

    [ValidateSet('google_apis', 'google_apis_playstore', 'default')]
    [string]$Variant = 'google_apis',

    [ValidateSet('x86_64', 'arm64-v8a')]
    [string]$Abi = 'x86_64',

    [string]$AvdName,

    [string]$AvdHome,

    [ValidateRange(2048, 16384)]
    [int]$RamMb = 4096,

    [ValidateRange(1, 16)]
    [int]$Cores = 4,

    [ValidateRange(6, 64)]
    [int]$DataGb = 8,

    [string]$SdkRoot = $env:ANDROID_SDK_ROOT,

    [string]$MagiskApk,

    [string]$KernelSuApk,

    [string]$ZygiskNextZip,

    [switch]$Force,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) 'avd-root-toolkit'
$script:BootTimeoutSec = 420
$script:GitHubApi = 'https://api.github.com/repos'

# API Level 与系统镜像目录名的映射（API 37 的目录名带小版本号）
$script:ImageDirByApi = @{
    33 = 'android-33'
    34 = 'android-34'
    35 = 'android-35'
    36 = 'android-36'
    37 = 'android-37.0'
}

# ---------------------------------------------------------------------------
# 控制台输出
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    [ok] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    [警告] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    [失败] $Message" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# 进程封装
# ---------------------------------------------------------------------------

function Invoke-Native {
    <#
        执行外部命令，合并 stdout/stderr，非零退出码时抛错。
        InputText 用于需要 stdin 应答的场景（avdmanager 会问是否自定义硬件）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$InputText,
        [switch]$AllowFailure
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $output = $InputText | & $FilePath @Arguments 2>&1 | Out-String
        }
        else {
            $output = & $FilePath @Arguments 2>&1 | Out-String
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "命令执行失败（退出码 $code）：$FilePath $($Arguments -join ' ')`n$output"
    }

    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

# ---------------------------------------------------------------------------
# SDK 相关
# ---------------------------------------------------------------------------

function Resolve-Sdk {
    if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
        throw '未设置 ANDROID_SDK_ROOT，请用 -SdkRoot D:\sdk 指定或先设置环境变量。'
    }
    if (-not (Test-Path -LiteralPath $SdkRoot)) {
        throw "SDK 目录不存在：$SdkRoot"
    }
    return (Resolve-Path -LiteralPath $SdkRoot).Path
}

function Get-ToolPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $sdk = Resolve-Sdk
    $candidates = switch ($Name) {
        'adb' { @((Join-Path $sdk 'platform-tools\adb.exe')) }
        'emulator' { @((Join-Path $sdk 'emulator\emulator.exe')) }
        'sdkmanager' { @((Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat')) }
        'avdmanager' { @((Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat')) }
        default { @() }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw "找不到工具 $Name（已查找：$($candidates -join '、')）"
}

function Get-ImageDir {
    param([Parameter(Mandatory = $true)][int]$ApiLevel)

    if (-not $script:ImageDirByApi.ContainsKey($ApiLevel)) {
        throw "不支持的 API Level：$ApiLevel"
    }
    $sdk = Resolve-Sdk
    return (Join-Path $sdk "system-images\$($script:ImageDirByApi[$ApiLevel])\$Variant\$Abi")
}

function Get-RamdiskPath {
    return (Join-Path (Get-ImageDir -ApiLevel $Api) 'ramdisk.img')
}

function Resolve-AvdName {
    if (-not [string]::IsNullOrWhiteSpace($AvdName)) {
        return $AvdName
    }
    $suffix = if ($Action -eq 'root-kernelsu') { 'KernelSU' } else { 'Magisk' }
    return "Android${Api}_$suffix"
}

# ---------------------------------------------------------------------------
# 设备相关
# ---------------------------------------------------------------------------

function Get-AdbDeviceSerial {
    <#
        返回正在运行的模拟器 serial。接了多台设备时，优先选择 AVD 名匹配的那台。
    #>
    $adb = Get-ToolPath -Name 'adb'
    $result = Invoke-Native -FilePath $adb -Arguments @('devices')

    $serials = @()
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^(emulator-\d+)\s+device$') {
            $serials += $Matches[1]
        }
    }
    if ($serials.Count -eq 0) {
        throw '没有正在运行的模拟器。先执行 -Action start。'
    }
    if ($serials.Count -eq 1) {
        return $serials[0]
    }

    $wanted = Resolve-AvdName
    foreach ($serial in $serials) {
        $name = (& $adb -s $serial shell getprop ro.boot.qemu.avd_name 2>&1 | Out-String).Trim()
        if ($name -eq $wanted) {
            return $serial
        }
    }
    throw "当前有多台模拟器（$($serials -join '、')），但没有一台叫 $wanted。"
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $adb = Get-ToolPath -Name 'adb'
    $final = @('-s', $Serial) + $Arguments
    return Invoke-Native -FilePath $adb -Arguments $final -AllowFailure:$AllowFailure
}

function Wait-DeviceBoot {
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [int]$TimeoutSec = $script:BootTimeoutSec
    )

    Write-Info "等待 $Serial 开机完成（超时 ${TimeoutSec}s）"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $probe = Invoke-Adb -Serial $Serial -Arguments @('shell', 'getprop', 'sys.boot_completed') -AllowFailure
        if ($probe.Output.Trim() -eq '1') {
            Write-Ok '设备已开机'
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "设备在 ${TimeoutSec}s 内没有完成开机"
}

function Get-DeviceProp {
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $result = Invoke-Adb -Serial $Serial -Arguments @('shell', 'getprop', $Name)
    return $result.Output.Trim()
}

function Get-KmiFromKernel {
    param([Parameter(Mandatory = $true)][string]$KernelRelease)

    if ($KernelRelease -match '(android\d+)-(\d+\.\d+)') {
        return "$($Matches[1])-$($Matches[2])"
    }
    throw "无法从内核版本推导 KMI：$KernelRelease"
}

function Restart-Emulator {
    <#
        模拟器只在 QEMU 启动时读取 ramdisk.img，所以补丁必须靠「完全重启模拟器」生效，
        `adb reboot` 是不够的。
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)

    Write-Info '关闭模拟器'
    Invoke-Adb -Serial $Serial -Arguments @('emu', 'kill') -AllowFailure | Out-Null
    Start-Sleep -Seconds 6
    Get-Process -Name 'qemu-system-x86_64', 'emulator' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Start-Avd -Name (Resolve-AvdName)
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------

function Get-GitHubAsset {
    <#
        按仓库 + 文件名通配符下载 release 资产。API 限流时给出明确提示。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Write-Info "使用已缓存：$(Split-Path -Leaf $Destination)"
        return $Destination
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Info "查询 $Repository 的最新 release"
    try {
        $release = Invoke-RestMethod -Uri "$script:GitHubApi/$Repository/releases/latest" `
            -Headers @{ 'User-Agent' = 'avd-root-toolkit' }
    }
    catch {
        throw "无法访问 GitHub releases（$($_.Exception.Message)）。请手动下载后通过参数指定本地文件。"
    }

    $asset = $release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) {
        throw "$Repository $($release.tag_name) 中没有匹配 '$Pattern' 的资产"
    }

    Write-Info "下载 $($asset.name)（$([math]::Round($asset.size / 1MB, 1)) MB）"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $Destination `
        -Headers @{ 'User-Agent' = 'avd-root-toolkit' }
    return $Destination
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Invoke-Doctor {
    Write-Step '环境体检'

    try {
        $sdk = Resolve-Sdk
        Write-Ok "SDK 根目录：$sdk"
    }
    catch {
        Write-Err $_.Exception.Message
        return
    }

    foreach ($tool in @('adb', 'emulator', 'sdkmanager', 'avdmanager')) {
        try {
            Write-Ok "$tool : $(Get-ToolPath -Name $tool)"
        }
        catch {
            Write-Warn "$tool : 缺失"
        }
    }

    try {
        $emu = Get-ToolPath -Name 'emulator'
        $version = (Invoke-Native -FilePath $emu -Arguments @('-version') -AllowFailure).Output
        $line = ($version -split "`r?`n" | Where-Object { $_ -match 'emulator version' } | Select-Object -First 1)
        if ($line) { Write-Ok $line.Trim() }
    }
    catch {
        Write-Warn '无法读取 emulator 版本'
    }

    try {
        $emu = Get-ToolPath -Name 'emulator'
        $accel = (Invoke-Native -FilePath $emu -Arguments @('-accel-check') -AllowFailure).Output
        if ($accel -match 'is installed and usable') {
            Write-Ok '硬件加速：可用'
        }
        else {
            Write-Warn '硬件加速：需要人工确认，输出如下'
            Write-Info (($accel.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' ')
        }
    }
    catch {
        Write-Warn '硬件加速检查失败'
    }

    try {
        $adb = Get-ToolPath -Name 'adb'
        $devices = (Invoke-Native -FilePath $adb -Arguments @('devices')).Output.Trim()
        Write-Info '当前连接的设备：'
        ($devices -split "`r?`n" | Select-Object -Skip 1) |
            Where-Object { $_.Trim() } |
            ForEach-Object { Write-Info "  $(($_ -replace '\s+', ' ').Trim())" }
    }
    catch {
        Write-Warn '无法列出设备'
    }

    $root = [System.IO.Path]::GetPathRoot((Resolve-Sdk))
    $drive = $root.TrimEnd('\', ':')
    $freeGb = [math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 1)
    if ($freeGb -ge 25) { Write-Ok "SDK 所在盘剩余 ${freeGb} GB" }
    else { Write-Warn "SDK 所在盘只剩 ${freeGb} GB（建议 ≥25 GB）" }

    $avdHomePath = if ($AvdHome) { $AvdHome } else { Join-Path $env:USERPROFILE '.android\avd' }
    if (Test-Path -LiteralPath $avdHomePath) {
        $avds = Get-ChildItem -LiteralPath $avdHomePath -Filter '*.ini' -ErrorAction SilentlyContinue
        if ($avds) {
            Write-Info "已有 AVD（$avdHomePath）："
            $avds | ForEach-Object { Write-Info "  $($_.BaseName)" }
        }
        else {
            Write-Info "$avdHomePath 下还没有 AVD"
        }
    }
}

function Invoke-Install {
    Write-Step "安装 API $Api 所需组件（$Variant / $Abi）"

    $sdkmanager = Get-ToolPath -Name 'sdkmanager'
    $packages = @(
        'emulator',
        'platform-tools',
        "system-images;android-$Api;$Variant;$Abi"
    )
    $arguments = @("--sdk_root=$((Resolve-Sdk))") + $packages

    if ($DryRun) {
        Write-Info "dry run：sdkmanager $($arguments -join ' ')"
        return
    }

    Write-Info "待安装：$($packages -join '，')"
    $result = Invoke-Native -FilePath $sdkmanager -Arguments $arguments -InputText 'y' -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "sdkmanager 执行失败，若提示 license 未接受请先手动运行一次：`n$($result.Output)"
    }
    Write-Ok 'SDK 组件安装完成'
}

function Invoke-Create {
    $name = Resolve-AvdName
    Write-Step "创建 AVD：$name（API $Api）"

    $imagePackage = "system-images;android-$Api;$Variant;$Abi"
    $avdmanager = Get-ToolPath -Name 'avdmanager'
    $arguments = @('create', 'avd', '-n', $name, '-k', $imagePackage, '-d', 'medium_phone', '--force')

    if ($AvdHome) {
        if (-not (Test-Path -LiteralPath $AvdHome)) {
            New-Item -ItemType Directory -Path $AvdHome -Force | Out-Null
        }
        $arguments += @('-p', (Join-Path $AvdHome "$name.avd"))
    }

    if ($DryRun) {
        Write-Info "dry run：avdmanager $($arguments -join ' ')"
        return
    }

    $result = Invoke-Native -FilePath $avdmanager -Arguments $arguments -InputText 'no' -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "avdmanager 执行失败：`n$($result.Output)"
    }

    $configPath = Get-AvdConfigPath -Name $name
    Set-AvdConfig -Path $configPath
    Write-Ok "AVD 已创建：$configPath"
}

function Get-AvdConfigPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    # 即使数据目录用 -p 指到了别的盘，.ini 仍然在标准 AVD 目录里
    $iniCandidates = @(
        (Join-Path $env:USERPROFILE ".android\avd\$Name.ini"),
        (Join-Path $env:ANDROID_AVD_HOME "$Name.ini")
    )
    foreach ($candidate in $iniCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $pathLine = (Get-Content -LiteralPath $candidate |
                Where-Object { $_ -match '^path=' } | Select-Object -First 1)
            if ($pathLine) {
                $avdPath = $pathLine.Substring(5).Trim()
                return (Join-Path $avdPath 'config.ini')
            }
        }
    }
    throw "找不到 AVD $Name 的 config.ini"
}

function Set-AvdConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    Write-Step '调整 AVD 配置'
    $content = Get-Content -LiteralPath $Path -Raw
    $overrides = [ordered]@{
        'hw.ramSize'                              = "$RamMb"
        'hw.cpu.ncore'                            = "$Cores"
        'vm.heapSize'                             = '512'
        'hw.gpu.enabled'                          = 'yes'
        'hw.gpu.mode'                             = 'host'
        'hw.keyboard'                             = 'yes'
        'disk.dataPartition.size'                 = "${DataGb}G"
        'fastboot.forceColdBoot'                  = 'yes'
        'firstboot.bootFromDownloadableSnapshot'  = 'no'
        'firstboot.saveToLocalSnapshot'           = 'no'
    }

    foreach ($key in $overrides.Keys) {
        $value = $overrides[$key]
        if ($content -match "(?m)^$([regex]::Escape($key))=") {
            $content = [regex]::Replace($content, "(?m)^$([regex]::Escape($key))=.*$", "$key=$value")
        }
        else {
            $content = $content.TrimEnd() + "`n$key=$value`n"
        }
        Write-Info "$key=$value"
    }

    Set-Content -LiteralPath $Path -Value $content -NoNewline
    Write-Ok "配置已写入：$Path"
}

function Start-Avd {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Step "启动 $Name（硬件 GPU 渲染）"
    $emulator = Get-ToolPath -Name 'emulator'
    $arguments = @(
        '-avd', $Name,
        '-gpu', 'host',
        '-feature', '-ForceSwiftshader',
        '-netdelay', 'none',
        '-netspeed', 'full'
    )
    if ($Force) {
        $arguments += '-no-snapshot-load'
    }

    if ($DryRun) {
        Write-Info "dry run：emulator $($arguments -join ' ')"
        return
    }

    Start-Process -FilePath $emulator -ArgumentList $arguments `
        -WorkingDirectory (Join-Path (Resolve-Sdk) 'emulator') | Out-Null

    Write-Info '等待 adb 识别设备'
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $probe = Invoke-Native -FilePath (Get-ToolPath -Name 'adb') -Arguments @('devices') -AllowFailure
        if ($probe.Output -match 'emulator-\d+\s+device') {
            Write-Ok '设备已上线'
            return
        }
    }
    Write-Warn '120s 内没有识别到设备，请检查模拟器窗口'
}

function Invoke-Start {
    Start-Avd -Name (Resolve-AvdName)
}

function Get-PristineRamdisk {
    <#
        返回未打补丁的 ramdisk：优先用备份，没有备份则用当前镜像并立刻创建备份。
    #>
    param([Parameter(Mandatory = $true)][string]$Ramdisk)

    $backup = "$Ramdisk.backup"
    if (Test-Path -LiteralPath $backup) {
        Write-Info "使用原始备份：$backup"
        return $backup
    }
    if (-not (Test-Path -LiteralPath $Ramdisk)) {
        throw "找不到 ramdisk：$Ramdisk（先执行 -Action install）"
    }
    if (-not $DryRun) {
        Copy-Item -LiteralPath $Ramdisk -Destination $backup -Force
        Write-Info "已创建备份：$backup"
    }
    return $Ramdisk
}

function Install-Ramdisk {
    param(
        [Parameter(Mandatory = $true)][string]$Patched,
        [Parameter(Mandatory = $true)][string]$Ramdisk
    )

    if ($DryRun) {
        Write-Info "dry run：将用 $Patched 替换 $Ramdisk"
        return
    }
    Copy-Item -LiteralPath $Patched -Destination $Ramdisk -Force
    Write-Ok "ramdisk 已替换：$Ramdisk"
}

function Invoke-RootMagisk {
    $serial = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $serial

    $kernel = (Invoke-Adb -Serial $serial -Arguments @('shell', 'uname', '-r')).Output.Trim()
    Write-Step "用 Magisk 打补丁（内核 $kernel）"

    $apk = if ($MagiskApk) { $MagiskApk } else {
        Get-GitHubAsset -Repository 'topjohnwu/Magisk' -Pattern 'Magisk-v*.apk' `
            -Destination (Join-Path $script:WorkDir 'Magisk.apk')
    }
    if (-not (Test-Path -LiteralPath $apk)) { throw "找不到 Magisk APK：$apk" }

    $ramdisk = Get-RamdiskPath
    $pristine = Get-PristineRamdisk -Ramdisk $ramdisk

    $remote = '/data/local/tmp/avdroot'
    Invoke-Adb -Serial $serial -Arguments @('shell', 'rm', '-rf', $remote) | Out-Null
    Invoke-Adb -Serial $serial -Arguments @('shell', 'mkdir', '-p', $remote) | Out-Null

    Write-Info '推送 payload'
    Invoke-Adb -Serial $serial -Arguments @('push', $apk, "$remote/Magisk.apk") | Out-Null
    Invoke-Adb -Serial $serial -Arguments @('push', $pristine, "$remote/ramdisk.img") | Out-Null

    $libDir = "lib/$Abi"
    $extract = Invoke-Adb -Serial $serial -Arguments @(
        'shell', "cd $remote && unzip -o -q Magisk.apk '$libDir/*' 'assets/*.sh' -d ."
    ) -AllowFailure
    if ($extract.ExitCode -ne 0) { throw "解压 Magisk payload 失败：`n$($extract.Output)" }

    $setup = @(
        "cd $remote",
        "cp -f $libDir/libmagiskboot.so magiskboot",
        "cp -f $libDir/libmagisk.so magisk",
        "cp -f $libDir/libmagiskinit.so magiskinit",
        "cp -f $libDir/libinit-ld.so init-ld",
        "chmod 755 magiskboot magisk magiskinit init-ld"
    ) -join ' && '
    Invoke-Adb -Serial $serial -Arguments @('shell', $setup) | Out-Null

    Write-Step '用 magiskboot 打补丁'
    $decompress = Invoke-Adb -Serial $serial -Arguments @(
        'shell', "cd $remote && ./magiskboot decompress ramdisk.img ramdisk.cpio"
    ) -AllowFailure
    if ($decompress.ExitCode -ne 0) { throw "解压 ramdisk 失败：`n$($decompress.Output)" }

    $format = 'lz4_legacy'
    if ($decompress.Output -match 'Detected format:\s*(\S+)') { $format = $Matches[1] }
    Write-Info "ramdisk 压缩格式：$format"

    $status = Invoke-Adb -Serial $serial -Arguments @('shell', "cd $remote && ./magiskboot cpio ramdisk.cpio test") -AllowFailure
    if ($status.Output -match 'Magisk patched' -or $status.ExitCode -eq 1) {
        if (-not $Force) {
            throw '这个 ramdisk 已经被 Magisk 打过补丁；确需重打请加 -Force（会用备份重来）。'
        }
    }

    $sha = (Invoke-Adb -Serial $serial -Arguments @('shell', "cd $remote && ./magiskboot sha1 ramdisk.img")).Output.Trim()
    $config = @(
        'KEEPVERITY=true',
        'KEEPFORCEENCRYPT=true',
        'RECOVERYMODE=false',
        'VENDORBOOT=false',
        "SHA1=$sha"
    ) -join "`n"
    $configPath = Join-Path $script:WorkDir 'magisk-config'
    Set-Content -LiteralPath $configPath -Value $config -NoNewline
    Invoke-Adb -Serial $serial -Arguments @('push', $configPath, "$remote/config") | Out-Null

    $compress = @(
        "cd $remote",
        './magiskboot compress=xz magisk magisk.xz',
        './magiskboot compress=xz init-ld init-ld.xz'
    ) -join ' && '
    Invoke-Adb -Serial $serial -Arguments @('shell', $compress) | Out-Null

    $ops = @(
        "cd $remote",
        'export KEEPVERITY=true KEEPFORCEENCRYPT=true',
        "./magiskboot cpio ramdisk.cpio 'add 0750 init magiskinit' 'mkdir 0750 overlay.d' 'mkdir 0750 overlay.d/sbin' 'add 0644 overlay.d/sbin/magisk.xz magisk.xz' 'add 0644 overlay.d/sbin/init-ld.xz init-ld.xz' 'patch' 'mkdir 000 .backup' 'add 000 .backup/.magisk config'"
    ) -join ' && '
    $patch = Invoke-Adb -Serial $serial -Arguments @('shell', $ops) -AllowFailure
    if ($patch.ExitCode -ne 0) { throw "cpio 操作失败：`n$($patch.Output)" }

    $repack = Invoke-Adb -Serial $serial -Arguments @(
        'shell', "cd $remote && ./magiskboot compress=$format ramdisk.cpio patched.img"
    ) -AllowFailure
    if ($repack.ExitCode -ne 0) { throw "重新打包失败：`n$($repack.Output)" }

    $local = Join-Path $script:WorkDir 'ramdisk-magisk.img'
    Invoke-Adb -Serial $serial -Arguments @('pull', "$remote/patched.img", $local) | Out-Null
    Install-Ramdisk -Patched $local -Ramdisk $ramdisk

    Restart-Emulator -Serial $serial
    $newSerial = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $newSerial

    Complete-MagiskSetup -Serial $newSerial -Apk $apk
}

function Complete-MagiskSetup {
    <#
        打完补丁的首次开机，/data/adb/magisk 是空的，`magisk --install-module` 会报
        "Incomplete Magisk install"。这里补齐运行环境、装管理器、开 Zygisk、给 shell 预授权。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Apk
    )

    Write-Step '补齐 Magisk 运行环境'
    Invoke-Adb -Serial $Serial -Arguments @('root') -AllowFailure | Out-Null
    Start-Sleep -Seconds 4

    $remote = '/data/local/tmp/avdroot'
    $provision = @(
        'M=/data/adb/magisk',
        'mkdir -p $M',
        "cd $remote",
        "cp -f lib/$Abi/libmagisk.so \$M/magisk",
        "cp -f lib/$Abi/libmagiskinit.so \$M/magiskinit",
        "cp -f lib/$Abi/libmagiskpolicy.so \$M/magiskpolicy",
        "cp -f lib/$Abi/libbusybox.so \$M/busybox",
        "cp -f lib/$Abi/libinit-ld.so \$M/init-ld",
        'cp -f assets/*.sh $M/',
        'chmod 755 $M/magisk $M/magiskinit $M/magiskpolicy $M/busybox $M/init-ld $M/*.sh',
        'chcon -R u:object_r:magisk_file:s0 $M 2>/dev/null || true'
    ) -join '; '
    Invoke-Adb -Serial $Serial -Arguments @('shell', $provision) | Out-Null

    Write-Info '安装 Magisk 管理器'
    Invoke-Adb -Serial $Serial -Arguments @('install', '-r', $Apk) | Out-Null

    Write-Info '启用 Zygisk'
    $enable = 'MAGISK=$(command -v magisk || echo /debug_ramdisk/magisk); $MAGISK --sqlite "REPLACE INTO settings (key,value) VALUES(''zygisk'',1)"'
    Invoke-Adb -Serial $Serial -Arguments @('shell', $enable) -AllowFailure | Out-Null

    Write-Info '给 adb shell（uid 2000）预授权 superuser'
    $grant = 'MAGISK=$(command -v magisk || echo /debug_ramdisk/magisk); $MAGISK --sqlite "insert or replace into policies (uid,policy,until,logging,notification) values (2000,2,0,1,1)"'
    Invoke-Adb -Serial $Serial -Arguments @('shell', $grant) -AllowFailure | Out-Null

    Restart-Emulator -Serial $Serial
    $final = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $final

    Write-Step '结果校验'
    $id = Invoke-Adb -Serial $final -Arguments @('shell', 'su', '-c', 'id') -AllowFailure
    Write-Info $id.Output.Trim()
    if ($id.Output -match 'uid=0') {
        Write-Ok 'Magisk root 已生效'
    }
    else {
        Write-Warn '未能确认 root，请打开 Magisk App 完成一次 additional setup 后重试'
    }
}

function Invoke-RootKernelSu {
    $serial = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $serial

    $kernel = (Invoke-Adb -Serial $serial -Arguments @('shell', 'uname', '-r')).Output.Trim()
    $kmi = Get-KmiFromKernel -KernelRelease $kernel
    Write-Step "用 KernelSU 打补丁（内核 $kernel，KMI $kmi）"

    if ($kernel -notmatch '^6\.(1[2-9]|[2-9][0-9])' -and $kernel -notmatch '^7\.') {
        Write-Warn '当前内核低于 6.12，官方 KernelSU LKM 极可能加载失败'
        Write-Warn '原因见 docs/kernelsu-limits.md，建议改用 -Action root-magisk'
    }

    $apk = if ($KernelSuApk) { $KernelSuApk } else {
        Get-GitHubAsset -Repository 'tiann/KernelSU' -Pattern 'KernelSU_v*-release.apk' `
            -Destination (Join-Path $script:WorkDir 'KernelSU.apk')
    }
    if (-not (Test-Path -LiteralPath $apk)) { throw "找不到 KernelSU APK：$apk" }

    $ramdisk = Get-RamdiskPath
    $pristine = Get-PristineRamdisk -Ramdisk $ramdisk
    $remote = '/data/local/tmp/avdroot'

    Invoke-Adb -Serial $serial -Arguments @('shell', 'rm', '-rf', $remote) | Out-Null
    Invoke-Adb -Serial $serial -Arguments @('shell', 'mkdir', '-p', $remote) | Out-Null
    Invoke-Adb -Serial $serial -Arguments @('push', $apk, "$remote/KernelSU.apk") | Out-Null
    Invoke-Adb -Serial $serial -Arguments @('push', $pristine, "$remote/ramdisk.img") | Out-Null

    $extract = "cd $remote && unzip -o -q KernelSU.apk 'lib/$Abi/libksud.so' -d . && cp -f lib/$Abi/libksud.so ksud && chmod 755 ksud"
    $result = Invoke-Adb -Serial $serial -Arguments @('shell', $extract) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "解压 ksud 失败：`n$($result.Output)" }

    Write-Info '执行 ksud boot-patch'
    $patch = "cd $remote && ./ksud boot-patch -b ramdisk.img --ramdisk --kmi $kmi --allow-shell -o . --out-name patched.img"
    $result = Invoke-Adb -Serial $serial -Arguments @('shell', $patch) -AllowFailure
    if ($result.ExitCode -ne 0) { throw "ksud boot-patch 失败：`n$($result.Output)" }
    Write-Info (($result.Output.Trim() -split "`r?`n" | Select-Object -Last 6) -join ' | ')

    $local = Join-Path $script:WorkDir 'ramdisk-kernelsu.img'
    Invoke-Adb -Serial $serial -Arguments @('pull', "$remote/patched.img", $local) | Out-Null
    Install-Ramdisk -Patched $local -Ramdisk $ramdisk

    Restart-Emulator -Serial $serial
    $final = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $final

    Write-Info '安装 KernelSU 管理器'
    Invoke-Adb -Serial $final -Arguments @('install', '-r', $apk) -AllowFailure | Out-Null

    Write-Step '结果校验'
    $id = Invoke-Adb -Serial $final -Arguments @('shell', 'su', '0', 'id') -AllowFailure
    Write-Info $id.Output.Trim()
    if ($id.Output -match 'uid=0') {
        Write-Ok 'KernelSU root 已生效'
        Write-Info '下一步安装 Zygisk Next：-Action zygisk-next'
    }
    else {
        Write-Warn 'KernelSU 没有加载成功，请对照 docs/kernelsu-limits.md'
    }
}

function Invoke-ZygiskNext {
    $serial = Get-AdbDeviceSerial
    Wait-DeviceBoot -Serial $serial

    $isKernelSu = (Invoke-Adb -Serial $serial -Arguments @('shell', 'test', '-d', '/data/adb/ksu') -AllowFailure).ExitCode -eq 0
    $isMagisk = (Invoke-Adb -Serial $serial -Arguments @('shell', 'test', '-d', '/data/adb/magisk') -AllowFailure).ExitCode -eq 0

    if ($isKernelSu) {
        Write-Step '为 KernelSU 安装 Zygisk Next'
        $zip = if ($ZygiskNextZip) { $ZygiskNextZip } else {
            Get-GitHubAsset -Repository 'Dr-TSNG/ZygiskNext' -Pattern '*release.zip' `
                -Destination (Join-Path $script:WorkDir 'Zygisk-Next.zip')
        }
        Invoke-Adb -Serial $serial -Arguments @('push', $zip, '/data/local/tmp/zygisk-next.zip') | Out-Null

        $install = 'su 0 /data/adb/ksu/bin/ksud module install /data/local/tmp/zygisk-next.zip'
        $result = Invoke-Adb -Serial $serial -Arguments @('shell', $install) -AllowFailure
        Write-Info (($result.Output.Trim() -split "`r?`n" | Select-Object -Last 5) -join ' | ')
        if ($result.ExitCode -ne 0) { throw 'ksud module install 失败' }

        Restart-Emulator -Serial $serial
        $final = Get-AdbDeviceSerial
        Wait-DeviceBoot -Serial $final

        $status = Invoke-Adb -Serial $final -Arguments @('shell', 'su', '0', '/data/adb/ksu/bin/znctl', 'status') -AllowFailure
        Write-Info (($status.Output.Trim() -split "`r?`n" |
            Where-Object { $_ -match 'version:|inject_state|root_status' }) -join ' | ')
        return
    }

    if ($isMagisk) {
        Write-Step '为 Magisk 启用内置 Zygisk'
        Invoke-Adb -Serial $serial -Arguments @('root') -AllowFailure | Out-Null
        Start-Sleep -Seconds 4

        $enable = 'MAGISK=$(command -v magisk || echo /debug_ramdisk/magisk); $MAGISK --sqlite "REPLACE INTO settings (key,value) VALUES(''zygisk'',1)" && $MAGISK --sqlite "select * from settings"'
        $result = Invoke-Adb -Serial $serial -Arguments @('shell', $enable) -AllowFailure
        Write-Info (($result.Output.Trim() -split "`r?`n") -join ' | ')

        Restart-Emulator -Serial $serial
        $final = Get-AdbDeviceSerial
        Wait-DeviceBoot -Serial $final
        Write-Ok 'Zygisk 已启用（Magisk 内置），可用 Zygisk 模块验证'
        return
    }

    throw '设备上没有检测到 Magisk 或 KernelSU'
}

function Invoke-Restore {
    Write-Step '还原未 Root 的 ramdisk'

    $ramdisk = Get-RamdiskPath
    $backup = "$ramdisk.backup"
    if (-not (Test-Path -LiteralPath $backup)) {
        throw "没有找到备份：$backup"
    }
    if ($DryRun) {
        Write-Info "dry run：copy $backup -> $ramdisk"
        return
    }
    Copy-Item -LiteralPath $backup -Destination $ramdisk -Force
    Write-Ok '已还原，重启模拟器即可回到未 Root 状态'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $script:WorkDir)) {
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }

    switch ($Action) {
        'doctor' { Invoke-Doctor }
        'install' { Invoke-Install }
        'create' { Invoke-Create }
        'start' { Invoke-Start }
        'root-magisk' { Invoke-RootMagisk }
        'root-kernelsu' { Invoke-RootKernelSu }
        'zygisk-next' { Invoke-ZygiskNext }
        'restore' { Invoke-Restore }
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}

exit 0
