#!/bin/bash -e

# Download the requested APPLaunch version, or the newest version when unset.
AUTH_ARGS=()
GITHUB_AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$GITHUB_AUTH_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}")
fi

LAUNCHER_RELEASES_URL="${LAUNCHER_RELEASES_URL:-https://api.github.com/repos/CardputerZero/launcher/releases?per_page=100}"
DEB_SOURCE_FILE="${APPLAUNCH_DEB_FILE:-}"
REQUESTED_VERSION="${APPLAUNCH_VERSION:-}"
DEB_URL=""
DEB_FILE=""

if [ -n "$DEB_SOURCE_FILE" ]; then
    if [ ! -f "$DEB_SOURCE_FILE" ]; then
        echo "ERROR: APPLAUNCH_DEB_FILE does not exist: $DEB_SOURCE_FILE"
        exit 1
    fi
    DEB_FILE="${DEB_SOURCE_FILE##*/}"
    echo "Using local APPLaunch package: $DEB_SOURCE_FILE"
    install -m 644 "$DEB_SOURCE_FILE" "${ROOTFS_DIR}/tmp/${DEB_FILE}"
else
    RELEASES_RESPONSE=$(mktemp)
    trap 'rm -f "$RELEASES_RESPONSE"' EXIT

    echo "Querying APPLaunch releases API: $LAUNCHER_RELEASES_URL"
    curl -fsSL "${AUTH_ARGS[@]}" -o "$RELEASES_RESPONSE" "$LAUNCHER_RELEASES_URL"

    ASSET_INFO=$(python3 - "$RELEASES_RESPONSE" "$REQUESTED_VERSION" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    releases = json.load(f)
requested_version = sys.argv[2]

if not isinstance(releases, list):
    releases = [releases]

pattern = re.compile(r"^applaunch_(?P<version>.+)-(?P<revision>[^_]+)_arm64\.deb$", re.IGNORECASE)
candidates = []
for release in releases:
    if release.get("draft"):
        continue
    published_at = release.get("published_at") or release.get("created_at") or ""
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        match = pattern.fullmatch(name)
        if match and (not requested_version or match.group("version") == requested_version):
            candidates.append((published_at, release.get("tag_name", ""), name, asset["url"]))

if candidates:
    published_at, tag_name, name, api_url = max(candidates)
    print(f"{name}\t{api_url}\t{tag_name}\t{published_at}")
PY
)

    if [ -n "$ASSET_INFO" ]; then
        IFS=$'\t' read -r DEB_FILE DEB_URL RELEASE_TAG RELEASE_DATE <<< "$ASSET_INFO"
        echo "Selected APPLaunch release ${RELEASE_TAG:-unknown} (${RELEASE_DATE:-unknown}): ${DEB_FILE}"
    fi
fi
if [ -z "$DEB_SOURCE_FILE" ] && [ -z "$DEB_URL" ]; then
    if [ -n "$REQUESTED_VERSION" ]; then
        echo "ERROR: Could not find APPLaunch version $REQUESTED_VERSION"
    else
        echo "ERROR: Could not find the newest APPLaunch release"
    fi
    exit 1
fi

if [ -z "$DEB_SOURCE_FILE" ]; then
    DEB_FILE="${DEB_FILE:-${DEB_URL##*/}}"
    case "$DEB_FILE" in
        *.deb) ;;
        # Private repositories only serve assets through the releases API, whose
        # URLs end in a numeric id, and apt only accepts local packages
        # named *.deb.
        *) DEB_FILE="applaunch.deb" ;;
    esac
    echo "Downloading APPLaunch from: $DEB_URL"
    curl -fsSL "${AUTH_ARGS[@]}" \
        -H "Accept: application/octet-stream" \
        -o "${ROOTFS_DIR}/tmp/${DEB_FILE}" \
        -L "$DEB_URL"
fi

DEB_PATH="${ROOTFS_DIR}/tmp/${DEB_FILE}"
if ! dpkg-deb --info "$DEB_PATH" >/dev/null 2>&1; then
    echo "ERROR: APPLaunch input is not a valid Debian package: $DEB_PATH"
    exit 1
fi
if [ "$(dpkg-deb -f "$DEB_PATH" Architecture)" != "arm64" ]; then
    echo "ERROR: APPLaunch package architecture must be arm64"
    exit 1
fi
echo "APPLaunch package: $(dpkg-deb -f "$DEB_PATH" Package Version Architecture)"
sha256sum "$DEB_PATH"

install -m 644 files/start.elf "${ROOTFS_DIR}/boot/firmware/start.elf"
install -m 644 files/fixup.dat "${ROOTFS_DIR}/boot/firmware/fixup.dat"
install -m 644 files/splash.bmp "${ROOTFS_DIR}/boot/firmware/splash.bmp"
install -m 644 files/CardputerZero_splash_custom.bin \
    "${ROOTFS_DIR}/boot/firmware/CardputerZero_splash_custom.bin"
