# 坑清单

[**中文**](05-gotchas.md) | [English](en/05-gotchas.md) | [日本語](ja/05-gotchas.md) | [Русский](ru/05-gotchas.md)

全部是我们在 Redmi Note 11T Pro+ 上**实际踩过**的坑。按"杀伤力"排序。

---

## 1. 🔴 ESP 是空的 —— 开机找不到可引导设备

**症状**
```
BdsDxe: No bootable option or device was found.
```
或者卡在 UEFI 界面 / 直接跳进 UEFI Shell。

**原因**
用 Dism++ 之类的工具释放映像时，**ESP 分区不会被写引导**。刚格式化完的 ESP 里只有：

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING
```

**解决**
```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```
x64 的 `bcdboot` **可以**给 ARM64 映像写引导，会自动挑 `bootaa64.efi`。
写完核对 `bootmgfw.efi` 的 PE machine 必须是 **`0xAA64`**。

详见 [03-windows-vm.md](03-windows-vm.md) 第 2.3 节。

---

## 2. 🔴 VNC 端口不是你以为的那个

**症状**
`adb forward tcp:5900 tcp:5900` 之后，VNC 客户端连不上 / 连上了是黑屏。
但**有时候又能连** —— 行为飘忽。

**原因（两层）**

1. `-vnc 127.0.0.1:N` 里 **`N` 是 display 号，不是端口号**，端口 = `5900 + N`
   → 写成 `-vnc 127.0.0.1:5900` 实际监听 **11800** ✗（不是 5900）
2. **端口被占时 QEMU 不报错**，而是**静默把 display 号 +1**
   → 你以为它在 5900，其实跑到了 **5901** ✗

**解决**

```bash
# 正确写法：:0 → 端口 5900
-vnc 127.0.0.1:0,lossy=on
```

**并且**启动前要等端口真的空闲、启动后要核对实际端口：

```bash
# 启动前
for i in $(seq 1 30); do
    netstat -tln | grep -q ":5900 " || break
    sleep 1
done

