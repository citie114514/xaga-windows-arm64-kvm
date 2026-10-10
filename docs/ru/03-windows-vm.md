# Диск Windows 11 ARM64 — как его собрать

[中文](../03-windows-vm.md) | [English](../en/03-windows-vm.md) | [日本語](../ja/03-windows-vm.md) | **Русский**

> Цель: не устанавливая гипервизор и не запуская установщик внутри ВМ, прямо на ПК получить
> **загрузочный VHDX с внедрёнными драйверами и обойдёнными проверками TPM**.

**Зачем так**: запускать установщик Windows под эмуляцией ARM — это производительный кошмар (часы).
Развернув образ прямо на ПК, вы оставляете телефону только один проход OOBE, экономя основную часть времени.

---

## 0. Что нужно

| Материал | Пояснение |
|---|---|
| **Windows 11 ARM64 ISO** | **Обязательно ARM64!** x64 на ARM — только эмуляция, смысла нет |
| **virtio-win ISO** | Скачать с [fedorapeople](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) |
| ПК | Windows, права администратора, **минимум 30 GB свободно** |
| 7-Zip | Для извлечения драйверов |

> ⚠️ **Обязательно проверяйте целостность скачанного virtio-win.** При скачивании через прокси файл
> часто обрезается, а обрезанный ISO всё равно «открывается», но данные из него не читаются
> (проявляется как ошибки инструмента, и это легко принять за проблему самого инструмента).
> Как проверить: прочитать PVD образа (смещение `16 × 2048`; размер тома — little-endian u32 по адресу
> `pvd[80:84]`, умноженный на 2048) и сравнить с фактическим размером файла. В этом проекте
> `scripts/extract-virtio.ps1` делает эту проверку автоматически.

---

## 1. Сборка в один клик (рекомендуется)

```powershell
# PowerShell от администратора

# (1) Извлечь драйверы virtio для ARM64
.\scripts\extract-virtio.ps1 -Iso D:\virtio-win.iso -OutDir .\virtio-arm64-w11

# (2) Собрать загрузочный VHDX из ISO
.\scripts\build-windows-vhdx.ps1 `
    -Iso D:\Win11_ARM64.iso `
    -DriversDir .\virtio-arm64-w11 `
    -Out .\win.vhdx `
    -SizeGB 100
```

`build-windows-vhdx.ps1` автоматически делает эти 6 вещей (каждая с проверкой):

```
[1] Монтирует ISO, перечисляет образы, автоматически выбирает ARM64 (неверная архитектура сразу прерывает работу с ошибкой)
[2] Создаёт динамический VHDX + разделы: MSR(16M) + Windows(NTFS) + ESP(FAT32, 300M)
[3] dism /Apply-Image /Compact:ON   (сжатие CompactOS; измерено всего ~10 GB)
[4] bcdboot G:\Windows /s S: /f UEFI   <- шаг, который забывают чаще всего
    и проверка, что PE machine у bootmgfw.efi == 0xAA64
[5] Офлайн-инъекция LabConfig для обхода проверок TPM/SecureBoot/RAM
[6] dism /Add-Driver с рекурсивным внедрением драйверов virtio для ARM64 и подтверждением наличия viostor
```

---

## 2. Ручные шаги (для тех, кому нужны детали)

### 2.1 Создать диск и разделы

Создайте **динамический VHDX на 100 GiB** через Dism++ или diskpart, с разметкой GPT:

| Раздел | Размер | Тип | Буква диска (пример) |
|---|---|---|---|
| MSR | 16 MB | Microsoft Reserved | — |
| Windows | остаток | NTFS | `G:` |
| **ESP** | 300 MB | **FAT32 / EFI System** | `S:` |

### 2.2 Развернуть образ

```powershell
# Сначала посмотреть, какие образы есть и какой из них ARM64
dism /Get-WimInfo /WimFile:G:\..\install.wim     # или sources\install.wim со смонтированного ISO

# Развернуть (со сжатием CompactOS)
dism /Apply-Image /ImageFile:D:\sources\install.wim /Index:3 /ApplyDir:G:\ /Compact:ON
```

> Если внутри ISO лежит `install.esd` (а не wim), дополнительно нужен `/Compress:recovery`.

### 2.3 Записать загрузочные файлы — **самая большая ловушка**

**У дисков, развёрнутых инструментами вроде Dism++, ESP полностью пустой:**

```
EFI\Boot\BOOTAA64.EFI                     MISSING
EFI\Microsoft\Boot\bootmgfw.efi           MISSING
EFI\Microsoft\Boot\BCD                    MISSING      <- вот этот
```

Без загрузочных файлов прошивка просто сообщит «загрузочное устройство не найдено».

**Хорошая новость: x64-версия `bcdboot` умеет писать загрузчик для ARM64-образа** и сама выбирает
`bootaa64.efi`:

