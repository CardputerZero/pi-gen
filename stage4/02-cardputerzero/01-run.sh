#!/bin/bash -e

# fonts-dejavu-* may have been unpacked before the dpkg excludes registered
# in stage2. Sweep any excluded font that still made it onto disk, then
# refresh the fontconfig cache so applications never see the stale entries.
on_chroot << EOF
sed -n 's/^path-exclude=//p' /etc/dpkg/dpkg.cfg.d/01-cardputerzero-fonts | \
while read -r pattern; do
    rm -f \$pattern
done
fc-cache -f >/dev/null
EOF
