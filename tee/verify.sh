#!/usr/bin/env bash
# ---------------------------------------------------------------
#  tee 基座自检 —— 看你的设备到底能用哪个成品补丁
#
#  用法:
#     bash tee/verify.sh              # 自动挑第一个已连接设备
#     bash tee/verify.sh <serial>     # 指定设备（adb devices 里看到的那个）
#
#  依赖: adb（在 PATH 里即可）+ 设备已 root
# ---------------------------------------------------------------
set -u

# ---- 已知的成品补丁（基座 -> 文件名 / 备注）--------------------
declare -A PATCH_OF=(
  ["f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062"]="tee_nogz_rk_5M.img"
  ["a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7"]="tee_nogz_shuilanA15_5M.img"
)
declare -A NOTE_OF=(
  ["f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062"]="实机验证成功 ✅"
  ["a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7"]="离线全过 / 未实机验证 ⏳"
)
# ---- 已经刷入补丁后的 tee_a（刷完再跑本脚本时应该看到这些）--------
declare -A PATCHED_OF=(
  ["f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689"]="tee_nogz_rk_5M.img"
  ["17ec849749febda62445f922ec3ee8b65a3092f0ea2c641e98eb732fbe60ee59"]="tee_nogz_shuilanA15_5M.img"
)
FACTORY_TEE_B="f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062"
PART_SIZE=5242880

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31m[!!]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[..]\033[0m   %s\n' "$*"; }

# ---- 找 adb ----------------------------------------------------
if command -v adb >/dev/null 2>&1; then
  ADB=adb
else
  for c in \
    "/c/Program Files/UotanToolbox/Bin/platform-tools/adb" \
    "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" \
    "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
    "/c/platform-tools/adb.exe" ; do
    [ -f "$c" ] && ADB="$c" && break
  done
  [ -z "${ADB:-}" ] && { bad "找不到 adb，请把它加进 PATH 或用完整路径改本脚本"; exit 1; }
fi
say "adb: $ADB"

# ---- 选设备 ----------------------------------------------------
SERIAL="${1:-}"
if [ -z "$SERIAL" ]; then
  SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  [ -z "$SERIAL" ] && { bad "没有已连接且已授权的设备"; exit 1; }
fi
say "设备: $SERIAL"
say ""

# ---- 身份 ------------------------------------------------------
say "====== 设备身份 ======"
for p in ro.serialno ro.product.device ro.build.version.release ro.build.display.id ro.boot.slot_suffix; do
  v="$("$ADB" -s "$SERIAL" shell getprop $p 2>/dev/null | tr -d '\r')"
  printf '  %-24s %s\n' "$p" "$v"
done
say ""

# ---- root ------------------------------------------------------
say "====== root 检查 ======"
if [ "$("$ADB" -s "$SERIAL" shell 'su -c id -u' 2>/dev/null | tr -d '\r' | tail -1)" = "0" ]; then
  ok "已 root"
else
  bad "拿不到 root（su 失败）—— 后续无法读取 tee 分区"
  exit 1
fi
say ""

# ---- 读 tee ----------------------------------------------------
# 用 MSYS_NO_PATHCONV 防止 Git Bash 把 /data/... 转成 Windows 路径
h() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$SERIAL" shell \
    "su -c 'dd if=/dev/block/by-name/$1 bs=4096 2>/dev/null | sha256sum'" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}
sz() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$SERIAL" shell \
    "su -c 'blockdev --getsize64 /dev/block/by-name/$1 2>/dev/null'" 2>/dev/null | tr -d '\r' | tail -1
}

say "====== tee 分区 ======"
TEE_A="$(h tee_a)"; TEE_B="$(h tee_b)"
SA="$(sz tee_a)";  SB="$(sz tee_b)"

printf '  %-8s %-70s %s bytes\n' "tee_a" "${TEE_A:-<读不到>}" "${SA:-?}"
printf '  %-8s %-70s %s bytes\n' "tee_b" "${TEE_B:-<读不到>}" "${SB:-?}"
say ""

if [ -n "$SA" ] && [ "$SA" != "$PART_SIZE" ]; then
  warn "tee_a 尺寸 $SA 与预期的 $PART_SIZE 不同 —— 你的机型可能不是本项目的目标"
  say ""
fi

# ---- 判断 ------------------------------------------------------
say "====== 结论 ======"
if [ "$TEE_B" = "$FACTORY_TEE_B" ]; then
  ok "tee_b 是原厂基座（f8f286f1…）—— 你这台设备的 tee 基座未被 ROM 改过"
else
  warn "tee_b 不是原厂基座 —— 说明基座被改过，需格外小心"
fi
say ""

if [ -n "$TEE_A" ] && [ -n "${PATCHED_OF[$TEE_A]:-}" ]; then
  ok "你的 tee_a 已经是**刷好补丁**的状态 ✅"
  ok "对应成品:  tee/${PATCHED_OF[$TEE_A]}"
  say ""
  say "  → 不用再刷了。直接验证 KVM:"
  say "      adb shell su -c 'ls -l /dev/kvm'"
  say "      adb shell su -c 'grep -i kvm /proc/misc'"
  say ""
  say "  如果 /dev/kvm 不存在，说明补丁虽然写入了但没生效，请 dump 日志排查:"
  say "      adb shell su -c 'dmesg | grep -i -E \"sbc|kvm|atf\" | tail -30'"
elif [ -n "$TEE_A" ] && [ -n "${PATCH_OF[$TEE_A]:-}" ]; then
  ok "你的 tee_a = ${TEE_A:0:16}… （这是**未打补丁的原厂基座**）"
  ok "可以刷:  tee/${PATCH_OF[$TEE_A]}   （${NOTE_OF[$TEE_A]}）"
  say ""
  say "  刷之前记得先备份:"
  say "    adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a_backup.img bs=4096'"
  say "    adb pull /data/local/tmp/tee_a_backup.img"
elif [ -n "$TEE_A" ]; then
  bad "你的 tee_a = ${TEE_A:0:16}… 不在成品清单里"
  say ""
  say "  → 需要**自己构建**（大约 1~2 小时）:"
  say "      1. dump 出 tee_a / lk_a / preloader_raw_a"
  say "      2. 按 docs/02-build-and-sign.md 走一遍"
  say "      3. 工具在 tools/ 里（capstone + unicorn 就够了）"
  say ""
  say "  完整哈希以便你对照:"
  say "      $TEE_A"
else
  bad "读不到 tee_a —— 检查 root 权限"
fi
