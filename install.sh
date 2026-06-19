#!/usr/bin/env bash
#
# dotnix — bootstrap for a fresh Arch install (native or WSL).
#
# Symlinks ALL configs into place every run (so a config is ready even before
# its program is installed). Package installation is tiered:
#
#   minimal    (default)  CLI/TUI toolchain only — what zsh, tmux & nvim need.
#   selective             minimal + an interactive pick-list of desktop groups.
#   full                  minimal + every desktop group.
#
# On Arch-on-WSL the desktop groups never apply (the Windows side provides the
# GUI), so every mode collapses to the minimal CLI set there.
#
# Usage:
#   ./install.sh                 minimal install (default)
#   ./install.sh --selective     minimal + choose desktop groups
#   ./install.sh --full          minimal + all desktop groups
#   ./install.sh --symlinks-only just (re)create the symlinks
#   ./install.sh --no-aur        skip AUR packages / paru bootstrap
#   ./install.sh -h | --help

set -uo pipefail

# ── Pretty output ─────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()  { printf '%s\n' "${BLUE}$*${NC}"; }
ok()    { printf '%s\n' "${GREEN}✓ $*${NC}"; }
warn()  { printf '%s\n' "${YELLOW}! $*${NC}"; }
err()   { printf '%s\n' "${RED}✗ $*${NC}" >&2; }
step()  { printf '\n%s\n' "${BOLD}${BLUE}▶ $*${NC}"; }

# ── Paths & flags ─────────────────────────────────────────────────────────
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
BACKUP_DIR="$CONFIG_DIR/dotnix-backup-$(date +%Y%m%d_%H%M%S)"

MODE=minimal           # minimal | selective | full
SYMLINKS_ONLY=0
DO_AUR=1
for arg in "$@"; do
  case "$arg" in
    --minimal)                     MODE=minimal ;;
    --selective|-s)                MODE=selective ;;
    --full)                        MODE=full ;;
    --symlinks-only|--no-packages) SYMLINKS_ONLY=1 ;;
    --no-aur)                      DO_AUR=0 ;;
    -h|--help)
      sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

# ── Environment detection ─────────────────────────────────────────────────
IS_WSL=0
[[ "$(uname -r)" == *microsoft* ]] && IS_WSL=1
HAVE_PACMAN=0
command -v pacman &>/dev/null && HAVE_PACMAN=1

# Top-level repo dirs that are NOT ~/.config symlinks.
# qbittorrent is special-cased in run_symlinks (only its theme subdir is
# linked, since ~/.config/qBittorrent holds live runtime state).
EXCLUDE_DIRS=(shell grub_cpy nvim_backup qbittorrent)

# ──────────────────────────────────────────────────────────────────────────
# Package sets
# ──────────────────────────────────────────────────────────────────────────
# Minimal, every machine — the CLI/TUI toolchain zsh/tmux/nvim depend on.
PACMAN_COMMON=(
  base-devel git zsh tmux neovim fzf zoxide eza bat ripgrep fd
  fastfetch tree lazygit yazi zip unzip python man-db openssh
)
AUR_COMMON=( sesh )

# Minimal, native only — essential deps for the terminal/nvim to behave on a
# real Linux desktop (icon glyphs + a working system clipboard). On WSL the
# Windows host supplies fonts and the clipboard, so these are skipped.
PACMAN_COMMON_NATIVE=(
  ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols wl-clipboard xclip
)

# Optional desktop groups (native only). Selected via --full or --selective.
DESKTOP_GROUPS=( terminals desktop hyprland sway theming media pdf launcher )

declare -A GROUP_DESC=(
  [terminals]="Terminal emulators (kitty, ghostty)"
  [desktop]="Wayland desktop utils (waybar, dunst, eww, screenshots, audio, brightness)"
  [hyprland]="Hyprland compositor"
  [sway]="Sway compositor"
  [theming]="GTK/Qt theming (kvantum, qt5ct, fontconfig)"
  [media]="Media (mpv + streamlink for twitch)"
  [pdf]="PDF viewers (zathura, sioyek)"
  [launcher]="App launcher (albert)"
)
declare -A GROUP_PACMAN=(
  [terminals]="kitty ghostty"
  [desktop]="waybar dunst polkit brightnessctl playerctl grim slurp xsettingsd nwg-look volumeicon pavucontrol"
  [hyprland]="hyprland"
  [sway]="sway swaybg"
  [theming]="kvantum kvantum-qt5 qt5ct fontconfig"
  [media]="mpv streamlink"
  [pdf]="zathura zathura-pdf-mupdf"
  [launcher]=""
)
declare -A GROUP_AUR=(
  [desktop]="eww"
  [pdf]="sioyek"
  [launcher]="albert"
)

