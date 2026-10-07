# vendor_boot 软编回退补丁 —— 让 KVM 和日用共存

[**中文**](07-vendor-boot-swcodec.md)  （English / 日本語 / Русский 版待补）

> 刷了 NoGZ tee 之后，硬件视频编解码会失效（[第 13 条](05-gotchas.md)）——
> Moonlight 无响应、录屏 0 字节、QQ 图片不显示。

> ⚠️⚠️⚠️ **此方案已标注为存疑/不推荐** ⚠️⚠️⚠️
> 实测发现：HAL 缺失导致**崩溃**而非退回软编 ✗，
> 且 venc/vdec 驱动**没有独立 /dev/video 节点**（MTK 不走 V4L2 /dev/video* ✗），
> 所以「改 compatible → 驱动不绑定 → 回退软编」的预期链条**断裂** ✗。
> **硬件编解码失效是结构性代价，目前没有不刷分区的绕过办法** ✗

> 以下内容保留供参考，**但不应作为可行方案使用** ✗

---

## ⚠️ 先分清三种组合

| 组合 | KVM | 硬件编解码 | 说明 |
|---|---|---|---|
| 原厂 tee + 原厂 vendor_boot | ❌ | ✅ | 正常日用（没 KVM）|
| NoGZ tee + 原厂 vendor_boot | ✅ | ❌ **失效** | 只有 KVM |
| **NoGZ tee + 改过 vendor_boot** | ✅ | ✅ **软编可用** | **两者兼得** ⭐ |

> ⚠️ **vendor_boot 补丁必须和 NoGZ tee 配套** ✓
> 单独刷它（配原厂 tee）会白白丢掉硬件解码 ✗ —— 没必要

---

## 🧪 实测数据

设备：备用机 `IBAYUOMJ9LHQFI4D`（Android 16，xagapro）

```
tee_a          = f1511dcad9820397 (NoGZ rk 补丁)
vendor_boot_a  = 383f4cdc10dc72e9 (swcodec 补丁)

/dev/kvm       = crw-rw-rw- 1 root root 10, 232  ✅ KVM 出现
screenrecord   = 266,386 字节                    ✅ 之前是 0 字节！
文件头         = ftyp mp42（完整 MP4）            ✅
TEE 服务       = teei_daemon + beanpod 正常      ✅
应用包数       = 379 个完好                      ✅
```

**→ KVM 和录屏同时工作** ✓✓✓

---

## 🔬 精确机理

```
MTK 的 venc / vdec 在 open() 的时候：
   → 通过 IPI 向 VCP 协处理器查询【支持的帧尺寸】
   → 而 VCP 的 READY 握手依赖 EL2 / 安全世界那条链

把 Android 内核抬到 EL2（这是 KVM 的必需条件）之后：
   → 握手断裂 ✗
   → 尺寸表为空 ✗
   → Codec2 的 configure() 返回 EINVAL ✗
   → 框架 / 应用【不会自动回退到软件编码】✗
   → 结果：screenrecord 录出来是 0 字节、
           Moonlight / UU远程 / QQ 图片 全部失效 ✗
```

**解法**：改 `vendor_boot` 的 dtb 里 venc/vdec 的 **compatible 字符串**（同长度替换，只动 2 字节）：

```
mediatek,mt6895-vcodec-dec → mediatek,mt6895-vcodec-de0
mediatek,mt6895-vcodec-enc → mediatek,mt6895-vcodec-en0
```

**→ 驱动不绑定** → 不产生 `/dev/video*` → MTK C2 HAL 注册不出 `c2.mtk.*` 视频编解码器
**→ 框架自动回退到软件编码/解码** ✓ → 录屏 / QQ 图片 / UU远程 恢复 ✓

**为什么有效而改 media_codecs_c2.xml 无效**：
编解码器清单由 MTK 自己的 C2 HAL（`libcodec2_mtk_venc.so` / `libcodec2_mtk_vdec.so`）
**运行时枚举**，不是从 XML 读的 ✗ —— 所以改 XML 没用 ✗。
只有让驱动不绑定（compatible 不匹配）才能让 HAL 枚举不出硬件编解码器 ✓。

