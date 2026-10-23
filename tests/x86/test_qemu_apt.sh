#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
fixture="$(mktemp -d /tmp/jetson-apt.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin"
mkdir -p "$fixture/rootfs/usr/share/pam-configs"
cat > "$fixture/rootfs/usr/share/pam-configs/nv-power-adapter-check" <<'EOF'

# NVIDIA header that pam-auth-update misparses before its first field.
# A second comment line exercises removal of the complete leading preamble.
Name: NVIDIA power adapter check
Default: yes
Priority: 0
Session-Type: Additional
Session:
\toptional pam_exec.so /usr/sbin/nv_pam_power_adapter_checker.sh
EOF
cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
if [[ "$1" == chroot && "$3" == /usr/bin/env ]]; then
    rootfs_path="$2"
    shift 3
    while [[ "$1" == *=* ]]; do shift; done
    if [[ "$1" == /bin/sh ]]; then
        profile="$rootfs_path/usr/share/pam-configs/nv-power-adapter-check"
        temporary="${profile}.test-tmp"
        awk '!started && /^[[:space:]]*$/ { next } !started && /^[[:space:]]*#/ { next } { started=1; print }' \
            "$profile" > "$temporary" && cat "$temporary" > "$profile"
        status=$?
        rm -f "$temporary"
        exit "$status"
    fi
fi
case "${1:-}" in
    cp|install|rm|mkdir) command "$@" ;;
esac
EOF
chmod +x "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
export JETSON_TEST_LOG="$fixture/sudo.log"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/qemu_apt.sh"

qemu_apt_validate_force_repositories 0
qemu_apt_validate_force_repositories 1
if qemu_apt_validate_force_repositories true >/dev/null 2>&1; then
    echo 'FAIL: repository force mode accepted a value other than 0 or 1' >&2; exit 1
fi

mkdir -p "$fixture/profiles/ubuntu/jammy" "$fixture/profiles/ubuntu/default"
printf 'ID=ubuntu\nVERSION_CODENAME=jammy\n' > "$fixture/rootfs/etc-os-release"
qemu_apt_resolve_profile "$fixture/rootfs/etc-os-release" "$fixture/profiles"
[[ "$(qemu_apt_resolve_profile "$fixture/rootfs/etc-os-release" "$fixture/profiles")" == "$fixture/profiles/ubuntu/jammy" ]] || {
    echo 'FAIL: exact OS/codename repository profile was not preferred' >&2; exit 1;
}
rm -rf "$fixture/profiles/ubuntu/jammy"
[[ "$(qemu_apt_resolve_profile "$fixture/rootfs/etc-os-release" "$fixture/profiles")" == "$fixture/profiles/ubuntu/default" ]] || {
    echo 'FAIL: default OS repository profile was not selected as fallback' >&2; exit 1;
}

source_root="$fixture/rootfs/etc/apt"
mkdir -p "$source_root/sources.list.d"
cat > "$source_root/sources.list" <<'EOF'
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ noble main universe
deb https://repo.download.nvidia.com/jetson/common r39.2 main
EOF
cat > "$source_root/sources.list.d/mixed.sources" <<'EOF'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/ https://third-party.example/repo
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: noble-security
Components: main universe
Enabled: no
EOF
cat > "$source_root/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian https://security.debian.org/debian-security
Suites: bookworm bookworm-security
Components: main
EOF
printf 'deb https://mirror.example.invalid/ubuntu noble main\n' > "$source_root/sources.list.d/unknown.list"
chmod 640 "$source_root/sources.list"
cp -a "$source_root" "$fixture/original-apt"

printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$fixture/rootfs/etc/os-release"
qemu_apt_stage_repository_candidate "$fixture/rootfs" archive ""
grep -Fq 'http://old-releases.ubuntu.com/ubuntu/ noble' "$source_root/sources.list" || {
    echo 'FAIL: Ubuntu classic source was not redirected to the archive while retaining its codename' >&2; exit 1;
}
grep -Fq '[arch=arm64]' "$source_root/sources.list" || {
    echo 'FAIL: Ubuntu archive rewrite dropped the source architecture filter' >&2; exit 1;
}
grep -Fq 'repo.download.nvidia.com/jetson/common' "$source_root/sources.list" || {
    echo 'FAIL: NVIDIA source changed during archive fallback' >&2; exit 1;
}
grep -Fq 'https://third-party.example/repo' "$source_root/sources.list.d/mixed.sources" || {
    echo 'FAIL: third-party URI in a mixed Deb822 stanza was not preserved' >&2; exit 1;
}
grep -Fq 'http://old-releases.ubuntu.com/ubuntu/' "$source_root/sources.list.d/mixed.sources" || {
    echo 'FAIL: Ubuntu Deb822 URI was not redirected' >&2; exit 1;
}
grep -Fq 'https://archive.ubuntu.com/ubuntu' "$source_root/sources.list.d/mixed.sources" || {
    echo 'FAIL: disabled repository stanza was modified' >&2; exit 1;
}
grep -Fq 'https://deb.debian.org/debian' "$source_root/sources.list.d/debian.sources" || {
    echo 'FAIL: Debian source was rewritten while processing an Ubuntu rootfs' >&2; exit 1;
}
grep -Fq 'https://mirror.example.invalid/ubuntu noble main' "$source_root/sources.list.d/unknown.list" || {
    echo 'FAIL: unknown repository was modified during archive fallback' >&2; exit 1;
}
qemu_apt_restore_repository_sources "$fixture/rootfs"
diff -ru "$fixture/original-apt" "$source_root" >/dev/null || {
    echo 'FAIL: source rollback did not restore original file contents' >&2; exit 1;
}
[[ "$(stat -c '%a' "$source_root/sources.list")" == 640 ]] || {
    echo 'FAIL: source rollback did not preserve the original file mode' >&2; exit 1;
}

printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$fixture/rootfs/etc/os-release"
sed -i 's#URIs: https://deb.debian.org/debian https://security.debian.org/debian-security#URIs: https://deb.debian.org/debian https://security.debian.org/debian-security#' "$source_root/sources.list.d/debian.sources"
qemu_apt_stage_repository_candidate "$fixture/rootfs" archive ""
grep -Fq 'https://archive.debian.org/debian' "$source_root/sources.list.d/debian.sources" || {
    echo 'FAIL: Debian source was not redirected to archive.debian.org' >&2; exit 1;
}
grep -Fq 'https://archive.debian.org/debian-security' "$source_root/sources.list.d/debian.sources" || {
    echo 'FAIL: Debian security source was not redirected to archive.debian.org' >&2; exit 1;
}
grep -Fq 'Check-Valid-Until: no' "$source_root/sources.list.d/debian.sources" || {
    echo 'FAIL: Debian archive source lacks source-scoped Valid-Until override' >&2; exit 1;
}
qemu_apt_restore_repository_sources "$fixture/rootfs"

printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$fixture/rootfs/etc/os-release"
mkdir -p "$fixture/profiles/ubuntu/noble/sources.list.d"
cat > "$fixture/profiles/ubuntu/noble/sources.list.d/custom.sources" <<'EOF'
Types: deb
URIs: http://apt-mirror.lan/ubuntu
Suites: noble noble-updates
Components: main universe
EOF
qemu_apt_stage_repository_candidate "$fixture/rootfs" custom "$fixture/profiles/ubuntu/noble"
grep -Fq '# jetson-custom-profile-disabled deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ noble main universe' "$source_root/sources.list" || {
    echo 'FAIL: custom profile did not disable the recognized official Ubuntu source' >&2; exit 1;
}
grep -Fq 'repo.download.nvidia.com/jetson/common' "$source_root/sources.list" || {
    echo 'FAIL: custom profile changed the NVIDIA source' >&2; exit 1;
}
grep -Fq 'https://third-party.example/repo' "$source_root/sources.list.d/mixed.sources" || {
    echo 'FAIL: custom profile removed the third-party URI from a mixed Deb822 stanza' >&2; exit 1;
}
grep -Fq 'http://apt-mirror.lan/ubuntu' "$source_root/sources.list.d/jetson-custom-profile-custom.sources" || {
    echo 'FAIL: custom APT profile source was not installed' >&2; exit 1;
}
qemu_apt_restore_repository_sources "$fixture/rootfs"
diff -ru "$fixture/original-apt" "$source_root" >/dev/null || {
    echo 'FAIL: rollback after custom profile did not restore original source files' >&2; exit 1;
}
if qemu_apt_stage_repository_candidate "$fixture/rootfs" custom "$fixture/profiles/ubuntu/missing"; then
    echo 'FAIL: custom candidate accepted a missing profile directory' >&2; exit 1;
