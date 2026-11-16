#!/bin/bash
# Verify CardputerZero image contains all required customizations.
# Usage: ./tools/verify-image.sh <image.img>
# Exit 0 = all checks pass, Exit 1 = failure (breaks CI)

set -euo pipefail

IMG="${1:?Usage: $0 <image.img>}"
ERRORS=0
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "  ✓ $1"; }

echo "=========================================="
echo " CardputerZero Image Verification"
echo "=========================================="
echo " Image: $IMG"
echo ""

# --- Extract partitions ---
# Get partition offsets (sectors, 512 bytes each)
BOOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $2}')
BOOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $3}')
ROOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $2}')
ROOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $3}')

BOOT_SECTORS=$((BOOT_END - BOOT_START + 1))
ROOT_SECTORS=$((ROOT_END - ROOT_START + 1))

echo "[1/7] Extracting partitions..."
dd if="$IMG" of="$TMPDIR/boot.fat" bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" 2>/dev/null
dd if="$IMG" of="$TMPDIR/root.ext4" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" 2>/dev/null

# --- Mount boot ---
mkdir -p "$TMPDIR/boot"
mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot" 2>/dev/null

echo ""
echo "[2/7] Boot partition (FAT32)"

for firmware_file in start.elf splash.bmp; do
    if [ -s "$TMPDIR/boot/$firmware_file" ]; then
        pass "$firmware_file exists ($(stat -c%s "$TMPDIR/boot/$firmware_file" 2>/dev/null || stat -f%z "$TMPDIR/boot/$firmware_file") bytes)"
    else
        fail "$firmware_file MISSING or empty"
    fi
done

if [ -s "$TMPDIR/boot/initramfs8" ]; then
    pass "initramfs8 exists ($(stat -c%s "$TMPDIR/boot/initramfs8" 2>/dev/null || stat -f%z "$TMPDIR/boot/initramfs8") bytes)"
else
    fail "initramfs8 MISSING or empty"
fi

if grep -q '^auto_initramfs=1' "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: auto_initramfs=1"
else
    fail "config.txt: auto_initramfs=1 missing"
fi

if grep -qw 'resize' "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: resize token present"
else
    fail "cmdline.txt: resize token missing"
fi

if grep -Eq '^[[:space:]]*kernel[[:space:]]*=[[:space:]]*u-boot\.bin([[:space:]]*(#.*)?)?$' \
    "$TMPDIR/boot/config.txt" 2>/dev/null; then
    fail "config.txt: U-Boot kernel override should be removed"
else
    pass "config.txt: no U-Boot kernel override"
fi

if [ -e "$TMPDIR/boot/u-boot.bin" ]; then
    fail "u-boot.bin should be removed from boot partition"
else
    pass "u-boot.bin absent"
fi

# Check config.txt. Newer m5stack-linux-dtoverlays split the legacy
# cardputerzero-overlay into board-revision specific overlays.
CARDPUTERZERO_OVERLAYS=(
    "cardputerzero-v3-overlay"
    "cardputerzero-v5-overlay"
    "cardputerzero-overlay"
)

FOUND_CARDPUTERZERO_OVERLAY=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    if grep -q "dtoverlay=${overlay}" "$TMPDIR/boot/config.txt" 2>/dev/null; then
        FOUND_CARDPUTERZERO_OVERLAY="$overlay"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_OVERLAY" ]; then
    pass "config.txt: dtoverlay=${FOUND_CARDPUTERZERO_OVERLAY}"
else
    fail "config.txt: missing CardputerZero dtoverlay"
fi

if grep -q "dtparam=spi=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=spi=on"
else
    fail "config.txt: missing dtparam=spi=on"
fi

if grep -q "dtparam=i2c_arm=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=i2c_arm=on"
else
    fail "config.txt: missing dtparam=i2c_arm=on"
fi


# Check overlay dtbo
FOUND_CARDPUTERZERO_DTBO=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    dtbo="$TMPDIR/boot/overlays/${overlay}.dtbo"
    if [ -f "$dtbo" ]; then
        FOUND_CARDPUTERZERO_DTBO="$dtbo"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_DTBO" ]; then
    pass "overlays/$(basename "$FOUND_CARDPUTERZERO_DTBO") exists ($(stat -c%s "$FOUND_CARDPUTERZERO_DTBO" 2>/dev/null || stat -f%z "$FOUND_CARDPUTERZERO_DTBO") bytes)"
else
    fail "CardputerZero overlay dtbo MISSING"
fi

# Check cmdline.txt
if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "quiet") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: quiet present"
else
    fail "cmdline.txt: quiet missing"
fi

if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "splash") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" >/dev/null 2>&1; then
    fail "cmdline.txt: splash should be removed for CardputerZero"
else
    pass "cmdline.txt: splash removed"
