#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-apt.XXXXXX)"
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
source "$REPO_DIR/lib/qemu_apt.sh"

qemu_apt_load_packages "$REPO_DIR/qemu-packages.txt"
[[ "${QEMU_APT_PACKAGES[*]}" == 'mc vim' ]] || {
    echo 'FAIL: default package list must install mc and vim' >&2; exit 1;
}

packages="$fixture/packages.txt"
cat > "$packages" <<'EOF'
# desired editor and tools
mc

vim # basic editor
EOF

qemu_apt_load_packages "$packages"
qemu_apt_run_update_upgrade "$fixture/rootfs"
[[ "$(wc -l < "$JETSON_TEST_LOG")" -eq 3 ]] || {
    echo 'FAIL: expected apt update, upgrade, and install commands' >&2; exit 1;
}
grep -Fq 'apt-get update' "$JETSON_TEST_LOG" || { echo 'FAIL: apt update missing' >&2; exit 1; }
grep -Fq 'apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade' "$JETSON_TEST_LOG" || {
    echo 'FAIL: non-interactive apt upgrade missing' >&2; exit 1;
}
grep -Fq 'install mc vim' "$JETSON_TEST_LOG" || { echo 'FAIL: package list was not applied' >&2; exit 1; }

: > "$JETSON_TEST_LOG"
printf 'mc;touch /tmp/bad\n' > "$packages"
if qemu_apt_load_packages "$packages" >/dev/null 2>&1; then
    echo 'FAIL: invalid package name was accepted' >&2; exit 1
fi
[[ ! -s "$JETSON_TEST_LOG" ]] || { echo 'FAIL: apt ran with invalid package list' >&2; exit 1; }

printf 'PASS: package-list parsing and apt update/upgrade/install commands\n'
