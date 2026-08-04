#!/bin/bash -e

# wf-panel-pi is installed by stage4/00-install-packages, after the custom
# stage2 runs. Keep PackageKit available on demand but remove the panel widget
# that refreshes all APT metadata at login on this 256 MiB target.
PANEL_CONFIG="${ROOTFS_DIR}/etc/xdg/wf-panel-pi/wf-panel-pi.ini"
if [ ! -f "$PANEL_CONFIG" ]; then
    echo "ERROR: wf-panel-pi configuration is missing: $PANEL_CONFIG" >&2
    exit 1
fi

sed -i -E \
    '/^widgets_right=/ { s/(^|[[:space:]])updater([[:space:]]|$)/\1\2/g; s/[[:space:]]+/ /g; }' \
    "$PANEL_CONFIG"

if grep -Eq '^widgets_right=.*(^|[[:space:]])updater([[:space:]]|$)' \
    "$PANEL_CONFIG"; then
    echo "ERROR: failed to disable the wf-panel-pi updater widget" >&2
    exit 1
fi
