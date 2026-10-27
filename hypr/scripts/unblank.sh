#!/usr/bin/env bash
#
# The wake half of idle-blank.sh: you moved the mouse, so give the panel and
# the keyboard back. Nothing else.
#
# This deliberately does NOT restart hyprlock. The instance blanked by
# idle-blank.sh was born against a live output and had drawn before the panel
# went away, so it is healthy — it keeps rendering the moment frame callbacks
# resume, and its unlock path works. Replacing it would only produce the seam
# it used to: dark panel, ~135ms of bare compositor, then a second lock screen
# fading in. That is the "black flash and a new hyprlock" glitch.
#
# The one case that DOES need a replacement — a lock carried across suspend,
# which may have been born blind — is still handled by resume-lock.sh from
# hypridle's after_sleep_cmd.
set -uo pipefail

# Keyboard backlight first, before any of the early exits below: idle-blank.sh
# paused razer-fx with SIGUSR1, and if this wake bails out (session already
# unlocked by howdy, or resume-lock.sh owning the wake) nothing else would ever
# send the SIGUSR2 — the keys stay dark until razer-fx is restarted. Resuming
# is idempotent and harmless in every state.
RAZER_PID_FILE="${XDG_RUNTIME_DIR:-/run/user/$UID}/razer-fx.pid"
[[ -r $RAZER_PID_FILE ]] && kill -USR2 "$(cat "$RAZER_PID_FILE")" 2>/dev/null

# Nothing to do on an unlocked session, and importantly nothing to *undo*:
# this must never be able to put a lock back (see resume-lock.sh's note on
# howdy unlocking without any input event).
# Is the session locked? Hyprland says so; niri can't be asked, so there a
# running hyprlock stands in for it (it only stays up once it holds the lock).
session_locked() {
    if [[ -n ${NIRI_SOCKET:-} ]]; then pidof -q hyprlock; else [[ $(hyprctl locked 2>/dev/null) == true ]]; fi
}
session_locked || exit 0

# A wake from suspend fires this and resume-lock.sh together. resume-lock.sh
# holds this flock while it deliberately keeps the backlight at 0 across its
# swap; lighting the panel up underneath it would show exactly the seam it is
# hiding. If it is running, it owns the wake — stay out of the way.
LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$UID}/resume-lock.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if [[ -n ${NIRI_SOCKET:-} ]]; then niri msg action power-on-monitors >/dev/null 2>&1
else hyprctl dispatch 'hl.dsp.dpms({action="on"})' >/dev/null 2>&1; fi

# You are back: have face unlock look for you.
"$(dirname "${BASH_SOURCE[0]}")/face-unlock.sh" rearm

exit 0
