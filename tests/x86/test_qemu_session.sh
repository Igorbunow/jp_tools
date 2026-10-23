#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/qemu_session.sh"

tmp="$(mktemp -d)"
trap '[[ -n "${holder_pid:-}" ]] && kill "$holder_pid" 2>/dev/null || true; [[ -n "${legacy_pid:-}" ]] && kill "$legacy_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
rootfs="$tmp/rootfs"
mkdir -p "$rootfs/etc"
cleanup_count=0
cleanup_qemu_rootfs() { cleanup_count=$((cleanup_count + 1)); rm -f "$rootfs/etc/resolv.conf.bak"; }
confirm() { [[ "${CONFIRM_RESULT:-no}" == yes ]]; }

qemu_session_begin "$tmp/session.lock" "$rootfs" true false
qemu_session_set_phase "testing"
qemu_session_end true

touch "$rootfs/etc/resolv.conf.bak"
CONFIRM_RESULT=no
if qemu_session_begin "$tmp/session.lock" "$rootfs" true false; then
    echo 'FAIL: interactive recovery should honor a declined prompt' >&2; exit 1
fi
[[ -e "$rootfs/etc/resolv.conf.bak" ]]
CONFIRM_RESULT=yes
qemu_session_begin "$tmp/session.lock" "$rootfs" true false
[[ "$cleanup_count" == 1 && ! -e "$rootfs/etc/resolv.conf.bak" ]]
qemu_session_end true

touch "$rootfs/etc/resolv.conf.bak"
if qemu_session_begin "$tmp/session.lock" "$rootfs" false false; then
    echo 'FAIL: batch recovery must require explicit force' >&2; exit 1
fi
qemu_session_begin "$tmp/session.lock" "$rootfs" false true
[[ "$cleanup_count" == 2 ]]
qemu_session_end true

(
    exec 8>"$tmp/session.lock"
    flock -x 8
    printf 'pid=%s\nrootfs=%s\nphase=live-test\n' "$BASHPID" "$rootfs" > "$tmp/session.lock.meta"
    exec -a setup_jetson.sh sleep 30
) &
holder_pid=$!
for _ in {1..50}; do [[ -f "$tmp/session.lock.meta" ]] && break; sleep 0.02; done
if qemu_session_begin "$tmp/session.lock" "$rootfs" false false; then
    echo 'FAIL: batch mode must not reclaim a live lock implicitly' >&2; exit 1
fi
qemu_session_begin "$tmp/session.lock" "$rootfs" false true
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
qemu_session_end true

(
    exec -a "sudo chroot $rootfs /bin/bash" sleep 30
) &
legacy_pid=$!
for _ in {1..50}; do
    ps -o args= -p "$legacy_pid" | grep -Fq "$rootfs" && break
    sleep 0.02
done
if qemu_session_begin "$tmp/session.lock" "$rootfs" false false; then
    echo 'FAIL: batch mode must detect a legacy orphaned chroot' >&2; exit 1
fi
CONFIRM_RESULT=yes
qemu_session_begin "$tmp/session.lock" "$rootfs" true false
wait "$legacy_pid" 2>/dev/null || true
qemu_session_end true

printf 'PASS: QEMU session lock and stale-state recovery\n'
