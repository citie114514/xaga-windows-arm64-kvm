# xagapro (Redmi Note 11T Pro+) — отчёт о выполнимости MTK NoGZ → KVM

[中文](../appendix-early-report.md) | [English](../en/appendix-early-report.md) | [日本語](../ja/appendix-early-report.md) | **Русский**

Дата: 2026-10-04
Устройство: `192.168.31.75:33445` (устройство 1, **ничего не прошивалось**, только чтение)
Статус: **все офлайн-проверки пройдены; ждём решения о записи на устройство**

---

## 1. Факты об устройстве (разведка только чтением)

| Пункт | Значение |
|---|---|
| Модель | 22041216UC / `xagapro` / на рынке **Redmi Note 11T Pro+** |
| SoC | MT6895 (Dimensity 8100: 4×A78 + 4×A55) |
| Система | HyperOS 3, `OS3.0.1.0.VLHCNXM`, Android 15 |
| Ядро | `5.10.247-android12-9-Pandora-26w08d` (стороннее ядро Pandora) |
| Root | **есть**, KernelSU (`uid=0(root) context=u:r:ksu:s0`) |
| Загрузчик | **разблокирован** (`ro.boot.flash.locked=0`, `verifiedbootstate=orange`) |
| Текущий слот | `_a` |
| RAM | 7.68 GiB → вариант на **8 GiB** (не 12 GiB) |
| userdata | 226 G, занято 204 G, свободно 21 G (**тесно — освободите место перед сборкой rootfs**) |
| `hwid` | sku=xagapro country=CN level=MP version=4.9.0 project_adc=701 |

Возможности ядра (из `/proc/config.gz`):

```
CONFIG_ARM64_VHE=y          <- ключ: ядро поддерживает VHE и может работать на EL2
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_ARM_GIC_V3=y         <- аппаратная основа vGIC
CONFIG_ARM_GIC_V3_ITS=y
CONFIG_ARM64_VA_BITS=39
```

`/dev/kvm` **отсутствует**, а модуль `kvm` вкомпилирован в ядро, но не инициализируется, потому что
ядро работает на EL1.
В `/sys/module/` есть `gz_main_mod` `gz_trusty_mod` `gz_tz_system` `gz_ipc_mod`
`gz_irq_mod` `gz_virtio_mod` → **GenieZone занимает EL2**, ровно как предсказывает теория.

---

## 2. Почему официальный скрипт сразу отказывается

`mtk-mod-tee-nogz` знает только 3 профиля, и все они сопоставляются точно по полной SHA-256
`tee.img`/`lk.img`:

| profile | Целевая модель | Совпадает с этим устройством? |
|---|---|---|
| `yunluo` | — | ❌ |
| `peral` | Xiaomi 13T | ❌ |
| `xaga` | Redmi Note 11T Pro / POCO X4 GT | ❌ |

Измерено на устройстве (sha256 прямо из `/dev/block/by-name/`):

```
tee_a (5 MiB) = f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062
lk_a  (8 MiB) = 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3
tee_b         = f8f286f1... (идентичен tee_a)
lk_b          = 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0
gz_a          = 3f829d4061b1cc00d6bbcd1cafa3263348ec75800c9654cd936410c4d26572f6
```

Против профиля xaga:
- `tee_sha256 = bd4b13a7…` ❌
- `lk_sha256 = 03856964…` ❌

**Вывод: скопировать нельзя; для xagapro нужно добавить новый профиль (= работа по адаптации,
описанная в `docs/adaptation.md` апстрим-репозитория).**

Хорошая новость: структурно они очень близки — **ATF является продуктом сборки того же исходника**,
различаются лишь несколько смещений функций.

---

## 3. Полученный реверсом профиль xagapro (проверен официальной регрессией)

### 3.1 Как были найдены смещения (доказательства из дизассемблера)

| Пункт | xaga | **xagapro (это устройство)** | Доказательство |
|---|---|---|---|
| `pc_patch` | 0x1ad9c | **0x1ade0** | `ldr x8,[x1,#0x10]` → заменено на `mov x8,#0x50f00000` |
| `kernel_patch` | 0x64a4 | **0x64a4** | `csel w12,w13,w12,eq` → заменено на `mov w12,#0x3c9` (EL2h) |
| `getter` | 0xe5f8 | **0xe560** | `adrp x8,0x48244000; ldr w8,[x8,#0xf00]; mvn w8,w8; and w0,w8,#1; ret` = документированный `(~flags)&1` |
| `callback` | 0xdf14 | **0xde7c** | дельта до getter = **0x6e4 (точно как у xaga)** |
| `flag` | 0x45f08 | **0x44f00** | callback: `adrp x9,0x48244000; str w8,[x9,#0xf00]` |
| `ep` | 0x53930 | **0x52930** | `add x14,x14,#0x938` → x14 = ep+8; PC пишется в ep+8, SPSR в ep+16, что соответствует раскладке `entry_point_info` из TF-A |
| `kernel_args` | 0x539e0 | **0x529e0** | = ep + 0xB0 (та же дельта, что у xaga) |
| `handoff_global` | 0x53af0 | **0x52af0** | args_getter case0: `adrp x8,0x48252000; ldr x0,[x8,#0xaf0]` |
| `cold` | [0x1ad74,0x1adf8] | **[0x1adb8,0x1ae3c]** | функция начинается с `stp x29,x30` и заканчивается `ret` |
| `cold_helpers` | [0xb6e8,0xb700] | **[0xb6bc,0xb6d4]** | две маленькие функции `adrp/ldr/ret` |
| `kernel` | [0x6454,0x6538] | **[0x6454,0x6538]** | полностью идентично |
| `tag_parser` | [0x6688,0x68e8] | **[0x6688,0x68f0]** | начало полностью совпадает |
| `args_getter` | [0xb7fc,0xb858] | **[0xb7d0,0xb800]** | диспетчер таблицы переходов + case0 |
| `lk_*` (13 пунктов) | — | **идентично xaga** | см. ниже |

