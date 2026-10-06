# 成品 tee 镜像

[**中文**](README.md) | [English](README.en.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

这里是**已经构建并签名好**的 NoGZ 补丁 `tee` 镜像，可直接刷入对应固件的设备。

---

# 🛑 试用前必读（两条）

## ① 先把【工程 preloader】刷上 —— 否则你可能没路可退

```
原厂 preloader ⇒ EDL 需要小米售后账号授权 ✗
              ⇒ tee 刷错、起不来时【没有免授权的救援通道】✗

工程 preloader ⇒ usbdl_verify_da 返回值被丢弃 → SLA/DAA 形同虚设
              ⇒ SP Flash / mtkclient 【免账号】可写 ✓
              ⇒ 这才是“刷坏了还能救”的前提 ✓
```

```bash
fastboot flash preloader1 preloader_xaga.bin
fastboot flash preloader2 preloader_xaga.bin
fastboot reboot
```

（by-name 里对应 `preloader_raw_a` / `preloader_raw_b`）

> ⚠️ 工程 preloader **只让写入免授权**，**不会关掉启动时的镜像校验** ✗ ——
> `sbc_en` 仍为 1，ATF 每个启动都在被校验（详见 [../docs/05-gotchas.md](../docs/05-gotchas.md)）

## ② 本项目的 tee 适用于哪些机型

| 代号 | 市场名称 | 本项目适配 |
|---|---|---|
| **`xagapro`** | **Redmi Note 11T Pro+** / **Redmi K50i** | ✅ **本项目实测机**（两个成品都出自这里）|
| `xaga` | **Redmi Note 11T Pro** / **POCO X4 GT** | ⚠️ 固件不同，需要自己的 profile；但**跨基座实测可启动**，可先备份后试 |

两者同为 **MT6895 / Dimensity 8100**，原理完全一致，差别只在固件基座。

---

## 👉 想直接拿成品试？按这个顺序

```
① 确认能刷入工程 preloader（手里有文件、fastboot / SP Flash 能用）
② 刷入并验证能正常开机
③ 备份：tee_a / tee_b / lk_a / lk_b / preloader_raw_a / seccfg
④ 跑 tee/verify.sh 看自己设备该用哪个成品
⑤ 刷入成品 → 重启 → 【给它 3 分钟】（每次开机都会卡第二屏 1~2 分钟，不是变砖）
⑥ 验证：adb shell su -c 'ls -l /dev/kvm'
```

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

## ⚠️ 实测代价：开 KVM 会让【硬件视频解码】失效 —— 不适合当主力机

**这一条很重要，而且推翻了本文档早前的说法** ✗

实测（同一台设备，刷前 / 刷后 / 刷回 三次对比）：

| 功能 | 刷之前 | 刷之后 | 刷回原厂后 |
|---|---|---|---|
| Moonlight 串流 | ✅ 正常 | ❌ **无响应** | ✅ 恢复 |
| UU 远程 | ✅ 正常 | ❌ **无法使用** | ✅ 恢复 |
| QQ 聊天图片 | ✅ 正常 | ❌ **不显示** | ✅ 恢复 |
| 内部存储 | ✅ 正常 | ⚠️ 开机时可能不挂载（部分设备）| ✅ 恢复 |
| 应用数据 | ✅ | ⚠️ 可能导致损坏（QQ 报“聊天记录异常”）| —— |

**刷回原厂后一切正常** ✓（已实测）

### 为什么会这样

```
MTK 的硬件编解码（mtk-vcodec）依赖：
   · mtk_sec_heap      安全内存
   · gz_tz_system       GZ 提供的 TEE 服务
   · gz_trusty_mod
   · cmdq_sec_drv      安全命令队列

NoGZ 补丁让 GZ 拿不到 EL2  →  这条依赖链断裂 ✗
   →  硬件解码器初始化失败 ✗
   →  Moonlight / UU远程 / QQ 图片 / 缩略图生成  全部受影响 ✗
```

**注意：这与“基座匹不匹配”无关** ✗ —— 同基座补丁同样会出现，
因为这是 **NoGZ 把 GZ 干掉** 这个行为本身的代价 ✓

### 所以这个项目的正确用法

| | |
|---|---|
| ❌ **不要** | 把开 KVM 的机器当日常主力机 |
| ✅ **适合** | 二奶机 / 实验机 / 专门跑虚拟机的机器 |
| ✅ **或者** | 接受“硬件视频解码不可用”这个代价 |
| ✅ **想要两全** | 走 [主线 Linux](../docs/06-mainline.md) 路线（另一套取舍）|

> 🛠 **本文档早前写过「刷了不影响日用」—— 那是错的** ✗
> 当时那个 A/B 测试只覆盖了 KeyMint / Gatekeeper / Widevine / 指纹，
> **没有测硬件视频解码** ✗。已更正。

---

## ❓ 那它到底会不会影响应用检测？（KeyMint / DRM / 指纹）

这是另一个问题，答案是 **不影响** ✓：

**原理上为什么不会影响**：补丁只做一件事 —— **不让 GZ 拿到 EL2**。
而应用检测依赖的安全能力**全部跑在 TEE（S-EL1）**，和 EL2 是两套独立的东西：

| 安全能力 | 实际承载 | 刷补丁后 |
|---|---|---|
| **硬件密钥 / KeyMint 证明** | `keymint@1.0-service.beanpod`（厂商 TEE） | ✅ 正常 |
| **Gatekeeper**（锁屏密码校验） | TEE | ✅ 正常 |
| **Widevine / DRM** | `widevine_driver` 挂在 `mtk_sec_heap` 上 | ✅ 正常 |
| **指纹 / 人脸** | TEE | ✅ 正常 |
| **Secure Element**（NFC 支付） | `secure_element@1.2-service-mediatek` | ✅ 正常 |
| **GZ / GenieZone（EL2）** | MediaTek 的 EL2 虚拟化框架 | ⚠️ **失效**（但实测无任何影响）|

### 实测证据

两台设备（**一台未刷 / 一台已刷补丁**）跑完全相同的命令，结果**逐项一致**：

```
① Verified Boot 状态
   ro.boot.verifiedbootstate   orange      ← 两台都是 orange（BL 已解锁）
   ro.boot.flash.locked        0           ← 两台都是 0
   ro.secure / ro.debuggable   1 / 0       ← 完全相同
   ro.build.tags               release-keys

② 关键 HAL 服务（两台完全相同）
   android.hardware.security.keymint.IKeyMintDevice/default               ✓
   android.hardware.security.keymint.IRemotelyProvisionedComponent/default ✓
   android.service.gatekeeper.IGateKeeperService                          ✓
   fingerprint / biometric / auth 服务                                    ✓

③ TEE 是否真的活着（两台完全相同）
   teei_daemon 及 [teei_*] 内核线程均存在            ← Trustonic TEE 在跑
   keymint@1.0-service.beanpod 进程在跑
   android.hardware.secure_element@1.2-service-mediatek 在跑
   widevine_driver 仍持有 mtk_sec_heap 引用           ← DRM 安全内存路径通

④ 端到端硬件密钥测试（keystore_cli_v2，两台完全相同）
   generate --seclevel=tee   →  GenerateKey: success
   get-chars                 →  特征全部落在 "Hardware:" 段，"Software:" 段为空
   sign-verify               →  Sign: 256 bytes.  Verify: OK
```

**怎么客观判断 TEE 真的在干活**（而不是退化成软件实现）：

```bash
# 强制在 TEE 里生成密钥，并看特征归属
adb shell 'keystore_cli_v2 generate --name=t --seclevel=tee'
adb shell 'keystore_cli_v2 get-chars --name=t'      # 全部应在 "Hardware:" 下
adb shell 'keystore_cli_v2 sign-verify --name=t'    # 必须 Verify: OK
adb shell 'keystore_cli_v2 delete --name=t'
```

### 两个重要提醒

1. **`verifiedbootstate = orange`（BL 已解锁）本来就是 Play Integrity 的杀手**，
   跟刷不刷 `tee` **无关**。BL 解锁 + Root 的设备，`MEETS_DEVICE_INTEGRITY` /
   `MEETS_STRONG_INTEGRITY` **本来就不会通过**，银行 App 本来就靠 Root 隐藏手段去绕。
   **刷 `tee` 既不改善也不恶化这个状态** —— 它不碰 BL 锁、不碰 Root、不碰 dm-verity。

2. **`gz_*` 内核模块照样会加载**（`lsmod` 看得到 `gz_main_mod` / `gz_irq_mod` /
   `gz_virtio_mod` 等），但引用计数为 0 —— 它加载了却 **拿不到 EL2，因而是死的**。
   真正干活的是 TEE，不是 GZ。

> **一句话**：补丁动的是 **EL2 的归属**，不动 **TEE**。
> 所有“看你是不是真机 / 有没有被改”的检测，看的是 TEE 和 Verified Boot，两者都没变。

---

## 🔬 刷之前可以做的额外验证：同构比对

实机验证是最终标准，但有一个**不刷机**就能排掉一大类问题的方法。

**思路**：一个可靠的 NoGZ 补丁，相对它基座 `tee_a` 的改动是**模式化**的 ——
改动集中在 profile 定义的那几个补丁点（ATF 的 getter/callback/pc_patch 等），
其余差异只是签名带来的。所以拿一个**已经实机验证可用的补丁**作参照，
比较两者「与各自基座的差异区间」是不是**同构**：

```bash
python tools/verify-patch-diff.py \
  --base-a  backup/tee_a.img \
  --patch-a tee/tee_nogz_rk_5M.img \
  --base-b  backup/tee_a_NEWROM_a91f5de.img \
  --patch-b tee/tee_nogz_shuilanA15_5M.img
```

本项目的实测输出：

```
  区间数量一致 : ✅ 是  (175 vs 175)
  总字节一致   : ✅ 是  (2953488 vs 2953488)
  长度序列一致 : ✅ 是

  ✅ 结论：待验证补丁与参照补丁同构 —— 走的是同一套补丁流程，没有走样。
```

**→ 说明两个补丁用的是同一套构建流程，没有走样。**
这**不能替代实机验证**，但能排掉「构建过程出错 / profile 偏移算错」这一类问题。

---

## ⚠️ 千万别把不同基座的补丁混在一个目录里

实测踩过一次：**因为文件名认错，把别的基座的补丁刷了进去** ✗ ——
当时以为"卡二"了，但后来发现**很可能只是没等够**（刷完补丁第一次启动本来就要等约 2 分钟才进系统）。
**但别因此去试** ✗ —— 用对基座才是正道 ✓

```
/data/local/tmp/tee_patched.img     ← 别的基座的补丁 ✗ 但名字最像"该刷的那个"
/data/local/tmp/tee_nogz_new.img    ← 本机该刷的补丁 ✓ 名字却看不懂
```

**→ 规则：补丁文件名里必须写清「适配哪种基座 / 能不能给这台刷」** ✓
例如 `FLASH_THIS_shuilan_patch_for_this_phone.img` /
`DO_NOT_FLASH_rk_patch_wrong_base.img` ✓

说得更直白一点：**同一台设备上不要同时放多个基座的补丁** ✗。
真放了，至少写一份 `TEE_README.txt` 在旁边说清楚哪个能刷。

---

## ⚠️ 核心规律：补丁绑死的是 `tee` 基座 —— **但「跨基座能不能用」已被实测推翻**

NoGZ 补丁改的是 `tee` 分区里 **`atf` 成员的启动交接逻辑**，所以它只对
**「构建它时用的那个 `tee` 基座」**有效。

### 🧪 2026-10-07 的决定性实测：**跨基座可以正常启动** ✓

```
备用机（原始 tee_a = f8f286f1…，即 rk 补丁的基座）
  → 刷入 shuilan 补丁（17ec8497…，基座 a91f5ded…）   ← 真正的跨基座
  → 重启后 136 秒回到网络
  → 之后 3 分钟内连测 12 次，全程在线（不是启动循环）
  → 系统正常，tee_b 全程未动
```

**→ 所以「跨基座必坏」是错的** ✗，「跨基座就启动不了」也是错的** ✗。

**之前那个「卡二」的真面目**：就是**每次开机都会有的 1~2 分钟延迟** ✗
（见 [docs/05-gotchas.md 第 12 条](../docs/05-gotchas.md)）—— 当时没等够就去进了 fastboot，把一个本来能起来的启动亲手打断了 ✗。

### 那么现在该怎么理解「基座匹配」

| 说法 | 现在该怎么说 |
|---|---|
| 补丁绑死 `tee` 基座 | ⚠️ **夸大**。实测跨基座能启动；基座差异不阻止启动 |
| 跨基座必卡二 | ❌ **错**。那就是延迟 |
| 跨基座的补丁装进去的是**别的批次的 TEE OS** | ✅ 事实 |
| 跨基座可能让 keymint / DRM / 安全元件与 ROM 版本不匹配 | ⚠️ **理论上仍可能**，但本机跨基座实测尚未发现异常 |

**→ 仍然推荐用针对自己基座的补丁** ✓，但理由变了：
不是因为「会卡住」✗，而是**同基座更保守、更少变量** ✓。

> 🔑 **真正的实用结论**：**刷错了基座也不用恐慌** ✓ —— 它会先卡 1~2 分钟，
> **给它 3 分钟**，很大概率自己就起来了 ✓
> （当然，先备份总没错。）

**已实测确认的边界**（哪些变化不影响、哪些影响）：

| 分区/条件 | 变了会失效吗 | 怎么确认 |
|---|---|---|
| **`tee`** | ✅ **会失效** | 比 `tee_a` 哈希 |
| `lk` | ❌ 不会 | 实测被换掉后补丁照常工作 |
| `gz` / `dtbo` / `boot` / `system` | ❌ 不会 | 跨 Android 15 → 16 大版本升级仍正常 |
| 跨设备（同型号） | ⚠️ **看 `tee_b`** | `tee_b` 相同 = 同批固件 = 基座相同 |

> 🛑 **最容易误读的一点：刷「备用机的补丁」成功 ≠ 跨基座可行** ✗
>
> 有人看到「备用机刷它的补丁能用」就推出「那把备用机的补丁刷到主力机上也行」✗ —— **这是错的推论** ✓：
>
> | | 备用机 | 主力机 |
> |---|---|---|
> | 备用机那份补丁（`f1511dca…`）的基座 | `f8f286f1…` | `f8f286f1…` |
> | 刷之前它自己的 `tee_a` | **`f8f286f1…`** | **`a91f5ded…`** |
> | 判定 | ✅ **同基座**（就该能用）| ⚠️ **跨基座**（已实测可行 ✓，见上）|
>
> **备用机那次自始至终都是同基座刷入** ✓ —— 它证明的是「同基座可用」✓，
> **不能当成「跨基座可行」的证据** ✗。
> 真正跨基座的只有主力机那一次 ⚠️，而且那次结论不可靠（见下面「混刷」一节）。

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

## 2. ⭐ `tee_nogz_shuilanA15_5M.img` —— **实机验证成功**

| 项 | 值 |
|---|---|
| 适配基座（`tee_a`） | `a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7` |
| 构建时配套的 `lk` | `a17d87c630f23b6720cfe311b2a06d196503a4eb00242bc6413eeeb0b836e1cb` |
| cert mode | `LEGACY` |
| 大小 | 5 242 880 字节 |
| sha256 | `17ec849749febda62445f922ec3ee8b65a3092f0ea2c641e98eb732fbe60ee59` |
| 离线自检 | ✅ 14/14 回归全通过 |
| 验签 | ✅ 2 × `Result: VALID` |
| 同构比对 | ✅ 与实机验证可用的 rk 补丁逐项一致（175 区间 / 2953488 字节）|
| **实机验证** | ✅ **通过**（2026-10-06 实测）|

**实测结果（原 `a91f5ded` 基座设备）**

```
刷前 tee_a = a91f5deda942a167   （已另存备份）
刷后 tee_a = 17ec849749febda6   ✓ 回读校验一致
tee_b      = f8f286f138e758a5   ✓ 全程未动

重启后：
  /dev/kvm   = crw-rw-rw- 1 root root 10, 232   ✅ 出现
  /proc/misc = 232 kvm                           ✅
  系统完好：497 个应用包一个没丢 ✓
```

> ⚠️ **每次开机都会卡在第二屏 1~2 分钟**（本次实测 130 秒）才进系统 —— 不是只有第一次。
> **这不是变砖，等着就好** —— 千万不要急着进 fastboot，那会打断启动。
> 详见 [docs/05-gotchas.md 第 12 条](../docs/05-gotchas.md)。

**它是怎么来的**：某个设备**刷 ROM 之后 `tee_a` 被更新成了 `a91f5ded…`**
（原厂未改动的 `tee_b` 仍是 `f8f286f1…`）。于是用**这台设备自己的 `tee_a`**
重新逆向偏移、重新构建、重新签名 —— 也就是**同一台设备换基座后该怎么自救**的完整范例。

> 它是**跟随第一台设备的实战**而产出的、针对第二个基座的补丁。
> 截至 2026-10-06，它已在原 `a91f5ded` 基座的设备上**实机验证通过** ✓

---

## 两个补丁对照

| | `tee_nogz_rk_5M.img` | `tee_nogz_shuilanA15_5M.img` |
|---|---|---|
| 基座 | `f8f286f1…`（原厂） | `a91f5ded…`（ROM 更新后） |
| 离线回归 | 14/14 ✅ | 14/14 ✅ |
| 验签 | VALID ✅ | VALID ✅ |
| 实机 | ✅ **成功** | ✅ **成功** |
| 对应 profile | [`profiles/xagapro.json`](../profiles/xagapro.json) | [`profiles/shuilanA15.json`](../profiles/shuilanA15.json) |

**⚠️ 关于「混刷」—— 早期那个「必卡二」的结论已经作废，而且现在证明「跨基座可行」** ✓

我们曾经断言：把「原厂基座」的补丁刷进「已更新基座」的设备**必卡二**。
但这个结论**依据的是一次被误诊的测试** ✗ ——

**刷完 NoGZ 补丁后，第一次启动本来就会在第二屏卡将近 2 分钟**
（详见 [docs/05-gotchas.md 第 12 条](../docs/05-gotchas.md)）。当时没等够，就把它当成了砖 ✗

**→ 而 2026-10-07 的备用机实验已经把这个悬案彻底结清** ✓ ——
**跨基座补丁【能正常启动】，既不是「必坏」✗，也不是「未验证」⚠️，而是【已实测可行】** ✓
（详见本文档上面「核心规律」一节的完整数据。）

### 但仍然强烈建议用针对自己基座的补丁 ✓

理由**不是**「会卡二」✗，而是：
跨基座的补丁里装的是**别的批次的 TEE OS**。即使系统能启动，
keymint / DRM / 安全元件这类 TEE 服务可能与设备当前的 ROM **版本不匹配** ✗。

### 怎么区分「正常慢」和「真失败」✓

| 现象 | 正常慢 ✓ | 真失败 ✗ |
|---|---|---|
| 屏幕 | 停在**第二屏**（logo2）转圈 | 停在**第一屏**，或黑屏后**自动进 fastboot** |
| adb | **设备可见**（`adb devices` 看得到） | 看不到，或本身就是 fastboot 模式 |
| 时间 | 1~3 分钟后自己进系统 | 5 分钟以上无变化 |
| 处理 | **等** ✓ | 刷回备份 ✓ |

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
