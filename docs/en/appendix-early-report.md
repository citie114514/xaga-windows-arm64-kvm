# xagapro (Redmi Note 11T Pro+) — feasibility report for MTK NoGZ → KVM

**English** | [中文](../appendix-early-report.md) | [日本語](../ja/appendix-early-report.md) | [Русский](../ru/appendix-early-report.md)

Date: 2026-10-04
Device: `192.168.31.75:33445` (device 1, **nothing flashed**, read-only throughout)
Status: **all offline checks passed; waiting on the decision whether to write to the device**

---

## 1. Device facts (read-only recon)

| Item | Value |
|---|---|
| Model | 22041216UC / `xagapro` / marketed as **Redmi Note 11T Pro+** |
| SoC | MT6895 (Dimensity 8100: 4×A78 + 4×A55) |
| System | HyperOS 3, `OS3.0.1.0.VLHCNXM`, Android 15 |
| Kernel | `5.10.247-android12-9-Pandora-26w08d` (third-party Pandora kernel) |
| Root | **yes**, KernelSU (`uid=0(root) context=u:r:ksu:s0`) |
| Bootloader | **unlocked** (`ro.boot.flash.locked=0`, `verifiedbootstate=orange`) |
| Current slot | `_a` |
| RAM | 7.68 GiB → the **8 GiB** variant (not 12 GiB) |
| userdata | 226 G, 204 G used, 21 G free (**tight — clear space before building a rootfs**) |
| `hwid` | sku=xagapro country=CN level=MP version=4.9.0 project_adc=701 |

Kernel capabilities (from `/proc/config.gz`):

```
CONFIG_ARM64_VHE=y          <- key: the kernel supports VHE and can run at EL2
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_ARM_GIC_V3=y         <- the hardware basis for vGIC
CONFIG_ARM_GIC_V3_ITS=y
CONFIG_ARM64_VA_BITS=39
```

`/dev/kvm` **does not exist**, and the `kvm` module is compiled in but fails to initialise because the
kernel is running at EL1.
Under `/sys/module/` there are `gz_main_mod` `gz_trusty_mod` `gz_tz_system` `gz_ipc_mod`
`gz_irq_mod` `gz_virtio_mod` → **GenieZone is holding EL2**, exactly as the theory predicts.

---

## 2. Why the official script refuses outright

`mtk-mod-tee-nogz` only knows 3 profiles, all matched precisely by the full SHA-256 of
`tee.img`/`lk.img`:

| profile | Target model | Matches this device? |
|---|---|---|
| `yunluo` | — | ❌ |
| `peral` | Xiaomi 13T | ❌ |
| `xaga` | Redmi Note 11T Pro / POCO X4 GT | ❌ |

Measured on this device (sha256 straight from `/dev/block/by-name/`):

```
tee_a (5 MiB) = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_a  (8 MiB) = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3
tee_b         = f8f286f1... (identical to tee_a)
lk_b          = 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0
gz_a          = 3f829d4061b1cc00d6bbcd1cafa3263348ec75800c9654cd936410c4d26572f6
```

Against the xaga profile:
- `tee_sha256 = bd4b13a7…` ❌
- `lk_sha256 = 03856964…` ❌

