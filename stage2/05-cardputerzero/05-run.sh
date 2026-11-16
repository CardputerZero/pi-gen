#!/bin/bash -e
#
# CardputerZero first-boot resizing (32GB shipping cards).
#
# The initramfs script grows the partition and the ext4 filesystem before the
# root filesystem is mounted.  This is deliberately not left to
# systemd-growfs-root: on Trixie that runs an online resize at sysinit, while
# journald/udev/cloud-init are already doing I/O on the same SD card.  On
# low-end cards that first boot can stall or hit MMC/kernel error paths.
#
# We also disable the first-boot fstrim that raspberrypi-sys-mods pulls in via
# rpi-resize and that fstrim.timer would otherwise trigger (the image has no
# timer stamp).  A full-card TRIM is the other big first-boot I/O burst and is
# not required for a working SD-card image; users can still run fstrim.service
# manually.

install -d "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/local-premount"
install -d "${ROOTFS_DIR}/usr/share/initramfs-tools/hooks"
install -d "${ROOTFS_DIR}/etc/systemd/system"

install -m 0755 files/resize_early \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/local-premount/resize_early"
install -m 0755 files/cardputerzero-resize-hook \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/hooks/cardputerzero-resize"

# Keep rpi-resize enabled: it is the unit that pulls
# first-boot-complete.target, which other first-boot units order themselves
# against.  Masking rpi-resize would remove that ordering.  Instead, override
# its Wants so it only pulls first-boot-complete and no longer starts
# systemd-growfs-root.service or fstrim.service.
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
