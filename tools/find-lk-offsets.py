"""为我们的新 LK 定位剩余偏移：反汇编旧 LK 的缺失字段区域，在新 LK 里找等价代码。"""
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

OLD = 'C:/Users/citie/xaga-kvm/backup/lk_a.img'
NEW = 'C:/Users/citie/xaga-kvm/dump-newrom/lk_a.img'
PROF = 'C:/Users/citie/xaga-kvm/profiles.xagapro.json'
LK_BASE = 0x50f00000

old = open(OLD, 'rb').read()
new = open(NEW, 'rb').read()
p = json.load(open(PROF, encoding='utf-8'))['xagapro']

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

def dis(blob, off, n=16):
    out = []
    for i in md.disasm(blob[off:off+n*4], LK_BASE + off):
        out.append('    %08X  %-9s %s' % (i.address, i.mnemonic, i.op_str))
    return '\n'.join(out)

TARGETS = [
    ('lk_gate',     0x28D4),
    ('lk_skip',     0x2904),
    ('lk_elcheck0', 0x39C8),
    ('lk_elcheck1', 0x3A6C),
    ('lk_stack1',   0x1A7CC),
    ('lk_getter',   0x1E8A8),
    ('lk_callback', 0x1E8BC),
]

for name, off in TARGETS:
    print('=' * 74)
    print('%s  旧偏移 0x%X  (VA 0x%08X)' % (name, off, LK_BASE + off))
    print('=' * 74)
    print('--- 旧 LK 该处反汇编 ---')
    print(dis(old, max(0, off - 16), 18))

    # 用该处前后共 32 字节做指纹，在新 LK 里找
    fp = old[off:off + 32]
    locs = []
    i = 0
    while True:
        i = new.find(fp, i)
        if i < 0:
            break
        locs.append(i)
        i += 1
    print('--- 32B 指纹在新 LK 命中: %d 处 %s' % (len(locs), [hex(x) for x in locs[:6]]))
    if not locs:
        # 逐级缩短
        for L in (24, 20, 16, 12):
            f2 = old[off:off + L]
            l2 = []
            j = 0
            while True:
                j = new.find(f2, j)
                if j < 0:
                    break
                l2.append(j)
                j += 1
            print('    %dB 指纹 → %d 处 %s' % (L, len(l2), [hex(x) for x in l2[:6]]))
            if l2:
                print('    ↳ 新 LK 该处反汇编:')
                print(dis(new, max(0, l2[0] - 16), 18))
                break
    else:
        print('    ↳ 新 LK 该处反汇编:')
        print(dis(new, max(0, locs[0] - 16), 18))
    print()
