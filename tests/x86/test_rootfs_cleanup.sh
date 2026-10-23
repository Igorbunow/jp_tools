#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/rootfs_cleanup.sh"

fixture="$(mktemp -d /tmp/jetson-rootfs-clean.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
rootfs="$fixture/rootfs"
mkdir -p "$rootfs/tmp/session" "$rootfs/var/tmp" "$rootfs/run/systemd/resolve" \
    "$rootfs/var/cache/apt/archives/partial" "$rootfs/var/cache/man" \
    "$rootfs/var/cache/debconf" "$rootfs/var/lib/apt/lists/partial" \
    "$rootfs/var/cache/apt" \
    "$rootfs/var/log/journal/machine" "$rootfs/var/lib/systemd/coredump" \
    "$rootfs/var/crash" "$rootfs/usr/bin" "$rootfs/home/nvidia/.cache" \
    "$rootfs/home/nvidia/.npm/_cacache" "$rootfs/home/nvidia/.local/share/fish" \
    "$rootfs/root/.cache" "$rootfs/etc"
printf 'temporary\n' > "$rootfs/tmp/session/tmp-file"
printf 'temporary\n' > "$rootfs/var/tmp/tmp-file"
printf 'runtime\n' > "$rootfs/run/systemd/runtime-file"
printf 'resolver target\n' > "$rootfs/run/systemd/resolve/stub-resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
printf 'package\n' > "$rootfs/var/cache/apt/archives/package.deb"
printf 'apt-cache\n' > "$rootfs/var/cache/apt/pkgcache.bin"
printf 'apt-source-cache\n' > "$rootfs/var/cache/apt/srcpkgcache.bin"
printf 'partial\n' > "$rootfs/var/cache/apt/archives/partial/download"
printf 'index\n' > "$rootfs/var/lib/apt/lists/packages.gz"
printf 'lock\n' > "$rootfs/var/lib/apt/lists/lock"
printf 'man-cache\n' > "$rootfs/var/cache/man/index.db"
printf 'debconf\n' > "$rootfs/var/cache/debconf/config.dat"
printf 'journal\n' > "$rootfs/var/log/journal/machine/system.journal"
printf 'log\n' > "$rootfs/var/log/dpkg.log"
printf 'old-log\n' > "$rootfs/var/log/dpkg.log.1"
printf 'core\n' > "$rootfs/var/lib/systemd/coredump/core.dump"
printf 'crash\n' > "$rootfs/var/crash/crash.report"
printf 'user-cache\n' > "$rootfs/home/nvidia/.cache/data"
printf 'npm-cache\n' > "$rootfs/home/nvidia/.npm/_cacache/data"
printf 'bash commands\n' > "$rootfs/home/nvidia/.bash_history"
printf 'fish commands\n' > "$rootfs/home/nvidia/.local/share/fish/fish_history"
printf 'root commands\n' > "$rootfs/root/.bash_history"
printf 'root cache\n' > "$rootfs/root/.cache/data"
printf 'configuration\n' > "$rootfs/etc/important.conf"

sudo() { "$@"; }
qemu_source="$fixture/qemu-aarch64-static"
printf 'qemu binary\n' > "$qemu_source"
chmod +x "$qemu_source"
rootfs_cleanup_install_temporary_qemu "$rootfs" "$qemu_source"
[[ -x "$rootfs/usr/bin/qemu-aarch64-static" ]] || { echo 'FAIL: temporary QEMU binary was not installed' >&2; exit 1; }
rootfs_cleanup_transient_artifacts "$rootfs" false
[[ -e "$rootfs/usr/bin/qemu-aarch64-static" &&
    -e "$rootfs/usr/bin/.jetson-qemu-aarch64-static-temporary" ]] || {
    echo 'FAIL: disabled cleanup removed the setup-owned QEMU emulator' >&2; exit 1;
}
rootfs_cleanup_remove_temporary_qemu "$rootfs"
[[ ! -e "$rootfs/usr/bin/qemu-aarch64-static" ]] || { echo 'FAIL: setup-owned QEMU binary remained' >&2; exit 1; }

