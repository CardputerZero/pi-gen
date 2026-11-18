#!/bin/bash -e
#
# CardputerZero images are fixed-size: the root partition and filesystem are
# created at build time (IMAGE_TOTAL_SIZE) and are never grown on the device.
# cmdline.txt has no "resize" token, so raspberrypi-sys-mods' resize_early and
# set_partuuid both exit early, and no custom initramfs resize code is
# installed anymore.
#
# Keep rpi-resize enabled: it is the unit that pulls first-boot-complete.target,
# which other first-boot units order themselves against.  Masking rpi-resize
# would remove that ordering.  Instead, override its Wants so it only pulls
# first-boot-complete and no longer starts systemd-growfs-root.service (which
# would attempt an online resize) or fstrim.service (a full-card TRIM burst on
# the first boot, because the image ships no fstrim timer stamp).

install -d "${ROOTFS_DIR}/etc/systemd/system"

install -d "${ROOTFS_DIR}/etc/systemd/system/rpi-resize.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/rpi-resize.service.d/10-cardputerzero-no-growfs-fstrim.conf" << 'EOF'
[Unit]
Wants=
Wants=first-boot-complete.target
EOF

# fstrim.timer would fire immediately on the first boot because there is no
# /var/lib/systemd/timers/stamp-fstrim.timer in the image.  Remove the enable
# link and mask the timer; fstrim.service itself remains available for manual
# use (systemctl start fstrim.service).
rm -f "${ROOTFS_DIR}/etc/systemd/system/timers.target.wants/fstrim.timer"
ln -sfn /dev/null "${ROOTFS_DIR}/etc/systemd/system/fstrim.timer"
rm -f "${ROOTFS_DIR}/var/lib/systemd/deb-systemd-helper-enabled/timers.target.wants/fstrim.timer"

# Give every card its own MBR disk ID on first boot (B1).  The build already
# writes a random ID into the image, but every copy of that image would share
# it; this one-shot service randomizes it per card and keeps the PARTUUID
# references in fstab/cmdline in sync.  It never touches partitions or the
# filesystem size.
if [ "${RANDOMIZE_DISK_ID_ON_FIRST_BOOT:-1}" = "1" ]; then
    install -d "${ROOTFS_DIR}/usr/lib/cardputerzero"
    install -m 0755 files/randomize-disk-id \
        "${ROOTFS_DIR}/usr/lib/cardputerzero/randomize-disk-id"
    install -d "${ROOTFS_DIR}/usr/lib/systemd/system"
    install -m 0644 files/cardputerzero-diskid.service \
        "${ROOTFS_DIR}/usr/lib/systemd/system/cardputerzero-diskid.service"
    install -d "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/cardputerzero-diskid.service \
        "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/cardputerzero-diskid.service"
fi
