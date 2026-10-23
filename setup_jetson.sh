#!/bin/bash

# Сохраняем абсолютный путь к директории с архивами
ARCHIVE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Параметры по умолчанию
JETSON_USER="${JETSON_USER:-nvidia}"
JETSON_PASS="${JETSON_PASS:-nvidia}"
JETSON_HOST="${JETSON_HOST:-nvidia-agx-orin}"
DEPLOY_BASE_DIR="."
SILENT_MODE=false
FORCE_DELETE=false
SKIP_QEMU=false
ROOT_UART_AUTOLOGIN=true
JETSON_BOARD="${JETSON_BOARD:-jetson-agx-orin-devkit-noeeprom}"
L4T_VERSION="${L4T_VERSION:-}"
JETPACK_VERSION="${JETPACK_VERSION:-$(basename "$ARCHIVE_DIR")}" 
JETPACK_VERSION="${JETPACK_VERSION% }"

# Release archives are selected as a matching pair, so R36.4.x (JetPack 6.2.2)
# and R36.5.x (JetPack 6.2.3) deployments both work from this directory.
L4T_RELEASE_FILE=""
ROOTFS_FILE=""
SOURCES_FILE="public_sources.tbz2"
LOCAL_ROOTFS_OVERLAY_NAME="root_fs"
LOCAL_BOARD_CONFIG_NAME="b_conf"

# Helper for colored output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

usage() {
    echo "Использование: $0 [OPTIONS]"
    echo "Options:"
    echo "  -u, --user <name>      Имя пользователя (default: nvidia)"
    echo "  -p, --pass <pass>      Пароль (default: nvidia)"
    echo "  -n, --host <name>      Имя хоста (default: nvidia-agx-orin)"
    echo "  -d, --dir <path>       Базовый путь для развертывания (default: .)"
    echo "  -y, --yes              Тихий режим (пакетный режим)"
    echo "  -f, --force            Принудительное удаление старой установки"
    echo "  --skip-qemu            Пропустить этап QEMU chroot"
    echo "  --version <version>    Версия L4T (по умолчанию последняя полная пара)"
    echo "  --board <name>         Имя профиля flash.sh (default: jetson-agx-orin-devkit-noeeprom)"
    echo "  --jetpack-version <v>  Версия для выбора b_conf (по умолчанию имя каталога setup_jetson.sh)"
    echo "  --no-root-uart-login   Отключить root autologin на UART (default: включён)"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user) JETSON_USER="$2"; shift 2 ;;
        -p|--pass) JETSON_PASS="$2"; shift 2 ;;
        -n|--host) JETSON_HOST="$2"; shift 2 ;;
        -d|--dir) DEPLOY_BASE_DIR="$2"; shift 2 ;;
        -y|--yes) SILENT_MODE=true; shift ;;
        -f|--force) FORCE_DELETE=true; shift ;;
        --skip-qemu) SKIP_QEMU=true; shift ;;
        --no-root-uart-login) ROOT_UART_AUTOLOGIN=false; shift ;;
        --version) L4T_VERSION="$2"; shift 2 ;;
        --board) JETSON_BOARD="$2"; shift 2 ;;
        --jetpack-version) JETPACK_VERSION="$2"; shift 2 ;;
        *) usage ;;
    esac
done

# Приводим базовый путь к абсолютному
DEPLOY_BASE_DIR="$(mkdir -p "$DEPLOY_BASE_DIR" && cd "$DEPLOY_BASE_DIR" && pwd)"
TARGET_DIR="$DEPLOY_BASE_DIR/Linux_for_Tegra"
LOCAL_ROOTFS_OVERLAY="$ARCHIVE_DIR/$LOCAL_ROOTFS_OVERLAY_NAME"

