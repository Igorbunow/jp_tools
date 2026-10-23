#!/usr/bin/env bash

QEMU_SESSION_FD=""
QEMU_SESSION_LOCK=""
QEMU_SESSION_META=""
QEMU_SESSION_ROOTFS=""

qemu_session_artifacts_exist() {
    local rootfs="$1" mount_path
    for mount_path in "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/dev/pts"; do
        if sudo mountpoint -q "$mount_path" 2>/dev/null; then return 0; fi
    done
    [[ -e "$rootfs/etc/resolv.conf.bak" || -L "$rootfs/etc/resolv.conf.bak" || -e "$rootfs/etc/resolv.conf.bak.missing" ]]
}

qemu_session_write_meta() {
    local phase="$1" temp="${QEMU_SESSION_META}.tmp.$$"
    { printf 'pid=%s\n' "$BASHPID"; printf 'rootfs=%s\n' "$QEMU_SESSION_ROOTFS"; printf 'phase=%s\n' "$phase"; } > "$temp" || return 1
    mv -f -- "$temp" "$QEMU_SESSION_META"
}

qemu_session_collect_tree() {
    local pid="$1" child
    printf '%s\n' "$pid"
    while read -r child; do
        [[ "$child" =~ ^[0-9]+$ ]] || continue
        qemu_session_collect_tree "$child"
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null)
}

qemu_session_signal_pid() {
    local signal="$1" pid="$2"
    kill -"$signal" "$pid" 2>/dev/null || sudo kill -"$signal" "$pid" 2>/dev/null || true
}

qemu_session_wait_tree() {
    local pids_name="$1" max_checks="$2" pid state alive
    local -n pids_ref="$pids_name"
    local check
    for ((check=0; check<max_checks; check++)); do
        alive=false
        for pid in "${pids_ref[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
                [[ "$state" == Z* ]] || alive=true
            fi
        done
        [[ "$alive" == false ]] && return 0
        sleep 0.1
    done
    return 1
}

qemu_session_terminate_tree() {
    local root_pid="$1" descendant
    local -a tree=() descendants=()
    mapfile -t tree < <(qemu_session_collect_tree "$root_pid" | awk '!seen[$0]++')
    descendants=("${tree[@]:1}")
    for descendant in "${descendants[@]}"; do qemu_session_signal_pid HUP "$descendant"; done
    sleep 0.2
    for descendant in "${tree[@]}"; do qemu_session_signal_pid TERM "$descendant"; done
    if qemu_session_wait_tree tree 30; then return 0; fi
    for descendant in "${tree[@]}"; do qemu_session_signal_pid KILL "$descendant"; done
    qemu_session_wait_tree tree 20
}

qemu_session_kill_owner() {
    local meta="$1" expected_rootfs="$2" pid owner_args recorded_rootfs
    recorded_rootfs="$(sed -n 's/^rootfs=//p' "$meta" | head -n1)"
    [[ "$recorded_rootfs" == "$expected_rootfs" ]] || { printf 'Refusing session PID from a different rootfs: %s\n' "$recorded_rootfs" >&2; return 1; }
    pid="$(sed -n 's/^pid=//p' "$meta" | head -n1)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || { printf 'Refusing unsafe QEMU session PID in %s\n' "$meta" >&2; return 1; }
    kill -0 "$pid" 2>/dev/null || return 0
    owner_args="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$owner_args" == *setup_jetson.sh* || "$owner_args" == *setup_qemu_session_test* ]] || { printf 'Refusing to terminate PID %s: it is not a recognized setup process\n' "$pid" >&2; return 1; }
    qemu_session_terminate_tree "$pid"
}

qemu_session_legacy_pids() {
    local rootfs="$1" pid args
    while read -r pid args; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$args" == *chroot*"$rootfs"* ]] || continue
        [[ "$args" == *sudo* || "$args" == *chroot* ]] || continue
        printf '%s\n' "$pid"
    done < <(ps -eo pid=,args=)
}

