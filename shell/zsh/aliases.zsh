# File listing (requires eza)
alias ls='eza -a --icons'
alias ll='eza -al --icons'
alias lt='eza -a --tree --level=1 --icons'

# NVIDIA PRIME render offload (Wayland/Hyprland)
alias nvidia-run='__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only'

# FZF-based search
alias ffind="fzf --preview 'bat --style=numbers --color=always {} || cat {}' --height=40% --layout=reverse --border --preview-window=right:60%:wrap"
alias fdir="find . -type d | fzf --preview 'tree -C {} | head -100' --height=40% --layout=reverse --border"
alias fopen="fzf --preview 'bat --style=numbers --color=always {} || cat {}' --height=40% --layout=reverse --border | xargs -r -I {} nvim {}"
alias fkill="ps aux | fzf --preview 'echo {}' --height=40% --layout=reverse --border | awk '{print \$2}' | xargs -r kill -9"
