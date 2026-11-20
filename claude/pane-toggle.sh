#!/usr/bin/env bash
# pane-toggle.sh — Mod+Shift+D: open/close the Claude side pane: nvim following
# Claude (:ClaudeWatch), or with CLAUDE_PANE=tui the read-only claude/pane.py.
# It opens as the 2nd column of the terminal workspace, beside the Claude
# terminal, without taking focus (niri/conf/rules/apps.kdl).
set -euo pipefail
APP=dev.dotnix.claude-pane
pane() { niri msg -j windows | jq -c --arg a "$APP" '[.[] | select(.app_id == $a)][0] // empty'; }

w=$(pane)
if [[ -n $w ]]; then
	niri msg action close-window --id "$(jq -r .id <<<"$w")"
	exit
fi

# Your nvim, following Claude (nvim/lua/config/modules/claude-watch.lua). It
# listens on claude-pane/watch-nvim.sock, so its state can be checked
# (nvim --server … --remote-expr) without looking at the screen.
# CLAUDE_PANE=tui opens the older read-only viewer (claude/pane.py) instead.
if [[ ${CLAUDE_PANE:-} == tui ]]; then
	setsid -f ghostty --gtk-single-instance=false --class="$APP" --title="claude pane" \
		--custom-shader= -e python3 -I "$HOME/github/config/dotnix/claude/pane.py" >/dev/null 2>&1
else
	setsid -f ghostty --gtk-single-instance=false --class="$APP" --title="claude watch" \
		-e nvim --listen "${XDG_RUNTIME_DIR:-/tmp}/claude-pane/watch-nvim.sock" -c ClaudeWatch >/dev/null 2>&1   # -c, not +: ghostty eats +words
fi

for _ in $(seq 30); do
	w=$(pane)
	[[ -n $w ]] && break
	sleep 0.1
done
[[ -z $w ]] && exit 0

# niri puts it after that workspace's active column; make it column 2.
[[ $(jq -r '.layout.pos_in_scrolling_layout[0]' <<<"$w") == 2 ]] && exit 0
back=$(niri msg -j focused-window | jq -r '.id // empty')
niri msg action focus-window --id "$(jq -r .id <<<"$w")"
niri msg action move-column-to-index 2
[[ -n $back ]] && niri msg action focus-window --id "$back"
exit 0
