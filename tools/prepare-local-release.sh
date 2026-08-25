#!/bin/bash
# Prepare an already-built CardputerZero image for local/manual distribution.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY_DIR="${DEPLOY_DIR:-$ROOT/deploy}"
RELEASE_DATE="${RELEASE_DATE:-$(date +%Y-%m-%d)}"
SOURCE_IMAGE="${SOURCE_IMAGE:-$DEPLOY_DIR/cardputerzero-trixie-arm64.img.xz}"
RAW_IMAGE="${RAW_IMAGE:-${SOURCE_IMAGE%.xz}}"
RELEASE_ROOT="${RELEASE_ROOT:-$ROOT/../build-artifacts/local-releases}"
RELEASE_NAME="${RELEASE_DATE}-cardputerzero-trixie-arm64"
RELEASE_DIR="$RELEASE_ROOT/$RELEASE_NAME"
RELEASE_IMAGE="$RELEASE_DIR/$RELEASE_NAME.img.xz"
INFO_FILE="${INFO_FILE:-$DEPLOY_DIR/cardputerzero-trixie-arm64.info}"
IMAGE_DERIVATION="${IMAGE_DERIVATION:-full-build}"

usage() {
    cat <<'EOF'
Usage: [environment variables] tools/prepare-local-release.sh

Environment:
  SOURCE_IMAGE     Input .img.xz file.
  RAW_IMAGE        Matching uncompressed .img used for verification.
  RELEASE_DATE     YYYY-MM-DD, defaults to today.
  RELEASE_ROOT     Parent output directory.
  IMAGE_DERIVATION Provenance label, defaults to full-build.
  VERIFY_IMAGE=0   Skip image verification (not recommended).
  EXPECTED_DTOVERLAYS_COMMIT / APPLAUNCH_VERSION
EOF
}

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    usage >&2
    exit 2
fi

[[ "$RELEASE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    echo "ERROR: RELEASE_DATE must use YYYY-MM-DD" >&2
    exit 2
}
test -f "$SOURCE_IMAGE"
xz -t "$SOURCE_IMAGE"

mkdir -p "$RELEASE_DIR"

if [ "${VERIFY_IMAGE:-1}" = "1" ]; then
    test -f "$RAW_IMAGE" || {
        echo "ERROR: raw image is required for verification: $RAW_IMAGE" >&2
        echo "Run: xz -dk '$SOURCE_IMAGE'" >&2
        exit 1
    }
    sudo env \
        VERIFY_PROFILE=full \
        EXPECTED_DTOVERLAYS_COMMIT="${EXPECTED_DTOVERLAYS_COMMIT:-}" \
        APPLAUNCH_VERSION="${APPLAUNCH_VERSION:-}" \
        "$ROOT/tools/verify-image.sh" "$RAW_IMAGE" 2>&1 |
        tee "$RELEASE_DIR/full-image-verification.log"
fi

if [ ! -e "$RELEASE_IMAGE" ]; then
    ln "$SOURCE_IMAGE" "$RELEASE_IMAGE" 2>/dev/null ||
        cp --reflink=auto "$SOURCE_IMAGE" "$RELEASE_IMAGE"
fi

if [ -f "$INFO_FILE" ]; then
    cp "$INFO_FILE" "$RELEASE_DIR/$RELEASE_NAME.info"
fi

(
    cd "$RELEASE_DIR"
    sha256sum "$RELEASE_NAME.img.xz" > "$RELEASE_NAME.img.xz.sha256"
    sha256sum -c "$RELEASE_NAME.img.xz.sha256"
)

IMAGE_SHA256=$(sha256sum "$RELEASE_IMAGE" | awk '{print $1}')
PI_GEN_HEAD=$(git -C "$ROOT" rev-parse HEAD)
PI_GEN_BRANCH=$(git -C "$ROOT" branch --show-current)
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    PI_GEN_WORKTREE=dirty
else
    PI_GEN_WORKTREE=clean
fi
KERNEL_VERSION=""
if [ -f "$INFO_FILE" ]; then
    KERNEL_VERSION=$(awk '$2 == "linux-image-rpi-v8" { print $3; exit }' "$INFO_FILE")
fi

export IMAGE_SHA256 PI_GEN_HEAD PI_GEN_BRANCH PI_GEN_WORKTREE KERNEL_VERSION
export IMAGE_DERIVATION
export RELEASE_NAME
python3 - "$RELEASE_DIR/build-info.json" <<'PY'
import json
import os
import sys

data = {
    "pigen_commit": os.environ["PI_GEN_HEAD"],
    "pigen_branch": os.environ["PI_GEN_BRANCH"],
    "pigen_worktree": os.environ["PI_GEN_WORKTREE"],
    "launcher_version": os.environ.get("APPLAUNCH_VERSION", ""),
    "kernel_version": os.environ.get("KERNEL_VERSION", ""),
    "driver_commit": os.environ.get("EXPECTED_DTOVERLAYS_COMMIT", ""),
    "image_name": f'{os.environ["RELEASE_NAME"]}.img.xz',
    "image_sha256": os.environ["IMAGE_SHA256"],
    "image_derivation": os.environ["IMAGE_DERIVATION"],
    "release_channel": "local",
    "verify_profile": "full",
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY

{
    echo "release_name=$RELEASE_NAME"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "image_sha256=$IMAGE_SHA256"
    echo "image_derivation=$IMAGE_DERIVATION"
    echo "pi_gen_head=$PI_GEN_HEAD"
    echo "pi_gen_branch=$PI_GEN_BRANCH"
    echo "pi_gen_worktree=$PI_GEN_WORKTREE"
    echo "dtoverlays_commit=${EXPECTED_DTOVERLAYS_COMMIT:-not-enforced}"
    echo "applaunch_version=${APPLAUNCH_VERSION:-automatic}"
} > "$RELEASE_DIR/release-manifest.txt"

echo "Local release prepared: $RELEASE_DIR"
find "$RELEASE_DIR" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | sort
echo "Flash: $RELEASE_IMAGE"
