# 完成済み tee イメージ

[中文](README.md) | [English](README.en.md) | **日本語** | [Русский](README.ru.md)

**すでにビルドと署名が済んだ** NoGZ パッチ入り `tee` イメージです。対応するファームウェアの
デバイスにそのまま書き込めます。

---

# 🛑 試す前に必ず読んでください

## ① まず【エンジニアリング preloader】を焼く —— さもないと退路が無いかもしれません

```
純正 preloader       ⇒ EDL に小米アフターサービスのアカウント認可が必要 ✗
                    ⇒ tee を間違えて起動しなくなったとき、【認証不要の救助路が無い】✗

エンジニアリング preloader ⇒ usbdl_verify_da の戻り値が破棄され、SLA/DAA が実質無効化
                        ⇒ SP Flash / mtkclient で【アカウント無しで】書き込める ✓
                        ⇒ これが「壊しても救える」の実際の前提 ✓
```

```bash
fastboot flash preloader1 preloader_xaga.bin
fastboot flash preloader2 preloader_xaga.bin
fastboot reboot
```

（by-name では `preloader_raw_a` / `preloader_raw_b`）

> ⚠️ エンジニアリング preloader が免除するのは**書き込みの認証だけ**で、
> **起動時のイメージ検証は切れません** ✗ —— `sbc_en` は依然 1 で、ATF は毎回検証されます
> （[../docs/05-gotchas.md](../docs/05-gotchas.md) 参照）。

## ② どの機種に使えるか

| コードネーム | 市場名 | 本プロジェクト |
|---|---|---|
| **`xagapro`** | **Redmi Note 11T Pro+** / **Redmi K50i** | ✅ **本プロジェクトの実測機**（2 つの完成品はここから出ています）|
| `xaga` | **Redmi Note 11T Pro** / **POCO X4 GT** | ⚠️ ファームウェアが異なり固有の profile が必要。ただし**ベース違いでも起動することは実測済み**なので、バックアップしてから試すことは可能 |

どちらも **MT6895 / Dimensity 8100** で、原理は同一、違いはファームウェアベースだけです。

---

## 👉 完成品をそのまま試したい場合の順序

```
① エンジニアリング preloader を焼けることを確認（ファイルがある + fastboot / SP Flash が使える）
② 焼いて正常起動を確認
③ バックアップ：tee_a / tee_b / lk_a / lk_b / preloader_raw_a / seccfg
④ tee/verify.sh で自分の機体がどの完成品に合うか確認
⑤ 書き込み → 再起動 → 【3 分待つ】（毎回の起動で 2 回目の画面が 1〜2 分止まる。文鎮ではない）
⑥ 確認：adb shell su -c 'ls -l /dev/kvm'
```

---

# ⭐ 実機検証に成功した例

## [`tee_nogz_rk_5M.img`](tee_nogz_rk_5M.img) —— **実機で KVM が動作**

```
sha256   f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
base     f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
size     5 242 880 バイト（tee パーティションをちょうど埋める）
cert     LEGACY
```

**実測記録**（同一デバイス、OS のメジャーアップデートを 2 回またいで）

| 時点 | システム | `tee_a` | `lk_a` | 結果 |
|---|---|---|---|---|
| 初回書き込み | HyperOS（Android 15） | `f8f286f1…` → パッチに書換 | `8cbaa2e8…` | ✅ `/dev/kvm` 出現、2 vCPU の Linux ゲストが完全起動 |
| アップデート後 | **Android 16 / HyperOS 3.3** | パッチのまま | `a17d87c6…`（**差し替えられた**） | ✅ **依然正常**、`/dev/kvm` も健在 |

**このアップデートが重要な結論を偶然与えてくれました**：

> **`lk` が差し替わってもパッチには一切影響しない。互換性を決めるのは `tee` ベースだけ。**

**実測の証拠（生の出力）**

```console
$ adb shell su -c 'for p in tee_a tee_b; do printf "%s " $p; dd if=/dev/block/by-name/$p bs=4096 2>/dev/null | sha256sum | cut -c1-16; done'
tee_a f1511dcad9820397      ← 本パッチ
tee_b f8f286f138e758a5      ← 純正、未変更

$ adb shell su -c 'ls -l /dev/kvm'
crw-rw-rw- 1 root root 10, 232 2026-10-06 21:52 /dev/kvm      ← ✅

$ adb shell "grep -i kvm /proc/misc"
232 kvm

$ adb shell su -c 'dmesg | grep -i sbc'
[SBC] image atf header auth pass
sbc_en = 1
```

