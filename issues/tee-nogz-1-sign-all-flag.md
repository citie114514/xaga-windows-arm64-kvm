# `scripts/build.py` calls an undefined `sign_all_flag()` — the signing path always raises `NameError`

## Summary

`scripts/build.py:340` calls `sign_all_flag(args.tools)`, but **no such function is defined anywhere in the file** (383 lines). `--check-only` returns before that line, so the offline regression works and the defect is invisible until someone actually signs.

```python
# scripts/build.py, in main()
    unsigned, final = args.out_dir / "tee.unsigned.img", args.out_dir / f"tee_nogz_{mode}.img"
    unsigned.write_bytes(patch(source, p, 512))
    all_flag = sign_all_flag(args.tools)          # <-- NameError
    run_tool(args.tools, "sign_mtk_cert.py",
             [unsigned, *flags, *all_flag, "-w", "-o", final], args.out_dir / "sign.log")
```

Reproduction (any matching firmware, `--check-only` omitted):

```bash
python scripts/build.py --profile <p> --tee tee.img --lk lk.img \
  --preloader preloader.bin --tools ../pwnage24mtk --out-dir outputs/run-01
# NameError: name 'sign_all_flag' is not defined
```

## Suggested fix

The obvious intent is "does this `sign_mtk_cert.py` accept `--all`?". For the public `pwnage24mtk` (kasnria001) the CLI is

```
usage: sign_mtk_cert.py [-h] [-w] [-o OUT] [--legacy] image
```

i.e. **no `--all`**, so the flag list must be empty. A robust version would probe it, e.g.

```python
def sign_all_flag(tools):
    """`--all` exists only in newer sign_mtk_cert.py builds."""
    out = subprocess.run([sys.executable, str(tools / "sign_mtk_cert.py"), "--help"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         encoding="utf-8", errors="replace").stdout
    return ["--all"] if "--all" in out else []
```

and the failure should be a clear `require(...)` message rather than a bare `NameError`.

## Verified working path with the patch applied externally

Signing `xaga`-class ATF with `pwnage24mtk` works fine once the call is made directly, so this really is only the missing helper:

```bash
python sign_mtk_cert.py tee.unsigned.img --legacy -w -o tee_nogz_legacy.img
python verify_mtk_image.py --all tee_nogz_legacy.img     # -> 2 x "Result: VALID"
```

One related gotcha worth documenting: the signed image grows (here **+1072 bytes**, the legacy BIT STRING wrapper plus the widened CERT2). Appending happens **after the ATF member**, so member offsets shift while the trailing zero padding is unchanged; truncating back to the partition size (verified all-zero) gives a flashable image.

## Extra: an `xagapro` profile would be useful

I reverse-engineered a profile for the **Redmi Note 11T Pro+ (`xagapro`, 22041216UC)**, which is a different SKU from `xaga` and whose `tee`/`lk` hashes therefore do not match any shipped profile. The offsets were derived by locating the same instruction shapes the shipped profiles use, and the **full 14-check regression passes** against the real device firmware (including the four negative controls):

```
tee_sha256 = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_sha256  = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3

pc_patch 0x1ade0  kernel_patch 0x64a4  getter 0xe560  callback 0xde7c  flag 0x44f00
cold [0x1adb8,0x1ae3c]  cold_helpers [0xb6bc,0xb6d4]  ep 0x52930
kernel_args 0x529e0  handoff_global 0x52af0
tag_parser [0x6688,0x68f0]  args_getter [0xb7d0,0xb800]
lk_* (all) identical to the `xaga` profile
```

End-to-end result on hardware: `sbc_en = 1`, `[SBC] image atf header auth pass`, `/dev/kvm` appears, and a 2-vCPU Linux guest boots under KVM. I can open a PR with the profile if you want it — it needs the audit you describe in `references/adaptation.md`, but the regression is the same one your CI already runs.
