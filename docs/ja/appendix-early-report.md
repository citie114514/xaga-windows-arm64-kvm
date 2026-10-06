# xagapro（Redmi Note 11T Pro+）MTK NoGZ → KVM 実現可能性報告

[中文](../appendix-early-report.md) | [English](../en/appendix-early-report.md) | **日本語** | [Русский](../ru/appendix-early-report.md)

日付：2026-10-04
デバイス：`192.168.31.75:33445`（1 台目、**何も書き込んでいない**、終始読み取りのみ）
状態：**オフライン検証はすべて通過。実機書き込みの可否を判断待ち**

---

## 1. デバイスの事実（読み取りのみの調査）

| 項目 | 値 |
|---|---|
| 型番 | 22041216UC / `xagapro` / 市場名 **Redmi Note 11T Pro+** |
| SoC | MT6895（Dimensity 8100：4×A78 + 4×A55） |
| システム | HyperOS 3、`OS3.0.1.0.VLHCNXM`、Android 15 |
| カーネル | `5.10.247-android12-9-Pandora-26w08d`（サードパーティ Pandora カーネル） |
| Root | **あり**、KernelSU（`uid=0(root) context=u:r:ksu:s0`） |
| ブートローダー | **アンロック済み**（`ro.boot.flash.locked=0`、`verifiedbootstate=orange`） |
| 現在のスロット | `_a` |
| RAM | 7.68 GiB → **8 GiB 版**（12 GiB ではない） |
| userdata | 226 G、使用 204 G、空き 21 G（**厳しい。rootfs を作る前に整理が必要**） |
| `hwid` | sku=xagapro country=CN level=MP version=4.9.0 project_adc=701 |

カーネル内蔵の機能（`/proc/config.gz` より）：

```
CONFIG_ARM64_VHE=y          ← 重要：カーネルが VHE に対応し EL2 で動作できる
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_ARM_GIC_V3=y         ← vGIC のハードウェア基盤
CONFIG_ARM_GIC_V3_ITS=y
CONFIG_ARM64_VA_BITS=39
```

現在 `/dev/kvm` は**存在せず**、`kvm` モジュールはカーネルに組み込まれていますが、
カーネルが EL1 で動作しているため初期化に失敗しています。
`/sys/module/` 配下に `gz_main_mod` `gz_trusty_mod` `gz_tz_system` `gz_ipc_mod`
`gz_irq_mod` `gz_virtio_mod` がある → **GenieZone が EL2 を占有している** —— 理論と完全に一致します。

---

## 2. 公式スクリプトが即座に拒否する理由

`mtk-mod-tee-nogz` は 3 つの profile しか知らず、いずれも `tee.img`/`lk.img` の完全な SHA-256 で
厳密照合します：

| profile | 対象機種 | 本機に一致するか |
|---|---|---|
| `yunluo` | — | ❌ |
| `peral` | Xiaomi 13T | ❌ |
| `xaga` | Redmi Note 11T Pro / POCO X4 GT | ❌ |

本機の実測（`/dev/block/by-name/` から直接 sha256）：

```
tee_a (5 MiB) = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_a  (8 MiB) = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3
tee_b         = f8f286f1... (tee_a と同一)
lk_b          = 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0
gz_a          = 3f829d4061b1cc00d6bbcd1cafa3263348ec75800c9654cd936410c4d26572f6
```

xaga profile と比較して：
- `tee_sha256 = bd4b13a7…` ❌
- `lk_sha256 = 03856964…` ❌

**結論：そのまま流用はできない。xagapro 用に新しい profile を追加する必要がある
（＝上流リポジトリの `docs/adaptation.md` に記述された適合作業）。**

朗報：構造的には極めて近く、**ATF は同一ソースのビルド成果物**で、一部の関数オフセットが違うだけです。

---

## 3. リバースした xagapro profile（公式回帰で検証済み）

### 3.1 位置特定の根拠（逆アセンブリの証拠）

