# Cached shell tool init — avoids subprocess forks on every startup.
# Each cache is rebuilt only when the tool binary is newer than the cached file.

_zsh_cache_dir="$HOME/.cache/zsh"
[[ -d "$_zsh_cache_dir" ]] || mkdir -p "$_zsh_cache_dir"

# fzf key bindings and completion
if command -v fzf &>/dev/null; then
  _fzf_cache="$_zsh_cache_dir/fzf-init.zsh"
  if [[ ! -f "$_fzf_cache" || "$commands[fzf]" -nt "$_fzf_cache" ]]; then
    fzf --zsh >| "$_fzf_cache"
  fi
  source "$_fzf_cache"
  unset _fzf_cache
fi

# zoxide (smart cd replacement)
if command -v zoxide &>/dev/null; then
  _zoxide_cache="$_zsh_cache_dir/zoxide-init.zsh"
  if [[ ! -f "$_zoxide_cache" || "$commands[zoxide]" -nt "$_zoxide_cache" ]]; then
    zoxide init zsh >| "$_zoxide_cache"
  fi
  source "$_zoxide_cache"
  unset _zoxide_cache
fi

unset _zsh_cache_dir
