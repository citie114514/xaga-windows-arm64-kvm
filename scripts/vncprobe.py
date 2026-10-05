"""VNC 吞吐探针：协商 Tight/JPEG 编码，统计单位时间内能拉多少画面数据。
用来对比 lossy=on 前后的实际传输效率（不需要解码，只数字节）。"""
import socket, struct, sys, time
sys.stdout.reconfigure(encoding='utf-8')

HOST, PORT = '127.0.0.1', 5900
SECONDS = 12


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
s.sendall(b'RFB 003.008\n')
n = recvall(s, 1)[0]
types = list(recvall(s, n))
print('RFB %s  security=%s' % (ver.decode().strip(), types))
s.sendall(bytes([1]))
assert struct.unpack('>I', recvall(s, 4))[0] == 0
s.sendall(bytes([1]))
w, h = struct.unpack('>HH', recvall(s, 4))
recvall(s, 16)
nlen = struct.unpack('>I', recvall(s, 4))[0]
name = recvall(s, nlen).decode('utf-8', 'replace')
print('framebuffer %dx%d  name=%r' % (w, h, name))
print('数据量（未压缩）= %.2f MB/帧' % (w * h * 4 / 1048576))

# 像 TightVNC 一样协商编码：Tight(7)=JPEG、ZRLE(16)、Hextile(5)、Raw(0)
enc = struct.pack('>BBHiiii', 2, 0, 4, 7, 16, 5, 0)
s.sendall(enc)
print('已协商编码 Tight(7) / ZRLE(16) / Hextile(5) / Raw(0)')

s.settimeout(1.0)
total = 0
frames_started = 0
t0 = time.time()
last_req = 0
while time.time() - t0 < SECONDS:
    # 每秒发一次"全刷"请求，逼服务器重编码整屏
    if time.time() - last_req > 1.0:
        s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
        last_req = time.time()
    try:
        chunk = s.recv(262144)
        if not chunk:
            break
        total += len(chunk)
    except socket.timeout:
        continue
    except Exception as e:
        print('recv error:', e)
        break

dt = time.time() - t0
print()
print('=== 结果 ===')
print('  测试时长      : %.1f 秒' % dt)
print('  收到数据      : %.2f MB' % (total / 1048576))
print('  平均吞吐      : %.2f MB/s' % (total / 1048576 / dt))
if total:
    print('  等效每帧成本  : %.2f MB/帧（对比未压缩 %.2f MB）'
          % (total / 1048576 / max(1, int(dt)), w * h * 4 / 1048576))
s.close()
