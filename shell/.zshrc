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
source "$_zsh_dir/prompt-status.zsh"

# WSL-only Windows interop (winget/winutil wrappers, env vars, …)
[[ -n "$IS_WSL" ]] && source "$_zsh_dir/wsl.zsh"

# Per-machine secrets (API keys, …) — untracked, optional
[[ -f "$_zsh_dir/secrets.zsh" ]] && source "$_zsh_dir/secrets.zsh"

unset _zsh_dir

# Set DOTNIX_NO_TMUX=1 to start a plain shell. Keep the terminal's starting
# directory when creating main; attaching preserves the existing workspace.
if [[ -o interactive && -t 0 && -t 1 && -z "$TMUX" && "$TERM_PROGRAM" != "vscode" && "${DOTNIX_NO_TMUX:-0}" != 1 ]] && command -v tmux &>/dev/null; then
  tmux new-session -A -s main -c "$PWD"
fi
