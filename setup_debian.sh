#!/usr/bin/env bash
set -euo pipefail

# Run from the project root even when invoked by absolute or relative path.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$PWD"
cd "$PROJECT_DIR"

BOARD="jetson-agx-orin-devkit"
VERSION=""
L4T_DIR="${JETSON_L4T_DIR:-}"
usage() {
    cat <<EOF
Usage: $0 [--board PROFILE] [--version L4T_VERSION] [--l4t-dir PATH]

Options:
  --board PROFILE       Board profile to patch (default: jetson-agx-orin-devkit).
  --version VERSION     L4T release version used by version-specific fixes.
  --l4t-dir PATH        Exact Linux_for_Tegra directory.
  -h, --help            Show this help.

Environment variables:
  JETSON_L4T_DIR        Default exact Linux_for_Tegra directory; --l4t-dir overrides it.
EOF
}
while (($#)); do
    case "$1" in
        --board) (($# >= 2)) || { echo "--board requires a value" >&2; exit 2; }; BOARD="$2"; shift 2 ;;
        --version) (($# >= 2)) || { echo "--version requires a value" >&2; exit 2; }; VERSION="$2"; shift 2 ;;
        --l4t-dir) (($# >= 2)) || { echo "--l4t-dir requires a value" >&2; exit 2; }; L4T_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$L4T_DIR" ]]; then L4T_DIR="$PROJECT_DIR/Linux_for_Tegra"; fi
[[ "$L4T_DIR" = /* ]] || L4T_DIR="$CALLER_DIR/$L4T_DIR"
L4T_DIR="$(realpath -m -- "$L4T_DIR")"
PATCH_FILE="$L4T_DIR/tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh"
PY_FLASH_INTERNAL="$L4T_DIR/bootloader/tegraflash_internal.py"
RCM_BINARY="$L4T_DIR/bootloader/tegrarcm_v2"
SOURCE_RCM="$PROJECT_DIR/debian_patches/bootloader/tegrarcm_v2"
BOARD_CONF="$L4T_DIR/${BOARD}.conf"
MB2_BCT_NAME="tegra234-mb2-bct-misc-ids-10g-no-cvb-eeprom.dts"
MB2_BCT_DIR="$L4T_DIR/bootloader/generic/BCT"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

check_packages() {
    local -A deps=(
        [abootimg]=abootimg [xmlstarlet]=xmlstarlet [sgdisk]=gdisk
        [parted]=parted [cpio]=cpio [gzip]=gzip [strings]=binutils
        [sshpass]=sshpass [ssh-keygen]=openssh-client
    )
    local cmd
    local -a missing=()
    for cmd in "${!deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("${deps[$cmd]}")
    done
    if ((${#missing[@]})); then
        echo "Installing required packages: ${missing[*]}"
        # Continue with usable repository indexes when one unrelated third-party
        # repository has an expired signing key.
        sudo apt-get update || echo "Warning: apt-get update reported a repository error; trying package installation with available indexes."
        sudo apt-get install -y "${missing[@]}"
    fi
}

replace_rcm_binary() {
    [[ -f "$SOURCE_RCM" ]] || fail "custom RCM binary not found: $SOURCE_RCM"
    [[ -f "$RCM_BINARY" ]] || fail "L4T RCM binary not found: $RCM_BINARY"
    cp -f -- "$SOURCE_RCM" "$RCM_BINARY"
    chmod +x "$RCM_BINARY"
    local src_md5 dst_md5
    src_md5="$(md5sum "$SOURCE_RCM" | awk '{print $1}')"
    dst_md5="$(md5sum "$RCM_BINARY" | awk '{print $1}')"
    [[ "$src_md5" == "$dst_md5" ]] || fail "tegrarcm_v2 checksum mismatch"
    echo "Custom tegrarcm_v2 installed (MD5: $src_md5)."
}

apply_patches() {
    local tmp
    [[ -f "$PATCH_FILE" ]] || fail "L4T recovery script not found: $PATCH_FILE"

    # A: Strip CR characters from recovery_copy_binlist.txt entries.
    if ! grep -Fq "tr -d '\\r'" "$PATCH_FILE"; then
        sed -i 's#|g" >"${_tmp_list_file}"#|g" | tr -d '\''\\r'\'' >"${_tmp_list_file}"#' "$PATCH_FILE"
    fi
    grep -Fq "tr -d '\\r'" "$PATCH_FILE" || fail "could not apply binlist CR cleanup (Patch A)"

    # B: gzip -t should not print expected errors for uncompressed kernels.
    if ! grep -Fq 'gzip -t "${_kernel_fs}" > /dev/null 2>&1' "$PATCH_FILE"; then
        sed -i -E '/gzip -t "\$\{_kernel_fs\}"/s#^[[:space:]]*if[[:space:]]+gzip -t "\$\{_kernel_fs\}"[[:space:]]*;[[:space:]]*then#\t\tif gzip -t "${_kernel_fs}" > /dev/null 2>\&1 ; then#' "$PATCH_FILE"
    fi
    grep -Fq 'gzip -t "${_kernel_fs}" > /dev/null 2>&1' "$PATCH_FILE" || fail "could not apply gzip check (Patch B)"

    # C: Some initrds do not contain dhclient-script.
    if ! grep -Fq 'if [ -f "${_initrd_dir}/sbin/dhclient-script" ]; then' "$PATCH_FILE"; then
        tmp="$(mktemp)"
        if ! awk '
            index($0, "sed -i") && index($0, "dhclient-script") {
                indent = $0; sub(/[^ \t].*$/, "", indent)
                print indent "if [ -f \"${_initrd_dir}/sbin/dhclient-script\" ]; then"
                print indent "\t" $0
                print indent "fi"
                found = 1
                next
            }
            { print }
            END { if (!found) exit 2 }
        ' "$PATCH_FILE" > "$tmp"; then
            rm -f "$tmp"
            fail "could not locate dhclient-script edit (Patch C)"
        fi
        cat "$tmp" > "$PATCH_FILE"
        rm -f "$tmp"
    fi
    grep -Fq 'if [ -f "${_initrd_dir}/sbin/dhclient-script" ]; then' "$PATCH_FILE" || fail "Patch C verification failed"

    # D: DSA host keys are disabled by modern OpenSSH; this failure is nonfatal.
    if ! grep -Fq 'check_warning "ssh-keygen -t dsa"' "$PATCH_FILE"; then
        sed -i '/ssh-keygen -t dsa/s/;[[:space:]]*check_error/;check_warning "ssh-keygen -t dsa"/' "$PATCH_FILE"
    fi
    grep -Fq 'check_warning "ssh-keygen -t dsa"' "$PATCH_FILE" || fail "could not make DSA key generation nonfatal (Patch D)"

    # E: Only edit sshd_config when it exists in the generated initrd.
    if grep -Fq '#Port/Port' "$PATCH_FILE" && ! grep -Fq 'if [ -f "${_initrd_dir}/${sshd_config_file}" ]; then' "$PATCH_FILE"; then
        tmp="$(mktemp)"
        if ! awk '
            index($0, "#Port/Port") { print "\tif [ -f \"${_initrd_dir}/${sshd_config_file}\" ]; then"; found = 1 }
            { print }
            index($0, "UsePAM yes/UsePAM no") && found { print "\tfi"; found = 2 }
            END { if (found != 2) exit 2 }
        ' "$PATCH_FILE" > "$tmp"; then
            rm -f "$tmp"
            fail "could not locate sshd_config edit block (Patch E)"
        fi
        cat "$tmp" > "$PATCH_FILE"
        rm -f "$tmp"
    fi
    if grep -Fq '#Port/Port' "$PATCH_FILE"; then
        grep -Fq 'if [ -f "${_initrd_dir}/${sshd_config_file}" ]; then' "$PATCH_FILE" || fail "Patch E verification failed"
    else
        echo "Patch E not applicable: release writes sshd_config.d/initrd.conf directly."
    fi

    # F: Keep the existing manual recovery-mode handoff workaround.
    if [[ "$BOARD" == jetson-agx-orin-10g_4eth_pci_nvme_dp ]] && ! grep -q 'DEBIAN WORKAROUND' "$PY_FLASH_INTERNAL"; then
        grep -Fq "info_print('Boot Rom communication')" "$PY_FLASH_INTERNAL" || fail "cannot locate Boot Rom handoff in tegraflash_internal.py"
        tmp="$(mktemp)"
        cat > "$tmp" <<'PROMPT'
    print('\n' + '#' * 70)
    print('# DEBIAN WORKAROUND: PLEASE RESET JETSON TO RCM NOW!')
    print('# 1. Power OFF (unplug adapter or hold Power 5-10s)')
    print('# 2. Wait 3 seconds')
    print('# 3. Enter Recovery Mode (Hold Rec, then Power ON)')
    print('#' * 70)
    input('PRESS ENTER TO CONTINUE FLASHING...')
PROMPT
        sed -i "/info_print('Boot Rom communication')/r $tmp" "$PY_FLASH_INTERNAL"
        rm -f "$tmp"
    fi

    echo "L4T Debian compatibility patches are present."
}

ensure_board_mb2_bct() {
    # This board profile names a composite MB2 BCT that is not shipped by L4T.
    # Build it from the NVIDIA P3701 base plus the local carrier-EEPROM override.
    [[ -f "$BOARD_CONF" ]] || fail "board profile not found: $BOARD_CONF"
    grep -Fq "MB2_BCT=\"$MB2_BCT_NAME\"" "$BOARD_CONF" || return 0

    local base="$MB2_BCT_DIR/tegra234-mb2-bct-misc-p3701-0000.dts"
    local override="$MB2_BCT_DIR/tegra234-mb2-bct-ids-cvb-eeprom-override.dtsi"
    local output="$MB2_BCT_DIR/$MB2_BCT_NAME"
    [[ -f "$base" ]] || fail "P3701 MB2 BCT base not found: $base"
    [[ -f "$override" ]] || fail "carrier EEPROM override not found: $override"

    if [[ ! -f "$output" ]]; then
        cat > "$output" <<'DTS'
/dts-v1/;

#include "tegra234-mb2-bct-misc-p3701-0000.dts"
#include "tegra234-mb2-bct-ids-cvb-eeprom-override.dtsi"
DTS
        echo "Created board MB2 BCT: $output"
    fi
}

fix_usb_autosuspend() {
    local parameter=/sys/module/usbcore/parameters/autosuspend
    if [[ -e "$parameter" ]]; then
        echo -1 | sudo tee "$parameter" >/dev/null
    else
        echo "USB autosuspend parameter is unavailable; skipping."
    fi
}

[[ -f "$PATCH_FILE" ]] || fail "L4T recovery script not found: $PATCH_FILE (set --l4t-dir or JETSON_L4T_DIR)"
[[ -f "$BOARD_CONF" ]] || fail "board profile not found: $BOARD_CONF"

# The historical custom RCM/BCT and manual recovery prompt apply only to the
# custom R36 carrier profile. Stock NVIDIA profiles (R35 devkit and R39+) keep
# their release-provided flashing tools and BCT configuration.
if [[ "$BOARD" == jetson-agx-orin-10g_4eth_pci_nvme_dp ]]; then
    [[ -f "$PY_FLASH_INTERNAL" ]] || fail "L4T tegraflash_internal.py not found"
    [[ -f "$RCM_BINARY" ]] || fail "L4T tegrarcm_v2 not found"
    [[ -f "$SOURCE_RCM" ]] || fail "custom tegrarcm_v2 not found"
fi

check_packages
fix_usb_autosuspend
if [[ "$BOARD" == jetson-agx-orin-10g_4eth_pci_nvme_dp ]]; then
    replace_rcm_binary
    ensure_board_mb2_bct
    apply_patches
else
    echo "Stock board profile $BOARD: preserving release-provided RCM/BCT and flash tooling."
    # Still apply the shell recovery-image fixes where their expected script is
    # present; skip the custom tegraflash_internal.py handoff patch.
    apply_patches
fi
