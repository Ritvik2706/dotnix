#!/usr/bin/env bash
# record.sh <region|window|screen|at WxH+X+Y|output NAME> — the island's screen recorder.
# `at` and `output` come from niri's screenshot UI (its r key): the selection it
# already has, in logical layout coordinates, or a whole output.
# Records with wf-recorder through the compositor's screencopy, encoding H.264 on
# the Intel GPU (VA-API), so what niri leaves out of captures (the island's
# recording bar, layer-rule hide-from-capture) is not in the video. Only changed
# frames are taken: a still screen costs next to nothing.
# Measured 2026-11-11 at 2560x1440, forced 60 fps: wf-recorder ~15% of one core
# (gpu-screen-recorder ~14%), niri +25% while everything moves (it renders the
# capture: OBS pays the same); about 5% when the screen changes as in normal use.
# Records until it is sent SIGTERM or SIGINT, then saves to ~/Videos/Recordings
# and says so. Prints "started" once the recording is under way; exits 3 if the
# region selection was cancelled.
set -uo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"

dir="${RECORD_DIR:-$HOME/Videos/Recordings}"   # RECORD_DIR: for trying it out
mkdir -p "$dir"
out="$dir/recording-$(date +%F-%H-%M-%S).mp4"

# "WxH+X+Y" → wf-recorder's "X,Y WxH".
geom() {
	local g=$1 w h x y
	IFS='x+' read -r w h x y <<<"$g"
	printf '%s,%s %sx%s' "$x" "$y" "$w" "$h"
}

case "${1:-screen}" in
	region)
		g="$(slurp -b '10162266' -c 'EAF4FFFF' -s 'DCEEFF0A' -w 2 -f '%wx%h+%x+%y')" || exit 3
		args=(-g "$(geom "$g")") ;;
	window)
		g="$("$here/wm.sh" active-geom)"
		if [[ -n $g ]]; then
			# niri gives it output-local; wf-recorder wants the layout's coordinates.
			if [[ -n ${NIRI_SOCKET:-} ]]; then
				read -r ox oy < <(niri msg -j focused-output | jq -r '"\(.logical.x) \(.logical.y)"')
				IFS='x+' read -r w h x y <<<"$g"
				g="${w}x${h}+$((x + ox))+$((y + oy))"
			fi
			args=(-g "$(geom "$g")")
		else
			args=(-o "$("$here/wm.sh" monitor)")
		fi ;;
	at) args=(-g "$(geom "$2")") ;;
	output) args=(-o "$2") ;;
	*) args=(-o "$("$here/wm.sh" monitor)") ;;
esac

# The Intel GPU's render node: the one niri composites on, so frames reach the
# encoder as GPU buffers (renderD128 is the NVIDIA card here).
dev=""
for d in /sys/class/drm/renderD*; do
	[[ $(basename "$(readlink -f "$d/device/driver")") == i915 ]] && { dev="/dev/dri/${d##*/}"; break; }
done
enc=(-c h264_vaapi)
[[ -n $dev ]] && enc+=(-d "$dev")
# The sound that is playing (the default output's monitor), as gsr's default_output did.
audio=()
sink="$(pactl get-default-sink 2>/dev/null)" && [[ -n $sink ]] && audio=("--audio=$sink.monitor")

log="$(mktemp)"
wf-recorder "${args[@]}" "${enc[@]}" "${audio[@]}" -f "$out" -y >"$log" 2>&1 &
pid=$!
# The island stops it with TERM (it starts its children with SIGINT ignored, and a
# shell can't trap what it was started ignoring); wf-recorder saves on SIGINT.
trap 'kill -INT "$pid" 2>/dev/null' INT TERM
# It only counts as started once the recorder is still up a moment later:
# a bad region or a missing encoder makes it give up straight away.
sleep 0.8
if ! kill -0 "$pid" 2>/dev/null; then
	why="$(grep -m1 -iE 'invalid|cannot|failed|error' "$log")"
	notify-send -a "Screen recording" -u critical "Couldn't start recording" "${why:-wf-recorder stopped}"
	rm -f "$log" "$out"
	exit 1
fi
echo started
wait "$pid"; wait "$pid"
rm -f "$log"
if [[ -s "$out" ]]; then
	notify-send -a "Screen recording" -i video-x-generic "Recording saved" "${out/#$HOME/\~}"
fi
