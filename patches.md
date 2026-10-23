# Патчи для прошивки NVIDIA L4T (JetPack 6.x) на Debian 12/13

Этот документ содержит описание изменений, необходимых для корректной работы `flash.sh` и вспомогательных скриптов NVIDIA на дистрибутивах Debian.

## 1. Необходимые системные пакеты
Перед началом работы на чистой системе Debian необходимо установить следующие зависимости:

```bash
sudo apt-get update
sudo apt-get install -y \
    abootimg \
    xmlstarlet \
    gdisk \
    parted \
    cpio \
    gzip \
    strings \
    sshpass \
    ssh-keygen
```

## 2. Патч скрипта формирования Recovery Image
Файл: `tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh`

### Изменение А: Обработка символов возврата каретки (\r)
В списках файлов (`binlist`) NVIDIA могут присутствовать символы `\r`, которые ломают пути в Linux. Мы добавили `tr -d '\r'`.

**До:**
```bash
grep -E "^(jammy|all)" "${_binlist_file}" | sed \
    -e "s|<ARCH>|${_librariesdir}|g" \
    ... >"${_tmp_list_file}"
```

**После:**
```bash
grep -E "^(jammy|all)" "${_binlist_file}" | sed \
    -e "s|<ARCH>|${_librariesdir}|g" \
    ... | tr -d '\r' >"${_tmp_list_file}"
```

### Изменение Б: Подавление ошибок проверки сжатия
Некоторые ядра не сжаты через gzip, что вызывало лишние ошибки в stderr.

**Изменено на:**
```bash
if gzip -t "${_kernel_fs}" > /dev/null 2>&1 ; then
```

### Изменение В: Проверка существования файлов перед `sed -i`
Если файл (например, `dhclient-script`) отсутствует в текущей конфигурации, `sed -i` вернет ошибку, которая прервет весь процесс. Добавлены проверки `if [ -f ...]`.

**Пример:**
```bash
if [ -f "${_initrd_dir}/sbin/dhclient-script" ]; then
    sed -i 's/\/bin\/sh/\/bin\/bash/' "${_initrd_dir}/sbin/dhclient-script"; check_error
fi
```

### Изменение Г: Ослабление требований к DSA-ключам
Современные версии `ssh-keygen` в Debian блокируют создание DSA-ключей (Error 255). Мы изменили `check_error` на `check_warning`.

**Изменено на:**
```bash
ssh-keygen -t dsa ... ; check_warning "ssh-keygen -t dsa"
```

---

## 3. Рекомендации по использованию
При возникновении ошибки `command is failed` без описания в будущем, рекомендуется временно добавить `set -x` в начало функции `ota_make_recovery_img`, чтобы увидеть, какая именно системная команда возвращает не нулевой код.

**Результат:** После применения данных правок прошивка успешно завершается сообщением:
`The target generic has been flashed successfully.`
