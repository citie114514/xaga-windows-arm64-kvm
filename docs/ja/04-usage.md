# 使い方

[中文](../04-usage.md) | [English](../en/04-usage.md) | **日本語** | [Русский](../ru/04-usage.md)

本稿で扱うのは：**起動方法**、**QEMU の各引数の意味**、**画面の見方**、**ネットワークの通し方**、
**性能の調整方法**です。

---

## 1. 起動

```bash
# スマホに転送した後で実行（root が必要）
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
```

スクリプトは **VNC ポート 5900 を固定**し、次のことを行います：

```
[1] 古いインスタンスを掃除（ポートが埋まると QEMU が黙って 5901 に移るため）
[2] 5900 が本当に空くのを待つ（最大 30 秒、超えたら妥協せず終了）
[3] QEMU を起動（コア固定 + 最適化済みの引数一式）
[4] 実際の待ち受けポート == 5900 を確認（違えばエラー終了）
```

**なぜポートを確認するのか**：QEMU の `-vnc host:N` の `N` は **display 番号**で、ポート = `5900 + N`。
5900 が埋まっていると、**QEMU はエラーを出さず display 番号を +1 してしまう** → 5901 ✗
したがってスクリプト側で能動的に待ち、確認する必要があります。

停止：

```bash
adb shell su -c 'sh /data/local/tmp/stop-vm.sh'   # 短いプロセス名で照合するため pkill -f の自殺を避けられる
```

---

## 2. 画面を見る（VNC）

```bash
adb forward tcp:5900 tcp:5900
# 任意の VNC クライアントで 127.0.0.1:5900 に接続（パスワード無し）
```

コマンドラインでフレームを取得（クライアントを開かずにスクリーンショット/調査したいとき）：

```bash
python scripts/vncgrab.py        # vnc-0.png / vnc-1.png に保存
python scripts/vncprobe.py       # VNC の実スループットを測定
python scripts/vncinput.py       # キーを 1 回送ってゲストが反応するか確認
```

**もっと滑らかにしたい場合**：`boot-win.sh` にはすでに `lossy=on`（JPEG 非可逆圧縮）が入っています。
実測で 1 フレームあたり **3.00 MB → 0.36 MB（1/8.3）** になります。これが最大の一手です。

---

## 3. QEMU の引数を 1 つずつ解説

```bash
Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=/data/media/0/DroidVM/win.vhdx

export LD_LIBRARY_PATH=/system/lib64        # ← 必須！ないとリンカ名前空間がシステムライブラリを見つけられない

taskset f0 "$Q" \                           # ← 必須！A78 クラスタに固定し big.LITTLE の競合を避ける
  -name win -L /data/data/cn.classfun.droidvm/usr/share/qemu \
  -accel kvm -machine virt -cpu host \
  -smp 4,sockets=1,cores=4,threads=1 -m 4096M \
  -bios "$FW" \
  -drive file="$DISK",if=none,id=nv0,format=vhdx,cache=writeback,aio=threads \
  -device virtio-blk-pci,drive=nv0,disable-legacy=on,disable-modern=off,bootindex=1 \
  -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-balloon-pci,disable-legacy=on,disable-modern=off \
  -device qemu-xhci,id=xhci \
  -device usb-tablet -device usb-kbd \
  -device virtio-gpu-pci,disable-legacy=on,disable-modern=off,xres=1920,yres=1080,edid=on \
  -vnc 127.0.0.1:0,lossy=on \
  -display none -nodefaults
```

