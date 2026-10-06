# Включение KVM — полный процесс

[中文](../01-enable-kvm.md) | [English](../en/01-enable-kvm.md) | [日本語](../ja/01-enable-kvm.md) | **Русский**

> Цель: заставить `/dev/kvm` появиться в Android, чтобы QEMU мог использовать аппаратное
> ускорение (а не программную эмуляцию TCG, которая слишком медленная для работы).

**Требования**: разблокированный загрузчик + root (KernelSU/Magisk) + adb и Python 3.10+ на ПК.
**Форма**: изменяется только `tee_a`, `tee_b` остаётся штатным (встроенная страховка).

---

## 0. Сначала проверьте текущее состояние (только чтение, нулевой риск)

```bash
# Есть ли KVM
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'

# Узлы, связанные с GZ (показывают, кто занимает EL2)
adb shell su -c 'ls -l /dev/gz* /dev/gunyah 2>&1'

# Состояние блокировки загрузчика (0 = разблокирован)
adb shell getprop ro.boot.flash.locked

# Модель устройства
adb shell getprop ro.product.device
```

Ожидаемые результаты (до патча):

| Проверка | Нормальный результат |
|---|---|
| `/dev/kvm` | `No such file or directory` |
| `/proc/misc` | среди 46 записей **нет** `kvm` |
| `/dev/gz_kree` | существует (char 10,99) |
| `/dev/gzvm` | не существует |
| `ro.boot.flash.locked` | `0` |

**Пояснение**: прошивка **GenieZone (GZ)** от MediaTek занимает EL2, поэтому Linux не может
получить расширения виртуализации, и ядро не экспортирует `/dev/kvm`.
Замена ATF, работающего на EL2, — единственный выход.

---

## 1. Считайте состояние Secure Boot устройства (от него зависит, нужна ли подпись)

Preloader записывает свой вердикт в лог, который попадает в раздел **`expdb`**:

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/expdb.img bs=1M'
adb pull /data/local/tmp/expdb.img
# На ПК ищите:
grep -a -o "sbc_en = [01]" expdb.img | sort | uniq -c
grep -a -o "img_auth_required = [0-9]" expdb.img | sort | uniq -c
grep -a -c "cert vfy" expdb.img
```

Измерено на этом устройстве (Redmi Note 11T Pro+):

```
    440  sbc_en = 1                      <- Secure Boot включён
    220  [PART] img_auth_required = 1
     21  cert vfy(24 ms) / cert vfy(17 ms) / ...   <- проверка сертификатов реально выполняется
```

**Почему это важно**:

- Значение SBC читается из **eFuse (OTP, записывается однократно)** — см. дизассемблер preloader ниже
- `sbc_en = 1` → **при каждой загрузке проверяется цепочка сертификатов ATF**
- → **изменённый ATF обязан пройти подпись MTK**, этот шаг пропустить нельзя

```asm
; Решение SBC внутри preloader (вот почему «правка preloader» не помогает)
0x020522FC  push   {r7, lr}
0x02052300  movs   r0, #0x1F          ; efuse word index 31
0x02052302  bl     #0x02054860        ; прочитать eFuse
0x02052306  ubfx   r0, r0, #1, #1     ; SBC = bit 1
0x0205230A  pop    {r7, pc}
```

> **Частое заблуждение**: многие думают, что «инженерный preloader» позволяет загружаться без
> подписи. В действительности инженерный preloader снимает авторизацию только для **записи**
> (возвращаемое значение `usbdl_verify_da` просто отбрасывается); **проверка образов при загрузке
> всё равно выполняется**. Разница объяснена в [appendix-atf-reverse.md](appendix-atf-reverse.md).

---

## 2. Резервная копия штатных разделов (**пропускать категорически нельзя**)

```bash
for p in tee_a tee_b lk_a lk_b preloader_raw_a seccfg; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/bk_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/bk_$p.img ./backup/$p.img
done

