#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/rootfs_release_fixes.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

rootfs="$fixture/rootfs"
mkdir -p "$rootfs/etc/apt/sources.list.d" "$rootfs/etc"
printf 'ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\nPRETTY_NAME="Ubuntu 22.04.5 LTS"\n' > "$rootfs/etc/os-release"
printf 'deb https://repo.download.nvidia.com/jetson/<SOC> r36.5 main\n' > "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
printf 'TEGRA_CHIPID 0x23\n' > "$rootfs/etc/nv_boot_control.conf"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/board.conf"
grep -Fq 'jetson/t234 r36.5 main' "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/board.conf"
[[ "$(grep -Fc 'jetson/t234' "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list")" == 1 ]]

# A board profile supplies the chip id before nv_boot_control.conf exists.
printf 'CHIPID=0x23\n' > "$fixture/board.conf"
printf 'deb https://repo.download.nvidia.com/jetson/<SOC> r35.6 main\n' > "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
rm -f "$rootfs/etc/nv_boot_control.conf"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/board.conf"
grep -Fq 'jetson/t234 r35.6 main' "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"

mkdir -p "$fixture/bsp"
cat > "$fixture/bsp/jetson-agx-orin-devkit-noeeprom.conf" <<'EOF'
source "${LDK_DIR}/jetson-agx-orin-devkit.conf"
EOF
cat > "$fixture/bsp/jetson-agx-orin-devkit.conf" <<'EOF'
source "${LDK_DIR}/p3701.conf.common"
EOF
printf 'CHIPID=0x23\n' > "$fixture/bsp/p3701.conf.common"
printf 'deb https://repo.download.nvidia.com/jetson/<SOC> r36.4 main\n' > "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/bsp/jetson-agx-orin-devkit-noeeprom.conf"
grep -Fq 'jetson/t234 r36.4 main' "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"

# Releases whose installed sources already lack the placeholder remain untouched.
printf 'deb https://repo.download.nvidia.com/jetson/common r36.5 main\n' > "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/absent-board.conf"
grep -Fxq 'deb https://repo.download.nvidia.com/jetson/common r36.5 main' \
    "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
printf '#deb https://repo.download.nvidia.com/jetson/<SOC> r36.5 main\n' > "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
rootfs_fix_normalize_nvidia_soc "$rootfs" "$fixture/absent-board.conf"
grep -Fxq '#deb https://repo.download.nvidia.com/jetson/<SOC> r36.5 main' \
    "$rootfs/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"

fixes="$fixture/fixes"
mkdir -p "$fixes/common/ubuntu/jammy/files/etc" "$fixes/6.2.x/ubuntu/jammy/files/etc" \
    "$fixes/6.2.3/ubuntu/jammy/files/etc" "$rootfs/etc"
printf 'common\n' > "$fixes/common/ubuntu/jammy/files/etc/example.conf"
printf 'minor\n' > "$fixes/6.2.x/ubuntu/jammy/files/etc/example.conf"
printf 'exact\n' > "$fixes/6.2.3/ubuntu/jammy/files/etc/example.conf"
rootfs_fix_apply_layers "$rootfs" "$fixes" 6.2.3 ubuntu jammy
[[ "$(cat "$rootfs/etc/example.conf")" == exact ]]
rootfs_fix_apply_layers "$rootfs" "$fixes" 6.2.2 ubuntu jammy
[[ "$(cat "$rootfs/etc/example.conf")" == minor ]]

mkdir -p "$fixes/common/ubuntu/jammy/patches"
printf 'before\n' > "$rootfs/etc/patched.conf"
cat > "$fixes/common/ubuntu/jammy/patches/001-example.patch" <<'EOF'
--- a/etc/patched.conf
+++ b/etc/patched.conf
@@ -1 +1 @@
-before
+after
EOF
rootfs_fix_apply_layers "$rootfs" "$fixes" 6.2.3 ubuntu jammy
[[ "$(cat "$rootfs/etc/patched.conf")" == after ]]
rootfs_fix_apply_layers "$rootfs" "$fixes" 6.2.3 ubuntu jammy
[[ "$(cat "$rootfs/etc/patched.conf")" == after ]]

mkdir -p "$fixes/6.2/ubuntu/jammy/files/etc"
printf 'minor-only\n' > "$fixes/6.2/ubuntu/jammy/files/etc/unpatched.conf"
rootfs_fix_apply_layers "$rootfs" "$fixes" 6.2 ubuntu jammy
[[ "$(cat "$rootfs/etc/unpatched.conf")" == minor-only ]]

rootfs_fix_write_identity "$rootfs" 6.2.3 R36.5.2 jetson-agx-orin-devkit-noeeprom
grep -Fxq 'JetPack: 6.2.3' "$rootfs/etc/jetson-image-info"
grep -Fxq 'L4T: R36.5.2' "$rootfs/etc/jetson-image-info"
grep -Fxq 'Distribution: Ubuntu 22.04.5 LTS (jammy; version 22.04)' "$rootfs/etc/jetson-image-info"
grep -Fxq 'Board profile: jetson-agx-orin-devkit-noeeprom' "$rootfs/etc/jetson-image-info"
printf 'PASS: rootfs release fixes, NVIDIA SoC normalization, and image identity\n'
