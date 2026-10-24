#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_DIR/setup_jetson.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

eval "$(sed -n '/^preflight_board_profile() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^copy_board_configuration() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^apply_debian_patches() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^stock_board_profile_names() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^stock_profile_module_name() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^list_stock_board_profiles() {/,/^}/p' "$SETUP")"
stock_profile_selector="$(sed -n '/^select_stock_board_profile() {/,/^}/p' "$SETUP")"
[[ -n "$stock_profile_selector" ]] || fail 'stock NVIDIA profile selector is missing'
eval "$stock_profile_selector"
eval "$(sed -n '/^check_patch_target() {/,/^}/p' "$REPO_DIR/setup_debian.sh")"

print_warning() { printf 'Warning: %s\n' "$*" >&2; }
print_error() { printf 'Error: %s\n' "$*" >&2; }
print_notice() { printf '%s\n' "$*"; }
update_step() { :; }
sudo() { printf 'sudo'; printf ' %q' "$@"; printf '\n'; }

PROJECT_DIR="$REPO_DIR"
LOCAL_BOARD_CONFIG_NAME=b_conf
test_temp_root="$(mktemp -d /tmp/jetson-missing-profile.XXXXXX)"
trap 'rm -rf -- "$test_temp_root"' EXIT
TARGET_DIR="$test_temp_root/Linux_for_Tegra"
mkdir -p "$TARGET_DIR"
touch "$TARGET_DIR/jetson-nano-2gb-devkit.conf"
ln -s jetson-nano-2gb-devkit.conf "$TARGET_DIR/jetson-tx1-devkit.conf"
JETSON_BOARD=jetson-not-in-tree
JETPACK_VERSION=4.6.6
L4T_VERSION_SELECTED=R32.7.6
JETSON_MODULE=""
REQUIRE_BOARD_PROFILE=false
BOARD_PROFILE_DIR=""
BOARD_CONFIG_AVAILABLE=false
BOARD_PROFILE_AVAILABLE=false
SILENT_MODE=false
BOARD_WAS_EXPLICIT=false
NVIDIA_PROFILE_SELECTION=""

out="$(preflight_board_profile 2>&1)" || fail 'optional profile preflight stopped preparation'
assert_contains "$out" 'No compatible project b_conf profile'
[[ -z "$BOARD_PROFILE_DIR" ]] || fail 'missing profile unexpectedly resolved'
SILENT_MODE=true
if out="$(preflight_board_profile 2>&1)"; then
    fail 'batch mode accepted missing explicit NVIDIA profile selection'
fi
assert_contains "$out" 'requires --nvidia-profile or JETSON_NVIDIA_PROFILE'
NVIDIA_PROFILE_SELECTION=1
preflight_board_profile >/dev/null 2>&1 || fail 'batch mode rejected an explicit NVIDIA profile selection'
SILENT_MODE=false
NVIDIA_PROFILE_SELECTION=""
NVIDIA_PROFILE_SELECTION=1
copy_board_configuration >"$test_temp_root/copy-profile.out" 2>&1 || fail 'missing profile prevented setup continuation'
out="$(cat "$test_temp_root/copy-profile.out")"
assert_contains "$out" 'Available NVIDIA profiles:'
assert_contains "$out" 'jetson-nano-2gb-devkit (module: nano-2gb)'
assert_contains "$out" 'jetson-tx1-devkit (module: tx1)'
assert_contains "$out" 'module:'
[[ "$BOARD_CONFIG_AVAILABLE" == true ]] || fail 'selected stock NVIDIA profile was not marked available'
[[ "$JETSON_BOARD" == jetson-nano-2gb-devkit ]] || fail 'stock profile index selected the wrong profile'
out="$(apply_debian_patches 2>&1)" || fail 'generic Debian patch invocation failed'
[[ "$out" != *'--generic-only'* ]] || fail 'generic-only mode used after selecting a stock profile'

# Batch selection accepts a profile name as well as a 1-based index.
NVIDIA_PROFILE_SELECTION=jetson-tx1-devkit
select_stock_board_profile "$NVIDIA_PROFILE_SELECTION" >/dev/null || fail 'stock profile name selection failed'
[[ "$JETSON_BOARD" == jetson-tx1-devkit ]] || fail 'stock profile name selected the wrong profile'

NVIDIA_PROFILE_SELECTION=""
SILENT_MODE=false
select_stock_board_profile < <(printf '2\n') >/dev/null 2>&1 || fail 'interactive stock profile selection failed'
[[ "$JETSON_BOARD" == jetson-tx1-devkit ]] || fail 'interactive stock profile selection chose the wrong profile'

