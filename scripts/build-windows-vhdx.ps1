<#
.SYNOPSIS
    一键从 Windows 11 ARM64 ISO 制作可直接给 QEMU 启动的 VHDX（含引导 + virtio 驱动 + 可选的 TPM 检查绕过）

.DESCRIPTION
    不需要装虚拟机、不需要在 VM 里跑安装程序。全程命令行：
      ISO → VHDX → 分区 → 释放映像(CompactOS) → bcdboot 写引导 → LabConfig（可选，防重置/OOBE 场景） → 注入 virtio 驱动

    产出 win.vhdx 直接推到手机，用 scripts/boot-win.sh 启动即可。

.PARAMETER Iso
    Windows 11 ARM64 的 ISO 路径（必须是 ARM64！x64 的用不了）

.PARAMETER Out
    输出的 VHDX 路径，默认 .\win.vhdx

.PARAMETER DriversDir
    virtio ARM64 驱动目录（每个驱动一个子目录，含 .inf/.cat/.sys）
    可用 scripts/extract-virtio.ps1 从 virtio-win.iso 抽出来

.PARAMETER SizeGB
    虚拟磁盘大小，默认 100

.PARAMETER Index
    映像索引，留空则自动挑 ARM64 的那个

.EXAMPLE
    .\build-windows-vhdx.ps1 -Iso D:\Win11_ARM64.iso -DriversDir .\virtio-arm64-w11

.NOTES
    必须在管理员 PowerShell 里运行（要挂载 VHD、写分区）。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $Iso,
    [string] $Out = '.\win.vhdx',
    [string] $DriversDir,
    [int]    $SizeGB = 100,
    [int]    $Index  = 0
)

$ErrorActionPreference = 'Stop'
$script:Step = 0
function Section($t) { $script:Step++; Write-Host "`n$('='*70)`n[$script:Step] $t`n$('='*70)" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [..]   $t" }
function Warn($t) { Write-Host "  [警告] $t" -ForegroundColor Yellow }
function Fail($t) { Write-Host "  [失败] $t" -ForegroundColor Red; throw $t }

# ---- 管理员检查 -------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail '请在【管理员】PowerShell 里运行本脚本' }

if (-not (Test-Path $Iso)) { Fail "找不到 ISO: $Iso" }
$Out = [System.IO.Path]::GetFullPath($Out)

# ============================================================================
Section "挂载 ISO 并识别映像"

$isoMount = Mount-DiskImage -ImagePath $Iso -PassThru
$isoVol   = $isoMount | Get-Volume
$isoDrive = "$($isoVol.DriveLetter):"
Ok "ISO 挂载到 $isoDrive"

$wim = Join-Path $isoDrive 'sources\install.wim'
if (-not (Test-Path $wim)) {
    $wim = Join-Path $isoDrive 'sources\install.esd'
    if (-not (Test-Path $wim)) { Fail "ISO 里找不到 install.wim / install.esd" }
}
$isEsd = $wim.EndsWith('.esd')
Info "映像文件: $wim $(if($isEsd){'(ESD)'})"

$wimInfo = & dism /Get-WimInfo "/WimFile:$wim" 2>&1
# 解析出索引/名称（兼容中文与 English 两种输出，且冒号前后可能有空格）
$images = @()
$cur = $null
foreach ($line in $wimInfo) {
    $s = "$line"
    if ($s -match '^\s*(Index|索引)\s*:\s*(\d+)') {
        if ($null -ne $cur) { $images += [pscustomobject]$cur }
        $cur = @{ Index = [int]$Matches[2]; Name = ''; Arch = '' }
    }
    elseif ($null -ne $cur -and $s -match '^\s*(Name|名称)\s*:\s*(.+)$') {
        $cur.Name = $Matches[2].Trim()
    }
}
if ($null -ne $cur) { $images += [pscustomobject]$cur }

# 架构要单独用 /Index:N 查（列表里没有这个字段）
foreach ($im in $images) {
    $one = & dism /Get-WimInfo "/WimFile:$wim" "/Index:$($im.Index)" 2>&1
    foreach ($l in $one) {
        if ("$l" -match '^\s*(Architecture|体系结构)\s*:\s*(.+)$') { $im.Arch = $Matches[2].Trim(); break }
    }
}

if (-not $images) { Fail "解析 install.wim 信息失败：`n$wimInfo" }
Write-Host "  映像列表:" -ForegroundColor DarkGray
$images | ForEach-Object { Write-Host ("    [{0}] {1}   ({2})" -f $_.Index, $_.Name, $_.Arch) -ForegroundColor DarkGray }

if ($Index -le 0) {
    $arm = $images | Where-Object { $_.Arch -match 'ARM64|arm64' } | Select-Object -First 1
    if ($arm) {
        $Index = $arm.Index
        Ok "自动选中 ARM64 映像: [$Index] $($arm.Name)"
    } elseif ($images.Count -gt 0) {
        # 拿不到架构信息时，退回选最后一个（多版本 ISO 通常最后一个功能最全）
        Warn "ISO 里没读出 Architecture 字段；默认选最后一个映像（通常是专业版）"
        $Index = ($images | Select-Object -Last 1).Index
        Ok "选用: [$Index] $(($images | Select-Object -Last 1).Name)"
    } else {
        Fail "没解析出任何映像"
    }
} else {
    $sel = $images | Where-Object { $_.Index -eq $Index }
    if (-not $sel) { Fail "索引 $Index 不存在" }
    if ($sel.Arch -and $sel.Arch -notmatch 'ARM64|arm64') { Fail "索引 $Index 的架构是 $($sel.Arch)，不是 ARM64 —— 会做出无法启动的盘" }
    Ok "选定映像: [$Index] $($sel.Name)"
}

# ============================================================================
Section "创建并分区 VHDX（MSR + Windows + ESP）"

if (Test-Path $Out) { Fail "输出文件已存在: $Out（先删掉或换个路径，避免覆盖）" }

# 用 diskpart 创建并挂载动态 VHDX（无需 Hyper-V 模块）
$createScript = @"
create vdisk file="$Out" maximum=$($SizeGB * 1024) type=expandable
select vdisk file="$Out"
attach vdisk
"@
Write-Host "    -- diskpart 脚本 --" -ForegroundColor DarkGray
$createScript -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "      $_" -ForegroundColor DarkGray } }
$cFile = Join-Path $env:TEMP "vhd_create_$(Get-Random).txt"
Set-Content -Path $cFile -Value $createScript -Encoding ASCII
$cr = & diskpart /s $cFile 2>&1
$cr | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Remove-Item $cFile -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $Out)) { Fail "diskpart 创建 VHD 失败，看上面输出" }
Ok "已创建并挂载动态 VHDX: $Out  ($SizeGB GiB)"