| 項目 | xaga | **xagapro（本機）** | 根拠 |
|---|---|---|---|
| `pc_patch` | 0x1ad9c | **0x1ade0** | `ldr x8,[x1,#0x10]` → `mov x8,#0x50f00000` に変更 |
| `kernel_patch` | 0x64a4 | **0x64a4** | `csel w12,w13,w12,eq` → `mov w12,#0x3c9`(EL2h) に変更 |
| `getter` | 0xe5f8 | **0xe560** | `adrp x8,0x48244000; ldr w8,[x8,#0xf00]; mvn w8,w8; and w0,w8,#1; ret` = 文書化された `(~flags)&1` |
| `callback` | 0xdf14 | **0xde7c** | getter への delta = **0x6e4（xaga と完全に同一）** |
| `flag` | 0x45f08 | **0x44f00** | callback: `adrp x9,0x48244000; str w8,[x9,#0xf00]` |
| `ep` | 0x53930 | **0x52930** | `add x14,x14,#0x938` → x14 = ep+8；PC は ep+8、SPSR は ep+16 に書き込み、TF-A の `entry_point_info` レイアウトに合致 |
| `kernel_args` | 0x539e0 | **0x529e0** | = ep + 0xB0（xaga と同じ delta） |
| `handoff_global` | 0x53af0 | **0x52af0** | args_getter case0: `adrp x8,0x48252000; ldr x0,[x8,#0xaf0]` |
| `cold` | [0x1ad74,0x1adf8] | **[0x1adb8,0x1ae3c]** | 関数は `stp x29,x30` で始まり `ret` で終わる |
| `cold_helpers` | [0xb6e8,0xb700] | **[0xb6bc,0xb6d4]** | 2 つの小さな `adrp/ldr/ret` 関数 |
| `kernel` | [0x6454,0x6538] | **[0x6454,0x6538]** | 完全に同一 |
| `tag_parser` | [0x6688,0x68e8] | **[0x6688,0x68f0]** | 開始は完全に一致 |
| `args_getter` | [0xb7fc,0xb858] | **[0xb7d0,0xb800]** | ジャンプテーブル ディスパッチャ + case0 |
| `lk_*`（13 項目） | — | **xaga と完全に同一** | 下記参照 |

**LK 側はすべて同一オフセットに命中し、命令語も一致**：`lk_illegal=0x3a18` はまさに
`mrs x9,cptr_el3`；`lk_elcheck` の開始 `0x39c8` は `mrs x4,CurrentEL`；`lk_gate=0x28d4`、
`lk_skip=0x2904`（`mov w0,wzr`）、`lk_getter=0x1e8a8`、`lk_callback=0x1e8bc` もすべて一致。
→ **本機の LK コードセクションは xaga のものと同じビルド**で、外側の証明書/DTB パッケージングだけが
異なります。

### 3.2 検証結果

公式の `scripts/build.py --check-only` を使用（profile 追加 + オフセット修正のみ。判定ロジックは一切改変せず）：

```
passed_checks:
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=False   (4)
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=True    (4)
  missing_tag_defaults
  LK_EL2_illegal_EL3_negative_control
  kernel_feature_and_AArch32_controls
  wrong_PC_negative_control
  missing_tag_sync_negative_control
  budget_exhaustion_rejected
→ 14/14 すべて通過
```

4 つの**反例**（誤った PC、共有 tag の同期漏れ、LK が EL2 から入って CPTR_EL3 を読む、
命令予算の枯渇）も通過しており、パッチの意味論が本当に正しいことを示しています
（「動いたから通す」ではありません）。

### 3.3 成品（未署名）

`tee_nogz_xagapro.unsigned.img`、sha256 `2bcdf7b3bdae3dcc77d570e350a79e5962a46daa7cd19610b022742f8773f413`

10 スロットの実際の変更：

| ATF オフセット | file オフセット | 元の命令 | 新しい命令 |
|---|---|---|---|
| 0x01ade0 | 0x01afe0 | `ldr x8,[x1,#0x10]` | `mov x8,#0x50f00000` |
| 0x0064a4 | 0x0066a4 | `csel w12,w13,w12,eq` | `mov w12,#0x3c9` ← **カーネル引き渡し EL1h → EL2h** |
| 0x00e560 | 0x00e760 | `adrp x8,#0x48244000` | `mov w0,#0` |
| 0x00e564 | 0x00e764 | `ldr w8,[x8,#0xf00]` | `ret` |
| 0x00de7c | 0x00e07c | `ldr w8,[x0]` | `mov w8,#1` |
| 0x00de84 | 0x00e084 | `mov w0,wzr` | `str w8,[x0]` ← **共有 tag flags=1 を書き込み** |
| 0x00de8c | 0x00e08c | `ret` | `b #0x4820e568` |
| 0x00e568 | 0x00e768 | `mvn w8,w8` | `dc cvac,x0` |
| 0x00e56c | 0x00e76c | `and w0,w8,#1` | `dsb sy` |
| 0x00e570 | 0x00e770 | `ret` | `b #0x4820e560` |

---

## 4. 署名の実現可能性（確認済み）

```
detect_pl_cert_mode.py preloader_raw_a.img --json
→ status: LEGACY
   reason: certificate entry uses enter-value traversal (arg4=1); legacy BIT STRING wrapper required
   sha256: 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1
```

結論は明確です（`NEED_MANUAL` ではありません）→ 署名時に pwnage は `--legacy` が必要で、
スクリプトが自動で付けます。

---

## 5. 何が足りないか / リスク

