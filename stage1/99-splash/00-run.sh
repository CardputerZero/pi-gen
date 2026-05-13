#!/bin/bash -e
# Build splash init and install into initramfs

# Cross-compile the splash program
aarch64-linux-gnu-gcc -static -Os \
    -o "${ROOTFS_DIR}/usr/lib/splash-init" \
    files/splash.c

aarch64-linux-gnu-strip "${ROOTFS_DIR}/usr/lib/splash-init"

# Create initramfs with splash as /init
INITRAMFS_DIR=$(mktemp -d)
mkdir -p "$INITRAMFS_DIR"/{dev,proc,sbin,bin}

cp "${ROOTFS_DIR}/usr/lib/splash-init" "$INITRAMFS_DIR/init"
chmod +x "$INITRAMFS_DIR/init"

# Create minimal device nodes
mknod "$INITRAMFS_DIR/dev/mem" c 1 1
mknod "$INITRAMFS_DIR/dev/null" c 1 3

# Pack initramfs
(cd "$INITRAMFS_DIR" && find . | cpio -o -H newc | gzip > "${ROOTFS_DIR}/boot/firmware/initramfs-splash.img")
rm -rf "$INITRAMFS_DIR"

# Add to config.txt
echo "initramfs initramfs-splash.img followkernel" >> "${ROOTFS_DIR}/boot/firmware/config.txt"

echo "Splash initramfs installed"
