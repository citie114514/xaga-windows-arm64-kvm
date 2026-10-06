# Usage

**English** | [中文](../04-usage.md) | [日本語](../ja/04-usage.md) | [Русский](../ru/04-usage.md)

This page covers: **how to launch**, **what every QEMU flag means**, **how to see the screen**,
**how to get networking**, and **how to tune performance**.

---

## 1. Launching

```bash
# Run on the phone after pushing the script (requires root)
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
```

The script pins **VNC to port 5900** and does the following:

```
[1] Kill old instances (so the port isn't taken and QEMU silently moves to 5901)
[2] Wait for 5900 to actually be free (up to 30 s, then give up -- no compromises)
[3] Launch QEMU (CPU pinning + the full set of tuned flags)
[4] Verify the actual listening port == 5900 (error out if not)
```

**Why verify the port**: in QEMU's `-vnc host:N`, `N` is the **display number** and the port is
`5900 + N`. If 5900 is taken, **QEMU does not error — it silently increments the display number**
→ 5901 ✗ So the script must actively wait and then verify.

Stopping:

```bash
adb shell su -c 'sh /data/local/tmp/stop-vm.sh'   # matches a short process name, so pkill -f can't kill itself
```

---

## 2. Seeing the screen (VNC)

```bash
adb forward tcp:5900 tcp:5900
# Any VNC client connects to 127.0.0.1:5900 (no password)
```

Grabbing frames from the command line (for screenshots/debugging without a client):

```bash
python scripts/vncgrab.py        # saves vnc-0.png / vnc-1.png
python scripts/vncprobe.py       # measures actual VNC throughput
python scripts/vncinput.py       # sends a keystroke to check whether the guest reacts
```

**For more smoothness**: `boot-win.sh` already enables `lossy=on` (lossy JPEG compression), which
measured cuts the per-frame payload from **3.00 MB to 0.36 MB (1/8.3)**. That is the single biggest win.

---

## 3. Every QEMU flag explained

```bash
Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=/data/media/0/DroidVM/win.vhdx

export LD_LIBRARY_PATH=/system/lib64        # <- mandatory! otherwise the linker namespace can't find system libs

taskset f0 "$Q" \                           # <- mandatory! pin to the A78 cluster, avoiding the big.LITTLE race
  -name win -L /data/data/cn.classfun.droidvm/usr/share/qemu \
  -accel kvm -machine virt -cpu host \
  -smp 4,sockets=1,cores=4,threads=1 -m 4096M \
  -bios "$FW" \
  -drive file="$DISK",if=none,id=nv0,format=vhdx,cache=writeback,aio=threads \
  -device virtio-blk-pci,drive=nv0,disable-legacy=on,disable-modern=off,bootindex=1 \
  -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-balloon-pci,disable-legacy=on,disable-modern=off \
  -device qemu-xhci,id=xhci \
  -device usb-tablet -device usb-kbd \
  -device virtio-gpu-pci,disable-legacy=on,disable-modern=off,xres=1920,yres=1080,edid=on \
  -vnc 127.0.0.1:0,lossy=on \
  -display none -nodefaults
```

