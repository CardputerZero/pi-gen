#!/bin/bash
# Verify CardputerZero image contains all required customizations.
# Usage: VERIFY_PROFILE=full|lite ./tools/verify-image.sh <image.img>
# Exit 0 = all checks pass, Exit 1 = failure (breaks CI)

set -euo pipefail

IMG="${1:?Usage: $0 <image.img>}"
VERIFY_PROFILE="${VERIFY_PROFILE:-full}"
EXPECTED_DTOVERLAYS_COMMIT="${EXPECTED_DTOVERLAYS_COMMIT:-}"
EXPECTED_APPLAUNCH_VERSION="${EXPECTED_APPLAUNCH_VERSION:-}"
ERRORS=0

case "$VERIFY_PROFILE" in
    full|lite) ;;
    *)
        echo "ERROR: VERIFY_PROFILE must be 'full' or 'lite'" >&2
        exit 2
        ;;
esac
TMPDIR=$(mktemp -d)
cleanup() {
    mountpoint -q "$TMPDIR/boot" && umount "$TMPDIR/boot" || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "  ✓ $1"; }

check_aarch64_elf() {
    local image_path="$1"
    local label="$2"
    local output="$TMPDIR/${label}.elf"

    if debugfs -R "dump -p ${image_path} ${output}" \
        "$TMPDIR/root.ext4" >/dev/null 2>&1 && \
        readelf -h "$output" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64'; then
        pass "$label is an ARM64 ELF"
    else
        fail "$label is missing or is not an ARM64 ELF"
    fi
}

echo "=========================================="
echo " CardputerZero Image Verification"
echo "=========================================="
echo " Image: $IMG"
echo " Profile: $VERIFY_PROFILE"
echo ""

# --- Extract partitions ---
# Get partition offsets (sectors, 512 bytes each)
BOOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $2}')
BOOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $3}')
ROOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $2}')
ROOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $3}')

BOOT_SECTORS=$((BOOT_END - BOOT_START + 1))
ROOT_SECTORS=$((ROOT_END - ROOT_START + 1))

echo "[1/6] Extracting partitions..."
dd if="$IMG" of="$TMPDIR/boot.fat" bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" 2>/dev/null
dd if="$IMG" of="$TMPDIR/root.ext4" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" 2>/dev/null

# --- Mount boot ---
mkdir -p "$TMPDIR/boot"
mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot" 2>/dev/null

echo ""
echo "[2/6] Boot partition (FAT32)"

for firmware_file in start.elf splash.bmp; do
    if [ -s "$TMPDIR/boot/$firmware_file" ]; then
        pass "$firmware_file exists ($(stat -c%s "$TMPDIR/boot/$firmware_file" 2>/dev/null || stat -f%z "$TMPDIR/boot/$firmware_file") bytes)"
    else
        fail "$firmware_file MISSING or empty"
    fi
done

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


# Check the DTBO selected by config.txt. Multiple board revisions can coexist
# in /boot/overlays, so checking the first file found can inspect the wrong
# hardware revision.
FOUND_CARDPUTERZERO_DTBO=""
if [ -n "$FOUND_CARDPUTERZERO_OVERLAY" ]; then
    dtbo="$TMPDIR/boot/overlays/${FOUND_CARDPUTERZERO_OVERLAY}.dtbo"
    if [ -f "$dtbo" ]; then
        FOUND_CARDPUTERZERO_DTBO="$dtbo"
    fi
fi

if [ -n "$FOUND_CARDPUTERZERO_DTBO" ]; then
    pass "overlays/$(basename "$FOUND_CARDPUTERZERO_DTBO") exists ($(stat -c%s "$FOUND_CARDPUTERZERO_DTBO" 2>/dev/null || stat -f%z "$FOUND_CARDPUTERZERO_DTBO") bytes)"

    if command -v dtc >/dev/null 2>&1 && \
        dtc -I dtb -O dts -o "$TMPDIR/cardputerzero-overlay.dts" \
            "$FOUND_CARDPUTERZERO_DTBO" 2>/dev/null; then
        for property in \
            "m5stack,mono" \
            "simple-audio-card,fully-routed" \
            "Speaker Switch DRV"; do
            if grep -q "$property" "$TMPDIR/cardputerzero-overlay.dts"; then
                pass "audio overlay contains: $property"
            else
                fail "audio overlay missing: $property"
            fi
        done
    else
        fail "unable to decompile CardputerZero overlay (install device-tree-compiler)"
    fi
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
echo "[3/6] Kernel modules (/lib/modules/*/extra/)"

