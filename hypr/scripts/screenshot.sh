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
	area)
		# Glass-inspired selection: cool dimming, a luminous edge, and a
		# barely tinted interior. These colors affect only the picker.
		geom="$(slurp \
			-b '10162266' \
			-c 'EAF4FFFF' \
			-s 'DCEEFF0A' \
			-w 2 \
			-d \
			-F 'sans-serif')" || exit 0
		;;
	window)
		if [[ -n ${NIRI_SOCKET:-} ]]; then
			# niri doesn't say where a tiled window is, but shoots one itself
			# (straight to $tmp; it is copied below like the others).
			niri msg action screenshot-window --path "$tmp" >/dev/null
			for _ in {1..40}; do [[ -s $tmp ]] && break; sleep 0.05; done
			geom=niri
		else
			geom="$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')"
		fi ;;
	screen) geom="" ;;
	*) echo "usage: $0 <area|window|screen> <copy|save>" >&2; exit 1 ;;
esac

if [[ "$geom" == niri ]]; then
	[[ -s $tmp ]] || exit 1
elif [[ -n "$geom" ]]; then
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
