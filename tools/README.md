# 为新固件定位 profile 的工具

给已有 profile、但换了固件批次的设备**重新定位偏移**用的。
方法核心：**不移位硬猜，而是用旧 profile 已知位置处的"指令骨架"去新二进制里搜**。

## 脚本

| 脚本 | 作用 |
|---|---|
| `find-new-offsets.py` | 用旧 profile 各字段处 16 字节指令序列做指纹，在**新 ATF** 里搜；并输出两版 ATF 的逐块相似度分布 |
| `find-getter.py` | 反汇编旧/新 ATF 的 getter 区域，逐个看 `0xD00001A8` 这类锚点的上下文 |
| `match-lk2.py` | **主力工具**：把 LK 线性反汇编一次，把 `bl`/`adrp` 等 PC 相对操作数**归一化**成占位符，再滑窗比较指令骨架。避开了"函数一移动、`bl` 编码就变、字节指纹全失效"的坑 |
| `find-lk-offsets.py` | 早期版本（逐字节指纹），保留作对照 —— 它失败的原因很有教学意义 |

## 实战流程（本次就是这样做的，约 1~2 小时）

```
1) 从设备 dump 新固件：tee_a / lk_a / preloader_raw_a
2) 抽出 tee 里的 ATF 成员（偏移 0x200，长 283016）
3) 跑 find-new-offsets.py：
     旧 profile 的每个字段 → 在新 ATF 里搜 16 字节指纹
     命中且偏移相近（±0x100）→ 直接采用
4) 跑 match-lk2.py：定位全部 lk_* 偏移
5) 把结果写成新 profile，哈希换成新的，合并进 profiles.json
6) 跑 build.py --check-only → 要求 14/14 全过
7) 再跑完整构建（--preloader + --tools）→ 验签要 2 × Result: VALID
```

## 本次的实际数据（Redmi Note 11T Pro+，两批固件）

**ATF**：新固件与上游 `xaga` 偏移**完全一致**（7 处精确命中）——
虽然两个 ATF 逐字节只有 **29.5% 相同**（说明是不同构建，但**函数布局相同**）。

**LK**：逐字节 **83.86% 相同**；11 个字段里

```
9 个偏移完全不变   0x28D4 / 0x2904 / 0x39C8 / 0x3A6C / 0x1A7A0 / 0x1A7CC / 0x3A18 / 0x14CAC / 0x14D40
2 个位移 −0x90     lk_getter 0x1E8A8 → 0x1E818
                   lk_callback 0x1E8BC → 0x1E82C
```

## 需要装的依赖

```bash
python -m venv .venv
.venv/Scripts/python.exe -m pip install capstone unicorn
```

## 踩过的坑

| 坑 | 说明 |
|---|---|
| **字节指纹在 LK 上全失效** | `bl`/`adrp` 是 PC 相对寻址，函数一移动编码就变 → 必须**归一化指令骨架**再比（`match-lk2.py` 就是干这个的） |
| **`md.skipdata = True` 必须加** | LK 文件开头是头部不是代码，Capstone 不加这个会立刻停下（只反汇编出 1 条指令 ✗） |
| **profile 的值必须是字符串** | `build.py` 里 `int(v, 0) if v.startswith("0x")` → 写成整数会 `AttributeError` ✗ |
| **上游 `sign_all_flag` bug** | `build.py` 会给 `sign_mtk_cert.py` 传 `--all`，但那脚本没这个参数 → 必须让 `sign_all_flag()` 返回 `[]`（见 [issues/](../issues/)） |
