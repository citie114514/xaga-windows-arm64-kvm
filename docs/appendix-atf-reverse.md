# preloader_raw_a.img 逆向结论

文件：`D:\Administrator\下载\preloader_raw_a.img`
大小：4 190 208 字节（0x3FF000）
sha256：`056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1`

## 0. 最重要的结论（先说）

**这份文件与手机当前正在运行的 preloader 逐字节相同。**
（设备 `preloader_raw_a` 分区 dump 的 sha256 也是 `056ed47a…`）

→ 把它刷进去**不会改变任何东西**。如果它真是"免授权工程版"，
   那这台机器**现在已经在跑它了**。

## 1. 容器结构

```
0x0000  MMM\x01  len=0x38  "FILE_INFO"
0x0038  MMM\x01  len=0x0C  type=1  val=1
0x0044  MMM\x01  len=0x64  type=7  val=0x90
0x00A8  MMM\x01  len=0x14  type=2  val=0
0x00BC  MMM\x01  len=0x30  type=8  val=0
0x00F0  ← 代码开始
```
头部字段（`parse_hdr`）：
```
load = 0x02000F10   size = 0x0007A0B0   header = 0xF0   ida = 0xF0
运行时基址 base = 0x02001000，代码 0xF0 .. 0x7A1A0
镜像之后的 0x384E60 字节全是 0x00 填充
```

## 2. SBC（Secure Boot Control）的来源 —— 决定性证据

```
0x020522FC  push   {r7, lr}
0x020522FE  mov    r7, sp
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; efuse 读取
0x02052306  ubfx   r0, r0, #1, #1     ; 取 bit 1
0x0205230A  pop    {r7, pc}
```

**SBC 是运行时从 eFuse 读出来的**（word 0x1F 的 bit 1）。
eFuse 是 OTP，一次性烧写，**改 preloader 无法改变它**。

## 3. 校验逻辑是"条件执行"，不是"被旁路"

调用方（0x0204FA0E）：
```
0x0204FA14  bl     #0x020522FC        ; r0 = sbc_en
0x0204FA18  mov    r1, r0
0x0204FA1A  movw   r0, #0x7528        ; "sbc_en = %d"
0x0204FA22  bl     #0x02045C74        ; 打印 sbc_en
0x0204FA26  bl     #0x020522FC        ; 再读一次
0x0204FA2A  cbz    r0, #0x0204FA5C    ; sbc_en == 0 → 直接跳过校验
0x0204FA2C  movw   r0, #0x7535        ; "sbc_en = 1"
0x0204FA34  bl     #0x02045C74        ; 打印
...                                    ; 继续走证书链校验
```

这是**正常的零售逻辑**：SBC 没烧的机器就免校验，烧了的就校验。
没有任何 `movs r0,#0` / `bx lr` 之类的硬编码旁路。

## 4. 证书链 / 镜像校验代码完整存在

```
0x020407F0  ...  img_auth 主逻辑
   0x0204083C  ldr r0, [pc,#...]  → "img_auth_required = %x"
   0x020408D2  →                  "cert chain vfy fail..."
   0x020408F0  bl #0x0200E368     ; 真正的校验入口（返回 0 = 通过）
   0x0204086E  mov.w r8, #-1      ; 失败返回值

0x0204E888  img auth fail 路径 → "img auth fail(0x%x)"
0x0204FE22  0x020676AD → "seclib_img_auth_load_sig"
```
另外镜像里包含 MTK 的证书 OID 与算法：
```
2.16.886.2454.1.1 / .1.2 / .1.3 / .2.1 ... .3.2   ; 2.16.886 = TW, 2454 = MediaTek
1.2.840.113549.1.1.1   ; rsaEncryption
1.2.840.113549.1.1.10  ; RSASSA-PSS
V.Mon May 30 17:26:17 2022   ; 证书库版本串
```

## 5. DA 校验（usbdl_verify_da）也完整、无短路