NVIDIA_PROFILE_SELECTION=99
if select_stock_board_profile "$NVIDIA_PROFILE_SELECTION" >/dev/null 2>&1; then
    fail 'out-of-range stock profile index was accepted'
fi

PATCH_FILE="$TARGET_DIR/tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh"
BOARD_CONF="$TARGET_DIR/jetson-tx1-devkit.conf"
check_output="$test_temp_root/check_patch_target.out"
GENERIC_ONLY=true
PATCH_TARGET_AVAILABLE=true
check_patch_target >"$check_output" 2>&1 || fail 'missing OTA script blocked generic-only setup'
out="$(cat "$check_output")"
assert_contains "$out" 'skipping OTA-specific compatibility patches'
[[ "$PATCH_TARGET_AVAILABLE" == false ]] || fail 'missing OTA script was not marked as skipped'
GENERIC_ONLY=false
BOARD=jetson-tx1-devkit
touch "$BOARD_CONF"
check_patch_target >"$check_output" 2>&1 || fail 'missing OTA script blocked stock NVIDIA profile setup'
out="$(cat "$check_output")"
assert_contains "$out" 'skipping OTA-specific compatibility patches'
[[ "$PATCH_TARGET_AVAILABLE" == false ]] || fail 'missing OTA script was not skipped for stock profile setup'
BOARD=jetson-agx-orin-10g_4eth_pci_nvme_dp
if check_patch_target >"$check_output" 2>&1; then
    fail 'missing OTA script unexpectedly passed custom IDS profile preflight'
fi
out="$(cat "$check_output")"
assert_contains "$out" 'L4T recovery script not found'

REQUIRE_BOARD_PROFILE=true
JETSON_BOARD=jetson-not-in-tree
if out="$(preflight_board_profile 2>&1)"; then
    fail 'required missing profile unexpectedly passed preflight'
fi
assert_contains "$out" 'A compatible b_conf profile is required'

REQUIRE_BOARD_PROFILE=false
JETSON_BOARD=jetson-xavier
JETSON_MODULE=xavier-agx
JETPACK_VERSION=4.6.6
preflight_board_profile >/dev/null 2>&1 || fail 'existing profile failed preflight'
[[ "$BOARD_PROFILE_DIR" == "$REPO_DIR/b_conf/modules/xavier-agx/4.6.6/jetson-xavier" ]] || \
    fail 'existing profile resolved to an unexpected path'

JETSON_BOARD=jetson-stock-board
JETSON_MODULE=""
BOARD_PROFILE_DIR=""
NVIDIA_PROFILE_SELECTION=jetson-stock-board
touch "$TARGET_DIR/jetson-stock-board.conf"
preflight_board_profile >/dev/null 2>&1 || fail 'optional stock BSP configuration failed preflight'
copy_board_configuration >/dev/null 2>&1 || fail 'stock BSP configuration blocked setup'
[[ "$BOARD_CONFIG_AVAILABLE" == true ]] || fail 'stock BSP config was not recognized'
out="$(apply_debian_patches 2>&1)" || fail 'stock profile Debian patch invocation failed'
[[ "$out" != *'--generic-only'* ]] || fail 'generic-only mode used despite an available stock board config'

strict_order="$(awk '/^select_release_pair$/ { select_line=NR } index($0, "preflight_board_profile || exit 1") { preflight_line=NR } /^check_dependencies$/ { dependencies_line=NR } END { print select_line, preflight_line, dependencies_line }' "$SETUP")"
read -r select_line preflight_line dependencies_line <<< "$strict_order"
((select_line < preflight_line && preflight_line < dependencies_line)) || \
    fail 'required board profile is not checked before dependency setup/deployment'

archive_dir="$test_temp_root/archive"
mkdir -p "$archive_dir"
deploy_dir="$archive_dir/deployment"
touch "$archive_dir/Jetson_Linux_R32.7.6_aarch64.tbz2" \
    "$archive_dir/Tegra_Linux_Sample-Root-Filesystem_R32.7.6_aarch64.tbz2"
if out="$(bash "$SETUP" --archive-dir "$archive_dir" --deploy-dir "$deploy_dir" \
    --jetpack-version 4.6.6 --version R32.7.6 --board jetson-agx-orin-devkit-noeeprom \
    --require-board-profile --yes --skip-qemu 2>&1)"; then
    fail 'strict setup unexpectedly accepted a missing profile'
fi
assert_contains "$out" 'A compatible b_conf profile is required'
[[ "$out" != *'Target directory:'* ]] || fail 'strict setup got past profile preflight'
[[ ! -e "$deploy_dir/Linux_for_Tegra" ]] || fail 'strict setup created a deployment before rejecting the profile'
printf 'PASS: missing board profiles warn and continue; required profiles fail before deployment\n'
