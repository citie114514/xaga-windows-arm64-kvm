# 手机端脚本

推到手机 ` /data/local/tmp/` 下运行。**全部需要 root。**

| 脚本 | 作用 | 实测 |
|---|---|---|
| [`boot-win.sh`](boot-win.sh) | 启动 QEMU + KVM（**锁定 VNC 5900**，磁盘缺失时给友好提示） | ✅ |
| [`stop-vm.sh`](stop-vm.sh) | 安全停止（短进程名匹配，不会 `pkill -f` 把自己杀掉） | ✅ |
| [`restore-disk.sh`](restore-disk.sh) | 把备份的虚拟磁盘放回 `win.vhdx`（识别格式 / 查空间 / 校验 sha256） | ✅ |
| [`qemu-wrapper.sh`](qemu-wrapper.sh) | **可选**：替换 DroidVM 的 QEMU，让它自己建的配置也能跑 | ✅ |

## 安装

```bash
adb push scripts/phone/boot-win.sh scripts/phone/stop-vm.sh scripts/phone/restore-disk.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/*.sh'
```

---

# 两条启动路线 —— **选一条，不要混着用**

## 路线 A：命令行直接启动（**推荐**）

```bash
adb shell su -c 'sh /data/local/tmp/boot-win.sh'
adb forward tcp:5900 tcp:5900
# VNC 客户端连 127.0.0.1:5900
```

| 优点 | 缺点 |
|---|---|
| 参数**完全可控**；端口**固定 5900**；不看 DroidVM 脸色 | 没有图形界面，改参数要编辑脚本 |

**这条路完全绕开 DroidVM 的配置管理** —— 它不读 `vms.json`，也不会被应用重写。

## 路线 B：让 DroidVM 应用自己也能启动（可选）

DroidVM 应用**自己生成的配置是跑不起来的**：它没给 virtio 网卡挂
`-netdev` 后端（客机没网）、也没加 `virtio-balloon`（内存只涨不跌）。

装一个**包装脚本**就能补齐 —— 把应用调用的 `qemu-system-aarch64` 换成一层
wrapper，转发给真正的 `.real`：

```bash
# 1) 先把原二进制改名（只做一次）
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 [ -f qemu-system-aarch64.real ] || mv qemu-system-aarch64 qemu-system-aarch64.real'

# 2) 拷入 wrapper
adb push scripts/phone/qemu-wrapper.sh /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/qemu-wrapper.sh /data/data/cn.classfun.droidvm/usr/bin/qemu-system-aarch64'

# 3) 权限和属主要和 .real 保持一致
adb shell su -c 'cd /data/data/cn.classfun.droidvm/usr/bin && \
                 chmod 755 qemu-system-aarch64 && \
                 chown $(stat -c %u qemu-system-aarch64.real):$(stat -c %g qemu-system-aarch64.real) qemu-system-aarch64 && \
                 ls -l qemu-system-aarch64*'
```

它做三件事，而且**只在"调用方没给"时才补**，所以不会干扰路线 A：

```
1) 把完整参数记到 /data/local/tmp/qemu-args.log   ← 排错时非常有用
2) 缺 -netdev user 就补上（id 用 auto0，避免和调用方撞车）
   缺 virtio-balloon-pci 就补上
3) 用 taskset f0 绑 A78 簇 —— 避开 big.LITTLE 迁移导致的 KVM 竞态
```

**回退**：把 `.real` 改回原名即可。

---

# ⚠️ DroidVM 应用的三个坑

## 1. VNC 端口默认是**随机的**

`vms.json` 里 `screens.*.vnc.port` 的默认值是 **`-1`**，意思是"自动挑一个"：

```json
"vnc": { "host": "127.0.0.1", "port": -1, "password": "", "password_auth": false }
```

**后果**：每次启动端口可能都不同 ✗ —— 你 `adb forward tcp:5900` 转发的端口
根本没人在听 ✗。这是「虚拟机明明起来了却连不上」的常见原因。

- **本项目的做法**：路线 A 直接写死 `-vnc 127.0.0.1:0`（= 5900），启动后再核对一次
- 改 `port` 字段理论上是另一条路，但**未实测**，而且有下面第 3 条的风险，**不推荐**

## 2. 应用建的配置本身就不全

见上面「路线 B」——缺 `-netdev` 和 balloon，靠 wrapper 补。

## 3. 手改 `vms.json` 会让应用读不出来

**症状**：手改了 `vms.json`（比如换磁盘路径），VM 在应用里**直接消失**，
提示"当前版本读取不了"。

**原因**：DroidVM 用自己严格的 schema 校验，**不认识手加的字段**，就把整个条目剔除。

**解决**
- **只改它已有的字段**（如 `disks[].path`、`screens.*.exporter`），**不要新增字段**
- 改完保留原属主和权限：
  ```bash
  OWN=$(stat -c %u vms.json); GRP=$(stat -c %g vms.json); MODE=$(stat -c %a vms.json)
  # ... 改 ...
  chown $OWN:$GRP vms.json; chmod $MODE vms.json
  ```
- **改之前先备份**：`cp vms.json vms.json.bak`

> 更多坑见 [docs/05-gotchas.md](../../docs/05-gotchas.md)（第 2、9 条）。
