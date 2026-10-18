# v0.1.0 —— 一键开 KVM（发行版）

不用 clone 任何仓库：下载下面的 zip，解压，双击 `start-kvm.bat`。

## 包含内容

- `start-kvm.bat` + `scripts/run-oneclick.ps1` —— 唯一入口
- `scripts/` —— kvm-oneclick / flash-tee / flash-vendor-boot / fix-upstream / 手机端脚本
- `tools/mtk-mod-tee-nogz`（已打 xagapro profile + sign_all_flag 补丁）、`tools/pwnage24mtk`
- `tee/` —— 两个实机验证过的成品（rk / shuilanA15）
- `vendor_boot_a_swcodec.img` / `vendor_boot_a_orig.img` —— 软编回退补丁与回滚镜像
- `lk-archive/` —— 配对 lk（应对 OTA 换 lk）
- `profiles/`、`README-发行版.md`（中英日俄四语）

## 前提

Bootloader 已解锁、已 root（KernelSU/Magisk）、PC 有 Python 3.10+、USB 调试已开。

## 用法

```powershell
cd <解压目录>\scripts
.\run-oneclick.ps1              # 完整流程
.\run-oneclick.ps1 -DryRun      # 只构建校验，不刷
.\run-oneclick.ps1 -Yes         # 全自动（录屏用）
.\run-oneclick.ps1 -SkipVendorBoot
```

脚本会自动：校验包结构 → 检查 Python → 首次建 venv 装依赖 → 确保上游补丁 →
备份六分区 → dump → 构建 NoGZ → 签名（2× VALID）→ 裁剪 → 刷入 tee_a → 回读校验 →
提示刷 vendor_boot（录屏/串流恢复 + 开机第二屏等待消失）。

## 提醒

- 刷完重启第二屏卡 1~2 分钟是正常的，等满 3 分钟，千万别进 fastboot
- 只改 `tee_a` / `vendor_boot_a`，`tee_b` 从未改动，是天然兜底
- 回滚：`fastboot flash tee_a <备份>`（实测有效）
- 文档：https://github.com/citie114514/xaga-windows-arm64-kvm

> 本包内含 GPL 许可的第三方工具（mtk-mod-tee-nogz、pwnage24mtk），各自 LICENSE 已随包保留。
> `tee/` 与 `vendor_boot_a_*.img` 为厂商固件，仅供在你自有硬件上做互操作性研究。