| 引数 | 役割 / 注意 |
|---|---|
| `LD_LIBRARY_PATH=/system/lib64` | DroidVM の QEMU に必要。ないとシステムライブラリが見つからない |
| `taskset f0` | CPU 4-7（A78 クラスタ）に固定。**固定しないとランダムに失敗する**（[01-enable-kvm.md](01-enable-kvm.md) の付録参照） |
| `-accel kvm` | ハードウェアアクセラレーション（tee を焼く目的そのもの）。`tcg` は遅すぎて使えない |
| `-machine virt` | ARM の汎用仮想プラットフォーム |
| `-cpu host` | ホスト CPU の機能を透過。**taskset と併用が必須** |
| `-smp 4` | vCPU 4 個。この端末は 4×A78 なので、**それ以上は A55 に回されて遅くなる** |
| `-m 4096M` | メモリ 4 GB。スマホでは 4G を超えない方がよい |
| `-bios "$FW"` | **標準の AAVMF であること** —— DroidVM 同梱の改造版は QEMU 上でスピンして止まる |
| `-drive ... format=vhdx` | **QEMU は VHDX を直接読み書きできる** ✓ 変換不要 |
| `cache=writeback` | 折衷案。速さ優先なら `cache=unsafe`（ただし停電で破損し得る） |
| `aio=threads` | 非同期 IO をスレッドプールで（FUSE 上では native より安定） |
| `if=none` + `-device` | モダンな書き方：先にバックエンドを定義し、デバイスにぶら下げる |
| `disable-legacy=on,disable-modern=off` | virtio 1.0（modern）のみ。Windows ドライバは modern が必要 |
| `bootindex=1` | 起動優先度（AAVMF が無視することもあるが、書いて害はない） |
| `-netdev user,id=n0` | **ユーザーモード NAT（slirp）**。VM のネット接続はこれ |
| `-device virtio-net-pci` | ネットワークカード。ドライバは `NetKVM`（注入済み） |
| `-device virtio-balloon-pci` | バルーン メモリ。ゲストに `blnsvr` を入れると余ったメモリを Android に返せる |
| `-device qemu-xhci,id=xhci` | USB コントローラ。**バス名は `xhci.0` であって `xhci` ではない** |
| `-device usb-tablet` | 絶対座標マウス（**`bus=` を書かず自動でぶら下げる**。`bus=usb` はエラー） |
| `-vnc 127.0.0.1:0,lossy=on` | display 0 → ポート **5900**。`lossy=on` で JPEG 圧縮 |
| `-display none -nodefaults` | ローカル表示なし、既定デバイスなし（最小化で省リソース） |

### 任意：ドライバ CD を挿す

```bash
if [ -f /data/local/tmp/virtio-win.iso ]; then
  set -- "$@" -drive file=/data/local/tmp/virtio-win.iso,if=none,id=cd0,media=cdrom,readonly=on \
              -device usb-storage,drive=cd0,removable=on
fi
```

> ✅ `virtio-win.iso` は**純粋なデータディスク**（El Torito も EFI 起動も無い）なので、挿しても**安全**で、
> 起動を奪いません。
> ❌ **Windows インストール ISO は挿さないこと** —— あれは起動可能で、システムディスクと起動を奪い合います。

---

## 4. ネットワーク

起動スクリプトには **QEMU ユーザーモード NAT（slirp）** がすでに設定されています：

| 項目 | 値 |
|---|---|
| VM の IP | `10.0.2.15` |
| ゲートウェイ | `10.0.2.2` |
| DNS | `10.0.2.3` |
| 外向き | ✅ 公網に出られる |
| 内向き | ❌ 外から入れない（NAT の性質） |

ドライバは `NetKVM`（注入済み）なので、**Windows 側はドライバ不要でそのまま使えます**。

**ネットワークが本当に通っているか確認**（PC 側で QEMU プロセスの外向き接続を見る）：

```bash
adb shell su -c 'ss -tnp | grep qemu | grep -v 127.0.0.1'
# ESTAB  192.168.31.75:44394  ->  204.79.197.235:443      ← Microsoft
```

VM 側の確認：Edge でネットが見えれば OK。

> **ヒント**：デスクトップに入る前に時刻が異常（例：2768 年）でも、
> **ネットが繋がれば Windows の NTP が自動で直します**。

---

## 5. 性能チューニング

### 実測データ（当て推量を避ける）

| 項目 | 実測値 | 結論 |
|---|---|---|
| **VNC `lossy=on`** | 1 フレーム **3.00 MB → 0.36 MB（1/8.3）** | ✅ 最大の一手。必ず有効化 |
| **adb 転送トンネルのスループット** | **276 MB/s** | ❌ **ボトルネックではない**。ネットワークをいじるのは無駄 |
| 解像度 1080p vs 720p | ピクセル数が 2.25 倍 | レンダリングとエンコードのコストに影響 |
| CPU コア固定 | 成功率 2/5 → **3/3** | ✅ 必須 |

### 調整できるつまみ

| こうしたい | やり方 |
|---|---|
| **より滑らかに** | 解像度を 1280×720 に落とす（`xres=1280,yres=720`）。Windows 側で視覚効果を切る |
| **メモリを節約** | ゲスト側に `blnsvr.exe` を入れ、バルーンで余ったメモリを Android に返す |
| **ディスクを速く** | `cache=unsafe`（⚠️ 停電でファイルシステムが壊れ得る） |
| **CPU を強く** | `-smp` は **4 を超えない** —— それ以上は A55 に回されてむしろ遅くなる |
| **メモリを増やす** | `-m` は 6G まで可能だが、スマホ自身もメモリを使うため OOM を誘発しやすい |

