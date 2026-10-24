#!/bin/bash

# Project resources stay beside this script; release archives and deployment
# output can be stored independently.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SHARED_DIR="/opt/nvidia/jp/6.2.3"
ARCHIVE_DIR="${JETSON_ARCHIVE_DIR:-}"
DEPLOY_BASE_DIR="${JETSON_DEPLOY_DIR:-}"
# shellcheck source=lib/qemu_resolv.sh
source "$PROJECT_DIR/lib/qemu_resolv.sh"
# shellcheck source=lib/qemu_apt.sh
source "$PROJECT_DIR/lib/qemu_apt.sh"
# shellcheck source=lib/rootfs_cleanup.sh
source "$PROJECT_DIR/lib/rootfs_cleanup.sh"
# shellcheck source=lib/root_uart.sh
source "$PROJECT_DIR/lib/root_uart.sh"
# shellcheck source=lib/rootfs_release_fixes.sh
source "$PROJECT_DIR/lib/rootfs_release_fixes.sh"
# shellcheck source=lib/qemu_chroot.sh
source "$PROJECT_DIR/lib/qemu_chroot.sh"
# shellcheck source=lib/qemu_session.sh
source "$PROJECT_DIR/lib/qemu_session.sh"
# shellcheck source=lib/l4t_mount_cleanup.sh
source "$PROJECT_DIR/lib/l4t_mount_cleanup.sh"
# shellcheck source=lib/progress.sh
source "$PROJECT_DIR/lib/progress.sh"
# shellcheck source=lib/terminal_status.sh
source "$PROJECT_DIR/lib/terminal_status.sh"

# Default settings
JETSON_USER="${JETSON_USER:-nvidia}"
JETSON_PASS="${JETSON_PASS:-nvidia}"
JETSON_HOST="${JETSON_HOST:-nvidia-agx-orin}"
SILENT_MODE=false
FORCE_DELETE=false
SKIP_QEMU=false
SKIP_DEBIAN_PATCHES=false
ROOT_UART_AUTOLOGIN=true
BOARD_WAS_EXPLICIT=false
if [[ -n "${JETSON_BOARD:-}" ]]; then BOARD_WAS_EXPLICIT=true; fi
JETSON_BOARD="${JETSON_BOARD:-jetson-agx-orin-devkit-noeeprom}"
JETSON_MODULE="${JETSON_MODULE:-}"
L4T_VERSION="${L4T_VERSION:-}"
JETPACK_VERSION="${JETPACK_VERSION:-}"
PRINT_PATHS=false
APT_UPGRADE_BATCH=false
FORCE_QEMU_CLEANUP=false
FORCE_CUSTOM_REPOSITORIES=false
ROOTFS_CLEANUP_ENABLED=true
REQUIRE_BOARD_PROFILE=false
NVIDIA_PROFILE_SELECTION="${JETSON_NVIDIA_PROFILE:-}"
BOARD_PROFILE_DIR=""
BOARD_PROFILE_ERROR=""
BOARD_PROFILE_AVAILABLE=false
BOARD_CONFIG_AVAILABLE=false
APT_PACKAGES_FILE="${JETSON_APT_PACKAGES_FILE:-$PROJECT_DIR/qemu-packages.txt}"

case "${JETSON_SKIP_DEBIAN_PATCHES:-0}" in
    1) SKIP_DEBIAN_PATCHES=true ;;
    0) ;;
    *) echo "JETSON_SKIP_DEBIAN_PATCHES must be 0 or 1" >&2; exit 2 ;;
esac
case "${JETSON_APT_UPGRADE:-0}" in
    1) APT_UPGRADE_BATCH=true ;;
    0) ;;
    *) echo "JETSON_APT_UPGRADE must be 0 or 1" >&2; exit 2 ;;
esac
case "${JETSON_FORCE_CUSTOM_REPOSITORIES:-0}" in
    1) FORCE_CUSTOM_REPOSITORIES=true ;;
    0) ;;
    *) qemu_apt_validate_force_repositories "${JETSON_FORCE_CUSTOM_REPOSITORIES}"; exit 2 ;;
esac
case "${JETSON_SKIP_ROOTFS_CLEANUP:-0}" in
    1) ROOTFS_CLEANUP_ENABLED=false ;;
    0) ;;
    *) echo "JETSON_SKIP_ROOTFS_CLEANUP must be 0 or 1" >&2; exit 2 ;;
esac
case "${JETSON_REQUIRE_BOARD_PROFILE:-0}" in
    1) REQUIRE_BOARD_PROFILE=true ;;
    0) ;;
    *) echo "JETSON_REQUIRE_BOARD_PROFILE must be 0 or 1" >&2; exit 2 ;;
esac

# Release archives are selected as a matching pair. L4T R32.7.6 also supports
# NVIDIA's separate Xavier and Jetson-210 BSP archive names.
L4T_RELEASE_FILE=""
L4T_VERSION_SELECTED=""
ROOTFS_FILE=""
SOURCES_FILE="public_sources.tbz2"
LOCAL_ROOTFS_OVERLAY_NAME="root_fs"
LOCAL_BOARD_CONFIG_NAME="b_conf"

