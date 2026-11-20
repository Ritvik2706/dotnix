# dotnix

Ritvik's Arch Linux desktop config: a **niri** session on a Razer Blade laptop
(eDP-2, scale 1.6) plus a TV, with **lumen** (Ritvik's own shell runtime) drawing
the top "island". `install.sh` symlinks each folder into `~/.config/` (niri,
ghostty, tmux, nvim, lumen, …), so editing here edits the live config.
Hyprland (`hypr/`) was the previous session and is still maintained (hyprlock
+ face unlock are used on niri too); waybar, eww, sway and friends are older
setups.

Related repos, not in here: `~/github/projects/niri` (patched niri, branch
`dotnix-patches`) and `~/github/projects/lumen` (lumen engine). Projects live
in `~/github/projects`; configs stay in dotnix.

## The look: liquid glass, everywhere

The lumen island's compositor-drawn liquid glass (iOS 26 / MacShell style) is
THE design language for anything visual: bars, popups, pages, other apps.
Reproduce it, don't invent a new style.

- Source of truth: `lumen/shells/island/glass.plm` (`lgs_*` values,
  `material control|field|panel`), `lumen/shells/island/CONTROLS.md`, niri's
  `src/render_helpers/shaders/liquid_glass.frag`. Tune on the island's Control
  Center → Glass page, not by hand; other surfaces read the same numbers.
- Every island control (button, pill, chip, field, panel) uses
  `material: control|field|panel`. Never the old `glass: 25%; blur: 0%` +
  shadow. Not glass: content rows, bubbles, avatars, switches, slider fills.
- Dark, nearly clear glass, squircle corners (24px, exponent 4), capsules for
  resting items, white SF Pro text. No outer drop shadows.
- Blur: tiled windows keep the global `xray` wallpaper frost; only floating
  file choosers (and the lumen layer) get `xray false` real blur.

## Colours come from the wallpaper

Picking a wallpaper (Mod+P) runs `theme/wallpaper-theme.py apply`, which
re-themes the island, niri borders, ghostty/tmux/zsh/nvim, and Claude Code
(`~/.claude/themes/wallpaper.json`). Accents come from what is right *behind*
each element.

- Files headed `Written by theme/wallpaper-theme.py … Don't edit` are
  generated (`lumen/shells/island/theme.plm`, `niri/theme.kdl`,
  `ghostty/wall-*`, `~/.cache/lumen/term/*`). Change the engine, not them.
- After an engine change, check with `theme/preview.py OUT.png IMAGES…`;
  `idk.png` must still reproduce the `dusk` preset.
- **Zen browser: shape (rounding, spacing) and compositor glass only.** Never
  Zen accent colours, tints or invented colours. The live Zen profile lives in
  `zen/` and is fragile: a Zen update can fork a fresh profile (recovery from
  `~/.config/dotnix-backup-*`).
- Code colours (eldritch palette) keep their meaning; only hue moves.

## niri

- Patched niri: **commit on `dotnix-patches` → export with `git format-patch`
  into `niri/patches/` → install ONLY with `niri/scripts/niri-patched.sh
  build`** (checks, keeps `niri.prev`). Never copy a binary into
  `~/.local/bin` or edit `niri/patches/*.patch` by hand; a Claude hook blocks
  both. Changes take effect on the user's next niri restart.
- Test compositor changes in a nested niri (winit) before installing.
- niri-native, vim-style binds (Mod+hjkl focus, Ctrl move, Shift resize). No
  scratchpad/named-scratch workspace. `niri/mode.kdl` is included last and
  rewritten by `scripts/mode.sh`; keep it committed.
- Scripts that spawn long-lived children must be launched via niri to test:
  Claude's Bash tool kills `setsid` children.

## Lumen island

- Scene: `lumen/shells/island/island.{plm,luau}`, pages in `pages/`.
- Check logic after editing `island.luau`:
  `lumen --scene island.plm --screen NO-SUCH-SCREEN --seconds 3 --no-hud`
  (bogus screen = nothing drawn) and look for `syntax error`. `lumen --check`
  does NOT compile the Luau. A syntax error leaves the running island silently
  on its old logic. (The old 200-top-level-locals limit no longer applies.)
- List pages open in vim normal mode (j/k, gg/G, dd, `i`/`/` for search, Esc,
  q). Copy the clipboard page's rules (`clip_keys` etc.).
- Two monitors: the island lives on one at a time. **Always check both
  monitors' screenshots** after a visual change.

## Hyprland (if touching `hypr/`)

Lua config (0.55+): `hyprctl dispatch 'hl.dsp.…(…)'` form only; legacy
`hyprctl dispatch name args` and `hyprctl keyword` fail.

## How to work here

Project skills in `.claude/skills/`: `verify-look` (screenshots + diffs on
every monitor), `niri-patch` (the full patched-niri flow), `retheme-check`
(theme engine changes across all wallpapers), `island-page` (island
conventions), `lumen-engine` (changing lumen itself; release builds restart
the live island). Lumen's own `lumen` skill (from `lumen --install-skill`,
user-level) teaches the language. Use them for those jobs.

- **Verify visual changes with screenshots** (`grim`, crop, look), not just
  by reasoning. Before/after for anything that should look identical.
- **Performance work must be pixel-identical** (diff < 1/255) to the current
  glass look.
- **Testing is proportionate**: targeted tests + the normal suite for small
  changes; stress/slow runs only for big layout-logic changes, offered as
  optional.
- **Icon glyphs**: Nerd Font / icomoon glyphs are private-use characters. The
  Edit/Write tools can drop them or turn `\uXXXX` escapes into raw glyphs.
  Patch glyph lines with a small script using explicit codepoints; keep
  escapes in scripts. A hook flags both.
- **Laptop**: `nvidia-smi` wakes the dGPU; avoid it for casual checks.
- Commit only when asked. The user's commits are informal; group related
  changes.
