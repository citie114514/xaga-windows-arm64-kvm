# 构建与签名 —— 步骤详解

[**中文**](02-build-and-sign.md) | [English](en/02-build-and-sign.md) | [日本語](ja/02-build-and-sign.md) | [Русский](ru/02-build-and-sign.md)

本篇讲清楚：**NoGZ 补丁到底改了什么**、**怎么构建**、**怎么签名**、**怎么验**。

> 工具是 [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)（上游），
> 本项目的一键脚本只是把它和"刷入 + 验证"串起来。
> 上游明确声明：**不包含固件、不含刷机镜像、脚本没有自动刷写功能** —— 刷入那一半是本项目补的。

---

## 一、补丁到底改了什么

改的是 `tee.img` 里 **`atf` 成员**的**启动交接逻辑**，目标状态是：

> **保持 LK 进入 EL1h、AArch64 内核交接到 EL2h**，并**同步 ATF/LK 共享的 GZ-info tag**。

上游保留了三类"错误做法"作为反例（这也是为什么不能自己乱 patch）：

| # | 反例 | 说明 |
|---|---|---|
| 1 | `D2A21E08` 实际装入 `0x10f00000`，不是 LK 的 `0x50f00000` | 正确编码应是 **`D2AA1E08`** |
| 2 | 原版 LK 的 EL2 入口路径**会访问 `CPTR_EL3`** | 所以**不能**把 LK 和内核的入口级别一并强制为 EL2h |
| 3 | 只改 ATF 的 GZ getter **不会**自动改变 LK 的状态 | 必须**同步共享 tag**，否则后续仍会进 GZ unmap 路径 |

**关键点**：补丁**保留 GZ 的内存预留和 remap**，并**不宣称返还内存** ——
它只是让 EL2 能被 Linux 使用（从而暴露 `/dev/kvm`）。

---

## 二、环境准备

**Python 3.10+**，建议独立虚拟环境。

Linux / macOS：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

Windows PowerShell：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

依赖是 **Capstone**（反汇编）和 **Unicorn**（模拟执行）—— 都是离线分析用的，不需要设备和网络。

**另外还需要**（不随仓库分发，自行准备）：

- **`pwnage24mtk`** 完整工具目录（含 `sign_mtk_cert.py` / `verify_mtk_image.py`）
- **与设备匹配的固件**：`tee.img` / `lk.img` / `preloader.bin`
  → 直接从设备 dump 最可靠（见 [01-enable-kvm.md](01-enable-kvm.md) 第 3 节）

---

## 三、机型匹配（必须先过这一关）

工具靠 **完整 SHA-256** 匹配 TEE/LK 配对，**不是**靠机型名或文件大小：

| Profile | 目标样本 |
|---|---|
| `xaga` | Redmi Note 11T Pro / Pro+（MT6895）**← 本项目实测机型** |
| `peral` | Xiaomi 13T |
| `yunluo` | 已分析的 yunluo TEE/LK 配对 |

> **机型名相同、固件版本接近、文件大小一致，都不能替代哈希匹配。**
> 所以务必**从设备本身 dump**，不要到网上找"同机型"的固件包。

完整哈希和地址定义在工具仓库的 `references/profiles.json`。

```bash
# 先算一下你 dump 出来的哈希，和 profiles.json 对照
sha256sum dump/tee_a.img dump/lk_a.img
```

---

## 四、第一步：只做离线检查（不签名、不产出）

先跑 `--check-only`，确认 TEE/LK 配对能匹配上、补丁回归能过：

Linux / macOS：

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    "$HOME/private-firmware/xaga/tee.img" \
  --lk     "$HOME/private-firmware/xaga/lk.img" \
  --check-only
```

Windows：

```powershell
$inputDir = Join-Path $HOME 'private-firmware\xaga'
.\.venv\Scripts\python.exe scripts/build.py --profile xaga `
  --tee "$inputDir\tee.img" --lk "$inputDir\lk.img" --check-only
```

`--check-only` 的行为：

- ✅ 做 TEE/LK 补丁的离线回归（PC/SPSR、真实 ATF/LK tag parser、共享 flags、GZ gate、以及刻意构造的错误反例）
- ❌ **不**检测签名模式、**不**生成镜像、**不**调用 pwnage

