# ============================================================================
#  make-release.ps1 —— 构建发行版 zip（维护者用）
#
#  产出：dist\xaga-kvm-release-<日期>.zip
#  内容：start-kvm.bat + run-oneclick.ps1 + RELEASE-README（四语）
#        + scripts/（一键脚本全部）+ profiles/ + tee/ 成品 + vendor_boot 两份
#        + lk-archive/ + tools/（mtk-mod-tee-nogz 已打补丁 + pwnage24mtk）
#
#  用法：
#      .\make-release.ps1                        # 用 D:\ 下现成 tools（不存在则 clone）
#      .\make-release.ps1 -ForceFetchTools       # 强制重新 clone 两个工具仓库
#
#  生成后手动创建 GitHub Release 并把 zip 传上去，然后更新 README 的下载链接。
# ============================================================================
[CmdletBinding()]
param(
    [switch] $ForceFetchTools
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot }
        else { Split-Path -Parent (Get-Location).Path }
$Dist = Join-Path $Root 'dist'
$Stage = Join-Path $env:TEMP ('xaga-release-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$PkgRoot = Join-Path $Stage 'xaga-kvm'

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Yellow }
function Ok  ([string]$t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info([string]$t) { Write-Host "  [..]   $t" }

# ---------- 干净起见清掉旧 dist zip ----------
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
Get-ChildItem $Dist -Filter 'xaga-kvm-release-*.zip' -ErrorAction SilentlyContinue |
    Remove-Item -Force
New-Item -ItemType Directory -Force -Path $PkgRoot | Out-Null

# ---------- [1] 拷贝仓库内容 ----------
Step '拷贝 scripts / profiles / tee / 镜像 / lk-archive'
Copy-Item (Join-Path $Root 'scripts')  (Join-Path $PkgRoot 'scripts') -Recurse
Copy-Item (Join-Path $Root 'profiles') (Join-Path $PkgRoot 'profiles') -Recurse
Copy-Item (Join-Path $Root 'tee')      (Join-Path $PkgRoot 'tee') -Recurse
Copy-Item (Join-Path $Root 'lk-archive') (Join-Path $PkgRoot 'lk-archive') -Recurse
foreach ($f in @('vendor_boot_a_swcodec.img', 'vendor_boot_a_orig.img', 'start-kvm.bat')) {
    Copy-Item (Join-Path $Root $f) (Join-Path $PkgRoot $f) -ErrorAction SilentlyContinue
}
Copy-Item (Join-Path $Root 'scripts\RELEASE-README.md') (Join-Path $PkgRoot 'README-发行版.md')
Copy-Item (Join-Path $Root 'LICENSE') (Join-Path $PkgRoot 'LICENSE') -ErrorAction SilentlyContinue

# ---------- [2] 准备 tools ----------
Step '准备 tools（mtk-mod-tee-nogz + pwnage24mtk）'
$toolsOut = Join-Path $PkgRoot 'tools'
New-Item -ItemType Directory -Force -Path $toolsOut | Out-Null

function Get-ToolRepo([string]$Repo, [string]$Name, [string]$LocalDir) {
    # 候选顺序：仓库内 tools-src/ → D:\ 现成克隆 → 重新 clone
    foreach ($cand in @($LocalDir, (Join-Path 'D:\' $Name))) {
        if ((Test-Path $cand) -and -not $ForceFetchTools) { return $cand }
    }
    if (Test-Path $LocalDir) { Remove-Item $LocalDir -Recurse -Force }
    git clone --depth 1 $Repo $LocalDir
    if ($LASTEXITCODE -ne 0) { throw "git clone $Repo 失败（检查代理/网络）" }
    return $LocalDir
}

$fix = Join-Path $Root 'scripts\fix-upstream.ps1'
if (Test-Path $fix) {
    $teeRepo = Get-ToolRepo 'https://github.com/MT6895-Mainline/mtk-mod-tee-nogz' 'mtk-mod-tee-nogz' (Join-Path $Root 'tools-src\mtk-mod-tee-nogz')
    $pwnRepo = Get-ToolRepo 'https://github.com/kasnria001/pwnage24mtk'          'pwnage24mtk'          (Join-Path $Root 'tools-src\pwnage24mtk')
    # 打补丁（幂等）：sign_all_flag 定义 + xagapro profile + choices
    & $fix -TeeFixRepo $teeRepo -ProjRepo $Root
    if ($LASTEXITCODE -ne 0) { throw 'fix-upstream 失败' }
    Copy-Item $teeRepo (Join-Path $toolsOut 'mtk-mod-tee-nogz') -Recurse
    Copy-Item $pwnRepo (Join-Path $toolsOut 'pwnage24mtk') -Recurse
    # 移掉工具仓库里的 .git 与 .venv（减小体积、避免携带本机 venv）
    Get-ChildItem $toolsOut -Recurse -Directory -Filter '.git' -Force  | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $toolsOut -Recurse -Directory -Filter '.venv' -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
    # 直接拷仓库里已有的 tools（如果没有 fix-upstream 这种情况基本不会发生）
    Copy-Item (Join-Path $Root 'tools') $toolsOut -Recurse -ErrorAction SilentlyContinue
}

# ---------- [3] 准备 adb（platform-tools） ----------
Step '准备 adb（优先用本机已有 platform-tools，否则下载）'
$ptOut = Join-Path $toolsOut 'platform-tools'
New-Item -ItemType Directory -Force -Path $ptOut | Out-Null
$ptCands = @(
    (Join-Path $Root 'tools-src\platform-tools'),
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools'),
    'C:\Program Files\UotanToolbox\Bin\platform-tools',
    'C:\platform-tools'
)
$ptSrc = $null
foreach ($c in $ptCands) { if ($c -and (Test-Path (Join-Path $c 'adb.exe'))) { $ptSrc = $c; break } }
if (-not $ptSrc) {
    $ptSrc = Join-Path $Root 'tools-src\platform-tools'
    if (-not (Test-Path (Join-Path $ptSrc 'adb.exe'))) {
        $zip = Join-Path $env:TEMP 'platform-tools.zip'
        Info "下载 platform-tools ..."
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -Proxy 'http://127.0.0.1:10808' -TimeoutSec 300
        Expand-Archive -Path $zip -DestinationPath (Split-Path $ptSrc -Parent) -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path (Join-Path $ptSrc 'adb.exe'))) { throw "拿不到 platform-tools（缺少 adb.exe）: $ptSrc" }
# 只带必需的几个文件（约 11 MB），不携 etc1tool/sqlite3 等无关工具
foreach ($f in @('adb.exe','fastboot.exe','AdbWinApi.dll','AdbWinUsbApi.dll','libwinpthread-1.dll','NOTICE.txt','source.properties')) {
    $srcFile = Join-Path $ptSrc $f
    if (Test-Path $srcFile) { Copy-Item $srcFile (Join-Path $ptOut $f) -Force }
}
Ok "adb 已打包: $([math]::Round((Get-ChildItem $ptOut -File | Measure-Object Length -Sum).Sum/1MB,1)) MB（来源：$ptSrc）"

# ---------- [4] 打包 ----------
Step '打包 zip'
$ver = Get-Date -Format 'yyyyMMdd'
$zip = Join-Path $Dist "xaga-kvm-release-$ver.zip"
Compress-Archive -Path $PkgRoot -CompressionLevel Optimal -DestinationPath $zip
Write-Host ''
Write-Host "  ZIP: $zip" -ForegroundColor Green
"{0:N0} KB" -f ((Get-Item $zip).Length / 1KB) | Write-Host

# ---------- 清理 ----------
Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host '  下一步：gh release create v0.1 --title "..." --notes "..." dist\xaga-kvm-release-*.zip' -ForegroundColor Cyan
Write-Host '  然后更新 README 快速开始的下载链接。' -ForegroundColor Cyan
