# Claude Code shortcuts
alias c='claude'                          # short invoke
alias cc='claude --continue'              # resume most recent session in this dir
alias cr='claude --resume'                # interactive picker to pick a specific session
alias co='claude --model opus'            # quick model override for a harder task
alias cq='noglob cq'                     # allow unquoted questions containing ? or *

# File listing (requires eza)
alias ls='eza -a --icons=auto'
alias ll='eza -al --icons=auto'
alias lt='eza -a --tree --level=1 --icons=auto'

# NVIDIA PRIME render offload (Wayland/Hyprland)
alias nvidia-run='__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only'

# FZF-based search
alias ffind="fzf --preview 'bat --style=numbers --color=always {} || cat {}' --height=40% --layout=reverse --border --preview-window=right:60%:wrap"
alias fdir="find . -type d | fzf --preview 'tree -C {} | head -100' --height=40% --layout=reverse --border"
alias fopen="fzf --preview 'bat --style=numbers --color=always {} || cat {}' --height=40% --layout=reverse --border | xargs -r -I {} nvim {}"
alias fkill="ps aux | fzf --preview 'echo {}' --height=40% --layout=reverse --border | awk '{print \$2}' | xargs -r kill -9"

# Road Trip Ltd company hub (runs from source, in its own venv)
alias roadtrip='~/github/projects/roadtripltd/.venv/bin/python ~/github/projects/roadtripltd/main.py'

# Arch's openai-codex package ships a bare binary without the package layout the
# app-server daemon needs, so run codex in-process
alias codex='codex --no-daemon'