qemu_session_kill_legacy() {
    local rootfs="$1" pid args
    local -a roots=() tree=()
    mapfile -t roots < <(qemu_session_legacy_pids "$rootfs")
    for pid in "${roots[@]}"; do
        args="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
        [[ "$args" == *chroot*"$rootfs"* ]] || continue
        qemu_session_terminate_tree "$pid" || return 1
    done
}

qemu_session_recover() {
    local rootfs="$1" interactive="$2" force="$3" meta="$4"
    local has_legacy=false
    local -a legacy_pids=()
    mapfile -t legacy_pids < <(qemu_session_legacy_pids "$rootfs")
    ((${#legacy_pids[@]})) && has_legacy=true
    local prompt='A previous QEMU session is still active or left cleanup artifacts. Terminate it and clean the rootfs?'
    if [[ "$interactive" == true ]]; then
        confirm "$prompt" || { printf 'QEMU session recovery was declined.\n' >&2; return 1; }
    elif [[ "$force" == true ]]; then
        printf 'Force-recovering a previous QEMU session.\n' >&2
    else
        printf 'A previous QEMU session is active or incomplete. Re-run with --force-qemu-cleanup to recover in batch mode.\n' >&2
        return 1
    fi
    if [[ -s "$meta" ]]; then qemu_session_kill_owner "$meta" "$rootfs" || return 1; fi
    if [[ "$has_legacy" == true ]]; then qemu_session_kill_legacy "$rootfs" || return 1; fi
    if declare -F cleanup_qemu_rootfs >/dev/null; then cleanup_qemu_rootfs "$rootfs" || return 1; fi
}

qemu_session_begin() {
    local lock_file="$1" rootfs="$2" interactive="$3" force="$4"
    local meta="${lock_file}.meta"
    local -a legacy_pids=()
    mkdir -p -- "$(dirname -- "$lock_file")" || return 1
    QEMU_SESSION_LOCK="$lock_file"
    QEMU_SESSION_META="$meta"
    QEMU_SESSION_ROOTFS="$rootfs"
    exec {QEMU_SESSION_FD}>"$lock_file" || return 1
    mapfile -t legacy_pids < <(qemu_session_legacy_pids "$rootfs")
    if ! flock -n "$QEMU_SESSION_FD"; then
        qemu_session_recover "$rootfs" "$interactive" "$force" "$meta" || { exec {QEMU_SESSION_FD}>&-; QEMU_SESSION_FD=""; return 1; }
        for _ in {1..50}; do
            flock -n "$QEMU_SESSION_FD" && break
            sleep 0.1
        done
        flock -n "$QEMU_SESSION_FD" || { printf 'Could not acquire QEMU session lock after recovery.\n' >&2; exec {QEMU_SESSION_FD}>&-; QEMU_SESSION_FD=""; return 1; }
    elif qemu_session_artifacts_exist "$rootfs" || ((${#legacy_pids[@]})); then
        qemu_session_recover "$rootfs" "$interactive" "$force" "$meta" || { exec {QEMU_SESSION_FD}>&-; QEMU_SESSION_FD=""; return 1; }
    elif [[ -s "$meta" ]]; then
        # An unlocked metadata file means its owner exited without finalizing.
        qemu_session_recover "$rootfs" "$interactive" "$force" "$meta" || { exec {QEMU_SESSION_FD}>&-; QEMU_SESSION_FD=""; return 1; }
    fi
    qemu_session_write_meta "starting" || { exec {QEMU_SESSION_FD}>&-; QEMU_SESSION_FD=""; return 1; }
}

qemu_session_set_phase() {
    [[ -n "$QEMU_SESSION_FD" ]] || return 1
    qemu_session_write_meta "$1"
}

qemu_session_end() {
    local clean="$1"
    if [[ "$clean" == true ]]; then rm -f -- "$QEMU_SESSION_META"; fi
    if [[ -n "$QEMU_SESSION_FD" ]]; then
        flock -u "$QEMU_SESSION_FD" 2>/dev/null || true
        exec {QEMU_SESSION_FD}>&-
    fi
    QEMU_SESSION_FD=""
    [[ "$clean" == true ]]
}
