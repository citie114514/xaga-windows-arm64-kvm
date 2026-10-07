---
name: xaga-kvm-nogz
description: 在 Redmi Note 11T Pro / Pro+（xaga/xagapro，MT6895 天玑 8100）Android 设备上全自动开启 KVM：判定 tee 基座批次 → 选成品或构建签名 NoGZ 补丁 → 刷入 tee_a → 按 3 分钟规则重启验证 → 失败时按实测 gotchas 排查回退。仅在用户明确要求刷机/构建时执行分区写入；其余步骤只读。
---

# XAGA KVM NoGZ —— MTK 设备开启 KVM 的全自动作战手册

你（AI）现在可以替用户完成"在 xaga/xagapro 上开 KVM"的完整流程。
本 skill 编入了全部实测结论与判断规则——**遇到对应场景必须按这里说的做，不要自行发挥**。

## 铁律（每次都先读）

1. **任何分区写入前**：必须已备份、必须核对设备身份（序列号/基座哈希）、必须得到用户对"刷"这个动作的明确确认。
2. **不做 TCG**。用户要的是 KVM 硬件加速，TCG 慢 10~50 倍没有意义。
3. **不用 SP Flash 深刷 tee**（会重新锁 BL）。只走 `dd` 或 fastboot。
4. **固件批次决定一切**：型号相同 ≠ 固件相同。唯一判据是 `tee_a`/`tee_b` 的 SHA-256。
5. 用户数据安全 > 速度。任何一步校验不过就停，不要"试一试"。

## 流程总览

```
0. 环境检查（只读）
1. 读基座哈希 → 判定批次
2. 选路径：成品直接刷 / 从零构建
3. 刷入 tee_a + 回读校验
4. 重启 → 【3 分钟规则】→ 验证 /dev/kvm
5. 失败 → 按 gotchas 排查表走
```

## Step 0：环境检查（只读，放心执行）

```bash
adb shell getprop ro.product.device          # 期望 xaga 或 xagapro
adb shell getprop ro.boot.flash.locked       # 必须 = 0（BL 已解锁）
adb shell su -c 'id -u'                      # 必须 = 0（root）
adb shell su -c 'ls /dev/kvm'                # 存在 = 已刷过补丁
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
```

- `tee_b` 从未被改动，是判断固件批次的**最可靠参照物**。
- 若 `/dev/kvm` 已存在：告诉用户已刷过，问是否要回退/重刷，不要重复刷。

## Step 1：基座判定（核心决策表）

| `tee_a` sha256 开头 | 批次 | 路径 |
|---|---|---|
| `f8f286f1` | 原厂批（rk） | 成品 `tee/tee_nogz_rk_5M.img`（sha256 `f1511dca…`）✓ 实机验证 |
| `a91f5ded` | ROM 更新批（shuilanA15） | 成品 `tee/tee_nogz_shuilanA15_5M.img`（sha256 `17ec8497…`）✓ 实机验证 |
| `bd4b13a7` | 上游 xaga 批 | 用 [MT6895-Mainline v1.0 release](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz/releases/tag/v1.0)（ATF-only 格式，见其说明） |
| 其它 | 未知批次 | 走 Step 2B 从零构建；不要套用任何成品 |

**跨基座结论（实测）**：批次不匹配的补丁**也能启动**，但不推荐——TEE OS 版本可能不匹配。
刷错批次**不用恐慌**：先按 3 分钟规则等，大概率能起来；不行就回退（见 Step 5）。

**lk 配对规则（实测）**：OTA 会换 lk（A15→A16 后 `lk_a` `8cbaa2e8…` → `a17d87c6…`）。
lk 变化**不影响补丁在实机上的工作**，但**构建工具要求 tee+lk 配对**。
构建时若 lk 哈希不匹配：在 `lk-archive/` 找配对备份；没有就用 `flash-tee.ps1` 直接刷成品。

## Step 2A：刷成品（推荐，2 分钟）

```bash
adb push tee/tee_nogz_<批次>_5M.img /data/local/tmp/tee_patched.img
adb shell su -c 'sha256sum /data/local/tmp/tee_patched.img'    # 必须等于成品哈希
adb shell su -c 'dd if=/data/local/tmp/tee_patched.img of=/dev/block/by-name/tee_a bs=4096 && sync'
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'   # 必须回读一致
```

或直接跑一键脚本（自动备份+匹配+刷入）：

```powershell
.\scripts\flash-tee.ps1 -Yes          # -Yes 免交互，录屏用
```

## Step 2B：从零构建（10 分钟，未知批次时）

前置：clone `woaphone` 系谱的 `mtk-mod-tee-nogz`（当前用 MT6895-Mainline fork）+ `pwnage24mtk` + Python venv。

**已知坑（脚本 `fix-upstream.ps1` 自动处理，手动跑才需要知道）**：
- 上游 `build.py` 调用了未定义的 `sign_all_flag()` → 必报 NameError，需插入定义（返回 `[]`）
- `--profile` choices 不含 `xagapro`；`references/profiles.json` 缺对应条目