**Все смещения на стороне LK попали в те же значения и с идентичными словами инструкций**:
`lk_illegal=0x3a18` — это ровно `mrs x9,cptr_el3`; `lk_elcheck` начинается с `0x39c8` и
`mrs x4,CurrentEL`; а `lk_gate=0x28d4`, `lk_skip=0x2904` (`mov w0,wzr`), `lk_getter=0x1e8a8`,
`lk_callback=0x1e8bc` — всё сходится.
→ **Секция кода LK этого устройства — та же сборка, что и у xaga**; различается лишь внешняя
упаковка сертификата/DTB.

### 3.2 Результаты проверки

С официальным `scripts/build.py --check-only` (только добавление профиля и исправление смещений,
без изменений в логике решений):

```
passed_checks:
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=False   (4)
  shared_chain flags=0x0/0x1/0x2/0xffffffff  tag_last=True    (4)
  missing_tag_defaults
  LK_EL2_illegal_EL3_negative_control
  kernel_feature_and_AArch32_controls
  wrong_PC_negative_control
  missing_tag_sync_negative_control
  budget_exhaustion_rejected
→ 14/14 всё пройдено
```

Включая 4 **контрпримера** (неверный PC, пропущенная синхронизация общего тега, вход LK из EL2 с
чтением CPTR_EL3, исчерпание бюджета инструкций) — это показывает, что семантика патча действительно
верна, а не «запустилось, значит прошло».

### 3.3 Артефакт (без подписи)

`tee_nogz_xagapro.unsigned.img`, sha256 `2bcdf7b3bdae3dcc77d570e350a79e5962a46daa7cd19610b022742f8773f413`

Фактические изменения в 10 местах:

| Смещение ATF | Смещение в файле | Старая инструкция | Новая инструкция |
|---|---|---|---|
| 0x01ade0 | 0x01afe0 | `ldr x8,[x1,#0x10]` | `mov x8,#0x50f00000` |
| 0x0064a4 | 0x0066a4 | `csel w12,w13,w12,eq` | `mov w12,#0x3c9` ← **передача ядру EL1h → EL2h** |
| 0x00e560 | 0x00e760 | `adrp x8,#0x48244000` | `mov w0,#0` |
| 0x00e564 | 0x00e764 | `ldr w8,[x8,#0xf00]` | `ret` |
| 0x00de7c | 0x00e07c | `ldr w8,[x0]` | `mov w8,#1` |
| 0x00de84 | 0x00e084 | `mov w0,wzr` | `str w8,[x0]` ← **запись общего тега flags=1** |
| 0x00de8c | 0x00e08c | `ret` | `b #0x4820e568` |
| 0x00e568 | 0x00e768 | `mvn w8,w8` | `dc cvac,x0` |
| 0x00e56c | 0x00e76c | `and w0,w8,#1` | `dsb sy` |
| 0x00e570 | 0x00e770 | `ret` | `b #0x4820e560` |

---

## 4. Выполнимость подписи (установлено)

```
detect_pl_cert_mode.py preloader_raw_a.img --json
→ status: LEGACY
   reason: certificate entry uses enter-value traversal (arg4=1); legacy BIT STRING wrapper required
   sha256: 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1
```

Вывод однозначен (не `NEED_MANUAL`) → при подписи pwnage нужен `--legacy`, скрипт добавляет его сам.

---

## 5. Чего не хватает / риски

### 5.1 Не хватает
1. **Инструментарий `pwnage24mtk`** (`sign_mtk_cert.py` / `verify_mtk_image.py`). В репозитории он не поставляется; нужна своя доверенная копия.
2. **Проверка загрузки на устройстве**: ветка linux в этом репозитории — для **xaga**. У xagapro адаптации только в нескольких драйверах (например, `power: mediatek: xagapro: SC8561` для зарядки), поэтому **панель/тач/зарядка могут отличаться → может не загрузиться**.
3. Место на диске: осталось всего 21 G; для сборки rootfs нужно место.

