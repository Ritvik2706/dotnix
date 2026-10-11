#!/usr/bin/env bash
# screenshot.sh <area|window|screen> <copy|save>
#
# One entry point for the grim/slurp binds (keybinds/screenshots.lua).
# Saves land in ~/Pictures/Screenshots (created on demand), every shot is also
# copied to the clipboard, and a toast shows a thumbnail of what was taken.
# Cancelling the slurp selection (Esc) exits quietly.
set -euo pipefail

target="${1:-area}"
action="${2:-copy}"
dir="$HOME/Pictures/Screenshots"
tmp="$(mktemp --suffix=.png)"
trap 'rm -f "$tmp"' EXIT

case "$target" in
	area) geom="$(slurp)" || exit 0 ;;
	window) geom="$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" ;;
	screen) geom="" ;;
	*) echo "usage: $0 <area|window|screen> <copy|save>" >&2; exit 1 ;;
esac

if [[ -n "$geom" ]]; then
	grim -g "$geom" "$tmp"
else
	grim "$tmp"
fi

wl-copy --type image/png <"$tmp"

if [[ "$action" == "save" ]]; then
	mkdir -p "$dir"
	out="$dir/screenshot-$(date +%F-%H-%M-%S).png"
	cp "$tmp" "$out"
	dunstify -a "Screenshot" -i "$out" -r 72945 -u low "Screenshot saved" "${out/#$HOME/\~} (also copied)"
else
	dunstify -a "Screenshot" -i "$tmp" -r 72945 -u low "Screenshot" "Copied to clipboard"
	sleep 1 # let dunst read the thumbnail before the trap deletes it
fi
