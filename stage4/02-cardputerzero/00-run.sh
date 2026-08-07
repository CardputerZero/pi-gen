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

# The default 8 MiB CMA pool is exhausted by the vc4 fbdev buffer before labwc
# can allocate an HDMI swapchain. 32 MiB covers common 720p/1080p dumb-buffer
# allocations; unused CMA pages remain available for movable allocations.
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
if [ ! -f "$CMDLINE" ]; then
    echo "ERROR: boot cmdline is missing: $CMDLINE" >&2
    exit 1
fi
awk '
    {
        out = ""
        for (i = 1; i <= NF; ++i) {
            if ($i !~ /^cma=/)
                out = out (out == "" ? "" : " ") $i
        }
        print out " cma=32M"
    }
' "$CMDLINE" >"${CMDLINE}.tmp"
mv "${CMDLINE}.tmp" "$CMDLINE"

install -d \
    "${ROOTFS_DIR}/usr/libexec" \
    "${ROOTFS_DIR}/usr/lib/systemd/system" \
    "${ROOTFS_DIR}/usr/lib/udev/rules.d" \
    "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d"
install -m 755 files/cardputerzero-hdmi-display \
    "${ROOTFS_DIR}/usr/libexec/cardputerzero-hdmi-display"
install -m 644 files/cardputerzero-hdmi-display.service \
    "${ROOTFS_DIR}/usr/lib/systemd/system/cardputerzero-hdmi-display.service"
install -m 644 files/zz-cardputerzero-hdmi-display.rules \
    "${ROOTFS_DIR}/usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules"
install -m 644 files/20-cardputerzero-hdmi.conf \
    "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d/20-cardputerzero-hdmi.conf"

# stage3/4 installs the desktop stack after the product OOBE was configured in
# stage2.  Disable the display manager again at the final image layer so it
# cannot race the root LaunchWizard for DRM/VT and memory on the first boot.
# The HDMI helper starts it explicitly only while an HDMI display is connected.
on_chroot << 'CHROOT'
systemctl disable lightdm.service adbd.service cardputer-adb-hotplug.service
systemctl disable cardputerzero-hdmi-display.timer || true
systemctl enable cardputerzero-hdmi-display.service
CHROOT

rm -f "${ROOTFS_DIR}/etc/systemd/system/display-manager.service" \
    "${ROOTFS_DIR}/etc/systemd/system/graphical.target.wants/lightdm.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/adbd.service" \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service" \
    "${ROOTFS_DIR}/etc/systemd/system/timers.target.wants/cardputerzero-hdmi-display.timer" \
    "${ROOTFS_DIR}/usr/lib/systemd/system/cardputerzero-hdmi-display.timer"

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

if [ ! -L "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cardputerzero-hdmi-display.service" ]; then
    echo "ERROR: HDMI display monitor is not enabled" >&2
    exit 1
fi
