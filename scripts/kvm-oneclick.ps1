<#
.SYNOPSIS
    一键在 MediaTek 设备上开启 KVM（替换 TEE 里的 ATF 为 NoGZ 补丁版并签名刷入）

.DESCRIPTION
    适用：Redmi Note 11T Pro / Pro+（MT6895 / xagapro）及 mtk-mod-tee-nogz 支持的其它机型。
    前提：BL 已解锁 + 已 Root（KernelSU/Magisk）+ PC 上有 adb + Python 3.10+。

    流程：
      0. 环境自检（adb / python / 设备 / 解锁状态 / root）
      1. 只读侦察（机型、分区、sbc_en、当前 /dev/kvm 状态）
      2. 备份原厂分区到 PC（tee_a / tee_b / lk_a / preloader_raw_a / seccfg）
      3. 从设备 dump 出 TEE / LK / preloader（保证与设备哈希匹配）
      4. 调 mtk-mod-tee-nogz 构建 NoGZ 补丁副本（离线回归 + 签名）
      5. 校验（要求 2× Result: VALID）+ 裁掉尾部零填充到分区大小
      6. 刷入 tee_a + 回读校验
      7. 提示重启并验证 /dev/kvm

    本脚本只改 tee_a，不动 tee_b / preloader / eFuse。tee_b 未改是天然兜底。

.PARAMETER Profile
    mtk-mod-tee-nogz 的机型 profile。xaga = Redmi Note 11T Pro / Pro+。
    可选：xaga / peral / yunluo

.PARAMETER TeeFixRepo
    mtk-mod-tee-nogz 仓库路径（需已 pip install -r requirements.txt）

.PARAMETER PwnageDir
    pwnage24mtk 工具目录（含 sign_mtk_cert.py / verify_mtk_image.py）

.PARAMETER WorkDir
    工作目录，默认 .\kvm-work

.PARAMETER DryRun
    只做到第 5 步（构建+校验），不刷入

.EXAMPLE
    .\kvm-oneclick.ps1 -Profile xaga -TeeFixRepo D:\mtk-mod-tee-nogz -PwnageDir D:\pwnage24mtk

.NOTES
    刷 ATF 属于修改设备信任链，风险自担。请务必保留备份。
#>