confirm() {
    if [ "$SILENT_MODE" = true ]; then return 0; fi
    read -p "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

check_dependencies() {
    local deps=("pv" "tar" "sudo" "df" "awk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}Ошибка: $dep не установлен.${NC}"
            exit 1
        fi
    done
}

check_disk_space() {
    local path=$1
    echo -e "${GREEN}--- Проверка дискового пространства ---${NC}"
    local free_space=$(df -h "$path" | awk 'NR==2 {print $4}')
    local device=$(df -h "$path" | awk 'NR==2 {print $1}')
    echo -e "Путь: $path (Устройство: $device)"
    echo -e "Доступно: ${GREEN}$free_space${NC}"
    echo -e "----------------------------------------"
}

# Переменные для отслеживания общего прогресса
TOTAL_STEPS=8
CURRENT_STEP=0

select_release_pair() {
    local archive version rootfs
    local -a versions=()
    for archive in "$ARCHIVE_DIR"/Jetson_Linux_R[0-9]*_aarch64.tbz2; do
        [[ -f "$archive" ]] || continue
        version="${archive##*/Jetson_Linux_}"
        version="${version%_aarch64.tbz2}"
        rootfs="$ARCHIVE_DIR/Tegra_Linux_Sample-Root-Filesystem_${version}_aarch64.tbz2"
        if [[ -f "$rootfs" ]]; then
            [[ -z "$L4T_VERSION" || "$L4T_VERSION" == "$version" ]] && versions+=("$version")
        fi
    done
    if ((${#versions[@]} == 0)); then
        echo -e "${RED}Ошибка: не найдена согласованная пара Jetson_Linux и Sample-Root-Filesystem в $ARCHIVE_DIR (version=${L4T_VERSION:-latest})${NC}" >&2
        exit 1
    fi
    version="$(printf '%s\n' "${versions[@]}" | sort -Vu | tail -n1)"
    L4T_RELEASE_FILE="Jetson_Linux_${version}_aarch64.tbz2"
    ROOTFS_FILE="Tegra_Linux_Sample-Root-Filesystem_${version}_aarch64.tbz2"
    echo "Выбрана пара исходников L4T ${version}."
}

update_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${GREEN}[Шаг $CURRENT_STEP из $TOTAL_STEPS] $1${NC}"
}

extract_with_progress() {
    local archive_path="$ARCHIVE_DIR/$1"
    local dest_dir="$2"
    local desc="$3"
    
    if [ ! -f "$archive_path" ]; then
        echo -e "${RED}Ошибка: $archive_path не найден.${NC}"
        return 1
    fi

    local size_bytes=$(stat -c%s "$archive_path")
    local size_human=$(du -h "$archive_path" | awk '{print $1}')
    echo -e "${GREEN}Распаковка $desc...${NC}"
    
    # Формат pv: %p-процент, %t-время, %e-ETA, %r-скорость, %b-байты
    # Мы вставляем size_human прямо в строку формата, так как %s может не работать
    pv -F "%p %t %e [%r] [%b / $size_human] " -s "$size_bytes" "$archive_path" | sudo tar -xjf - -C "$dest_dir"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}Успешно: $desc${NC}"
        return 0
    else
        echo -e "${RED}Ошибка при распаковке $desc${NC}"
        return 1
    fi
}

deploy_system() {
    echo -e "${GREEN}=== Начало процесса развертывания ===${NC}"
    
    # 1. Extract L4T Core
    update_step "Распаковка ядра L4T"
    extract_with_progress "$L4T_RELEASE_FILE" "$DEPLOY_BASE_DIR" "L4T Core" || exit 1
    
    # 2. Extract RootFS
    update_step "Распаковка Sample RootFS"
    sudo mkdir -p "$TARGET_DIR/rootfs"
    extract_with_progress "$ROOTFS_FILE" "$TARGET_DIR/rootfs" "Sample RootFS" || exit 1
    
    # 3. Apply Binaries
    update_step "Применение бинарных файлов NVIDIA"
    cd "$TARGET_DIR" || exit 1
    if sudo ./apply_binaries.sh; then
        echo -e "${GREEN}Бинарные файлы применены.${NC}"
    else
        echo -e "${RED}Ошибка apply_binaries.sh${NC}"
        exit 1
    fi
    
    # 4. Create User
    update_step "Настройка пользователя: $JETSON_USER"
    if sudo ./tools/l4t_create_default_user.sh -u "$JETSON_USER" -p "$JETSON_PASS" -a -n "$JETSON_HOST" --accept-license; then
        echo -e "${GREEN}Пользователь создан.${NC}"
    else
        echo -e "${RED}Ошибка создания пользователя.${NC}"
        exit 1
    fi

    # l4t_create_default_user.sh may replace getty configuration, so configure
    # the UART login only after this command has completed.
    
    # 5. Overlay files
    update_step "Копирование Overlay (root_fs)"
    if [ -d "$LOCAL_ROOTFS_OVERLAY" ]; then
        if sudo cp -r "$LOCAL_ROOTFS_OVERLAY"/* "$TARGET_DIR/rootfs/"; then
            echo -e "${GREEN}Содержимое root_fs успешно скопировано в RootFS.${NC}"
        else
            echo -e "${RED}Ошибка при копировании Overlay!${NC}"
            exit 1
        fi
    else
        echo -e "Папка $LOCAL_ROOTFS_OVERLAY не найдена, пропускаю overlay."
    fi
    
    # 6. Public Sources (optional)
    if [ -f "$ARCHIVE_DIR/$SOURCES_FILE" ]; then
       echo -e "\n[Опционально] Распаковка Sources"
       extract_with_progress "$SOURCES_FILE" "$TARGET_DIR" "Public Sources" || exit 1
    fi
    
    echo -e "\n${GREEN}=== Развертывание выполнено успешно ===${NC}"
}

copy_board_configuration() {
    local board_dir="$ARCHIVE_DIR/$LOCAL_BOARD_CONFIG_NAME"
    local bundle_dir payload
    [[ -d "$TARGET_DIR" ]] || { echo -e "${RED}Ошибка: L4T не развернут в $TARGET_DIR${NC}" >&2; return 1; }
    [[ -f "$board_dir/select_config.sh" ]] || { echo -e "${RED}Селектор b_conf не найден: $board_dir/select_config.sh${NC}" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$board_dir/select_config.sh"
    bundle_dir="$(b_conf_select_package "$board_dir" "$JETSON_BOARD" "$JETPACK_VERSION")" || return 1
    payload="$bundle_dir/Linux_for_Tegra"
    [[ -f "$payload/${JETSON_BOARD}.conf" ]] || {
        echo -e "${RED}В пакете нет профиля ${JETSON_BOARD}.conf: $payload${NC}" >&2
        return 1
    }

    update_step "Установка b_conf: $JETSON_BOARD для JetPack $JETPACK_VERSION"
    b_conf_install_payload "$payload" "$TARGET_DIR" || return 1

    echo -e "${GREEN}Выбран пакет: $bundle_dir${NC}"
    [[ -f "$bundle_dir/COMPATIBILITY.md" ]] && echo "Журнал совместимости: $bundle_dir/COMPATIBILITY.md"
}

apply_debian_patches() {
    [[ -x "$ARCHIVE_DIR/setup_debian.sh" ]] || {
        echo -e "${RED}Ошибка: Bash-патчер $ARCHIVE_DIR/setup_debian.sh не найден или не исполняемый${NC}" >&2
        return 1
    }
    update_step "Применение патчей совместимости L4T"
    sudo "$ARCHIVE_DIR/setup_debian.sh" --board "$JETSON_BOARD" --version "${L4T_VERSION_SELECTED}"
}

configure_root_uart_login() {
    local rootfs="$TARGET_DIR/rootfs"
    local dropin="$rootfs/etc/systemd/system/serial-getty@ttyTCU0.service.d/autologin.conf"
    [[ -d "$rootfs/etc/systemd/system" ]] || { echo "systemd unit directory unavailable; UART autologin not configured."; return 0; }
    if [[ "$ROOT_UART_AUTOLOGIN" == true ]]; then
        sudo mkdir -p "$(dirname "$dropin")"
        sudo tee "$dropin" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I ${TERM}
EOF
        echo "Enabled passwordless root autologin on serial-getty@ttyTCU0.service. Disable with --no-root-uart-login."
    else
        sudo rm -f "$dropin"
        echo "Passwordless root UART autologin disabled."
    fi
}

setup_qemu_chroot() {
    local rootfs_path="$TARGET_DIR/rootfs"
    echo -e "${GREEN}=== Вход в QEMU Chroot ===${NC}"
    
    if ! command -v qemu-aarch64-static &> /dev/null; then
        echo "Установка qemu-user-static на хост..."
        sudo apt-get update && sudo apt-get install -y qemu-user-static
    fi
    
    sudo cp /usr/bin/qemu-aarch64-static "$rootfs_path/usr/bin/"
    
    echo "Монтирование ресурсов..."
    sudo mount -t proc /proc "$rootfs_path/proc"
    sudo mount -t sysfs /sys "$rootfs_path/sys"
    sudo mount --bind /dev "$rootfs_path/dev"
    sudo mount --bind /dev/pts "$rootfs_path/dev/pts"
    
    # Резервное копирование resolv.conf
    [ -f "$rootfs_path/etc/resolv.conf" ] && sudo mv "$rootfs_path/etc/resolv.conf" "$rootfs_path/etc/resolv.conf.bak"
    sudo cp /etc/resolv.conf "$rootfs_path/etc/resolv.conf"

    echo -e "${GREEN}Вход в окружение (с подавлением ошибок локалей)...${NC}"
    # Запускаем chroot с чистыми переменными локали
    sudo chroot "$rootfs_path" /usr/bin/env LANG=C LC_ALL=C LANGUAGE=C /bin/bash

    echo "Размонтирование ресурсов..."
    sudo umount "$rootfs_path/proc" || true
    sudo umount "$rootfs_path/sys" || true
    sudo umount "$rootfs_path/dev/pts" || true
    sudo umount "$rootfs_path/dev" || true
    
    # Восстановление resolv.conf
    sudo rm "$rootfs_path/etc/resolv.conf"
    [ -f "$rootfs_path/etc/resolv.conf.bak" ] && sudo mv "$rootfs_path/etc/resolv.conf.bak" "$rootfs_path/etc/resolv.conf"
    
    echo -e "${GREEN}Завершено.${NC}"
}

# --- Начало выполнения ---

check_dependencies
select_release_pair
L4T_VERSION_SELECTED="${L4T_RELEASE_FILE#Jetson_Linux_}"
L4T_VERSION_SELECTED="${L4T_VERSION_SELECTED%_aarch64.tbz2}"

# Проверка текущего статуса
DEPLOY_STATUS="не развернуто"
if [ -d "$TARGET_DIR" ]; then
    DEPLOY_STATUS="обнаружено в $TARGET_DIR"
fi

echo -e "Целевая директория: ${GREEN}$TARGET_DIR${NC}"
echo -e "Текущее состояние: ${GREEN}$DEPLOY_STATUS${NC}"

WANT_DEPLOY=false
if [ -d "$TARGET_DIR" ]; then
    if [ "$FORCE_DELETE" = true ]; then
        WANT_DEPLOY=true
    elif [ "$SILENT_MODE" = true ]; then
        echo "Тихий режим не удаляет существующее развертывание; используем его. Для пересоздания укажите --force."
        WANT_DEPLOY=false
    elif confirm "Удалить существующее развертывание в $TARGET_DIR?"; then
        echo "Удаление старых данных..."
        sudo rm -rf "$TARGET_DIR"
        WANT_DEPLOY=true
    elif confirm "Попробовать развернуть поверх?"; then
        WANT_DEPLOY=true
    fi
else
    if confirm "Развернуть новую систему Jetson L4T?"; then
        WANT_DEPLOY=true
    fi
fi

if [ "$WANT_DEPLOY" = true ]; then
    check_disk_space "$DEPLOY_BASE_DIR"
    deploy_system
fi

if [ -d "$TARGET_DIR" ]; then
    copy_board_configuration || exit 1
    apply_debian_patches || exit 1
    echo -e "\n${GREEN}Подготовка завершена. После включения платы и подтверждения режима Recovery запустить:${NC}"
    echo "  cd \"$TARGET_DIR\" && sudo ./flash.sh $JETSON_BOARD mmcblk0p1"
fi

# QEMU Шаг всегда спрашиваем, если не пропущен флагом
if [ "$SKIP_QEMU" = false ]; then
    if confirm "Требуется ли войти в chroot через QEMU для настройки?"; then
        setup_qemu_chroot
    fi
fi

# Must remain the final rootfs mutation: l4t_create_default_user.sh and an
# optional QEMU session can alter the image, so configure UART login last.
if [[ -d "$TARGET_DIR/rootfs" ]]; then
    configure_root_uart_login
fi

echo -e "${GREEN}Работа скрипта завершена.${NC}"
