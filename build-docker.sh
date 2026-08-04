#!/usr/bin/env bash
# Note: Avoid usage of arrays as MacOS users have an older version of bash (v3.x) which does not supports arrays
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

BUILD_OPTS="$*"

# Allow user to override docker command
DOCKER=${DOCKER:-docker}

# Ensure that default docker command is not set up in rootless mode
if \
  ! ${DOCKER} ps    >/dev/null 2>&1 || \
    ${DOCKER} info 2>/dev/null | grep -q rootless \
; then
	DOCKER="sudo ${DOCKER}"
fi
if ! ${DOCKER} ps >/dev/null; then
	echo "error connecting to docker:"
	${DOCKER} ps
	exit 1
fi

CONFIG_FILE=""
if [ -f "${DIR}/config" ]; then
	CONFIG_FILE="${DIR}/config"
fi

while getopts "c:" flag
do
	case "${flag}" in
		c)
			CONFIG_FILE="${OPTARG}"
			;;
		*)
			;;
	esac
done

# Ensure that the configuration file is an absolute path
if test -x /usr/bin/realpath; then
	CONFIG_FILE=$(realpath -s "$CONFIG_FILE" || realpath "$CONFIG_FILE")
fi

# Ensure that the confguration file is present
if test -z "${CONFIG_FILE}"; then
	echo "Configuration file need to be present in '${DIR}/config' or path passed as parameter"
	exit 1
else
	# shellcheck disable=SC1090
	source ${CONFIG_FILE}
fi

CONTAINER_NAME=${CONTAINER_NAME:-pigen_work}
CONTINUE=${CONTINUE:-0}
PRESERVE_CONTAINER=${PRESERVE_CONTAINER:-0}
PIGEN_DOCKER_OPTS=${PIGEN_DOCKER_OPTS:-""}
BASE_IMAGE=${BASE_IMAGE:-debian:trixie}
DTOVERLAYS_LOCAL_DIR=${DTOVERLAYS_LOCAL_DIR:-""}

if [ -n "${DTOVERLAYS_LOCAL_DIR}" ]; then
  DTOVERLAYS_LOCAL_DIR=$(realpath "${DTOVERLAYS_LOCAL_DIR}")
  if [ ! -d "${DTOVERLAYS_LOCAL_DIR}/.git" ]; then
    echo "DTOVERLAYS_LOCAL_DIR is not a Git repository: ${DTOVERLAYS_LOCAL_DIR}" 1>&2
    exit 1
  fi
  case "${DTOVERLAYS_LOCAL_DIR}" in
    *[[:space:]]*)
      echo "DTOVERLAYS_LOCAL_DIR cannot contain whitespace" 1>&2
      exit 1
      ;;
  esac
  PIGEN_DOCKER_OPTS="${PIGEN_DOCKER_OPTS} --volume ${DTOVERLAYS_LOCAL_DIR}:/local-dtoverlays:ro"
  DTOVERLAYS_REPO=file:///local-dtoverlays
  export DTOVERLAYS_REPO
fi

if [ -z "${IMG_NAME}" ]; then
	echo "IMG_NAME not set in 'config'" 1>&2
	echo 1>&2
exit 1
fi

# Ensure the Git Hash is recorded before entering the docker container
GIT_HASH=${GIT_HASH:-"$(git rev-parse HEAD)"}

CONTAINER_EXISTS=$(${DOCKER} ps -a --filter name="${CONTAINER_NAME}" -q)
CONTAINER_RUNNING=$(${DOCKER} ps --filter name="${CONTAINER_NAME}" -q)
if [ "${CONTAINER_RUNNING}" != "" ]; then
	echo "The build is already running in container ${CONTAINER_NAME}. Aborting."
	exit 1
fi
if [ "${CONTAINER_EXISTS}" != "" ] && [ "${CONTINUE}" != "1" ]; then
	echo "Container ${CONTAINER_NAME} already exists and you did not specify CONTINUE=1. Aborting."
	echo "You can delete the existing container like this:"
	echo "  ${DOCKER} rm -v ${CONTAINER_NAME}"
	exit 1
fi

# Modify original build-options to allow config file to be mounted in the docker container
BUILD_OPTS="$(echo "${BUILD_OPTS:-}" | sed -E 's@\-c\s?([^ ]+)@-c /config@')"

${DOCKER} build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t pi-gen "${DIR}"

if [ "${CONTAINER_EXISTS}" != "" ]; then
  DOCKER_CMDLINE_NAME="${CONTAINER_NAME}_cont"
  DOCKER_CMDLINE_PRE="--rm"
  DOCKER_CMDLINE_POST="--volumes-from=${CONTAINER_NAME}"
else
  DOCKER_CMDLINE_NAME="${CONTAINER_NAME}"
  DOCKER_CMDLINE_PRE=""
  DOCKER_CMDLINE_POST=""
