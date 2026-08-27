#!/usr/bin/env bash
#
# Wake path for the lock screen. Run from hypridle's after_sleep_cmd and from
# the screen-blank listener's on-resume (see hypr/hypridle.conf).
#
# ── WHY THIS EXISTS: the lid-close freeze ────────────────────────────────
#
# hyprlock's render loop is driven by the compositor's frame callbacks. A lock
# that comes up while the output is off (lid shut, or dpms off) never gets a
# callback, so it never draws a frame: the label assets stay queued forever
# and the log fills with
#
#     WARN ]: Trying to update label, but a resource is still pending!
#
# On its own that is just an ugly lock screen. The damage is that the UNLOCK
# runs through that same render path — it fades out. So PAM can succeed, the
# journal can say `auth: authenticated for hyprlock`, and `Unlocking session`
# still never arrives. What you get is a dimmed, frozen still of the desktop
# that eats every keystroke. Measured on this machine, one boot, same config:
#
#     lock born with the panel ON    auth -> unlock in 0.8s
#     lock born with the panel OFF   auth -> unlock in 41s, or never
#
# It cannot be configured away: `no_fade_out` and `disable_loading_bar` are
# not config options in hyprlock 0.9.6 and are not CLI flags either (check
# `hyprlock --help`). Nothing here is tuning — it is working around a client
# that does not cope with its output being off at lock time.
#
# ── THE FIX ──────────────────────────────────────────────────────────────
#
# Never carry a lock that was born blind across the wake. Bring the output up,
# then replace hyprlock with a process that locks against a live panel.
#
# Replacing it is safe and does NOT expose the desktop: under ext-session-lock
# a client that dies without sending `unlock` leaves the compositor locked, and
# misc:allow_session_lock_restore lets the new one adopt that lock.
#
# ── WHY THE BACKLIGHT DANCE ──────────────────────────────────────────────
#
# Correct is not the same as smooth. Done naively you watch the whole seam:
# the panel lights onto the FROZEN frame of the dead lock, that flicks to
# whatever Hyprland draws in the ~135ms with no lock client, and only then
# does the real lock fade in. Three states, all of them wrong-looking.
#
# So the swap happens behind a dark backlight. The panel is electrically on
# the whole time — the new hyprlock needs that, it is the entire point — but
# at brightness 0 there is nothing to see. Light comes back only once the new
# lock is up, so the first and only thing you see is the lock screen fading
# in. `dpms on` can restore the panel's brightness itself, so it is blanked
# again after.
#
# The trap is load-bearing: if anything below fails, the backlight comes back
# regardless. A black panel would look exactly like the bug being fixed.
#
# The other half of "smooth" is --no-fade-in on the unit's ExecStart. hyprlock
# screencopies the screen as it starts and cross-fades FROM that capture INTO
# the lock composition; on this path the capture is your desktop, so the fade
# shows a dimmed desktop for a beat before the lock resolves. That both looks
# wrong and looks exactly like the freeze. With it off, hyprlock's first frame
# IS the finished lock screen — which is what makes the wait below a real
# readiness check instead of a guess at an animation's length.
set -uo pipefail

BL_PREV=$(brightnessctl -m 2>/dev/null | head -1 | cut -d, -f3)

restore_backlight() {
    [[ -n ${BL_PREV:-} ]] && brightnessctl -q set "$BL_PREV" 2>/dev/null
    return 0
}
trap restore_backlight EXIT

blank() { brightnessctl -q set 0 2>/dev/null || true; }

# 1. Dark before anything else, so the frozen frame is never shown.
blank

# 2. Panel electrically on — the new hyprlock must find a live output or it
#    is born with the same defect. Blank again: dpms on can undo step 1.
hyprctl dispatch dpms on >/dev/null 2>&1
blank

# 3. Keyboard backlight back (razer-fx is paused with SIGUSR1 when we blank).
RAZER_PID_FILE="${XDG_RUNTIME_DIR:-/run/user/$UID}/razer-fx.pid"
[[ -r $RAZER_PID_FILE ]] && kill -USR2 "$(cat "$RAZER_PID_FILE")" 2>/dev/null

# 4. Swap in a fresh lock. `restart` covers both cases: it replaces a running
#    instance, and starts one if somehow nothing is locked. Remember who we
#    are replacing — step 5 needs it.
OLD_PID=$(pidof hyprlock 2>/dev/null || true)
systemctl --user restart hyprlock.service

# 5. Wait for the NEW hyprlock to have taken over.
#
#    `hyprctl locked` is useless as a readiness signal here, and for a good
#    reason: it stays true across the entire swap. That is the ext-session-
#    lock guarantee this whole approach leans on — the compositor holds the
#    lock when a client dies without unlocking — so it can tell us the screen
#    is covered, but never who is covering it. The PID changing is the only
#    thing that says the replacement is live. Measured swap: ~135ms.
#
#    Bounded at ~3s. If it has not come up by then something is wrong, and
#    the trap handing back a lit screen beats leaving the user staring at a
#    black panel with no way to tell it from a dead machine.
for _ in {1..60}; do
    NEW_PID=$(pidof hyprlock 2>/dev/null || true)
    [[ -n $NEW_PID && $NEW_PID != "$OLD_PID" ]] && break
    sleep 0.05
done

# 6. One frame's grace so the light rises onto a drawn lock screen rather than
#    the instant before it. With --no-fade-in there is nothing to wait out
#    beyond this.
sleep 0.1

# 7. trap restores the backlight here.
