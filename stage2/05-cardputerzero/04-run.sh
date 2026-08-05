#!/bin/bash -e

# The desktop stages pull fonts-dejavu-* in as dependencies and stage4
# installs the JetBrains Mono and Noto CJK packages, so the dpkg excludes
# have to land before any of them unpack.
install -m 644 files/01-cardputerzero-fonts \
    "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d/01-cardputerzero-fonts"