# 启动后
netstat -tlnp | grep qemu        # 必须显示 127.0.0.1:5900
```

`scripts/boot-win.sh` 已经把这两件事都做了，并且**核对失败会直接退出**。

---

## 3. 🔴 `-cpu host` 在 big.LITTLE 上随机失败

**症状**
```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```
同一命令连跑 5 次，有时候成功有时候失败。

**原因**
`-cpu host` 枚举的是 **QEMU 当前所在 CPU** 的特性。MTK 是 4×A78 + 4×A55，
写 vCPU 寄存器期间如果被调度器在 A55/A78 之间迁移 → `EINVAL`。

**实测数据**

| 条件 | 成功率 |
|---|---|
| 不绑核 | **2/5** ✗ |
| `taskset 1`（cpu0，A55） | **3/3** ✓ |
| `taskset 80`（cpu7，A78） | **3/3** ✓ |
| `taskset f0`（cpu4-7，A78 簇） | **3/3** ✓ |

**解决**
```bash
taskset f0 qemu-system-aarch64 ...
```

> 各种 `-cpu` 变体（`host,pmu=off`、`host,sve=off` 等）表现**不稳定，随机性大于特性差异**，
> 不要指望靠调特性绕过 —— **就是绑核**。

---

## 4. 🔴 `pkill -f` 把自己的 shell 杀掉了

**症状**
脚本执行到一半突然没了，没有任何输出，进程也没起来。

**原因**
```bash
adb shell su -c 'pkill -f qemu-system-aarch64.real; ...'
```
`pkill -f` 匹配的是**完整命令行**，而**外层 `su -c` 的命令行里就含有这个字符串** →
**把自己的 shell 也杀了**。

**解决**
用**短进程名**匹配（`pkill` 默认只匹配进程名，debian 上 comm 最长 15 字符）：

```bash
pkill qemu-system-aar
```

或者把 `pkill` 放进**脚本文件**里执行（脚本自身的命令行不含那个字符串）：

```bash
# scripts/stop-vm.sh
pkill qemu-system-aar
```

---

## 5. 🟠 `-device usb-tablet,bus=usb` 报总线不存在

**症状**
```
qemu-system-aarch64: -device usb-tablet,bus=usb: Bus 'usb' not found
```
QEMU 直接起不来。

**原因**
`-device qemu-xhci,id=usb` 里的 `id=usb` **只是设备 id**，USB 总线名是 **`usb.0`**（`<id>.0`）。

**解决**
**去掉 `bus=`**，让它自动挂到唯一的 USB 控制器上（最省事）：

```bash
-device qemu-xhci,id=xhci -device usb-tablet -device usb-kbd
```

---

## 6. 🟠 挂 Windows 安装 ISO 会抢引导

**症状**
明明装了系统，开机却进了 Windows 安装程序。

**原因**
Windows 安装 ISO 是**可引导的**（El Torito + `EFI\BOOT\BOOTAA64.EFI`），
UEFI 可能优先选它。

**解决**
- 装完系统后**别挂** Windows 安装 ISO
- 要挂光盘就挂 **`virtio-win.iso`** —— 它是**纯数据盘**（`genisoimage` 生成的 ISO9660，无 El Torito、无 EFI 目录），**挂上去安全**

---

## 7. 🟠 `adb push` 到 `/data/media/0/` 权限拒绝

**症状**
```
adb: error: stat failed when trying to push to /data/media/0/DroidVM/win.vhdx: Permission denied
```

**原因**
`/data/media/0` 是 root 专属目录，adb 的 shell 用户写不进去。

**解决**
先推到 shell 能写的地方，再 `su` 搬过去（**同一文件系统内是秒级 rename**）：

```bash
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'
```

> 顺带一提：`/storage/emulated/0/...` 是 **FUSE 挂载**，`/data/media/0/...` 是**原生路径**，指向同一个文件。
> QEMU 用原生路径可以绕过 FUSE 层。（实测读速率两者都是 ~950 MB/s，差别不大，但原生更稳。）

---

## 8. 🟠 虚拟机里时间变成 2768 年

**症状**
Windows 任务栏显示 `2768/12/24`。

**原因**
QEMU 侧 RTC 初值读取有偏差（**+742 年**）。
但 **PL031 RTC 是 32 位秒计数器，物理上最多只能表示到 2106 年** ——
所以**不可能是 RTC 给出的值**，是 QEMU 构建的转换 bug。

**解决**
**有网之后 Windows NTP 会自动纠正**（这也顺带证明了网络是通的）。
想手动改：

```powershell
# Windows 里，管理员 PowerShell
Stop-Service w32time; Set-Service w32time -StartupType Disabled
Set-Date -Date "2026-10-06 03:20:00"
```

或者右键任务栏时间 → 调整日期和时间 → 关掉「自动设置时间」→ 手动改。

---

## 9. 🟠 DroidVM 的配置体系：三个必须分清的事

DroidVM 应用和 QEMU 命令行是**两套互不相通的启动方式**。混着用必踩坑。

### (a) 应用建的配置**本身就跑不起来**

DroidVM 生成的启动参数缺东西：

- **virtio 网卡没挂 `-netdev` 后端** → 客机里没有网
- **没有 `virtio-balloon`** → 内存只涨不跌

**解决**：装一层**包装脚本**，把应用调用的 `qemu-system-aarch64` 换成
wrapper（转发给 `.real`），在启动时按需补齐 —— 完整安装方法见
[scripts/phone/README.md](../scripts/phone/README.md)。
**只在调用方没给时才补**，所以不会干扰自己写的启动脚本。

### (b) VNC 端口默认是**随机的**

`vms.json` 里 `screens.*.vnc.port` 默认 **`-1`** = "自动挑一个"：

```json
"vnc": { "host": "127.0.0.1", "port": -1, "password": "", "password_auth": false }
```

**后果**：每次启动端口可能都不同 ✗ —— 你 `adb forward tcp:5900` 转发的端口
根本没人听 ✗。这是「虚拟机明明起来了却连不上 VNC」的常见原因。

本项目**绕开这条路**：`boot-win.sh` 直接写死 `-vnc 127.0.0.1:0`（= 5900），
启动后再核对一次实际端口。

> 把 `port` 字段改成固定值**理论上是另一条路，但未实测**，
> 而且有下面 (c) 的风险，因此本项目的脚本不依赖它。

### (c) 手改 `vms.json` 会让应用读不出来

**症状**
手改了 `vms.json`（比如换磁盘路径），结果 VM 在应用里**消失了**，提示"当前版本读取不了"。

**原因**
DroidVM 用自己严格的 schema 校验，**不认识手加的字段**，就把整个条目剔除。

**解决**
- **只改它已有的字段**（比如 `disks[].path`、`screens.*.exporter`），**不要新增字段**
- 改完保留原属主和权限：
  ```bash
  OWN=$(stat -c %u vms.json); GRP=$(stat -c %g vms.json); MODE=$(stat -c %a vms.json)
  # ... 改 ...
  chown $OWN:$GRP vms.json; chmod $MODE vms.json
  ```
- **改之前先备份** `cp vms.json vms.json.bak`

### 结论：二选一，别混

| 路线 | 优点 | 缺点 |
|---|---|---|
| **`boot-win.sh` 命令行**（推荐） | 参数完全可控、端口固定 5900、不看应用脸色 | 没有图形界面，改参数要编辑脚本 |
| **DroidVM 应用启动** | 有界面、能管多台 | 参数不全（要 wrapper 补）、端口随机、配置不能手改 |

> 两者**不要同时用**：应用启动会重写 `vms.json`，命令行启动完全不碰它。

---

## 10. 🟡 `virtio-gpu-rutabaga-pci` 直接崩溃

**症状**
```
exit=139      # SIGSEGV
```
QEMU 秒崩，没有任何输出。

**原因**
`virtio-gpu-rutabaga-pci`（走 gfxstream 的那套）+ `-display egl-headless` 在这个构建上段错误。
顺带一提，`virtio-gpu-gl-pci` + `-display none` 也会报
`The display backend does not have OpenGL support enabled`。

**解决**
- 正常显示用 **`virtio-gpu-pci`**（Windows 走 `viogpudo`）
- 要跑 **virgl**（Linux 客机才有意义）用 **`virtio-gpu-gl-pci` + `-display egl-headless`**（实测能初始化成功）
- **别用 rutabaga**

---

## 11. 🔴 **刷 ROM / OTA 后补丁失效（最容易白折腾的一条）**

**症状**
刷完新 ROM，`/dev/kvm` 不见了 —— 或者刷了个「别的固件做的补丁」进 `tee_a`，
**看着像是卡开机**（⚠️ 但先看完第 12 条 —— 刚刷完补丁本来就会卡第二屏等 2 分钟 ✗）。

**原因**
NoGZ 补丁改的是 `tee` 分区里 `atf` 成员的启动交接逻辑，
所以 **补丁只对「构建它时用的那个 `tee` 基座」有效**。

实测（同一台 Redmi Note 11T Pro+，两台机器对照）：

| 设备 | `tee_a` | `lk_a` | 结果 |
|---|---|---|---|
| 备用机 · Android 15 原 ROM | `f8f286f1…` → 刷成补丁 `f1511dca…` | `8cbaa2e8…` | ✅ 开机 + KVM |
| 备用机 · 升级到 **Android 16** | 补丁 `f1511dca…`（**没变**） | **`a17d87c6…`（变了！）** | ✅ **依然开机 + KVM** |
| 主力机 · **不同批次的**固件 | 被 ROM 更新成 `a91f5ded…` | `a17d87c6…` | 刷「备用机的补丁」→ 当时看着像卡开机 ⚠️ |

> ⚠️ **读这张表必须先分清「同基座」和「跨基座」** ——
> 这是最容易误读的一点：
>
> | 情形 | 备用机 | 主力机 |
> |---|---|---|
> | 刷的补丁基座 | `f8f286f1…`（rk 补丁）| `f8f286f1…`（rk 补丁）|
> | 刷之前自己的 `tee_a` | **`f8f286f1…`** | **`a91f5ded…`** |
> | 判定 | ✅ **同基座** | ❌ **跨基座** |
>
> **所以备用机刷成功“不能”当成“跨基座也可行”的证据** ✗ ——
> 它恰恰只是证明了“**同基座可用**” ✓。
> **真正跨基座的情况只有主力机那一次** ⚠️（而且结论不可靠，见下）。

**结论（很反直觉，但实测如此）**：

- ✅ **`lk` 变了不影响补丁**（备用机 `lk_a` 换过，照样跑）
- ✅ **GZ / dtbo / boot / system 变了也不影响**（跨 Android 15 → 16 都正常）
- ❌ **`tee` 基座变了就会失效** —— 这是唯一已知的「命门」
- ⚠️ **同一批固件基座相同**，不同批次可能不同（本案例里上游 `xaga` profile 的基座
  `bd4b13a7…` 就是第三批）；**不是「每台机器都不一样」**

> 🛠 **重要修正（2026-10-06）**：上表最后一行的「卡开机」**依据不可靠**。
> 后来实测发现：**刷完补丁后第一次启动，本来就会在第二屏卡将近 2 分钟才进系统**
> （见第 12 条）。当时没等够就判了死刑 ✗。
> 而 2026-10-07 的备用机实验已经结清：**跨基座【能正常启动】** ✓
> —— 既不是「必坏」✗，也不是「未验证」⚠️，而是**已实测可行** ✓（详见 [tee/README.md](../tee/README.md)）。
> 推荐用针对自己基座的补丁仍然是正确做法 ✓，理由是 **TEE OS 版本匹配**，不是会卡二。

**最坑的地方：ROM 包里没有 `tee` 镜像，也可能被改**

主力机刷的那个 ROM 包里**根本没有 tee 镜像**，但刷完后 `tee_a` 还是从
`f8f286f1…` 变成了 `a91f5ded…`（应该是首次开机的固件更新或 `super.img` 触发的）。
**所以不能靠「看包里有没有 tee」来判断会不会被改。**

**解决**

```bash
# ① 刷 ROM 前先备份
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a.bak bs=4096'

