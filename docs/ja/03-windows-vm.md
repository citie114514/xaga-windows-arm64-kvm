# Windows 11 ARM64 ディスク —— 作製手順

[中文](../03-windows-vm.md) | [English](../en/03-windows-vm.md) | **日本語** | [Русский](../ru/03-windows-vm.md)

> 目標：仮想マシンをインストールせず、VM 内でインストーラーを走らせず、PC 上で直接
> **起動可能・ドライバ注入済み・TPM チェック回避済み**の VHDX を作る。

**なぜこの方法か**：ARM エミュレーション環境で Windows インストーラーを走らせるのは性能地獄
（数時間かかる）。イメージを PC 上で直接「展開」し、スマホには OOBE を 1 回だけやらせることで、
時間の大部分を節約できます。

---

## 0. 用意するもの

| 材料 | 説明 |
|---|---|
| **Windows 11 ARM64 ISO** | **必ず ARM64**！x64 は ARM 上ではソフトウェアエミュレーションのみで無意味 |
| **virtio-win ISO** | [fedorapeople](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) からダウンロード |
| PC | Windows、管理者権限、**空き 30 GB 以上** |
| 7-Zip | ドライバ抽出用 |

> ⚠️ **virtio-win のダウンロードは必ず完全性を検証してください**。プロキシ経由だと途中で切れることが多く、
> 切り詰められた ISO でも「開く」ことはできてしまいますが中身のデータが読めません
> （ツールのエラーとして現れ、ツール側の問題と誤診しやすい）。
> 検証方法：ISO の PVD を読む（オフセット `16 × 2048`、ボリュームサイズは `pvd[80:84]` の
> little-endian u32 × 2048）と、ファイルの実際のサイズを比較します。
> 本プロジェクトの `scripts/extract-virtio.ps1` が自動でこの検査を行います。

---

## 1. ワンクリック作製（推奨）

```powershell
# 管理者 PowerShell

# ① virtio ARM64 ドライバを抽出
.\scripts\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11

# ② ISO から起動可能な VHDX を作る
.\scripts\build-windows-vhdx.ps1 `
    -Iso D:\Win11_ARM64.iso `
    -DriversDir .\virtio-arm64-w11 `
    -Out .\win.vhdx `
    -SizeGB 100
```

`build-windows-vhdx.ps1` は次の 6 つを自動で行います（各段階で検証あり）：

```
[1] ISO をマウントし、イメージを列挙し、ARM64 のものを自動選択（アーキテクチャを間違えると即エラー中止）
[2] 動的 VHDX を作成 + パーティション：MSR(16M) + Windows(NTFS) + ESP(FAT32, 300M)
[3] dism /Apply-Image /Compact:ON   （CompactOS 圧縮。実測で約 10 GB しか使わない）
[4] bcdboot G:\Windows /s S: /f UEFI   ← 最も忘れられやすい工程
    bootmgfw.efi の PE machine == 0xAA64 を検証
[5] LabConfig をオフライン注入して TPM/SecureBoot/RAM チェックを回避
[6] dism /Add-Driver で ARM64 virtio ドライバを再帰的に注入し、viostor が入ったことを確認
```

---

## 2. 手作業の手順（細部を知りたいとき）

### 2.1 ディスク作成 + パーティション

Dism++ か diskpart で **100 GiB の動的 VHDX** を作り、GPT でパーティションを切ります：

| パーティション | サイズ | 種類 | ドライブ文字（例） |
|---|---|---|---|
| MSR | 16 MB | Microsoft Reserved | — |
| Windows | 残り | NTFS | `G:` |
| **ESP** | 300 MB | **FAT32 / EFI System** | `S:` |

### 2.2 イメージを展開

```powershell
# まずイメージ一覧と、どれが ARM64 かを見る
dism /Get-WimInfo /WimFile:G:\..\install.wim     # または ISO マウント後の sources\install.wim

# 展開（CompactOS 圧縮）
dism /Apply-Image /ImageFile:D:\sources\install.wim /Index:3 /ApplyDir:G:\ /Compact:ON
```

> ISO 内が `install.esd`（wim でない）場合は、追加で `/Compress:recovery` が必要です。

### 2.3 ブートファイルの書き込み —— **最大の罠**

