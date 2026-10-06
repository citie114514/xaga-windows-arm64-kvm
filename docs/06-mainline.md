# 进阶路线：主线 Linux + KDE

[**中文**](06-mainline.md) | [English](en/06-mainline.md) | [日本語](ja/06-mainline.md) | [Русский](ru/06-mainline.md)

> 如果你不满足于在 Android 里跑虚拟机，而是想把手机直接变成一台 Linux 电脑
> —— 和 [kde-yyds](https://space.bilibili.com/2008726064) 那个视频一样。

⚠️ **本路线我们只做到"验证 KVM 可用"这一步**（在 Android 内核上），
**没有实际把主线装起来**。下面的内容基于项目仓库和公开视频整理，
具体步骤请以上游项目为准。

---

## 一、同机主线的现状（相当完整了）

项目：**[`MT6895-Mainline`](https://github.com/MT6895-Mainline)**
分支：**`7.2-mt6895-xiaomi-xaga`**

| 子系统 | 状态 |
|---|---|
| 内核 | **Linux 7.2**（主线） |
| **GPU** | **Mali-G610 — Panthor / PanVK** ✓ |
| **桌面** | **KDE Plasma，完整 GPU 加速** ✓ |
| 显示 | 华星 / 天马屏**都支持**，**144Hz 高刷** |
| 音频 | 扬声器 ✓ 3.5mm 耳机 ✓ |
| 无线 | WiFi ✓ 蓝牙 ✓ |
| 其它 | 指纹 ✓ 自动亮度/自动旋转 ✓ 相机 **RAW** ✓ PPS 协议快充 ✓ |
| 系统 | **Arch Linux ARM 可启动** ✓ |

**从视频标题能看到的时间线**（B 站 `kde-yyds`）：

| 时间 | 里程碑 |
|---|---|
| 08-10 | 启动 Arch Linux ARM。当时**只驱动了 simplefb / UFS / USB** |
| 08-19 | Mali-G610 起来（Panfrost） |
| 08-21 | KDE Plasma + 完整 GPU 加速 |
| 09-01 | Linux 7.2 Panthor/PanVK + 卡顿修复 |
| 09 月 | 指纹 / 自动亮度旋转 / PPS 快充 / 相机 RAW / 蓝牙 / 144Hz / 扬声器 / 耳机 / WiFi |

---

## 二、启动方式（和本项目方案一致）

作者在视频简介里说明了他们怎么做的 —— 值得注意的几点：

> 设备树靠塞在内核里内核自己替换，因为**改 dtbo 之后 LK 会炸**。
> 早期调试靠某一块保留的内存（bit 会随机翻转但重启到安卓还能读取）。
> 后来 ufs 驱动起来了，就把 kmsg 写到**空槽位的 `vendor_boot_b` 分区**并刷回安卓读。
> 后来 simplefb 起来了就能直接看屏幕了。usb 起来之后手搓 init，
> 让 usb 暴露成一个 **serial console**，电脑上直接连 `/dev/ttyACM0`。
> 最后把 rootfs 用 **fastboot 刷进 `userdata`** 挂载并启动 `/sbin/init`。

**关键结论**：

| 项 | 做法 |
|---|---|
| **Bootloader** | **保留原厂 LK**，不移植 U-Boot（LK 也能加载主线内核） |
| **设备树** | **dtb 塞进内核**，内核自己替换（不能改 dtbo，否则 LK 炸） |
| **内核** | → `boot` 分区 |
| **rootfs** | → `userdata` 分区（fastboot 刷入） |
| **调试** | 早期靠保留内存写 kmsg → 后来写 `vendor_boot_b` 空槽位 → simplefb → USB 串口 |
| **参考** | mt6878 mainline |

**这和我们在 Android 上做 KVM 的思路是同一套**：保留 LK、不动 dtbo、只换能换的部分。

---

## 三、⚠️ 必须知道的坑：7.2 Panthor 的 GEM Shrinker

**这条和"跑虚拟机"直接相关，一定要看：**

> Linux 7.2 的 panthor 引入了 **GEM Shrinker**，在可用内存较低时可以进行内存回收。
> **但当内存压力过大时，回收对 panthor 带来的开销很大，就出现了雷霆大卡顿。**
> 在 7.2 的 panthor，gem shrinker 是新引入的第一个版本，有些回归也正常，
> **要是遇到了那就先关掉吧。**

修复 commit：
[`MT6895-Mainline/linux@4fadce8d`](https://github.com/MT6895-Mainline/linux/commit/4fadce8d6bbce016a8965ad93a5285c565401c1d)

**为什么这对本项目的读者重要**：**跑虚拟机正是"内存压力极大"的场景**
（KDE + QEMU + Windows 几个 GB + 磁盘缓存）。
所以如果你在主线 Linux 上跑虚拟机觉得莫名卡顿，**先怀疑这个**。

---

## 四、为什么主线上会比 Android 上流畅

从视频和项目信息能看出几个原因：

1. **KDE 合成器有完整 GPU 加速**（Panthor/PanVK）—— Android 那套图形栈在虚拟机场景反而绕
2. **没有 Android 的后台/温控/内存管理干扰**
3. **QEMU 是发行版正常构建**，不用像 DroidVM 那样为 Android 做各种适配
   （也就没有本项目踩的那些 VNC 端口错位、`vms.json` 被重写、native exporter 限制之类的问题）
4. 显示路径可以在**本机**（原生窗口 / localhost VNC），延迟远低于"adb 转发到 PC 再过 VNC"

---

## 五、两条路怎么选

| | **Android（本项目主线）** | **主线 Linux（本篇）** |
|---|---|---|
| 改造量 | 只需刷 `tee_a` | 要装整个系统 |
| 风险 | 只动一个分区，可回滚 | 要重分区刷 rootfs |
| 日常主力 | ✅ 还能打电话刷微信 | ⚠️ 取决于移植完整度 |
| 虚拟机体验 | 能用，受 VNC 路径限制 | **更顺**（GPU 加速 + 本机显示） |
| 适合谁 | **想留着 Android 的人** | 想把这台机器当 Linux 电脑用的人 |

**建议**：先按本项目在 Android 上把 KVM 开起来（**这一步在两个路线上是共用的** ——
主线上也需要同样的 ATF 原理，只不过主线的 ATF 由发行版/项目提供）。
玩得顺了，再考虑上主线。

---

## 六、进一步了解

- **项目仓库**：[`MT6895-Mainline`](https://github.com/MT6895-Mainline)
  - 内核分支：`7.2-mt6895-xiaomi-xaga`
  - ATF NoGZ 补丁工具：[`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)
- **B 站**：[kde-yyds](https://space.bilibili.com/2008726064) —— 这台机器主线进展的持续记录
- **参考机型**：mt6878 mainline

> 本项目作者也是从那个视频得到灵感，才做出这个 Android 版本的。
> 主线那边的进度远超前于我们，**想深入请直接看上游**。
