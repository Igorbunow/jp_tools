#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/lib/progress.sh"

[[ "$(jetson_calculate_total_steps true true true true true true)" == 16 ]]
[[ "$(jetson_calculate_total_steps false true true true false true)" == 7 ]]
[[ "$(jetson_calculate_total_steps false true true true true false)" == 7 ]]
[[ "$(jetson_calculate_total_steps false false false false false false)" == 0 ]]
printf 'PASS: progress totals match selected setup stages\n'
