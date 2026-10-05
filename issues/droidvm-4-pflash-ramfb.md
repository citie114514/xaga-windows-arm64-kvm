# [qemu] pflash drive uses the vars image as flash0 (size mismatch), and `ramfb` needs a `vgabios-ramfb.bin` that is not shipped

Two independent problems with the QEMU backend's device/resource handling. Both are visible in the same startup log.

## 1. `if=pflash` is used for the UEFI variable store, but QEMU's `virt` machine wants a 64 MiB code flash there

`QemuBackendInstance` (dev `0.0.6.r240.g5c89691`, ~line 223):

```java
if (boot.uefi) {
    args.add("-bios");
    args.add(boot.firmware.isEmpty() ? PATH_EDK2_QEMU_FIRMWARE : boot.firmware);
    if (boot.varsEnabled) {
        var vars = boot.vars.isEmpty() ? PATH_EDK2_VARS : boot.vars;
        args.add("-drive");
        args.add(fmt("file=%s,if=pflash,format=raw", vars));
    }
}
```

`PATH_EDK2_VARS` is `edk2-gunyah.vars.fd` = 786 432 bytes, but on `-machine virt` the **first** `if=pflash` drive becomes `flash0`, which QEMU sizes at 64 MiB:

```
qemu-system-aarch64: cfi.pflash01 device '/machine/virt.flash0' requires 67108864 bytes,
                    pflash0 block backend provides 786432 bytes
```

QEMU then refuses to start. On this arm64 host there is only one UEFI vars file shipped and it belongs to the *crosvm/gunyah* firmware, so the value is also the wrong image for the QEMU path.

**Suggested fix:** emit the pair QEMU's `virt` expects

```
-drive if=pflash,format=raw,readonly=on,file=<code, 64 MiB>
-drive if=pflash,format=raw,file=<vars, 64 MiB>
```

(or ship a QEMU-specific vars image together with the code image), and drop `-bios` when pflash is used.

## 2. `ramfb` is added but its option ROM is missing from the QEMU data dir

With the `simplefb` screen enabled (`screens.simplefb.enabled = true`), `buildGpuCommand()` adds a bare `-device ramfb`. QEMU then looks for the device's option ROM in the `-L` directory and fails:

```
rom: file vgabios-ramfb.bin   : error Failed to open file "vgabios-ramfb.bin": No such file or directory
```

`-L` is `pathJoin(DATA_DIR, "usr", "share", "qemu")`. Inspecting the shipped tree, `vgabios-ramfb.bin` is not present (the bundled QEMU otherwise finds its other ROMs there).

This is what produced the earlier report *"Guest has not initialized the display (yet)"* — the device that was supposed to bring up a framebuffer never initialised.

**Suggested fix:** ship `vgabios-ramfb.bin` (it is a small, freely redistributable QEMU ROM) or stop emitting `-device ramfb` when the ROM is not available, so the failure is explicit rather than a black screen.

## Impact

With both `boot.uefi.vars_enabled = true` and the `simplefb` screen on, the QEMU backend cannot start at all. Turning both off is a workaround, but then the UEFI variable store is absent and only `virtio-gpu-pci` provides a display.
