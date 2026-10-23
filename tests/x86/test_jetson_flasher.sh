#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

fixture="$(mktemp -d /tmp/jetson-flasher.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/b_conf/common/demo/Linux_for_Tegra" "$fixture/Linux_for_Tegra" "$fixture/bin"
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

out="$(bash "$fixture/b_conf/flash_jetson.sh" --list --jetpack-version 6.2.3)"
assert_contains "$out" 'demo'

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes
assert_contains "$(cat "$JETSON_TEST_LOG")" './flash.sh demo mmcblk0p1'
[[ -f "$fixture/Linux_for_Tegra/profile.dat" ]] || fail "selected payload was not installed"

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

if bash "$fixture/b_conf/flash_jetson.sh" --board missing --mode full --jetpack-version 6.2.3 --yes >/dev/null 2>&1; then
    fail "unknown profile unexpectedly accepted"
fi
if bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 >/dev/null 2>&1; then
    fail "non-interactive flash ran without --yes"
fi

printf 'PASS: profile listing, guarded full/rootfs/DTB writes, dry-run and batch validation\n'
