# xagapro (Redmi Note 11T Pro+) 走 MTK NoGZ → KVM 可行性报告

[**中文**](appendix-early-report.md) | [English](en/appendix-early-report.md) | [日本語](ja/appendix-early-report.md) | [Русский](ru/appendix-early-report.md)

日期：2026-10-04
设备：`192.168.31.75:33445`（备用机，**未刷任何东西**，全程只读）
状态：**离线验证全部通过，等待决定是否实机写入**

---

## 1. 设备事实（只读侦察）

| 项目 | 值 |
|---|---|
| 型号 | 22041216UC / `xagapro` / 市场名 **Redmi Note 11T Pro+** |
| SoC | MT6895（Dimensity 8100：4×A78 + 4×A55） |
| 系统 | HyperOS 3，`OS3.0.1.0.VLHCNXM`，Android 15 |
| 内核 | `5.10.247-android12-9-Pandora-26w08d`（第三方内核 Pandora） |
| Root | **有**，KernelSU（`uid=0(root) context=u:r:ksu:s0`） |
| Bootloader | **已解锁**（`ro.boot.flash.locked=0`，`verifiedbootstate=orange`） |
| 当前槽位 | `_a` |
| RAM | 7.68 GiB → **8 GiB 版本**（不是 12 GiB） |
| userdata | 226 G，已用 204 G，剩 21 G（**偏紧，装 rootfs 前要清空间**） |
| `hwid` | sku=xagapro country=CN level=MP version=4.9.0 project_adc=701 |

内核自带能力（从 `/proc/config.gz`）：

```
CONFIG_ARM64_VHE=y          <- 关键：内核支持 VHE，可以运行在 EL2
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_ARM_GIC_V3=y         <- vGIC 硬件基础
CONFIG_ARM_GIC_V3_ITS=y
CONFIG_ARM64_VA_BITS=39
```

当前 `/dev/kvm` **不存在**，`kvm` 模块已编译进内核但因内核运行在 EL1 而初始化失败。
`/sys/module/` 下有 `gz_main_mod` `gz_trusty_mod` `gz_tz_system` `gz_ipc_mod`
`gz_irq_mod` `gz_virtio_mod` → **GenieZone 正在占着 EL2**，与理论完全一致。

---

## 2. 为什么官方脚本直接拒绝

`mtk-mod-tee-nogz` 只认 3 个 profile，全部按 `tee.img`/`lk.img` 完整 SHA-256 精确匹配：

| profile | 目标机型 | 是否匹配本机 |
|---|---|---|
| `yunluo` | — | ❌ |
| `peral` | Xiaomi 13T | ❌ |
| `xaga` | Redmi Note 11T Pro / POCO X4 GT | ❌ |

本机实测（`/dev/block/by-name/` 直接 sha256）：

```
tee_a (5 MiB) = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_a  (8 MiB) = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3
tee_b         = f8f286f1... (与 tee_a 完全相同)
lk_b          = 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0
gz_a          = 3f829d4061b1cc00d6bbcd1cafa3263348ec75800c9654cd936410c4d26572f6
```

对 xaga profile：
- `tee_sha256 = bd4b13a7…` ❌
- `lk_sha256 = 03856964…` ❌

**结论：不能照抄，必须为 xagapro 新增 profile（= 该仓库 `docs/adaptation.md` 描述的适配工作）。**

好消息：结构上高度接近，**ATF 是同一份源码构建物**，只是个别函数偏移不同。

---

## 3. 逆向出的 xagapro profile（已用官方回归验证）

### 3.1 定位依据（反汇编证据）