函数 `0x0201144C`，内部有：
- DA 长度检查（`da_len < sig_len` 的错误打印）
- 对 DA 类型字节的跳表分发（`sub.w r1, r0, #0xC4; cmp r1, #0x23; tbh [pc, r1, lsl #1]`）
- 特殊值 `0xFE` 分支
- 失败返回 `#-1` 等

**没有"直接返回成功"的短路分支。**

## 6. 构建来源

字符串里的源码路径：
```
/home/work/mnt/miui_codes2/build_home_rom-vext-merged/vendor/mediatek/
  proprietary/bootable/bootloader/preloader/platform/mt6895/src/...
```
构造时间戳：`20230918-112001`（2023-09-18 11:20:01）

→ 这是**小米 MIUI 构建农场的零售构建**。MTK 自家工厂工程版
   来自 MTK 内部构建服务器，路径形态不同。

---

## 汇总：静态能得出什么 / 不能得出什么

| 问题 | 静态能不能回答 | 结论 |
|---|---|---|
| 这份是不是零售 preloader | ✅ 能 | 是（小米 build farm + efuse 动态读 SBC） |
| 代码里有没有硬编码关校验 | ✅ 能 | **没有**，校验是条件执行 |
| 校验函数是否被删除/stub | ✅ 能 | **没有**，全套都在 |
| **这台机的校验到底开没开** | ❌ **不能** | 由 eFuse word 0x1F bit 1 决定，必须实测 |

## 一锤定音的实测（零风险，只读）

preloader 自己会把结果打进日志：

```
0x0204FA1A  "sbc_en = %d"      → 日志里出现 "sbc_en = 0" 或 "sbc_en = 1"
```

而 preloader 的日志落在 **`expdb` 分区**（本机 128 MiB）。

```bash
adb shell su -c "dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M"
adb pull /data/local/tmp/expdb.img
grep -a -o "sbc_en = [01]" expdb.img
```

另外可读 `seccfg`（MTK 的锁状态分区，对应镜像里的
`[SEC_POLICY] lock_state = 0x%x` 那条打印）确认 `lock_state`。

## 备注：刷 tee 其实不依赖"免授权"

- BL 已解锁（`ro.boot.flash.locked=0`）→ **fastboot 可以直接写 `tee_a`**
- 但 **preloader 在启动 ATF 时会校验 ATF 的签名**（SBC 开的话）
- 所以真正决定能否刷入修改版 tee 的，还是 **eFuse 里的 SBC**

---

# 实机验证结果（2026-10-05，只读）

## A. 这台机的 Secure Boot 是**开着**的（实测，非推测）

从 `expdb`（preloader 启动日志分区，128 MiB）直接读出的原文：

```
   440  sbc_en = 1                  ← preloader 自己算出来的 SBC 值
   220  [PART] img_auth_required = 1
     5  img_auth_required = 0
    21  [SEC_POLICY] lock_state = 0x3
    21  cert vfy(24 ms)  / cert vfy(17 ms) / ...   ← 证书校验真的跑了并成功
    12  part: lk_a img: aee
    10  part: lk_a img: bl2_ext
    10  part: gz_a img: unmap2
    10  part: gz_a img: gz
```

与 `seccfg` 分区的裸数据完全对应：

```
00000000: 4d4d4d4d 04000000 3c000000 03000000   MMMM....<.......
00000010: 00000000 00000000 45454545 b4c9b88a
00000020: 255a1745 17c0c5f6 85315e9e c48e00f7
00000030: c8965b9d a1ed3100 cf79a983 00000000
                    ↑ 0x0C = 0x03  ← 与日志 lock_state = 0x3 一致
         偏移 0x18..0x38 是 32 字节 seccfg 哈希
```

**推论**：既然 `sbc_en = 1` 且 `img_auth_required = 1`，
修改过的 ATF **必须过 MTK 证书校验**才能启动 →
**pwnage 签名（LEGACY 模式）是必经步骤，不能省。**

## B. DroidVM 的 GenieZone 路线在本机不可行

```
/dev/gunyah   → 不存在
/dev/kvm      → 不存在（EL2 被 GZ 占）
/dev/gz_kree  → 存在（char 10,99）  ← GZ 的 KRE 服务接口
/dev/gzvm     → 不存在              ← crosvm/DroidVM 需要的 VM 接口
```

