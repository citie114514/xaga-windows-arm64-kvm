# Tools for locating profiles for new firmware

**English** | [中文](README.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

For a device that already has a profile but a different firmware batch, these **re-locate the
offsets**. The core idea: **don't guess by shifting bytes around — search the new binary using
the "instruction skeleton" known from the old profile's positions.**

## Scripts

| Script | Purpose |
|---|---|
| `find-new-offsets.py` | Uses the 16-byte instruction sequence at each old-profile field as a fingerprint, searches it in the **new ATF**, and prints the block-by-block similarity distribution between the two ATF builds |
| `find-getter.py` | Disassembles the getter region of the old/new ATF so you can inspect the context around anchors like `0xD00001A8` one by one |
| `match-lk2.py` | **The workhorse**: linearly disassembles the LK once, **normalizes** PC-relative operands (`bl`, `adrp`, …) into placeholders, then slides a window comparing instruction skeletons. This sidesteps the trap where a function moves, the `bl` encoding changes, and every byte fingerprint becomes useless |
| `find-lk-offsets.py` | An earlier version (byte-level fingerprints), kept for comparison — *why* it fails is instructive |
| `verify-patch-diff.py` | Offline check for a NoGZ patch: compares the diff regions of a patch against its base with those of an already-verified patch, to confirm both came out of the same pipeline ("isomorphism") |

## Real workflow (this is exactly how we did it — about 1–2 hours)

```
1) Dump the new firmware off the device: tee_a / lk_a / preloader_raw_a
2) Extract the ATF member from tee (offset 0x200, length 283016)
3) Run find-new-offsets.py:
     each field of the old profile -> search its 16-byte fingerprint in the new ATF
     hit AND offset close (±0x100) -> adopt directly
4) Run match-lk2.py: locate all the lk_* offsets
5) Write the result out as a new profile, swap in the new hashes, merge into profiles.json
6) Run build.py --check-only -> must be 14/14
7) Run the full build (--preloader + --tools) -> signature check must be 2 × Result: VALID
```

## Actual data from this project (Redmi Note 11T Pro+, two firmware batches)

**ATF**: the new firmware's offsets are **identical to upstream `xaga`** (7 exact hits) —
even though the two ATFs are only **29.5% identical byte-for-byte** (different builds, but the
**function layout is the same**).

**LK**: **83.86% identical byte-for-byte**; of its 11 fields:

```
9 offsets unchanged    0x28D4 / 0x2904 / 0x39C8 / 0x3A6C / 0x1A7A0 / 0x1A7CC / 0x3A18 / 0x14CAC / 0x14D40
2 shifted by −0x90     lk_getter   0x1E8A8 -> 0x1E818
                       lk_callback 0x1E8BC -> 0x1E82C
```

## Dependencies

```bash
python -m venv .venv
.venv/Scripts/python.exe -m pip install capstone unicorn
```

## Traps we hit

| Trap | Explanation |
|---|---|
| **Byte fingerprints are useless on LK** | `bl`/`adrp` are PC-relative, so any function move changes the encoding → you must **normalize the instruction skeleton** before comparing (`match-lk2.py` does exactly this) |
| **`md.skipdata = True` is mandatory** | The LK file starts with a header, not code; without this flag Capstone stops immediately (disassembles exactly 1 instruction ✗) |
| **Profile values must be strings** | `build.py` does `int(v, 0) if v.startswith("0x")` → writing an integer raises `AttributeError` ✗ |
| **Upstream `sign_all_flag` bug** | `build.py` passes `--all` to `sign_mtk_cert.py`, but that script has no such flag → `sign_all_flag()` must return `[]` (see [issues/](../issues/)) |
