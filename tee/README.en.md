# Prebuilt `tee` Images

[中文](README.md) | **English** | [日本語](README.ja.md) | [Русский](README.ru.md)

Signed NoGZ-patched `tee` partition images, ready to flash onto a device whose firmware
matches the base they were built from.

---

# 🛑 Read this before trying them

## (1) Flash the **engineering preloader** first — otherwise you may have no way back

```
Stock preloader       => EDL requires a Xiaomi after-sales account authorisation ✗
                      => if the tee is wrong and it won't boot, you have NO no-auth rescue ✗

Engineering preloader => usbdl_verify_da's return value is discarded, so SLA/DAA are bypassed
                      => SP Flash / mtkclient can write WITHOUT an account ✓
                      => this is the actual precondition for "if it breaks you can recover" ✓
```

```bash
fastboot flash preloader1 preloader_xaga.bin
fastboot flash preloader2 preloader_xaga.bin
fastboot reboot
```

(by-name partitions `preloader_raw_a` / `preloader_raw_b`)

> ⚠️ The engineering preloader **only removes auth for writing**; it does **NOT** disable image
> verification at boot ✗ — `sbc_en` is still 1 and ATF is still verified every boot
> (see [../docs/05-gotchas.md](../docs/05-gotchas.md)).

## (2) Which devices these images fit

| Codename | Market names | This project |
|---|---|---|
| **`xagapro`** | **Redmi Note 11T Pro+** / **Redmi K50i** | ✅ **The device measured here** (both prebuilt images came from it) |
| `xaga` | **Redmi Note 11T Pro** / **POCO X4 GT** | ⚠️ Different firmware, needs its own profile — but **cross-base has been measured to boot**, so you may back up and try |

Both are **MT6895 / Dimensity 8100**; the principle is identical and only the firmware base differs.

---

## 👉 Want to just try a prebuilt image? Follow this order

```
1) Confirm you can flash the engineering preloader (you have the file; fastboot / SP Flash works)
2) Flash it and verify the device boots normally
3) Back up: tee_a / tee_b / lk_a / lk_b / preloader_raw_a / seccfg
4) Run tee/verify.sh to see which prebuilt fits your device
5) Flash it -> reboot -> 【give it 3 minutes】 (every boot stops at the second screen for 1-2 minutes; not a brick)
6) Verify: adb shell su -c 'ls -l /dev/kvm'
```

---

## ⭐ The verified example

### [`tee_nogz_rk_5M.img`](tee_nogz_rk_5M.img) — **KVM confirmed working on real hardware**

```
sha256   f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
base     f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
size     5,242,880 bytes (exactly one tee partition)
cert     LEGACY
```

**Verified twice on the same device, across a full OS upgrade**

| When | System | `tee_a` | `lk_a` | Result |
|---|---|---|---|---|
| First flash | HyperOS (Android 15) | `f8f286f1…` → patched | `8cbaa2e8…` | ✅ `/dev/kvm` appeared, 2-vCPU Linux guest booted fully |
| After upgrade | **Android 16 / HyperOS 3.3** | patch still present | `a17d87c6…` (**replaced**) | ✅ **still works**, `/dev/kvm` still there |

**That upgrade produced an important finding:**

> **A changed `lk` does not affect the patch at all. The only thing that decides
> compatibility is the `tee` base.**

**Raw evidence**

```console
$ adb shell su -c 'for p in tee_a tee_b; do printf "%s " $p; dd if=/dev/block/by-name/$p bs=4096 2>/dev/null | sha256sum | cut -c1-16; done'
tee_a f1511dcad9820397      ← this patch
tee_b f8f286f138e758a5      ← stock, never touched

$ adb shell su -c 'ls -l /dev/kvm'
crw-rw-rw- 1 root root 10, 232 2026-10-06 21:52 /dev/kvm      ← ✅

$ adb shell "grep -i kvm /proc/misc"
232 kvm

$ adb shell su -c 'dmesg | grep -i sbc'
[SBC] image atf header auth pass
sbc_en = 1
```

**What it actually ran**: `crosvm` (microdroid) booting a guest — passed.
`qemu-system-aarch64 -accel kvm` with a 2-vCPU Linux guest — passed. Later the same device
ran a **full Windows 11 ARM64 install through to the desktop**.

---

## Check your device first

```bash
bash tee/verify.sh                 # auto-detects a connected device
bash tee/verify.sh <serial>        # or name one explicitly
```

It prints your `tee_a` / `tee_b`, then tells you which prebuilt image (if any) is safe.
The manual version is a single hash comparison:

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

