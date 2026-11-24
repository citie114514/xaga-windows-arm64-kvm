# 一键开 KVM —— 发行版（中英双语）

**中文 / English**

这个压缩包把所有工具都打包好了（补丁工具、签名工具、成品 tee、vendor_boot、脚本、配对 lk、profiles），
解压后**不需要 clone 任何仓库**，跑一个脚本就能全自动完成。

This zip bundles every tool you need (patch tool, signing tool, prebuilt tee, vendor_boot, scripts, paired lk, profiles).
No repo cloning needed — one script does everything automatically.

---

## 中文

### 前提（不可省略）

- Bootloader 已解锁（`ro.boot.flash.locked=0`）
- 已 root（KernelSU / Magisk），adb shell 有 root 权限
- PC 装了 Python 3.10+（勾选 Add to PATH）
- adb：**包内已自带**（`tools/platform-tools/`），系统没装也能用。
  查找顺序：系统的 adb（常见路径 + PATH）优先，找不到才用包内那份；
  想用自己下载的，把 `platform-tools` 目录放到 `scripts` 里或发行版根目录也行
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
- adb: **bundled in this archive** (`tools/platform-tools/`), so a system install is optional.
  Lookup order: your system adb (known paths + PATH) first, bundled copy as the fallback;
  you can also drop your own `platform-tools` folder into `scripts/` or the bundle root
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


