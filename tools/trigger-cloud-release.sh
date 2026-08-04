#!/bin/bash
# Validate and trigger the repository's GitHub Actions image build.

set -euo pipefail

REPO="${REPO:-CardputerZero/pi-gen}"
REF="${REF:-cardputerzero_v0.6}"
WORKFLOW="${WORKFLOW:-build.yml}"
DRY_RUN=0
WATCH=1

usage() {
    cat <<'EOF'
Usage: tools/trigger-cloud-release.sh [--dry-run] [--no-watch] [--ref REF]

The source ref must already be pushed to GitHub. Repository variables and
release asset URLs are validated by build.yml before the expensive build.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-watch) WATCH=0 ;;
        --ref)
            shift
            REF="${1:?--ref requires a value}"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

command -v gh >/dev/null || {
    echo "ERROR: GitHub CLI (gh) is not installed" >&2
    exit 1
}

if [ "$DRY_RUN" = "1" ]; then
    echo "gh workflow run $WORKFLOW --repo $REPO --ref $REF"
    echo "gh run list --repo $REPO --workflow $WORKFLOW --limit 5"
    exit 0
fi

gh auth status
gh api "repos/$REPO/commits/$REF" --jq '.sha' >/dev/null
gh workflow view "$WORKFLOW" --repo "$REPO" >/dev/null

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF"
echo "Triggered $REPO/$WORKFLOW at ref $REF"

if [ "$WATCH" = "1" ]; then
    RUN_ID=""
    for _ in $(seq 1 12); do
        RUN_ID=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" \
            --branch "$REF" --event workflow_dispatch --limit 10 \
            --json databaseId,createdAt \
            --jq ".[] | select(.createdAt >= \"$STARTED_AT\") | .databaseId" |
            head -1)
        [ -z "$RUN_ID" ] || break
        sleep 5
    done
    test -n "$RUN_ID"
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status
fi
