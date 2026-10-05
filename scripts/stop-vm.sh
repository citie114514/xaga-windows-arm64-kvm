#!/system/bin/sh
# 安全停止 QEMU（用短进程名匹配，避免 pkill -f 匹配到自己的 shell）
pkill qemu-system-aar 2>/dev/null
sleep 2
n=\$(pgrep qemu-system-aar | wc -l)
echo "剩余 qemu 进程: \$n"
