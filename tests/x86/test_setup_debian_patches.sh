#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

eval "$(sed -n '/^apply_patches() {/,/^}/p' "$REPO_DIR/setup_debian.sh")"

fixture="$(mktemp -d /tmp/setup-debian-patches.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
PATCH_FILE="$fixture/ota_make_recovery_img_dtb.sh"
BOARD=jetson-agx-xavier-devkit
GENERIC_ONLY=false
PY_FLASH_INTERNAL="$fixture/tegraflash_internal.py"
mkdir -p "$(dirname "$PATCH_FILE")"

cat > "$PATCH_FILE" <<'EOF'
sed -e "s|<KERNEL_VERSION>|${_BASE_KERNEL_VERSION}|g" >"${_tmp_list_file}"
sed -i 's/\/bin\/sh/\/bin\/bash/' "${_initrd_dir}/sbin/dhclient-script";check_error
#Port/Port
UsePAM yes/UsePAM no
ssh-keygen -t dsa -N "" -f "${_initrd_dir}/${ssh_config_dir}/ssh_host_dsa_key" >/dev/null 2>&1;check_error
EOF

out="$(apply_patches 2>&1)" || fail "legacy OTA script without gzip test was rejected: $out"
assert_contains "$out" 'Patch B not applicable'
grep -Fq 'if [ -f "${_initrd_dir}/sbin/dhclient-script" ]; then' "$PATCH_FILE" || fail 'Patch C was not applied'
grep -Fq 'check_warning "ssh-keygen -t dsa"' "$PATCH_FILE" || fail 'Patch D was not applied'
grep -Fq 'if [ -f "${_initrd_dir}/${sshd_config_file}" ]; then' "$PATCH_FILE" || fail 'Patch E was not applied'

cat >> "$PATCH_FILE" <<'EOF'
if gzip -t "${_kernel_fs}" ; then
    echo valid
fi
EOF
apply_patches >/dev/null 2>&1 || fail 'gzip compatibility patch failed when the release contains the gzip check'
grep -Fq 'gzip -t "${_kernel_fs}" > /dev/null 2>&1' "$PATCH_FILE" || fail 'Patch B did not suppress gzip diagnostics'

printf 'PASS: release-specific OTA patches skip absent gzip checks and patch supported checks\n'