`VMHypervisor.GENIEZONE` 查的正是 `/dev/gzvm`。本机只有老一代 GZ，
且 `isBackendSupported` 里 QEMU 不支持 GENIEZONE（只有 crosvm 支持）。
→ **DroidVM 只能走 KVM 后端，也就是必须刷 tee。**

## C. 你给的那份 preloader 帮不上忙

它 = 设备当前运行的版本（逐字节相同），且其 SBC 判定读 eFuse：

```asm
0x020522FC  movs r0, #0x1F          ; efuse word 31
0x02052302  bl   #0x02054860        ; efuse 读取
0x02052306  ubfx r0, r0, #1, #1     ; SBC = bit 1
```

所以它**不会**跳过校验。要"免校验启动"需要的是另一份被人为改成
不读 eFuse 的 preloader。

## D. 仍未查清的一点（诚实标注）

preloader 的显式校验日志只点名 `lk_a`(aee/bl2_ext) 与 `gz_a`(gz/unmap2)，
**没有直接出现 `tee_a`/`atf`**。而 `bl2_ext` 内部含
`[BL31] load failed` + `atf` + `vm-BL31-reserved` 等串，说明 ATF 的加载
发生在 `bl2_ext` 阶段。ATF 具体由谁校验、是否校验，本轮未隔离出来。

→ 在 `sbc_en=1` 的前提下**按"会被校验"处理**是安全假设。

## E. 交叉验证：这些日志确实来自当前这个 preloader

expdb 里只出现 **一个** preloader 构建戳：

```
  10  Build Time: 20230918-112001
  10  20230918-112001          （没有任何其它版本的构建戳）
```

而当前镜像里内嵌的构建戳也是 `20230918-112001`
→ 那些 `sbc_en = 1` / `cert vfy(24 ms)` 日志**不是旧版残留**，
  就是这个工程 preloader 自己打的。

## F. 工程 preloader 的"工程"在哪：DA/EDL 路径

`usbdl_verify_da`（0x0201144C）在全镜像里**只有一个调用点**：0x02032B86。

```asm
0x02032B68  ldrb.w  r0, [r8]        ; 收到的字节
0x02032B6C  cmp     r0, #0xA0       ; == 0xA0 才算 DA
0x02032B6E  bne     #0x2032B96
...
0x02032B80  add     r0, sp, #0x1c
0x02032B82  mov.w   r1, #0x12c
0x02032B86  bl      #0x201144C      ; usbdl_verify_da(buf, 0x12c)
0x02032B8A  mov     r0, r4          ; ← 直接用 r4，**没有** cmp r0 / bne
0x02032B8C  mov     r1, r5
0x02032B8E  mov     r2, fp
0x02032B90  bl      #0x2045C74      ; log
0x02032B94  b       #0x2032B30      ; 回主循环
```

**返回值被直接丢弃，调用点没有做任何判断。**
（强制如果存在，只能在函数内部 —— 函数里有一条
 `bl #0x2045BA8(1)` 的可疑失败分支，本轮未完全排除。）

## G. 最终判断

| 问题 | 答案 |
|---|---|
| 工程 preloader 关掉了**启动时的镜像校验**吗 | **没有**（SBC 仍读 eFuse，且实测值=1，证书校验真实执行）|
| 它可能关掉了 **EDL/DA 授权**吗 | **很可能**（`usbdl_verify_da` 返回值未检）|
| 所以刷改过的 tee 还要签名吗 | **要**。免授权刷机 ≠ 免签启动 |

**零风险验证"免授权"的办法**：进 EDL，用未签名 DA **只读**一下
（如 `mtkclient r seccfg`），看会不会要求 `.auth` 文件。

**最直白的验证"改了哪里"**：拿原厂 xagapro preloader 与本镜像做二进制 diff。

---

# 最终结论（2026-10-05，实机日志 + 静态逆向）

## H. 完整的两段式校验链（全部零 fail）

### 第一段：preloader 校验
日志：`part: %s img: %s cert vfy(%d ms)` / `[PART] img_auth_required = %x`

