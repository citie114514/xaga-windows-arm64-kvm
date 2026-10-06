# 成品 tee 镜像

这里是**已经构建并签名好**的 NoGZ 补丁 `tee` 镜像，可直接刷入对应固件的设备。

---

# ⭐ 实机验证成功的示例

## [`tee_nogz_rk_5M.img`](tee_nogz_rk_5M.img) —— **已在真机上跑通 KVM**

```
sha256   f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
base     f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
size     5 242 880 字节（正好占满 tee 分区）
cert     LEGACY
```

**实测记录**（同一台设备，跨两次系统大版本升级）

| 时间点 | 系统 | `tee_a` | `lk_a` | 结果 |
|---|---|---|---|---|
| 首次刷入 | HyperOS（Android 15） | `f8f286f1…` → 刷为补丁 | `8cbaa2e8…` | ✅ `/dev/kvm` 出现，2-vCPU Linux guest 完整启动 |
| 升级后 | **Android 16 / HyperOS 3.3** | 补丁仍在 | `a17d87c6…`（**被换掉了**） | ✅ **依然正常**，`/dev/kvm` 仍在 |

**这次升级意外给出了一个关键结论**：

> **`lk` 被换掉完全不影响补丁；真正决定兼容性的只有 `tee` 基座。**

**实测证据（原始输出）**

```console
$ adb shell su -c 'for p in tee_a tee_b; do printf "%s " $p; dd if=/dev/block/by-name/$p bs=4096 2>/dev/null | sha256sum | cut -c1-16; done'
tee_a f1511dcad9820397      ← 本补丁
tee_b f8f286f138e758a5      ← 原厂，未改动

$ adb shell su -c 'ls -l /dev/kvm'
crw-rw-rw- 1 root root 10, 232 2026-10-06 21:52 /dev/kvm      ← ✅

$ adb shell "grep -i kvm /proc/misc"
232 kvm

$ adb shell su -c 'dmesg | grep -i sbc'
[SBC] image atf header auth pass
sbc_en = 1
```

**实际跑过的东西**：`crosvm`（microdroid）拉起 guest —— 通过；`qemu-system-aarch64 -accel kvm`
拉起 2-vCPU Linux guest —— 通过；后续还在同一台设备上把 **Windows 11 ARM64 完整装起来并进了桌面**。

> ⚠️ 注意：**本补丁只对 `tee_a` = `f8f286f1…` 的设备有效**。
> 刷之前**务必先跑下面的自检**。

---

## 👉 刷之前先自检

仓库里附带了一个自检脚本 [`verify.sh`](verify.sh)，直接帮你比对：

```bash
bash tee/verify.sh                 # 自动检测已连接设备
bash tee/verify.sh <serial>        # 指定设备
```

它会打印你设备的 `tee_a` / `tee_b`，并告诉你**能不能用哪个成品补丁**。

手动版（只比一个哈希）：

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

| 你设备的 `tee_a` sha256 | 可以刷哪个 |
|---|---|
| `f8f286f1…`（原厂基座） | `tee_nogz_rk_5M.img` ✓ |
| `a91f5ded…` | `tee_nogz_shuilanA15_5M.img` ✓ |
| 其它 | ✗ **不要刷**，按 [docs/02](../docs/02-build-and-sign.md) 自己构建 |

---

## ⚠️ 核心规律：补丁**绑死的是 `tee` 基座**

NoGZ 补丁改的是 `tee` 分区里 **`atf` 成员的启动交接逻辑**，所以它只对
**「构建它时用的那个 `tee` 基座」**有效。

**已实测确认的边界**（哪些变化不影响、哪些影响）：

| 分区/条件 | 变了会失效吗 | 怎么确认 |
|---|---|---|
| **`tee`** | ✅ **会失效** | 比 `tee_a` 哈希 |
| `lk` | ❌ 不会 | 实测被换掉后补丁照常工作 |
| `gz` / `dtbo` / `boot` / `system` | ❌ 不会 | 跨 Android 15 → 16 大版本升级仍正常 |
| 跨设备（同型号） | ⚠️ **看 `tee_b`** | `tee_b` 相同 = 同批固件 = 基座相同 |

