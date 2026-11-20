# Start the status-bar session on the built-in LCD console only.
if [ -t 1 ] && [ "$(tty)" = "/dev/tty1" ] && [ -z "${TMUX:-}" ]; then
    if [ -x /usr/local/bin/cz ]; then
        /usr/local/bin/cz
    fi
fi
