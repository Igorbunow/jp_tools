#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/b_conf/select_config.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

fixture="$(mktemp -d /tmp/b-conf-selector.XXXXXX)"
mkdir -p "$fixture/common/demo" "$fixture/6.x/demo" \
    "$fixture/6.2.x/demo" "$fixture/6.2.2/demo" "$fixture/7.2.x/demo"
for bundle in "$fixture"/common/demo "$fixture"/6.x/demo \
    "$fixture"/6.2.x/demo "$fixture"/6.2.2/demo "$fixture"/7.2.x/demo; do
    mkdir -p "$bundle/Linux_for_Tegra"
done

# New module-aware layout takes precedence and filters profiles by module.
mkdir -p "$fixture/modules/xavier-agx/4.6.6/jetson-xavier/Linux_for_Tegra" \
    "$fixture/modules/xavier-nx/4.6.6/jetson-xavier-nx-devkit/Linux_for_Tegra"
printf 'xavier-agx\n' > "$fixture/modules/xavier-agx/4.6.6/jetson-xavier/MODULE"
printf 'xavier-nx\n' > "$fixture/modules/xavier-nx/4.6.6/jetson-xavier-nx-devkit/MODULE"
assert_eq "$(b_conf_select_package "$fixture" jetson-xavier 4.6.6 xavier-agx)" \
    "$fixture/modules/xavier-agx/4.6.6/jetson-xavier"
assert_eq "$(b_conf_select_package "$fixture" jetson-xavier 4.6.6)" \
    "$fixture/modules/xavier-agx/4.6.6/jetson-xavier"
assert_eq "$(b_conf_profile_module "$fixture/modules/xavier-agx/4.6.6/jetson-xavier")" "xavier-agx"
if b_conf_select_package "$fixture" jetson-xavier 4.6.6 xavier-nx >/dev/null 2>&1; then
    fail "profile from a different module unexpectedly resolved"
fi

for spec in 'xavier-agx jetson-xavier' 'xavier-nx jetson-xavier-nx-devkit' \
    'nano-2gb jetson-nano-2gb-devkit' 'tx1 jetson-tx1-devkit'; do
    read -r module board <<< "$spec"
    profile="$REPO_DIR/b_conf/modules/$module/4.6.6/$board"
    [[ "$(cat "$profile/MODULE")" == "$module" ]] || fail "wrong module metadata for $board"
    [[ -f "$profile/COMPATIBILITY.md" ]] || fail "compatibility journal missing for $board"
    [[ "$(b_conf_select_package "$REPO_DIR/b_conf" "$board" 4.6.6 "$module")" == "$profile" ]] || \
        fail "JetPack 4.6.6 profile did not resolve: $board"
done

orin_common="$REPO_DIR/b_conf/modules/orin-agx/common/jetson-agx-orin-devkit-noeeprom"
assert_eq "$(b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-devkit-noeeprom 5.1.7)" "$orin_common"
assert_eq "$(cat "$orin_common/MODULE")" "orin-agx"
[[ -f "$orin_common/COMPATIBILITY.md" ]] || fail "Orin AGX common profile journal missing"
if b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-devkit-noeeprom 4.6.6 >/dev/null 2>&1; then
    fail "Orin AGX profile was incorrectly selected for JetPack 4.6.6"
fi

assert_eq "$(b_conf_select_package "$fixture" demo 6.2.2)" "$fixture/6.2.2/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.2)" "$fixture/6.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.2.9)" "$fixture/6.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.8.1)" "$fixture/6.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 7.2.4)" "$fixture/7.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 7.3.0)" "$fixture/common/demo"

