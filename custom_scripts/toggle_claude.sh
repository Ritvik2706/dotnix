#!/usr/bin/env bash
# Floating Claude Desktop popup for Hyprland (0.55+ Lua config), and niri.
#   - super+S (or 3-finger up) shows Claude as a centered floating overlay that
#     slides up from the bottom; super+S again (or 3-finger down) slides it away.
# It lives on the special:claude workspace and is shown by *toggling that special
# workspace* over the current monitor — that's what gives the slidevert (bottom)
# animation (see specialWorkspace in hypr/lua/animations.lua). Workspace, float,
# center and size all come from the window rule in hypr/lua/rules.lua, so a
# fresh launch lands on special:claude by itself. Hyprland 0.55 uses a Lua
# config, so dispatch goes through the hl.dsp.* API form.
set -euo pipefail

# Optional action: toggle (default) | show | hide
ACTION="${1:-toggle}"

CLASS="com.anthropic.Claude"     # Wayland app_id of claude-desktop
SPECIAL="claude"                 # special:claude

# niri has no special workspaces and no minimize, and closing Claude's window
# to hide it costs ~4s to rebuild it on show. So there, the niri way: Claude is
# an ordinary full-width window, the second column of workspace 2, beside the
# terminal (one terminal, tmux inside). super+S scrolls over to it; on Claude,
# back to the window you were on. Nothing is ever closed, so both ways are
# instant.
if [[ -n ${NIRI_SOCKET:-} ]]; then
  WS=2 COL=2
  BACK="${XDG_RUNTIME_DIR:-/tmp}/claude-back"   # the window super+S left from
  win="$(niri msg -j windows | jq -c --arg c "$CLASS" '[.[] | select(.app_id == $c)][0] // empty')"
  id="$(jq -r '.id // empty' <<<"$win")"
  focused="$(jq -r '.is_focused // false' <<<"$win")"

  # On Claude: back to the window you came from (on this workspace or another).
  # Remembered rather than niri's focus-window-previous, whose history only
  # takes a focus in after a short delay: a quick there-and-back would miss it.
  if [[ "$ACTION" == "hide" || ( "$ACTION" == "toggle" && "$focused" == true ) ]]; then
    [[ "$focused" == true ]] || exit 0
    back="$(cat "$BACK" 2>/dev/null || true)"
    if [[ -n "$back" ]] && niri msg -j windows | jq -e --argjson b "$back" 'any(.[]; .id == $b)' >/dev/null; then
      niri msg action focus-window --id "$back"
    else
      niri msg action focus-window-previous
    fi
    exit 0
  fi

  niri msg -j focused-window | jq -r '.id // empty' >"$BACK"

  # Open: go to it.
  if [[ -n "$id" ]]; then
    niri msg action focus-window --id "$id"
    exit 0
  fi

  # Not open (not running, or its window was closed to the tray): (re)open it
  # beside the first column of workspace 2, and make sure it is the second.
  # claude-desktop is single-instance, so this also brings a tray-closed
  # window back.
  niri msg action focus-workspace "$WS"
  niri msg action focus-column-first
  claude-desktop >/dev/null 2>&1 &
  disown
  for _ in $(seq 150); do
    id="$(niri msg -j windows | jq -r --arg c "$CLASS" '[.[] | select(.app_id == $c)][0].id // empty')"
    [[ -n "$id" ]] && break
    sleep 0.1
  done
  [[ -z "$id" ]] && exit 0
  niri msg action move-window-to-tiling --id "$id"
  niri msg action focus-window --id "$id"
  niri msg action move-column-to-index "$COL"
  exit 0
fi

addr_of()    { hyprctl -j clients | jq -r --arg c "$CLASS" '[.[]|select(.class==$c)|.address]|.[0]//empty'; }
focus()      { hyprctl dispatch 'hl.dsp.focus({window="address:'"$1"'"})' >/dev/null 2>&1 || true; }
toggle_sp()  { hyprctl dispatch 'hl.dsp.workspace.toggle_special("'"$SPECIAL"'")' >/dev/null 2>&1 || true; }
# Is special:claude currently shown on the focused monitor?
is_shown()   { [[ "$(hyprctl -j monitors | jq -r '.[]|select(.focused).specialWorkspace.name')" == "special:$SPECIAL" ]]; }

A="$(addr_of)"

# No window (not running, or closed to tray): launch / re-show it. claude-desktop
# is single-instance, so a second invocation just brings the main window back.
if [[ -z "$A" ]]; then
  [[ "$ACTION" == "hide" ]] && exit 0
  claude-desktop >/dev/null 2>&1 &
  disown
  for _ in {1..60}; do
    A="$(addr_of)"
    [[ -n "$A" ]] && break
    sleep 0.25
  done
  [[ -z "$A" ]] && exit 0
  is_shown || toggle_sp
  focus "$A"
  exit 0
fi

case "$ACTION" in
  show) is_shown || toggle_sp ;;        # only reveal if hidden
  hide) is_shown && toggle_sp ;;        # only hide if shown
  *)    toggle_sp ;;                    # toggle
esac

is_shown && focus "$A" || true
