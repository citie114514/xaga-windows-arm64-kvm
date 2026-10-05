# 在 Redmi Note 11T Pro+ (MT6895) 上跑 Windows 11 ARM64

> 用 **KVM** 在手机上原生虚拟化 Windows 11 ARM64 —— 从「MTK 机器为什么不能 KVM」到「桌面跑起来」的完整记录。

![Windows 11 ARM64 桌面](images/final-1080.png)

<!-- 上方截图：1920×1080 的 Windows 11 桌面在 Redmi Note 11T Pro+ 上通过 QEMU/KVM 运行 -->

| 项 | 值 |
|---|---|
| 设备 | Redmi Note 11T Pro+（`xagapro` / `22041216UC`） |
| SoC | MediaTek MT6895 (Dimensity 8100)，4×Cortex-A78 + 4×Cortex-A55，Mali-G610 |
| 宿主 | Android 15 / HyperOS 3（KernelSU root，BL 已解锁） |
| 客户机 | Windows 11 专业版 ARM64（zh-CN，26100 系） |
| 加速 | **KVM**（ATF 打补丁后暴露 `/dev/kvm`） |
| 磁盘 | 100 GiB 动态 VHDX → 实测占 23.4 GiB |

---

## 快速结论（TL;DR）

MTK 机器默认**不能** KVM，因为 **EL2 被 MediaTek 的 GenieZone(GZ) 固件占着**，内核拿不到虚拟化扩展。
解决办法是**换掉 `tee_a` 分区里的 `atf` 成员**（跑在 EL2 的那段 ATF），让 EL2 交给 Linux：

1. 从 `tee_a` 里剥出未签名的 NOGZ 版 ATF 镜像
2. 用公开的 `pwnage24mtk` 工具做 **LEGACY 模式签名**（利用 MTK ASN.1 证书解析缺陷）
3. `dd` 写回 `tee_a`，重启
4. 日志出现 `[SBC] image atf header auth pass`，`/dev/kvm` 出现 ✓

