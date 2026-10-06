# Enabling KVM — the complete process

**English** | [中文](../01-enable-kvm.md) | [日本語](../ja/01-enable-kvm.md) | [Русский](../ru/01-enable-kvm.md)

> Goal: make `/dev/kvm` appear on Android so QEMU can use hardware acceleration (instead of TCG
> software emulation, which is too slow to be usable).

**Prerequisites**: unlocked bootloader + root (KernelSU/Magisk) + adb and Python 3.10+ on the PC.
**Shape**: only `tee_a` is modified; `tee_b` stays stock (a built-in fallback).

---

## 0. Check the current state first (read-only, zero risk)

```bash
# Is KVM there?
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'

# GZ-related nodes (shows what is occupying EL2)
adb shell su -c 'ls -l /dev/gz* /dev/gunyah 2>&1'

# Bootloader lock state (0 = unlocked)
adb shell getprop ro.boot.flash.locked

# Device model
adb shell getprop ro.product.device
```

Expected results (before patching):

| Check | Normal result |
|---|---|
| `/dev/kvm` | `No such file or directory` |
| `/proc/misc` | **no** `kvm` among the 46 entries |
| `/dev/gz_kree` | exists (char 10,99) |
| `/dev/gzvm` | does not exist |
| `ro.boot.flash.locked` | `0` |

**Explanation**: MediaTek's **GenieZone (GZ)** firmware occupies EL2, so Linux cannot get the
virtualization extensions and the kernel therefore never exposes `/dev/kvm`.
Replacing the ATF that runs at EL2 is the only way out.

---

## 1. Read the device's Secure Boot state (decides whether signing is needed)

The preloader writes its verdict into the log, which lands in the **`expdb`** partition:

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M'
adb pull /data/local/tmp/expdb.img
# On the PC, look for:
grep -a -o "sbc_en = [01]" expdb.img | sort | uniq -c
grep -a -o "img_auth_required = [0-9]" expdb.img | sort | uniq -c
grep -a -c "cert vfy" expdb.img
```

Measured on this device (Redmi Note 11T Pro+):

```
    440  sbc_en = 1                      <- Secure Boot is on
    220  [PART] img_auth_required = 1
     21  cert vfy(24 ms) / cert vfy(17 ms) / ...   <- certificate verification really runs
