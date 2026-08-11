#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "ERROR: build-local-image.sh line $LINENO: $BASH_COMMAND (exit $rc)" >&2' ERR

PIGEN=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKSPACE=$(CDPATH= cd -- "$PIGEN/.." && pwd)
LAUNCHER=${LAUNCHER_DIR:-"$WORKSPACE/launcher"}
DTO=${DTOVERLAYS_SOURCE_DIR:-"$WORKSPACE/m5stack-linux-dtoverlays"}
ARTIFACTS=${ARTIFACTS_DIR:-"$WORKSPACE/build-artifacts"}
BUILD_DATE=${BUILD_DATE:-$(date +%Y-%m-%d)}
IMAGE_BASENAME=${IMAGE_BASENAME:-"$BUILD_DATE-cardputerzero-trixie-arm64-local"}
CONFIG_FILE="$ARTIFACTS/one-click/$IMAGE_BASENAME.config"
INPUTS_FILE="$ARTIFACTS/one-click/$IMAGE_BASENAME.build-inputs"
LAUNCHER_OUTPUT=${LAUNCHER_OUTPUT_DIR:-"$ARTIFACTS/launcher-release"}
SCONS=${SCONS:-/home/m5stack/.venvs/cardputerzero-build/bin/scons}
JOBS=${JOBS:-$(nproc)}
SUDO=${SUDO:-sudo}

usage() {
    cat <<'EOF'
Usage: tools/build-local-image.sh

Builds the complete APPLaunch package, a fresh pi-gen image, full offline
verification, and SHA-256 metadata. No environment variables are required.

Optional environment:
  SKIP_LAUNCHER_BUILD=1       Reuse APPLAUNCH_SOURCE_FILE or the last package.
  APPLAUNCH_SOURCE_FILE=PATH  Use this host-side applaunch arm64 .deb.
  RECORDER_SOURCE_FILE=PATH   Use this host-side Recorder arm64 .deb.
  IMAGE_BASENAME=NAME         Override the deploy filename stem.
  KEEP_RAW_IMAGE=1            Keep the uncompressed .img after verification.
  SCONS=PATH, JOBS=N          Override the launcher build tools.
  DTOVERLAYS_SOURCE_DIR=PATH  Override the host dtoverlays source repository.
  CONTINUE=1                  Resume an existing pi-gen Docker container.
  PREPARE_ONLY=1              Validate inputs and write manifests, then stop.
EOF
}

if [ "${1:-}" = --help ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    usage >&2
    exit 2
fi

for command in git docker dpkg-deb sha256sum xz python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $command" >&2
        exit 1
    }
done
for repo in "$PIGEN" "$LAUNCHER" "$DTO"; do
    git -C "$repo" rev-parse --verify HEAD >/dev/null
    if git -C "$repo" diff --name-only --diff-filter=U | grep -q .; then
        echo "ERROR: unresolved Git conflict in $repo" >&2
        exit 1
    fi
done
while IFS= read -r submodule_line; do
    marker=${submodule_line:0:1}
    read -r _submodule_commit submodule_path _submodule_tail <<<"${submodule_line:1}"
    case "$marker" in
        -|U)
            echo "ERROR: launcher submodule is unavailable or conflicted: $submodule_path" >&2
            exit 1
            ;;
        +)
            if [ "$submodule_path" != SDK ]; then
                echo "ERROR: unexpected launcher submodule mismatch: $submodule_path" >&2
                exit 1
            fi
            echo "Using local launcher/SDK commit outside the parent gitlink: $_submodule_commit"
            ;;
    esac
done < <(git -C "$LAUNCHER" submodule status --recursive)

SDK="$LAUNCHER/SDK"
git -C "$SDK" rev-parse --verify HEAD >/dev/null
if git -C "$SDK" diff --name-only --diff-filter=U | grep -q .; then
    echo "ERROR: unresolved Git conflict in $SDK" >&2
    exit 1
fi