| Flag | Effect / notes |
|---|---|
| `LD_LIBRARY_PATH=/system/lib64` | Needed by DroidVM's QEMU, otherwise it can't find system libraries |
| `taskset f0` | Pins to CPU 4-7 (the A78 cluster). **Without it, it fails randomly** (see the appendix of [01-enable-kvm.md](01-enable-kvm.md)) |
| `-accel kvm` | Hardware acceleration (the whole point of flashing `tee`). Using `tcg` is too slow to be usable |
| `-machine virt` | The generic ARM virtual platform |
| `-cpu host` | Passes through host CPU features. **Must be combined with taskset** |
| `-smp 4` | 4 vCPUs. The phone has 4×A78; **any more can only land on A55 and slows things down** |
| `-m 4096M` | 4 GB of RAM. On a phone, don't exceed 4G |
| `-bios "$FW"` | **Must be the stock AAVMF** — DroidVM's modified build spins/hangs under QEMU |
| `-drive ... format=vhdx` | **QEMU reads and writes VHDX directly** ✓ no conversion needed |
| `cache=writeback` | A compromise. `cache=unsafe` is faster (but risks corruption on power loss) |
| `aio=threads` | Async IO via a thread pool (more stable than native on FUSE) |
| `if=none` + `-device` | The modern style: define the backend first, then attach it to a device |
| `disable-legacy=on,disable-modern=off` | virtio 1.0 (modern) only. Windows drivers need modern |
| `bootindex=1` | Boot priority (AAVMF may ignore it, but it's harmless) |
| `-netdev user,id=n0` | **User-mode NAT (slirp)** — this is what gives the VM internet access |
| `-device virtio-net-pci` | The NIC. Its driver is `NetKVM` (already injected) |
| `-device virtio-balloon-pci` | Balloon memory. With `blnsvr` installed in the guest, idle memory can be returned to Android |
| `-device qemu-xhci,id=xhci` | USB controller. **Note the bus name is `xhci.0`, not `xhci`** |
| `-device usb-tablet` | Absolute-coordinate mouse (**leave off `bus=` and let it attach automatically**; `bus=usb` errors out) |
| `-vnc 127.0.0.1:0,lossy=on` | display 0 → port **5900**; `lossy=on` enables JPEG compression |
| `-display none -nodefaults` | No local display, no default devices (minimal = fewer resources) |

### Optional: attach the driver CD

```bash
if [ -f /data/local/tmp/virtio-win.iso ]; then
  set -- "$@" -drive file=/data/local/tmp/virtio-win.iso,if=none,id=cd0,media=cdrom,readonly=on \
              -device usb-storage,drive=cd0,removable=on
fi
```

> ✅ `virtio-win.iso` is a **pure data disc** (no El Torito, no EFI boot), so attaching it is **safe**
> and it will not steal the boot.
> ❌ **Do not attach a Windows install ISO** — that one is bootable and will compete with your system disk.

---

## 4. Networking

The boot script already configures **QEMU user-mode NAT (slirp)**:

| Item | Value |
|---|---|
| The VM's IP | `10.0.2.15` |
| Gateway | `10.0.2.2` |
| DNS | `10.0.2.3` |
| Outbound | ✅ can reach the internet |
| Inbound | ❌ the outside cannot connect in (a NAT property) |

The driver is `NetKVM` (already injected), so **it works in Windows with no extra driver work**.

**Verify the network really works** (watch QEMU's outbound connections from the PC):

```bash
adb shell su -c 'ss -tnp | grep qemu | grep -v 127.0.0.1'
# ESTAB  192.168.31.75:44394  ->  204.79.197.235:443      <- Microsoft
```

Inside the VM: if Edge can browse, you're good.

> **Tip**: if the clock looks absurd before you reach the desktop (say the year 2768),
> **Windows NTP corrects it once the network is up**.

---

## 5. Performance tuning

### Measured data (so you don't have to guess)

| Item | Measured | Conclusion |
|---|---|---|
| **VNC `lossy=on`** | per frame **3.00 MB → 0.36 MB (1/8.3)** | ✅ the biggest win, always enable it |
| **adb forward tunnel throughput** | **276 MB/s** | ❌ **not a bottleneck**; don't waste time on the network |
| 1080p vs 720p | 2.25× the pixels | Affects render and encode cost |
| CPU pinning | success 2/5 → **3/3** | ✅ mandatory |

### The knobs you can turn

| You want | How |
|---|---|
| **Smoother** | Drop the resolution to 1280×720 (`xres=1280,yres=720`); turn off visual effects inside Windows |
| **Less memory used** | Install `blnsvr.exe` in the guest so the balloon returns idle memory to Android |
| **Faster disk** | `cache=unsafe` (⚠️ power loss may corrupt the filesystem) |
| **More CPU** | **Don't raise `-smp` above 4** — beyond that it can only be scheduled onto A55 and is slower |
| **More RAM** | `-m` can go to 6G, but the phone needs memory too and OOM becomes likely |

### The real key to smoothness: the display path

```
Native local display (viewed directly on the phone)  -> smoothest
localhost VNC (same-device loopback)                 -> very smooth
adb forward + a VNC client on the PC                 -> noticeable latency (this project's default)
```

**Why it stutters**: QEMU's VNC encoding runs on the main thread, and `taskset f0` pins every thread
to the A78 cluster, so the VNC thread **competes for the same 4 cores** as the 4 vCPUs.

**Ideas worth trying** (not fully validated in this project — feedback welcome):

- Leave one core for QEMU's helper threads: `-smp 3`
- `-cpu cortex-a78` (a fixed CPU model, avoiding the host pass-through big.LITTLE race) plus dropping
  `taskset`, letting QEMU's threads spread across all 8 cores

**On Android, for even better smoothness**: use the DroidVM app's `native` display
(it draws straight onto the phone screen with no network involved at all — the "looks smooth locally"
effect from the [kde-yyds](https://space.bilibili.com/2008726064) video).

---

## 6. Daily maintenance

### Backup / snapshot

`win.vhdx` is the entire Windows system, so **you must have a backup**.

```bash
# Make a compressed snapshot on the phone (the VM must be stopped, otherwise the snapshot is torn)
adb shell su -c 'export LD_LIBRARY_PATH=/system/lib64; \
  /data/data/cn.classfun.droidvm/usr/bin/qemu-img convert -c -o compression_type=zstd \
  /data/media/0/DroidVM/win.vhdx /data/local/tmp/win-snapshot.qcow2'
```

- **`-c` + zstd**: about 40 minutes (CPU-bound)
- **Without `-c`**: about 90 seconds, but roughly 2 GB larger
- The result can be used directly as a qcow2 disk (`format=qcow2`), or converted back to vhdx with `qemu-img convert`

### Restoring / swapping the disk

Put the backup image back in `win.vhdx`'s place. Use `restore-disk.sh`, which:

1. Reads the file header and **detects the format** (VHDX / QCOW2 / VHD)
2. Compares against free space on `/data` and errors out rather than writing half a file
3. **Warns before overwriting** an existing target (3 seconds, Ctrl-C works)
4. Computes a **sha256** after copying

```bash
adb push win.vhdx /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/restore-disk.sh /data/local/tmp/win.vhdx'
```

> ⚠️ **Don't** just `adb push win.vhdx /data/media/0/DroidVM/` —
> adb's normal privileges cannot write to that directory (it's root-only) and you'll get
> `permission denied`. Push to `/data/local/tmp` first, then move it as root.
> `restore-disk.sh` already handles this.

**If it's a QCOW2 disk** (for example restoring from the compressed snapshot above), remember to change
`format=vhdx` to `format=qcow2` in `boot-win.sh`, otherwise QEMU refuses to open it.

### Checking the current state

```bash
# Is anything running?
adb shell su -c 'pgrep qemu-system-aar | wc -l'

# Is VNC on 5900?
adb shell su -c 'netstat -tln | grep 5900'

# The last launch log (arguments and errors are both here)
adb shell su -c 'tail -40 /data/local/tmp/win-qemu.log'

# Serial log (early Windows boot output shows up here)
adb shell su -c 'tail -40 /data/local/tmp/win-serial.log'
```

### Space

The system disk grows to about **~23 GB** in real usage (a 100 GiB dynamic disk).
With a backup, keep at least **40 GB** free on the phone's `/data`.

```bash
adb shell su -c 'df -h /data | tail -1'
```

---

## 7. Next steps

- **Troubleshooting** → [05-gotchas.md](05-gotchas.md)
- **Want mainline Linux + KDE** → [06-mainline.md](06-mainline.md)
