# Build and sign — the steps explained

**English** | [中文](../02-build-and-sign.md) | [日本語](../ja/02-build-and-sign.md) | [Русский](../ru/02-build-and-sign.md)

This page explains: **what the NoGZ patch actually changes**, **how to build it**, **how to sign it**
and **how to verify it**.

> The tool is [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) (upstream).
> This project's one-click script merely strings it together with "flashing + verification".
> Upstream explicitly states: **it ships no firmware, no flashable images, and its scripts do not
> flash anything** — this project supplies that half.

---

## 1. What the patch actually changes

It changes the **boot handover logic of the `atf` member** inside `tee.img`. The target state is:

> **Keep LK entering EL1h and the AArch64 kernel handing over to EL2h**, and **synchronise the
> GZ-info tag shared between ATF and LK**.

Upstream keeps three kinds of "wrong approach" as counter-examples (which is why you shouldn't
hand-patch this yourself):

| # | Counter-example | Explanation |
|---|---|---|
| 1 | `D2A21E08` actually loads `0x10f00000`, not LK's `0x50f00000` | The correct encoding is **`D2AA1E08`** |
| 2 | The original LK's EL2 entry path **accesses `CPTR_EL3`** | So you **cannot** force both LK's and the kernel's entry level to EL2h |
| 3 | Only changing ATF's GZ getter **does not** automatically change LK's state | You must **synchronise the shared tag**, otherwise the GZ unmap path is still taken later |

**The key point**: the patch **preserves GZ's memory reservation and remapping** and **does not claim
to return that memory** — it only makes EL2 usable by Linux (and thereby exposes `/dev/kvm`).

---

## 2. Setting up the environment

**Python 3.10+**, ideally in its own virtual environment.

Linux / macOS:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

Windows PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

The dependencies are **Capstone** (disassembly) and **Unicorn** (emulated execution) — both are for
offline analysis and need neither a device nor a network.

**You also need** (not distributed with the repository, prepare it yourself):

- The complete **`pwnage24mtk`** tool directory (containing `sign_mtk_cert.py` / `verify_mtk_image.py`)
- **Firmware matching your device**: `tee.img` / `lk.img` / `preloader.bin`
  → dumping straight from the device is the most reliable (see section 3 of [01-enable-kvm.md](01-enable-kvm.md))

---

## 3. Model matching (you must get past this first)

The tool matches TEE/LK pairs by **full SHA-256**, **not** by model name or file size:

| Profile | Target sample |
|---|---|
| `xaga` | Redmi Note 11T Pro / Pro+ (MT6895) **← the device this project measured on** |
| `peral` | Xiaomi 13T |
| `yunluo` | An already-analysed yunluo TEE/LK pair |

> **The same model name, a close firmware version, or matching file sizes are no substitute for a
> hash match.** So always **dump from the device itself**; don't go hunting for a "same model"
> firmware package online.

The full hashes and address definitions live in the tool repository's `references/profiles.json`.

```bash
# Compute the hash of what you dumped and compare it against profiles.json
sha256sum dump/tee_a.img dump/lk_a.img
```

---

## 4. Step one: offline check only (no signing, no output)

Run `--check-only` first to confirm the TEE/LK pair matches and the patch regressions pass:

Linux / macOS:

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    "$HOME/private-firmware/xaga/tee.img" \
  --lk     "$HOME/private-firmware/xaga/lk.img" \
  --check-only
```

Windows:

```powershell
$inputDir = Join-Path $HOME 'private-firmware\xaga'
.\.venv\Scripts\python.exe scripts/build.py --profile xaga `
  --tee "$inputDir\tee.img" --lk "$inputDir\lk.img" --check-only
```

What `--check-only` does:

- ✅ Runs the offline TEE/LK patch regression (PC/SPSR, the real ATF/LK tag parsers, shared flags, the GZ gate, and deliberately constructed counter-examples)
- ❌ Does **not** detect the signing mode, **not** produce an image, **not** invoke pwnage

**What the offline regression covers** (our report shows **14/14 passed**):

