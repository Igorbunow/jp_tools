#!/usr/bin/env bash

# Resolve shared and JetPack-specific rootfs overlays for a distro/codename.
rootfs_fix_version_layers() {
    local root="$1" version="$2" os_id="$3" codename="$4"
    local major minor patch selector dir candidate
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || return 0
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[4]:-0}"
    local -a selectors=("$major.x" "$major.$minor.x")
    if [[ "$version" == *.*.* ]]; then
        selectors+=("$major.$minor.$patch")
    else
        selectors+=("$major.$minor")
    fi
    for selector in "${selectors[@]}"; do
        dir="$root/$selector/$os_id"
        for candidate in "$dir/default" "$dir/$codename"; do
            [[ "$candidate" != "$dir/default" || "$codename" != default ]] || continue
            [[ -d "$candidate" ]] && printf '%s\n' "$candidate"
        done
    done
}

rootfs_fix_install_file() {
    local source="$1" target="$2" mode="$3"
    mkdir -p -- "$(dirname -- "$target")" 2>/dev/null || sudo mkdir -p -- "$(dirname -- "$target")" || return 1
    if [[ -w "$(dirname -- "$target")" ]]; then
        install -m "$mode" -- "$source" "$target"
    else
        sudo install -m "$mode" -- "$source" "$target"
    fi
}