REQUIRED_MODULES=(
    "bq27xxx_battery.ko"  
    "bq27xxx_battery_i2c.ko"
    "cardputerzero-audio.ko"
    "m5ioe1.ko"
    "simple-amplifier.ko"
    "tca8418_keypad_m5stack.ko"
    "es8389_m5stack.ko"
    "pwm_bl_m5stack.ko"
    "st7789v_m5stack.ko"
)

KVER=$(debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -o '[0-9][^ ]*rpi-v8' | head -1)
if [ -z "$KVER" ]; then
    fail "unable to identify the rpi-v8 kernel module directory"
fi

for mod in "${REQUIRED_MODULES[@]}"; do
    MODULE_STAT=$(debugfs -R "stat lib/modules/${KVER}/extra/${mod}" \
        "$TMPDIR/root.ext4" 2>/dev/null || true)
    SIZE=$(printf '%s\n' "$MODULE_STAT" |
        sed -n 's/.*Size:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$SIZE" ] && [ "$SIZE" -gt 0 ]; then
        pass "$mod ($SIZE bytes)"
    else
        fail "$mod MISSING or empty"
    fi
done

DTOVERLAYS_COMMIT=$(debugfs -R "cat etc/cardputerzero-dtoverlays.commit" \
    "$TMPDIR/root.ext4" 2>/dev/null | tr -d '\r\n' || true)
if printf '%s\n' "$DTOVERLAYS_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
    pass "dtoverlays source commit recorded ($DTOVERLAYS_COMMIT)"
    if [ -n "$EXPECTED_DTOVERLAYS_COMMIT" ] && \
        [ "$DTOVERLAYS_COMMIT" != "$EXPECTED_DTOVERLAYS_COMMIT" ]; then
        fail "dtoverlays commit mismatch: expected $EXPECTED_DTOVERLAYS_COMMIT"
    fi
else
    fail "dtoverlays source commit MISSING or invalid"
fi

echo ""
echo "[4/6] APPLaunch"

if debugfs -R "stat usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    pass "APPLaunch binary installed"
    check_aarch64_elf \
        "usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" \
        "APPLaunch"
else
    fail "APPLaunch binary MISSING"
fi

if debugfs -R "stat usr/share/APPLaunch/bin/LaunchWizard" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    pass "LaunchWizard binary installed"
    check_aarch64_elf \
        "usr/share/APPLaunch/bin/LaunchWizard" \
        "LaunchWizard"
else
    fail "LaunchWizard binary MISSING"
fi

if debugfs -R "cat usr/lib/systemd/system/LaunchWizard.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "ExecStart=/usr/share/APPLaunch/bin/LaunchWizard"; then
    pass "LaunchWizard system service exists"
else
    fail "LaunchWizard system service MISSING"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/LaunchWizard.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    pass "LaunchWizard enabled for first boot"
else
    fail "LaunchWizard first-boot enablement MISSING"
fi

if debugfs -R "stat var/lib/LaunchWizard/run-oobe" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    pass "LaunchWizard explicit first-boot marker installed"
else
    fail "LaunchWizard first-boot marker MISSING"
fi

if debugfs -R "dump usr/share/APPLaunch/bin/LaunchWizard $TMPDIR/LaunchWizard" \
        "$TMPDIR/root.ext4" >/dev/null 2>&1 && \
        grep -a -q '/var/lib/LaunchWizard/run-oobe' "$TMPDIR/LaunchWizard"; then
    pass "LaunchWizard binary supports the explicit first-boot marker"
else
    fail "LaunchWizard binary does not support the first-boot marker"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/userconfig.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "Raspberry Pi console userconfig should not be enabled"
else
    pass "console userconfig disabled; LaunchWizard owns first boot"
fi

if debugfs -R "stat etc/systemd/system/display-manager.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "display-manager enabled during product OOBE"
else
    pass "display-manager disabled during product OOBE"
fi

if debugfs -R "stat etc/systemd/system/graphical.target.wants/lightdm.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "LightDM enabled during product OOBE"
else
    pass "LightDM disabled during product OOBE"
fi

CMDLINE=$(debugfs -R "cat boot/firmware/cmdline.txt" "$TMPDIR/root.ext4" 2>/dev/null || true)
if printf '%s\n' "$CMDLINE" | grep -Eq '(^|[[:space:]])cma=32M([[:space:]]|$)'; then
    pass "HDMI desktop CMA set to 32 MiB"
else
    fail "HDMI desktop CMA setting MISSING"
fi

if debugfs -R "cat usr/libexec/cardputerzero-hdmi-display" "$TMPDIR/root.ext4" 2>/dev/null | \
        grep -q '/var/lib/LaunchWizard/run-oobe'; then
    pass "HDMI hotplug helper preserves product OOBE"
else
    fail "HDMI hotplug helper MISSING or unsafe"
fi

if debugfs -R "cat usr/lib/systemd/system/cardputerzero-hdmi-display.service" "$TMPDIR/root.ext4" 2>/dev/null | \
        grep -q 'ExecStart=/usr/libexec/cardputerzero-hdmi-display --monitor'; then
    pass "HDMI display monitor service installed"
else
    fail "HDMI display monitor service MISSING"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/cardputerzero-hdmi-display.service" "$TMPDIR/root.ext4" 2>/dev/null | \
        grep -q "Inode:"; then
    pass "HDMI display monitor enabled"
else
    fail "HDMI display monitor not enabled"
fi

HDMI_RULE=$(debugfs -R "cat usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules" \
    "$TMPDIR/root.ext4" 2>/dev/null || true)
if printf '%s\n' "$HDMI_RULE" | grep -q 'TAG-="master-of-seat"'; then
    pass "Internal panel excluded from LightDM seats"
else
    fail "Internal panel LightDM seat exclusion MISSING"
fi

if debugfs -R "cat etc/lightdm/lightdm.conf.d/20-cardputerzero-hdmi.conf" \
        "$TMPDIR/root.ext4" 2>/dev/null | grep -q 'logind-check-graphical=true'; then
    pass "LightDM restricted to graphical seats"
else
    fail "LightDM graphical-seat restriction MISSING"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/adbd.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "ADB enabled by default"
else
    pass "ADB disabled by default"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "ADB hotplug monitor enabled while ADB defaults off"
else
    pass "ADB hotplug monitor disabled by default"
fi

if debugfs -R "stat etc/xdg/autostart/piwiz.desktop" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    fail "Raspberry Pi desktop piwiz should not be enabled"
else
    pass "desktop piwiz disabled; LaunchWizard owns first boot"
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

if debugfs -R "cat etc/pipewire/pipewire.conf.d/20-rtkit-direct.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rtportal.enabled = false"; then
    pass "PipeWire uses RTKit directly"
else
    fail "PipeWire direct-RTKit configuration MISSING"
fi

if debugfs -R "cat etc/systemd/system/user@1000.service.d/20-rtkit-order.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "After=rtkit-daemon.service"; then
    pass "user@1000 ordered after RTKit"
else
    fail "user@1000 RTKit ordering MISSING"
fi

if debugfs -R "cat home/pi/.config/systemd/user/pipewire.service.d/20-audio-rlimits.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "LimitRTPRIO=20"; then
    pass "pi PipeWire realtime limits configured"
else
    fail "pi PipeWire realtime limits MISSING"
fi

if debugfs -R "stat etc/systemd/system/multi-user.target.wants/rtkit-daemon.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Inode:"; then
    pass "rtkit-daemon enabled"
else
    fail "rtkit-daemon enablement MISSING"
fi

PANEL_CONFIG=$(debugfs -R "cat etc/xdg/wf-panel-pi/wf-panel-pi.ini" "$TMPDIR/root.ext4" 2>/dev/null || true)
if printf '%s\n' "$PANEL_CONFIG" | grep -Eq '^widgets_right=.*(^|[[:space:]])updater([[:space:]]|$)'; then
    fail "wf-panel-pi updater should be disabled"
else
    pass "wf-panel-pi updater disabled; PackageKit remains on demand"
fi

echo ""
echo "[5/6] Modprobe configuration"

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
echo "[6/6] Packages"

set +e
debugfs -R "cat var/lib/dpkg/status" "$TMPDIR/root.ext4" > "$TMPDIR/dpkg_status" 2>/dev/null
echo "  dpkg_status size: $(wc -c < "$TMPDIR/dpkg_status") bytes"

if grep -q "^Package: applaunch$" "$TMPDIR/dpkg_status"; then
    APPLAUNCH_STATUS=$(sed -n '/^Package: applaunch$/,/^$/p' "$TMPDIR/dpkg_status")
    VER=$(printf '%s\n' "$APPLAUNCH_STATUS" | \
        awk '$1 == "Version:" { print $2; exit }')
    ARCH=$(printf '%s\n' "$APPLAUNCH_STATUS" | \
        awk '$1 == "Architecture:" { print $2; exit }')
    pass "applaunch package installed (v$VER)"
    if [ "$ARCH" = "arm64" ]; then
        pass "applaunch package architecture is arm64"
    else
        fail "applaunch package architecture is '$ARCH', expected arm64"
    fi
    if [ -n "$EXPECTED_APPLAUNCH_VERSION" ] && \
        [ "$VER" != "$EXPECTED_APPLAUNCH_VERSION" ]; then
        fail "applaunch version mismatch: expected $EXPECTED_APPLAUNCH_VERSION"
    fi
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

CAMERA_PACKAGE=""
for package in cameraapp camera; do
    PACKAGE_STATUS=$(sed -n "/^Package: ${package}$/,/^$/p" "$TMPDIR/dpkg_status")
    PACKAGE_ARCH=$(printf '%s\n' "$PACKAGE_STATUS" |
        awk '$1 == "Architecture:" { print $2; exit }')
    if [ "$PACKAGE_ARCH" = "arm64" ]; then
        CAMERA_PACKAGE="$package"
        pass "$package installed (arm64)"
        break
    fi
done
if [ -z "$CAMERA_PACKAGE" ]; then
    fail "CameraApp NOT installed as arm64 (accepted packages: cameraapp or camera)"
fi

CUSTOM_PACKAGES=(
    "factorytest"
    "m5cardputerzero-cap-cc1101-nfc"
    "m5cardputerzero-cap-cc1101-subg-chat"
    "m5cardputerzero-cap-lora-1262-gps"
    "m5cardputerzero-compass"
    "m5cardputerzero-files"
    "m5cardputerzero-ir-remote"
    "m5cardputerzero-music"
    "m5cardputerzero-recorder"
)
for package in "${CUSTOM_PACKAGES[@]}"; do
    PACKAGE_STATUS=$(sed -n "/^Package: ${package}$/,/^$/p" "$TMPDIR/dpkg_status")
    PACKAGE_ARCH=$(printf '%s\n' "$PACKAGE_STATUS" |
        awk '$1 == "Architecture:" { print $2; exit }')
    if [ "$PACKAGE_ARCH" = "arm64" ]; then
        pass "$package installed (arm64)"
    else
        fail "$package NOT installed as arm64"
    fi
done

if [ "$VERIFY_PROFILE" = "full" ]; then
    DESKTOP_PACKAGES=(
        "chromium"
        "firefox"
        "libcamera-tools"
        "python3-picamera2"
        "rpicam-apps"
        "vlc"
    )
    for package in "${DESKTOP_PACKAGES[@]}"; do
        if grep -q "^Package: ${package}$" "$TMPDIR/dpkg_status"; then
            pass "$package installed"
        else
            fail "$package NOT installed"
        fi
    done

    FONT_PACKAGES=(
        "fonts-jetbrains-mono"
        "fonts-noto-cjk"
        "fonts-noto-cjk-extra"
    )
    for package in "${FONT_PACKAGES[@]}"; do
        if grep -q "^Package: ${package}$" "$TMPDIR/dpkg_status"; then
            pass "$package installed"
        else
            fail "$package NOT installed"
        fi
    done

    KEPT_FONTS=(
        "usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        "usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf"
        "usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf"
        "usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
        "usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc"
    )
    for font in "${KEPT_FONTS[@]}"; do
        if debugfs -R "stat ${font}" "$TMPDIR/root.ext4" 2>/dev/null | \
            grep -q "Size:"; then
            pass "font present: $(basename "$font")"
        else
            fail "font MISSING: $(basename "$font")"
        fi
    done

    EXCLUDED_FONTS=(
        "usr/share/fonts/truetype/dejavu/DejaVuSans-ExtraLight.ttf"
        "usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf"
        "usr/share/fonts/truetype/dejavu/DejaVuMathTeXGyre.ttf"
        "usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Thin.ttf"
        "usr/share/fonts/truetype/jetbrains-mono/JetBrainsMonoNL-Regular.ttf"
        "usr/share/fonts/opentype/noto/NotoSansCJK-Thin.ttc"
        "usr/share/fonts/opentype/noto/NotoSerifCJK-Light.ttc"
    )
    for font in "${EXCLUDED_FONTS[@]}"; do
        if debugfs -R "stat ${font}" "$TMPDIR/root.ext4" 2>/dev/null | \
            grep -q "Size:"; then
            fail "excluded font still present: $(basename "$font")"
        else
            pass "excluded font absent: $(basename "$font")"
        fi
    done
else
    pass "desktop-only package checks skipped for lite profile"
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