| Your `tee_a` sha256 | What you can flash |
|---|---|
| `f8f286f1…` (stock base) | `tee_nogz_rk_5M.img` ✓ |
| `a91f5ded…` | `tee_nogz_shuilanA15_5M.img` ✓ |
| anything else | ✗ **Do not flash** — build your own per [docs/02](../docs/02-build-and-sign.md) |

---

## ⚠️ The measured cost: enabling KVM breaks **hardware video decoding** — not for a daily driver

**This matters, and it overturns an earlier claim in this document** ✗

Measured on one device across three states (before / after / after reverting):

| Function | Before | After | After reverting |
|---|---|---|---|
| Moonlight streaming | ✅ | ❌ **no response** | ✅ restored |
| UU Remote | ✅ | ❌ **unusable** | ✅ restored |
| QQ chat images | ✅ | ❌ **don't display** | ✅ restored |
| Internal storage | ✅ | ⚠️ may not mount at boot | ✅ restored |
| App data | ✅ | ⚠️ may be corrupted (QQ reported "chat history anomaly") | —— |

**Reverting to stock restores everything** ✓ (measured)

### Why

```
MediaTek's hardware codec (mtk-vcodec) depends on:
   · mtk_sec_heap        secure memory
   · gz_tz_system        TEE services provided by GZ
   · gz_trusty_mod
   · cmdq_sec_drv        secure command queue

The NoGZ patch stops GZ from getting EL2  ->  that dependency chain breaks ✗
   ->  hardware decoder initialisation fails ✗
   ->  Moonlight / UU Remote / QQ images / thumbnail generation  all affected ✗
```

**Precise mechanism** (why it is specifically *hardware* codecs that break):

```
MTK's venc / vdec, when open()ed:
   -> use an IPI to the VCP co-processor to query the "supported frame sizes"
   -> and the VCP's READY handshake depends on the EL2 / secure-world chain

After the Android kernel is raised to EL2 (which KVM requires):
   -> the handshake breaks
   -> the size table comes back empty
   -> Codec2's configure() returns EINVAL
   -> the framework / apps DO NOT fall back to software encoding
   -> result: screenrecord produces 0-byte files,
              and Moonlight / UU Remote / QQ images all fail
```

**This explains four things**:

| Observation | Explanation |
|---|---|
| Why it is specifically **hardware** codecs that break | software codecs don't go through VCP, so they're unaffected |
| Why the failure is at the **configure** stage | the size-table query happens right there |
| Why apps **don't degrade gracefully** | they get `EINVAL` and simply give up; they never switch to software |
| Why the `/dev/vdec-fmt` node exists | that node *is* the frame-size table |

> **So: as long as KVM is present, hardware codecs are unusable.**
> **This is the inherent cost of the tee patch and cannot be avoided** — it is not a config or base issue.


**Note: this has NOTHING to do with whether the base matches** ✗ — a same-base patch does it too,
because it is the cost of **NoGZ killing GZ** itself ✓

### So how should this be used

| | |
|---|---|
| ❌ **Don't** | use a KVM-enabled phone as a daily driver |
| ✅ **Good for** | a spare / test / dedicated-VM phone |
| ✅ **Or** | accept "hardware video decoding unavailable" |
| ✅ **Want both** | go the [mainline Linux](../docs/06-mainline.md) route (different trade-offs) |

> 🛠 **This document used to say "it doesn't affect daily use" — that was wrong** ✗
> The A/B test at the time only covered KeyMint / Gatekeeper / Widevine / fingerprint,
> and **never tested hardware video decoding** ✗. Corrected.

---

## ❓ Does it affect app integrity checks? (KeyMint / DRM / fingerprint)

That is a different question, and the answer is **no** ✓:

This is the first question anyone should ask before flashing. We ran an A/B test on two
units (one stock, one patched) plus before/after on the same device.

**Why it cannot matter, architecturally**: the patch does exactly one thing —
**it stops GZ from claiming EL2**. Everything app-integrity checks rely on lives in the
**TEE (S-EL1)**, which is a completely separate world from EL2:

| Security capability | What actually provides it | After patching |
|---|---|---|
| **Hardware-backed keys / KeyMint attestation** | `keymint@1.0-service.beanpod` (vendor TEE) | ✅ works |
| **Gatekeeper** (lockscreen credential verification) | TEE | ✅ works |
| **Widevine / DRM** | `widevine_driver` holding a `mtk_sec_heap` reference | ✅ works |
| **Fingerprint / face** | TEE | ✅ works |
| **Secure Element** (NFC payments) | `secure_element@1.2-service-mediatek` | ✅ works |
| **GZ / GenieZone (EL2)** | MediaTek's EL2 virtualization framework | ⚠️ inert — **with no observed impact** |

