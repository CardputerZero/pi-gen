#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
install -d -m 0755 "${ROOTFS_DIR}/opt"
# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/rpi-config.py "${ROOTFS_DIR}/opt/rpi-config.py"

# Pin the dtoverlay driver revision. Building whatever "main" happens to point
# at makes image builds unreproducible (rebuilding a release tag picks up a
# newer driver) and means a force-push to that repository changes the kernel
# module that ships in every official image. Bump this deliberately, or
# override DTOVERLAYS_COMMIT for a test build.
DTOVERLAYS_COMMIT="${DTOVERLAYS_COMMIT:-a3fd3e83c0247e16e194e7e40f7fc1f5be933dd4}"
echo "${DTOVERLAYS_COMMIT}" > "${ROOTFS_DIR}/etc/cardputerzero-dtoverlays.commit"

on_chroot << 'CHROOT'
set -e

# Install build dependencies
apt-get install -y --no-install-recommends \
    build-essential \
    linux-headers-rpi-v8 \
    device-tree-compiler \
    git

# Build the pinned driver revision written by the host side above.
DTOVERLAYS_COMMIT="$(cat /etc/cardputerzero-dtoverlays.commit)"
rm -rf /tmp/dtoverlays
git init -q /tmp/dtoverlays
git -C /tmp/dtoverlays remote add origin \
    https://github.com/m5stack/m5stack-linux-dtoverlays.git
git -C /tmp/dtoverlays fetch -q --depth=1 origin "${DTOVERLAYS_COMMIT}"
git -C /tmp/dtoverlays checkout -q --detach FETCH_HEAD

# Fail the build rather than ship a driver nobody asked for.
DTOVERLAYS_ACTUAL="$(git -C /tmp/dtoverlays rev-parse HEAD)"
if [ "$DTOVERLAYS_ACTUAL" != "$DTOVERLAYS_COMMIT" ]; then
    echo "ERROR: dtoverlays checkout is ${DTOVERLAYS_ACTUAL}," >&2
    echo "ERROR: expected ${DTOVERLAYS_COMMIT}" >&2
    exit 1
fi

# /lib/modules can hold more than one *rpi-v8* tree (an apt upgrade earlier in
# the build, a held-back linux-image). "ls | head -1" then picks whichever name
# sorts first rather than the kernel actually installed, and the module is built
# and depmod'd against the wrong one -- the display driver is simply absent at
# runtime, with no build-time error. Require exactly one and say so loudly.
KVER_LIST="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name '*rpi-v8*' \
    -printf '%f\n' | sort)"
KVER_COUNT="$(printf '%s' "$KVER_LIST" | grep -c . || true)"
if [ "$KVER_COUNT" -ne 1 ]; then
    echo "ERROR: expected exactly one *rpi-v8* kernel in /lib/modules," >&2
    echo "ERROR: found ${KVER_COUNT}:" >&2
    printf '  %s\n' $KVER_LIST >&2
    exit 1
fi
KVER="$KVER_LIST"
export KERNELDIR="/lib/modules/${KVER}/build"
export EXTRADIR="/lib/modules/${KVER}/extra"

# make and install st7789v overlay + module
cd /tmp/dtoverlays/modules/CardputerZero
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y install
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y config_setup

# Reserve 64 MiB of contiguous memory for the KMS display driver.
DEFAULT_CONFIG="/boot/firmware/config.txt"
sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-64/' "$DEFAULT_CONFIG"
# That pattern is fully anchored, so the day the line carries a parameter or
# trailing whitespace the substitution matches nothing, sed still exits 0, and
# the image ships with no CMA reserved -- which fails on the device, not in CI.
if ! grep -q '^dtoverlay=vc4-kms-v3d,cma-64$' "$DEFAULT_CONFIG"; then
    echo "ERROR: could not add cma-64 to the vc4-kms-v3d overlay in" >&2
    echo "ERROR: ${DEFAULT_CONFIG}; current dtoverlay lines:" >&2
    grep -n '^dtoverlay=' "$DEFAULT_CONFIG" >&2 || true
    exit 1
fi

# Update module dependencies
depmod -a "${KVER}"

# Clean up build artifacts only (keep all build tools for user driver builds)
rm -rf /tmp/dtoverlays

CHROOT
