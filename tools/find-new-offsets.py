"""为新固件定位补丁偏移：用旧 profile 的锚点在新 ATF 里搜索对应位置。
旧 profile: profiles.xagapro.json  (备用机原厂固件)
新固件    : backup/tee_a_NEWROM_a91f5de.img  (主力机 ROM)
"""
import json, sys, hashlib, struct
sys.stdout.reconfigure(encoding='utf-8')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

OLD_TEE = 'C:/Users/citie/xaga-kvm/backup/tee_a.img'
NEW_TEE = 'C:/Users/citie/xaga-kvm/backup/tee_a_NEWROM_a91f5de.img'
PROF    = 'C:/Users/citie/xaga-kvm/profiles.xagapro.json'
ATF_OFF, ATF_LEN = 0x200, 283016
BASE = 0x48200000          # mblock-15-BL31-reserved 基址

def load(path):
    return open(path, 'rb').read()[ATF_OFF:ATF_OFF + ATF_LEN]

old, new = load(OLD_TEE), load(NEW_TEE)
prof = json.load(open(PROF, encoding='utf-8'))['xagapro']

print('旧 ATF %d 字节  sha256 %s' % (len(old), hashlib.sha256(old).hexdigest()[:24]))
print('新 ATF %d 字节  sha256 %s' % (len(new), hashlib.sha256(new).hexdigest()[:24]))
print()

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = False

# ---------- 1) 用 profile 里的指令锚点搜索 ----------
print('=' * 70)
print('1) 指令锚点搜索')
print('=' * 70)
for key in ('getter_before',):
    for v in prof[key]:
        pat = v.to_bytes(4, 'little')
        old_loc = old.find(pat)
        hits = []
        i = 0
        while True:
            i = new.find(pat, i)
            if i < 0:
                break
            hits.append(i)
            i += 1
        print('  %-14s = 0x%08X' % (key, v))
        print('    旧 ATF 命中: %s' % (hex(old_loc) if old_loc >= 0 else '无'))
        print('    新 ATF 命中: %d 处 %s' % (len(hits), [hex(x) for x in hits[:10]]))
print()

# ---------- 2) 用旧 profile 各偏移处的指令字节去新 ATF 里找 ----------
print('=' * 70)
print('2) 用旧 profile 各偏移处的 16 字节指令序列做指纹搜索')
print('=' * 70)
FIELDS = ['pc_patch', 'kernel_patch', 'getter', 'callback', 'flag',
          'cold', 'cold_helpers', 'kernel', 'ep', 'kernel_args',
          'tag_parser', 'args_getter', 'handoff_global',
          'lk_parser', 'lk_getter', 'lk_callback', 'lk_gate', 'lk_skip',
          'lk_stack', 'lk_elcheck', 'lk_illegal']
for f in FIELDS:
    v = prof[f]
    vals = v if isinstance(v, list) else [v]
    for n, off in enumerate(vals):
        fp = old[off:off + 16]
        if len(fp) < 16:
            print('  %-14s[%d] @0x%06X  越界' % (f, n, off)); continue
        # 在新 ATF 里找同样的 16 字节
        locs = []
        i = 0
        while True:
            i = new.find(fp, i)
            if i < 0:
                break
            locs.append(i)
            i += 1
        mark = '★' if locs else ' '
        print('  %s %-14s[%d] 旧@0x%06X  新命中 %d 处 %s'
              % (mark, f, n, off, len(locs), [hex(x) for x in locs[:4]]))
print()

# ---------- 3) 看两个 ATF 的整体相似度分布 ----------
print('=' * 70)
print('3) 相似度分布（每 4KB 块）')
print('=' * 70)
BLK = 0x1000
rows = []
for i in range(0, len(old) - BLK, BLK):
    a, b = old[i:i + BLK], new[i:i + BLK]
    same = sum(1 for x, y in zip(a, b) if x == y)
    rows.append((i, same * 100.0 / BLK))
hi = [r for r in rows if r[1] > 90]
mid = [r for r in rows if 50 < r[1] <= 90]
lo = [r for r in rows if r[1] <= 50]
print('  高相似(>90%%)块: %d 个' % len(hi))
print('  中相似(50-90%%): %d 个' % len(mid))
print('  低相似(<=50%%):  %d 个' % len(lo))
print('  高相似块地址(前20): %s' % [hex(r[0]) for r in hi[:20]])