[CmdletBinding()]
param(
    [string] $Profile    = 'xaga',
    [string] $ProjRepo   = '',
    [Parameter(Mandatory=$true)][string] $TeeFixRepo,
    [Parameter(Mandatory=$true)][string] $PwnageDir,
    [string] $WorkDir    = '.\kvm-work',
    [switch] $DryRun,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$script:Step = 0

function Section($t) { $script:Step++; Write-Host "`n$('='*70)`n[$script:Step] $t`n$('='*70)" -ForegroundColor Cyan }
function Ok($t)      { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info($t)    { Write-Host "  [..]   $t" }
function Warn($t)    { Write-Host "  [警告] $t" -ForegroundColor Yellow }
function Fail($t)    { Write-Host "  [失败] $t" -ForegroundColor Red; throw $t }

# ---- 全局 -------------------------------------------------------------------
if (-not $ProjRepo) {
    $here2 = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Get-Location).Path }
    $ProjRepo = Split-Path -Parent $here2
}
$WorkDir = (New-Item -ItemType Directory -Force -Path $WorkDir).FullName
$BackupDir = Join-Path $WorkDir 'backup'
$DumpDir   = Join-Path $WorkDir 'dump'
$OutDir    = Join-Path $WorkDir ('outputs-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
foreach ($d in @($BackupDir, $DumpDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$PY = Join-Path $TeeFixRepo '.venv\Scripts\python.exe'
if (-not (Test-Path $PY)) { $PY = 'python' }

function Find-AdbExe {
    # 1) 常见绝对路径（不依赖 PATH；UotanToolbox / Android SDK / 手动解压）
    $cands = @(
        "C:\Program Files\UotanToolbox\Bin\platform-tools\adb.exe",
        "C:\Program Files (x86)\UotanToolbox\Bin\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:USERPROFILE\platform-tools\adb.exe",
        "C:\platform-tools\adb.exe",
        "D:\platform-tools\adb.exe"
    )
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    # 2) PATH 逐目录扫描（比 Get-Command 可靠）
    foreach ($d in ($env:PATH -split ';')) {
        if (-not $d) { continue }
        $p = Join-Path $d.Trim('"') 'adb.exe'
        if (Test-Path $p) { return $p }
    }
    # 3) 最后才试 Get-Command
    $c = Get-Command adb.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    return $null
}

# ⚠️ 函数名不能叫 Adb：PowerShell 里函数会遮蔽外部 adb.exe，
#    导致 `& adb @Args` 递归调到自己 → CallDepthOverflow（PS5 实测）。
$script:AdbExe = Find-AdbExe
function Invoke-Adb { param([Parameter(ValueFromRemainingArguments=$true)]$AdbArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $call = @()
    if ($script:Serial) { $call += @('-s', $script:Serial) }
    $call += $AdbArgs
    $out = & $script:AdbExe @call 2>&1
    $ErrorActionPreference = $old
    return ($out | ForEach-Object { "$_".TrimEnd() })
}
function Adb { param([Parameter(ValueFromRemainingArguments=$true)]$AdbArgs) Invoke-Adb @AdbArgs }
function Sh  { param([string]$Cmd) (Adb shell "su -c '$Cmd'") -join "`n" }
function ShRaw { param([string]$Cmd) (Adb shell $Cmd) -join "`n" }

# ============================================================================
Section "环境自检"

if (-not $script:AdbExe) { Fail '找不到 adb.exe —— 请装 platform-tools 并加入 PATH 或放在常见位置' }
Ok "adb: $script:AdbExe"

try { $pyver = & $PY --version 2>&1 } catch { Fail "Python 不可用: $PY" }
Ok "python: $pyver  ($PY)"

if (-not (Test-Path (Join-Path $TeeFixRepo 'scripts\build.py'))) { Fail "TeeFixRepo 里找不到 scripts\build.py: $TeeFixRepo" }
Ok "mtk-mod-tee-nogz: $TeeFixRepo"

# ---- 自动给上游 mtk-mod-tee-nogz 打必要补丁（幂等，细节见 fix-upstream.ps1）----
# 上游目前：① build.py 调用了未定义的 sign_all_flag() → 签名必报 NameError
#           ② --profile 没有 xagapro（Note 11T Pro+ 原厂基座 f8f286f1… 批次）
$buildPyPath = Join-Path $TeeFixRepo 'scripts\build.py'
$profilesJsonPath = Join-Path $TeeFixRepo 'references\profiles.json'
$needFix = $false
$buildSrc = Get-Content $buildPyPath -Raw -Encoding UTF8
if (($buildSrc -notmatch 'def sign_all_flag') -or ($buildSrc -notmatch '"xagapro"')) { $needFix = $true }
if (-not (Select-String -Path $profilesJsonPath -Pattern '"xagapro"' -Quiet)) { $needFix = $true }
if ($needFix) {
    Info '上游 mtk-mod-tee-nogz 缺少必要补丁 —— 自动修复中（详见 fix-upstream.ps1）'
    $fixScript = Join-Path $PSScriptRoot 'fix-upstream.ps1'
    if (-not (Test-Path $fixScript)) { Fail "找不到 $fixScript —— 请更新本仓库" }
    & $fixScript -TeeFixRepo $TeeFixRepo -ProjRepo $ProjRepo
    if ($LASTEXITCODE -ne 0) { Fail '上游补丁失败 —— 请看上方输出' }
    Ok '上游补丁就绪'
} else {
    Ok '上游 mtk-mod-tee-nogz 补丁已就绪'
}

if (-not (Test-Path (Join-Path $PwnageDir 'sign_mtk_cert.py'))) { Fail "PwnageDir 里找不到 sign_mtk_cert.py: $PwnageDir" }
Ok "pwnage24mtk: $PwnageDir"

$devs = (Invoke-Adb devices) | Select-String 'device$'
if (-not $devs) { Fail '没有已授权的 adb 设备（先插 USB 或 adb connect）' }
if (-not $Serial) {
    $devList = @($devs | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devList.Count -gt 1) {
        Info "检测到多台设备: $($devList -join ' , ') → 自动选第一台（用 -Serial 可指定）"
    }
    $script:Serial = $devList[0]
}
Ok "设备: $Serial"

$model = ShRaw 'getprop ro.product.device'
$soc   = ShRaw 'getprop ro.soc.model'
$rel   = ShRaw 'getprop ro.build.version.release'
$lock  = ShRaw 'getprop ro.boot.flash.locked'
Info "机型   : $model"
Info "SoC    : $soc"
Info "Android: $rel"
Info "BL解锁 : ro.boot.flash.locked=$lock"

if ($lock -ne '0') { Fail 'BL 未解锁（ro.boot.flash.locked != 0）。先解锁 BL。' }
Ok 'BL 已解锁'

$isRoot = (Sh 'id')
if ($isRoot -notmatch 'uid=0') { Fail "拿不到 root。请确认 KernelSU/Magisk 已授权本 adb shell。返回：$isRoot" }
Ok 'Root 可用'

# ============================================================================
Section "只读侦察（不改任何东西）"

$byName = Sh 'ls /dev/block/by-name/ | tr ''\n'' '' '''
Info "分区: $byName"
foreach ($p in 'tee_a','tee_b','lk_a','preloader_raw_a','seccfg','expdb') {
    if ($byName -notmatch "\b$p\b") { Warn "没有 $p 分区（不同机型命名可能不同）" }
}

$kvm = Sh 'ls -l /dev/kvm 2>&1'
if ($kvm -match 'No such file') {
    Info '/dev/kvm : 不存在（正符合预期，打完补丁后出现）'
} else {
    Warn "/dev/kvm 已存在：$kvm"
    Warn '可能已经打过补丁了 —— 请确认是否还要继续'
}

# 从 expdb 读 preloader 的 SBC 判定
Info '读取 expdb（preloader 启动日志）确认 Secure Boot 状态...'
Sh 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M 2>/dev/null' | Out-Null
Invoke-Adb pull /data/local/tmp/expdb.img (Join-Path $WorkDir 'expdb.img') | Out-Null
$sbc = Select-String -Path (Join-Path $WorkDir 'expdb.img') -Pattern 'sbc_en = [01]' -AllMatches -Encoding default |
       ForEach-Object { $_.Matches.Value } | Group-Object | Sort-Object Count -Descending
if ($sbc) {
    Info "expdb 里的 SBC 判定:"
    $sbc | ForEach-Object { Info ("  {0}  ×{1}" -f $_.Name, $_.Count) }
    if ($sbc[0].Name -match 'sbc_en = 1') {
        Ok 'SBC = 1（Secure Boot 开着）→ 改过的 ATF **必须签名**，本脚本会走签名流程'
    } else {
        Warn 'SBC = 0 → 理论上不需要签名。但请自行确认。'
    }
} else {
    Warn '没在 expdb 里找到 sbc_en（可能已被覆盖）。按"会被校验"处理更安全。'
}

# ============================================================================
Section "备份原厂分区到 PC（务必保留！）"

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($p in 'tee_a','tee_b','lk_a','lk_b','preloader_raw_a','seccfg') {
    Write-Host "  备份 $p ... " -NoNewline
    Sh "dd if=/dev/block/by-name/$p of=/data/local/tmp/bk_$p.img bs=4096 2>/dev/null" | Out-Null
    $local = Join-Path $BackupDir "$p.$ts.img"
    Invoke-Adb pull "/data/local/tmp/bk_$p.img" $local | Out-Null
    if (Test-Path $local) {
        $h = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
        $s = (Get-Item $local).Length
        Write-Host "OK  $s 字节" -ForegroundColor Green
        Add-Content (Join-Path $BackupDir 'SHA256SUMS.txt') "$h  $p.$ts.img"
    } else {
        Write-Host '跳过（分区不存在）' -ForegroundColor Yellow
    }
}
Ok "备份目录: $BackupDir"
Ok "校验清单: SHA256SUMS.txt"
$teeBackup = Get-ChildItem $BackupDir -Filter 'tee_a.*.img' | Select-Object -First 1
if (-not $teeBackup) { Fail '没有备份到 tee_a —— 中止（绝不能无备份刷机）' }
$TeeSize = $teeBackup.Length
Info "tee_a 分区大小: $TeeSize 字节"

# ============================================================================
Section "从设备 dump 出 TEE / LK / preloader（保证与设备哈希匹配）"

# profile 期望的 lk 哈希（用于检测“设备 lk 已被 OTA 更换”的情况）
$profileLkHash = ''
try {
    $pj = Get-Content (Join-Path $TeeFixRepo 'references\profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileLkHash = $pj.$Profile.lk_sha256
} catch { }

foreach ($p in 'tee_a','lk_a','preloader_raw_a') {
    Write-Host "  dump $p ... " -NoNewline
    Sh "dd if=/dev/block/by-name/$p of=/data/local/tmp/dp_$p.img bs=4096 2>/dev/null" | Out-Null
    $local = Join-Path $DumpDir "$p.img"
    Invoke-Adb pull "/data/local/tmp/dp_$p.img" $local | Out-Null
    if (Test-Path $local) {
        Write-Host "OK  $((Get-Item $local).Length) 字节" -ForegroundColor Green
    } else { Fail "dump $p 失败" }
}

# ---- lk 配对检测：OTA 会换 lk（实测 A15→A16 后 lk_a 从 8cbaa2e8 变 a17d87c6），
#      而上游 build.py 强制 tee+lk 成对哈希校验。补丁只改 tee 里的 atf，
#      实机验证 lk 变化不影响成品工作，但【构建时的回归模拟】需要配对的 lk。
if ($profileLkHash) {
    $lkDumped = (Get-FileHash (Join-Path $DumpDir 'lk_a.img') -Algorithm SHA256).Hash.ToLower()
    if ($lkDumped -ne $profileLkHash) {
        Warn "设备的 lk_a ($($lkDumped.Substring(0,16))…) 与 profile $Profile 期望的 ($($profileLkHash.Substring(0,16))…) 不同"
        Info '原因：OTA 更新会换 lk（本机实测 A15→A16 后 lk 被换）。实机上这不影响补丁工作 ✓'
        Info '但构建工具的离线回归需要“与 tee 配对的那支 lk”才能跑通。'
        $searchRoots = @((Join-Path $ProjRepo 'lk-archive'), (Join-Path $ProjRepo 'kvm-work'))
        $cand = $searchRoots | ForEach-Object {
            Get-ChildItem $_ -Recurse -Filter 'lk_a.img' -ErrorAction SilentlyContinue
        } | Where-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() -eq $profileLkHash } |
                Select-Object -First 1
        if ($cand) {
            Info "找到配对的 lk 备份: $($cand.FullName) → 使用它"
            Copy-Item $cand.FullName (Join-Path $DumpDir 'lk_a.img') -Force
        } else {
            Fail (@"
设备的 lk 已被 OTA 更换，且本地没有配对的 lk 备份。两个选择：
  ① 用成品直接刷（不需要构建）：scripts\flash-tee.ps1 -Yes
  ② 提供 lk_a.img（与你的 tee 批次配对的那支，可在升 OTA 前备份过）后重跑
完整说明见 tee/README.md 的「补丁绑死的是 tee 基座」一节。
"@)
        }
    } else {
        Ok "lk_a 与 profile 配对 ✓ ($($lkDumped.Substring(0,16))…)"
    }
}

# ============================================================================
Section "构建 NoGZ 补丁副本（离线回归 + 自动选签名模式 + 签名）"

$teeImg = Join-Path $DumpDir 'tee_a.img'
$lkImg  = Join-Path $DumpDir 'lk_a.img'
$plImg  = Join-Path $DumpDir 'preloader_raw_a.img'

Push-Location $TeeFixRepo
try {
    Write-Host "`n--- build.py 输出 ---`n" -ForegroundColor DarkGray
    & $PY 'scripts/build.py' `
        --profile $Profile `
        --tee $teeImg `
        --lk $lkImg `
        --preloader $plImg `
        --tools $PwnageDir `
        --out-dir $OutDir
    $rc = $LASTEXITCODE
    Write-Host "`n--- build.py 退出码: $rc ---" -ForegroundColor DarkGray
    if ($rc -ne 0) { Fail "build.py 失败（退出码 $rc），请看上方日志和 $OutDir\*.log" }
} finally { Pop-Location }

$signed = Get-ChildItem $OutDir -Filter 'tee_nogz_*.img' | Select-Object -First 1
if (-not $signed) { Fail "没生成签名成品，检查 $OutDir" }
Ok "签名成品: $($signed.FullName)  ($($signed.Length) 字节)"

# 验签
Write-Host "`n--- verify 输出 ---" -ForegroundColor DarkGray
Push-Location $PwnageDir
try {
    $vout = & $PY 'verify_mtk_image.py' --all $signed.FullName 2>&1
    $vout | ForEach-Object { Write-Host "  $_" }
} finally { Pop-Location }
$valid = ($vout | Select-String 'Result:\s*VALID').Count
if ($valid -lt 2) { Fail "验签没有 2 个 VALID（实际 $valid 个）—— 不要刷！" }
Ok "验签通过: $valid × Result: VALID"

# ============================================================================
Section "裁掉尾部零填充到分区大小"

$signedLen = $signed.Length
if ($signedLen -eq $TeeSize) {
    Ok "大小刚好等于分区（$TeeSize 字节），无需裁剪"
    $flashImg = $signed.FullName
} elseif ($signedLen -gt $TeeSize) {
    $extra = $signedLen - $TeeSize
    Info "签名后超出分区 $extra 字节 —— 检查超出部分是否全为 0x00 ..."
    $bytes = [System.IO.File]::ReadAllBytes($signed.FullName)
    $tail  = $bytes[($TeeSize)..($signedLen-1)]
    $nonzero = 0; foreach ($b in $tail) { if ($b -ne 0) { $nonzero++ } }
    if ($nonzero -gt 0) { Fail "超出部分有 $nonzero 个非零字节 → 不能简单裁剪，需人工分析" }
    Ok "超出部分全为 0x00（$extra 字节），安全裁掉"
    $flashImg = Join-Path $OutDir 'tee_nogz_flash.img'
    $fs = [System.IO.File]::Create($flashImg)
    $fs.Write($bytes, 0, $TeeSize); $fs.Close()
    Ok "已裁剪: $flashImg ($((Get-Item $flashImg).Length) 字节)"
} else {
    Warn "签名成品比分区小 $($TeeSize - $signedLen) 字节 —— 刷入时会补零（通常没问题）"
    $flashImg = $signed.FullName
}

$flashHash = (Get-FileHash $flashImg -Algorithm SHA256).Hash.ToLower()
Info "待刷镜像 sha256: $flashHash"
Info "原厂 tee_a  sha256: $((Get-FileHash $teeBackup.FullName -Algorithm SHA256).Hash.ToLower())"

# ============================================================================
if ($DryRun) {
    Write-Host "`n[DryRun] 已生成待刷镜像，未刷入。" -ForegroundColor Yellow
    Write-Host "  镜像: $flashImg"
    Write-Host "  要去掉 -DryRun 才会真正刷入。" -ForegroundColor Yellow
    exit 0
}

Section "刷入 tee_a（务必确认备份已完成）"

Write-Host @"
  即将执行的操作：
    1. 把 $flashImg 推到手机
    2. dd 写入 /dev/block/by-name/tee_a
    3. 回读并比对 sha256
  已有备份：
    原厂 tee_a : $($teeBackup.FullName)
    备份目录   : $BackupDir
  回滚方法（如需）：
    adb push "$($teeBackup.FullName)" /data/local/tmp/tee_stock.img
    adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
    adb reboot
"@ -ForegroundColor Yellow

if (-not $Yes) {
    $ans = Read-Host "  确认刷入？输入 yes 继续"
    if ($ans -ne 'yes') { Write-Host '  已取消。' -ForegroundColor Yellow; exit 0 }
}

Invoke-Adb push $flashImg /data/local/tmp/tee_nogz_flash.img | Out-Null
Sh 'sync' | Out-Null
Sh "dd if=/data/local/tmp/tee_nogz_flash.img of=/dev/block/by-name/tee_a bs=4096 2>&1" | ForEach-Object { Info $_ }
Sh 'sync' | Out-Null

$readback = Sh 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum' 
$readbackHash = ($readback -split '\s+')[0].ToLower()
Info "回读 sha256: $readbackHash"
if ($readbackHash -eq $flashHash) {
    Ok '回读一致 → 写入生效 ✓'
} else {
    Fail "回读不一致！期望 $flashHash，实际 $readbackHash（别断电，重刷或用备份回滚）"
}

# ============================================================================
Section "完成 —— 重启并验证"

Write-Host @"

  刷好了。接下来：

  1) 重启手机
       adb reboot

  2) 等开机后验证 /dev/kvm 出现
       adb shell su -c 'ls -l /dev/kvm'
       adb shell su -c 'cat /proc/misc | grep kvm'

  3) 看 ATF 是否通过真机校验（从 preloader 日志）
       adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
       adb pull /data/local/tmp/e.img
       # 在里面找： [SBC] image atf header auth pass

  如果起不来：
       # 用备份回滚
       adb push "$($teeBackup.FullName)" /data/local/tmp/tee_stock.img
       adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
       adb reboot
     还可以切到 B 槽（tee_b 未改动，天然兜底）。

  下一步：装 Windows 11 ARM64 虚拟机 → 见 docs/03-windows-vm.md
"@ -ForegroundColor Green
