# Ritvik's Dotfiles 

A collection of my personal configuration files for Linux (Manjaro/Arch) with a focus on Hyprland window manager, modern terminal tools, and development environment.

##  What's Included

### Window Management & Desktop
- **hypr/** - Hyprland window manager configuration with custom keybinds, animations, and workspace rules
- **waybar/** - Status bar configuration with system monitoring and custom modules

### Terminal & Shell
- **fish/** - Fish shell configuration with custom functions and aliases
- **kitty/** - Kitty terminal emulator with custom themes and keybinds  
- **ghostty/** - Ghostty terminal configuration
- **tmux/** - Terminal multiplexer with productivity-focused setup

### Development Tools
- **nvim/** - Neovim configuration with LSP, plugins, and custom keybinds
- **micro/** - Micro editor configuration for quick file editing
- **lazygit/** - Git TUI configuration for efficient version control

### System Utilities
- **btop/** - System monitor themes and configuration
- **fastfetch/** - System info display configuration
- **yazi/** - File manager configuration with custom themes
- **custom_scripts/** - Personal automation and utility scripts

### Desktop Environment & Theming
- **eww/** - ElKowars wacky widgets for custom desktop widgets
- **wal/** - Pywal configuration for automatic color scheme generation
- **volumeicon/** - Volume control and audio management
- **copyq/** - Clipboard manager with advanced features
- **Kvantum/** - Qt application theming engine
- **vicinae/** - Application launcher (Raycast-like) with the custom "Lumen" theme
- **libreoffice/** - "Lumen" application colors for LibreOffice. Not symlinked —
  the profile is rewritten by the app on exit, so run `libreoffice/apply.sh`

## Installation

### Prerequisites
- A working **Arch Linux** install (native or Arch-on-WSL) with `sudo` access.
- `git`, to clone this repo. Everything else is installed for you.

### Quick Setup
```bash
# Clone the repo to its canonical location
git clone <this-repo-url> ~/github/config/dotnix

# Run the bootstrap
cd ~/github/config/dotnix
./install.sh
```

`install.sh` is a one-shot, idempotent bootstrap. It always:
- **Symlinks** every config dir into `~/.config/<name>` and the shell dotfiles
  into `~`, all pointing back at this repo — **for everything**, even programs
  you haven't installed yet (so the config is ready the day you do). Any real
  files already in the way are moved to a timestamped `~/.config/dotnix-backup-*`
  folder first.
- **Sets `zsh`** as the login shell and **syncs Neovim plugins** headlessly.

Package installation is **tiered** — pick how much to install:

| Mode | Command | Installs |
|------|---------|----------|
| **minimal** *(default)* | `./install.sh` | CLI/TUI toolchain only — what zsh, tmux & nvim need |
| **selective** | `./install.sh --selective` | minimal **+** an interactive pick-list of desktop groups |
| **full** | `./install.sh --full` | minimal **+** every desktop group |

Desktop groups (offered in selective / all-in for full): `terminals`, `desktop`
(bar, notifications, screenshots, audio…), `hyprland`, `sway`, `theming`,
`media`, `pdf`, `launcher`.

It is **WSL-aware**: on Arch-on-WSL every mode collapses to the CLI set — the
native desktop/Wayland stack is skipped since the Windows side provides it.
Detection is automatic via the kernel name.

Other flags:
```bash
./install.sh --symlinks-only   # just (re)create symlinks, no packages
./install.sh --no-aur          # skip AUR packages / paru bootstrap
./install.sh --help
```

The symlink list is **auto-derived** from the repo's top-level directories
(everything except `shell/`, `grub_cpy/`), so new configs are picked up
automatically next run — no need to edit the script.

> **Secrets:** API keys live in `shell/zsh/secrets.zsh`, which is git-ignored.
> Copy `shell/zsh/secrets.zsh.example` to `secrets.zsh` and fill it in per machine.

## Key Features

### Hyprland Setup
- Custom animations and workspace management
- Optimized for productivity with smart window rules
- Multiple decoration profiles (gaming, productivity, etc.)
- Integrated with waybar for system monitoring

### Development Environment
- Neovim with LSP support and modern plugins
- Terminal-first workflow with tmux and fish shell
- Git integration with lazygit for visual git management
- Multiple terminal options (kitty, ghostty) for different use cases

### System Monitoring
- btop for system resource monitoring
- fastfetch for system info display
- Custom scripts for system automation

## Directory Structure

```
dotfiles_RitvikPC/
```
dotfiles_RitvikPC/
├── vicinae/           # Application launcher (Lumen theme + settings)
├── btop/              # System monitor configuration
├── copyq/             # Clipboard manager config
├── custom_scripts/    # Personal automation scripts
├── eww/               # ElKowars wacky widgets
├── fastfetch/         # System info display config
├── fish/              # Fish shell configuration
├── ghostty/           # Ghostty terminal config
├── hypr/              # Hyprland window manager
├── kitty/             # Kitty terminal emulator
├── Kvantum/           # Qt theming engine config
├── lazygit/           # Git TUI configuration
├── micro/             # Micro editor configuration
├── nvim/              # Neovim configuration
├── tmux/              # Terminal multiplexer config
├── volumeicon/        # Volume control config
├── wal/               # Pywal color scheme config
├── waybar/            # Waybar status bar
├── yazi/              # File manager configuration
├── install.sh         # Automated installation script
├── .gitignore         # Git ignore rules
└── README.md          # This file
```

## 🔧 Customization

Each application configuration is self-contained in its respective directory. Feel free to:

1. **Fork this repository** and customize it for your needs
2. **Modify individual configs** - each directory contains application-specific settings
3. **Add new tools** - follow the same structure for additional applications
4. **Remove unwanted configs** - simply delete directories you don't need

## Contributing

If you have suggestions for improvements or find bugs, feel free to:
- Open an issue
- Submit a pull request
- Share your own config modifications

## Notes

- These configurations are optimized for **Manjaro Linux** with **Hyprland** window manager
- Some configs may need adjustment for different distros or desktop environments
- The install script will backup existing configurations before creating symlinks
- Regular updates are made to keep up with application changes

## Useful Links

- [Hyprland Documentation](https://hyprland.org/)
- [Fish Shell Documentation](https://fishshell.com/docs/current/)
- [Neovim Documentation](https://neovim.io/doc/)
- [Kitty Terminal Documentation](https://sw.kovidgoyal.net/kitty/)

---

**Happy Configuring! 🎉**

*Last updated: September 2025*
