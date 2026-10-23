#!/usr/bin/env bash

# Clean the mountpoint used by NVIDIA flash.sh while building system.img.
l4t_cleanup_bootloader_mount() {
    local bootloader_dir="$1"
    local mount_path="$bootloader_dir/mnt"
    local source loop_count=0

    command -v sudo >/dev/null 2>&1 || {
        printf 'Error: sudo is required to inspect or clean %s.\n' "$mount_path" >&2
        return 1
    }
    command -v mountpoint >/dev/null 2>&1 || {
        printf 'Error: mountpoint is required to inspect %s.\n' "$mount_path" >&2
        return 1
    }
    command -v findmnt >/dev/null 2>&1 || {
        printf 'Error: findmnt is required to identify the source of %s.\n' "$mount_path" >&2
        return 1
    }

    while sudo mountpoint -q "$mount_path"; do
        loop_count=$((loop_count + 1))
        if ((loop_count > 16)); then
            printf 'Error: too many stacked mounts at %s; refusing further cleanup.\n' "$mount_path" >&2
            return 1
        fi

        source="$(sudo findmnt --noheadings --raw --output SOURCE --target "$mount_path")" || {
            printf 'Error: cannot identify the mounted source at %s.\n' "$mount_path" >&2
            return 1
        }
        printf 'Warning: cleaning up leftover BSP mount at %s (source %s).\n' \
            "$mount_path" "${source:-unknown}" >&2
        sudo umount -- "$mount_path" || {
            printf 'Error: failed to unmount %s.\n' "$mount_path" >&2
            return 1
        }

        if [[ "$source" =~ ^/dev/loop[0-9]+$ ]]; then
            # Some BSP versions configure autoclear and release the loop as
            # soon as the mount is removed. Detach only if it is still active.
            if sudo losetup "$source" >/dev/null 2>&1; then
                sudo losetup --detach "$source" || {
                    printf 'Error: failed to detach loop device %s after unmounting %s.\n' \
                        "$source" "$mount_path" >&2
                    return 1
                }
            fi
        fi
    done
}
