#!/usr/bin/env bash
# @file     select_config.sh
# @author   Project maintainers
# @date     Oct, 2026
# @version  V1.0.0
# @brief    Resolve a board configuration bundle for a JetPack version.
# @details  Selects the most specific available package: exact version,
#           minor-family, major-family, then common.

b_conf_select_package() {
    local root="${1:-}"
    local profile="${2:-}"
    local version="${3:-}"
    local major minor patch candidate

    [[ -n "$root" && -d "$root" ]] || {
        printf 'Configuration root does not exist: %s\n' "$root" >&2
        return 2
    }
    [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        printf 'Invalid board profile name: %s\n' "$profile" >&2
        return 2
    }
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || {
        printf 'Invalid JetPack version (expected major.minor[.patch]): %s\n' "$version" >&2
        return 2
    }

    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[4]:-0}"
    local -a candidates=(
        "$root/$major.$minor.$patch/$profile"
        "$root/$major.$minor.x/$profile"
        "$root/$major.x/$profile"
        "$root/common/$profile"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/Linux_for_Tegra" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'No configuration bundle for profile %s and JetPack %s under %s\n' \
        "$profile" "$version" "$root" >&2
    return 1
}

b_conf_install_payload() {
    local payload="${1:-}"
    local target="${2:-}"
    local source_file relative_path destination mode

    [[ -d "$payload" && -n "$target" ]] || {
        printf 'Invalid configuration payload or target: %s -> %s\n' "$payload" "$target" >&2
        return 2
    }
    if find "$payload" -type l -print -quit | grep -q .; then
        printf 'Symlinks are not supported in configuration payloads: %s\n' "$payload" >&2
        return 2
    fi

    while IFS= read -r -d '' source_file; do
        relative_path="${source_file#"$payload"/}"
        destination="$target/$relative_path"
        if [[ -e "$destination" || -L "$destination" ]]; then
            if [[ -f "$destination" && ! -L "$destination" ]] && cmp -s -- "$source_file" "$destination"; then
                continue
            fi
            printf 'Refusing to overwrite existing BSP file: %s\n' "$destination" >&2
            return 1
        fi
        mode="$(stat -c '%a' "$source_file")"
        sudo install -D -m "$mode" -- "$source_file" "$destination" || return 1
    done < <(find "$payload" -type f -print0)
}
