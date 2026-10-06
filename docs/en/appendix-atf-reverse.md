# preloader_raw_a.img — reverse-engineering conclusions

**English** | [中文](../appendix-atf-reverse.md) | [日本語](../ja/appendix-atf-reverse.md) | [Русский](../ru/appendix-atf-reverse.md)

File: `D:\Administrator\下载\preloader_raw_a.img`
Size: 4 190 208 bytes (0x3FF000)
sha256: `056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1`

## 0. The most important conclusion (stated first)

**This file is byte-for-byte identical to the preloader the phone is currently running.**
(The sha256 of the `preloader_raw_a` partition dumped from the device is also `056ed47a…`)

→ Flashing it **would change nothing**. If it really were a "no-auth engineering build", then this
device **is already running it right now.**

## 1. Container structure

```
0x0000  MMM\x01  len=0x38  "FILE_INFO"
0x0038  MMM\x01  len=0x0C  type=1  val=1
0x0044  MMM\x01  len=0x64  type=7  val=0x90
0x00A8  MMM\x01  len=0x14  type=2  val=0
0x00BC  MMM\x01  len=0x30  type=8  val=0
0x00F0  <- code starts here
```
Header fields (`parse_hdr`):
```
load = 0x02000F10   size = 0x0007A0B0   header = 0xF0   ida = 0xF0
runtime base = 0x02001000, code 0xF0 .. 0x7A1A0
the 0x384E60 bytes after the image are all 0x00 padding
```

## 2. Where SBC (Secure Boot Control) comes from — decisive evidence

```
0x020522FC  push   {r7, lr}
0x020522FE  mov    r7, sp
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; read efuse
0x02052306  ubfx   r0, r0, #1, #1     ; take bit 1
0x0205230A  pop    {r7, pc}
```

**SBC is read from eFuse at runtime** (bit 1 of word 0x1F). eFuse is OTP, written once —
**changing the preloader cannot change it**.

## 3. The verification logic is "conditionally executed", not "bypassed"

The caller (0x0204FA0E):
```
0x0204FA14  bl     #0x020522FC        ; r0 = sbc_en
0x0204FA18  mov    r1, r0
0x0204FA1A  movw   r0, #0x7528        ; "sbc_en = %d"
0x0204FA22  bl     #0x02045C74        ; print sbc_en
0x0204FA26  bl     #0x020522FC        ; read it again
0x0204FA2A  cbz    r0, #0x0204FA5C    ; sbc_en == 0 -> skip verification entirely
0x0204FA2C  movw   r0, #0x7535        ; "sbc_en = 1"
0x0204FA34  bl     #0x02045C74        ; print
...                                    ; continue into the certificate-chain verification
```

This is **normal retail logic**: devices without SBC fused skip verification, devices with it fused
verify. There is no hardcoded bypass like `movs r0,#0` / `bx lr`.

## 4. The certificate chain / image verification code is fully present

```
0x020407F0  ...  main img_auth logic
   0x0204083C  ldr r0, [pc,#...]  -> "img_auth_required = %x"
   0x020408D2  ->                  "cert chain vfy fail..."
   0x020408F0  bl #0x0200E368     ; the real verification entry (returns 0 = pass)
   0x0204086E  mov.w r8, #-1      ; failure return value

0x0204E888  img auth fail path -> "img auth fail(0x%x)"
0x0204FE22  0x020676AD -> "seclib_img_auth_load_sig"
```
The image also contains MTK's certificate OIDs and algorithms:
```
2.16.886.2454.1.1 / .1.2 / .1.3 / .2.1 ... .3.2   ; 2.16.886 = TW, 2454 = MediaTek
1.2.840.113549.1.1.1   ; rsaEncryption
1.2.840.113549.1.1.10  ; RSASSA-PSS
V.Mon May 30 17:26:17 2022   ; certificate store version string
```

## 5. DA verification (usbdl_verify_da) is also complete, with no short circuit

