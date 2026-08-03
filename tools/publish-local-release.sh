#!/bin/bash
# Upload a bundle made by prepare-local-release.sh as a GitHub prerelease.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="${REPO:-CardputerZero/pi-gen}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: tools/publish-local-release.sh [--dry-run] RELEASE_DIR

Environment:
  REPO=owner/repository
  TAG=local-YYYYMMDD-HHMMSS-sha7

The command always creates a prerelease. It does not push source changes.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

RELEASE_DIR=$(realpath "$1")
test -d "$RELEASE_DIR"

mapfile -t IMAGES < <(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.img.xz' | sort)
if [ "${#IMAGES[@]}" -ne 1 ]; then
    echo "ERROR: release directory must contain exactly one .img.xz" >&2
    exit 1
fi
IMAGE=${IMAGES[0]}
SHA_FILE="${IMAGE}.sha256"
test -f "$SHA_FILE"
(cd "$RELEASE_DIR" && sha256sum -c "$(basename "$SHA_FILE")")

mapfile -t ASSETS < <(find "$RELEASE_DIR" -maxdepth 1 -type f \
    \( -name '*.img.xz' -o -name '*.img.xz.sha256' -o -name '*.info' \
       -o -name 'full-image-verification.log' -o -name 'release-manifest.txt' \
       -o -name 'build-info.json' \) |
    sort)

test -f "$RELEASE_DIR/build-info.json" || {
    echo "ERROR: build-info.json is required for M5 Imager OSS synchronisation" >&2
    exit 1
}

TARGET=$(git -C "$ROOT" rev-parse HEAD)
TAG="${TAG:-local-$(date -u +%Y%m%d-%H%M%S)-${TARGET:0:7}}"
[[ "$TAG" =~ ^local-[0-9]{8}-[0-9]{6}-[0-9a-f]{7}$ ]] || {
    echo "ERROR: TAG must match local-YYYYMMDD-HHMMSS-sha7" >&2
    exit 2
}

NOTES_FILE="$RELEASE_DIR/release-notes.md"
{
    echo "Local CardputerZero image build."
    echo
    echo "- pi-gen target: $TARGET"
    echo "- image SHA-256: $(awk '{print $1}' "$SHA_FILE")"
    echo "- source state: $(awk -F= '$1 == "pi_gen_worktree" { print $2 }' "$RELEASE_DIR/release-manifest.txt")"
    echo
    echo "Verify the SHA-256 file before flashing. This is a prerelease."
} > "$NOTES_FILE"
ASSETS+=("$NOTES_FILE")

if [ "$DRY_RUN" = "1" ]; then
    echo "Repository: $REPO"
    echo "Target: $TARGET"
    echo "Tag: $TAG"
    printf 'Asset: %s\n' "${ASSETS[@]}"
    echo "Dry run complete; no GitHub changes made."
    exit 0
fi

command -v gh >/dev/null || {
    echo "ERROR: GitHub CLI (gh) is not installed" >&2
    exit 1
}
gh auth status
CAN_PUSH=$(gh api "repos/$REPO" --jq '.permissions.push')
if [ "$CAN_PUSH" != "true" ]; then
    echo "ERROR: authenticated account cannot publish to $REPO" >&2
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "ERROR: release tag already exists: $TAG" >&2
    exit 1
fi

gh_api_retry() {
    local attempt output
    for attempt in 1 2 3 4 5; do
        if output=$(gh api "$@" 2>&1); then
            printf '%s\n' "$output"
            return 0
        fi
        echo "WARN: GitHub API attempt $attempt failed: $output" >&2
        sleep $((attempt * 2))
    done
    return 1
}

publish_complete_draft() {
    local draft_id asset name expected_size remote_size
    draft_id=$(gh_api_retry --paginate "repos/$REPO/releases" \
        --jq ".[] | select(.draft == true and .tag_name == \"$TAG\") | .id" |
        head -1)
    if [ -z "$draft_id" ]; then
        echo "ERROR: upload failed and no matching draft release was found" >&2
        return 1
    fi

    for asset in "${ASSETS[@]}"; do
        name=$(basename "$asset")
        expected_size=$(stat --format=%s "$asset")
        remote_size=$(gh_api_retry "repos/$REPO/releases/$draft_id" \
            --jq ".assets[] | select(.name == \"$name\") | .size" |
            head -1)
        if [ "$remote_size" != "$expected_size" ]; then
            echo "ERROR: draft asset is missing or incomplete: $name" >&2
            echo "       expected=$expected_size remote=${remote_size:-missing}" >&2
            return 1
        fi
    done

    echo "All draft assets are complete; retrying the final publish operation."
    gh_api_retry --method PATCH "repos/$REPO/releases/$draft_id" \
        -F draft=false -F prerelease=true >/dev/null
}

if ! gh release create "$TAG" "${ASSETS[@]}" \
    --repo "$REPO" \
    --target "$TARGET" \
    --prerelease \
    --title "$TAG" \
    --notes-file "$NOTES_FILE"; then
    echo "WARN: gh release create failed; checking for a complete draft release." >&2
    publish_complete_draft
fi

echo "Published prerelease: https://github.com/$REPO/releases/tag/$TAG"
