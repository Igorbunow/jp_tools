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

# Default settings
JETSON_USER="${JETSON_USER:-nvidia}"
JETSON_PASS="${JETSON_PASS:-nvidia}"
JETSON_HOST="${JETSON_HOST:-nvidia-agx-orin}"
SILENT_MODE=false
FORCE_DELETE=false
SKIP_QEMU=false
SKIP_DEBIAN_PATCHES=false
ROOT_UART_AUTOLOGIN=true
JETSON_BOARD="${JETSON_BOARD:-jetson-agx-orin-devkit-noeeprom}"
L4T_VERSION="${L4T_VERSION:-}"
JETPACK_VERSION="${JETPACK_VERSION:-}"
PRINT_PATHS=false
APT_UPGRADE_BATCH=false
FORCE_QEMU_CLEANUP=false
FORCE_CUSTOM_REPOSITORIES=false
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
    echo "  --jetpack-version <v>  b_conf selection version (default: archive directory name)"
    echo "  --no-root-uart-login   Disable root UART autologin (default: enabled)"
    echo "  -h, --help             Show this help"
    echo "Environment variables:"
    echo "  JETSON_ARCHIVE_DIR, JETSON_DEPLOY_DIR  Archive and deployment base paths."
    echo "  JETPACK_VERSION, L4T_VERSION          Select b_conf and matching L4T archives."
    echo "  JETSON_BOARD, JETSON_USER, JETSON_PASS, JETSON_HOST  Board/default-user settings."
    echo "  JETSON_SKIP_DEBIAN_PATCHES=0|1        Apply Debian patches (default) or skip them."
    echo "  JETSON_APT_UPGRADE=0|1                 Enable batch rootfs apt update/upgrade."
    echo "  JETSON_APT_PACKAGES_FILE               Package list for rootfs APT operations."
    echo "  JETSON_FORCE_CUSTOM_REPOSITORIES=0|1   Allow custom repository profiles after APT errors."
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
        --force-qemu-cleanup) FORCE_QEMU_CLEANUP=true; shift ;;
        --apt-upgrade) APT_UPGRADE_BATCH=true; shift ;;
        --force-repositories) FORCE_CUSTOM_REPOSITORIES=true; shift ;;
        --apt-packages-file) APT_PACKAGES_FILE="${2:?--apt-packages-file requires a path}"; shift 2 ;;
        --skip-debian-patches) SKIP_DEBIAN_PATCHES=true; shift ;;
        --no-root-uart-login) ROOT_UART_AUTOLOGIN=false; shift ;;
        --version) L4T_VERSION="$2"; shift 2 ;;
        --board) JETSON_BOARD="$2"; shift 2 ;;
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
JETPACK_VERSION="${JETPACK_VERSION:-$(basename -- "$ARCHIVE_DIR")}"
JETPACK_VERSION="${JETPACK_VERSION% }"

if [[ "$PRINT_PATHS" == true ]]; then
    printf 'Project resources: %s\n' "$PROJECT_DIR"
    printf 'Archive directory: %s\n' "$ARCHIVE_DIR"
    printf 'Deployment base directory: %s\n' "$DEPLOY_BASE_DIR"
    printf 'L4T directory: %s\n' "$TARGET_DIR"
    printf 'JetPack version: %s\n' "$JETPACK_VERSION"
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
        echo -e "${RED}Error: no matching Jetson_Linux and Sample-Root-Filesystem archive pair found in $ARCHIVE_DIR (version=${L4T_VERSION:-latest})${NC}" >&2
        exit 1
    fi
    version="$(printf '%s\n' "${versions[@]}" | sort -Vu | tail -n1)"
    L4T_RELEASE_FILE="Jetson_Linux_${version}_aarch64.tbz2"
    ROOTFS_FILE="Tegra_Linux_Sample-Root-Filesystem_${version}_aarch64.tbz2"
    echo "Selected L4T source pair: ${version}."
}

update_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "\n${GREEN}[Step $CURRENT_STEP of $TOTAL_STEPS] $1${NC}"
}

print_notice() {
    echo -e "${GREEN}$*${NC}"
}