free_bytes=$(df -PB1 "$WORKSPACE" | awk 'NR == 2 {print $4}')
minimum_bytes=$((30 * 1024 * 1024 * 1024))
if [ "$free_bytes" -lt "$minimum_bytes" ]; then
    echo "ERROR: at least 30 GiB free space is required for a full image build" >&2
    exit 1
fi
docker ps >/dev/null
$SUDO -v

mkdir -p "$ARTIFACTS/one-click" "$LAUNCHER_OUTPUT" \
    "$PIGEN/local-packages" "$PIGEN/local-sources"

if [ "${SKIP_LAUNCHER_BUILD:-0}" != 1 ]; then
    SCONS="$SCONS" JOBS="$JOBS" OUTPUT_DIR="$LAUNCHER_OUTPUT" \
        "$LAUNCHER/scripts/build_cardputerzero_release_local.sh"
fi

APPLAUNCH_SOURCE_FILE=${APPLAUNCH_SOURCE_FILE:-}
if [ -z "$APPLAUNCH_SOURCE_FILE" ]; then
    pointer="$LAUNCHER_OUTPUT/applaunch-package.path"
    test -f "$pointer" || {
        echo "ERROR: no launcher package result found: $pointer" >&2
        exit 1
    }
    APPLAUNCH_SOURCE_FILE=$(sed -n '1p' "$pointer")
fi
test -f "$APPLAUNCH_SOURCE_FILE"
test "$(dpkg-deb -f "$APPLAUNCH_SOURCE_FILE" Package)" = applaunch
test "$(dpkg-deb -f "$APPLAUNCH_SOURCE_FILE" Architecture)" = arm64
APPLAUNCH_VERSION=$(dpkg-deb -f "$APPLAUNCH_SOURCE_FILE" Version)
APPLAUNCH_SHA256=$(sha256sum "$APPLAUNCH_SOURCE_FILE" | awk '{print $1}')
STAGED_APPLAUNCH="$PIGEN/local-packages/applaunch-one-click-arm64.deb"
install -m 0644 "$APPLAUNCH_SOURCE_FILE" "$STAGED_APPLAUNCH"

RECORDER_SOURCE_FILE=${RECORDER_SOURCE_FILE:-}
if [ -z "$RECORDER_SOURCE_FILE" ]; then
    RECORDER_SOURCE_FILE=$(find "$PIGEN/local-packages" -maxdepth 1 -type f \
        -name 'm5cardputerzero-recorder_*_arm64.deb' -print | sort -V | tail -1)
fi
test -n "$RECORDER_SOURCE_FILE"
test -f "$RECORDER_SOURCE_FILE"
test "$(dpkg-deb -f "$RECORDER_SOURCE_FILE" Package)" = m5cardputerzero-recorder
test "$(dpkg-deb -f "$RECORDER_SOURCE_FILE" Architecture)" = arm64
RECORDER_VERSION=$(dpkg-deb -f "$RECORDER_SOURCE_FILE" Version)
RECORDER_SHA256=$(sha256sum "$RECORDER_SOURCE_FILE" | awk '{print $1}')
STAGED_RECORDER="$PIGEN/local-packages/recorder-one-click-arm64.deb"
if [ "$RECORDER_SOURCE_FILE" != "$STAGED_RECORDER" ]; then
    install -m 0644 "$RECORDER_SOURCE_FILE" "$STAGED_RECORDER"
fi

worktree_fingerprint() {
    repo=$1
    {
        git -C "$repo" diff --binary HEAD
        git -C "$repo" ls-files --others --exclude-standard -z |
            LC_ALL=C sort -z |
            while IFS= read -r -d '' file; do
                sha256sum -- "$repo/$file"
            done
    } | sha256sum | awk '{print $1}'
}

