# Windows 11 ARM64 disk — how to build it

**English** | [中文](../03-windows-vm.md) | [日本語](../ja/03-windows-vm.md) | [Русский](../ru/03-windows-vm.md)

> Goal: without installing a hypervisor and without running the installer inside a VM, produce a
> **bootable VHDX with drivers injected and TPM checks bypassed** directly on the PC.

**Why do it this way**: running the Windows installer under ARM emulation is a performance nightmare
(hours). Applying the image directly on the PC leaves the phone with only one OOBE pass, saving the
vast majority of the time.

---

## 0. What you need

| Item | Notes |
|---|---|
| **Windows 11 ARM64 ISO** | **Must be ARM64!** x64 on ARM is emulation-only and pointless |
| **virtio-win ISO** | Download from [fedorapeople](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) |
| PC | Windows, administrator rights, **at least 30 GB free** |
| 7-Zip | For extracting drivers |

> ⚠️ **Always verify the integrity of the virtio-win download.** Downloads through a proxy are often
> truncated, and a truncated ISO still "opens" but its contents can't be read (it shows up as tool
> errors, which is easily misdiagnosed as a tool problem).
> How to verify: read the ISO's PVD (offset `16 × 2048`; the volume size is the little-endian u32 at
> `pvd[80:84]` × 2048) and compare it against the actual file size. This project's
> `scripts/extract-virtio.ps1` performs this check automatically.

---

## 1. One-click build (recommended)

```powershell
# Admin PowerShell

# (1) Extract the ARM64 virtio drivers
.\scripts\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11

# (2) Build a bootable VHDX from the ISO
.\scripts\build-windows-vhdx.ps1 `
    -Iso D:\Win11_ARM64.iso `
    -DriversDir .\virtio-arm64-w11 `
    -Out .\win.vhdx `
    -SizeGB 100
```

`build-windows-vhdx.ps1` performs these 6 things automatically (each with verification):

```
[1] Mount the ISO, list the images, pick the ARM64 one automatically (the wrong architecture aborts with an error)
[2] Create a dynamic VHDX + partitions: MSR(16M) + Windows(NTFS) + ESP(FAT32, 300M)
[3] dism /Apply-Image /Compact:ON   (CompactOS compression; measured at only ~10 GB)
[4] bcdboot G:\Windows /s S: /f UEFI   <- the step most often forgotten
    and verify bootmgfw.efi's PE machine == 0xAA64
[5] Offline injection of LabConfig to bypass TPM/SecureBoot/RAM checks
[6] dism /Add-Driver to recursively inject the ARM64 virtio drivers, and confirm viostor is in place
```

---

## 2. Manual steps (for when you want the details)

### 2.1 Create the disk and partitions

Create a **100 GiB dynamic VHDX** with Dism++ or diskpart, GPT partitioned:

| Partition | Size | Type | Drive letter (example) |
|---|---|---|---|
| MSR | 16 MB | Microsoft Reserved | — |
| Windows | remaining | NTFS | `G:` |
| **ESP** | 300 MB | **FAT32 / EFI System** | `S:` |

### 2.2 Apply the image

```powershell
# First see which images exist and which is ARM64
dism /Get-WimInfo /WimFile:G:\..\install.wim     # or sources\install.wim from the mounted ISO

# Apply (with CompactOS compression)
dism /Apply-Image /ImageFile:D:\sources\install.wim /Index:3 /ApplyDir:G:\ /Compact:ON
```

> If the ISO contains `install.esd` (not wim), you additionally need `/Compress:recovery`.

### 2.3 Write the boot files — **the biggest trap**

**Disks produced by tools like Dism++ have a completely empty ESP:**

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING      <- this one
```

Without boot files, the firmware just reports "no bootable device".

**Good news: the x64 `bcdboot` can write boot files for an ARM64 image** and picks `bootaa64.efi`
automatically:

```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```

The log shows it recognising ARM64 (`bootaa64.efi`):

```
BFSVC: Updating \\?\GLOBALROOT\Device\HarddiskVolume10\EFI\Boot\bootaa64.efi
BFSVC: Copy files which lack a version: y  G:\Windows\boot\EFI -> ...\EFI\Microsoft\Boot
```

The post-build checklist (**all must pass**):

| Check | Expectation |
|---|---|
| `S:\EFI\Boot\bootaa64.efi` | exists (the fallback boot path) |
| `S:\EFI\Microsoft\Boot\bootmgfw.efi` | exists |
| `bootmgfw.efi`'s PE machine | **`0xAA64` (ARM64)** ← otherwise it won't boot |
| `S:\EFI\Microsoft\Boot\BCD` | exists |
| The BCD `path` entry | `\Windows\system32\winload.efi` |

### 2.4 Bypass the TPM / SecureBoot / RAM checks

Windows 11 checks hardware requirements on first boot. Bypass it by writing the registry offline:

```powershell
reg load HKLM\OFFLINESYS G:\Windows\System32\config\SYSTEM
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f
}
reg query 'HKLM\OFFLINESYS\Setup\LabConfig'
reg unload HKLM\OFFLINESYS
```

Without this, the very first boot step stops at "This PC can't run Windows 11".

### 2.5 Inject the virtio drivers

**The directory naming matters** (this is the key to finding things inside the ISO):

```
virtio-win.iso
├── Balloon\w11\ARM64\      balloon.sys  blnsvr.exe
├── NetKVM\w11\ARM64\       netkvm.sys
├── viostor\w11\ARM64\      viostor.sys     <- REQUIRED if you boot from virtio-blk
├── vioscsi\w11\ARM64\      vioscsi.sys
├── vioinput\w11\ARM64\     vioinput.sys  viohidkmdf.sys
├── viogpudo\w11\ARM64\     viogpudo.sys   <- the virtio-gpu display driver
├── vioserial\w11\ARM64\    vioser.sys
├── viomem\w11\ARM64\ / viorng\w11\ARM64\ / viosock\w11\ARM64\ / viofs\w11\ARM64\ / pvpanic\w11\ARM64\
```

- The ARM64 directory is called **`ARM64`** (not `aarch64`! many people fail to find drivers here)
- Windows 11 uses the **`w11`** subdirectory (Win10 uses `w10`)

Inject:

```powershell
dism /Image:G:\ /Add-Driver /Driver:D:\virtio-arm64-w11 /Recurse
```

Successful output:

```
The operation completed successfully. 12 of 12 drivers were installed.
```

**After injecting, verify every `.sys` is an ARM64 PE** (machine = `0xAA64`):

```
Balloon      balloon.sys      ARM64 OK
NetKVM       netkvm.sys       ARM64 OK
pvpanic      pvpanic.sys      ARM64 OK
viofs        viofs.sys        ARM64 OK
viogpudo     viogpudo.sys     ARM64 OK
vioinput     viohidkmdf.sys   ARM64 OK
vioinput     vioinput.sys     ARM64 OK
viomem       viomem.sys       ARM64 OK
viorng       viorng.sys       ARM64 OK
vioscsi      vioscsi.sys      ARM64 OK
vioserial    vioser.sys       ARM64 OK
viosock      viosock.sys      ARM64 OK
viostor      viostor.sys      ARM64 OK      <- 13 .sys files, all 0xAA64
```

---

## 3. Push to the phone and boot

```bash
# Push (USB is faster; /data/media/0 needs root, so push to /data/local/tmp and move it)
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'

