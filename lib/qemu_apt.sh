#!/usr/bin/env bash

QEMU_APT_PACKAGES=()

qemu_apt_load_packages() {
    local package_file="$1"
    local line package
    local -a line_packages=()

    [[ -r "$package_file" ]] || {
        printf 'APT package list is not readable: %s\n' "$package_file" >&2
        return 1
    }

    QEMU_APT_PACKAGES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        read -r -a line_packages <<< "$line"
        for package in "${line_packages[@]}"; do
            [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || {
                printf 'Invalid Debian package name in %s: %s\n' "$package_file" "$package" >&2
                QEMU_APT_PACKAGES=()
                return 1
            }
            QEMU_APT_PACKAGES+=("$package")
        done
    done < "$package_file"
}

qemu_apt_run_update_upgrade() {
    local rootfs_path="$1"

    sudo chroot "$rootfs_path" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    sudo chroot "$rootfs_path" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || return 1
    if ((${#QEMU_APT_PACKAGES[@]})); then
        sudo chroot "$rootfs_path" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
            apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            install "${QEMU_APT_PACKAGES[@]}" || return 1
    fi
}
