# PATH — consolidated, no duplicates
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"

# API keys live in zsh/secrets.zsh (untracked; sourced from .zshrc).
# Copy zsh/secrets.zsh.example to zsh/secrets.zsh and fill it in per machine.

# Claude Code caps colours at 256 inside tmux unless told it can use RGB
# (tmux.conf has *:RGB); the status line and themes need true colour.
export CLAUDE_CODE_TMUX_TRUECOLOR=1