| Check | Result |
|---|---|
| PC / SPSR state | ✓ |
| ATF tag parser | ✓ |
| LK tag parser | ✓ |
| Shared flags | ✓ |
| GZ gate | ✓ |
| Deliberately constructed counter-examples (must be rejected) | ✓ |

> ⚠️ The "14 records" in the report are **bounded check records, not 14 whole-device boot tests**.
> Offline `VALID` ≠ the device will boot.

---

## 5. Step two: detect the preloader's signing mode

The signing method **depends on the preloader's certificate traversal mode**, so confirm it with the
detector bundled in the tool:

```bash
.venv/bin/python scripts/detect_pl_cert_mode.py \
  "$HOME/private-firmware/xaga/preloader.bin" --json
```

By default the full evidence (including disassembly) is written to a new file under `logs/`, which is
git-ignored.

| Detection result | Corresponding pwnage argument |
|---|---|
| **`new`: `NEW_PARSER`** | **Add no mode argument** (neither `--legacy` nor a `--new`) |
| **`legacy`: `LEGACY`** | **Add `--legacy`** |
| `NEED_MANUAL` / unsupported / ambiguous | **Stop and analyse by hand**; don't guess by model |

> On this device (Redmi Note 11T Pro+) it measured **`LEGACY`**, so `--legacy` applies.
>
> Note that "new adds nothing" means **no extra mode option** — not that you omit the input files and
> write options. The normal `--all -w -o` still applies.
>
> The detector is **static evidence analysis**; it is not the efuse state, the exploitability of the
> vulnerability, or an on-device boot verification.

---

## 6. Step three: build the signed copy

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee       "$HOME/private-firmware/xaga/tee.img" \
  --lk        "$HOME/private-firmware/xaga/lk.img" \
  --preloader "$HOME/private-firmware/xaga/preloader.bin" \
  --tools     ../pwnage24mtk \
  --out-dir   outputs/xaga-run-01
```

**Things to watch out for**:

- `--preloader` is required (the signing mode is tied to it); the script invokes the detector
  automatically, so **you don't choose the mode by hand**
- The preloader's hash is recorded in the manifest, but **the script cannot prove from the filename
  alone that it matches what the device actually uses**
- `--out-dir` **must be a new, non-existent directory** — use a new one for a rerun, **don't overwrite
  old results**, and above all **don't feed a signed artefact back in as input**

### Output layout

```text
outputs/xaga-run-01/
  cert-mode.txt          # full detection evidence
  detect.log             # detector JSON output or error
  tee.unsigned.img       # intermediate file (NOT the signed result!)
  tee_nogz_legacy.img    # in LEGACY mode -> this is the result
  # tee_nogz_new.img     # in NEW_PARSER mode it's this one
  sign.log
  verify.log
  disassembly.txt
  manifest.json
```

**Success cannot be judged by the mere existence of an `.img`** — look at **the exit code, the full
logs, and manifest.json**.

---

## 7. Step four: verify the signature (two VALIDs required)

```bash
cd ../pwnage24mtk
python verify_mtk_image.py --all ../outputs/xaga-run-01/tee_nogz_legacy.img
```

**You must see two `Result: VALID` lines** (the ATF group and the TEE group):

```
Result: VALID
Result: VALID
```

Measured here:

| Check | Result |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`** ✓ |
| CERT1 / CERT2 signature | OK ✓ |
| Image header hash / Image data hash | OK ✓ |
| Whether the `tee` member was modified | **not modified** ✓ |
| ATF vs. re-patching result | **byte-for-byte identical** ✓ |
| The official 14-item regression | **14/14 passed** ✓ |

**Unverified item (stated honestly)**: `Trusted root check: skipped`
→ Comparing this certificate chain against the device's eFuse trust root **cannot be verified
offline**; only a real boot proves it.

> This relies on a **third-party tool's certificate handling**. It does not imply possession of the
> vendor's private key, nor any new official authorisation. The mechanism is a flaw in MTK's ASN.1
> certificate parsing (same class as CVE-2023-20696, only fixed in CVE-2025-20730).

---

## 8. Step five: dealing with "1072 bytes over the partition"

This was **this project's biggest trap**, and it must be handled:

