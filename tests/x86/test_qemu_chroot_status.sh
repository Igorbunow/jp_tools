#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/qemu_chroot.sh"

qemu_chroot_normalize_shell_status 130
if qemu_chroot_normalize_shell_status 7; then
    echo 'FAIL: an explicitly nonzero interactive shell exit must remain an error' >&2; exit 1
else
    [[ "$?" -eq 7 ]] || { echo 'FAIL: interactive shell status was not preserved' >&2; exit 1; }
fi
printf 'PASS: Ctrl+C status is handled while other QEMU shell errors are preserved\n'