```
 12  part: lk_a img: aee
 10  part: lk_a img: bl2_ext
 10  part: gz_a img: unmap2
 10  part: gz_a img: gz
 21  cert vfy(17..30 ms)
```

### 第二段：`bl2_ext`（扩展 BL2）的 `[SBC]` 子系统校验

```
[SBC] image <X> header auth pass    +    [SBC] <X> cert chain vfy pass
```

完整清单：
```
dtbo(21) lk_main_dtb(16) logo(12) tinysys-sspm(11) tinysys-mcupm-RV33_A(11)
spmfw(11) pi_img(6) dpmpt(6) tinysys-vcp-RV55_A(5) tinysys-scp-RV55_A(5)
tinysys-gpueb-RV33_A(5) tinysys-apusys-RV33_A(5) **tee(5)** mvpu_algo(5)
md1rom(5) md1dsp(5) **lk(5)** hifi3_a/b_{sram,iram,dram}(5) dpmpm(5)
dpmdm(5) ccu(5) **atf(5)**
```

**零个 `auth fail` / `vfy fail`。**

## I. 决定性结论

| 事实 | 证据 |
|---|---|
| ATF 每个启动都在被校验 | `[SBC] image atf header auth pass` ×5 |
| 校验开关由 eFuse 决定且 = 1 | `sbc_en = 1` ×440，无反例 |
| 校验真实执行（非死代码） | `cert vfy(17..30 ms)` ×21 |
| **改过的 ATF 必须过 MTK 签名** | 上述三条 |
| **免授权刷机能写进去** | `usbdl_verify_da` 返回值未检（见 §F） |
| 刷坏了能救 | 走 **preloader 模式**（非 BROM），免授权 |
| 为什么能换内核 | `boot`/`vendor_boot` **不在** `[SBC]` 清单里（归 AVB 管，解锁后不拦）|

→ **pwnage 签名（LEGACY 模式）是必经步骤，不可省。**

## J. ATF 的实际装载点

```
Load 'tee_a' partition to 0x0xffff000048200000 (283016...)
Load 'tee_a' partition to 0x0xffff00006ffffdc0 (3200000...)
```

`0x48200000` = mblock-15-BL31-reserved 基址；283016 = `atf` 成员大小。
第二个是 `tee` 成员（3 200 000 字节 = TEE OS）。
→ 跑起来的 ATF 就是 `tee_a` 里的 `atf` 成员，就是 NoGZ 补丁要改的那个。




---

# 签名完成（2026-10-05）

## 工具

`kasnria001/pwnage24mtk`（公开）：
- 原理：MTK ASN.1 证书解析逻辑缺陷（CVE-2023-20696 同类 / CVE-2025-20730 修补）
- 老设备用 `bypass_mode 1`（= 本机检测出的 `LEGACY` / `enter-value traversal, arg4=1`）
  做法：把**原始未改动的 CERT2 DER** 包成 `BIT STRING` 假对象放前面，
  真 cert 放在后面并带更新后的 image hash / image hdr hash
- 只用标准库，无额外依赖

命令：
```bash
python sign_mtk_cert.py <unsigned.img> --legacy -w -o <out.img>
python verify_mtk_image.py --all <out.img>      # 要求 2 个 Result: VALID
```

## 关键坑：签名后超出分区 1072 字节

```
unsigned : 5 242 880   (= tee 分区大小，刚好占满)
signed   : 5 243 952   (+1072)
```

增量来自 BIT STRING wrapper（987B）+ CERT2 dsize 982→2059（对齐到 2064）。

**但插入点在 ATF 之后、尾部零填充完全没变：**

| 成员 | unsigned | signed |
|---|---|---|
| `atf` | 0x200 | 0x200 |
| `tee` | 0x46440 | 0x46870 (+1072) |
| `cert1` | 0x353a40 | 0x353e70 (+1072) |
| `cert2` | 0x354310 | 0x354740 (+1072) |
| 尾部零填充 | 1 751 322 | **1 751 322（不变）** |

