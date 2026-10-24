#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-chroot.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/rootfs/tmp"
cat > "$fixture/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
while (($#)); do
    if [[ "$1" == --rcfile ]]; then
        rc_inside="$2"
        cat "$JETSON_TEST_ROOTFS$rc_inside" >> "$JETSON_TEST_LOG"
        break
    fi
    shift
done
exit "${JETSON_TEST_SUDO_EXIT:-0}"
SUDO
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
export JETSON_TEST_LOG="$fixture/sudo.log"
export JETSON_TEST_ROOTFS="$fixture/rootfs"
export DISPLAY=:99
export XAUTHORITY=/tmp/host-xauthority

# shellcheck source=/dev/null
source "$REPO_DIR/lib/qemu_chroot.sh"
qemu_chroot_run_shell "$fixture/rootfs" orin-agx

grep -Fq 'setpriv --clear-groups chroot ' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU chroot must clear inherited supplementary groups' >&2; exit 1;
}
grep -Fq '/usr/bin/env -i HOME=/root USER=root LOGNAME=root' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU shell must start with a clean environment' >&2; exit 1;
}
grep -Fq 'TERM=' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU shell must preserve the terminal type' >&2; exit 1;
}
if grep -Eq 'DISPLAY=|XAUTHORITY=' "$JETSON_TEST_LOG"; then
    echo 'FAIL: host X11 authorization variables must not enter the chroot' >&2; exit 1;
fi
grep -Fq 'root@orin-agx-qemu:' "$JETSON_TEST_LOG" && grep -Fq '\\w#' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU shell prompt must identify its target module and environment' >&2; exit 1;
}
if find "$fixture/rootfs/tmp" -name '.jetson-qemu-bashrc.*' -print -quit | grep -q .; then
    echo 'FAIL: temporary QEMU bashrc must be removed after shell exit' >&2; exit 1;
fi
if JETSON_TEST_SUDO_EXIT=29 qemu_chroot_run_shell "$fixture/rootfs" orin-agx; then
    echo 'FAIL: QEMU shell must preserve a nonzero chroot status' >&2; exit 1
else
    status=$?
    [[ "$status" == 29 ]] || { echo "FAIL: unexpected QEMU shell status: $status" >&2; exit 1; }
fi
if find "$fixture/rootfs/tmp" -name '.jetson-qemu-bashrc.*' -print -quit | grep -q .; then
    echo 'FAIL: temporary QEMU bashrc must be removed after a failed shell' >&2; exit 1;
fi

printf 'PASS: QEMU chroot has a target-specific prompt, a clean environment, and no temporary shell config remains\n'
