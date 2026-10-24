#!/usr/bin/env bash
# List compatible b_conf profiles and flash one selected profile.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
B_CONF_DIR="$SCRIPT_DIR"
# shellcheck source=lib/l4t_mount_cleanup.sh
source "$REPO_DIR/lib/l4t_mount_cleanup.sh"
# shellcheck source=lib/terminal_status.sh
source "$REPO_DIR/lib/terminal_status.sh"
L4T_DIR="${JETSON_L4T_DIR:-}"
DEPLOY_BASE_DIR="${JETSON_DEPLOY_DIR:-}"
ARCHIVE_DIR="${JETSON_ARCHIVE_DIR:-}"
JETPACK_VERSION="${JETPACK_VERSION:-}"
JETSON_MODULE="${JETSON_MODULE:-}"
BOARD="${JETSON_PROFILE:-${JETSON_BOARD:-}}"
SELECTED_BUNDLE=""
MODE=""
ROOTDEV="mmcblk0p1"
ROOTFS_SIZE_REQUESTED="${JETSON_ROOTFS_SIZE:-}"
ROOTFS_SIZE_RESOLVED=""
ROOTFS_SIZE_SOURCE=""
ROOTFS_SIZE_FOR_FLASH=false
FORCE_ROOTFS_SIZE=false
ASSUME_YES=false
DRY_RUN=false
LIST_ONLY=false
REPLACE_CONFLICTS=false
STOCK_PROFILE_SELECTED=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --list                       List compatible project and NVIDIA BSP profiles.
  --board PROFILE              Board profile (also accepted: --profile).
  --module MODULE              Module family (e.g. orin-agx, orin-nx, xavier-agx, nano-2gb, tx1).
  --mode MODE                  full, dtb (write A then B), or rootfs (APP only).
  --jetpack-version VERSION    Override JetPack detection and select matching versioned profiles.
  --l4t-dir PATH               Use this exact Linux_for_Tegra directory.
  --deploy-dir PATH            Use PATH/Linux_for_Tegra as the deployment.
  --rootdev DEVICE             flash.sh root device (default: mmcblk0p1).
  --rootfs-size SIZE           Rootfs size (e.g. 8GiB); use 'max' for the BSP/profile maximum.
  --force-rootfs-size SIZE     Force this explicit size if the profile's maximum is unknown or exceeded.
  --yes                        Confirm BSP changes and destructive flash in batch mode.
  --replace-conflicts          Replace differing profile files already present in the BSP.
  --dry-run                    Print planned file copies and flash commands only.
  -h, --help                   Show this help.

Environment variables:
  JETSON_DEPLOY_DIR            Base deployment directory; uses PATH/Linux_for_Tegra.
  JETSON_ARCHIVE_DIR           Archive directory; used to match the deployed L4T release when image metadata is absent.
  JETSON_L4T_DIR               Exact Linux_for_Tegra directory (takes precedence).
  JETSON_ROOTFS_SIZE           Rootfs size passed to flash.sh; supports a size or 'max'.
  JETPACK_VERSION              JetPack version used to resolve versioned profiles.
  JETSON_MODULE                Restrict profiles to a module family; CLI --module takes precedence.
  JETSON_PROFILE               Board profile name; --board/--profile takes precedence.
  JETSON_BOARD                 Legacy alias for JETSON_PROFILE.
  JETSON_REPLACE_CONFLICTS     Set to 1 to allow replacing differing BSP files.
  JETSON_USB_SYSFS_ROOT        USB sysfs root used for Recovery detection (default: /sys/bus/usb/devices).

Without --board or --mode, an interactive terminal prompts for the missing choices.
Examples:
  $0 --list
  $0 --board jetson-agx-orin-devkit-noeeprom --mode full --yes
  $0 --board jetson-agx-orin-10g_4eth_pci_nvme_dp --mode dtb --yes
  $0 --board jetson-agx-orin-devkit-noeeprom --mode rootfs --dry-run
  $0 --board jetson-agx-orin-devkit-noeeprom --mode full --rootfs-size max
  $0 --module xavier-agx --list --jetpack-version 4.6.6
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

