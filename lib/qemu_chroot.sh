#!/usr/bin/env bash

qemu_chroot_run_shell() {
    local rootfs_path="$1"

    sudo setpriv --clear-groups chroot "$rootfs_path" \
        /usr/bin/env LANG=C LC_ALL=C LANGUAGE=C /bin/bash
}

qemu_chroot_normalize_shell_status() {
    local status="$1"
    [[ "$status" =~ ^[0-9]+$ ]] || return 2
    # Bash may return 130 when the last interactive command was interrupted,
    # even though the user then exited the shell and cleanup completed.
    ((status == 130)) && return 0
    return "$status"
}
