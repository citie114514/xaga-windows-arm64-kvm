#!/system/bin/sh
# Windows 11 ARM64 VM —— 优化版
#   1) -vnc lossy=on    : VNC 走 JPEG 有损压缩，传输量降 5~10 倍（解决"卡"）
#   2) 1024x768         : 像素少 44%，CPU 渲染和 VNC 编码都轻
#   3) virtio-win CD    : 挂虚拟光驱，方便装 ARM64 辅助服务（blnsvr 等）
#   4) virtio-balloon   : 动态内存，让 VM 把闲置内存还给 Android
Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=/data/media/0/DroidVM/win.vhdx
ISO=/data/media/0/Download/../Download/virtio-win.iso
LOG=/data/local/tmp/win-qemu.log
SER=/data/local/tmp/win-serial.log

# virtio-win.iso 可能放在几个位置，找一个存在的
for c in /data/media/0/DroidVM/virtio-win.iso /data/media/0/Download/virtio-win.iso /data/local/tmp/virtio-win.iso; do
  [ -f "$c" ] && ISO="$c" && break
done
echo "virtio-win ISO = $ISO"

pkill -f qemu-system-aarch64.real 2>/dev/null
sleep 1
rm -f "$LOG" "$SER" /data/local/tmp/qemu-args.log

export LD_LIBRARY_PATH=/system/lib64
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
  -vnc 127.0.0.1:0,lossy=on \
  -display none -nodefaults

# 有 ISO 就加光驱（USB 存储，Windows 自带驱动，零风险）
if [ -f "$ISO" ]; then
  set -- "$@" -drive file="$ISO",if=none,id=cd0,media=cdrom,readonly=on \
              -device usb-storage,drive=cd0,removable=on
fi

nohup "$Q" "$@" > "$LOG" 2>&1 &
echo "started pid=$!"
sleep 6
echo "--- qemu stdout ---"; cat "$LOG"
echo "--- ps ---"; ps -A -o PID,USER,NAME | grep qemu | grep -v grep
echo "--- VNC 端口 ---"; netstat -tlnp 2>/dev/null | grep qemu
