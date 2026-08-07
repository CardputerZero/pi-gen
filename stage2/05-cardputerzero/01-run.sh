#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
DTOVERLAYS_REPO="${DTOVERLAYS_REPO:-https://github.com/m5stack/m5stack-linux-dtoverlays.git}"
DTOVERLAYS_REF="${DTOVERLAYS_REF:-main}"
DTOVERLAYS_ARCHIVE="${DTOVERLAYS_ARCHIVE:-}"
DTOVERLAYS_ARCHIVE_SHA256="${DTOVERLAYS_ARCHIVE_SHA256:-}"
CHROOT_DTOVERLAYS_ARCHIVE=""
if [ -n "$DTOVERLAYS_ARCHIVE" ]; then
    if [ ! -f "$DTOVERLAYS_ARCHIVE" ]; then
        echo "ERROR: DTOVERLAYS_ARCHIVE does not exist: $DTOVERLAYS_ARCHIVE"
        exit 1
    fi
    if ! [[ "$DTOVERLAYS_REF" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: archive builds require a 40-character DTOVERLAYS_REF commit"
        exit 1
    fi
    if ! [[ "$DTOVERLAYS_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: archive builds require DTOVERLAYS_ARCHIVE_SHA256"
        exit 1
    fi
    CHROOT_DTOVERLAYS_ARCHIVE=/tmp/cardputerzero-dtoverlays.tar.gz
    install -m 0644 "$DTOVERLAYS_ARCHIVE" \
        "${ROOTFS_DIR}${CHROOT_DTOVERLAYS_ARCHIVE}"
fi
printf 'DTOVERLAYS_REPO=%q\nDTOVERLAYS_REF=%q\nDTOVERLAYS_ARCHIVE=%q\nDTOVERLAYS_ARCHIVE_SHA256=%q\n' \
    "$DTOVERLAYS_REPO" "$DTOVERLAYS_REF" \
    "$CHROOT_DTOVERLAYS_ARCHIVE" "$DTOVERLAYS_ARCHIVE_SHA256" \
    > "${ROOTFS_DIR}/tmp/cardputerzero-dtoverlays.env"
install -m 0644 files/cardputerzero-extport-permissions.patch \
    "${ROOTFS_DIR}/tmp/cardputerzero-extport-permissions.patch"
install -d -m 0755 "${ROOTFS_DIR}/opt"
# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/rpi-config.py "${ROOTFS_DIR}/opt/rpi-config.py"

on_chroot << 'CHROOT'
set -e
. /tmp/cardputerzero-dtoverlays.env

# Install build dependencies
apt-get install -y --no-install-recommends \
    build-essential \
    linux-headers-rpi-v8 \
    device-tree-compiler \
    git

# Fetch the requested branch, tag, or commit so image builds are reproducible.
rm -rf /tmp/dtoverlays
if [ -n "$DTOVERLAYS_ARCHIVE" ]; then
    printf '%s  %s\n' "$DTOVERLAYS_ARCHIVE_SHA256" \
        "$DTOVERLAYS_ARCHIVE" | sha256sum -c -
    mkdir -p /tmp/dtoverlays
    tar -xzf "$DTOVERLAYS_ARCHIVE" --strip-components=1 \
        -C /tmp/dtoverlays
    printf '%s\n' "$DTOVERLAYS_REF" \
        > /etc/cardputerzero-dtoverlays.commit
else
    git init /tmp/dtoverlays
    git -C /tmp/dtoverlays remote add origin "$DTOVERLAYS_REPO"
    for attempt in 1 2 3; do
        if git -C /tmp/dtoverlays fetch --depth=1 origin "$DTOVERLAYS_REF"; then
            break
        fi
        if [ "$attempt" -eq 3 ]; then
            echo "ERROR: failed to fetch DTOVERLAYS_REF after $attempt attempts"
            exit 1
        fi
        echo "dtoverlays fetch attempt $attempt failed; retrying..."
        sleep $((attempt * 5))
    done
    git -C /tmp/dtoverlays checkout --detach FETCH_HEAD
    git -C /tmp/dtoverlays rev-parse HEAD \
        > /etc/cardputerzero-dtoverlays.commit
fi

if git -C /tmp/dtoverlays apply --check \
        /tmp/cardputerzero-extport-permissions.patch; then
    git -C /tmp/dtoverlays apply \
        /tmp/cardputerzero-extport-permissions.patch
elif git -C /tmp/dtoverlays apply --reverse --check \
        /tmp/cardputerzero-extport-permissions.patch; then
    echo "CardputerZero ExtPort permissions are already present in DTOVERLAYS_REF"
else
    echo "ERROR: CardputerZero ExtPort permissions do not apply to DTOVERLAYS_REF"
    exit 1
fi

KVER=$(ls /lib/modules/ | grep rpi-v8 | head -1)
export KERNELDIR="/lib/modules/${KVER}/build"
export EXTRADIR="/lib/modules/${KVER}/extra"

# make and install st7789v overlay + module
cd /tmp/dtoverlays/modules/CardputerZero
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y install
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y config_setup

# Update module dependencies
depmod -a "${KVER}"

# Clean up build artifacts only (keep all build tools for user driver builds)
rm -rf /tmp/dtoverlays
rm -f /tmp/cardputerzero-dtoverlays.env \
    /tmp/cardputerzero-dtoverlays.tar.gz \
    /tmp/cardputerzero-extport-permissions.patch

CHROOT
