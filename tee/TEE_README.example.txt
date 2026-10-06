════════════════════════════════════════════════════════════════════
 这堆 tee 镜像 —— 刷之前务必看这里！
════════════════════════════════════════════════════════════════════

【本机的 tee 基座现状】
  tee_a = a91f5deda942a167892938f62de3024ab7b677267ae7cf34b7f1e642e02500d7
  tee_b = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
  → 本机是「a91f5ded 基座」，只能刷针对这个基座构建的补丁

【文件清单 —— 哪个能刷】

  ⚠️ 带 DO_NOT_FLASH 前缀的是别人的基座 —— 能启动但非首选；见下面说明
  ─────────────────────────────────────────────────────────────
  FLASH_THIS_shuilan_patch_for_this_phone.img        17ec849749febda6...
      → 为本机构建的 NoGZ 补丁（离线 14/14 + 签名 VALID）
      → 结构已与验证可用的 rk 补丁比对一致（差异区间 175 个 / 2953488 字节，完全同构）
      → 刷它能开启 KVM（/dev/kvm 出现）
      → 恢复：fastboot flash tee_a tee_a_backup.img

  ❌ DO_NOT_FLASH_rk_patch_wrong_base.img   ← 原 tee_patched.img
  ❌ DO_NOT_FLASH_rk_patch_copy.img         ← 原 tee_nogz_new 之外的任何 f1511dca 前缀文件
      → 这俩是 f1511dcad9820397... （备用机那台的补丁）
      → ⚠️ 基座是 f8f286f1 的，与本机不同
         注：2026-10-07 实测证明【跨基座也能启动】，只是会先卡 1~2 分钟；
         但仍建议优先用同基座的补丁（更保守）
      → 只适合 tee_b=f8f286f1 且 tee_a 未更新的设备

  ─────────────────────────────────────────────────────────────
  tee_a_backup.img        a91f5deda942a167...  ← 本机原厂 tee_a，出事的后悔药
  tee_b_main.img          f8f286f138e758a5...  ← 本机 tee_b（全程未动）
  tee_newrom.img          a91f5deda942a167...  ← 同上（刷 ROM 后存的）
  tee_a_main_now.img      a91f5deda942a167...  ← 同上（工具 dump 的）

【判断一个 img 能不能刷 —— 只比一个哈希】

  # 看文件是什么
  sha256sum /data/local/tmp/xxx.img

  # 看本机基座
  dd if=/dev/block/by-name/tee_b bs=4096 2>/dev/null | sha256sum

  文件哈希 == 17ec8497...  → 刷（本机适用）
  文件哈希 == f1511dca...  → ⚠️ 不是本机的基座；能启动（实测过），但优先用同基座的
  文件哈希 == a91f5ded...  → 这是原厂备份，不是补丁，刷了没意义（但也不会坏）

【卡二了怎么办】

  1. 黑屏/转圈时：长按「音量下 + 电源」进 fastboot
  2. PC 上执行：
       fastboot flash tee_a /path/to/tee_a_backup.img
       fastboot reboot
  3. 大约 40 秒后恢复。全程只动 tee_a，数据不丢。

════════════════════════════════════════════════════════════════════