**実際に動かしたもの**：`crosvm`（microdroid）でのゲスト起動 —— 成功。
`qemu-system-aarch64 -accel kvm` による 2 vCPU Linux ゲスト —— 成功。
さらに同じデバイス上で **Windows 11 ARM64 を最後までインストールしてデスクトップまで到達**。

> ⚠️ 注意：**本パッチは `tee_a` = `f8f286f1…` のデバイスにのみ有効です。**
> 書き込む前に**必ず下の自己診断を実行してください**。

---

## 👉 書き込む前の自己診断

リポジトリには自己診断スクリプト [`verify.sh`](verify.sh) が付属しています：

```bash
bash tee/verify.sh                 # 接続中のデバイスを自動検出
bash tee/verify.sh <serial>        # デバイスを指定
```

デバイスの `tee_a` / `tee_b` を表示し、**どの完成済みパッチが使えるか**を教えてくれます。

手動版（ハッシュを 1 つ比べるだけ）：

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

| あなたのデバイスの `tee_a` sha256 | 書き込めるもの |
|---|---|
| `f8f286f1…`（純正ベース） | `tee_nogz_rk_5M.img` ✓ |
| `a91f5ded…` | `tee_nogz_shuilanA15_5M.img` ✓ |
| それ以外 | ✗ **書き込まないこと**。[docs/02](../docs/02-build-and-sign.md) に従って自分でビルド |

---

## ❓ 書き込むとアプリの整合性チェックに影響しますか？（実測の答え：**しません**）

書き込む前に最も気になる点です。**同一デバイスの前後比較 + 2 台での A/B 比較**を実測しました。

**原理的に影響しない理由**：パッチが行うことはただ 1 つ —— **GZ に EL2 を渡さない**。
アプリの整合性チェックが依存する安全機能は**すべて TEE（S-EL1）**で動いており、
EL2 とはまったく別の世界です：

| 安全機能 | 実際の担い手 | パッチ後 |
|---|---|---|
| **ハードウェア鍵 / KeyMint 証明** | `keymint@1.0-service.beanpod`（ベンダー TEE） | ✅ 正常 |
| **Gatekeeper**（ロック画面の資格情報検証） | TEE | ✅ 正常 |
| **Widevine / DRM** | `widevine_driver` が `mtk_sec_heap` を保持 | ✅ 正常 |
| **指紋 / 顔認証** | TEE | ✅ 正常 |
| **Secure Element**（NFC 決済） | `secure_element@1.2-service-mediatek` | ✅ 正常 |
| **GZ / GenieZone（EL2）** | MediaTek の EL2 仮想化フレームワーク | ⚠️ **無効**（ただし実測で影響なし）|

### 実測の証拠

2 台のデバイス（**1 台は未書き込み / 1 台は書き込み済み**）でまったく同じコマンドを実行し、
結果は**項目ごとに一致**しました：

```
① Verified Boot の状態
   ro.boot.verifiedbootstate   orange      ← 両方とも orange（BL アンロック済み）
   ro.boot.flash.locked        0           ← 両方とも 0
   ro.secure / ro.debuggable   1 / 0       ← 完全に同一
   ro.build.tags               release-keys

② 主要な HAL サービス（両方で同一）
   android.hardware.security.keymint.IKeyMintDevice/default               ✓
   android.hardware.security.keymint.IRemotelyProvisionedComponent/default ✓
   android.service.gatekeeper.IGateKeeperService                          ✓
   fingerprint / biometric / auth サービス                                 ✓

③ TEE が本当に生きているか（両方で同一）
   teei_daemon と [teei_*] カーネルスレッドが存在      ← Trustonic TEE が稼働中
   keymint@1.0-service.beanpod プロセスが稼働中
   android.hardware.secure_element@1.2-service-mediatek が稼働中
   widevine_driver が mtk_sec_heap の参照を保持         ← DRM の安全メモリ経路が生きている

④ エンドツーエンドのハードウェア鍵テスト（keystore_cli_v2、両方で同一）
   generate --seclevel=tee   →  GenerateKey: success
   get-chars                 →  特性はすべて "Hardware:" 側、"Software:" 側は空
   sign-verify               →  Sign: 256 bytes.  Verify: OK
```

**TEE が本当に仕事をしているか**を客観的に確かめる方法（ソフトウェア実装に
落ちていないか）：

