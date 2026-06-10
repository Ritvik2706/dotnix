# tmux config

Originally based on [linkarzu's dotfiles](https://github.com/linkarzu/dotfiles-latest)
([video](https://youtu.be/0aD7-EBnULc)), trimmed down and adapted for my
devices. Prefix is `Ctrl+a`. Status bar look (transparent, rounded pills) is
from [Yahddyyp's dotfiles](https://github.com/Yahddyyp/MacOS-Dotfiles), using
upstream `catppuccin/tmux` pinned at v2.1.3.

## Setup

```bash
./setup.sh
```

Checks dependencies (`tmux`, `git`, `fzf`), symlinks `~/.config/tmux` here,
and installs TPM. Plugins install automatically on first start (or `prefix+I`).
The `plugins/` directory is gitignored — TPM manages it at runtime.

## Layout

| Path | What |
| --- | --- |
| `tmux.conf` | The whole config: options, keybindings, plugins |
| `tools/tmux-sessionizer.sh` | ThePrimeagen's sessionizer — pick a dir, get a session |
| `tools/simple_toggle.sh` | Toggle/zoom the neovim terminal pane (`Alt+t` in copy mode) |
| `layouts/` | Saved custom pane layouts (`prefix+Alt+l` / `prefix+Alt+L`), see its readme |
| `plugins/` | TPM-managed, gitignored |

## Keybinding highlights

- `prefix+f` — fuzzy-find a project dir and open it as a session
- `prefix+Ctrl+u/i/y/h` — sessionizer shortcuts (`~/.config`, `~/github`, `~/Downloads`, `~`)
- `prefix+s` — session tree sorted by last use (`d` kills the highlighted one)
- `prefix+Space` — alternate between the last two sessions
- `prefix+|` / `prefix+-` — splits in the current directory
- `prefix+u/i/o` — windows 1-3 (`p` is taken by floax)
- `prefix+v` then `v`/`y` — vim-style copy mode
