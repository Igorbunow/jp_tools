#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/terminal_status.sh"

output_file="$(mktemp)"
trap 'terminal_status_finish 0 >/dev/null 2>&1 || true; rm -f -- "$output_file"' EXIT
TERMINAL_STATUS_TEST_OUTPUT="$output_file"
terminal_status_is_enabled() { return 0; }
terminal_status_write_title() { printf '%s\n' "$1" >> "$TERMINAL_STATUS_TEST_OUTPUT"; }

terminal_status_start 'Setup Jetson'
pid="$TERMINAL_STATUS_PID"
sleep 0.28
kill -0 "$pid"
terminal_status_finish 1
! kill -0 "$pid" 2>/dev/null
grep -Eq '^[|/\\-] Setup Jetson$' "$output_file"
tail -n 1 "$output_file" | grep -Fq 'X Setup Jetson'

: > "$output_file"
terminal_status_start 'Flash Jetson'
sleep 0.12
pid="$TERMINAL_STATUS_PID"
terminal_status_finish 0
! kill -0 "$pid" 2>/dev/null
tail -n 1 "$output_file" | grep -Fq 'OK Flash Jetson'

: > "$output_file"
terminal_status_is_enabled() { return 1; }
terminal_status_start 'Non-interactive run'
[[ -z "$TERMINAL_STATUS_PID" ]]
terminal_status_finish 1
[[ ! -s "$output_file" ]]

for script in "$REPO_DIR/setup_jetson.sh" "$REPO_DIR/b_conf/flash_jetson.sh"; do
    grep -Fq 'source "$PROJECT_DIR/lib/terminal_status.sh"' "$script" 2>/dev/null ||
        grep -Fq 'source "$REPO_DIR/lib/terminal_status.sh"' "$script"
    grep -Eq 'terminal_status_start ' "$script"
    grep -Eq 'terminal_status_finish "?\$exit_status"?' "$script"
done
printf 'PASS: terminal title animation ends with success or failure status and both tools install it\n'
