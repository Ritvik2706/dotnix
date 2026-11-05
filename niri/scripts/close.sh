#!/usr/bin/env bash
# close.sh — Mod+Q: close the focused window, except that Steam's main window
# quits Steam outright instead of leaving it in the tray. Its popups (friends
# list, settings) and games (steam_app_*) just close as usual.
w=$(niri msg -j focused-window)
if jq -e '.app_id == "steam" and (.is_floating | not)' <<<"$w" >/dev/null 2>&1; then
	exec steam -shutdown
fi
exec niri msg action close-window
