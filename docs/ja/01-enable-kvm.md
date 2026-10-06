# KVM を有効にする —— 完全な手順

[中文](../01-enable-kvm.md) | [English](../en/01-enable-kvm.md) | **日本語** | [Русский](../ru/01-enable-kvm.md)

> 目標：Android 上に `/dev/kvm` を出現させ、QEMU がハードウェアアクセラレーションを使えるようにする
> （使えないほど遅い TCG ソフトウェアエミュレーションではなく）。

**前提**：ブートローダーがアンロック済み + root 取得済み（KernelSU/Magisk）+ PC に adb と Python 3.10+。
**方針**：`tee_a` だけを変更し、`tee_b` は純正のまま（天然の保険）。

---

## 0. まず現状確認（読み取りのみ、リスクゼロ）

```bash
# KVM があるか
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'

# GZ 関連のノード（EL2 を誰が占有しているか分かる）
adb shell su -c 'ls -l /dev/gz* /dev/gunyah 2>&1'

# BL アンロック状態（0 = アンロック済み）
adb shell getprop ro.boot.flash.locked

# デバイスの型番
adb shell getprop ro.product.device
```

期待される結果（パッチ前）：

| チェック | 正常な結果 |
|---|---|
| `/dev/kvm` | `No such file or directory` |
| `/proc/misc` | 46 項目の中に **`kvm` は無い** |
| `/dev/gz_kree` | 存在する（char 10,99） |
| `/dev/gzvm` | 存在しない |
| `ro.boot.flash.locked` | `0` |

**説明**：MediaTek の **GenieZone（GZ）** ファームウェアが EL2 を占有しているため、
Linux が仮想化拡張を取得できず、カーネルは `/dev/kvm` を公開しません。
EL2 で動いている ATF を差し替えるのが唯一の道です。

---

## 1. デバイスの Secure Boot 状態を読む（署名が必要かを決める）

preloader は自分の判定結果をログに書き出し、それが **`expdb`** パーティションに残ります：

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M'
adb pull /data/local/tmp/expdb.img
# PC 側で探す：
grep -a -o "sbc_en = [01]" expdb.img | sort | uniq -c
grep -a -o "img_auth_required = [0-9]" expdb.img | sort | uniq -c
grep -a -c "cert vfy" expdb.img
```

本機（Redmi Note 11T Pro+）の実測：

```
    440  sbc_en = 1                      ← Secure Boot が有効
    220  [PART] img_auth_required = 1
     21  cert vfy(24 ms) / cert vfy(17 ms) / ...   ← 証明書検証が実際に走っている
```

**なぜこれが重要か**：

- SBC の値は **eFuse（OTP、一度だけ書き込み可能）** から読まれます —— 下の preloader 逆アセンブリ参照
- `sbc_en = 1` → **起動のたびに ATF の証明書チェーンが検証される**
- → **改変した ATF は MTK の署名を通す必要がある**。この工程は省略できません

```asm
; preloader 内の SBC 判定（これが「preloader を改変しても無駄」な理由）
0x020522FC  push   {r7, lr}
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; eFuse を読む
0x02052306  ubfx   r0, r0, #1, #1     ; SBC = bit 1
0x0205230A  pop    {r7, pc}
```

> **よくある誤解**：「エンジニアリング preloader を焼けば署名なしで起動できる」と考える人が多いですが、
> 実際にエンジニアリング preloader が免除するのは**書き込み**の認証だけです
> （`usbdl_verify_da` の戻り値が単に破棄される）。**起動時のイメージ検証は変わらず走ります**。
> 両者の違いは [appendix-atf-reverse.md](appendix-atf-reverse.md) を参照。

---

## 2. 純正パーティションのバックアップ（**絶対に省略しない**）

```bash
for p in tee_a tee_b lk_a lk_b preloader_raw_a seccfg; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/bk_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/bk_$p.img ./backup/$p.img
done

# ハッシュを記録（ロールバック時の照合用）
cd backup && sha256sum *.img | tee SHA256SUMS.txt
```

本機の純正 `tee_a` の sha256（対照用）：

```
f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   tee_a.img  (5242880 バイト)
```

**バックアップを失うとロールバックできません。** ワンクリックスクリプトは、バックアップに
失敗した時点で中止します。

---

## 3. デバイスから直接材料を dump する（ハッシュ一致を保証）

パッチツールは **TEE / LK の組み合わせが解析済みバージョンとハッシュ完全一致**することを要求します ——
したがって**ファームウェアパッケージを探し回らず、デバイスから直接 dump** してください：

```bash
for p in tee_a lk_a preloader_raw_a; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/dp_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/dp_$p.img ./dump/$p.img
done
```

---

## 4. ビルド + 署名

この工程では [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)（NoGZ
パッチツール）+ [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk)（署名ツール）を使います。

**詳しい原理と手順は [02-build-and-sign.md](02-build-and-sign.md)**。ここでは最小限のコマンドだけ：

```bash
# 環境
git clone https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
python -m venv .venv && .venv/bin/python -m pip install -r requirements.txt