# ──────────────────────────────────────────────────────────────────────────
# Package installation helpers
# ──────────────────────────────────────────────────────────────────────────
install_pacman() {
  local want=("$@") avail=() missing=() p
  ((${#want[@]})) || return 0
  for p in "${want[@]}"; do
    if pacman -Si "$p" &>/dev/null; then avail+=("$p"); else missing+=("$p"); fi
  done
  if ((${#avail[@]})); then
    sudo pacman -S --needed --noconfirm "${avail[@]}" \
      && ok "pacman: ${#avail[@]} packages installed/present" \
      || warn "pacman reported errors — see output above"
  fi
  ((${#missing[@]})) && warn "not in official repos, skipping: ${missing[*]}"
}

bootstrap_paru() {
  command -v paru &>/dev/null && { AUR_HELPER=paru; return 0; }
  command -v yay  &>/dev/null && { AUR_HELPER=yay;  return 0; }
  info "no AUR helper found — bootstrapping paru from the AUR…"
  sudo pacman -S --needed --noconfirm base-devel git || return 1
  local tmp; tmp="$(mktemp -d)"
  if git clone --depth=1 https://aur.archlinux.org/paru.git "$tmp/paru" \
     && ( cd "$tmp/paru" && makepkg -si --noconfirm ); then
    rm -rf "$tmp"; AUR_HELPER=paru; ok "paru installed"
  else
    rm -rf "$tmp"; err "paru bootstrap failed"; return 1
  fi
}

install_aur() {
  local want=("$@")
  ((${#want[@]})) || return 0
  "$AUR_HELPER" -S --needed --noconfirm "${want[@]}" \
    && ok "AUR: ${want[*]}" \
    || warn "AUR helper reported errors for: ${want[*]}"
}

# Interactive desktop-group picker. Fills the named array via a bash nameref.
select_groups() {
  local -n __out=$1
  printf '%s\n' "${BOLD}Optional desktop groups${NC} (the CLI set is always installed):"
  local i=1 g
  for g in "${DESKTOP_GROUPS[@]}"; do
    printf '  %2d) %-10s %s\n' "$i" "$g" "${GROUP_DESC[$g]}"
    ((i++))
  done
  printf "Numbers (e.g. '2 3 4'), 'all', or empty for none: "
  local reply n; read -r reply
  if [[ "$reply" == all ]]; then __out=("${DESKTOP_GROUPS[@]}"); return; fi
  for n in $reply; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#DESKTOP_GROUPS[@]} )) && __out+=("${DESKTOP_GROUPS[$((n-1))]}")
  done
}

run_packages() {
  if ((!HAVE_PACMAN)); then
    warn "pacman not found — not an Arch system; skipping package install."
    return 0
  fi

  # Decide which desktop groups to install.
  local -a selected=()
  if ((IS_WSL)); then
    [[ "$MODE" != minimal ]] && info "WSL: desktop groups don't apply — installing the CLI set only."
  else
    case "$MODE" in
      full)      selected=("${DESKTOP_GROUPS[@]}") ;;
      selective) select_groups selected ;;
      minimal)   : ;;
    esac
  fi

  # Assemble the final package lists.
  local -a pac=("${PACMAN_COMMON[@]}") aur=() g
  ((IS_WSL)) || pac+=("${PACMAN_COMMON_NATIVE[@]}")
  ((DO_AUR)) && aur+=("${AUR_COMMON[@]}")
  for g in "${selected[@]}"; do
    [[ -n "${GROUP_PACMAN[$g]:-}" ]] && pac+=( ${GROUP_PACMAN[$g]} )
    ((DO_AUR)) && [[ -n "${GROUP_AUR[$g]:-}" ]] && aur+=( ${GROUP_AUR[$g]} )
  done
  ((${#selected[@]})) && info "desktop groups: ${selected[*]}"

  step "Refreshing databases & upgrading system (-Syu avoids partial upgrades)"
  sudo pacman -Syu --noconfirm || warn "pacman -Syu failed (continuing)"

  step "Installing packages (${#pac[@]})"
  install_pacman "${pac[@]}"

  if ((DO_AUR)) && ((${#aur[@]})); then
    step "Setting up AUR packages"
    if bootstrap_paru; then install_aur "${aur[@]}"; else warn "skipping AUR packages (no helper)."; fi
  elif ((!DO_AUR)); then
    info "--no-aur given — skipping AUR packages."
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Symlinks — ALWAYS link everything, regardless of install mode.
# ──────────────────────────────────────────────────────────────────────────
declare -a LINKED=() RELINKED=() BACKED=() FAILED=()

is_excluded() {
  local name="$1" e
  for e in "${EXCLUDE_DIRS[@]}"; do [[ "$name" == "$e" ]] && return 0; done
  return 1
}

# link <source> <target> <label>
link() {
  local src="$1" dst="$2" label="$3"
  if [[ ! -e "$src" ]]; then err "source missing: $src"; FAILED+=("$label"); return; fi
  if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
    LINKED+=("$label"); return
  fi
  if [[ -L "$dst" ]]; then
    rm -f "$dst"; ln -s "$src" "$dst" && RELINKED+=("$label") || FAILED+=("$label")
    return
  fi
  if [[ -e "$dst" ]]; then
    mkdir -p "$BACKUP_DIR"
    if mv "$dst" "$BACKUP_DIR/"; then BACKED+=("$label"); else err "backup failed: $dst"; FAILED+=("$label"); return; fi
  fi
  ln -s "$src" "$dst" && RELINKED+=("$label") || FAILED+=("$label")
}

run_symlinks() {
  step "Linking ~/.config entries"
  mkdir -p "$CONFIG_DIR"
  local dir name
  for dir in "$DOTFILES_DIR"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    is_excluded "$name" && continue
    link "$dir" "$CONFIG_DIR/$name" "$name"
  done

  # qBittorrent: link only the custom theme, not the whole (stateful) dir.
  mkdir -p "$CONFIG_DIR/qBittorrent/themes"
  link "$DOTFILES_DIR/qbittorrent/themes/lumen" \
       "$CONFIG_DIR/qBittorrent/themes/lumen" "qBittorrent/themes/lumen"

  step "Linking home dotfiles"
  local f base
  # Every dotfile (file or symlink) directly under shell/ — the zsh/ subdir is
  # sourced via .zshrc, not linked into $HOME.
  for f in "$DOTFILES_DIR"/shell/.[!.]*; do
    [[ -f "$f" || -L "$f" ]] || continue
    base="$(basename "$f")"
    link "$f" "$HOME/$base" "$base"
  done
}

# ──────────────────────────────────────────────────────────────────────────
# Login shell + plugins
# ──────────────────────────────────────────────────────────────────────────
set_login_shell() {
  ((HAVE_PACMAN)) || return 0
  local zsh_path; zsh_path="$(command -v zsh)" || return 0
  if [[ "${SHELL:-}" == "$zsh_path" ]] && [[ "$(getent passwd "$USER" | cut -d: -f7)" == "$zsh_path" ]]; then
    ok "login shell already zsh"; return 0
  fi
  step "Setting zsh as the login shell"
  grep -qx "$zsh_path" /etc/shells 2>/dev/null || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  if chsh -s "$zsh_path"; then ok "login shell set to $zsh_path (re-login to take effect)"
  else warn "chsh failed — set it manually with: chsh -s $zsh_path"; fi
}

sync_plugins() {
  command -v nvim &>/dev/null || return 0
  step "Syncing Neovim plugins (lazy.nvim)"
  nvim --headless "+Lazy! sync" +qa &>/dev/null \
    && ok "Neovim plugins synced" \
    || warn "nvim plugin sync had issues — open nvim once to finish."
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────
printf '%s\n' "${BOLD}${BLUE}dotnix bootstrap${NC}"
printf 'repo:   %s\n' "$DOTFILES_DIR"
printf 'target: %s  and  ~ dotfiles\n' "$CONFIG_DIR"
printf 'mode:   %s | %s\n' \
  "$([[ $IS_WSL == 1 ]] && echo WSL || echo native)" \
  "$([[ $SYMLINKS_ONLY == 1 ]] && echo 'symlinks only' || echo "$MODE install")"

if ((!SYMLINKS_ONLY)) && ((HAVE_PACMAN)); then
  info "requesting sudo up front (for package installation)…"
  sudo -v || { err "sudo required for package install — re-run with --symlinks-only to skip."; exit 1; }
fi

((SYMLINKS_ONLY)) || run_packages
run_symlinks
((SYMLINKS_ONLY)) || set_login_shell
((SYMLINKS_ONLY)) || sync_plugins

# ── Summary ───────────────────────────────────────────────────────────────
step "Summary"
((${#RELINKED[@]})) && info "linked:   ${RELINKED[*]}"
((${#LINKED[@]}))   && ok   "already:  ${#LINKED[@]} up to date"
((${#BACKED[@]}))   && warn "backed up (in $BACKUP_DIR): ${BACKED[*]}"
((${#FAILED[@]}))   && err  "failed:   ${FAILED[*]}"

printf '\n%s\n' "${GREEN}${BOLD}Done.${NC}"
echo "All configs are symlinked — even for programs you didn't install yet."
echo "Next: start a new shell (or 'exec zsh'). nvim installs remaining plugins on first launch."
if ((!IS_WSL)) && [[ "$MODE" == minimal ]]; then
  echo "Tip: install a compositor/desktop later with  ./install.sh --selective"
fi
