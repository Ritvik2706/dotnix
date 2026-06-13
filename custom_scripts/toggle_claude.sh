#!/usr/bin/env bash
# CopyQ-style floating Claude popup for Hyprland (0.55+ Lua config).
#   - super+S shows Claude as a centered floating window over your CURRENT
#     workspace (launching it the first time).
#   - super+S again hides it by parking it on the special:claude workspace.
# Float/center/size come from the window rule in hypr/lua/rules.lua. This script
# only moves the window in/out of the hidden scratchpad. Hyprland 0.55 uses a Lua
# config, so dispatch goes through the hl.dsp.* API form.
set -euo pipefail

CLASS="chrome-claude.ai__-Default"
HIDE_WS="special:claude"
APP_URL="https://claude.ai/"
CHROMIUM_BIN="${CHROMIUM_BIN:-chromium}"   # ungoogled-chromium-bin installs /usr/bin/chromium

addr_of()  { hyprctl -j clients | jq -r --arg c "$CLASS" '[.[]|select(.class==$c)|.address]|.[0]//empty'; }
ws_of()    { hyprctl -j clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.name'; }
focus()    { hyprctl dispatch 'hl.dsp.focus({window="address:'"$1"'"})' >/dev/null 2>&1 || true; }
move_to()  { hyprctl dispatch 'hl.dsp.window.move({workspace="'"$1"'", follow=false})' >/dev/null 2>&1 || true; }

A="$(addr_of)"

# First run: launch. The window rule floats + centers it on the current
# workspace; wait for it to map, then focus it.
if [[ -z "$A" ]]; then
  "$CHROMIUM_BIN" --ozone-platform-hint=auto --enable-features=UseOzonePlatform \
    --app="$APP_URL" >/dev/null 2>&1 &
  disown
  for _ in {1..60}; do
    A="$(addr_of)"
    [[ -n "$A" ]] && break
    sleep 0.25
  done
  [[ -n "$A" ]] && focus "$A"
  exit 0
fi

if [[ "$(ws_of "$A")" == "$HIDE_WS" ]]; then
  # Hidden -> show on the workspace the user is currently looking at, focused.
  cur="$(hyprctl activeworkspace -j | jq -r '.id')"
  focus "$A"
  move_to "$cur"
  focus "$A"
else
  # Visible -> hide into the scratchpad.
  focus "$A"
  move_to "$HIDE_WS"
fi