```powershell
bcdboot G:\Windows /s S: /f UEFI /v
```

В логе видно, что она распознала ARM64 (`bootaa64.efi`):

```
BFSVC: Updating \\?\GLOBALROOT\Device\HarddiskVolume10\EFI\Boot\bootaa64.efi
BFSVC: Copy files which lack a version: y  G:\Windows\boot\EFI -> ...\EFI\Microsoft\Boot
```

Чек-лист после сборки (**должно выполняться всё**):

| Проверка | Ожидание |
|---|---|
| `S:\EFI\Boot\bootaa64.efi` | существует (резервный путь загрузки) |
| `S:\EFI\Microsoft\Boot\bootmgfw.efi` | существует |
| PE machine у `bootmgfw.efi` | **`0xAA64` (ARM64)** ← иначе не загрузится |
| `S:\EFI\Microsoft\Boot\BCD` | существует |
| Запись `path` в BCD | `\Windows\system32\winload.efi` |

### 2.4 Обход проверок TPM / SecureBoot / RAM (опционально)

> **Этот шаг опционален**: проверки аппаратных требований выполняются внутри
> **программы установки Windows**. Наш процесс применяет образ прямо в VHDX через
> `dism /Apply-Image` и никогда не запускает установку, поэтому система нормально
> загружается и работает без этих ключей реестра. Он становится обязательным только
> при переходе на традиционный путь «загрузиться с ISO и установить».

Windows 11 проверяет требования к оборудованию при первой загрузке. Обойдите это, записав реестр офлайн:

```powershell
reg load HKLM\OFFLINESYS G:\Windows\System32\config\SYSTEM
foreach ($n in 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck') {
    reg add 'HKLM\OFFLINESYS\Setup\LabConfig' /v $n /t REG_DWORD /d 1 /f
}
reg query 'HKLM\OFFLINESYS\Setup\LabConfig'
reg unload HKLM\OFFLINESYS
```

Без этого уже на первом шаге загрузки появится «Этот компьютер не соответствует минимальным требованиям
для запуска Windows 11».

### 2.5 Внедрить драйверы virtio

**Именование каталогов имеет значение** (это ключ к поиску нужного внутри ISO):

```
virtio-win.iso
├── Balloon\w11\ARM64\      balloon.sys  blnsvr.exe
├── NetKVM\w11\ARM64\       netkvm.sys
├── viostor\w11\ARM64\      viostor.sys     <- ОБЯЗАТЕЛЕН, если загружаетесь с virtio-blk
├── vioscsi\w11\ARM64\      vioscsi.sys
├── vioinput\w11\ARM64\     vioinput.sys  viohidkmdf.sys
├── viogpudo\w11\ARM64\     viogpudo.sys   <- драйвер вывода virtio-gpu
├── vioserial\w11\ARM64\    vioser.sys
├── viomem\w11\ARM64\ / viorng\w11\ARM64\ / viosock\w11\ARM64\ / viofs\w11\ARM64\ / pvpanic\w11\ARM64\
```

- Каталог для ARM64 называется **`ARM64`** (не `aarch64`! многие именно здесь не находят драйверы)
- Windows 11 использует подкаталог **`w11`** (Win10 — `w10`)

Внедрение:

```powershell
dism /Image:G:\ /Add-Driver /Driver:D:\virtio-arm64-w11 /Recurse
```

Успешный вывод:

```
Операция успешно завершена. Установлено драйверов: 12 из 12.
```

**После внедрения обязательно проверьте, что каждый `.sys` — это ARM64 PE** (machine = `0xAA64`):

```
Balloon      balloon.sys      ARM64 OK
NetKVM       netkvm.sys       ARM64 OK
pvpanic      pvpanic.sys      ARM64 OK
viofs        viofs.sys        ARM64 OK
viogpudo     viogpudo.sys     ARM64 OK
vioinput     viohidkmdf.sys   ARM64 OK
vioinput     vioinput.sys     ARM64 OK
viomem       viomem.sys       ARM64 OK
viorng       viorng.sys       ARM64 OK
vioscsi      vioscsi.sys      ARM64 OK
vioserial    vioser.sys       ARM64 OK
viosock      viosock.sys      ARM64 OK
viostor      viostor.sys      ARM64 OK      <- 13 файлов .sys, все 0xAA64
```

---

## 3. Скопировать на телефон и загрузиться

```bash
# Копирование (USB быстрее; /data/media/0 требует root, поэтому сначала в /data/local/tmp)
adb push win.vhdx /data/local/tmp/win.vhdx
adb shell su -c 'mkdir -p /data/media/0/DroidVM && mv /data/local/tmp/win.vhdx /data/media/0/DroidVM/'

# Убедиться, что места хватает (реальное использование вырастает до ~23 GB)
adb shell su -c 'df -h /data | tail -1'
```

