# [qemu] `-bios <edk2-qemu.fd>` leaves the guest spinning: garbled serial, one vCPU at 100%, "display output is not active"

## Environment

- Redmi Note 11T Pro+ (`xagapro`), MT6895, Maliki-G610, Android 15, KernelSU, kernel 5.10.247
- KVM confirmed working on this host (`/dev/kvm`)
- DroidVM `dev` `0.0.6.r240.g5c89691`
- VM: backend `qemu`, hypervisor `kvm`, protected_vm `protected_normal`, 4096 MB, `-smp 4`, Windows 11 Arm64 ISO attached, `screens.gpu-0` enabled (`gpu_backend = none` → `virtio-gpu-pci`)

## Summary

The QEMU backend launches, but the guest firmware never produces any output. The VNC console shows **"display output is not active"**, and the guest vCPU burns 100 % of a core forever. Serial shows only 5 bytes of garbage.

## What DroidVM passes (captured from the process table)

```
qemu-system-aarch64 -name 2 -L .../usr/share/qemu -accel kvm -machine virt -cpu host
  -smp 4,sockets=1,cores=2,threads=2 -m 4096M
  -bios .../usr/share/droidvm/edk2-qemu.fd
  ... virtio-blk-pci (disk.qcow2), virtio-scsi-pci + scsi-cd (Windows ISO), virtio-net-pci,
      virtio-sound-pci, virtio-gpu-pci,xres=1280,yres=720,edid=on, ramfb ...
  -vnc 127.0.0.1:6410 -nodefaults
```

## Actual result

Serial output (with `-serial stdio` substituted for the uart chardev, same everything else):

```
ab=000 c=400 1234564
```

That is the *entire* output — the firmware never prints its own banner, not even under `-display none -serial stdio`.

CPU accounting of the guest process (8 s window):

```
T0 = 13 ticks  ->  T1 = 804 ticks   (791 ticks ≈ 7.9 s CPU in 8 s wall)
threads = 15, one thread: cpu_ticks = 802, all other vCPU threads = 0
```

So exactly one vCPU is spinning in a tight loop and the rest are idle.

## Things ruled out

- **RAM / disks / GPU / RAMFB:** reproduced with a minimal hand-built command line (no audio, no xhci, no ramfb).
- **`-cpu host` feature flakiness:** this is not the `Failed to put registers` issue — with `taskset` pinning the command line is stable and still hangs.
- **The firmware file itself is not broken:** the *same* `edk2-qemu.fd` runs under **crosvm** and prints `UEFI firmware (version  built at 16:00:07 on Mar 29 2026)`.
- **`-bios` vs pflash:** this looked like the cause (see the pflash issue), but replacing `-bios` with a **standard 64 MiB pflash0 (code) + 64 MiB pflash1 (vars) pair** gives the *same* 5 bytes of garbage and the same spin:

  ```
  -drive if=pflash,format=raw,readonly=on,file=code.fd     # edk2-qemu.fd padded to 64 MiB
  -drive if=pflash,format=raw,file=vars.fd                  # 64 MiB zero-filled
  → ab=000 c=400 1234564   (then timeout)
  ```

## Probable cause

`edk2-qemu.fd` is apparently built for a specific QEMU invocation that DroidVM does not produce (different memory map / flash layout / UART description), so the firmware faults early and ends up spinning. Because the firmware cannot initialise its console, the guest also never initialises a GOP, which is what QEMU reports as "display output is not active".

## Suggested fixes

1. Verify the exact QEMU command line the shipping firmware expects (pflash sizes, `-machine` options, UART/`-serial` description) and align `QemuBackendInstance` with it.
2. If the firmware needs the pflash pair, emit **two** `if=pflash` drives (code + vars), not `-bios` plus one vars drive (see the pflash issue).
3. Add a firmware self-check: if the guest produces no serial output for N seconds while a vCPU is spinning, surface that in the app instead of a bare black screen.

## Impact

The QEMU backend cannot boot a UEFI guest at all on this host, so it cannot be used as a fallback for the crosvm ISO problem.
