import socket
import struct
import sys

sys.stdout.reconfigure(encoding='utf-8')
from PIL import Image

HOST, PORT = '127.0.0.1', 5900


def recvall(s, n):
    buf = b''
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError('closed')
        buf += c
    return buf


s = socket.create_connection((HOST, PORT), timeout=30)
ver = recvall(s, 12)
print('server version:', ver)
s.sendall(b'RFB 003.008\n')

n = recvall(s, 1)[0]
types = list(recvall(s, n))
print('security types:', types)
if 1 not in types:
    print('no None auth; types =', types)
    sys.exit(1)
s.sendall(bytes([1]))
res = struct.unpack('>I', recvall(s, 4))[0]
print('security result:', res)
if res != 0:
    sys.exit(1)

s.sendall(bytes([1]))            # ClientInit, shared
w, h = struct.unpack('>HH', recvall(s, 4))
pf = recvall(s, 16)
namelen = struct.unpack('>I', recvall(s, 4))[0]
name = recvall(s, namelen).decode('latin-1', 'replace')
print('framebuffer: %dx%d  name=%r' % (w, h, name))

# SetPixelFormat: 32bpp, depth 24, little-endian, true colour, RGB shifts 16/8/0
pf_req = bytes([0]) + b'\x00' * 3 + struct.pack('>BBBBHHHBBBxxx',
                                                 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
s.sendall(pf_req)
# SetEncodings: Raw(0), DesktopSize(-223) optional
s.sendall(struct.pack('>BBH', 2, 0, 1) + struct.pack('>i', 0))

frames = 0
for attempt in range(6):
    s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
    hdr = recvall(s, 4)
    msg_type, pad, nrects = hdr[0], hdr[1], struct.unpack('>H', hdr[2:4])[0]
    if msg_type != 0:
        print('msg type', msg_type, 'skipped')
        continue
    canvas = Image.new('RGB', (w, h), (0, 0, 0))
    px = canvas.load()
    got = 0
    for _ in range(nrects):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', recvall(s, 12))
        if enc != 0:
            print('non-raw encoding', enc)
            break
        data = recvall(s, rw * rh * 4)
        got += rw * rh
        for row in range(rh):
            base = row * rw * 4
            for col in range(rw):
                o = base + col * 4
                b = data[o]
                g = data[o + 1]
                r = data[o + 2]
                px[x + col, y + row] = (r, g, b)
    print('rects=%d pixels=%d' % (nrects, got))
    px_check = canvas.getcolors(maxcolors=1 << 24)
    print('  颜色数 =', len(px_check), ' 最多的3种:', sorted(px_check, reverse=True)[:3])
    canvas.save(r'C:/Users/citie/xaga-kvm/vnc-%d.png' % attempt)
    frames += 1
    if len(px_check) > 60:      # 有明显内容就再多抓两帧
        continue
    if attempt >= 1:
        break

s.close()
print('saved %d frames as vnc-N.png' % frames)
