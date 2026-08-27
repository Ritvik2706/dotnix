#!/usr/bin/env bash
#
# Wire up the "one authentication surface" arrangement:
#
#     cold boot ─┐
#                ├─→ hyprlock  ─→ desktop
#     idle / lid ┘
#
# SDDM autologins straight into Hyprland, and hyprlock.service covers the
# session before anything is drawn. Boot and lock are then not two themes
# kept in sync — they are the same program. Howdy authenticates both, because
# there is only one thing left to authenticate against.
#
# THE TRADE, stated plainly: the session starts before anyone authenticates.
# Autostarted apps run behind the lock, and a hyprlock that never comes up
# means a bare desktop. That is why hyprlock.service retries forever rather
# than hitting a start limit. If that trade is not acceptable, don't run this
# — use SDDM as a real greeter instead (sddm/apply.sh) and keep hyprlock for
# locking only.
#
# Everything here is idempotent and reversible with --revert.
#
# Usage:
#   ./lock-setup.sh            wire it up
#   ./lock-setup.sh --revert   back to a normal SDDM greeter
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO=$(cd .. && pwd)

USER_NAME=${SUDO_USER:-$USER}
SESSION=hyprland-uwsm.desktop
AUTOLOGIN_CONF=/etc/sddm.conf.d/20-autologin.conf
HOWDY_CONF=/etc/howdy/config.ini
UNIT_SRC="$REPO/system/systemd/hyprlock.service"
UNIT_DST="$HOME/.config/systemd/user/hyprlock.service"
# The boot blackout. Autologin means Hyprland composites a real, unauthenticated
# desktop for ~400ms before hyprlock's surface exists, and hyprlock cannot start
# any earlier (it is a Wayland client of the compositor it covers). This unit
# darkens the panel before Hyprland's first frame; hypr/scripts/boot-unblank.sh
# brings it back once `hyprctl locked` is true.
BLANK_SRC="$REPO/system/systemd/hyprlock-blank.service"
BLANK_DST="$HOME/.config/systemd/user/hyprlock-blank.service"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ──────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--revert" ]]; then
    say "removing autologin"
    sudo rm -f "$AUTOLOGIN_CONF"

    say "disabling the lock unit"
    systemctl --user disable --now hyprlock.service 2>/dev/null || true
    systemctl --user disable --now hyprlock-blank.service 2>/dev/null || true
    rm -f "$UNIT_DST" "$BLANK_DST"
    systemctl --user daemon-reload
    # Leave nothing dark behind: if the revert lands while the blackout is up,
    # the panel would otherwise stay at zero with no unit left to undo it.
    brightnessctl -q -r 2>/dev/null || brightnessctl -q set 40% 2>/dev/null || true

    if [[ -f "$HOWDY_CONF.dotnix-bak" ]]; then
        say "restoring howdy config"
        sudo mv "$HOWDY_CONF.dotnix-bak" "$HOWDY_CONF"
    fi

    echo
    echo "reverted. SDDM will ask for a password on next boot."
    echo "the LUMEN greeter theme is untouched — see sddm/apply.sh"
    exit 0
fi

command -v hyprlock >/dev/null || { echo "hyprlock is not installed" >&2; exit 1; }
[[ -f /usr/share/wayland-sessions/$SESSION ]] \
    || { echo "session file $SESSION not found" >&2; exit 1; }

# ── 1. the lock unit ──────────────────────────────────────────────────────
# Linked, not copied, so edits in the repo are live after a daemon-reload.
say "installing hyprlock.service"
mkdir -p "$(dirname "$UNIT_DST")"
ln -sfn "$UNIT_SRC" "$UNIT_DST"
ln -sfn "$BLANK_SRC" "$BLANK_DST"
systemctl --user daemon-reload
systemctl --user enable hyprlock.service
systemctl --user enable hyprlock-blank.service
echo "  enabled — the session will now come up locked, behind a dark panel"

# ── 2. autologin ──────────────────────────────────────────────────────────
# Relogin=false on purpose: with Relogin=true an explicit logout would drop
# you straight back into a new session, making it impossible to reach the
# greeter (or another session) without editing this file from a TTY.
say "configuring autologin for $USER_NAME"
sudo mkdir -p /etc/sddm.conf.d
sudo tee "$AUTOLOGIN_CONF" >/dev/null <<EOF
# Managed by dotnix — see system/lock-setup.sh
# The greeter is bypassed at boot; hyprlock is the authentication surface.
[Autologin]
User=$USER_NAME
Session=$SESSION
Relogin=false
EOF
echo "  $AUTOLOGIN_CONF"

# ── 3. howdy ──────────────────────────────────────────────────────────────
# Tuned for the IR sensor rather than for a webcam. /dev/video2 on this
# machine is the GREY 8-bit stream — the Windows-Hello IR sensor, exposed
# under the RGB camera's name — which is the correct device and already set.
if [[ -f "$HOWDY_CONF" ]]; then
    say "tuning howdy"
    [[ -f "$HOWDY_CONF.dotnix-bak" ]] || sudo cp "$HOWDY_CONF" "$HOWDY_CONF.dotnix-bak"

    set_key() {  # set_key <key> <value> <why>
        sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*($1)[[:space:]]*=.*|\1 = $2|" "$HOWDY_CONF"
        printf '  %-16s %-6s %s\n' "$1" "$2" "$3"
    }

    # dark_threshold is a SKIP threshold, not a floor: compare.py computes
    # `darkness` as the percentage of pixels in the darkest eighth of the
    # histogram and skips the frame when darkness > dark_threshold. So a LOWER
    # value throws away MORE frames. 60 is upstream's default and correct;
    # raise it toward 80 (never lower it) if the log ever says "All frames
    # were too dark".
    set_key dark_threshold 60 "upstream default; lower values discard MORE frames"

    # Evidence-based: every successful unlock in this machine's journal came
    # back in ~2s. 4s was already enough when someone is actually there, and
    # every extra second is spent by the UNATTENDED scans (see below), not by
    # you. 5 leaves a little room for the IR exposure to settle in the dark.
    set_key timeout 5 "successes land in ~2s; the rest is unattended burn"

    # Suppress "Identified face as ritvik" — hyprlock renders PAM messages in
    # the field, and a success message flashing where the dots are is noise.
    set_key no_confirmation true "no PAM chatter in the dot row"

    # Never scan while the lid is shut (a closed lid means a black frame and
    # a guaranteed failed attempt) or over SSH.
    set_key abort_if_lid_closed true "a shut lid can only fail"
    set_key abort_if_ssh true "never face-auth a remote session"

    echo
    echo "  NOT changed: certainty=4.2 (default is 3.5 — yours is already"
    echo "  permissive, which trades false rejects for false accepts). Lower"
    echo "  it toward 3.5 if you want face unlock to be stricter."
else
    echo "howdy config not found at $HOWDY_CONF — skipping" >&2
fi

# ── done ──────────────────────────────────────────────────────────────────
say "done"
cat <<EOF
Test BEFORE rebooting, in this order:

  1. lock now, without touching the session:
         systemctl --user start hyprlock.service
     unlock with your face, then with your password.

  2. confirm it locks itself on the next session start:
         systemctl --user is-enabled hyprlock.service     # -> enabled

  3. watch what howdy actually does (run from a TTY, not this session):
         sudo howdy test

Keep a TTY open (Ctrl+Alt+F2) the first time you reboot. If anything goes
wrong you can log in there and run:  $REPO/system/lock-setup.sh --revert
EOF