| 项 | xaga | **xagapro（本机）** | 证据 |
|---|---|---|---|
| `pc_patch` | 0x1ad9c | **0x1ade0** | `ldr x8,[x1,#0x10]` → 改成 `mov x8,#0x50f00000` |
| `kernel_patch` | 0x64a4 | **0x64a4** | `csel w12,w13,w12,eq` → 改成 `mov w12,#0x3c9`(EL2h) |
| `getter` | 0xe5f8 | **0xe560** | `adrp x8,0x48244000; ldr w8,[x8,#0xf00]; mvn w8,w8; and w0,w8,#1; ret` = 文档里的 `(~flags)&1` |
| `callback` | 0xdf14 | **0xde7c** | delta 到 getter = **0x6e4（与 xaga 完全相同）** |
| `flag` | 0x45f08 | **0x44f00** | callback: `adrp x9,0x48244000; str w8,[x9,#0xf00]` |
| `ep` | 0x53930 | **0x52930** | `add x14,x14,#0x938` → x14 = ep+8；PC 写 ep+8、SPSR 写 ep+16，符合 TF-A `entry_point_info` 布局 |
| `kernel_args` | 0x539e0 | **0x529e0** | = ep + 0xB0（与 xaga 同 delta） |
| `handoff_global` | 0x53af0 | **0x52af0** | args_getter case0: `adrp x8,0x48252000; ldr x0,[x8,#0xaf0]` |
| `cold` | [0x1ad74,0x1adf8] | **[0x1adb8,0x1ae3c]** | 函数 `stp x29,x30` 起，`ret` 止 |
| `cold_helpers` | [0xb6e8,0xb700] | **[0xb6bc,0xb6d4]** | 两个 `adrp/ldr/ret` 小函数 |
| `kernel` | [0x6454,0x6538] | **[0x6454,0x6538]** | 完全相同 |
| `tag_parser` | [0x6688,0x68e8] | **[0x6688,0x68f0]** | 起始完全一致 |
| `args_getter` | [0xb7fc,0xb858] | **[0xb7d0,0xb800]** | 跳表分发器 + case0 |
| `lk_*` (13 项) | — | **与 xaga 完全一致** | 见下 |

**LK 侧全部命中同一偏移且指令字一致**：`lk_illegal=0x3a18` 处就是 `mrs x9,cptr_el3`；
`lk_elcheck` 起点 `0x39c8` 就是 `mrs x4,CurrentEL`；`lk_gate=0x28d4`、`lk_skip=0x2904`
（`mov w0,wzr`）、`lk_getter=0x1e8a8`、`lk_callback=0x1e8bc` 全部对上。
→ **本机 LK 的代码段与 xaga 的那份是同一份构建**，只是外层证书/DTB 打包不同。

### 3.2 验证结果

用官方 `scripts/build.py --check-only`（仅新增 profile + 修正偏移，未改任何判定逻辑）：

```
passed_checks:
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=False   (4)
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=True    (4)
  missing_tag_defaults
  LK_EL2_illegal_EL3_negative_control
  kernel_feature_and_AArch32_controls
  wrong_PC_negative_control
  missing_tag_sync_negative_control
  budget_exhaustion_rejected
→ 14/14 全部通过
```

包含 4 个**反例**也通过（错误 PC、漏同步共享 tag、LK 从 EL2 进入读 CPTR_EL3、
指令预算耗尽），说明补丁语义确实正确，而不是"跑通了就过"。

### 3.3 成品（未签名）

`tee_nogz_xagapro.unsigned.img`，sha256 `2bcdf7b3bdae3dcc77d570e350a79e5962a46daa7cd19610b022742f8773f413`

10 个槽位的实际改动：

| ATF 偏移 | file 偏移 | 原指令 | 新指令 |
|---|---|---|---|
| 0x01ade0 | 0x01afe0 | `ldr x8,[x1,#0x10]` | `mov x8,#0x50f00000` |
| 0x0064a4 | 0x0066a4 | `csel w12,w13,w12,eq` | `mov w12,#0x3c9` ← **内核交接 EL1h → EL2h** |
| 0x00e560 | 0x00e760 | `adrp x8,#0x48244000` | `mov w0,#0` |
| 0x00e564 | 0x00e764 | `ldr w8,[x8,#0xf00]` | `ret` |
| 0x00de7c | 0x00e07c | `ldr w8,[x0]` | `mov w8,#1` |
| 0x00de84 | 0x00e084 | `mov w0,wzr` | `str w8,[x0]` ← **写共享 tag flags=1** |
| 0x00de8c | 0x00e08c | `ret` | `b #0x4820e568` |
| 0x00e568 | 0x00e768 | `mvn w8,w8` | `dc cvac,x0` |
| 0x00e56c | 0x00e76c | `and w0,w8,#1` | `dsb sy` |
| 0x00e570 | 0x00e770 | `ret` | `b #0x4820e560` |

---

## 4. 签名可行性（已探明）

```
detect_pl_cert_mode.py preloader_raw_a.img --json
→ status: LEGACY
   reason: certificate entry uses enter-value traversal (arg4=1); legacy BIT STRING wrapper required
   sha256: 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1
```

结论明确（不是 `NEED_MANUAL`）→ 签名时 pwnage 需要 `--legacy`，脚本会自动带。

---

## 5. 还缺什么 / 风险

