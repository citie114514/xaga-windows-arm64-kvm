# On-device scripts

**English** | [中文](README.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

Push these to `/data/local/tmp/` on the phone and run them there. **All of them require root.**

| Script | What it does | Tested |
|---|---|---|
| [`boot-win.sh`](boot-win.sh) | Boots QEMU + KVM (**pins VNC to 5900**, gives a friendly message when the disk is missing) | ✅ |
| [`stop-vm.sh`](stop-vm.sh) | Stops safely (short process-name match, so `pkill -f` can't kill your own shell) | ✅ |
| [`restore-disk.sh`](restore-disk.sh) | Puts a backed-up virtual disk back as `win.vhdx` (detects format / checks free space / verifies sha256) | ✅ |
| [`qemu-wrapper.sh`](qemu-wrapper.sh) | **Optional**: wraps DroidVM's QEMU so the app's own configs also work | ✅ |

## Install

```bash
adb push scripts/phone/boot-win.sh scripts/phone/stop-vm.sh scripts/phone/restore-disk.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/*.sh'
```

---

# Two launch routes — **pick one, don't mix them**

## Route A: launch from the command line (**recommended**)

```bash
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
adb forward tcp:5900 tcp:5900
# Point your VNC client at 127.0.0.1:5900
```

| Pros | Cons |
|---|---|
| Arguments **fully under control**; port **pinned to 5900**; no dependency on DroidVM | No GUI; changing arguments means editing the script |

**This route bypasses DroidVM's config management entirely** — it never reads `vms.json`, and the
app can't rewrite it.

## Route B: let the DroidVM app launch it too (optional)

Configs the DroidVM app generates **don't work on their own**: it never attaches a `-netdev`
backend to the virtio NIC (the guest has no network) and never adds `virtio-balloon` (memory
only goes up).

A **wrapper script** fixes that — replace the `qemu-system-aarch64` the app calls with a wrapper
that forwards to the real `.real` binary:

```bash
# 1) Rename the original binary first (only once)
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 [ -f qemu-system-aarch64.real ] || mv qemu-system-aarch64 qemu-system-aarch64.real'

# 2) Push the wrapper
adb push scripts/phone/qemu-wrapper.sh /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/qemu-wrapper.sh /data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64'

# 3) Match permissions and ownership to .real
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 chmod 755 qemu-system-aarch64 && \
                 chown $(stat -c %u qemu-system-aarch64.real):$(stat -c %g qemu-system-aarch64.real) qemu-system-aarch64 && \
                 ls -l qemu-system-aarch64*'
```

It does three things, and **only when the caller didn't already provide them**, so it never
interferes with Route A:

```
1) Logs the full argument list to /data/local/tmp/qemu-args.log   <- very useful when debugging
2) Adds -netdev user if missing (id auto0, so it can't collide with the caller's id)
   Adds virtio-balloon-pci if missing
3) Binds everything to the A78 cluster with taskset f0 -- avoids the big.LITTLE migration
   race that breaks KVM
```

**Rollback**: rename `.real` back.

---

# ⚠️ Three traps in the DroidVM app

## 1. The VNC port defaults to **random**

`screens.*.vnc.port` in `vms.json` defaults to **`-1`**, meaning "pick one automatically":

```json
"vnc": { "host": "127.0.0.1", "port": -1, "password": "", "password_auth": false }
```

**Consequence**: the port can differ on every launch ✗ — whatever you forwarded with
`adb forward tcp:5900` has nothing listening on it ✗. This is a common cause of "the VM is
clearly running but I can't connect".

- **What this project does**: Route A writes `-vnc 127.0.0.1:0` (i.e. 5900) and re-checks the
  actual port after startup
- Setting the `port` field is theoretically another option, but it is **untested** and carries
  the risk in trap 3 — **not recommended**

## 2. Configs the app creates are incomplete

See "Route B" above — they lack `-netdev` and balloon, which the wrapper supplies.

## 3. Hand-editing `vms.json` makes the app unable to read it

**Symptom**: you hand-edit `vms.json` (e.g. to change the disk path) and the VM **simply
disappears** from the app, with a "this version can't read it" error.

**Cause**: DroidVM validates against its own strict schema and **doesn't recognise
hand-added fields**, so it drops the whole entry.

**Fix**
- **Only change fields it already has** (e.g. `disks[].path`, `screens.*.exporter`) — **never add new ones**
- Preserve the original owner and permissions:
  ```bash
  OWN=$(stat -c %u vms.json); GRP=$(stat -c %g vms.json); MODE=$(stat -c %a vms.json)
  # ... edit ...
  chown $OWN:$GRP vms.json; chmod $MODE vms.json
  ```
- **Back up first**: `cp vms.json vms.json.bak`

> More traps in [docs/05-gotchas.md](../../docs/05-gotchas.md) (items 2 and 9).