**Conclusion: this cannot be copied wholesale; a new profile must be added for xagapro (= the
adaptation work described in the upstream repo's `docs/adaptation.md`).**

The good news: structurally they are very close — **the ATF is a build product of the same source**,
only a few function offsets differ.

---

## 3. The reverse-engineered xagapro profile (validated with the official regression)

### 3.1 How the offsets were located (disassembly evidence)

| Item | xaga | **xagapro (this device)** | Evidence |
|---|---|---|---|
| `pc_patch` | 0x1ad9c | **0x1ade0** | `ldr x8,[x1,#0x10]` → changed to `mov x8,#0x50f00000` |
| `kernel_patch` | 0x64a4 | **0x64a4** | `csel w12,w13,w12,eq` → changed to `mov w12,#0x3c9` (EL2h) |
| `getter` | 0xe5f8 | **0xe560** | `adrp x8,0x48244000; ldr w8,[x8,#0xf00]; mvn w8,w8; and w0,w8,#1; ret` = the documented `(~flags)&1` |
| `callback` | 0xdf14 | **0xde7c** | delta to getter = **0x6e4 (exactly the same as xaga)** |
| `flag` | 0x45f08 | **0x44f00** | callback: `adrp x9,0x48244000; str w8,[x9,#0xf00]` |
| `ep` | 0x53930 | **0x52930** | `add x14,x14,#0x938` → x14 = ep+8; PC written at ep+8, SPSR at ep+16, matching the TF-A `entry_point_info` layout |
| `kernel_args` | 0x539e0 | **0x529e0** | = ep + 0xB0 (same delta as xaga) |
| `handoff_global` | 0x53af0 | **0x52af0** | args_getter case0: `adrp x8,0x48252000; ldr x0,[x8,#0xaf0]` |
| `cold` | [0x1ad74,0x1adf8] | **[0x1adb8,0x1ae3c]** | the function starts at `stp x29,x30` and ends at `ret` |
| `cold_helpers` | [0xb6e8,0xb700] | **[0xb6bc,0xb6d4]** | two small `adrp/ldr/ret` functions |
| `kernel` | [0x6454,0x6538] | **[0x6454,0x6538]** | completely identical |
| `tag_parser` | [0x6688,0x68e8] | **[0x6688,0x68f0]** | the start is identical |
| `args_getter` | [0xb7fc,0xb858] | **[0xb7d0,0xb800]** | jump-table dispatcher + case0 |
| `lk_*` (13 items) | — | **identical to xaga** | see below |

**Every LK-side offset hit the same value with identical instruction words**: `lk_illegal=0x3a18` is
exactly `mrs x9,cptr_el3`; `lk_elcheck` starts at `0x39c8` with `mrs x4,CurrentEL`; and
`lk_gate=0x28d4`, `lk_skip=0x2904` (`mov w0,wzr`), `lk_getter=0x1e8a8`, `lk_callback=0x1e8bc` all line up.
→ **This device's LK code section is the same build as xaga's**; only the outer certificate/DTB
packaging differs.

### 3.2 Validation results

Using the official `scripts/build.py --check-only` (only adding a profile + correcting offsets, with
no changes to any decision logic):

```
passed_checks:
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=False   (4)
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=True    (4)
  missing_tag_defaults
  LK_EL2_illegal_EL3_negative_control
  kernel_feature_and_AArch32_controls
  wrong_PC_negative_control
  missing_tag_sync_negative_control
  budget_exhaustion_rejected
→ 14/14 all passed
```

Including the 4 **counter-examples** (wrong PC, missed shared-tag sync, LK entering from EL2 and
reading CPTR_EL3, instruction budget exhaustion) — which shows the patch semantics really are correct,
rather than "it ran, so it passes".

### 3.3 The artefact (unsigned)

`tee_nogz_xagapro.unsigned.img`, sha256 `2bcdf7b3bdae3dcc77d570e350a79e5962a46daa7cd19610b022742f8773f413`

The actual changes at 10 slots:

| ATF offset | file offset | Old instruction | New instruction |
|---|---|---|---|
| 0x01ade0 | 0x01afe0 | `ldr x8,[x1,#0x10]` | `mov x8,#0x50f00000` |
| 0x0064a4 | 0x0066a4 | `csel w12,w13,w12,eq` | `mov w12,#0x3c9` ← **kernel handover EL1h → EL2h** |
| 0x00e560 | 0x00e760 | `adrp x8,#0x48244000` | `mov w0,#0` |
| 0x00e564 | 0x00e764 | `ldr w8,[x8,#0xf00]` | `ret` |
| 0x00de7c | 0x00e07c | `ldr w8,[x0]` | `mov w8,#1` |
| 0x00de84 | 0x00e084 | `mov w0,wzr` | `str w8,[x0]` ← **write shared tag flags=1** |
| 0x00de8c | 0x00e08c | `ret` | `b #0x4820e568` |
| 0x00e568 | 0x00e768 | `mvn w8,w8` | `dc cvac,x0` |
| 0x00e56c | 0x00e76c | `and w0,w8,#1` | `dsb sy` |
| 0x00e570 | 0x00e770 | `ret` | `b #0x4820e560` |

---

## 4. Signing feasibility (established)

```
detect_pl_cert_mode.py preloader_raw_a.img --json
→ status: LEGACY
   reason: certificate entry uses enter-value traversal (arg4=1); legacy BIT STRING wrapper required
   sha256: 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1
```

The conclusion is unambiguous (not `NEED_MANUAL`) → signing needs `--legacy`, which the script adds
automatically.

---

## 5. What is missing / the risks

### 5.1 Missing
1. **The `pwnage24mtk` toolchain** (`sign_mtk_cert.py` / `verify_mtk_image.py`). The repository does not bundle it; you must supply a trusted copy.
2. **On-device boot validation**: this repository's linux branch is for **xaga**. xagapro only has adaptations in a few drivers (e.g. `power: mediatek: xagapro: SC8561` charging), so **panel/touch/charging may differ → it might not boot**.
3. Disk space: only 21 G left; building a rootfs needs room.

### 5.2 Risks (think these through first)
- **`tee` is a security partition.** Flash it wrongly → preloader signature verification fails → the boot chain breaks → **only EDL can rescue it**, and MT6895's EDL normally needs an authorised account. This is a real bricking risk.
- Passing the counter-example checks **≠ it will boot**. Upstream's own statement is
  `device_tested: false` / "the offline regression does not mean a device will necessarily accept it or boot".
- Both slots: `tee_a == tee_b` (both must be changed for it to stick; changing only one means switching slots reverts it).
- **The impact on Android itself is unknown**: with GZ disabled the `gz_*` modules won't load; although
  `CONFIG_ARM64_VHE=y`, whether MTK's proprietary drivers assume GZ exists is unverified.

### 5.3 Suggested order of progress
1. Get `pwnage24mtk` first, run `sign_mtk_cert.py` + `verify_mtk_image.py`, require **two `Result: VALID`**,
   and re-run the 14-item regression on the result.
2. Then decide whether to write. If writing, prefer writing only `tee_a` (the current slot), and confirm
   EDL/authorised tools are available and the rollback paths (`misc`/`frp` etc.) are clear.
3. Consider PRing this profile to the upstream repository (`docs/adaptation.md` requires a new version to
   be audited with positive and negative cases).

---

## 6. Backups (already in `backup/` in this directory)

| File | Size | sha256 |
|---|---|---|
| `tee_a.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `tee_b.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `lk_a.img` | 8 MiB | 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3 |
| `lk_b.img` | 8 MiB | 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0 |
| `preloader_raw_a.img` | 4 MiB | 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1 |

---

## 7. Reproduction commands

```bash
git clone --depth 1 https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
# Merge the contents of profiles.xagapro.json into references/profiles.json
# Add "xagapro" to the --profile choices in scripts/build.py

# 1) Offline regression (does not touch the device)
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img --check-only

# 2) Signing (requires your own pwnage24mtk)
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img \
  --preloader backup/preloader_raw_a.img \
  --tools ../pwnage24mtk \
  --out-dir outputs/xagapro-run-01
```

Dependencies: `pip install capstone unicorn`

---

## 8. Additional evidence (evening of 2026-10-04)

### 8.1 Why KVM is currently unavailable — nailed down by measurement

```
/proc/misc | grep -i kvm        -> empty (not one of the 46 misc devices)
/sys/module/kvm/                -> only parameters/ and uevent; no initstate / refcnt
/sys/module/kvm/parameters/     -> halt_poll_ns=500000 grow=2 grow_start=10000 shrink=0
/dev/kvm                        -> does not exist
```

`kvm_init()` never completed (the misc device was never registered). The `kvm_arch_init` / `kvm_init`
symbols are present in the kernel and the config is `CONFIG_KVM=y`, so the only possible reason for
failure is **the kernel is not at EL2**.
That maps exactly onto the `kernel_patch` slot in the table in 3.1 (`csel w12,w13,w12,eq` → forcing
`#0x3c9`).

### 8.2 The patch works for Android too

`kernel_patch` lives in ATF's "AArch64 kernel handover helper" and decides **the SPSR at the kernel
entry point**. Kernels in different slots (Android's or mainline's) go through the same handover point,
therefore:

- Stay on Android: the Android kernel also comes up from EL2. Its config is
  `CONFIG_ARM64_VHE=y` + `CONFIG_VIRTUALIZATION=y` + `CONFIG_KVM=y`, so `/dev/kvm` appears.
- Flash mainline: the approach shown in the video.
- The two can coexist (different slots / `fastboot boot`).

**The recommended minimal verification**: flash only `tee`, reboot into Android, check `/dev/kvm`.
That single step confirms the ATF part on real hardware at the lowest cost.

Android-side limitations: there is no SELinux rule for `/dev/kvm` (you need `su -c` and possibly
`setenforce 0`); Termux's QEMU has no virgl/venus, so GPU acceleration is unavailable.