fi
mkdir -p "$fixture/profiles/ubuntu/empty"
if qemu_apt_stage_repository_candidate "$fixture/rootfs" custom "$fixture/profiles/ubuntu/empty"; then
    echo 'FAIL: custom candidate accepted a profile without APT source files' >&2; exit 1;
fi
diff -ru "$fixture/original-apt" "$source_root" >/dev/null || {
    echo 'FAIL: missing custom profile changed existing sources' >&2; exit 1;
}

printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$fixture/rootfs/etc/os-release"
cat > "$source_root/sources.list.d/debian-classic.list" <<'EOF'
deb [arch=arm64] https://deb.debian.org/debian bookworm main
deb [arch=arm64 check-valid-until=yes] https://security.debian.org/debian-security bookworm-security main
EOF
qemu_apt_stage_repository_candidate "$fixture/rootfs" archive ""
grep -Fq 'https://archive.debian.org/debian bookworm main' "$source_root/sources.list.d/debian-classic.list" || {
    echo 'FAIL: Debian classic source rewrite changed its suite or components' >&2; exit 1;
}
grep -Fq 'check-valid-until=no' "$source_root/sources.list.d/debian-classic.list" || {
    echo 'FAIL: Debian classic source did not replace the stale Valid-Until setting' >&2; exit 1;
}
qemu_apt_restore_repository_sources "$fixture/rootfs"

printf 'ID=myapt\nVERSION_CODENAME=stable\n' > "$fixture/rootfs/etc/os-release"
mkdir -p "$source_root/sources.list.d" "$fixture/profiles/myapt/stable/sources.list.d"
printf 'deb https://official.myapt.invalid/stable main\n' > "$source_root/sources.list.d/official.list"
printf 'deb https://vendor.example.invalid/repo stable main\n' > "$source_root/sources.list.d/vendor.list"
printf 'sources.list.d/official.list\n' > "$fixture/profiles/myapt/stable/replace-files"
printf 'deb https://mirror.lan/myapt stable main\n' > "$fixture/profiles/myapt/stable/sources.list.d/official.list"
printf 'deb https://tools.lan/myapt stable tools\n' > "$fixture/profiles/myapt/stable/sources.list.d/tools.list"
cp -a "$source_root" "$fixture/original-myapt"
qemu_apt_stage_repository_candidate "$fixture/rootfs" custom "$fixture/profiles/myapt/stable"
grep -Fq 'https://mirror.lan/myapt stable main' "$source_root/sources.list.d/official.list" || {
    echo 'FAIL: custom replace-files manifest was not applied for a non-Ubuntu/Debian APT system' >&2; exit 1;
}
grep -Fq 'https://vendor.example.invalid/repo stable main' "$source_root/sources.list.d/vendor.list" || {
    echo 'FAIL: non-Ubuntu/Debian custom profile changed an unlisted source file' >&2; exit 1;
}
grep -Fq 'https://tools.lan/myapt stable tools' "$source_root/sources.list.d/jetson-custom-profile-tools.list" || {
    echo 'FAIL: additional non-Ubuntu/Debian profile source was not installed' >&2; exit 1;
}
qemu_apt_restore_repository_sources "$fixture/rootfs"
diff -ru "$fixture/original-myapt" "$source_root" >/dev/null || {
    echo 'FAIL: non-Ubuntu/Debian profile rollback did not restore original source files' >&2; exit 1;
}