**Dism++ などで展開したディスクは、ESP が完全に空です**：

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING      ← これ
```

ブートファイルを書かないと、起動時は「起動可能なデバイスが見つからない」だけになります。

**朗報：x64 の `bcdboot` でも ARM64 イメージにブートファイルを書けます**。`bootaa64.efi` を自動選択します：

```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```

ログで ARM64（`bootaa64.efi`）を認識しているのが分かります：

```
BFSVC: Updating \\?\GLOBALROOT\Device\HarddiskVolume10\EFI\Boot\bootaa64.efi
BFSVC: Copy files which lack a version: y  G:\Windows\boot\EFI -> ...\EFI\Microsoft\Boot
```

完了後のチェックリスト（**すべて通ること**）：

| 検査 | 期待 |
|---|---|
| `S:\EFI\Boot\bootaa64.efi` | 存在（フォールバック起動パス） |
| `S:\EFI\Microsoft\Boot\bootmgfw.efi` | 存在 |
| `bootmgfw.efi` の PE machine | **`0xAA64`（ARM64）** ← でないと起動しない |
| `S:\EFI\Microsoft\Boot\BCD` | 存在 |
| BCD の `path` | `\Windows\system32\winload.efi` |

### 2.4 TPM / SecureBoot / RAM チェックの回避

Windows 11 は初回起動でハードウェア要件を検査します。レジストリをオフラインで書いて回避します：

```powershell
reg load HKLM\OFFLINESYS G:\Windows\System32\config\SYSTEM
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f
}
reg query 'HKLM\OFFLINESYS\Setup\LabConfig'
reg unload HKLM\OFFLINESYS
```

これを書かないと、起動の最初の段階で「この PC は Windows 11 を実行する最小要件を満たしていません」で
止まります。

### 2.5 virtio ドライバの注入

**ディレクトリ名に意味があります**（ISO 内から目的のものを探す鍵）：

```
virtio-win.iso
├── Balloon\w11\ARM64\      balloon.sys  blnsvr.exe
├── NetKVM\w11\ARM64\       netkvm.sys
├── viostor\w11\ARM64\      viostor.sys     ← virtio-blk を起動ディスクにするなら**必須**
├── vioscsi\w11\ARM64\      vioscsi.sys
├── vioinput\w11\ARM64\     vioinput.sys  viohidkmdf.sys
├── viogpudo\w11\ARM64\     viogpudo.sys   ← virtio-gpu の表示ドライバ
├── vioserial\w11\ARM64\    vioser.sys
├── viomem\w11\ARM64\ / viorng\w11\ARM64\ / viosock\w11\ARM64\ / viofs\w11\ARM64\ / pvpanic\w11\ARM64\
```

- ARM64 ディレクトリの名前は **`ARM64`**（`aarch64` ではありません！ここで見つけられない人が多い）
- Windows 11 は **`w11`** サブディレクトリ（Win10 は `w10`）

注入：

```powershell
dism /Image:G:\ /Add-Driver /Driver:D:\virtio-arm64-w11 /Recurse
```

成功時の出力：

```
操作は正常に完了しました。12 個中 12 個のドライバーがインストールされました。
```

**注入後は必ず `.sys` が ARM64 PE であること**（machine = `0xAA64`）を検証してください：

```
Balloon      balloon.sys      ARM64 ✓
NetKVM       netkvm.sys       ARM64 ✓
pvpanic      pvpanic.sys      ARM64 ✓
viofs        viofs.sys        ARM64 ✓
viogpudo     viogpudo.sys     ARM64 ✓
vioinput     viohidkmdf.sys   ARM64 ✓
vioinput     vioinput.sys     ARM64 ✓
viomem       viomem.sys       ARM64 ✓
viorng       viorng.sys       ARM64 ✓
vioscsi      vioscsi.sys      ARM64 ✓
vioserial    vioser.sys       ARM64 ✓
viosock      viosock.sys      ARM64 ✓
viostor      viostor.sys      ARM64 ✓      ← 合計 13 個の .sys、すべて 0xAA64
```

---

## 3. スマホに転送して起動

```bash
# 転送（USB の方が速い。 /data/media/0 は root が必要なので /data/local/tmp に送ってから移動）
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'

# 容量を確認（実使用量は ~23 GB まで増える）
adb shell su -c 'df -h /data | tail -1'
```

その後：

```bash
# scripts/phone/boot-win.sh をスマホへ
adb push scripts/phone/boot-win.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/boot-win.sh && nohup /data/local/tmp/boot-win.sh > /data/local/tmp/boot.out 2>&1 &'

