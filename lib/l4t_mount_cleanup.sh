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

# Unmount all mountpoints below one Linux_for_Tegra deployment, deepest-first.
# The deployment directory itself is intentionally excluded because it may be
# a user-managed filesystem containing the BSP rather than a BSP work mount.
l4t_cleanup_deployment_mounts() {
    local deployment_dir="${1%/}"
    local targets encoded_target mount_path source longest_path
    local cleanup_count=0 longest_length

    [[ "$deployment_dir" == /* && "$deployment_dir" != "/" ]] || {
        printf 'Error: deployment path must be absolute and cannot be /.\n' >&2
        return 1
    }

    command -v sudo >/dev/null 2>&1 || {
        printf 'Error: sudo is required to inspect or clean mounts under %s.\n' "$deployment_dir" >&2
        return 1
    }
    command -v findmnt >/dev/null 2>&1 || {
        printf 'Error: findmnt is required to inspect mounts under %s.\n' "$deployment_dir" >&2
        return 1
    }
    command -v mountpoint >/dev/null 2>&1 || {
        printf 'Error: mountpoint is required to inspect mounts under %s.\n' "$deployment_dir" >&2
        return 1
    }

    while ((cleanup_count < 256)); do
        targets="$(sudo findmnt --raw --noheadings --output TARGET)" || {
            printf 'Error: cannot inspect active mounts.\n' >&2
            return 1
        }

        longest_path=""
        longest_length=0
        while IFS= read -r encoded_target; do
            [[ -n "$encoded_target" ]] || continue
            # findmnt raw output hex-escapes unsafe characters such as spaces.
            printf -v mount_path '%b' "$encoded_target"
            case "$mount_path" in
                "$deployment_dir"/*) ;;
                *) continue ;;
            esac
            if ((${#mount_path} > longest_length)); then
                longest_path="$mount_path"
                longest_length=${#mount_path}
            fi
        done <<< "$targets"

        [[ -n "$longest_path" ]] || return 0
        if ! sudo mountpoint -q "$longest_path"; then
            # The mount disappeared between inspection and selection.
            cleanup_count=$((cleanup_count + 1))
            continue
        fi

        source="$(sudo findmnt --noheadings --raw --output SOURCE --target "$longest_path")" || {
            printf 'Error: cannot identify the mounted source at %s.\n' "$longest_path" >&2
            return 1
        }
        printf 'Warning: cleaning up leftover L4T mount at %s (source %s).\n' \
            "$longest_path" "${source:-unknown}" >&2
        if ! sudo umount -- "$longest_path"; then
            printf 'Warning: normal unmount failed; lazily detaching %s.\n' "$longest_path" >&2
            sudo umount --lazy -- "$longest_path" || {
                printf 'Error: failed to unmount %s, including lazy detach.\n' "$longest_path" >&2
                return 1
            }
        fi
        cleanup_count=$((cleanup_count + 1))

        if [[ "$source" =~ ^/dev/loop[0-9]+$ ]] && sudo losetup "$source" >/dev/null 2>&1; then
            sudo losetup --detach "$source" || {
                printf 'Error: failed to detach loop device %s after unmounting %s.\n' \
                    "$source" "$longest_path" >&2
                return 1
            }
        fi
    done

    printf 'Error: mount cleanup exceeded 256 operations under %s.\n' "$deployment_dir" >&2
    return 1
}
