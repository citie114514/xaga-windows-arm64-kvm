# ============================================================================
#  run-oneclick.ps1 —— Release bundle entry point (multi-language)
#
#  What it does: after extracting the xaga-kvm release zip, run this (or
#  start-kvm.bat) and it will: validate the bundle -> check Python -> create a
#  venv and install deps (first run) -> patch upstream tools -> run kvm-oneclick
#  (backup / dump / build / sign / flash) -> offer the vendor_boot patch.
#  No repo cloning needed; every tool ships inside the bundle.
#
#  Usage:
#      .\run-oneclick.ps1                 # interactive, asks language
#      .\run-oneclick.ps1 -Lang en        # skip the language prompt
#      .\run-oneclick.ps1 -DryRun         # build & verify only, no flashing
#      .\run-oneclick.ps1 -Yes            # auto-confirm everything
#      .\run-oneclick.ps1 -SkipVendorBoot # skip the vendor_boot step
#
#  Requires: unlocked bootloader, root, USB debugging.
# ============================================================================
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $SkipVendorBoot,
    [ValidateSet('zh','en','ja','ru')]
    [string] $Lang
)

$ErrorActionPreference = 'Stop'

# ---------------- messages (zh / en / ja / ru) ----------------
$MSG = @{
  zh = @{
    pickTitle = '选择语言 / Language / 言語 / Язык'
    pickHint  = '回车默认 [1] 中文'
    title     = 'XAGA KVM 一键开 KVM —— 发行版入口'
    stepStruct= '校验发行版结构'
    okStruct  = '发行版结构完整'
    dieStruct = '缺少必需文件（zip 是否解压完整？）'
    stepPy    = '检查 Python'
    okPy      = 'python'
    diePy     = '找不到 Python —— 请安装 Python 3.10+（勾选 Add to PATH）'
    stepVenv  = '创建 Python 虚拟环境并安装依赖（首次运行需要几分钟）'
    okVenvNew = '依赖安装完成'
    okVenvOld = '虚拟环境已存在，跳过'
    diePip    = 'pip install 失败（已尝试镜像与官方源，检查网络后重试）'
    stepPatch = '检查上游工具补丁'
    infoPatch = '上游工具缺补丁，正在修复'
    okPatch   = '上游工具就绪'
    diePatch  = '上游补丁失败'
    stepRun   = '运行 kvm-oneclick（备份 → dump → 构建 → 签名 → 刷入）'
    okRun     = 'kvm-oneclick 完成'
    dieRun    = 'kvm-oneclick 失败，请看上方日志'
    hintVB    = '想让录屏 / 串流 / QQ 图片恢复，并让开机第二屏等待消失？下一步刷 vendor_boot 软编回退补丁：'
    dryRunVB  = '（-DryRun 模式：只演示命令，不刷）'
    okAll     = '全部完成。重启后验证：adb shell su -c "ls -l /dev/kvm"'
    noteLog   = '注意：下面各步骤的详细日志是中文（脚本原文），关键行看 [OK] / [XX] / Result: VALID。'
    vbFail    = 'flash-vendor-boot 未执行或失败（可用 -SkipVendorBoot 跳过本步骤）'
  }
  en = @{
    pickTitle = 'Choose language / Language / 言語 / Язык'
    pickHint  = 'Press Enter for [1] Chinese'
    title     = 'XAGA KVM — release bundle entry point'
    stepStruct= 'Validating bundle structure'
    okStruct  = 'Bundle structure OK'
    dieStruct = 'Missing required files (is the zip fully extracted?)'
    stepPy    = 'Checking Python'
    okPy      = 'python'
    diePy     = 'Python not found — install Python 3.10+ and tick "Add to PATH"'
    stepVenv  = 'Creating the Python venv and installing dependencies (first run, a few minutes)'
    okVenvNew = 'Dependencies installed'
    okVenvOld = 'venv already present, skipping'
    diePip    = 'pip install failed (tried mirror and official index; check your network)'
    stepPatch = 'Checking upstream tool patches'
    infoPatch = 'Upstream tools are missing patches, applying'
    okPatch   = 'Upstream tools ready'
    diePatch  = 'Upstream patch failed'
    stepRun   = 'Running kvm-oneclick (backup → dump → build → sign → flash)'
    okRun     = 'kvm-oneclick finished'
    dieRun    = 'kvm-oneclick failed, see the log above'
    hintVB    = 'Want screen recording / streaming / QQ images back, and the second-screen boot wait gone? Next: flash the vendor_boot software-codec patch:'
    dryRunVB  = '(-DryRun: showing the command only, nothing is flashed)'
    okAll     = 'All done. After reboot verify: adb shell su -c "ls -l /dev/kvm"'
    noteLog   = 'Note: the detailed step logs below are in Chinese (the scripts'' native language). Watch for [OK] / [XX] / Result: VALID.'
    vbFail    = 'flash-vendor-boot did not run or failed (use -SkipVendorBoot to skip it)'
  }
  ja = @{
    pickTitle = '言語を選択 / Language / 言語 / Язык'
    pickHint  = 'Enter で [1] 中国語'
    title     = 'XAGA KVM — 配布パッケージのエントリ'
    stepStruct= '配布構成を検証しています'
    okStruct  = '配布構成は正常です'
    dieStruct = '必須ファイルがありません（ZIP は完全に解凍されましたか？）'
    stepPy    = 'Python を確認しています'
    okPy      = 'python'
    diePy     = 'Python が見つかりません — Python 3.10+ を「Add to PATH」付きでインストールしてください'
    stepVenv  = 'Python 仮想環境を作成し依存関係をインストールします（初回は数分）'
    okVenvNew = '依存関係のインストール完了'
    okVenvOld = '仮想環境が既にあるためスキップ'
    diePip    = 'pip install が失敗しました（ミラーと公式を試しました。ネットワークを確認してください）'
    stepPatch = '上流ツールのパッチを確認しています'
    infoPatch = '上流ツールにパッチが無いため適用します'
    okPatch   = '上流ツールの準備完了'
    diePatch  = '上流パッチの適用に失敗しました'
    stepRun   = 'kvm-oneclick を実行中（バックアップ → dump → ビルド → 署名 → 書き込み）'
    okRun     = 'kvm-oneclick 完了'
    dieRun    = 'kvm-oneclick が失敗しました。上のログを確認してください'
    hintVB    = '録画・ストリーミング・QQ 画像を復活させ、2 画面目の待ちも消しますか？次は vendor_boot ソフトコーデックパッチです：'
    dryRunVB  = '（-DryRun：コマンド表示のみ、書き込みません）'
    okAll     = 'すべて完了。再起動後に確認：adb shell su -c "ls -l /dev/kvm"'
    noteLog   = '注意：以下の詳細ログは中国語（スクリプト本来の言語）です。重要な行は [OK] / [XX] / Result: VALID を見てください。'
    vbFail    = 'flash-vendor-boot は実行されなかったか失敗しました（-SkipVendorBoot で省略できます）'
  }
  ru = @{
    pickTitle = 'Выберите язык / Language / 言語 / Язык'
    pickHint  = 'Enter — [1] китайский'
    title     = 'XAGA KVM — вход в комплект релиза'
    stepStruct= 'Проверка структуры комплекта'
    okStruct  = 'Структура комплекта в порядке'
    dieStruct = 'Не хватает обязательных файлов (архив распакован полностью?)'
    stepPy    = 'Проверка Python'
    okPy      = 'python'
    diePy     = 'Python не найден — установите Python 3.10+ с «Add to PATH»'
    stepVenv  = 'Создание venv и установка зависимостей (первый запуск, несколько минут)'
    okVenvNew = 'Зависимости установлены'
    okVenvOld = 'venv уже есть, пропускаем'
    diePip    = 'pip install не удался (пробовали зеркало и официальный индекс; проверьте сеть)'
    stepPatch = 'Проверка патчей апстрим-инструментов'
    infoPatch = 'В апстрим-инструментах нет патчей, применяем'
    okPatch   = 'Апстрим-инструменты готовы'
    diePatch  = 'Патч апстрима не применился'
    stepRun   = 'Запуск kvm-oneclick (резервная копия → dump → сборка → подпись → запись)'
    okRun     = 'kvm-oneclick завершён'
    dieRun    = 'kvm-oneclick не удался, смотрите лог выше'
    hintVB    = 'Хотите вернуть запись экрана / стриминг / картинки QQ и убрать ожидание на втором экране? Дальше — патч vendor_boot с программными кодеками:'
    dryRunVB  = '(-DryRun: только показываем команду, ничего не пишем)'
    okAll     = 'Готово. После перезагрузки проверьте: adb shell su -c "ls -l /dev/kvm"'
    noteLog   = 'Внимание: подробные логи ниже на китайском (родной язык скриптов). Смотрите строки [OK] / [XX] / Result: VALID.'
    vbFail    = 'flash-vendor-boot не запускался или завершился ошибкой (можно пропустить через -SkipVendorBoot)'
  }
}

