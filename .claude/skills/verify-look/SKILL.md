---
name: verify-look
description: Screenshot and check a visual change on the real desktop (island, niri borders/glass, terminal, any UI) on EVERY connected monitor, with before/after pixel diffs. Use after any change that affects how something looks, and for perf work that must stay pixel-identical.
---

# Verify a look

Visual changes are verified by looking, not by reasoning about the code. The
helper is `look.py` next to this file (run it with `python3 -I`).

## Steps

1. **Before the change** (when there's a before): wait for animations to
   settle, then
   `python3 -I .claude/skills/verify-look/look.py shot before --crop island`
   (crop: `island`, `bottom`, `full`, or `x,y,w,h` / `x,y,w,h%`).
2. Make the change and let it apply (lumen hot-reloads; niri config reloads;
   a niri *binary* change only shows in a nested niri, see `niri-patch`).
3. `look.py shot after --crop <same>`, then **Read every crop it prints**:
   one per monitor. The island lives on one monitor at a time, so check that
   the other monitor's strip is still right too.
4. If it should be unchanged (perf passes, refactors):
   `look.py diff before after --crop <region>`. Must say `identical` (max
   diff ≤ 1/255). Otherwise Read the heat map it names.
5. Report what you saw, per monitor, plainly. If something looks off, say
   so; don't call it matched without having looked.

## Gotchas

- Use full-output shots (the helper does): `grim -g` region captures omit
  lumen's surface.
- The clock, cursor, media art and the terminal you're typing in change
  between shots; crop them out of a diff or expect them in the heat map.
- Only one monitor connected (TV unplugged)? Say the other wasn't checked.
- Hover/open states: lumen's `--say` drives a running scene (e.g.
  `lumen --say "fact name value"`), or ask the user to hover and screenshot.
- Compare against the island as the reference for "does this match the glass
  look" (CLAUDE.md, The look).
