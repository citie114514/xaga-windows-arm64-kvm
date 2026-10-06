# Prebuilt `tee` Images

**English** | [中文](README.md)

Signed NoGZ-patched `tee` partition images, ready to flash onto a device whose firmware
matches the base they were built from.

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

## ❓ Does patching `tee` affect app integrity / detection? **No — tested.**

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

## ⚠️ The core rule: a patch is bound to one `tee` base

The NoGZ patch modifies the **boot handover logic of the `atf` member** inside the `tee`
partition, so it is only valid for **the exact base it was built from**.

**What has been empirically confirmed to matter — and what does not:**

| Partition / condition | Breaks the patch? | How to check |
|---|---|---|
| **`tee`** | ✅ **Yes** | compare the `tee_a` hash |
| `lk` | ❌ No | confirmed after it was replaced |
| `gz` / `dtbo` / `boot` / `system` | ❌ No | survived an Android 15 → 16 upgrade |
| Across devices (same model) | ⚠️ **Depends on `tee_b`** | same `tee_b` = same firmware batch = same base |

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
| **On real hardware** | ✅ **working** | ❌ **not tested** |
| Profile | [`profiles/xagapro.json`](../profiles/xagapro.json) | [`profiles/shuilanA15.json`](../profiles/shuilanA15.json) |

**⚠️ Never mix them up.** Flashing a stock-base patch onto a device whose base was already
updated **stops it at the second boot screen**, and only a `fastboot` restore brings it back.

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
| `tee_nogz_shuilanA15_5M.img` | ⏳ offline-verified patch, base `a91f5ded…` |
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
