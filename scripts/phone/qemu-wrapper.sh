#!/system/bin/sh
# ============================================================================
#  DroidVM 的 QEMU 包装脚本（包装 qemu-system-aarch64.real）
#
#  做三件事：
#   1) 记录完整参数到 /data/local/tmp/qemu-args.log（排错用，很有用）
#   2) 自动补 DroidVM 应用**没有**传的东西：
#        · -netdev user      → 给 virtio-net-pci 挂上用户态 NAT（有网）
#        · virtio-balloon-pci → 气球内存（装了 blnsvr 后能把内存还给 Android）
#      只在"调用方没给"时才补，所以本项目的 boot-win.sh（自己带了这些）
#      不会被重复添加。用 auto0 作为 id，避免和调用方的 id 撞车。
#   3) 把整个进程绑到 A78 簇（cpu4-7, mask=f0）
#      —— 避开 big.LITTLE 迁移导致的 KVM 寄存器竞态
#         （不绑核时 -cpu host 实测 5 次里失败 3 次）
#
#  注意：-netdev 必须在引用它的 -device 之前定义，所以插在参数最前面。
# ============================================================================

REAL=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64.real
LOG=/data/local/tmp/qemu-args.log

# ---- 1) 记录参数 -----------------------------------------------------------
{
    echo "=== $(date) ==="
    for a in "$@"; do echo "  $a"; done
} >> "$LOG" 2>/dev/null

# ---- 2) 扫描调用方给了什么 -------------------------------------------------
have_netdev=0
have_balloon=0
nic_without_netdev=0

for a in "$@"; do
    case "$a" in
        -netdev) have_netdev=1 ;;
        virtio-net-pci*)
            case "$a" in
                *,netdev=*) ;;              # 已经挂了后端，不用管
                *) nic_without_netdev=1 ;;  # 有网卡但没后端 → 要补
            esac
            ;;
        virtio-balloon*) have_balloon=1 ;;
    esac
done

# 不需要补就直通，保持零开销
if { [ "$have_netdev" = 1 ] || [ "$nic_without_netdev" = 0 ]; } && [ "$have_balloon" = 1 ]; then
    exec /system/bin/taskset f0 "$REAL" "$@"
fi

# ---- 3) 重建参数表（用文件按行存取，避免参数里的空格被拆开）-----------------
TMP=/data/local/tmp/.qemu-argv.$$
if ! printf '%s\n' "$@" > "$TMP" 2>/dev/null; then
    exec /system/bin/taskset f0 "$REAL" "$@"
fi

set --
# 网卡需要后端时，把 -netdev 插到最前面（QEMU 要求先定义再被引用）
if [ "$have_netdev" = 0 ] && [ "$nic_without_netdev" = 1 ]; then
    set -- "$@" -netdev user,id=auto0
fi

while IFS= read -r a; do
    case "$a" in
        virtio-net-pci*)
            case "$a" in
                *,netdev=*) ;;
                *) a="$a,netdev=auto0" ;;
            esac
            ;;
    esac
    set -- "$@" "$a"
done < "$TMP"

if [ "$have_balloon" = 0 ]; then
    set -- "$@" -device virtio-balloon-pci,disable-legacy=on,disable-modern=off
fi

rm -f "$TMP" 2>/dev/null

# ---- 4) 绑核执行 -----------------------------------------------------------
exec /system/bin/taskset f0 "$REAL" "$@"
