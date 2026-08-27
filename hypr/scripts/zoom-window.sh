#!/usr/bin/env bash
# "Zoom" — pseudo-fullscreen focus mode.
#
#   zoom-window.sh          SUPER+T       toggle zoom on the active window
#   zoom-window.sh cycle    SUPER+grave   hand the zoom slot to the next window
#
# Instead of a real fullscreen, zooming floats the window, blows it up to a
# fraction of the usable monitor area and centers it, so it sits over the tiled
# windows behind it.  Un-zooming puts the window back exactly where it came from
# (tiled, or its previous floating geometry).
#
# NOTE: this Hyprland uses the Lua config format, so dispatchers must be sent in
# the `hl.dsp.*` form (see hypr/README.md).  `hl.dsp.window.float()` is a plain
# toggle on the active window, hence the explicit floating-state bookkeeping.
#
# State lives per window address under $XDG_RUNTIME_DIR, so several windows can
# be zoomed independently and nothing survives the session.

set -euo pipefail

SIZE=${ZOOM_SIZE:-0.94} # fraction of the usable monitor area to occupy

state_dir="${XDG_RUNTIME_DIR:-/tmp}/hypr-zoom"
mkdir -p "$state_dir"

dispatch() { hyprctl dispatch "$1" >/dev/null; }

# Same toast style as lua/notify.lua so it stacks with the other layout binds.
notify() {
	dunstify -a Window -i /usr/share/icons/candy-icons/places/48/folder-windows.svg \
		-r 72937 -u low -h string:x-dunst-stack-tag:layout "Window State" "$1" || true
}

state_of() { echo "$state_dir/${1#0x}"; }

# Windows sharing a workspace, in creation order — a stable ring for cycling
# that does not shuffle when the zoomed window changes shape.
siblings() {
	hyprctl -j clients |
		jq -r --argjson ws "$1" '[.[] | select(.workspace.id == $ws and .mapped)]
			| sort_by(.stableId) | .[].address'
}

# Restore the active window from its saved pre-zoom geometry.
restore_active() {
	local win addr state floating
	win=$(hyprctl -j activewindow)
	addr=$(jq -r '.address' <<<"$win")
	floating=$(jq -r 'if .floating then 1 else 0 end' <<<"$win")
	state=$(state_of "$addr")
	[ -f "$state" ] || return 0
	# shellcheck disable=SC1090
	. "$state"
	rm -f "$state"
	if [ "$was_floating" = 1 ]; then
		[ "$floating" = 1 ] || dispatch 'hl.dsp.window.float()'
		dispatch "hl.dsp.window.resize({x=$old_w,y=$old_h})"
		dispatch "hl.dsp.window.move({x=$old_x,y=$old_y})"
	else
		[ "$floating" = 0 ] || dispatch 'hl.dsp.window.float()'
	fi
}

# Float the active window, blow it up and center it, remembering where it was.
zoom_active() {
	local win addr floating mon_id old_x old_y old_w old_h mw mh scale rl rt rr rb w h
	win=$(hyprctl -j activewindow)
	addr=$(jq -r '.address' <<<"$win")
	read -r floating mon_id old_x old_y old_w old_h < <(
		jq -r '[(if .floating then 1 else 0 end), .monitor, .at[0], .at[1], .size[0], .size[1]]
			| @tsv' <<<"$win"
	)
	read -r mw mh scale rl rt rr rb < <(
		hyprctl -j monitors |
			jq -r --argjson id "$mon_id" \
				'.[] | select(.id == $id) | [.width, .height, .scale] + .reserved | @tsv'
	)
	# Window geometry is in logical pixels; monitor width/height are physical.
	read -r w h < <(awk -v mw="$mw" -v mh="$mh" -v s="$scale" -v rl="$rl" -v rt="$rt" \
		-v rr="$rr" -v rb="$rb" -v f="$SIZE" \
		'BEGIN { printf "%d %d\n", int((mw/s - rl - rr) * f), int((mh/s - rt - rb) * f) }')

	cat >"$(state_of "$addr")" <<STATE
was_floating=$floating
old_x=$old_x
old_y=$old_y
old_w=$old_w
old_h=$old_h
STATE

	[ "$floating" = 1 ] || dispatch 'hl.dsp.window.float()'
	dispatch "hl.dsp.window.resize({x=$w,y=$h})"
	dispatch 'hl.dsp.window.center({respect_reserved=true})'
}

# ---------------------------------------------------------------- main -------

win=$(hyprctl -j activewindow)
addr=$(jq -r '.address // empty' <<<"$win")
[ -n "$addr" ] || exit 0
ws=$(jq -r '.workspace.id' <<<"$win")

# Drop state left behind by windows that were closed while zoomed.
for f in "$state_dir"/*; do
	[ -e "$f" ] || continue
	hyprctl -j clients | jq -e --arg a "0x${f##*/}" 'any(.[]; .address == $a)' >/dev/null || rm -f "$f"
done

mapfile -t ring < <(siblings "$ws")

case "${1:-toggle}" in
cycle)
	[ "${#ring[@]}" -gt 1 ] || exit 0
	# Anchor on whichever window currently holds the zoom slot, if any, so the
	# hand-off works even when focus has wandered off it.
	anchor=""
	for a in "${ring[@]}"; do
		[ -f "$(state_of "$a")" ] && anchor=$a && break
	done
	from=${anchor:-$addr}
	next=""
	for i in "${!ring[@]}"; do
		[ "${ring[i]}" = "$from" ] && next=${ring[(i + 1) % ${#ring[@]}]} && break
	done
	[ -n "$next" ] || next=${ring[0]}

	if [ -n "$anchor" ]; then
		dispatch "hl.dsp.focus({window=\"address:$anchor\"})"
		restore_active
		dispatch "hl.dsp.focus({window=\"address:$next\"})"
		zoom_active
		notify "Zoom → next window"
	else
		# Nothing is zoomed — degrade to plain focus cycling within the workspace.
		dispatch "hl.dsp.focus({window=\"address:$next\"})"
	fi
	;;
toggle)
	if [ -f "$(state_of "$addr")" ]; then
		# Never guarded: a window must always be able to leave the zoom slot.
		restore_active
		notify "Zoom Off"
		exit 0
	fi
	# Zooming a workspace's only window is pointless — there is nothing behind
	# it to float over, and it just loses the window its tiled geometry.
	if [ "${#ring[@]}" -le 1 ]; then
		notify "Zoom needs another window"
		exit 0
	fi
	zoom_active
	notify "Zoomed"
	;;
*)
	echo "usage: ${0##*/} [toggle|cycle]" >&2
	exit 2
	;;
esac