**离线回归过的项目**（本机报告是 **14/14 通过**）：

| 检查项 | 结果 |
|---|---|
| PC / SPSR 状态 | ✓ |
| ATF tag parser | ✓ |
| LK tag parser | ✓ |
| 共享 flags | ✓ |
| GZ gate | ✓ |
| 有意构造的错误反例（应被拒绝） | ✓ |

> ⚠️ 报告里的"14 条记录"是**有边界的检查记录，不是 14 次整机启动测试**。
> 离线 `VALID` ≠ 设备一定能启动。

---

## 五、第二步：检测 preloader 的签名模式

签名方式**取决于 preloader 的证书遍历模式**，必须先用工具里的检测器确认：

```bash
.venv/bin/python scripts/detect_pl_cert_mode.py \
  "$HOME/private-firmware/xaga/preloader.bin" --json
```

默认把完整证据（含反汇编）写到 `logs/` 下的新文件，该目录已被 Git 忽略。

| 检测结果 | 对应的 pwnage 参数 |
|---|---|
| **`new`：`NEW_PARSER`** | **不加模式参数**（既不加 `--legacy`，也没有 `--new`） |
| **`legacy`：`LEGACY`** | **加 `--legacy`** |
| `NEED_MANUAL` / 不支持 / 结果不明确 | **停下来手工分析**，不要按机型猜 |

> 本机（Redmi Note 11T Pro+）实测是 **`LEGACY`**，所以走 `--legacy`。
>
> 注意"new 什么也不加"指的是**不增加模式选项**，不是省略输入文件和写入选项 ——
> 正常的 `--all -w -o` 还是要保留的。
>
> 检测器是**静态证据分析**，不等于 efuse 状态、漏洞可利用性或设备启动验证。

---

## 六、第三步：构建签名副本

```bash
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee       "$HOME/private-firmware/xaga/tee.img" \
  --lk        "$HOME/private-firmware/xaga/lk.img" \
  --preloader "$HOME/private-firmware/xaga/preloader.bin" \
  --tools     ../pwnage24mtk \
  --out-dir   outputs/xaga-run-01
```

**注意事项**：

- 必须提供 `--preloader`（签名模式和它绑定），脚本会自动调用检测器，**不需要手工选模式**
- preloader 的哈希会记进 manifest，但**脚本无法仅凭文件名证明它和设备实际用的一致**
- `--out-dir` **必须是尚不存在的新目录** —— 重跑请换目录，**不要覆盖旧结果**，
  **更不要把签名产物当原始输入再喂进去**

### 产出结构

```text
outputs/xaga-run-01/
  cert-mode.txt          # 完整检测证据
  detect.log             # 检测器 JSON 输出或错误
  tee.unsigned.img       # 中间文件（不是签名成品！）
  tee_nogz_legacy.img    # LEGACY 模式 → 这个才是成品
  # tee_nogz_new.img     # NEW_PARSER 模式时是这个
  sign.log
  verify.log
  disassembly.txt
  manifest.json
```

**判断成功不能只看 `.img` 存在** —— 要看**退出码、完整日志和 manifest.json**。

---

## 七、第四步：验签（要求 2 个 VALID）

```bash
cd ../pwnage24mtk
python verify_mtk_image.py --all ../outputs/xaga-run-01/tee_nogz_legacy.img
```

**必须看到两个 `Result: VALID`**（ATF 组 + TEE 组）：

```
Result: VALID
Result: VALID
```

本机实测：

