#!/bin/bash -e

# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/template.zip "${ROOTFS_DIR}/var/template.zip"

