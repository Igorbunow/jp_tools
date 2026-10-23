#!/usr/bin/env bash

rootfs_cleanup_clear_directory() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || return 0
    sudo find "$path" -mindepth 1 -xdev -depth -delete
}

rootfs_cleanup_clear_runtime_directory() {
    local path="$1"
    local preserved_file="${2:-}"
    [[ -d "$path" && ! -L "$path" ]] || return 0
    if [[ -n "$preserved_file" ]]; then
        sudo find "$path" -mindepth 1 -xdev ! -path "$preserved_file" ! -type d -delete
    else
        sudo find "$path" -mindepth 1 -xdev ! -type d -delete
    fi
}

rootfs_cleanup_clear_apt_directory() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || return 0
    sudo find "$path" -mindepth 1 -maxdepth 1 \
        ! -name lock ! -name partial -exec rm -rf -- {} + || return 1
    rootfs_cleanup_clear_directory "$path/partial"
}

rootfs_cleanup_temporary_qemu_marker_content() {
    printf '%s\n' 'jetson-qemu-aarch64-static-temporary-v1'
}

rootfs_cleanup_remove_temporary_qemu() {
    local rootfs_path="$1"
    local binary_path="$rootfs_path/usr/bin/qemu-aarch64-static"
    local marker_path="$rootfs_path/usr/bin/.jetson-qemu-aarch64-static-temporary"
    local expected_marker

    [[ -e "$marker_path" ]] || return 0
    expected_marker="$(mktemp)" || return 1
    rootfs_cleanup_temporary_qemu_marker_content > "$expected_marker"
    if ! cmp -s -- "$expected_marker" "$marker_path"; then
        rm -f -- "$expected_marker"
        printf 'Refusing to remove QEMU binary with an unexpected ownership marker: %s\n' "$marker_path" >&2
        return 1
    fi
    rm -f -- "$expected_marker"
    sudo rm -f -- "$binary_path" "$marker_path"
}

rootfs_cleanup_install_temporary_qemu() {
    local rootfs_path="$1"
    local source_path="$2"
    local binary_path="$rootfs_path/usr/bin/qemu-aarch64-static"
    local marker_path="$rootfs_path/usr/bin/.jetson-qemu-aarch64-static-temporary"
    local temporary_marker expected_marker status

    [[ -x "$source_path" ]] || {
        printf 'QEMU static emulator is not executable: %s\n' "$source_path" >&2
        return 1
    }
    if [[ -e "$binary_path" || -L "$binary_path" ]]; then
        [[ -x "$binary_path" ]] || {
            printf 'Existing QEMU static emulator is not executable: %s\n' "$binary_path" >&2
            return 1
        }
        return 0
    fi
    if [[ -e "$marker_path" ]]; then
        expected_marker="$(mktemp)" || return 1
        rootfs_cleanup_temporary_qemu_marker_content > "$expected_marker"
        if ! cmp -s -- "$expected_marker" "$marker_path"; then
            rm -f -- "$expected_marker"
            printf 'Refusing to replace unexpected QEMU ownership marker: %s\n' "$marker_path" >&2
            return 1
        fi
        rm -f -- "$expected_marker"
    fi
    temporary_marker="$(mktemp)" || return 1
    rootfs_cleanup_temporary_qemu_marker_content > "$temporary_marker"
    sudo install -m 0644 -- "$temporary_marker" "$marker_path"
    status=$?
    rm -f -- "$temporary_marker"
    ((status == 0)) || return "$status"
    if ! sudo cp -- "$source_path" "$binary_path"; then
        rootfs_cleanup_remove_temporary_qemu "$rootfs_path" || true
        return 1
    fi
}

