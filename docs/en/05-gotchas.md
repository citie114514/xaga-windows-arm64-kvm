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

## 7. 🟠 Time inside the VM becomes the year 2768

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

## 8. 🟠 DroidVM's config system: three things you must keep apart

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

## 9. 🟡 `virtio-gpu-rutabaga-pci` crashes immediately

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

## 10. 🔴 **The patch stops working after a ROM / OTA update — it shows up as a *first-screen* hang, not a second-screen one**

> **This entry is about "the patch was not accepted"** ✗
> whereas "hangs at the second screen for 1–2 minutes" is **a different thing** (normal delay, see item 11) ✓
> **Spend 30 seconds working out which one you have**, or you will waste a lot of time.

### Step 1: 30-second self-check — first screen or second screen?

**No PC needed — the screen alone tells you**:

| What you see | Verdict | What to do |
|---|---|---|
| Stuck on the **first screen** (first logo) / black screen then **falls into fastboot** | ❌ **the patch was not accepted** — this is the entry you're reading | keep reading |
| Stuck on the **second screen** (logo2 spinner) for 1–2 minutes, then boots by itself | ✅ **normal**, not this entry | **go to item 11**; wait the full 3 minutes, don't touch the power key |
| Stuck on the second screen for more than 5 minutes with no change | ⚠️ may be a TEE-related issue | also keep reading, and see item 13 |

> 🔑 **Why the test works**: ATF signature verification happens during the `bl2_ext` stage,
> **long before the kernel starts**. **Never reaching the second screen ⇒ it may never have been
> accepted**; **reaching the second screen ⇒ ATF was definitely accepted** ✓, and whatever follows is
> just the boot process (delay / TEE initialisation).
> So "it looks like a boot hang" **cannot** be used as evidence that the patch failed ✗.

### Step 2: important corrections (settled by measurement, 2026-10-06 / 10-07)


> 🛠 **Read this correction first (settled by measurements on 2026-10-06 / 10-07) — skipping it wastes your time:**
> - After flashing the patch, **every** boot stalls at the **second screen** for 1–2 minutes before the system comes up (see item 11) ✓
>   ⇒ "it looks like a boot hang" is **not** evidence that the patch failed ✗
> - **A cross-base patch boots normally too** ✓ (measured 2026-10-07)
>   ⇒ neither "always breaks" ✗ nor "unverified" ⚠️, but **measured and working** ✓ (see [tee/README.en.md](../../tee/README.en.md))
> - Building a patch for your own base is still **recommended** ✓ — but the reason is **TEE OS version matching**, not "otherwise it hangs at the second screen" ✗

### First, self-test: are you stuck at the "first screen" or the "second screen"? (30 seconds, no PC needed)

| What you see | Verdict | What to do |
|---|---|---|
| Stuck at the **first screen** (first logo) / black screen, then **straight into fastboot** | ❌ **the patch was not accepted** — this is your entry | read "Cause" and "Fix" below |
| Stuck at the **second screen** (logo2 / spinner) for 1–2 minutes, then boots by itself | ✅ normal (see item 11) | **wait the full 3 minutes**, don't touch the power key |
| `adb devices` shows the device, but `sys.boot_completed=0` | ⏳ normal delay | keep waiting |

> 🔑 **Why the rule holds**: ATF's signature check happens in the `bl2_ext` stage (**long before the kernel starts**).
> No second screen ⇒ it may never have been accepted; second screen visible ⇒ ATF was definitely accepted ✓,
> so the problem can only be later in the boot process (the delay, or TEE init). See item 11.

With adb available, run the command-line self-test too:

```bash
# 1) Is the patch actually in effect?
adb shell su -c 'ls -l /dev/kvm'        # present -> the patch is active ✓
adb shell su -c 'ls -l /dev/gz_kree'    # present -> GZ still owns EL2, the patch is not active ✗

# 2) Did the ROM change your base? (tee_b was never touched — use it as the reference)
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
#   identical to the value recorded when the patch was built -> base unchanged ✓
```

**Symptom**
After flashing a new ROM, `/dev/kvm` is gone — or you flashed a patch **built from different
firmware** into `tee_a` and it **looks like the device hangs at boot** (⚠️ use the self-test above to
tell "first screen" from "second screen" first).

**Cause**
The NoGZ patch modifies the boot handover logic of the `atf` member inside the `tee` partition, so
**a patch is built against one specific `tee` base**.

Measured (same Redmi Note 11T Pro+, two devices compared):