# ビルド（new/legacy の署名モードを自動判別して pwnage を呼ぶ）
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    ../dump/tee_a.img \
  --lk     ../dump/lk_a.img \
  --preloader ../dump/preloader_raw_a.img \
  --tools  ../pwnage24mtk \
  --out-dir ../outputs/run-01
```

主要な出力：

```
outputs/run-01/
  tee_nogz_legacy.img     ← 署名済み成品（LEGACY モード時）
  tee_nogz_new.img        ← （NEW_PARSER モード時）
  verify.log  sign.log  cert-mode.txt  manifest.json
```

**`Result: VALID` が 2 回出ることを必ず確認**してください。出なければ焼かないこと。

### 4.1 「署名後にパーティションを超える」問題への対処

署名は ATF の**後ろ**に BIT STRING ラッパーを挿入するため、イメージがパーティションより
少しだけ大きくなります：

```
未署名 : 5 242 880    (= パーティションサイズ、ちょうど埋まる)
署名済 : 5 243 952    (+1072 バイト)
```

**要点**：挿入点は `atf` の後ろなので、**末尾 1.75 MB のゼロ埋めはまったく変化していません** →
**1072 バイトの末尾ゼロ埋めを切り落とせばちょうど 5 MiB になり、実データの損失はゼロ**です。

ワンクリックスクリプトはこれを自動で行い、しかも**切り落とす部分がすべて 0x00 であることを
1 バイトずつ確認してから**実行します：

```bash
# 手作業の場合（超えた部分がすべてゼロであることを確認した上で）
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
```

超えた部分に**非ゼロバイトが含まれる**場合は、レイアウトが想定と違います ——
**手を止めて人力で解析してください。無理に切らないこと**。

---

## 5. 書き込み

```bash
adb push tee_nogz_flash.img /data/local/tmp/
adb shell su -c 'sync'
adb shell su -c 'dd if=/data/local/tmp/tee_nogz_flash.img of=/dev/block/by-name/tee_a bs=4096'
adb shell su -c 'sync'

# 読み戻して検証（元ファイルのハッシュと一致しなければならない）
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

本機で成功したときの記録：

```
before : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   (純正)
dd 5242880 bytes, 0.019 s, 263 M/s
after  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689   (パッチ版)
```

> ⚠️ **SP Flash で tee を全書き換えしないこと** —— 全書き換えは BL を再ロックし、以降
> fastboot が不便になります。`dd` で直接書けば十分です（BL はアンロック済みなので
> `/dev/block/by-name/tee_a` は書き込み可能）。

### ロールバック方法（控えておく）

```bash
adb push ./backup/tee_a.img /data/local/tmp/tee_stock.img
adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
adb reboot
```

**B スロット**に切り替える手もあります（`tee_b` は未変更なので天然の保険）。

---

## 6. 再起動して検証

```bash
adb reboot
# 起動を待つ（初回は約 2 分かかります —— 落とし穴 12 を参照）
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

成功の印：

```
crw-rw-rw- 1 root root u:object_r:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        ← /proc/misc に出現（以前の 46 項目には無かった）
```

同時に、`expdb` から ATF が実機検証を通ったことも確認できます：

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
adb pull /data/local/tmp/e.img
grep -a "\[SBC\] image atf" e.img
# [SBC] image atf header auth pass      ← pwnage の証明書脆弱性が本機で成立
```

### 決定的な検証：実際にゲストを走らせる

システム内蔵の AVF `crosvm` で microdroid カーネルを起動します（最もクリーンな検証で、
サードパーティ製アプリに一切依存しません）：

```bash
adb shell su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

ゲストの出力：

```
Booting Linux on physical CPU 0x0 [0x412fd050]        ← Cortex-A55
GICv3: CPU0: found redistributor 0 region 0:0x3ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x1 [0x411fd411]     ← Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

→ **ATF → EL2 → VHE → KVM → 2 vCPU の Linux ゲストが完全起動。チェーン全体が閉じました。** ✅

---

## 7. 次のステップ

`/dev/kvm` が手に入ったら：

- **Windows 11 ARM64 を入れる** → [03-windows-vm.md](03-windows-vm.md)
- **QEMU の使い方と調整** → [04-usage.md](04-usage.md)
- **問題が起きたら** → [05-gotchas.md](05-gotchas.md)

---

## 付録：QEMU になぜ `taskset` のコア固定が必要か

MTK の big.LITTLE（4×A78 + 4×A55）では、QEMU の `-cpu host` は**その時点で動いている CPU** の
機能を列挙します。vCPU レジスタを書いている最中にスケジューラが A55/A78 間でマイグレーション
させると、こうなります：

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

実測（同じコマンドを 5 回連続）：

| 条件 | 成功率 |
|---|---|
| コア固定なし | **2/5** ✗ |
| `taskset 1`（cpu0、A55） | **3/3** ✓ |
| `taskset 80`（cpu7、A78） | **3/3** ✓ |
| `taskset f0`（cpu4-7、A78 クラスタ全体） | **3/3** ✓ |

**したがって起動スクリプトではコア固定が必須です**（本プロジェクトは `taskset f0` で速い
A78 クラスタに固定）。DroidVM 自身の QEMU バックエンドにはこのオプションが無いため、
ラッパーで包んでいます —— [04-usage.md](04-usage.md) を参照。