fi

if grep -q "plymouth.ignore-serial-consoles" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: plymouth.ignore-serial-consoles should be removed for CardputerZero"
else
    pass "cmdline.txt: plymouth.ignore-serial-consoles removed"
fi

if grep -q "console=serial0,115200" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: console=serial0,115200 should be removed for CardputerZero"
else
    pass "cmdline.txt: console=serial0,115200 removed"
fi

umount "$TMPDIR/boot" 2>/dev/null || true

echo ""
echo "[3/7] First-boot resize chain"

ROOTFS_MOUNT="$TMPDIR/rootfs"
mkdir -p "$ROOTFS_MOUNT"
ROOTFS_MOUNTED=0
if mount -o loop,ro "$TMPDIR/root.ext4" "$ROOTFS_MOUNT" 2>/dev/null; then
    ROOTFS_MOUNTED=1
else
    fail "root.ext4 could not be mounted for resize checks"
fi

if [ "$ROOTFS_MOUNTED" = 1 ]; then
    RESIZE_EARLY="$ROOTFS_MOUNT/usr/share/initramfs-tools/scripts/local-premount/resize_early"
    RESIZE_HOOK="$ROOTFS_MOUNT/usr/share/initramfs-tools/hooks/cardputerzero-resize"

    if [ -x "$RESIZE_EARLY" ] && grep -q "resize2fs" "$RESIZE_EARLY"; then
        pass "initramfs resize_early runs resize2fs"
    else
        fail "initramfs resize_early missing resize2fs"
    fi

    if [ -x "$RESIZE_HOOK" ] && grep -q "resize2fs" "$RESIZE_HOOK"; then
        pass "initramfs hook copies resize2fs"
    else
        fail "initramfs resize2fs hook MISSING"
    fi

    RPI_RESIZE_DROPIN="$ROOTFS_MOUNT/etc/systemd/system/rpi-resize.service.d/10-cardputerzero-no-growfs-fstrim.conf"
    if [ -f "$RPI_RESIZE_DROPIN" ] &&
        grep -q '^Wants=first-boot-complete.target$' "$RPI_RESIZE_DROPIN" &&
        ! grep -Eq 'systemd-growfs-root|fstrim' "$RPI_RESIZE_DROPIN"; then
        pass "rpi-resize override keeps first-boot-complete but skips growfs/fstrim"
    else
        fail "rpi-resize override missing or still pulls growfs/fstrim"
    fi

    if [ -L "$ROOTFS_MOUNT/etc/systemd/system/sysinit.target.wants/rpi-resize.service" ]; then
        pass "rpi-resize.service enabled (first-boot-complete chain present)"
    else
        fail "rpi-resize.service not enabled; first-boot-complete may never be reached"
    fi

    FSTRIM_TIMER_TARGET="$(readlink "$ROOTFS_MOUNT/etc/systemd/system/fstrim.timer" 2>/dev/null || true)"
    if [ "$FSTRIM_TIMER_TARGET" = "/dev/null" ]; then
        pass "fstrim.timer masked (no first-boot TRIM)"
    else
        fail "fstrim.timer not masked"
    fi

    if [ -L "$ROOTFS_MOUNT/etc/systemd/system/timers.target.wants/fstrim.timer" ]; then
        fail "fstrim.timer still enabled in timers.target.wants"
    else
        pass "fstrim.timer not enabled in timers.target.wants"
    fi

    umount "$ROOTFS_MOUNT" 2>/dev/null || true
fi

# 32GB shipping cards: the image should use ~32768 bytes/inode.  This keeps
# the first-boot inode-table initialization small while leaving enough inodes
# for the 6.4GB build filesystem and the grown 32GB filesystem.
INODE_COUNT=$(LC_ALL=C dumpe2fs -h "$TMPDIR/root.ext4" 2>/dev/null | awk -F: '/Inode count/{gsub(/[^0-9]/, "", $2); print $2; exit}' || true)
BLOCK_COUNT=$(LC_ALL=C dumpe2fs -h "$TMPDIR/root.ext4" 2>/dev/null | awk -F: '/Block count/{gsub(/[^0-9]/, "", $2); print $2; exit}' || true)
BLOCK_SIZE=$(LC_ALL=C dumpe2fs -h "$TMPDIR/root.ext4" 2>/dev/null | awk -F: '/Block size/{gsub(/[^0-9]/, "", $2); print $2; exit}' || true)
if [ -n "$INODE_COUNT" ] && [ -n "$BLOCK_COUNT" ] && [ -n "$BLOCK_SIZE" ] && [ "$INODE_COUNT" -gt 0 ]; then
    INODE_RATIO=$((BLOCK_COUNT * BLOCK_SIZE / INODE_COUNT))
    if [ "$INODE_RATIO" -ge 30000 ] && [ "$INODE_RATIO" -le 36000 ]; then
        pass "root filesystem inode ratio ~$INODE_RATIO bytes/inode"
    else
        fail "root filesystem inode ratio $INODE_RATIO, expected ~32768"
    fi