# Confirm there is enough space (real usage grows to ~23 GB)
adb shell su -c 'df -h /data | tail -1'
```

Then:

```bash
# Push scripts/phone/boot-win.sh to the phone
adb push scripts/phone/boot-win.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/boot-win.sh && nohup /data/local/tmp/boot-win.sh > /data/local/tmp/boot.out 2>&1 &'

# See the screen
adb forward tcp:5900 tcp:5900
# A VNC client connects to 127.0.0.1:5900 (no password)
```

### First boot (OOBE)

This takes **5–15 minutes** and reboots by itself once or twice (the screen may briefly go black after
a reboot — that's normal).

**The key pages**:

| Step | Page | What to do |
|---|---|---|
| 1 | Is this the right country/region? | Pick your region → Yes |
| 2 | Keyboard layout | Your layout → Yes |
| 3 | Second keyboard layout | Skip |
| 4 | **Let's connect you to a network** | Choose **"I don't have internet"** → **"Continue with limited setup"** ← this lets you create a **local account** instead of a Microsoft account |
| 5 | Licence agreement | Accept |
| 6 | Who's going to use this device? | Enter a username; **leaving the password blank** is easiest |
| 7 | Privacy settings | Turn everything off → Accept |
| 8 | 🎉 Desktop | The first desktop load still takes a few minutes |

**If step 4 has no "I don't have internet" option**:
press `Shift + F10` for a command prompt → type `oobe\bypassnro` → it reboots by itself, and the page
will then offer the skip option.

### Recommendations after installation

- **Install the balloon memory service** (returns idle memory to Android — very valuable on a phone):
  attach the `virtio-win.iso` CD (`boot-win.sh` attaches `/data/local/tmp/virtio-win.iso`
  automatically), open the drive in Windows → `Balloon\w11\ARM64\blnsvr.exe` → install
- **Turn off visual effects** (a noticeable speed-up under software rendering): System Properties →
  Advanced → Performance → Adjust for best performance

---

## 4. An important fact about "guest tools"

**virtio-win has no ARM64 guest-tools installer.** A full sweep of the ISO:

```
guest-agent\qemu-ga-i386.msi        <- x86 only
guest-agent\qemu-ga-x86_64.msi      <- x64 only
virtio-win-gt-x64.msi               <- x64 only
virtio-win-gt-x86.msi               <- x86 only
virtio-win-guest-tools.exe          <- what it installs is the above
```

**So don't waste time hunting for an ARM64 guest-tools MSI — it doesn't exist.**

The ARM64 directories contain only the **drivers themselves** plus a few **usable helper EXEs**:

| File | Purpose |
|---|---|
| `blnsvr.exe` | Balloon memory service (**worth installing**) |
| `vgpusrv.exe` / `viogpuap.exe` | virtio-gpu user-space components |
| `virtiofs.exe` | virtio-fs shared directories (needs `vhost-user-fs` configured on the QEMU side) |
| `netkvmco.exe` / `netkvmp.exe` | NIC configuration tools |
| `qemu-ga` | ❌ **no ARM64 build** |

**The essential driver injection was already done in step 2.5**, and that is enough.

---

## 5. Can you avoid a virtio disk?

Yes. **Windows 11 ARM64 ships the NVMe driver (`stornvme`)**, so using NVMe as the boot disk works with
**zero injection**:

```
-device nvme,serial=win,drive=nv0
```

**The trade-off**:

| Option | Needs driver injection | Speed | Notes |
|---|---|---|---|
| **virtio-blk** (this project's default) | ✅ needs `viostor` | fast | Fine once the driver is injected |
| NVMe | ❌ not needed | also fast | The zero-injection fallback |
| IDE/AHCI | ❌ | slow | Not recommended |

**Recommendation**: since the drivers are injected anyway, use `virtio-blk` (it matches the network,
GPU and balloon setup — cleanest). If you want to first verify "does this disk boot at all", you can
use NVMe to rule drivers out.

---

## 6. Next steps

- **Learn how to tune the QEMU flags** → [04-usage.md](04-usage.md)
- **Hit a problem** → [05-gotchas.md](05-gotchas.md)
