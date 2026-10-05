#!/bin/bash
# 断点续传下载 + 完整性校验（代理会中途掐断，所以循环续传直到拿全）
PX="http://127.0.0.1:10808"
URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"
OUT="${1:-/c/Users/citie/xaga-kvm/virtio-win.iso}"

echo "=== 1) 探测服务端总大小（HEAD）==="
TOTAL=$(curl -sIL --ssl-no-revoke -x "$PX" --max-time 60 "$URL" \
        | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
echo "Content-Length = ${TOTAL:-未知}"

prev=0
for i in $(seq 1 80); do
  have=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
  if [ -n "$TOTAL" ] && [ "$have" -ge "$TOTAL" ]; then
    echo ">>> 已完整：$have / $TOTAL"; break
  fi
  echo "--- 第 $i 次续传：已有 $have 字节 ---"
  curl -sL --ssl-no-revoke -x "$PX" -C - -o "$OUT" "$URL" \
       --retry 3 --retry-delay 2 --retry-all-errors \
       --max-time 300 --speed-time 30 --speed-limit 1024 2>&1 | tail -2
  now=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
  echo "    续传后 = $now"
  if [ "$now" -le "$prev" ] && [ "$prev" -gt 0 ]; then
    echo "    !!! 无进展，改用 -C - 的替代方案：重新设置 Range 重试"
  fi
  prev=$now
  [ -n "$TOTAL" ] && [ "$now" -ge "$TOTAL" ] && break
  sleep 1
done

echo
echo "=== 2) 校验 ISO 卷大小 ==="
python - "$OUT" <<'PY'
import struct,os,sys
p=sys.argv[1]; sz=os.path.getsize(p)
f=open(p,'rb'); f.seek(16*2048); pvd=f.read(2048)
vol=struct.unpack('<I',pvd[80:84])[0]*2048
print('文件大小   =', sz)
print('ISO 声明卷 =', vol)
print('结果       =', '完整 ✓' if sz>=vol else '仍不完整 ✗ 还缺 %d 字节' % (vol-sz))
PY
