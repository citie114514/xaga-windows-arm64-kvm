# Gotcha list

**English** | [中文](../05-gotchas.md) | [日本語](../ja/05-gotchas.md) | [Русский](../ru/05-gotchas.md)

Every trap here was **actually hit** on a Redmi Note 11T Pro+. Ordered by how much damage
they do.

---

## 1. 🔴 The ESP is empty — the firmware finds no bootable device

**Symptom**
```
BdsDxe: No bootable option or device was found.
```
Or the firmware sits on the UEFI screen / drops straight into the UEFI Shell.

**Cause**
When you apply an image with a tool like Dism++, **it does not write boot files to the ESP**.
A freshly formatted ESP contains only:

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING
```

**Fix**
```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```
The x64 `bcdboot` **can** write boot files for an ARM64 image and picks `bootaa64.efi`
automatically. Afterwards, verify that `bootmgfw.efi`'s PE machine is **`0xAA64`**.

See [03-windows-vm.md](03-windows-vm.md) section 2.3.

---

## 2. 🔴 The VNC port is not the one you think

**Symptom**
After `adb forward tcp:5900 tcp:5900`, the VNC client can't connect — or it connects to a black
screen. But **sometimes it works**, so the behaviour looks erratic.

**Cause (two layers)**

1. In `-vnc 127.0.0.1:N`, **`N` is the display number, not the port**; the port is `5900 + N`
   → `-vnc 127.0.0.1:5900` actually listens on **11800** ✗ (not 5900)
2. **When the port is taken, QEMU does not error** — it **silently increments the display number**
   → you think it's on 5900, but it's actually on **5901** ✗

**Fix**

```bash
# Correct form: :0 -> port 5900
-vnc 127.0.0.1:0,lossy=on
```

**And** wait for the port to actually be free before starting, then verify the actual port after:

```bash
# Before starting
for i in $(seq 1 30); do
    netstat -tln | grep -q ":5900 " || break
    sleep 1
done