# ② 刷 ROM 后算哈希，和补丁的「适配基座」对照
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

| 结果 | 下一步 |
|---|---|
| 没变 | ✅ 补丁继续有效，什么都不用做 |
| 变了 | ⚠️ 推荐 **dump 新的 `tee_a`/`lk_a`/`preloader_raw_a` 重新构建**（同基座最保守）；
但如果只是急着用，**别的基座的成品也能启动** ✓（2026-10-07 实测），只是第一次记得给 3 分钟 |

**判断基座有没有变的最省事方法** —— 看没被动过的那个槽：

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
# = f8f286f1… → 基座没变 ✓
```

**回退**：把备份的 `tee_a` 刷回去；或切 B 槽（`tee_b` 从未改动，天然兜底）。

---

## 12. 🔴 刷完补丁后**每次开机都会卡在第二屏 1~2 分钟** —— 这不是变砖！

**症状**
刷完 NoGZ 补丁之后，**每一次**开机都会停在**开机第二屏**（logo2 / 转圈），
**1~2 分钟没有任何动静** ✗ —— 看起来完全像"卡二 / 变砖"。

> ⚠️ **注意是「每一次」，不是只有第一次** ✗ —— 实测反馈：刷了补丁之后每次开机都这样。

**但这很正常** ✓ —— 实测（主力机，`tee_a` 刷入 `17ec8497…` 后重启）：

```
 20s   adb 已能看到设备，但 sys.boot_completed=0
 30s   ...
 140s  仍在等（整整 120 秒屏幕上没有任何变化）
 150s  sys.boot_completed=1   ← 自己起来了 ✓
