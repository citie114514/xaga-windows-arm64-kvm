# Windows 11 ARM64 磁盘 —— 制作流程

[**中文**](03-windows-vm.md) | [English](en/03-windows-vm.md) | [日本語](ja/03-windows-vm.md) | [Русский](ru/03-windows-vm.md)

> 目标：不用装虚拟机、不在 VM 里跑安装程序，直接在 PC 上做出**可引导、带驱动、绕过 TPM 检查**的 VHDX。

**为什么这么做**：在 ARM 模拟环境下跑 Windows 安装程序是性能地狱（几小时起步）。
把镜像直接在 PC 上"释放"进去，只让手机做一次 OOBE，省下绝大部分时间。

---

## 0. 准备材料

| 材料 | 说明 |
|---|---|
| **Windows 11 ARM64 ISO** | **必须是 ARM64**！x64 的在 ARM 上只能软件模拟，没有意义 |
| **virtio-win ISO** | 从 [fedorapeople](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) 下载 |
| PC | Windows，管理员权限，**至少 30 GB 空闲** |
| 7-Zip | 抽驱动用 |

> ⚠️ **下载 virtio-win 务必校验完整性**。用代理下载时经常被截断，而截断的 ISO 还能"打开"，
> 但读不出里面的数据（表现为工具报错，很容易误判成工具问题）。
> 校验方法：读 ISO 的 PVD（偏移 `16 × 2048`，卷大小在 `pvd[80:84]` 的小端 u32 × 2048），
> 和文件实际大小比对。本项目自带 `scripts/extract-virtio.ps1` 会自动做这个检查。

---

## 1. 一键制作（推荐）

```powershell
# 管理员 PowerShell

# ① 抽 virtio ARM64 驱动
.\scripts\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11

# ② 从 ISO 做出可引导 VHDX
.\scripts\build-windows-vhdx.ps1 `
    -Iso D:\Win11_ARM64.iso `
    -DriversDir .\virtio-arm64-w11 `
    -Out .\win.vhdx `
    -SizeGB 100
```

`build-windows-vhdx.ps1` 会自动完成这 6 件事（每步都有校验）：

```
[1] 挂载 ISO，列出映像，自动挑出 ARM64 的那个（选错架构会直接报错中止）
[2] 建动态 VHDX + 分区：MSR(16M) + Windows(NTFS) + ESP(FAT32, 300M)
[3] dism /Apply-Image /Compact:ON   （CompactOS 压缩，实测只占 ~10 GB）
[4] bcdboot G:\Windows /s S: /f UEFI   ← 最容易漏的一步
    并校验 bootmgfw.efi 的 PE machine == 0xAA64
[5] 离线注入 LabConfig 绕过 TPM/SecureBoot/RAM 检查
[6] dism /Add-Driver 递归注入 virtio ARM64 驱动，并确认 viostor 就位
```

---

## 2. 手工步骤（想搞清楚细节时看这里）

### 2.1 建盘 + 分区

用 Dism++ 或 diskpart 建一个 **100 GiB 动态 VHDX**，GPT 分区：

| 分区 | 大小 | 类型 | 盘符（示例） |
|---|---|---|---|
| MSR | 16 MB | Microsoft Reserved | — |
| Windows | 剩余 | NTFS | `G:` |
| **ESP** | 300 MB | **FAT32 / EFI System** | `S:` |

### 2.2 释放映像

```powershell
# 先看有哪些映像、哪个是 ARM64
dism /Get-WimInfo /WimFile:G:\..\install.wim     # 或 ISO 挂载后的 sources\install.wim

# 释放（CompactOS 压缩）
dism /Apply-Image /ImageFile:D:\sources\install.wim /Index:3 /ApplyDir:G:\ /Compact:ON
```

> 如果 ISO 里是 `install.esd`（不是 wim），需要额外加 `/Compress:recovery`。

### 2.3 写引导 —— **最大的坑**