### The evidence

Two devices — **one stock, one patched** — run the same commands, giving **identical results
across the board**:

```
1) Verified Boot state
   ro.boot.verifiedbootstate   orange      <- both, bootloader unlocked
   ro.boot.flash.locked        0           <- both
   ro.secure / ro.debuggable   1 / 0       <- identical
   ro.build.tags               release-keys

2) Key HAL services (identical on both)
   android.hardware.security.keymint.IKeyMintDevice/default                ✓
   android.hardware.security.keymint.IRemotelyProvisionedComponent/default ✓
   android.service.gatekeeper.IGateKeeperService                           ✓
   fingerprint / biometric / auth services                                 ✓

3) Is the TEE actually alive? (identical on both)
   teei_daemon and [teei_*] kernel threads present     <- Trustonic TEE running
   keymint@1.0-service.beanpod process running
   android.hardware.secure_element@1.2-service-mediatek running
   widevine_driver still holds an mtk_sec_heap ref     <- DRM secure-memory path alive

4) End-to-end hardware key test (keystore_cli_v2, identical on both)
   generate --seclevel=tee   ->  GenerateKey: success
   get-chars                 ->  all characteristics under "Hardware:", "Software:" empty
   sign-verify               ->  Sign: 256 bytes.  Verify: OK
```

**How to objectively prove the TEE is really doing the work** (rather than silently falling
back to software):

```bash
# Force a TEE-backed key and inspect where its characteristics land
adb shell 'keystore_cli_v2 generate --name=t --seclevel=tee'
adb shell 'keystore_cli_v2 get-chars --name=t'      # everything should be under "Hardware:"
adb shell 'keystore_cli_v2 sign-verify --name=t'    # must report Verify: OK
adb shell 'keystore_cli_v2 delete --name=t'
```

### Two important caveats

1. **`verifiedbootstate = orange` (unlocked bootloader) is already the Play Integrity killer**
   — and it has **nothing to do with `tee`**. On a device that is bootloader-unlocked and
   rooted, `MEETS_DEVICE_INTEGRITY` / `MEETS_STRONG_INTEGRITY` **already fail**, and banking
   apps are already dealt with via root-hiding. **Patching `tee` neither improves nor worsens
   this** — it does not touch the bootloader lock, root, or dm-verity.

2. **The `gz_*` kernel modules still load** (`lsmod` shows `gz_main_mod`, `gz_irq_mod`,
   `gz_virtio_mod` and friends), but with a zero reference count — they load and then
   **cannot get EL2, so they are dead**. The TEE, not GZ, is what does the real work.

> **In one line**: the patch changes **who owns EL2**; it does not touch the **TEE**.
> Every "is this a genuine, unmodified device?" check looks at the TEE and Verified Boot —
> neither of which changes.

---

## 🔬 Extra verification you can do before flashing: isomorphism check

Real-hardware testing is the final word, but there is a no-flash check that rules out a
whole class of problems.

**The idea**: a sound NoGZ patch changes its base `tee_a` in a **patterned** way — the changes
land on the patch points defined in the profile (ATF `getter`/`callback`/`pc_patch`, …), and
the rest of the diff is just signing. So take a patch **already verified on real hardware** as
a reference and compare whether the two "diff-against-their-own-base" region sets are
**isomorphic**:

```bash
python tools/verify-patch-diff.py \
  --base-a  backup/tee_a.img \
  --patch-a tee/tee_nogz_rk_5M.img \
  --base-b  backup/tee_a_NEWROM_a91f5de.img \
  --patch-b tee/tee_nogz_shuilanA15_5M.img
```

Actual output from this project:

```
  Region count identical : ✅ yes  (175 vs 175)
  Total bytes identical  : ✅ yes  (2953488 vs 2953488)
  Length sequence same   : ✅ yes

  ✅ Conclusion: the patch under test is isomorphic to the reference — same patch pipeline,
     nothing went off the rails.
```

**→ Both patches came out of the same build pipeline with no deviation.** This **cannot replace
real-hardware testing**, but it rules out "the build went wrong" / "the profile offsets are
miscalculated" classes of problems.

---

## ⚠️ Never keep patches for different bases in one directory

We actually hit this: **a patch for the wrong base was flashed because the filename was
misleading** ✗ — at the time it looked like the device was bricked, but it was most likely just
**not given the ~2 minutes the first boot after a patch needs**.
**Don't go and test that, though** ✗ — using the right base is the correct approach ✓