```

**Why this matters**:

- The SBC value is read from **eFuse (OTP, written once)** — see the preloader disassembly below
- `sbc_en = 1` → **every boot verifies the ATF certificate chain**
- → **a modified ATF must be signed with MTK's signature**; this step cannot be skipped

```asm
; The SBC decision inside the preloader (this is why "modifying the preloader" doesn't help)
0x020522FC  push   {r7, lr}
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; read eFuse
0x02052306  ubfx   r0, r0, #1, #1     ; SBC = bit 1
0x0205230A  pop    {r7, pc}
```

> **Common misconception**: many people think flashing an "engineering preloader" allows unsigned
> booting. In reality an engineering preloader only makes **writing** unauthenticated (the return
> value of `usbdl_verify_da` is simply discarded); **image verification at boot still runs**.
> The difference is explained in [appendix-atf-reverse.md](appendix-atf-reverse.md).

---

## 2. Back up the stock partitions (**absolutely must not be skipped**)

```bash
for p in tee_a tee_b lk_a lk_b preloader_raw_a seccfg; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/bk_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/bk_$p.img ./backup/$p.img
done

# Record the hashes for rollback verification
cd backup && sha256sum *.img | tee SHA256SUMS.txt
```

The sha256 of this device's stock `tee_a` (for reference):

```
f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   tee_a.img  (5242880 bytes)
```

**If the backup is lost, there is no rollback.** The one-click script aborts unless the backup
succeeded.

---

## 3. Dump the material straight off the device (guarantees hash matching)

The patch tool requires that **the TEE / LK pair hash-matches an analysed version exactly** — so
**dump directly from the device** rather than hunting for firmware packages:

```bash
for p in tee_a lk_a preloader_raw_a; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/dp_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/dp_$p.img ./dump/$p.img
done
```

---

## 4. Build + sign

This step uses [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) (the NoGZ
patch tool) plus [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) (the signing tool).

**The full explanation and steps are in [02-build-and-sign.md](02-build-and-sign.md).** Here is the
minimal command:

```bash
# Environment
git clone https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
python -m venv .venv && .venv/bin/python -m pip install -r requirements.txt

# Build (auto-detects new/legacy signing mode and invokes pwnage)
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    ../dump/tee_a.img \
  --lk     ../dump/lk_a.img \
  --preloader ../dump/preloader_raw_a.img \
  --tools  ../pwnage24mtk \
  --out-dir ../outputs/run-01
```

Key outputs:

```
outputs/run-01/
  tee_nogz_legacy.img     <- signed result (in LEGACY mode)
  tee_nogz_new.img        <- (in NEW_PARSER mode)
  verify.log  sign.log  cert-mode.txt  manifest.json
```

**You must see two `Result: VALID` lines**, otherwise do not flash.

### 4.1 Handling "signed image larger than the partition"

Signing inserts a BIT STRING wrapper **after** the ATF, making the image slightly larger than the
partition:

```
unsigned : 5 242 880    (= partition size, exactly fills it)
signed   : 5 243 952    (+1072 bytes)
```

**The key point**: the insertion point is after the `atf` member, so the **tail 1.75 MB of zero
padding is completely unchanged** →
**trimming 1072 bytes of trailing zero padding yields exactly 5 MiB with zero real data loss**.

The one-click script does this automatically, and **verifies byte by byte that everything being
trimmed is 0x00 before touching anything**:

```bash
# Manual approach (after confirming the excess is all zeros)
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
```

If the excess **contains non-zero bytes**, the layout is not what you expect —
**stop and analyse it by hand; do not force a trim**.

---

## 5. Flashing

```bash
adb push tee_nogz_flash.img /data/local/tmp/
adb shell su -c 'sync'
adb shell su -c 'dd if=/data/local/tmp/tee_nogz_flash.img of=/dev/block/by-name/tee_a bs=4096'
adb shell su -c 'sync'

# Read back and verify (must match the source file's hash)
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

The record from a successful run on this device:

```
before : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   (stock)
dd 5242880 bytes, 0.019 s, 263 M/s
after  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689   (patched)
```

> ⚠️ **Do not use SP Flash Tool to flash `tee`** — a full flash re-locks the bootloader, after which
> fastboot becomes inconvenient. Writing with `dd` is enough (the bootloader is unlocked, so
> `/dev/block/by-name/tee_a` is writable).

### Rollback (keep this handy)

```bash
adb push ./backup/tee_a.img /data/local/tmp/tee_stock.img
adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
adb reboot
```

You can also switch to **slot B** (`tee_b` was never modified — a built-in fallback).

---

## 6. Reboot and verify

```bash
adb reboot
# wait for boot (the first boot takes about 2 minutes -- see gotcha 12)
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

Signs of success:

```
crw-rw-rw- 1 root root u:object_r:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        <- now present in /proc/misc (it wasn't among the 46 entries before)
```

At the same time, `expdb` should show that the ATF passed the on-device verification:

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
adb pull /data/local/tmp/e.img
grep -a "\[SBC\] image atf" e.img
# [SBC] image atf header auth pass      <- pwnage's certificate flaw holds on this device
```

### The decisive test: actually run a guest

Use the system's built-in AVF `crosvm` to boot a microdroid kernel (the cleanest verification,
depending on no third-party app):

```bash
adb shell su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

Guest output:

```
Booting Linux on physical CPU 0x0 [0x412fd050]        <- Cortex-A55
GICv3: CPU0: found redistributor 0 region 0:0x3ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x1 [0x411fd411]     <- Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

→ **ATF → EL2 → VHE → KVM → a 2-vCPU Linux guest boots fully; the whole chain is closed.** ✅

---

## 7. Next steps

With `/dev/kvm` in place:

- **Install Windows 11 ARM64** → [03-windows-vm.md](03-windows-vm.md)
- **Learn how to use and tune QEMU** → [04-usage.md](04-usage.md)
- **Hit a problem** → [05-gotchas.md](05-gotchas.md)

---

## Appendix: why QEMU still needs `taskset` CPU pinning

On MediaTek's big.LITTLE (4×A78 + 4×A55), QEMU's `-cpu host` enumerates the features of **the CPU it
happens to be running on**; if the scheduler migrates it between A55 and A78 while vCPU registers
are being written, you get:

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

Measured (same command run 5 times in a row):

| Condition | Success rate |
|---|---|
| No pinning | **2/5** ✗ |
| `taskset 1` (cpu0, A55) | **3/3** ✓ |
| `taskset 80` (cpu7, A78) | **3/3** ✓ |
| `taskset f0` (cpu4-7, the whole A78 cluster) | **3/3** ✓ |

**So the boot script must pin the CPU** (this project uses `taskset f0`, pinning to the fast A78
cluster). DroidVM's own QEMU backend has no option for this, which is why we wrapped it —
see [04-usage.md](04-usage.md).
