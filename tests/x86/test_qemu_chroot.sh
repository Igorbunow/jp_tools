#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-chroot.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin"
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
EOF
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
export JETSON_TEST_LOG="$fixture/sudo.log"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/qemu_chroot.sh"
qemu_chroot_run_shell "$fixture/rootfs"
grep -Fq 'setpriv --clear-groups chroot ' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU chroot must clear inherited supplementary groups' >&2; exit 1;
}
grep -Fq 'LANG=C LC_ALL=C LANGUAGE=C /bin/bash' "$JETSON_TEST_LOG" || {
    echo 'FAIL: QEMU shell must keep the clean locale environment' >&2; exit 1;
}

printf 'PASS: QEMU chroot clears inherited groups and uses a clean locale\n'