**Dism++ 之类的工具释放出来的盘，ESP 分区是完全空的**：

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING      ← 就是这个
```

不写引导的话，开机只会"找不到可引导设备"。

**好消息：x64 的 `bcdboot` 可以给 ARM64 映像写引导**，它会自动挑 `bootaa64.efi`：

```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```

日志里会看到它认出了 ARM64（`bootaa64.efi`）：

```
BFSVC: Updating \\?\GLOBALROOT\Device\HarddiskVolume10\EFI\Boot\bootaa64.efi
BFSVC: Copy files which lack a version: y  G:\Windows\boot\EFI -> ...\EFI\Microsoft\Boot
```

完成后的核对清单（**必须全过**）：

| 检查 | 期望 |
|---|---|
| `S:\EFI\Boot\bootaa64.efi` | 存在（兜底引导路径） |
| `S:\EFI\Microsoft\Boot\bootmgfw.efi` | 存在 |
| `bootmgfw.efi` 的 PE machine | **`0xAA64`（ARM64）** ← 不然起不来 |
| `S:\EFI\Microsoft\Boot\BCD` | 存在 |
| BCD 里的 `path` | `\Windows\system32\winload.efi` |

### 2.4 绕过 TPM / SecureBoot / RAM 检查

Windows 11 首次启动会检查硬件要求。离线写注册表绕过：

```powershell
reg load HKLM\OFFLINESYS G:\Windows\System32\config\SYSTEM
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f
}
reg query 'HKLM\OFFLINESYS\Setup\LabConfig'
reg unload HKLM\OFFLINESYS
```

不写这个的话，开机第一步就卡在「这台电脑不满足运行 Windows 11 的最低系统要求」。

### 2.5 注入 virtio 驱动

**目录命名有讲究**（这是从 ISO 里找东西的关键）：

```
virtio-win.iso
├── Balloon\w11\ARM64\      balloon.sys  blnsvr.exe
├── NetKVM\w11\ARM64\       netkvm.sys
├── viostor\w11\ARM64\      viostor.sys     ← 用 virtio-blk 启动盘**必须**有
├── vioscsi\w11\ARM64\      vioscsi.sys
├── vioinput\w11\ARM64\     vioinput.sys  viohidkmdf.sys
├── viogpudo\w11\ARM64\     viogpudo.sys   ← virtio-gpu 显示驱动
├── vioserial\w11\ARM64\    vioser.sys
├── viomem\w11\ARM64\ / viorng\w11\ARM64\ / viosock\w11\ARM64\ / viofs\w11\ARM64\ / pvpanic\w11\ARM64\
```

- ARM64 目录叫 **`ARM64`**（不是 `aarch64`！很多人在这里找不到驱动）
- Windows 11 用 **`w11`** 子目录（Win10 是 `w10`）

注入：

```powershell
dism /Image:G:\ /Add-Driver /Driver:D:\virtio-arm64-w11 /Recurse
```

成功输出：

```
操作成功，其中成功 12 个，不适用 0 个。
```

**注入后必须验证 `.sys` 是 ARM64 PE**（machine = `0xAA64`）：

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
viostor      viostor.sys      ARM64 ✓      ← 共 13 个 .sys，全部 0xAA64
```

---

## 3. 推到手机并启动

```bash
# 推送（USB 更快；/data/media/0 需要 root，所以先推 /data/local/tmp 再搬）
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'

# 确认空间够（实时占用会涨到 ~23 GB）
adb shell su -c 'df -h /data | tail -1'
```

然后：

```bash
# 把 scripts/boot-win.sh 推到手机
adb push scripts/boot-win.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/boot-win.sh && nohup /data/local/tmp/boot-win.sh > /data/local/tmp/boot.out 2>&1 &'

# 看画面
adb forward tcp:5900 tcp:5900
# VNC 客户端连 127.0.0.1:5900（无密码）
```

### 首次开机（OOBE）

