#!/usr/bin/env bash

configure_root_uart_login() {
    local rootfs="$1"
    local enabled="$2"
    local dropin="$rootfs/etc/systemd/system/serial-getty@ttyTCU0.service.d/autologin.conf"

    [[ -d "$rootfs/etc/systemd/system" ]] || {
        ROOT_UART_MESSAGE="UART autologin skipped: systemd unit directory is unavailable."
        return 0
    }
    if [[ "$enabled" == true ]]; then
        sudo mkdir -p "$(dirname -- "$dropin")" || return 1
        sudo tee "$dropin" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I ${TERM}
EOF
        ROOT_UART_MESSAGE="Enabled passwordless root autologin on serial-getty@ttyTCU0.service."
    else
        sudo rm -f "$dropin" || return 1
        ROOT_UART_MESSAGE="Disabled passwordless root UART autologin."
    fi
}
