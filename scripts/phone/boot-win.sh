#!/system/bin/sh
# ============================================================================
#  Windows ARM64 @ Redmi Note 11T Pro+ (xaga) —— QEMU + KVM 启动脚本
#
#  用法:  su -c sh /data/local/tmp/boot-win.sh [磁盘路径]
#         默认磁盘 /data/media/0/DroidVM/win.vhdx
#
#  看画面（在 PC 上）:
#         adb forward tcp:5900 tcp:5900
#         VNC 客户端连 127.0.0.1:5900（无密码）
#
#  ⚠️ VNC 端口锁定 5900：QEMU 的 -vnc :0 表示 display 0 → 端口 5900；
#     若 5900 被占，QEMU 会**静默 +1 挪到 5901**，所以这里先等端口空闲，
#     启动后再核对实际端口，不对就报错退出。
# ============================================================================

Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=${1:-/data/media/0/DroidVM/win.vhdx}
ISO=/data/local/tmp/virtio-win.iso
LOG=/data/local/tmp/win-qemu.log
SER=/data/local/tmp/win-serial.log
VNC_PORT=5900
VNC_DISP=0

die() { echo "❌ $*"; exit 1; }

echo "=== 0) 前置检查 ==="
[ -x "$Q" ]  || die "找不到 QEMU: $Q"
[ -f "$FW" ] || die "找不到固件: $FW"
[ -c /dev/kvm ] || die "没有 /dev/kvm —— NoGZ 补丁没生效？（跑 tee/verify.sh 看看）"
[ -f "$DISK" ] || die "找不到磁盘: $DISK
   如果磁盘丢了/被清掉了，把你备份的镜像放回去：
       su -c sh /data/local/tmp/restore-disk.sh <你的 win.vhdx>"
echo "  QEMU : $Q"
echo "  固件 : $FW"
echo "  磁盘 : $DISK  ($(ls -lh "$DISK" 2>/dev/null | awk '{print $5}'))"
echo "  KVM  : OK"

echo "=== 1) 清理旧实例 ==="
pkill qemu-system-aar 2>/dev/null
for i in $(seq 1 20); do
    [ -z "$(pgrep qemu-system-aar)" ] && break
    sleep 1
done
echo "  剩余 qemu 进程: $(pgrep qemu-system-aar | wc -l)"

echo "=== 2) 等待端口 $VNC_PORT 空闲 ==="
port_busy() { netstat -tln 2>/dev/null | grep -q ":$1 "; }
for i in $(seq 1 30); do
    port_busy $VNC_PORT || { echo "  $VNC_PORT 已空闲（等了 ${i}s）"; break; }
    echo "  等待中 ($i/30)..."
    sleep 1
done
if port_busy $VNC_PORT; then
    echo "  ❌ $VNC_PORT 仍被占用，放弃（避免 QEMU 静默挪到 5901）"
    netstat -tln 2>/dev/null | grep ":$VNC_PORT "
    exit 1
fi

rm -f "$LOG" "$SER" /data/local/tmp/qemu-args.log
export LD_LIBRARY_PATH=/system/lib64

echo "=== 3) 启动 QEMU ==="
set -- \
  -name win -L /data/data/cn.classfun.droidvm/usr/share/qemu \
  -accel kvm -machine virt -cpu host \
  -smp 4,sockets=1,cores=4,threads=1 -m 4096M \
  -bios "$FW" \
  -drive file="$DISK",if=none,id=nv0,format=vhdx,cache=writeback,aio=threads \
  -device virtio-blk-pci,drive=nv0,disable-legacy=on,disable-modern=off,bootindex=1 \
  -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-balloon-pci,disable-legacy=on,disable-modern=off \
  -device qemu-xhci,id=xhci \
  -device usb-tablet -device usb-kbd \
  -device virtio-gpu-pci,disable-legacy=on,disable-modern=off,xres=1920,yres=1080,edid=on \
  -serial file:"$SER" \
  -vnc 127.0.0.1:$VNC_DISP,lossy=on \
  -display none -nodefaults

if [ -f "$ISO" ]; then
    set -- "$@" -drive file="$ISO",if=none,id=cd0,media=cdrom,readonly=on \
                -device usb-storage,drive=cd0,removable=on
    echo "  已挂载光盘: $ISO"
fi

# 绑 A78 簇（mask f0）——避开 big.LITTLE 迁移导致的 KVM 竞态
nohup taskset f0 "$Q" "$@" > "$LOG" 2>&1 &
echo "  pid=$!"
sleep 6

echo "=== 4) 核对实际 VNC 端口 ==="
ACTUAL=$(netstat -tln 2>/dev/null | grep "127.0.0.1:" | grep -oE ":59[0-9][0-9] " | tr -d ' :' | head -1)
echo "  QEMU 实际监听: ${ACTUAL:-无}"
if [ "$ACTUAL" != "$VNC_PORT" ]; then
    echo "  ❌ 端口不是 $VNC_PORT（实际 ${ACTUAL:-无}）"
    ps -A -o PID,NAME 2>/dev/null | grep qemu | grep -v grep
    echo "  --- qemu 输出 ---"; cat "$LOG"
    exit 2
fi
echo "  ✅ 端口 = $VNC_PORT"

echo
echo "=== 启动完成 ==="
ps -A -o PID,USER,NAME 2>/dev/null | grep qemu | grep -v grep
echo "--- qemu stdout ---"; cat "$LOG"
echo
echo "接下来（在 PC 上）："
echo "  adb forward tcp:$VNC_PORT tcp:$VNC_PORT"
echo "  VNC 客户端连 127.0.0.1:$VNC_PORT（无密码，lossy=on 已开）"
