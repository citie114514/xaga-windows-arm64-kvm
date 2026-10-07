# ============================================================================
#  fix-upstream.ps1 —— 给 freshly-clone 的 mtk-mod-tee-nogz 打两个必要补丁
#
#  为什么要跑这个：上游仓库目前有两个问题，不修必挂：
#    1) scripts/build.py 调用了未定义的 sign_all_flag() → 签名步骤必报 NameError
#    2) --profile choices 里没有 xagapro（Note 11T Pro+ 的原厂基座批次 f8f286f1…）
#       且 references/profiles.json 里没有对应条目
#       （上游的 xaga profile 是另一批固件 bd4f13a7…，哈希校验对不上就直接中止）
#
#  修复内容：
#    - 插入 sign_all_flag() 定义（返回空列表；当前 sign_mtk_cert.py 不认 --all）
#    - 把本项目 profiles/ 目录里的 xagapro.json（含历史产出哈希校验）转成
#      上游 profiles.json 格式合入，并扩展 --profile choices
#
#  用法（管理员不必须）：
#      .\fix-upstream.ps1 -TeeFixRepo D:\mtk-mod-tee-nogz
#
#  可重复执行（幂等）：已打过的补丁会跳过。
#  参考来源：xaga-windows-arm64-kvm issues/tee-nogz-1-sign-all-flag.md
#            及本项目 profiles/xagapro.json（实机验证过的偏移）
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $TeeFixRepo,   # mtk-mod-tee-nogz 仓库路径
    [string] $ProjRepo = ''                             # 本项目仓库根（默认自动推断）
)

$ErrorActionPreference = 'Stop'

# ---------- 推断本项目仓库根（脚本在 <repo>\scripts\ 下） ----------
if (-not $ProjRepo) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $ProjRepo = Split-Path -Parent $here
}
$profilesDir = Join-Path $ProjRepo 'profiles'
if (-not (Test-Path (Join-Path $profilesDir 'xagapro.json'))) {
    Write-Host "[失败] 在 $profilesDir 找不到 xagapro.json —— 请确认 -ProjRepo 指向本项目仓库" -ForegroundColor Red
    exit 1
}

$buildPy   = Join-Path $TeeFixRepo 'scripts\build.py'
$profilesJson = Join-Path $TeeFixRepo 'references\profiles.json'
foreach ($f in @($buildPy, $profilesJson)) {
    if (-not (Test-Path $f)) {
        Write-Host "[失败] 找不到 $f —— -TeeFixRepo 指向的不是 mtk-mod-tee-nogz 仓库？" -ForegroundColor Red
        exit 1
    }
}

$py = $null
foreach ($c in @((Join-Path $TeeFixRepo '.venv\Scripts\python.exe'), 'python')) {
    try { & $c --version *>$null; $py = $c; break } catch { }
}
if (-not $py) { Write-Host '[失败] 找不到 python（先按教程建好 venv）' -ForegroundColor Red; exit 1 }

# ---------- 补丁 1：sign_all_flag 定义 ----------
$src = Get-Content $buildPy -Raw -Encoding UTF8
if ($src -match 'def sign_all_flag') {
    Write-Host '[跳过] sign_all_flag 已存在（可能上游已修复）' -ForegroundColor Yellow
} elseif ($src -match 'sign_all_flag\(') {
    $hook = @'

def sign_all_flag(tools):
    # Patched for xaga-windows-arm64-kvm (issues/tee-nogz-1-sign-all-flag):
    # upstream called this helper without defining it -> NameError on the signing path.
    # Current sign_mtk_cert.py does not accept --all, so return an empty list.
    return []
'@
    $anchor = 'def detect_signing_mode(preloader, output_dir):'
    if ($src -notmatch [regex]::Escape($anchor)) {
        Write-Host '[失败] 在 build.py 里找不到插入锚点（上游结构变了？）' -ForegroundColor Red; exit 1
    }
    $src = $src.Replace($anchor, ($hook + "`n" + $anchor))
    Set-Content -Path $buildPy -Value $src -Encoding UTF8 -NoNewline
    Write-Host '[OK]   补丁 1：sign_all_flag() 已插入 build.py' -ForegroundColor Green
} else {
    Write-Host '[失败] build.py 里既没有定义也没有调用 sign_all_flag（上游结构变了？）' -ForegroundColor Red; exit 1
}

# ---------- 补丁 2：xagapro profile 合入 + choices 扩展 ----------
$pyScript = @'
import json, hashlib, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
repo, proj = sys.argv[1], sys.argv[2]
pj = repo + r"\references\profiles.json"
up = json.load(open(pj, encoding="utf-8"))
changed = False
if "xagapro" not in up:
    ours = json.load(open(proj + r"\profiles\xagapro.json", encoding="utf-8"))["xagapro"]
    # 历史产出校验：本项目仓库 tee/tee_nogz_rk_5M.img 就是此 profile 的实机验证成品
    try:
        rk = hashlib.sha256(open(proj + r"\tee\tee_nogz_rk_5M.img", "rb").read()).hexdigest()
        ours["historical_output_sha256"] = rk
        ours["historical_output_cert_mode"] = "legacy"
    except OSError:
        pass
    def norm(v):
        if isinstance(v, bool): return v
        if isinstance(v, int): return hex(v)
        if isinstance(v, list): return [norm(e) for e in v]
        return v
    up["xagapro"] = {k: norm(v) for k, v in ours.items()}
    json.dump(up, open(pj, "w", encoding="utf-8"), indent=2)
    changed = True
src = open(repo + r"\scripts\build.py", encoding="utf-8").read()
old = '"--profile", choices=["yunluo", "peral", "xaga"]'
new = '"--profile", choices=["yunluo", "peral", "xaga", "xagapro"]'
if old in src:
    open(repo + r"\scripts\build.py", "w", encoding="utf-8", newline="").write(src.replace(old, new, 1))
    changed = True
    print("choices extended")
elif '"xagapro"' in src:
    pass
else:
    print("WARN: --profile choices 行没找到，请手工检查 build.py")
print("CHANGED" if changed else "ALREADY")
'@
$tmp = Join-Path $env:TEMP ('fixup-profiles-' + [guid]::NewGuid() + '.py')
[IO.File]::WriteAllText($tmp, ($pyScript -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
& $py $tmp $TeeFixRepo $ProjRepo
$rc = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if ($rc -ne 0) { Write-Host '[失败] profile 合并脚本出错' -ForegroundColor Red; exit 1 }

# ---------- 收尾校验 ----------
$check = & $py $buildPy --help 2>&1 | Out-String
if ($check -match 'xagapro') { Write-Host '[OK]   build.py 已接受 --profile xagapro' -ForegroundColor Green }
else { Write-Host '[警告] build.py --help 里没看到 xagapro，请手工确认' -ForegroundColor Yellow }

Write-Host ''
Write-Host '完成 ✓ 现在可以回到本项目 scripts 目录跑一键脚本：' -ForegroundColor Cyan
Write-Host '    .\kvm-oneclick.ps1 -Profile xagapro -TeeFixRepo <这个仓库> -PwnageDir <pwnage24mtk>' -ForegroundColor Cyan
