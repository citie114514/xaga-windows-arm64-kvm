# preloader_raw_a.img リバース結論

[中文](../appendix-atf-reverse.md) | [English](../en/appendix-atf-reverse.md) | **日本語** | [Русский](../ru/appendix-atf-reverse.md)

ファイル：`D:\Administrator\下载\preloader_raw_a.img`
サイズ：4 190 208 バイト（0x3FF000）
sha256：`056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1`

## 0. 最も重要な結論（先に）

**このファイルは、スマホが現在実行している preloader とバイト単位で同一です。**
（デバイスの `preloader_raw_a` パーティションを dump したものの sha256 も `056ed47a…`）

→ これを書き込んでも**何も変わりません**。もし本当に「認証不要のエンジニアリング版」なら、
この端末は**今すでにそれを動かしている**ことになります。

## 1. コンテナ構造

```
0x0000  MMM\x01  len=0x38  "FILE_INFO"
0x0038  MMM\x01  len=0x0C  type=1  val=1
0x0044  MMM\x01  len=0x64  type=7  val=0x90
0x00A8  MMM\x01  len=0x14  type=2  val=0
0x00BC  MMM\x01  len=0x30  type=8  val=0
0x00F0  ← コード開始
```
ヘッダフィールド（`parse_hdr`）：
```
load = 0x02000F10   size = 0x0007A0B0   header = 0xF0   ida = 0xF0
ランタイムベース base = 0x02001000、コード 0xF0 .. 0x7A1A0
イメージ後の 0x384E60 バイトはすべて 0x00 埋め
```

## 2. SBC（Secure Boot Control）の出所 —— 決定的な証拠

```
0x020522FC  push   {r7, lr}
0x020522FE  mov    r7, sp
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; efuse 読み出し
0x02052306  ubfx   r0, r0, #1, #1     ; bit 1 を取得
0x0205230A  pop    {r7, pc}
```

**SBC は実行時に eFuse から読み出されます**（word 0x1F の bit 1）。
eFuse は OTP で一度だけ書き込まれ、**preloader を変えても変えられません**。

## 3. 検証ロジックは「条件付き実行」であり「バイパス」ではない

呼び出し側（0x0204FA0E）：
```
0x0204FA14  bl     #0x020522FC        ; r0 = sbc_en
0x0204FA18  mov    r1, r0
0x0204FA1A  movw   r0, #0x7528        ; "sbc_en = %d"
0x0204FA22  bl     #0x02045C74        ; sbc_en を出力
0x0204FA26  bl     #0x020522FC        ; もう一度読む
0x0204FA2A  cbz    r0, #0x0204FA5C    ; sbc_en == 0 → 検証を丸ごとスキップ
0x0204FA2C  movw   r0, #0x7535        ; "sbc_en = 1"
0x0204FA34  bl     #0x02045C74        ; 出力
...                                    ; 証明書チェーン検証へ進む
```

これは**正常なリテール ロジック**です：SBC が焼かれていない端末は検証をスキップし、
焼かれている端末は検証します。`movs r0,#0` / `bx lr` のようなハードコードされたバイパスはありません。

## 4. 証明書チェーン / イメージ検証のコードは完全に存在する

```
0x020407F0  ...  img_auth メインロジック
   0x0204083C  ldr r0, [pc,#...]  → "img_auth_required = %x"
   0x020408D2  →                  "cert chain vfy fail..."
   0x020408F0  bl #0x0200E368     ; 実際の検証入口（0 を返せば通過）
   0x0204086E  mov.w r8, #-1      ; 失敗時の戻り値

0x0204E888  img auth fail 経路 → "img auth fail(0x%x)"
0x0204FE22  0x020676AD → "seclib_img_auth_load_sig"
```
さらにイメージには MTK の証明書 OID とアルゴリズムが含まれます：
```
2.16.886.2454.1.1 / .1.2 / .1.3 / .2.1 ... .3.2   ; 2.16.886 = TW, 2454 = MediaTek
1.2.840.113549.1.1.1   ; rsaEncryption
1.2.840.113549.1.1.10  ; RSASSA-PSS
V.Mon May 30 17:26:17 2022   ; 証明書ストアのバージョン文字列
```

## 5. DA 検証（usbdl_verify_da）も完全で、短絡は無い