# Запишите хеши для сверки при откате
cd backup && sha256sum *.img | tee SHA256SUMS.txt
```

sha256 штатного `tee_a` этого устройства (для справки):

```
f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   tee_a.img  (5242880 байт)
```

**Если копия потеряна, отката не будет.** Скрипт в один клик прерывается, если копию снять не удалось.

---

## 3. Снять материал прямо с устройства (гарантирует совпадение хешей)

Инструмент патча требует, чтобы **пара TEE / LK точно совпадала по хешу с проанализированной
версией** — поэтому **снимайте данные прямо с устройства**, а не ищите пакеты прошивок:

```bash
for p in tee_a lk_a preloader_raw_a; do
  adb shell su -c "dd if=/dev/block/by-name/$p of=/data/local/tmp/dp_$p.img bs=4096 2>/dev/null"
  adb pull /data/local/tmp/dp_$p.img ./dump/$p.img
done
```

---

## 4. Сборка + подпись

На этом шаге используются [`mtk-mod-tee-nogz`](https://github.com/MT6895-Mainline/mtk-mod-tee-nogz)
(инструмент патча NoGZ) и [`pwnage24mtk`](https://github.com/kasnria001/pwnage24mtk) (инструмент подписи).

**Подробное объяснение и шаги — в [02-build-and-sign.md](02-build-and-sign.md).** Здесь только
минимальная команда:

```bash
# Окружение
git clone https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
python -m venv .venv && .venv/bin/python -m pip install -r requirements.txt

# Сборка (автоопределение режима new/legacy и вызов pwnage)
.venv/bin/python scripts/build.py \
  --profile xaga \
  --tee    ../dump/tee_a.img \
  --lk     ../dump/lk_a.img \
  --preloader ../dump/preloader_raw_a.img \
  --tools  ../pwnage24mtk \
  --out-dir ../outputs/run-01
```

Ключевые результаты:

```
outputs/run-01/
  tee_nogz_legacy.img     <- подписанный результат (в режиме LEGACY)
  tee_nogz_new.img        <- (в режиме NEW_PARSER)
  verify.log  sign.log  cert-mode.txt  manifest.json
```

**Вы обязаны увидеть два `Result: VALID`**, иначе не прошивайте.

### 4.1 Как быть с «подписанный образ больше раздела»

Подпись вставляет обёртку BIT STRING **после** ATF, из-за чего образ становится немного больше
раздела:

```
без подписи : 5 242 880    (= размер раздела, заполняет ровно)
с подписью  : 5 243 952    (+1072 байта)
```

**Главное**: точка вставки находится после ATF, поэтому **хвостовые 1.75 MB нулевого заполнения
полностью не изменились** →
**обрезав 1072 байта хвостового нуля, получаем ровно 5 MiB без потери реальных данных**.

Скрипт в один клик делает это автоматически, причём **сначала побайтово убеждается, что
обрезаемое состоит только из 0x00**:

```bash
# Вручную (после подтверждения, что превышение — нули)
head -c 5242880 tee_nogz_legacy.img > tee_nogz_flash.img
```

Если превышение **содержит ненулевые байты**, значит раскладка не та, что вы ожидаете —
**остановитесь и разберитесь руками, не обрезайте силой**.

---

## 5. Запись

```bash
adb push tee_nogz_flash.img /data/local/tmp/
adb shell su -c 'sync'
adb shell su -c 'dd if=/data/local/tmp/tee_nogz_flash.img of=/dev/block/by-name/tee_a bs=4096'
adb shell su -c 'sync'