Function `0x0201144C` contains:
- a DA length check (the `da_len < sig_len` error print)
- a jump-table dispatch on the DA type byte (`sub.w r1, r0, #0xC4; cmp r1, #0x23; tbh [pc, r1, lsl #1]`)
- a special `0xFE` branch
- failure returns such as `#-1`

**There is no "return success immediately" short-circuit branch.**

## 6. Build provenance

Source paths in the strings:
```
/home/work/mnt/miui_codes2/build_home_rom-vext-merged/vendor/mediatek/
  proprietary/bootable/bootloader/preloader/platform/mt6895/src/...
```
Build timestamp: `20230918-112001` (2023-09-18 11:20:01)

→ This is a **retail build from Xiaomi's MIUI build farm**. MTK's own factory engineering builds come
from MTK-internal build servers and have a different path shape.

---

## Summary: what static analysis can and cannot answer

| Question | Can static analysis answer? | Conclusion |
|---|---|---|
| Is this a retail preloader? | ✅ yes | Yes (Xiaomi build farm + SBC read dynamically from efuse) |
| Is there a hardcoded verification disable in the code? | ✅ yes | **No** — verification is conditionally executed |
| Were the verification functions deleted/stubbed? | ✅ yes | **No** — the whole set is present |
| **Is verification actually enabled on this device?** | ❌ **no** | Determined by eFuse word 0x1F bit 1; must be measured |

## The decisive zero-risk (read-only) measurement

The preloader prints its own verdict:

```
0x0204FA1A  "sbc_en = %d"      -> the log contains "sbc_en = 0" or "sbc_en = 1"
```

And the preloader's log lands in the **`expdb` partition** (128 MiB on this device).

```bash
adb shell su -c "dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M"
adb pull /data/local/tmp/expdb.img
grep -a -o "sbc_en = [01]" expdb.img
```

You can also read `seccfg` (MTK's lock-state partition, corresponding to the image's
`[SEC_POLICY] lock_state = 0x%x` print) to confirm `lock_state`.

## Note: flashing `tee` does not actually depend on "no-auth"

- The bootloader is unlocked (`ro.boot.flash.locked=0`) → **fastboot can write `tee_a` directly**
- But **the preloader verifies the ATF signature when booting ATF** (if SBC is on)
- So what really decides whether a modified `tee` can boot is still **the SBC bit in eFuse**

---

# On-device verification results (2026-10-05, read-only)

## A. Secure Boot on this device is **ON** (measured, not assumed)

Raw text read directly from `expdb` (the preloader boot-log partition, 128 MiB):

```
   440  sbc_en = 1                  <- the SBC value the preloader computed itself
   220  [PART] img_auth_required = 1
     5  img_auth_required = 0
    21  [SEC_POLICY] lock_state = 0x3
    21  cert vfy(24 ms)  / cert vfy(17 ms) / ...   <- certificate verification really ran and passed
    12  part: lk_a img: aee
    10  part: lk_a img: bl2_ext
    10  part: gz_a img: unmap2
    10  part: gz_a img: gz
```

Matching the raw data of the `seccfg` partition exactly:

```
00000000: 4d4d4d4d 04000000 3c000000 03000000   MMMM....<.......
00000010: 00000000 00000000 45454545 b4c9b88a
00000020: 255a1745 17c0c5f6 85315e9e c48e00f7
00000030: c8965b9d a1ed3100 cf79a983 00000000
                    ^ 0x0C = 0x03  <- matches lock_state = 0x3 in the log
         offset 0x18..0x38 is the 32-byte seccfg hash
```

**Inference**: since `sbc_en = 1` and `img_auth_required = 1`, a modified ATF
**must pass MTK's certificate verification** to boot →
**pwnage signing (LEGACY mode) is a mandatory step that cannot be skipped.**

## B. DroidVM's GenieZone route is not viable on this device

```
/dev/gunyah   -> does not exist
/dev/kvm      -> does not exist (EL2 held by GZ)
/dev/gz_kree  -> exists (char 10,99)  <- GZ's KRE service interface
/dev/gzvm     -> does not exist       <- the VM interface crosvm/DroidVM needs
```