関数 `0x0201144C` の内部には：
- DA 長チェック（`da_len < sig_len` のエラー出力）
- DA 型バイトに対するジャンプテーブル ディスパッチ（`sub.w r1, r0, #0xC4; cmp r1, #0x23; tbh [pc, r1, lsl #1]`）
- 特殊値 `0xFE` の分岐
- 失敗時の `#-1` などの戻り値

**「即座に成功を返す」短絡分岐はありません。**

## 6. ビルドの由来

文字列内のソースパス：
```
/home/work/mnt/miui_codes2/build_home_rom-vext-merged/vendor/mediatek/
  proprietary/bootable/bootloader/preloader/platform/mt6895/src/...
```
ビルド時刻：`20230918-112001`（2023-09-18 11:20:01）

→ これは**小米 MIUI ビルドファームのリテール ビルド**です。MTK 自身の工場エンジニアリング版は
MTK 内部のビルドサーバー由来で、パスの形が異なります。

---

## まとめ：静的解析で分かること / 分からないこと

| 問い | 静的に答えられるか | 結論 |
|---|---|---|
| これはリテール preloader か | ✅ 可能 | はい（小米の build farm + efuse からの動的 SBC 読み） |
| コード内に検証無効化のハードコードがあるか | ✅ 可能 | **無い**。検証は条件付き実行 |
| 検証関数が削除 / stub 化されているか | ✅ 可能 | **無い**。一式そろっている |
| **この端末で検証が有効かどうか** | ❌ **不可能** | eFuse word 0x1F bit 1 が決める。実測が必須 |

## 一撃で決まる実測（リスクゼロ、読み取りのみ）

preloader 自身が結果をログに書き出します：

```
0x0204FA1A  "sbc_en = %d"      → ログに "sbc_en = 0" か "sbc_en = 1" が現れる
```

そして preloader のログは **`expdb` パーティション**（本機では 128 MiB）に落ちます。

```bash
adb shell su -c "dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M"
adb pull /data/local/tmp/expdb.img
grep -a -o "sbc_en = [01]" expdb.img
```

さらに `seccfg`（MTK のロック状態パーティション。イメージ内の
`[SEC_POLICY] lock_state = 0x%x` の出力に対応）を読んで `lock_state` を確認できます。

## 補足：tee の書き込みは実は「認証不要」に依存しない

- BL はアンロック済み（`ro.boot.flash.locked=0`）→ **fastboot で `tee_a` を直接書ける**
- ただし **preloader は ATF 起動時に ATF の署名を検証します**（SBC が有効な場合）
- したがって改変版 tee を起動できるかを決めるのは、やはり **eFuse の SBC**

---

# 実機検証結果（2026-10-05、読み取りのみ）

## A. この端末の Secure Boot は**有効**（実測であり推測ではない）

`expdb`（preloader 起動ログ パーティション、128 MiB）から直接読んだ原文：

```
   440  sbc_en = 1                  ← preloader 自身が算出した SBC 値
   220  [PART] img_auth_required = 1
     5  img_auth_required = 0
    21  [SEC_POLICY] lock_state = 0x3
    21  cert vfy(24 ms)  / cert vfy(17 ms) / ...   ← 証明書検証が実際に走り成功した
    12  part: lk_a img: aee
    10  part: lk_a img: bl2_ext
    10  part: gz_a img: unmap2
    10  part: gz_a img: gz
```

`seccfg` パーティションの生データと完全に対応します：

```
00000000: 4d4d4d4d 04000000 3c000000 03000000   MMMM....<.......
00000010: 00000000 00000000 45454545 b4c9b88a
00000020: 255a1745 17c0c5f6 85315e9e c48e00f7
00000030: c8965b9d a1ed3100 cf79a983 00000000
                    ↑ 0x0C = 0x03  ← ログの lock_state = 0x3 と一致
         オフセット 0x18..0x38 は 32 バイトの seccfg ハッシュ
```

**推論**：`sbc_en = 1` かつ `img_auth_required = 1` なので、
改変した ATF は**MTK の証明書検証を通らなければ起動できません** →
**pwnage 署名（LEGACY モード）は必須の工程で、省略できません。**

## B. DroidVM の GenieZone 路線は本機では不可能

```
/dev/gunyah   → 存在しない
/dev/kvm      → 存在しない（EL2 を GZ が占有）
/dev/gz_kree  → 存在する（char 10,99）  ← GZ の KRE サービス インターフェース
/dev/gzvm     → 存在しない              ← crosvm/DroidVM が必要とする VM インターフェース
```

