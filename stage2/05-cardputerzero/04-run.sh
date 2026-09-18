#!/bin/bash -e

# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/template.zip "${ROOTFS_DIR}/var/template.zip"
install -m 0644 files/fb-mirror.desktop "${ROOTFS_DIR}/usr/share/applications/fb-mirror.desktop"
install -m 0755 files/fb-mirror.py "${ROOTFS_DIR}/usr/bin/fb-mirror.py"