```
/data/local/tmp/tee_patched.img     <- wrong base ✗ yet the name looks like "the one to flash"
/data/local/tmp/tee_nogz_new.img    <- the correct patch for this device ✓ with an opaque name
```

**→ Rule: the filename must state which base it targets and whether it is safe for this
specific device** ✓ e.g. `FLASH_THIS_shuilan_patch_for_this_phone.img` /
`DO_NOT_FLASH_rk_patch_wrong_base.img` ✓

Put bluntly: **do not leave patches for several bases on the same device** ✗. If you must,
write a `TEE_README.txt` next to them saying which one is safe.

---

## ⚠️ The core rule: a patch is bound to one `tee` base — **but "cross-base cannot boot" has been disproved**

The NoGZ patch modifies the **boot handover logic of the `atf` member** inside the `tee`
partition, so it is only valid for **the exact base it was built from**.

### 🧪 Decisive experiment, 2026-10-07: **cross-base boots normally** ✓

```
Device 1 (original tee_a = f8f286f1…, i.e. the rk patch's own base)
  -> flashed the shuilan patch (17ec8497…, base a91f5ded…)   <- genuinely cross-base
  -> came back on the network 136 seconds after rebooting
  -> then 12/12 checks over 3 minutes, continuously online (not a boot loop)
  -> system normal, tee_b untouched throughout
```

**→ So "cross-base always breaks" is wrong** ✗, and "a cross-base patch cannot boot" is wrong too ✗.

**What that earlier "boot hang" really was**: the **1–2 minute delay that happens on every boot** ✗
(see [docs/05-gotchas.md item 12](../docs/05-gotchas.md)) — at the time we didn't wait long enough,
went into fastboot, and interrupted a boot that would have succeeded ✗.

**→ Recommended anyway: use the patch built for your own base** ✓ — not because "otherwise it hangs" ✗,
but because **same-base is more conservative with fewer variables** ✓.

> 🔑 **Practical takeaway**: **don't panic if you flashed the wrong base** ✓ — it will sit at the second
> screen for 1–2 minutes first; **give it 3 minutes** and it will very likely come up on its own ✓
> (backing up first still never hurts).

**What has been empirically confirmed to matter — and what does not:**

| Partition / condition | Breaks the patch? | How to check |
|---|---|---|
| **`tee`** | ✅ **Yes** | compare the `tee_a` hash |
| `lk` | ❌ No | confirmed after it was replaced |
| `gz` / `dtbo` / `boot` / `system` | ❌ No | survived an Android 15 → 16 upgrade |
| Across devices (same model) | ⚠️ **Depends on `tee_b`** | same `tee_b` = same firmware batch = same base |

> 🛑 **The most commonly misread point: successfully flashing "the other device's patch" ≠ cross-base works** ✗
>
> People see "device 1 works with its own patch" and conclude "so device 1's patch will work on device 2 too" ✗ — **that inference is wrong** ✓:
>
> | | Device 1 | Device 2 |
> |---|---|---|
> | Base of device 1's patch (`f1511dca…`) | `f8f286f1…` | `f8f286f1…` |
> | Its own `tee_a` before flashing | **`f8f286f1…`** | **`a91f5ded…`** |
> | Verdict | ✅ **same base** (expected to work) | ⚠️ **cross base** (measured working ✓, see above) |
>
> **Device 1's case was same-base flashing from beginning to end** ✓ — it proves that
> "**same-base works**" ✓, and **cannot be used as evidence that "cross-base works"** ✗.
> The only genuinely cross-base case is device 2 ⚠️, and even that conclusion is unreliable
> (see the "mixing them up" section below).