`VMHypervisor.GENIEZONE` が探すのはまさに `/dev/gzvm` です。本機には旧世代の GZ しかなく、
`isBackendSupported` では QEMU が GENIEZONE をサポートしません（サポートするのは crosvm のみ）。
→ **DroidVM は KVM バックエンドしか使えず、つまり tee を焼く必要があります。**

## C. 提供された preloader は役に立たない

それはデバイスが現在実行している版と同じ（バイト単位で同一）で、その SBC 判定は eFuse を読みます：

```asm
0x020522FC  movs r0, #0x1F          ; efuse word 31
0x02052302  bl   #0x02054860        ; efuse 読み出し
0x02052306  ubfx r0, r0, #1, #1     ; SBC = bit 1
```

したがって**検証をスキップしません**。「検証なしで起動」に必要なのは、eFuse を読まないように
人為的に改変された別の preloader です。

## D. まだ切り分けられていない点（正直に明記）

preloader の明示的な検証ログが名指しするのは `lk_a`(aee/bl2_ext) と `gz_a`(gz/unmap2) のみで、
**`tee_a`/`atf` は直接現れません**。一方 `bl2_ext` の内部には
`[BL31] load failed` + `atf` + `vm-BL31-reserved` などの文字列があり、ATF のロードが
`bl2_ext` 段階で起きていることを示します。ATF を具体的に誰が検証するのか、検証するのかは、
今回は切り分けられませんでした。

→ `sbc_en=1` を前提に**「検証される」ものとして扱う**のが安全な仮定です。

## E. 相互検証：これらのログは確かに現在のこの preloader のもの

expdb に現れる preloader のビルドスタンプは**1 つだけ**です：

```
  10  Build Time: 20230918-112001
  10  20230918-112001          （他のバージョンのビルドスタンプは一切無い）
```

そして現在のイメージに埋め込まれたビルドスタンプも `20230918-112001`
→ それらの `sbc_en = 1` / `cert vfy(24 ms)` ログは**旧版の残留ではなく**、
このエンジニアリング preloader 自身が出力したものです。

## F. エンジニアリング preloader の「エンジニアリング」な点：DA/EDL 経路

`usbdl_verify_da`（0x0201144C）の呼び出し点は、イメージ全体で**1 か所だけ**：0x02032B86。

```asm
0x02032B68  ldrb.w  r0, [r8]        ; 受信したバイト
0x02032B6C  cmp     r0, #0xA0       ; 0xA0 のときだけ DA とみなす
0x02032B6E  bne     #0x2032B96
...
0x02032B80  add     r0, sp, #0x1c
0x02032B82  mov.w   r1, #0x12c
0x02032B86  bl      #0x201144C      ; usbdl_verify_da(buf, 0x12c)
0x02032B8A  mov     r0, r4          ; ← r4 をそのまま使用。cmp r0 / bne は**無い**
0x02032B8C  mov     r1, r5
0x02032B8E  mov     r2, fp
0x02032B90  bl      #0x2045C74      ; ログ
0x02032B94  b       #0x2032B30      ; メインループへ戻る
```

**戻り値はそのまま捨てられ、呼び出し点は何の判断もしていません。**
（強制的なバイパスがあるとすれば関数内部のみ —— 関数内に `bl #0x2045BA8(1)` という
疑わしい失敗分岐が 1 つあり、今回は完全には排除できていません。）

## G. 最終判断

| 問い | 答え |
|---|---|
| エンジニアリング preloader は**起動時のイメージ検証**を切っているか | **切っていない**（SBC は今も eFuse を読み、実測値=1、証明書検証が実際に実行されている） |
| **EDL/DA 認証**は切っている可能性があるか | **可能性が高い**（`usbdl_verify_da` の戻り値が未検査） |
| では改変 tee の書き込みに署名は必要か | **必要**。認証不要の書き込み ≠ 署名不要の起動 |

**「認証不要」をリスクゼロで確かめる方法**：EDL に入り、未署名 DA で**読み取りのみ**行い
（例：`mtkclient r seccfg`）、`.auth` ファイルを要求されるか見ます。

**「どこが変わったか」を最も直接的に確かめる方法**：純正の xagapro preloader と本イメージを
バイナリ diff にかけます。

---

# 最終結論（2026-10-05、実機ログ + 静的リバース）