# 找到刚挂上的虚拟盘
Start-Sleep -Seconds 2
$disk = Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' } |
        Sort-Object Number -Descending | Select-Object -First 1
if (-not $disk) { Fail '没找到刚挂载的虚拟磁盘（Get-Disk 里没有 File Backed Virtual）' }
Info "已挂载为 Disk $($disk.Number)，$([int]($disk.Size/1GB)) GiB"

# 用 diskpart 分区（对 ESP 的 GPT 类型处理最省事）
$winMB = [int]($SizeGB * 1024) - 16 - 300
$dp = @"
select disk $($disk.Number)
clean
convert gpt
create partition msr size=16
create partition primary size=$winMB
format fs=ntfs quick label=Windows
assign letter=G
create partition efi size=300
format fs=fat32 quick label=ESP
assign letter=S
"@
$dpFile = Join-Path $env:TEMP "dp_$(Get-Random).txt"
Set-Content -Path $dpFile -Value $dp -Encoding ASCII
& diskpart /s $dpFile | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Remove-Item $dpFile -Force

if (-not (Test-Path 'G:\')) { Fail 'Windows 分区没挂上 G: —— 看上面的 diskpart 输出' }
if (-not (Test-Path 'S:\')) { Fail 'ESP 没挂上 S:' }
Ok "分区完成: Windows=G:  ESP=S:"

# ============================================================================
Section "释放 Windows 映像到 G:（CompactOS）"

$args = @('/Apply-Image', "/ImageFile:$wim", "/Index:$Index", '/ApplyDir:G:\', '/Compact:ON')
if ($isEsd) { $args += '/Compress:recovery' }
Info "dism $($args -join ' ')"
& dism @args | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) { Fail "dism /Apply-Image 失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path 'G:\Windows\System32\winload.efi')) { Fail '释放后找不到 G:\Windows\System32\winload.efi' }
Ok '映像释放完成'

# ============================================================================
Section "写 UEFI 引导（bcdboot）—— 最容易漏的一步"

Info 'ESP 刚格式化完是空的，必须自己写引导，否则开机找不到可引导设备'
& bcdboot 'G:\Windows' /s S: /f UEFI /v 2>&1 | ForEach-Object {
    if ($_ -match 'bootaa64|bootmgfw|error|failure') { Write-Host "    $_" -ForegroundColor DarkGray }
}
if ($LASTEXITCODE -ne 0) { Warn "bcdboot 退出码 $LASTEXITCODE（通常仍可用，下面会核对文件）" }

$fwEfi = 'S:\EFI\Microsoft\Boot\bootmgfw.efi'
$bcd   = 'S:\EFI\Microsoft\Boot\BCD'
$fbEfi = 'S:\EFI\Boot\bootaa64.efi'
if (-not (Test-Path $bcd)) { Fail 'BCD 没生成 —— 引导没写好' }
if (-not (Test-Path $fwEfi)) { Fail 'bootmgfw.efi 没生成' }

# 核对 bootmgfw.efi 是 ARM64
$fs = [System.IO.File]::OpenRead($fwEfi); $b = New-Object byte[] 256; [void]$fs.Read($b,0,256); $fs.Close()
$pe = [BitConverter]::ToInt32($b,0x3C); $mach = [BitConverter]::ToUInt16($b,$pe+4)
if ($mach -ne 0xAA64) { Fail ("bootmgfw.efi 架构是 0x{0:X4}，不是 ARM64 —— bcdboot 拿错文件了" -f $mach) }
Ok "bootmgfw.efi 架构 = ARM64 (0xAA64) ✓"
Ok "BCD 已生成 ✓"
if (Test-Path $fbEfi) { Ok "兜底路径 EFI\Boot\bootaa64.efi 已生成 ✓" }

# ============================================================================
Section "绕过 TPM / SecureBoot / RAM 检查（LabConfig，可选——dism 直释流程不跑安装程序，此步非必须）"

& reg load 'HKLM\OFFLINESYS' 'G:\Windows\System32\config\SYSTEM' | Out-Null
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    & reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f | Out-Null
}
$check = & reg query 'HKLM\OFFLINESYS\Setup\LabConfig' 2>&1
$check | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
& reg unload 'HKLM\OFFLINESYS' | Out-Null
Ok 'LabConfig 已写入（可选预防项：重置/OOBE 等场景可能重新触发硬件检查）'

# ============================================================================
Section "注入 virtio ARM64 驱动"

if ($DriversDir -and (Test-Path $DriversDir)) {
    $infCount = (Get-ChildItem $DriversDir -Recurse -Filter '*.inf').Count
    Info "在 $DriversDir 找到 $infCount 个 .inf"
    & dism /Image:G:\ /Add-Driver "/Driver:$((Resolve-Path $DriversDir).Path)" /Recurse 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Warn "部分驱动注入失败（退出码 $LASTEXITCODE），看上面输出" }

    # 关键检查：viostor 在不在（virtio-blk 启动盘必需）
    $viostor = Get-ChildItem 'G:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'viostor*' -ErrorAction SilentlyContinue
    if ($viostor) { Ok "viostor 已就位 ✓（virtio-blk 启动盘必需）" }
    else { Warn 'DriverStore 里没找到 viostor —— 如果打算用 virtio-blk 启动盘会 0x7B 蓝屏' }
} else {
    Warn "没提供 -DriversDir，跳过驱动注入。"
    Warn "不注入驱动的话：只能用 NVMe/IDE 启动盘（Windows 自带驱动），但用不了 virtio 网卡/显卡/气球。"
}

# ============================================================================
Section "收尾"

& dism /Image:G:\ /Cleanup-Image /StartComponentCleanup 2>&1 | Out-Null   # 可选，失败无所谓

Write-Host "  卸载 VHD ..." -NoNewline
$detachScript = @"
select vdisk file="$Out"
detach vdisk
"@
$dFile = Join-Path $env:TEMP "vhd_detach_$(Get-Random).txt"
Set-Content -Path $dFile -Value $detachScript -Encoding ASCII
& diskpart /s $dFile 2>&1 | Out-Null
Remove-Item $dFile -Force -ErrorAction SilentlyContinue
Write-Host ' 完成' -ForegroundColor Green

Write-Host "  卸载 ISO ..." -NoNewline
Dismount-DiskImage -ImagePath $Iso | Out-Null
Write-Host ' 完成' -ForegroundColor Green

$sz = (Get-Item $Out).Length
Ok "输出: $Out  ($([math]::Round($sz/1GB,2)) GiB 实际占用)"

Write-Host @"

  下一步：把 win.vhdx 推到手机并启动
     adb push "$Out" /data/local/tmp/win.vhdx
     # 手机上（需要 root）：
     #   su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'
     # 然后跑 scripts/boot-win.sh

  首次开机会跑 OOBE，5~15 分钟。
  到"连接网络"那页选【我没有 Internet 连接】→【继续执行受限设置】建本地账户最省事。

  驱动目录如果还没有，可以先用 scripts/extract-virtio.ps1 从 virtio-win ISO 抽 ARM64 驱动。
"@ -ForegroundColor Green
