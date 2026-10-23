#!/usr/bin/env bash

jetson_calculate_total_steps() {
    local deploy="$1" has_target="$2" has_rootfs="$3"
    local apply_patches="$4" run_apt="$5" run_qemu="$6"
    local total=0

    [[ "$deploy" == true ]] && total=$((total + 5))
    if [[ "$has_target" == true ]]; then
        total=$((total + 1))
        [[ "$apply_patches" == true ]] && total=$((total + 1))
    fi
    [[ "$run_apt" == true ]] && total=$((total + 6))
    [[ "$run_qemu" == true ]] && total=$((total + 5))
    # Rootfs finalization always has release-fix, image-identity, and UART stages.
    [[ "$has_rootfs" == true ]] && total=$((total + 3))
    printf '%s\n' "$total"
}