```

**结果**：`/dev/kvm` 正常出现 ✓，系统完好 ✓，497 个应用包一个没丢 ✓

**原因（推测）**
补丁让 ATF 不再把 EL2 交给 GZ，启动链里某个环节在**等 GZ 的回应**，
等不到就超时，然后继续往下走 —— 所以是"卡住但不死"。

### ✅ 正确做法：**等 3 分钟**

- **不要**以为变砖 ✗
- **千万不要**急着按「音量下 + 电源」进 fastboot ✗ ——
  **那会打断启动** ✗，把一个本来能好的启动硬生生变成进不了系统 ✗
- 只有**超过 5 分钟**仍无任何反应，才考虑是不是刷错了别的基座的补丁 ✗

**这不是一次性现象** —— 只要补丁还在，每次开机都会经历这段等待 ✓
（可以理解为：GZ 拿不到 EL2，启动链每次都要等那个握手超时）。

### 怎么区分「正常的慢」和「真的坏」

| 现象 | 正常慢 ✓ | 真失败 ✗ |
|---|---|---|
| 屏幕 | 停在**第二屏**（logo2）转圈 | 停在**第一屏**，或黑屏后**自动进 fastboot** |
| adb | **设备可见**（`adb devices` 能看到序列号） | 看不到，或本身就是 fastboot 模式 |
| 时间 | 1~3 分钟后自己进系统 | 5 分钟以上无变化 |
| 处理 | **等** ✓ | 刷回备份（见 [tee/README.md](../tee/README.md) 的回退节）|

> 💡 教训：本项目曾因为没等够，把这当成真卡二白白恢复了一次。
> **刷完补丁之后，每次开机都请先给它 3 分钟。**

### 🔑 为什么「停在第二屏」是个关键判据

ATF 的签名校验发生在 **`bl2_ext` 阶段**（preloader 阶段，**远早于内核启动**）：

```
ATF 校验（[SBC] image atf header auth pass）
    ↓ 早于内核