```bash
# 強制的に TEE 内で鍵を生成し、特性の帰属を見る
adb shell 'keystore_cli_v2 generate --name=t --seclevel=tee'
adb shell 'keystore_cli_v2 get-chars --name=t'      # すべて "Hardware:" の下にあるべき
adb shell 'keystore_cli_v2 sign-verify --name=t'    # Verify: OK でなければならない
adb shell 'keystore_cli_v2 delete --name=t'
```

### 重要な注意 2 点

1. **`verifiedbootstate = orange`（BL アンロック）は元々 Play Integrity の致命傷**であり、
   `tee` を書き込むかどうかとは**無関係**です。BL アンロック + root のデバイスでは
   `MEETS_DEVICE_INTEGRITY` / `MEETS_STRONG_INTEGRITY` は**元から通りません**し、
   銀行アプリも元から root 隠蔽で対処しています。
   **`tee` の書き込みはこの状態を改善も悪化もさせません** —— BL ロック、root、dm-verity の
   いずれにも触れないからです。

2. **`gz_*` カーネルモジュールは変わらずロードされます**（`lsmod` に `gz_main_mod` /
   `gz_irq_mod` / `gz_virtio_mod` などが見えます）が、参照カウントは 0 ——
   ロードはされるものの **EL2 を取れないため死んでいます**。
   実際に働いているのは TEE であり、GZ ではありません。

> **一言で**：パッチが変えるのは **EL2 の所有権**であり、**TEE には触れません**。
> 「本物か / 改変されていないか」を見るあらゆる検査は TEE と Verified Boot を見ており、
> そのどちらも変わっていません。

---

## 🔬 書き込む前にできる追加検証：同型比較

実機検証が最終的な基準ですが、**書き込まずに**問題の一大カテゴリを排除できる方法があります。

**考え方**：信頼できる NoGZ パッチは、そのベース `tee_a` に対する変更が**パターン化**されています ——
変更は profile で定義されたパッチ点（ATF の getter/callback/pc_patch など）に集中し、
残りの差分は署名によるものです。そこで**すでに実機検証済みのパッチ**を参照として、
両者の「各自のベースとの差分領域」が**同型**かどうかを比べます：

```bash
python tools/verify-patch-diff.py \
  --base-a  backup/tee_a.img \
  --patch-a tee/tee_nogz_rk_5M.img \
  --base-b  backup/tee_a_NEWROM_a91f5de.img \
  --patch-b tee/tee_nogz_shuilanA15_5M.img
```

本プロジェクトの実測出力：

```
  区間数が一致   : ✅ はい  (175 vs 175)
  総バイトが一致 : ✅ はい  (2953488 vs 2953488)
  長さ列が一致   : ✅ はい

  ✅ 結論：検証対象のパッチは参照パッチと同型 —— 同じパイプラインから出ており、逸脱していない。
```

**→ 2 つのパッチは同じビルド手順から出ており、逸脱がないことを示します。**
これは**実機検証の代わりにはなりません**が、「ビルドが壊れた / profile の偏移を計算ミスした」
といったカテゴリの問題は排除できます。

---

## ⚠️ ベースの違うパッチを同じディレクトリに置かないこと

実測で一度踏みました：**ファイル名を読み違えて、別ベースのパッチを書き込んでしまった** ✗ ——
当時は「2 回目の画面で止まった」と思いましたが、後に**単に待ち時間が足りなかっただけ**の
可能性が高いと判明しました（パッチ書き込み後は毎回の起動で約 2 分かかります）。
**ただし、それを試してはいけません** ✗ —— 正しいベースを使うのが正道です ✓

```
/data/local/tmp/tee_patched.img     ← 別ベースのパッチ ✗ なのに名前は一番「書き込むべきもの」っぽい
/data/local/tmp/tee_nogz_new.img    ← このデバイスに書き込むべきパッチ ✓ なのに名前が分かりにくい
```

**→ ルール：パッチのファイル名には「どのベース向けか / この個体に書き込んでよいか」を必ず書く** ✓
例：`FLASH_THIS_shuilan_patch_for_this_phone.img` /
`DO_NOT_FLASH_rk_patch_wrong_base.img` ✓

もっとはっきり言えば：**同じデバイス上に複数ベースのパッチを同時に置かない** ✗。
どうしても置くなら、どれが安全かを書いた `TEE_README.txt` を隣に用意してください。

