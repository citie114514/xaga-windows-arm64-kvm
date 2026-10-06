#!/system/bin/sh
# ============================================================================
#  把备份的虚拟磁盘放回 DroidVM 目录
#
#  用法:  su -c sh /data/local/tmp/restore-disk.sh <你的镜像文件>
#
#  例:    adb push win.vhdx /data/local/tmp/
#         adb shell su -c 'sh /data/local/tmp/restore-disk.sh /data/local/tmp/win.vhdx'
#
#  目标位置固定为 /data/media/0/DroidVM/win.vhdx
#  （DroidVM 的 vms.json 里就是读这个路径；用原生路径可绕过 FUSE，快很多）
# ============================================================================

SRC="$1"
DST_DIR=/data/media/0/DroidVM
DST="$DST_DIR/win.vhdx"

if [ -z "$SRC" ]; then
    echo "用法: sh $0 <你的镜像文件.vhdx>"
    echo
    echo "当前 DroidVM 目录:"
    ls -lh "$DST_DIR" 2>/dev/null || echo "  (不存在)"
    exit 1
fi

[ -f "$SRC" ] || { echo "❌ 找不到源文件: $SRC"; exit 1; }

echo "=== 1) 识别镜像格式 ==="
MAGIC=$(dd if="$SRC" bs=1 count=8 2>/dev/null | tr -d '\0')
SZ=$(stat -c %s "$SRC" 2>/dev/null)
echo "  文件: $SRC"
echo "  大小: $(echo "$SZ" | awk '{printf "%.2f GiB", $1/1073741824}')"
echo "  头 8 字节: $MAGIC"

case "$MAGIC" in
    vhdxfile*) FMT=vhdx; echo "  ✅ 识别为 VHDX" ;;
    QFI*)      FMT=qcow2; echo "  ⚠️ 识别为 QCOW2 —— boot-win.sh 里要改成 format=qcow2" ;;
    *)         FMT=unknown; echo "  ⚠️ 无法识别格式（VHD 的标志在尾部）。按 VHDX 处理。" ;;
esac

echo
echo "=== 2) 检查空间 ==="
DF=$(df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
NEED=$((SZ / 1024))
echo "  /data 可用: $(echo "$DF" | awk '{printf "%.1f GiB", $1/1048576}')"
echo "  需要:       $(echo "$NEED" | awk '{printf "%.1f GiB", $1/1048576}')"
if [ "$DF" -lt "$NEED" ]; then
    echo "  ❌ 空间不够"
    exit 1
fi
echo "  ✅ 空间足够"

echo
echo "=== 3) 确认覆盖 ==="
if [ -f "$DST" ]; then
    echo "  ⚠️ 目标已存在，将被覆盖:"
    ls -lh "$DST"
    echo "  （3 秒后继续，Ctrl-C 可取消）"
    sleep 3
fi

echo
echo "=== 4) 复制 ==="
mkdir -p "$DST_DIR"
# 同分区内用 mv 最快；跨分区才真正复制
case "$SRC" in
    /data/local/tmp/*)
        echo "  移动 $SRC → $DST"
        mv -f "$SRC" "$DST" || cp -f "$SRC" "$DST"
        ;;
    *)
        echo "  复制 $SRC → $DST"
        cp -f "$SRC" "$DST"
        ;;
esac
sync

echo
echo "=== 5) 校验 ==="
if [ -f "$DST" ]; then
    S1=$(sha256sum "$SRC" 2>/dev/null | awk '{print $1}')
    S2=$(sha256sum "$DST" 2>/dev/null | awk '{print $1}')
    ls -lh "$DST"
    if [ -n "$S2" ] && [ "$S1" = "$S2" ]; then
        echo "  ✅ sha256 一致: ${S2%${S2#????????????????}}…"
    elif [ -n "$S1" ]; then
        echo "  ⚠️ 源已被移动，无法比对（如果上面用了 mv，这是正常的）"
    fi
    echo
    echo "现在可以启动:"
    echo "  su -c sh /data/local/tmp/boot-win.sh"
else
    echo "  ❌ 复制失败"
    exit 1
fi
