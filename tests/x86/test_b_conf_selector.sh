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

assert_eq "$(b_conf_select_package "$fixture" demo 6.2.2)" "$fixture/6.2.2/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.2)" "$fixture/6.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.2.9)" "$fixture/6.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 6.8.1)" "$fixture/6.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 7.2.4)" "$fixture/7.2.x/demo"
assert_eq "$(b_conf_select_package "$fixture" demo 7.3.0)" "$fixture/common/demo"

# Real 6.2.x board bundles must resolve independently and remain self-contained.
bundle_root="$REPO_DIR/b_conf/6.2.x"
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
    sha256sum -c "$REPO_DIR/b_conf/6.2.x/jetson-agx-orin-10g_4eth_pci_nvme_dp/CHECKSUMS.sha256" >/dev/null
)

if b_conf_select_package "$fixture" missing 6.2.2 >/dev/null 2>&1; then
    fail "missing profile unexpectedly resolved"
fi
if b_conf_select_package "$fixture" ../demo 6.2.2 >/dev/null 2>&1; then
    fail "unsafe profile name unexpectedly resolved"
fi
if b_conf_select_package "$fixture" demo R36.4.3 >/dev/null 2>&1; then
    fail "non-JetPack version unexpectedly accepted"
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

printf 'PASS: exact, minor-family, major-family and common profile selection\n'
