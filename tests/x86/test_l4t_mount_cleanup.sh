#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixture="$(mktemp -d /tmp/jetson-mount-cleanup.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bootloader/mnt"
touch "$fixture/mount-active"
cleanup_log="$fixture/cleanup.log"

sudo() {
    local command="$1"
    shift
    case "$command" in
        mountpoint)
            [[ -e "$fixture/mount-active" ]]
            ;;
        findmnt)
            printf '/dev/loop42\n'
            ;;
        umount)
            [[ "$1" == -- ]] && shift
            [[ "$1" == "$fixture/bootloader/mnt" ]] || return 9
            printf 'umount %s\n' "$1" >> "$cleanup_log"
            rm -f "$fixture/mount-active"
            ;;
        losetup)
            if [[ "$1" == /dev/loop42 ]]; then
                return 0
            fi
            [[ "$1" == --detach && "$2" == /dev/loop42 ]] || return 9
            printf 'losetup -d %s\n' "$2" >> "$cleanup_log"
            ;;
        *) return 127 ;;
    esac
}

source "$REPO_DIR/lib/l4t_mount_cleanup.sh"
out="$(l4t_cleanup_bootloader_mount "$fixture/bootloader" 2>&1)"
[[ "$out" == *'Warning: cleaning up leftover BSP mount'* ]] || fail 'cleanup warning was not shown'
[[ ! -e "$fixture/mount-active" ]] || fail 'BSP mount was not unmounted'
[[ "$(cat "$cleanup_log")" == *"umount $fixture/bootloader/mnt"* ]] || fail 'wrong mountpoint was unmounted'
[[ "$(cat "$cleanup_log")" == *'losetup -d /dev/loop42'* ]] || fail 'loop device was not detached'

out="$(l4t_cleanup_bootloader_mount "$fixture/bootloader" 2>&1)"
[[ -z "$out" ]] || fail 'cleanup reported work when no mount existed'

printf 'PASS: leaked BSP loop mount is warned about, unmounted, and detached\n'

# Cover every mount below one deployment, including nested mounts and mounts
# unrelated to that deployment which must remain untouched.
mount_root="$fixture/deployment with spaces/Linux_for_Tegra"
mount_active="$fixture/active-mounts"
mount_log="$fixture/mount-cleanup.log"
mkdir -p "$mount_root/rootfs/dev/pts" "$mount_root/bootloader/mnt"
printf '%s\n%s\n%s\n%s\n' \
    "$mount_root/rootfs" \
    "$mount_root/rootfs/dev" \
    "$mount_root/rootfs/dev/pts" \
    "$mount_root/rootfs/dev/pts/cache" \
    "$fixture/other-project/mnt" > "$mount_active"

sudo() {
    local command="$1"
    shift
    case "$command" in
        mountpoint)
            [[ "$1" == -q ]] && shift
            grep -Fxq -- "$1" "$mount_active"
            ;;
        findmnt)
            if [[ "$*" == *'--output TARGET'* ]]; then
                while IFS= read -r target; do
                    printf '%s\n' "${target// /\\x20}"
                done < "$mount_active"
            elif [[ "$*" == *'--output SOURCE'* ]]; then
                case "${!#}" in
                    "$mount_root/rootfs/dev/pts") printf 'devpts\n' ;;
                    "$mount_root/rootfs/dev") printf 'tmpfs\n' ;;
                    "$mount_root/rootfs") printf '/dev/loop43\n' ;;
                    *) printf 'tmpfs\n' ;;
                esac
            else
                return 2
            fi
            ;;
        umount)
            if [[ "$1" == --lazy ]]; then
                shift
                [[ "$1" == -- ]] && shift
                printf 'lazy %s\n' "$1" >> "$mount_log"
            else
                [[ "$1" == -- ]] && shift
                if [[ "$1" == "$mount_root/rootfs/dev/pts/cache" ]]; then
                    printf 'busy %s\n' "$1" >> "$mount_log"
                    return 32
                fi
                printf '%s\n' "$1" >> "$mount_log"
            fi
            awk -v target="$1" '$0 != target' "$mount_active" > "$mount_active.tmp"
            mv "$mount_active.tmp" "$mount_active"
            ;;
        losetup)
            if [[ "$1" == /dev/loop43 ]]; then return 0; fi
            [[ "$1" == --detach && "$2" == /dev/loop43 ]] || return 9
            printf 'detached %s\n' "$2" >> "$mount_log"
            ;;
        *) return 127 ;;
    esac
}

if ! out="$(l4t_cleanup_deployment_mounts "$mount_root" 2>&1)"; then
    printf '%s\n' "$out" >&2
    printf 'Active fake mounts:\n%s\nCleanup log:\n%s\n' "$(cat "$mount_active")" "$(cat "$mount_log" 2>/dev/null || true)" >&2
    fail 'deployment mount cleanup failed'
fi
[[ "$out" == *"Warning: cleaning up leftover L4T mount at $mount_root/rootfs/dev/pts"* ]] || fail 'nested mount warning missing'
[[ "$out" == *"Warning: normal unmount failed; lazily detaching $mount_root/rootfs/dev/pts/cache"* ]] || fail 'lazy unmount warning missing'
expected_log="$(printf '%s\n' "busy $mount_root/rootfs/dev/pts/cache" "lazy $mount_root/rootfs/dev/pts/cache" "$mount_root/rootfs/dev/pts" "$mount_root/rootfs/dev" "$mount_root/rootfs" 'detached /dev/loop43')"
[[ "$(cat "$mount_log")" == "$expected_log" ]] || fail 'mounts were not removed deepest-first or loop was not detached'
grep -Fxq "$fixture/other-project/mnt" "$mount_active" || fail 'mount outside deployment was unmounted'
if grep -Fxq "$mount_root" "$mount_log"; then fail 'deployment root mountpoint itself was unmounted'; fi

printf 'PASS: deployment cleanup warns and unmounts nested mounts deepest-first without touching other deployments\n'

if out="$(l4t_cleanup_deployment_mounts / 2>&1)"; then
    fail 'deployment cleanup accepted / as its cleanup boundary'
fi
[[ "$out" == *'deployment path must be absolute and cannot be /'* ]] || fail 'unsafe deployment boundary was not rejected clearly'
printf 'PASS: deployment cleanup rejects an unsafe root boundary\n'