### 滑らかさの本当の鍵：表示経路

```
本機ネイティブ表示（スマホ上で直接見る）  → 最も滑らか
localhost VNC（本機ループバック）          → とても滑らか
adb 転送 + PC 上の VNC クライアント        → 遅延を感じる（本プロジェクトの既定）
```

**なぜカクつくのか**：QEMU の VNC エンコードはメインスレッドで動き、`taskset f0` が全スレッドを
A78 クラスタに固定するため、VNC スレッドは 4 つの vCPU と**同じ 4 コアを奪い合います**。

**試す価値のある案**（本プロジェクトでは十分に検証していない。フィードバック歓迎）：

- QEMU の補助スレッド用に 1 コア残す：`-smp 3`
- `-cpu cortex-a78`（CPU 型番を固定し host 透過の big.LITTLE 競合を避ける）+ `taskset` を外し、
  QEMU のスレッドを 8 コアに分散させる

**Android 上でもっと滑らかにしたい場合**：DroidVM アプリの `native` 表示を使う
（画面をスマホのスクリーンに直接描画し、ネットワークを一切経由しません ——
[kde-yyds](https://space.bilibili.com/2008726064) の動画にある「本機で見るととても滑らか」な効果です）。

---

## 6. 日常メンテナンス

### バックアップ / スナップショット

`win.vhdx` は Windows システムそのものなので、**必ずバックアップを取ってください**。

```bash
# スマホ上で圧縮スナップショットを作る（VM は停止していること。でないとスナップショットが壊れる）
adb shell su -c 'export LD_LIBRARY_PATH=/system/lib64; \
  /data/data/cn.classfun.droidvm/usr/bin/qemu-img convert -c -o compression_type=zstd \
  /data/media/0/DroidVM/win.vhdx /data/local/tmp/win-snapshot.qcow2'
```

- **`-c` + zstd**：約 40 分（CPU 律速）
- **`-c` なし**：約 90 秒だが、ファイルが 2 GB ほど大きい
- 生成物はそのまま qcow2 ディスクとして使え（`format=qcow2`）、`qemu-img convert` で vhdx に戻すこともできる

### ディスクの復元 / 入れ替え

バックアップイメージを `win.vhdx` の位置に戻します。`restore-disk.sh` を使うと：

1. ファイルヘッダを読んで**形式を自動判別**（VHDX / QCOW2 / VHD）
2. `/data` の空き容量と比較し、足りなければ書きかけで失敗させずエラーにする
3. 既存のターゲットがある場合は**先に警告してから上書き**（3 秒で Ctrl-C 可能）
4. コピー後に **sha256 検証**

```bash
adb push win.vhdx /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/restore-disk.sh /data/local/tmp/win.vhdx'
```

> ⚠️ **直接** `adb push win.vhdx /data/media/0/DroidVM/` **はしないこと** ——
> あのディレクトリは通常の adb 権限では書けず（root 専用）、`permission denied` になります。
> 必ず `/data/local/tmp` に転送し、root で移動してください。`restore-disk.sh` は既に対応済みです。

**QCOW2 ディスクの場合**（上の圧縮スナップショットから復元する場合など）は、`boot-win.sh` の
`format=vhdx` を `format=qcow2` に変更してください。でないと QEMU が開くのを拒否します。

### 現在の状態を確認する

```bash
# 動いているか
adb shell su -c 'pgrep qemu-system-aar | wc -l'

# VNC が 5900 か
adb shell su -c 'netstat -tln | grep 5900'

# 最後の起動ログ（引数もエラーもここにある）
adb shell su -c 'tail -40 /data/local/tmp/win-qemu.log'

# シリアルログ（Windows の起動初期はここに何か出る）
adb shell su -c 'tail -40 /data/local/tmp/win-serial.log'
```

### 空き容量

システムディスクの実使用量は **およそ 23 GB** まで育ちます（100 GiB の動的ディスク）。
バックアップも考えると、スマホの `/data` は **40 GB** 以上空けておくと安心です。

```bash
adb shell su -c 'df -h /data | tail -1'
```

---

## 7. 次のステップ

- **トラブルシュート** → [05-gotchas.md](05-gotchas.md)
- **メインライン Linux + KDE に進みたい** → [06-mainline.md](06-mainline.md)
