#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

fixture="$(mktemp -d /tmp/jetson-flasher.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/b_conf/common/demo/Linux_for_Tegra" "$fixture/Linux_for_Tegra/bootloader" \
    "$fixture/bin" "$fixture/sysfs/1-1" "$fixture/lib"
printf 'ROOTFSSIZE=55GiB\n' > "$fixture/Linux_for_Tegra/p3701.conf.common"
mkdir -p "$fixture/b_conf/common/multi-module/Linux_for_Tegra"
cat > "$fixture/b_conf/common/multi-module/Linux_for_Tegra/multi-module.conf" <<'EOF'
# Supports multiple module SKUs; this small value is for debug images only.
ROOTFSSIZE=8GiB
EOF
cp "$REPO_DIR/b_conf/select_config.sh" "$fixture/b_conf/"
cp "$REPO_DIR/b_conf/flash_jetson.sh" "$fixture/b_conf/"
cp "$REPO_DIR/lib/l4t_mount_cleanup.sh" "$fixture/lib/"
printf 'demo config\n' > "$fixture/b_conf/common/demo/Linux_for_Tegra/demo.conf"
printf 'payload\n' > "$fixture/b_conf/common/demo/Linux_for_Tegra/profile.dat"
cat > "$fixture/b_conf/common/demo/ROOTFS_SIZE" <<'EOF'
DEFAULT=8GiB
EOF
cat > "$fixture/Linux_for_Tegra/flash.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${JETSON_TEST_CREATE_STALE_MOUNT:-0}" == 1 ]]; then
    mkdir -p "$JETSON_TEST_BOOTLOADER/mnt"
    touch "$JETSON_TEST_MOUNT_MARKER"
fi
exit "${JETSON_TEST_FLASH_EXIT:-0}"
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
case "${1:-}" in
    mountpoint)
        [[ -e "$JETSON_TEST_MOUNT_MARKER" ]]
        exit
        ;;
    findmnt)
        printf '/dev/loop42\n'
        exit 0
        ;;
    umount)
        [[ "${2:-}" == -- && "${3:-}" == "$JETSON_TEST_BOOTLOADER/mnt" ]] || exit 9
        rm -f "$JETSON_TEST_MOUNT_MARKER"
        exit 0
        ;;
    losetup)
        if [[ "${2:-}" == /dev/loop42 ]]; then exit 0; fi
        [[ "${2:-}" == --detach && "${3:-}" == /dev/loop42 ]] || exit 9
        exit 0
        ;;
    env)
        shift
        exec /usr/bin/env "$@"
        ;;
esac
exit 0
EOF
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
export JETSON_TEST_LOG="$fixture/sudo.log"
export JETSON_TEST_BOOTLOADER="$fixture/Linux_for_Tegra/bootloader"
export JETSON_TEST_MOUNT_MARKER="$fixture/bsp-mount-active"
export JETSON_USB_SYSFS_ROOT="$fixture/sysfs"
printf '0955\n' > "$fixture/sysfs/1-1/idVendor"
printf '7023\n' > "$fixture/sysfs/1-1/idProduct"

out="$(bash "$fixture/b_conf/flash_jetson.sh" --help)"
assert_contains "$out" 'JETSON_ARCHIVE_DIR'
assert_contains "$out" 'JETSON_DEPLOY_DIR'
assert_contains "$out" 'JETSON_ROOTFS_SIZE'
assert_contains "$out" '--force-rootfs-size'

out="$(bash "$fixture/b_conf/flash_jetson.sh" --list --jetpack-version 6.2.3)"
assert_contains "$out" 'demo'

: > "$JETSON_TEST_LOG"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes)"
assert_contains "$out" 'Rootfs partition size: 8GiB'
assert_contains "$(cat "$JETSON_TEST_LOG")" 'IDS_ROOTFS_SIZE=8GiB ./flash.sh -S 8GiB demo mmcblk0p1'
[[ -f "$fixture/Linux_for_Tegra/profile.dat" ]] || fail "selected payload was not installed"

out="$(JETSON_TEST_CREATE_STALE_MOUNT=1 bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes 2>&1)"
assert_contains "$out" 'Warning: cleaning up leftover BSP mount'
[[ ! -e "$JETSON_TEST_MOUNT_MARKER" ]] || fail 'flash_jetson.sh left the BSP loop mount active'
if out="$(JETSON_TEST_CREATE_STALE_MOUNT=1 JETSON_TEST_FLASH_EXIT=23 \
    bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes 2>&1)"; then
    fail 'flash_jetson.sh unexpectedly succeeded after a flash command failure'
fi
assert_contains "$out" 'Warning: cleaning up leftover BSP mount'
[[ ! -e "$JETSON_TEST_MOUNT_MARKER" ]] || fail 'flash_jetson.sh left the BSP mount after flash.sh failed'