valid_rootfs_size() {
    [[ "$1" =~ ^[0-9]+(KiB|MiB|GiB)?$ ]]
}

rootfs_size_bytes() {
    local value="$1" number unit multiplier
    if [[ "$value" =~ ^([0-9]+)(KiB|MiB|GiB)?$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]:-B}"
    else
        return 1
    fi
    case "$unit" in
        B) multiplier=1 ;;
        KiB) multiplier=1024 ;;
        MiB) multiplier=$((1024 * 1024)) ;;
        GiB) multiplier=$((1024 * 1024 * 1024)) ;;
    esac
    printf '%s\n' "$((number * multiplier))"
}

bsp_profile_rootfs_size() {
    local config="$SELECTED_BUNDLE/Linux_for_Tegra/$BOARD.conf"
    [[ -r "$config" ]] || config="$L4T_DIR/$BOARD.conf"
    [[ -r "$config" ]] || return 1
    LDK_DIR="$L4T_DIR" bash --noprofile --norc -c '
        LDK_DIR="$1"
        export LDK_DIR
        source "$2" >/dev/null 2>&1 || exit 1
        printf "%s\n" "${ROOTFSSIZE:-}"
    ' _ "$L4T_DIR" "$config"
}

bsp_max_rootfs_size() {
    local config="$L4T_DIR/p3701.conf.common"
    [[ -r "$config" ]] || return 1
    bash --noprofile --norc -c '
        source "$1" >/dev/null 2>&1 || exit 1
        printf "%s\n" "${ROOTFSSIZE:-}"
    ' _ "$config"
}

resolve_rootfs_size() {
    local metadata="$SELECTED_BUNDLE/ROOTFS_SIZE"
    local line key value bsp_size="" bsp_max=""
    local default_size="" max_size=""

    if [[ -r "$metadata" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            value="${line#*=}"
            value="${value//[[:space:]]/}"
            case "$key" in
                DEFAULT) default_size="$value" ;;
                MAX) max_size="$value" ;;
                *) die "unknown key '$key' in $metadata" ;;
            esac
        done < "$metadata"
    fi

    if [[ -z "$default_size" ]]; then
        bsp_size="$(bsp_profile_rootfs_size 2>/dev/null || true)"
        default_size="$bsp_size"
    fi
    if [[ -z "$max_size" ]]; then
        bsp_max="$(bsp_max_rootfs_size 2>/dev/null || true)"
        max_size="$bsp_max"
    fi
    valid_rootfs_size "$default_size" || die "could not determine a valid rootfs size for profile $BOARD; set --rootfs-size or JETSON_ROOTFS_SIZE"

    if [[ -z "$ROOTFS_SIZE_REQUESTED" ]]; then
        [[ "$FORCE_ROOTFS_SIZE" == false ]] || die '--force-rootfs-size requires an explicit --rootfs-size value'
        ROOTFS_SIZE_RESOLVED="$default_size"
        ROOTFS_SIZE_SOURCE="profile default"
    elif [[ "${ROOTFS_SIZE_REQUESTED,,}" == max ]]; then
        [[ "$FORCE_ROOTFS_SIZE" == false ]] || die '--force-rootfs-size cannot be combined with --rootfs-size max; provide an explicit size'
        valid_rootfs_size "$max_size" || die "maximum rootfs size is unknown for profile $BOARD; use an explicit size with --force-rootfs-size"
        ROOTFS_SIZE_RESOLVED="$max_size"
        ROOTFS_SIZE_SOURCE="BSP maximum"
    else
        valid_rootfs_size "$ROOTFS_SIZE_REQUESTED" || die "invalid rootfs size '$ROOTFS_SIZE_REQUESTED'; use bytes, KiB, MiB, or GiB"
        ROOTFS_SIZE_RESOLVED="$ROOTFS_SIZE_REQUESTED"
        ROOTFS_SIZE_SOURCE="user selection"
    fi
    local requested_bytes max_bytes
    requested_bytes="$(rootfs_size_bytes "$ROOTFS_SIZE_RESOLVED")" || die "could not parse rootfs size '$ROOTFS_SIZE_RESOLVED'"
    if valid_rootfs_size "$max_size"; then
        max_bytes="$(rootfs_size_bytes "$max_size")" || die "could not parse BSP maximum rootfs size '$max_size'"
        if ((requested_bytes > max_bytes)); then
            [[ "$FORCE_ROOTFS_SIZE" == true ]] || die "requested rootfs size $ROOTFS_SIZE_RESOLVED exceeds the detected BSP maximum $max_size for profile $BOARD; use --force-rootfs-size to override"
            printf 'Rootfs size limit override: %s (requested maximum: %s).\n' "$ROOTFS_SIZE_RESOLVED" "$max_size"
        fi
    elif [[ -n "$ROOTFS_SIZE_REQUESTED" ]]; then
        [[ "$FORCE_ROOTFS_SIZE" == true ]] || die "maximum rootfs size is unknown for profile $BOARD; use --force-rootfs-size with an explicit size to proceed"
        printf 'Rootfs size limit override: %s (maximum unknown).\n' "$ROOTFS_SIZE_RESOLVED"
    fi
    ROOTFS_SIZE_FOR_FLASH=true

    if [[ "$MODE" == dtb ]]; then
        printf 'Rootfs partition size: %s (%s; not written in DTB-only mode).\n' \
            "$ROOTFS_SIZE_RESOLVED" "$ROOTFS_SIZE_SOURCE"
        ROOTFS_SIZE_FOR_FLASH=false
    else
        printf 'Rootfs partition size: %s (%s).\n' "$ROOTFS_SIZE_RESOLVED" "$ROOTFS_SIZE_SOURCE"
    fi
}

