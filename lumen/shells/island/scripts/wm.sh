#!/usr/bin/env bash
# wm.sh — the few things the island asks of the compositor, on Hyprland or niri.
#   wm.sh windows            windows, most recently focused first: id, workspace, class, title (TSV)
#   wm.sh focus <id>         focus a window by the id `windows` gave
#   wm.sh close <id>         close it
#   wm.sh focus-class <cls>  focus the first window of that class (app id)
#   wm.sh active-geom        the focused window as WxH+X+Y, in layout pixels
#   wm.sh monitor            the focused monitor's name
set -uo pipefail

if [[ -n ${NIRI_SOCKET:-} && -S $NIRI_SOCKET ]]; then
	case ${1:-} in
		windows)
			# By position, the number on their Mod+N key (a project's named workspace too).
			niri msg -j workspaces | jq -c 'map({key: (.id|tostring), value: (.idx|tostring)}) | from_entries' >"${XDG_RUNTIME_DIR:-/tmp}/wm-ws.json"
			niri msg -j windows | jq -r --slurpfile ws "${XDG_RUNTIME_DIR:-/tmp}/wm-ws.json" '
				sort_by(-(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0)) | .[]
				| [(.id|tostring), ($ws[0][(.workspace_id|tostring)] // "?"), (.app_id // ""), (.title // "")] | @tsv' ;;
		focus) niri msg action focus-window --id "$2" ;;
		close) niri msg action close-window --id "$2" ;;
		focus-class)
			id=$(niri msg -j windows | jq -r --arg c "$2" '[.[] | select(.app_id == $c)][0].id // empty')
			[[ -n $id ]] && niri msg action focus-window --id "$id" ;;
		active-geom)
			# Where the tile sits in the view, when niri says (output-local: right
			# on one monitor). When it doesn't, nothing: callers take the output.
			niri msg -j focused-window | jq -r '
				.layout as $l | if $l.tile_pos_in_workspace_view then
				"\($l.window_size[0])x\($l.window_size[1])+\($l.tile_pos_in_workspace_view[0]|floor)+\($l.tile_pos_in_workspace_view[1]|floor)"
				else empty end' ;;
		monitor) niri msg -j focused-output | jq -r '.name' ;;
		*) echo "usage: ${0##*/} windows|focus|close|focus-class|active-geom|monitor" >&2; exit 2 ;;
	esac
else
	case ${1:-} in
		windows) hyprctl clients -j | jq -r 'map(select(.mapped and (.hidden | not))) | sort_by(.focusHistoryID) | .[] | [.address, .workspace.name, .class, .title] | @tsv' ;;
		focus) hyprctl dispatch 'hl.dsp.focus({ window = "address:'"$2"'" })' >/dev/null ;;
		close) hyprctl dispatch 'hl.dsp.window.close({ window = "address:'"$2"'" })' >/dev/null ;;
		focus-class) hyprctl dispatch 'hl.dsp.focus({ window = "class:'"$2"'" })' >/dev/null ;;
		active-geom) hyprctl activewindow -j | jq -r '"\(.size[0])x\(.size[1])+\(.at[0])+\(.at[1])"' ;;
		monitor) hyprctl monitors -j | jq -r '.[] | select(.focused) | .name' ;;
		*) echo "usage: ${0##*/} windows|focus|close|focus-class|active-geom|monitor" >&2; exit 2 ;;
	esac
fi
