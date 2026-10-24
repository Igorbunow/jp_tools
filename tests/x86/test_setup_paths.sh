#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
SETUP="$REPO_DIR/setup_jetson.sh"
DEFAULT_DIR=/opt/nvidia/jp/6.2.3

host_command_function="$(sed -n '/^host_command_available() {/,/^}/p' "$SETUP")"
[[ -n "$host_command_function" ]] || fail 'host command lookup helper is missing'
eval "$host_command_function"
if PATH=/usr/bin:/bin host_command_available losetup; then
    :
else
    fail 'host command lookup did not find losetup outside PATH under sbin'
fi

out="$(env -u JETSON_ARCHIVE_DIR -u JETSON_DEPLOY_DIR bash "$SETUP" --print-paths 2>&1 || true)"
assert_contains "$out" "Archive directory: $DEFAULT_DIR"
assert_contains "$out" "Deployment base directory: $DEFAULT_DIR"
assert_contains "$out" "L4T directory: $DEFAULT_DIR/Linux_for_Tegra"
assert_contains "$out" 'Debian patches: enabled'
assert_contains "$out" 'Rootfs apt update/upgrade (batch): disabled'
assert_contains "$out" 'Rootfs transient cleanup: enabled'
assert_contains "$out" "APT package list: $REPO_DIR/qemu-packages.txt"
assert_contains "$out" 'Custom APT repositories (force): disabled'

out="$(bash "$SETUP" --force-repositories --print-paths 2>&1)"
assert_contains "$out" 'Custom APT repositories (force): enabled'

out="$(JETSON_FORCE_CUSTOM_REPOSITORIES=1 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Custom APT repositories (force): enabled'

out="$(JETSON_FORCE_CUSTOM_REPOSITORIES=0 bash "$SETUP" --force-repositories --print-paths 2>&1)"
assert_contains "$out" 'Custom APT repositories (force): enabled'

if out="$(JETSON_FORCE_CUSTOM_REPOSITORIES=yes bash "$SETUP" --print-paths 2>&1)"; then
    fail 'setup_jetson accepted an invalid JETSON_FORCE_CUSTOM_REPOSITORIES value'
fi
assert_contains "$out" 'JETSON_FORCE_CUSTOM_REPOSITORIES must be 0 or 1'

out="$(bash "$SETUP" --force --print-paths 2>&1)"
assert_contains "$out" 'Custom APT repositories (force): disabled'

out="$(JETSON_NVIDIA_PROFILE=2 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'NVIDIA stock profile selection: 2'
out="$(bash "$SETUP" --nvidia-profile jetson-tx1-devkit --print-paths 2>&1)"
assert_contains "$out" 'NVIDIA stock profile selection: jetson-tx1-devkit'
out="$(bash "$SETUP" --help 2>&1)"
assert_contains "$out" '--nvidia-profile'
assert_contains "$out" 'JETSON_NVIDIA_PROFILE'


out="$(bash "$SETUP" --force-qemu-cleanup --print-paths 2>&1)"
assert_contains "$out" "Deployment base directory: $DEFAULT_DIR"

out="$(bash "$SETUP" --no-rootfs-cleanup --print-paths 2>&1)"
assert_contains "$out" 'Rootfs transient cleanup: disabled'

out="$(JETSON_SKIP_ROOTFS_CLEANUP=1 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Rootfs transient cleanup: disabled'

if out="$(JETSON_SKIP_ROOTFS_CLEANUP=yes bash "$SETUP" --print-paths 2>&1)"; then
    fail 'setup_jetson accepted an invalid JETSON_SKIP_ROOTFS_CLEANUP value'
fi
assert_contains "$out" 'JETSON_SKIP_ROOTFS_CLEANUP must be 0 or 1'

out="$(JETSON_APT_UPGRADE=1 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Rootfs apt update/upgrade (batch): enabled'

out="$(JETSON_APT_UPGRADE=0 bash "$SETUP" --apt-upgrade --print-paths 2>&1)"
assert_contains "$out" 'Rootfs apt update/upgrade (batch): enabled'

out="$(bash "$SETUP" --apt-packages-file ./custom-packages.txt --print-paths 2>&1)"
assert_contains "$out" "APT package list: $PWD/custom-packages.txt"

out="$(JETSON_SKIP_DEBIAN_PATCHES=1 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Debian patches: skipped'

out="$(env -u JETSON_SKIP_DEBIAN_PATCHES bash "$SETUP" --skip-debian-patches --print-paths 2>&1)"
assert_contains "$out" 'Debian patches: skipped'

