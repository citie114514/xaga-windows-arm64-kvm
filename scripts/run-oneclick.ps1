# ============================================================================
#  run-oneclick.ps1 —— 发行版唯一入口
#
#  作用：解压 xaga-kvm 发行版 zip 后，双击 start-kvm.bat 或运行本脚本，
#        全自动完成：环境检查 → 建 venv → 打上游补丁 → 备份 → dump → 构建
#        → 签名 → 校验 → 刷入 tee_a → 提示刷 vendor_boot。
#        不需要 clone 任何仓库，工具已随包捆绑。
#
#  用法：
#      .\run-oneclick.ps1                 # 完整流程（交互确认）
#      .\run-oneclick.ps1 -Yes            # 全自动（录屏用）
#      .\run-oneclick.ps1 -DryRun         # 只做到构建校验，不刷
#      .\run-oneclick.ps1 -SkipVendorBoot # 刷完 tee 后不提示 vendor_boot
#
#  前提：手机已解锁 BL + 已 root + 已开 USB 调试
# ============================================================================
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $SkipVendorBoot
)

$ErrorActionPreference = 'Stop'

# ---------- 定位发行版根目录（本脚本在 <root>\scripts 下） ----------
$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
        else { (Split-Path -Parent (Split-Path -Parent (Get-Location).Path)) }
$TeeFixRepo = Join-Path $Root 'tools\mtk-mod-tee-nogz'
$PwnageDir  = Join-Path $Root 'tools\pwnage24mtk'
$Scripts    = Join-Path $Root 'scripts'

function Title([string]$t) { Write-Host ''; Write-Host ('=' * 64) -ForegroundColor DarkCyan
                             Write-Host "  $t" -ForegroundColor Cyan
                             Write-Host ('=' * 64) -ForegroundColor DarkCyan }
function Step([string]$t)  { Write-Host ''; Write-Host "==> $t" -ForegroundColor Yellow }
function Ok  ([string]$t)  { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info([string]$t)  { Write-Host "  [..]   $t" }
function Die ([string]$t)  { Write-Host "  [XX]   $t" -ForegroundColor Red; Write-Host ''; exit 1 }

function Find-Tool([string]$name) {
    $cands = @(
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

    # 4) 最后兜底：包内自带（发行版 tools/platform-tools，或把 platform-tools 放在脚本旁边）
    foreach ($p in @(
        (Join-Path $PSScriptRoot "$name.exe"),
        (Join-Path $PSScriptRoot "platform-tools\$name.exe"),
        (Join-Path $PSScriptRoot "..\platform-tools\$name.exe"),
        (Join-Path $PSScriptRoot "..\tools\platform-tools\$name.exe")
    )) { if (Test-Path $p) { return $p } }
    return $null
}

Title 'XAGA KVM 一键开 KVM —— 发行版入口'

# ---------- [0] adb：优先系统，找不到就用包内自带的（不注入 PATH） ----------
# 候选顺序与各脚本一致：脚本目录 → 脚本目录/platform-tools → 上级 platform-tools
#                     → 上级 tools/platform-tools → 常见安装位置 → PATH
$adbPath = Find-Tool 'adb'
if ($adbPath) {
    $isBundled = $adbPath -like (Join-Path $Root '*')
    if ($isBundled) { Ok "adb（包内自带）: $adbPath" } else { Ok "adb（系统）: $adbPath" }
} else {
    Die '找不到 adb：包里没有 platform-tools，系统也没装。请把 platform-tools 放到 scripts 同级目录，或安装后加入 PATH。'
}

# ---------- [1] 校验发行版结构 ----------
Step '校验发行版结构'
foreach ($need in @(
    (Join-Path $TeeFixRepo 'scripts\build.py'),
    (Join-Path $PwnageDir 'sign_mtk_cert.py'),
    (Join-Path $Scripts 'kvm-oneclick.ps1'),
    (Join-Path $Scripts 'flash-vendor-boot.ps1')
)) {
    if (-not (Test-Path $need)) { Die "缺少必需文件：$need`n（发行版 zip 是否解压完整？）" }
}
Ok "发行版结构完整：$Root"

# ---------- [2] 检查 Python ----------
Step '检查 Python'
$py = Find-Tool 'python'
if (-not $py) {
    foreach ($cand in @("$env:LOCALAPPDATA\Programs\Python\Python*\python.exe", "C:\Python*\python.exe")) {
        $hit = Get-ChildItem $cand -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $py = $hit.FullName; break }
    }
}
if (-not $py) { Die '找不到 Python —— 请先安装 Python 3.10+（勾选 Add to PATH）' }
Ok "python: $py"

# ---------- [3] 建 venv + 装依赖（只一次） ----------
$venvPy = Join-Path $TeeFixRepo '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
    Step '创建 Python 虚拟环境并安装依赖（首次运行需要几分钟）'
    & $py -m venv (Join-Path $TeeFixRepo '.venv')
    if ($LASTEXITCODE -ne 0) { Die 'venv 创建失败' }
    $req = Join-Path $TeeFixRepo 'requirements.txt'
    if (Test-Path $req) {
        # 镜像可能缺新版依赖，按序回退：本机配置 → 清华镜像 → 官方源+本地代理
        $ok = $false
        & $venvPy -m pip install -r $req
        if ($LASTEXITCODE -eq 0) { $ok = $true }
        if (-not $ok) {
            & $venvPy -m pip install -r $req -i https://pypi.tuna.tsinghua.edu.cn/simple
            if ($LASTEXITCODE -eq 0) { $ok = $true }
        }
        if (-not $ok) {
            & $venvPy -m pip install -r $req -i https://pypi.org/simple --proxy http://127.0.0.1:10808
            if ($LASTEXITCODE -eq 0) { $ok = $true }
        }
        if (-not $ok) { Die 'pip install 失败（已尝试镜像与官方源，检查网络后重试）' }
    }
    Ok '依赖安装完成'
} else {
    Ok '虚拟环境已存在，跳过'
}

