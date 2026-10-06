#!/system/bin/sh
# ============================================================================
#  安全停止 QEMU 虚拟机
#
#  注意：**不要用 `pkill -f qemu-system-aarch64`**
#        —— 外层 `su -c '...'` 的命令行里也含这个字符串，会把你自己那个
#           shell 一起杀掉。用短名 `qemu-system-aar` 匹配才安全。
# ============================================================================

echo "=== 停止 QEMU ==="
before=$(pgrep qemu-system-aar 2>/dev/null | wc -l)
echo "  当前进程数: $before"

pkill qemu-system-aar 2>/dev/null

for i in $(seq 1 15); do
    now=$(pgrep qemu-system-aar 2>/dev/null | wc -l)
    [ "$now" = "0" ] && break
    sleep 1
done

now=$(pgrep qemu-system-aar 2>/dev/null | wc -l)
if [ "$now" = "0" ]; then
    echo "  ✅ 已全部退出"
else
    echo "  ⚠️ 还有 $now 个没退（可能是卡在 I/O）。再等一轮..."
    sleep 3
    pkill -9 qemu-system-aar 2>/dev/null
    sleep 2
    echo "  剩余: $(pgrep qemu-system-aar 2>/dev/null | wc -l)"
fi

echo "--- 端口 5900 状态 ---"
netstat -tln 2>/dev/null | grep ":5900 " || echo "  5900 已释放 ✓"
