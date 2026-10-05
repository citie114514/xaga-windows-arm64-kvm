# 使用方法

本篇讲：**怎么启动**、**每个 QEMU 参数是什么意思**、**怎么看画面**、**网络怎么通**、**怎么调性能**。

---

## 一、启动

```bash
# 推到手机后执行（需要 root）
adb shell su -c /data/local/tmp/boot-win.sh
```

脚本固定在 **VNC 端口 5900**，并且会做这些事：

```
[1] 清理旧实例（避免端口被占 → QEMU 静默挪到 5901）
[2] 等待 5900 真正空闲（最多 30 秒，超时就退出，不将就）
[3] 启动 QEMU（绑核 + 全套优化参数）
[4] 核对实际监听端口 == 5900（不等于就报错退出）
```

**为什么要核对端口**：QEMU 的 `-vnc host:N` 里 `N` 是 **display 号**，端口 = `5900 + N`。
如果 5900 被占着，**QEMU 不会报错，而是静默把 display 号 +1** → 变成 5901 ✗
所以脚本必须主动等待 + 核对。

停止：

```bash
adb shell su -c /data/local/tmp/stop-vm.sh     # 用短进程名匹配，避免 pkill -f 自杀
```

---

## 二、看画面（VNC）

```bash
adb forward tcp:5900 tcp:5900
# 任意 VNC 客户端连 127.0.0.1:5900（无密码）
```

命令行抓帧（不想开客户端时，用来截图/排错）：

```bash
python scripts/vncgrab.py        # 存成 vnc-0.png / vnc-1.png
python scripts/vncprobe.py       # 测 VNC 实际吞吐
python scripts/vncinput.py       # 发一次按键，看客机 UI 是否响应
```

**想要更流畅**：`boot-win.sh` 里已经带了 `lossy=on`（JPEG 有损压缩），
实测每帧数据量从 **3.00 MB 降到 0.36 MB（1/8.3）**。这是最大的一刀。

---

## 三、QEMU 参数逐条说明

```bash
Q=/data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64
FW=/data/data/cn.classfun.droidvm/usr/share/droidvm/aavmf-QEMU_EFI.fd
DISK=/data/media/0/DroidVM/win.vhdx

export LD_LIBRARY_PATH=/system/lib64        # ← 必须！否则链接器命名空间拿不到系统库

taskset f0 "$Q" \                           # ← 必须！绑到 A78 簇，避开 big.LITTLE 竞态
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

| 参数 | 作用 / 注意 |
|---|---|
| `LD_LIBRARY_PATH=/system/lib64` | DroidVM 的 QEMU 需要，否则找不到系统库 |
| `taskset f0` | 绑到 CPU 4-7（A78 簇）。**不绑会随机失败**（见 [01-enable-kvm.md](01-enable-kvm.md) 附录） |
| `-accel kvm` | 硬件加速（这就是刷 tee 的目的）。用了 `tcg` 会慢到没法用 |
| `-machine virt` | ARM 通用虚拟平台 |
| `-cpu host` | 透传宿主 CPU 特性。**必须配合 taskset** |
| `-smp 4` | 4 个 vCPU。手机 4×A78，**再多就只能上 A55，会拖慢** |
| `-m 4096M` | 4 GB 内存。手机上建议不超过 4G |
| `-bios "$FW"` | **必须是标准 AAVMF** —— DroidVM 自带的魔改版在 QEMU 上会自旋卡死 |
| `-drive ... format=vhdx` | **QEMU 能直接读写 VHDX** ✓ 不用转换格式 |
| `cache=writeback` | 折中。想更快可以 `cache=unsafe`（但有掉电损坏风险） |
| `aio=threads` | 异步 IO 用线程池（比 native 在 FUSE 上更稳） |
| `if=none` + `-device` | 现代写法：先定义后端，再挂到设备上 |
| `disable-legacy=on,disable-modern=off` | 只用 virtio 1.0（modern）。Windows 驱动需要 modern |
| `bootindex=1` | 启动优先级（AAVMF 不一定认，但写上无害） |
| `-netdev user,id=n0` | **用户态 NAT（slirp）**，VM 上网用它 |
| `-device virtio-net-pci` | 网卡。驱动是 `NetKVM`（已注入）|
| `-device virtio-balloon-pci` | 气球内存。装了 guest 里的 `blnsvr` 后能把闲置内存还给 Android |
| `-device qemu-xhci,id=xhci` | USB 控制器。**注意总线名是 `xhci.0`，不是 `xhci`** |
| `-device usb-tablet` | 绝对坐标鼠标（**不加 `bus=` 让它自动挂**，写 `bus=usb` 会报错） |
| `-vnc 127.0.0.1:0,lossy=on` | display 0 → 端口 **5900**；`lossy=on` 开 JPEG 压缩 |
| `-display none -nodefaults` | 不要本地显示、不要默认设备（最小化，省资源） |

### 可选：挂驱动光盘

```bash
if [ -f /data/local/tmp/virtio-win.iso ]; then
  set -- "$@" -drive file=/data/local/tmp/virtio-win.iso,if=none,id=cd0,media=cdrom,readonly=on \
              -device usb-storage,drive=cd0,removable=on