# ---------------- language picker ----------------
if (-not $Lang) {
    Write-Host ''
    Write-Host '  =================================================='
    Write-Host '   XAGA KVM'
    Write-Host '  =================================================='
    Write-Host ''
    Write-Host "  $($MSG.zh.pickTitle)" -ForegroundColor Cyan
    Write-Host '    [1] 中文'
    Write-Host '    [2] English'
    Write-Host '    [3] 日本語'
    Write-Host '    [4] Русский'
    Write-Host ''
    $pick = Read-Host "  $($MSG.zh.pickHint)"
    switch ($pick.Trim()) {
        '2' { $Lang = 'en' }
        '3' { $Lang = 'ja' }
        '4' { $Lang = 'ru' }
        default { $Lang = 'zh' }
    }
}
$M = $MSG[$Lang]

# ---------------- paths ----------------
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
    return $null
}

Title $M.title

# ---------------- [1] bundle structure ----------------
Step $M.stepStruct
foreach ($need in @(
    (Join-Path $TeeFixRepo 'scripts\build.py'),
    (Join-Path $PwnageDir 'sign_mtk_cert.py'),
    (Join-Path $Scripts 'kvm-oneclick.ps1'),
    (Join-Path $Scripts 'flash-vendor-boot.ps1')
)) {
    if (-not (Test-Path $need)) { Die "$($M.dieStruct)`n  $need" }
}
Ok "$($M.okStruct): $Root"

