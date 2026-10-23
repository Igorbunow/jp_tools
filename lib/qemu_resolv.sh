#!/usr/bin/env bash

qemu_ensure_nameservers() {
    local resolv_file="$1"
    local nameserver
    local last_char
    local configured_nameservers
    local -a nameservers=()

    [[ -f "$resolv_file" ]] || {
        printf 'QEMU resolver file not found: %s\n' "$resolv_file" >&2
        return 1
    }
    if grep -Eq '^[[:space:]]*nameserver[[:space:]]+[^[:space:]#]+' "$resolv_file"; then
        return 0
    fi

    configured_nameservers="${JETSON_QEMU_NAMESERVERS:-8.8.8.8 1.1.1.1}"
    configured_nameservers="${configured_nameservers//$'\n'/ }"
    read -r -a nameservers <<< "$configured_nameservers"
    ((${#nameservers[@]} > 0)) || {
        printf 'JETSON_QEMU_NAMESERVERS must contain at least one address\n' >&2
        return 1
    }

    for nameserver in "${nameservers[@]}"; do
        [[ "$nameserver" =~ ^[0-9A-Fa-f:.]+$ && ( "$nameserver" == *.* || "$nameserver" == *:* ) ]] || {
            printf 'Invalid DNS nameserver address: %s\n' "$nameserver" >&2
            return 1
        }
    done

    {
        if [[ -s "$resolv_file" ]]; then
            last_char="$(tail -c 1 "$resolv_file")"
            [[ -z "$last_char" ]] || printf '\n'
        fi
        for nameserver in "${nameservers[@]}"; do
            printf 'nameserver %s\n' "$nameserver"
        done
    } | sudo tee -a "$resolv_file" >/dev/null

    printf 'Added fallback DNS nameservers to %s: %s\n' "$resolv_file" "${nameservers[*]}"
}

qemu_prepare_rootfs_resolv() {
    local rootfs_resolv="$1"
    local host_resolv="$2"
    local backup="${rootfs_resolv}.bak"
    local missing_marker="${backup}.missing"

    if [[ -e "$backup" || -L "$backup" || -e "$missing_marker" ]]; then
        printf 'Resolver backup already exists: %s\n' "$backup" >&2
        return 1
    fi
    if [[ -e "$rootfs_resolv" || -L "$rootfs_resolv" ]]; then
        sudo mv -- "$rootfs_resolv" "$backup" || return 1
    else
        sudo touch -- "$missing_marker" || return 1
    fi
    if ! sudo cp -- "$host_resolv" "$rootfs_resolv"; then
        qemu_restore_rootfs_resolv "$rootfs_resolv"
        return 1
    fi
    if ! qemu_ensure_nameservers "$rootfs_resolv"; then
        qemu_restore_rootfs_resolv "$rootfs_resolv"
        return 1
    fi
}

qemu_restore_rootfs_resolv() {
    local rootfs_resolv="$1"
    local backup="${rootfs_resolv}.bak"
    local missing_marker="${backup}.missing"

    if [[ -e "$backup" || -L "$backup" ]]; then
        sudo rm -f -- "$rootfs_resolv" || return 1
        sudo mv -- "$backup" "$rootfs_resolv" || return 1
    elif [[ -e "$missing_marker" ]]; then
        sudo rm -f -- "$rootfs_resolv" || return 1
        sudo rm -f -- "$missing_marker" || return 1
    fi
    return 0
}
