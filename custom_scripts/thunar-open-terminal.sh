#!/usr/bin/env bash
# Xfce "TerminalEmulator" helper: open a new tmux window at the directory
# Thunar was showing, then jump to the workspace holding the terminal.
# Falls back to a plain ghostty window when no tmux server is running.
#
# exo/xfce4-mime-helper runs us with cwd set to the target directory;
# a directory may also arrive as $1. Always exit 0 — a non-zero status
# makes Thunar pop up "Failed to execute default Terminal Emulator".

dir="${1:-$PWD}"
[ -d "$dir" ] || dir="$PWD"

focus_terminal() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # most recently focused ghostty window (lowest focusHistoryID)
  local info
  info=$(hyprctl clients -j 2>/dev/null |
    jq -r '[.[] | select(.class | test("ghostty"; "i"))]
           | sort_by(.focusHistoryID) | first
           | select(. != null) | "\(.address) \(.workspace.id)"') || return 0
  [ -n "$info" ] || return 0

  local addr ws
  read -r addr ws <<<"$info"
  # Hyprland 0.55+ Lua config: legacy `hyprctl dispatch workspace 2` is parsed
  # as Lua and fails silently — dispatch the hl.dsp.* objects instead.
  hyprctl dispatch "hl.dsp.focus({workspace = $ws})" >/dev/null 2>&1
  hyprctl dispatch "hl.dsp.focus({window = \"address:$addr\"})" >/dev/null 2>&1
}

if tmux has-session 2>/dev/null; then
  tmux new-window -c "$dir"
  focus_terminal
else
  cd "$dir" || exit 0
  ghostty &
fi

exit 0
