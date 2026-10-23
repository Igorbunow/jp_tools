#!/bin/bash

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    cat <<'EOF'
Usage: ./cleanup.sh

Reverts tracked changes and removes temporary ramdisk build artifacts from
Linux_for_Tegra in the current directory.

Environment variables: none.
EOF
    exit 0
fi

echo "Cleaning up temporary build artifacts..."

# Clean Linux_for_Tegra directory using git if it exists
if [ -d "Linux_for_Tegra/.git" ]; then
    echo "Reverting changes in Linux_for_Tegra via git..."
    git -C Linux_for_Tegra clean -fd
    git -C Linux_for_Tegra checkout .
else
    echo "Linux_for_Tegra/.git not found; preserving BSP firmware and generated images."
fi

# General cleanup
rm -rf Linux_for_Tegra/bootloader/ramdisk_tmp

echo "Cleanup completed."
