# vendor_boot 软编回退补丁 —— 让 KVM 和编解码功能共存 ✅（已实机验证）

[**中文**](07-vendor-boot-swcodec.md)  （English / 日本語 / Русский 版待补）

> **状态变更记录**：
> - 初版方案 → 曾因实测崩溃被撤回（标注存疑/不推荐）
> - **2026-10-08 复测推翻撤回结论**：在与 NoGZ tee 的正确组合下**完整验证通过**——
>   KVM ✓ + 录屏 ✓ + 软编正常 ✓（详见下方实测数据与机理）
> - 当初的"无效"判断源于测量时设备组合混淆；本篇现为**最终验证版本**

> ⚠️ **前提**：本补丁**必须和 NoGZ tee 配套使用**（单独刷它配原厂 tee 会白白丢掉硬件解码，没意义）。

---

## ⚠️ 先分清三种组合

| 组合 | KVM | 编解码（录屏/串流/图片） | 说明 |
|---|---|---|---|
| 原厂 tee + 原厂 vendor_boot | ❌ | ✅ 硬编 | 正常日用（没 KVM）|
| **NoGZ tee + 原厂 vendor_boot** | ✅ | ❌ **失效** | 只有 KVM（gotcha #13 的裸组合）|
| **NoGZ tee + 改过 vendor_boot** | ✅ | ✅ **软编回退可用** | **两者兼得** ⭐（本方案，已验证）|

---

## 🧪 实测数据（2026-10-08，备用机 xagapro / Android 16 / OS3.0.301.4）

```
tee_a          = f1511dcad9820397 (NoGZ rk 补丁)     ← KVM 生效
vendor_boot_a  = 383f4cdc10dc72e9 (swcodec 补丁)     ← mtk 视频驱动解绑
/dev/kvm       = crw-rw-rw- 1 root root 10, 232      ✅ KVM 出现

screenrecord 8s = 1 884 858 字节                      ✅ 之前是 0 字节！
文件头         = ftyp mp42（完整 MP4）                ✅
编码器         = c2.android.avc.encoder（软编）       ✅ logcat 确认
media.swcodec  = RSS 12 MB 存活，crash buffer 无记录  ✅ 软编服务健康
c2.mtk.* 视频编解码器注册数 = 0                       ✅ 硬编已按预期解绑
```

**→ KVM 和编解码同时工作** ✓✓✓

> ⚠️ **性能代价仍在**：录屏/串流走软编，CPU 占用高于硬编——
> 1080p 没问题 ✓，4K 或高帧率可能卡顿 ✗，Moonlight 串流延迟比真硬编高。
> **功能可用性完全恢复**（录屏、QQ 图片、缩略图、相机录像）✓

---

## 🔬 精确机理

```
MTK 的 venc / vdec 在 open() 的时候：
   → 通过 IPI 向 VCP 协处理器查询【支持的帧尺寸】
   → 而 VCP 的 READY 握手依赖 EL2 / 安全世界那条链

把 Android 内核抬到 EL2（这是 KVM 的必需条件）之后：
   → 握手断裂 ✗
   → 硬件编解码器的帧尺寸表为空 ✗
   → Codec2 的 configure() 返回 EINVAL ✗
   → c2.mtk.* 视频编解码器全部失效 ✗
```

**解法**：改 `vendor_boot` 的 dtb 里 venc/vdec 的 **compatible 字符串**（同长度替换，只动 2 字节）：

```
mediatek,mt6895-vcodec-dec → mediatek,mt6895-vcodec-de0
mediatek,mt6895-vcodec-enc → mediatek,mt6895-vcodec-en0
```

**→ 驱动不绑定** → 不产生 `/dev/video*` → MTK C2 HAL 枚举不出 `c2.mtk.*` 视频编解码器
**→ 框架自动回退到软件编解码（c2.android.avc.encoder）** ✓ → 录屏 / QQ 图片 / 串流恢复 ✓

### 为什么"软编可用"这次成立，而之前结论是"软编也废"？

> **关键教训：不同批次的 ROM 不能互相外推结论。**

- 早期"软编也失效"（`libmedia.so` 缺符号 `MetaDataBase::writeToParcel`）的测量
  是在**主力机（pearl / Android 15 / AP3A 编译）**上做的