rootfs_fix_apply_layers() {
    local rootfs="$1" fixes_root="$2" version="$3" os_id="$4" codename="$5"
    local layer source relative target patch_file temp
    local -a layers=()
    [[ "$os_id" =~ ^[a-zA-Z0-9._+-]+$ && "$codename" =~ ^[a-zA-Z0-9._+-]+$ ]] || return 2
    [[ -d "$fixes_root/common/$os_id/default" ]] && layers+=("$fixes_root/common/$os_id/default")
    if [[ "$codename" != default && -d "$fixes_root/common/$os_id/$codename" ]]; then
        layers+=("$fixes_root/common/$os_id/$codename")
    fi
    while IFS= read -r layer; do layers+=("$layer"); done < <(rootfs_fix_version_layers "$fixes_root" "$version" "$os_id" "$codename")
    for layer in "${layers[@]}"; do
        if [[ -d "$layer/files" ]]; then
            while IFS= read -r -d '' source; do
                relative="${source#"$layer/files/"}"
                [[ "$relative" != /* && "$relative" != *'..'* ]] || { printf 'Unsafe rootfs fix path: %s\n' "$relative" >&2; return 1; }
                target="$rootfs/$relative"
                if [[ -L "$target" ]]; then
                    printf 'Refusing to replace rootfs symlink with release fix: %s\n' "$target" >&2
                    return 1
                fi
                rootfs_fix_install_file "$source" "$target" "$(stat -c '%a' "$source")" || return 1
            done < <(find "$layer/files" -type f -print0 | sort -z)
        fi
        if [[ -d "$layer/patches" ]]; then
            while IFS= read -r -d '' patch_file; do
                if patch -d "$rootfs" -p1 --dry-run -R < "$patch_file" >/dev/null 2>&1 ||
                   sudo patch -d "$rootfs" -p1 --dry-run -R < "$patch_file" >/dev/null 2>&1; then
                    continue
                fi
                if [[ -w "$rootfs" ]]; then
                    patch -d "$rootfs" -p1 --forward < "$patch_file" || return 1
                else
                    sudo patch -d "$rootfs" -p1 --forward < "$patch_file" || return 1
                fi
            done < <(find "$layer/patches" -type f -name '*.patch' -print0 | sort -z)
        fi
    done
}

rootfs_fix_read_os_release() {
    local file="$1" key value line
    ROOTFS_FIX_OS_ID="" ROOTFS_FIX_CODENAME="" ROOTFS_FIX_PRETTY_NAME="" ROOTFS_FIX_VERSION_ID=""
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
        case "$key" in
            ID) ROOTFS_FIX_OS_ID="${value,,}" ;;
            VERSION_CODENAME) ROOTFS_FIX_CODENAME="$value" ;;
            PRETTY_NAME) ROOTFS_FIX_PRETTY_NAME="$value" ;;
            VERSION_ID) ROOTFS_FIX_VERSION_ID="$value" ;;
        esac
    done < "$file"
    [[ -n "$ROOTFS_FIX_OS_ID" ]]
}

rootfs_fix_chipid_to_soc() {
    case "${1,,}" in
        0x21|21) printf 't210\n' ;;
        0x18|18) printf 't186\n' ;;
        0x19|19) printf 't194\n' ;;
        0x23|23) printf 't234\n' ;;
        *) return 1 ;;
    esac
}

rootfs_fix_normalize_nvidia_soc() {
    local rootfs="$1" board_conf="${2:-}" chipid="" source_file tmp soc
    if [[ -r "$rootfs/etc/nv_boot_control.conf" ]]; then
        chipid="$(awk '$1 == "TEGRA_CHIPID" {print $2; exit}' "$rootfs/etc/nv_boot_control.conf")"
    fi
    if [[ -z "$chipid" && -n "$board_conf" && -r "$board_conf" ]]; then
        chipid="$(LDK_DIR="$(dirname -- "$board_conf")" BOARD_CONF_NAME="$(basename -- "$board_conf")" \
            bash -c 'source "$LDK_DIR/$BOARD_CONF_NAME" >/dev/null 2>&1; printf "%s" "${CHIPID:-}"' 2>/dev/null || true)"
    fi
    if [[ -z "$chipid" && -n "$board_conf" && -r "$board_conf" ]]; then
        chipid="$(awk -F= '$1 ~ /^[[:space:]]*CHIPID[[:space:]]*$/ {gsub(/["\047[:space:]]/, "", $2); print $2; exit}' "$board_conf")"
    fi
    [[ -n "$chipid" ]] || {
        if grep -RqsE '^[[:space:]]*[^#[:space:]].*<SOC>' "$rootfs/etc/apt/sources.list" "$rootfs/etc/apt/sources.list.d" 2>/dev/null; then
            printf 'Cannot resolve NVIDIA <SOC> repository placeholder: board CHIPID is unknown.\n' >&2
            return 1
        fi
        return 0
    }
    soc="$(rootfs_fix_chipid_to_soc "$chipid")" || {
        printf 'Unsupported NVIDIA repository CHIPID: %s\n' "$chipid" >&2
        return 1
    }
    while IFS= read -r -d '' source_file; do
        grep -qE '^[[:space:]]*[^#[:space:]].*<SOC>' "$source_file" || continue
        if [[ -w "$source_file" ]]; then
            sed -i '/^[[:space:]]*#/!s|<SOC>|'"$soc"'|g' "$source_file" || return 1
        else
            sudo sed -i '/^[[:space:]]*#/!s|<SOC>|'"$soc"'|g' "$source_file" || return 1
        fi
    done < <(find "$rootfs/etc/apt" -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
}

rootfs_fix_write_identity() {
    local rootfs="$1" jetpack="$2" l4t="$3" board="$4"
    local distro codename version_id
    rootfs_fix_read_os_release "$rootfs/etc/os-release" || return 1
    distro="${ROOTFS_FIX_PRETTY_NAME:-${ROOTFS_FIX_OS_ID}}"
    codename="${ROOTFS_FIX_CODENAME:-unknown}"
    version_id="${ROOTFS_FIX_VERSION_ID:-unknown}"
    local temp_file
    temp_file="$(mktemp)" || return 1
    printf 'JetPack: %s\nL4T: %s\nDistribution: %s (%s; version %s)\nBoard profile: %s\n' \
        "$jetpack" "$l4t" "$distro" "$codename" "$version_id" "$board" > "$temp_file"
    rootfs_fix_install_file "$temp_file" "$rootfs/etc/jetson-image-info" 644
    local status=$?
    rm -f -- "$temp_file"
    return "$status"
}