fi
```

> ✅ `virtio-win.iso` 是**纯数据盘**（没有 El Torito、没有 EFI 引导），挂上去**安全**，不会抢引导。
> ❌ **不要挂 Windows 安装 ISO** —— 那个是可引导的，会跟你的系统盘抢引导。

---

## 四、网络

启动脚本里已经配好了 **QEMU 用户态 NAT（slirp）**：

| 项 | 值 |
|---|---|
| VM 的 IP | `10.0.2.15` |
| 网关 | `10.0.2.2` |
| DNS | `10.0.2.3` |
| 出网 | ✅ 能上公网（出站） |
| 入站 | ❌ 外面连不进来（NAT 特性） |

驱动是 `NetKVM`（已注入），**Windows 里免驱直接就能用**。

**验证网络真的通了**（在 PC 上看 QEMU 进程的出网连接）：

```bash
adb shell su -c 'ss -tnp | grep qemu | grep -v 127.0.0.1'
# ESTAB  192.168.31.75:44394  ->  204.79.197.235:443      ← Microsoft
```

VM 里的验证：打开 Edge 能上网就对了。

> **提示**：进桌面前如果时间显示很离谱（比如 2768 年），**有网之后 Windows NTP 会自己纠正**。

---

## 五、性能调优

### 实测数据（避免瞎猜）

| 项 | 实测值 | 结论 |
|---|---|---|
| **VNC `lossy=on`** | 每帧 **3.00 MB → 0.36 MB（1/8.3）** | ✅ 最大的一刀，必开 |
| **adb 转发隧道吞吐** | **276 MB/s** | ❌ **不是瓶颈**，别在网络上折腾 |
| 分辨率 1080p vs 720p | 像素差 2.25 倍 | 影响渲染和编码开销 |
| CPU 绑核 | 成功率 2/5 → **3/3** | ✅ 必做 |

### 可调的旋钮

| 想要 | 怎么做 |
|---|---|
| **更流畅** | 分辨率降到 1280×720（`xres=1280,yres=720`）；Windows 里关视觉特效 |
| **更省内存** | 装 guest 侧的 `blnsvr.exe`，让气球把闲置内存还给 Android |
| **磁盘更快** | `cache=unsafe`（⚠️ 掉电可能损坏文件系统） |
| **CPU 更强** | `-smp` **别超过 4** —— 再多就只能调度到 A55 上，反而慢 |
| **多给内存** | `-m` 可以到 6G，但手机本身也要用，容易触发 OOM |

### 流畅度的真正关键：显示路径

```
本机原生显示（手机上直接看）  → 最流畅
localhost VNC（本机回环）      → 很流畅
adb 转发 + PC 上的 VNC 客户端  → 有延迟感（就是本项目默认这种方式）
```

**为什么会卡**：QEMU 的 VNC 编码跑在主线程，而 `taskset f0` 把所有线程都绑在 A78 簇上，
VNC 线程要和 4 个 vCPU **抢同样 4 个核**。

**可尝试的思路**（未在本项目充分验证，欢迎反馈）：

- 给 QEMU 的辅助线程留一个核：`-smp 3`
- `-cpu cortex-a78`（固定 CPU 型号，避免 host 透传的 big.LITTLE 竞态）+ 去掉 `taskset`，
  让 QEMU 线程摊到 8 个核上

**Android 上还想更流畅**：用 DroidVM 应用的 `native` 显示
（它把画面直接画在手机屏幕上，完全不走网络 —— 就是 [kde-yyds](https://space.bilibili.com/2008726064)
视频里那种"本机看着很顺"的效果）。

---

## 六、日常维护

### 备份 / 快照

`win.vhdx` 是整个 Windows 系统，**一定要有备份**。

```bash
# 在手机上做压缩快照（VM 必须停着，否则快照是撕裂的）
adb shell su -c 'export LD_LIBRARY_PATH=/system/lib64; \
  /data/data/cn.classfun.droidvm/usr/bin/qemu-img convert -c -o compression_type=zstd \
  /data/media/0/DroidVM/win.vhdx /data/local/tmp/win-snapshot.qcow2'
```

- **`-c` + zstd**：约 40 分钟（CPU 受限）
- **不加 `-c`**：约 90 秒，但文件大 2 GB 左右
- 产出可直接当 qcow2 盘用（`format=qcow2`），也可以 `qemu-img convert` 转回 vhdx

### 空间

系统盘实时占用会长到 **~23 GB**（100 GiB 虚拟大小的动态盘）。
加备份的话，手机 `/data` 至少留 **40 GB** 比较安心。

```bash
adb shell su -c 'df -h /data | tail -1'
```

---

## 七、下一步

- **踩坑排查** → [05-gotchas.md](05-gotchas.md)
- **想上主线 Linux + KDE** → [06-mainline.md](06-mainline.md)