- 本次验证在**备用机（dali / Android 16 / OS3.0.301.4，2026-03 编译）**上：
  swcodec APEX 与 system 配套正常，软编服务健康运行
- **两台设备是不同的移植 ROM**——"第二层断裂"只在主力机那支 ROM 上成立，
  **不是普遍规律** ✗（文档此前把它当成了普适结论，是误推）

**结论**：
- 备用机（dali A16 ROM）：NoGZ + swcodec 补丁 = **全功能恢复** ✓（本篇）
- 主力机（pearl A15 ROM）：软编是否可用**未复测**——如果也想走这条路，
  先跑上面的验证命令确认 `media.swcodec` 存活与录屏输出

---

## 📦 成品下载

| 文件 | 说明 |
|---|---|
| [`vendor_boot_a_swcodec.img`](../vendor_boot_a_swcodec.img) | 改过的 vendor_boot（64 MiB，sha256 `383f4cdc…`）✅ 本机在用 |
| [`vendor_boot_a_orig.img`](../vendor_boot_a_orig.img) | 原始备份（回退用，sha256 `fed80580…`）|

**差异**：与原厂 `vendor_boot_a` 只差 **2 个字节**（两个 compatible 字符串各 1 字符）。

> ⚠️ 这份成品出自备用机（xagapro）的固件。**vendor_boot 的 dtb 与设备批次相关**——
> 不同批次（xaga vs xagapro，不同 OS 版本）不能直接刷，请按下面「自己制作」一节
> 用**你自己设备的 vendor_boot_a 备份**制作（一条 python 命令的事）。

---

## 📲 刷入方法

### ⚠️ 前提

- **已经刷了 NoGZ tee**（否则刷它没意义）
- BL 已解锁
- **备份了原厂 `vendor_boot_a`**（回退要用）

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

### 重启后验证

```bash
# KVM 还在
adb shell su -c 'ls -l /dev/kvm'

# 编解码恢复（录屏非 0 字节 = 软编回退成功）
adb shell screenrecord --time-limit 8 /data/local/tmp/test.mp4
adb shell ls -l /data/local/tmp/test.mp4    # > 0 字节 ✓

# 确认软编在工作、mtk 硬编已解绑
adb shell "logcat -d | grep 'c2.android.avc.encoder' | tail -2"   # 有 start = 在用
adb shell "dumpsys media.codec | grep -c 'c2.mtk.avc'"            # 0 = 硬编已解绑
```

> 注意：vendor_boot **不在** preloader 的 `[SBC]` 签名校验清单里（归 AVB 管，解锁后不拦）✓
> venc/vdec 节点在 **vendor_boot 的 dtb** 里，不在 dtbo 里（dtbo 改了要重新签名）✓

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

回退后：恢复「NoGZ tee + 原厂 vendor_boot」= KVM ✓ + 编解码失效 ✗（gotcha #13 裸组合）。
连 tee 一起回退原厂 = 完全的原始状态。

---

## 🔧 自己制作（强烈推荐——用你自己设备的 vendor_boot_a）

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
diff = sum(1 for a, b in zip(orig, new) if a != b)
print(f'差异字节数: {diff}')
assert diff == 2, '应该只改 2 字节'
open('vendor_boot_a_swcodec.img', 'wb').write(new)
```

> 💡 `dec` 替换后变成 `de0`，不会被 `enc` 的替换误伤 ✓
> ⚠️ 制作前先确认你设备的 dtb 里确实是这两个 compatible 字符串
> （`strings vendor_boot_a_orig.img | grep mt6895-vcodec`），
> 不同 OS 版本的 dtb 可能不同——字符串变了就按同样的"同长度替换"思路改。

---

## ⚠️ 注意事项

1. **必须和 NoGZ tee 配套** ✓ —— 单独刷它（配原厂 tee）会白白丢掉硬件解码 ✗
2. **软编性能低于硬编** ✗ —— 1080p 录屏/播放没问题 ✓，4K/高帧率可能卡 ✗
3. **AVB**：解锁 BL 后 vendor_boot 的校验失败不会阻止启动 ✓（orange 状态 ✓）
4. **Moonlight 等串流**：功能可用 ✓，但走软编延迟/功耗高于真硬编 ⚠️
5. **不同 ROM 批次的软编健康度不同**——刷完必须按上面的命令实测验证 ✗→✓