DTOVERLAYS_REF=${DTOVERLAYS_REF:-$(git -C "$DTO" rev-parse HEAD)}
[[ "$DTOVERLAYS_REF" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: DTOVERLAYS_REF must be a 40-character commit" >&2
    exit 1
}
git -C "$DTO" cat-file -e "$DTOVERLAYS_REF^{commit}"
DTO_ARCHIVE_NAME="m5stack-linux-dtoverlays-$DTOVERLAYS_REF.tar.gz"
DTO_ARCHIVE_HOST="$PIGEN/local-sources/$DTO_ARCHIVE_NAME"
DTO_ARCHIVE_TMP="$DTO_ARCHIVE_HOST.tmp"
DTO_WORKTREE_SHA256=$(worktree_fingerprint "$DTO")
DTO_SNAPSHOT_INCLUDES_WORKTREE=0
if [ -z "$(git -C "$DTO" status --porcelain --untracked-files=normal)" ]; then
    git -C "$DTO" archive --format=tar.gz \
        --prefix="m5stack-linux-dtoverlays-$DTOVERLAYS_REF/" \
        -o "$DTO_ARCHIVE_TMP" "$DTOVERLAYS_REF"
else
    DTO_SNAPSHOT_INCLUDES_WORKTREE=1
    DTO_SNAPSHOT_ROOT=$(mktemp -d "$ARTIFACTS/one-click/dto-snapshot.XXXXXX")
    DTO_SNAPSHOT_NAME="m5stack-linux-dtoverlays-$DTOVERLAYS_REF"
    DTO_SNAPSHOT_DIR="$DTO_SNAPSHOT_ROOT/$DTO_SNAPSHOT_NAME"
    DTO_PATCH="$DTO_SNAPSHOT_ROOT/worktree.patch"
    mkdir -p "$DTO_SNAPSHOT_DIR"
    git -C "$DTO" archive --format=tar "$DTOVERLAYS_REF" |
        tar -xf - -C "$DTO_SNAPSHOT_DIR"
    git -C "$DTO" diff --binary "$DTOVERLAYS_REF" -- >"$DTO_PATCH"
    if [ -s "$DTO_PATCH" ]; then
        (cd "$DTO_SNAPSHOT_DIR" && git apply --binary --whitespace=nowarn "$DTO_PATCH")
    fi
    while IFS= read -r -d '' file; do
        target="$DTO_SNAPSHOT_DIR/$file"
        mkdir -p "$(dirname "$target")"
        cp -a -- "$DTO/$file" "$target"
    done < <(git -C "$DTO" ls-files --others --exclude-standard -z)
    DTO_SOURCE_EPOCH=$(git -C "$DTO" show -s --format=%ct "$DTOVERLAYS_REF")
    tar --sort=name --mtime="@$DTO_SOURCE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$DTO_SNAPSHOT_ROOT" -cf - "$DTO_SNAPSHOT_NAME" |
        gzip -n >"$DTO_ARCHIVE_TMP"
    rm -rf -- "$DTO_SNAPSHOT_ROOT"
fi
mv -f "$DTO_ARCHIVE_TMP" "$DTO_ARCHIVE_HOST"
DTO_ARCHIVE_SHA256=$(sha256sum "$DTO_ARCHIVE_HOST" | awk '{print $1}')

cat >"$CONFIG_FILE" <<EOF
IMG_NAME=cardputerzero-trixie-arm64
IMG_FILENAME=$IMAGE_BASENAME
ARCHIVE_FILENAME=$IMAGE_BASENAME
RELEASE=trixie
DEPLOY_COMPRESSION=xz
TARGET_HOSTNAME=cardputerzero
FIRST_USER_NAME=pi
FIRST_USER_PASS=raspberry
DISABLE_FIRST_BOOT_USER_RENAME=1
ENABLE_SSH=1
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
KEYBOARD_LAYOUT="English (US)"
TIMEZONE_DEFAULT=Asia/Shanghai
STAGE_LIST="stage0 stage1 stage2 stage3 stage4"
EOF

cat >"$INPUTS_FILE" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
pi_gen_head=$(git -C "$PIGEN" rev-parse HEAD)
pi_gen_worktree_sha256=$(worktree_fingerprint "$PIGEN")
launcher_head=$(git -C "$LAUNCHER" rev-parse HEAD)
launcher_worktree_sha256=$(worktree_fingerprint "$LAUNCHER")
launcher_sdk_head=$(git -C "$SDK" rev-parse HEAD)
launcher_sdk_worktree_sha256=$(worktree_fingerprint "$SDK")
dtoverlays_head=$(git -C "$DTO" rev-parse HEAD)
dtoverlays_worktree_sha256=$DTO_WORKTREE_SHA256
dtoverlays_build_ref=$DTOVERLAYS_REF
dtoverlays_snapshot_includes_worktree=$DTO_SNAPSHOT_INCLUDES_WORKTREE
dtoverlays_archive_sha256=$DTO_ARCHIVE_SHA256
applaunch_version=$APPLAUNCH_VERSION
applaunch_sha256=$APPLAUNCH_SHA256
recorder_version=$RECORDER_VERSION
recorder_sha256=$RECORDER_SHA256
EOF

if [ "${PREPARE_ONLY:-0}" = 1 ]; then
    echo "Preparation checks passed: $INPUTS_FILE"
    exit 0
fi

export APPLAUNCH_DEB_FILE=/pi-gen/local-packages/$(basename "$STAGED_APPLAUNCH")
export RECORDER_DEB_FILE=/pi-gen/local-packages/$(basename "$STAGED_RECORDER")
export DTOVERLAYS_REF
export DTOVERLAYS_ARCHIVE=/pi-gen/local-sources/$DTO_ARCHIVE_NAME
export DTOVERLAYS_ARCHIVE_SHA256=$DTO_ARCHIVE_SHA256
unset DTOVERLAYS_LOCAL_DIR
export XZ_DEFAULTS=${XZ_DEFAULTS:--T0}
export BASE_IMAGE=${BASE_IMAGE:-docker.m.daocloud.io/library/debian:trixie}
export CONTAINER_NAME=${CONTAINER_NAME:-pigen_oneclick}
export CONTINUE=${CONTINUE:-0}
export PRESERVE_CONTAINER=${PRESERVE_CONTAINER:-0}

(
    cd "$PIGEN"
    ./build-docker.sh -c "$CONFIG_FILE"
)

IMAGE_XZ="$PIGEN/deploy/$IMAGE_BASENAME.img.xz"
RAW_IMAGE=${IMAGE_XZ%.xz}
INFO_FILE="$PIGEN/deploy/$IMAGE_BASENAME.info"
VERIFY_LOG="$PIGEN/deploy/$IMAGE_BASENAME.verification.log"
test -f "$IMAGE_XZ"
test -f "$INFO_FILE"
xz -t "$IMAGE_XZ"
xz -dkf "$IMAGE_XZ"
$SUDO env \
    VERIFY_PROFILE=full \
    EXPECTED_DTOVERLAYS_COMMIT="$DTOVERLAYS_REF" \
    EXPECTED_APPLAUNCH_VERSION="$APPLAUNCH_VERSION" \
    "$PIGEN/tools/verify-image.sh" "$RAW_IMAGE" 2>&1 | tee "$VERIFY_LOG"
grep -Fq 'ALL CHECKS PASSED' "$VERIFY_LOG"
(
    cd "$PIGEN/deploy"
    sha256sum "$IMAGE_BASENAME.img.xz" >"$IMAGE_BASENAME.img.xz.sha256"
    sha256sum -c "$IMAGE_BASENAME.img.xz.sha256"
)
install -m 0644 "$INPUTS_FILE" "$PIGEN/deploy/$IMAGE_BASENAME.build-inputs"

if [ "${KEEP_RAW_IMAGE:-0}" != 1 ]; then
    rm -f "$RAW_IMAGE"
fi

echo "Complete image: $IMAGE_XZ"
echo "Checksum: $IMAGE_XZ.sha256"
echo "Package manifest: $PIGEN/deploy/$IMAGE_BASENAME.build-inputs"
echo "Verification: $VERIFY_LOG"