## H. 完全な 2 段階の検証チェーン（fail ゼロ）

### 第 1 段：preloader の検証
ログ：`part: %s img: %s cert vfy(%d ms)` / `[PART] img_auth_required = %x`

```
 12  part: lk_a img: aee
 10  part: lk_a img: bl2_ext
 10  part: gz_a img: unmap2
 10  part: gz_a img: gz
 21  cert vfy(17..30 ms)
```

### 第 2 段：`bl2_ext`（拡張 BL2）の `[SBC]` サブシステム検証

```
[SBC] image <X> header auth pass    +    [SBC] <X> cert chain vfy pass
```

完全な一覧：
```
dtbo(21) lk_main_dtb(16) logo(12) tinysys-sspm(11) tinysys-mcupm-RV33_A(11)
spmfw(11) pi_img(6) dpmpt(6) tinysys-vcp-RV55_A(5) tinysys-scp-RV55_A(5)
tinysys-gpueb-RV33_A(5) tinysys-apusys-RV33_A(5) **tee(5)** mvpu_algo(5)
md1rom(5) md1dsp(5) **lk(5)** hifi3_a/b_{sram,iram,dram}(5) dpmpm(5)
dpmdm(5) ccu(5) **atf(5)**
```

**`auth fail` / `vfy fail` は 1 つもありません。**

## I. 決定的な結論

| 事実 | 根拠 |
|---|---|
| ATF は毎回の起動で検証されている | `[SBC] image atf header auth pass` ×5 |
| 検証スイッチは eFuse が決め、値は 1 | `sbc_en = 1` ×440、反例なし |
| 検証は実際に実行されている（デッドコードではない） | `cert vfy(17..30 ms)` ×21 |
| **改変した ATF は MTK 署名を通す必要がある** | 上記 3 つ |
| **認証不要の書き込みで入れられる** | `usbdl_verify_da` の戻り値が未検査（§F） |
| 壊しても救える | **preloader モード**（BROM ではない）経由、認証不要 |
| なぜカーネルを差し替えられるのか | `boot`/`vendor_boot` は `[SBC]` 一覧に**無い**（AVB 管理で、アンロック後は止めない）|

→ **pwnage 署名（LEGACY モード）は必須の工程で、省略できません。**

## J. ATF の実際のロード位置

```
Load 'tee_a' partition to 0x0xffff000048200000 (283016...)
Load 'tee_a' partition to 0x0xffff00006ffffdc0 (3200000...)
```

`0x48200000` = mblock-15-BL31-reserved のベース；283016 = `atf` メンバのサイズ。
2 つ目は `tee` メンバ（3 200 000 バイト = TEE OS）。
→ 動いている ATF は `tee_a` 内の `atf` メンバであり、NoGZ パッチが変更する対象そのものです。

---

# 署名完了（2026-10-05）

## ツール

`kasnria001/pwnage24mtk`（公開）：
- 原理：MTK の ASN.1 証明書解析ロジックの欠陥（CVE-2023-20696 と同種 / CVE-2025-20730 で修正）
- 旧世代デバイスは `bypass_mode 1`（= 本機で検出された `LEGACY` / `enter-value traversal, arg4=1`）
  やり方：**元の未改変 CERT2 DER** を `BIT STRING` の偽オブジェクトとして前に置き、
  本物の cert を後ろに置いて更新後の image hash / image hdr hash を持たせる
- 標準ライブラリのみで、追加依存なし

コマンド：
```bash
python sign_mtk_cert.py <unsigned.img> --legacy -w -o <out.img>
python verify_mtk_image.py --all <out.img>      # Result: VALID が 2 つ必要
```

## 重要な罠：署名後にパーティションを 1072 バイト超過

```
unsigned : 5 242 880   (= tee パーティションサイズ、ちょうど埋まる)
signed   : 5 243 952   (+1072)
```

増加分は BIT STRING ラッパー（987B）+ CERT2 dsize 982→2059（2064 にアライン）から。

**しかし挿入点は ATF の後ろで、末尾のゼロ埋めはまったく変わっていません：**

| メンバ | unsigned | signed |
|---|---|---|
| `atf` | 0x200 | 0x200 |
| `tee` | 0x46440 | 0x46870 (+1072) |
| `cert1` | 0x353a40 | 0x353e70 (+1072) |
| `cert2` | 0x354310 | 0x354740 (+1072) |
| 末尾ゼロ埋め | 1 751 322 | **1 751 322（不変）** |

