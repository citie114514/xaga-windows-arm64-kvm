# 开启 KVM —— 完整流程

[**中文**](../01-enable-kvm.md) | [English](../en/01-enable-kvm.md) | [日本語](../ja/01-enable-kvm.md) | [Русский](../ru/01-enable-kvm.md)

> 目标：让 Android 上出现 `/dev/kvm`，从而让 QEMU 用上硬件加速（而不是慢到无法使用的 TCG 软件模拟）。

**前提**：Bootloader 已解锁 + 已 Root（KernelSU/Magisk）+ PC 有 adb 和 Python 3.10+。
**形态**：只改 `tee_a`，`tee_b` 保持原厂（天然兜底）。

---

## 0. 先确认现状（只读，零风险）

```bash
# KVM 在不在
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'

# GZ 相关的节点（说明 EL2 被谁占着）
adb shell su -c 'ls -l /dev/gz* /dev/gunyah 2>&1'

# BL 解锁状态（0 = 已解锁）
adb shell getprop ro.boot.flash.locked

# 设备型号
adb shell getprop ro.product.device
```

预期结果（未打补丁时）：

| 检查 | 正常结果 |
|---|---|
| `/dev/kvm` | `No such file or directory` |
| `/proc/misc` | 46 项里**没有** `kvm` |
| `/dev/gz_kree` | 存在（char 10,99） |
| `/dev/gzvm` | 不存在 |
| `ro.boot.flash.locked` | `0` |

**说明**：MTK 的 **GenieZone(GZ)** 固件占着 EL2，所以 Linux 拿不到虚拟化扩展，内核就不暴露 `/dev/kvm`。
换掉 EL2 上的那段 ATF 是唯一出路。

---

## 1. 读取设备的 Secure Boot 状态（决定要不要签名）

preloader 会把自己的判定结果打进日志，落在 **`expdb`** 分区：

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M'
adb pull /data/local/tmp/expdb.img
# 在 PC 上找：
grep -a -o "sbc_en = [01]" expdb.img | sort | uniq -c
grep -a -o "img_auth_required = [0-9]" expdb.img | sort | uniq -c
grep -a -c "cert vfy" expdb.img
```

本机（Redmi Note 11T Pro+）实测：

```
    440  sbc_en = 1                      ← Secure Boot 开着
    220  [PART] img_auth_required = 1
     21  cert vfy(24 ms) / cert vfy(17 ms) / ...   ← 证书校验真的在跑
```

**为什么这个重要**：

- SBC 的值是从 **eFuse（OTP，一次性烧写）** 读出来的 —— 见下面这段 preloader 反汇编
- `sbc_en = 1` → **每个启动都会对 ATF 做证书链校验**
- → **改过的 ATF 必须过 MTK 签名**，这一步不能省

```asm
; preloader 里 SBC 的判定（这就是"改 preloader 没用"的原因）
0x020522FC  push   {r7, lr}
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; 读 eFuse
0x02052306  ubfx   r0, r0, #1, #1     ; SBC = bit 1
0x0205230A  pop    {r7, pc}
```

> **常见误区**：很多人以为刷了"工程 preloader"就能免签启动。
> 实际上工程 preloader 只让**写入**免授权（`usbdl_verify_da` 的返回值被直接丢弃），
> **启动时的镜像校验照跑**。两者的区别见 [appendix-atf-reverse.md](appendix-atf-reverse.md)。

---

## 2. 备份原厂分区（**绝对不能跳过**）

```bash
for p in tee_a tee_b lk_a lk_b preloader_raw_a seccfg; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/bk_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/bk_$p.img ./backup/$p.img
done

# 记下哈希，回滚时核对
cd backup && sha256sum *.img | tee SHA256SUMS.txt
```

本机原厂 `tee_a` 的 sha256（供对照）：

```
f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   tee_a.img  (5242880 字节)
```

**备份丢了就没法回滚了。** 一键脚本会在没备份成功时直接中止。

---

## 3. 从设备 dump 出料（保证哈希匹配）

补丁工具要求 **TEE / LK 配对必须与已分析的版本哈希完全匹配** ——
所以**直接从设备 dump**，不要到处找固件包：

```bash
for p in tee_a lk_a preloader_raw_a; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/dp_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/dp_$p.img ./dump/$p.img
done
```

---

## 4. 构建 + 签名

这一步用 [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)（NoGZ 补丁工具）
+ [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk)（签名工具）。

**详细的原理和步骤见 [02-build-and-sign.md](02-build-and-sign.md)**。这里只给最简命令：

```bash
# 环境
git clone https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
python -m venv .venv && .venv/bin/python -m pip install -r requirements.txt

