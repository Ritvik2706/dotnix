# Resolve the real location of this file through the symlink so module paths
# work regardless of where the dotfiles repo is cloned.
_zsh_dir="$(dirname "$(readlink -f "${HOME}/.zshrc")")/zsh"

# Detect WSL once via kernel name — more reliable than WSL_DISTRO_NAME, which
# tmux-spawned shells don't inherit. Exported so functions and child processes
# can branch on it. Set before sourcing modules so functions.zsh can use it.
[[ "$(uname -r)" == *microsoft* ]] && export IS_WSL=1

source "$_zsh_dir/plugins.zsh"
source "$_zsh_dir/exports.zsh"
source "$_zsh_dir/history.zsh"
source "$_zsh_dir/completions.zsh"
source "$_zsh_dir/aliases.zsh"
source "$_zsh_dir/functions.zsh"
source "$_zsh_dir/tools.zsh"

# WSL-only Windows interop (winget/winutil wrappers, env vars, …)
[[ -n "$IS_WSL" ]] && source "$_zsh_dir/wsl.zsh"

# Per-machine secrets (API keys, …) — untracked, optional
[[ -f "$_zsh_dir/secrets.zsh" ]] && source "$_zsh_dir/secrets.zsh"

unset _zsh_dir

# Auto-start tmux in interactive shells (skip inside VS Code or existing tmux)
if command -v tmux &>/dev/null && [[ -z "$TMUX" && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux new-session -A -s main -c ~/github
fi
