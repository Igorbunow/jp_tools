#!/usr/bin/env bash
# @file     select_config.sh
# @author   Project maintainers
# @date     Oct, 2026
# @version  V1.0.0
# @brief    Resolve a board configuration bundle for a JetPack version/module.
# @details  Selects the most specific available package: exact version,
#           minor-family, major-family, then common.

b_conf_profile_module() {
    local bundle="${1:-}" module_file profile
    module_file="$bundle/MODULE"
    if [[ -r "$module_file" ]]; then
        IFS= read -r profile < "$module_file" || true
        [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] && { printf '%s\n' "$profile"; return 0; }
    fi
    # Legacy layouts predate module directories. Preserve their profiles and
    # infer the module from the board name where it is unambiguous.
    profile="${bundle##*/}"
    case "$profile" in
        *orin*) printf 'orin-agx\n' ;;
        *xavier-nx*) printf 'xavier-nx\n' ;;
        *xavier*) printf 'xavier-agx\n' ;;
        *nano-2gb*|*nano-2g*) printf 'nano-2gb\n' ;;
        *tx1*) printf 'tx1\n' ;;
        *) return 1 ;;
    esac
}

b_conf_version_ge() {
    local left="${1:-}" right="${2:-}" left_major left_minor left_patch right_major right_minor right_patch
    [[ "$left" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || return 2
    left_major=$((10#${BASH_REMATCH[1]})); left_minor=$((10#${BASH_REMATCH[2]})); left_patch=$((10#${BASH_REMATCH[4]:-0}))
    [[ "$right" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || return 2
    right_major=$((10#${BASH_REMATCH[1]})); right_minor=$((10#${BASH_REMATCH[2]})); right_patch=$((10#${BASH_REMATCH[4]:-0}))
    ((left_major > right_major || (left_major == right_major && left_minor > right_minor) || \
        (left_major == right_major && left_minor == right_minor && left_patch >= right_patch)))
}

b_conf_profile_version_compatible() {
    local profile="${1:-}" version="${2:-}" min_version="" max_version=""
    [[ ! -f "$profile/JETPACK_MIN_VERSION" ]] || IFS= read -r min_version < "$profile/JETPACK_MIN_VERSION" || true
    [[ ! -f "$profile/JETPACK_MAX_VERSION" ]] || IFS= read -r max_version < "$profile/JETPACK_MAX_VERSION" || true
    [[ -z "$min_version" ]] || b_conf_version_ge "$version" "$min_version" || return 1
    [[ -z "$max_version" ]] || b_conf_version_ge "$max_version" "$version" || return 1
    return 0
}

b_conf_select_package() {
    local root="${1:-}"
    local profile="${2:-}"
    local version="${3:-}"
    local module="${4:-}"
    local major minor patch candidate

    [[ -n "$root" && -d "$root" ]] || {
        printf 'Configuration root does not exist: %s\n' "$root" >&2
        return 2
    }
    [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        printf 'Invalid board profile name: %s\n' "$profile" >&2
        return 2
    }
    if [[ -n "$module" && ! "$module" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        printf 'Invalid module family: %s\n' "$module" >&2
        return 2
    fi
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || {
        printf 'Invalid JetPack version (expected major.minor[.patch]): %s\n' "$version" >&2
        return 2
    }

    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[4]:-0}"
    local -a selectors=("$major.$minor.$patch" "$major.$minor.x" "$major.x" common)
    local -a candidates=()
    if [[ -n "$module" ]]; then
        for candidate in "${selectors[@]}"; do
            candidates+=("$root/modules/$module/$candidate/$profile")
        done
    else
        local -a module_matches=()
        local module_root
        for module_root in "$root"/modules/*; do
            [[ -d "$module_root" ]] || continue
            for candidate in "${selectors[@]}"; do
                if [[ -d "$module_root/$candidate/$profile" ]] && \
                    b_conf_profile_version_compatible "$module_root/$candidate/$profile" "$version"; then
                    module_matches+=("$module_root/$candidate/$profile")
                    break
                fi
            done
        done
        if ((${#module_matches[@]} == 1)); then
            printf '%s\n' "${module_matches[0]}"
            return 0
        elif ((${#module_matches[@]} > 1)); then
            printf 'Profile %s exists for multiple module families; specify a module.\n' "$profile" >&2
            return 3
        fi
    fi
    for candidate in "${selectors[@]}"; do
        candidates+=("$root/$candidate/$profile")
    done

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/Linux_for_Tegra" || -f "$candidate/MODULE" ]]; then
            b_conf_profile_version_compatible "$candidate" "$version" || continue
            if [[ -n "$module" ]]; then
                [[ "$(b_conf_profile_module "$candidate" 2>/dev/null || true)" == "$module" ]] || continue
            fi
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
