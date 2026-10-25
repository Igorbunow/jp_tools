#!/usr/bin/env bash

QEMU_APT_PACKAGES=()
QEMU_APT_FAILED_STEP=""
QEMU_APT_EXIT_STATUS=0
QEMU_APT_REPOSITORY_BACKUP_DIR=""
QEMU_APT_REPOSITORY_BACKUP_ROOTFS=""
QEMU_APT_REPOSITORY_OS_ID=""
QEMU_APT_REPOSITORY_ATTEMPTS=""
QEMU_APT_LAST_OFFICIAL_REPOSITORY_FAILURE=false
QEMU_APT_UPGRADE_PIN_FILE=""
QEMU_APT_SERVICE_POLICY_ROOTFS=""

qemu_apt_service_policy_content() {
    cat <<'EOF'
#!/bin/sh
exit 101
EOF
}

qemu_apt_service_policy_marker_content() {
    printf '%s\n' 'jetson-qemu-apt-temporary-policy-v1'
}

qemu_apt_cleanup_service_policy() {
    local rootfs_path="$1"
    local policy_file="$rootfs_path/usr/sbin/policy-rc.d"
    local marker_file="$rootfs_path/usr/sbin/.jetson-qemu-policy-rcd-active"
    local expected_policy expected_marker cleanup_status=0

    [[ -e "$marker_file" ]] || { QEMU_APT_SERVICE_POLICY_ROOTFS=""; return 0; }
    expected_marker="$(mktemp)" || return 1
    qemu_apt_service_policy_marker_content > "$expected_marker"
    if ! cmp -s -- "$expected_marker" "$marker_file"; then
        rm -f -- "$expected_marker"
        printf 'Refusing to clean unexpected QEMU policy marker: %s\n' "$marker_file" >&2
        return 1
    fi
    rm -f -- "$expected_marker"

    if [[ -e "$policy_file" || -L "$policy_file" ]]; then
        expected_policy="$(mktemp)" || return 1
        qemu_apt_service_policy_content > "$expected_policy"
        if ! cmp -s -- "$expected_policy" "$policy_file"; then
            rm -f -- "$expected_policy"
            printf 'Refusing to remove modified policy-rc.d: %s\n' "$policy_file" >&2
            return 1
        fi
        rm -f -- "$expected_policy"
        if [[ -w "$policy_file" ]]; then rm -f -- "$policy_file" || cleanup_status=$?
        else sudo rm -f -- "$policy_file" || cleanup_status=$?; fi
    fi
    if ((cleanup_status == 0)); then
        if [[ -w "$marker_file" ]]; then rm -f -- "$marker_file" || cleanup_status=$?
        else sudo rm -f -- "$marker_file" || cleanup_status=$?; fi
    fi
    ((cleanup_status == 0)) || return "$cleanup_status"
    QEMU_APT_SERVICE_POLICY_ROOTFS=""
}

qemu_apt_prepare_service_policy() {
    local rootfs_path="$1"
    local policy_file="$rootfs_path/usr/sbin/policy-rc.d"
    local marker_file="$rootfs_path/usr/sbin/.jetson-qemu-policy-rcd-active"
    local temporary_policy temporary_marker

    qemu_apt_cleanup_service_policy "$rootfs_path" || return 1
    # Preserve any policy intentionally provided by the target image.
    if [[ -e "$policy_file" || -L "$policy_file" ]]; then return 0; fi
    if [[ -w "$(dirname -- "$policy_file")" ]]; then
        mkdir -p -- "$(dirname -- "$policy_file")" || return 1
    else
        sudo mkdir -p -- "$(dirname -- "$policy_file")" || return 1
    fi
    temporary_policy="$(mktemp)" || return 1
    temporary_marker="$(mktemp)" || { rm -f -- "$temporary_policy"; return 1; }
    qemu_apt_service_policy_content > "$temporary_policy"
    qemu_apt_service_policy_marker_content > "$temporary_marker"
    if [[ -w "$(dirname -- "$policy_file")" ]]; then
        install -m 0755 -- "$temporary_marker" "$marker_file" &&
            install -m 0755 -- "$temporary_policy" "$policy_file"
    else
        sudo install -m 0755 -- "$temporary_marker" "$marker_file" &&
            sudo install -m 0755 -- "$temporary_policy" "$policy_file"
    fi
    local status=$?
    rm -f -- "$temporary_policy" "$temporary_marker"
    if ((status != 0)); then
        qemu_apt_cleanup_service_policy "$rootfs_path" || true
        return "$status"
    fi
    QEMU_APT_SERVICE_POLICY_ROOTFS="$rootfs_path"
}