之后 Windows 那侧就是常规操作了 —— 但有**几个必踩的坑**（见[坑清单](#坑清单)）。

---

## 一、为什么 MTK 手机上 KVM 默认不可用

先确认现象（全是只读操作）：

```bash
adb shell su -c 'ls -l /dev/kvm'          # No such file or directory
adb shell su -c 'cat /proc/misc'          # 46 项里没有 kvm
adb shell su -c 'ls -l /dev/gz*'          # /dev/gz_kree 存在，/dev/gzvm 不存在
```

对照：

| 节点 | 本机 | 说明 |
|---|---|---|
| `/dev/kvm` | ❌ | EL2 被占，内核不暴露 |
| `/dev/gunyah` | ❌ | 新一代 Gunyah 不存在 |
| `/dev/gz_kree` | ✅ (char 10,99) | 老一代 GZ 的 KRE 接口 |
| `/dev/gzvm` | ❌ | crosvm / DroidVM 的 GZ 虚拟化入口，**缺这个就没法用 GZ 后端** |

`VMHypervisor.GENIEZONE` 查的正是 `/dev/gzvm`，而且 DroidVM 里 **QEMU 后端不支持 GENIEZONE**（只有 crosvm 支持）。
→ **结论：想在 DroidVM 里跑 VM，只能走 KVM 后端 → 必须刷 ATF。**

### 关键：Secure Boot 是**开着**的

从 `expdb` 分区（preloader 启动日志落盘处）里直接读出：

```
440  sbc_en = 1                    ← preloader 自己算出来的值
220  [PART] img_auth_required = 1
 21  [SEC_POLICY] lock_state = 0x3
 21  cert vfy(24 ms) / cert vfy(17 ms) ...
```

`seccfg` 分区裸数据也对得上（偏移 `0x0C` = `0x03`）。

**SBC 的判定来自 eFuse（OTP，不可改）** —— preloader 里那段：

```asm
0x020522FC  push   {r7, lr}
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; efuse 读取
0x02052306  ubfx   r0, r0, #1, #1     ; SBC = bit 1
0x0205230A  pop    {r7, pc}
```

**所以：工程 preloader 能让你"免费写进去"，但改不了"启动时校不校验"。改过的 ATF 必须过 MTK 签名。**
（详见 [`docs/01-tee-nogz-kvm.md`](docs/01-tee-nogz-kvm.md) 的完整逆向过程）

---

## 二、把 `/dev/kvm` 弄出来

### 2.1 完整校验链（理解为什么必须签名）

ATF 的加载发生在 `bl2_ext` 阶段，每个启动都走两段校验，且**零 fail**：

```
第一段  preloader:      part: lk_a img: bl2_ext   cert vfy(17..30 ms) ×21
第二段  bl2_ext [SBC]:  [SBC] image atf  header auth pass  ×5
                        [SBC] image tee  header auth pass  ×5
                        [SBC] image lk   header auth pass  ×5
                        ...（共 20+ 个镜像）
```

ATF 的实际装载点：

```
Load 'tee_a' partition to 0xffff000048200000    ; mblock-15-BL31-reserved 基址
                                                 ; 283016 = atf 成员大小
```

→ 跑在 EL2 的就是 `tee_a` 里的 `atf` 成员，也正是要被替换的那个。

### 2.2 签名（pwnage24mtk，LEGACY 模式）

工具：[`kasnria001/pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk)（公开）

原理：MTK 的 ASN.1 证书解析逻辑缺陷（CVE-2023-20696 同类，CVE-2025-20730 才修补）。
老设备用 `--legacy`（= `bypass_mode 1`，对应本机检测出的 `enter-value traversal, arg4=1`）：

```bash
python sign_mtk_cert.py   <unsigned.img> --legacy -w -o <out.img>
python verify_mtk_image.py --all <out.img>     # 要看到 2 个 Result: VALID
```

### 2.3 必须注意：签名后超出分区 1072 字节

```
unsigned : 5 242 880   (= 分区大小，刚好占满)
signed   : 5 243 952   (+1072，来自 BIT STRING wrapper + CERT2 膨胀)
```

**但插入点在 `atf` 之后，尾部 1.75 MB 零填充完全没变** →
**裁掉 1072 字节的尾部零填充即正好 5 MiB，零真实数据损失**（已逐字节验证被裁部分全为 0x00）。

### 2.4 刷入与验证

> ⚠️ **不要用 SP Flash 深刷** —— 深刷会把 BL 重新锁上。用 `dd` 直写 `tee_a` 即可（BL 已解锁）。

```bash
# 备份原厂（务必！）
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_stock.img'
adb pull /data/local/tmp/tee_stock.img

# 写入（tee_a 分区大小 5242880 字节）
adb push tee_nogz_legacy_5M.img /data/local/tmp/
adb shell su -c 'dd if=/data/local/tmp/tee_nogz_legacy_5M.img of=/dev/block/by-name/tee_a bs=4096'
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 count=1280 | sha256sum'   # 回读校验
adb reboot
```

重启后应该看到：

```
[SBC] image atf header auth pass      ← pwnage 的证书漏洞在本机成立
crw-rw-rw- 1 root root ... 10, 232  /dev/kvm
232 kvm                                ← /proc/misc 里出现了
```

**决定性验证** —— 真跑一个 Linux guest（用系统自带的 AVF `crosvm`）：

```bash
su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

guest 输出：

```
Booting Linux on physical CPU 0x0 [0x412fd050]      ← A55
GICv3: CPU0: found redistributor 0 region 0:0x3ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x1 [0x411fd411]   ← A78
smp: Brought up 1 node, 2 CPUs
```

→ **ATF → EL2 → VHE → KVM → 2 vCPU Linux guest 完整启动，整条链路闭环。**

### 2.5 成品校验值

| 文件 | 大小 | sha256 |
|---|---|---|
| `tee_nogz_legacy_5M.img`（补丁版） | 5242880 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `tee_stock.img`（原厂，回滚用） | 5242880 | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

> `tee_b` 保持原厂未动 —— 切到 B 槽会回到无 KVM 状态，是天然兜底。

---

## 三、准备 Windows 11 ARM64 磁盘

**思路**：不在虚拟机里跑安装程序，而是在 PC 上用 **Dism++** 直接把 `install.wim` 释放进一个磁盘镜像，
带上引导和驱动，然后整个镜像推给手机引导。省掉整个 OOBE 安装过程（也避开了在 ARM 模拟环境下跑安装器的性能地狱）。

### 3.1 释放镜像

1. 用 Dism++ 创建一个 **动态 VHDX**（100 GiB）
2. 分区：MSR(16M) + Windows(NTFS) + **ESP(300M, FAT32)**
3. `文件 → 释放映像` → 选 `install.wim` 里的「Windows 11 专业版」→ 勾选 **CompactOS**
4. 实测释放后占约 10 GB

### 3.2 ⚠️ 写引导 —— 最大的坑：ESP 是空的

用 Dism++ 释放出来的磁盘，**ESP 分区是完全空的**（只有 `System Volume Information`）：

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING      ← 就是这个
```

**必须自己写引导。好消息：x64 的 `bcdboot` 可以给 ARM64 映像写引导**，它会自动挑 `bootaa64.efi`：

```powershell
# 管理员 PowerShell：挂载 ESP 到 S:，然后
bcdboot G:\Windows /s S: /f UEFI /v
```

日志里的关键行（证明它认出了 ARM64 目标）：

```
BFSVC: Updating \\?\GLOBALROOT\Device\HarddiskVolume10\EFI\Boot\bootaa64.efi
BFSVC: Copy files which lack a version: y  G:\Windows\boot\EFI -> ...\EFI\Microsoft\Boot
```

完成后核对：

```
EFI\Boot\bootaa64.efi           3120480 bytes
EFI\Microsoft\Boot\bootmgfw.efi  machine = 0xAA64      ← 必须是 ARM64
BCD                              path = \Windows\system32\winload.efi
```

### 3.3 绕过 TPM（离线改注册表）

Windows 11 首次启动会检查 TPM/SecureBoot/RAM。离线注入 `LabConfig`：

```powershell
reg load HKLM\OFFLINESYS G:\Windows\System32\config\SYSTEM
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f
}
reg unload HKLM\OFFLINESYS
```

---

## 四、注入 virtio ARM64 驱动

从 [virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) 下载 ISO（注意校验完整性，代理可能截断）。

**目录命名有讲究**：ARM64 目录叫 **`ARM64`**（不是 `aarch64`），Windows 11 用 **`w11`** 子目录：

```
virtio-win.iso
├── Balloon\w11\ARM64\      blnsvr.exe
├── NetKVM\w11\ARM64\       netkvm.sys
├── viostor\w11\ARM64\      viostor.sys     ← 用 virtio-blk 启动盘**必须**有！
├── vioscsi\w11\ARM64\
├── vioinput\w11\ARM64\
├── viogpudo\w11\ARM64\     ← virtio-gpu 显示驱动
└── ... (Balloon pvpanic viofs vioinput viomem viorng vioserial viosock)
```

用 Dism++ 的「驱动管理 → 添加驱动」递归注入目录即可。成功输出：

```
操作成功，其中成功 12 个，不适用 0 个。
```

**注入后务必验证 `.sys` 是 ARM64 PE**（machine = `0xAA64`），否则注入了也起不来：

```
Balloon    balloon.sys    ARM64 ✓
NetKVM     netkvm.sys     ARM64 ✓
viostor    viostor.sys    ARM64 ✓
vioinput   viohidkmdf.sys ARM64 ✓
... 共 13 个 .sys，全部 0xAA64
```

> **为什么启动盘用 `virtio-blk` 也行**：因为 `viostor` 注入了。
> 想零注入启动可以改用 **NVMe**（Windows 11 ARM64 自带 `stornvme` inbox 驱动）✓

---

## 五、启动

### 5.1 固件：**必须用标准 AAVMF**

DroidVM 自带的 `edk2-qemu.fd` 是自建魔改版（同尺寸但内容差 134 万字节），
在 QEMU 上会**自旋卡死**（串口只有 `ab=000 c=400 1234564`）。

换成标准 [AAVMF](https://packages.debian.org/bookworm/qemu-efi-aarch64) 的 `QEMU_EFI.fd`（3,145,728 字节）立刻正常。

### 5.2 完整命令

```bash
Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=/data/media/0/DroidVM/win.vhdx          # 用原生路径，绕过 FUSE

export LD_LIBRARY_PATH=/system/lib64

taskset f0 "$Q" \
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

看画面：

```bash
adb forward tcp:5900 tcp:5900
# 然后用任意 VNC 客户端连 127.0.0.1:5900（无密码）
```

脚本见 [`scripts/boot-win-fast.sh`](scripts/boot-win-fast.sh)。

### 5.3 首次启动

OOBE 会跑 5~15 分钟。**关键一步是「连接网络」那页** —— 我们的网卡配了 slirp，
所以直接用 **「我没有 Internet 连接」→「继续执行受限设置」** 建本地账户最省事
（不会就走 `Shift+F10` → `oobe\bypassnro` 重启一下）。

---

## 坑清单

踩过的坑，按杀伤力排序：

| # | 坑 | 真相 |
|---|---|---|
| 1 | **ESP 是空的** | Dism++ 释放映像**不写引导**。必须 `bcdboot`，否则开机找不到可引导设备 |
| 2 | **`-vnc 127.0.0.1:5900` 连不上** | QEMU 把冒号后的数字当 **display 号**：`5900` → 端口 **11800**！要用 `:0`（= 5900） |
| 3 | **`-device usb-tablet,bus=usb` 报 `Bus 'usb' not found`** | `-device qemu-xhci,id=usb` 时，总线名是 **`usb.0`** 不是 `usb`。去掉 `bus=` 最省事 |
| 4 | **`-cpu host` 随机失败** | big.LITTLE 竞态：写 vCPU 寄存器时被调度器在 A55/A78 间迁移 → `Failed to put registers after init: Invalid argument`。实测不绑核 2/5 成功，`taskset f0` 后 3/3 |
| 5 | **`pkill -f qemu-system-aarch64.real` 杀掉自己的 shell** | `-f` 匹配完整命令行，而外层 `su -c '...qemu-system-aarch64.real...'` 里就含这个串。用短名 `pkill qemu-system-aar` |
| 6 | **`adb push` 到 `/data/media/0/` 权限拒绝** | shell 用户写不进，先推 `/data/local/tmp` 再 `su -c mv` |
| 7 | **Windows 安装 ISO 挂 CD 会抢引导** | 那是可引导的 El Torito 盘。要挂就挂 `virtio-win.iso`（纯数据盘，无 EFI 引导，安全） |
| 8 | **虚拟机里时间变成 2768 年** | RTC 初值读取偏差（**+742 年**）。但 PL031 是 32 位秒计数器，物理上最多到 2106 年 → 是 QEMU 侧的 bug。**有网后 NTP 自愈** |
| 9 | **DroidVM 会重写 `vms.json`** | 手加的字段会让 VM 被判定"当前版本读取不了"而消失。只改它已有的字段才安全 |
| 10 | **`virtio-gpu-rutabaga-pci` + `-display egl-headless` 直接 SIGSEGV** | exit=139 崩溃。要用 `virtio-gpu-pci`（+ `-display egl-headless` 时可跑 virgl） |

---

## 网络 / 显示 / 性能

### 网络

用 **QEMU 用户态 NAT（slirp）**，VM 拿 `10.0.2.15`，网关/DNS 是 `10.0.2.2` / `10.0.2.3`。
`netkvm` 驱动注入过，免驱直接用。验证方式（看 QEMU 进程的出网连接）：

```bash
ss -tnp | grep qemu | grep -v 127.0.0.1
# ESTAB 192.168.31.75:44394 -> 204.79.197.235:443   ← Microsoft
```

### 显示：Windows 没有 GPU 加速（硬限制）

| 方案 | Windows 客机 | Linux 客机 |
|---|---|---|
| virtio-gpu + viogpudo | ✅ 能用，但**纯 DOD 显示，无 3D** | — |
| **virgl** | ❌ **Windows 没有 virgl 驱动**，不存在 | ✅ Mesa `virgl` 可用 |
| `virtio-gpu-rutabaga` (gfxstream) | ❌ 且本机段错误崩溃 | — |

**所以 Windows 这台永远是软件渲染。** 但实测 `-display egl-headless` 下 **virgl 能成功初始化**
（`/dev/dri/card0` + `libvirglrenderer.so` 都在），**Linux 客机可以走真 GPU 加速**。

### 性能优化（实测数据）

| 优化 | 效果 |
|---|---|
| **`-vnc ...,lossy=on`** | 每帧数据量 **3.00 MB → 0.36 MB（1/8.3）** ✓✓✓ 最大的一刀 |
| 分辨率降到 720p | 像素 -44% |
| **adb 转发隧道实测 276 MB/s** | → **隧道不是瓶颈**，别在网络上瞎折腾 |
| `-device virtio-balloon-pci` | 配合 guest 里的 `blnsvr` 可把闲置内存还给 Android |

> **真正的流畅度关键**：**显示路径**。画面在本机（原生显示 / localhost VNC）时最流畅；
> 绕到 PC 上过 VNC 就会有延迟感。

---

## 主线 Linux 现状（同机）

这台机器的主线移植已经相当完整 —— 项目：[`MT6895-Mainline`](https://github.com/MT6895-Mainline)，
内核分支 **`7.2-mt6895-xiaomi-xaga`**。

| 子系统 | 状态 |
|---|---|
| 内核 | **Linux 7.2**（主线） |
| GPU | **Mali-G610 — Panthor/PanVK** ✓ |
| 桌面 | **KDE Plasma，完整 GPU 加速** ✓ |
| 显示 | 华星/天马屏都支持，**144Hz 高刷** |
| 音频 | 扬声器 ✓ 3.5mm 耳机 ✓ |
| 无线 | WiFi ✓ 蓝牙 ✓ |
| 其他 | 指纹 ✓ 自动亮度/旋转 ✓ 相机 RAW ✓ PPS 快充 ✓ |

**启动方式**（和本项目方案一致）：保留原厂 **LK**（不移植 U-Boot）、**dtb 塞进内核**、
内核 → `boot` 分区、rootfs → `userdata` 分区。

> ⚠️ **Linux 7.2 的 panthor 有个已知问题**：新引入的 GEM Shrinker 在**内存压力大时开销极高，会出现严重卡顿** ——
> 而跑 VM 正是高内存压力场景。修复：用这个 commit 或直接关掉 shrinker
> [`MT6895-Mainline/linux@4fadce8d`](https://github.com/MT6895-Mainline/linux/commit/4fadce8d6bbce016a8965ad93a5285c565401c1d)

参考频道：[kde-yyds](https://space.bilibili.com/2008726064)（B 站，这台机器主线进展的持续记录）

---

## 仓库内容

```
.
├── README.md                      ← 本文
├── conversation.md                ← 完整对话记录（2.5 MB，从零到跑通的全部过程）
├── docs/
│   ├── 01-tee-nogz-kvm.md         ← ATF/preloader 逆向 + 签名 + 实机验证（技术细节全在这）
│   └── 00-report-legacy.md        ← 早期探索报告
├── scripts/
│   ├── boot-win-fast.sh           ← QEMU 启动脚本（含全部优化参数）
│   ├── stop-vm.sh                 ← 安全停止（避开 pkill -f 自杀坑）
│   ├── flash-tee.sh               ← TEE 刷入 + 回读校验
│   ├── vncgrab.py / vncprobe.py   ← VNC 抓帧 / 吞吐探针
│   ├── dl-resume.sh               ← 断点续传下载（代理会掐断连接时用）
│   └── export-session.py          ← 把 pi 会话日志导出成 markdown
├── issues/                        ← 给 DroidVM 提交的 4 个 issue + 1 个上游 PR
└── images/                        ← 过程截图
```

---

## 致谢 / 参考

- [`MT6895-Mainline`](https://github.com/MT6895-Mainline) —— 这台机器的主线移植项目（也是本项目 ATF 补丁的上游）
- [`kasnria001/pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) —— MTK 证书签名绕过工具
- [kde-yyds](https://space.bilibili.com/2008726064) —— 同机主线进展视频记录
- [DroidVM](https://github.com/) —— Android 上的 VM 管理器（本项目提交了 4 个 issue）

## 免责声明

刷 ATF/TEE 属于**修改设备信任链**的操作。虽然本项目全程实机验证成功，但：

- **务必先备份原厂 `tee_a`**（本文给了 sha256 供核对）
- `tee_b` 未动，是天然兜底；实在不行还能走 **preloader 模式**（免授权）救砖
- **不要用 SP Flash 深刷**（会把 BL 重新锁上）
- 一切后果自负

## License

MIT
