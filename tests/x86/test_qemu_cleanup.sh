#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
setup_script="$REPO_DIR/setup_jetson.sh"

apt_run_line="$(grep -nF 'qemu_apt_validate_repositories "$rootfs_path" "$PROJECT_DIR/apt-repositories" "$FORCE_CUSTOM_REPOSITORIES"' "$setup_script" | cut -d: -f1)"
apt_check_step_line="$(grep -nF 'update_step "Checking rootfs repository availability"' "$setup_script" | cut -d: -f1)"
apt_check_call_line="$(grep -nF 'qemu_apt_validate_repositories "$rootfs_path" "$PROJECT_DIR/apt-repositories" "$FORCE_CUSTOM_REPOSITORIES"' "$setup_script" | cut -d: -f1)"
apt_update_step_line="$(grep -nF 'update_step "Updating rootfs system packages"' "$setup_script" | cut -d: -f1)"
apt_update_call_line="$(grep -nF 'qemu_apt_upgrade_install "$rootfs_path"' "$setup_script" | cut -d: -f1)"
apt_cleanup_line="$(grep -nF 'cleanup_qemu_rootfs "$rootfs_path"' "$setup_script" | tail -n1 | cut -d: -f1)"
apt_status_line="$(grep -nE '^[[:space:]]+status=\$\?$' "$setup_script" | tail -n1 | cut -d: -f1)"
apt_cleanup_status_line="$(grep -nE '^[[:space:]]+cleanup_status=\$\?$' "$setup_script" | cut -d: -f1)"
if ! ((apt_run_line < apt_status_line && apt_status_line < apt_cleanup_line && \
       apt_cleanup_line < apt_cleanup_status_line)); then
    echo 'FAIL: APT stage must save its result and clean up mounts before returning' >&2
    exit 1
fi
if ! ((apt_check_step_line < apt_check_call_line && apt_check_call_line < apt_update_step_line && \
       apt_update_step_line < apt_update_call_line && apt_update_call_line < apt_cleanup_line)); then
    echo 'FAIL: repository validation must be a visible step before package updates' >&2
    exit 1
fi

grep -Fq 'trap '\''qemu_handle_signal INT 130'\'' INT' "$setup_script" || {
    echo 'FAIL: SIGINT must trigger QEMU mount cleanup' >&2; exit 1;
}
grep -Fq 'trap '\''qemu_handle_signal TERM 143'\'' TERM' "$setup_script" || {
    echo 'FAIL: SIGTERM must trigger QEMU mount cleanup' >&2; exit 1;
}
grep -Fq 'cleanup_qemu_rootfs "$QEMU_ROOTFS_ACTIVE"' "$setup_script" || {
    echo 'FAIL: signal handler must unmount the active rootfs' >&2; exit 1;
}
grep -Fq 'QEMU_ROOTFS_ACTIVE=""' "$setup_script" || {
    echo 'FAIL: cleanup must clear the active rootfs state' >&2; exit 1;
}
grep -Fq 'update_step "Preparing QEMU rootfs"' "$setup_script" || {
    echo 'FAIL: QEMU rootfs preparation must be a numbered step' >&2; exit 1;
}
grep -Fq 'update_step "Mounting QEMU rootfs resources"' "$setup_script" || {
    echo 'FAIL: QEMU mounts must be a numbered step' >&2; exit 1;
}
grep -Fq 'update_step "Unmounting QEMU rootfs resources"' "$setup_script" || {
    echo 'FAIL: QEMU unmounts must be a numbered step' >&2; exit 1;
}
grep -Fq 'local cleanup_status' "$setup_script" || {
    echo 'FAIL: cleanup result must be checked after the APT operation' >&2; exit 1;
}
grep -Fq 'trap setup_jetson_exit_cleanup EXIT' "$setup_script" || {
    echo 'FAIL: setup_jetson.sh must clean managed mounts on every exit' >&2; exit 1;
}
grep -Fq 'Warning: unmounting QEMU resource at $mount_path during cleanup.' "$setup_script" || {
    echo 'FAIL: QEMU unmounts must be explicitly reported' >&2; exit 1;
}
grep -Fq 'l4t_cleanup_bootloader_mount "$TARGET_DIR/bootloader"' "$setup_script" || {
    echo 'FAIL: setup_jetson.sh must clean a stale BSP loop mount on exit' >&2; exit 1;
}

printf 'PASS: QEMU APT cleanup runs on normal return and termination signals\n'

fixture="$(mktemp -d /tmp/jetson-qemu-signal.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/rootfs/etc" "$fixture/deploy"
touch "$fixture/rootfs/etc/resolv.conf.bak"
cat > "$fixture/signal-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -u
source "$QEMU_TEST_REPO/lib/qemu_session.sh"
rootfs="$QEMU_TEST_ROOTFS"
confirm() { return 0; }
cleanup_qemu_rootfs() { rm -f "$rootfs/etc/resolv.conf.bak"; }
qemu_session_begin "$QEMU_TEST_LOCK" "$rootfs" true false
held=true
handle_hup() {
    cleanup_qemu_rootfs "$rootfs"
    qemu_session_end true
    exit 129
}
trap handle_hup HUP
qemu_session_set_phase interactive-chroot
printf 'READY\n' > "$QEMU_TEST_READY"
sleep 30
HARNESS
chmod +x "$fixture/signal-harness.sh"
export QEMU_TEST_REPO="$REPO_DIR"
export QEMU_TEST_ROOTFS="$fixture/rootfs"
export QEMU_TEST_LOCK="$fixture/deploy/session.lock"
export QEMU_TEST_READY="$fixture/ready"
setsid "$fixture/signal-harness.sh" &
signal_pid=$!
for _ in {1..100}; do [[ -f "$QEMU_TEST_READY" ]] && break; sleep 0.02; done
[[ -f "$QEMU_TEST_READY" ]] || { echo 'FAIL: signal harness did not start' >&2; exit 1; }
kill -HUP -- "-$signal_pid"
set +e
wait "$signal_pid" 2>"$fixture/wait.stderr"
signal_status=$?
set -e
[[ "$signal_status" -eq 129 ]] || { echo 'FAIL: HUP did not return its conventional status' >&2; exit 1; }
[[ ! -e "$fixture/rootfs/etc/resolv.conf.bak" ]] || { echo 'FAIL: HUP left resolver cleanup state behind' >&2; exit 1; }
[[ ! -e "$QEMU_TEST_LOCK.meta" ]] || { echo 'FAIL: HUP left stale session metadata' >&2; exit 1; }
exec 9>"$QEMU_TEST_LOCK"
flock -n 9 || { echo 'FAIL: HUP left the session lock held' >&2; exit 1; }
exec 9>&-
printf 'PASS: handled HUP cleans rootfs state and releases the session lock\n'