fallback_rootfs="$fixture/fallback-rootfs"
fallback_sources="$fallback_rootfs/etc/apt"
profile_root="$fixture/fallback-profiles"
mkdir -p "$fallback_sources/sources.list.d" "$profile_root/ubuntu/noble/sources.list.d"
printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$fallback_rootfs/etc/os-release"
cat > "$fallback_sources/sources.list" <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports/ noble main
deb https://repo.download.nvidia.com/jetson/common r39.2 main
EOF
cat > "$profile_root/ubuntu/noble/sources.list.d/mirror.sources" <<'EOF'
Types: deb
URIs: http://apt-mirror.lan/ubuntu
Suites: noble noble-updates
Components: main universe
EOF
cp -a "$fallback_sources" "$fixture/fallback-original"

cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
if [[ "$1" == chroot && "$3" == /usr/bin/env ]]; then
    rootfs_path="$2"
    shift 3
    while [[ "$1" == *=* ]]; do shift; done
    if [[ "$1" == /bin/sh ]]; then
        profile="$rootfs_path/usr/share/pam-configs/nv-power-adapter-check"
        [[ -f "$profile" ]] || exit 0
        temporary="${profile}.test-tmp"
        awk '!started && /^[[:space:]]*$/ { next } !started && /^[[:space:]]*#/ { next } { started=1; print }' \
            "$profile" > "$temporary" && cat "$temporary" > "$profile"
        status=$?
        rm -f "$temporary"
        exit "$status"
    fi
