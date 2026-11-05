#!/usr/bin/env bash
# niri-launch.sh — what niri.service runs (systemd drop-in, see
# system/niri-patched-setup.sh): the patched niri if it can start, otherwise
# stock niri, so a login always ends in a working desktop. Never a TTY.
#
#   1. The patched build (~/.local/bin/niri), then the previous good one
#      (niri.prev), if it passes niri-patched.sh's check: libraries present,
#      symbols resolvable, config accepted. A build that crashed while starting
#      last time is skipped until it is rebuilt.
#   2. It is watched for its first STARTUP_SECS: dying in that window counts as
#      a crash, and stock niri takes over in the same login.
#   3. Stock niri (/usr/bin/niri): first the wallpaper theme is rewritten
#      without the patched-only glass keys (which stock niri would reject,
#      dropping the whole config: no keybinds), then, inside the session,
#      niri-patched.sh says what happened and fixes it in the background.
#
# Kept small and defensive on purpose: anything unexpected falls through to
# stock niri.
#
# Testing (nested, never your session): NIRI_LAUNCH_PATCHED=<a binary>,
# NIRI_LAUNCH_ARGS="-c <config>" instead of --session, NIRI_LAUNCH_NO_FIX=1
# to skip the background fix.
set -u

PATCHED=${NIRI_LAUNCH_PATCHED:-$HOME/.local/bin/niri}
STOCK=/usr/bin/niri
read -ra ARGS <<<"${NIRI_LAUNCH_ARGS:---session}"
CONFIG=$HOME/.config/niri/config.kdl
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
TOOL=$HERE/niri-patched.sh
THEME=$HERE/../../theme/wallpaper-theme.py
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/niri-patched
STARTUP_SECS=20
mkdir -p "$STATE"

log() { systemd-cat -t niri-launch -p info echo "$*" 2>/dev/null || true; }

usable() { # usable BIN -> 0, or prints why not
	[[ -e $STATE/crashed && $(<"$STATE/crashed") == "$(stat -c %Y "$1" 2>/dev/null)" ]] \
		&& { echo "it crashed while starting last time"; return 1; }
	"$TOOL" check "$1"
}

why=""
for bin in "$PATCHED" "$PATCHED.prev"; do
	if w=$(usable "$bin" 2>&1); then
		log "starting $bin"
		"$bin" "${ARGS[@]}" &
		child=$!
		# Logout / stop: pass it on, and don't mistake it for a crash.
		trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit $?' TERM INT HUP
		for ((i = 0; i < STARTUP_SECS * 2; i++)); do
			kill -0 "$child" 2>/dev/null || break
			sleep 0.5 & wait $!
		done
		if kill -0 "$child" 2>/dev/null; then
			# Up and running: from here on it is just niri. A minute in, the
			# same check the pacman hook runs (an update made while no session
			# was up, e.g. from a TTY, is caught here).
			rm -f "$STATE/crashed"
			[[ -n ${NIRI_LAUNCH_NO_FIX:-} ]] || systemd-run --user --quiet --collect --on-active=60 \
				--unit="niri-patched-login-$$" "$TOOL" auto >/dev/null 2>&1
			wait "$child"
			exit $?
		fi
		wait "$child"; rc=$?
		trap - TERM INT HUP
		# A clean quit right away (a compositor switch) is not a crash.
		((rc == 0)) && exit 0
		log "$bin died while starting (exit $rc)"
		stat -c %Y "$bin" >"$STATE/crashed" 2>/dev/null
		why="it crashed while starting (exit $rc)"
		break
	fi
	[[ -z $why ]] && why=$w
done

# ── stock niri ───────────────────────────────────────────────────────────
log "falling back to stock niri: $why"
if ! "$STOCK" validate -c "$CONFIG" >/dev/null 2>&1; then
	# The theme as it was last applied, minus what only the patched niri knows.
	src=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' \
		"${XDG_CACHE_HOME:-$HOME/.cache}/lumen/theme.json" 2>/dev/null)
	[[ -n $src ]] && WALLTHEME_NIRI_EXE=$STOCK timeout 30 python3 "$THEME" apply "$src" >/dev/null 2>&1
	"$STOCK" validate -c "$CONFIG" >/dev/null 2>&1 \
		|| why="$why; stock niri also rejects the config, so niri's defaults are in use"
fi
# Once the session is up: tell, and fix in the background.
[[ -n ${NIRI_LAUNCH_NO_FIX:-} ]] || systemd-run --user --quiet --collect --on-active=15 \
	--unit="niri-patched-fallback-$$" "$TOOL" fallback "$why" >/dev/null 2>&1
exec "$STOCK" "${ARGS[@]}"