---

## ⚠️ 核心ルール：パッチは **`tee` ベースに縛られる** —— **ただし「ベース違いは起動できない」は実測で否定されました**

NoGZ パッチが変更するのは `tee` パーティション内の **`atf` メンバの起動引き渡しロジック**なので、
**「ビルド時に使った `tee` ベース」**に対してのみ有効です。

### 🧪 2026-10-07 の決定的な実験：**ベース違いでも正常に起動する** ✓

```
1 台目（元の tee_a = f8f286f1…、つまり rk パッチ自身のベース）
  → shuilan パッチ（17ec8497…、ベース a91f5ded…）を書き込み   ← 真のベース違い
  → 再起動後 136 秒でネットワークに復帰
  → その後 3 分間で 12/12 回連続オンライン（起動ループではない）
  → システム正常、tee_b は終始未変更
```

**→ したがって「ベース違いは必ず壊れる」は誤り** ✗、
「ベース違いのパッチは起動できない」も誤り** ✗ です。

**以前の「起動停止」の正体**：**毎回の起動で起きる 1〜2 分の遅延** ✗
（[docs/05-gotchas.md 第 12 項](../docs/05-gotchas.md)）—— 当時は待ち時間が足りずに fastboot へ入り、
成功するはずの起動を自ら中断していました ✗。

**→ それでも自分のベースに合わせたパッチを推奨します** ✓ —— 理由は「さもないと止まるから」✗
ではなく、**同ベースの方が保守的で変数が少ないから** ✓ です。

> 🔑 **実用的な結論**：**ベースを間違えて書いても慌てないこと** ✓ —— まず 2 回目の画面で
> 1〜2 分止まるので、**3 分待てば** そのまま自力で起動する可能性が高いです ✓
> （もちろん、先にバックアップしておくに越したことはありません）。

**実測で確認済みの境界**（どの変化が影響し、どれがしないか）：

| パーティション / 条件 | 変わると無効になるか | 確認方法 |
|---|---|---|
| **`tee`** | ✅ **無効になる** | `tee_a` のハッシュを比較 |
| `lk` | ❌ ならない | 差し替え後もパッチは正常動作（実測） |
| `gz` / `dtbo` / `boot` / `system` | ❌ ならない | Android 15 → 16 の大型アップデートをまたいでも正常 |
| デバイス間（同型機） | ⚠️ **`tee_b` 次第** | `tee_b` が同じ = 同じファームウェアバッチ = 同じベース |

> 🛑 **最も誤読されやすい点：「もう一方のパッチを書いて動いた」≠「ベース違いでも可能」** ✗
>
> 「1 台目は自分のパッチで動いたのだから、1 台目のパッチを 2 台目に書いても動くはず」✗
> という推論は**間違い**です ✓：
>
> | | 1 台目 | 2 台目 |
> |---|---|---|
> | 1 台目のパッチ（`f1511dca…`）のベース | `f8f286f1…` | `f8f286f1…` |
> | 書き込み前の自分の `tee_a` | **`f8f286f1…`** | **`a91f5ded…`** |
> | 判定 | ✅ **同ベース**（動いて当然）| ⚠️ **ベース違い**（実測で使える ✓、上記参照）|
>
> **1 台目の事例は最初から最後まで同ベースへの書き込み** ✓ —— 証明しているのは
> 「**同ベースなら使える**」✓ であり、**「ベース違いでも可能」の証拠にはできません** ✗。
> 真にベース違いなのは 2 台目の 1 回だけ ⚠️ で、しかもその結論は不確かです
> （下の「混ぜ書き」の節を参照）。