| Device | `tee_a` | `lk_a` | Result |
|---|---|---|---|
| Device 1 · stock Android 15 ROM | `f8f286f1…` → flashed to patch `f1511dca…` | `8cbaa2e8…` | ✅ boots + KVM |
| Device 1 · upgraded to **Android 16** | patch `f1511dca…` (**unchanged**) | **`a17d87c6…` (changed!)** | ✅ **still boots + KVM** |
| Device 2 · a **different firmware batch** | updated by the ROM to `a91f5ded…` | `a17d87c6…` | flashing device 1's patch → **it boots, but may be unstable or have other bugs** ⚠️ |

**Conclusion (counter-intuitive, but measured)**:

- ✅ **A changed `lk` does not affect the patch** (device 1's `lk_a` was replaced; it still works)
- ✅ **Changed `gz` / `dtbo` / `boot` / `system` don't either** (survived Android 15 → 16)
- ⚠️ **A changed `tee` base means the patch is no longer tailored** — it **still boots normally** ✓
  (measured 2026-10-07), but it is a "works, not recommended" combination because the **TEE OS
  versions may not match** ⚠️
- ✅ **The same firmware batch shares a base**, different batches may differ (the upstream `xaga`
  profile's base `bd4b13a7…` is a third batch in this story); it is **not** "every device is different"

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
| Changed | ⚠️ **dump the new `tee_a`/`lk_a`/`preloader_raw_a` and rebuild** (same base is the safest);<br>if you just want it working now, **a build from another base boots normally too** ✓ (measured 2026-10-07) |

**The simplest way to tell whether the base changed** — look at the untouched slot:

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
# = f8f286f1… -> the base didn't change ✓
```

**Rollback**: flash the backed-up `tee_a` back; or switch to slot B (`tee_b` was never modified,
a built-in fallback).

---

## 11. 🔴 **Every boot after flashing hangs at the second screen for 1–2 minutes — that is not a brick!**

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
| Action | **wait** ✓ | **first go to item 10 and check the patch / base** (don't just restore the backup) → only restore the backup once that is ruled out (see the rollback section of [tee/README.md](../../tee/README.en.md)) |

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
    => go to item 10 and troubleshoot (it has a 30-second self-test)

Reaches the second screen (logo2)
    => ATF was definitely accepted ✓
    => the problem is definitely NOT the signature and NOT the base, but the boot process afterwards
       (i.e. the delay, or TEE initialisation)
```

> This diagnostic is **free**: no logs, no PC — **the screen alone tells you** ✓
> It is also how this project later confirmed that "that boot hang was really just not waiting
> long enough" ✓

---

## 12. 🔴 The host `bcdboot` cannot write the boot files: it wants `EFI_EX`, which old images don't have

**Symptom**
On a Windows host with **Secure Boot enabled and the 2023 PCA installed**, writing boot files for an
**older ARM64 image** such as Win10 LTSC 2021 makes `bcdboot` fail outright:

```
BFSVC: Using Ex bins because SB is on, BFSVC_USE_EX_BINS is set, and 2023 PCA is in DB.
BFSVC: Using source OS version a00004a610001
BFSVC: Unable to open file G:\Windows\boot\EFI_EX\bootmgfw_EX.efi for read because the file or path does not exist
BFSVC Error: Failed to validate boot manager checksum (G:\Windows\boot\EFI_EX\bootmgfw_EX.efi)! Error code = 0xc1
BFSVC Error: ServicingBootFiles failed. Error = 0xc1
Failure when attempting to copy boot files.
```

**Cause**
The host `bcdboot` decides to use the "Ex bins" (boot manager with the 2023 PCA ✓) based on the
**host's own** Secure Boot state. But the `EFI_EX\` directory only exists in newer Windows ✗ —
**it is simply not present in the Win10 LTSC 2021 image** ✗ → the copy fails.

> This does not contradict [docs/03](03-windows-vm.md)'s "x64 `bcdboot` can write ARM64 boot files"
> — that holds when the **host has no SB / no 2023 PCA** ✓; here the host policy blocks it ✗.

**Fix: skip `bcdboot` and lay it out by hand (fully under your control)**

```powershell
# Administrator PowerShell; $E = ESP drive letter (e.g. V:), $W = Windows partition letter (e.g. G:)
New-Item -ItemType Directory -Force -Path "$E\EFI\Boot"           | Out-Null
New-Item -ItemType Directory -Force -Path "$E\EFI\Microsoft\Boot" | Out-Null

# Copy the ARM64 boot manager straight out of the image
Copy-Item "$W\Windows\boot\EFI\bootmgfw.efi" "$E\EFI\Microsoft\Boot\bootmgfw.efi" -Force
Copy-Item "$W\Windows\boot\EFI\bootmgfw.efi" "$E\EFI\Boot\bootaa64.efi" -Force   # fallback path
Copy-Item "$W\Windows\boot\EFI\boot.stl"     "$E\EFI\Microsoft\Boot\boot.stl" -Force

# Build the BCD by hand (createstore, then osloader, then bootmgr)
$BCD = "$E\EFI\Microsoft\Boot\BCD"
Remove-Item $BCD -Force -ErrorAction SilentlyContinue
bcdedit /createstore $BCD
$g = (bcdedit /store $BCD /create /d "Windows 10 ARM64" /application osloader | Select-String '\{[0-9a-fA-F-]+\}').Matches[0].Value
bcdedit /store $BCD /set "$g" device     "partition=$W"
bcdedit /store $BCD /set "$g" path       "\Windows\system32\winload.efi"
bcdedit /store $BCD /set "$g" osdevice   "partition=$W"
bcdedit /store $BCD /set "$g" systemroot "\Windows"
bcdedit /store $BCD /create "{bootmgr}" /d "Windows Boot Manager"      # <- do NOT add /application!
bcdedit /store $BCD /set "{bootmgr}" device       "partition=$E"
bcdedit /store $BCD /set "{bootmgr}" path         "\EFI\Microsoft\Boot\bootmgfw.efi"
bcdedit /store $BCD /set "{bootmgr}" default      "$g"
bcdedit /store $BCD /set "{bootmgr}" displayorder "$g"
bcdedit /store $BCD /set "{bootmgr}" timeout      5
```

**Three traps inside the trap**:

1. **`/application bootmgr` is invalid syntax** ✗ — the only legal types are `osloader` / `resume` /
   `startup` / `bootsector` / `fwbootmgr` and so on ✗. To create a boot manager you must write
   **`/create {bootmgr} /d "..."`** ✓ (the error is `The application type switch specified is not valid.`)
2. **Writing the BCD on the ESP requires administrator rights** ✗ — without elevation you get
   `The boot configuration data store could not be opened. Access is denied.`
3. **Check the architecture before copying boot files** ✓ — `bootmgfw.efi`'s PE machine must be
   **`0xAA64`**; never take it from the host's `C:\Windows\boot\EFI\` (that one is x64 ✗)

**Bonus**: the image's own `boot\EFI\` also contains `zh-CN\*.mui` (the localised boot menu),
`memtest.efi` and `winsipolicy.p7b` — copying those over as well makes it more complete ✓.

---

## 13. 🔴 **Enabling KVM breaks hardware video codecs — don't use it on a daily driver**

**Symptoms** (measured on real hardware, three states: before / after / after reverting)

| Function | Before | After | After reverting |
|---|---|---|---|
| Moonlight streaming | ✅ | ❌ **no response** | ✅ restored |
| UU Remote | ✅ | ❌ **unusable** | ✅ restored |
| QQ chat images | ✅ | ❌ **don't display** | ✅ restored |
| Internal storage | ✅ | ⚠️ may not mount at boot | ✅ restored |
| App data | ✅ | ⚠️ may be corrupted | —— |
| **Screen recording / camera video** | ✅ | ❌ **produces 0-byte files** | ✅ restored |

**Reverting to stock restores everything** ✓ — so the fault really is caused by the patch ✓

**Cause**

MediaTek's hardware codecs (mtk-vcodec) go through this dependency chain:

```
mtk_sec_heap      secure memory
gz_tz_system      TEE services provided by GZ
gz_trusty_mod
cmdq_sec_drv      secure command queue
```

The NoGZ patch stops GZ from getting EL2 → the chain breaks ✗ → hardware codec init fails ✗
→ Moonlight / UU Remote / QQ images / thumbnails, screen recording / camera video all affected ✗

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


> ⚠️ **Key point: this is unrelated to whether the base matches** ✗
> A same-base patch (built from this very device's firmware) **does it too** ✓
> It is the inherent cost of **NoGZ killing GZ** ✓

**How to use it properly**

| | |
|---|---|
| ❌ **Don't** | use a KVM-enabled phone as a daily driver |
| ✅ **Good for** | a spare / test / dedicated-VM phone |
| ✅ **Or** | accept "hardware video codecs unavailable" |
| ✅ **Want both** | go the [mainline Linux](06-mainline.md) route |

**Rollback**: flash the backed-up `tee_a` back and reboot → every function returns ✓

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