# 画面を見る
adb forward tcp:5900 tcp:5900
# VNC クライアントで 127.0.0.1:5900 に接続（パスワード無し）
```

### 初回起動（OOBE）

**5〜15 分**かかり、途中で 1〜2 回自力で再起動します（再起動後に画面が一瞬暗くなることがありますが正常です）。

**重要なページ**：

| 手順 | ページ | やり方 |
|---|---|---|
| 1 | 国または地域は合っていますか？ | 選択 → はい |
| 2 | キーボードレイアウト | 選択 → はい |
| 3 | 2 つ目のキーボードレイアウト | スキップ |
| 4 | **ネットワークに接続しましょう** | **「インターネットに接続していません」** → **「制限付きセットアップを続行」** ← これで**ローカルアカウント**を作れます（Microsoft アカウント不要） |
| 5 | ライセンス条項 | 同意 |
| 6 | このデバイスを使うのは誰ですか？ | ユーザー名を入力。**パスワードは空**が一番楽 |
| 7 | プライバシー設定 | すべてオフ → 同意 |
| 8 | 🎉 デスクトップ | 初回のデスクトップ表示にはさらに数分かかります |

**手順 4 に「インターネットに接続していません」が無い場合**：
`Shift + F10` でコマンドプロンプト → `oobe\bypassnro` と入力 → 自動で再起動し、その後このページに
スキップ項目が現れます。

### インストール後の推奨

- **バルーン メモリ サービスを入れる**（余ったメモリを Android に返します。スマホではこれが非常に貴重）：
  `virtio-win.iso` を光学ドライブとして挿す（`boot-win.sh` が `/data/local/tmp/virtio-win.iso` を
  自動で挿します）→ Windows でドライブを開く → `Balloon\w11\ARM64\blnsvr.exe` → インストール
- **視覚効果を切る**（ソフトウェアレンダリングでは体感差が大きい）：システムのプロパティ → 詳細設定 →
  パフォーマンス → パフォーマンスを優先する

---

## 4. 「guest tools」に関する重要な事実

**virtio-win に ARM64 版の guest tools インストーラーはありません。** ISO を全走査した結果：

```
guest-agent\qemu-ga-i386.msi        ← x86 のみ
guest-agent\qemu-ga-x86_64.msi      ← x64 のみ
virtio-win-gt-x64.msi               ← x64 のみ
virtio-win-gt-x86.msi               ← x86 のみ
virtio-win-guest-tools.exe          ← これが入れるのも上記
```

**したがって ARM64 の guest tools MSI を探すのは時間の無駄です —— 存在しません。**

ARM64 ディレクトリにあるのは**ドライバ本体**と、いくつかの**使える補助 EXE** だけです：

| ファイル | 用途 |
|---|---|
| `blnsvr.exe` | バルーン メモリ サービス（**入れる価値あり**） |
| `vgpusrv.exe` / `viogpuap.exe` | virtio-gpu のユーザー空間コンポーネント |
| `virtiofs.exe` | virtio-fs 共有ディレクトリ（QEMU 側に `vhost-user-fs` の設定が必要） |
| `netkvmco.exe` / `netkvmp.exe` | ネットワークカード設定ツール |
| `qemu-ga` | ❌ **ARM64 版なし** |

**中核となるドライバ注入は 2.5 で完了しています**。それで十分です。

---

## 5. virtio ディスクを使わない選択肢

可能です。**Windows 11 ARM64 は NVMe（`stornvme`）ドライバを内蔵**しているので、NVMe を起動ディスクにすれば
**注入ゼロ**で起動できます：

```
-device nvme,serial=win,drive=nv0
```

**トレードオフ**：

| 方式 | ドライバ注入 | 速度 | 説明 |
|---|---|---|---|
| **virtio-blk**（本プロジェクトの既定） | ✅ `viostor` が必要 | 速い | 注入済みなら問題なし |
| NVMe | ❌ 不要 | これも速い | 注入ゼロの保険 |
| IDE/AHCI | ❌ | 遅い | 非推奨 |

**推奨**：ドライバを注入している以上 `virtio-blk` を使いましょう（ネットワーク・GPU・バルーンと
同じ系統で最も綺麗です）。まず「ディスクが起動するか」を確かめたい場合は、NVMe でドライバ要因を
切り分けられます。

---

## 6. 次のステップ

- **QEMU の引数の調整方法** → [04-usage.md](04-usage.md)
- **問題が起きたら** → [05-gotchas.md](05-gotchas.md)
