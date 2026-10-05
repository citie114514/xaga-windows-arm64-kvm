`main()` calls `sign_all_flag(args.tools)` at line 340, but the function is not defined anywhere in `scripts/build.py` (383 lines). Every run that reaches the signing step therefore dies with:

```
NameError: name 'sign_all_flag' is not defined
```

`--check-only` returns before that line, so the offline regression is unaffected and the defect only shows up when someone actually signs.

## The fix

Add the helper. `--all` is not optional for the `sign_mtk_cert.py` this project is written against — `docs/technical-guide.md` already specifies `--all -w` for `NEW_PARSER` and `--legacy --all -w` for `LEGACY`, and `tests/test_cert_mode.py:119` asserts exactly that:

```python
self.assertEqual(sign_args[1:-1], [*flags, "--all", "-w", "-o"])
```

so the implementation keeps the call site as it is and returns `["--all"]`. The helper stays a named hook (instead of inlining the literal) so that a tool copy which does not accept the option can be handled in one place later.

## Verification

```
$ python -m unittest discover -s tests
Ran 28 tests in 1.224s
OK
```

Both failures that existed before the change (`test_cert_mode.SigningModeTests.test_orchestration_uses_detected_mode_not_profile` for `NEW_PARSER` and `LEGACY`) now pass.

## Out-of-tree confirmation with the public tooling

Independently of the test suite, the signing step was exercised end to end against a real device firmware (`xagapro`, see below) using the public `pwnage24mtk` copy:

```bash
python sign_mtk_cert.py tee.unsigned.img --legacy -w -o tee_nogz_legacy.img
python verify_mtk_image.py --all tee_nogz_legacy.img     # -> 2 x "Result: VALID"
```

Two notes from that run that may be worth a line in `docs/technical-guide.md`:

1. The public `pwnage24mtk` `sign_mtk_cert.py` CLI is `[-h] [-w] [-o OUT] [--legacy] image`, i.e. it has **no** `--all`. Users of that copy need one that accepts the option (or a small change here).
2. The signed image grows — `+1072` bytes in this case (the legacy BIT STRING wrapper plus the widened CERT2). The insertion happens **after the ATF member**, so the following member offsets shift by that amount while the trailing zero padding is untouched. Truncating back to the partition size (having verified the removed tail is all zeros) yields an image that is exactly 5 242 880 bytes and still verifies with two `VALID` groups.

## Offer: an `xagapro` profile

This work also produced a profile for the **Redmi Note 11T Pro+ / `xagapro` (22041216UC)**, a different SKU whose `tee`/`lk` hashes match none of the three shipped profiles. The offsets were located from the same instruction shapes the existing profiles use, and the repository's own 14-check regression passes on the real firmware, negative controls included:

```
tee_sha256 = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_sha256  = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3

pc_patch 0x1ade0        kernel_patch 0x64a4      getter 0xe560       callback 0xde7c
flag 0x44f00            ep 0x52930               kernel_args 0x529e0  handoff_global 0x52af0
cold [0x1adb8,0x1ae3c]  cold_helpers [0xb6bc,0xb6d4]
tag_parser [0x6688,0x68f0]  args_getter [0xb7d0,0xb800]
lk_* — identical to the shipped `xaga` profile in every field
```

On hardware the patched and re-signed ATF is accepted (`sbc_en = 1`, `[SBC] image atf header auth pass`), `/dev/kvm` appears, and a 2-vCPU Linux guest boots under KVM.

Happy to send that as a separate PR if you want it — it needs the audit described in `references/adaptation.md`, but PR CI runs the same regression.