| 检查项 | 结果 |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`** ✓ |
| CERT1 / CERT2 signature | OK ✓ |
| Image header hash / Image data hash | OK ✓ |
| `tee` 成员是否被改动 | **未改动** ✓ |
| ATF 与重新打补丁结果 | **逐字节一致** ✓ |
| 官方 14 项回归 | **14/14 通过** ✓ |

**未验证项（诚实标注）**：`Trusted root check: skipped`
→ 设备 eFuse 信任根对这条证书链的比对**无法离线验证**，只能实机启动才算。

> 这里用到的是**第三方工具的证书处理方式**，不代表拥有厂商私钥，也不代表获得了新的官方授权。
> 原理是 MTK 的 ASN.1 证书解析逻辑缺陷（CVE-2023-20696 同类，CVE-2025-20730 才修补）。

---

## 八、第五步：处理"超出分区 1072 字节"

这是本项目踩到的**最大坑**，必须处理：

```
unsigned : 5 242 880   (= tee 分区大小，刚好占满)
signed   : 5 243 952   (+1072)
```

增量来自 **BIT STRING wrapper（987 B）** + **CERT2 dsize 982→2059（对齐到 2064）**。

**但插入点在 `atf` 之后，尾部零填充完全没变：**

| 成员 | unsigned | signed |
|---|---|---|
| `atf` | 0x200 | 0x200（**没变**） |
| `tee` | 0x46440 | 0x46870（+1072） |
| `cert1` | 0x353a40 | 0x353e70（+1072） |
| `cert2` | 0x354310 | 0x354740（+1072） |
| **尾部零填充** | 1 751 322 | **1 751 322（不变）** |

尾部有 **1.75 MB 全零** → **裁掉 1072 字节零填充即正好 5 MiB，零真实数据损失**。

```bash
# 先逐字节确认超出部分全是 0x00
python - <<'PY'
data = open('tee_nogz_legacy.img','rb').read()
tail = data[5242880:]
print('超出字节数:', len(tail), ' 非零字节数:', sum(1 for b in tail if b))
PY

# 确认全零后再裁
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
sha256sum tee_nogz_flash.img
```

**如果超出部分含非零字节 → 停下来人工分析，不要硬裁。**

一键脚本会自动做这件事，**并且坚持先验证全零才裁**。

---

## 九、第六步：刷入并实机验证

这部分见 [01-enable-kvm.md](01-enable-kvm.md) 的第 5、6 节：

```
dd 写入 tee_a  →  回读 sha256 比对  →  重启  →  /dev/kvm 出现
                                        ↘  expdb 里 [SBC] image atf header auth pass
```

**成品参考值**（Redmi Note 11T Pro+）：

| 文件 | 大小 | sha256 |
|---|---|---|
| `tee_nogz_legacy_5M.img`（补丁版，已裁到分区大小） | 5 242 880 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `tee_a.img`（原厂，回滚用） | 5 242 880 | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

---

## 十、想适配别的 MTK 机型？

上游要求：**新增版本必须提供完整 SHA-256 配对**，参考 `references/adaptation.md`。

> **不要通过修改已有哈希或删除断言来绕过版本检查。**

大致流程：

1. 从目标设备 dump 出 `tee` / `lk` / `preloader`
2. 算 SHA-256，和 `references/profiles.json` 里的已分析样本对照
3. 如果没匹配上 → 需要按 `references/adaptation.md` **新增一个 profile**（要理解 ATF/LK 的偏移和指令）
4. 跑 `--check-only` 回归 → 再走签名流程

**同型号不同固件版本也可能匹配不上** —— 这套东西是"精确固件样本"级别的工具，容不下模糊匹配。

---

## 十一、验证边界（务必阅读）

上游明确列出的边界，照抄如下（很重要，别过度解读）：

- 已知镜像回归会检查 PC/SPSR、真实 ATF/LK tag parser、共享 flags、GZ gate 和有意构造的错误反例。
- 报告中的 14 条记录是**有边界的检查记录，不是 14 次整机启动测试**。
- CPU 特征、CurrentEL、部分系统寄存器和缓存维护被**显式建模**；
  **没有执行**完整 LK 初始化、Linux、真实 ERET、PSCI 或外设。
- 离线验签若显示 `Trusted root check: skipped`，**设备信任根仍未验证**。
- CI 不包含真实固件，**不能替代** `build.py --check-only` 的已知镜像回归，更**不能证明硬件兼容性**。

**报告时请分别注明**：输入身份、离线结果、实际设备反馈、未验证项。

---

## 十二、上游工具的已知 Bug（已提 PR）

`scripts/build.py:340` 调用了 `sign_all_flag(args.tools)`，但**全文件没有这个函数的定义**
→ 走签名路径必然 `NameError`。`--check-only` 提前 return 所以没暴露。

（另：`sign_mtk_cert.py` 本身没有 `--all` 参数，所以该函数本该返回 `[]`。）

修复见本仓库的 [issues/tee-nogz-1-sign-all-flag.md](../issues/tee-nogz-1-sign-all-flag.md)。