# ---------- [4] 确保上游补丁已打（幂等） ----------
Step '检查上游工具补丁'
$buildSrc = Get-Content (Join-Path $TeeFixRepo 'scripts\build.py') -Raw -Encoding UTF8
if (($buildSrc -notmatch 'def sign_all_flag') -or ($buildSrc -notmatch '"xagapro"')) {
    Info '上游工具缺补丁，运行 fix-upstream.ps1 ...'
    & (Join-Path $Scripts 'fix-upstream.ps1') -TeeFixRepo $TeeFixRepo -ProjRepo $Root
    if ($LASTEXITCODE -ne 0) { Die 'fix-upstream 失败' }
}
Ok '上游工具就绪'

# ---------- [5] 调 kvm-oneclick ----------
Step '运行 kvm-oneclick（备份 → dump → 构建 → 签名 → 刷入）'
$oneclickArgs = @{
    Profile    = 'xagapro'
    TeeFixRepo = $TeeFixRepo
    PwnageDir  = $PwnageDir
    ProjRepo   = $Root
    WorkDir    = (Join-Path $Root 'kvm-work')
    AdbPath    = $adbPath
}
if ($DryRun) { $oneclickArgs.DryRun = $true }
if ($Yes)    { $oneclickArgs.Yes    = $true }

& (Join-Path $Scripts 'kvm-oneclick.ps1') @oneclickArgs
if ($LASTEXITCODE -ne 0) { Die 'kvm-oneclick 失败，请看上方日志' }
Ok 'kvm-oneclick 完成'

# ---------- [6] 提示刷 vendor_boot ----------
if (-not $SkipVendorBoot) {
    Write-Host ''
    Write-Host '  想让录屏 / 串流 / QQ 图片也恢复（KVM 与编解码共存），并让开机第二屏等待消失？' -ForegroundColor Cyan
    Write-Host '  下一步刷 vendor_boot 软编回退补丁：' -ForegroundColor Cyan
    $vbArgs = @{ AdbPath = $adbPath }
    if ($DryRun) { $vbArgs.DryRun = $true }
    if ($Yes)    { $vbArgs.Yes    = $true }
    if ($DryRun) {
        Info '（-DryRun 模式：只演示命令，不刷）'
        Write-Host "      cd `"$Scripts`"; .\flash-vendor-boot.ps1" -ForegroundColor Gray
    } else {
        & (Join-Path $Scripts 'flash-vendor-boot.ps1') @vbArgs
        if ($LASTEXITCODE -ne 0) { Info 'flash-vendor-boot 未执行或失败（可用 -SkipVendorBoot 跳过本步骤）' }
    }
}

Write-Host ''
Ok '全部完成。重启后验证：adb shell su -c "ls -l /dev/kvm"'
