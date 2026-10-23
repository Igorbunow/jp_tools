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