**最も確実な自己診断 —— 触られていない側のスロット `tee_b` を見る**：

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
```

- `tee_b` が変わっていない（= 純正）→ `tee` ベースは純正バッチのまま → 純正ベースのパッチが使える ✓
- `tee_b` も変わっている → ベースが入れ替わった → 再ビルドが必須 ✗

> **ROM / OTA アップデートは `tee_a` を黙って書き換えます** ⚠️ —— 本件では、あるデバイスが
> **ROM 書き込み後に `tee_a` を `f8f286f1…` から `a91f5ded…` へ変更されました**
> （ROM パッケージに `tee` イメージが入っていなくても、初回起動時のファームウェア更新や
> `super.img` が原因で起こります）。
> **したがって：ROM を書き込む前に `tee_a` をバックアップし、書き込み後にハッシュを比較し、
> 変わっていたらパッチを作り直してください。**

---

# 完成品一覧

## 1. ⭐ `tee_nogz_rk_5M.img` —— **実機検証に成功**（参照用として推奨）

| 項目 | 値 |
|---|---|
| 対応ベース（`tee_a`） | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |
| ビルド時の `lk` | `8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3` |
| cert mode | `LEGACY` |
| サイズ | 5 242 880 バイト（= tee パーティションサイズ） |
| sha256 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| オフライン検証 | ✅ 14/14 回帰すべて通過 |
| 署名検証 | ✅ 2 × `Result: VALID` |
| **実機検証** | ✅ **通過**（Android 15 → 16 をまたいで 2 回確認） |

## 2. ⭐ `tee_nogz_shuilanA15_5M.img` —— **実機検証に成功**

| 項目 | 値 |
|---|---|
| 対応ベース（`tee_a`） | `a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7` |
| ビルド時の `lk` | `a17d87c630f23b6720cfe311b2a06d196503a4eb00242bc6413eeeb0b836e1cb` |
| cert mode | `LEGACY` |
| サイズ | 5 242 880 バイト |
| sha256 | `17ec849749febda62445f922ec3ee8b65a3092f0ea2c641e98eb732fbe60ee59` |
| オフライン検証 | ✅ 14/14 回帰すべて通過 |
| 署名検証 | ✅ 2 × `Result: VALID` |
| 同型比較 | ✅ 実機検証済みの rk パッチと項目ごとに一致（175 区間 / 2953488 バイト）|
| **実機検証** | ✅ **通過**（2026-10-06 実測）|

**実測結果（元 `a91f5ded` ベースのデバイス）**

```
書き込み前 tee_a = a91f5deda942a167   （別途バックアップ済み）
書き込み後 tee_a = 17ec849749febda6   ✓ 読み戻し検証も一致
tee_b            = f8f286f138e758a5   ✓ 終始未変更

再起動後：
  /dev/kvm   = crw-rw-rw- 1 root root 10, 232   ✅ 出現
  /proc/misc = 232 kvm                           ✅
  システム無傷：497 個のアプリパッケージが 1 つも欠けていない ✓
```

> ⚠️ **毎回の起動で 2 回目の画面が約 2 分停止します**（今回の実測は 130 秒）——
> **文鎮ではありません。待てば大丈夫です** —— 慌てて fastboot に入らないでください。
> それは起動を中断させてしまいます。
> 詳細は [docs/05-gotchas.md 第 12 項](../docs/05-gotchas.md)。

**このパッチが生まれた経緯**：あるデバイスが**ROM 書き込み後に `tee_a` を `a91f5ded…` へ
更新されました**（純正のままの `tee_b` は `f8f286f1…`）。そこで**そのデバイス自身の `tee_a`**
を使って偏移を再リバースし、再ビルドし、再署名しました ——
つまり**同じデバイスでベースが入れ替わったときにどう自救するか**の完全な実例です。

> これは**1 台目の実戦に続いて**生まれた、2 つ目のベース向けのパッチです。
> 2026-10-06 時点で、元 `a91f5ded` ベースのデバイス上で**実機検証に通過**しています ✓

---

## 2 つのパッチの対照

| | `tee_nogz_rk_5M.img` | `tee_nogz_shuilanA15_5M.img` |
|---|---|---|
| ベース | `f8f286f1…`（純正） | `a91f5ded…`（ROM 更新後） |
| オフライン回帰 | 14/14 ✅ | 14/14 ✅ |
| 署名検証 | VALID ✅ | VALID ✅ |
| 実機 | ✅ **成功** | ✅ **成功** |
| 対応 profile | [`profiles/xagapro.json`](../profiles/xagapro.json) | [`profiles/shuilanA15.json`](../profiles/shuilanA15.json) |

**⚠️ 「混ぜ書き」について —— 初期の「必ず 2 回目の画面で止まる」という結論は取り消しました** ✗

以前は「純正ベースのパッチを、ベースが更新済みのデバイスに書き込むと**必ず止まる**」と
断言していました。しかしその結論は**誤診した 1 回のテストに基づいていました** ✗ ——

**NoGZ パッチを書いた後は、毎回の起動で 2 回目の画面が 2 分近く止まります**
（[docs/05-gotchas.md 第 12 項](../docs/05-gotchas.md)）。当時は待ち時間が足りず、
文鎮だと判断してしまいました ✗

**→ 2026-10-07 の 1 台目（原文では「1 台目」＝実験機）での実験で、この懸案は完全に決着しました** ✓ ——
**ベース違いのパッチは【正常に起動します】。 「必ず壊れる」✗ でも「未検証」⚠️ でもなく、【実測で使える】✓ です**
（上の「核心ルール」の節に完全なデータがあります）。

### それでも自分のベースに合わせたパッチを強く推奨します ✓

理由は**「2 回目の画面で止まるから」ではありません** ✗。理由は：
ベース違いのパッチには**別バッチの TEE OS** が入っているためです。仮にシステムが起動しても、
keymint / DRM / セキュアエレメントといった TEE サービスが、デバイス現在の ROM と
**バージョン不整合**を起こす可能性があります ✗。

### 「正常な遅さ」と「本当の失敗」の見分け方 ✓

| 現象 | 正常な遅さ ✓ | 本当の失敗 ✗ |
|---|---|---|
| 画面 | **2 回目の画面**（logo2）でスピナー | **1 回目の画面**で停止、またはブラックアウト後に**自動で fastboot へ** |
| adb | **デバイスが見える**（`adb devices` に出る） | 見えない、または既に fastboot モード |
| 時間 | 1〜3 分で自力でシステムへ | 5 分以上変化なし |
| 対応 | **待つ** ✓ | バックアップを書き戻す ✓ |

---

# 書き込み方法

## 0) まずバックアップ（必須、省略不可）

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a_backup.img bs=4096'
adb shell su -c 'dd if=/dev/block/by-name/tee_b of=/data/local/tmp/tee_b_backup.img bs=4096'
adb pull /data/local/tmp/tee_a_backup.img
adb pull /data/local/tmp/tee_b_backup.img

# ハッシュを記録しておく（ロールバック時の照合用）
sha256sum tee_a_backup.img tee_b_backup.img
```