```
unsigned : 5 242 880   (= tee partition size, exactly fills it)
signed   : 5 243 952   (+1072)
```

The increase comes from a **BIT STRING wrapper (987 B)** plus **CERT2 dsize going 982→2059 (aligned to 2064)**.

**But the insertion point is after `atf`, so the trailing zero padding is completely unchanged:**

| Member | unsigned | signed |
|---|---|---|
| `atf` | 0x200 | 0x200 (**unchanged**) |
| `tee` | 0x46440 | 0x46870 (+1072) |
| `cert1` | 0x353a40 | 0x353e70 (+1072) |
| `cert2` | 0x354310 | 0x354740 (+1072) |
| **trailing zero padding** | 1 751 322 | **1 751 322 (unchanged)** |

There are **1.75 MB of zeros** at the tail → **trimming 1072 bytes of zero padding yields exactly
5 MiB with zero real data loss**.

```bash
# First confirm byte by byte that the excess is all 0x00
python - <<'PY'
data = open('tee_nogz_legacy.img','rb').read()
tail = data[5242880:]
print('excess bytes:', len(tail), ' non-zero bytes:', sum(1 for b in tail if b))
PY

# Only after confirming it's all zeros, trim
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
sha256sum tee_nogz_flash.img
```

**If the excess contains non-zero bytes → stop and analyse by hand; do not force a trim.**

The one-click script does this automatically, and **insists on verifying all-zeros before trimming**.

---

## 9. Step six: flash and verify on the device

This part is covered in sections 5 and 6 of [01-enable-kvm.md](01-enable-kvm.md):

```
dd into tee_a  ->  read back and compare sha256  ->  reboot  ->  /dev/kvm appears
                                                      \-> expdb shows [SBC] image atf header auth pass
```

**Reference values for the finished artefacts** (Redmi Note 11T Pro+):

| File | Size | sha256 |
|---|---|---|
| `tee_nogz_legacy_5M.img` (patched, trimmed to partition size) | 5 242 880 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `tee_a.img` (stock, for rollback) | 5 242 880 | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

---

## 10. Want to adapt this to another MTK model?

Upstream requires that **a new version supply a complete SHA-256 pair**; see `references/adaptation.md`.

> **Do not bypass the version check by editing existing hashes or deleting assertions.**

Rough process:

1. Dump `tee` / `lk` / `preloader` from the target device
2. Compute the SHA-256 and compare against the analysed samples in `references/profiles.json`
3. If nothing matches → you need to **add a new profile** per `references/adaptation.md` (which means
   understanding ATF/LK offsets and instructions)
4. Run the `--check-only` regression → then go through the signing flow

**The same model on a different firmware version may not match either** — this is an
"exact firmware sample" level tool; there is no room for fuzzy matching.

---

## 11. Verification boundaries (must read)

The boundaries upstream explicitly lists, quoted for clarity (important — don't over-interpret):

- The known-image regression checks PC/SPSR, the real ATF/LK tag parsers, shared flags, the GZ gate and deliberately constructed counter-examples.
- The 14 records in the report are **bounded check records, not 14 whole-device boot tests**.
- CPU features, CurrentEL, some system registers and cache maintenance are **explicitly modelled**;
  full LK initialisation, Linux, a real ERET, PSCI and peripherals are **not executed**.
- If offline signature verification reports `Trusted root check: skipped`, **the device trust root is still unverified**.
- CI contains no real firmware and **cannot replace** the known-image regression of `build.py --check-only`, still less **prove hardware compatibility**.

**When reporting, state separately**: the identity of the inputs, the offline results, the actual
device feedback, and the unverified items.

---

## 12. A known bug in the upstream tool (we filed a PR)

`scripts/build.py:340` calls `sign_all_flag(args.tools)`, but **that function is not defined anywhere
in the file** → the signing path necessarily raises `NameError`. `--check-only` returns early, so it
never surfaced.

(Also: `sign_mtk_cert.py` itself has no `--all` argument, so that function should simply return `[]`.)

The fix is in [issues/tee-nogz-1-sign-all-flag.md](../issues/tee-nogz-1-sign-all-flag.md).
