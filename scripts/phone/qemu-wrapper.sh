#!/system/bin/sh
# ============================================================================
#  DroidVM 的 QEMU 包装脚本（包装 qemu-system-aarch64.real）
#
#  做四件事：
#   1) 记录完整参数到 /data/local/tmp/qemu-args.log（排错用，很有用）
#   2) pflash unit 修正：DroidVM 用 "-bios 固件 + -drive if=pflash(vars)"，
#      但 vars 不写 unit= → 被挂到 pflash0 与 -bios 冲突
#      （QEMU: cannot use both options at once）→ 给无 unit= 的 pflash drive 补 unit=1
#   3) 自动补 DroidVM 应用**没有**传的东西：
#        · -netdev user      → 给 virtio-net-pci 挂上用户态 NAT（有网）
#        · virtio-balloon-pci → 气球内存（装了 blnsvr 后能把内存还给 Android）
#      只在"调用方没给"时才补，所以本项目的 boot-win.sh（自己带了这些）
#      不会被重复添加。用 auto0 作为 id，避免和调用方的 id 撞车。
#   4) 把整个进程绑到 A78 簇（cpu4-7, mask=f0）
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
need_pflash_unit=0

prev=""
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
        -drive)
            # 前一个参数是 -drive 时当前是它的值；这里处理的是"当前 a 是 drive 值"的情形
            ;;
        *,if=pflash,*)
            # 只在紧跟 -drive 后面的值里判断
            if [ "$prev" = "-drive" ]; then
                case "$a" in
                    *,unit=*) ;;            # 已指定 unit，不动
                    *) need_pflash_unit=1 ;; # 无 unit= → 要补 unit=1
                esac
            fi
            ;;
    esac
    prev="$a"
done

# ---- 3) pflash unit 修正（无论后面走不走直通，都必须做）----------------------
# vars 挂 pflash1（标准 AAVMF 双 flash 布局：flash0=代码，flash1=vars）
if [ "$need_pflash_unit" = 1 ]; then
    TMP2=/data/local/tmp/.qemu-argv2.$$
    prev=""
    : > "$TMP2" 2>/dev/null || TMP2=""
    if [ -n "$TMP2" ] && printf '' >> "$TMP2" 2>/dev/null; then
        for a in "$@"; do
            if [ "$prev" = "-drive" ]; then
                case "$a" in
                    *,if=pflash,*)
                        case "$a" in
                            *,unit=*) ;;
                            *) a="$a,unit=1" ;;
                        esac
                        ;;
                esac
            fi
            printf '%s\n' "$a" >> "$TMP2"
            prev="$a"
        done
        set --
        while IFS= read -r a; do set -- "$@" "$a"; done < "$TMP2"
        rm -f "$TMP2" 2>/dev/null
    else
        # 临时文件不可用（罕见）：保险起见不修改参数，直接执行
        exec /system/bin/taskset f0 "$REAL" "$@"
    fi
fi

# ---- 4) 缺 netdev/balloon 时的补齐 -----------------------------------------
# 都齐了就直通，保持零开销
if { [ "$have_netdev" = 1 ] || [ "$nic_without_netdev" = 0 ]; } && [ "$have_balloon" = 1 ]; then
    exec /system/bin/taskset f0 "$REAL" "$@"
fi

# ---- 重建参数表（用文件按行存取，避免参数里的空格被拆开）---------------------
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

# ---- 5) 绑核执行 -----------------------------------------------------------
exec /system/bin/taskset f0 "$REAL" "$@"