out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --rootfs-size max)"
assert_contains "$out" 'Rootfs partition size: 55GiB'
assert_contains "$out" 'IDS_ROOTFS_SIZE=55GiB ./flash.sh -S 55GiB demo mmcblk0p1'
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --rootfs-size 56320MiB)"
assert_contains "$out" 'Rootfs partition size: 56320MiB'
if bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --rootfs-size 56GiB > "$fixture/oversize.out" 2>&1; then
    fail 'rootfs size greater than the BSP maximum was accepted'
fi
assert_contains "$(cat "$fixture/oversize.out")" 'exceeds the detected BSP maximum 55GiB'
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --force-rootfs-size 56GiB)"
assert_contains "$out" 'Rootfs size limit override: 56GiB (requested maximum: 55GiB)'
assert_contains "$out" 'IDS_ROOTFS_SIZE=56GiB ./flash.sh -S 56GiB demo mmcblk0p1'
out="$(JETSON_ROOTFS_SIZE=12GiB bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run)"
assert_contains "$out" 'Rootfs partition size: 12GiB'
assert_contains "$out" 'IDS_ROOTFS_SIZE=12GiB ./flash.sh -S 12GiB demo mmcblk0p1'
out="$(JETSON_ROOTFS_SIZE=12GiB bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --rootfs-size 16GiB)"
assert_contains "$out" 'Rootfs partition size: 16GiB'
assert_contains "$out" 'IDS_ROOTFS_SIZE=16GiB ./flash.sh -S 16GiB demo mmcblk0p1'

mkdir -p "$fixture/alternate-bsp"
cp "$fixture/Linux_for_Tegra/flash.sh" "$fixture/alternate-bsp/flash.sh"
cp "$fixture/Linux_for_Tegra/p3701.conf.common" "$fixture/alternate-bsp/p3701.conf.common"
: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --yes --l4t-dir "$fixture/alternate-bsp"
[[ -f "$fixture/alternate-bsp/profile.dat" ]] || fail "--l4t-dir deployment target was ignored"

mkdir -p "$fixture/uncertain-bsp"
cp "$fixture/Linux_for_Tegra/flash.sh" "$fixture/uncertain-bsp/flash.sh"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board multi-module --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/uncertain-bsp")"
assert_contains "$out" 'Rootfs partition size: 8GiB (profile default)'
if bash "$fixture/b_conf/flash_jetson.sh" --board multi-module --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/uncertain-bsp" --rootfs-size max > "$fixture/unknown-max.out" 2>&1; then
    fail 'profile debug size was incorrectly treated as its maximum'
fi
assert_contains "$(cat "$fixture/unknown-max.out")" 'maximum rootfs size is unknown'
if bash "$fixture/b_conf/flash_jetson.sh" --board multi-module --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/uncertain-bsp" --rootfs-size 16GiB > "$fixture/unknown-max.out" 2>&1; then
    fail 'explicit size was accepted despite unknown max without force'
fi
assert_contains "$(cat "$fixture/unknown-max.out")" 'maximum rootfs size is unknown'
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/uncertain-bsp" --force-rootfs-size 16GiB)"
assert_contains "$out" 'Rootfs size limit override: 16GiB (maximum unknown)'
if bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/uncertain-bsp" --force-rootfs-size >/dev/null 2>&1; then
    fail '--force-rootfs-size was accepted without a size'
fi

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode rootfs --rootdev mmcblk1p1 --jetpack-version 6.2.3 --yes
assert_contains "$(cat "$JETSON_TEST_LOG")" 'IDS_ROOTFS_SIZE=8GiB ./flash.sh -S 8GiB -k APP demo mmcblk1p1'

: > "$JETSON_TEST_LOG"
bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode dtb --jetpack-version 6.2.3 --yes
log="$(cat "$JETSON_TEST_LOG")"
assert_contains "$log" './flash.sh -k A_kernel-dtb demo mmcblk0p1'
assert_contains "$log" './flash.sh -k B_kernel-dtb demo mmcblk0p1'
if [[ "$log" == *' -S '* ]]; then fail 'DTB-only mode unexpectedly passed a rootfs size'; fi

: > "$JETSON_TEST_LOG"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode dtb --jetpack-version 6.2.3 --dry-run)"
assert_contains "$out" 'A_kernel-dtb'
assert_contains "$out" 'B_kernel-dtb'
[[ ! -s "$JETSON_TEST_LOG" ]] || fail "dry-run invoked sudo"
out="$(bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run --l4t-dir "$fixture/alternate-bsp")"
assert_contains "$out" "$fixture/alternate-bsp"
mkdir -p "$fixture/deploy-env/Linux_for_Tegra"
cp "$fixture/alternate-bsp/flash.sh" "$fixture/deploy-env/Linux_for_Tegra/flash.sh"
cp "$fixture/Linux_for_Tegra/p3701.conf.common" "$fixture/deploy-env/Linux_for_Tegra/p3701.conf.common"
out="$(JETSON_DEPLOY_DIR="$fixture/deploy-env" bash "$fixture/b_conf/flash_jetson.sh" --board demo --mode full --jetpack-version 6.2.3 --dry-run)"
assert_contains "$out" "$fixture/deploy-env/Linux_for_Tegra"

