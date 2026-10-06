# 固件 profile

`mtk-mod-tee-nogz` 靠 **profile** 定位 ATF/LK 里需要打补丁的位置。
profile 用 **完整文件 SHA-256** 匹配输入，所以是"精确固件样本"级别的工具 ——
**同型号不同固件批次，profile 就不通用**。

## 这里的文件

| 文件 | 基座 `tee` | 基座 `lk` | 说明 |
|---|---|---|---|
| `xagapro.json` | `f8f286f1…` | `8cbaa2e8…` | 我们自己逆向出来的。对应 **rk 的包**，也是**两台机器 `tee_b` 的共同基座** |
| `shuilanA15.json` | `a91f5ded…` | `a17d87c6…` | 为 **ShuiLan 的 A15 (pearl 移植)** 逆向 —— 见 `tools/` 的方法 |

> `shuilanA15.json` 里同时保留了上游原始 `xaga` 条目（改名 `xaga_upstream`）以便对照。

## 怎么用

把这些条目合并进 `mtk-mod-tee-nogz` 的 `references/profiles.json`，
然后按 [docs/02-build-and-sign.md](../docs/02-build-and-sign.md) 构建。

⚠️ 注意：`build.py` 的 `--profile` 参数是**写死的三个选项**（`yunluo`/`peral`/`xaga`）✗
所以新增机型时要么覆盖 `xaga` 条目（本项目就是这么做的），要么改 `choices`。

## 怎么为新固件做 profile

见 [`tools/README.md`](../tools/README.md) —— 里面是我们实际用过的方法：
**用旧 profile 的指令锚点在新的二进制里重新定位**，而不是从零逆向。

本次实测：一个新固件的 ATF 有 **7 处偏移与上游完全一致**，
LK 有 **10/11 处完全一致（只有 2 处位移 −0x90）** ——
**一两个小时就能搞定**，不是"几天的大工程"。