printf 'pre-existing binary\n' > "$rootfs/usr/bin/qemu-aarch64-static"
chmod +x "$rootfs/usr/bin/qemu-aarch64-static"
rootfs_cleanup_install_temporary_qemu "$rootfs" "$qemu_source"
rootfs_cleanup_remove_temporary_qemu "$rootfs"
[[ -s "$rootfs/usr/bin/qemu-aarch64-static" ]] || { echo 'FAIL: pre-existing QEMU binary was removed' >&2; exit 1; }
rm -f "$rootfs/usr/bin/qemu-aarch64-static"

ROOTFS_CLEANUP_ENABLED=false
rootfs_cleanup_transient_artifacts "$rootfs" "$ROOTFS_CLEANUP_ENABLED"
[[ -s "$rootfs/tmp/session/tmp-file" ]] || { echo 'FAIL: disabled cleanup changed /tmp' >&2; exit 1; }

rootfs_cleanup_install_temporary_qemu "$rootfs" "$qemu_source"
ROOTFS_CLEANUP_ENABLED=true
rootfs_cleanup_transient_artifacts "$rootfs" "$ROOTFS_CLEANUP_ENABLED"
for removed_file in \
    "$rootfs/tmp/session/tmp-file" "$rootfs/var/tmp/tmp-file" \
    "$rootfs/run/systemd/runtime-file" "$rootfs/var/cache/apt/archives/package.deb" \
    "$rootfs/var/cache/apt/pkgcache.bin" "$rootfs/var/cache/apt/srcpkgcache.bin" \
    "$rootfs/var/cache/apt/archives/partial/download" "$rootfs/var/lib/apt/lists/packages.gz" \
    "$rootfs/var/cache/man/index.db" "$rootfs/var/log/journal/machine/system.journal" \
    "$rootfs/var/log/dpkg.log.1" "$rootfs/var/lib/systemd/coredump/core.dump" \
    "$rootfs/var/crash/crash.report" "$rootfs/usr/bin/qemu-aarch64-static" \
    "$rootfs/home/nvidia/.bash_history" \
    "$rootfs/home/nvidia/.local/share/fish/fish_history" "$rootfs/root/.bash_history"; do
    [[ ! -e "$removed_file" ]] || { echo "FAIL: transient artifact remained: $removed_file" >&2; exit 1; }
done
[[ ! -s "$rootfs/var/log/dpkg.log" ]] || { echo 'FAIL: active log was not truncated' >&2; exit 1; }
[[ -e "$rootfs/var/lib/apt/lists/lock" ]] || { echo 'FAIL: APT lock file was removed' >&2; exit 1; }
[[ -d "$rootfs/run/systemd" && -s "$rootfs/run/systemd/resolve/stub-resolv.conf" ]] || {
    echo 'FAIL: runtime directories or the restored resolver target were removed' >&2; exit 1;
}
[[ -d "$rootfs/home/nvidia/.cache" && -d "$rootfs/root/.cache" ]] || {
    echo 'FAIL: user cache directories were removed instead of emptied' >&2; exit 1;
}
[[ -s "$rootfs/var/cache/debconf/config.dat" ]] || { echo 'FAIL: debconf database was removed' >&2; exit 1; }
[[ ! -e "$rootfs/home/nvidia/.cache/data" && ! -e "$rootfs/home/nvidia/.npm/_cacache/data" &&
    ! -e "$rootfs/root/.cache/data" ]] || {
    echo 'FAIL: user/root package caches were not removed' >&2; exit 1;
}
[[ -s "$rootfs/etc/important.conf" ]] || { echo 'FAIL: system configuration was removed' >&2; exit 1; }
printf 'PASS: rootfs cleanup removes transient system artifacts and preserves user/config state\n'