# A deployment directory can be named arbitrarily. When no version override is
# provided, common profiles must still be discoverable without treating the
# repository directory name as a JetPack version.
out="$(JETSON_DEPLOY_DIR="$fixture/deploy-env" bash "$fixture/b_conf/flash_jetson.sh" --list)"
assert_contains "$out" 'common/demo'

mkdir -p "$fixture/b_conf/6.2.3/versioned/Linux_for_Tegra" "$fixture/versioned-deploy/6.2.3/Linux_for_Tegra"
printf 'versioned config\n' > "$fixture/b_conf/6.2.3/versioned/Linux_for_Tegra/versioned.conf"
cp "$fixture/Linux_for_Tegra/flash.sh" "$fixture/versioned-deploy/6.2.3/Linux_for_Tegra/flash.sh"
cp "$fixture/Linux_for_Tegra/p3701.conf.common" "$fixture/versioned-deploy/6.2.3/Linux_for_Tegra/p3701.conf.common"
out="$(JETSON_DEPLOY_DIR="$fixture/versioned-deploy/6.2.3" bash "$fixture/b_conf/flash_jetson.sh" --list)"
assert_contains "$out" 'Profiles compatible with JetPack 6.2.3:'
assert_contains "$out" 'versioned'

# An arbitrary deployment path must use the JetPack metadata written into the
# deployed rootfs, so minor-family profiles are listed without an override.
mkdir -p "$fixture/b_conf/6.2.x/family-versioned/Linux_for_Tegra" \
    "$fixture/deployed-arbitrary/Linux_for_Tegra/rootfs/etc" \
    "$fixture/deployed-arbitrary/Linux_for_Tegra/nv_tegra" \
    "$fixture/archive/6.2.3"
printf 'family config\n' > "$fixture/b_conf/6.2.x/family-versioned/Linux_for_Tegra/family-versioned.conf"
cp "$fixture/Linux_for_Tegra/flash.sh" "$fixture/deployed-arbitrary/Linux_for_Tegra/flash.sh"
cp "$fixture/Linux_for_Tegra/p3701.conf.common" "$fixture/deployed-arbitrary/Linux_for_Tegra/p3701.conf.common"
cat > "$fixture/deployed-arbitrary/Linux_for_Tegra/rootfs/etc/jetson-image-info" <<'EOF'
JetPack: 6.2.3
L4T: R36.5.2
Distribution: Ubuntu 22.04 (jammy; version 22.04)
Board profile: demo
EOF
printf '# R36 (release), REVISION: 5.2, BOARD: generic\n' > "$fixture/deployed-arbitrary/Linux_for_Tegra/nv_tegra/nv_tegra_release"
out="$(JETSON_DEPLOY_DIR="$fixture/deployed-arbitrary" bash "$fixture/b_conf/flash_jetson.sh" --list)"
assert_contains "$out" 'Detected JetPack version: 6.2.3'
assert_contains "$out" 'family-versioned'

# Older deployments without image metadata can match the detected L4T release
# to a versioned archive pair.
mv "$fixture/deployed-arbitrary/Linux_for_Tegra/rootfs/etc/jetson-image-info" \
    "$fixture/deployed-arbitrary/Linux_for_Tegra/rootfs/etc/jetson-image-info.saved"
touch "$fixture/archive/6.2.3/Jetson_Linux_R36.5.2_aarch64.tbz2" \
    "$fixture/archive/6.2.3/Tegra_Linux_Sample-Root-Filesystem_R36.5.2_aarch64.tbz2"
out="$(JETSON_DEPLOY_DIR="$fixture/deployed-arbitrary" JETSON_ARCHIVE_DIR="$fixture/archive/6.2.3" \
    bash "$fixture/b_conf/flash_jetson.sh" --list)"
assert_contains "$out" 'Detected JetPack version: 6.2.3'
assert_contains "$out" 'matched deployed L4T R36.5.2 to archive pair'
assert_contains "$out" 'family-versioned'

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
if [[ "$(cat "$JETSON_TEST_LOG")" == *'./flash.sh'* || "$(cat "$JETSON_TEST_LOG")" == *'install -D'* ]]; then
    fail 'batch flash modified the BSP/device despite missing Recovery mode'
fi

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
if [[ "$(cat "$JETSON_TEST_LOG")" == *'./flash.sh'* || "$(cat "$JETSON_TEST_LOG")" == *'install -D'* ]]; then
    fail 'interactive quit modified the BSP/device despite missing Recovery mode'
fi

printf 'PASS: profile listing, recovery retry/quit and batch validation, guarded full/rootfs/DTB writes\n'
