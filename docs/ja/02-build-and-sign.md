# ビルドと署名 —— 手順の詳細

[中文](../02-build-and-sign.md) | [English](../en/02-build-and-sign.md) | **日本語** | [Русский](../ru/02-build-and-sign.md)

本稿で明らかにするのは：**NoGZ パッチが実際に何を変えるのか**、**どうビルドするか**、
**どう署名するか**、**どう検証するか**です。

> ツールは [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)（上流）です。
> 本プロジェクトのワンクリックスクリプトは、それを「書き込み + 検証」と繋いでいるだけです。
> 上流は明確に宣言しています：**ファームウェアを含まず、書き込み用イメージも含まず、
> スクリプトに自動書き込み機能はありません** —— 書き込み側は本プロジェクトが補っています。

---

## 1. パッチは実際に何を変えるのか

変わるのは `tee.img` 内の **`atf` メンバの起動引き渡しロジック**で、目標状態は：

> **LK は EL1h に入り、AArch64 カーネルは EL2h へ引き渡す状態を維持**し、
> かつ **ATF/LK が共有する GZ-info タグを同期させる**。

上流は 3 種類の「誤ったやり方」を反例として残しています（自分で適当に patch してはいけない理由でもあります）：

| # | 反例 | 説明 |
|---|---|---|
| 1 | `D2A21E08` は実際には `0x10f00000` をロードし、LK の `0x50f00000` ではない | 正しいエンコードは **`D2AA1E08`** |
| 2 | オリジナル LK の EL2 エントリ経路は **`CPTR_EL3` にアクセスする** | よって LK とカーネルの入口レベルをまとめて EL2h に強制しては**ならない** |
| 3 | ATF の GZ getter だけを変えても LK の状態は**自動では変わらない** | **共有タグを同期**しないと、後で GZ unmap 経路に入ってしまう |

**要点**：パッチは **GZ のメモリ予約と remap を保持**し、**メモリを返却するとは主張していません** ——
EL2 を Linux が使えるようにするだけ（その結果 `/dev/kvm` が露出する）です。

---

## 2. 環境準備

**Python 3.10+**、独立した仮想環境を推奨します。

Linux / macOS：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

Windows PowerShell：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

依存は **Capstone**（逆アセンブラ）と **Unicorn**（エミュレート実行）—— どちらもオフライン解析用で、
デバイスもネットワークも不要です。

**さらに必要**（リポジトリには同梱されないので自分で用意）：

- **`pwnage24mtk`** の完全なツールディレクトリ（`sign_mtk_cert.py` / `verify_mtk_image.py` を含む）
- **デバイスに一致するファームウェア**：`tee.img` / `lk.img` / `preloader.bin`
  → デバイスから直接 dump するのが最も確実（[01-enable-kvm.md](01-enable-kvm.md) の第 3 節参照）

---

## 3. 機種マッチング（まずここを通る必要がある）

ツールは **完全な SHA-256** で TEE/LK の組み合わせを照合します。**機種名でもファイルサイズでもありません**：

| Profile | 対象サンプル |
|---|---|
| `xaga` | Redmi Note 11T Pro / Pro+（MT6895）**← 本プロジェクトの実測機種** |
| `peral` | Xiaomi 13T |
| `yunluo` | 解析済みの yunluo TEE/LK ペア |

> **機種名が同じ、ファームウェア版が近い、ファイルサイズが一致する —— どれもハッシュ一致の代わりにはなりません。**
> したがって必ず**デバイス自身から dump** してください。ネット上で「同機種」のファームウェアパッケージを
> 探してはいけません。

完全なハッシュとアドレス定義はツールリポジトリの `references/profiles.json` にあります。

```bash
# dump したもののハッシュを計算し、profiles.json と照合する
sha256sum dump/tee_a.img dump/lk_a.img
```

---

## 4. 第一段階：オフライン検査だけを行う（署名なし、成果物なし）

まず `--check-only` を実行し、TEE/LK の組み合わせが一致し、パッチの回帰が通ることを確認します：

Linux / macOS：

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    "$HOME/private-firmware/xaga/tee.img" \
  --lk     "$HOME/private-firmware/xaga/lk.img" \
  --check-only
```

Windows：

```powershell
$inputDir = Join-Path $HOME 'private-firmware\xaga'
.\.venv\Scripts\python.exe scripts/build.py --profile xaga `
  --tee "$inputDir\tee.img" --lk "$inputDir\lk.img" --check-only
```

`--check-only` の挙動：

- ✅ TEE/LK パッチのオフライン回帰を実行（PC/SPSR、実際の ATF/LK tag parser、共有 flags、GZ gate、および意図的に作った誤った反例）
- ❌ 署名モードを**検出せず**、イメージを**生成せず**、pwnage を**呼び出さない**

**オフライン回帰で確認する項目**（本機のレポートは **14/14 通過**）：

