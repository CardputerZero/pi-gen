#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"

IMGID="$(dd if="${IMG_FILE}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_PARTUUID="${IMGID}-02"

sed -i "s/BOOTDEV/PARTUUID=${BOOT_PARTUUID}/" "${ROOTFS_DIR}/etc/fstab"
sed -i "s/ROOTDEV/PARTUUID=${ROOT_PARTUUID}/" "${ROOTFS_DIR}/etc/fstab"

sed -i "s/ROOTDEV/PARTUUID=${ROOT_PARTUUID}/" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# Normalize CardputerZero cmdline for this image and keep console/splash/plymouth out.
if grep -q "dtoverlay=cardputerzero" "${ROOTFS_DIR}/boot/firmware/config.txt" 2>/dev/null; then
    awk '
    {
        out = ""
        for (i = 1; i <= NF; i++) {
            if ($i != "console=serial0,115200" && $i != "splash" && $i != "plymouth.ignore-serial-consoles") {
                out = out (out == "" ? "" : " ") $i
            }
        }
        print out
    }
    ' "${ROOTFS_DIR}/boot/firmware/cmdline.txt" > "${ROOTFS_DIR}/boot/firmware/cmdline.txt.tmp"
    mv "${ROOTFS_DIR}/boot/firmware/cmdline.txt.tmp" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

    # Keep boot/cmdline.txt aligned with the file actually mounted in verify.
    cp "${ROOTFS_DIR}/boot/firmware/cmdline.txt" "${ROOTFS_DIR}/boot/cmdline.txt"
fi
