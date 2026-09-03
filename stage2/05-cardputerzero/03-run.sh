#!/bin/bash -e

# Install CardputerZero app debs from GitHub releases. Asset names include the
# app version, so match package prefix/suffix instead of hard-coding versions.
AUTH_ARGS=()
GITHUB_AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$GITHUB_AUTH_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}")
fi

download_and_install_deb() {
    local app_name="$1"
    local api_url="$2"
    local deb_url_var="$3"
    local filename_pattern="$4"
    local apt_options="${5:-}"

    local deb_file_var="${deb_url_var%_URL}_FILE"
    local deb_source_file=""
    local deb_url=""
    local deb_file
    echo "Forcing latest ${app_name} release; ignoring ${deb_url_var} and ${deb_file_var}"
    if [ -n "$deb_source_file" ]; then
        if [ ! -f "$deb_source_file" ]; then
            echo "ERROR: ${deb_file_var} does not exist: $deb_source_file"
            exit 1
        fi
        deb_file="${deb_source_file##*/}"
        echo "Using local ${app_name} package: $deb_source_file"
        install -m 0644 "$deb_source_file" \
            "${ROOTFS_DIR}/tmp/${deb_file}"
    elif [ -z "$deb_url" ]; then
        local response_file
        local http_status
        local curl_exit
        local asset_info

        response_file=$(mktemp)
        echo "Querying ${app_name} releases API: ${api_url}"
        set +e
        http_status=$(curl -sSL \
            --retry 3 --retry-all-errors \
            --connect-timeout 15 --max-time 120 \
            "${AUTH_ARGS[@]}" \
            -o "$response_file" \
            -w '%{http_code}' \
            "$api_url")
        curl_exit=$?
        set -e
        echo "${app_name}: GitHub API HTTP status ${http_status} (curl exit ${curl_exit})"

        if [ "$curl_exit" -ne 0 ]; then
            rm -f "$response_file"
            echo "ERROR: Failed to query ${app_name} releases API"
            exit 1
        fi

        if ! [[ "$http_status" =~ ^2 ]]; then
            rm -f "$response_file"
            echo "ERROR: ${app_name} releases API returned HTTP ${http_status}"
            exit 1
        fi

        asset_info=$(python3 - "$response_file" "$filename_pattern" <<'PY'
import json
import re
import sys

response_path, filename_pattern = sys.argv[1], sys.argv[2]
with open(response_path, "r", encoding="utf-8") as f:
    data = json.load(f)

releases = data if isinstance(data, list) else [data]
pattern = re.compile(filename_pattern)
candidates = []
for release in releases:
    if release.get("draft") or release.get("prerelease"):
        continue
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        browser_url = asset.get("browser_download_url", "")
        api_url = asset.get("url", "")
        if pattern.search(name) or pattern.search(browser_url):
            published_at = release.get("published_at") or release.get("created_at") or ""
            candidates.append((published_at, name, api_url))

if candidates:
    _, name, api_url = max(candidates)
    print(f"{name}\t{api_url}")
PY
)
        rm -f "$response_file"

        if [ -n "$asset_info" ]; then
            deb_file="${asset_info%%$'\t'*}"
            deb_url="${asset_info#*$'\t'}"
        fi
    fi

    if [ -z "$deb_source_file" ] && [ -z "$deb_url" ]; then
        echo "ERROR: Could not find ${app_name} m5stack1 arm64 deb URL matching ${filename_pattern}"
        exit 1
    fi

    if [ -z "$deb_source_file" ]; then
        deb_file="${deb_file:-${deb_url##*/}}"
        case "$deb_file" in
            *.deb) ;;
            # Private repositories only serve assets through the releases API,
            # whose URLs end in a numeric id, and apt only accepts local
            # packages named *.deb.
            *) deb_file="${app_name}.deb" ;;
        esac
        echo "Downloading ${app_name} from: $deb_url"
        curl -fsSL \
            --retry 5 --retry-all-errors \
            --connect-timeout 15 --max-time 300 \
            "${AUTH_ARGS[@]}" \
            -H "Accept: application/octet-stream" \
            -o "${ROOTFS_DIR}/tmp/${deb_file}" \
            -L "$deb_url"
    fi

    local deb_path="${ROOTFS_DIR}/tmp/${deb_file}"
    if ! dpkg-deb --info "$deb_path" >/dev/null 2>&1; then
        echo "ERROR: ${app_name} input is not a valid Debian package"
        exit 1
    fi
    if [ "$(dpkg-deb -f "$deb_path" Architecture)" != "arm64" ]; then
        echo "ERROR: ${app_name} package architecture must be arm64"
        exit 1
    fi
    echo "${app_name} package: $(dpkg-deb -f "$deb_path" Package Version Architecture)"
    sha256sum "$deb_path"

on_chroot << CHROOT
set -e
apt-get install -y --no-install-recommends ${apt_options} "/tmp/${deb_file}"
rm -f "/tmp/${deb_file}"
CHROOT
}

