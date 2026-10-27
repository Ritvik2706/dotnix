#!/usr/bin/env bash
#
# The going-DOWN half of the lid/suspend lock. resume-lock.sh is the coming-up
# half, and the two talk through one file: the sleep verdict.
#
#   sleep-lock.sh lid            lid closed (Hyprland switch bind)
#   sleep-lock.sh birth          hyprlock.service ExecStartPost
#
# The verdict itself is written by lock-sleep-guard.py, which also HOLDS the
# suspend until the lock is mature — see its header for why that has to be a
# logind inhibitor of our own and cannot be hypridle's.
#
# ── THE PROBLEM ──────────────────────────────────────────────────────────
#
# A hyprlock that starts at the instant of suspend never gets to draw (the
# full story is at the top of resume-lock.sh), so resume-lock.sh used to
# replace the lock on EVERY wake. Correct, but you saw all of it: the old lock
# for a beat, the screen going black for the swap, then a second lock screen.
# The journal showed the lock being taken 4.4s after the lid closed and 150ms
# before suspend — born blind, every time.
#
# ── THE FIX ──────────────────────────────────────────────────────────────
#
# 1. Lock the moment the lid closes, while the panel is still live, so the
#    lock has drawn long before the system sleeps.
# 2. Record how each hyprlock was born: panel lit or dark, and when.
# 3. At suspend (lock-sleep-guard.py), hold the system until the lock is
#    mature — born lit, alive >= MATURE_MS — then write that verdict.
# 4. resume-lock.sh keeps a healthy lock as it is — no swap, nothing to see —
#    and only swaps one that is suspect (or turns out to be stuck anyway).
set -uo pipefail

RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}
BIRTH_FILE=$RUN/hyprlock-birth     # "<pid> <lit|dark> <epoch_ms>"

now_ms()   { date +%s%3N; }
# panel_on / session_locked: Hyprland or niri (lock-state.sh)
# shellcheck source=lock-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock-state.sh"
locked()   { session_locked; }
lock_pid() { systemctl --user show -p MainPID --value hyprlock.service 2>/dev/null; }

cmd_lid() {
    # Docked — an external monitor is on: closing the lid is "use the big
    # screen", not "I'm leaving". logind does not suspend in that case either
    # (HandleLidSwitchDocked=ignore), so neither do we lock.
    if [[ -n ${NIRI_SOCKET:-} ]]; then
        niri msg -j outputs 2>/dev/null | jq -e 'any(.[]; (.name | startswith("eDP") | not) and .current_mode != null)' >/dev/null 2>&1 && exit 0
    elif hyprctl monitors -j 2>/dev/null | python3 -c '
import json, sys
mons = json.load(sys.stdin)
sys.exit(0 if any(not m["name"].startswith("eDP") and not m.get("disabled") for m in mons) else 1)
' 2>/dev/null; then
        exit 0
    fi
    systemctl --user start hyprlock.service
}

cmd_birth() {
    local pid=${MAINPID:-$(lock_pid)} lit=dark
    panel_on && lit=lit
    printf '%s %s %s\n' "$pid" "$lit" "$(now_ms)" > "$BIRTH_FILE"
}

case ${1:-} in
    lid)          cmd_lid ;;
    birth)        cmd_birth ;;
    *)            echo "usage: ${0##*/} lid|birth" >&2; exit 2 ;;
esac