**最可靠的自检方法 —— 看没被动过的那个槽 `tee_b`**：

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum'
```

- `tee_b` 没变过（= 原厂）→ 说明 `tee` 基座还是原厂那批 → 可用原厂基座的补丁 ✓
- `tee_b` 也变了 → 基座已换 → 必须重新构建 ✗

> **ROM / OTA 更新会偷偷改 `tee_a`** ⚠️ —— 本案例中有一个设备**刷 ROM 后 `tee_a` 从
> `f8f286f1…` 被换成了 `a91f5ded…`**（即使 ROM 包里根本没带 `tee` 镜像，是首启固件更新
> 或 `super.img` 干的）。
> **所以：刷 ROM 前备份 `tee_a`，刷完后重新比哈希，变了就重做补丁。**

---

# 成品清单

## 1. ⭐ `tee_nogz_rk_5M.img` —— **实机验证成功**（推荐参照）

| 项 | 值 |
|---|---|
| 适配基座（`tee_a`） | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |
| 构建时配套的 `lk` | `8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3` |
| cert mode | `LEGACY` |
| 大小 | 5 242 880 字节（= tee 分区大小） |
| sha256 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| 离线自检 | ✅ 14/14 回归全通过 |
| 验签 | ✅ 2 × `Result: VALID` |
| **实机验证** | ✅ **通过**（跨 Android 15 → 16 两次确认） |

## 2. ⏳ `tee_nogz_shuilanA15_5M.img` —— 离线全过，**未实机验证**

| 项 | 值 |
|---|---|
| 适配基座（`tee_a`） | `a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7` |
| 构建时配套的 `lk` | `a17d87c630f23b6720cfe311b2a06d196503a4eb00242bc6413eeeb0b836e1cb` |
| cert mode | `LEGACY` |
| 大小 | 5 242 880 字节 |
| sha256 | `17ec849749febda62445f922ec3ee8b65a3092f0ea2c641e98eb732fbe60ee59` |
| 离线自检 | ✅ 14/14 回归全通过 |
| 验签 | ✅ 2 × `Result: VALID` |
| **实机验证** | ❌ **尚未验证**（`device_tested: false`） |

**它是怎么来的**：某个设备**刷 ROM 之后 `tee_a` 被更新成了 `a91f5ded…`**
（原厂未改动的 `tee_b` 仍是 `f8f286f1…`）。于是用**这台设备自己的 `tee_a`**
重新逆向偏移、重新构建、重新签名 —— 也就是**同一台设备换基座后该怎么自救**的完整范例。

> 它是**跟随第一台设备的实战**而产出的、针对第二个基座的补丁。
> 目前**离线验证（14/14 + 验签）全部通过，但还没有刷到真机上跑过**。
> 如果你手上正好是这个基座，欢迎实测后在 issue 里反馈结果。

---

## 两个补丁对照

| | `tee_nogz_rk_5M.img` | `tee_nogz_shuilanA15_5M.img` |
|---|---|---|
| 基座 | `f8f286f1…`（原厂） | `a91f5ded…`（ROM 更新后） |
| 离线回归 | 14/14 ✅ | 14/14 ✅ |
| 验签 | VALID ✅ | VALID ✅ |
| 实机 | ✅ **成功** | ❌ 未验证 |
| 对应 profile | [`profiles/xagapro.json`](../profiles/xagapro.json) | [`profiles/shuilanA15.json`](../profiles/shuilanA15.json) |

**⚠️ 千万不要混刷** —— 实测把「原厂基座」的补丁刷进「已更新基座」的设备，
**会卡在开机第二屏（卡二）**，必须 fastboot 刷回备份才能救活。

---

# 刷入方法

## 0) 先备份（必须，不可跳过）

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_a_backup.img bs=4096'
adb shell su -c 'dd if=/dev/block/by-name/tee_b of=/data/local/tmp/tee_b_backup.img bs=4096'
adb pull /data/local/tmp/tee_a_backup.img
adb pull /data/local/tmp/tee_b_backup.img

# 记下哈希，回退时对照
sha256sum tee_a_backup.img tee_b_backup.img
```

## 1) 刷入

```bash
adb push tee_nogz_rk_5M.img /data/local/tmp/tee_patched.img

# 手机上先校验推过去的文件没坏（重要！）
adb shell su -c 'sha256sum /data/local/tmp/tee_patched.img'
# 必须等于成品 sha256

adb shell su -c 'dd if=/data/local/tmp/tee_patched.img of=/dev/block/by-name/tee_a bs=4096 && sync'
```

## 2) 回读校验（必须）

```bash
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
# 必须等于成品 sha256
```

## 3) 重启 + 验证 KVM

```bash
adb reboot
# 等开机完成
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'grep -i kvm /proc/misc'
adb shell su -c 'dmesg | grep -i -E "sbc|kvm" | tail -20'
```

预期看到：

```
crw-rw-rw- 1 root root 10, 232 … /dev/kvm
232 kvm
[SBC] image atf header auth pass
```

## 🔙 回退（卡二时怎么救）

**症状**：刷完重启后卡在开机第二屏（logo 转圈后黑屏/重启循环），但设备**还能进 fastboot**
（音量下 + 电源）。

```bash
# 进 fastboot 模式后
fastboot devices
fastboot flash tee_a tee_a_backup.img
fastboot reboot
```

**这条路已实测有效** —— 本项目的第二个基座就是这么从「卡二」救回来的，
**全程只动 `tee_a` 一个分区**，其它数据（用户数据 / 系统）完好无损。

> 兜底二：设备还有 **B 槽**，`tee_b` 从未改动，是天然的第二个副本。

---

# 关于这些文件

- 这些是**经官方工具链签名**的完整 `tee` 分区镜像（含 MTK 的 ATF、TEE OS 与证书链）。
- 由 [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) +
  [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) 构建，
  偏移定义见 [`profiles/`](../profiles/)，逆向工具见 [`tools/`](../tools/)。
- upstream `mtk-mod-tee-nogz` 明确声明**不包含固件与预编译镜像**；这里放成品是
  为了**可对照、可复用**，请自行判断是否适合你的场景。
- **刷机有风险**，请只在**你自己有权访问的设备与固件**上使用，并**先备份**。