内核启动 → 第一屏 → 第二屏
```

**所以：**

```
看不到第二屏（停第一屏 / 直接进 fastboot）
    ⇒ 可能是「没被接受」——签名/基座/分区写坏

能看到第二屏（logo2）
    ⇒ ATF 一定已经被接受了 ✓
    ⇒ 问题一定不在签名 / 不在基座，而在后面的启动过程
      （也就是延迟，或者 TEE 初始化）
```

> 这个判据是**免费的**：不用看日志、不用连电脑，**看屏幕就能分** ✓
> 这也是为什么本项目后来能确认「那次卡二其实只是没等够」✓

---

## 13. 🔴 宿主的 `bcdboot` 写不了引导：它要 `EFI_EX`，而老镜像里没有

**症状**
在**开了 Secure Boot 且装了 2023 PCA** 的 Windows 主机上，给 Win10 LTSC 2021 这类
**较老的 ARM64 镜像**写引导，`bcdboot` 直接失败：

```
BFSVC: Using Ex bins because SB is on, BFSVC_USE_EX_BINS is set, and 2023 PCA is in DB.
BFSVC: Using source OS version a00004a610001
BFSVC: Unable to open file G:\Windows\boot\EFI_EX\bootmgfw_EX.efi for read because the file or path does not exist
BFSVC Error: Failed to validate boot manager checksum (G:\Windows\boot\EFI_EX\bootmgfw_EX.efi)! Error code = 0xc1
BFSVC Error: ServicingBootFiles failed. Error = 0xc1
Failure when attempting to copy boot files.
```

**原因**
宿主 `bcdboot` 根据**宿主自己的** Secure Boot 状态决定使用「Ex bins」
（带 2023 PCA 的引导管理器 ✓）。而 `EFI_EX\` 目录是较新 Windows 才有的 ✗ ——
**Win10 LTSC 2021 镜像里根本不存在** ✗ → 拷贝失败。

> 这与 [docs/03](03-windows-vm.md) 里「x64 的 bcdboot 能给 ARM64 写引导」并不矛盾 ——
> 那条在**宿主没开 SB / 没有 2023 PCA** 时成立 ✓，这里是被宿主策略堵住了 ✗。

**解决：绕开 bcdboot，手工布置（完全可控）**

```powershell
# 管理员 PowerShell； $E = ESP 盘符（如 V:）， $W = Windows 分区盘符（如 G:）
New-Item -ItemType Directory -Force -Path "$E\EFI\Boot"           | Out-Null
New-Item -ItemType Directory -Force -Path "$E\EFI\Microsoft\Boot" | Out-Null

# 直接拷镜像自带的 ARM64 引导管理器
Copy-Item "$W\Windows\boot\EFI\bootmgfw.efi" "$E\EFI\Microsoft\Boot\bootmgfw.efi" -Force
Copy-Item "$W\Windows\boot\EFI\bootmgfw.efi" "$E\EFI\Boot\bootaa64.efi" -Force   # 兜底路径
Copy-Item "$W\Windows\boot\EFI\boot.stl"     "$E\EFI\Microsoft\Boot\boot.stl" -Force

