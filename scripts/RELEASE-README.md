# 一键开 KVM —— 发行版（四语）

**中文 / English / 日本語 / Русский**

这个压缩包把所有工具都打包好了（补丁工具、签名工具、成品 tee、vendor_boot、脚本、配对 lk、profiles），
解压后**不需要 clone 任何仓库**，跑一个脚本就能全自动完成。

This zip bundles every tool you need (patch tool, signing tool, prebuilt tee, vendor_boot, scripts, paired lk, profiles).
No repo cloning needed — one script does everything automatically.

この ZIP には必要なツールがすべて同梱されています（パッチツール、署名ツール、完成品 tee、vendor_boot、スクリプト、対応 lk、profiles）。
リポジトリの clone は不要で、1 つのスクリプトで全自動で完了します。

Этот архив содержит все необходимые инструменты (инструмент патча, инструмент подписи, готовые tee, vendor_boot, скрипты, парный lk, profiles).
Клонирование репозиториев не требуется — один скрипт делает всё автоматически.

---

## 中文

### 前提（不可省略）

- Bootloader 已解锁（`ro.boot.flash.locked=0`）
- 已 root（KernelSU / Magisk），adb shell 有 root 权限
- PC 装了 Python 3.10+（勾选 Add to PATH）
- adb：**包内已自带**（`tools/platform-tools/`），系统没装也能用；自己装的话记得加入 PATH
- 手机已开启 USB 调试，用 USB 线连接（无线 adb 刷分区不推荐）
- 数据已备份（本项目强制备份固件分区，但你的数据自己负责）

### 使用

双击 **`start-kvm.bat`**，或手动运行：

```powershell
cd <解压目录>\scripts
.\run-oneclick.ps1
```

脚本自动完成：

1. 校验发行版结构（缺文件会提示）
2. 检查 Python
3. 首次运行建 venv 并装依赖（几分钟，只需一次）
4. 确保上游补丁已打（幂等）
5. 调 kvm-oneclick：备份六个分区 → dump → 构建 NoGZ → 签名（2× VALID）→ 裁剪 → 刷入 tee_a → 回读校验
6. 提示刷 vendor_boot（录屏/串流恢复 + 开机第二屏等待消失）

常用选项：

```powershell
.\run-oneclick.ps1 -DryRun          # 只做到构建校验，不刷入
.\run-oneclick.ps1 -Yes             # 全自动确认（录屏用）
.\run-oneclick.ps1 -SkipVendorBoot  # 刷完 tee 后不提示 vendor_boot
```

### 刷完重启的规则

- 第二屏会卡 1~2 分钟：**正常**，等满 3 分钟，千万别进 fastboot
- 看到 `/dev/kvm`（10, 232）即成功
- 想录屏/串流 → 按脚本提示刷 vendor_boot（刷回原厂又会变慢，属正常）

### 回滚

