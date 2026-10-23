#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-apt.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin"
mkdir -p "$fixture/rootfs/usr/share/pam-configs"
cat > "$fixture/rootfs/usr/share/pam-configs/nv-power-adapter-check" <<'EOF'

# NVIDIA header that pam-auth-update misparses before its first field.
# A second comment line exercises removal of the complete leading preamble.
Name: NVIDIA power adapter check
Default: yes
Priority: 0
Session-Type: Additional
Session:
\toptional pam_exec.so /usr/sbin/nv_pam_power_adapter_checker.sh
EOF
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
if [[ "$1" == chroot && "$3" == /usr/bin/env ]]; then
    rootfs_path="$2"
    shift 3
    while [[ "$1" == *=* ]]; do shift; done
    if [[ "$1" == /bin/sh ]]; then
        profile="$rootfs_path/usr/share/pam-configs/nv-power-adapter-check"
        temporary="${profile}.test-tmp"
        awk '!started && /^[[:space:]]*$/ { next } !started && /^[[:space:]]*#/ { next } { started=1; print }' \
            "$profile" > "$temporary" && cat "$temporary" > "$profile"
        status=$?
        rm -f "$temporary"
        exit "$status"
    fi
fi
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
[[ "$(head -n 1 "$fixture/rootfs/usr/share/pam-configs/nv-power-adapter-check")" == 'Name: NVIDIA power adapter check' ]] || {
    echo 'FAIL: malformed leading comments were not removed from the NVIDIA PAM profile' >&2; exit 1;
}
[[ "$(grep -c 'apt-get' "$JETSON_TEST_LOG")" -eq 3 ]] || {
    echo 'FAIL: expected PAM profile preparation and apt update, upgrade, and install commands' >&2; exit 1;
}
grep -Fq 'pam-configs/nv-power-adapter-check' "$JETSON_TEST_LOG" || {
    echo 'FAIL: NVIDIA PAM profile preparation did not run before APT' >&2; exit 1;
}
grep -Fq 'apt-get update' "$JETSON_TEST_LOG" || { echo 'FAIL: apt update missing' >&2; exit 1; }
grep -Fq 'LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive apt-get update' "$JETSON_TEST_LOG" || { echo 'FAIL: APT update must use a generated locale-independent environment' >&2; exit 1; }
grep -Fq 'apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade' "$JETSON_TEST_LOG" || {
    echo 'FAIL: non-interactive apt upgrade missing' >&2; exit 1;
}
grep -Fq 'LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive apt-get -y' "$JETSON_TEST_LOG" || { echo 'FAIL: APT upgrade/install must use a generated locale-independent environment' >&2; exit 1; }
grep -Fq 'install mc vim' "$JETSON_TEST_LOG" || { echo 'FAIL: package list was not applied' >&2; exit 1; }

: > "$JETSON_TEST_LOG"
printf 'mc;touch /tmp/bad\n' > "$packages"
if qemu_apt_load_packages "$packages" >/dev/null 2>&1; then
    echo 'FAIL: invalid package name was accepted' >&2; exit 1
fi
[[ ! -s "$JETSON_TEST_LOG" ]] || { echo 'FAIL: apt ran with invalid package list' >&2; exit 1; }

printf 'PASS: package-list parsing and apt update/upgrade/install commands\n'

cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
case "$*" in
    *"$JETSON_TEST_FAIL_MATCH"*) exit "${JETSON_TEST_FAIL_STATUS:-42}" ;;
esac
EOF
chmod +x "$fixture/bin/sudo"
printf 'mc vim\n' > "$packages"
qemu_apt_load_packages "$packages"
for failure_case in \
    'apt-get update|apt-get update|42' \
    'upgrade|apt-get upgrade|43' \
    'install mc vim|apt-get install|44'; do
    IFS='|' read -r JETSON_TEST_FAIL_MATCH expected_step expected_status <<< "$failure_case"
    export JETSON_TEST_FAIL_MATCH
    JETSON_TEST_FAIL_STATUS="$expected_status"
    export JETSON_TEST_FAIL_STATUS
    : > "$JETSON_TEST_LOG"
    if qemu_apt_run_update_upgrade "$fixture/rootfs"; then
        echo "FAIL: failed $expected_step was reported as successful" >&2; exit 1
    fi
    [[ "$QEMU_APT_FAILED_STEP" == "$expected_step" && "$QEMU_APT_EXIT_STATUS" -eq "$expected_status" ]] || {
        echo "FAIL: $expected_step failure and exit status were not recorded" >&2; exit 1;
    }
done
