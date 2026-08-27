#!/usr/bin/env bash
#
# The second half of the boot blackout. system/systemd/hyprlock-blank.service
# takes the backlight to zero before Hyprland can draw its first frame; this
# brings it back, and only once the session is genuinely locked.
#
# WHY THERE IS A GAP TO COVER AT ALL
#
# The session autologins, so Hyprland composites a real, unauthenticated
# desktop for a beat before hyprlock's lock surface exists. Measured, one boot:
#
#     [10.250]  Hyprland starts
#     [15.232]  Hyprland signals ready
#     [15.504]  hyprlock.service started
#     [15.630]  onLockLocked          <- session actually covered
#
# hyprlock is a Wayland client, so it cannot start before the compositor it is
# covering is serving. Reordering units cannot close that window. Darkening it
# can — the same move the wake path makes in resume-lock.sh.
#
# WHY `hyprctl locked` IS THE RIGHT SIGNAL HERE (and was the wrong one there)
#
# On the wake path this flag is useless: it stays true across the whole swap,
# because the compositor holds the lock when a client dies without unlocking,
# so it can say the screen is covered but not who is covering it. At boot
# there is no prior lock to confuse it with — false means the desktop is bare,
# true means hyprlock has it. That is exactly the question being asked.
set -uo pipefail

DEADLINE=$((SECONDS + 25))

# The trap is the whole safety story. If hyprlock never comes up, the light
# comes back anyway: an unlocked desktop is a known, visible problem, while a
# permanently black panel is indistinguishable from a dead machine and leaves
# no way to fix it. Fail visible, not fail dark.
restore_backlight() {
    brightnessctl -q -r 2>/dev/null || brightnessctl -q set 40% 2>/dev/null
    return 0
}
trap restore_backlight EXIT

while (( SECONDS < DEADLINE )); do
    if [[ $(hyprctl locked 2>/dev/null) == true ]]; then
        # Log what the blackout actually cost, so the next boot's journal says
        # whether this is still worth it:
        #     journalctl --user -b -t boot-unblank
        systemd-cat -t boot-unblank -p info \
            echo "locked after ${SECONDS}s of blackout; restoring backlight" 2>/dev/null
        exit 0   # trap restores
    fi
    sleep 0.05
done

systemd-cat -t boot-unblank -p warning \
    echo "hyprlock did not lock within 25s — restoring backlight on an UNLOCKED session" 2>/dev/null
