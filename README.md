# 在 Android 手机上跑 Windows 11 ARM64 —— 用真正的 KVM 硬件加速

[**中文**](README.md) | [English](README.en.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

> Redmi Note 11T Pro+ / **Redmi K50i**（MT6895 / Dimensity 8100）实测通过。
> 同 SoC 家族的 **Redmi Note 11T Pro / POCO X4 GT**（代号 `xaga`）原理完全相同，但固件不同，
> 需要各自的 profile。
> ⚠️ **跨基座补丁虽然实测能启动，但不推荐** —— 代价与同基座一样（见下方「硬件解码失效」），
> 而且变量更多。**能用同基座就用同基座。**
> **不用刷机、不用换系统、留在 Android 里就能玩虚拟机。**

---

> # 定位说明：KVM 与编解码可以两全（2026-10-08 更新）
>
> 开 KVM 的裸代价是 **硬件视频编解码失效**（VCP 握手依赖 EL2/安全世界链，已实测）：
>
> | | 刷之前 | 刷 NoGZ 后（裸）| + vendor_boot 补丁后 | 刷回原厂后 |
> |---|---|---|---|---|
> | Moonlight 串流 | ✅ | ❌ **无响应** | ⚠️ 可用（软编）| ✅ |
> | UU 远程 | ✅ | ❌ **用不了** | ⚠️ 可用（软编）| ✅ |
> | QQ 聊天图片 | ✅ | ❌ **不显示** | ✅ 恢复 | ✅ |
> | **录屏 / 相机录像** | ✅ | ❌ **0 字节** | ✅ **恢复**（软编）| ✅ |
> | **/dev/kvm** | ❌ | ✅ | ✅ **仍在** | ❌ |
>
> **解法（已完整实测）**：再刷一个 vendor_boot 软编回退补丁（改 dtb 2 字节）→
> mtk 硬编解绑 → 框架回退软编 → **KVM 和录屏/串流/图片同时可用** ✓
> → [docs/07-vendor-boot-swcodec.md](docs/07-vendor-boot-swcodec.md)
>
> **剩余代价**：编解码走软编，CPU 占用更高——1080p 无碍 ✓，4K/高帧率可能卡 ⚠️，
> 串流延迟高于真硬编。功能可用性完全恢复 ✓
>
> **机理**（两层，实测确认）：
> ① VCP 握手依赖 EL2/安全世界链 → 内核抬到 EL2 后断裂 → 硬编全废（NoGZ 固有代价，与基座无关）
> ② 软编是否可用**取决于 ROM 批次**：早期在 pearl(A15) ROM 上测得 mediaswcodec 缺符号 →
>    曾误推为普遍规律；2026-10-08 在 dali(A16) ROM 上复测**软编正常** ✗→✓
>
> **回到纯日用**：刷回原厂 tee + 原厂 vendor_boot + 重启 → 全部恢复 ✓
>
> 完整实测与回退方法：[docs/05-gotchas.md 第 13 条](docs/05-gotchas.md)
>
![Windows 11 ARM64 桌面](images/final-1080.png)

**实机证据**：Windows 11 ARM64 里 CPU-Z 看到的就是虚拟化的 `virt-10.0`，系统信息直接显示 **KVM Virtual Machine**：

| CPU-Z Bench（虚拟机内跑分） | 系统信息（KVM Virtual Machine） |
|---|---|
| ![CPU-Z Bench](images/cpu-z-bench.png) | ![关于本机](images/about-kvm-vm.png) |

> 单核 247 / 多核 709（4 vCPU，对比参考骁龙 860）；处理器显示 `virt-10.0 @ 2.36 GHz`，
> 设备型号 **KVM Virtual Machine** —— KVM 硬件加速真实生效的直接证据。

---

## ⚠️ 开始之前必须知道的**三**件事

### 1. 需要 Root（不可绕过）

要让 Android 上的 QEMU 用 **KVM** 硬件加速，必须替换设备 `tee` 分区里跑在 EL2 的 ATF 固件。
这需要：

- ✅ **Bootloader 已解锁**
- ✅ **已 Root**（KernelSU / Magisk，且给 adb shell 授权）
- ✅ PC 上有 **adb** 和 **Python 3.10+**

> **没有 Root 就没有 KVM。** 网上那种"免 Root 跑虚拟机"的方案用的是 **TCG（纯软件模拟）** ——
> 速度大概是 KVM 的 **1/10 ~ 1/50**，装个系统要几小时，日常根本没法用。
> **本项目只做 KVM 路线，不做 TCG。**

### 2. 会改动设备信任链

替换 ATF 属于**修改启动链**的操作。虽然本项目全程实机验证成功，但你必须知道：

- **务必先备份原厂 `tee_a`**（一键脚本会强制备份，没备份就中止）
- **只改 `tee_a`，`tee_b` 保持原厂** —— 切到 B 槽就回到没 KVM 的状态，是天然兜底
- **不要用 SP Flash 深刷 `tee`**（会把 BL 重新锁上，后续 fastboot 就不方便了）
- **一切后果自负**

### 3. ⭐ 试 `tee` 之前，先把【工程 preloader】刷上 —— 这是唯一的免授权救砖路径

**这一点比备份还重要** ✗：

```
原厂 preloader ⇒ EDL 需要小米售后账号授权 ✗
              ⇒ tee 刷错、设备起不来时，你没有免授权的救援通道 ✗

工程 preloader ⇒ usbdl_verify_da 的返回值被直接丢弃
              ⇒ SLA / DAA 校验形同虚设
              ⇒ 可以用 SP Flash / mtkclient【免账号】写入 ✓
              ⇒ 这才是“刷坏了还能救”的前提 ✓
```

**刷工程 preloader（fastboot 即可，比刷 tee 简单得多）**：

```bash
fastboot flash preloader1 preloader_xaga.bin
fastboot flash preloader2 preloader_xaga.bin
fastboot reboot
```

（本机 by-name 里对应 `preloader_raw_a` / `preloader_raw_b`）

> ⚠️ **工程 preloader 只让“写入”免授权，不会关掉“启动时的镜像校验”** ✗
> `sbc_en` 仍然从 eFuse 读、实测值仍然是 **1**，ATF 每个启动都还在被校验 ✓
> 所以**改了 ATF 就必须签名**这一点不变 —— 详见 [docs/05](docs/05-gotchas.md) 与
> [appendix-atf-reverse](docs/appendix-atf-reverse.md)

**→ 推荐的完整顺序**：

```
① 确认可以刷入工程 preloader（手里有文件 + 能用 fastboot / SP Flash）
② 刷入工程 preloader 并验证能正常开机
③ 备份 tee_a / tee_b / lk_a / lk_b / preloader_raw_a / seccfg
④ 再用本项目的成品 tee 去试
```

### 3.1 先查一下：你设备上跑的**已经是**工程 preloader 了吗？

**很可能已经是了** ✓ —— 先比较哈希，别白刷：

```bash
adb shell su -c 'dd if=/dev/block/by-name/preloader_raw_a bs=4096 2>/dev/null | sha256sum'
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1` | **就是这份已流出的工程版** ✓ | **什么都不用刷** ✓ 已处于可免授权救援状态 |
| 其他哈希 | 别的构建（可能是未动过的原厂）| 需先拿到对应的工程 preloader 再刷 |

> 本项目实机实测：一台设备的 `preloader_raw_a`、用户提供的文件、PC 上的备份
> **三者哈希完全相同**（`056ed47a…`），即该设备本来就在跑工程版 ✓
> —— **直接 `dd` 提出来就是那份文件**，不需要另找。

**零风险确认法**：进 EDL，用**未签名 DA** 只读一下（如 `mtkclient r seccfg`）——
要求 `.auth` 文件 = 原厂 ✗；不要求 = 工程版 ✓

---

## 这条路线适合谁

| 你的情况 | 建议 |
|---|---|
| **想留在 Android**，只是想跑个 Windows/ARM Linux 虚拟机 | ✅ **就是本项目** —— 见[快速开始](#快速开始) |
| 想折腾**主线 Linux + KDE**（和 [kde-yyds](https://space.bilibili.com/2008726064) 那个视频一样） | 见 [docs/06-mainline.md](docs/06-mainline.md)（同机主线已相当完整） |
| 没有 Root | ❌ 本项目帮不了你（TCG 方案不在讨论范围内） |
| 不是 MT6895 设备 | ⚠️ 原理通用，但 `tee` 补丁需要你机型的 TEE/LK 配对（见 [docs/02](docs/02-build-and-sign.md)） |

---

## 原理一句话

MTK 设备上 `/dev/kvm` 不存在，是因为 **EL2 被 MediaTek 的 GenieZone(GZ) 固件占着**。
把 `tee_a` 里跑在 EL2 的那段 **ATF** 换成 **NoGZ 补丁版**（并过 MTK 签名校验），
EL2 就交给 Linux 了 → `/dev/kvm` 出现 → QEMU 能用 KVM。

```mermaid
graph LR
    A["tee_a 分区"] --> B["atf 成员<br/>跑在 EL2"]
    B -->|"换成 NoGZ 补丁版"| C["pwnage 签名<br/>过 MTK 证书校验"]
    C -->|"dd 刷入"| D["SBC 校验通过"]
    D --> E["/dev/kvm 出现"]
    E --> F["QEMU + KVM<br/>跑 Windows 11 ARM64"]
```

**为什么必须签名**：本机实测 `sbc_en = 1`（Secure Boot 开着，值来自 eFuse OTP，改不了），
每个启动都会对 ATF 做证书链校验。所以改过的 ATF **必须用 [pwnage24mtk](https://github.com/kasnria001/pwnage24mtk)
的证书解析漏洞签名**才能被接受。详见 [docs/01](docs/01-enable-kvm.md) 和 [docs/02](docs/02-build-and-sign.md)。

---

## 🎁 不想自己构建？直接用成品

仓库里放了**已经构建并签名好**的 `tee` 镜像，可以直接刷 —— 其中包括**已实机验证成功的示例**：

| 文件 | 适配基座（你的 `tee_a`） | 实机验证 |
|---|---|---|
| [`tee/tee_nogz_rk_5M.img`](tee/tee_nogz_rk_5M.img) | `f8f286f1…`（原厂） | ✅ **已成功**（跨 Android 15 → 16 两次确认）|
| [`tee/tee_nogz_shuilanA15_5M.img`](tee/tee_nogz_shuilanA15_5M.img) | `a91f5ded…`（刷 ROM 后） | ✅ **已成功**（2026-10-06 实测）|

**刷之前先跑自检**，它会直接告诉你该用哪个（还是需要自己构建）：

```bash
bash tee/verify.sh                 # 自动检测已连接设备
bash tee/verify.sh <serial>        # 指定设备
```

自检会打印你设备的 `tee_a` / `tee_b`，并区分三种状态：**未打补丁 / 已打补丁 / 需要自行构建**。

> ⚠️ **补丁是按 `tee` 基座构建的** —— 推荐用同基座的（更保守、变量更少）。
> **跨基座也实测能启动** ✓（2026-10-07），但**不推荐**：
> 变量更多，而且硬件解码失效的代价一样存在（见第 13 条）。
> 实在要用就记得**先备份**、**给它 3 分钟**。
>
> ⚠️ **刷完补丁后开机，第二屏会卡约 1~2 分钟**才进系统 —— 这是正常的，
> **不是变砖，等着就好**。千万不要急着进 fastboot，那会打断启动。
>
> 💡 **2026-10-07 新观察**：多次开机之后，这段延迟**可能会缩短甚至基本消失**
> （备用机实测：KVM 仍在，编解码失效不变，但开机速度明显恢复）。
> 机理尚未确认（推测是最初几次开机叠加了一次性的系统收尾工作 / 服务重试退避），
> 但**判断规则不变：卡第二屏 + adb 可见 = 等 3 分钟再说**。
>
> ⚠️ **刷了会不会影响日用应用检测（银行 App / Play Integrity / DRM）？实测答案：不会** ——
> 补丁只改 EL2 归属，不碰 TEE。完整实测数据、基座对照表与回退方法见 [`tee/README.md`](tee/README.md)。

---

## 快速开始

### 第 1 步：开启 KVM（一键脚本）

```powershell
# 准备两个工具（都要单独下载）
git clone https://github.com/MT6895-Mainline/mtk-mod-tee-nogz   D:\mtk-mod-tee-nogz
git clone https://github.com/kasnria001/pwnage24mtk             D:\pwnage24mtk

# 装 mtk-mod-tee-nogz 的依赖
cd D:\mtk-mod-tee-nogz
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt

# 一键跑完：环境检查 → 备份 → dump → 构建 → 签名 → 校验 → 刷入 → 验证提示
# （首次运行会自动给 mtk-mod-tee-nogz 打两个必要补丁：sign_all_flag 定义 + xagapro profile）
cd <本仓库>\scripts
.\kvm-oneclick.ps1 -Profile xagapro -TeeFixRepo D:\mtk-mod-tee-nogz -PwnageDir D:\pwnage24mtk
```

> ⚠️ **-Profile 必须用 `xagapro`**（Note 11T Pro / Pro+ 的 `f8f286f1…` 原厂基座批次）——
> 上游的 `xaga` profile 是另一批固件（`bd4b13a7…`），哈希校验对不上会直接中止。
> 不确定自己是不是这批？先看 `tee_a` 哈希（脚本自检会打印），`f8f286f1` 开头就用 `xagapro`。
>
> ⚠️ **升过 Android 16 的设备注意**：OTA 会换掉 `lk_a`（`8cbaa2e8…` → `a17d87c6…`）。
> 补丁在实机上照样工作 ✓，但构建工具的离线回归需要与 tee 配对的那支 lk ——
> 一键脚本会自动在 `lk-archive/` 里找配对备份；找不到时会给出明确指引
> （可改用 [`flash-tee.ps1`](#) 直接刷成品，不需要构建）。

脚本会做这些事，**每一步都有输出和校验**：

```
[1] 环境自检        adb / python / 设备 / BL 解锁 / root
[2] 只读侦察        机型、分区、/dev/kvm 现状、从 expdb 读 sbc_en
[3] 备份原厂分区     tee_a / tee_b / lk_a / lk_b / preloader_raw_a / seccfg → PC
[4] dump 出料        从设备 dump TEE/LK/preloader（保证哈希匹配）
[5] 构建 + 签名      调 mtk-mod-tee-nogz（自动检测 new/legacy 模式）
[6] 校验             要求 2× Result: VALID；裁掉尾部零填充到分区大小
[7] 刷入 tee_a       dd + 回读 sha256 比对
[8] 提示重启验证     /dev/kvm、[SBC] image atf header auth pass
```

**只想先看看结果不刷机**：加 `-DryRun` —— 会一路做到第 6 步并把待刷镜像留在磁盘上。

刷完重启，验证：

```bash
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

> ### ⚠️ 刷完补丁后开机**会在第二屏卡 1~2 分钟**才进系统 —— 这不是变砖
>
> 刷完补丁后的**最初几次**开机都会停在**开机第二屏**（logo2 / 转圈），
> **1~2 分钟没有任何动静** ✗ —— 看起来完全像「卡二 / 变砖」。
> 💡 **多次开机后这段延迟可能缩短**（2026-10-07 备用机观察，机理未确认），
> 但**第一次刷完时请按 2 分钟预期**，不要心存侥幸。
>
> **千万不要**在这时按「音量下 + 电源」进 fastboot ✗ —— **那会打断启动**，
> 把一个本来能好的开机变成真的进不了系统 ✗。**等 3 分钟** ✓
>
> 怎么区分「正常慢」和「真失败」：**停在第二屏 + adb 能看到设备 = 正常，等** ✓；
> **停在第一屏，或黑屏后自动进 fastboot = 真失败** ✗。详见 [docs/05](docs/05-gotchas.md) 第 12 条。

### 第 2 步：做一个 Windows 11 ARM64 磁盘（一键脚本）

不用装虚拟机、不用在 VM 里跑安装程序 —— 全程命令行直接从 ISO 做出可引导的 VHDX：

```powershell
# 抽 virtio ARM64 驱动（需要 7-Zip）
.\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11

# 从 Windows 11 ARM64 ISO 直接做盘
# （管理员 PowerShell）
.\build-windows-vhdx.ps1 -Iso D:\Win11_ARM64.iso -DriversDir .\virtio-arm64-w11
```

脚本自动完成：分区 → `dism /Apply-Image /Compact:ON` → **`bcdboot` 写引导** → **LabConfig 绕过 TPM** → **注入驱动** → 校验 `bootmgfw.efi` 是 ARM64。

> ⚠️ 这一步最容易踩的坑：Dism++ 之类工具释放出来的盘 **ESP 是空的**，必须自己 `bcdboot`，否则开机找不到可引导设备。

### 第 3 步：推到手机并启动

```bash
# 先把手机端脚本推上去（都在 scripts/phone/）
adb push scripts/phone/boot-win.sh scripts/phone/stop-vm.sh scripts/phone/restore-disk.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/*.sh'

# 把磁盘放到位（restore-disk.sh 会检查格式、空间，并校验 sha256）
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'sh /data/local/tmp/restore-disk.sh /data/local/tmp/win.vhdx'

# 启动（脚本会自己等 5900 空闲、启动后核对端口）
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
adb forward tcp:5900 tcp:5900                    # VNC 固定 5900
# VNC 客户端连 127.0.0.1:5900（无密码）
```

> 磁盘丢了或换新盘时，直接跑 `restore-disk.sh <镜像>` 即可 ——它会自动识别
> VHDX / QCOW2 / VHD、检查 `/data` 剩余空间、必要时确认覆盖，最后算 sha256 校验。

首次开机会跑 OOBE，5~15 分钟。到「连接网络」那页选 **【我没有 Internet 连接】** →
**【继续执行受限设置】** 建本地账户最省事。

---

## 目录导航

| 文件 | 内容 |
|---|---|
| [README.en.md](README.en.md) | **English version of this README**（一句话原理 + 完整三步骤）|
| [README.ja.md](README.ja.md) | 日本語版 README |
| [README.ru.md](README.ru.md) | Русская версия README |
| [docs/01-enable-kvm.md](docs/01-enable-kvm.md) | **开启 KVM 完整流程**：原理、校验链分析、刷入与验证 （[English](docs/en/01-enable-kvm.md) / [日本語](docs/ja/01-enable-kvm.md) / [Русский](docs/ru/01-enable-kvm.md)）|
| [docs/02-build-and-sign.md](docs/02-build-and-sign.md) | **构建与签名步骤详解**：NoGZ 补丁怎么改、pwnage 怎么签、超分区怎么处理 （[English](docs/en/02-build-and-sign.md) / [日本語](docs/ja/02-build-and-sign.md) / [Русский](docs/ru/02-build-and-sign.md)）|
| [docs/03-windows-vm.md](docs/03-windows-vm.md) | Windows 11 ARM64 磁盘：释放镜像、写引导、绕过 TPM、注入驱动 （[English](docs/en/03-windows-vm.md) / [日本語](docs/ja/03-windows-vm.md) / [Русский](docs/ru/03-windows-vm.md)）|
| [docs/04-usage.md](docs/04-usage.md) | **使用方法**：QEMU 参数逐条说明、VNC、网络、性能调优 （[English](docs/en/04-usage.md) / [日本語](docs/ja/04-usage.md) / [Русский](docs/ru/04-usage.md)）|
| [docs/05-gotchas.md](docs/05-gotchas.md) | **坑清单**（13 条，全是我们踩过的）| （[English](docs/en/05-gotchas.md) / [日本語](docs/ja/05-gotchas.md) / [Русский](docs/ru/05-gotchas.md)）|
| [docs/06-mainline.md](docs/06-mainline.md) | 进阶：换主线 Linux + KDE 的路线 （[English](docs/en/06-mainline.md) / [日本語](docs/ja/06-mainline.md) / [Русский](docs/ru/06-mainline.md)）|
| [docs/appendix-atf-reverse.md](docs/appendix-atf-reverse.md) | **附录：preloader 逆向结论**（SBC 来自 eFuse、两段式 `[SBC]` 校验链、ATF 装载点）（[English](docs/en/appendix-atf-reverse.md) / [日本語](docs/ja/appendix-atf-reverse.md) / [Русский](docs/ru/appendix-atf-reverse.md)）|
| [docs/appendix-early-report.md](docs/appendix-early-report.md) | **附录：早期可行性报告**（只读侦察、逆向出的偏移、风险）（[English](docs/en/appendix-early-report.md) / [日本語](docs/ja/appendix-early-report.md) / [Русский](docs/ru/appendix-early-report.md)）|
| [tee/](tee/) | **成品 tee 镜像**（已签名，可直接刷）+ 适配基座对照表 |
| [profiles/](profiles/) | 固件 profile（ATF/LK 偏移定义）|
| [tools/](tools/) | 为新固件重新定位 profile 的逆向工具 |
| [scripts/](scripts/) | 一键脚本（构建 VHDX / 提驱动 / 开 KVM）|
| [docs/07-vendor-boot-swcodec.md](docs/07-vendor-boot-swcodec.md) | **vendor_boot 软编回退补丁（已验证）**：让 KVM 和录屏 / 串流 / 图片共存 |
| [scripts/write-boot-manual.ps1](scripts/write-boot-manual.ps1) | **绕开 `bcdboot` 手工写 UEFI 引导**（宿主开了 Secure Boot 时，`bcdboot` 会因缺 `EFI_EX` 而失败 —— 见 [docs/05](docs/05-gotchas.md) 第 12 条）|
| [scripts/phone/](scripts/phone/) | **手机端脚本**：`boot-win.sh` 启动 / `stop-vm.sh` 停止 / `restore-disk.sh` 恢复磁盘 / `qemu-wrapper.sh` 让 DroidVM 应用自己也能跑 |

---

## 常见问题

**Q: 为什么 VNC 连不上？**

两种情况要分开看，别混：

**① 用本项目 `boot-win.sh` 启动（命令行路线）**
> QEMU 的 `-vnc host:N` 里 `N` 是 **display 号**，端口 = `5900 + N`。
> 写成 `-vnc :5900` 实际监听的是 **11800**（不是 5900！）。
> 而且端口被占时 QEMU **不报错，而是静默挪到下一个 display**（→ 5901），
> 所以 `scripts/phone/boot-win.sh` 会先等端口空闲、启动后再核对实际端口。

**② 用 DroidVM 应用自己的配置启动**
> 这里还有三个坑：
> - `vms.json` 里 `screens.*.vnc.port` 的默认值是 **`-1`**，意思是「自动挑一个」
>   —— **每次启动端口都可能不一样** ✗，你 `adb forward tcp:5900` 转发的端口没人听
> - 应用**手动创建**的 VM 用 `-pflash` 加载固件，要求固件文件正好 **64 MiB**，
>   而自带固件只有 768 KiB → 直接报
>   `cfi.pflash01 ... requires 67108864 bytes ... provides 786432 bytes` ✗
>   （修复思路：把固件补零到 64 MiB，见 [docs/05](docs/05-gotchas.md) 第 8(d) 条）
> - 应用自己建的配置**本身就跑不起来**（缺 `-netdev` 和 balloon，需要包装脚本补）；
>   而**手改 `vms.json` 又会让应用读不出来** ✗
>
> **所以本项目直接走命令行路线**，绕开这些：端口固定 5900、参数完全可控。
> 细节见 [scripts/phone/README.md](scripts/phone/README.md)。

**Q: Windows 有没有 GPU 加速？**
> **没有，这是硬限制。** virtio-win 的 `viogpudo` 只是显示驱动，**没有 3D 能力**；
> Windows 也没有 virgl 驱动（那是 Linux 才有的）。所以 Windows 这台永远是软件渲染。
> 想看 GPU 加速的虚拟机，得走 [主线 Linux 路线](docs/06-mainline.md) + Linux 客机。

**Q: 卡顿怎么办？**
> 主要看**显示路径**。加 `-vnc ...,lossy=on` 能把每帧数据量从 3.0 MB 降到 **0.36 MB（1/8.3）**。
> 另外实测 adb 转发隧道有 **276 MB/s**，所以网络本身不是瓶颈 —— 别在网络上瞎折腾。
> 详见 [docs/04](docs/04-usage.md)。

**Q: 能不能不 Root？**
> 不能。没有 Root 就改不了 `tee_a`，也就没有 KVM。见上面的警告。

**Q: 能不能用别的 Windows 版本？**
> 需要 **ARM64** 的 Windows。x64 的在 ARM 上只能软件模拟（极慢），没有意义。

**Q: 刷了 `tee` 会不会影响日用（银行 App / Play Integrity / DRM / 视频解码）？**

**要分成两件事看，不要混** ✗：

**① 应用检测（银行 App / Play Integrity / DRM 认证）—— 不影响** ✓
> 补丁只改变 **EL2 的归属**，不碰 **TEE**。
> 实测（未刷 / 已刷 A/B 对照，逐项一致）：KeyMint 硬件密钥证明、Gatekeeper、
> Widevine/DRM 认证、指纹与人脸、Secure Element **全部正常**。
>
> 另外：**`verifiedbootstate = orange`（BL 解锁）本来就是 Play Integrity 的杀手**，
> 跟你刷不刷 `tee` 无关。

**② 但裸组合会有实际代价 —— 硬件视频解码失效（有已验证的解）** ✗→✓
> 裸组合（NoGZ tee + 原厂 vendor_boot）实测（刷前/刷后/刷回 三次对比）：
>
> | | 刷之前 | 刷之后 | 刷回后 |
> |---|---|---|---|
> | Moonlight | ✅ | ❌ 无响应 | ✅ |
> | UU 远程 | ✅ | ❌ 用不了 | ✅ |
> | QQ 图片 | ✅ | ❌ 不显示 | ✅ |
> | 内部存储 | ✅ | ⚠️ 可能开机不挂载 | ✅ |
>
> **原因**：MTK 的硬件编解码依赖 `mtk_sec_heap` + `gz_tz_system` + `cmdq_sec_drv`，
> GZ 拿不到 EL2 后这条链就断了 ✗（与基座匹不匹配无关，同基座补丁一样出现）
>
> ✅ **解（2026-10-08 已完整验证）**：再刷 [vendor_boot 软编回退补丁](docs/07-vendor-boot-swcodec.md)
> → 硬编解绑、框架回退软编 → **KVM 与录屏/串流/图片同时可用**（软编性能代价：1080p 无碍，4K 可能卡）

**→ 结论** ✓
> 功能上可以日用（装 swcodec 补丁后），软编有性能/功耗损耗，重度视频场景不佳。
> 想要完整 GPU 加速的虚拟机 → 走 [主线 Linux](docs/06-mainline.md) 路线。
> 完整实测见 [tee/README.md](tee/README.md)。

---

## 致谢与溯源

NoGZ 补丁工具的演进链（本仓库是最新一代）：

- [`woaphone/mtk-mod-tee-nogz`](https://github.com/woaphone/mtk-mod-tee-nogz) —— **真原项目**：
  搞清 ATF→EL2 交接机理并做出 NoGZ 补丁工具（yunluo / peral 两个 profile，附带 Codex skill）
- [`MT6895-Mainline/mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) ——
  其 fork：新增 xaga profile（`bd4b13a7…` 基座批次）与 ATF-only 发行（[v1.0 release](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz/releases/tag/v1.0)）
- **本仓库** —— 在上游基础上新增 xagapro（`f8f286f1…`）/ shuilanA15（`a91f5ded…`）
  两个基座的 profile 逆向、实机验证与全流程自动化
  （一键构建/刷入/回退、lk 配对处理、完整疑难解答与实测数据）
- [`kasnria001/pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) —— MTK 证书签名绕过工具
- [`MT6895-Mainline`](https://github.com/MT6895-Mainline) —— 这台机器的主线移植项目
- [kde-yyds](https://space.bilibili.com/2008726064)（GitHub: [kde-yyds](https://github.com/kde-yyds)）—— 同机主线 Linux 进展记录，本项目的灵感来源

## License

本项目**代码、脚本与文档**采用 [MIT 许可证](LICENSE)。

> ⚠️ [`tee/`](tee/) 下的厂商固件镜像（含 MediaTek 与设备厂商的二进制、证书链）
> **不在 MIT 许可范围内**，仅供在你自有硬件上做互操作性研究使用。