末尾に 1.75 MB の全ゼロ → **1072 バイトのゼロ埋めを切ればちょうど 5 MiB、実データ損失ゼロ。**
（切る部分がすべて 0x00 であることを検証済み）

## 成品

```
ファイル : sign-test/tee_nogz_legacy_5M.img
サイズ   : 5 242 880  (= tee パーティション)
sha256   : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```

| 検査 | 結果 |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`**（ATF グループ + TEE グループ）|
| CERT1 / CERT2 signature | OK |
| Image header hash / Image data hash | OK |
| `tee` メンバが変更されたか | **未変更** ✓ |
| ATF と再パッチ結果 | **バイト単位で一致** ✓ |
| 公式 14 項目回帰 | **14/14 通過** ✓ |

**未検証項目（正直に明記）**：`Trusted root check: skipped`
→ この証明書チェーンに対するデバイス eFuse トラストルートの照合は**オフラインでは未検証**で、
実機起動でしか分かりません。

## 上流リポジトリのバグ（フィードバック用）

`scripts/build.py:340` は `sign_all_flag(args.tools)` を呼びますが、**ファイル全体にこの関数の定義がありません**
→ 署名経路を通れば必ず `NameError`。`--check-only` は途中で return するため露見しませんでした。
（また、`sign_mtk_cert.py` 自体に `--all` 引数が無いので、この関数は本来 `[]` を返すべきです。）

---

# コミュニティ チュートリアルによる裏付け（Coolapk「MTK SPFlash V6 使用教程 For xaga/pearl」）

チュートリアルの重要文：

> エンジニアリング **Preloader は安全でない VCOM ポートを公開し、SLA（シリアル リンク認証）と
> DAA（ダウンロード エージェント認証）の検査を無効化している**ため、小米のアフターサービス アカウントの
> 認可なしにツールで書き込める

> 最近良いニュースがあり、**xaga のエンジニアリング Preloader ブートファイルが流出**しました。
> 何の役に立つかというと、答えは**無料のブリック救済**です……一定のハードブリックを避けられ、
> お金を払わずに自分で救えます

## 3 つの独立した証拠が完全に噛み合う

| チュートリアルの主張 | 本イメージ内の対応証拠 |
|---|---|
| **DAA**（ダウンロード エージェント認証）を無効化 | `usbdl_verify_da` の**戻り値がそのまま捨てられている**（§F）|
| 安全でない **VCOM ポート**を公開 | イメージ内に `USB CDC ACM for preloader` の文字列 |
| できるのは「書き込める」ことで、検証を切ったわけではない | `sbc_en` は eFuse から読み、実測 = 1、`[SBC] image atf header auth pass`（§E/§H）|

→ **エンジニアリング preloader = 「書き込み」を認証不要にする（+ 壊れても救える）。起動時に検証するか
どうかには一切触れない。** 本文書 §G/§I の結論と一致し、矛盾しません。

## チュートリアルから我々に有用な 2 点

1. **SP Flash で全書き換えすると BL が再ロックされる**
   > 全書き換え後は bl はロックされた状態になる。ただし 2 回目は即座に開けられる
   > （seccfg パーティションを書かなければ bl のアンロック状態を保てるという話もあるが、ツールはこのパーティションを書かない）
   → **SP Flash で tee を書かないこと**。BL が再ロックされ、以降 fastboot が不便になります。

2. エンジニアリング preloader の書き込みは **fastboot** 経由：
   ```
   fastboot flash preloader1 preloader_xaga.bin
   fastboot flash preloader2 preloader_xaga.bin
   fastboot reboot
   ```
   （本機の by-name では `preloader_raw_a` / `preloader_raw_b` に対応）

3. 復旧チェーンに必要な材料（チュートリアルで @rkpsz 氏が共有したパッケージ）：
   `SP_Flash_Tool_v6.2316_Win.zip` + `auth_sv5.auth` + `libusb_v1.12.exe` +
   MediaTek ドライバ + `preloader_xaga.bin` + 線刷パッケージ `flash.xml`

---

# ✅ 実機成功（2026-10-05 22:00）

## 書き込み

```
tee_a BEFORE : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
dd 5242880 bytes, 0.019 s, 263 M/s
tee_a AFTER  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```
読み戻しハッシュ == 成品ハッシュ → 書き込みが実際に効いた。

## 再起動後：ATF が実機の SBC 検証を通過

```
[SBC] image atf header auth pass   ×3
```
→ pwnage の証明書脆弱性が本機で成立し、署名版 ATF が受け入れられた。

## KVM が起動

```
crw-rw-rw- 1 root root u:objectr:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        ← /proc/misc（書き込み前は 46 項目に kvm が無かった）
head -c 1 /dev/kvm → Invalid argument
                     ↑ Permission denied ではない → open() が SELinux（Enforcing）を通過
