#!/usr/bin/env bash

# Update a terminal tab/window title while a long-running Jetson tool is active.
TERMINAL_STATUS_PID=""

terminal_status_is_enabled() {
    [[ -t 2 && -w /dev/tty ]]
}

terminal_status_write_title() {
    local title="$1"
    # Do not allow user-controlled text to inject additional terminal controls.
    title="${title//$'\033'/}"
    title="${title//$'\007'/}"
    title="${title//$'\r'/ }"
    title="${title//$'\n'/ }"
    printf '\033]0;%s\007' "$title" > /dev/tty
}

terminal_status_animation_loop() {
    local label="$1"
    local frames=('|' '/' '-' $'\\')
    local frame_index=0
    local ticker_pid=""

    trap 'if [[ -n "$ticker_pid" ]]; then kill "$ticker_pid" 2>/dev/null || true; wait "$ticker_pid" 2>/dev/null || true; fi; exit 0' TERM INT
    while :; do
        terminal_status_write_title "${frames[$frame_index]} $label"
        frame_index=$(((frame_index + 1) % ${#frames[@]}))
        sleep 0.45 &
        ticker_pid=$!
        wait "$ticker_pid" || break
        ticker_pid=""
    done
}

terminal_status_start() {
    local label="$1"
    [[ -z "$TERMINAL_STATUS_PID" ]] || return 0
    terminal_status_is_enabled || return 0
    TERMINAL_STATUS_LABEL="$label"
    terminal_status_animation_loop "$label" </dev/null >/dev/null 2>&1 &
    TERMINAL_STATUS_PID=$!
}

terminal_status_finish() {
    local exit_status="${1:-0}"
    local marker="OK"
    if [[ -n "$TERMINAL_STATUS_PID" ]]; then
        kill "$TERMINAL_STATUS_PID" 2>/dev/null || true
        wait "$TERMINAL_STATUS_PID" 2>/dev/null || true
        TERMINAL_STATUS_PID=""
    fi
    terminal_status_is_enabled || return 0
    ((exit_status == 0)) || marker="X"
    terminal_status_write_title "$marker ${TERMINAL_STATUS_LABEL:-Jetson tool}"
}