**为什么改 vendor_boot 而不是 dtbo**：
- vcp / venc / vdec 节点在 **vendor_boot 的 dtb** 里，不在 dtbo 里 ✗
- dtbo 在 preloader 的 `[SBC]` 签名校验清单里 ✗（改了要重新签名）
- vendor_boot **不在**清单里（归 AVB 管，解锁后不拦）✓

---

## 📦 成品下载

| 文件 | 说明 |
|---|---|
| [`vendor_boot_a_swcodec.img`](../vendor_boot_a_swcodec.img) | 改过的 vendor_boot（64 MiB）|
| [`vendor_boot_a_orig.img`](../vendor_boot_a_orig.img) | 原始备份（回退用）|

**差异**：与原厂 `vendor_boot_a` 只差 **2 个字节**（两个 compatible 字符串各 1 字符）。

---

## 📲 刷入方法

### ⚠️ 前提

- **已经刷了 NoGZ tee**（否则刷这个没意义 ✗）
- BL 已解锁
- 备份了原厂 `vendor_boot_a`（可以用 `vendor_boot_a_orig.img`）

### 刷入

```bash
# 方式一：fastboot（推荐，快）
adb reboot bootloader
fastboot flash vendor_boot vendor_boot_a_swcodec.img
fastboot reboot

# 方式二：dd
adb push vendor_boot_a_swcodec.img /data/local/tmp/vb_sw.img
adb shell su -c 'dd if=/data/local/tmp/vb_sw.img of=/dev/block/by-name/vendor_boot_a bs=4096 && sync'
adb reboot
```

### 重启后

```bash
# 验证 KVM
adb shell su -c 'ls -l /dev/kvm'

# ⚠️ 等 3 分钟（第二屏卡 1~2 分钟是正常的）

# 验证录屏
adb shell screenrecord --time-limit 5 /data/local/tmp/test.mp4
adb shell su -c 'ls -l /data/local/tmp/test.mp4'
# > 0 字节 = 软编回退成功 ✓
```

---

## 🔙 回退

```bash
# fastboot
adb reboot bootloader
fastboot flash vendor_boot vendor_boot_a_orig.img
fastboot reboot

# dd
adb push vendor_boot_a_orig.img /data/local/tmp/vb_orig.img
adb shell su -c 'dd if=/data/local/tmp/vb_orig.img of=/dev/block/by-name/vendor_boot_a bs=4096 && sync'
adb reboot
```

**或者连 vendor_boot 和 tee 一起回退**（把原厂 tee_a 也刷回去 ✓ 就是完全的原始状态 ✓）。

---

## 🔧 自己制作（如果不想用现成的）

```python
# make_vb_swcodec.py —— 同长度替换 compatible 字符串
orig = open('vendor_boot_a_orig.img', 'rb').read()
new = orig.replace(
    b'mediatek,mt6895-vcodec-dec\x00',
    b'mediatek,mt6895-vcodec-de0\x00',
).replace(
    b'mediatek,mt6895-vcodec-enc\x00',
    b'mediatek,mt6895-vcodec-en0\x00',
)
assert len(new) == len(orig), '长度必须一致'
newer = new.replace(
    b'mediatek,mt6895-vcodec-enc\x00',
    b'mediatek,mt6895-vcodec-en0\x00',
)  # enc 在 dec 后面出现，要分开替换
diff = sum(1 for a, b in zip(orig, newer) if a != b)
print(f'差异字节数: {diff}')   # 应该是 2
assert diff == 2, '应该只改 2 字节'
open('vendor_boot_a_swcodec.img', 'wb').write(newer)
```

> 💡 `dec` 和 `enc` 是不同的字符串，分开替换即可 ✓
> （`dec` 替换后变成 `de0`，不会再被 `enc` 的替换误伤 ✓）

---

## ⚠️ 注意事项

1. **必须和 NoGZ tee 配套** ✓ —— 单独刷它（配原厂 tee）会白白丢掉硬件解码 ✗
2. **Moonlight 的性能会打折** ✗ —— 软编解码比硬件慢，
   但至少**功能可用** ✓（比"直接无响应"强 ✓）
3. **AVB**：解锁 BL 后 vendor_boot 的校验失败不会阻止启动 ✓（orange 状态 ✓）
4. **软编解码的 CPU 占用更高** ✗ —— 4K 视频可能会卡 ✗ 1080p 没问题 ✓