会跑 **5~15 分钟**，中间会自己重启一两次（重启后画面可能短暂变黑，属正常）。

**关键页面**：

| 步骤 | 页面 | 怎么做 |
|---|---|---|
| 1 | 这是正确的国家（地区）吗？ | 选 **中国** → 是 |
| 2 | 键盘布局 | **微软拼音** → 是 |
| 3 | 第二种键盘布局 | 跳过 |
| 4 | **让我们为你连接网络** | 选 **「我没有 Internet 连接」** → **「继续执行受限设置」** ← 这样能建**本地账户**，不用微软账号 |
| 5 | 许可协议 | 接受 |
| 6 | 谁将使用此设备？ | 输用户名，**密码留空**最省事 |
| 7 | 隐私设置 | 全关 → 接受 |
| 8 | 🎉 进桌面 | 首次进桌面还会再花几分钟铺桌面 |

**如果第 4 步没有「我没有 Internet 连接」**：
按 `Shift + F10` 调命令行 → 输入 `oobe\bypassnro` → 会自动重启，重启后再到这页就有跳过选项了。

### 装完之后的建议

- **装气球内存服务**（把闲置内存还给 Android，手机上这个很值钱）：
  挂上 `virtio-win.iso` 光盘（`boot-win.sh` 会自动挂 `/data/local/tmp/virtio-win.iso`），
  在 Windows 里打开光驱 → `Balloon\w11\ARM64\blnsvr.exe` → 安装
- **关掉视觉特效**（软件渲染下能明显提速）：系统属性 → 高级 → 性能 → 调整为最佳性能

---

## 4. 关于"guest tools"的重要事实

**virtio-win 没有 ARM64 版的 guest tools 安装包。** 全量扫过 ISO：

```
guest-agent\qemu-ga-i386.msi        ← 只有 x86
guest-agent\qemu-ga-x86_64.msi      ← 只有 x64
virtio-win-gt-x64.msi               ← 只有 x64
virtio-win-gt-x86.msi               ← 只有 x86
virtio-win-guest-tools.exe          ← 安装器里装的也是上面这些
```

**所以不要浪费时间找 ARM64 的 guest tools MSI —— 不存在。**

ARM64 目录里只有**驱动本体**和几个**能用的辅助 EXE**：

| 文件 | 用途 |
|---|---|
| `blnsvr.exe` | 气球内存服务（**值得装**） |
| `vgpusrv.exe` / `viogpuap.exe` | virtio-gpu 用户态组件 |
| `virtiofs.exe` | virtio-fs 共享目录（需要 QEMU 侧配 `vhost-user-fs`） |
| `netkvmco.exe` / `netkvmp.exe` | 网卡配置工具 |
| `qemu-ga` | ❌ **没有 ARM64 版** |

**核心的驱动注入已经在第 2.5 步做完了**，这就够了。

---

## 5. 不用 virtio 磁盘行不行？

行。**Windows 11 ARM64 自带 NVMe（`stornvme`）驱动**，所以用 NVMe 当启动盘**零注入**就能启动：

```
-device nvme,serial=win,drive=nv0
```

**取舍**：

| 方案 | 需要注入驱动 | 速度 | 说明 |
|---|---|---|---|
| **virtio-blk**（本项目默认） | ✅ 需要 `viostor` | 快 | 驱动注入过了就没问题 |
| NVMe | ❌ 不需要 | 也很快 | 零注入的保底方案 |
| IDE/AHCI | ❌ | 慢 | 不推荐 |

**建议**：既然驱动都注入了，就用 `virtio-blk`（和网络/显卡/气球一套，最干净）。
如果想先验证"盘能不能启动"，可以先用 NVMe 排除驱动因素。

---

## 6. 下一步

- **了解 QEMU 参数怎么调** → [04-usage.md](04-usage.md)
- **遇到问题** → [05-gotchas.md](05-gotchas.md)