# After starting
netstat -tlnp | grep qemu        # must show 127.0.0.1:5900
```

`scripts/phone/boot-win.sh` already does both, and **exits immediately if the check fails**.

---

## 3. 🔴 `-cpu host` fails randomly on big.LITTLE

**Symptom**
```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```
The same command run 5 times succeeds sometimes and fails other times.

**Cause**
`-cpu host` enumerates the features of **the CPU QEMU happens to be running on**. MTK is
4×A78 + 4×A55, so if the scheduler migrates the process between A55 and A78 while vCPU registers
are being written → `EINVAL`.

**Measured data**

| Condition | Success rate |
|---|---|
| No affinity | **2/5** ✗ |
| `taskset 1` (cpu0, A55) | **3/3** ✓ |
| `taskset 80` (cpu7, A78) | **3/3** ✓ |
| `taskset f0` (cpu4-7, A78 cluster) | **3/3** ✓ |

**Fix**
```bash
taskset f0 qemu-system-aarch64 ...
```

> All the `-cpu` variants (`host,pmu=off`, `host,sve=off`, …) behave **unpredictably — the
> randomness dominates any feature difference**. Don't try to work around it by tweaking
> features — **just pin the CPU affinity**.

---

## 4. 🔴 `pkill -f` killed its own shell

**Symptom**
A script stops halfway with no output, and no process is left running.

**Cause**
```bash
adb shell su -c 'pkill -f qemu-system-aarch64.real; ...'
```
`pkill -f` matches the **whole command line**, and **the outer `su -c` command line contains that
very string** → **it kills its own shell too**.

**Fix**
Match on a **short process name** (`pkill` matches only the process name by default):

```bash
pkill qemu-system-aar
```

Or put the `pkill` inside a **script file** (the script's own command line doesn't contain the
string):

```bash
# scripts/phone/stop-vm.sh
pkill qemu-system-aar
```

---

## 5. 🟠 `-device usb-tablet,bus=usb` reports a missing bus

**Symptom**
```
qemu-system-aarch64: -device usb-tablet,bus=usb: Bus 'usb' not found
```
QEMU won't start at all.

**Cause**
In `-device qemu-xhci,id=usb`, the `id=usb` is **just the device id**; the USB bus is named
**`usb.0`** (`<id>.0`).

**Fix**
**Drop `bus=`** and let it attach to the only USB controller automatically (simplest):

```bash
-device qemu-xhci,id=xhci -device usb-tablet -device usb-kbd
```

---

## 6. 🟠 Attaching a Windows install ISO steals the boot

**Symptom**
The system is installed, but booting lands in the Windows installer.

**Cause**
A Windows install ISO is **bootable** (El Torito + `EFI\BOOT\BOOTAA64.EFI`), so UEFI may prefer it.

**Fix**
- After installing, **don't attach** the Windows install ISO
- If you want a CD, attach **`virtio-win.iso`** — it is a **pure data disc** (ISO9660 produced by
  `genisoimage`: no El Torito, no EFI directory), so it's **safe to attach**

---

## 7. 🟠 `adb push` to `/data/media/0/` is permission denied

**Symptom**
```
adb: error: stat failed when trying to push to /data/media/0/DroidVM/win.vhdx: Permission denied
```

**Cause**
`/data/media/0` is a root-only directory; adb's shell user cannot write there.

**Fix**
Push somewhere the shell can write, then move it as root (**a rename within the same filesystem
is instant**):

```bash
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'
```

> Side note: `/storage/emulated/0/...` is a **FUSE mount**, while `/data/media/0/...` is the
> **native path** pointing at the same file. QEMU using the native path bypasses the FUSE layer.
> (Measured read throughput: about the same, ~950 MB/s, but the native path is more robust.)

---

## 8. 🟠 Time inside the VM becomes the year 2768

**Symptom**
The Windows taskbar shows `2768/12/24`.

**Cause**
QEMU's initial RTC value is off by **+742 years**.
But **the PL031 RTC is a 32-bit seconds counter, which physically cannot represent beyond 2106** —
so **it cannot be the RTC producing that value**; it's a conversion bug in the QEMU build.

**Fix**
**Once the network is up, Windows NTP corrects it automatically** (which incidentally proves the
network works). To set it manually:

```powershell
# Inside Windows, admin PowerShell
Stop-Service w32time; Set-Service w32time -StartupType Disabled
Set-Date -Date "2026-10-06 03:20:00"
```

Or right-click the taskbar clock → adjust date and time → turn off "Set time automatically" →
set it by hand.

---

## 9. 🟠 DroidVM's config system: three things you must keep apart

The DroidVM app and the QEMU command line are **two mutually incompatible ways to launch a VM**.
Mixing them always ends in a trap.

### (a) Configs the app creates **don't work on their own**

The launch arguments DroidVM generates are incomplete:

- **The virtio NIC has no `-netdev` backend** → no network in the guest
- **No `virtio-balloon`** → memory only goes up

**Fix**: install a **wrapper script** so that the `qemu-system-aarch64` the app calls forwards to
the real `.real` binary and fills in what's missing — full instructions in
[scripts/phone/README.md](../../scripts/phone/README.md).
It **only fills in what the caller didn't provide**, so it never interferes with your own boot
scripts.

### (b) The VNC port defaults to **random**

`screens.*.vnc.port` in `vms.json` defaults to **`-1`** = "pick one automatically":

```json
"vnc": { "host": "127.0.0.1", "port": -1, "password": "", "password_auth": false }
```

**Consequence**: the port can differ on every launch ✗ — whatever you forwarded with
`adb forward tcp:5900` has nothing listening on it ✗. This is a common cause of "the VM is clearly
running but VNC won't connect".

This project **avoids that path**: `boot-win.sh` hardcodes `-vnc 127.0.0.1:0` (= 5900) and
re-checks the actual port after startup.

> Setting the `port` field to a fixed value is **theoretically another route, but untested**, and
> it carries the risk in (c) below — so this project's scripts don't rely on it.

### (c) Hand-editing `vms.json` makes the app unable to read it

**Symptom**
You hand-edit `vms.json` (e.g. to change the disk path) and the VM **disappears** from the app,
with a "this version can't read it" message.

**Cause**
DroidVM validates against its own strict schema and **doesn't recognise hand-added fields**, so it
drops the entire entry.

**Fix**
- **Only change fields it already has** (e.g. `disks[].path`, `screens.*.exporter`) — **never add new fields**
- Preserve the original owner and permissions:
  ```bash
  OWN=$(stat -c %u vms.json); GRP=$(stat -c %g vms.json); MODE=$(stat -c %a vms.json)
  # ... edit ...
  chown $OWN:$GRP vms.json; chmod $MODE vms.json
  ```
- **Back up first**: `cp vms.json vms.json.bak`

### Conclusion: pick one, don't mix

| Route | Pros | Cons |
|---|---|---|
| **`boot-win.sh` command line** (recommended) | Full control over arguments, port pinned to 5900, no dependency on the app | No GUI; changing arguments means editing the script |
| **DroidVM app launch** | Has a GUI, can manage several VMs | Incomplete arguments (needs the wrapper), random port, config can't be hand-edited |

> **Don't use both at once**: the app rewrites `vms.json` when it launches, while the command line
> never touches it.

---

## 10. 🟡 `virtio-gpu-rutabaga-pci` crashes immediately

**Symptom**
```
exit=139      # SIGSEGV
```
QEMU dies instantly with no output.

**Cause**
`virtio-gpu-rutabaga-pci` (the gfxstream path) plus `-display egl-headless` segfaults on this build.
Incidentally, `virtio-gpu-gl-pci` with `-display none` also reports
`The display backend does not have OpenGL support enabled`.

**Fix**
- For normal display use **`virtio-gpu-pci`** (Windows uses `viogpudo`)
- For **virgl** (only meaningful with a Linux guest) use **`virtio-gpu-gl-pci` + `-display egl-headless`** (measured to initialise successfully)
- **Don't use rutabaga**

---

## 11. 🔴 **The patch stops working after a ROM / OTA update**

**Symptom**
After flashing a new ROM, `/dev/kvm` is gone — or you flashed a patch **built from different
firmware** into `tee_a` and it **looks like the device hangs at boot** (⚠️ but read item 12 first —
the first boot after flashing a patch always hangs at the second screen for ~2 minutes ✗).

**Cause**
The NoGZ patch modifies the boot handover logic of the `atf` member inside the `tee` partition, so
**a patch is built for the `tee` base it was built from** —— though a cross-base patch does boot ✓
(measured 2026-10-07); it just needs the 1–2 minute wait.

Measured (same Redmi Note 11T Pro+, two devices compared):

| Device | `tee_a` | `lk_a` | Result |
|---|---|---|---|
| Device 1 · stock Android 15 ROM | `f8f286f1…` → flashed to patch `f1511dca…` | `8cbaa2e8…` | ✅ boots + KVM |
| Device 1 · upgraded to **Android 16** | patch `f1511dca…` (**unchanged**) | **`a17d87c6…` (changed!)** | ✅ **still boots + KVM** |
| Device 2 · a **different firmware batch** | updated by the ROM to `a91f5ded…` | `a17d87c6…` | flashing device 1's patch → looked like a boot hang ⚠️ |

> ⚠️ **This table must be read with "same base" vs "cross base" firmly in mind** — it is the
> easiest thing to misread here:
>
> | | Device 1 | Device 2 |
> |---|---|---|
> | Base of the patch being flashed | `f8f286f1…` (the rk patch) | `f8f286f1…` (the rk patch) |
> | Its own `tee_a` before flashing | **`f8f286f1…`** | **`a91f5ded…`** |
> | Verdict | ✅ **same base** | ❌ **cross base** |
>
> **So device 1's success CANNOT be used as evidence that cross-base works** ✗ —
> it only demonstrates that **same-base works** ✓.
> **The only genuinely cross-base case is device 2** ⚠️ (and that conclusion is unreliable, see below).

**Conclusion (counter-intuitive, but measured)**:

- ✅ **A changed `lk` does not affect the patch** (device 1's `lk_a` was replaced; it still works)
- ✅ **Changed `gz` / `dtbo` / `boot` / `system` don't either** (survived Android 15 → 16)
- ❌ **A changed `tee` base does break it** — the only known "killer"
- ⚠️ **The same firmware batch shares a base**, different batches may differ (the upstream `xaga`
  profile's base `bd4b13a7…` is a third batch in this story); it is **not** "every device is different"

> 🛠 **Important correction (2026-10-06)**: the "boot hang" in the last row **rested on unreliable
> evidence**. Later measurements showed that **the first boot after flashing a patch normally hangs
> at the second screen for nearly 2 minutes** (see item 12). At the time we didn't wait long enough
> and declared it dead ✗.
> And the 2026-10-07 experiment on device 1 has settled it: **a cross-base patch boots normally** ✓
> —— not "it will fail" ✗, not "unverified" ⚠️, but **measured and working** ✓ (see [tee/README.en.md](../../tee/README.en.md)).
> Recommending a patch built for your own base is still correct ✓ — the reason is **TEE OS version
> matching**, not that it would hang.

**The nastiest part: a ROM package with no `tee` image can still change it**

The ROM flashed to device 2 **contained no `tee` image at all**, yet afterwards `tee_a` had changed
from `f8f286f1…` to `a91f5ded…` (probably a first-boot firmware update or `super.img`).
**So you cannot judge whether it will change by checking whether the package contains `tee`.**

**Fix**

```bash
# 1) Back up before flashing a ROM
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a.bak bs=4096'

