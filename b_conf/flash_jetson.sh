#!/usr/bin/env bash
# List compatible b_conf profiles and flash one selected profile.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
B_CONF_DIR="$SCRIPT_DIR"
L4T_DIR="${JETSON_L4T_DIR:-}"
DEPLOY_BASE_DIR="${JETSON_DEPLOY_DIR:-}"
ARCHIVE_DIR="${JETSON_ARCHIVE_DIR:-}"
JETPACK_VERSION="${JETPACK_VERSION:-}"
BOARD=""
MODE=""
ROOTDEV="mmcblk0p1"
ASSUME_YES=false
DRY_RUN=false
LIST_ONLY=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --list                       List profiles compatible with the selected version (or common profiles if unknown).
  --board PROFILE              Board profile (also accepted: --profile).
  --mode MODE                  full, dtb (write A then B), or rootfs (APP only).
  --jetpack-version VERSION    Override JetPack detection and select matching versioned profiles.
  --l4t-dir PATH               Use this exact Linux_for_Tegra directory.
  --deploy-dir PATH            Use PATH/Linux_for_Tegra as the deployment.
  --rootdev DEVICE             flash.sh root device (default: mmcblk0p1).
  --yes                        Confirm BSP changes and destructive flash in batch mode.
  --dry-run                    Print planned file copies and flash commands only.
  -h, --help                   Show this help.

Environment variables:
  JETSON_DEPLOY_DIR            Base deployment directory; uses PATH/Linux_for_Tegra.
  JETSON_ARCHIVE_DIR           Archive directory; used to match the deployed L4T release when image metadata is absent.
  JETSON_L4T_DIR               Exact Linux_for_Tegra directory (takes precedence).
  JETPACK_VERSION              JetPack version used to resolve versioned profiles.
  JETSON_USB_SYSFS_ROOT        USB sysfs root used for Recovery detection (default: /sys/bus/usb/devices).