| 検査項目 | 結果 |
|---|---|
| PC / SPSR の状態 | ✓ |
| ATF tag parser | ✓ |
| LK tag parser | ✓ |
| 共有 flags | ✓ |
| GZ gate | ✓ |
| 意図的に作った誤った反例（拒否されるべき） | ✓ |

> ⚠️ レポートの「14 件の記録」は**境界付きの検査記録であり、14 回の実機起動テストではありません**。
> オフラインの `VALID` ≠ デバイスが起動できるという意味ではありません。

---

## 5. 第二段階：preloader の署名モードを検出する

署名方式は **preloader の証明書走査モードに依存**するため、ツール内の検出器で先に確認します：

```bash
.venv/bin/python scripts/detect_pl_cert_mode.py \
  "$HOME/private-firmware/xaga/preloader.bin" --json
```

既定では完全な証拠（逆アセンブリを含む）が `logs/` 配下の新しいファイルに書き出されます。このディレクトリは
Git で無視されています。

| 検出結果 | 対応する pwnage の引数 |
|---|---|
| **`new`：`NEW_PARSER`** | **モード引数を追加しない**（`--legacy` も `--new` も付けない） |
| **`legacy`：`LEGACY`** | **`--legacy` を付ける** |
| `NEED_MANUAL` / 非対応 / 結果不明 | **手を止めて人力で解析**。機種から推測しない |

> 本機（Redmi Note 11T Pro+）の実測は **`LEGACY`** なので `--legacy` を使います。
>
> 「new は何も付けない」とは**モードオプションを増やさない**という意味で、入力ファイルや書き込み
> オプションを省略する意味ではありません。通常の `--all -w -o` はそのまま必要です。
>
> 検出器は**静的証拠の解析**であり、efuse の状態、脆弱性の悪用可能性、実機での起動検証とは別物です。

---

## 6. 第三段階：署名済みコピーをビルドする

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee       "$HOME/private-firmware/xaga/tee.img" \
  --lk        "$HOME/private-firmware/xaga/lk.img" \
  --preloader "$HOME/private-firmware/xaga/preloader.bin" \
  --tools     ../pwnage24mtk \
  --out-dir   outputs/xaga-run-01
```

**注意点**：

- `--preloader` は必須です（署名モードがこれに結び付いています）。スクリプトが検出器を自動で呼ぶので、
  **モードを手で選ぶ必要はありません**
- preloader のハッシュは manifest に記録されますが、**ファイル名だけからデバイスが実際に使っているものと
  一致するとスクリプトが証明することはできません**
- `--out-dir` は**まだ存在しない新しいディレクトリでなければなりません** —— 再実行時は別のディレクトリにし、
  **古い結果を上書きしないでください**。ましてや**署名済み成果物を入力として戻さないでください**

### 出力構成

```text
outputs/xaga-run-01/
  cert-mode.txt          # 検出の完全な証拠
  detect.log             # 検出器の JSON 出力またはエラー
  tee.unsigned.img       # 中間ファイル（署名済み成品ではない！）
  tee_nogz_legacy.img    # LEGACY モード → これが成品
  # tee_nogz_new.img     # NEW_PARSER モードならこれ
  sign.log
  verify.log
  disassembly.txt
  manifest.json
```

**`.img` が存在するかだけで成功を判断しないこと** —— **終了コード、完全なログ、manifest.json** を見ます。

---

## 7. 第四段階：署名検証（VALID が 2 つ必要）

```bash
cd ../pwnage24mtk
python verify_mtk_image.py --all ../outputs/xaga-run-01/tee_nogz_legacy.img
```

**`Result: VALID` が 2 回**出る必要があります（ATF グループ + TEE グループ）：

```
Result: VALID
Result: VALID
```

本機の実測：

| 検査項目 | 結果 |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`** ✓ |
| CERT1 / CERT2 signature | OK ✓ |
| Image header hash / Image data hash | OK ✓ |
| `tee` メンバが変更されたか | **未変更** ✓ |
| ATF と再パッチ結果 | **バイト単位で一致** ✓ |
| 公式の 14 項目回帰 | **14/14 通過** ✓ |

**未検証項目（正直に明記）**：`Trusted root check: skipped`
→ この証明書チェーンに対するデバイス eFuse トラストルートの照合は**オフラインでは検証できず**、
実機起動でしか分かりません。

> ここで使っているのは**サードパーティ製ツールの証明書処理**であり、ベンダーの秘密鍵を所持していることや、
> 新たな公式認可を得たことを意味しません。原理は MTK の ASN.1 証明書解析ロジックの欠陥
> （CVE-2023-20696 と同種。CVE-2025-20730 でようやく修正）です。

---

## 8. 第五段階：「パーティションを 1072 バイト超過」への対処

これは本プロジェクトが踏んだ**最大の罠**で、必ず対処が必要です：

