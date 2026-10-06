"""定位新固件的 getter / callback 区域（补丁核心）。"""
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

OLD = 'C:/Users/citie/xaga-kvm/backup/tee_a.img'
NEW = 'C:/Users/citie/xaga-kvm/backup/tee_a_NEWROM_a91f5de.img'
PROF = 'C:/Users/citie/xaga-kvm/profiles.xagapro.json'
UPST = 'C:/Users/citie/AppData/Local/Temp/teefix/references/profiles.json'
OFF, LEN = 0x200, 283016

old = open(OLD, 'rb').read()[OFF:OFF+LEN]
new = open(NEW, 'rb').read()[OFF:OFF+LEN]
ours = json.load(open(PROF, encoding='utf-8'))['xagapro']
up   = json.load(open(UPST, encoding='utf-8'))['xaga']

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

def dis(blob, start, n=14, base=0):
    out = []
    for i in md.disasm(blob[start:start+n*4], base+start):
        out.append('    %06X  %-8s %s' % (i.address, i.mnemonic, i.op_str))
    return '\n'.join(out)

print('='*72)
print('A) 旧 getter 区域（profile: getter=0x%X, getter_before=%s）'
      % (ours['getter'], [hex(x) for x in ours['getter_before']]))
print('='*72)
g = ours['getter']
print(dis(old, g-24, 18))

print()
print('='*72)
print('B) 上游 xaga 的 getter 区域（getter=0x%X）' % int(up['getter'],16))
print('='*72)
gu = int(up['getter'], 16)
print(dis(old, gu-24, 18))

print()
print('='*72)
print('C) 新固件里 0xD00001A8 的 17 个命中点 —— 逐个看上下文')
print('='*72)
pat = (0xD00001A8).to_bytes(4, 'little')
hits = []
i = 0
while True:
    i = new.find(pat, i)
    if i < 0: break
    hits.append(i); i += 1
for h in hits[:6]:
    print('  --- 命中 @ 0x%06X ---' % h)
    print(dis(new, max(0, h-16), 10))

print()
print('='*72)
print('D) 新固件里搜上游 getter 的 16 字节指纹')
print('='*72)
for src_name, blob, off in (('上游xaga', old, gu), ('我们xagapro', old, g)):
    fp = blob[off:off+24]
    locs = []
    i = 0
    while True:
        i = new.find(fp, i)
        if i < 0: break
        locs.append(i); i += 1
    print('  %s @0x%06X → 新固件命中 %d 处 %s' % (src_name, off, len(locs), [hex(x) for x in locs[:5]]))
    # 缩短到 12 字节再试
    fp2 = blob[off:off+12]
    locs2 = []
    i = 0
    while True:
        i = new.find(fp2, i)
        if i < 0: break
        locs2.append(i); i += 1
    print('      缩到 12 字节 → 命中 %d 处 %s' % (len(locs2), [hex(x) for x in locs2[:8]]))
