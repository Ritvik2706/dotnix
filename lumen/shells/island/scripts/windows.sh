#!/usr/bin/env bash
# windows.sh — the compositor's windows, most recently focused first, for the
# island's switcher: id, workspace name, class and title, tab-separated.
# (Hyprland or niri: see wm.sh.)
exec "$(dirname "${BASH_SOURCE[0]}")/wm.sh" windows