# Helper for colored output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -u, --user <name>      User name (default: nvidia)"
    echo "  -p, --pass <pass>      Password (default: nvidia)"
    echo "  -n, --host <name>      Host name (default: nvidia-agx-orin)"
    echo "  --archive-dir <path>   Directory containing NVIDIA archives"
    echo "  --deploy-dir <path>    Deployment base directory (creates Linux_for_Tegra/)"
    echo "  -d, --dir <path>       Alias for --deploy-dir"
    echo "                         Default shared path: $DEFAULT_SHARED_DIR"
    echo "  --print-paths          Show resolved paths and exit"
    echo "  -y, --yes              Non-interactive batch mode"
    echo "  -f, --force            Remove an existing deployment"
    echo "  --skip-qemu            Skip the interactive QEMU shell"
    echo "  --no-rootfs-cleanup    Keep rootfs caches, temporary files, logs, and histories"
    echo "  JETSON_QEMU_NAMESERVERS=... DNS servers for rootfs without nameservers (default: 8.8.8.8 1.1.1.1)"
    echo "  --force-qemu-cleanup   Terminate/recover a stale QEMU session in batch mode"
    echo "  --apt-upgrade          Run apt update/upgrade in batch mode"
    echo "  --force-repositories   Try the matching custom APT repository profile after source errors"
    echo "  JETSON_FORCE_CUSTOM_REPOSITORIES=1  Enable custom APT repository profiles"
    echo "  --apt-packages-file <path> Package list file (default: $APT_PACKAGES_FILE)"
    echo "  JETSON_APT_UPGRADE=1   Enable apt update/upgrade in batch mode"
    echo "  --skip-debian-patches  Do not run setup_debian.sh"
    echo "  --version <version>    L4T version (default: latest complete archive pair)"
    echo "  --board <name>         flash.sh profile (default: jetson-agx-orin-devkit-noeeprom)"
    echo "  --nvidia-profile <name|number>  Select a stock NVIDIA profile when no b_conf profile matches"
    echo "  --module <name>        Module family for profile selection (or JETSON_MODULE)"
    echo "  --require-board-profile  Fail before deployment if no compatible b_conf profile exists"
    echo "  --jetpack-version <v>  b_conf version (default: archive directory or parent name)"
    echo "  --no-root-uart-login   Disable root UART autologin (default: enabled)"
    echo "  -h, --help             Show this help"
    echo "Environment variables:"
    echo "  JETSON_ARCHIVE_DIR, JETSON_DEPLOY_DIR  Archive and deployment base paths."
    echo "  JETPACK_VERSION, L4T_VERSION          Select b_conf and matching L4T archives."
    echo "  JETSON_BOARD, JETSON_USER, JETSON_PASS, JETSON_HOST  Board/default-user settings."
    echo "  JETSON_MODULE                         Module family for b_conf selection."
    echo "  JETSON_NVIDIA_PROFILE                 Stock NVIDIA profile name or 1-based list number."
    echo "  JETSON_REQUIRE_BOARD_PROFILE=0|1     Require a compatible b_conf profile (default: 0)."
    echo "  JETSON_SKIP_DEBIAN_PATCHES=0|1        Apply Debian patches (default) or skip them."
    echo "  JETSON_APT_UPGRADE=0|1                 Enable batch rootfs apt update/upgrade."
    echo "  JETSON_APT_PACKAGES_FILE               Package list for rootfs APT operations."
    echo "  JETSON_FORCE_CUSTOM_REPOSITORIES=0|1   Allow custom repository profiles after APT errors."
    echo "  JETSON_SKIP_ROOTFS_CLEANUP=0|1         Keep rootfs transient files when set to 1."
    echo "  JETSON_QEMU_NAMESERVERS                Space-separated rootfs DNS fallback servers."
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user) JETSON_USER="$2"; shift 2 ;;
        -p|--pass) JETSON_PASS="$2"; shift 2 ;;
        -n|--host) JETSON_HOST="$2"; shift 2 ;;
        --archive-dir) ARCHIVE_DIR="$2"; shift 2 ;;
        --deploy-dir) DEPLOY_BASE_DIR="$2"; shift 2 ;;
        -d|--dir) DEPLOY_BASE_DIR="$2"; shift 2 ;;
        --print-paths) PRINT_PATHS=true; shift ;;
        -y|--yes) SILENT_MODE=true; shift ;;
        -f|--force) FORCE_DELETE=true; shift ;;
        --skip-qemu) SKIP_QEMU=true; shift ;;
        --no-rootfs-cleanup) ROOTFS_CLEANUP_ENABLED=false; shift ;;
        --force-qemu-cleanup) FORCE_QEMU_CLEANUP=true; shift ;;
        --apt-upgrade) APT_UPGRADE_BATCH=true; shift ;;
        --force-repositories) FORCE_CUSTOM_REPOSITORIES=true; shift ;;
        --apt-packages-file) APT_PACKAGES_FILE="${2:?--apt-packages-file requires a path}"; shift 2 ;;
        --skip-debian-patches) SKIP_DEBIAN_PATCHES=true; shift ;;
        --no-root-uart-login) ROOT_UART_AUTOLOGIN=false; shift ;;
        --version) L4T_VERSION="$2"; shift 2 ;;
        --board) JETSON_BOARD="$2"; BOARD_WAS_EXPLICIT=true; shift 2 ;;
        --nvidia-profile) NVIDIA_PROFILE_SELECTION="${2:?--nvidia-profile requires a name or number}"; shift 2 ;;
        --module) JETSON_MODULE="$2"; shift 2 ;;
        --require-board-profile) REQUIRE_BOARD_PROFILE=true; shift ;;
        --jetpack-version) JETPACK_VERSION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$ARCHIVE_DIR" && -z "$DEPLOY_BASE_DIR" ]]; then
    ARCHIVE_DIR="$DEFAULT_SHARED_DIR"
    DEPLOY_BASE_DIR="$DEFAULT_SHARED_DIR"
elif [[ -z "$ARCHIVE_DIR" ]]; then
    ARCHIVE_DIR="$DEPLOY_BASE_DIR"
elif [[ -z "$DEPLOY_BASE_DIR" ]]; then
    DEPLOY_BASE_DIR="$ARCHIVE_DIR"
fi