# Обратное чтение и проверка (должно совпасть с хешем исходного файла)
adb shell su -c 'dd if=/dev/block/by-name/tee_a bs=4096 2>/dev/null | sha256sum'
```

Запись успешного прогона на этом устройстве:

```
before : f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062   (штатный)
dd 5242880 bytes, 0.019 s, 263 M/s
after  : f1511dcad9820397abb1dc843d8fa70f6284f3c3c58aa4bedd7c8c49b54d1689   (патч)
```

> ⚠️ **Не прошивайте `tee` через SP Flash Tool** — полная прошивка заново блокирует загрузчик, и
> fastboot после этого становится неудобным. Записи через `dd` достаточно (загрузчик разблокирован,
> поэтому `/dev/block/by-name/tee_a` доступен для записи).

### Откат (держите под рукой)

```bash
adb push ./backup/tee_a.img /data/local/tmp/tee_stock.img
adb shell su -c 'dd if=/data/local/tmp/tee_stock.img of=/dev/block/by-name/tee_a bs=4096'
adb reboot
```

Можно также переключиться на **слот B** (`tee_b` не изменялся — встроенная страховка).

---

## 6. Перезагрузка и проверка

```bash
adb reboot
# дождитесь загрузки (первая занимает около 2 минут — см. ловушку 12)
adb shell su -c 'ls -l /dev/kvm'
adb shell su -c 'cat /proc/misc | grep kvm'
```

Признаки успеха:

```
crw-rw-rw- 1 root root u:object_r:kvm_device:s0  10, 232  /dev/kvm
232 kvm                        <- появился в /proc/misc (раньше среди 46 записей его не было)
```

Одновременно в `expdb` должно быть видно, что ATF прошёл проверку на устройстве:

```bash
adb shell su -c 'dd if=/dev/block/by-name/expdb of=/data/local/tmp/e.img bs=1M'
adb pull /data/local/tmp/e.img
grep -a "\[SBC\] image atf" e.img
# [SBC] image atf header auth pass      <- уязвимость сертификата pwnage работает на этом устройстве
```

### Решающая проверка: реально запустить гостя

Используйте встроенный AVF `crosvm`, чтобы поднять ядро microdroid (самая чистая проверка,
не зависящая ни от какого стороннего приложения):

```bash
adb shell su -c "/apex/com.android.virt/bin/crosvm --no-syslog run --disable-sandbox \
  --hypervisor kvm \
  --initrd /apex/com.android.virt/etc/microdroid_initrd_normal.img \
  --serial type=stdout,hardware=serial \
  --mem 512 --cpus 2 \
  -p 'console=ttyS0 earlycon=uart,mmio,0x3f8 loglevel=7' \
  /apex/com.android.virt/etc/fs/microdroid_kernel"
```

Вывод гостя:

```
Booting Linux on physical CPU 0x0 [0x412fd050]        <- Cortex-A55
GICv3: CPU0: found redistributor 0 region 0:0x3ffb0000
arch_timer: cp15 timer(s) running at 13.00MHz (virt).
CPU1: Booted secondary processor 0x1 [0x411fd411]     <- Cortex-A78
smp: Brought up 1 node, 2 CPUs
```

→ **ATF → EL2 → VHE → KVM → Linux-гость на 2 vCPU загружается полностью. Вся цепочка замкнута.** ✅

---

## 7. Что дальше

Когда `/dev/kvm` есть:

- **Установить Windows 11 ARM64** → [03-windows-vm.md](03-windows-vm.md)
- **Как пользоваться QEMU и что настраивать** → [04-usage.md](04-usage.md)
- **Если возникла проблема** → [05-gotchas.md](05-gotchas.md)

---

## Приложение: почему QEMU всё ещё нужен `taskset`

На big.LITTLE от MediaTek (4×A78 + 4×A55) `-cpu host` в QEMU перечисляет возможности **того CPU,
на котором он в данный момент работает**; если планировщик мигрирует процесс между A55 и A78 во
время записи регистров vCPU, получается:

```
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

Измерено (одна и та же команда, 5 запусков подряд):

| Условие | Доля успеха |
|---|---|
| Без привязки | **2/5** ✗ |
| `taskset 1` (cpu0, A55) | **3/3** ✓ |
| `taskset 80` (cpu7, A78) | **3/3** ✓ |
| `taskset f0` (cpu4-7, весь кластер A78) | **3/3** ✓ |

**Поэтому в скрипте запуска привязка к ядрам обязательна** (в этом проекте — `taskset f0`, привязка
к быстрому кластеру A78). В собственном бэкенде QEMU у DroidVM такой опции нет, поэтому мы обернули
его — см. [04-usage.md](04-usage.md).
