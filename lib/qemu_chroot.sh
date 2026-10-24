#!/usr/bin/env bash

qemu_chroot_run_shell() (
    local rootfs_path="$1"
    local prompt_module="${2:-jetson}"
    local prompt rc_host_path rc_chroot_path

    prompt_module="${prompt_module//[^a-zA-Z0-9_.-]/-}"
    [[ -n "$prompt_module" ]] || prompt_module="jetson"
    prompt="root@${prompt_module}-qemu:\\w# "

    rc_host_path="$(mktemp "$rootfs_path/tmp/.jetson-qemu-bashrc.XXXXXX")" || return 1
    rc_chroot_path="/tmp/${rc_host_path##*/}"
    trap 'rm -f -- "$rc_host_path"' EXIT
    printf 'if [[ -r /root/.bashrc ]]; then source /root/.bashrc; fi\nPS1=%q\nexport PS1\n' \
        "$prompt" > "$rc_host_path" || return 1
    chmod 0644 "$rc_host_path" || return 1

    sudo setpriv --clear-groups chroot "$rootfs_path" \
        /usr/bin/env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/bash \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        TERM="${TERM:-dumb}" LANG=C LC_ALL=C LANGUAGE=C \
        /bin/bash --rcfile "$rc_chroot_path" -i
)

qemu_chroot_normalize_shell_status() {
    local status="$1"
    [[ "$status" =~ ^[0-9]+$ ]] || return 2
    # Bash may return 130 when the last interactive command was interrupted,
    # even though the user then exited the shell and cleanup completed.
    ((status == 130)) && return 0
    return "$status"
}