### 5.1 还缺
1. **`pwnage24mtk` 工具链**（`sign_mtk_cert.py` / `verify_mtk_image.py`）。仓库不捆绑，必须自备可信副本。
2. **真机启动验证**：本仓库的 linux 分支是 **xaga** 的。xagapro 只在个别驱动里有适配
   （如 `power: mediatek: xagapro: SC8561` 充电），**面板/触摸/充电可能不同 → 可能起不来**。
3. 磁盘空间：只剩 21 G，rootfs 构建要腾地方。

### 5.2 风险（必须先想清楚）
- **tee 是安全分区。** 刷错 → preloader 验签失败 → 启动链断 → **只能靠 EDL 救**，
  而 MT6895 的 EDL 通常需要授权账号。这是真实砖机风险。
- 反例检验通过 **≠ 能启动**。官方自己的声明就是
  `device_tested: false` / "离线回归不等于设备一定接受或能够启动"。
- 双槽位 tee_a == tee_b（都改了才有效，只改一个则切槽位会回来）。
- **对 Android 本体的影响未知**：GZ 被禁用后 `gz_*` 模块不会加载；
  虽然 `CONFIG_ARM64_VHE=y`，但 MTK 私有驱动是否假设 GZ 存在，未验证。

### 5.3 建议的推进顺序
1. 先拿到 `pwnage24mtk`，跑 `sign_mtk_cert.py` + `verify_mtk_image.py`，
   要求输出**两个 `Result: VALID`**，并对成品重新跑一遍 14 项回归。
2. 再决定是否写入。要写入时优先只写 `tee_a`（当前槽位），并确认
   EDL/授权工具可用、`misc`/`frp` 等可回滚路径清楚。
3. 建议把这份 profile 提 PR 给上游仓库（`docs/adaptation.md` 要求新增版本需审计 + 正反例）。

---

## 6. 备份（已在本目录 `backup/`）

| 文件 | 大小 | sha256 |
|---|---|---|
| `tee_a.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `tee_b.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `lk_a.img` | 8 MiB | 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3 |
| `lk_b.img` | 8 MiB | 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0 |
| `preloader_raw_a.img` | 4 MiB | 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1 |

---

## 7. 复现命令

```bash
git clone --depth 1 https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
# 把 profiles.xagapro.json 里的内容并入 references/profiles.json
# 在 scripts/build.py 的 --profile choices 里加上 "xagapro"

# 1) 离线回归（不碰设备）
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img --check-only

# 2) 签名（需要自备 pwnage24mtk）
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img \
  --preloader backup/preloader_raw_a.img \
  --tools ../pwnage24mtk \
  --out-dir outputs/xagapro-run-01
```

依赖：`pip install capstone unicorn`

---

## 8. 补充证据（2026-10-04 晚）

### 8.1 KVM 为何当前不可用 —— 实测钉死

```
/proc/misc | grep -i kvm        → 空（46 项 misc 设备里一个都没有）
/sys/module/kvm/                → 只有 parameters/ uevent，没有 initstate / refcnt
/sys/module/kvm/parameters/     → halt_poll_ns=500000 grow=2 grow_start=10000 shrink=0
/dev/kvm                        → 不存在
```

`kvm_init()` 未能完成（misc 设备没注册）。内核里 `kvm_arch_init` / `kvm_init` 符号都在，
配置也是 `CONFIG_KVM=y`，唯一能让它失败的原因就是 **内核不在 EL2**。
与 3.1 表里 `kernel_patch` 那个槽位（`csel w12,w13,w12,eq` → 强制 `#0x3c9`）完全对应。

### 8.2 补丁对 Android 同样生效

`kernel_patch` 位于 ATF 的「AArch64 内核交接 helper」，它决定**内核入口的 SPSR**。
不同槽位之间的内核（Android 的或 mainline 的）走的是同一个交接点，因此：

- 留在 Android：Android 内核同样从 EL2 起来。其配置为
  `CONFIG_ARM64_VHE=y` + `CONFIG_VIRTUALIZATION=y` + `CONFIG_KVM=y`，`/dev/kvm` 会出现。
- 刷 mainline：视频里的做法。
- 两者可共存（不同槽位 / `fastboot boot`）。

**建议的最小验证**：只刷 `tee`，重启进 Android，看 `/dev/kvm`。
这一步就能在真机上证实 ATF 那一环，成本最低。

Android 侧限制：`/dev/kvm` 无 SELinux 规则（需 `su -c` + 可能 `setenforce 0`）；
Termux 的 QEMU 没有 virgl/venus，GPU 加速不可用。

