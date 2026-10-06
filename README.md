# 在 Android 手机上跑 Windows 11 ARM64 —— 用真正的 KVM 硬件加速

> Redmi Note 11T Pro / Pro+（MT6895 / Dimensity 8100）实测通过。
> **不用刷机、不用换系统、留在 Android 里就能玩虚拟机。**

![Windows 11 ARM64 桌面](images/final-1080.png)

---

## ⚠️ 开始之前必须知道的两件事

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
- **不要用 SP Flash 深刷**（会把 BL 重新锁上）
- 刷坏了还能走 **preloader 模式**（免授权）救砖
- **一切后果自负**

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
    A[tee_a 分区] --> B[atf 成员<br/>跑在 EL2]
    B -->|换成 NoGZ 补丁版| C[pwnage 签名<br/>过 MTK 证书校验]
    C -->|dd 刷入| D[SBC 校验通过]
    D --> E[/dev/kvm 出现]
    E --> F[QEMU + KVM<br/>跑 Windows 11 ARM64]
```

**为什么必须签名**：本机实测 `sbc_en = 1`（Secure Boot 开着，值来自 eFuse OTP，改不了），
每个启动都会对 ATF 做证书链校验。所以改过的 ATF **必须用 [pwnage24mtk](https://github.com/kasnria001/pwnage24mtk)
的证书解析漏洞签名**才能被接受。详见 [docs/01](docs/01-enable-kvm.md) 和 [docs/02](docs/02-build-and-sign.md)。

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
cd <本仓库>\scripts
.\kvm-oneclick.ps1 -Profile xaga -TeeFixRepo D:\mtk-mod-tee-nogz -PwnageDir D:\pwnage24mtk
```

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
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'
adb shell su -c /data/local/tmp/boot-win.sh      # 把 scripts/boot-win.sh 推上去
adb forward tcp:5900 tcp:5900                    # VNC 固定 5900
# VNC 客户端连 127.0.0.1:5900（无密码）
```

首次开机会跑 OOBE，5~15 分钟。到「连接网络」那页选 **【我没有 Internet 连接】** →
**【继续执行受限设置】** 建本地账户最省事。

---

## 目录导航

| 文件 | 内容 |
|---|---|
| [docs/01-enable-kvm.md](docs/01-enable-kvm.md) | **开启 KVM 完整流程**：原理、校验链分析、刷入与验证 |
| [docs/02-build-and-sign.md](docs/02-build-and-sign.md) | **构建与签名步骤详解**：NoGZ 补丁怎么改、pwnage 怎么签、超分区怎么处理 |
| [docs/03-windows-vm.md](docs/03-windows-vm.md) | Windows 11 ARM64 磁盘：释放镜像、写引导、绕过 TPM、注入驱动 |
| [docs/04-usage.md](docs/04-usage.md) | **使用方法**：QEMU 参数逐条说明、VNC、网络、性能调优 |
| [docs/05-gotchas.md](docs/05-gotchas.md) | **坑清单**（10 条，全是我们踩过的） |
| [docs/06-mainline.md](docs/06-mainline.md) | 进阶：换主线 Linux + KDE 的路线 |
| [tee/](tee/) | **成品 tee 镜像**（已签名，可直接刷）+ 适配基座对照表 |
| [profiles/](profiles/) | 固件 profile（ATF/LK 偏移定义）|
| [tools/](tools/) | 为新固件重新定位 profile 的逆向工具 |
| [scripts/](scripts/) | 一键脚本 + 启动脚本 + 抓帧/探针工具 |

---

## 常见问题

**Q: 为什么 VNC 连不上？**
> QEMU 的 `-vnc host:0` 里那个数字是 **display 号**，端口 = `5900 + display`。
> 写成 `-vnc :5900` 会变成端口 **11800**（不是 5900！）。
> 而且端口被占时 QEMU 会**静默挪到下一个 display**（→ 5901），
> 所以 `scripts/boot-win.sh` 会先等端口空闲、启动后再核对实际端口。

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

---

## 致谢

- [`MT6895-Mainline`](https://github.com/MT6895-Mainline) —— 这台机器的主线移植项目，也是 NoGZ 补丁工具的上游
- [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) —— ATF NoGZ 补丁的构建/签名工具（本项目的一键脚本封装了它）
- [`kasnria001/pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) —— MTK 证书签名绕过工具
- [kde-yyds](https://space.bilibili.com/2008726064) —— 同机主线 Linux 进展记录，本项目的灵感来源

## License

MIT
