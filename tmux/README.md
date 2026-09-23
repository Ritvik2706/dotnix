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

- `prefix+f` — sesh picker: existing sessions, pinned projects, and directory history (formerly `prefix+T`)
- `prefix+Ctrl+u/i/y/h` — sessionizer shortcuts (`~/.config`, `~/github`, `~/Downloads`, `~`)
- `prefix+s` — session tree sorted by last use (`d` kills the highlighted one)
- `prefix+Space` — alternate between the last two sessions
- `prefix+F` — tmux-thumbs text hints for copying (uppercase F)
- `prefix+|` / `prefix+-` — splits in the current directory
- `prefix+1..9` — select a window; `prefix+u/i` also select windows 1-2
- `prefix+o` — SessionX picker; `prefix+p` — Floax floating terminal
- `prefix+Q` — toggle typing in all panes; a yellow `SYNC` label shows when enabled
- `prefix+r` — reload the config with confirmation
- `prefix+v` then `v`/`y` — vim-style copy mode

## Terminal startup and prompt

Ghostty starts login Zsh, and Zsh attaches to `main` or creates it in the
terminal's starting directory. Existing tmux panes and VS Code terminals skip
this. Run `DOTNIX_NO_TMUX=1 zsh` for a plain shell, or
`DOTNIX_NO_TMUX=1 ghostty` to launch Ghostty without automatic attachment.
After detaching, the outer shell remains available.

The right prompt shows nonzero exit codes and elapsed seconds for commands
lasting at least three seconds.

Project sessions use the directory name plus a stable path digest, so projects
with the same name remain separate. Existing sessions keep their old names;
the updated sessionizer creates new names on first use. Symlinks to the same
project reuse its session.