else
    fail "could not read root filesystem inode count"
fi

echo ""
echo "[4/7] Kernel modules (/lib/modules/*/extra/)"

REQUIRED_MODULES=(
    "bq27xxx_battery.ko"  
    "bq27xxx_battery_i2c.ko"
    "m5ioe1.ko"
    "tca8418_keypad_m5stack.ko"
    "es8389_m5stack.ko"
    "pwm_bl_m5stack.ko"
    "st7789v_m5stack.ko"
)

for mod in "${REQUIRED_MODULES[@]}"; do
    if debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -q .; then
        KVER=$(debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -o '[0-9][^ ]*rpi-v8')
        if debugfs -R "stat lib/modules/${KVER}/extra/${mod}" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
            SIZE=$(debugfs -R "stat lib/modules/${KVER}/extra/${mod}" "$TMPDIR/root.ext4" 2>/dev/null | grep "Size:" | awk '{print $2}')
            pass "$mod ($SIZE bytes)"
        else
            fail "$mod MISSING"
        fi
    fi
done

DTOVERLAYS_COMMIT=$(debugfs -R "cat etc/cardputerzero-dtoverlays.commit" \
    "$TMPDIR/root.ext4" 2>/dev/null | tr -d '\r\n' || true)
if [[ "$DTOVERLAYS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    pass "dtoverlays source commit recorded ($DTOVERLAYS_COMMIT)"
else
    fail "dtoverlays source commit MISSING or invalid"
fi

echo ""
echo "[5/7] APPLaunch"

if debugfs -R "stat usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    pass "APPLaunch binary installed"
else
    fail "APPLaunch binary MISSING"
fi

if debugfs -R "cat usr/lib/systemd/user/APPLaunch.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "ExecStart"; then
    pass "APPLaunch user service exists"
else
    # Try alternative path
    if debugfs -R "cat lib/systemd/user/APPLaunch.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "ExecStart"; then
        pass "APPLaunch user service exists"
    else
        fail "APPLaunch user service MISSING"
    fi
fi

# APPLaunch is installed but intentionally not enabled by default.
if debugfs -R "ls etc/systemd/user/default.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "APPLaunch"; then
    fail "APPLaunch user service enabled by default"
else
    pass "APPLaunch user service not enabled by default"
fi

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "APPLaunch"; then
    fail "APPLaunch system service enabled by default"
else
    pass "APPLaunch system service not enabled by default"
fi

echo ""
echo "[6/7] Modprobe configuration"

if debugfs -R "cat etc/modules-load.d/cardputerzero.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "i2c-dev"; then
    pass "modules-load.d: i2c-dev"
else
    fail "modules-load.d: i2c-dev MISSING"
fi

if debugfs -R "cat etc/modprobe.d/blacklist-8192cu.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "blacklist 8192cu"; then
    pass "modprobe.d: blacklist 8192cu"
else
    fail "modprobe.d: blacklist 8192cu MISSING"
fi

if debugfs -R "cat etc/modprobe.d/rfkill_default.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rfkill"; then
    pass "modprobe.d: rfkill default_state=0"
else
    fail "modprobe.d: rfkill MISSING"
fi

echo ""
echo "[7/7] Packages"

set +e
debugfs -R "cat var/lib/dpkg/status" "$TMPDIR/root.ext4" > "$TMPDIR/dpkg_status" 2>/dev/null
echo "  dpkg_status size: $(wc -c < "$TMPDIR/dpkg_status") bytes"

if grep -q "^Package: applaunch$" "$TMPDIR/dpkg_status"; then
    APPLAUNCH_STATUS=$(sed -n '/^Package: applaunch$/,/^$/p' "$TMPDIR/dpkg_status")
    VER=$(printf '%s\n' "$APPLAUNCH_STATUS" | awk '$1 == "Version:" { print $2; exit }')
    pass "applaunch package installed (v$VER)"
else
    fail "applaunch package NOT installed"
fi

if grep -q "^Package: fastfetch$" "$TMPDIR/dpkg_status"; then
    pass "fastfetch installed"
else
    fail "fastfetch NOT installed"
fi

if grep -q "^Package: cmatrix$" "$TMPDIR/dpkg_status"; then
    pass "cmatrix installed"
else
    fail "cmatrix NOT installed"
fi
set -e

echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo " ✓ ALL CHECKS PASSED"
    echo "=========================================="
    exit 0
else
    echo " ✗ $ERRORS CHECK(S) FAILED"
    echo "=========================================="
    exit 1
fi
