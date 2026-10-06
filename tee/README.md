# 成品 tee 镜像（示例）

这里是**已经构建并签名好**的 NoGZ 补丁 tee 镜像，可直接刷入对应固件的设备。
放在这里是为了给后来者一个**可对照的成品示例**，以及方便已确认固件匹配的人直接用。

---

## ⚠️ 先读这个：补丁是**绑定 tee 基座**的

NoGZ 补丁改的是 `tee` 分区里 **`atf` 成员**的启动交接逻辑。
所以补丁**只对"构建它时用的那个 `tee` 基座"有效**。

**判断你的设备能不能用某个补丁 —— 只比一个哈希：**

```bash
# 1) 看你设备当前的 tee_a（补丁就是要覆盖它）
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'

# 2) 和下表"适配基座"对照
#    = 基座  → 可以直接刷 ✓
#    ≠ 基座  → 不要刷 ✗（即使同型号、同 ROM 版本也可能卡开机）
```

**如果 `tee_a` 和基座不一致**：把 `tee_a` + `lk_a` + `preloader_raw_a` dump 出来，
按 [docs/02-build-and-sign.md](../docs/02-build-and-sign.md) 重新构建 —— 工具都在
[`tools/`](../tools/) 里。

---

## 成品清单

### 1. `tee_nogz_rk_5M.img`

| 项 | 值 |
|---|---|
| 适配基座（`tee_a`） | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |
| 构建时配套的 `lk` | `8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3` |
| cert mode | `LEGACY` |
| 大小 | 5 242 880 字节（= tee 分区） |
| sha256 | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| 实机验证 | ✅ **已通过**（两次：原 ROM + Android 16 新 ROM 都正常，`/dev/kvm` 出现） |

**实测结论（重要）**：该补丁在设备升级到 **Android 16 / HyperOS 3.3** 之后**依然有效** ——
即使这次升级**把 `lk_a` 换掉了**（`8cbaa2e8...` → `a17d87c6...`）。

**→ 说明：`lk` 变化不影响补丁；真正决定兼容性的是 `tee` 基座。**

### 2. `tee_nogz_shuilanA15_5M.img`

| 项 | 值 |
|---|---|
| 适配基座（`tee_a`） | `a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7` |
| 构建时配套的 `lk` | `a17d87c630f23b6720cfe311b2a06d196503a4eb00242bc6413eeeb0b836e1cb` |
| cert mode | `LEGACY` |
| 大小 | 5 242 880 字节 |
| sha256 | `17ec849749febda62445f922ec3ee8b65a3092f0ea2c641e98eb732fbe60ee59` |
| 离线回归 | ✅ 14/14 全通过 |
| 验签 | ✅ 2 × `Result: VALID` |
| 实机验证 | ❌ **尚未实机验证**（`device_tested: false`） |

> 这个基座是**某些 HyperOS ROM 刷机后会更新出来的** `tee_a`（本案例中刷完 ROM 后
> `tee_a` 从 `f8f286f1...` 被换成了 `a91f5ded...`）。原厂未改动的 `tee_b` 仍是 `f8f286f1...`。
> **本案例中这个补丁没有实际使用**（后来发现设备保留着旧补丁，`/dev/kvm` 已可用）。

---

## 刷入方法

```bash
# 0) 先备份（必须！）
adb shell su -c 'dd if=/dev/block/by-name/tee_a of=/data/local/tmp/tee_backup.img bs=4096'
adb pull /data/local/tmp/tee_backup.img

# 1) 推入并刷写
adb push <成品>.img /data/local/tmp/tee_patched.img
adb shell su -c 'dd if=/data/local/tmp/tee_patched.img of=/dev/block/by-name/tee_a bs=4096 && sync'

# 2) 回读校验（必须和成品 sha256 一致）
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'

# 3) 重启 + 验证
adb reboot
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

**回退**：把第 0 步的备份刷回 `tee_a` 即可；或者切到 B 槽（`tee_b` 从未改动，是天然兜底）。

---

## 关于这些文件

- 这些是**经过官方工具链签名**的完整 `tee` 分区镜像（含 MTK 的 ATF、TEE OS 与证书链）。
- 它们由 [_`mtk-mod-tee-nogz`_](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz) +
  [_`pwnage24mtk`_](https://github.com/kasnria001/pwnage24mtk) 构建，偏移定义见
  [`profiles/`](../profiles/)。
- upstream `mtk-mod-tee-nogz` 明确声明**不包含固件与预编译镜像**；这里放成品是为了
  **可对照、可复用**，请自行判断是否适合你的场景。
- 请只在**你自己有权访问的设备与固件**上使用。
