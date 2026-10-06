#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify-patch-diff.py —— 不刷机就验证一个 NoGZ 补丁「有没有走样」

原理
----
一个可靠的 NoGZ 补丁，相对于它的基座 tee_a，改动应该是**模式化**的：
改动集中在 profile 里定义的那几个补丁点（ATF 的 getter/callback/pc_patch/... ），
再加上签名带来的天然差异。

所以验证方法是**同构比对**：

    拿「一个已经实机验证可用的补丁」做参照，
    比较它和自己的基座之间的差异区间（数量 / 各区间长度 / 相对位置），
    再看「待验证的补丁」是不是**同一套模式**。

如果两者区间数量、总字节数、长度序列一致 → 说明补丁走的是同一套流程，没走样。

用法
----
    python verify-patch-diff.py \
        --base-a  backup/tee_a.img \
        --patch-a sign-test/tee_nogz_legacy_5M.img \
        --base-b  backup/tee_a_NEWROM_a91f5de.img \
        --patch-b sign-test/tee_nogz_shuilanA15_5M.img

    # 也可以只分析一组：
    python verify-patch-diff.py --base-a <基座> --patch-a <补丁>

依赖：无（纯标准库）
"""
import argparse
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass


def diff_regions(a: bytes, b: bytes, gap_tolerance: int = 16):
    """把两个字节串的差异合并成区间列表。

    相邻差异之间若间隔不超过 gap_tolerance 字节的相同内容，合并为一个区间，
    以免签名/对齐造成的大量零碎区间把统计搅乱。
    """
    n = min(len(a), len(b))
    out = []
    i = 0
    while i < n:
        if a[i] != b[i]:
            start = i
            gap = 0
            while i < n:
                if a[i] != b[i]:
                    gap = 0
                else:
                    gap += 1
                    if gap > gap_tolerance:
                        break
                i += 1
            out.append((start, i - gap))
        else:
            i += 1
    return out


def signature(regions):
    """把区间列表压成一个"指纹"：区间数 + 总字节 + 长度序列"""
    lengths = [e - s for s, e in regions]
    return {
        'count': len(regions),
        'total': sum(lengths),
        'lengths': lengths,
        'span': (regions[0][0], regions[-1][1]) if regions else (0, 0),
    }


def analyze(title: str, base_p: str, patch_p: str):
    print('=' * 74)
    print(f'  {title}')
    print('=' * 74)
    for tag, p in (('基座', base_p), ('补丁', patch_p)):
        if not os.path.exists(p):
            print(f'  ✗ {tag}文件不存在: {p}')
            return None
    base = open(base_p, 'rb').read()
    patch = open(patch_p, 'rb').read()

    print(f'  基座 : {os.path.basename(base_p):<44} {len(base):>9} 字节')
    print(f'  补丁 : {os.path.basename(patch_p):<44} {len(patch):>9} 字节')

    if len(base) != len(patch):
        print(f'  ⚠️ 两者长度不同（差 {len(patch) - len(base)} 字节）—— 正常应该是同尺寸分区镜像')

    regions = diff_regions(base, patch)
    sig = signature(regions)
    print()
    print(f'  差异区间数   : {sig["count"]}')
    print(f'  差异总字节   : {sig["total"]}')
    print(f'  区间跨度     : 0x{sig["span"][0]:x} .. 0x{sig["span"][1]:x}')
    print(f'  区间长度序列 : {sig["lengths"][:14]}{" ..." if len(sig["lengths"]) > 14 else ""}')
    print()
    return sig


def main():
    ap = argparse.ArgumentParser(description='验证 NoGZ 补丁是否与参照补丁同构')
    ap.add_argument('--base-a', metavar='FILE', help='参照组的基座 tee_a')
    ap.add_argument('--patch-a', metavar='FILE', help='参照组的补丁（已实机验证可用）')
    ap.add_argument('--base-b', metavar='FILE', help='待验证组的基座 tee_a')
    ap.add_argument('--patch-b', metavar='FILE', help='待验证组的补丁')
    ap.add_argument('--tolerance', type=int, default=16,
                    help='合并差异区间时的间隔容忍字节数（默认 16）')
    args = ap.parse_args()

    if not args.base_a or not args.patch_a:
        ap.print_help()
        return 1

    global diff_regions
    _orig = diff_regions
    diff_regions = lambda a, b: _orig(a, b, args.tolerance)

    sa = analyze('参照组（已实机验证）', args.base_a, args.patch_a)
    print()
    sb = None
    if args.base_b and args.patch_b:
        sb = analyze('待验证组', args.base_b, args.patch_b)

    if sa and sb:
        print('=' * 74)
        print('  同构判定')
        print('=' * 74)
        same_count = sa['count'] == sb['count']
        same_total = sa['total'] == sb['total']
        same_lengths = sa['lengths'] == sb['lengths']
        print(f'  区间数量一致 : {"✅ 是" if same_count else "❌ 否"}  ({sa["count"]} vs {sb["count"]})')
        print(f'  总字节一致   : {"✅ 是" if same_total else "❌ 否"}  ({sa["total"]} vs {sb["total"]})')
        print(f'  长度序列一致 : {"✅ 是" if same_lengths else "❌ 否"}')
        print()
        if same_count and same_total and same_lengths:
            print('  ✅ 结论：待验证补丁与参照补丁**同构** —— 走的是同一套补丁流程，没有走样。')
            print('     这不能替代实机验证，但可以排除「构建过程出错」这类问题。')
        else:
            print('  ⚠️ 结论：两者**不同构** —— 值得人工检查构建流程或 profile 偏移是否正确。')
    print()
    return 0


if __name__ == '__main__':
    sys.exit(main())