```powershell
.\scripts\kvm-oneclick.ps1 -Profile xagapro -TeeFixRepo <path> -PwnageDir <path>
```

构建成功判据（缺一不可）：
- 14/14 离线回归通过
- 签名后 **2 × `Result: VALID`**
- 产物 5 243 952 字节 → 确认超出部分（1072 字节）**全为 0x00** 后裁到 5 242 880 字节
- 裁剪后 sha256 与基座对应成品一致（`f8f286f1` 基座 → `f1511dca…`）

**离线 VALID ≠ 设备一定能启动**——最终标准只有实机。

## Step 3：重启 —— 3 分钟规则（最重要的一条）

刷完重启后，**每一次开机都会停在第二屏（logo2 转圈）1~2 分钟**。

| 现象 | 判定 | 动作 |
|---|---|---|
| 停第二屏 + `adb devices` 能看到 | **正常** | **等满 3 分钟**，什么都不做 |
| 停第一屏 / 自动进 fastboot | 真失败 | 进 Step 5 排查 |

原理：ATF 签名校验在 `bl2_ext` 阶段（远早于内核）。**能看到第二屏 = 补丁已被接受**，
后面只是 GZ 握手超时的等待。**千万不要**按「音量下+电源」进 fastboot——
那会把一个本来能好的开机硬生生变成砖。（本项目曾因此误诊过一次"卡二"。）

💡 多次开机后延迟可能缩短甚至消失（2026-10-07 备用机观察，机理未确认）。

## Step 4：验证成功

```bash
adb shell su -c 'ls -l /dev/kvm'      # crw-rw-rw- 10, 232 = 成功
adb shell su -c 'cat /proc/misc | grep kvm'
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
adb pull /data/local/tmp/e.img && grep -a "\[SBC\] image atf" e.img
# [SBC] image atf header auth pass = pwnage 证书绕过在真机成立
```

决定性验证（crosvm 拉 microdroid guest）：

```bash
adb shell su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
# 看到 guest 内核输出 = ATF→EL2→KVM 全链闭环
```

## Step 5：失败排查（按序）

1. **卡第一屏 / fastboot 循环** → 补丁没被接受：
   - 核对 `tee_a` 当前哈希是不是目标成品（回读错了 = 重刷）
   - 基座对不对（Step 1 表）
   - 救砖：`fastboot flash tee_a tee_a_backup.img` + `fastboot reboot`（**实测有效，只动 tee_a**）
2. **卡第二屏 > 5 分钟** → 可能刷了错批次：回退备份，换正确基座成品
3. **`/dev/kvm` 在但 QEMU 报错** → 查 [docs/05-gotchas.md](../../docs/05-gotchas.md)：
   `-cpu host` 必须配 `taskset f0`；VNC 端口是 display 号（`:0`=5900）；`LD_LIBRARY_PATH=/system/lib64`
4. **回退后一切恢复**（录屏/串流/QQ 图片）→ 这正常，见下方代价说明

## ⚠️ 必须告知用户的代价（gotcha #13，2026-10-08 更新）

**裸 NoGZ 组合**（tee 补丁 + 原厂 vendor_boot）：硬件视频编解码失效（VCP 握手断）——
Moonlight ✗ UU远程 ✗ QQ图片 ✗ 录屏 0 字节 ✗。

✅ **有已验证的解**：再刷 vendor_boot swcodec 回退补丁（docs/07，dtb 改 2 字节）→
硬编解绑、框架回退软编 → **KVM 与录屏/串流/图片同时可用**。
剩余代价：软编 CPU 占用高（1080p 无碍，4K 可能卡，串流延迟偏高）。

**注意**：软编是否可用**取决于 ROM 批次**——早期在 pearl(A15) ROM 上测得软编也废
（缺符号），2026-10-08 在 dali(A16) ROM 上复测正常。刷完 swcodec 补丁后
**必须实测验证**（screenrecord 非 0 字节 = 成功）。

应用检测不受影响（KeyMint/Gatekeeper/Widevine/指纹全走 TEE S-EL1，与 EL2 无关）；
但 BL 解锁的 `verifiedbootstate=orange` 本来就过不了 Play Integrity，与刷 tee 无关。

## Windows 虚拟机速查

启动：`adb shell su -c 'sh /data/local/tmp/boot-win.sh'` → `adb forward tcp:5900 tcp:5900` → VNC 连 `127.0.0.1:5900`。
磁盘制作/驱动注入/常见报错见 [docs/03](../../docs/03-windows-vm.md) 与 [docs/04](../../docs/04-usage.md)。

## 边界声明

- 本 skill 只覆盖 xaga/xagapro（MT6895）的已知批次；其它 MTK 机型参考上游 `references/adaptation.md` 自行逆向
- 所有"实机验证"结论出自本项目两台设备的实测，跨设备（同型号同批次）应当成立但未逐一验证
- 刷改信任链有风险，仅在用户自有设备上操作，后果自负
