# Going further: mainline Linux + KDE

**English** | [中文](../06-mainline.md) | [日本語](../ja/06-mainline.md) | [Русский](../ru/06-mainline.md)

> For people who aren't satisfied with running a VM inside Android and want to turn the phone
> straight into a Linux computer — like in that [kde-yyds](https://space.bilibili.com/2008726064)
> video.

⚠️ **On this route we only went as far as "confirming KVM works"** (on the Android kernel).
**We never actually installed mainline ourselves.** What follows is assembled from the project
repository and public videos — for concrete steps, defer to the upstream project.

---

## 1. The state of mainline on this device (quite complete)

Project: **[`MT6895-Mainline`](https://github.com/MT6895-Mainline)**
Branch: **`7.2-mt6895-xiaomi-xaga`**

| Subsystem | Status |
|---|---|
| Kernel | **Linux 7.2** (mainline) |
| **GPU** | **Mali-G610 — Panthor / PanVK** ✓ |
| **Desktop** | **KDE Plasma, fully GPU-accelerated** ✓ |
| Display | Both the CSOT and Tianma panels **are supported**, **144 Hz** |
| Audio | Speaker ✓ 3.5 mm headphone ✓ |
| Wireless | WiFi ✓ Bluetooth ✓ |
| Other | Fingerprint ✓ auto-brightness/auto-rotate ✓ camera **RAW** ✓ PPS fast charging ✓ |
| System | **Arch Linux ARM boots** ✓ |

**Timeline visible from the video titles** (Bilibili channel `kde-yyds`):

| Date | Milestone |
|---|---|
| 08-10 | Boots Arch Linux ARM. At that point **only simplefb / UFS / USB were driven** |
| 08-19 | Mali-G610 comes up (Panfrost) |
| 08-21 | KDE Plasma + full GPU acceleration |
| 09-01 | Linux 7.2 Panthor/PanVK + stutter fixes |
| September | Fingerprint / auto-brightness+rotate / PPS charging / camera RAW / Bluetooth / 144 Hz / speaker / headphone / WiFi |

---

## 2. How it boots (the same shape as this project)

The author explained their approach in the video description. Notable points:

> The device tree is stuffed into the kernel and the kernel swaps it itself, because
> **modifying dtbo makes LK blow up**.
> Early debugging used a reserved region of memory (bits flip randomly, but it could still be read
> after rebooting back into Android). Later, once the UFS driver worked, kmsg was written to the
> **empty `vendor_boot_b` slot** and the phone was flashed back to Android to read it.
> Later still, once simplefb worked, the screen could be watched directly. After USB came up we
> hand-rolled init so USB exposes a **serial console**, letting the PC connect to `/dev/ttyACM0`.
> Finally the rootfs was **flashed into `userdata` with fastboot**, mounted, and `/sbin/init` started.

**Key takeaways**:

| Item | Approach |
|---|---|
| **Bootloader** | **Keep the stock LK**; don't port U-Boot (LK can load a mainline kernel too) |
| **Device tree** | **The dtb is embedded in the kernel** and swapped by the kernel (you cannot modify dtbo or LK blows up) |
| **Kernel** | → the `boot` partition |
| **rootfs** | → the `userdata` partition (flashed with fastboot) |
| **Debugging** | reserved memory for kmsg early on → then the empty `vendor_boot_b` slot → simplefb → USB serial |
| **Reference** | mt6878 mainline |

**This is the same mindset we used for KVM on Android**: keep LK, don't touch dtbo, and swap only
what can be swapped.

---

## 3. ⚠️ A trap you must know: the 7.2 Panthor GEM shrinker

**This one is directly relevant to running VMs — definitely read it:**

> Linux 7.2's panthor introduced the **GEM shrinker**, which can reclaim memory when available
> memory is low. **But under heavy memory pressure the reclaim cost for panthor is very high, and
> you get thunderous stutter.** In 7.2's panthor the gem shrinker is the first version of something
> newly introduced, so some regressions are expected — **if you hit it, just turn it off for now.**

Fix commit:
[`MT6895-Mainline/linux@4fadce8d`](https://github.com/MT6895-Mainline/linux/commit/4fadce8d6bbce016a8965ad93a5285c565401c1d)

**Why this matters to readers of this project**: **running a VM is exactly a "heavy memory pressure"
scenario** (KDE + QEMU + several GB of Windows + disk cache).
So if a VM on mainline Linux feels inexplicably laggy, **suspect this first**.

---

## 4. Why mainline can feel smoother than Android

A few reasons are visible from the videos and the project:

1. **The KDE compositor has full GPU acceleration** (Panthor/PanVK) — Android's graphics stack
   actually gets in the way in a VM scenario
2. **None of Android's background / thermal / memory-management interference**
3. **QEMU is a normal distribution build** — no need for the various adaptations DroidVM makes for
   Android (which is why this project hit things like VNC port confusion, `vms.json` being
   rewritten, native-exporter limitations)
4. The display path can be **local** (a native window / localhost VNC), with far lower latency than
   "adb-forward to a PC and then VNC on top of that"

---

## 5. Choosing between the two routes

| | **Android (this project)** | **Mainline Linux (this page)** |
|---|---|---|
| How much to change | Just flash `tee_a` | Install an entire system |
| Risk | One partition, rollback-able | Repartition and flash a rootfs |
| Daily driver | ✅ You can still make calls and use WeChat | ⚠️ Depends on how complete the port is |
| VM experience | Usable, limited by the VNC path | **Smoother** (GPU acceleration + local display) |
| Best for | **People who want to keep Android** | People who want to use the phone as a Linux computer |

**Recommendation**: first get KVM working on Android with this project (**this step is shared by
both routes** — mainline needs the same ATF idea, except that mainline's ATF comes from the
distribution/project). Once that's comfortable, consider moving to mainline.

---

## 6. Learn more

- **Project repository**: [`MT6895-Mainline`](https://github.com/MT6895-Mainline)
  - Kernel branch: `7.2-mt6895-xiaomi-xaga`
  - ATF NoGZ patch tool: [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)
- **Bilibili**: [kde-yyds](https://space.bilibili.com/2008726064) — the ongoing record of mainline progress on this device
- **Reference device**: mt6878 mainline

> This project's author also got the idea from that video, and that is how the Android version came
> about. Progress on the mainline side is far ahead of ours — **go straight to upstream if you want
> to go deeper.**
