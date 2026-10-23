#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

fixture="$(mktemp -d /tmp/jetson-flasher.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/b_conf/common/demo/Linux_for_Tegra" "$fixture/Linux_for_Tegra" "$fixture/bin" "$fixture/sysfs/1-1"
cp "$REPO_DIR/b_conf/select_config.sh" "$fixture/b_conf/"
cp "$REPO_DIR/b_conf/flash_jetson.sh" "$fixture/b_conf/"
printf 'demo config\n' > "$fixture/b_conf/common/demo/Linux_for_Tegra/demo.conf"
printf 'payload\n' > "$fixture/b_conf/common/demo/Linux_for_Tegra/profile.dat"
cat > "$fixture/Linux_for_Tegra/flash.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/Linux_for_Tegra/flash.sh"
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$JETSON_TEST_LOG"
printf '\n' >> "$JETSON_TEST_LOG"
if [[ "${1:-}" == install ]]; then
    shift
    exec /usr/bin/install "$@"
fi
exit 0
EOF
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
export JETSON_TEST_LOG="$fixture/sudo.log"
export JETSON_USB_SYSFS_ROOT="$fixture/sysfs"
printf '0955\n' > "$fixture/sysfs/1-1/idVendor"
printf '7023\n' > "$fixture/sysfs/1-1/idProduct"

out="$(bash "$fixture/b_conf/flash_jetson.sh" --list --jetpack-version 6.2.3)"
assert_contains "$out" 'demo'

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes
assert_contains "$(cat "$JETSON_TEST_LOG")" './flash.sh demo mmcblk0p1'
[[ -f "$fixture/Linux_for_Tegra/profile.dat" ]] || fail "selected payload was not installed"

mkdir -p "$fixture/alternate-bsp"
cp "$fixture/Linux_for_Tegra/flash.sh" "$fixture/alternate-bsp/flash.sh"
: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes --l4t-dir "$fixture/alternate-bsp"
[[ -f "$fixture/alternate-bsp/profile.dat" ]] || fail "--l4t-dir deployment target was ignored"

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode rootfs --rootdev mmcblk1p1 --jetpack-version 6.2.3 --yes
assert_contains "$(cat "$JETSON_TEST_LOG")" './flash.sh -k APP demo mmcblk1p1'

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode dtb --jetpack-version 6.2.3 --yes
log="$(cat "$JETSON_TEST_LOG")"
assert_contains "$log" './flash.sh -k A_kernel-dtb demo mmcblk0p1'
assert_contains "$log" './flash.sh -k B_kernel-dtb demo mmcblk0p1'

: > "$JETSON_TEST_LOG"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode dtb --jetpack-version 6.2.3 --dry-run)"
assert_contains "$out" 'A_kernel-dtb'
assert_contains "$out" 'B_kernel-dtb'
[[ ! -s "$JETSON_TEST_LOG" ]] || fail "dry-run invoked sudo"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/alternate-bsp")"
assert_contains "$out" "$fixture/alternate-bsp"
mkdir -p "$fixture/deploy-env/Linux_for_Tegra"
cp "$fixture/alternate-bsp/flash.sh" "$fixture/deploy-env/Linux_for_Tegra/flash.sh"
out="$(JETSON_DEPLOY_DIR="$fixture/deploy-env" bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run)"
assert_contains "$out" "$fixture/deploy-env/Linux_for_Tegra"

if bash "$fixture/b_conf/flash_jetson.sh" --board missing --mode full --jetpack-version 6.2.3 --yes >/dev/null 2>&1; then
    fail "unknown profile unexpectedly accepted"
fi
if bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 >/dev/null 2>&1; then
    fail "non-interactive flash ran without --yes"
fi

mkdir -p "$fixture/sysfs-empty"
mkdir -p "$fixture/sysfs-empty/1-1"
printf '0955\n' > "$fixture/sysfs-empty/1-1/idVendor"
printf '7020\n' > "$fixture/sysfs-empty/1-1/idProduct"
: > "$JETSON_TEST_LOG"
if JETSON_USB_SYSFS_ROOT="$fixture/sysfs-empty" bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes > "$fixture/no-recovery.out" 2>&1; then
    fail "batch flash unexpectedly continued without a recovery device"
fi
assert_contains "$(cat "$fixture/no-recovery.out")" 'Recovery device not detected'
[[ ! -s "$JETSON_TEST_LOG" ]] || fail "batch flash touched BSP/device despite missing recovery device"

: > "$JETSON_TEST_LOG"
if ! printf 'r\nq\n' | script -qefc "env JETSON_USB_SYSFS_ROOT='$fixture/sysfs-empty' bash '$fixture/b_conf/flash_jetson.sh' --board demo --mode full --jetpack-version 6.2.3" /dev/null > "$fixture/interactive-recovery.out" 2>&1; then
    # Choosing quit is a clean cancellation, but script(1) returns the command's
    # non-zero cancellation status. Validate its UI and side effects below.
    :
fi
interactive_out="$(cat "$fixture/interactive-recovery.out")"
assert_contains "$interactive_out" 'Recovery device not detected'
assert_contains "$interactive_out" '[r]etry'
assert_contains "$interactive_out" '[q]uit'
assert_contains "$interactive_out" 'still not detected'
[[ ! -s "$JETSON_TEST_LOG" ]] || fail "interactive quit touched BSP/device despite missing recovery device"

printf 'PASS: profile listing, recovery retry/quit and batch validation, guarded full/rootfs/DTB writes\n'