ARCHIVE_DIR="$(realpath -m -- "$ARCHIVE_DIR")"
DEPLOY_BASE_DIR="$(realpath -m -- "$DEPLOY_BASE_DIR")"
[[ "$APT_PACKAGES_FILE" = /* ]] || APT_PACKAGES_FILE="$PWD/$APT_PACKAGES_FILE"
APT_PACKAGES_FILE="$(realpath -m -- "$APT_PACKAGES_FILE")"
TARGET_DIR="$DEPLOY_BASE_DIR/Linux_for_Tegra"
QEMU_SESSION_LOCK_FILE="$DEPLOY_BASE_DIR/.jetson-qemu-session.lock"
QEMU_SESSION_HELD=false
QEMU_ROOTFS_ACTIVE=""
LOCAL_ROOTFS_OVERLAY="$PROJECT_DIR/$LOCAL_ROOTFS_OVERLAY_NAME"
if [[ -z "$JETPACK_VERSION" ]]; then
    archive_version_dir="$(basename -- "$ARCHIVE_DIR")"
    if [[ "$archive_version_dir" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        JETPACK_VERSION="$archive_version_dir"
    else
        parent_version_dir="$(basename -- "$(dirname -- "$ARCHIVE_DIR")")"
        JETPACK_VERSION="$parent_version_dir"
    fi
fi

if [[ "$PRINT_PATHS" == true ]]; then
    printf 'Project resources: %s\n' "$PROJECT_DIR"
    printf 'Archive directory: %s\n' "$ARCHIVE_DIR"
    printf 'Deployment base directory: %s\n' "$DEPLOY_BASE_DIR"
    printf 'L4T directory: %s\n' "$TARGET_DIR"
    printf 'JetPack version: %s\n' "$JETPACK_VERSION"
    printf 'Module family: %s\n' "${JETSON_MODULE:-auto}"
    printf 'NVIDIA stock profile selection: %s\n' "${NVIDIA_PROFILE_SELECTION:-interactive or required in batch mode}"
    if [[ "$REQUIRE_BOARD_PROFILE" == true ]]; then
        printf 'Board profile required: enabled\n'
    else
        printf 'Board profile required: disabled\n'
    fi
    if [[ "$SKIP_DEBIAN_PATCHES" == true ]]; then
        printf 'Debian patches: skipped\n'
    else
        printf 'Debian patches: enabled\n'
    fi
    if [[ "$APT_UPGRADE_BATCH" == true ]]; then
        printf 'Rootfs apt update/upgrade (batch): enabled\n'
    else
        printf 'Rootfs apt update/upgrade (batch): disabled\n'
    fi
    if [[ "$ROOTFS_CLEANUP_ENABLED" == true ]]; then
        printf 'Rootfs transient cleanup: enabled\n'
    else
        printf 'Rootfs transient cleanup: disabled\n'
    fi
    printf 'APT package list: %s\n' "$APT_PACKAGES_FILE"
    if [[ "$FORCE_CUSTOM_REPOSITORIES" == true ]]; then
        printf 'Custom APT repositories (force): enabled\n'
    else
        printf 'Custom APT repositories (force): disabled\n'
    fi
    exit 0
fi

[[ -d "$ARCHIVE_DIR" ]] || { echo -e "${RED}Error: archive directory not found: $ARCHIVE_DIR${NC}" >&2; exit 1; }
mkdir -p -- "$DEPLOY_BASE_DIR"
DEPLOY_BASE_DIR="$(cd -- "$DEPLOY_BASE_DIR" && pwd)"
TARGET_DIR="$DEPLOY_BASE_DIR/Linux_for_Tegra"

confirm() {
    if [ "$SILENT_MODE" = true ]; then return 0; fi
    read -p "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

host_command_available() {
    local command_name="$1"
    local directory

    command -v "$command_name" >/dev/null 2>&1 && return 0
    for directory in /usr/local/sbin /usr/sbin /sbin; do
        [[ -x "$directory/$command_name" ]] && return 0
    done
    return 1
}

check_dependencies() {
    local deps=("pv" "tar" "sudo" "df" "awk" "setpriv" "flock" "mountpoint" "findmnt" "losetup" "umount" "ps" "patch")
    for dep in "${deps[@]}"; do
        if ! host_command_available "$dep"; then
            echo -e "${RED}Error: required command '$dep' is not installed.${NC}"
            exit 1
        fi
    done
}

check_disk_space() {
    local path=$1
    echo -e "${GREEN}--- Disk space check ---${NC}"
    local free_space=$(df -h "$path" | awk 'NR==2 {print $4}')
    local device=$(df -h "$path" | awk 'NR==2 {print $1}')
    echo -e "Path: $path (Device: $device)"
    echo -e "Available: ${GREEN}$free_space${NC}"
    echo -e "----------------------------------------"
}

# Overall progress tracking
TOTAL_STEPS=0
CURRENT_STEP=0

select_release_pair() {
    local archive version rootfs preferred=""
    local -a versions=()
    for archive in "$ARCHIVE_DIR"/Jetson_Linux_R[0-9]*_aarch64.tbz2 \
                   "$ARCHIVE_DIR"/Jetson-210_Linux_R[0-9]*_aarch64.tbz2; do
        [[ -f "$archive" ]] || continue
        version="${archive##*/Jetson_Linux_}"
        [[ "$archive" == *Jetson-210_Linux_* ]] && version="${archive##*/Jetson-210_Linux_}"
        version="${version%_aarch64.tbz2}"
        rootfs="$ARCHIVE_DIR/Tegra_Linux_Sample-Root-Filesystem_${version}_aarch64.tbz2"
        if [[ -f "$rootfs" ]]; then
            [[ -z "$L4T_VERSION" || "$L4T_VERSION" == "$version" ]] && versions+=("$version")
        fi
    done
    if ((${#versions[@]} == 0)); then
        echo -e "${RED}Error: no matching Jetson_Linux and Sample-Root-Filesystem archive pair found in $ARCHIVE_DIR (version=${L4T_VERSION:-latest})${NC}" >&2
        exit 1
    fi
    version="$(printf '%s\n' "${versions[@]}" | sort -Vu | tail -n1)"
    if [[ "$JETSON_MODULE" == nano-2gb || "$JETSON_MODULE" == tx1 || "$JETSON_BOARD" == *nano* || "$JETSON_BOARD" == *tx1* ]]; then
        preferred="Jetson-210_Linux_${version}_aarch64.tbz2"
    else
        preferred="Jetson_Linux_${version}_aarch64.tbz2"
    fi
    if [[ -f "$ARCHIVE_DIR/$preferred" ]]; then
        L4T_RELEASE_FILE="$preferred"
    elif [[ -f "$ARCHIVE_DIR/Jetson_Linux_${version}_aarch64.tbz2" ]]; then
        L4T_RELEASE_FILE="Jetson_Linux_${version}_aarch64.tbz2"
    elif [[ -f "$ARCHIVE_DIR/Jetson-210_Linux_${version}_aarch64.tbz2" ]]; then
        L4T_RELEASE_FILE="Jetson-210_Linux_${version}_aarch64.tbz2"
    else
        echo -e "${RED}Error: BSP archive missing for L4T $version in $ARCHIVE_DIR${NC}" >&2
        exit 1
    fi
    ROOTFS_FILE="Tegra_Linux_Sample-Root-Filesystem_${version}_aarch64.tbz2"
    L4T_VERSION_SELECTED="$version"
    validate_module_for_source_pair "$JETSON_MODULE" "$JETPACK_VERSION" "$L4T_RELEASE_FILE" || exit 1
    echo "Selected L4T source pair: ${version}."
    printf 'Current JetPack version: %s\n' "$JETPACK_VERSION"
    if [[ "$JETPACK_VERSION" == 4.6.6 ]]; then
        case "$L4T_RELEASE_FILE" in
            Jetson-210_Linux_*) echo 'Selected BSP archive set: Nano2g_TX1.' ;;
            Jetson_Linux_*) echo 'Selected BSP archive set: Xavier.' ;;
        esac
        printf 'Supported modules for JetPack %s in selected BSP: %s\n' "$JETPACK_VERSION" \
            "$(supported_modules_for_source_pair "$JETPACK_VERSION" "$L4T_RELEASE_FILE")"
    else
        printf 'Supported modules for JetPack %s: %s\n' "$JETPACK_VERSION" \
            "$(supported_modules_for_jetpack "$JETPACK_VERSION")"
    fi
}

supported_modules_for_jetpack() {
    local version="${1:-}" module_root selector_dir profile_dir profile resolved
    local -a modules=()
    [[ -n "$version" ]] || { printf 'unknown\n'; return 0; }
    # shellcheck source=b_conf/select_config.sh
    source "$PROJECT_DIR/b_conf/select_config.sh"
    for module_root in "$PROJECT_DIR"/b_conf/modules/*; do
        [[ -d "$module_root" ]] || continue
        for selector_dir in "$module_root"/*; do
            [[ -d "$selector_dir" ]] || continue
            for profile_dir in "$selector_dir"/*; do
                [[ -d "$profile_dir" ]] || continue
                profile="${profile_dir##*/}"
                resolved="$(b_conf_select_package "$PROJECT_DIR/b_conf" "$profile" "$version" "${module_root##*/}" 2>/dev/null || true)"
                if [[ "$resolved" == "$profile_dir" ]]; then
                    modules+=("${module_root##*/}")
                    break 2
                fi
            done
        done
    done
    if ((${#modules[@]})); then
        local sorted_modules
        sorted_modules="$(printf '%s\n' "${modules[@]}" | sort -u)"
        local first=true
        while IFS= read -r module; do
            [[ -n "$module" ]] || continue
            if [[ "$first" == true ]]; then
                printf '%s' "$module"
                first=false
            else
                printf ', %s' "$module"
            fi
        done <<< "$sorted_modules"
        printf '\n'
    else
        printf 'none\n'
    fi
}

supported_modules_for_source_pair() {
    local version="${1:-}" release_file="${2:-}"
    if [[ "$version" == 4.6.6 ]]; then
        case "$release_file" in
            Jetson-210_Linux_R32.7.6_*) printf 'nano, nano-2gb, tx1\n'; return 0 ;;
            Jetson_Linux_R32.7.6_*) printf 'tx2, xavier-agx, xavier-nx\n'; return 0 ;;
        esac
    fi
    supported_modules_for_jetpack "$version"
}

validate_module_for_source_pair() {
    local module="${1:-}" version="${2:-}" release_file="${3:-}"
    local supported_modules archive_set
    [[ -n "$module" && "$version" == 4.6.6 ]] || return 0
    case "$release_file" in
        Jetson-210_Linux_R32.7.6_*) supported_modules='nano,nano-2gb,tx1'; archive_set='Nano2g_TX1' ;;
        Jetson_Linux_R32.7.6_*) supported_modules='tx2,xavier-agx,xavier-nx'; archive_set='Xavier' ;;
        *) return 0 ;;
    esac
    case ",$supported_modules," in
        *",$module,"*) return 0 ;;
    esac
    print_error "Module $module is not included in the JetPack 4.6.6 $archive_set archive set. Supported modules in this set: $supported_modules. Select the matching archive directory."
    return 1
}