# 手工建 BCD（createstore 后先建 osloader，再建 bootmgr）
$BCD = "$E\EFI\Microsoft\Boot\BCD"
Remove-Item $BCD -Force -ErrorAction SilentlyContinue
bcdedit /createstore $BCD
$g = (bcdedit /store $BCD /create /d "Windows 10 ARM64" /application osloader | Select-String '\{[0-9a-fA-F-]+\}').Matches[0].Value
bcdedit /store $BCD /set "$g" device     "partition=$W"
bcdedit /store $BCD /set "$g" path       "\Windows\system32\winload.efi"
bcdedit /store $BCD /set "$g" osdevice   "partition=$W"
bcdedit /store $BCD /set "$g" systemroot "\Windows"
bcdedit /store $BCD /create "{bootmgr}" /d "Windows Boot Manager"      # ← 不要加 /application！
bcdedit /store $BCD /set "{bootmgr}" device       "partition=$E"
bcdedit /store $BCD /set "{bootmgr}" path         "\EFI\Microsoft\Boot\bootmgfw.efi"
bcdedit /store $BCD /set "{bootmgr}" default      "$g"
bcdedit /store $BCD /set "{bootmgr}" displayorder "$g"
bcdedit /store $BCD /set "{bootmgr}" timeout      5
```

**三个坑中坑**：

1. **`/application bootmgr` 是错语法** ✗ —— 合法类型只有 `osloader` / `resume` / `startup` /
   `bootsector` / `fwbootmgr` 等 ✗。建引导管理器必须写 **`/create {bootmgr} /d "..."`** ✓
   （报错为 `The application type switch specified is not valid.`）
2. **写 ESP 上的 BCD 需要管理员** ✗ —— 非提权会报 `The boot configuration data store could not be opened. Access is denied.`
3. **拷引导文件前先确认架构** ✓ —— `bootmgfw.efi` 的 PE machine 必须是 **`0xAA64`**；
   千万别从宿主的 `C:\Windows\boot\EFI\` 拿（那是 x64 的 ✗）

**副产品**：镜像自带的 `boot\EFI\` 里还有 `zh-CN\*.mui`（启动菜单的中文界面）、
`memtest.efi`、`winsipolicy.p7b` —— 一并拷过去更完整 ✓。

---

## 14. 🔴 **开 KVM 会让硬件视频解码失效 —— 不要把开 KVM 的机器当主力机**

**症状**（实机实测，刷前/刷后/刷回 三次对比）

| 功能 | 刷之前 | 刷之后 | 刷回原厂后 |
|---|---|---|---|
| Moonlight 串流 | ✅ 正常 | ❌ **无响应** | ✅ 恢复 |
| UU 远程 | ✅ 正常 | ❌ **无法使用** | ✅ 恢复 |
| QQ 聊天图片 | ✅ 正常 | ❌ **不显示** | ✅ 恢复 |
| 内部存储 | ✅ 正常 | ⚠️ 开机时可能不挂载 | ✅ 恢复 |
| 应用数据 | ✅ | ⚠️ 可能导致损坏（QQ 报“聊天记录异常”）| —— |

**刷回原厂后全部恢复正常** ✓ —— 所以故障确实由补丁引起 ✓

**原因**

```
MTK 的硬件编解码（mtk-vcodec）依赖：
   · mtk_sec_heap        安全内存
   · gz_tz_system        GZ 提供的 TEE 服务
   · gz_trusty_mod
   · cmdq_sec_drv        安全命令队列

NoGZ 补丁让 GZ 拿不到 EL2  →  这条依赖链断裂 ✗
   →  硬件解码器初始化失败 ✗
   →  Moonlight / UU远程 / QQ 图片 / 缩略图生成  全部受影响 ✗
```

### 精确机理（为什么偏偏是硬件编解码坏掉）

```
MTK 的 venc / vdec 在 open() 的时候：
   → 通过 IPI 向 VCP 协处理器查询【支持的帧尺寸】
   → 而 VCP 的 READY 握手依赖 EL2 / 安全世界那条链

