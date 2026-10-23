#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-resolv.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin"
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"
PATH="$fixture/bin:$PATH"
export PATH

# shellcheck source=/dev/null
source "$REPO_DIR/lib/qemu_resolv.sh"

resolv="$fixture/resolv.conf"
: > "$resolv"
qemu_ensure_nameservers "$resolv"
[[ "$(cat "$resolv")" == $'nameserver 8.8.8.8\nnameserver 1.1.1.1' ]] || {
    echo 'FAIL: default nameservers were not written' >&2; exit 1;
}

printf 'search example.test\nnameserver 9.9.9.9\n' > "$resolv"
qemu_ensure_nameservers "$resolv"
[[ "$(cat "$resolv")" == $'search example.test\nnameserver 9.9.9.9' ]] || {
    echo 'FAIL: existing nameserver configuration was changed' >&2; exit 1;
}

printf '#nameserver 9.9.9.9\nsearch example.test\n' > "$resolv"
if JETSON_QEMU_NAMESERVERS=$'8.8.8.8\noptions ndots:1' qemu_ensure_nameservers "$resolv" >/dev/null 2>&1; then
    echo 'FAIL: invalid nameserver input was accepted' >&2; exit 1
fi
[[ "$(cat "$resolv")" == $'#nameserver 9.9.9.9\nsearch example.test' ]] || {
    echo 'FAIL: invalid DNS input modified resolv.conf' >&2; exit 1;
}

JETSON_QEMU_NAMESERVERS=4.2.2.1 qemu_ensure_nameservers "$resolv"
[[ "$(tail -n1 "$resolv")" == 'nameserver 4.2.2.1' ]] || {
    echo 'FAIL: commented nameserver was incorrectly treated as active' >&2; exit 1;
}

mkdir -p "$fixture/rootfs/etc"
rootfs_resolv="$fixture/rootfs/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs_resolv"
host_resolv="$fixture/host-resolv.conf"
printf 'search example.test\n' > "$host_resolv"
qemu_prepare_rootfs_resolv "$rootfs_resolv" "$host_resolv"
[[ -f "$rootfs_resolv" && ! -L "$rootfs_resolv" ]] || {
    echo 'FAIL: dangling rootfs resolver symlink was not replaced' >&2; exit 1;
}
grep -Fq 'nameserver 8.8.8.8' "$rootfs_resolv" || {
    echo 'FAIL: DNS fallback was not added to rootfs resolver' >&2; exit 1;
}
[[ -L "$rootfs_resolv.bak" ]] || {
    echo 'FAIL: original dangling symlink was not backed up' >&2; exit 1;
}
qemu_restore_rootfs_resolv "$rootfs_resolv"
[[ -L "$rootfs_resolv" && "$(readlink "$rootfs_resolv")" == '../run/systemd/resolve/stub-resolv.conf' ]] || {
    echo 'FAIL: original dangling resolver symlink was not restored' >&2; exit 1;
}

missing_resolv="$fixture/rootfs/etc/missing-resolv.conf"
qemu_prepare_rootfs_resolv "$missing_resolv" "$host_resolv"
[[ -e "$missing_resolv.bak.missing" ]] || {
    echo 'FAIL: missing original resolver was not tracked for restoration' >&2; exit 1;
}
qemu_restore_rootfs_resolv "$missing_resolv"
[[ ! -e "$missing_resolv" && ! -e "$missing_resolv.bak.missing" ]] || {
    echo 'FAIL: temporary resolver was not removed after restoration' >&2; exit 1;
}

untouched_resolv="$fixture/rootfs/etc/untouched-resolv.conf"
printf 'nameserver 9.9.9.9\n' > "$untouched_resolv"
qemu_restore_rootfs_resolv "$untouched_resolv"
grep -Fq 'nameserver 9.9.9.9' "$untouched_resolv" || {
    echo 'FAIL: cleanup modified a resolver that was not prepared' >&2; exit 1;
}

printf 'PASS: QEMU resolver fallback, preservation, and override\n'