- 脚本备份目录：`<解压目录>\vb-backup-<时间>\`、`<解压目录>\kvm-work\backup\`
- `fastboot flash tee_a <备份>` 实测可救；只动 tee_a 一个分区

### 常见问题

- **Python 找不到**：装 Python 3.10+ 勾选 Add to PATH
- **提示缺文件**：zip 没解压完整，或不是从 Release 下载的完整包
- **lk 不匹配**（升过 Android 16）：脚本自动找 `lk-archive/` 配对备份
- 更多见官方仓库 [xaga-windows-arm64-kvm](https://github.com/citie114514/xaga-windows-arm64-kvm) 的 docs/

---

## English

### Prerequisites (mandatory)

- Bootloader unlocked (`ro.boot.flash.locked=0`)
- Rooted (KernelSU / Magisk), adb shell has root
- Python 3.10+ on the PC (tick "Add to PATH")
- adb: **bundled in this archive** (`tools/platform-tools/`), so a system install is optional; if you do install platform-tools, add it to PATH
- USB debugging enabled; use a USB cable (wireless adb for flashing not recommended)
- Data backed up (this project backs up firmware partitions, but your data is your responsibility)

### Usage

Double-click **`start-kvm.bat`**, or run manually:

```powershell
cd <extract dir>\scripts
.\run-oneclick.ps1
```

The script automatically:

1. Validates the bundle (prompts if files are missing)
2. Checks Python
3. Creates a venv and installs deps on first run (a few minutes, once only)
4. Ensures the upstream patch is applied (idempotent)
5. Runs kvm-oneclick: backup six partitions → dump → build NoGZ → sign (2× VALID) → trim → flash tee_a → readback verify
6. Offers to flash vendor_boot (restores screen recording / streaming + removes the second-screen boot wait)

Useful flags:

```powershell
.\run-oneclick.ps1 -DryRun          # build & verify only, no flashing
.\run-oneclick.ps1 -Yes             # auto-confirm everything (for screen recording)
.\run-oneclick.ps1 -SkipVendorBoot  # skip the vendor_boot prompt after tee
```

### After the reboot

- The second splash screen hangs 1–2 min: **normal**, wait a full 3 minutes, never enter fastboot
- Success = `/dev/kvm` (10, 232) appears
- Want recording/streaming? Flash vendor_boot as prompted (flashing stock vendor_boot back makes boot slow again — expected)

### Rollback

- Script backups: `<extract dir>\vb-backup-<timestamp>\`, `<extract dir>\kvm-work\backup\`
- `fastboot flash tee_a <backup>` is a verified rescue; only tee_a is touched

### FAQ

- **Python not found**: install Python 3.10+ with "Add to PATH"
- **Missing files**: zip incomplete, or not the full bundle from Releases
- **lk mismatch** (after Android 16 OTA): the script auto-finds the paired backup in `lk-archive/`
- More: official repo [xaga-windows-arm64-kvm](https://github.com/citie114514/xaga-windows-arm64-kvm) docs/

---

## 日本語

### 前提（必須）

- Bootloader がアンロック済み（`ro.boot.flash.locked=0`）
- root 済み（KernelSU / Magisk）、adb shell が root 権限を持つ
- PC に Python 3.10+（「Add to PATH」にチェック）
- adb：**同梱済み**（`tools/platform-tools/`）なので無くても動きます。自分で入れる場合は PATH に追加
- USB デバッグ有効、USB ケーブル接続（ワイヤレス adb での書き込みは非推奨）
- データのバックアップ（本プロジェクトはファームウェア領域をバックアップしますが、データの責任は自己責任です）

### 使い方

**`start-kvm.bat`** をダブルクリック、または手動で：

```powershell
cd <解凍先>\scripts
.\run-oneclick.ps1
```

自動で行うこと：

1. 配布構成の検証（ファイル欠落を検出）
2. Python の確認
3. 初回に venv 作成と依存インストール（数分、一度だけ）
4. 上流パッチ適用の確認（冪等）
5. kvm-oneclick 実行：6 パーティションのバックアップ → dump → NoGZ ビルド → 署名（2× VALID）→ トリム → tee_a 書き込み → 読み戻し検証
6. vendor_boot の書き込みを提案（録画・ストリーミング復活 + 2 画面目の待ちが消える）

オプション：

```powershell
.\run-oneclick.ps1 -DryRun          # ビルドと検証のみ、書き込まない
.\run-oneclick.ps1 -Yes             # 全自動確認（録画用）
.\run-oneclick.ps1 -SkipVendorBoot  # tee 後に vendor_boot を促さない
```

### 再起動後

- 2 画面目に 1〜2 分停止：**正常**。3 分待ち、fastboot に入らないこと
- `/dev/kvm`（10, 232）が出たら成功
- 録画・ストリーミングが必要なら、指示に従って vendor_boot を書き込む（元に戻すと起動が遅くなるのは正常）

### ロールバック

- バックアップ：`<解凍先>\vb-backup-<日時>\`、`<解凍先>\kvm-work\backup\`
- `fastboot flash tee_a <バックアップ>` が実測で有効。tee_a だけを触る

### よくある問題

- **Python が見つからない**：Python 3.10+ を「Add to PATH」付きでインストール
- **ファイル不足**：zip が不完全、または Releases のフルバンドル以外を使用
- **lk 不一致**（Android 16 に更新した端末）：`lk-archive/` のペアバックアップを自動検索
- 詳細：公式リポジトリ [xaga-windows-arm64-kvm](https://github.com/citie114514/xaga-windows-arm64-kvm) の docs/

---

## Русский

### Обязательные требования

- Загрузчик разблокирован (`ro.boot.flash.locked=0`)
- Root (KernelSU / Magisk), adb shell имеет root
- Python 3.10+ на ПК (отметить «Add to PATH»)
- adb: **уже в комплекте** (`tools/platform-tools/`), ставить отдельно не обязательно; если ставите — добавьте в PATH
- Включена отладка по USB, подключение по кабелю (беспроводной adb для записи не рекомендуется)
- Данные сохранены (проект резервирует разделы прошивки, но ваши данные — ваша ответственность)

### Использование

Двойной клик по **`start-kvm.bat`**, либо вручную:

```powershell
cd <папка распаковки>\scripts
.\run-oneclick.ps1
```

Скрипт автоматически:

1. Проверяет комплект (сообщит о недостающих файлах)
2. Проверяет Python
3. При первом запуске создаёт venv и ставит зависимости (несколько минут, один раз)
4. Убеждается, что апстрим-патч применён (идемпотентно)
5. Запускает kvm-oneclick: резервная копия шести разделов → dump → сборка NoGZ → подпись (2× VALID) → обрезка → запись tee_a → проверка чтением
6. Предлагает записать vendor_boot (возвращает запись экрана/стриминг + убирает ожидание на втором экране)

Параметры:

```powershell
.\run-oneclick.ps1 -DryRun          # только сборка и проверка, без записи
.\run-oneclick.ps1 -Yes             # полное автоподтверждение (для записи экрана)
.\run-oneclick.ps1 -SkipVendorBoot  # не предлагать vendor_boot после tee
```

### После перезагрузки

- Второй экран висит 1–2 минуты: **нормально**, ждать 3 минуты, НЕ входить в fastboot
- Успех = появился `/dev/kvm` (10, 232)
- Нужна запись/стриминг? Запишите vendor_boot по подсказке (возврат стокового vendor_boot снова замедлит загрузку — ожидаемо)

### Откат

- Резервные копии: `<папка распаковки>\vb-backup-<время>\`, `<папка распаковки>\kvm-work\backup\`
- `fastboot flash tee_a <бэкап>` — проверенный способ спасти; затрагивается только tee_a

### Частые вопросы

- **Python не найден**: установите Python 3.10+ с «Add to PATH»
- **Недостающие файлы**: архив неполный, или использован не полный комплект из Releases
- **lk не совпадает** (после OTA на Android 16): скрипт сам находит парный бэкап в `lk-archive/`
- Подробнее: официальный репозиторий [xaga-windows-arm64-kvm](https://github.com/citie114514/xaga-windows-arm64-kvm), docs/