qemu_apt_upgrade_pin_content() {
    cat <<'EOF'
Package: nvidia-l4t-*
Pin: version *
Pin-Priority: -1
EOF
}

qemu_apt_cleanup_upgrade_pin() {
    local rootfs_path="$1"
    local pin_file="$rootfs_path/etc/apt/preferences.d/90-jetson-qemu-no-l4t-upgrade"
    local expected_file

    [[ -e "$pin_file" ]] || { QEMU_APT_UPGRADE_PIN_FILE=""; return 0; }
    expected_file="$(mktemp)" || return 1
    qemu_apt_upgrade_pin_content > "$expected_file"
    if ! cmp -s -- "$expected_file" "$pin_file"; then
        rm -f -- "$expected_file"
        printf 'Refusing to remove unexpected APT preferences file: %s\n' "$pin_file" >&2
        return 1
    fi
    rm -f -- "$expected_file"
    if [[ -w "$pin_file" ]]; then
        rm -f -- "$pin_file"
    else
        sudo rm -f -- "$pin_file"
    fi || return 1
    QEMU_APT_UPGRADE_PIN_FILE=""
}

qemu_apt_prepare_upgrade_pin() {
    local rootfs_path="$1"
    local pin_file="$rootfs_path/etc/apt/preferences.d/90-jetson-qemu-no-l4t-upgrade"
    local temporary_file

    qemu_apt_cleanup_upgrade_pin "$rootfs_path" || return 1
    temporary_file="$(mktemp)" || return 1
    qemu_apt_upgrade_pin_content > "$temporary_file"
    if [[ -w "$(dirname -- "$pin_file")" ]]; then
        install -D -m 0644 -- "$temporary_file" "$pin_file"
    else
        sudo install -D -m 0644 -- "$temporary_file" "$pin_file"
    fi
    local status=$?
    rm -f -- "$temporary_file"
    ((status == 0)) || return "$status"
    QEMU_APT_UPGRADE_PIN_FILE="$pin_file"
}

qemu_apt_validate_force_repositories() {
    case "$1" in
        0|1) return 0 ;;
        *)
            printf 'JETSON_FORCE_CUSTOM_REPOSITORIES must be 0 or 1\n' >&2
            return 2
            ;;
    esac
}

qemu_apt_resolve_profile() {
    local os_release_path="$1"
    local profile_root="$2"
    local line key value os_id="" codename=""

    [[ -r "$os_release_path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        case "$key" in
            ID) os_id="$value" ;;
            VERSION_CODENAME) codename="$value" ;;
        esac
    done < "$os_release_path"

    [[ "$os_id" =~ ^[a-zA-Z0-9._+-]+$ && "$os_id" != . && "$os_id" != .. ]] || return 1
    if [[ "$codename" =~ ^[a-zA-Z0-9._+-]+$ && "$codename" != . && "$codename" != .. ]]; then
        if [[ -d "$profile_root/$os_id/$codename" ]]; then
            printf '%s\n' "$profile_root/$os_id/$codename"
            return 0
        fi
    fi
    if [[ -d "$profile_root/$os_id/default" ]]; then
        printf '%s\n' "$profile_root/$os_id/default"
        return 0
    fi
    return 1
}

