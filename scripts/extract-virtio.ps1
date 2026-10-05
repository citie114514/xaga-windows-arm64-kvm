<#
.SYNOPSIS
    从 virtio-win.iso 抽出 Windows 11 ARM64 的 virtio 驱动，并校验每个 .sys 都是 ARM64

.DESCRIPTION
    virtio-win.iso 的 ARM64 目录叫 ARM64（不是 aarch64），Windows 11 用 w11 子目录。
    本脚本抽出后按驱动名扁平化，并逐个检查 PE machine == 0xAA64。

.PARAMETER Iso
    virtio-win.iso 路径

.PARAMETER OutDir
    输出目录，默认 .\virtio-arm64-w11

.PARAMETER WinVer
    Windows 版本子目录，默认 w11（Win10 用 w10）

.EXAMPLE
    .\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $Iso,
    [string] $OutDir = '.\virtio-arm64-w11',
    [string] $WinVer = 'w11'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Iso)) { throw "找不到 ISO: $Iso" }
$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName

# 找解压工具
$sevenZip = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenZip) { throw '需要 7-Zip（装了才有 7z.exe），或者先手动把 ISO 挂载后复制' }
Write-Host "使用: $sevenZip"

# 校验 ISO 完整性（防止被代理截断）
$len = (Get-Item $Iso).Length
Write-Host "ISO 大小: $len 字节"
$fs = [System.IO.File]::OpenRead($Iso)
$pvd = New-Object byte[] 2048; $fs.Position = 16 * 2048; [void]$fs.Read($pvd,0,2048); $fs.Close()
$volSectors = [BitConverter]::ToUInt32($pvd, 80)
$volBytes = [uint64]$volSectors * 2048
Write-Host "ISO 声明卷大小: $volBytes 字节"
if ($volBytes -ne $len) {
    Write-Host "  ⚠️ 大小不一致 —— ISO 可能被截断（下载不完整）！" -ForegroundColor Yellow
    Write-Host "  如果继续，抽驱动可能失败。" -ForegroundColor Yellow
} else {
    Write-Host "  ✓ 大小一致，ISO 完整" -ForegroundColor Green
}

# 抽取
$raw = Join-Path $env:TEMP "vw_raw_$(Get-Random)"
Write-Host "`n抽取 *\$WinVer\ARM64\*（排除 *.pdb）..."
& $sevenZip x $Iso "-o$raw" -r "*\$WinVer\ARM64\*" -x!*.pdb -y | Select-String 'Everything is Ok|Error|ERROR' | ForEach-Object { Write-Host "  $_" }

# 扁平化
Write-Host "`n整理成扁平目录..."
$drivers = Get-ChildItem $raw -Directory | Where-Object { Test-Path (Join-Path $_.FullName "$WinVer\ARM64") }
if (-not $drivers) { throw "没抽到任何驱动，检查 WinVer 参数（当前 $WinVer）或 ISO 是否完整" }

$okList = @(); $badList = @()
foreach ($d in $drivers) {
    $src = Join-Path $d.FullName "$WinVer\ARM64"
    $dst = Join-Path $OutDir $d.Name
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item (Join-Path $src '*') $dst -Force
    $files = (Get-ChildItem $dst).Count

    # 校验 .sys 架构
    $arch = ''
    $sys = Get-ChildItem $dst -Filter '*.sys' | Select-Object -First 1
    if ($sys) {
        $b = [System.IO.File]::ReadAllBytes($sys.FullName)
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        $mach = [BitConverter]::ToUInt16($b, $pe + 4)
        $arch = ('0x{0:X4}' -f $mach)
        if ($mach -eq 0xAA64) { $okList += $d.Name } else { $badList += "$($d.Name) ($arch)" }
    }
    $mark = if ($arch -eq '0xAA64' -or -not $sys) { '✓' } else { '✗' }
    Write-Host ("  {0,-12} {1,2} 文件  {2,-8} {3}" -f $d.Name, $files, $arch, $mark)
}

Remove-Item $raw -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== 结果 ===" -ForegroundColor Cyan
Write-Host "  ARM64 驱动: $($okList.Count) 个  $($okList -join ', ')" -ForegroundColor Green
if ($badList) { Write-Host "  ⚠️ 非 ARM64: $($badList -join ', ')" -ForegroundColor Red }

if ($okList -contains 'viostor') {
    Write-Host "  ✓ viostor 在（virtio-blk 启动盘必需）" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ 没有 viostor！用 virtio-blk 启动盘会 0x7B 蓝屏" -ForegroundColor Yellow
}

Write-Host "`n输出目录: $OutDir"
Write-Host "用法: build-windows-vhdx.ps1 -Iso <Win11 ARM64 ISO> -DriversDir `"$OutDir`""
