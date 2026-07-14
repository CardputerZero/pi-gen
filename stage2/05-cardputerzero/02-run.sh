#!/bin/bash -e

# Download the newest versioned APPLaunch deb outside chroot.
AUTH_ARGS=()
GITHUB_AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$GITHUB_AUTH_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}")
fi

LAUNCHER_RELEASES_URL="${LAUNCHER_RELEASES_URL:-https://api.github.com/repos/CardputerZero/launcher/releases}"
DEB_URL="${APPLAUNCH_DEB_URL:-}"
DEB_FILE=""

if [ -z "$DEB_URL" ]; then
    RELEASES_RESPONSE=$(mktemp)
    trap 'rm -f "$RELEASES_RESPONSE"' EXIT

    echo "Querying APPLaunch releases API: $LAUNCHER_RELEASES_URL"
    curl -fsSL "${AUTH_ARGS[@]}" -o "$RELEASES_RESPONSE" "$LAUNCHER_RELEASES_URL"

    ASSET_INFO=$(python3 - "$RELEASES_RESPONSE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    releases = json.load(f)

if not isinstance(releases, list):
    releases = [releases]

pattern = re.compile(r"^applaunch_[^/]+_m5stack1_arm64\.deb$", re.IGNORECASE)
for release in releases:
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        if pattern.fullmatch(name):
            print(f"{name}\t{asset['url']}")
            raise SystemExit(0)
PY
)

    if [ -n "$ASSET_INFO" ]; then
        DEB_FILE="${ASSET_INFO%%$'\t'*}"
        DEB_URL="${ASSET_INFO#*$'\t'}"
    fi
fi

UBOOT_URL="${UBOOT_FIRMWARE_URL:-https://github.com/CardputerZero/u-boot/releases/latest/download/uboot-firmware-m5stack.tar.gz}"


if [ -z "$DEB_URL" ]; then
    echo "ERROR: Could not find an APPLaunch m5stack1 arm64 deb"
    exit 1
fi

DEB_FILE="${DEB_FILE:-${DEB_URL##*/}}"
echo "Downloading APPLaunch from: $DEB_URL"
curl -fsSL "${AUTH_ARGS[@]}" \
    -H "Accept: application/octet-stream" \
    -o "${ROOTFS_DIR}/tmp/${DEB_FILE}" \
    -L "$DEB_URL"

echo "Downloading U-Boot firmware from: $UBOOT_URL"
curl -fsSL -o "${ROOTFS_DIR}/tmp/uboot-firmware.tar.gz" -L "$UBOOT_URL"
tar -xzf "${ROOTFS_DIR}/tmp/uboot-firmware.tar.gz" -C "${ROOTFS_DIR}/boot/firmware"

# Install APPLaunch normally so dpkg registers the package. Then adjust startup
# state directly in the rootfs; LaunchWizard controls first-boot APPLaunch start.
on_chroot << CHROOT
set -e
dpkg -i "/tmp/${DEB_FILE}"
rm -f "/tmp/${DEB_FILE}"
CHROOT

if [ ! -x "${ROOTFS_DIR}/usr/share/APPLaunch/bin/LaunchWizard" ]; then
    echo "ERROR: LaunchWizard missing from installed APPLaunch package"
    exit 1
fi

install -d "${ROOTFS_DIR}/usr/lib/systemd/system"
cat > "${ROOTFS_DIR}/usr/lib/systemd/system/LaunchWizard.service" << 'EOF'
[Unit]
Description=LaunchWizard First Boot Setup
After=systemd-user-sessions.service plymouth-quit.service
Before=display-manager.service
Wants=graphical.target plymouth-quit.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/plymouth quit
ExecStartPre=-/usr/bin/timeout 3 /usr/bin/plymouth --wait
ExecStart=/usr/share/APPLaunch/bin/LaunchWizard
WorkingDirectory=/usr/share/APPLaunch
Restart=on-failure
RestartSec=1
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

install -d "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/LaunchWizard.service \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/LaunchWizard.service"

install -d "${ROOTFS_DIR}/usr/lib/systemd/user"
cat > "${ROOTFS_DIR}/usr/lib/systemd/user/APPLaunch.service" << 'EOF'
[Unit]
Description=APPLaunch Service
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
ExecStart=/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
WorkingDirectory=/usr/share/APPLaunch
Restart=always
RestartSec=1
StartLimitInterval=0

[Install]
WantedBy=default.target
EOF

rm -f "${ROOTFS_DIR}/etc/systemd/user/default.target.wants/APPLaunch.service"
rm -f "${ROOTFS_DIR}/home/pi/.config/systemd/user/default.target.wants/APPLaunch.service"
rm -f "${ROOTFS_DIR}/var/lib/systemd/linger/pi"

install -d "${ROOTFS_DIR}/etc/xdg/autostart"
cat > "${ROOTFS_DIR}/etc/xdg/autostart/piwiz.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Raspberry Pi First-Run Wizard
Exec=piwiz
StartupNotify=true
EOF

install -d "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d"
cat > "${ROOTFS_DIR}/etc/lightdm/lightdm.conf.d/99-cardputerzero-firstboot.conf" << 'EOF'
[Seat:*]
autologin-user=rpi-first-boot-wizard
autologin-session=rpd-labwc
EOF

# Install U-Boot firmware
sed -i '1i kernel=u-boot.bin' ${ROOTFS_DIR}/boot/firmware/config.txt



# Append custom cmdline parameters for CardputerZero.
sed -i 's/$/ quiet fbcon=map:off cfg80211.ieee80211_regdom=AE/' \
    "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# Clean up CardputerZero cmdline tokens.
for cmd in "${ROOTFS_DIR}/boot/firmware/cmdline.txt" "${ROOTFS_DIR}/boot/cmdline.txt"; do
    [ -f "$cmd" ] || continue
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
    ' "$cmd" > "${cmd}.tmp"
    mv "${cmd}.tmp" "$cmd"
done

# Module load config
cat > "${ROOTFS_DIR}/etc/modules-load.d/cardputerzero.conf" << 'EOF'
i2c-dev
EOF

# Disable systemd-backlight auto-start for backlight devices.
install -d "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/systemd-backlight@backlight:backlight.service"

# Modprobe configs
cat > "${ROOTFS_DIR}/etc/modprobe.d/blacklist-8192cu.conf" << 'EOF'
blacklist 8192cu
EOF

cat > "${ROOTFS_DIR}/etc/modprobe.d/rfkill_default.conf" << 'EOF'
options rfkill default_state=0
EOF

# Persistent journal — retain logs across reboots for debugging
mkdir -p "${ROOTFS_DIR}/var/log/journal"
mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/persist.conf" << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF

# Root partition resize on first boot (U-Boot skips initramfs so
# raspberrypi-sys-mods' resize_early never runs)
install -m 755 -d "${ROOTFS_DIR}/usr/lib/cardputerzero"
install -m 755 files/resize-root "${ROOTFS_DIR}/usr/lib/cardputerzero/resize-root"
install -m 644 files/cardputerzero-resize.service "${ROOTFS_DIR}/etc/systemd/system/cardputerzero-resize.service"

on_chroot << 'CHROOT'
systemctl enable cardputerzero-resize.service
CHROOT