fi

# Check if binfmt_misc is required
binfmt_misc_required=1
case $(uname -m) in
  aarch64)
    binfmt_misc_required=0
    ;;
  arm*)
    binfmt_misc_required=0
    ;;
esac

# Check if qemu-aarch64 and /proc/sys/fs/binfmt_misc are present. Prefer the
# static interpreter: an F-flag binfmt registration can then execute inside a
# Debian container without depending on the Ubuntu host's dynamic libraries.
if [[ "${binfmt_misc_required}" == "1" ]]; then
  if qemu_arm=$(command -v qemu-aarch64-static); then
    :
  elif qemu_arm=$(command -v qemu-aarch64); then
    :
  else
    echo "qemu-aarch64 not found (please install qemu-user-binfmt)"
    exit 1
  fi
  if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
    echo "binfmt_misc required but not mounted, trying to mount it..."
    if ! mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc ; then
        echo "mounting binfmt_misc failed"
        exit 1
    fi
    echo "binfmt_misc mounted"
  fi
  binfmt_name="qemu-aarch64-rpi"
  binfmt_entry="/proc/sys/fs/binfmt_misc/${binfmt_name}"
  if [ -e "${binfmt_entry}" ] && \
      ! grep -qx "interpreter ${qemu_arm}" "${binfmt_entry}"; then
    echo "Replacing stale ${binfmt_name} registration..."
    sudo sh -c "echo -1 > '${binfmt_entry}'"
  fi
  if [ ! -e "${binfmt_entry}" ]; then
    # Register qemu-aarch64 for binfmt_misc.
    reg="echo ':qemu-aarch64-rpi:M::"\
"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:"\
"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:"\
"${qemu_arm}:F' > /proc/sys/fs/binfmt_misc/register"
    echo "Registering qemu-aarch64 for binfmt_misc..."
    sudo bash -c "${reg}"
  fi
  if ! grep -qx "interpreter ${qemu_arm}" "${binfmt_entry}"; then
    echo "qemu-aarch64 binfmt registration is invalid" 1>&2
    exit 1
  fi
fi

trap 'echo "got CTRL+C... please wait 5s" && ${DOCKER} stop -t 5 ${DOCKER_CMDLINE_NAME}' SIGINT SIGTERM
time ${DOCKER} run \
  $DOCKER_CMDLINE_PRE \
  --name "${DOCKER_CMDLINE_NAME}" \
  --privileged \
  ${PIGEN_DOCKER_OPTS} \
  --volume "${CONFIG_FILE}":/config:ro \
  -e "GIT_HASH=${GIT_HASH}" \
  -e "GITHUB_TOKEN" \
  -e "GH_TOKEN" \
  -e "APPLAUNCH_DEB_FILE" \
  -e "APPLAUNCH_DEB_URL" \
  -e "RECORDER_DEB_FILE" \
  -e "COMPASS_DEB_FILE" \
  -e "CAMERA_APP_DEB_FILE" \
  -e "FACTORY_TEST_DEB_FILE" \
  -e "FILES_DEB_FILE" \
  -e "MUSIC_DEB_FILE" \
  -e "IR_REMOTE_DEB_FILE" \
  -e "CAP_CC1101_SUBG_CHAT_DEB_FILE" \
  -e "CAP_CC1101_NFC_DEB_FILE" \
  -e "CAP_LORA_1262_GPS_DEB_FILE" \
  -e "LAUNCHER_RELEASES_URL" \
  -e "DTOVERLAYS_REPO" \
  -e "DTOVERLAYS_REF" \
  -e "DTOVERLAYS_ARCHIVE" \
  -e "DTOVERLAYS_ARCHIVE_SHA256" \
  $DOCKER_CMDLINE_POST \
  pi-gen \
  bash -e -o pipefail -c "
    # binfmt_misc is sometimes not mounted with debian trixie image
    (mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc || true) &&
    dpkg-reconfigure qemu-user-binfmt &&
    cd /pi-gen; ./build.sh ${BUILD_OPTS} &&
    rsync -av work/*/build.log deploy/
  " &
  wait "$!"

# Ensure that deploy/ is always owned by calling user
echo "copying results from deploy/"
${DOCKER} cp "${CONTAINER_NAME}":/pi-gen/deploy - | tar -xf -

echo "copying log from container ${CONTAINER_NAME} to deploy/"
${DOCKER} logs --timestamps "${CONTAINER_NAME}" &>deploy/build-docker.log

ls -lah deploy

# cleanup
if [ "${PRESERVE_CONTAINER}" != "1" ]; then
	${DOCKER} rm -v "${CONTAINER_NAME}"
fi

echo "Done! Your image(s) should be in deploy/"
