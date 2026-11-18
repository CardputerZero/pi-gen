#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"

unmount_image "${IMG_FILE}"

rm -f "${IMG_FILE}"

rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"

BOOT_SIZE="$((512 * 1024 * 1024))"
ROOT_SIZE=$(du -x --apparent-size -s "${EXPORT_ROOTFS_DIR}" --exclude var/cache/apt/archives --exclude boot/firmware --block-size=1 | cut -f 1)

# All partition sizes and starts will be aligned to this size
ALIGN="$((8 * 1024 * 1024))"

BOOT_PART_START=$((ALIGN))
BOOT_PART_SIZE=$(((BOOT_SIZE + ALIGN - 1) / ALIGN * ALIGN))
ROOT_PART_START=$((BOOT_PART_START + BOOT_PART_SIZE))

# Lite images are only CI check builds; keep them sized to their contents even
# when the product image is fixed-size.  IMG_SUFFIX is set by the EXPORT_IMAGE
# of the stage being exported ("-lite" for stage2).
FIXED_SIZE=1
case "${IMG_SUFFIX:-}" in
	*-lite*) FIXED_SIZE=0 ;;
esac

if [ -n "${IMAGE_TOTAL_SIZE:-}" ] && [ "$FIXED_SIZE" = "1" ]; then
	# CardputerZero fixed-size image: the root partition/filesystem is created
	# here and never grown on the device (no cmdline "resize" token, no
	# initramfs resize hook).  The layout must therefore be exact.
	IMG_SIZE="${IMAGE_TOTAL_SIZE}"
	ROOT_PART_SIZE=$((IMG_SIZE - ROOT_PART_START))
	if [ "$IMG_SIZE" -le "$ROOT_PART_START" ] || [ "$((ROOT_PART_SIZE % ALIGN))" -ne 0 ]; then
		echo "ERROR: IMAGE_TOTAL_SIZE=${IMG_SIZE} is not a valid aligned size" >&2
		echo "ERROR: boot partition ends at ${ROOT_PART_START}; the remainder must be a positive multiple of ${ALIGN}" >&2
		exit 1
	fi
	ROOT_MIN_FREE="${ROOT_MIN_FREE:-$((2 * 1024 * 1024 * 1024))}"
	if [ "$ROOT_PART_SIZE" -lt "$((ROOT_SIZE + ROOT_MIN_FREE))" ]; then
		echo "ERROR: rootfs (${ROOT_SIZE} bytes) + ${ROOT_MIN_FREE} bytes minimum free space" >&2
		echo "ERROR: does not fit the ${ROOT_PART_SIZE}-byte root partition of the fixed image" >&2
		exit 1
	fi
	echo "Fixed image size: ${IMG_SIZE} bytes (root partition ${ROOT_PART_SIZE} bytes, ~$(( (ROOT_PART_SIZE - ROOT_SIZE) / 1024 / 1024 )) MiB free after rsync)"
else
	# Upstream behaviour: size the image to the rootfs contents (lite build).
	ROOT_MARGIN="$(echo "($ROOT_SIZE * 0.2 + 200 * 1024 * 1024) / 1" | bc)"
	ROOT_PART_SIZE=$(((ROOT_SIZE + ROOT_MARGIN + ALIGN - 1) / ALIGN * ALIGN))
	IMG_SIZE=$((ROOT_PART_START + ROOT_PART_SIZE))
fi

truncate -s "${IMG_SIZE}" "${IMG_FILE}"

parted --script "${IMG_FILE}" mklabel msdos
# Give every image build its own random MBR disk signature (the PARTUUID
# prefix).  parted mklabel already generates one, but writing it explicitly
# guarantees separate builds cannot share a PARTUUID prefix.
dd if=/dev/urandom of="${IMG_FILE}" bs=1 seek=440 count=4 conv=notrunc status=none
parted --script "${IMG_FILE}" unit B mkpart primary fat32 "${BOOT_PART_START}" "$((BOOT_PART_START + BOOT_PART_SIZE - 1))"
parted --script "${IMG_FILE}" unit B mkpart primary ext4 "${ROOT_PART_START}" "$((ROOT_PART_START + ROOT_PART_SIZE - 1))"

echo "Creating loop device..."
cnt=0
until ensure_next_loopdev && LOOP_DEV="$(losetup --show --find --partscan "$IMG_FILE")"; do
	if [ $cnt -lt 5 ]; then
		cnt=$((cnt + 1))
		echo "Error in losetup.  Retrying..."
		sleep 5
	else
		echo "ERROR: losetup failed; exiting"
		exit 1
	fi
done

ensure_loopdev_partitions "$LOOP_DEV"
BOOT_DEV="${LOOP_DEV}p1"
ROOT_DEV="${LOOP_DEV}p2"

ROOT_FEATURES="^huge_file"
for FEATURE in 64bit; do
if grep -q "$FEATURE" /etc/mke2fs.conf; then
	ROOT_FEATURES="^$FEATURE,$ROOT_FEATURES"
fi
done

# Fixed 14.8 GiB image: the root filesystem is 14,632 MiB and uses roughly
# 141k inodes at build time.  32768 bytes/inode yields ~469k inodes (headroom
# for app installs) with a ~115 MiB inode table.  The image is never grown on
# the device; see docs/fixed-image-size.md.
ROOT_INODE_RATIO="${ROOT_INODE_RATIO:-32768}"

if [ "$BOOT_SIZE" -lt 134742016 ]; then
	FAT_SIZE=16
else
	FAT_SIZE=32
fi

mkdosfs -n bootfs -F "$FAT_SIZE" -s 1 -v "$BOOT_DEV" > /dev/null
# lazy_itable_init=0 moves the ~115 MiB inode-table zeroing from the first
# boot (kernel ext4lazyinit) to the build, where it costs nothing and does
# not add I/O to a possibly cheap SD card.
mkfs.ext4 -L rootfs -O "$ROOT_FEATURES" -i "$ROOT_INODE_RATIO" \
	-E lazy_itable_init=0 "$ROOT_DEV" > /dev/null

mount -v "$ROOT_DEV" "${ROOTFS_DIR}" -t ext4
mkdir -p "${ROOTFS_DIR}/boot/firmware"
mount -v "$BOOT_DEV" "${ROOTFS_DIR}/boot/firmware" -t vfat

rsync -aHAXx --exclude /var/cache/apt/archives --exclude /boot/firmware "${EXPORT_ROOTFS_DIR}/" "${ROOTFS_DIR}/"
rsync -rtx "${EXPORT_ROOTFS_DIR}/boot/firmware/" "${ROOTFS_DIR}/boot/firmware/"