**The most reliable self-check — look at the untouched slot `tee_b`:**

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
```

- `tee_b` is still stock → the `tee` base is still the stock batch → stock-base patches work ✓
- `tee_b` changed too → the base is gone → you must rebuild ✗

> **ROM / OTA updates silently change `tee_a`** ⚠️ — in this project one device had `tee_a`
> switched from `f8f286f1…` to `a91f5ded…` **after flashing a ROM**, even though the ROM
> package contained no `tee` image at all (a first-boot firmware update or `super.img` did it).
> **So: back up `tee_a` before flashing a ROM, re-hash afterwards, and rebuild the patch if
> it changed.**

---

## The two images

| | `tee_nogz_rk_5M.img` | `tee_nogz_shuilanA15_5M.img` |
|---|---|---|
| Base | `f8f286f1…` (stock) | `a91f5ded…` (after a ROM update) |
| sha256 | `f1511dca…` | `17ec8497…` |
| Offline regression | 14/14 ✅ | 14/14 ✅ |
| Signature check | VALID ✅ | VALID ✅ |
| **On real hardware** | ✅ **working** | ✅ **working** (2026-10-06) |
| Profile | [`profiles/xagapro.json`](../profiles/xagapro.json) | [`profiles/shuilanA15.json`](../profiles/shuilanA15.json) |

**⚠️ About "mixing them up" — our earlier "it will definitely stop booting" claim is void, and cross-base is now proven to work** ✓

We used to state that flashing a stock-base patch onto a device whose base had been updated
**stops at the second boot screen**. That conclusion rested on **one misdiagnosed test** ✗ —
**every boot after flashing a NoGZ patch normally hangs at the second screen for 1–2 minutes** (see [docs/05-gotchas.md item 12](../docs/05-gotchas.md)). We simply did not wait
long enough ✗.

**→ And the 2026-10-07 device-1 experiment has settled this completely** ✓ ——
**a cross-base patch DOES boot normally: not "it will fail" ✗, not "unverified" ⚠️, but MEASURED AND WORKING** ✓
(see the full data in the "core rule" section above).

### You should still use the patch built for your own base ✓

Not because it would hang ✗, but because a cross-base patch carries another batch's **TEE OS**.
Even if the system boots, TEE services such as keymint / DRM / Secure Element may mismatch the
device's current ROM ✗.

### Telling "normal slow" apart from "really broken" ✓

| Signal | Normal ✓ | Really broken ✗ |
|---|---|---|
| Screen | hangs at the **second** screen (logo2) | hangs at the **first** screen, or **falls into fastboot** |
| adb | device **visible** in `adb devices` | not visible, or already in fastboot |
| Time | boots by itself in 1–3 minutes | no change after 5+ minutes |
| Action | **wait** ✓ | restore the backup |

---

## Flashing

```bash
# 0) Back up first (mandatory)
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a_backup.img bs=4096'
adb shell su -c 'dd if=/dev/block/by-name/tee_b of=/data/local/tmp/tee_b_backup.img bs=4096'
adb pull /data/local/tmp/tee_a_backup.img
adb pull /data/local/tmp/tee_b_backup.img
sha256sum tee_a_backup.img tee_b_backup.img     # record these

# 1) Push and verify the file actually arrived intact
adb push tee_nogz_rk_5M.img /data/local/tmp/tee_patched.img
adb shell su -c 'sha256sum /data/local/tmp/tee_patched.img'   # must equal the published sha256

# 2) Flash
adb shell su -c 'dd if=/data/local/tmp/tee_patched.img of=/dev/block/by-name/tee_a bs=4096 && sync'

# 3) Read back and verify
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'

# 4) Reboot and check KVM
adb reboot
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'grep -i kvm /proc/misc'
```

Expected:

```
crw-rw-rw- 1 root root 10, 232 … /dev/kvm
232 kvm
[SBC] image atf header auth pass
```

## 🔙 Recovery if it fails

**Symptom**: the device hangs at the second boot screen (logo spins, then a black screen or
a reboot loop) — but it still enters **fastboot** (Volume Down + Power).

```bash
fastboot devices
fastboot flash tee_a tee_a_backup.img
fastboot reboot
```

**This path is proven** — it is exactly how the second base in this project was rescued.
It touches **only `tee_a`**; user data and the rest of the system are untouched.

> Fallback: the device also has a **B slot**, and `tee_b` was never modified, which is a
> natural second copy.

---

## Files in this directory

| File | What it is |
|---|---|
| `tee_nogz_rk_5M.img` | ✅ verified-working patch, base `f8f286f1…` |
| `tee_nogz_shuilanA15_5M.img` | ✅ verified-working patch, base `a91f5ded…` |
| `verify.sh` | Device self-check — tells you which image fits |
| `README.md` | Chinese documentation (more detail) |

---

## About these files

- They are **complete, officially-signed `tee` partition images** (MediaTek ATF, TEE OS and
  the certificate chain included).
- Built with [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) +
  [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk). Offset definitions live in
  [`profiles/`](../profiles/); the reverse-engineering tools in [`tools/`](../tools/).
- Upstream `mtk-mod-tee-nogz` explicitly ships **no firmware and no prebuilt images**.
  They are mirrored here so results can be **cross-checked and reused** — judge for yourself
  whether they suit your situation.
- **Flashing carries risk.** Use these only on **hardware you own**, and **back up first**.
- **Not covered by this repository's MIT license** — see the note at the end of
  [`../LICENSE`](../LICENSE).