### 5.2 Риски (продумайте заранее)
- **`tee` — это раздел безопасности.** Неверная прошивка → проверка подписи preloader падает → цепочка загрузки рвётся → **спасти может только EDL**, а для MT6895 EDL обычно требует авторизованной учётной записи. Это реальный риск «кирпича».
- Прохождение контрпримеров **≠ устройство загрузится**. Собственное заявление апстрима:
  `device_tested: false` / «офлайн-регрессия не означает, что устройство обязательно примет образ или загрузится».
- Оба слота: `tee_a == tee_b` (нужно менять оба, иначе переключение слота вернёт всё назад).
- **Влияние на сам Android неизвестно**: при отключённом GZ модули `gz_*` не загрузятся; хотя
  `CONFIG_ARM64_VHE=y`, предполагают ли проприетарные драйверы MTK существование GZ — не проверено.

### 5.3 Рекомендуемый порядок действий
1. Сначала достаньте `pwnage24mtk`, запустите `sign_mtk_cert.py` + `verify_mtk_image.py`, требуйте
   **два `Result: VALID`**, и прогоните 14-пунктовую регрессию ещё раз по результату.
2. Затем решайте, писать ли. Если писать — предпочтительно только `tee_a` (текущий слот), и убедитесь,
   что EDL/авторизованные инструменты доступны, а пути отката (`misc`/`frp` и т. п.) понятны.
3. Рассмотрите отправку этого профиля PR в апстрим-репозиторий (`docs/adaptation.md` требует, чтобы
   новая версия проходила аудит с положительными и отрицательными случаями).

---

## 6. Резервные копии (уже в `backup/` этого каталога)

| Файл | Размер | sha256 |
|---|---|---|
| `tee_a.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `tee_b.img` | 5 MiB | f8f286f138e758a59159fccb4c9533355616aa1670aada795dd80402fdec5062 |
| `lk_a.img` | 8 MiB | 8cbaa2e8e25cc7ba90bd17cb83c610d1645b3bccbd8584d3c266f15a7de05ea3 |
| `lk_b.img` | 8 MiB | 0b64806db121903956554ebbf0d27e24da7c45f75b73152423ca0b52b0077fa0 |
| `preloader_raw_a.img` | 4 MiB | 056ed47a97391139fd3553575a276afbaaa110c103bcf04c97cdc106f1fa68d1 |

---

## 7. Команды для воспроизведения

```bash
git clone --depth 1 https://github.com/MT6895-Mainline/mtk-mod-tee-nogz
cd mtk-mod-tee-nogz
# Слейте содержимое profiles.xagapro.json в references/profiles.json
# Добавьте "xagapro" в --profile choices в scripts/build.py

# 1) Офлайн-регрессия (не трогает устройство)
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img --check-only

# 2) Подпись (нужен собственный pwnage24mtk)
python scripts/build.py --profile xagapro \
  --tee backup/tee_a.img --lk backup/lk_a.img \
  --preloader backup/preloader_raw_a.img \
  --tools ../pwnage24mtk \
  --out-dir outputs/xagapro-run-01
```

Зависимости: `pip install capstone unicorn`

---

## 8. Дополнительные доказательства (вечер 2026-10-04)

### 8.1 Почему KVM сейчас недоступен — установлено измерениями

```
/proc/misc | grep -i kvm        -> пусто (ни одного из 46 устройств misc)
/sys/module/kvm/                -> только parameters/ и uevent; нет initstate / refcnt
/sys/module/kvm/parameters/     -> halt_poll_ns=500000 grow=2 grow_start=10000 shrink=0
/dev/kvm                        -> не существует
```

`kvm_init()` не завершился (устройство misc не зарегистрировано). Символы `kvm_arch_init` /
`kvm_init` в ядре есть, конфигурация `CONFIG_KVM=y`, поэтому единственная возможная причина отказа —
**ядро не находится на EL2**.
Это точно соответствует слоту `kernel_patch` из таблицы в 3.1 (`csel w12,w13,w12,eq` → принудительно
`#0x3c9`).

### 8.2 Патч работает и для Android

`kernel_patch` расположен в «помощнике передачи управления ядру AArch64» внутри ATF и определяет
**SPSR в точке входа ядра**. Ядра в разных слотах (Android или mainline) проходят через одну и ту же
точку передачи, поэтому:

- Остаться на Android: ядро Android тоже поднимается с EL2. Его конфигурация —
  `CONFIG_ARM64_VHE=y` + `CONFIG_VIRTUALIZATION=y` + `CONFIG_KVM=y`, поэтому `/dev/kvm` появится.
- Прошить mainline: подход из видео.
- Оба варианта могут сосуществовать (разные слоты / `fastboot boot`).

**Рекомендуемая минимальная проверка**: прошить только `tee`, перезагрузиться в Android, посмотреть
`/dev/kvm`. Этот один шаг подтверждает часть, связанную с ATF, на реальном железе с минимальными затратами.

Ограничения на стороне Android: для `/dev/kvm` нет правила SELinux (нужен `su -c` и, возможно,
`setenforce 0`); в QEMU из Termux нет virgl/venus, поэтому GPU-ускорение недоступно.
