#!/usr/bin/env python3
"""给 freshly-cloned mtk-mod-tee-nogz 打两个必要补丁（跨平台版，供 CI 与手动使用）。

1) build.py 调用了未定义的 sign_all_flag() → 签名路径必然 NameError
2) --profile choices 与 references/profiles.json 都缺 xagapro（f8f286f1 基座批次）

用法：
    python scripts/fix-upstream.py --tee-fix <mtk-mod-tee-nogz 路径> --proj <本仓库根>

幂等：已打过就跳过。
"""
import argparse
import hashlib
import json
import os
import sys

# Windows 控制台可能是 GBK，统一按 UTF-8 输出并容错，避免打印符号时崩溃
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SIGN_HOOK = '''
def sign_all_flag(tools):
    # Patched for xaga-windows-arm64-kvm (issues/tee-nogz-1-sign-all-flag):
    # upstream called this helper without defining it -> NameError on the signing path.
    # Current sign_mtk_cert.py does not accept --all, so return an empty list.
    return []
'''

ANCHOR = "def detect_signing_mode(preloader, output_dir):"
CHOICES_OLD = '"--profile", choices=["yunluo", "peral", "xaga"]'
CHOICES_NEW = '"--profile", choices=["yunluo", "peral", "xaga", "xagapro"]'


def norm(value):
    """profiles.json 里 load_profile 只对 str 调 int(v,0)；int 与 list 元素统一成 0x 字符串。"""
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return hex(value)
    if isinstance(value, list):
        return [norm(v) for v in value]
    return value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tee-fix", required=True, help="mtk-mod-tee-nogz 仓库路径")
    ap.add_argument("--proj", required=True, help="本项目仓库根（读 profiles/xagapro.json 与 tee/）")
    args = ap.parse_args()

    build_py = os.path.join(args.tee_fix, "scripts", "build.py")
    profiles_json = os.path.join(args.tee_fix, "references", "profiles.json")
    for p in (build_py, profiles_json):
        if not os.path.isfile(p):
            sys.exit(f"[失败] 找不到 {p}")

    # ---------- 补丁 1：sign_all_flag 定义 ----------
    src = open(build_py, encoding="utf-8").read()
    if "def sign_all_flag" in src:
        print("[跳过] sign_all_flag 已存在")
    elif "sign_all_flag(" in src:
        if ANCHOR not in src:
            sys.exit("[失败] build.py 结构变了，找不到插入锚点")
        src = src.replace(ANCHOR, SIGN_HOOK.strip("\n") + "\n\n\n" + ANCHOR, 1)
        print("[OK]   已插入 sign_all_flag()")
    else:
        sys.exit("[失败] build.py 既没定义也没调用 sign_all_flag")

    # ---------- 补丁 2：choices ----------
    if CHOICES_OLD in src:
        src = src.replace(CHOICES_OLD, CHOICES_NEW, 1)
        print("[OK]   --profile choices 已扩展")
    elif '"xagapro"' in src:
        print("[跳过] choices 已含 xagapro")
    else:
        print("[警告] 没找到 choices 行，请人工检查")

    open(build_py, "w", encoding="utf-8", newline="\n").write(src)

    # ---------- 补丁 3：xagapro profile ----------
    prof = json.load(open(profiles_json, encoding="utf-8"))
    if "xagapro" in prof:
        print("[跳过] profiles.json 已有 xagapro")
    else:
        ours_path = os.path.join(args.proj, "profiles", "xagapro.json")
        if not os.path.isfile(ours_path):
            sys.exit(f"[失败] 找不到 {ours_path}")
        ours = json.load(open(ours_path, encoding="utf-8"))["xagapro"]
        # 历史产出校验：仓库里的实机验证成品
        rk = os.path.join(args.proj, "tee", "tee_nogz_rk_5M.img")
        if os.path.isfile(rk):
            ours["historical_output_sha256"] = hashlib.sha256(open(rk, "rb").read()).hexdigest()
            ours["historical_output_cert_mode"] = "legacy"
        prof["xagapro"] = {k: norm(v) for k, v in ours.items()}
        json.dump(prof, open(profiles_json, "w", encoding="utf-8"), indent=2)
        print("[OK]   profiles.json 已合入 xagapro")

    print("done")


if __name__ == "__main__":
    main()
