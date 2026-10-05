#!/system/bin/sh
TEE=/dev/block/by-name/tee_a
WANT=f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
STOCK=f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062

h() { sha256sum "$TEE" | cut -d' ' -f1; }

echo "=== BEFORE : $(h)"
dd if=/data/local/tmp/tee_nogz.img of="$TEE" bs=65536 conv=fsync 2>&1 || echo "!!! DD FAILED"
sync
sleep 1
A=$(h)
echo "=== AFTER  : $A"

if [ "$A" = "$WANT" ]; then
  echo "=== RESULT : OK —— tee_a 已是签名过的 NoGZ 版"
  exit 0
fi

echo "=== RESULT : MISMATCH —— 立即还原原厂 tee_a"
dd if=/data/local/tmp/tee_stock.img of="$TEE" bs=65536 conv=fsync 2>&1
sync
sleep 1
B=$(h)
echo "=== RESTORE: $B"
if [ "$B" = "$STOCK" ]; then echo "=== 已还原原厂，设备未受影响"; else echo "=== !!! 还原也异常，需手动处理"; fi
exit 1