# 构建（自动检测 new/legacy 签名模式并调用 pwnage）
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    ../dump/tee_a.img \
  --lk     ../dump/lk_a.img \
  --preloader ../dump/preloader_raw_a.img \
  --tools  ../pwnage24mtk \
  --out-dir ../outputs/run-01
```

产出关键文件：

```
outputs/run-01/
  tee_nogz_legacy.img     ← 签名成品（LEGACY 模式时）
  tee_nogz_new.img        ← （NEW_PARSER 模式时）
  verify.log  sign.log  cert-mode.txt  manifest.json
```

**必须看到两个 `Result: VALID`**，否则不要刷。

### 4.1 处理"签名后超出分区"的问题

签名会在 ATF **之后**插入 BIT STRING wrapper，让镜像比分区大一点：

```
unsigned : 5 242 880    (= 分区大小，刚好占满)
signed   : 5 243 952    (+1072 字节)
```

**关键**：插入点在 `atf` 之后，**尾部 1.75 MB 的零填充完全没变** →
**裁掉 1072 字节的尾部零填充即正好 5 MiB，零真实数据损失**。

一键脚本会自动做这件事，并且**先逐字节确认被裁部分全是 0x00 才动手**：

```bash
# 手工做法（确认超出部分全零后）
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
```

如果超出部分**含非零字节**，说明布局和你预期的不一样，**停下来人工分析，不要硬裁**。

---

## 5. 刷入

```bash
adb push tee_nogz_flash.img /data/local/tmp/
adb shell su -c 'sync'
adb shell su -c 'dd if=/data/local/tmp/tee_nogz_flash.img of=/dev/block/by-name/tee_a bs=4096'
adb shell su -c 'sync'

# 回读校验（必须和源文件哈希一致）
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

本机成功时的记录：

```
before : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   (原厂)
dd 5242880 bytes, 0.019 s, 263 M/s
after  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689   (补丁版)
```

> ⚠️ **不要用 SP Flash 深刷 tee** —— 深刷会把 BL 重新锁上，之后 fastboot 就不方便了。
> 用 `dd` 直写即可（BL 已解锁，`/dev/block/by-name/tee_a` 可写）。

### 回滚方法（留着备用）

```bash
adb push ./backup/tee_a.img /data/local/tmp/tee_stock.img
adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
adb reboot
```

还可以切到 **B 槽**（`tee_b` 未改动，天然兜底）。

---

## 6. 重启并验证

```bash
adb reboot
# 等开机
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

成功的标志：

```
crw-rw-rw- 1 root root u:object_r:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        ← /proc/misc 里出现了（之前 46 项里没有）
```

同时从 `expdb` 里应该能看到 ATF 通过了真机校验：

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
adb pull /data/local/tmp/e.img
grep -a "\[SBC\] image atf" e.img
# [SBC] image atf header auth pass      ← pwnage 的证书漏洞在本机成立
```

### 决定性验证：真跑一个 guest

用系统自带的 AVF `crosvm` 拉一个 microdroid 内核起来（最干净的验证，不依赖任何第三方 App）：

```bash
adb shell su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

guest 输出：

```
Booting Linux on physical CPU 0x0 [0x412fd050]        ← Cortex-A55
GICv3: CPU0: found redistributor 0 region 0:0x3ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x1 [0x411fd411]     ← Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

→ **ATF → EL2 → VHE → KVM → 2 vCPU Linux guest 完整启动，整条链路闭环。** ✅

---

## 7. 下一步

`/dev/kvm` 有了之后：

- **装 Windows 11 ARM64** → [03-windows-vm.md](03-windows-vm.md)
- **了解 QEMU 怎么用、怎么调** → [04-usage.md](04-usage.md)
- **遇到问题** → [05-gotchas.md](05-gotchas.md)

---

## 附：为什么 QEMU 还需要 `taskset` 绑核

MTK 的 big.LITTLE（4×A78 + 4×A55）上，QEMU 的 `-cpu host` 会枚举**当前所在 CPU** 的特性；
如果写 vCPU 寄存器期间被调度器在 A55/A78 之间迁移，就会：

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

实测（同一命令连跑 5 次）：

| 条件 | 成功率 |
|---|---|
| 不绑核 | **2/5** ✗ |
| `taskset 1`（cpu0，A55） | **3/3** ✓ |
| `taskset 80`（cpu7，A78） | **3/3** ✓ |
| `taskset f0`（cpu4-7，整个 A78 簇） | **3/3** ✓ |

**所以启动脚本里必须绑核**（本项目用 `taskset f0`，绑到快的 A78 簇）。
DroidVM 自己的 QEMU 后端没有这个参数选项，所以我们用 wrapper 包了一层 ——
见 [04-usage.md](04-usage.md)。