尾部有 1.75 MB 全零 → **裁掉 1072 字节零填充即正好 5 MiB，零真实数据损失。**
（已验证被裁部分全为 0x00）

## 成品

```
文件   : sign-test/tee_nogz_legacy_5M.img
大小   : 5 242 880  (= tee 分区)
sha256 : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```

| 检查 | 结果 |
|---|---|
| `verify_mtk_image.py --all` | **2 × `Result: VALID`**（ATF 组 + TEE 组）|
| CERT1 / CERT2 signature | OK |
| Image header hash / Image data hash | OK |
| `tee` 成员是否被改动 | **未改动** ✓ |
| ATF 与重新打补丁结果 | **逐字节一致** ✓ |
| 官方 14 项回归 | **14/14 通过** ✓ |

**未验证项（诚实标注）**：`Trusted root check: skipped`
→ 设备 eFuse 信任根对这条证书链的比对**未被离线验证**，只能实机启动才算。

## 上游仓库的 bug（供反馈）

`scripts/build.py:340` 调用了 `sign_all_flag(args.tools)`，但**全文件没有这个函数的定义**
→ 走签名路径必然 `NameError`。`--check-only` 提前 return 所以没暴露。
（另：`sign_mtk_cert.py` 本身没有 `--all` 参数，所以该函数本该返回 `[]`。）

---

# 社区教程佐证（酷安《MTK SPFlash V6使用教程 For xaga/pearl》）

教程原文关键句：

> 因为工程 **Preloader 它暴露了一个不安全的 VCOM 端口，并且禁用了 SLA（串行链路身份验证）
> 和 DAA（下载代理身份验证）检查**，允许使用工具刷写设备，而无需小米售后账号授权刷写设备

> 最近有个好消息，就是 **xaga 的工程 Preloader 引导文件被泄露**，泄漏有什么用呢，
> 答案是 **免费救砖** …… 可以避免一定的黑砖，不用花钱自行抢救

## 三条独立证据完全咬合

| 教程的说法 | 本镜像里的对应证据 |
|---|---|
| 禁用 **DAA**（下载代理身份验证） | `usbdl_verify_da` 调用后**返回值被直接丢弃**（§F）|
| 暴露不安全的 **VCOM 端口** | 镜像内含 `USB CDC ACM for preloader` 字符串 |
| 只是"能刷进去"，不是关校验 | `sbc_en` 从 eFuse 读、实测 = 1，`[SBC] image atf header auth pass`（§E/§H）|

→ **工程 preloader = 让"写"免授权（+ 刷坏能救），完全不动"启动时校不校验"。**
   与本文档 §G/§I 的结论一致，无冲突。

## 教程里对我们有用的两点

1. **SP Flash 深刷后 BL 会被重新锁上**
   > 深刷完 bl 就是锁的了，不过第二次可以秒开
   > （有大佬说不刷 seccfg 分区就能保持 bl 解锁状态，但是工具没有刷这个分区）
   → **不要用 SP Flash 刷 tee**，否则 BL 被锁回，后续 fastboot 不方便。

2. 刷工程 preloader 走的是 **fastboot**：
   ```
   fastboot flash preloader1 preloader_xaga.bin
   fastboot flash preloader2 preloader_xaga.bin
   fastboot reboot
   ```
   （本机 by-name 里对应的是 `preloader_raw_a` / `preloader_raw_b`）

3. 恢复链路需要的材料（教程里 @rkpsz 分享的包）：
   `SP_Flash_Tool_v6.2316_Win.zip` + `auth_sv5.auth` + `libusb_v1.12.exe` +
   `一加mtk驱动.exe` + `preloader_xaga.bin` + 线刷包 `flash.xml`

---

# ✅ 实机成功（2026-10-05 22:00）

## 刷入

```
tee_a BEFORE : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
dd 5242880 bytes, 0.019 s, 263 M/s
tee_a AFTER  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689
```
回读哈希 == 成品哈希 → 写入真生效。

## 重启后：ATF 通过真机 SBC 校验

```
[SBC] image atf header auth pass   ×3
```
→ pwnage 的证书漏洞在本机成立，签名版 ATF 被接受。

