#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
install -d -m 0755 "${ROOTFS_DIR}/opt"
# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/rpi-config.py "${ROOTFS_DIR}/opt/rpi-config.py"

on_chroot << 'CHROOT'
set -e

# Install build dependencies
apt-get install -y --no-install-recommends \
    build-essential \
    linux-headers-rpi-v8 \
    device-tree-compiler \
    git

# Always build the latest driver from the main branch.
rm -rf /tmp/dtoverlays
git clone --depth=1 https://github.com/m5stack/m5stack-linux-dtoverlays.git \
    /tmp/dtoverlays
git -C /tmp/dtoverlays rev-parse HEAD \
    > /etc/cardputerzero-dtoverlays.commit

KVER=$(ls /lib/modules/ | grep rpi-v8 | head -1)
export KERNELDIR="/lib/modules/${KVER}/build"
export EXTRADIR="/lib/modules/${KVER}/extra"

# make and install st7789v overlay + module
cd /tmp/dtoverlays/modules/CardputerZero
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y install
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y config_setup

# Reserve 64 MiB of contiguous memory for the KMS display driver.
CONFIG_FILE=/boot/config.txt
if [ ! -e "$CONFIG_FILE" ]; then
    CONFIG_FILE=/boot/firmware/config.txt
fi
sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-64/' "$CONFIG_FILE"

# Update module dependencies
depmod -a "${KVER}"

# Clean up build artifacts only (keep all build tools for user driver builds)
rm -rf /tmp/dtoverlays

CHROOT