```
未署名 : 5 242 880   (= tee パーティションサイズ、ちょうど埋まる)
署名済 : 5 243 952   (+1072)
```

増加分は **BIT STRING ラッパー（987 B）** + **CERT2 dsize 982→2059（2064 にアライン）** から来ています。

**しかし挿入点は `atf` の後ろなので、末尾のゼロ埋めはまったく変わっていません：**

| メンバ | 未署名 | 署名済 |
|---|---|---|
| `atf` | 0x200 | 0x200（**不変**） |
| `tee` | 0x46440 | 0x46870（+1072） |
| `cert1` | 0x353a40 | 0x353e70（+1072） |
| `cert2` | 0x354310 | 0x354740（+1072） |
| **末尾ゼロ埋め** | 1 751 322 | **1 751 322（不変）** |

末尾に **1.75 MB の全ゼロ**があります → **1072 バイトのゼロ埋めを切ればちょうど 5 MiB で、
実データの損失はゼロ**です。

```bash
# まず超過部分がすべて 0x00 であることを 1 バイトずつ確認
python - <<'PY'
data = open('tee_nogz_legacy.img','rb').read()
tail = data[5242880:]
print('超過バイト数:', len(tail), ' 非ゼロバイト数:', sum(1 for b in tail if b))
PY

# すべてゼロだと確認できたら切る
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
sha256sum tee_nogz_flash.img
```

**超過部分に非ゼロバイトがあれば → 手を止めて人力で解析。無理に切らないこと。**

ワンクリックスクリプトはこれを自動で行い、**必ず全ゼロを検証してから切る**ようにしています。

---

## 9. 第六段階：書き込みと実機検証

この部分は [01-enable-kvm.md](01-enable-kvm.md) の第 5・6 節を参照：

```
dd で tee_a に書き込み  →  読み戻して sha256 照合  →  再起動  →  /dev/kvm 出現
                                                    ↘  expdb に [SBC] image atf header auth pass
```

**成品の参考値**（Redmi Note 11T Pro+）：

| ファイル | サイズ | sha256 |
|---|---|---|
| `tee_nogz_legacy_5M.img`（パッチ版、パーティションサイズに調整済み） | 5 242 880 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `tee_a.img`（純正、ロールバック用） | 5 242 880 | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

---

## 10. 他の MTK 機種に適合させたい場合

上流の要求：**新しいバージョンは完全な SHA-256 ペアを提供しなければならない**。`references/adaptation.md` を参照。

> **既存のハッシュを書き換えたり、アサーションを削除してバージョンチェックを回避しないこと。**

おおよその流れ：

1. 対象デバイスから `tee` / `lk` / `preloader` を dump
2. SHA-256 を計算し、`references/profiles.json` の解析済みサンプルと比較
3. 一致しなければ → `references/adaptation.md` に従って**新しい profile を追加**する必要がある
   （ATF/LK のオフセットと命令を理解する必要があります）
4. `--check-only` の回帰を実行 → その後に署名フローへ

**同型機でもファームウェア版が違えば一致しないことがあります** —— これは「正確なファームウェアサンプル」
レベルのツールで、曖昧なマッチングの余地はありません。

---

## 11. 検証の境界（必読）

上流が明示している境界をそのまま引用します（重要。過剰に解釈しないこと）：

- 既知イメージの回帰は PC/SPSR、実際の ATF/LK tag parser、共有 flags、GZ gate、意図的に作った誤った反例を検査する。
- レポートの 14 件の記録は**境界付きの検査記録であり、14 回の実機起動テストではない**。
- CPU 特性、CurrentEL、一部のシステムレジスタとキャッシュ保守は**明示的にモデル化**されているが、
  完全な LK 初期化、Linux、実際の ERET、PSCI、ペリフェラルは**実行していない**。
- オフライン署名検証が `Trusted root check: skipped` を示す場合、**デバイスのトラストルートは未検証のまま**である。
- CI に実ファームウェアは含まれず、`build.py --check-only` の既知イメージ回帰を**代替できず**、
  まして**ハードウェア互換性を証明できない**。

**報告の際は以下を区別して明記してください**：入力の同一性、オフライン結果、実際のデバイスからの
フィードバック、未検証項目。

---

## 12. 上流ツールの既知バグ（PR 提出済み）

`scripts/build.py:340` は `sign_all_flag(args.tools)` を呼びますが、**ファイル全体にこの関数の定義がありません**
→ 署名経路を通れば必ず `NameError` になります。`--check-only` は途中で return するため露見していませんでした。

（また、`sign_mtk_cert.py` 自体に `--all` 引数が無いので、この関数は本来 `[]` を返すべきです。）

修正は本リポジトリの [issues/tee-nogz-1-sign-all-flag.md](../issues/tee-nogz-1-sign-all-flag.md) を参照。
