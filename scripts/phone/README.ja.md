# スマホ側スクリプト

[中文](README.md) | [English](README.en.md) | **日本語** | [Русский](README.ru.md)

スマホの `/data/local/tmp/` に転送して実行します。**すべて root が必要です。**

| スクリプト | 役割 | 検証 |
|---|---|---|
| [`boot-win.sh`](boot-win.sh) | QEMU + KVM を起動（**VNC を 5900 に固定**、ディスクが無い場合は分かりやすく案内） | ✅ |
| [`stop-vm.sh`](stop-vm.sh) | 安全に停止（短いプロセス名で照合するため、`pkill -f` が自分のシェルを殺す事故を避けられる） | ✅ |
| [`restore-disk.sh`](restore-disk.sh) | バックアップした仮想ディスクを `win.vhdx` に戻す（形式判定 / 空き容量確認 / sha256 検証） | ✅ |
| [`qemu-wrapper.sh`](qemu-wrapper.sh) | **任意**：DroidVM の QEMU をラップし、アプリ自身の設定でも動くようにする | ✅ |

## インストール

```bash
adb push scripts/phone/boot-win.sh scripts/phone/stop-vm.sh scripts/phone/restore-disk.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/*.sh'
```

---

# 2 つの起動経路 —— **どちらか一方にしてください**

## 経路 A：コマンドラインから起動（**推奨**）

```bash
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
adb forward tcp:5900 tcp:5900
# VNC クライアントで 127.0.0.1:5900 に接続
```

| 長所 | 短所 |
|---|---|
| 引数を**完全に制御**でき、ポートは **5900 固定**、DroidVM に左右されない | GUI が無く、引数の変更はスクリプト編集になる |

**この経路は DroidVM の設定管理を完全に迂回します** —— `vms.json` を読まず、アプリに
書き換えられることもありません。

## 経路 B：DroidVM アプリからも起動できるようにする（任意）

DroidVM アプリが生成する設定は**それ自体では動きません**：virtio NIC に `-netdev`
バックエンドを付けず（ゲストにネットワークが無い）、`virtio-balloon` も追加しません
（メモリが増える一方）。

**ラッパースクリプト**で補えます —— アプリが呼ぶ `qemu-system-aarch64` を、
本物の `.real` に転送するラッパーに差し替えます：

```bash
# 1) まず元のバイナリをリネーム（一度だけ）
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 [ -f qemu-system-aarch64.real ] || mv qemu-system-aarch64 qemu-system-aarch64.real'

# 2) ラッパーを転送
adb push scripts/phone/qemu-wrapper.sh /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/qemu-wrapper.sh /data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64'

# 3) パーミッションと所有者を .real に合わせる
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 chmod 755 qemu-system-aarch64 && \
                 chown $(stat -c %u qemu-system-aarch64.real):$(stat -c %g qemu-system-aarch64.real) qemu-system-aarch64 && \
                 ls -l qemu-system-aarch64*'
```

やることは 3 つで、しかも**呼び出し側が既に指定していない場合に限り**補うため、
経路 A を邪魔しません：

```
1) 引数リスト全体を /data/local/tmp/qemu-args.log に記録   ← デバッグ時に非常に有用
2) -netdev user が無ければ追加（id は auto0 なので呼び出し側と衝突しない）
   virtio-balloon-pci が無ければ追加
3) taskset f0 で A78 クラスタに固定 —— KVM を壊す big.LITTLE のマイグレーション競合を回避
```

**ロールバック**：`.real` を元の名前に戻すだけです。

---

# ⚠️ DroidVM アプリの 3 つの罠

## 1. VNC ポートは既定で**ランダム**

`vms.json` の `screens.*.vnc.port` の既定値は **`-1`**、つまり「自動で選ぶ」：

```json
"vnc": { "host": "127.0.0.1", "port": -1, "password": "", "password_auth": false }
```

**結果**：起動のたびにポートが変わり得ます ✗ —— `adb forward tcp:5900` した先には
誰もいません ✗。「VM は起動しているのに繋がらない」のよくある原因です。

- **本プロジェクトの方法**：経路 A が `-vnc 127.0.0.1:0`（= 5900）を書き込み、
  起動後に実際のポートを再確認します
- `port` フィールドを設定するのも理論上は可能ですが**未検証**で、下の 3 のリスクが
  あります —— **非推奨**

## 2. アプリが作る設定は不完全

上の「経路 B」参照 —— `-netdev` と balloon が欠けており、ラッパーが補います。

## 3. `vms.json` を手で編集するとアプリが読めなくなる

**症状**：`vms.json` を手で編集（例：ディスクパスの変更）したら、VM がアプリから
**消えてしまい**、「現在のバージョンでは読み取れません」と表示される。

**原因**：DroidVM は独自の厳格なスキーマで検証しており、**手で追加したフィールドを
認識しない**ため、エントリごと除外してしまう。

**対処**
- **既にあるフィールドだけを変更する**（例：`disks[].path`、`screens.*.exporter`）—— **新しいフィールドは追加しない**
- 元の所有者とパーミッションを保つ：
  ```bash
  OWN=$(stat -c %u vms.json); GRP=$(stat -c %g vms.json); MODE=$(stat -c %a vms.json)
  # ... 編集 ...
  chown $OWN:$GRP vms.json; chmod $MODE vms.json
  ```
- **編集前にバックアップ**：`cp vms.json vms.json.bak`

> その他の罠は [docs/05-gotchas.md](../../docs/05-gotchas.md)（第 2 項・第 9 項）を参照。
