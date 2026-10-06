"""归一化指令序列匹配 v2：先线性反汇编，再滑窗比较（快得多）"""
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

OLD = 'C:/Users/citie/xaga-kvm/backup/lk_a.img'
NEW = 'C:/Users/citie/xaga-kvm/dump-newrom/lk_a.img'
PROF = 'C:/Users/citie/xaga-kvm/profiles.xagapro.json'

old = open(OLD, 'rb').read()
new = open(NEW, 'rb').read()
p = json.load(open(PROF, encoding='utf-8'))['xagapro']
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.skipdata = True

BRANCH = re.compile(r'^(b|bl|cbz|cbnz|tbz|tbnz)(\.\w+)?$')
PCREL  = re.compile(r'^(adrp|adr)$')

def norm(m, o):
    if BRANCH.match(m):
        return m + ' <t>'
    if PCREL.match(m):
        return m + ' ' + re.sub(r'#0x[0-9a-f]+', '<imm>', o)
    return m + (' ' + o if o else '')

def linear(blob):
    """线性反汇编成 {文件偏移: 归一化文本}，同时保留顺序"""
    arr = {}
    for i in md.disasm(blob, 0):
        arr[i.address] = norm(i.mnemonic, i.op_str)
    return arr

print('反汇编旧 LK ...')
A = linear(old)
print('  得到 %d 条指令' % len(A))
print('反汇编新 LK ...')
B = linear(new)
print('  得到 %d 条指令' % len(B))

def pat_at(arr, off, n=16):
    out = []
    for k in range(n):
        a = off + k * 4
        if a not in arr:
            return None
        out.append(arr[a])
    return out

TARGETS = [('lk_gate', 0x28D4), ('lk_skip', 0x2904),
           ('lk_elcheck0', 0x39C8), ('lk_elcheck1', 0x3A6C),
           ('lk_stack1', 0x1A7CC), ('lk_getter', 0x1E8A8),
           ('lk_callback', 0x1E8BC), ('lk_parser0', 0x14CAC),
           ('lk_parser1', 0x14D40), ('lk_stack0', 0x1A7A0),
           ('lk_illegal', 0x3A18)]

print()
print('%-14s %-9s %-9s %s' % ('字段', '旧偏移', '新偏移', '得分'))
print('-' * 62)
found = {}
for name, off in TARGETS:
    pat = pat_at(A, off, 16)
    if not pat:
        print('%-14s 0x%06X   (旧侧反汇编失败)' % (name, off))
        continue
    best, bo = -1, None
    lo, hi = max(0, off - 0x8000), min(len(new) - 64, off + 0x8000)
    for cand in range(lo, hi, 4):
        sc = 0
        for k in range(16):
            if B.get(cand + k * 4) == pat[k]:
                sc += 1
            else:
                break
        if sc > best:
            best, bo = sc, cand
            if sc == 16:
                break
    found[name] = (off, bo, best)
    print('%-14s 0x%06X  0x%06X  %2d/16 %s'
          % (name, off, bo or 0, best, '★' if best == 16 else ''))

print()
print('=== 汇总：新 LK 偏移建议 ===')
for n, (o, x, sc) in found.items():
    if sc >= 12:
        print('  %-14s 0x%06X → 0x%06X  (%d/16)' % (n, o, x, sc))
    else:
        print('  %-14s 0x%06X → 未可靠定位 (%d/16)' % (n, o, sc))
