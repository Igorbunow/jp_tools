#!/usr/bin/env bash
# Build, install, or restore an opt-in OP-TEE TOS image with two test-key
# warnings moved to OP-TEE's debug-only log level.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERSION_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BSP="${VERSION_ROOT}/Linux_for_Tegra"
PATCH_FILE="${SCRIPT_DIR}/patches/quiet-test-uefi-auth-warnings.patch"
TOS="${BSP}/bootloader/tos-optee_t234.img"
BACKUP="${TOS}.before-quiet-uefi-warnings"
MODE=""
ASSUME_YES=0

usage() {
	cat <<'EOF'
Usage:
  b_conf/suppress_uefi_auth_warnings.sh --build [--yes]
  sudo b_conf/suppress_uefi_auth_warnings.sh --install [--yes]
  sudo b_conf/suppress_uefi_auth_warnings.sh --restore [--yes]

--build    Build and validate a patched TOS image under /tmp; install nothing.
--install  Build, validate, back up, then install the patched TOS image.
--restore  Restore the original TOS image from its backup.
--yes      Skip the confirmation prompt for install/restore.

Environment variables:
  CROSS_COMPILE_AARCH64_PATH  NVIDIA AArch64 Buildroot toolchain directory (required).
  TMPDIR                      Temporary workspace parent (default: /tmp).
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
confirm() {
	(( ASSUME_YES )) && return 0
	[[ -t 0 ]] || die 'confirmation needed; rerun interactively or pass --yes'
	local answer
	read -r -p "$1 [y/N] " answer
	[[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || die 'cancelled'
}

for arg in "$@"; do
	case "$arg" in
		--build|--install|--restore)
			[[ -z "$MODE" ]] || die 'choose one mode'
			MODE="${arg#--}"
			;;
		--yes) ASSUME_YES=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $arg" ;;
	esac
done
[[ -n "$MODE" ]] || { usage >&2; exit 2; }
[[ -f "$PATCH_FILE" ]] || die "missing patch: $PATCH_FILE"

if [[ "$MODE" == restore ]]; then
	[[ -f "$BACKUP" ]] || die "backup not found: $BACKUP"
	confirm "Restore $TOS from $BACKUP?"
	install -m 0644 "$BACKUP" "$TOS"
	printf 'Restored original TOS image.\n'
	exit 0
fi

[[ -f "$TOS" ]] || die "T234 TOS image not found: $TOS"
command -v tar >/dev/null || die 'tar is required'
command -v patch >/dev/null || die 'patch is required'
command -v dtc >/dev/null || die 'dtc is required'
command -v python3 >/dev/null || die 'python3 is required by NVIDIA TOS image generator'
command -v strings >/dev/null || die 'strings is required to validate the rebuilt image'
command -v rg >/dev/null || die 'ripgrep is required to detect the matching NVIDIA build options'

mapfile -t archives < <(find "$BSP" -path "$BSP/rootfs" -prune -o -type f -name nvidia-jetson-optee-source.tbz2 -print)
[[ ${#archives[@]} -eq 1 ]] || die "expected one OP-TEE source archive under $BSP; found ${#archives[@]}"
ARCHIVE="${archives[0]}"
GEN="${BSP}/nv_tegra/tos-scripts/gen_tos_part_img.py"
STMM="${BSP}/bootloader/standalonemm_optee_t234.bin"
[[ -x "$GEN" && -f "$STMM" ]] || die 'NVIDIA TOS generator or T234 STMM image is missing'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quiet-uefi-warnings.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK"
[[ -f "$WORK/optee_src_build.sh" && -f "$WORK/optee/optee_os/core/pta/tegra/jetson_user_key_pta.c" ]] || die 'unrecognized NVIDIA OP-TEE source archive layout'
patch --directory="$WORK" --strip=1 --dry-run < "$PATCH_FILE" >/dev/null || die 'patch does not match this OP-TEE source version'
patch --directory="$WORK" --strip=1 < "$PATCH_FILE" >/dev/null

SRC="${WORK}/optee/optee_os/core/pta/tegra/jetson_user_key_pta.c"
[[ $(grep -Fc 'DMSG("WARNING: Test UEFI variable auth "' "$SRC") -eq 1 ]] || die 'test-key warning patch check failed'
[[ $(grep -Fc 'DMSG("WARNING: UEFI variable protection "' "$SRC") -eq 1 ]] || die 'protection warning patch check failed'
[[ $(grep -Fc 'EMSG("UEFI variable auth key not set !")' "$SRC") -eq 1 ]] || die 'security error log unexpectedly changed'

TOOLCHAIN="${CROSS_COMPILE_AARCH64_PATH:-}"
[[ -n "$TOOLCHAIN" && -x "$TOOLCHAIN/bin/aarch64-buildroot-linux-gnu-gcc" ]] || die 'set CROSS_COMPILE_AARCH64_PATH to the NVIDIA AArch64 Buildroot toolchain before building'
export CROSS_COMPILE_AARCH64_PATH="$TOOLCHAIN"
export UEFI_STMM_PATH="$STMM"
if rg -q 'optee_src_build\.sh.*-t|EXTRA_BUILD_OPTS=.*-t' "${BSP}/source" --glob 'nv_public_src_build_tos.sh'; then
	FTPM=(-t)
else
	FTPM=()
fi
(
	cd "$WORK"
	./optee_src_build.sh -p t234 "${FTPM[@]}"
)
dtc -I dts -O dtb -o "$WORK/optee/tegra234-optee.dtb" "$WORK/optee/tegra234-optee.dts"

# Reuse the exact BL31/ATF monitor and TOS DTB from the installed image.
read -r MONITOR_OFFSET MONITOR_SIZE TOS_OFFSET TOS_SIZE _ < <(od -An -tu4 -j16 -N20 --endian=little "$TOS")
read -r TOS_TYPE DTB_OFFSET DTB_SIZE < <(od -An -tu4 -j52 -N12 --endian=little "$TOS")
[[ "$MONITOR_OFFSET" == 0 && "$TOS_TYPE" == 4 && "$MONITOR_SIZE" -gt 0 && "$DTB_OFFSET" -gt 0 && "$DTB_SIZE" -gt 0 ]] || die 'installed TOS image has an unsupported TOC layout'
dd if="$TOS" of="$WORK/bl31.bin" bs=1 skip=$((512 + MONITOR_OFFSET)) count="$MONITOR_SIZE" status=none
dd if="$TOS" of="$WORK/original-optee.dtb" bs=1 skip=$((512 + DTB_OFFSET)) count="$DTB_SIZE" status=none
[[ -s "$WORK/bl31.bin" && -s "$WORK/original-optee.dtb" ]] || die 'failed to extract monitor or DTB from existing TOS image'

OUTPUT="${WORK}/tos-optee_t234.img"
python3 "$GEN" --monitor "$WORK/bl31.bin" --os "$WORK/optee/build/t234/core/tee-raw.bin" --dtb "$WORK/optee/tegra234-optee.dtb" --tostype optee "$OUTPUT" >/dev/null
strings "$OUTPUT" > "$WORK/output.strings"
if grep -Fq 'WARNING: Test UEFI variable auth key is being used !' "$WORK/output.strings"; then
	die 'rebuilt TOS still contains the test-key warning string'
fi
if grep -Fq 'WARNING: UEFI variable protection is not fully enabled !' "$WORK/output.strings"; then
	die 'rebuilt TOS still contains the protection warning string'
fi
grep -Fq 'UEFI variable auth key not set !' "$WORK/output.strings" || die 'rebuilt TOS lost the security error message'

if [[ "$MODE" == build ]]; then
	SAVED="${VERSION_ROOT}/tos-optee_t234.quiet-test-key-warnings.img"
	install -m 0644 "$OUTPUT" "$SAVED"
	printf 'Built and validated: %s\n' "$SAVED"
	exit 0
fi

(( EUID == 0 )) || die '--install must run with sudo'
[[ ! -e "$BACKUP" ]] || die "backup already exists: $BACKUP (restore or move it first)"
confirm "Install patched TOS image to $TOS? A backup will be saved at $BACKUP."
install -m 0644 "$TOS" "$BACKUP"
install -m 0644 "$OUTPUT" "${TOS}.new"
mv -f -- "${TOS}.new" "$TOS"
printf 'Installed patched TOS. Flash/reflash the device for the change to take effect.\n'