update_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${GREEN}[Step $CURRENT_STEP of $TOTAL_STEPS] $1${NC}"
}

print_notice() {
    echo -e "${GREEN}$*${NC}"
}

print_warning() {
    echo -e "${YELLOW}Warning: $*${NC}" >&2
}

print_error() {
    echo -e "${RED}$*${NC}" >&2
}

stock_board_profile_names() {
    local config
    STOCK_BOARD_PROFILES=()
    [[ -d "$TARGET_DIR" ]] || return 0
    while IFS= read -r -d '' config; do
        STOCK_BOARD_PROFILES+=("${config##*/}")
    done < <(find "$TARGET_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'jetson-*.conf' -print0 | sort -z)
}

stock_profile_module_name() {
    case "$1" in
        *orin-nx*) printf 'orin-nx\n' ;;
        *orin-nano*) printf 'orin-nano\n' ;;
        *agx-orin*|*orin-devkit*) printf 'orin-agx\n' ;;
        *xavier-nx*) printf 'xavier-nx\n' ;;
        *xavier*) printf 'xavier-agx\n' ;;
        *tx1*) printf 'tx1\n' ;;
        *tx2*) printf 'tx2\n' ;;
        *nano-2gb*) printf 'nano-2gb\n' ;;
        *nano*) printf 'nano\n' ;;
        *) printf 'unknown:%s\n' "${1#jetson-}" ;;
    esac
}