## KVM 上线

```
crw-rw-rw- 1 root root u:objectr:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        ← /proc/misc（刷之前 46 项里没有 kvm）
head -c 1 /dev/kvm → Invalid argument
                     ↑ 不是 Permission denied → open() 过了 SELinux（Enforcing）
```

## 真跑起 Linux VM（决定性证据）

本机自带 AVF 的 crosvm + microdroid 内核：

```bash
su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

guest 输出：

```
Booting Linux on physical CPU 0x0000000000 [0x412fd050]   ← Cortex-A55
Linux version 6.6.30-android15-5
Machine model: linux,dummy-virt
psci: PSCIv1.0 detected in firmware.
GICv3: CPU0: found redistributor 0 region 0:0x000000003ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x0000000001 [0x411fd411]  ← Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

**结论：ATF → EL2 → VHE → KVM → 一个 2 vCPU 的 Linux guest 正常启动。整条链路在真机上闭环。**

## 最终成品

| 文件 | sha256 |
|---|---|
| `sign-test/tee_nogz_legacy_5M.img` | `f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689` |
| `backup/tee_a.img`（回滚用） | `f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062` |

## 遗留

- `tee_b` **未修改**（仍然是原厂）。切到 B 槽会回到无 KVM 状态，但也因此是天然兜底。
- 上游 `mtk-mod-tee-nogz` 的 `sign_all_flag` 未定义 bug 可反馈。

---

# DroidVM 实机验证（2026-10-05 深夜）

## 环境

```
DroidVM v0.0.6 已安装，daemon 运行中（KernelSU 已授权）
内核 5.10.247-android12-9-Pandora-26w08d   SoC MT6895Z/TCZA
自带: usr/bin/{qemu-system-aarch64, qemu-img, crosvm}
      usr/share/droidvm/{edk2-qemu.fd, edk2-gunyah.fd, vmlinuz, initramfs.img}
无 usr/lib/modules（KVM 不需要厂商模块，与源码分析一致）
```

## ① crosvm + KVM：**稳定可用**（已实测）

用设备自带 AVF 的 crosvm 引导 microdroid 内核，guest 完整启动、双核 SMP 成功。

## ② DroidVM 自带 QEMU + KVM：**flaky（big.LITTLE 竞态）**

裸跑 QEMU 会因链接器命名空间拿不到 `libbinder_ndk.so`，需
`LD_LIBRARY_PATH=/system/lib64` 绕过（DroidVM daemon 自己有正确环境，不需要）。

```
Accelerators supported in QEMU binary: gunyah, kvm, tcg     ← 无 geniezone
```

DroidVM 的 `QemuBackendInstance` 把 cpu 写死为 `host[,pmu=off]`（源码 L196-201），
实测 **同一命令连跑 5 次：2 成功 / 3 失败**：

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

**根因（已定位）**：`-cpu host` 枚举的是 QEMU **当前所在 CPU** 的特性；
big.LITTLE 上写 vCPU 寄存器期间被调度器在 A55/A78 间迁移 → EINVAL。

绑核验证：

| 条件 | 结果 |
|---|---|
| 不绑核 × 5 | 2/5 成功 |
| `taskset 1`（cpu0, A55）× 3 | **3/3 成功** |
| `taskset 80`（cpu7, A78）× 3 | **3/3 成功** |

各类 `-cpu` 变体的表现（不稳定，随机性大于特性差异）：
`host` ✗ · `host,pmu=off` ✗(60%) · `host,sve=off` ✓ · `host,pauth=off` ✓ ·
`host,sve=off,pauth=off` ✗ · `host,sve=off,pmu=off` ✓ · `max` ✗ · `cortex-a55` ✗(KVM 仅支持 host/max)

**结论**：QEMU+KVM 在 DroidVM 里需要 **CPU 绑核** 才可靠；crosvm 不需要。

## ③ 与 ATF 补丁无关的旁证

`/proc/cpuinfo` 的 Features 刷前刷后**完全一致**（都没有 `sve`），
说明补丁没有改变内核对 CPU 特性的判定。