### 5.1 足りないもの
1. **`pwnage24mtk` ツールチェーン**（`sign_mtk_cert.py` / `verify_mtk_image.py`）。リポジトリには同梱されないため、信頼できる副本を自分で用意する必要があります。
2. **実機での起動検証**：本リポジトリの linux ブランチは **xaga** 用です。xagapro は一部のドライバにしか適応がありません（例：`power: mediatek: xagapro: SC8561` 充電）。**パネル/タッチ/充電が異なる可能性 → 起動しないかもしれません**。
3. ディスク容量：残り 21 G しかなく、rootfs 構築には場所の確保が必要です。

### 5.2 リスク（先に腹を括っておくべきこと）
- **`tee` はセキュリティパーティションです。** 誤って書き込む → preloader の署名検証が失敗 → 起動チェーンが断たれる → **EDL でしか救えません**。しかも MT6895 の EDL は通常、認可されたアカウントが必要です。これは現実の文鎮リスクです。
- 反例検査の通過は **≠ 起動できる**。公式自身の声明は
  `device_tested: false` /「オフライン回帰は、デバイスが必ず受け入れる、あるいは起動できることを意味しない」です。
- 両スロット：`tee_a == tee_b`（両方変えないと有効になりません。片方だけではスロットを切り替えると戻ります）。
- **Android 本体への影響は不明**：GZ が無効化されると `gz_*` モジュールはロードされません。`CONFIG_ARM64_VHE=y` ではありますが、MTK の独自ドライバが GZ の存在を前提にしているかは未検証です。

### 5.3 推奨する進め方の順序
1. まず `pwnage24mtk` を入手し、`sign_mtk_cert.py` + `verify_mtk_image.py` を実行して
   **2 つの `Result: VALID`** を要求し、成品に対して 14 項目の回帰をもう一度実行します。
2. そのうえで書き込むか判断します。書き込む場合は現在のスロットの `tee_a` のみに書き、
   EDL/認可ツールが使えること、`misc`/`frp` などのロールバック経路が明確であることを確認します。
3. この profile を上流リポジトリに PR することを検討してください（`docs/adaptation.md` は
   新規バージョンに監査と正例・反例を要求しています）。

---

## 6. バックアップ（本ディレクトリの `backup/` に取得済み）

| ファイル | サイズ | sha256 |
|---|---|---|
| `tee_a.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `tee_b.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `lk_a.img` | 8 MiB | 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3 |
| `lk_b.img` | 8 MiB | 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0 |
| `preloader_raw_a.img` | 4 MiB | 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1 |

---

## 7. 再現コマンド

```bash
git clone --depth 1 https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
# profiles.xagapro.json の内容を references/profiles.json にマージする
# scripts/build.py の --profile choices に "xagapro" を追加する

# 1) オフライン回帰（デバイスに触れない）
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img --check-only

# 2) 署名（自前の pwnage24mtk が必要）
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img \
  --preloader backup/preloader_raw_a.img \
  --tools ../pwnage24mtk \
  --out-dir outputs/xagapro-run-01
```

依存：`pip install capstone unicorn`

---

## 8. 補足証拠（2026-10-04 夜）

### 8.1 KVM が現在使えない理由 —— 実測で確定

```
/proc/misc | grep -i kvm        → 空（46 項目の misc デバイスに 1 つも無い）
/sys/module/kvm/                → parameters/ と uevent のみ。initstate / refcnt が無い
/sys/module/kvm/parameters/     → halt_poll_ns=500000 grow=2 grow_start=10000 shrink=0
/dev/kvm                        → 存在しない
```

`kvm_init()` が完了していません（misc デバイスが登録されていない）。カーネル内に
`kvm_arch_init` / `kvm_init` のシンボルはあり、設定も `CONFIG_KVM=y` なので、
失敗し得る唯一の理由は **カーネルが EL2 にいないこと**です。
3.1 の表の `kernel_patch` のスロット（`csel w12,w13,w12,eq` → `#0x3c9` を強制）と完全に対応します。

### 8.2 パッチは Android にも有効

`kernel_patch` は ATF の「AArch64 カーネル引き渡しヘルパー」にあり、
**カーネル入口の SPSR** を決定します。スロットが違ってもカーネル（Android のものでも mainline のものでも）
は同じ引き渡し点を通るため：

- Android に留まる：Android カーネルも EL2 から起動します。その設定は
  `CONFIG_ARM64_VHE=y` + `CONFIG_VIRTUALIZATION=y` + `CONFIG_KVM=y` なので `/dev/kvm` が出現します。
- mainline を焼く：動画でやっている方法。
- 両立可能（別スロット / `fastboot boot`）。

**推奨する最小検証**：`tee` だけを焼き、Android に再起動して `/dev/kvm` を見る。
この 1 手で ATF の部分を実機で確認でき、コストが最も低い方法です。

Android 側の制約：`/dev/kvm` に SELinux ルールがありません（`su -c` と、場合によっては
`setenforce 0` が必要）。Termux の QEMU には virgl/venus が無く、GPU 加速は使えません。
