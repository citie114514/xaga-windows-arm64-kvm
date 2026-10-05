# [crosvm] UEFI guests cannot boot from a CD/ISO — `edk2-gunyah.fd` reports "No bootable option or device"

## Environment

- Device: Redmi Note 11T Pro+ (`xagapro`), MediaTek MT6895 (Dimensity 8100, 4×A78 + 4×A55, Mali-G610)
- Android 15 / HyperOS 3, KernelSU root, kernel `5.10.247-android12-9-Pandora-26w08d`
- Host kernel booted at EL2 → **KVM works** (`/dev/kvm` present, confirmed by running a working guest separately)
- DroidVM `dev` build `0.0.6.r240.g5c89691`
- VM: backend `crosvm`, hypervisor `kvm`, protected_vm `protected_normal`, `use_uefi`/`boot.protocol=uefi`, 4096 MB, Windows 11 Arm64 ISO attached as `bus: cdrom`

## Summary

With the crosvm backend, a UEFI guest **never finds the attached ISO as bootable**, so Windows (or any CD-booting OS) cannot be installed. The QEMU backend on the same device/ISO has other blockers, but this one is specific to the firmware crosvm loads.

## Steps to reproduce

1. Attach `Windows11_Client_arm64_zh-cn_26300_9457.iso` as a `cdrom` disk to a crosvm VM with `boot.protocol = uefi`.
2. Start the VM.

## Actual result

```
INFO  crosvm::crosvm::sys::linux::device_helpers] Trying to attach a scsi device: .../Windows11_Client_arm64_zh-cn_26300_9457.iso
INFO  disk] disk size 8852006912
UEFI firmware (version 0.1.r49.735c9f6 built at 19:55:16 on Sep  7 2026) 843FC000
BdsDxe: No bootable option or device was found.
BdsDxe: Press any key to enter the Boot Manager Menu.
```

The VM then exits (`crosvm: exiting with success`) after ~240 ms, and the app shows a black screen.

## Evidence that the ISO itself is fine

Parsed the ISO's El Torito boot catalog directly — it is a valid UEFI-bootable CD:

```
volume descriptors: sector 16 type=1 (PVD), sector 17 type=0 (Boot Record, ver=1), sector 18 type=255
El Torito BVD at sector 17 -> boot catalog LBA 22
validation entry : header=0x01  platform=0xEF (UEFI)  id="Microsoft Corporation"  key=0x55AA
initial entry    : boot_indicator=0x88 (bootable)  media=0x00 (no emulation)
                   sector_count=0x0d20 (3360 × 512 = 1680 KiB)  load_lba=550
LBA 550 starts with: eb 3c 90 'MSDMF3.2' ...   (standard EFI FAT boot image)
```

## Investigation

- Reproduced outside the app with the **AVF crosvm** (`/apex/com.android.virt/bin/crosvm`) using DroidVM's own firmware files, so the app is not a factor:

  ```
  # crosvm + edk2-gunyah.fd (as used by the app) + Windows ISO, ISO attached via --block AND --scsi-block
  → UEFI boots, then "No bootable option or device was found."
  ```

  ```
  # crosvm + the same firmware with NO disk attached
  → same message (expected)
  ```

- Attaching the ISO over **virtio-blk** (`--block path=...,ro=true`) or over **SCSI** (`--scsi-block path=...,ro=true`) makes no difference.

- `--pflash path=.../edk2-gunyah.vars.fd,block_size=262144` also makes no difference.

- Both firmware files in `usr/share/droidvm/` are compressed firmware volumes, so the included driver set cannot be listed from strings.

## Probable cause

`edk2-gunyah.fd` appears to be a trimmed EDK2 build without the **ISO9660 / El Torito** stack (or without a driver that produces `BlockIo` for a CD). UEFI's `BdsDxe` therefore enumerates no bootable option for a CD-ROM device.

`edk2-qemu.fd` is a separate build intended for the QEMU backend — using it under crosvm (via `boot.uefi.firmware`) prints only the banner and then makes no progress, so it is not a workaround.

## Suggested fixes

1. Ship an EDK2 build for crosvm that includes `MdeModulePkg/Universal/Disk/PartitionDxe` + `ISO9660` + the El Torito path, so `boot.protocol = uefi` can boot a CD.
2. Or document that the crosvm backend cannot install from ISO and steer UEFI installs to the QEMU backend.
3. Or expose the firmware choice per backend in the editor with a clear indication of which builds can boot media vs. only a preinstalled disk.

## Impact

On any non-Qualcomm device (where the QEMU backend has its own problems, see the related issues), installing Windows from ISO is currently impossible.
