#!/bin/bash
# Configure pinned GitHub repository variables consumed by build.yml.

set -euo pipefail

REPO="${REPO:-CardputerZero/pi-gen}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: [environment variables] tools/configure-cloud-release.sh [--dry-run]

Required environment:
  DTOVERLAYS_REF             40-character source commit
  APPLAUNCH_DEB_URL           Fixed arm64 deb release asset URL
  EXPECTED_APPLAUNCH_VERSION  Exact Debian package version

Optional product app URLs can be set with RECORDER_DEB_URL, COMPASS_DEB_URL,
CAMERA_APP_DEB_URL, FACTORY_TEST_DEB_URL, FILES_DEB_URL, MUSIC_DEB_URL,
IR_CHAT_DEB_URL, PIANO_DEB_URL, IR_REMOTE_DEB_URL, CAP_CC1101_SUBG_CHAT_DEB_URL,
CAP_CC1101_NFC_DEB_URL,
and CAP_LORA_1262_GPS_DEB_URL.
EOF
}

case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

: "${DTOVERLAYS_REF:?DTOVERLAYS_REF is required}"
: "${APPLAUNCH_DEB_URL:?APPLAUNCH_DEB_URL is required}"
: "${EXPECTED_APPLAUNCH_VERSION:?EXPECTED_APPLAUNCH_VERSION is required}"

[[ "$DTOVERLAYS_REF" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: DTOVERLAYS_REF must be a 40-character commit" >&2
    exit 2
}
[[ "$APPLAUNCH_DEB_URL" =~ ^https:// ]] || {
    echo "ERROR: APPLAUNCH_DEB_URL must use HTTPS" >&2
    exit 2
}
VARIABLE_NAMES=(
    DTOVERLAYS_REF
    APPLAUNCH_DEB_URL
    RECORDER_DEB_URL
    EXPECTED_APPLAUNCH_VERSION
    COMPASS_DEB_URL
    CAMERA_APP_DEB_URL
    FACTORY_TEST_DEB_URL
    FILES_DEB_URL
    MUSIC_DEB_URL
    IR_CHAT_DEB_URL
    PIANO_DEB_URL
    IR_REMOTE_DEB_URL
    CAP_CC1101_SUBG_CHAT_DEB_URL
    CAP_CC1101_NFC_DEB_URL
    CAP_LORA_1262_GPS_DEB_URL
)

if [ "$DRY_RUN" = "0" ]; then
    command -v gh >/dev/null || {
        echo "ERROR: GitHub CLI (gh) is not installed" >&2
        exit 1
    }
    gh auth status
    CAN_PUSH=$(gh api "repos/$REPO" --jq '.permissions.push')
    [ "$CAN_PUSH" = "true" ] || {
        echo "ERROR: authenticated account cannot configure $REPO" >&2
        exit 1
    }
fi

for name in "${VARIABLE_NAMES[@]}"; do
    value="${!name:-}"
    [ -n "$value" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
        printf 'gh variable set %q --repo %q --body %q\n' \
            "$name" "$REPO" "$value"
    else
        gh variable set "$name" --repo "$REPO" --body "$value"
    fi
done

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run complete; no repository variables changed."
else
    gh variable list --repo "$REPO"
fi
