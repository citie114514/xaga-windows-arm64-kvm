# ============================================================================
#  flash-vendor-boot.ps1 —— 一键刷入 vendor_boot 软编回退补丁
#
#  作用：KVM（NoGZ tee）与硬件视频编解码互斥，裸组合下录屏 0 字节、Moonlight/QQ 图片失效。
#        本脚本给 vendor_boot 的 dtb 改 2 字节（venc/vdec 的 compatible 解绑），
#        让 MTK 硬编不被注册 → 框架回退软编 → 编解码功能恢复，KVM 继续可用。
#        （完整原理与实测数据见 docs/07-vendor-boot-swcodec.md）
#
#  用法（在 scripts 目录下）：
#      .\flash-vendor-boot.ps1                 # 自动匹配成品，交互确认
#      .\flash-vendor-boot.ps1 -DryRun         # 只备份+构建+校验，不刷入
#      .\flash-vendor-boot.ps1 -Yes            # 全自动确认（录屏用）
#      .\flash-vendor-boot.ps1 -Serial 192.168.31.145:33445
#      .\flash-vendor-boot.ps1 -Patch D:\my_swcodec.img    # 指定镜像
#
#  ⚠️ 前提：已经刷了 NoGZ tee（/dev/kvm 存在）；BL 已解锁 + 已 root
#  ⚠️ 只改 vendor_boot_a；vendor_boot_b 不动 = 天然兜底
# ============================================================================
[CmdletBinding()]
param(
    [string] $Patch,                                  # 补丁镜像（不给则自动匹配/自动构建）
    [string] $Serial,                                 # 多设备时指定
    [string] $BackupDir = '',                         # 备份目录（默认 <repo>\vb-backup-<时间>）
    [switch] $DryRun,                                 # 只做到校验，不刷入
    [switch] $Yes                                     # 全部自动确认
)

$ErrorActionPreference = 'Stop'
$script:Step = 0

