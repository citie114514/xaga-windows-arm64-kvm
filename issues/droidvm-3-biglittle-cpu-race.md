# [qemu] `-cpu host` on big.LITTLE: `Failed to put registers after init: Invalid argument` — no CPU-affinity option on the QEMU backend

## Environment

- Redmi Note 11T Pro+ (`xagapro`), MediaTek MT6895 = **big.LITTLE** (4×Cortex-A55 `0xd05` IDs 0-3, 4×Cortex-A78 `0xd41` IDs 4-7)
- Android 15, KernelSU root, kernel 5.10.247, KVM available (`/dev/kvm`)
- DroidVM `dev` `0.0.6.r240.g5c89691`, backend `qemu`, hypervisor `kvm`

## Summary

On a big.LITTLE host, the QEMU backend frequently fails outright with:

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

and sometimes:

```
qemu-system-aarch64: Failed to put registers after reset: Invalid argument
 PC=0000000000000000 X00=0000000000000000 ... PSTATE=400003c5 -Z-- EL1h
```

Because `QemuBackendInstance` hardcodes `-cpu host` and offers **no CPU-affinity parameter**, a user cannot work around it from the app.

## Steps to reproduce

Start any QEMU-backed VM repeatedly. Observed success rate on this device: **~40 % with `-cpu host,pmu=off`** (2 successes / 5 attempts), and 0 % in one later session (7 consecutive failures).

## Root cause

`-cpu host` enumerates the features of the **physical CPU the QEMU thread currently happens to run on**. While QEMU is programming the vCPU registers the scheduler migrates the thread between the A55 and A78 clusters; the feature set read at the start no longer matches what is written at the end, and `KVM_SET_ONE_REG` returns `EINVAL`.

Note also that `-cpu host` plus the generated `-smp 4,sockets=1,cores=2,threads=2` advertises SMT, which this SoC does not have (`smt` defaults to `true`).

## Proof that pinning fixes it (100 %, 6/6)

Using the same binary and the same arguments, only adding `taskset`:

| condition | result |
|---|---|
| unbound, 5 attempts | 2 ok / 3 failed |
| `taskset 1` (cpu0, A55 cluster) × 3 | **3/3 ok** |
| `taskset 80` (cpu7, A78) × 3 | **3/3 ok** |

With the binary wrapped as

```sh
#!/system/bin/sh
exec /system/bin/taskset f0 /data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64.real "$@"
```

the VM starts reliably and runs for minutes (one vCPU consuming ~100 % CPU, no `Failed to put registers`).

## Additional observation

With `-cpu host`, adding feature suppressions is **not** a reliable workaround — the outcome looks random rather than feature-dependent:

```
-cpu host                    → fail
-cpu host,pmu=off            → fail (60 %)
-cpu host,sve=off            → ok
-cpu host,pauth=off          → ok
-cpu host,sve=off,pauth=off  → fail
-cpu host,sve=off,pmu=off    → ok
-cpu max                     → fail
-cpu cortex-a55              → KVM is not supported for this guest CPU type
```

## Suggested fix

The crosvm backend already has `buildCpuPlacementCommand()`. Please give the QEMU backend an equivalent, or pin the QEMU process to one cluster by default on heterogeneous hosts, e.g.:

- add `-cpu` model selection (currently `cpu_model` is only honoured for the `soft` hypervisor), or
- apply a CPU affinity mask around the QEMU spawn (the crosvm path's `cpu_affinity` / `cpu_clusters` config already exists in the schema), or
- at minimum, default `smt` to `false` on arm64 so `-smp` becomes `threads=1`.

## Impact

The QEMU backend is unusable out of the box on any big.LITTLE Android device without an external wrapper around the app's binary.