把 Android 内核抬到 EL2（这是 KVM 的必需条件）之后：
   → 握手断裂 ✗
   → 尺寸表为空 ✗
   → Codec2 的 configure() 返回 EINVAL ✗
   → 框架 / 应用【不会自动回退到软件编码】✗
   → 结果：screenrecord 录出来是 0 字节、
           Moonlight / UU远程 / QQ 图片 全部失效 ✗
```

**这解释了四个现象**：

| 现象 | 解释 |
|---|---|
| 为什么坏的偏偏是**硬件**编解码 | 软件编解码不经过 VCP，所以不受影响 ✓ |
| 为什么故障卡在 **configure** 阶段 | 尺寸表查询就在这一步 ✗ |
| 为什么应用**不会优雅降级** | 拿到 `EINVAL` 就直接放弃了，不会改走软编 ✗ |
| 为什么有 `/dev/vdec-fmt` 这个节点 | 那就是那张帧尺寸表 ✓ |

> 🔑 **所以：只要 KVM 在，硬件编解码就不可用。**
> **这是 tee 补丁的固有代价，无法规避** ✗ —— 不是配置问题，也不是基座问题 ✓

> ⚠️ **关键：这与“基座匹不匹配”无关** ✗
> 同基座补丁（针对本机固件构建的那个）**一样会出现** ✓
> 这是 **NoGZ 把 GZ 干掉** 这个行为本身的固有代价 ✓

**为什么之前没发现**

早期做的 A/B 对照只测了：
KeyMint 硬件密钥、Gatekeeper、Widevine 认证、指纹、Secure Element
—— **全部正常** ✓ —— 于是得出了“不影响日用”的结论 ✗

**但漏测了【硬件视频解码】** ✗ —— 而它才是真正会挂的那一块 ✓

**怎么用才对**

| | |
|---|---|
| ❌ **不要** | 把开 KVM 的机器当日常主力机 |
| ✅ **适合** | 二奶机 / 实验机 / 专门跑虚拟机的机器 |
| ✅ **或者** | 接受“硬件视频解码不可用”这个代价 |
| ✅ **想要两全** | 走 [主线 Linux](06-mainline.md) 路线（另一套取舍）|

**回退**：把备份的 `tee_a` 刷回去 + 重启 → 全部功能恢复 ✓

---

## 附：几个"看起来像坑其实不是"的事

| 现象 | 真相 |
|---|---|
| `warning: nic virtio-net-pci.0 has no peer` | 网卡没挂后端（少了 `-netdev user,id=n0`）。只是警告，**但网络是不通的** |
| AAVMF 启动时先卡几十秒 | 内置默认引导项 `Boot0002 "UEFI Misc Device"` 会先超时，属正常 |
| 首次开机画面短暂变黑 | Windows 在重启/切换显示模式。**重连 VNC 即可**，进度不会丢（写在盘上） |
| `Trusted root check: skipped` | 离线验签跳过信任根比对，**只能实机启动才算**（不是失败） |
| `/dev/kvm` 报 `Invalid argument` | 这是**正常**的！说明 `open()` 已经过了 SELinux（Enforcing），只是没传参数 |
| QEMU 报找不到 `libbinder_ndk.so` | DroidVM 的 QEMU 需要 `export LD_LIBRARY_PATH=/system/lib64` |

---

## 排错顺序建议

遇到"启动不了"，按这个顺序查：

```
1. adb shell su -c 'ls -l /dev/kvm'                    ← KVM 在不在（前置条件）
2. adb shell su -c 'cat /data/local/tmp/boot.out'      ← 启动脚本的输出（含端口核对）
3. adb shell su -c 'cat /data/local/tmp/win-qemu.log'  ← QEMU 自己的报错
4. adb shell su -c 'cat /data/local/tmp/win-serial.log'← 固件串口输出（BdsDxe 之类）
5. python scripts/vncgrab.py                           ← 抓一帧看画面到哪一步
6. adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
   adb pull /data/local/tmp/e.img && grep -a "\[SBC\] image" e.img   ← ATF 校验链
```
