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

# stage3/4 installs the desktop stack after the product OOBE was configured in
# stage2.  Disable the display manager again at the final image layer so it
# cannot race the root LaunchWizard for DRM/VT and memory on the first boot.
on_chroot << 'CHROOT'
systemctl disable lightdm.service adbd.service cardputer-adb-hotplug.service
CHROOT

rm -f "${ROOTFS_DIR}/etc/systemd/system/display-manager.service" \
    "${ROOTFS_DIR}/etc/systemd/system/graphical.target.wants/lightdm.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/adbd.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service"

for link in \
    "${ROOTFS_DIR}/etc/systemd/system/display-manager.service" \
    "${ROOTFS_DIR}/etc/systemd/system/graphical.target.wants/lightdm.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/adbd.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service"; do
    if [ -e "$link" ] || [ -L "$link" ]; then
        echo "ERROR: forbidden first-boot service remains enabled: $link" >&2
        exit 1
    fi
done
