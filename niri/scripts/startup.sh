#!/usr/bin/env bash
# startup.sh — the apps niri opens at login (config.kdl spawn-sh-at-startup):
# a terminal, and after a switch from Hyprland or back, what was open, put
# back where it was (layout.sh only acts on a layout saved moments ago).
set -uo pipefail

setsid -f ghostty >/dev/null 2>&1
# The colours that follow the wallpaper, for the niri that just started (glass
# borders only once the running niri is the patched one): once awww is up.
setsid -f sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do awww query >/dev/null 2>&1 && break; sleep 0.5; done
    ~/github/config/dotnix/theme/wallpaper-theme.py apply' >/dev/null 2>&1
~/.config/lumen/shells/island/scripts/restore-apps.sh restore
~/.config/niri/scripts/layout.sh restore
