#!/bin/bash -e
install -D -m 0755 files/cz-status        "${ROOTFS_DIR}/usr/local/bin/cz-status"
install -D -m 0755 files/cz-net           "${ROOTFS_DIR}/usr/local/bin/cz-net"
install -D -m 0755 files/cz               "${ROOTFS_DIR}/usr/local/bin/cz"
install -D -m 0644 files/cz-tmux.conf     "${ROOTFS_DIR}/etc/cz-tmux.conf"
install -D -m 0644 files/cz-autostart.sh  "${ROOTFS_DIR}/etc/profile.d/cz-autostart.sh"
install -D -m 0644 files/99-quiet-console.conf "${ROOTFS_DIR}/etc/sysctl.d/99-quiet-console.conf"
install -d "${ROOTFS_DIR}/etc/cloud"
touch "${ROOTFS_DIR}/etc/cloud/cloud-init.disabled"
install -D -m 0644 files/10-cz-issue.conf \
  "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/10-cz-issue.conf"
install -D -m 0644 files/cz-motd.sh "${ROOTFS_DIR}/etc/profile.d/cz-motd.sh"
install -D -m 0644 files/issue.net "${ROOTFS_DIR}/etc/issue.net"
install -D -m 0644 files/motd      "${ROOTFS_DIR}/etc/motd"
sed -i 's|^#\?Banner.*|Banner /etc/issue.net|' "${ROOTFS_DIR}/etc/ssh/sshd_config"
if [ -d "${ROOTFS_DIR}/etc/update-motd.d" ]; then
    chmod -x "${ROOTFS_DIR}"/etc/update-motd.d/* 2>/dev/null || true
fi
install -D -m 0644 files/tca8418_keypad_m5stack_keymap.map \
  "${ROOTFS_DIR}/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map"
install -D -m 0755 files/cz-keymap "${ROOTFS_DIR}/usr/local/sbin/cz-keymap"
install -D -m 0644 files/cz-keymap.service "${ROOTFS_DIR}/etc/systemd/system/cz-keymap.service"
on_chroot << 'CHROOT'
systemctl enable cz-keymap.service
CHROOT
install -D -m 0644 files/issue.cz "${ROOTFS_DIR}/etc/issue"
install -D -m 0644 files/asound.conf "${ROOTFS_DIR}/etc/asound.conf"
install -D -m 0755 files/cz-menu "${ROOTFS_DIR}/usr/local/bin/cz-menu"
install -D -m 0755 files/cz-menu-theme "${ROOTFS_DIR}/usr/local/bin/cz-menu-theme"
install -D -m 0755 files/cz-ir "${ROOTFS_DIR}/usr/local/bin/cz-ir"
install -D -m 0755 files/cz-font "${ROOTFS_DIR}/usr/local/bin/cz-font"
HN=$(cat "${ROOTFS_DIR}/etc/hostname")
sed -i '/^127\.0\.1\.1[[:space:]]/d' "${ROOTFS_DIR}/etc/hosts"
printf '127.0.1.1\t%s\n' "$HN" >> "${ROOTFS_DIR}/etc/hosts"
install -D -m 0755 files/cz-camera "${ROOTFS_DIR}/usr/local/bin/cz-camera"
install -D -m 0644 files/Camera_1.0.4_m5stack1_arm64.deb "${ROOTFS_DIR}/tmp/camera.deb"
on_chroot << 'CHROOT'
apt-get install -y /tmp/camera.deb
rm -f /tmp/camera.deb
CHROOT
install -D -m 0755 files/cz-news          "${ROOTFS_DIR}/usr/local/bin/cz-news"
install -D -m 0644 files/newsboat-urls    "${ROOTFS_DIR}/usr/share/cz/newsboat-urls"
install -D -m 0644 files/newsboat-config  "${ROOTFS_DIR}/usr/share/cz/newsboat-config"
install -D -m 0755 files/cz-wifi "${ROOTFS_DIR}/usr/local/bin/cz-wifi"
