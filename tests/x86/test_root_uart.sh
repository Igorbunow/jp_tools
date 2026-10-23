#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-uart.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/rootfs/etc/systemd/system/serial-getty@ttyTCU0.service.d"
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/root_uart.sh"

dropin="$fixture/rootfs/etc/systemd/system/serial-getty@ttyTCU0.service.d/autologin.conf"
printf '[Service]\nExecStart=-/sbin/agetty --autologin nvidia\n' > "$dropin"
configure_root_uart_login "$fixture/rootfs" true
[[ "$ROOT_UART_MESSAGE" == 'Enabled passwordless root autologin on serial-getty@ttyTCU0.service.' ]] || {
    echo 'FAIL: UART result message was not returned to the caller' >&2; exit 1;
}
grep -Fq 'ExecStart=-/sbin/agetty --autologin root' "$dropin" || {
    echo 'FAIL: root UART autologin was not configured' >&2; exit 1;
}
if grep -Fq -- '--autologin nvidia' "$dropin"; then
    echo 'FAIL: previous default-user autologin was not replaced' >&2; exit 1
fi

configure_root_uart_login "$fixture/rootfs" false
[[ "$ROOT_UART_MESSAGE" == 'Disabled passwordless root UART autologin.' ]] || {
    echo 'FAIL: UART disable message was not returned to the caller' >&2; exit 1;
}
[[ ! -e "$dropin" ]] || { echo 'FAIL: disabled UART autologin drop-in remains' >&2; exit 1; }

setup_script="$REPO_DIR/setup_jetson.sh"
apt_prompt_line="$(grep -nF 'confirm "Run apt update/upgrade on rootfs' "$setup_script" | cut -d: -f1)"
qemu_prompt_line="$(grep -nF 'confirm "Enter the QEMU chroot' "$setup_script" | cut -d: -f1)"
qemu_error_line="$(grep -nF 'QEMU chroot setup failed ' "$setup_script" | cut -d: -f1)"
uart_apply_line="$(grep -nF 'configure_root_uart_login "$TARGET_DIR/rootfs"' "$setup_script" | cut -d: -f1)"
final_status_line="$(grep -nF '[[ "$POST_SETUP_FAILED" == false ]] || exit 1' "$setup_script" | cut -d: -f1)"
if ! ((apt_prompt_line < qemu_prompt_line && qemu_prompt_line < qemu_error_line && \
       qemu_error_line < uart_apply_line && uart_apply_line < final_status_line)); then
    echo 'FAIL: APT must precede QEMU and UART must be configured before returning an optional-stage error' >&2
    exit 1
fi
grep -Fq 'update_step "$ROOT_UART_MESSAGE"' "$setup_script" || {
    echo 'FAIL: UART result must be shown as a colored progress step' >&2; exit 1;
}
grep -Fq 'TOTAL_STEPS="$(jetson_calculate_total_steps' "$setup_script" || {
    echo 'FAIL: progress total must reflect the selected stages' >&2; exit 1;
}
grep -Fq 'update_step "Updating rootfs with APT"' "$setup_script" || {
    echo 'FAIL: APT update must be shown as a progress step' >&2; exit 1;
}
grep -Fq 'update_step "Entering QEMU chroot for configuration"' "$setup_script" || {
    echo 'FAIL: interactive QEMU chroot must be shown as a progress step' >&2; exit 1;
}
grep -Fq 'Disable with --no-root-uart-login.' "$setup_script" || {
    echo 'FAIL: UART disable hint must be displayed on the following line' >&2; exit 1;
}

printf 'PASS: UART autologin replaces default user with root and can be disabled\n'
