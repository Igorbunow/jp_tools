#!/usr/bin/env bash
# List compatible b_conf profiles and flash one selected profile.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
B_CONF_DIR="$SCRIPT_DIR"
L4T_DIR="$REPO_DIR/Linux_for_Tegra"
JETPACK_VERSION="${JETPACK_VERSION:-$(basename -- "$REPO_DIR")}"
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
  --list                       List profiles compatible with this BSP version.
  --board PROFILE              Board profile (also accepted: --profile).
  --mode MODE                  full, dtb (write A then B), or rootfs (APP only).
  --jetpack-version VERSION    Override version inferred from the parent directory.
  --rootdev DEVICE             flash.sh root device (default: mmcblk0p1).
  --yes                        Confirm BSP changes and destructive flash in batch mode.
  --dry-run                    Print planned file copies and flash commands only.
  -h, --help                   Show this help.

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
        --rootdev) (($# >= 2)) || die "$1 requires a value"; ROOTDEV="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (use --help)" ;;
    esac
done

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
        bundle="$(b_conf_select_package "$B_CONF_DIR" "$profile" "$JETPACK_VERSION" 2>/dev/null)" || continue
        [[ -f "$bundle/Linux_for_Tegra/$profile.conf" ]] || continue
        seen[$profile]="$bundle"
    done < <(find "$B_CONF_DIR" -mindepth 2 -maxdepth 2 -type d -print | LC_ALL=C sort)

    for profile in "${!seen[@]}"; do
        printf '%s\t%s\n' "$profile" "${seen[$profile]}"
    done | LC_ALL=C sort
}

mapfile -t PROFILE_ROWS < <(compatible_profiles)
((${#PROFILE_ROWS[@]} > 0)) || die "no compatible board profiles for JetPack $JETPACK_VERSION"

if [[ "$LIST_ONLY" == true ]]; then
    printf 'Profiles compatible with JetPack %s:\n' "$JETPACK_VERSION"
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
    SELECTED_BUNDLE="$(b_conf_select_package "$B_CONF_DIR" "$BOARD" "$JETPACK_VERSION")" || exit 1
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