# 2) After flashing, hash it and compare against the patch's "supported base"
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

| Result | Next step |
|---|---|
| Unchanged | ✅ the patch still works, do nothing |
| Changed | ❌ the patch is invalid → **dump the new `tee_a`/`lk_a`/`preloader_raw_a` and rebuild** (you cannot reuse another ROM's build) |

**The simplest way to tell whether the base changed** — look at the untouched slot:

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
# = f8f286f1… -> the base didn't change ✓
```

**Rollback**: flash the backed-up `tee_a` back; or switch to slot B (`tee_b` was never modified,
a built-in fallback).

---

## 12. 🔴 **Every boot after flashing hangs at the second screen for 1–2 minutes — that is not a brick!**

**Symptom**
After flashing the NoGZ patch, **every** boot stops at the **second boot screen** (logo2 / spinner)
with **no change for 1–2 minutes** ✗ — it looks exactly like a brick.

> ⚠️ **Every boot, not just the first one** ✗ — reported from real use: after flashing, this happens on
every boot.

**But it is normal** ✓ — measured (device 2, `tee_a` flashed to `17ec8497…`, then rebooted):

```
 20s   adb already sees the device, but sys.boot_completed=0
 30s   ...
 140s  still waiting (a full 120 seconds with no change on screen)
 150s  sys.boot_completed=1   <- it came up by itself ✓
```

**Result**: `/dev/kvm` appeared normally ✓, the system was intact ✓, none of the 497 app packages
were lost ✓

**Cause (speculative)**
With the patch, ATF no longer hands EL2 to GZ, so some stage of the boot chain is **waiting for a
response from GZ**, times out, and then continues — hence "stuck but not dead".

### ✅ Correct behaviour: **wait 3 minutes**

- **Don't** assume it's bricked ✗
- **Absolutely do not** rush to press Volume Down + Power for fastboot ✗ —
  **that interrupts the boot** ✗ and turns a boot that would have succeeded into one that really
  cannot start ✗
- Only if there is **no change after 5 minutes** should you suspect a patch from the wrong base ✗

**This is not a one-off** — as long as the patch is in place, every boot goes through this wait ✓
(think of it as: GZ never gets EL2, so the boot chain has to wait out that handshake timeout each time).

### Telling "normal slow" apart from "really broken"

| Signal | Normal ✓ | Really broken ✗ |
|---|---|---|
| Screen | hangs at the **second** screen (logo2) with a spinner | hangs at the **first** screen, or a black screen that **falls into fastboot** |
| adb | **device visible** (`adb devices` shows the serial) | not visible, or already in fastboot |
| Time | comes up by itself in 1–3 minutes | no change after 5+ minutes |
| Action | **wait** ✓ | restore the backup (see the rollback section of [tee/README.md](../../tee/README.en.md)) |

> 💡 Lesson: this project once wasted a recovery because it didn't wait long enough and treated
> this as a real brick. **After flashing, give the first boot 3 minutes.**

### 🔑 Why "hangs at the second screen" is a key diagnostic

ATF signature verification happens during the **`bl2_ext` stage** (the preloader stage, **long before
the kernel starts**):

```
ATF verification ([SBC] image atf header auth pass)
    | happens before the kernel
kernel starts -> first screen -> second screen
```

**Therefore:**

```
Never reaches the second screen (stuck on the first / falls into fastboot)
    => might be "not accepted" -- signature / base / a corrupted partition write

Reaches the second screen (logo2)
    => ATF was definitely accepted ✓
    => the problem is definitely NOT the signature and NOT the base, but the boot process afterwards
       (i.e. the delay, or TEE initialisation)
```

> This diagnostic is **free**: no logs, no PC — **the screen alone tells you** ✓
> It is also how this project later confirmed that "that boot hang was really just not waiting
> long enough" ✓

---

## Appendix: things that look like traps but aren't

| Symptom | Truth |
|---|---|
| `warning: nic virtio-net-pci.0 has no peer` | The NIC has no backend (missing `-netdev user,id=n0`). Just a warning, **but the network won't work** |
| AAVMF takes tens of seconds before starting | The built-in default entry `Boot0002 "UEFI Misc Device"` times out first; normal |
| The screen briefly goes black during first boot | Windows is rebooting / switching display modes. **Just reconnect VNC**; progress isn't lost (it's on disk) |
| `Trusted root check: skipped` | Offline signature verification skips the trust-root comparison — **only a real boot proves it** (not a failure) |
| `/dev/kvm` reports `Invalid argument` | That's **normal**! It means `open()` already passed SELinux (Enforcing) and simply got no arguments |
| QEMU can't find `libbinder_ndk.so` | DroidVM's QEMU needs `export LD_LIBRARY_PATH=/system/lib64` |

---

## Suggested troubleshooting order

When "it won't boot", check in this order:

```
1. adb shell su -c 'ls -l /dev/kvm'                    <- is KVM there (precondition)
2. adb shell su -c 'cat /data/local/tmp/boot.out'      <- boot script output (includes port check)
3. adb shell su -c 'cat /data/local/tmp/win-qemu.log'  <- QEMU's own errors
4. adb shell su -c 'cat /data/local/tmp/win-serial.log'<- firmware serial output (BdsDxe etc.)
5. python scripts/vncgrab.py                           <- grab one frame to see how far it got
6. adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
   adb pull /data/local/tmp/e.img && grep -a "\[SBC\] image" e.img   <- ATF verification chain
```
