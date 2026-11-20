#!/bin/bash -e
# Late size trim. Runs after stage 05 has compiled the st7789v display module,
# so the build toolchain / kernel headers are no longer needed in the image.
on_chroot << 'EOF'
# Drop orphaned dependencies of the purged toolchain (gcc/g++/cpp/make/libc-dev...)
apt-get autoremove --purge -y

# Kernel headers were only needed to build the stage-05 display module.
dpkg-query -W -f='${Package}\n' 'linux-headers-*' 2>/dev/null | xargs -r apt-get purge -y || true
apt-get autoremove --purge -y

# Keep only the configured locale (en_US); /usr/share/locale is ~180MB otherwise.
for d in /usr/share/locale/*; do
  case "$(basename "$d")" in
    en_US|en) ;;
    *) rm -rf "$d" ;;
  esac
done

# Drop man pages and doc bodies, but retain copyright notices.
rm -rf /usr/share/man/*
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -depth -type d -empty -delete 2>/dev/null || true

apt-get clean
EOF
