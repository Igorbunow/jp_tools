#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

matches="$(rg -n -P '[\x{0400}-\x{04FF}]' --glob '*.sh' "$REPO_DIR" || true)"
if [[ -n "$matches" ]]; then
    printf 'FAIL: shell scripts contain Cyrillic text:\n%s\n' "$matches" >&2
    exit 1
fi

printf 'PASS: shell scripts contain no Cyrillic text.\n'
