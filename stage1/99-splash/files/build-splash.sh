#!/bin/bash
# Cross-compile splash init for aarch64
# Usage: ./build-splash.sh [output_path]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-${SCRIPT_DIR}/splash-init}"

aarch64-linux-gnu-gcc -static -Os -nostartfiles -e main \
    -o "$OUTPUT" \
    "$SCRIPT_DIR/splash.c" \
    -lc

# Strip for minimum size
aarch64-linux-gnu-strip "$OUTPUT"

SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")
echo "Built: $OUTPUT ($SIZE bytes)"
