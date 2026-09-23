#!/usr/bin/env bash

# Keep the list and preview on the terminal background.
selection=$(
  sesh list --icons | fzf-tmux -p 80%,70% \
    --no-sort --ansi --layout=reverse --border=rounded \
    --color='bg:-1,bg+:-1,preview-bg:-1,gutter:-1,input-bg:-1,header-bg:-1,fg:#cdd6f4,fg+:#cdd6f4,hl:#cba6f7,hl+:#cba6f7,pointer:#89b4fa,prompt:#cba6f7,border:#6c7086,header:#a6adc8' \
    --border-label ' sesh ' --prompt '⚡  ' \
    --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \
    --bind 'tab:down,btab:up' \
    --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
    --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
    --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
    --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
    --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
    --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
    --preview-window 'right:55%' \
    --preview 'sesh preview {}'
) || exit 0

[[ -n "$selection" ]] && sesh connect "$selection"
