#!/bin/bash -e

# Old kernels leave the APT index but remain in the official package pool.
# Install the entire pinned dependency set before any rolling kernel packages.
install -d "${ROOTFS_DIR}/var/tmp" "${ROOTFS_DIR}/etc/apt/preferences.d"
DOWNLOAD_DIR=$(mktemp -d "${ROOTFS_DIR}/var/tmp/cardputerzero-kernel.XXXXXX")
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
MANIFEST="${PWD}/files/kernel-packages.sha256"

while read -r checksum filename; do
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 30 --max-time 600 \
        "https://archive.raspberrypi.com/debian/pool/main/l/linux/${filename}" \
        -o "${DOWNLOAD_DIR}/${filename}"
done < "$MANIFEST"
(cd "$DOWNLOAD_DIR" && sha256sum --check "$MANIFEST")

install -m 644 files/kernel.pref \
    "${ROOTFS_DIR}/etc/apt/preferences.d/cardputerzero-kernel"
CHROOT_DOWNLOAD_DIR="${DOWNLOAD_DIR#"${ROOTFS_DIR}"}"
on_chroot << EOF
set -e
cd '${CHROOT_DOWNLOAD_DIR}'
packages=()
for deb in ./*.deb; do
    packages+=("\$(dpkg-deb -f "\$deb" Package)")
done
apt-get install -y --no-install-recommends \
    --allow-downgrades --allow-change-held-packages ./*.deb
kernel_version="\$(dpkg-query -W -f='\${Version}' linux-image-rpi-v8 2>/dev/null || true)"
printf 'Installed kernel version: %s\n' "\$kernel_version"
apt-mark hold "\${packages[@]}"
EOF