`VMHypervisor.GENIEZONE` looks for exactly `/dev/gzvm`. This device only has the older-generation GZ,
and in `isBackendSupported` QEMU does not support GENIEZONE (only crosvm does).
→ **DroidVM can only use the KVM backend, which means `tee` must be flashed.**

## C. The preloader you provided is of no help

It equals the version the device is currently running (byte-identical), and its SBC decision reads eFuse:

```asm
0x020522FC  movs r0, #0x1F          ; efuse word 31
0x02052302  bl   #0x02054860        ; read efuse
0x02052306  ubfx r0, r0, #1, #1     ; SBC = bit 1
```

So it **will not** skip verification. What "boot without verification" would need is a different
preloader that has been manually modified to not read eFuse.

## D. One thing still not fully pinned down (stated honestly)

The preloader's explicit verification log only names `lk_a` (aee/bl2_ext) and `gz_a` (gz/unmap2);
**`tee_a`/`atf` do not appear directly**. But `bl2_ext` internally contains strings such as
`[BL31] load failed` + `atf` + `vm-BL31-reserved`, indicating that ATF loading happens during the
`bl2_ext` stage. Who exactly verifies ATF, and whether it is verified, was not isolated in this round.

→ Under the premise `sbc_en=1`, **treating it as "will be verified" is the safe assumption.**

## E. Cross-check: these logs really come from this preloader

Only **one** preloader build stamp appears in expdb:

```
  10  Build Time: 20230918-112001
  10  20230918-112001          (no other version's build stamp at all)
```

And the build stamp embedded in the current image is also `20230918-112001`
→ Those `sbc_en = 1` / `cert vfy(24 ms)` logs are **not residue from an older version**; they were
printed by this very engineering preloader.

## F. Where the engineering preloader is "engineering": the DA/EDL path

`usbdl_verify_da` (0x0201144C) has **exactly one call site** in the whole image: 0x02032B86.

```asm
0x02032B68  ldrb.w  r0, [r8]        ; the received byte
0x02032B6C  cmp     r0, #0xA0       ; only 0xA0 counts as a DA
0x02032B6E  bne     #0x2032B96
...
0x02032B80  add     r0, sp, #0x1c
0x02032B82  mov.w   r1, #0x12c
0x02032B86  bl      #0x201144C      ; usbdl_verify_da(buf, 0x12c)
0x02032B8A  mov     r0, r4          ; <- uses r4 directly, with NO cmp r0 / bne
0x02032B8C  mov     r1, r5
0x02032B8E  mov     r2, fp
0x02032B90  bl      #0x2045C74      ; log
0x02032B94  b       #0x2032B30      ; back to the main loop
```

**The return value is discarded outright, and the call site makes no decision at all.**
(If a forced bypass exists, it can only be inside the function — where there is one suspicious failure
branch, `bl #0x2045BA8(1)`, which this round did not fully rule out.)

## G. Final judgement

