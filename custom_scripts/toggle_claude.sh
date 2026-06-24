#!/usr/bin/env bash
# Floating Claude popup for Hyprland (0.55+ Lua config).
#   - super+S (or 3-finger up) shows Claude as a centered floating overlay that
#     slides up from the bottom; super+S again (or 3-finger down) slides it away.
# It lives on the special:claude workspace and is shown by *toggling that special
# workspace* over the current monitor — that's what gives the slidevert (bottom)
# animation (see specialWorkspace in hypr/lua/animations.lua). Float/center/size
# come from the window rule in hypr/lua/rules.lua. Hyprland 0.55 uses a Lua
# config, so dispatch goes through the hl.dsp.* API form.
set -euo pipefail

# Optional action: toggle (default) | show | hide
ACTION="${1:-toggle}"

CLASS="chrome-claude.ai__-Default"
SPECIAL="claude"                 # special:claude
APP_URL="https://claude.ai/"
CHROMIUM_BIN="${CHROMIUM_BIN:-chromium}"   # ungoogled-chromium-bin installs /usr/bin/chromium

addr_of()    { hyprctl -j clients | jq -r --arg c "$CLASS" '[.[]|select(.class==$c)|.address]|.[0]//empty'; }
ws_of()      { hyprctl -j clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.name'; }
focus()      { hyprctl dispatch 'hl.dsp.focus({window="address:'"$1"'"})' >/dev/null 2>&1 || true; }
move_to()    { hyprctl dispatch 'hl.dsp.window.move({workspace="'"$1"'", follow=false})' >/dev/null 2>&1 || true; }
toggle_sp()  { hyprctl dispatch 'hl.dsp.workspace.toggle_special("'"$SPECIAL"'")' >/dev/null 2>&1 || true; }
# Is special:claude currently shown on the focused monitor?
is_shown()   { [[ "$(hyprctl -j monitors | jq -r '.[]|select(.focused).specialWorkspace.name')" == "special:$SPECIAL" ]]; }

A="$(addr_of)"

# First run: launch, park it on special:claude, then reveal it with the slide.
if [[ -z "$A" ]]; then
  "$CHROMIUM_BIN" --ozone-platform-hint=auto --enable-features=UseOzonePlatform \
    --app="$APP_URL" >/dev/null 2>&1 &
  disown
  for _ in {1..60}; do
    A="$(addr_of)"
    [[ -n "$A" ]] && break
    sleep 0.25
  done
  [[ -z "$A" ]] && exit 0
  move_to "special:$SPECIAL"     # park on the special workspace
  is_shown || toggle_sp          # slide it up from the bottom
  focus "$A"
  exit 0
fi

# Make sure the window actually lives on special:claude (it always should).
[[ "$(ws_of "$A")" == "special:$SPECIAL" ]] || move_to "special:$SPECIAL"

case "$ACTION" in
  show) is_shown || toggle_sp ;;        # only reveal if hidden
  hide) is_shown && toggle_sp ;;        # only hide if shown
  *)    toggle_sp ;;                    # toggle
esac

is_shown && focus "$A" || true
