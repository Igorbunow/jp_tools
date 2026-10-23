#!/usr/bin/env bash

QEMU_APT_PACKAGES=()
QEMU_APT_FAILED_STEP=""
QEMU_APT_EXIT_STATUS=0

qemu_apt_run_in_rootfs() {
    local rootfs_path="$1"
    shift
    sudo chroot "$rootfs_path" /usr/bin/env \
        LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive "$@"
}

qemu_apt_repair_nvidia_pam_profile() {
    local rootfs_path="$1"

    sudo chroot "$rootfs_path" /usr/bin/env \
        LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive \
        /bin/sh -c '
            profile=/usr/share/pam-configs/nv-power-adapter-check
            [ -f "$profile" ] || exit 0
            temporary=$(mktemp "${profile}.XXXXXX") || exit 1
            trap '\''rm -f "$temporary"'\'' EXIT HUP INT TERM
            awk '\''
                !started && /^[[:space:]]*$/ { next }
                !started && /^[[:space:]]*#/ { next }
                { started = 1; print }
            '\'' "$profile" > "$temporary" || exit 1
            cat "$temporary" > "$profile" || exit 1
        '
}

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
    local status

    QEMU_APT_FAILED_STEP=""
    QEMU_APT_EXIT_STATUS=0

    qemu_apt_repair_nvidia_pam_profile "$rootfs_path"
    status=$?
    if ((status != 0)); then
        QEMU_APT_FAILED_STEP="NVIDIA PAM profile preparation"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    qemu_apt_run_in_rootfs "$rootfs_path" apt-get update
    status=$?
    if ((status != 0)); then
        QEMU_APT_FAILED_STEP="apt-get update"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    qemu_apt_run_in_rootfs "$rootfs_path" \
        apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
    status=$?
    if ((status != 0)); then
        QEMU_APT_FAILED_STEP="apt-get upgrade"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    if ((${#QEMU_APT_PACKAGES[@]})); then
        qemu_apt_run_in_rootfs "$rootfs_path" \
            apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            install "${QEMU_APT_PACKAGES[@]}"
        status=$?
        if ((status != 0)); then
            QEMU_APT_FAILED_STEP="apt-get install"
            QEMU_APT_EXIT_STATUS="$status"
            return "$status"
        fi
    fi
}