while (($#)); do
    case "$1" in
        --list) LIST_ONLY=true; shift ;;
        --board|--profile) (($# >= 2)) || die "$1 requires a value"; BOARD="$2"; shift 2 ;;
        --module) (($# >= 2)) || die "$1 requires a value"; JETSON_MODULE="$2"; shift 2 ;;
        --mode) (($# >= 2)) || die "$1 requires a value"; MODE="$2"; shift 2 ;;
        --jetpack-version) (($# >= 2)) || die "$1 requires a value"; JETPACK_VERSION="$2"; shift 2 ;;
        --l4t-dir) (($# >= 2)) || die "$1 requires a value"; L4T_DIR="$2"; shift 2 ;;
        --deploy-dir) (($# >= 2)) || die "$1 requires a value"; DEPLOY_BASE_DIR="$2"; shift 2 ;;
        --rootdev) (($# >= 2)) || die "$1 requires a value"; ROOTDEV="$2"; shift 2 ;;
        --rootfs-size) (($# >= 2)) || die "$1 requires a value"; ROOTFS_SIZE_REQUESTED="$2"; shift 2 ;;
        --force-rootfs-size) (($# >= 2)) || die "$1 requires a value"; ROOTFS_SIZE_REQUESTED="$2"; FORCE_ROOTFS_SIZE=true; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --replace-conflicts) REPLACE_CONFLICTS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done
[[ "${JETSON_REPLACE_CONFLICTS:-0}" == 1 || "${JETSON_REPLACE_CONFLICTS:-}" == true ]] && REPLACE_CONFLICTS=true

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
    local candidate profile bundle module
    local -A seen=()
    while IFS= read -r candidate; do
        profile="${candidate##*/}"
        [[ -n "$profile" ]] || continue
        module="$(b_conf_profile_module "$candidate" 2>/dev/null || printf 'unspecified')"
        [[ -z "$JETSON_MODULE" || "$module" == "$JETSON_MODULE" ]] || continue
        if [[ "$VERSION_KNOWN" == true ]]; then
            if [[ "$candidate" == "$B_CONF_DIR/modules/"* ]]; then
                bundle="$(b_conf_select_package "$B_CONF_DIR" "$profile" "$JETPACK_VERSION" "$module" 2>/dev/null)" || continue
            else
                bundle="$(b_conf_select_package "$B_CONF_DIR" "$profile" "$JETPACK_VERSION" "${JETSON_MODULE:-}" 2>/dev/null)" || continue
            fi
        else
            bundle="$candidate"
            [[ "$bundle" == "$B_CONF_DIR/common/"* || "$bundle" == "$B_CONF_DIR/modules/"*/common/* ]] || continue
        fi
        [[ -f "$bundle/Linux_for_Tegra/$profile.conf" || -f "$L4T_DIR/$profile.conf" ]] || continue
        seen["$module/$profile"]="$bundle"
    done < <({
        find "$B_CONF_DIR" -mindepth 3 -type d -name Linux_for_Tegra -print | sed 's#/Linux_for_Tegra$##'
        find "$B_CONF_DIR" -mindepth 3 -type f -name MODULE -print | sed 's#/MODULE$##'
    } | LC_ALL=C sort -u)

    for candidate in "${!seen[@]}"; do
        printf '%s\t%s\t%s\n' "${candidate%%/*}" "${candidate#*/}" "${seen[$candidate]}"
    done | LC_ALL=C sort
}

stock_profiles() {
    local config profile module
    for config in "$L4T_DIR"/jetson-*.conf; do
        [[ -f "$config" ]] || continue
        profile="${config##*/}"
        profile="${profile%.conf}"
        module="NVIDIA BSP"
        case "$profile" in
            *orin*) module="orin-agx" ;;
            *xavier-nx*) module="xavier-nx" ;;
            *xavier*) module="xavier-agx" ;;
            *nano-2gb*|*nano-2g*) module="nano-2gb" ;;
            *nano*) module="nano" ;;
            *tx1*) module="tx1" ;;
        esac
        [[ -z "$JETSON_MODULE" || "$JETSON_MODULE" == "$module" ]] || continue
        printf '%s\t%s\n' "$module" "$profile"
    done | LC_ALL=C sort -u
}

stock_profile_available() {
    local wanted="$1" module profile
    while IFS=$'\t' read -r module profile; do
        [[ "$profile" == "$wanted" ]] && return 0
    done < <(stock_profiles)
    return 1
}

compatible_modules() {
    local row module profile bundle
    local -A seen=()
    for row in "${PROFILE_ROWS[@]}"; do
        IFS=$'\t' read -r module profile bundle <<< "$row"
        [[ "$module" != unspecified ]] || continue
        seen[$module]=1
    done
    printf '%s\n' "${!seen[@]}" | LC_ALL=C sort
}

mapfile -t PROFILE_ROWS < <(compatible_profiles)
((${#PROFILE_ROWS[@]} > 0)) || {
    [[ -n "$(stock_profiles)" ]] || {
        if [[ "$VERSION_KNOWN" == true ]]; then
            die "no compatible board profiles for JetPack $JETPACK_VERSION and no NVIDIA profiles found in $L4T_DIR"
        fi
        die 'no common board profiles or NVIDIA BSP profiles found; set JETPACK_VERSION or use --jetpack-version'
    }
}

if [[ "$LIST_ONLY" == true ]]; then
    if [[ "$VERSION_KNOWN" == true ]]; then
        printf 'Profiles compatible with JetPack %s:\n' "$JETPACK_VERSION"
    else
        printf 'Common profiles (JetPack version unknown; set JETPACK_VERSION or --jetpack-version to include versioned profiles):\n'
    fi
    for row in "${PROFILE_ROWS[@]}"; do
        IFS=$'\t' read -r module profile bundle <<< "$row"
        printf '  %-14s %-44s %s\n' "$module" "$profile" "${bundle#"$REPO_DIR"/}"
        [[ -f "$bundle/COMPATIBILITY.md" ]] && printf '    compatibility log: %s\n' "${bundle#"$REPO_DIR"/}/COMPATIBILITY.md"
    done
    printf 'NVIDIA BSP profiles:\n'
    while IFS=$'\t' read -r module profile; do
        [[ -n "$profile" ]] && printf '  %-14s %s\n' "$module" "$profile"
    done < <(stock_profiles)
    exit 0
fi

has_tty() { [[ -t 0 && -t 1 && -r /dev/tty && -w /dev/tty ]]; }

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
            # Orin, AGX Xavier, Xavier NX, Nano, and TX1 Force Recovery IDs.
            7023|7223|7323|7423|7523|7623|7019|7e19|7f21|7721) return 0 ;;
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
    local index choice selected
    local -a modules=()
    if [[ -z "$JETSON_MODULE" ]]; then
        mapfile -t modules < <(compatible_modules)
        if ((${#modules[@]} > 1)); then
            printf 'Compatible module families for JetPack %s:\n' "$JETPACK_VERSION" > /dev/tty
            for index in "${!modules[@]}"; do printf '  %d) %s\n' "$((index + 1))" "${modules[$index]}" > /dev/tty; done
            printf 'Choose module number: ' > /dev/tty
            IFS= read -r choice < /dev/tty || die 'could not read module choice'
            [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#modules[@]})) || die 'invalid module choice'
            JETSON_MODULE="${modules[$((choice - 1))]}"
            mapfile -t PROFILE_ROWS < <(compatible_profiles)
        fi
    fi
    printf 'Compatible b_conf profiles for JetPack %s:\n' "${JETPACK_VERSION:-unknown}" > /dev/tty
    for index in "${!PROFILE_ROWS[@]}"; do
        IFS=$'\t' read -r module profile bundle <<< "${PROFILE_ROWS[$index]}"
        printf '  %d) %s (%s)\n' "$((index + 1))" "$profile" "${bundle#"$REPO_DIR"/}" > /dev/tty
    done
    local stock_choice=$(( ${#PROFILE_ROWS[@]} + 1 ))
    printf '  %d) Browse NVIDIA profiles included in this JetPack BSP\n' "$stock_choice" > /dev/tty
    printf 'Choose profile number: ' > /dev/tty
    IFS= read -r choice < /dev/tty || die 'could not read profile choice'
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= stock_choice)) || die 'invalid profile choice'
    if ((choice == stock_choice)); then
        local -a stocks=()
        mapfile -t stocks < <(stock_profiles)
        ((${#stocks[@]} > 0)) || die "no NVIDIA stock profiles found in $L4T_DIR"
        printf 'NVIDIA profiles included in this JetPack BSP:\n' > /dev/tty
        for index in "${!stocks[@]}"; do
            IFS=$'\t' read -r module profile <<< "${stocks[$index]}"
            printf '  %d) %s (module: %s)\n' "$((index + 1))" "$profile" "$module" > /dev/tty
        done
        printf 'Choose NVIDIA profile number: ' > /dev/tty
        IFS= read -r selected < /dev/tty || die 'could not read NVIDIA profile choice'
        [[ "$selected" =~ ^[0-9]+$ ]] && ((selected >= 1 && selected <= ${#stocks[@]})) || die 'invalid NVIDIA profile choice'
        IFS=$'\t' read -r JETSON_MODULE BOARD <<< "${stocks[$((selected - 1))]}"
        SELECTED_BUNDLE=""
        STOCK_PROFILE_SELECTED=true
    else
        IFS=$'\t' read -r JETSON_MODULE BOARD SELECTED_BUNDLE <<< "${PROFILE_ROWS[$((choice - 1))]}"
        [[ "$JETSON_MODULE" != unspecified ]] || JETSON_MODULE=""
    fi
}

if [[ -z "$BOARD" ]]; then
    has_tty || die 'specify --board in batch mode'
    select_profile_interactively
elif [[ "$STOCK_PROFILE_SELECTED" != true ]]; then
    if [[ -z "$JETSON_MODULE" ]]; then
        local_profile_modules=()
        for row in "${PROFILE_ROWS[@]}"; do
            IFS=$'\t' read -r row_module row_profile row_bundle <<< "$row"
            [[ "$row_profile" == "$BOARD" ]] || continue
            [[ "$row_module" != unspecified ]] || continue
            local_profile_modules+=("$row_module")
        done
        if ((${#local_profile_modules[@]} == 1)); then
            JETSON_MODULE="${local_profile_modules[0]}"
            [[ "$JETSON_MODULE" != unspecified ]] || JETSON_MODULE=""
        elif ((${#local_profile_modules[@]} > 1)); then
            has_tty || die "profile '$BOARD' exists for multiple modules; specify --module"
            printf 'Module families for profile %s:\n' "$BOARD" > /dev/tty
            for index in "${!local_profile_modules[@]}"; do printf '  %d) %s\n' "$((index + 1))" "${local_profile_modules[$index]}" > /dev/tty; done
            printf 'Choose module number: ' > /dev/tty
            IFS= read -r choice < /dev/tty || die 'could not read module choice'
            [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#local_profile_modules[@]})) || die 'invalid module choice'
            JETSON_MODULE="${local_profile_modules[$((choice - 1))]}"
        fi
    fi
    if [[ "$VERSION_KNOWN" == true ]] && SELECTED_BUNDLE="$(b_conf_select_package "$B_CONF_DIR" "$BOARD" "$JETPACK_VERSION" "$JETSON_MODULE" 2>/dev/null)"; then
        :
    else
        if [[ "$VERSION_KNOWN" != true && -d "$B_CONF_DIR/modules/$JETSON_MODULE/common/$BOARD" ]]; then
            SELECTED_BUNDLE="$B_CONF_DIR/modules/$JETSON_MODULE/common/$BOARD"
        elif [[ -f "$L4T_DIR/$BOARD.conf" ]] && stock_profile_available "$BOARD"; then
            SELECTED_BUNDLE=""
        elif [[ "$VERSION_KNOWN" != true ]]; then
            SELECTED_BUNDLE="$B_CONF_DIR/modules/$JETSON_MODULE/common/$BOARD"
            [[ -d "$SELECTED_BUNDLE/Linux_for_Tegra" ]] || die "profile '$BOARD' is not common and no NVIDIA BSP profile matches; set JETPACK_VERSION or use --jetpack-version"
        else
            die "profile '$BOARD' is neither a compatible b_conf profile nor an NVIDIA profile in $L4T_DIR"
        fi
    fi
    [[ -f "$SELECTED_BUNDLE/Linux_for_Tegra/$BOARD.conf" || -f "$L4T_DIR/$BOARD.conf" ]] || die "profile config missing: $BOARD.conf"
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

resolve_rootfs_size

FLASH_COMMANDS=()
case "$MODE" in
    full)
        if [[ "$ROOTFS_SIZE_FOR_FLASH" == true ]]; then
            FLASH_COMMANDS+=("env IDS_ROOTFS_SIZE=$ROOTFS_SIZE_RESOLVED ./flash.sh -S $ROOTFS_SIZE_RESOLVED $BOARD $ROOTDEV")
        else
            FLASH_COMMANDS+=("./flash.sh $BOARD $ROOTDEV")
        fi
        ;;
    dtb)
        FLASH_COMMANDS+=("./flash.sh -k A_kernel-dtb $BOARD $ROOTDEV")
        FLASH_COMMANDS+=("./flash.sh -k B_kernel-dtb $BOARD $ROOTDEV")
        ;;
    rootfs) FLASH_COMMANDS+=("env IDS_ROOTFS_SIZE=$ROOTFS_SIZE_RESOLVED ./flash.sh -S $ROOTFS_SIZE_RESOLVED -k APP $BOARD $ROOTDEV") ;;
esac

if [[ "$DRY_RUN" == true ]]; then
    printf 'Dry run: profile=%s, JetPack=%s, mode=%s, rootdev=%s\n' "$BOARD" "$JETPACK_VERSION" "$MODE" "$ROOTDEV"
    printf 'Would install these profile files into %s:\n' "$L4T_DIR"
    if [[ -d "$SELECTED_BUNDLE/Linux_for_Tegra" ]]; then
        while IFS= read -r -d '' file; do printf '  %s\n' "${file#"$SELECTED_BUNDLE/Linux_for_Tegra"/}"; done \
            < <(find "$SELECTED_BUNDLE/Linux_for_Tegra" -type f -print0 | LC_ALL=C sort -z)
    else
        printf '  (NVIDIA stock BSP profile; no overlay files)\n'
    fi
    printf 'Would run:\n'
    for command in "${FLASH_COMMANDS[@]}"; do printf '  sudo %s\n' "$command"; done
    exit 0
fi

flash_jetson_exit_cleanup() {
    local exit_status=$?
    trap - EXIT
    if [[ -d "$L4T_DIR/bootloader" ]]; then
        l4t_cleanup_deployment_mounts "$L4T_DIR" || exit_status=1
    fi
    terminal_status_finish "$exit_status" || true
    exit "$exit_status"
}
trap flash_jetson_exit_cleanup EXIT
terminal_status_start "Jetson flash"

wait_for_recovery_device

conflicting_payload_files() {
    local payload="$1" source_file relative_path destination
    [[ -d "$payload" ]] || return 0
    while IFS= read -r -d '' source_file; do
        relative_path="${source_file#"$payload"/}"
        destination="$L4T_DIR/$relative_path"
        if [[ -e "$destination" || -L "$destination" ]] && \
            { [[ ! -f "$destination" || -L "$destination" ]] || ! cmp -s -- "$source_file" "$destination"; }; then
            printf '%s\n' "$relative_path"
        fi
    done < <(find "$payload" -type f -print0)
}

if [[ -n "$SELECTED_BUNDLE" && -d "$SELECTED_BUNDLE/Linux_for_Tegra" ]]; then
    mapfile -t CONFLICTS < <(conflicting_payload_files "$SELECTED_BUNDLE/Linux_for_Tegra")
    if ((${#CONFLICTS[@]})); then
        printf 'Profile files differ from existing BSP files:\n'
        for relative_path in "${CONFLICTS[@]}"; do
            printf '  %s\n' "$relative_path"
            source_file="$SELECTED_BUNDLE/Linux_for_Tegra/$relative_path"
            destination="$L4T_DIR/$relative_path"
            if grep -Iq . "$source_file"; then
                diff -u --label "BSP/$relative_path" --label "b_conf/$relative_path" -- "$destination" "$source_file" || true
            else
                printf '    (binary or non-text file differs)\n'
            fi
        done
        if [[ "$REPLACE_CONFLICTS" != true ]]; then
            has_tty || die 'conflicting profile files require --replace-conflicts or JETSON_REPLACE_CONFLICTS=1 in batch mode'
            printf 'Replace the differing files listed above? [y/N] ' > /dev/tty
            IFS= read -r answer < /dev/tty || die 'could not read conflict replacement confirmation'
            [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || die 'profile file replacement cancelled'
            REPLACE_CONFLICTS=true
        fi
    fi
fi

if [[ "$ASSUME_YES" != true ]]; then
    has_tty || die 'non-interactive flashing requires --yes'
    printf 'Profile %s, mode %s. Confirm the Jetson is in USB Recovery and accept that this writes device partitions? [y/N] ' "$BOARD" "$MODE" > /dev/tty
    IFS= read -r answer < /dev/tty || die 'could not read confirmation'
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || die 'operation cancelled'
fi

printf 'Installing profile %s from %s\n' "$BOARD" "${SELECTED_BUNDLE:-NVIDIA BSP}"
if [[ -d "$SELECTED_BUNDLE/Linux_for_Tegra" ]]; then
    b_conf_install_payload "$SELECTED_BUNDLE/Linux_for_Tegra" "$L4T_DIR" "$REPLACE_CONFLICTS" || die 'profile payload installation failed'
fi

for command in "${FLASH_COMMANDS[@]}"; do
    # Values are constrained above/profile names are selector-validated. Execute
    # as an argv array so paths and arguments are not re-parsed by a shell.
    read -r -a flash_args <<< "$command"
    printf 'Running: sudo'
    printf ' %q' "${flash_args[@]}"
    printf '\n'
    flash_status=0
    cleanup_status=0
    (cd -- "$L4T_DIR" && sudo "${flash_args[@]}") || flash_status=$?
    l4t_cleanup_deployment_mounts "$L4T_DIR" || cleanup_status=$?
    ((cleanup_status == 0)) || die "failed to clean BSP mounts after: $command"
    ((flash_status == 0)) || die "flash command failed: $command"
done

printf 'Flash operation completed for %s (%s).\n' "$BOARD" "$MODE"
