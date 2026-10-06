# ============================================================================
#  write-boot-manual.ps1 —— 不依赖 bcdboot，手工给 ARM64 Windows 镜像写 UEFI 引导
#
#  什么时候需要它：
#    宿主 Windows 开了 Secure Boot 且装了 2023 PCA 时，宿主的 bcdboot 会强制使用
#    "Ex bins"（EFI_EX\bootmgfw_EX.efi），而 Win10 LTSC 2021 这类较老镜像里
#    根本没有 EFI_EX 目录 → bcdboot 报 0xc1 失败：
#      BFSVC: Unable to open file ...\Windows\boot\EFI_EX\bootmgfw_EX.efi
#      Failure when attempting to copy boot files.
#
#  本脚本改为：直接从镜像自带的 boot\EFI 拷 ARM64 引导管理器，再用 bcdedit 建 BCD。
#
#  用法（管理员 PowerShell）：
#      .\write-boot-manual.ps1 -Vhdx C:\Users\me\win10.vhdx
#      .\write-boot-manual.ps1 -Vhdx ... -WindowsLetter G -EspLetter V
#      .\write-boot-manual.ps1 -Vhdx ... -NoAttach      # VHDX 已挂载时
#
#  ⚠️ 全程需要管理员（写 ESP 上的 BCD 是特权操作）
#  ⚠️ 必须确认 ESP 是空的或可覆盖的 —— 已存在引导会被覆盖
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Vhdx,
    [string]$WindowsLetter,      # 不给则自动识别（排除宿主系统盘）
    [string]$EspLetter,          # 不给则自动识别 / 分配
    [string]$Description = 'Windows 10 ARM64',
    [int]   $Timeout     = 5,
    [string]$Locale      = 'zh-CN',
    [switch]$NoAttach
)

