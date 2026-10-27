#!/usr/bin/env bash
#
# The 10-minute idle stage: lock, then turn the panel off — in that order, and
# with a wait in between.
#
# WHY THE ORDER AND THE WAIT MATTER
#
# hyprlock only renders when the compositor hands it frame callbacks, so a lock
# born against a dark output never draws (the whole story is in
# resume-lock.sh). The old on-timeout was one line —
#
#     loginctl lock-session; hyprctl dispatch dpms off
#
# — which races: lock-session returns as soon as the request is made, so dpms
# off routinely landed before hyprlock had drawn anything, and the wake had to
# throw that instance away and swap in a fresh one. That swap is the black
# flash and the "second lock screen appearing" you see after touching the
# trackpad.
#
# Waiting for hyprlock to be up and to have drawn before taking the panel away
# means the instance is healthy, and the wake is then just "turn the light back
# on" — no restart, no flash. See unblank.sh.
set -uo pipefail

loginctl lock-session

# Up to ~3s for the client to exist and settle. If it never appears we blank
# anyway: leaving a lit desktop up forever is worse than a lock that has to be
# swapped on wake, and resume-lock.sh still covers that case on the suspend
# path.
for _ in {1..60}; do
    pidof hyprlock >/dev/null 2>&1 && break
    sleep 0.05
done
# A couple of frames past process start, so the first composition is on screen
# before the output goes away.
sleep 0.3

if [[ -n ${NIRI_SOCKET:-} ]]; then niri msg action power-off-monitors >/dev/null 2>&1
else hyprctl dispatch 'hl.dsp.dpms({action="off"})' >/dev/null 2>&1; fi

# Pause razer-fx so the keyboard goes dark and stops rendering (SIGUSR2 in
# unblank.sh resumes it).
RAZER_PID_FILE="${XDG_RUNTIME_DIR:-/run/user/$UID}/razer-fx.pid"
[[ -r $RAZER_PID_FILE ]] && kill -USR1 "$(cat "$RAZER_PID_FILE")" 2>/dev/null
exit 0