rootfs_cleanup_transient_artifacts() {
    local rootfs_path="$1"
    local enabled="${2:-true}"
    local path log_path journal_path home_dir resolver_target="" resolver_target_in_rootfs="" status=0

    if [[ "$enabled" != true ]]; then
        return 0
    fi
    [[ -d "$rootfs_path" && ! -L "$rootfs_path" ]] || {
        printf 'Cannot clean rootfs transient files: invalid rootfs directory: %s\n' "$rootfs_path" >&2
        return 1
    }

    printf 'Removing rootfs temporary files, package caches, logs, and crash dumps...\n'
    for path in \
        "$rootfs_path/tmp" \
        "$rootfs_path/var/tmp" \
        "$rootfs_path/var/cache/man" \
        "$rootfs_path/var/cache/fontconfig" \
        "$rootfs_path/var/cache/ldconfig" \
        "$rootfs_path/var/crash" \
        "$rootfs_path/var/lib/systemd/coredump"; do
        rootfs_cleanup_clear_directory "$path" || status=1
    done

    if [[ -L "$rootfs_path/etc/resolv.conf" ]]; then
        resolver_target="$(readlink -- "$rootfs_path/etc/resolv.conf")"
        if [[ "$resolver_target" == /* ]]; then
            resolver_target_in_rootfs="$rootfs_path$resolver_target"
        else
            resolver_target_in_rootfs="$(dirname -- "$rootfs_path/etc/resolv.conf")/$resolver_target"
        fi
        resolver_target_in_rootfs="$(realpath -m -- "$resolver_target_in_rootfs")"
    fi
    rootfs_cleanup_clear_runtime_directory "$rootfs_path/run" "$resolver_target_in_rootfs" || status=1

    rootfs_cleanup_clear_apt_directory "$rootfs_path/var/cache/apt/archives" || status=1
    rootfs_cleanup_clear_apt_directory "$rootfs_path/var/lib/apt/lists" || status=1
    for path in \
        "$rootfs_path/var/cache/apt/pkgcache.bin" \
        "$rootfs_path/var/cache/apt/srcpkgcache.bin"; do
        if [[ -f "$path" && ! -L "$path" ]]; then
            sudo rm -f -- "$path" || status=1
        fi
    done
    rootfs_cleanup_remove_temporary_qemu "$rootfs_path" || status=1

    for home_dir in "$rootfs_path/root" "$rootfs_path"/home/*; do
        [[ -d "$home_dir" && ! -L "$home_dir" ]] || continue
        for path in \
            "$home_dir/.cache" \
            "$home_dir/.npm/_cacache" \
            "$home_dir/.npm/_logs" \
            "$home_dir/.gradle/caches" \
            "$home_dir/.cargo/registry/cache" \
            "$home_dir/.ccache"; do
            rootfs_cleanup_clear_directory "$path" || status=1
        done
        sudo find "$home_dir" -maxdepth 1 -type f \
            \( -name '.bash_history' -o -name '.zsh_history' -o -name '.sh_history' \
                -o -name '.ash_history' -o -name '.ksh_history' -o -name '.history' \
                -o -name '.python_history' -o -name '.sqlite_history' \
                -o -name '.node_repl_history' \) -delete || status=1
        if [[ -f "$home_dir/.local/share/fish/fish_history" &&
            ! -L "$home_dir/.local/share/fish/fish_history" ]]; then
            sudo rm -f -- "$home_dir/.local/share/fish/fish_history" || status=1
        fi
    done

    journal_path="$rootfs_path/var/log/journal"
    rootfs_cleanup_clear_directory "$journal_path" || status=1
    log_path="$rootfs_path/var/log"
    if [[ -d "$log_path" && ! -L "$log_path" ]]; then
        sudo find "$log_path" -xdev \
            ! -path "$journal_path" ! -path "$journal_path/*" \
            -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' \
                -o -name '*.[0-9]*' \) -delete || status=1
        sudo find "$log_path" -xdev \
            ! -path "$journal_path" ! -path "$journal_path/*" \
            -type f -exec truncate -s 0 -- {} + || status=1
    fi

    if ((status != 0)); then
        printf 'Warning: one or more rootfs transient artifacts could not be removed.\n' >&2
        return 1
    fi
}