Without --board or --mode, an interactive terminal prompts for the missing choices.
Examples:
  $0 --list
  $0 --board jetson-agx-orin-devkit-noeeprom --mode full --yes
  $0 --board jetson-agx-orin-10g_4eth_pci_nvme_dp --mode dtb --yes
  $0 --board jetson-agx-orin-devkit-noeeprom --mode rootfs --dry-run
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        --list) LIST_ONLY=true; shift ;;
        --board|--profile) (($# >= 2)) || die "$1 requires a value"; BOARD="$2"; shift 2 ;;
        --mode) (($# >= 2)) || die "$1 requires a value"; MODE="$2"; shift 2 ;;
        --jetpack-version) (($# >= 2)) || die "$1 requires a value"; JETPACK_VERSION="$2"; shift 2 ;;
        --l4t-dir) (($# >= 2)) || die "$1 requires a value"; L4T_DIR="$2"; shift 2 ;;
        --deploy-dir) (($# >= 2)) || die "$1 requires a value"; DEPLOY_BASE_DIR="$2"; shift 2 ;;
        --rootdev) (($# >= 2)) || die "$1 requires a value"; ROOTDEV="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

if [[ -n "$DEPLOY_BASE_DIR" && -z "$L4T_DIR" ]]; then
    L4T_DIR="$DEPLOY_BASE_DIR/Linux_for_Tegra"
fi
L4T_DIR="${L4T_DIR:-$REPO_DIR/Linux_for_Tegra}"
[[ "$L4T_DIR" = /* ]] || L4T_DIR="$PWD/$L4T_DIR"
L4T_DIR="$(realpath -m -- "$L4T_DIR")"

JETPACK_VERSION_SOURCE=""
if [[ -n "$JETPACK_VERSION" ]]; then
    JETPACK_VERSION_SOURCE="explicit JETPACK_VERSION/--jetpack-version override"
else
    # The deployed image is authoritative. setup_jetson.sh writes this file
    # after all rootfs work, and arbitrary deployment directory names are valid.
    image_info="$L4T_DIR/rootfs/etc/jetson-image-info"
    if [[ -r "$image_info" ]]; then
        detected_version="$(awk -F: '$1 == "JetPack" {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$image_info")"
        if [[ "$detected_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            JETPACK_VERSION="$detected_version"
            JETPACK_VERSION_SOURCE="deployed image metadata ($image_info)"
        fi
    fi

    # Older deployed images may lack jetson-image-info. Match their L4T
    # release against the archive pair when JETSON_ARCHIVE_DIR is supplied.
    if [[ -z "$JETPACK_VERSION" && -n "$ARCHIVE_DIR" && -r "$L4T_DIR/nv_tegra/nv_tegra_release" ]]; then
        l4t_release="$(sed -nE 's/^# R([0-9]+) \(release\), REVISION: ([0-9.]+),.*/R\1.\2/p' \
            "$L4T_DIR/nv_tegra/nv_tegra_release" | head -n 1)"
        archive_version="$(basename -- "${ARCHIVE_DIR%/}")"
        if [[ "$archive_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && -n "$l4t_release" && \
              -f "$ARCHIVE_DIR/Jetson_Linux_${l4t_release}_aarch64.tbz2" && \
              -f "$ARCHIVE_DIR/Tegra_Linux_Sample-Root-Filesystem_${l4t_release}_aarch64.tbz2" ]]; then
            JETPACK_VERSION="$archive_version"
            JETPACK_VERSION_SOURCE="matched deployed L4T $l4t_release to archive pair in $ARCHIVE_DIR"
        fi
    fi

    # Keep supporting deployments and repository checkouts named by version.
    if [[ -z "$JETPACK_VERSION" ]]; then
        for version_candidate in "$(basename -- "$(dirname -- "$L4T_DIR")")" \
                                 "$(basename -- "$REPO_DIR")"; do
            if [[ "$version_candidate" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                JETPACK_VERSION="$version_candidate"
                JETPACK_VERSION_SOURCE="version-named directory ($version_candidate)"
                break
            fi
        done
    fi
fi
VERSION_KNOWN=true
if [[ -z "$JETPACK_VERSION" ]]; then
    JETPACK_VERSION="unknown"
    VERSION_KNOWN=false
    printf 'JetPack version could not be detected from deployed image metadata or directory names.\n'
else
    if [[ "$JETPACK_VERSION_SOURCE" == "explicit JETPACK_VERSION/--jetpack-version override" ]]; then
        printf 'JetPack version: %s (%s).\n' "$JETPACK_VERSION" "$JETPACK_VERSION_SOURCE"
    else
        printf 'Detected JetPack version: %s (%s).\n' "$JETPACK_VERSION" "$JETPACK_VERSION_SOURCE"
    fi
fi

[[ -x "$L4T_DIR/flash.sh" ]] || die "flash.sh not found under $L4T_DIR"
[[ -f "$B_CONF_DIR/select_config.sh" ]] || die "b_conf/select_config.sh not found"
# shellcheck source=/dev/null
source "$B_CONF_DIR/select_config.sh"

compatible_profiles() {
    local candidate profile bundle
    local -A seen=()
    while IFS= read -r candidate; do
        profile="${candidate##*/}"
        [[ -n "$profile" && -z "${seen[$profile]+x}" ]] || continue
        if [[ "$VERSION_KNOWN" == true ]]; then
            bundle="$(b_conf_select_package "$B_CONF_DIR" "$profile" "$JETPACK_VERSION" 2>/dev/null)" || continue
        else
            bundle="$B_CONF_DIR/common/$profile"
            [[ -d "$bundle/Linux_for_Tegra" ]] || continue
        fi
        [[ -f "$bundle/Linux_for_Tegra/$profile.conf" ]] || continue
        seen[$profile]="$bundle"
    done < <(find "$B_CONF_DIR" -mindepth 2 -maxdepth 2 -type d -print | LC_ALL=C sort)

    for profile in "${!seen[@]}"; do
        printf '%s\t%s\n' "$profile" "${seen[$profile]}"
    done | LC_ALL=C sort
}

mapfile -t PROFILE_ROWS < <(compatible_profiles)
((${#PROFILE_ROWS[@]} > 0)) || {
    if [[ "$VERSION_KNOWN" == true ]]; then
        die "no compatible board profiles for JetPack $JETPACK_VERSION"
    fi
    die 'no common board profiles found; set JETPACK_VERSION or use --jetpack-version to select versioned profiles'
}

if [[ "$LIST_ONLY" == true ]]; then
    if [[ "$VERSION_KNOWN" == true ]]; then
        printf 'Profiles compatible with JetPack %s:\n' "$JETPACK_VERSION"
    else
        printf 'Common profiles (JetPack version unknown; set JETPACK_VERSION or --jetpack-version to include versioned profiles):\n'
    fi
    for row in "${PROFILE_ROWS[@]}"; do
        IFS=$'\t' read -r profile bundle <<< "$row"
        printf '  %-48s %s\n' "$profile" "${bundle#"$REPO_DIR"/}"
        [[ -f "$bundle/COMPATIBILITY.md" ]] && printf '    compatibility log: %s\n' "${bundle#"$REPO_DIR"/}/COMPATIBILITY.md"
    done
    exit 0
fi

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

recovery_device_present() {
    local vendor_file vendor product_file product
    local sysfs_root="${JETSON_USB_SYSFS_ROOT:-/sys/bus/usb/devices}"
    for vendor_file in "$sysfs_root"/*/idVendor; do
        [[ -r "$vendor_file" ]] || continue
        IFS= read -r vendor < "$vendor_file" || continue
        [[ "${vendor,,}" == 0955 ]] || continue
        product_file="${vendor_file%/idVendor}/idProduct"
        [[ -r "$product_file" ]] || continue
        IFS= read -r product < "$product_file" || continue
        case "${product,,}" in
            7023|7223|7323|7423|7523|7623) return 0 ;;
        esac
    done
    return 1
}

wait_for_recovery_device() {
    local answer
    if recovery_device_present; then
        printf 'NVIDIA USB device detected in Recovery mode.\n'
        return 0
    fi

    if [[ "$ASSUME_YES" == true ]] || ! has_tty; then
        die 'Recovery device not detected (no supported NVIDIA Jetson Recovery USB ID).'
    fi

    while true; do
        printf 'Recovery device not detected. Put the Jetson in USB Recovery and connect it, then choose [r]etry or [q]uit: ' > /dev/tty
        IFS= read -r answer < /dev/tty || die 'could not read recovery prompt'
        case "${answer,,}" in
            r|retry)
                if recovery_device_present; then
                    printf 'NVIDIA USB device detected in Recovery mode.\n' > /dev/tty
                    return 0
                fi
                printf 'Recovery device is still not detected.\n' > /dev/tty
                ;;
            q|quit|exit)
                die 'flashing cancelled by user'
                ;;
            *)
                printf 'Enter r to retry or q to quit.\n' > /dev/tty
                ;;
        esac
    done
}

select_profile_interactively() {
    local index choice
    printf 'Compatible board profiles for JetPack %s:\n' "$JETPACK_VERSION" > /dev/tty
    for index in "${!PROFILE_ROWS[@]}"; do
        IFS=$'\t' read -r profile bundle <<< "${PROFILE_ROWS[$index]}"
        printf '  %d) %s (%s)\n' "$((index + 1))" "$profile" "${bundle#"$REPO_DIR"/}" > /dev/tty
    done
    printf 'Choose profile number: ' > /dev/tty
    IFS= read -r choice < /dev/tty || die 'could not read profile choice'
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#PROFILE_ROWS[@]})) || die 'invalid profile choice'
    IFS=$'\t' read -r BOARD SELECTED_BUNDLE <<< "${PROFILE_ROWS[$((choice - 1))]}"
}

if [[ -z "$BOARD" ]]; then
    has_tty || die 'specify --board in batch mode'
    select_profile_interactively
else
    if [[ "$VERSION_KNOWN" == true ]]; then
        SELECTED_BUNDLE="$(b_conf_select_package "$B_CONF_DIR" "$BOARD" "$JETPACK_VERSION")" || exit 1
    else
        SELECTED_BUNDLE="$B_CONF_DIR/common/$BOARD"
        [[ -d "$SELECTED_BUNDLE/Linux_for_Tegra" ]] || die "profile '$BOARD' is not common; set JETPACK_VERSION or use --jetpack-version"
    fi
    [[ -f "$SELECTED_BUNDLE/Linux_for_Tegra/$BOARD.conf" ]] || die "profile config missing: $SELECTED_BUNDLE/Linux_for_Tegra/$BOARD.conf"
fi

if [[ -z "$MODE" ]]; then
    has_tty || die 'specify --mode in batch mode'
    printf 'Flash mode: 1) full  2) dtb (A and B)  3) rootfs (APP only)\nChoose mode: ' > /dev/tty
    IFS= read -r choice < /dev/tty || die 'could not read mode choice'
    case "$choice" in 1) MODE=full ;; 2) MODE=dtb ;; 3) MODE=rootfs ;; *) die 'invalid mode choice' ;; esac
fi
case "$MODE" in
    full) ;;
    dtb|rootfs) ;;
    *) die "invalid mode '$MODE'; expected full, dtb, or rootfs" ;;
esac
[[ "$ROOTDEV" =~ ^[A-Za-z0-9_.+-]+$ ]] || die "invalid root device: $ROOTDEV"

FLASH_COMMANDS=()
case "$MODE" in
    full) FLASH_COMMANDS+=("./flash.sh $BOARD $ROOTDEV") ;;
    dtb)
        FLASH_COMMANDS+=("./flash.sh -k A_kernel-dtb $BOARD $ROOTDEV")
        FLASH_COMMANDS+=("./flash.sh -k B_kernel-dtb $BOARD $ROOTDEV")
        ;;
    rootfs) FLASH_COMMANDS+=("./flash.sh -k APP $BOARD $ROOTDEV") ;;
esac

if [[ "$DRY_RUN" == true ]]; then
    printf 'Dry run: profile=%s, JetPack=%s, mode=%s, rootdev=%s\n' "$BOARD" "$JETPACK_VERSION" "$MODE" "$ROOTDEV"
    printf 'Would install these profile files into %s:\n' "$L4T_DIR"
    while IFS= read -r -d '' file; do printf '  %s\n' "${file#"$SELECTED_BUNDLE/Linux_for_Tegra"/}"; done \
        < <(find "$SELECTED_BUNDLE/Linux_for_Tegra" -type f -print0 | LC_ALL=C sort -z)
    printf 'Would run:\n'
    for command in "${FLASH_COMMANDS[@]}"; do printf '  sudo %s\n' "$command"; done
    exit 0
fi

wait_for_recovery_device

if [[ "$ASSUME_YES" != true ]]; then
    has_tty || die 'non-interactive flashing requires --yes'
    printf 'Profile %s, mode %s. Confirm the Jetson is in USB Recovery and accept that this writes device partitions? [y/N] ' "$BOARD" "$MODE" > /dev/tty
    IFS= read -r answer < /dev/tty || die 'could not read confirmation'
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || die 'operation cancelled'
fi

printf 'Installing profile %s from %s\n' "$BOARD" "$SELECTED_BUNDLE"
b_conf_install_payload "$SELECTED_BUNDLE/Linux_for_Tegra" "$L4T_DIR" || die 'profile payload installation failed'

for command in "${FLASH_COMMANDS[@]}"; do
    # Values are constrained above/profile names are selector-validated. Execute
    # as an argv array so paths and arguments are not re-parsed by a shell.
    read -r -a flash_args <<< "$command"
    printf 'Running: sudo'
    printf ' %q' "${flash_args[@]}"
    printf '\n'
    (cd -- "$L4T_DIR" && sudo "${flash_args[@]}") || die "flash command failed: $command"
done

printf 'Flash operation completed for %s (%s).\n' "$BOARD" "$MODE"
