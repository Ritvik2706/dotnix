#!/usr/bin/env bash
# record.sh <region|window|screen> — the island's screen recorder.
# Records with gpu-screen-recorder (the GPU's video encoder: the CPU stays free)
# until it is sent SIGINT, then saves to ~/Videos/Recordings and says so.
# Prints "started" once the recording is under way; exits 3 if the region
# selection was cancelled.
set -uo pipefail

dir="$HOME/Videos/Recordings"
mkdir -p "$dir"
out="$dir/recording-$(date +%F-%H-%M-%S).mp4"

case "${1:-screen}" in
	region)
		g="$(slurp -b '10162266' -c 'EAF4FFFF' -s 'DCEEFF0A' -w 2 -f '%wx%h+%x+%y')" || exit 3
		args=(-w region -region "$g") ;;
	window)
		g="$("$(dirname "${BASH_SOURCE[0]}")/wm.sh" active-geom)"
		if [[ -n $g ]]; then args=(-w region -region "$g"); else args=(-w "$("$(dirname "${BASH_SOURCE[0]}")/wm.sh" monitor)"); fi ;;
	*)
		args=(-w "$("$(dirname "${BASH_SOURCE[0]}")/wm.sh" monitor)") ;;
esac

log="$(mktemp)"
gpu-screen-recorder "${args[@]}" -f 60 -a default_output -o "$out" 2>"$log" &
pid=$!
trap 'kill -INT "$pid" 2>/dev/null' INT TERM
# It only counts as started once the recorder is still up a moment later:
# a missing encoder driver makes it give up straight away.
sleep 0.8
if ! kill -0 "$pid" 2>/dev/null; then
	why="$(grep -m1 'gsr error' "$log" | sed 's/^gsr error: //')"
	notify-send -a "Screen recording" -u critical "Couldn't start recording" "${why:-gpu-screen-recorder stopped}"
	rm -f "$log" "$out"
	exit 1
fi
echo started
wait "$pid"; wait "$pid"
rm -f "$log"
if [[ -s "$out" ]]; then
	notify-send -a "Screen recording" -i video-x-generic "Recording saved" "${out/#$HOME/\~}"
fi
