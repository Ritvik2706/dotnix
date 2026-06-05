# ── Performance tuning ────────────────────────────────────────────────────
ZSH_AUTOSUGGEST_MANUAL_REBIND=1
ZSH_AUTOSUGGEST_USE_ASYNC=true
ZSH_AUTOSUGGEST_STRATEGY=(history completion)

# ── Zinit bootstrap ───────────────────────────────────────────────────────
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"
if [[ ! -d "$ZINIT_HOME" ]]; then
  print -P "%F{cyan}zinit: first run — installing...%f"
  mkdir -p "$(dirname "$ZINIT_HOME")"
  git clone --depth=1 https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi
source "$ZINIT_HOME/zinit.zsh"

# ── Synchronous: theme + plugin aliases only ──────────────────────────────
# Everything here blocks the prompt — keep it minimal.

# git.zsh calls _omz_register_handler (from async_prompt.zsh) which we don't
# load. The theme uses git_prompt_info synchronously so async is not needed.
function _omz_register_handler() { return 0 }
zinit snippet OMZL::git.zsh
setopt PROMPT_SUBST
zinit snippet OMZT::xiong-chiamiov-plus

zinit snippet OMZP::git              # git aliases: gst, gco, gd, gl, etc.
zinit snippet OMZP::archlinux        # yay/pacman aliases

# Basic vi mode active immediately; full zsh-vi-mode loads async below
bindkey -v

# ── Turbo: everything else after the prompt renders ───────────────────────
# wait"0" = schedule for after first prompt; lucid = no output

zinit ice wait"0" lucid
zinit light zsh-users/zsh-autosuggestions

# fast-syntax-highlighting: faster + richer than zsh-syntax-highlighting
zinit ice wait"0" lucid
zinit light zdharma-continuum/fast-syntax-highlighting

# Completions + compinit deferred together — Tab works within 50ms of prompt
zinit ice wait"0" lucid blockf atinit"autoload -Uz compinit && compinit -C && zinit cdreplay -q"
zinit light zsh-users/zsh-completions

zinit ice wait"0" lucid atload"
  bindkey '^[[A' history-substring-search-up
  bindkey '^[[B' history-substring-search-down"
zinit light zsh-users/zsh-history-substring-search

zinit ice wait"0" lucid
zinit light joshskidmore/zsh-fzf-history-search

zinit ice wait"0" lucid
zinit light hlissner/zsh-autopair

# Full vi-mode: loads async; basic bindkey -v already active above.
# zsh-vi-mode resets ALL key bindings on init — use its hook to restore them.
# zvm_config runs before the plugin initializes (must be defined pre-load).
function zvm_config() {
  # Always start a fresh prompt in insert mode. Default is "last mode", which
  # carries normal mode (block cursor) over to the next prompt when the
  # previous line ended in normal mode — the cause of the stray block cursor.
  ZVM_LINE_INIT_MODE=$ZVM_MODE_INSERT
  # Pin cursor shapes: bar while typing, block in normal/command mode.
  ZVM_CURSOR_STYLE_ENABLED=true
  ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_BLINKING_BEAM
  ZVM_NORMAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK
}
zinit ice wait"0" lucid
zinit light jeffreytse/zsh-vi-mode

function zvm_after_init() {
  # Restore fzf bindings (Ctrl+R, Ctrl+T, Alt+C) that vi-mode overwrote
  local fzf_cache="$HOME/.cache/zsh/fzf-init.zsh"
  [[ -f "$fzf_cache" ]] && source "$fzf_cache"
  # Restore history-substring-search arrow bindings
  bindkey '^[[A' history-substring-search-up   2>/dev/null
  bindkey '^[[B' history-substring-search-down 2>/dev/null
  # Let backspace delete freely in insert mode. The vi default
  # (vi-backward-delete-char) stops at the point insert mode began, so you
  # can't backspace over a paste — this removes that wall.
  bindkey -M viins '^?' backward-delete-char
  bindkey -M viins '^H' backward-delete-char
}

# QoL: shows alias hint when you type a long-form command that has an alias
# e.g. typing `git status` reminds you that `gst` exists
zinit ice wait"0" lucid
zinit light MichaelAquilina/zsh-you-should-use