out="$(JETSON_SKIP_DEBIAN_PATCHES=0 bash "$SETUP" --skip-debian-patches --print-paths 2>&1)"
assert_contains "$out" 'Debian patches: skipped'

out="$(env -u JETSON_DEPLOY_DIR JETSON_ARCHIVE_DIR=/tmp/jetson-archives bash "$SETUP" --print-paths 2>&1 || true)"
assert_contains "$out" 'Archive directory: /tmp/jetson-archives'
assert_contains "$out" 'Deployment base directory: /tmp/jetson-archives'

out="$(env -u JETSON_ARCHIVE_DIR JETSON_DEPLOY_DIR=/tmp/jetson-output bash "$SETUP" --print-paths 2>&1 || true)"
assert_contains "$out" 'Archive directory: /tmp/jetson-output'
assert_contains "$out" 'Deployment base directory: /tmp/jetson-output'

out="$(env JETSON_ARCHIVE_DIR=/tmp/jetson-archives JETSON_DEPLOY_DIR=/tmp/jetson-output bash "$SETUP" --print-paths 2>&1 || true)"
assert_contains "$out" 'Archive directory: /tmp/jetson-archives'
assert_contains "$out" 'Deployment base directory: /tmp/jetson-output'

out="$(env JETSON_ARCHIVE_DIR=/tmp/old-archives JETSON_DEPLOY_DIR=/tmp/old-output bash "$SETUP" \
    --archive-dir /tmp/cli-archives --deploy-dir /tmp/cli-output --print-paths 2>&1 || true)"
assert_contains "$out" 'Archive directory: /tmp/cli-archives'
assert_contains "$out" 'Deployment base directory: /tmp/cli-output'

out="$(bash "$SETUP" --archive-dir /tmp/shared-location --print-paths 2>&1 || true)"
assert_contains "$out" 'Archive directory: /tmp/shared-location'
assert_contains "$out" 'Deployment base directory: /tmp/shared-location'

out="$(JETSON_ARCHIVE_DIR=/opt/nvidia/jp/4.6.6/Xavier JETSON_DEPLOY_DIR=/tmp/999nv \
    bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'JetPack version: 4.6.6'
assert_contains "$out" 'Archive directory: /opt/nvidia/jp/4.6.6/Xavier'
assert_contains "$out" 'Deployment base directory: /tmp/999nv'
out="$(JETSON_ARCHIVE_DIR=/opt/nvidia/jp/4.6.6/Xavier JETSON_DEPLOY_DIR=/tmp/999nv JETSON_MODULE=xavier-agx \
    bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Module family: xavier-agx'
out="$(JETSON_REQUIRE_BOARD_PROFILE=1 bash "$SETUP" --print-paths 2>&1)"
assert_contains "$out" 'Board profile required: enabled'
if out="$(JETSON_REQUIRE_BOARD_PROFILE=yes bash "$SETUP" --print-paths 2>&1)"; then
    fail 'setup_jetson accepted an invalid JETSON_REQUIRE_BOARD_PROFILE value'
fi
assert_contains "$out" 'JETSON_REQUIRE_BOARD_PROFILE must be 0 or 1'

supported_modules_function="$(sed -n '/^supported_modules_for_jetpack() {/,/^}/p' "$SETUP")"
supported_pair_function="$(sed -n '/^supported_modules_for_source_pair() {/,/^}/p' "$SETUP")"
validate_pair_function="$(sed -n '/^validate_module_for_source_pair() {/,/^}/p' "$SETUP")"
[[ -n "$supported_modules_function" && -n "$supported_pair_function" && -n "$validate_pair_function" ]] || fail 'source-pair module helpers are missing'
eval "$(sed -n '/^b_conf_version_ge() {/,/^}/p' "$REPO_DIR/b_conf/select_config.sh")"
eval "$(sed -n '/^b_conf_profile_version_compatible() {/,/^}/p' "$REPO_DIR/b_conf/select_config.sh")"
eval "$(sed -n '/^b_conf_profile_module() {/,/^}/p' "$REPO_DIR/b_conf/select_config.sh")"
eval "$(sed -n '/^b_conf_select_package() {/,/^}/p' "$REPO_DIR/b_conf/select_config.sh")"
eval "$supported_modules_function"
eval "$supported_pair_function"
eval "$validate_pair_function"
print_error() { printf 'Error: %s\n' "$*" >&2; }
PROJECT_DIR="$REPO_DIR"
JETPACK_VERSION=4.6.6
assert_contains "$(supported_modules_for_jetpack 4.6.6)" 'nano-2gb, tx1, xavier-agx, xavier-nx'
assert_contains "$(supported_modules_for_source_pair 4.6.6 Jetson-210_Linux_R32.7.6_aarch64.tbz2)" 'nano, nano-2gb, tx1'
assert_contains "$(supported_modules_for_source_pair 4.6.6 Jetson_Linux_R32.7.6_aarch64.tbz2)" 'tx2, xavier-agx, xavier-nx'
if validate_module_for_source_pair xavier-nx 4.6.6 Jetson-210_Linux_R32.7.6_aarch64.tbz2 >/dev/null 2>&1; then
    fail 'Xavier NX must be rejected for the Nano2g_TX1 archive set'