| Question | Answer |
|---|---|
| Does the engineering preloader disable **image verification at boot**? | **No** (SBC still reads eFuse, the measured value is 1, and certificate verification really executes) |
| Might it disable **EDL/DA authorisation**? | **Very likely** (`usbdl_verify_da`'s return value is unchecked) |
| So does flashing a modified `tee` still require signing? | **Yes.** No-auth flashing ≠ verification-free booting |

**Zero-risk way to test "no-auth"**: enter EDL and use an unsigned DA to do a **read-only** operation
(e.g. `mtkclient r seccfg`) and see whether it demands an `.auth` file.

**The most direct way to see "what was changed"**: binary-diff a stock xagapro preloader against this
image.

---

# Final conclusions (2026-10-05, on-device logs + static reverse engineering)

## H. The complete two-stage verification chain (zero failures throughout)

### Stage one: preloader verification
Log: `part: %s img: %s cert vfy(%d ms)` / `[PART] img_auth_required = %x`

```
 12  part: lk_a img: aee
 10  part: lk_a img: bl2_ext
 10  part: gz_a img: unmap2
 10  part: gz_a img: gz
 21  cert vfy(17..30 ms)
```

### Stage two: the `[SBC]` subsystem verification inside `bl2_ext` (extended BL2)

```
[SBC] image <X> header auth pass    +    [SBC] <X> cert chain vfy pass
```

The complete list:
```
dtbo(21) lk_main_dtb(16) logo(12) tinysys-sspm(11) tinysys-mcupm-RV33_A(11)
spmfw(11) pi_img(6) dpmpt(6) tinysys-vcp-RV55_A(5) tinysys-scp-RV55_A(5)
tinysys-gpueb-RV33_A(5) tinysys-apusys-RV33_A(5) **tee(5)** mvpu_algo(5)
md1rom(5) md1dsp(5) **lk(5)** hifi3_a/b_{sram,iram,dram}(5) dpmpm(5)
dpmdm(5) ccu(5) **atf(5)**
```

**Zero `auth fail` / `vfy fail`.**

## I. Decisive conclusions

| Fact | Evidence |
|---|---|
| ATF is verified on every boot | `[SBC] image atf header auth pass` ×5 |
| The verification switch is determined by eFuse and equals 1 | `sbc_en = 1` ×440, no counter-example |
| Verification really executes (not dead code) | `cert vfy(17..30 ms)` ×21 |
| **A modified ATF must pass MTK signing** | the three above |
| **No-auth flashing can write it in** | `usbdl_verify_da`'s return value is unchecked (see §F) |
| If it goes wrong it can be rescued | via **preloader mode** (not BROM), no auth required |
| Why the kernel can be swapped | `boot`/`vendor_boot` are **not** in the `[SBC]` list (AVB governs them, and it doesn't block after unlocking) |

→ **pwnage signing (LEGACY mode) is a mandatory step and cannot be skipped.**

## J. Where ATF is actually loaded

```
Load 'tee_a' partition to 0x0xffff000048200000 (283016...)
Load 'tee_a' partition to 0x0xffff00006ffffdc0 (3200000...)
```

`0x48200000` = the mblock-15-BL31-reserved base; 283016 = the size of the `atf` member.
The second is the `tee` member (3 200 000 bytes = TEE OS).
→ The ATF that runs is the `atf` member inside `tee_a`, which is exactly what the NoGZ patch modifies.

---

# Signing complete (2026-10-05)

## Tools

`kasnria001/pwnage24mtk` (public):
- Principle: a flaw in MTK's ASN.1 certificate parsing (same class as CVE-2023-20696 / fixed in CVE-2025-20730)
- Older devices use `bypass_mode 1` (= the `LEGACY` / `enter-value traversal, arg4=1` this device detected)
  The approach: wrap the **original, unmodified CERT2 DER** as a fake `BIT STRING` object in front,
  and put the real cert behind it carrying the updated image hash / image hdr hash
- Standard library only, no extra dependencies

Commands:
```bash
python sign_mtk_cert.py <unsigned.img> --legacy -w -o <out.img>
python verify_mtk_image.py --all <out.img>      # requires 2 × Result: VALID
```

## Key trap: the signed image is 1072 bytes larger than the partition

```
unsigned : 5 242 880   (= tee partition size, exactly fills it)
signed   : 5 243 952   (+1072)
```

The increase comes from the BIT STRING wrapper (987 B) plus CERT2 dsize going 982→2059 (aligned to 2064).

**But the insertion point is after ATF, so the trailing zero padding is completely unchanged:**

| Member | unsigned | signed |
|---|---|---|
| `atf` | 0x200 | 0x200 |
| `tee` | 0x46440 | 0x46870 (+1072) |
| `cert1` | 0x353a40 | 0x353e70 (+1072) |
| `cert2` | 0x354310 | 0x354740 (+1072) |
| trailing zero padding | 1 751 322 | **1 751 322 (unchanged)** |

There are 1.75 MB of zeros at the tail → **trimming 1072 bytes of zero padding yields exactly 5 MiB with
zero real data loss.** (Verified that everything trimmed is 0x00.)

## Artefact

```
file   : sign-test/tee_nogz_legacy_5M.img
size   : 5 242 880  (= tee partition)
sha256 : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```

| Check | Result |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`** (ATF group + TEE group) |
| CERT1 / CERT2 signature | OK |
| Image header hash / Image data hash | OK |
| Whether the `tee` member was modified | **not modified** ✓ |
| ATF vs. re-patching result | **byte-identical** ✓ |
| The official 14-item regression | **14/14 passed** ✓ |

**Unverified item (stated honestly)**: `Trusted root check: skipped`
→ Comparing this certificate chain against the device's eFuse trust root **was not verified offline**;
only a real boot proves it.

## A bug in the upstream repository (for feedback)

`scripts/build.py:340` calls `sign_all_flag(args.tools)`, but **that function is not defined anywhere
in the file** → the signing path necessarily raises `NameError`. `--check-only` returns early, so it
never surfaced.
(Also: `sign_mtk_cert.py` itself has no `--all` argument, so that function should return `[]`.)

---

# Corroboration from a community tutorial (Coolapk: "MTK SPFlash V6 usage tutorial for xaga/pearl")

Key quotes from the tutorial:

> Because the engineering **Preloader exposes an insecure VCOM port and disables SLA (serial link
> authentication) and DAA (download agent authentication) checks**, allowing tools to flash the device
> without authorisation from a Xiaomi after-sales account

> Recently there is good news: the **xaga engineering preloader boot file was leaked**. What is that
> good for? The answer is **free brick recovery** … it can avoid certain hard bricks, letting you
> rescue it yourself without paying

## Three independent pieces of evidence that fit together perfectly

| What the tutorial says | The corresponding evidence in this image |
|---|---|
| **DAA** (download agent authentication) is disabled | `usbdl_verify_da`'s **return value is discarded outright** (§F) |
| An insecure **VCOM port** is exposed | the image contains the string `USB CDC ACM for preloader` |
| It only makes flashing possible; it does not disable verification | `sbc_en` is read from eFuse, measured = 1, `[SBC] image atf header auth pass` (§E/§H) |

→ **Engineering preloader = makes "writing" unauthenticated (+ rescues bricks), and does not touch
"whether verification happens at boot" at all.** Consistent with §G/§I here, no conflict.

## Two useful points from the tutorial

1. **A full SP Flash write re-locks the bootloader**
   > After a deep flash the bootloader is locked, though the second time it can be opened instantly
   > (some people say not flashing the seccfg partition keeps the bootloader unlocked, but the tool doesn't flash that partition)
   → **Do not use SP Flash to flash `tee`**, otherwise the bootloader gets re-locked and fastboot becomes inconvenient.

2. Flashing an engineering preloader goes through **fastboot**:
   ```
   fastboot flash preloader1 preloader_xaga.bin
   fastboot flash preloader2 preloader_xaga.bin
   fastboot reboot
   ```
   (On this device the by-name partitions are `preloader_raw_a` / `preloader_raw_b`)

3. Materials needed for the recovery chain (the package @rkpsz shared in the tutorial):
   `SP_Flash_Tool_v6.2316_Win.zip` + `auth_sv5.auth` + `libusb_v1.12.exe` +
   a MediaTek driver .exe + `preloader_xaga.bin` + the flash package `flash.xml`

---

# ✅ Confirmed on real hardware (2026-10-05 22:00)

## Flashing

```
tee_a BEFORE : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
dd 5242880 bytes, 0.019 s, 263 M/s
tee_a AFTER  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```
The read-back hash == the artefact hash → the write really took effect.

## After reboot: ATF passes the on-device SBC check

```
[SBC] image atf header auth pass   ×3
```
→ pwnage's certificate flaw holds on this device, and the signed ATF is accepted.

## KVM is up

```
crw-rw-rw- 1 root root u:objectr:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        <- present in /proc/misc (before flashing, kvm wasn't among the 46 entries)
head -c 1 /dev/kvm -> Invalid argument
                     ^ not Permission denied -> open() passed SELinux (Enforcing)
```

## Actually running a Linux VM (decisive evidence)

Using the device's built-in AVF crosvm + microdroid kernel:

```bash
su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

Guest output:

```
Booting Linux on physical CPU 0x0000000000 [0x412fd050]   <- Cortex-A55
Linux version 6.6.30-android15-5
Machine model: linux,dummy-virt
psci: PSCIv1.0 detected in firmware.
GICv3: CPU0: found redistributor 0 region 0:0x000000003ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x0000000001 [0x411fd411]  <- Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

**Conclusion: ATF → EL2 → VHE → KVM → a 2-vCPU Linux guest boots normally. The whole chain closes on
real hardware.**

## Final artefacts

| File | sha256 |
|---|---|
| `sign-test/tee_nogz_legacy_5M.img` | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `backup/tee_a.img` (for rollback) | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

## Remaining

- `tee_b` is **unmodified** (still stock). Switching to slot B returns to a no-KVM state, but that is
  exactly why it is a natural fallback.
- Upstream `mtk-mod-tee-nogz`'s undefined `sign_all_flag` bug can be reported.

---

# DroidVM on-device verification (late 2026-10-05)

## Environment

```
DroidVM v0.0.6 installed, daemon running (KernelSU authorised)
kernel 5.10.247-android12-9-Pandora-26w08d   SoC MT6895Z/TCZA
bundled: usr/bin/{qemu-system-aarch64, qemu-img, crosvm}
         usr/share/droidvm/{edk2-qemu.fd, edk2-gunyah.fd, vmlinuz, initramfs.img}
no usr/lib/modules (KVM needs no vendor modules, consistent with the source analysis)
```

## (1) crosvm + KVM: **stable and usable** (measured)

Using the device's built-in AVF crosvm to boot a microdroid kernel, the guest started fully and
two-core SMP worked.

## (2) DroidVM's bundled QEMU + KVM: **flaky (big.LITTLE race)**

Running QEMU bare fails because the linker namespace can't find `libbinder_ndk.so`; it needs
`LD_LIBRARY_PATH=/system/lib64` to work around (the DroidVM daemon has a correct environment itself
and doesn't need this).

```
Accelerators supported in QEMU binary: gunyah, kvm, tcg     <- no geniezone
```

DroidVM's `QemuBackendInstance` hardcodes cpu to `host[,pmu=off]` (source L196-201), and measured
**the same command run 5 times: 2 successes / 3 failures**:

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

**Root cause (located)**: `-cpu host` enumerates the features of **the CPU QEMU is currently on**;
on big.LITTLE, a migration between A55 and A78 while vCPU registers are being written → EINVAL.

Pinning verification:

| Condition | Result |
|---|---|
| No pinning × 5 | 2/5 succeeded |
| `taskset 1` (cpu0, A55) × 3 | **3/3 succeeded** |
| `taskset 80` (cpu7, A78) × 3 | **3/3 succeeded** |

Behaviour of the various `-cpu` variants (unstable; randomness dominates any feature difference):
`host` ✗ · `host,pmu=off` ✗ (60%) · `host,sve=off` ✓ · `host,pauth=off` ✓ ·
`host,sve=off,pauth=off` ✗ · `host,sve=off,pmu=off` ✓ · `max` ✗ · `cortex-a55` ✗ (KVM only supports host/max)

**Conclusion**: QEMU+KVM inside DroidVM needs **CPU pinning** to be reliable; crosvm does not.

## (3) Corroborating evidence unrelated to the ATF patch

`/proc/cpuinfo`'s Features are **completely identical** before and after flashing (neither has `sve`),
showing the patch did not change the kernel's determination of CPU features.