fi
if [[ "$*" =~ apt-get.*[[:space:]]update($|[[:space:]]) ]]; then
    count=0
    [[ -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE" ]] && count="$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
    IFS=, read -r -a results <<< "${JETSON_TEST_APT_UPDATE_RESULTS:-0}"
    result_index=$((count - 1))
    if ((result_index >= ${#results[@]})); then result_index=$((${#results[@]} - 1)); fi
    exit "${results[$result_index]}"
fi
case "${1:-}" in
    cp|install|rm|mkdir) command "$@" ;;
esac
EOF
chmod +x "$fixture/bin/sudo"
export JETSON_TEST_APT_UPDATE_COUNT_FILE="$fixture/apt-update-count"
export JETSON_TEST_APT_UPDATE_RESULTS=0

qemu_apt_update_with_fallback "$fallback_rootfs" "$profile_root" false
[[ "$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")" == 1 ]] || {
    echo 'FAIL: successful initial repository validation ran more than once' >&2; exit 1;
}
diff -ru "$fixture/fallback-original" "$fallback_sources" >/dev/null || {
    echo 'FAIL: successful initial validation needlessly changed source files' >&2; exit 1;
}

rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
: > "$JETSON_TEST_LOG"
export JETSON_TEST_APT_UPDATE_RESULTS=42,0
qemu_apt_update_with_fallback "$fallback_rootfs" "$profile_root" true
[[ "$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")" == 2 ]] || {
    echo 'FAIL: opted-in custom repository profile was not retried after source failure' >&2; exit 1;
}
grep -Fq 'apt-mirror.lan/ubuntu' "$fallback_sources/sources.list.d/jetson-custom-profile-mirror.sources" || {
    echo 'FAIL: successful custom repository profile was not retained' >&2; exit 1;
}
grep -Fq 'repo.download.nvidia.com/jetson/common' "$fallback_sources/sources.list" || {
    echo 'FAIL: custom profile removed the NVIDIA repository' >&2; exit 1;
}
[[ -z "$QEMU_APT_REPOSITORY_BACKUP_DIR" ]] || {
    echo 'FAIL: successful custom profile left a source rollback backup behind' >&2; exit 1;
}

rm -rf "$fallback_sources"
cp -a "$fixture/fallback-original" "$fallback_sources"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
: > "$JETSON_TEST_LOG"
export JETSON_TEST_APT_UPDATE_RESULTS=42,43,0
qemu_apt_update_with_fallback "$fallback_rootfs" "$profile_root" true
[[ "$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")" == 3 ]] || {
    echo 'FAIL: failed custom source profile did not fall through to the archive attempt' >&2; exit 1;
}
grep -Fq 'old-releases.ubuntu.com/ubuntu' "$fallback_sources/sources.list" || {
    echo 'FAIL: successful archive fallback was not retained after a failed custom attempt' >&2; exit 1;
}
[[ ! -e "$fallback_sources/sources.list.d/jetson-custom-profile-mirror.sources" ]] || {
    echo 'FAIL: failed custom profile remained after archive fallback succeeded' >&2; exit 1;
}

rm -rf "$fallback_sources"
cp -a "$fixture/fallback-original" "$fallback_sources"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
: > "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
export JETSON_TEST_APT_UPDATE_RESULTS=42,43
if qemu_apt_update_with_fallback "$fallback_rootfs" "$profile_root" false; then
    echo 'FAIL: unavailable baseline and archive sources were reported as successful' >&2; exit 1;
fi
[[ "$QEMU_APT_FAILED_STEP" == 'apt-get update' && "$QEMU_APT_EXIT_STATUS" -eq 43 ]] || {
    echo 'FAIL: final repository validation failure status was not recorded' >&2; exit 1;
}
diff -ru "$fixture/fallback-original" "$fallback_sources" >/dev/null || {
    echo 'FAIL: failed archive attempt did not restore original source files' >&2; exit 1;
}

rm -rf "$fallback_sources"
cp -a "$fixture/fallback-original" "$fallback_sources"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
export JETSON_TEST_APT_UPDATE_RESULTS=42,0
qemu_apt_update_with_fallback "$fallback_rootfs" "$fixture/empty-profiles" true
[[ "$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")" == 2 ]] || {
    echo 'FAIL: missing custom profile did not proceed to the archive candidate' >&2; exit 1;
}
[[ -z "$QEMU_APT_REPOSITORY_BACKUP_DIR" ]] || {
    echo 'FAIL: archive success without a custom profile left a source backup behind' >&2; exit 1;
}

rm -rf "$fallback_sources"
cp -a "$fixture/fallback-original" "$fallback_sources"
printf 'ID=myapt\nVERSION_CODENAME=stable\n' > "$fallback_rootfs/etc/os-release"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
export JETSON_TEST_APT_UPDATE_RESULTS=42
if qemu_apt_update_with_fallback "$fallback_rootfs" "$fixture/empty-profiles" false; then
    echo 'FAIL: non-Ubuntu/Debian source failure was reported as successful' >&2; exit 1;
fi
[[ "$(cat "$JETSON_TEST_APT_UPDATE_COUNT_FILE")" == 1 ]] || {
    echo 'FAIL: automatic source rewrite ran for an unsupported APT distribution' >&2; exit 1;
}
diff -ru "$fixture/fallback-original" "$fallback_sources" >/dev/null || {
    echo 'FAIL: unsupported APT distribution source files were changed' >&2; exit 1;
}

rm -rf "$fallback_sources"
cp -a "$fixture/fallback-original" "$fallback_sources"
printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$fallback_rootfs/etc/os-release"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
export JETSON_TEST_APT_UPDATE_RESULTS=42,55
if qemu_apt_update_with_fallback "$fallback_rootfs" "$fixture/empty-profiles" false; then
    echo 'FAIL: failure from the preserved NVIDIA source was ignored' >&2; exit 1;
fi
[[ "$QEMU_APT_EXIT_STATUS" -eq 55 ]] || {
    echo 'FAIL: final third-party repository failure status was not preserved' >&2; exit 1;
}
grep -Fq 'repo.download.nvidia.com/jetson/common' "$fallback_sources/sources.list" || {
    echo 'FAIL: failed fallback altered the NVIDIA source' >&2; exit 1;
}
diff -ru "$fixture/fallback-original" "$fallback_sources" >/dev/null || {
    echo 'FAIL: third-party failure did not restore original source files' >&2; exit 1;
}

qemu_apt_load_packages "$REPO_DIR/qemu-packages.txt"
[[ "${QEMU_APT_PACKAGES[*]}" == 'mc vim' ]] || {
    echo 'FAIL: default package list must install mc and vim' >&2; exit 1;
}

packages="$fixture/packages.txt"
cat > "$packages" <<'EOF'
# desired editor and tools
mc

vim # basic editor
EOF

qemu_apt_load_packages "$packages"
rm -f "$JETSON_TEST_APT_UPDATE_COUNT_FILE"
export JETSON_TEST_APT_UPDATE_RESULTS=0
: > "$JETSON_TEST_LOG"
qemu_apt_run_update_upgrade "$fixture/rootfs"
[[ "$(head -n 1 "$fixture/rootfs/usr/share/pam-configs/nv-power-adapter-check")" == 'Name: NVIDIA power adapter check' ]] || {
    echo 'FAIL: malformed leading comments were not removed from the NVIDIA PAM profile' >&2; exit 1;
}
[[ "$(grep -c 'apt-get' "$JETSON_TEST_LOG")" -eq 3 ]] || {
    echo 'FAIL: expected PAM profile preparation and apt update, upgrade, and install commands' >&2; exit 1;
}
grep -Fq 'pam-configs/nv-power-adapter-check' "$JETSON_TEST_LOG" || {
    echo 'FAIL: NVIDIA PAM profile preparation did not run before APT' >&2; exit 1;
}
grep -Fq 'apt-get -o APT::Update::Error-Mode=any update' "$JETSON_TEST_LOG" || { echo 'FAIL: strict apt update missing' >&2; exit 1; }
grep -Fq 'LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive apt-get -o APT::Update::Error-Mode=any update' "$JETSON_TEST_LOG" || { echo 'FAIL: APT update must use a generated locale-independent environment' >&2; exit 1; }
grep -Fq 'apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade' "$JETSON_TEST_LOG" || {
    echo 'FAIL: non-interactive apt upgrade missing' >&2; exit 1;
}
grep -Fq 'LANG=C LC_ALL=C LANGUAGE=C DEBIAN_FRONTEND=noninteractive apt-get -y' "$JETSON_TEST_LOG" || { echo 'FAIL: APT upgrade/install must use a generated locale-independent environment' >&2; exit 1; }
grep -Fq 'install mc vim' "$JETSON_TEST_LOG" || { echo 'FAIL: package list was not applied' >&2; exit 1; }

: > "$JETSON_TEST_LOG"
printf 'mc;touch /tmp/bad\n' > "$packages"
if qemu_apt_load_packages "$packages" >/dev/null 2>&1; then
    echo 'FAIL: invalid package name was accepted' >&2; exit 1
fi
[[ ! -s "$JETSON_TEST_LOG" ]] || { echo 'FAIL: apt ran with invalid package list' >&2; exit 1; }

printf 'PASS: package-list parsing and apt update/upgrade/install commands\n'

cat > "$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JETSON_TEST_LOG"
case "$*" in
    *"$JETSON_TEST_FAIL_MATCH"*) exit "${JETSON_TEST_FAIL_STATUS:-42}" ;;
esac
EOF
chmod +x "$fixture/bin/sudo"
printf 'mc vim\n' > "$packages"
qemu_apt_load_packages "$packages"
for failure_case in \
    'APT::Update::Error-Mode=any update|apt-get update|42' \
    'upgrade|apt-get upgrade|43' \
    'install mc vim|apt-get install|44'; do
    IFS='|' read -r JETSON_TEST_FAIL_MATCH expected_step expected_status <<< "$failure_case"
    export JETSON_TEST_FAIL_MATCH
    JETSON_TEST_FAIL_STATUS="$expected_status"
    export JETSON_TEST_FAIL_STATUS
    : > "$JETSON_TEST_LOG"
    if qemu_apt_run_update_upgrade "$fixture/rootfs"; then
        echo "FAIL: failed $expected_step was reported as successful" >&2; exit 1
    fi
    [[ "$QEMU_APT_FAILED_STEP" == "$expected_step" && "$QEMU_APT_EXIT_STATUS" -eq "$expected_status" ]] || {
        echo "FAIL: $expected_step failure and exit status were not recorded" >&2; exit 1;
    }
    if [[ "$expected_step" == 'apt-get update' ]]; then
        if grep -Eq 'apt-get .* (upgrade|install)( |$)' "$JETSON_TEST_LOG"; then
            echo 'FAIL: package upgrade/install ran after repository validation failed' >&2; exit 1;
        fi
    fi
done