# ---------------- [2] python ----------------
Step $M.stepPy
$py = Find-Tool 'python'
if (-not $py) {
    foreach ($cand in @("$env:LOCALAPPDATA\Programs\Python\Python*\python.exe", "C:\Python*\python.exe")) {
        $hit = Get-ChildItem $cand -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $py = $hit.FullName; break }
    }
}
if (-not $py) { Die $M.diePy }
Ok "$($M.okPy): $py"

# ---------------- [3] venv + deps ----------------
$venvPy = Join-Path $TeeFixRepo '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
    Step $M.stepVenv
    & $py -m venv (Join-Path $TeeFixRepo '.venv')
    if ($LASTEXITCODE -ne 0) { Die 'venv creation failed' }
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
        if (-not $ok) { Die $M.diePip }
    }
    Ok $M.okVenvNew
} else {
    Ok $M.okVenvOld
}

# ---------------- [4] upstream patches ----------------
Step $M.stepPatch
$buildSrc = Get-Content (Join-Path $TeeFixRepo 'scripts\build.py') -Raw -Encoding UTF8
if (($buildSrc -notmatch 'def sign_all_flag') -or ($buildSrc -notmatch '"xagapro"')) {
    Info $M.infoPatch
    & (Join-Path $Scripts 'fix-upstream.ps1') -TeeFixRepo $TeeFixRepo -ProjRepo $Root
    if ($LASTEXITCODE -ne 0) { Die $M.diePatch }
}
Ok $M.okPatch

# ---------------- [5] kvm-oneclick ----------------
Step $M.stepRun
Write-Host "  $($M.noteLog)" -ForegroundColor DarkGray
$oneclickArgs = @{
    Profile    = 'xagapro'
    TeeFixRepo = $TeeFixRepo
    PwnageDir  = $PwnageDir
    ProjRepo   = $Root
    WorkDir    = (Join-Path $Root 'kvm-work')
}
if ($DryRun) { $oneclickArgs.DryRun = $true }
if ($Yes)    { $oneclickArgs.Yes    = $true }

& (Join-Path $Scripts 'kvm-oneclick.ps1') @oneclickArgs
if ($LASTEXITCODE -ne 0) { Die $M.dieRun }
Ok $M.okRun

# ---------------- [6] vendor_boot ----------------
if (-not $SkipVendorBoot) {
    Write-Host ''
    Write-Host "  $($M.hintVB)" -ForegroundColor Cyan
    $vbArgs = @{}
    if ($DryRun) { $vbArgs.DryRun = $true }
    if ($Yes)    { $vbArgs.Yes    = $true }
    if ($DryRun) {
        Info $M.dryRunVB
        Write-Host "      cd `"$Scripts`"; .\flash-vendor-boot.ps1" -ForegroundColor Gray
    } else {
        & (Join-Path $Scripts 'flash-vendor-boot.ps1') @vbArgs
        if ($LASTEXITCODE -ne 0) { Info $M.vbFail }
    }
}

Write-Host ''
Ok $M.okAll