list_stock_board_profiles() {
    local config first=true name
    stock_board_profile_names
    if ((${#STOCK_BOARD_PROFILES[@]} == 0)); then
        [[ -d "$TARGET_DIR" ]] && printf 'none found in the current BSP tree\n' || printf 'not available until BSP deployment\n'
        return 0
    fi
    for config in "${STOCK_BOARD_PROFILES[@]}"; do
        name="${config%.conf} (module: $(stock_profile_module_name "${config%.conf}"))"
        if [[ "$first" == true ]]; then
            printf '%s' "$name"
            first=false
        else
            printf ', %s' "$name"
        fi
    done
    printf '\n'
}

select_stock_board_profile() {
    local requested="${1:-${NVIDIA_PROFILE_SELECTION:-}}" profile_name index=0 selection_number
    stock_board_profile_names
    if ((${#STOCK_BOARD_PROFILES[@]} == 0)); then
        print_error "No NVIDIA stock board profiles are available in $TARGET_DIR."
        return 1
    fi

    if [[ -z "$requested" ]]; then
        if [[ "$SILENT_MODE" == true ]]; then
            print_error "Select a stock NVIDIA profile in batch mode with --nvidia-profile or JETSON_NVIDIA_PROFILE."
            return 1
        fi
        printf 'Select an NVIDIA board profile:\n' >&2
        for profile_name in "${STOCK_BOARD_PROFILES[@]}"; do
            index=$((index + 1))
            printf '  %d) %s (module: %s)\n' "$index" "${profile_name%.conf}" \
                "$(stock_profile_module_name "${profile_name%.conf}")" >&2
        done
        read -r -p 'Enter profile number or name: ' requested || {
            print_error 'No NVIDIA stock profile was selected.'
            return 1
        }
    fi

    if [[ "$requested" =~ ^[0-9]+$ ]]; then
        if ((${#requested} > 9)); then
            print_error "NVIDIA profile number is out of range: $requested"
            return 1
        fi
        selection_number=$((10#$requested))
        if ((selection_number < 1 || selection_number > ${#STOCK_BOARD_PROFILES[@]})); then
            print_error "NVIDIA profile number is out of range: $requested"
            return 1
        fi
        profile_name="${STOCK_BOARD_PROFILES[selection_number-1]}"
    else
        requested="${requested%.conf}"
        for profile_name in "${STOCK_BOARD_PROFILES[@]}"; do
            [[ "${profile_name%.conf}" == "$requested" ]] && break
        done
        [[ "${profile_name%.conf}" == "$requested" ]] || {
            print_error "NVIDIA profile is not available in this BSP: $requested"
            return 1
        }
    fi

    JETSON_BOARD="${profile_name%.conf}"
    NVIDIA_PROFILE_SELECTION="$JETSON_BOARD"
    BOARD_PROFILE_AVAILABLE=false
    BOARD_CONFIG_AVAILABLE=true
    print_notice "Selected NVIDIA profile: $JETSON_BOARD (module: $(stock_profile_module_name "$JETSON_BOARD"))."
}

extract_with_progress() {
    local archive_path="$ARCHIVE_DIR/$1"
    local dest_dir="$2"
    local desc="$3"
    
    if [ ! -f "$archive_path" ]; then
        echo -e "${RED}Error: archive not found: $archive_path${NC}"
        return 1
    fi

    local size_bytes=$(stat -c%s "$archive_path")
    local size_human=$(du -h "$archive_path" | awk '{print $1}')
    echo -e "${GREEN}Extracting $desc...${NC}"
    
    # pv format: %p percent, %t elapsed time, %e ETA, %r rate, %b bytes.
    # Insert size_human directly because %s may not work.
    pv -F "%p %t %e [%r] [%b / $size_human] " -s "$size_bytes" "$archive_path" | sudo tar -xjf - -C "$dest_dir"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}Completed: $desc${NC}"
        return 0
    else
        echo -e "${RED}Error extracting $desc${NC}"
        return 1
    fi
}

deploy_system() {
    echo -e "${GREEN}=== Starting deployment ===${NC}"
    
    # 1. Extract L4T Core
    update_step "Extracting L4T core"
    extract_with_progress "$L4T_RELEASE_FILE" "$DEPLOY_BASE_DIR" "L4T Core" || exit 1
    
    # 2. Extract RootFS
    update_step "Extracting Sample RootFS"
    sudo mkdir -p "$TARGET_DIR/rootfs"
    extract_with_progress "$ROOTFS_FILE" "$TARGET_DIR/rootfs" "Sample RootFS" || exit 1
    
    # 3. Apply Binaries
    update_step "Applying NVIDIA binaries"
    cd "$TARGET_DIR" || exit 1
    if sudo ./apply_binaries.sh; then
        echo -e "${GREEN}NVIDIA binaries applied.${NC}"
    else
        echo -e "${RED}Error: apply_binaries.sh failed.${NC}"
        exit 1
    fi
    
    # 4. Create User
    update_step "Creating user: $JETSON_USER"
    if sudo ./tools/l4t_create_default_user.sh -u "$JETSON_USER" -p "$JETSON_PASS" -a -n "$JETSON_HOST" --accept-license; then
        echo -e "${GREEN}User created.${NC}"
    else
        echo -e "${RED}Error creating user.${NC}"
        exit 1
    fi

    # l4t_create_default_user.sh may replace getty configuration, so configure
    # the UART login only after this command has completed.
    
    # 5. Overlay files
    update_step "Copying root_fs overlay"
    if [ -d "$LOCAL_ROOTFS_OVERLAY" ]; then
        if sudo cp -r "$LOCAL_ROOTFS_OVERLAY"/* "$TARGET_DIR/rootfs/"; then
            echo -e "${GREEN}root_fs overlay copied to RootFS.${NC}"
        else
            echo -e "${RED}Error copying root_fs overlay.${NC}"
            exit 1
        fi
    else
        echo -e "Overlay directory not found: $LOCAL_ROOTFS_OVERLAY (skipping)."
    fi
    
    # 6. Public Sources (optional)
    if [ -f "$ARCHIVE_DIR/$SOURCES_FILE" ]; then
       echo -e "\n[Optional] Extracting public sources"
       extract_with_progress "$SOURCES_FILE" "$TARGET_DIR" "Public Sources" || exit 1
    fi
    
    echo -e "\n${GREEN}=== Deployment completed successfully ===${NC}"
}

preflight_board_profile() {
    local board_dir="$PROJECT_DIR/$LOCAL_BOARD_CONFIG_NAME"
    local selection status
    [[ -f "$board_dir/select_config.sh" ]] || {
        print_error "b_conf selector not found: $board_dir/select_config.sh"
        return 2
    }
    # shellcheck source=/dev/null
    source "$board_dir/select_config.sh"
    if selection="$(b_conf_select_package "$board_dir" "$JETSON_BOARD" "$JETPACK_VERSION" "$JETSON_MODULE" 2>&1)"; then
        BOARD_PROFILE_DIR="$selection"
        BOARD_PROFILE_ERROR=""
        return 0
    else
        status=$?
    fi

    BOARD_PROFILE_DIR=""
    BOARD_PROFILE_ERROR="$selection"
    if ((status == 1)); then
        if [[ "$REQUIRE_BOARD_PROFILE" == true ]]; then
            print_error "A compatible b_conf profile is required for $JETSON_BOARD on JetPack $JETPACK_VERSION. $selection"
            return 1
        fi
        if [[ "$SILENT_MODE" == true && -z "$NVIDIA_PROFILE_SELECTION" && "$BOARD_WAS_EXPLICIT" != true ]]; then
            print_error "Batch mode without a project b_conf profile requires --nvidia-profile or JETSON_NVIDIA_PROFILE."
            return 1
        fi
        print_warning "No compatible project b_conf profile for $JETSON_BOARD on JetPack $JETPACK_VERSION. Continuing preparation; only NVIDIA profiles included in the selected JetPack BSP will be available unless a compatible project profile is added."
        return 0
    fi

    print_error "$selection"
    return "$status"
}

copy_board_configuration() {
    local board_dir="$PROJECT_DIR/$LOCAL_BOARD_CONFIG_NAME"
    local bundle_dir="$BOARD_PROFILE_DIR" payload stock_profiles requested=""
    [[ -d "$TARGET_DIR" ]] || { echo -e "${RED}Error: L4T is not deployed at $TARGET_DIR${NC}" >&2; return 1; }
    if [[ -z "$bundle_dir" ]]; then
        update_step "Checking b_conf profile: $JETSON_BOARD for JetPack $JETPACK_VERSION"
        BOARD_PROFILE_AVAILABLE=false
        stock_profiles="$(list_stock_board_profiles)"
        print_warning "No compatible b_conf profile for $JETSON_BOARD. Available NVIDIA profiles: $stock_profiles"
        if [[ -n "$NVIDIA_PROFILE_SELECTION" ]]; then
            requested="$NVIDIA_PROFILE_SELECTION"
        elif [[ "$BOARD_WAS_EXPLICIT" == true && -f "$TARGET_DIR/$JETSON_BOARD.conf" ]]; then
            requested="$JETSON_BOARD"
        fi
        select_stock_board_profile "$requested" || return 1
        return 0
    fi

    payload="$bundle_dir/Linux_for_Tegra"
    [[ -f "$payload/${JETSON_BOARD}.conf" || -f "$TARGET_DIR/${JETSON_BOARD}.conf" ]] || {
        echo -e "${RED}Error: profile ${JETSON_BOARD}.conf is missing from package: $payload${NC}" >&2
        return 1
    }

    update_step "Installing b_conf: $JETSON_BOARD for JetPack $JETPACK_VERSION"
    if [[ -d "$payload" ]]; then
        b_conf_install_payload "$payload" "$TARGET_DIR" || return 1
    fi

    BOARD_PROFILE_AVAILABLE=true
    BOARD_CONFIG_AVAILABLE=true
    echo -e "${GREEN}Selected package: $bundle_dir${NC}"
    [[ -f "$bundle_dir/COMPATIBILITY.md" ]] && echo "Compatibility log: $bundle_dir/COMPATIBILITY.md"
}

apply_debian_patches() {
    [[ -x "$PROJECT_DIR/setup_debian.sh" ]] || {
        echo -e "${RED}Error: Bash patcher not found or not executable: $PROJECT_DIR/setup_debian.sh${NC}" >&2
        return 1
    }
    update_step "Applying L4T compatibility patches"
    if [[ "$BOARD_CONFIG_AVAILABLE" == true ]]; then
        sudo "$PROJECT_DIR/setup_debian.sh" --board "$JETSON_BOARD" --version "${L4T_VERSION_SELECTED}" --l4t-dir "$TARGET_DIR"
    else
        print_warning "Board configuration is unavailable; applying release-wide Debian fixes only."
        sudo "$PROJECT_DIR/setup_debian.sh" --board "$JETSON_BOARD" --version "${L4T_VERSION_SELECTED}" --l4t-dir "$TARGET_DIR" --generic-only
    fi
}

apply_rootfs_release_fixes() {
    local rootfs_path="$TARGET_DIR/rootfs"
    update_step "Applying rootfs fixes for JetPack $JETPACK_VERSION"
    rootfs_fix_read_os_release "$rootfs_path/etc/os-release" || {
        print_error "Cannot identify target rootfs distribution from etc/os-release."
        return 1
    }
    rootfs_fix_normalize_nvidia_soc "$rootfs_path" "$TARGET_DIR/$JETSON_BOARD.conf" || return 1
    rootfs_fix_apply_layers "$rootfs_path" "$PROJECT_DIR/rootfs-fixes" \
        "$JETPACK_VERSION" "$ROOTFS_FIX_OS_ID" "$ROOTFS_FIX_CODENAME" || return 1
    print_notice "Rootfs release-specific fixes applied (or no matching fix was required)."
}

write_rootfs_image_identity() {
    local board_identity="$JETSON_BOARD"
    update_step "Writing rootfs image identity"
    [[ "$BOARD_CONFIG_AVAILABLE" == true ]] || board_identity="NVIDIA stock profile (not selected)"
    rootfs_fix_write_identity "$TARGET_DIR/rootfs" "$JETPACK_VERSION" \
        "$L4T_VERSION_SELECTED" "$board_identity"
}

begin_qemu_session() {
    local rootfs_path="$1"
    local interactive=true
    [[ "$SILENT_MODE" == true ]] && interactive=false
    qemu_session_begin "$QEMU_SESSION_LOCK_FILE" "$rootfs_path" "$interactive" "$FORCE_QEMU_CLEANUP" || return 1
    QEMU_SESSION_HELD=true
}

abort_qemu_session() {
    local rootfs_path="$1"
    local cleanup_status=0
    cleanup_qemu_rootfs "$rootfs_path" || cleanup_status=$?
    if ((cleanup_status == 0)); then end_qemu_session true; else end_qemu_session false; fi
    return "$cleanup_status"
}

end_qemu_session() {
    local clean="$1"
    if [[ "$QEMU_SESSION_HELD" == true ]]; then
        qemu_session_end "$clean"
        local status=$?
        QEMU_SESSION_HELD=false
        return "$status"
    fi
}

prepare_qemu_rootfs() {
    local rootfs_path="$1"
    update_step "Preparing QEMU rootfs"
    qemu_session_set_phase "preparing-rootfs" || return 1

    # Recover an exact temporary APT pin left by a forcibly terminated run.
    qemu_apt_cleanup_upgrade_pin "$rootfs_path" || return 1
    qemu_apt_cleanup_service_policy "$rootfs_path" || return 1
    if [[ "$ROOTFS_CLEANUP_ENABLED" == true ]]; then
        rootfs_cleanup_remove_temporary_qemu "$rootfs_path" || return 1
    fi
    
    if ! command -v qemu-aarch64-static &> /dev/null; then
        print_notice "Installing qemu-user-static on the host..."
        sudo apt-get update && sudo apt-get install -y qemu-user-static || return 1
    fi
    
    rootfs_cleanup_install_temporary_qemu "$rootfs_path" /usr/bin/qemu-aarch64-static || return 1

    # Replace the original resolver temporarily, including dangling symlinks,
    # and add fallback DNS only when the host resolver has no active server.
    QEMU_ROOTFS_ACTIVE="$rootfs_path"
    qemu_prepare_rootfs_resolv "$rootfs_path/etc/resolv.conf" /etc/resolv.conf || {
        cleanup_qemu_rootfs "$rootfs_path"
        return 1
    }
    
    qemu_session_set_phase "mounting-rootfs" || { cleanup_qemu_rootfs "$rootfs_path"; return 1; }
    update_step "Mounting QEMU rootfs resources"
    if ! sudo mount -t proc /proc "$rootfs_path/proc" || \
       ! sudo mount -t sysfs /sys "$rootfs_path/sys" || \
       ! sudo mount --bind /dev "$rootfs_path/dev" || \
       ! sudo mount --bind /dev/pts "$rootfs_path/dev/pts"; then
        cleanup_qemu_rootfs "$rootfs_path"
        return 1
    fi
}

cleanup_qemu_rootfs() {
    local rootfs_path="$1"
    local announce_cleanup_step="${2:-false}"
    local failed=false
    local mounts_active=false
    local resolver_restored=true
    local mount_path

    for mount_path in "$rootfs_path/dev/pts" "$rootfs_path/dev" "$rootfs_path/sys" "$rootfs_path/proc"; do
        if sudo mountpoint -q "$mount_path"; then
            print_notice "Warning: unmounting QEMU resource at $mount_path during cleanup."
            if ! sudo umount "$mount_path"; then failed=true; mounts_active=true; fi
        fi
    done
    if ! qemu_restore_rootfs_resolv "$rootfs_path/etc/resolv.conf"; then
        failed=true
        resolver_restored=false
    fi
    if [[ "$mounts_active" == false && "$resolver_restored" == true ]]; then
        if [[ "$ROOTFS_CLEANUP_ENABLED" == true ]]; then
            if [[ "$announce_cleanup_step" == true ]]; then
                update_step "Cleaning rootfs transient files and caches"
            else
                print_notice "Cleaning rootfs transient files and caches during session recovery."
            fi
        else
            if [[ "$announce_cleanup_step" == true ]]; then
                update_step "Skipping rootfs transient cleanup"
            else
                print_notice "Skipping rootfs transient cleanup by request."
            fi
        fi
        rootfs_cleanup_transient_artifacts "$rootfs_path" "$ROOTFS_CLEANUP_ENABLED" || failed=true
    else
        if [[ "$announce_cleanup_step" == true ]]; then
            update_step "Skipping rootfs cleanup because QEMU resources or resolver are not restored"
        else
            print_notice "Skipping rootfs cleanup because QEMU resources or resolver are not restored."
        fi
    fi
    qemu_apt_cleanup_upgrade_pin "$rootfs_path" || failed=true
    qemu_apt_cleanup_service_policy "$rootfs_path" || failed=true

    if [[ "$failed" == true ]]; then
        print_error "Error: QEMU rootfs cleanup failed for $rootfs_path. Check its mount points and resolver backup."
        return 1
    fi
    QEMU_ROOTFS_ACTIVE=""
}

qemu_handle_signal() {
    local signal_name="$1"
    local exit_status="$2"

    if [[ -n "$QEMU_ROOTFS_ACTIVE" ]]; then
        print_notice "Emergency cleanup after $signal_name: cleaning QEMU rootfs mounts..."
        if [[ -n "$QEMU_APT_REPOSITORY_BACKUP_DIR" ]]; then
            print_notice "Restoring APT repository sources after interruption..."
            qemu_apt_restore_repository_sources "$QEMU_APT_REPOSITORY_BACKUP_ROOTFS" || true
        fi
        cleanup_qemu_rootfs "$QEMU_ROOTFS_ACTIVE" || true
    fi
    if [[ "$QEMU_SESSION_HELD" == true ]]; then
        if [[ -z "$QEMU_ROOTFS_ACTIVE" ]]; then end_qemu_session true; else end_qemu_session false; fi
    fi
    trap - "$signal_name"
    exit "$exit_status"
}

trap 'qemu_handle_signal INT 130' INT
trap 'qemu_handle_signal TERM 143' TERM
trap 'qemu_handle_signal HUP 129' HUP

setup_qemu_chroot() {
    local rootfs_path="$TARGET_DIR/rootfs"
    local prompt_module="${JETSON_MODULE:-$(stock_profile_module_name "$JETSON_BOARD")}"
    local status
    begin_qemu_session "$rootfs_path" || return 1
    prepare_qemu_rootfs "$rootfs_path" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    qemu_session_set_phase "interactive-chroot" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    update_step "Entering QEMU chroot for configuration"
    print_notice "Entering environment with a clean locale..."
    qemu_chroot_run_shell "$rootfs_path" "$prompt_module"
    status=$?

    update_step "Unmounting QEMU rootfs resources"
    cleanup_qemu_rootfs "$rootfs_path" true || { end_qemu_session false; return 1; }
    end_qemu_session true || return 1
    if qemu_chroot_normalize_shell_status "$status"; then
        if ((status == 130)); then
            print_notice "QEMU shell received Ctrl+C and exited; cleanup completed."
        fi
        status=0
    fi
    print_notice "QEMU chroot session finished."
    return "$status"
}

update_rootfs_packages() {
    local rootfs_path="$TARGET_DIR/rootfs"
    local status
    local cleanup_status

    QEMU_APT_FAILED_STEP="package list validation"
    QEMU_APT_EXIT_STATUS=1
    qemu_apt_load_packages "$APT_PACKAGES_FILE" || return 1
    QEMU_APT_FAILED_STEP="QEMU rootfs preparation"
    QEMU_APT_EXIT_STATUS=1
    print_notice "Package list: $APT_PACKAGES_FILE (${QEMU_APT_PACKAGES[*]:-(no extra packages)})"
    begin_qemu_session "$rootfs_path" || { QEMU_APT_FAILED_STEP="stale QEMU session recovery"; return 1; }
    prepare_qemu_rootfs "$rootfs_path" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    qemu_session_set_phase "apt-update-upgrade" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    update_step "Checking rootfs repository availability"
    qemu_apt_validate_repositories "$rootfs_path" "$PROJECT_DIR/apt-repositories" "$FORCE_CUSTOM_REPOSITORIES"
    status=$?
    if ((status == 0)); then
        update_step "Updating rootfs system packages"
        qemu_apt_upgrade_install "$rootfs_path"
        status=$?
    else
        update_step "Updating rootfs system packages (skipped: repository validation failed)"
    fi
    update_step "Unmounting QEMU rootfs resources"
    cleanup_qemu_rootfs "$rootfs_path" true
    cleanup_status=$?
    if ((cleanup_status != 0)); then
        QEMU_APT_FAILED_STEP="QEMU rootfs cleanup"
        QEMU_APT_EXIT_STATUS="$cleanup_status"
        end_qemu_session false
        return "$cleanup_status"
    fi
    end_qemu_session true || { QEMU_APT_FAILED_STEP="QEMU session release"; return 1; }
    return "$status"
}

setup_jetson_exit_cleanup() {
    local exit_status=$?
    trap - EXIT

    if [[ -n "${QEMU_ROOTFS_ACTIVE:-}" ]]; then
        print_notice "Warning: setup_jetson.sh is exiting with active QEMU rootfs mounts; cleaning them up."
        if [[ -n "${QEMU_APT_REPOSITORY_BACKUP_DIR:-}" ]]; then
            qemu_apt_restore_repository_sources "$QEMU_APT_REPOSITORY_BACKUP_ROOTFS" || exit_status=1
        fi
        cleanup_qemu_rootfs "$QEMU_ROOTFS_ACTIVE" || exit_status=1
    fi
    if [[ "${QEMU_SESSION_HELD:-false}" == true ]]; then
        if [[ -n "${QEMU_ROOTFS_ACTIVE:-}" ]]; then
            end_qemu_session false || exit_status=1
        else
            end_qemu_session true || exit_status=1
        fi
    fi
    if [[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR/bootloader" ]]; then
        l4t_cleanup_deployment_mounts "$TARGET_DIR" || exit_status=1
    fi
    terminal_status_finish "$exit_status" || true
    exit "$exit_status"
}

trap setup_jetson_exit_cleanup EXIT
terminal_status_start "Jetson setup"

# --- Execution starts here ---

select_release_pair
preflight_board_profile || exit 1
check_dependencies

# Check current deployment status.
DEPLOY_STATUS="not deployed"
if [ -d "$TARGET_DIR" ]; then
    DEPLOY_STATUS="found at $TARGET_DIR"
fi

echo -e "Target directory: ${GREEN}$TARGET_DIR${NC}"
echo -e "Current status: ${GREEN}$DEPLOY_STATUS${NC}"

WANT_DEPLOY=false
if [ -d "$TARGET_DIR" ]; then
    if [ "$FORCE_DELETE" = true ]; then
        # Do not remove a deployment while a QEMU operation still owns or
        # partially uses its rootfs.
        begin_qemu_session "$TARGET_DIR/rootfs" || exit 1
        end_qemu_session true || exit 1
        WANT_DEPLOY=true
    elif [ "$SILENT_MODE" = true ]; then
        echo "Batch mode keeps the existing deployment. Use --force to recreate it."
        WANT_DEPLOY=false
    elif confirm "Remove the existing deployment at $TARGET_DIR?"; then
        echo "Removing existing deployment..."
        sudo rm -rf "$TARGET_DIR"
        WANT_DEPLOY=true
    elif confirm "Try deploying over the existing directory?"; then
        WANT_DEPLOY=true
    fi
else
    if confirm "Deploy a new Jetson L4T system?"; then
        WANT_DEPLOY=true
    fi
fi

ROOTFS_EXPECTED=false
if [[ "$WANT_DEPLOY" == true || -d "$TARGET_DIR/rootfs" ]]; then
    ROOTFS_EXPECTED=true
fi
RUN_ROOTFS_APT=false
RUN_QEMU_SHELL=false
if [[ "$ROOTFS_EXPECTED" == true ]]; then
    if [[ "$SILENT_MODE" == true ]]; then
        [[ "$APT_UPGRADE_BATCH" == true ]] && RUN_ROOTFS_APT=true
        [[ "$SKIP_QEMU" == false ]] && RUN_QEMU_SHELL=true
    else
        confirm "Run apt update/upgrade on rootfs and install packages from $APT_PACKAGES_FILE?" && RUN_ROOTFS_APT=true
        if [[ "$SKIP_QEMU" == false ]]; then
            confirm "Enter the QEMU chroot for configuration?" && RUN_QEMU_SHELL=true
        fi
    fi
fi

HAS_TARGET=false
if [[ "$WANT_DEPLOY" == true || -d "$TARGET_DIR" ]]; then HAS_TARGET=true; fi
APPLY_PATCHES=true
[[ "$SKIP_DEBIAN_PATCHES" == true ]] && APPLY_PATCHES=false
TOTAL_STEPS="$(jetson_calculate_total_steps \
    "$WANT_DEPLOY" "$HAS_TARGET" "$ROOTFS_EXPECTED" \
    "$APPLY_PATCHES" "$RUN_ROOTFS_APT" "$RUN_QEMU_SHELL")"

if [ "$WANT_DEPLOY" = true ]; then
    check_disk_space "$DEPLOY_BASE_DIR"
    deploy_system
fi

if [ -d "$TARGET_DIR" ]; then
    copy_board_configuration || exit 1
    if [[ "$SKIP_DEBIAN_PATCHES" == true ]]; then
        print_notice "Skipping Debian compatibility patches by request."
    else
        apply_debian_patches || exit 1
    fi
    if [[ -d "$TARGET_DIR/rootfs" ]]; then
        apply_rootfs_release_fixes || exit 1
    fi
    if [[ "$BOARD_CONFIG_AVAILABLE" == true ]]; then
        echo -e "\n${GREEN}Preparation complete. After powering on the board and confirming Recovery mode, run:${NC}"
        echo "  cd \"$TARGET_DIR\" && sudo ./flash.sh $JETSON_BOARD mmcblk0p1"
    else
        print_warning "System preparation completed, but no flashable board configuration was found. Select a compatible profile before flashing."
    fi
fi

POST_SETUP_FAILED=false

# Run the selected package update before the interactive QEMU shell so the
# shell sees the updated system and UART settings are still applied afterward.
if [[ "$RUN_ROOTFS_APT" == true ]]; then
    update_rootfs_packages || {
        print_error "Rootfs APT update failed during ${QEMU_APT_FAILED_STEP:-unknown stage} (exit status ${QEMU_APT_EXIT_STATUS:-1})."
        POST_SETUP_FAILED=true
    }
fi

# QEMU shell is independent of package installation and can be skipped.
if [[ -n "$QEMU_ROOTFS_ACTIVE" ]]; then
    print_error "QEMU chroot skipped because rootfs cleanup did not complete."
    POST_SETUP_FAILED=true
elif [[ "$RUN_QEMU_SHELL" == true ]]; then
    setup_qemu_chroot || {
        print_error "QEMU chroot setup failed (exit status $?)."
        POST_SETUP_FAILED=true
    }
fi

# Apply UART login last, after user creation, APT updates, and any QEMU session.
if [[ -d "$TARGET_DIR/rootfs" ]]; then
    write_rootfs_image_identity || {
        print_error "Failed to write rootfs image identity."
        POST_SETUP_FAILED=true
    }
    if configure_root_uart_login "$TARGET_DIR/rootfs" "$ROOT_UART_AUTOLOGIN"; then
        update_step "$ROOT_UART_MESSAGE"
        if [[ "$ROOT_UART_AUTOLOGIN" == true ]]; then
            echo "  Disable with --no-root-uart-login."
        fi
    else
        print_error "UART autologin configuration failed."
        POST_SETUP_FAILED=true
    fi
fi

print_notice "Script finished."
[[ "$POST_SETUP_FAILED" == false ]] || exit 1