sed -i \
    -e '/^splash_screen=/d' \
    -e '/^gpu_mem=/d' \
    -e '1i splash_screen=CardputerZero_splash_custom.bin\ngpu_mem=128\n' \
    "${ROOTFS_DIR}/boot/firmware/config.txt"
# Install APPLaunch normally so dpkg registers the package. Then adjust startup
# state directly in the rootfs; LaunchWizard controls first-boot APPLaunch start.
on_chroot << CHROOT
set -e
dpkg -i "/tmp/${DEB_FILE}"
install -d -m 700 /var/cache/APPLaunch/updates
install -m 600 "/tmp/${DEB_FILE}" /var/cache/APPLaunch/updates/installed.deb
rm -f "/tmp/${DEB_FILE}"
# The package postinst enables the ADB hotplug monitor, but the product
# default is ADB off. Disable it here rather than in stage4 so the lite
# profile (which stops after stage2) ships the same default.
systemctl disable cardputer-adb-hotplug.service adbd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service \
    /etc/systemd/system/multi-user.target.wants/adbd.service
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

# The Raspberry Pi userconfig/piwiz entry points are disabled at export time.
# Use LaunchWizard's explicit one-shot marker so product OOBE stays independent
# of those upstream desktop files. LaunchWizard removes this after completion.
install -d -m 700 "${ROOTFS_DIR}/var/lib/LaunchWizard"
touch "${ROOTFS_DIR}/var/lib/LaunchWizard/run-oobe"
chmod 600 "${ROOTFS_DIR}/var/lib/LaunchWizard/run-oobe"

# One-shot keyboard tutorial marker: LaunchWizard consumes it on first boot and
# shows the guide before the OOBE decision, whether or not the OOBE itself runs
# (Imager-provisioned devices skip the OOBE but still get the guide once).
touch "${ROOTFS_DIR}/var/lib/LaunchWizard/run-keyboard-guide"
chmod 600 "${ROOTFS_DIR}/var/lib/LaunchWizard/run-keyboard-guide"

install -d "${ROOTFS_DIR}/usr/lib/systemd/user"
cat > "${ROOTFS_DIR}/usr/lib/systemd/user/APPLaunch.service" << 'EOF'
[Unit]
Description=APPLaunch Service
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
# No desktop session ever runs xdg-user-dirs-update on this product, so create
# the standard folders (Music, Pictures, ...) before the launcher starts.
ExecStartPre=-/usr/bin/xdg-user-dirs-update
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

# Keep realtime media scheduling deterministic on the low-memory target.
for config_dir in \
    pipewire.conf.d \
    pipewire-pulse.conf.d \
    filter-chain.conf.d \
    client.conf.d; do
    install -d "${ROOTFS_DIR}/etc/pipewire/${config_dir}"
    install -m 644 files/20-rtkit-direct.conf \
        "${ROOTFS_DIR}/etc/pipewire/${config_dir}/20-rtkit-direct.conf"
done

install -d "${ROOTFS_DIR}/etc/systemd/system/user@1000.service.d"
install -m 644 files/20-rtkit-order.conf \
    "${ROOTFS_DIR}/etc/systemd/system/user@1000.service.d/20-rtkit-order.conf"

# Factory default output volume: WirePlumber's stock 40% (0.064 linear) is
# nearly inaudible on the small speaker, and the first-boot keyboard guide
# plays before anyone can reach the volume settings (bug #262).
install -d "${ROOTFS_DIR}/etc/wireplumber/wireplumber.conf.d"
install -m 644 files/50-cardputerzero-default-volume.conf \
    "${ROOTFS_DIR}/etc/wireplumber/wireplumber.conf.d/50-cardputerzero-default-volume.conf"

for audio_service in pipewire pipewire-pulse filter-chain; do
    service_dropin="${ROOTFS_DIR}/home/pi/.config/systemd/user/${audio_service}.service.d"
    install -d -m 755 -o 1000 -g 1000 "$service_dropin"
    install -m 644 -o 1000 -g 1000 files/20-audio-rlimits.conf \
        "$service_dropin/20-audio-rlimits.conf"
done

on_chroot << 'CHROOT'
systemctl enable rtkit-daemon.service
CHROOT

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

# # Root partition resize fallback on first boot.
# install -m 755 -d "${ROOTFS_DIR}/usr/lib/cardputerzero"
# install -m 755 files/resize-root "${ROOTFS_DIR}/usr/lib/cardputerzero/resize-root"
# install -m 644 files/cardputerzero-resize.service "${ROOTFS_DIR}/etc/systemd/system/cardputerzero-resize.service"
rm -f "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/adbd.service"

# on_chroot << 'CHROOT'
# systemctl enable cardputerzero-resize.service
# CHROOT
