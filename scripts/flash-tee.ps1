# ============================================================================
#  flash-tee.ps1 —— 一键给 MTK 手机刷 NoGZ tee 补丁（开 KVM）
#
#  用法（在 scripts 目录下）：
#      .\flash-tee.ps1                      # 自动匹配基座、交互确认
#      .\flash-tee.ps1 -Patch tee\tee_nogz_rk_5M.img
#      .\flash-tee.ps1 -SkipFastboot        # 跳过 fastboot 往返检查
#      .\flash-tee.ps1 -Serial 192.168.31.145:33445
#      .\flash-tee.ps1 -Yes                 # 全部自动确认（录屏用，慎用）
#
#  ⚠️ 需要：手机已解锁 BL + 已 root（KSU/Magisk）+ 已开 USB 调试
#  ⚠️ 刷完重启后【第二屏会卡 1~2 分钟】—— 这是正常的，等 3 分钟，别进 fastboot
# ============================================================================
[CmdletBinding()]
param(
    [string] $Patch,                              # 补丁镜像（不给则自动挑）
    [string] $RepoRoot = '',                      # 仓库根（仓库会自动推断）
    [string] $Serial,
    [string] $BackupDir = '',
    [switch] $SkipFastboot,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$script:Step = 0

# ---------- 路径推断（$PSScriptRoot 在参数默认值里取不到，所以放这里）----------
if (-not $RepoRoot) {
    $here = $null
    if     ($PSScriptRoot)                { $here = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else                                   { $here = (Get-Location).Path }
    $RepoRoot = Split-Path -Parent $here
}
if (-not $BackupDir) { $BackupDir = Join-Path $RepoRoot ('tee-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }

# ---------- 输出助手 --------------------------------------------------------
function Title([string]$t) { Write-Host ''; Write-Host ('═' * 66) -ForegroundColor DarkCyan
                             Write-Host ("  $t") -ForegroundColor Cyan
                             Write-Host ('═' * 66) -ForegroundColor DarkCyan }
function Step([string]$t)  { $script:Step++; Write-Host ''; Write-Host ("[$script:Step] $t") -ForegroundColor Yellow }
function Ok  ([string]$t)  { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info([string]$t)  { Write-Host "  [..]   $t" -ForegroundColor Gray }
function Warn([string]$t)  { Write-Host "  [!!]   $t" -ForegroundColor Yellow }
function Die ([string]$t)  { Write-Host "  [XX]   $t" -ForegroundColor Red; Write-Host ''; exit 1 }

function Ask([string]$q) {
    if ($Yes) { Write-Host "  >>> $q  (自动 Yes)"; return $true }
    $a = Read-Host "  >>> $q  [y/N]"
    return ($a -match '^[yY]')
}

# ---------- 工具定位 --------------------------------------------------------
function Find-Tool([string]$name) {
    # 1) 已知的绝对路径优先（最可靠，不依赖 PATH/Get-Command 的不确定行为）
    $cands = @(
        "C:\Program Files\UotanToolbox\Bin\platform-tools\$name.exe",
        "C:\Program Files (x86)\UotanToolbox\Bin\platform-tools\$name.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\$name.exe",
        "$env:USERPROFILE\platform-tools\$name.exe",
        "$env:USERPROFILE\scoop\shims\$name.exe",
        "C:\platform-tools\$name.exe",
        "D:\platform-tools\$name.exe"
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }

    # 2) 退回 PATH 手工扫描（比 Get-Command 可靠）
    foreach ($d in ($env:PATH -split ';')) {
        if (-not $d) { continue }
        $p = Join-Path $d.Trim('"') "$name.exe"
        if (Test-Path $p) { return $p }
    }

    # 3) 最后才试 Get-Command
    $c = Get-Command "$name.exe" -CommandType Application -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }

    return $null
}

# ---------- 设备操作封装 ----------------------------------------------------
$script:AdbExe = $null
function Adb { param([Parameter(ValueFromRemainingArguments=$true)]$Args)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'          # adb 往 stderr 写东西时不要抛异常
    $a = @(); if ($script:Serial) { $a += @('-s', $script:Serial) }
    $a += $Args
    & $script:AdbExe @a 2>&1 | ForEach-Object { "$_".TrimEnd() }
    $ErrorActionPreference = $old
}
function Sh { param([string]$Cmd)                   # root shell
    Adb shell "su -c '$Cmd'"
}
function Hash([string]$Part) {
    (Sh "dd if=/dev/block/by-name/$Part bs=4096 2>/dev/null | sha256sum" |
        Select-Object -First 1) -replace '\s.*$',''
}
function GetSha([string]$File) {
    (Get-FileHash -Algorithm SHA256 -Path $File).Hash.ToLower()
}

# ══════════════════════════════════════════════════════════════════════════
Title 'NoGZ tee 刷入工具 —— 开 KVM'

# ---------- [1] 工具与环境 ---------------------------------------------------
Step '环境检查'

$script:AdbExe = Find-Tool 'adb'
if (-not $script:AdbExe) {
    Warn ('Get-Command adb = ' + $(if (Get-Command adb -ErrorAction SilentlyContinue) { (Get-Command adb).Source } else { '(无)' }))
    Warn ('PATH 里 adb 计数 = ' + @(Get-Command adb -All -ErrorAction SilentlyContinue).Count)
    Die '找不到 adb —— 请装 platform-tools 并加入 PATH'
}
Ok "adb: $script:AdbExe"

$fastboot = Find-Tool 'fastboot'
if ($fastboot) { Ok "fastboot: $fastboot" } else { Warn '找不到 fastboot（-SkipFastboot 时会需要它）' }

Info '等待设备...'
$devs = @(& $script:AdbExe devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
if ($devs.Count -eq 0) { Die '没有已连接且已授权的设备（确认 USB 调试已开、手机上已点允许）' }

if (-not $Serial) {
    if ($devs.Count -eq 1) { $script:Serial = ($devs[0] -split '\s+')[0] }
    else {
        Write-Host '  检测到多台设备：'
        for ($i=0; $i -lt $devs.Count; $i++) { Write-Host ("    [$i] " + ($devs[$i] -split '\s+')[0]) }
        $pick = Read-Host '  选哪台？输入序号'
        $script:Serial = ($devs[[int]$pick] -split '\s+')[0]
    }
}
Ok "目标设备: $script:Serial"

# ---------- [2] 身份核对（很重要！）-----------------------------------------
Step '身份核对 —— 请仔细看这三行'
# ⚠️ 注意变量名：PowerShell 不区分大小写，所以不能用 $serial（会覆盖 $Serial）
$devModel = (Adb shell getprop ro.product.device | Select-Object -First 1)
$devSn    = (Adb shell getprop ro.serialno       | Select-Object -First 1)
$devBuild = (Adb shell getprop ro.build.display.id | Select-Object -First 1)
Write-Host "       型号      : $devModel"
Write-Host "       序列号    : $devSn"
Write-Host "       系统版本  : $devBuild"
if (-not (Ask '设备对不对？（刷错设备后果很严重）')) { Die '用户中止' }

# ---------- [3] 前置条件 -----------------------------------------------------
Step '前置条件'
$locked = (Adb shell getprop ro.boot.flash.locked | Select-Object -First 1)
if ($locked -ne '0') { Die "Bootloader 没解锁（ro.boot.flash.locked=$locked）" }
Ok 'Bootloader 已解锁'

$uid = (Sh 'id -u' | Select-Object -First 1)
if ($uid -ne '0') { Die "拿不到 root（su 返回 $uid）" }
Ok 'Root 可用'

$kvmNow = (Sh 'ls /dev/kvm >/dev/null 2>&1 && echo yes || echo no' | Select-Object -First 1)
if ($kvmNow -eq 'yes') { Warn '/dev/kvm 已经存在 —— 这台机器可能已经刷过了' }
else { Ok '/dev/kvm 不存在 —— 正是「刷之前」的状态' }

# ---------- [4] 读当前 tee 基座 ----------------------------------------------
Step '读取当前 tee 分区'
$teeA = Hash 'tee_a'
$teeB = Hash 'tee_b'
Write-Host "       tee_a = $($teeA.Substring(0,16))…"
Write-Host "       tee_b = $($teeB.Substring(0,16))…"

# ---------- [5] 自动挑补丁 ---------------------------------------------------
Step '选择要刷的补丁'
if (-not $Patch) {
    $teeDir = Join-Path $RepoRoot 'tee'
    $map = @{
        'f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062' = 'tee_nogz_rk_5M.img'
        'a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7' = 'tee_nogz_shuilanA15_5M.img'
    }
    if ($map.ContainsKey($teeA)) {
        $Patch = Join-Path $teeDir $map[$teeA]
        Ok "基座匹配，自动选中: $(Split-Path $Patch -Leaf)"
    } else {
        Warn '当前基座不在成品清单里'
        Info '可选：跨基座的补丁也实测能启动（重启后多等几分钟即可）'
        $all = Get-ChildItem (Join-Path $teeDir '*.img') -ErrorAction SilentlyContinue
        if (-not $all) { Die "tee 目录下没有成品镜像，请用 -Patch 指定" }
        for ($i=0; $i -lt $all.Count; $i++) { Write-Host "    [$i] $($all[$i].Name)" }
        $pick = Read-Host '  选一个（回车 = 取消）'
        if ([string]::IsNullOrWhiteSpace($pick)) { Die '用户取消' }
        $Patch = $all[[int]$pick].FullName
    }
}
if (-not (Test-Path $Patch)) { Die "找不到补丁文件: $Patch" }

$patchHash = GetSha $Patch
$patchSize = (Get-Item $Patch).Length
Ok "$(Split-Path $Patch -Leaf)  $patchSize 字节"
Write-Host "       sha256 = $patchHash"
if ($patchSize -ne 5242880) { Warn "大小不是 5242880（tee 分区大小），确认一下" }

# ---------- [6] 备份 ---------------------------------------------------------
Step '备份原厂分区（不可跳过）'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Ok "备份目录: $BackupDir"

foreach ($p in @('tee_a','tee_b')) {
    $out = "/data/local/tmp/${p}_bak.img"
    Sh "dd if=/dev/block/by-name/$p of=$out bs=4096" | Out-Null
    & $script:AdbExe @(@('-s',$script:Serial),'pull',$out,"$BackupDir\$p.img") 2>&1 |
        Select-Object -Last 1 | ForEach-Object { Info $_ }
    $local = Join-Path $BackupDir "$p.img"
    if (-not (Test-Path $local)) { Die "备份失败: $p" }
    Ok "$p  →  $((GetSha $local).Substring(0,16))…"
}
$bakA = GetSha (Join-Path $BackupDir 'tee_a.img')
if ($bakA -ne $teeA) { Die "备份哈希与设备上的不一致！停止操作" }
Ok '备份校验通过（与设备上一致）'

# ---------- [7] 可选：fastboot 往返（验证救援通道）--------------------------
if (-not $SkipFastboot) {
    Step 'fastboot 往返检查 —— 确认救援通道可用（强烈建议）'
    Info '接下来设备会重启到 bootloader，再回 Android，各约 20~40 秒'
    if (Ask '现在做这一步吗？（录课时很值得录，能证明"能救"）') {
        Adb reboot bootloader | Out-Null
        Info '等待进入 fastboot...'
        Start-Sleep 8
        $fb = $null
        for ($i=0; $i -lt 20; $i++) {
            $fb = & $fastboot devices 2>$null
            if ($fb) { break }
            Start-Sleep 2
        }
        if (-not $fb) { Die '没检测到 fastboot 设备 —— 手动按「音量下+电源」进 bootloader 看看' }
        Ok "fastboot 认到了: $fb"
        Info '这说明：万一刷坏了，你有 fastboot 可以救回来 ✓'
        if (Ask '现在回 Android 继续刷吗？') {
            & $fastboot reboot | Out-Null
            Info '等待 Android 起来（原厂/未打补丁时很快）...'
            for ($i=0; $i -lt 60; $i++) {
                Start-Sleep 3
                $s = (& $script:AdbExe devices | Select-String $script:Serial)
                if ($s -and $s -notmatch 'offline') { break }
            }
            Start-Sleep 5
            $ok = (Sh 'echo ready' | Select-Object -First 1)
            if ($ok -ne 'ready') { Die 'Android 没起来，等一下再重跑脚本' }
            Ok 'Android 已恢复'
        }
    } else { Info '已跳过' }
}

# ---------- [8] 推入 + 校验 --------------------------------------------------
Step '推入补丁并校验'
$remote = '/data/local/tmp/tee_patched.img'
& $script:AdbExe @(@('-s',$script:Serial),'push',$Patch,$remote) 2>&1 |
    Select-Object -Last 1 | ForEach-Object { Info $_ }
$remoteHash = (Sh "sha256sum $remote" | Select-Object -First 1).Split(' ')[0]
Write-Host "       手机上 = $remoteHash"
if ($remoteHash -ne $patchHash) { Die '推过去的文件哈希不符！可能传输损坏，重推一次' }
Ok '手机上文件校验通过'

# ---------- [9] 写入 ---------------------------------------------------------
Step '写入 tee_a'
if (-not (Ask "确认写入吗？目标 $script:Serial ，基座 $($teeA.Substring(0,16))… → 补丁 $($patchHash.Substring(0,16))…")) {
    Die '用户中止（分区未改动）'
}
Sh "dd if=$remote of=/dev/block/by-name/tee_a bs=4096 && sync" | Out-Null
Ok '写入完成'

# ---------- [10] 回读校验 ----------------------------------------------------
Step '回读校验'
$after = Hash 'tee_a'
Write-Host "       刷前 tee_a = $($teeA.Substring(0,16))…"
Write-Host "       刷后 tee_a = $($after.Substring(0,16))…"
if ($after -ne $patchHash) { Die "回读哈希不符！设备状态异常，建议立刻刷回备份：$BackupDir\tee_a.img" }
Ok '回读一致 —— 写入确实生效'

$teeB2 = Hash 'tee_b'
if ($teeB2 -ne $teeB) { Warn 'tee_b 好像变了？请检查' } else { Ok 'tee_b 未改动（兜底还在）' }

# ---------- 完成 -------------------------------------------------------------
Title '刷入完成 —— 接下来手动重启'

Write-Host @"

  ⚠️⚠️⚠️  重启之前请先读完这段  ⚠️⚠️⚠️

  重启后手机会停在【开机第二屏】，转圈但一动不动，可能 1~2 分钟。

      ✅ 这是正常的 —— 每次开机都会这样，不是只有第一次
      ✅ 因为 GZ 拿不到 EL2，启动链要等那个握手超时
      🚫 千万别按「音量下 + 电源」进 fastboot —— 那会打断启动
      ⏱️  耐心等 3 分钟，它会自己进系统

  然后验证：
      adb shell su -c 'ls -l /dev/kvm'
      预期：crw-rw-rw- 1 root root 10, 232  /dev/kvm

  出事的回退方法（备份就在下面这个目录里）：
      $BackupDir

      还能进系统：  dd if=tee_a.img of=/dev/block/by-name/tee_a bs=4096
      起不来了  ：  fastboot flash tee_a "$BackupDir\tee_a.img"

"@ -ForegroundColor White

Write-Host ('═' * 66) -ForegroundColor DarkCyan
Write-Host ("  备份位置: " + (Resolve-Path $BackupDir)) -ForegroundColor Cyan
Write-Host ('═' * 66) -ForegroundColor DarkCyan

if (Ask '现在重启吗？') {
    Adb reboot | Out-Null
    Ok '已发出重启 —— 记得：等 3 分钟，别碰它'
} else {
    Info '好，你手动重启时记得那段等待提示'
}
