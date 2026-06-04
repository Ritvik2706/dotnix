# Resolve the real location of this file through the symlink so module paths
# work regardless of where the dotfiles repo is cloned.
_zsh_dir="$(dirname "$(readlink -f "${HOME}/.zshrc")")/zsh"

source "$_zsh_dir/plugins.zsh"
source "$_zsh_dir/exports.zsh"
source "$_zsh_dir/history.zsh"
source "$_zsh_dir/completions.zsh"
source "$_zsh_dir/aliases.zsh"
source "$_zsh_dir/functions.zsh"
source "$_zsh_dir/tools.zsh"

# Detect WSL via kernel name — more reliable than WSL_DISTRO_NAME which tmux doesn't inherit
[[ "$(uname -r)" == *microsoft* ]] && source "$_zsh_dir/wsl.zsh"

unset _zsh_dir

# Auto-start tmux in interactive shells (skip inside VS Code or existing tmux)
if command -v tmux &>/dev/null && [[ -z "$TMUX" && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux new-session -A -s main -c ~/github
fi
