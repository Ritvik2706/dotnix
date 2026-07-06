#!/usr/bin/env bash
# waybar-ws.sh <workspace-id>
# Emits waybar JSON for a single Hyprland workspace pill.
#
# Why this exists: this Hyprland build Lua-evaluates every IPC dispatch, so
# waybar's built-in hyprland/workspaces "activate" click (which sends the
# legacy `dispatch workspace N`) fails. We render each workspace as a custom
# module whose on-click calls the working `hl.dsp.focus({workspace=N})` form.
#
# Output classes mirror #workspaces button styling:
#   active   -> the focused workspace (drawn as the inflated pill)
#   occupied -> has windows (drawn as a bead)
#   empty    -> no windows -> empty text so the module collapses (hidden),
#               matching the old "only occupied/focused" behaviour.
set -euo pipefail

id="${1:?usage: waybar-ws.sh <workspace-id>}"

active=$(hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty')
occupied=$(hyprctl -j workspaces 2>/dev/null | jq -r '.[] | select(.windows > 0) | .id')

class="empty"
text=""
if [[ "$id" == "$active" ]]; then
  class="active"
  text="$id"
elif grep -qx "$id" <<<"$occupied"; then
  class="occupied"
  text="$id"
fi

printf '{"text":"%s","class":"%s"}\n' "$text" "$class"
