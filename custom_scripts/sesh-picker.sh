#!/usr/bin/env bash
set -euo pipefail

if tmux list-clients >/dev/null 2>&1; then
  # We're already in/attached to tmux somewhere → focus ghostty window and show popup
  
  # Focus the ghostty window (Hyprland or niri: see the island's wm.sh)
  ~/.config/lumen/shells/island/scripts/wm.sh focus-class com.mitchellh.ghostty || true
  
  # Show the full-featured sesh popup (same as C-a T)
  tmux run-shell "sesh connect \"\$(
    sesh list --icons | fzf-tmux -p 80%,70% \\
      --no-sort --ansi --border-label ' sesh ' --prompt '⚡  ' \\
      --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \\
      --bind 'tab:down,btab:up' \\
      --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \\
      --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \\
      --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \\
      --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \\
      --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \\
      --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \\
      --preview-window 'right:55%' \\
      --preview 'sesh preview {}'
  )\""
else
  # No client yet → open terminal once and run picker there with full features
  exec ghostty -e bash -lc '
    sel="$(sesh list --icons | fzf --prompt="⚡  " --ansi --preview="sesh preview {}")"
    [ -n "$sel" ] && exec sesh connect "$sel"
  '
fi