RECORDER_RELEASES_URL="${RECORDER_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Recorder/releases}"
COMPASS_RELEASES_URL="${COMPASS_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Compass/releases}"
CAMERA_APP_RELEASES_URL="${CAMERA_APP_RELEASES_URL:-https://api.github.com/repos/CardputerZero/CameraApp/releases}"
FACTORY_TEST_RELEASES_URL="${FACTORY_TEST_RELEASES_URL:-https://api.github.com/repos/CardputerZero/FactoryTest/releases}"
FILES_RELEASES_URL="${FILES_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Files/releases}"
MUSIC_RELEASES_URL="${MUSIC_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Music/releases}"
IR_CHAT_RELEASES_URL="${IR_CHAT_RELEASES_URL:-https://api.github.com/repos/CardputerZero/IR-Chat/releases}"
PIANO_RELEASES_URL="${PIANO_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Piano/releases}"
IR_REMOTE_RELEASES_URL="${IR_REMOTE_RELEASES_URL:-https://api.github.com/repos/CardputerZero/IR-Remote/releases}"
CAP_CC1101_SUBG_CHAT_RELEASES_URL="${CAP_CC1101_SUBG_CHAT_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Cap-CC1101-SubG-Chat/releases}"
CAP_CC1101_NFC_RELEASES_URL="${CAP_CC1101_NFC_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Cap-CC1101-NFC/releases}"
CAP_LORA_1262_RELEASES_URL="${CAP_LORA_1262_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Cap-LoRa-1262/releases}"
CAP_LORA_1262_GPS_RELEASES_URL="${CAP_LORA_1262_GPS_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Cap-LoRa-1262-GPS/releases}"
KEYBOARD_GUIDE_RELEASES_URL="${KEYBOARD_GUIDE_RELEASES_URL:-https://api.github.com/repos/CardputerZero/Keyboard-Guide/releases}"

download_and_install_deb \
    "Recorder" \
    "$RECORDER_RELEASES_URL" \
    "RECORDER_DEB_URL" \
    'm5cardputerzero-recorder_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Compass" \
    "$COMPASS_RELEASES_URL" \
    "COMPASS_DEB_URL" \
    'm5cardputerzero-compass_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "CameraApp" \
    "$CAMERA_APP_RELEASES_URL" \
    "CAMERA_APP_DEB_URL" \
    '(CameraApp|Camera)_[^"/]*_m5stack1_arm64\.deb' \
    '-o Dpkg::Options::=--force-overwrite'

download_and_install_deb \
    "FactoryTest" \
    "$FACTORY_TEST_RELEASES_URL" \
    "FACTORY_TEST_DEB_URL" \
    '[^"/]*[Ff]actory[Tt]est[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Files" \
    "$FILES_RELEASES_URL" \
    "FILES_DEB_URL" \
    'm5cardputerzero-files_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Music" \
    "$MUSIC_RELEASES_URL" \
    "MUSIC_DEB_URL" \
    'm5cardputerzero-music_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "IR-Chat" \
    "$IR_CHAT_RELEASES_URL" \
    "IR_CHAT_DEB_URL" \
    'm5cardputerzero-ir-chat_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Piano" \
    "$PIANO_RELEASES_URL" \
    "PIANO_DEB_URL" \
    'm5cardputerzero-piano_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "IR-Remote" \
    "$IR_REMOTE_RELEASES_URL" \
    "IR_REMOTE_DEB_URL" \
    'm5cardputerzero-ir-remote_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Cap-CC1101-SubG-Chat" \
    "$CAP_CC1101_SUBG_CHAT_RELEASES_URL" \
    "CAP_CC1101_SUBG_CHAT_DEB_URL" \
    '[^"/]*[Cc]ap-[Cc][Cc]1101-[Ss]ub[Gg]-[Cc]hat[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Cap-CC1101-NFC" \
    "$CAP_CC1101_NFC_RELEASES_URL" \
    "CAP_CC1101_NFC_DEB_URL" \
    '[^"/]*[Cc]ap-[Cc][Cc]1101-[Nn][Ff][Cc][^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Cap-LoRa-1262" \
    "$CAP_LORA_1262_RELEASES_URL" \
    "CAP_LORA_1262_DEB_URL" \
    'm5cardputerzero-cap-lora-1262_[^"/]*_m5stack1_arm64\.deb'

download_and_install_deb \
    "Cap-LoRa-1262-GPS" \
    "$CAP_LORA_1262_GPS_RELEASES_URL" \
    "CAP_LORA_1262_GPS_DEB_URL" \
    '[^"/]*[Cc]ap-[Ll]o[Rr]a-1262-[Gg][Pp][Ss][^"/]*_m5stack1_arm64\.deb'

# First-boot keyboard tutorial, launched once by LaunchWizard before the OOBE.
download_and_install_deb \
    "Keyboard-Guide" \
    "$KEYBOARD_GUIDE_RELEASES_URL" \
    "KEYBOARD_GUIDE_DEB_URL" \
    'm5cardputerzero-keyboard-guide_[^"/]*_m5stack1_arm64\.deb'