# Real 6.2.x board bundles must resolve independently and remain self-contained.
bundle_root="$REPO_DIR/b_conf/modules/orin-agx/6.2.x"
bundle_10g="$(b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-10g_4eth_pci_nvme_dp 6.2.3)"
bundle_gmii="$(b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-gmii_2eth_audio_dp 6.2.3)"
assert_eq "$bundle_10g" "$bundle_root/jetson-agx-orin-10g_4eth_pci_nvme_dp"
assert_eq "$bundle_gmii" "$bundle_root/jetson-agx-orin-gmii_2eth_audio_dp"
assert_eq "$(b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-10g_4eth_pci_nvme_dp 6.2)" "$bundle_10g"
assert_eq "$(b_conf_select_package "$REPO_DIR/b_conf" jetson-agx-orin-gmii_2eth_audio_dp 6.2.2)" "$bundle_gmii"
[[ -f "$bundle_10g/Linux_for_Tegra/jetson-agx-orin-10g_4eth_pci_nvme_dp.conf" ]] || fail "10G profile config missing"
[[ -f "$bundle_10g/Linux_for_Tegra/bootloader/generic/BCT/tegra234-mb2-bct-misc-ids-10g-no-cvb-eeprom.dts" ]] || fail "10G MB2 BCT missing"
[[ -f "$bundle_gmii/Linux_for_Tegra/jetson-agx-orin-gmii_2eth_audio_dp.conf" ]] || fail "GMII profile config missing"
[[ -f "$bundle_gmii/Linux_for_Tegra/kernel/dtb/tegra234-p3701-gmii_nvme_2eth_audio_dp_64.dtb" ]] || fail "GMII DTB missing"
if find "$bundle_gmii/Linux_for_Tegra" -name '*10g*' -print -quit | grep -q .; then
    fail "GMII package contains unrelated 10G artifacts"
fi
(
    cd "$bundle_10g/Linux_for_Tegra"
    sha256sum -c "$REPO_DIR/b_conf/modules/orin-agx/6.2.x/jetson-agx-orin-10g_4eth_pci_nvme_dp/CHECKSUMS.sha256" >/dev/null
)

# Every checked-in profile follows the same module-first directory structure.
for module_root in "$REPO_DIR"/b_conf/modules/*; do
    [[ -d "$module_root" ]] || continue
    [[ -n "$(find "$module_root" -mindepth 2 -maxdepth 2 -type d -print -quit)" ]] || \
        fail "module family has no selector/profile directory: $module_root"
done
[[ ! -d "$REPO_DIR/b_conf/common" && ! -d "$REPO_DIR/b_conf/6.2.x" ]] || \
    fail "legacy root-level board profile directories remain"

if b_conf_select_package "$fixture" missing 6.2.2 >/dev/null 2>&1; then
    fail "missing profile unexpectedly resolved"
fi
if b_conf_select_package "$fixture" ../demo 6.2.2 >/dev/null 2>&1; then
    fail "unsafe profile name unexpectedly resolved"
fi
if b_conf_select_package "$fixture" demo 6.2.2 ../xavier >/dev/null 2>&1; then
    fail "unsafe module family unexpectedly accepted"
fi
if b_conf_select_package "$fixture" demo R36.4.3 >/dev/null 2>&1; then
    fail "non-JetPack version unexpectedly accepted"
fi

mkdir -p "$fixture/modules/xavier-agx/6.2.x/shared" "$fixture/modules/xavier-nx/6.2.x/shared"
printf 'xavier-agx\n' > "$fixture/modules/xavier-agx/6.2.x/shared/MODULE"
printf 'xavier-nx\n' > "$fixture/modules/xavier-nx/6.2.x/shared/MODULE"
if b_conf_select_package "$fixture" shared 6.2.3 >/dev/null 2>&1; then
    fail "ambiguous profile unexpectedly resolved without a module"
else
    status=$?
    [[ "$status" -eq 3 ]] || fail "ambiguous profile returned status $status, expected 3"
fi

payload="$fixture/package/Linux_for_Tegra"
destination="$fixture/installed/Linux_for_Tegra"
mkdir -p "$payload" "$destination"
printf 'profile-data\n' > "$payload/profile.conf"
b_conf_install_payload "$payload" "$destination" || fail "package install failed"
assert_eq "$(cat "$destination/profile.conf")" "profile-data"

printf 'vendor-data\n' > "$destination/vendor.conf"
printf 'attempted-overwrite\n' > "$payload/vendor.conf"
if b_conf_install_payload "$payload" "$destination" >/dev/null 2>&1; then
    fail "conflicting BSP file was overwritten"
fi
assert_eq "$(cat "$destination/vendor.conf")" "vendor-data"

b_conf_install_payload "$payload" "$destination" true || fail "approved conflicting payload was not installed"
assert_eq "$(cat "$destination/vendor.conf")" "attempted-overwrite"
printf 'outside data\n' > "$fixture/outside.conf"
ln -s "$fixture/outside.conf" "$destination/linked.conf"
printf 'replacement\n' > "$payload/linked.conf"
if b_conf_install_payload "$payload" "$destination" true >/dev/null 2>&1; then
    fail "approved payload followed/replaced a BSP symlink"
fi
assert_eq "$(cat "$fixture/outside.conf")" "outside data"

printf 'PASS: exact, minor-family, major-family and common profile selection\n'