print_error() {
    echo -e "${RED}$*${NC}" >&2
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

copy_board_configuration() {
    local board_dir="$PROJECT_DIR/$LOCAL_BOARD_CONFIG_NAME"
    local bundle_dir payload
    [[ -d "$TARGET_DIR" ]] || { echo -e "${RED}Error: L4T is not deployed at $TARGET_DIR${NC}" >&2; return 1; }
    [[ -f "$board_dir/select_config.sh" ]] || { echo -e "${RED}Error: b_conf selector not found: $board_dir/select_config.sh${NC}" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$board_dir/select_config.sh"
    bundle_dir="$(b_conf_select_package "$board_dir" "$JETSON_BOARD" "$JETPACK_VERSION")" || return 1
    payload="$bundle_dir/Linux_for_Tegra"
    [[ -f "$payload/${JETSON_BOARD}.conf" ]] || {
        echo -e "${RED}Error: profile ${JETSON_BOARD}.conf is missing from package: $payload${NC}" >&2
        return 1
    }

    update_step "Installing b_conf: $JETSON_BOARD for JetPack $JETPACK_VERSION"
    b_conf_install_payload "$payload" "$TARGET_DIR" || return 1

    echo -e "${GREEN}Selected package: $bundle_dir${NC}"
    [[ -f "$bundle_dir/COMPATIBILITY.md" ]] && echo "Compatibility log: $bundle_dir/COMPATIBILITY.md"
}

apply_debian_patches() {
    [[ -x "$PROJECT_DIR/setup_debian.sh" ]] || {
        echo -e "${RED}Error: Bash patcher not found or not executable: $PROJECT_DIR/setup_debian.sh${NC}" >&2
        return 1
    }
    update_step "Applying L4T compatibility patches"
    sudo "$PROJECT_DIR/setup_debian.sh" --board "$JETSON_BOARD" --version "${L4T_VERSION_SELECTED}" --l4t-dir "$TARGET_DIR"
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
    update_step "Writing rootfs image identity"
    rootfs_fix_write_identity "$TARGET_DIR/rootfs" "$JETPACK_VERSION" \
        "$L4T_VERSION_SELECTED" "$JETSON_BOARD"
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
    
    if ! command -v qemu-aarch64-static &> /dev/null; then
        print_notice "Installing qemu-user-static on the host..."
        sudo apt-get update && sudo apt-get install -y qemu-user-static || return 1
    fi
    
    sudo cp /usr/bin/qemu-aarch64-static "$rootfs_path/usr/bin/" || return 1

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
    local failed=false
    local mount_path

    for mount_path in "$rootfs_path/dev/pts" "$rootfs_path/dev" "$rootfs_path/sys" "$rootfs_path/proc"; do
        if sudo mountpoint -q "$mount_path"; then
            print_notice "Warning: unmounting QEMU resource at $mount_path during cleanup."
            sudo umount "$mount_path" || failed=true
        fi
    done
    qemu_restore_rootfs_resolv "$rootfs_path/etc/resolv.conf" || failed=true
    qemu_apt_cleanup_upgrade_pin "$rootfs_path" || failed=true

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
    local status
    begin_qemu_session "$rootfs_path" || return 1
    prepare_qemu_rootfs "$rootfs_path" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    qemu_session_set_phase "interactive-chroot" || { abort_qemu_session "$rootfs_path" || true; return 1; }
    update_step "Entering QEMU chroot for configuration"
    print_notice "Entering environment with a clean locale..."
    qemu_chroot_run_shell "$rootfs_path"
    status=$?

    update_step "Unmounting QEMU rootfs resources"
    cleanup_qemu_rootfs "$rootfs_path" || { end_qemu_session false; return 1; }
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
    cleanup_qemu_rootfs "$rootfs_path"
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
    exit "$exit_status"
}

trap setup_jetson_exit_cleanup EXIT

# --- Execution starts here ---

check_dependencies
select_release_pair
L4T_VERSION_SELECTED="${L4T_RELEASE_FILE#Jetson_Linux_}"
L4T_VERSION_SELECTED="${L4T_VERSION_SELECTED%_aarch64.tbz2}"

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
    echo -e "\n${GREEN}Preparation complete. After powering on the board and confirming Recovery mode, run:${NC}"
    echo "  cd \"$TARGET_DIR\" && sudo ./flash.sh $JETSON_BOARD mmcblk0p1"
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