qemu_apt_read_os_id() {
    local os_release_path="$1"
    local line key value
    QEMU_APT_REPOSITORY_OS_ID=""
    [[ -r "$os_release_path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        [[ "$key" == ID ]] || continue
        value="${BASH_REMATCH[2]}"
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        [[ "$value" =~ ^[a-zA-Z0-9._+-]+$ && "$value" != . && "$value" != .. ]] || return 1
        QEMU_APT_REPOSITORY_OS_ID="${value,,}"
        return 0
    done < "$os_release_path"
    return 1
}

qemu_apt_uri_is_official() {
    local os_id="$1"
    local uri="$2"
    case "$os_id" in
        ubuntu)
            [[ "$uri" =~ ^https?://(archive|ports|security|old-releases)\.ubuntu\.com([/:]|$) ]]
            ;;
        debian)
            [[ "$uri" =~ ^https?://(deb|security|archive|snapshot)\.debian\.org([/:]|$) ||
                "$uri" =~ ^https?://ftp\.[a-z0-9-]+\.debian\.org([/:]|$) ]]
            ;;
        *) return 1 ;;
    esac
}

qemu_apt_archive_uri() {
    local os_id="$1"
    local uri="$2"
    local scheme rest path
    case "$os_id" in
        ubuntu)
            if [[ "$uri" =~ ^https?://ports\.ubuntu\.com/ubuntu-ports(/.*)?$ ]]; then
                scheme="${uri%%://*}"
                path="${BASH_REMATCH[1]:-/}"
                printf '%s://old-releases.ubuntu.com/ubuntu%s\n' "$scheme" "$path"
            elif [[ "$uri" =~ ^https?://(archive|security|old-releases)\.ubuntu\.com/ubuntu(/.*)?$ ]]; then
                scheme="${uri%%://*}"
                path="${BASH_REMATCH[2]:-/}"
                printf '%s://old-releases.ubuntu.com/ubuntu%s\n' "$scheme" "$path"
            else
                printf '%s\n' "$uri"
            fi
            ;;
        debian)
            if qemu_apt_uri_is_official debian "$uri"; then
                scheme="${uri%%://*}"
                rest="${uri#*://}"
                path="${rest#*/}"
                [[ "$path" == "$rest" ]] && path=""
                printf '%s://archive.debian.org/%s\n' "$scheme" "$path"
            else
                printf '%s\n' "$uri"
            fi
            ;;
        *) return 1 ;;
    esac
}

qemu_apt_transform_list_file() {
    local source_file="$1"
    local output_file="$2"
    local os_id="$3"
    local candidate_kind="$4"
    local line prefix options uri suffix mapped
    local changed=false

    : > "$output_file" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([[:space:]]*deb)([[:space:]]+-src)?[[:space:]]+((\[[^]]*\])[[:space:]]+)?([^[:space:]]+)(.*)$ && -z "${BASH_REMATCH[2]}" ]]; then
            prefix="${BASH_REMATCH[1]} "
            options="${BASH_REMATCH[4]:-}"
            uri="${BASH_REMATCH[5]}"
            suffix="${BASH_REMATCH[6]}"
            if qemu_apt_uri_is_official "$os_id" "$uri"; then
                changed=true
                if [[ "$candidate_kind" == custom ]]; then
                    printf '# jetson-custom-profile-disabled %s\n' "$line" >> "$output_file"
                    continue
                fi
                mapped="$(qemu_apt_archive_uri "$os_id" "$uri")"
                if [[ "$os_id" == debian ]]; then
                    if [[ -n "$options" ]]; then
                        if [[ "$options" =~ check-valid-until=[^][[:space:]]+ ]]; then
                            options="${options/check-valid-until=${BASH_REMATCH[0]#check-valid-until=}/check-valid-until=no}"
                        else
                            options="${options%]} check-valid-until=no]"
                        fi
                    else
                        options='[check-valid-until=no]'
                    fi
                fi
                printf '%s%s%s%s%s\n' "$prefix" "${options:+$options }" "$mapped" "$suffix" '' >> "$output_file"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$output_file"
    done < "$source_file"
    [[ "$changed" == true ]]
}

qemu_apt_transform_deb822_file() {
    local source_file="$1"
    local output_file="$2"
    local os_id="$3"
    local candidate_kind="$4"

    awk -v os_id="$os_id" -v kind="$candidate_kind" '
        function official(uri) {
            if (os_id == "ubuntu")
                return uri ~ /^https?:\/\/(archive|ports|security|old-releases)\.ubuntu\.com([\/:]|$)/
            if (os_id == "debian")
                return uri ~ /^https?:\/\/(deb|security|archive|snapshot)\.debian\.org([\/:]|$)/ || uri ~ /^https?:\/\/ftp\.[a-z0-9-]+\.debian\.org([\/:]|$)/
            return 0
        }
        function archived(uri,    scheme, path, rest) {
            if (os_id == "ubuntu") {
                if (uri ~ /^https?:\/\/ports\.ubuntu\.com\/ubuntu-ports([/]|$)/) {
                    scheme = uri; sub(/:.*/, "", scheme)
                    path = uri; sub(/^https?:\/\/ports\.ubuntu\.com\/ubuntu-ports/, "", path)
                    if (path == "") path = "/"
                    return scheme "://old-releases.ubuntu.com/ubuntu" path
                }
                if (uri ~ /^https?:\/\/(archive|security|old-releases)\.ubuntu\.com\/ubuntu([/]|$)/) {
                    scheme = uri; sub(/:.*/, "", scheme)
                    path = uri; sub(/^https?:\/\/(archive|security|old-releases)\.ubuntu\.com\/ubuntu/, "", path)
                    if (path == "") path = "/"
                    return scheme "://old-releases.ubuntu.com/ubuntu" path
                }
            }
            if (os_id == "debian" && official(uri)) {
                scheme = uri; sub(/:.*/, "", scheme)
                rest = uri; sub(/^https?:\/\//, "", rest)
                sub(/^[^/]+\/?/, "", rest)
                return scheme "://archive.debian.org/" rest
            }
            return uri
        }
        function process_stanza(    i, j, field, value, nuri, uri, changed, kept, outuri, has_enabled, has_valid, in_uris, had_types) {
            if (n == 0) { print ""; return }
            had_types = 0; has_enabled = 0; has_valid = 0; nuri = 0
            for (i = 1; i <= n; i++) {
                if (line[i] ~ /^Types:[[:space:]]*/) {
                    value = line[i]; sub(/^Types:[[:space:]]*/, "", value)
                    if (value ~ /(^|[[:space:]])deb([[:space:]]|$)/) had_types = 1
                }
                if (line[i] ~ /^Enabled:[[:space:]]*no([[:space:]]|$)/) has_enabled = 1
                if (line[i] ~ /^Check-Valid-Until:/) has_valid = 1
                if (line[i] ~ /^URIs:[[:space:]]*/) {
                    value = line[i]; sub(/^URIs:[[:space:]]*/, "", value)
                    count = split(value, parts, /[[:space:]]+/)
                    for (j = 1; j <= count; j++) if (parts[j] != "") uri[++nuri] = parts[j]
                    j = i + 1
                    while (j <= n && line[j] ~ /^[[:space:]]+/) {
                        value = line[j]; sub(/^[[:space:]]+/, "", value)
                        count = split(value, parts, /[[:space:]]+/)
                        for (k = 1; k <= count; k++) if (parts[k] != "") uri[++nuri] = parts[k]
                        j++
                    }
                    i = j - 1
                }
            }
            changed = 0; kept = 0; outuri = ""
            for (i = 1; i <= nuri; i++) {
                if (official(uri[i])) {
                    changed = 1
                    if (kind == "custom") continue
                    uri[i] = archived(uri[i])
                }
                if (outuri != "") outuri = outuri " "
                outuri = outuri uri[i]
                kept++
            }
            if (!had_types || has_enabled || !changed) {
                for (i = 1; i <= n; i++) print line[i]
                print ""
                return
            }
            in_uris = 0; uri_written = 0; valid_written = 0
            for (i = 1; i <= n; i++) {
                if (line[i] ~ /^URIs:[[:space:]]*/) {
                    in_uris = 1
                    if (kept > 0) { print "URIs: " outuri; uri_written = 1 }
                    continue
                }
                if (in_uris && line[i] ~ /^[[:space:]]+/) continue
                in_uris = 0
                if (kind == "archive" && os_id == "debian" && line[i] ~ /^Check-Valid-Until:/) {
                    print "Check-Valid-Until: no"; valid_written = 1; continue
                }
                if (kind == "custom" && kept == 0 && line[i] ~ /^Enabled:/) {
                    print "Enabled: no"; has_enabled = 1; continue
                }
                print line[i]
                if (line[i] ~ /^Types:/ && kind == "archive" && os_id == "debian" && !has_valid && !valid_written) {
                    print "Check-Valid-Until: no"; valid_written = 1
                }
                if (line[i] ~ /^Types:/ && kind == "custom" && kept == 0 && !has_enabled) {
                    print "Enabled: no"; has_enabled = 1
                }
            }
            print ""
        }
        { if ($0 == "") process_stanza(); else line[++n] = $0 }
        END { if (n > 0) process_stanza() }
    ' "$source_file" > "$output_file"
}

qemu_apt_replace_source_file() {
    local source_file="$1"
    local os_id="$2"
    local candidate_kind="$3"
    local temporary mode
    temporary="$(mktemp)" || return 1
    if [[ "$source_file" == *.sources ]]; then
        qemu_apt_transform_deb822_file "$source_file" "$temporary" "$os_id" "$candidate_kind" || {
            rm -f -- "$temporary"
            return 0
        }
    else
        qemu_apt_transform_list_file "$source_file" "$temporary" "$os_id" "$candidate_kind" || {
            rm -f -- "$temporary"
            return 0
        }
    fi
    mode="$(stat -c '%a' -- "$source_file")" || { rm -f -- "$temporary"; return 1; }
    sudo install -m "$mode" -- "$temporary" "$source_file"
    local status=$?
    rm -f -- "$temporary"
    return "$status"
}

qemu_apt_restore_repository_sources() {
    local rootfs_path="$1"
    local apt_path="$rootfs_path/etc/apt"
    local backup_dir="$QEMU_APT_REPOSITORY_BACKUP_DIR"

    [[ -n "$backup_dir" && "$QEMU_APT_REPOSITORY_BACKUP_ROOTFS" == "$rootfs_path" ]] || return 0
    sudo rm -f -- "$apt_path/sources.list" || return 1
    sudo rm -rf -- "$apt_path/sources.list.d" || return 1
    if [[ -e "$backup_dir/sources.list" ]]; then
        sudo cp -a -- "$backup_dir/sources.list" "$apt_path/sources.list" || return 1
    fi
    if [[ -d "$backup_dir/sources.list.d" ]]; then
        sudo cp -a -- "$backup_dir/sources.list.d" "$apt_path/sources.list.d" || return 1
    fi
    sudo rm -rf -- "$backup_dir"
    QEMU_APT_REPOSITORY_BACKUP_DIR=""
    QEMU_APT_REPOSITORY_BACKUP_ROOTFS=""
    QEMU_APT_REPOSITORY_OS_ID=""
}

qemu_apt_copy_profile_sources() {
    local rootfs_path="$1"
    local profile_path="$2"
    local os_id="$3"
    local apt_path="$rootfs_path/etc/apt"
    local source_file relative target replacement_name
    local -A replacements=()

    if [[ "$os_id" != ubuntu && "$os_id" != debian && -f "$profile_path/replace-files" ]]; then
        while IFS= read -r relative || [[ -n "$relative" ]]; do
            relative="${relative%%#*}"
            [[ -n "$relative" ]] || continue
            [[ "$relative" =~ ^(sources\.list|sources\.list\.d/[A-Za-z0-9._+-]+\.(list|sources))$ ]] || return 1
            replacements["$relative"]=1
            sudo rm -f -- "$apt_path/$relative" || return 1
            if [[ -f "$profile_path/$relative" ]]; then
                sudo mkdir -p -- "$(dirname -- "$apt_path/$relative")" || return 1
                sudo install -m 644 -- "$profile_path/$relative" "$apt_path/$relative" || return 1
            fi
        done < "$profile_path/replace-files"
    fi

    while IFS= read -r -d '' source_file; do
        relative="${source_file#"$profile_path"/}"
        case "$relative" in
            replace-files) continue ;;
            sources.list) target="$apt_path/sources.list.d/jetson-custom-profile.list" ;;
            sources.list.d/*)
                target="$apt_path/sources.list.d/jetson-custom-profile-${relative##*/}"
                ;;
            *.list|*.sources) target="$apt_path/sources.list.d/jetson-custom-profile-${relative##*/}" ;;
            *) continue ;;
        esac
        if [[ "$os_id" != ubuntu && "$os_id" != debian ]]; then
            [[ -n "${replacements["${relative#sources.list.d/}"]:-}" || -n "${replacements["$relative"]:-}" ]] && continue
        fi
        sudo mkdir -p -- "$(dirname -- "$target")" || return 1
        sudo install -m 644 -- "$source_file" "$target" || return 1
    done < <(find "$profile_path" -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' -o -name 'sources.list' \) -print0)
}

qemu_apt_stage_repository_candidate() {
    local rootfs_path="$1"
    local candidate_kind="$2"
    local profile_path="$3"
    local apt_path="$rootfs_path/etc/apt"
    local source_file
    local profile_source

    [[ "$candidate_kind" == archive || "$candidate_kind" == custom ]] || return 2
    if [[ -n "$QEMU_APT_REPOSITORY_BACKUP_DIR" ]]; then
        qemu_apt_restore_repository_sources "$QEMU_APT_REPOSITORY_BACKUP_ROOTFS" || return 1
    fi
    qemu_apt_read_os_id "$rootfs_path/etc/os-release" || return 2
    if [[ "$candidate_kind" == archive && "$QEMU_APT_REPOSITORY_OS_ID" != ubuntu && "$QEMU_APT_REPOSITORY_OS_ID" != debian ]]; then
        return 2
    fi
    if [[ "$candidate_kind" == custom && ! -d "$profile_path" ]]; then
        return 2
    fi
    if [[ "$candidate_kind" == custom ]]; then
        profile_source="$(find "$profile_path" -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' -o -name 'sources.list' \) -print -quit)"
        [[ -n "$profile_source" ]] || return 2
    fi

    QEMU_APT_REPOSITORY_BACKUP_DIR="$(mktemp -d /tmp/jetson-apt-sources.XXXXXX)" || return 1
    QEMU_APT_REPOSITORY_BACKUP_ROOTFS="$rootfs_path"
    if [[ -f "$apt_path/sources.list" ]]; then
        sudo cp -a -- "$apt_path/sources.list" "$QEMU_APT_REPOSITORY_BACKUP_DIR/" || { qemu_apt_restore_repository_sources "$rootfs_path" || true; return 1; }
    fi
    if [[ -d "$apt_path/sources.list.d" ]]; then
        sudo cp -a -- "$apt_path/sources.list.d" "$QEMU_APT_REPOSITORY_BACKUP_DIR/" || { qemu_apt_restore_repository_sources "$rootfs_path" || true; return 1; }
    fi

    shopt -s nullglob
    local -a source_files=("$apt_path/sources.list" "$apt_path/sources.list.d"/*.list "$apt_path/sources.list.d"/*.sources)
    shopt -u nullglob
    for source_file in "${source_files[@]}"; do
        [[ -f "$source_file" ]] || continue
        qemu_apt_replace_source_file "$source_file" "$QEMU_APT_REPOSITORY_OS_ID" "$candidate_kind" || {
            qemu_apt_restore_repository_sources "$rootfs_path" || true
            return 1
        }
    done
    if [[ "$candidate_kind" == custom ]]; then
        qemu_apt_copy_profile_sources "$rootfs_path" "$profile_path" "$QEMU_APT_REPOSITORY_OS_ID" || {
            qemu_apt_restore_repository_sources "$rootfs_path" || true
            return 1
        }
    fi
}

qemu_apt_commit_repository_sources() {
    local rootfs_path="$1"
    [[ -n "$QEMU_APT_REPOSITORY_BACKUP_DIR" && "$QEMU_APT_REPOSITORY_BACKUP_ROOTFS" == "$rootfs_path" ]] || return 0
    sudo rm -rf -- "$QEMU_APT_REPOSITORY_BACKUP_DIR" || return 1
    QEMU_APT_REPOSITORY_BACKUP_DIR=""
    QEMU_APT_REPOSITORY_BACKUP_ROOTFS=""
    QEMU_APT_REPOSITORY_OS_ID=""
}

qemu_apt_run_repository_update() {
    local rootfs_path="$1"
    local output_file status uri
    QEMU_APT_LAST_OFFICIAL_REPOSITORY_FAILURE=false
    output_file="$(mktemp /tmp/jetson-apt-update.XXXXXX)" || return 1
    if qemu_apt_run_in_rootfs "$rootfs_path" apt-get \
        -o APT::Update::Error-Mode=any \
        -o Acquire::Languages=none \
        -o Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false \
        -o Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled=false \
        -o Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled=false \
        -o Acquire::IndexTargets::deb::DEP-11-icons-hidpi::DefaultEnabled=false \
        -o Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled=false \
        -o Acquire::IndexTargets::deb::DEP-11-icons-large-hidpi::DefaultEnabled=false \
        update >"$output_file" 2>&1; then
        status=0
    else
        status=$?
    fi
    cat -- "$output_file"
    while IFS= read -r uri; do
        if qemu_apt_uri_is_official "${QEMU_APT_REPOSITORY_OS_ID:-}" "$uri"; then
            QEMU_APT_LAST_OFFICIAL_REPOSITORY_FAILURE=true
            break
        fi
    done < <(grep -E '(^Err:|Failed to fetch |^E: The repository )' "$output_file" | grep -Eo 'https?://[^[:space:]]+' || true)
    rm -f -- "$output_file"
    return "$status"
}

qemu_apt_update_with_fallback() {
    local rootfs_path="$1"
    local profile_root="$2"
    local force_custom="$3"
    local status initial_status profile_path="" os_id="" official_failure=false

    QEMU_APT_FAILED_STEP=""
    QEMU_APT_EXIT_STATUS=0
    QEMU_APT_REPOSITORY_ATTEMPTS="current sources"
    qemu_apt_read_os_id "$rootfs_path/etc/os-release" || true
    os_id="$QEMU_APT_REPOSITORY_OS_ID"

    if qemu_apt_run_repository_update "$rootfs_path"; then
        return 0
    else
        initial_status=$?
    fi

    official_failure="$QEMU_APT_LAST_OFFICIAL_REPOSITORY_FAILURE"

    if [[ "$force_custom" == true || "$force_custom" == 1 ]]; then
        profile_path="$(qemu_apt_resolve_profile "$rootfs_path/etc/os-release" "$profile_root" 2>/dev/null || true)"
        if [[ -n "$profile_path" ]]; then
            printf 'Repository check failed; retrying with custom profile: %s\n' "$profile_path"
            QEMU_APT_REPOSITORY_ATTEMPTS+=" -> custom profile $profile_path"
            if qemu_apt_stage_repository_candidate "$rootfs_path" custom "$profile_path"; then
                if qemu_apt_run_repository_update "$rootfs_path"; then
                    qemu_apt_commit_repository_sources "$rootfs_path" || {
                        status=$?
                        QEMU_APT_FAILED_STEP="repository configuration commit"
                        QEMU_APT_EXIT_STATUS="$status"
                        qemu_apt_restore_repository_sources "$rootfs_path" || true
                        return "$status"
                    }
                    printf 'Custom repository profile validated and retained.\n'
                    return 0
                else
                    status=$?
                    [[ "$QEMU_APT_LAST_OFFICIAL_REPOSITORY_FAILURE" == true ]] && official_failure=true
                fi
                qemu_apt_restore_repository_sources "$rootfs_path" || {
                    QEMU_APT_FAILED_STEP="repository rollback"
                    QEMU_APT_EXIT_STATUS=1
                    return 1
                }
            else
                status=$?
            fi
            printf 'Custom repository profile failed validation (status %s); continuing to archive fallback.\n' "$status"
        else
            printf 'No custom repository profile matches %s; continuing to archive fallback.\n' "${os_id:-unknown distribution}"
        fi
    fi

    if [[ ( "$os_id" == ubuntu || "$os_id" == debian ) && "$official_failure" == true ]]; then
        printf 'Trying official archive repositories for %s.\n' "$os_id"
        QEMU_APT_REPOSITORY_ATTEMPTS+=" -> $os_id official archive"
        if qemu_apt_stage_repository_candidate "$rootfs_path" archive ""; then
            if qemu_apt_run_repository_update "$rootfs_path"; then
                qemu_apt_commit_repository_sources "$rootfs_path" || {
                    status=$?
                    QEMU_APT_FAILED_STEP="repository configuration commit"
                    QEMU_APT_EXIT_STATUS="$status"
                    qemu_apt_restore_repository_sources "$rootfs_path" || true
                    return "$status"
                }
                printf 'Official archive repositories validated and retained.\n'
                return 0
            else
                status=$?
            fi
            qemu_apt_restore_repository_sources "$rootfs_path" || {
                QEMU_APT_FAILED_STEP="repository rollback"
                QEMU_APT_EXIT_STATUS=1
                return 1
            }
        else
            status=$?
        fi
        printf 'Official archive validation failed (status %s).\n' "$status"
    elif [[ "$os_id" != ubuntu && "$os_id" != debian ]]; then
        printf 'No automatic archive fallback is defined for %s.\n' "${os_id:-unknown distribution}"
    else
        printf 'No failed official %s repository was detected; preserving configured sources.\n' "$os_id"
    fi

    QEMU_APT_FAILED_STEP="apt-get update"
    QEMU_APT_EXIT_STATUS="${status:-$initial_status}"
    printf 'Repository validation attempts failed: %s.\n' "$QEMU_APT_REPOSITORY_ATTEMPTS"
    return "$QEMU_APT_EXIT_STATUS"
}

qemu_apt_run_in_rootfs() {
    local rootfs_path="$1"
    shift
    sudo chroot "$rootfs_path" /usr/bin/env \
        LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive "$@"
}

qemu_apt_repair_nvidia_pam_profile() {
    local rootfs_path="$1"

    sudo chroot "$rootfs_path" /usr/bin/env \
        LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive \
        /bin/sh -c '
            profile=/usr/share/pam-configs/nv-power-adapter-check
            [ -f "$profile" ] || exit 0
            temporary=$(mktemp "${profile}.XXXXXX") || exit 1
            trap '\''rm -f "$temporary"'\'' EXIT HUP INT TERM
            awk '\''
                !started && /^[[:space:]]*$/ { next }
                !started && /^[[:space:]]*#/ { next }
                { started = 1; print }
            '\'' "$profile" > "$temporary" || exit 1
            cat "$temporary" > "$profile" || exit 1
        '
}

qemu_apt_load_packages() {
    local package_file="$1"
    local line package
    local -a line_packages=()

    [[ -r "$package_file" ]] || {
        printf 'APT package list is not readable: %s\n' "$package_file" >&2
        return 1
    }

    QEMU_APT_PACKAGES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        read -r -a line_packages <<< "$line"
        for package in "${line_packages[@]}"; do
            [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || {
                printf 'Invalid Debian package name in %s: %s\n' "$package_file" "$package" >&2
                QEMU_APT_PACKAGES=()
                return 1
            }
            QEMU_APT_PACKAGES+=("$package")
        done
    done < "$package_file"
}

qemu_apt_validate_repositories() {
    local rootfs_path="$1"
    local profile_root="${2:-}"
    local force_custom="${3:-false}"
    local status

    QEMU_APT_FAILED_STEP=""
    QEMU_APT_EXIT_STATUS=0

    qemu_apt_repair_nvidia_pam_profile "$rootfs_path"
    status=$?
    if ((status != 0)); then
        QEMU_APT_FAILED_STEP="NVIDIA PAM profile preparation"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    qemu_apt_update_with_fallback "$rootfs_path" "$profile_root" "$force_custom"
    status=$?
    return "$status"
}

qemu_apt_upgrade_install() {
    local rootfs_path="$1"
    local status
    local failed_step=""
    local cleanup_status=0

    qemu_apt_prepare_service_policy "$rootfs_path"
    status=$?
    if ((status != 0)); then
        QEMU_APT_FAILED_STEP="preparing chroot service policy"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    qemu_apt_prepare_upgrade_pin "$rootfs_path"
    status=$?
    if ((status != 0)); then
        qemu_apt_cleanup_service_policy "$rootfs_path" || true
        QEMU_APT_FAILED_STEP="protecting NVIDIA BSP packages during QEMU APT"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi

    qemu_apt_run_in_rootfs "$rootfs_path" \
        apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
    status=$?
    if ((status != 0)); then
        failed_step="apt-get upgrade"
    fi

    if ((status == 0)) && ((${#QEMU_APT_PACKAGES[@]})); then
        qemu_apt_run_in_rootfs "$rootfs_path" \
            apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            install "${QEMU_APT_PACKAGES[@]}"
        status=$?
        if ((status != 0)); then
            failed_step="apt-get install"
        fi
    fi

    qemu_apt_cleanup_upgrade_pin "$rootfs_path" || cleanup_status=$?
    if ((cleanup_status != 0)); then
        QEMU_APT_FAILED_STEP="restoring temporary NVIDIA BSP APT pin"
        QEMU_APT_EXIT_STATUS="$cleanup_status"
        return "$cleanup_status"
    fi
    qemu_apt_cleanup_service_policy "$rootfs_path" || cleanup_status=$?
    if ((cleanup_status != 0)); then
        QEMU_APT_FAILED_STEP="restoring target chroot service policy"
        QEMU_APT_EXIT_STATUS="$cleanup_status"
        return "$cleanup_status"
    fi
    if [[ -n "$failed_step" ]]; then
        QEMU_APT_FAILED_STEP="$failed_step"
        QEMU_APT_EXIT_STATUS="$status"
        return "$status"
    fi
}

qemu_apt_run_update_upgrade() {
    local rootfs_path="$1"
    local profile_root="${2:-}"
    local force_custom="${3:-false}"
    local status

    qemu_apt_validate_repositories "$rootfs_path" "$profile_root" "$force_custom"
    status=$?
    ((status == 0)) || return "$status"
    qemu_apt_upgrade_install "$rootfs_path"
}