## 1) 書き込み

```bash
adb push tee_nogz_rk_5M.img /data/local/tmp/tee_patched.img

# スマホ側で転送したファイルが壊れていないか先に確認（重要！）
adb shell su -c 'sha256sum /data/local/tmp/tee_patched.img'
# 完成品の sha256 と一致しなければならない

adb shell su -c 'dd if=/data/local/tmp/tee_patched.img of=/dev/block/by-name/tee_a bs=4096 && sync'
```

## 2) 読み戻し検証（必須）

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
# 完成品の sha256 と一致しなければならない
```

## 3) 再起動 + KVM の確認

```bash
adb reboot
# 起動完了を待つ（初回は約 2 分かかります）
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'grep -i kvm /proc/misc'
adb shell su -c 'dmesg | grep -i -E "sbc|kvm" | tail -20'
```

期待される出力：

```
crw-rw-rw- 1 root root 10, 232 … /dev/kvm
232 kvm
[SBC] image atf header auth pass
```

## 🔙 ロールバック（2 回目の画面で止まったときの救出）

**症状**：書き込み後の再起動で 2 回目の画面で止まる（ロゴが回った後にブラックアウト、
または再起動ループ）。ただしデバイスは**まだ fastboot に入れます**（音量下 + 電源）。

```bash
# fastboot モードに入ってから
fastboot devices
fastboot flash tee_a tee_a_backup.img
fastboot reboot
```

**この道は実測で有効です** —— 本プロジェクトの 2 つ目のベースはこうして救出しました。
**動かすのは `tee_a` 1 つだけ**で、他のデータ（ユーザーデータ / システム）は無傷です。

> 予備の手段 2：デバイスには **B スロット**もあり、`tee_b` は一度も変更されていないため、
> 天然の 2 つ目のコピーになっています。

---

# これらのファイルについて

- これらは**公式ツールチェーンで署名された**完全な `tee` パーティションイメージです
  （MediaTek の ATF、TEE OS、証明書チェーンを含みます）。
- [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) +
  [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) でビルドされています。
  偏移定義は [`profiles/`](../profiles/)、リバースツールは [`tools/`](../tools/)。
- 上流の `mtk-mod-tee-nogz` は**ファームウェアとビルド済みイメージを含まない**と明言しています。
  ここに完成品を置いているのは**照合と再利用のため**です。ご自身の状況に合うか判断してください。
- **書き込みにはリスクがあります**。**ご自身がアクセス権を持つデバイスとファームウェア**にのみ
  使用し、**必ずバックアップしてください**。
