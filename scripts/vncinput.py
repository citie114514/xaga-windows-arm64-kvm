"""连上 VM 的 VNC，发一次按键，然后抓帧对比 —— 判断客机 UI 是否还活着。"""
import socket, struct, sys, time
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


def connect():
    s = socket.create_connection((HOST, PORT), timeout=30)
    recvall(s, 12)
    s.sendall(b'RFB 003.008\n')
    n = recvall(s, 1)[0]
    types = list(recvall(s, n))
    if 1 not in types:
        raise SystemExit('no None auth')
    s.sendall(bytes([1]))
    if struct.unpack('>I', recvall(s, 4))[0] != 0:
        raise SystemExit('auth failed')
    s.sendall(bytes([1]))
    w, h = struct.unpack('>HH', recvall(s, 4))
    recvall(s, 16)                 # pixel format
    nlen = struct.unpack('>I', recvall(s, 4))[0]
    name = recvall(s, nlen).decode('utf-8', 'replace')
    return s, w, h, name


def grab(s, handle_messages=True):
    s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, 0, 0))   # full update
    while True:
        t = recvall(s, 1)[0]
        if t == 0:                                          # FramebufferUpdate
            recvall(s, 1)
            n = struct.unpack('>H', recvall(s, 2))[0]
            for _ in range(n):
                x, y, w, h, enc = struct.unpack('>HHHHi', recvall(s, 12))
                if enc == 0:
                    recvall(s, w * h * 4)
                elif enc == -223:
                    recvall(s, 4); recvall(s, recvall(s, 6)[4:6][0], )
                else:
                    ln = struct.unpack('>I', recvall(s, 4))[0]
                    recvall(s, ln)
            s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, 0, 0))
            continue
        if t == 1:                                          # SetColourMapEntries
            recvall(s, 3)
            n = struct.unpack('>H', recvall(s, 2))[0]
            recvall(s, n * 6)
            continue
        if t == 2:                                          # Bell
            continue
        if t == 3:                                          # ServerCutText
            recvall(s, 3)
            ln = struct.unpack('>I', recvall(s, 4))[0]
            recvall(s, ln)
            continue
        raise SystemExit('unknown msg %d' % t)


def key(s, keysym, down):
    s.sendall(struct.pack('>BBHI', 4, 1 if down else 0, 0, keysym))


def tap(s, keysym):
    key(s, keysym, True); time.sleep(0.05); key(s, keysym, False); time.sleep(0.4)


def stats(s, w, h):
    """抓一帧，返回 (颜色数, 白像素数)"""
    s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, 0, 1))     # incremental
    data = None
    while data is None:
        t = recvall(s, 1)[0]
        if t == 0:
            recvall(s, 1)
            n = struct.unpack('>H', recvall(s, 2))[0]
            for _ in range(n):
                x, y, rw, rh, enc = struct.unpack('>HHHHi', recvall(s, 12))
                if enc == 0:
                    data = (x, y, rw, rh, recvall(s, rw * rh * 4))
                else:
                    raise SystemExit('unexpected enc %d' % enc)
        elif t == 1:
            recvall(s, 3); n = struct.unpack('>H', recvall(s, 2))[0]; recvall(s, n * 6)
        elif t == 2:
            pass
        elif t == 3:
            recvall(s, 3); ln = struct.unpack('>I', recvall(s, 4))[0]; recvall(s, ln)
    x, y, rw, rh, px = data
    img = Image.frombytes('RGBA', (rw, rh), px)
    img = img.convert('RGB')
    cols = img.getcolors(maxcolors=1 << 20) or []
    white = sum(c for c, col in cols if col == (255, 255, 255))
    return len(cols), white, img


if __name__ == '__main__':
    s, w, h, name = connect()
    print('connected: %dx%d  name=%r' % (w, h, name))
    n0, w0, _ = stats(s, w, h)
    print('按键前 : 颜色数=%d 白像素=%d' % (n0, w0))

    print('发送 Esc ...')
    tap(s, 0xFF1B)
    time.sleep(2)
    n1, w1, _ = stats(s, w, h)
    print('Esc 后 : 颜色数=%d 白像素=%d' % (n1, w1))

    print('发送 Enter ...')
    tap(s, 0xFF0D)
    time.sleep(2)
    n2, w2, img = stats(s, w, h)
    print('Enter后: 颜色数=%d 白像素=%d' % (n2, w2))
    img.save('vnc-after-key.png')

    changed = (n0, w0) != (n1, w1) or (n1, w1) != (n2, w2)
    print()
    print('画面有变化吗 :', '是 ✓ 客机 UI 活着' if changed else '否 ✗ 客机没在刷新画面')
    s.close()
