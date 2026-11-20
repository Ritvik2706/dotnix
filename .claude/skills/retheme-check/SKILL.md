---
name: retheme-check
description: Check a change to the wallpaper theming engine (theme/wallpaper-theme.py) across all wallpapers, before vs after, then apply it live. Use whenever the engine, presets or what it writes (island, niri borders, terminal, Claude theme) changes.
---

# Check a theme-engine change

`theme/wallpaper-theme.py` turns the wallpaper into colours for the island,
niri borders, ghostty/tmux/zsh/nvim and Claude Code. A change that looks
right on one wallpaper can break another (busy, bright, grey or very warm
ones), so compare the whole set.

## Steps

1. **Before** (from the committed engine):
   ```sh
   S=<scratchpad>/retheme; mkdir -p $S/before
   cp theme/preview.py $S/before/
   git show HEAD:theme/wallpaper-theme.py > $S/before/wallpaper-theme.py
   cp -r theme/presets $S/before/ 2>/dev/null
   python3 -I $S/before/preview.py $S/before.png wallpapers/*
   ```
   (If the working tree already has engine edits you want as the baseline,
   copy the working files instead of `git show`.) About 1.5 s per wallpaper
   (~45 s for all 30); iterate on a varied handful (idk.png, bluewhite.jpg, a
   bright busy one, a grey one, a warm one) and run all of them at the end.
2. Make the engine change.
3. **After**: `python3 -I theme/preview.py $S/after.png wallpapers/*`.
4. Read both images, row by row. Look at: island pill legibility on its
   strip, border visibility against bright and busy walls, focused vs
   unfocused borders, accents that drift away from what's behind them,
   errors/diffs staying red/green. Grey walls should stay near-neutral.
   Name the wallpapers that got worse, if any.
5. **Ground truth**: `idk.png` should still give the dusk look the user tuned
   (theme/presets/dusk.json); call out if it moved.
6. **Apply live**: `python3 -I theme/wallpaper-theme.py apply` (current
   wallpaper). It prints what changed (`lumen`, `niri`, `tmux`, `ghostty`,
   `claude`, …). Then use `verify-look` on the island and borders.
7. Report: what changed, which walls improved/regressed, and that Claude
   Code's own colours update for new Claude sessions only.

## Rules

- Never hand-edit the generated files (`theme.plm`, `niri/theme.kdl`,
  `ghostty/wall-*`, `~/.cache/lumen/term/*`, `~/.claude/themes/wallpaper.json`).
- Colours come from what's right behind each element; don't reintroduce
  wallpaper-wide accent picking.
- Zen is never themed by colour.
- The theme cache key includes the script's mtime, so edited engines
  recompute; `warm` precomputes every wallpaper (the island runs it).
