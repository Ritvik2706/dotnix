---
name: island-page
description: Ritvik's conventions for the lumen island (dotnix lumen/shells/island) — adding or changing a page/panel, its controls, keys, hotkey and logic, and testing it. Use together with the `lumen` skill (the language) for any island .plm/.luau work.
---

# Island pages, Ritvik's way

The `lumen` skill teaches the language (check every word with
`lumen --grammar`). This one is how *this* island is built. Read
`lumen/shells/island/CONTROLS.md` before drawing any control.

## Where things are

- `island.plm`: the scene. `fact panel: home | ctl | … | act` (line ~1334)
  names every page; pages are `include "pages/<name>.plm"` inside the card
  (around lines 3138–3430, 3873). `island.luau`: the logic, facts only, never
  drawing. `glass.plm`: materials; `theme.plm`: generated colours (don't edit).
- A page opens by an event: `on <x>_open …` rules set `expanded = true;
  panel = <x>` (and the side-panel variant when `big`, the TV). A second press
  closes it.
- Hotkeys live in `niri/conf/binds/apps.kdl`:
  `Mod+C { spawn-sh "~/.local/bin/lumen --say island 'emit clip_open'"; }`.

## A new page

1. Add its name to `fact panel`, its `include` next to its siblings, and its
   `on <x>_open` rules (copy clipboard's four: toggle, open, side open, side
   close). Facts it needs go with the others, commented like them.
2. **Controls are glass**: every button, pill, chip, segmented track, field
   and tile is `body { material: control|field|panel; … }`. Override only
   colour/opacity (`opacity: lgc_fill + N% * zone.hover`, lit state
   `+ 55% * state`, accent/destructive tinted 45–60%). Never
   `glass: 25%; blur: 0%`, `shadow:` or `light:` on a control. Content (rows,
   bubbles, avatars, switches, slider fills, anything over an image) is not
   glass.
3. **Lists open in vim normal mode.** Copy the clipboard's rules (search
   `clip_keys` / `clip_insert` / `clip_dd` / `clip_gg` in island.plm): j/k and
   arrows move, gg/G ends, Ctrl+d/u half page, l/Enter/y act, dd/x delete,
   q/Esc close; `i` or `/` turns the round search button into the field
   (insert); Esc back to normal keeps the filter, Esc again clears it, then
   closes. Ctrl+j/k move while typing. `blur` on open; never `focus <input>`
   in the open rule. The chosen row is a `sel: bool` field drawn with the
   lilac/sunset gradient (content, not glass); a list that re-sorts live
   tracks the selection by key, not index. Its gliding glass is `Glide`
   (pages/glide.plm).
4. Hotkey in `niri/conf/binds/apps.kdl` with a `hotkey-overlay-title`.
5. Colours come from `theme.plm` lets (wallpaper-driven); fixed semantic ones
   (teal, amber, coral, rose, …) stay in island.plm. Don't invent colours.

## Test it

- `lumen --check island.plm` (in the island folder) checks the scene. It does
  NOT compile the Luau: for that run
  `lumen --scene island.plm --screen NO-SUCH-SCREEN --seconds 3 --no-hud`
  and look for `syntax error`. (A hook does this after island.luau edits.)
- The live island hot-reloads on save. Drive it to the state you need, then
  screenshot with `verify-look`:
  `lumen --say island 'emit clip_open'`, `lumen --say island 'fact x false'`
  (`fact x false`, not `x = false`). Close it again afterwards.
- Check BOTH monitors when the TV is connected: the island is on one at a
  time, the other shows a strip. Notifications are laptop-only.
- Never `pkill lumen` (that's the live island). A test lumen is killed by its
  PID (`pgrep -x lumen` + check the cmdline).

## Gotchas from earlier work

- Zones: a press goes to the zone declared LAST; hover hit zones should use
  the TARGET geometry so enter/leave don't flicker.
- Dropping a layer surface needs `POPUPS.parent` cleared, or its last frame
  stays on screen.
- Don't use `screens: each` for the island (doubles every zone, splits
  nothing).