$ErrorActionPreference = 'Stop'
function Say([string]$m,[string]$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Ok ([string]$m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad([string]$m){ Write-Host "  [!!]   $m" -ForegroundColor Red }
function Inf([string]$m){ Write-Host "  [..]   $m" -ForegroundColor Gray }

# ---- 权限检查 --------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Bad '请在【管理员】PowerShell 里运行本脚本'; exit 1 }

if (-not (Test-Path $Vhdx)) { Bad "找不到 VHDX: $Vhdx"; exit 1 }
$hostSys = $env:SystemDrive

# ---- 1) 挂载 ---------------------------------------------------------------
if (-not $NoAttach) {
    Say "`n=== 1) 挂载 VHDX ===" Cyan
    $sf = Join-Path $env:TEMP "wbm_att_$(Get-Random).txt"
    @("select vdisk file=`"$Vhdx`"","attach vdisk") | Set-Content -Path $sf -Encoding ASCII
    $r = & diskpart /s $sf 2>&1
    Remove-Item $sf -Force -ErrorAction SilentlyContinue
    if ($r -match 'already attached') { Inf 'VHDX 已经挂载，继续' } else { Ok '已挂载' }
    Start-Sleep 4
}

# ---- 2) 定位卷（关键：排除宿主系统盘）--------------------------------------
Say "`n=== 2) 定位 ESP / Windows 卷 ===" Cyan
$disk = Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' } |
        Sort-Object Number -Descending | Select-Object -First 1
if (-not $disk) { Bad '没找到已挂载的虚拟磁盘'; exit 1 }
Inf ("虚拟磁盘: Disk " + $disk.Number + "  " + [math]::Round($disk.Size/1GB,1) + " GiB  " + $disk.Location)

$parts   = Get-Partition -DiskNumber $disk.Number
$espPart = $parts | Where-Object { $_.Type -eq 'System' } | Select-Object -First 1
$winPart = $parts | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Size -Descending | Select-Object -First 1
if (-not $espPart) { Bad '该磁盘上没有 ESP 分区'; exit 1 }
if (-not $winPart) { Bad '该磁盘上没有 Windows 分区'; exit 1 }

if (-not $EspLetter) {
    $v = $espPart | Get-Volume
    if ($v.DriveLetter) { $EspLetter = $v.DriveLetter }
    else {
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $espPart.PartitionNumber -AccessPath 'V:' -ErrorAction SilentlyContinue
        Start-Sleep 3; $EspLetter = ($espPart | Get-Volume).DriveLetter
    }
}
if (-not $WindowsLetter) {
    $v = $winPart | Get-Volume
    if ($v.DriveLetter) { $WindowsLetter = $v.DriveLetter }
    else {
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $winPart.PartitionNumber -AccessPath 'W:' -ErrorAction SilentlyContinue
        Start-Sleep 3; $WindowsLetter = ($winPart | Get-Volume).DriveLetter
    }
}
$E = $EspLetter + ':'
$W = $WindowsLetter + ':'

# 二次确认：必须不是宿主系统盘，且确实含 Windows
if ($W -eq $hostSys) { Bad "Windows 卷等于宿主系统盘（$hostSys），中止"; exit 1 }
if (-not (Test-Path "$W\Windows\System32\ntoskrnl.exe")) { Bad "$W 里没有 Windows，中止"; exit 1 }
Ok "ESP=$E   Windows=$W   已确认不是宿主系统盘"

$src = "$W\Windows\boot\EFI"
if (-not (Test-Path "$src\bootmgfw.efi")) { Bad "镜像里没有 $src\bootmgfw.efi"; exit 1 }

# ---- 3) 校验源引导是 ARM64 -------------------------------------------------
Say "`n=== 3) 校验源引导架构 ===" Cyan
$b = [IO.File]::ReadAllBytes("$src\bootmgfw.efi")
$o = [BitConverter]::ToInt32($b, 0x3C); $m = [BitConverter]::ToUInt16($b, $o + 4)
if ($m -ne 0xAA64) { Bad ("bootmgfw.efi 的 machine=0x" + $m.ToString('X4') + "，不是 ARM64，中止"); exit 1 }
Ok ("bootmgfw.efi machine=0xAA64 (ARM64)  " + $b.Length + " 字节")

# ---- 4) 拷引导文件 ---------------------------------------------------------
Say "`n=== 4) 拷贝引导文件到 ESP ===" Cyan
New-Item -ItemType Directory -Force -Path "$E\EFI\Boot"           | Out-Null
New-Item -ItemType Directory -Force -Path "$E\EFI\Microsoft\Boot" | Out-Null
Copy-Item "$src\bootmgfw.efi" "$E\EFI\Microsoft\Boot\bootmgfw.efi" -Force
Copy-Item "$src\bootmgfw.efi" "$E\EFI\Boot\bootaa64.efi"           -Force   # 兜底路径
Ok 'bootmgfw.efi + bootaa64.efi'
foreach ($f in 'boot.stl','memtest.efi','winsipolicy.p7b') {
    if (Test-Path "$src\$f") { Copy-Item "$src\$f" "$E\EFI\Microsoft\Boot\$f" -Force; Ok $f }
}
if (Test-Path "$src\$Locale") {
    New-Item -ItemType Directory -Force -Path "$E\EFI\Microsoft\Boot\$Locale" | Out-Null
    Copy-Item "$src\$Locale\*" "$E\EFI\Microsoft\Boot\$Locale\" -Force -ErrorAction SilentlyContinue
    Ok "$Locale 启动菜单本地化资源"
}

# ---- 5) 建 BCD -------------------------------------------------------------
Say "`n=== 5) 建立 BCD ===" Cyan
$BCD = "$E\EFI\Microsoft\Boot\BCD"
Remove-Item $BCD -Force -ErrorAction SilentlyContinue
& bcdedit /createstore $BCD | Out-Null

$out = & bcdedit /store $BCD /create /d $Description /application osloader 2>&1
$g = ($out -join ' ')
if ($g -match '(\{[0-9a-fA-F-]+\})') { $g = $Matches[1] } else { Bad "创建 osloader 失败: $g"; exit 1 }
Inf "osloader = $g"

foreach ($kv in @(
    @('device',      "partition=$W"),
    @('path',        '\Windows\system32\winload.efi'),
    @('osdevice',    "partition=$W"),
    @('systemroot',  '\Windows'),
    @('detecthal',   'Yes')
)) { & bcdedit /store $BCD /set "$g" $kv[0] $kv[1] | Out-Null }
Ok 'Windows Boot Loader 条目'

# {bootmgr}：注意不能带 /application！
& bcdedit /store $BCD /create "{bootmgr}" /d "Windows Boot Manager" 2>&1 | Out-Null
foreach ($kv in @(
    @('device',       "partition=$E"),
    @('path',         '\EFI\Microsoft\Boot\bootmgfw.efi'),
    @('default',      $g),
    @('displayorder', $g),
    @('timeout',      "$Timeout"),
    @('locale',       $Locale)
)) { & bcdedit /store $BCD /set "{bootmgr}" $kv[0] $kv[1] | Out-Null }
Ok 'Windows Boot Manager 条目'

# ---- 6) 验证 ---------------------------------------------------------------
Say "`n=== 6) 验证 ===" Cyan
$final = & bcdedit /store $BCD /enum all 2>&1
$final | ForEach-Object { if ($_ -match '\S') { Write-Host "    $_" } }
$okAll = (($final | Select-String 'bootmgfw\.efi').Count -gt 0) -and
         (($final | Select-String 'winload\.efi').Count -gt 0)
Say ""
if ($okAll) { Ok 'ESP 引导就绪 —— 可以开机了' } else { Bad 'BCD 检查未通过，见上面输出' }

if (-not $NoAttach) { Say "`n  （VHDX 保持挂载，未自动卸载）" -ForegroundColor DarkGray }
