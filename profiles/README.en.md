# Firmware profiles

**English** | [中文](README.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

`mtk-mod-tee-nogz` uses a **profile** to locate the positions inside ATF/LK that need patching.
A profile matches its input by **full-file SHA-256**, so it works at the level of an
*exact firmware sample* — **the same device model on a different firmware batch needs a
different profile.**

## Files in this directory

| File | Base `tee` | Base `lk` | Notes |
|---|---|---|---|
| `xagapro.json` | `f8f286f1…` | `8cbaa2e8…` | Reverse-engineered by us. Corresponds to **rk's package**, and is also the **shared `tee_b` base of both devices** |
| `shuilanA15.json` | `a91f5ded…` | `a17d87c6…` | Reverse-engineered for **ShuiLan's A15 (pearl port)** — see `tools/` for the method |

> `shuilanA15.json` also keeps the original upstream `xaga` entry (renamed to
> `xaga_upstream`) so the two can be compared.

## How to use

Merge these entries into `mtk-mod-tee-nogz`'s `references/profiles.json`, then build
according to [docs/02-build-and-sign.md](../docs/02-build-and-sign.md).

⚠️ Note: `build.py`'s `--profile` argument is **hardcoded to three choices**
(`yunluo`/`peral`/`xaga`) ✗ — so to add a new model you either overwrite the `xaga` entry
(which is what this project does) or edit `choices`.

## Building a profile for new firmware

See [`tools/README.md`](../tools/README.md) — it documents the method we actually used:
**instead of reversing from scratch, re-locate the instruction anchors of the old profile
inside the new binary.**

Actual measurement: a new firmware's ATF had **7 offsets identical to upstream**, and its
LK had **10 of 11 identical (only 2 shifted by −0x90)** —
**this takes one to two hours**, not "a multi-day project".
