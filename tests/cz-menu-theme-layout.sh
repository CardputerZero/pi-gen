#!/bin/bash
# Layout test for cz-menu-theme: render main + a submenu, strip ANSI, and verify
# every line is exactly 53 columns and each screen fits the console row budget.
# Run: bash tests/cz-menu-theme-layout.sh
set -u
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../stage2/06-cpz-features/files/cz-menu-theme"
FUNCS="$(mktemp)"
trap 'rm -f "$FUNCS"' EXIT
# Load only the function/theme definitions, not the interactive main loop.
n=$(grep -n '^while :; do' "$SRC" | tail -1 | cut -d: -f1)
head -n $((n-1)) "$SRC" > "$FUNCS"
source "$FUNCS"
# Mock environment-dependent helpers so the test runs anywhere.
clear() { :; }
bat() { printf '%s' '85%'; }
bl()  { printf '%s' '60'; }
blm() { printf '%s' '100'; }
vol() { printf '%s' '40%'; }
temp() { printf '%s' '45.0°C'; }

render_main() {
    hdr "CARDPUTER ZERO" main
    row2 1 "Camera" 5 "IR"; row2 2 "Music" 6 "System"; row2 3 "News" 7 "Power"
    row2 4 "WiFi" 8 "Logout"; row1 0 "CLI"
    bsep
    brow "  press a number to select" "${DIM}  press a number to select${R}"
    bbot
}
render_sub() {
    hdr "AUDIO" audio
    row1 1 "Volume +5%"; row1 2 "Volume -5%"; row1 3 "Mute toggle"
    row1 4 "Speaker test"; row1 5 "All controls"; row1 6 "Save levels"
    row1 0 "Back"; bbot
}
render_system() {
    hdr "SYSTEM" system
    row1 1 "Audio"; row1 2 "Display"
    row1 0 "Back"; bbot
}
render_display() {
    hdr "DISPLAY" system
    row1 1 "Backlight +"; row1 2 "Backlight -"
    row1 0 "Back"; bbot
}
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
check() {
    local label="$1" body="$2" bad=0 w l rows
    echo "----- $label -----"
    printf '%s\n' "$body"
    while IFS= read -r l; do
        w=${#l}; [ "$w" -ne 53 ] && { echo "  !! width $w (want 53): [$l]"; bad=1; }
    done <<< "$body"
    rows=$(printf '%s\n' "$body" | wc -l)
    echo "  rows=$rows (console=14, tmux~13)  widths_ok=$([ $bad = 0 ] && echo yes || echo NO)"
    [ "$bad" = 0 ] && [ "$rows" -le 13 ]
}
render_ask() { printf 'n' | ask "Reboot the device?"; }
main_s="$(render_main | strip)"; sub_s="$(render_sub | strip)"; sys_s="$(render_system | strip)"; disp_s="$(render_display | strip)"
check "MAIN" "$main_s"; a=$?
check "AUDIO submenu" "$sub_s"; b=$?
check "SYSTEM submenu" "$sys_s"; s=$?
check "DISPLAY submenu" "$disp_s"; d=$?
check "CONFIRM(ask)" "$(render_ask | strip)"; c=$?
# Status bar fields per context.
st=0
case "$main_s" in *"Battery:"*"Date:"*"Time:"*) ;; *) st=1 ;; esac
case "$sub_s" in *"Vol:"*) ;; *) st=1 ;; esac
case "$sys_s" in *"BL:"*"Temp:"*) ;; *) st=1 ;; esac
case "$disp_s" in *"BL:"*) ;; *) st=1 ;; esac
echo "status fields (main=Battery/Date/Time, audio=Vol, system=BL/Temp, display=BL): $([ $st = 0 ] && echo OK || echo FAIL)"
# ask must confirm only on y/Y; anything else (incl. Enter) is No.
printf 'y'  | ask "Q?" >/dev/null; r1=$?
printf 'Y'  | ask "Q?" >/dev/null; r2=$?
printf 'n'  | ask "Q?" >/dev/null; r3=$?
printf '\n' | ask "Q?" >/dev/null; r4=$?
beh=0; [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$r3" = 1 ] && [ "$r4" = 1 ] || beh=1
echo "ask accepts y/Y only (y=$r1 Y=$r2 n=$r3 enter=$r4): $([ $beh = 0 ] && echo OK || echo FAIL)"
echo
if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$s" = 0 ] && [ "$d" = 0 ] && [ "$c" = 0 ] && [ "$beh" = 0 ] && [ "$st" = 0 ]; then echo "LAYOUT OK"; else echo "LAYOUT PROBLEM"; exit 1; fi
