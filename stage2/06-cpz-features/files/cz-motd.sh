# Short banner on interactive logins (SSH and secondary VTs).
if [ -t 1 ] && [ "$(tty)" != "/dev/tty1" ]; then
    _ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    printf '  ========================================\n'
    printf '   C A R D P U T E R   Z E R O\n'
    printf '   %s  -  %s\n' "$(hostname)" "${_ip:-no-ip}"
    printf '  ========================================\n'
    unset _ip
fi