# ---------- 路径推断 ----------
$here = if ($PSScriptRoot) { $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
        else { (Get-Location).Path }
$RepoRoot = Split-Path -Parent $here
if (-not $BackupDir) { $BackupDir = Join-Path $RepoRoot ('vb-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }

# ---------- 输出助手 ----------
function Title([string]$t) { Write-Host ''; Write-Host ('=' * 66) -ForegroundColor DarkCyan
                             Write-Host "  $t" -ForegroundColor Cyan
                             Write-Host ('=' * 66) -ForegroundColor DarkCyan }
function Step([string]$t)  { $script:Step++; Write-Host ''; Write-Host "[$script:Step] $t" -ForegroundColor Yellow }
function Ok  ([string]$t)  { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info([string]$t)  { Write-Host "  [..]   $t" -ForegroundColor Gray }
function Warn([string]$t)  { Write-Host "  [!!]   $t" -ForegroundColor Yellow }
function Die ([string]$t)  { Write-Host "  [XX]   $t" -ForegroundColor Red; Write-Host ''; exit 1 }

function Ask([string]$q) {
    if ($Yes) { Write-Host "  >>> $q  (自动 Yes)"; return $true }
    $a = Read-Host "  >>> $q  [y/N]"
    return ($a -match '^[yY]')
}

# ---------- 工具定位 ----------
function Find-Tool([string]$name) {
    $cands = @(
        (Join-Path $PSScriptRoot "..\tools\platform-tools\$name.exe"),
        "C:\Program Files\UotanToolbox\Bin\platform-tools\$name.exe",
        "C:\Program Files (x86)\UotanToolbox\Bin\platform-tools\$name.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\$name.exe",
        "$env:USERPROFILE\platform-tools\$name.exe",
        "C:\platform-tools\$name.exe",
        "D:\platform-tools\$name.exe"
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
    foreach ($d in ($env:PATH -split ';')) {
        if (-not $d) { continue }
        $p = Join-Path $d.Trim('"') "$name.exe"
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command "$name.exe" -CommandType Application -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    return $null
}

# ---------- 设备操作 ----------
$script:AdbExe = $null
function Invoke-Adb { param([Parameter(ValueFromRemainingArguments=$true)]$AdbArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $call = @()
    if ($script:Serial) { $call += @('-s', $script:Serial) }
    $call += $AdbArgs
    $out = & $script:AdbExe @call 2>&1
    $ErrorActionPreference = $old
    return ($out | ForEach-Object { "$_".TrimEnd() })
}
function Sh([string]$Cmd) { (Invoke-Adb shell "su -c '$Cmd'") -join "`n" }
function ShRaw([string]$Cmd) { (Invoke-Adb shell $Cmd) -join "`n" }
function Hash([string]$Part) {
    (Sh "dd if=/dev/block/by-name/$Part bs=4096 2>/dev/null | sha256sum" |
        Select-Object -First 1) -replace '\s.*$', ''
}
function GetSha([string]$File) { (Get-FileHash -Algorithm SHA256 -Path $File).Hash.ToLower() }

# 已知哈希（见 docs/07 实测记录）
$KNOWN_PATCHED = '383f4cdc10dc72e9f7c8dec4b785b8d19e64d09b2b74ece32f7a94596ad2e8f2'  # 备用机成品
$KNOWN_ORIG    = 'fed80580d619b916d73b51b704f2af6c9f08afafc84810ced0b2397a0b52797f'  # 对应原厂
$VB_SIZE       = 67108864   # 64 MiB

# ============================================================================
Title 'vendor_boot 软编回退补丁 —— 让 KVM 与编解码共存'

# ---------- [1] 环境检查 ----------
Step '环境检查'
$script:AdbExe = Find-Tool 'adb'
if (-not $script:AdbExe) { Die '找不到 adb.exe —— 请装 platform-tools 或放在常见路径' }
Ok "adb: $script:AdbExe"

$devs = @(Invoke-Adb devices | Select-String 'device$' | ForEach-Object { ($_ -split '\s+')[0] })
if ($devs.Count -eq 0) { Die '没有已授权的 adb 设备（确认 USB 调试已开、手机上已点允许）' }
if (-not $script:Serial) {
    if ($devs.Count -gt 1) { Info "检测到多台设备: $($devs -join ' , ') → 自动选第一台（用 -Serial 指定）" }
    $script:Serial = $devs[0]
}
Ok "目标设备: $script:Serial"

# ---------- [2] 身份与前提 ----------
Step '身份核对与前提检查'
$model = (ShRaw 'getprop ro.product.device' | Select-Object -First 1)
$sn    = (ShRaw 'getprop ro.serialno'       | Select-Object -First 1)
$rel   = (ShRaw 'getprop ro.build.version.release' | Select-Object -First 1)
Write-Host "       型号    : $model"
Write-Host "       序列号  : $sn"
Write-Host "       Android : $rel"
if (-not (Ask '设备对不对？（刷错设备后果很严重）')) { Die '用户中止' }

$locked = (ShRaw 'getprop ro.boot.flash.locked' | Select-Object -First 1)
if ($locked -ne '0') { Die "Bootloader 没解锁（ro.boot.flash.locked=$locked）" }
Ok 'Bootloader 已解锁'

$uid = (Sh 'id -u' | Select-Object -First 1)
if ($uid -ne '0') { Die "拿不到 root（su 返回 $uid）" }
Ok 'Root 可用'

$kvm = (Sh 'ls /dev/kvm >/dev/null 2>&1 && echo yes || echo no' | Select-Object -First 1)
if ($kvm -eq 'yes') { Ok '/dev/kvm 存在 —— NoGZ tee 已就位 ✓' }
else { Warn '/dev/kvm 不存在 —— 本补丁的前提是已经刷了 NoGZ tee；先刷 tee 再回来跑本脚本' 
       if (-not (Ask '仍然继续？（一般应先去刷 tee）')) { Die '用户中止' } }

$byName = Sh 'ls /dev/block/by-name/ | tr ''\n'' '' '''
if ($byName -notmatch 'vendor_boot_a') { Die '设备没有 vendor_boot_a 分区（不是 xaga/xagapro？）' }
Ok 'vendor_boot_a 分区存在'

# ---------- [3] 读当前 vendor_boot_a ----------
Step '读取当前 vendor_boot_a'
$vbNow = Hash 'vendor_boot_a'
if (-not $vbNow) { Die '读 vendor_boot_a 失败' }
Info "vendor_boot_a = $vbNow"
if ($vbNow -eq $KNOWN_PATCHED) {
    Ok '已经是软编回退补丁版本 ✓ —— 无需重复刷入'
    Write-Host ''
    Write-Host '  验证一下效果：' -ForegroundColor Cyan
    Write-Host '    adb shell screenrecord --time-limit 5 /data/local/tmp/t.mp4' -ForegroundColor Gray
    Write-Host '    adb shell ls -l /data/local/tmp/t.mp4   # 非 0 字节 = 软编在用' -ForegroundColor Gray
    exit 0
}
Ok '当前是未打补丁状态（或其它批次），继续'

# ---------- [4] 备份原厂 ----------
Step '备份原厂 vendor_boot_a（不可跳过）'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$tmp = '/data/local/tmp/vb_bk.img'
Sh "dd if=/dev/block/by-name/vendor_boot_a of=$tmp bs=4096 2>/dev/null" | Out-Null
$localBk = Join-Path $BackupDir 'vendor_boot_a.img'
Invoke-Adb pull $tmp $localBk | Out-Null
if (-not (Test-Path $localBk)) { Die "备份失败: $localBk" }
$bkHash = GetSha $localBk
if ($bkHash -ne $vbNow) { Die "备份哈希与设备不一致！停止操作（$bkHash vs $vbNow）" }
Ok "备份完成: $localBk"
Info "sha256 = $bkHash"
Info "回滚：.\flash-vendor-boot.ps1 -Patch `"$localBk`" （或 fastboot flash vendor_boot $localBk）"

# ---------- [5] 选/做补丁镜像 ----------
Step '准备补丁镜像'
if (-not $Patch) {
    $prebuilt = Join-Path $RepoRoot 'vendor_boot_a_swcodec.img'
    if ($vbNow -eq $KNOWN_ORIG -and (Test-Path $prebuilt)) {
        $Patch = $prebuilt
        Ok "基座匹配仓库成品: vendor_boot_a_swcodec.img"
    } else {
        Info '设备基座与仓库成品不匹配 → 用本机备份现场制作（同长度替换 2 字节）'
        $Patch = Join-Path $BackupDir 'vendor_boot_a_swcodec.img'
        $py = Find-Tool 'python'
        if (-not $py) { $py = 'python' }
        $script = @'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
pairs = [(b"mediatek,mt6895-vcodec-dec\x00", b"mediatek,mt6895-vcodec-de0\x00"),
         (b"mediatek,mt6895-vcodec-enc\x00", b"mediatek,mt6895-vcodec-en0\x00")]
out = data
hit = 0
for old, new in pairs:
    if old in out:
        out = out.replace(old, new)
        hit += 1
if hit == 0:
    print("NOCOMPAT"); sys.exit(2)
if len(out) != len(data):
    print("LENCHANGE"); sys.exit(3)
diff = sum(1 for a, b in zip(data, out) if a != b)
open(dst, "wb").write(out)
print("DIFF=%d HIT=%d" % (diff, hit))
'@
        $tmpPy = Join-Path $env:TEMP ('vbpatch-' + [guid]::NewGuid() + '.py')
        [IO.File]::WriteAllText($tmpPy, ($script -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $out = & $py $tmpPy $localBk $Patch 2>&1
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        Write-Host "       $out" -ForegroundColor DarkGray
        if ("$out" -match 'NOCOMPAT') { Die '在本机 vendor_boot 的 dtb 里找不到 mt6895-vcodec 的 compatible 字符串 —— 不同 OS 版本可能不同，请按 docs/07 的「自己制作」自行分析' }
        if ("$out" -match 'LENCHANGE') { Die '替换改变了文件长度 —— 必须同长度替换，停止' }
        if ("$out" -notmatch 'DIFF=2') { Warn "差异字节数不是 2（$out）—— 请人工确认后再刷" 
                                         if (-not (Ask '仍然继续？')) { Die '用户中止' } }
        Ok "已生成: $Patch"
    }
}
if (-not (Test-Path $Patch)) { Die "找不到补丁文件: $Patch" }
$patchHash = GetSha $Patch
$patchSize = (Get-Item $Patch).Length
Info "$(Split-Path $Patch -Leaf)  $patchSize 字节"
Info "sha256 = $patchHash"
if ($patchSize -ne $VB_SIZE) {
    Warn "大小不是 $VB_SIZE（64 MiB），分区写入可能不完整"
    if (-not (Ask '仍然继续？')) { Die '用户中止' }
}
if ($patchHash -eq $vbNow) { Die '待刷镜像与设备当前内容完全相同 —— 没必要刷' }

# ---------- [6] 刷入 ----------
Step '刷入 vendor_boot_a'
Write-Host @"
  即将执行：
    1. 把 $Patch 推到手机
    2. dd 写入 /dev/block/by-name/vendor_boot_a
    3. 回读并比对 sha256
  原厂备份：$localBk
"@ -ForegroundColor Yellow
if ($DryRun) {
    Write-Host ''
    Ok '[DryRun] 已备份 + 已准备补丁，未刷入'
    Info "手动刷入：adb push `"$Patch`" /data/local/tmp/vb.img && adb shell su -c 'dd if=/data/local/tmp/vb.img of=/dev/block/by-name/vendor_boot_a bs=4096 && sync'"
    exit 0
}
if (-not (Ask '确认刷入？')) { Die '用户中止' }

Invoke-Adb push $Patch /data/local/tmp/vb_new.img | Out-Null
Sh 'sync' | Out-Null
$devHash = (Sh 'sha256sum /data/local/tmp/vb_new.img' | Select-Object -First 1) -replace '\s.*$', ''
if ($devHash -ne $patchHash) { Die "推送后哈希不一致（$devHash）—— 传输损坏，请重试" }
Ok '推送校验通过'

Sh 'dd if=/data/local/tmp/vb_new.img of=/dev/block/by-name/vendor_boot_a bs=4096 2>&1' | ForEach-Object { Info $_ }
Sh 'sync' | Out-Null
$readback = Hash 'vendor_boot_a'
Info "回读 sha256: $readback"
if ($readback -eq $patchHash) { Ok '回读一致 → 写入生效 ✓' }
else { Die "回读不一致（期望 $patchHash，实际 $readback）—— 别断电，用备份重刷或进 fastboot 恢复" }

Sh 'rm -f /data/local/tmp/vb_new.img' | Out-Null

# ---------- [7] 重启与验证 ----------
Step '完成 —— 重启并验证'
Write-Host @"

  刷好了。接下来：

  1) 重启（第二屏卡 1~2 分钟是正常的，等 3 分钟，不要进 fastboot）
       adb reboot

  2) 验证 KVM 仍在
       adb shell su -c 'ls -l /dev/kvm'

  3) 验证编解码恢复（录屏非 0 字节 = 软编在用）
       adb shell screenrecord --time-limit 5 /data/local/tmp/t.mp4
       adb shell ls -l /data/local/tmp/t.mp4

  4) 确认软编确实在工作、mtk 硬编已解绑
       adb shell "logcat -d | grep 'c2.android.avc.encoder' | tail -2"
       adb shell "dumpsys media.codec | grep -c 'c2.mtk.avc'"     # 0 = 已解绑

  回滚（恢复硬编，代价是编解码又失效）：
       adb push "$localBk" /data/local/tmp/vb_orig.img
       adb shell su -c 'dd if=/data/local/tmp/vb_orig.img of=/dev/block/by-name/vendor_boot_a bs=4096'
       adb reboot
     或 fastboot flash vendor_boot "$localBk"

  说明：docs/07-vendor-boot-swcodec.md
"@ -ForegroundColor Green

if (Ask '现在重启吗？') {
    Invoke-Adb reboot | Out-Null
    Ok '已发出重启 —— 记得等 3 分钟，别碰它'
} else {
    Info '好，你手动重启时记得那段等待提示'
}