Затем:

```bash
# Закинуть scripts/phone/boot-win.sh на телефон
adb push scripts/phone/boot-win.sh /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/boot-win.sh && nohup /data/local/tmp/boot-win.sh > /data/local/tmp/boot.out 2>&1 &'

# Смотреть экран
adb forward tcp:5900 tcp:5900
# VNC-клиент подключается к 127.0.0.1:5900 (без пароля)
```

### Первая загрузка (OOBE)

Занимает **5–15 минут**, по ходу дело она сама перезагружается один-два раза (после перезагрузки экран
может на миг почернеть — это нормально).

**Ключевые страницы**:

| Шаг | Страница | Что делать |
|---|---|---|
| 1 | Правильный ли это регион? | Выбрать свой → Да |
| 2 | Раскладка клавиатуры | Своя → Да |
| 3 | Вторая раскладка | Пропустить |
| 4 | **Подключим вас к сети** | Выбрать **«У меня нет интернета»** → **«Продолжить с ограниченной настройкой»** ← так создаётся **локальная учётная запись** вместо учётной записи Microsoft |
| 5 | Лицензионное соглашение | Принять |
| 6 | Кто будет использовать это устройство? | Ввести имя; **пустой пароль** — проще всего |
| 7 | Параметры конфиденциальности | Всё выключить → Принять |
| 8 | 🎉 Рабочий стол | Первая отрисовка рабочего стола тоже займёт пару минут |

**Если на шаге 4 нет пункта «У меня нет интернета»**:
нажмите `Shift + F10` для командной строки → введите `oobe\bypassnro` → устройство само перезагрузится,
и после этого на странице появится возможность пропустить.

### Рекомендации после установки

- **Установить службу баллонной памяти** (возвращает простаивающую память Android — на телефоне это очень ценно):
  подключите `virtio-win.iso` как CD (`boot-win.sh` подключает `/data/local/tmp/virtio-win.iso`
  автоматически), откройте привод в Windows → `Balloon\w11\ARM64\blnsvr.exe` → установить
- **Отключить визуальные эффекты** (заметное ускорение при программном рендеринге): Свойства системы →
  Дополнительно → Быстродействие → Обеспечить наилучшее быстродействие

---

## 4. Важный факт о «guest tools»

**В virtio-win нет установщика guest tools для ARM64.** Полный обход ISO:

```
guest-agent\qemu-ga-i386.msi        <- только x86
guest-agent\qemu-ga-x86_64.msi      <- только x64
virtio-win-gt-x64.msi               <- только x64
virtio-win-gt-x86.msi               <- только x86
virtio-win-guest-tools.exe          <- устанавливает перечисленное выше
```

**Так что не тратьте время на поиски ARM64-версии guest tools MSI — её не существует.**

В каталогах ARM64 лежат только **сами драйверы** и несколько **пригодных вспомогательных EXE**:

| Файл | Назначение |
|---|---|
| `blnsvr.exe` | Служба баллонной памяти (**стоит установить**) |
| `vgpusrv.exe` / `viogpuap.exe` | Пользовательские компоненты virtio-gpu |
| `virtiofs.exe` | Общие каталоги virtio-fs (нужен настроенный `vhost-user-fs` на стороне QEMU) |
| `netkvmco.exe` / `netkvmp.exe` | Утилиты настройки сетевой карты |
| `qemu-ga` | ❌ **сборки для ARM64 нет** |

**Основное внедрение драйверов уже сделано на шаге 2.5**, и этого достаточно.

---

## 5. Можно ли обойтись без диска virtio?

Да. **Windows 11 ARM64 содержит драйвер NVMe (`stornvme`)**, поэтому использование NVMe в качестве
загрузочного диска работает с **нулевым внедрением**:

```
-device nvme,serial=win,drive=nv0
```

**Компромисс**:

| Вариант | Нужно внедрение драйвера | Скорость | Примечания |
|---|---|---|---|
| **virtio-blk** (вариант по умолчанию в проекте) | ✅ нужен `viostor` | быстро | Нормально, когда драйвер внедрён |
| NVMe | ❌ не нужен | тоже быстро | Резервный вариант без внедрения |
| IDE/AHCI | ❌ | медленно | Не рекомендуется |

**Рекомендация**: раз драйверы всё равно внедрены, используйте `virtio-blk` (в одной связке с сетью,
GPU и баллоном — самое чистое решение). Если хочется сначала проверить «загружается ли этот диск вообще»,
можно применить NVMe, чтобы исключить фактор драйверов.

---

## 6. Что дальше

- **Как настраивать флаги QEMU** → [04-usage.md](04-usage.md)
- **Если возникла проблема** → [05-gotchas.md](05-gotchas.md)