fi
validate_module_for_source_pair xavier-nx 4.6.6 Jetson_Linux_R32.7.6_aarch64.tbz2 || fail 'Xavier NX must be accepted for the Xavier archive set'
assert_contains "$(supported_modules_for_jetpack 5.1.7)" 'orin-agx'
assert_contains "$(supported_modules_for_jetpack 6.2.3)" 'orin-agx'
assert_contains "$(supported_modules_for_jetpack 6.2.4)" 'orin-agx'
assert_contains "$(supported_modules_for_jetpack 7.2.1)" 'orin-agx'

release_selector="$(sed -n '/^select_release_pair() {/,/^}/p' "$SETUP")"
[[ -n "$release_selector" ]] || fail 'release pair selector is missing'
eval "$release_selector"
fixture="$(mktemp -d /tmp/jetson-release-pair.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/Xavier" "$fixture/Nano2g_TX1"
touch "$fixture/Xavier/Jetson_Linux_R32.7.6_aarch64.tbz2" \
    "$fixture/Xavier/Tegra_Linux_Sample-Root-Filesystem_R32.7.6_aarch64.tbz2" \
    "$fixture/Nano2g_TX1/Jetson-210_Linux_R32.7.6_aarch64.tbz2" \
    "$fixture/Nano2g_TX1/Tegra_Linux_Sample-Root-Filesystem_R32.7.6_aarch64.tbz2"
if selected="$(
    ARCHIVE_DIR="$fixture/Nano2g_TX1"
    L4T_VERSION=""
    JETSON_MODULE=xavier-nx
    JETSON_BOARD=jetson-agx-orin-devkit-noeeprom
    select_release_pair 2>&1
    )"; then
    fail 'setup accepted Xavier NX with the Nano2g_TX1 archive set'
fi
assert_contains "$selected" 'not included in the JetPack 4.6.6 Nano2g_TX1 archive set'
ARCHIVE_DIR="$fixture/Xavier" L4T_VERSION="" JETSON_MODULE=xavier-agx JETSON_BOARD=jetson-xavier
select_release_pair > "$fixture/xavier-selection.out"
selected="$(cat "$fixture/xavier-selection.out")"
assert_contains "$selected" 'R32.7.6'
assert_contains "$selected" 'Current JetPack version: 4.6.6'
assert_contains "$selected" 'Supported modules for JetPack 4.6.6 in selected BSP: tx2, xavier-agx, xavier-nx'
[[ "$L4T_RELEASE_FILE" == Jetson_Linux_R32.7.6_aarch64.tbz2 ]] || fail 'Xavier BSP archive was not selected'
ARCHIVE_DIR="$fixture/Nano2g_TX1" L4T_VERSION="" JETSON_MODULE=tx1 JETSON_BOARD=jetson-tx1-devkit
select_release_pair > "$fixture/nano-selection.out"
selected="$(cat "$fixture/nano-selection.out")"
assert_contains "$selected" 'R32.7.6'
assert_contains "$selected" 'Current JetPack version: 4.6.6'
assert_contains "$selected" 'Supported modules for JetPack 4.6.6 in selected BSP: nano, nano-2gb, tx1'
[[ "$L4T_RELEASE_FILE" == Jetson-210_Linux_R32.7.6_aarch64.tbz2 ]] || fail 'Jetson-210 BSP archive was not selected'

rm -rf -- "$fixture"
fixture="$(mktemp -d /tmp/jetson-paths.XXXXXX)"
if out="$(bash "$REPO_DIR/setup_debian.sh" --board demo --l4t-dir "$fixture/deployed/Linux_for_Tegra" 2>&1)"; then
    fail 'setup_debian unexpectedly accepted an empty L4T directory'
fi
assert_contains "$out" "$fixture/deployed/Linux_for_Tegra/tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh"

printf 'PASS: setup path defaults, environment/CLI overrides, and setup_debian L4T path\n'
