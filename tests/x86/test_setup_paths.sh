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

fixture="$(mktemp -d /tmp/jetson-paths.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
if out="$(bash "$REPO_DIR/setup_debian.sh" --board demo --l4t-dir "$fixture/deployed/Linux_for_Tegra" 2>&1)"; then
    fail 'setup_debian unexpectedly accepted an empty L4T directory'
fi
assert_contains "$out" "$fixture/deployed/Linux_for_Tegra/tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh"

printf 'PASS: setup path defaults, environment/CLI overrides, and setup_debian L4T path\n'