```

## 実際に Linux VM を走らせる（決定的な証拠）

本機内蔵の AVF の crosvm + microdroid カーネル：

```bash
su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

ゲストの出力：

```
Booting Linux on physical CPU 0x0000000000 [0x412fd050]   ← Cortex-A55
Linux version 6.6.30-android15-5
Machine model: linux,dummy-virt
psci: PSCIv1.0 detected in firmware.
GICv3: CPU0: found redistributor 0 region 0:0x000000003ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x0000000001 [0x411fd411]  ← Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

**結論：ATF → EL2 → VHE → KVM → 2 vCPU の Linux ゲストが正常起動。チェーン全体が実機で閉じました。**

## 最終成品

| ファイル | sha256 |
|---|---|
| `sign-test/tee_nogz_legacy_5M.img` | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `backup/tee_a.img`（ロールバック用） | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

## 残件

- `tee_b` は**未変更**（純正のまま）。B スロットに切り替えると KVM 無しの状態に戻りますが、
  それゆえに天然の保険でもあります。
- 上流 `mtk-mod-tee-nogz` の `sign_all_flag` 未定義バグはフィードバックできます。

---

# DroidVM 実機検証（2026-10-05 深夜）

## 環境

```
DroidVM v0.0.6 インストール済み、daemon 稼働中（KernelSU 認可済み）
kernel 5.10.247-android12-9-Pandora-26w08d   SoC MT6895Z/TCZA
同梱: usr/bin/{qemu-system-aarch64, qemu-img, crosvm}
      usr/share/droidvm/{edk2-qemu.fd, edk2-gunyah.fd, vmlinuz, initramfs.img}
usr/lib/modules は無し（KVM にベンダー モジュールは不要。ソース解析と一致）
```

## ① crosvm + KVM：**安定して利用可能**（実測済み）

デバイス内蔵の AVF の crosvm で microdroid カーネルを起動し、ゲストは完全起動、2 コア SMP も成功。

## ② DroidVM 同梱 QEMU + KVM：**flaky（big.LITTLE 競合）**

素で QEMU を走らせるとリンカ名前空間が `libbinder_ndk.so` を取得できず、
`LD_LIBRARY_PATH=/system/lib64` で回避が必要（DroidVM daemon 自体は正しい環境を持つため不要）。

```
Accelerators supported in QEMU binary: gunyah, kvm, tcg     ← geniezone は無い
```

DroidVM の `QemuBackendInstance` は cpu を `host[,pmu=off]` にハードコードしており（ソース L196-201）、
実測で**同じコマンドを 5 回連続：2 成功 / 3 失敗**：

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

**根本原因（特定済み）**：`-cpu host` が列挙するのは QEMU が**現在動いている CPU** の機能で、
big.LITTLE 上で vCPU レジスタを書いている最中に A55/A78 間でマイグレーションされると EINVAL。

コア固定の検証：

| 条件 | 結果 |
|---|---|
| 固定なし × 5 | 2/5 成功 |
| `taskset 1`（cpu0, A55）× 3 | **3/3 成功** |
| `taskset 80`（cpu7, A78）× 3 | **3/3 成功** |

各種 `-cpu` 変種の挙動（不安定。ランダム性が機能差より支配的）：
`host` ✗ · `host,pmu=off` ✗(60%) · `host,sve=off` ✓ · `host,pauth=off` ✓ ·
`host,sve=off,pauth=off` ✗ · `host,sve=off,pmu=off` ✓ · `max` ✗ · `cortex-a55` ✗（KVM は host/max のみ対応）

**結論**：DroidVM 内の QEMU+KVM は**コア固定**があって初めて信頼できます。crosvm は不要です。

## ③ ATF パッチとは無関係の傍証

`/proc/cpuinfo` の Features は書き込み前後で**完全に同一**（どちらも `sve` 無し）で、
パッチがカーネルの CPU 特性判定を変えていないことを示します。
