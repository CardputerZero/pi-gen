#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
DTOOVERLAYS_REPO="${DTOOVERLAYS_REPO:-https://github.com/m5stack/m5stack-linux-dtoverlays.git}"
DTOOVERLAYS_REF="${DTOOVERLAYS_REF:-master}"
DTOOVERLAYS_ARCHIVE="${DTOOVERLAYS_ARCHIVE:-}"
DTOOVERLAYS_ARCHIVE_SHA256="${DTOOVERLAYS_ARCHIVE_SHA256:-}"
CHROOT_DTOOVERLAYS_ARCHIVE=""
if [ -n "$DTOOVERLAYS_ARCHIVE" ]; then
    if [ ! -f "$DTOOVERLAYS_ARCHIVE" ]; then
        echo "ERROR: DTOOVERLAYS_ARCHIVE does not exist: $DTOOVERLAYS_ARCHIVE"
        exit 1
    fi
    if ! [[ "$DTOOVERLAYS_REF" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: archive builds require a 40-character DTOOVERLAYS_REF commit"
        exit 1
    fi
    if ! [[ "$DTOOVERLAYS_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: archive builds require DTOOVERLAYS_ARCHIVE_SHA256"
        exit 1
    fi
    CHROOT_DTOOVERLAYS_ARCHIVE=/tmp/cardputerzero-dtoverlays.tar.gz
    install -m 0644 "$DTOOVERLAYS_ARCHIVE" \
        "${ROOTFS_DIR}${CHROOT_DTOOVERLAYS_ARCHIVE}"
fi
printf 'DTOOVERLAYS_REPO=%q\nDTOOVERLAYS_REF=%q\nDTOOVERLAYS_ARCHIVE=%q\nDTOOVERLAYS_ARCHIVE_SHA256=%q\n' \
    "$DTOOVERLAYS_REPO" "$DTOOVERLAYS_REF" \
    "$CHROOT_DTOOVERLAYS_ARCHIVE" "$DTOOVERLAYS_ARCHIVE_SHA256" \
    > "${ROOTFS_DIR}/tmp/cardputerzero-dtoverlays.env"
install -m 0644 files/cardputerzero-audio-fixes.patch \
    "${ROOTFS_DIR}/tmp/cardputerzero-audio-fixes.patch"
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
if [ -n "$DTOOVERLAYS_ARCHIVE" ]; then
    printf '%s  %s\n' "$DTOOVERLAYS_ARCHIVE_SHA256" \
        "$DTOOVERLAYS_ARCHIVE" | sha256sum -c -
    mkdir -p /tmp/dtoverlays
    tar -xzf "$DTOOVERLAYS_ARCHIVE" --strip-components=1 \
        -C /tmp/dtoverlays
    printf '%s\n' "$DTOOVERLAYS_REF" \
        > /etc/cardputerzero-dtoverlays.commit
else
    git init /tmp/dtoverlays
    git -C /tmp/dtoverlays remote add origin "$DTOOVERLAYS_REPO"
    for attempt in 1 2 3; do
        if git -C /tmp/dtoverlays fetch --depth=1 origin "$DTOOVERLAYS_REF"; then
            break
        fi
        if [ "$attempt" -eq 3 ]; then
            echo "ERROR: failed to fetch DTOOVERLAYS_REF after $attempt attempts"
            exit 1
        fi
        echo "dtoverlays fetch attempt $attempt failed; retrying..."
        sleep $((attempt * 5))
    done
    git -C /tmp/dtoverlays checkout --detach FETCH_HEAD
    git -C /tmp/dtoverlays rev-parse HEAD \
        > /etc/cardputerzero-dtoverlays.commit
fi
if git -C /tmp/dtoverlays apply --check /tmp/cardputerzero-audio-fixes.patch; then
    git -C /tmp/dtoverlays apply /tmp/cardputerzero-audio-fixes.patch
elif git -C /tmp/dtoverlays apply --reverse --check \
        /tmp/cardputerzero-audio-fixes.patch; then
    echo "CardputerZero audio fixes are already present in DTOOVERLAYS_REF"
else
    echo "ERROR: CardputerZero audio fixes do not apply to DTOOVERLAYS_REF"
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
    /tmp/cardputerzero-audio-fixes.patch

CHROOT
