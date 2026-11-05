# lumen island — things to fix

Collected 2026-10-28 from screenshots of the open card on light glass (over
a bright aquatic wallpaper) and on dark glass. Liquid glass background:
`LIQUID_GLASS_HANDOFF.md` (repo root).

## In progress
- [x] **Inner controls as real glass** (lumen-glass v4, `layer: 1`): Wi-Fi /
  Bluetooth pills, page headers' back button, notifications button, weather
  and inbox panels with the inbox's top button, media transport, the round
  action buttons. MacShell's Control Center values (`lgc_*` in glass.plm,
  derived from the Glass page sliders); niri draws layer 1 flat (no inner
  shading, no shadow, no second blur). Needs niri restarted once to show.
- [x] Every control is glass through shared materials (`material control /
  field / panel` in glass.plm, rules in shells/island/CONTROLS.md): ~70
  bodies across the island and its pages. Kept lumen-drawn on purpose:
  content (rows, bubbles, avatars, emoji), switches, segment thumbs, slider
  fills, the recording pill, the camera's buttons (over the viewfinder).
- [ ] Check every page once on the real desktop (accent / rose tinted glass
  at 45–60%, state-lit tiles at +55–75%): tune if any reads too faint.
- [x] Controls are light or dark as the glass they sit on (niri: layer 1
  inherits layer 0's state, no reading of its own).
- [ ] Glass page: sliders for the controls (`lgc_*` are derived for now).

## Light glass (the text and chips don't follow it yet)
- [ ] Inner panels stay dark grey on light glass, and the text inside them
  turns dark with the card → dark text on dark panels (mail senders,
  weather temperatures). Panels must follow light/dark too (solved by the
  item above: their own glass decides for itself, `adapt:`).
- [ ] Coloured text has no light-mode variant and loses contrast on light
  glass: weather H/L and the hourly times (teal), "INBOX", mail ages
  ("now", "1h", "3h"), the unread dot. Accent colours (`teal`, `lilac`,
  `tint_ink`, `soft_l`, …) need darker variants on light glass.
- [ ] Secondary text (mail previews, "Mostly Clear", ring labels CPU /
  MEMORY / SOUND) is too faint on light glass: dim opacities were tuned for
  white on dark.
- [ ] The "11045 unread" pearl chip and the Wi-Fi / Bluetooth icon discs
  (pearl) disappear into light glass.
- [ ] Ring gauges (CPU / memory / sound): arcs and track contrast on light.
- [ ] The header's page dots capsule (dark) on light glass.
- [ ] Text shadows: removed on light glass for the main text; check icons.
- [ ] Go through every page in light mode: controls, sound mixer, Glass page,
  Wi-Fi / Bluetooth lists, launcher, clipboard, emoji, wallpapers, notes,
  mail, WhatsApp, timer, camera, capture, notices, OSD, calendar.
- [ ] The left rail and right capsule decide separately (`gl_l`, `gl_r`);
  their hover cards (windows card, calendar) should follow their own glass.

## Readability
- [ ] Clear glass over busy light scenery: content competes with what is
  behind (reading-view frost was removed on request). Options: adaptive
  diffusion done properly (a blurred detail map in niri's capture, see the
  handoff), or a slightly stronger tint on light glass only.

## Glass engine (niri / lumen)
- [ ] Busy-content adaptive diffusion: needs a blurred |sharp − blurred|
  detail map pass in framebuffer_effect.rs (the 5-tap version painted
  copies of edges and was removed).
- [ ] MacShell's 24-tap residual blur was not ported (perf); revisit if the
  edge looks grainy over sharp content.
- [x] More than 8 glass shapes per surface: 24 from v4 (16 per layer).
  lumen sends layer 1 and more than 8 only to a v4 niri (an older one killed
  the island over it).

## Housekeeping
- [ ] Commit: lumen (glass protocol client, `adapt`, scene props — the repo
  also has unrelated uncommitted work, review first) and dotnix (island,
  glass.plm, Glass page, theme generator, niri scripts, lock fixes, terminal
  theme…). niri's patches are committed on `dotnix-patches`.
- [ ] Run `system/niri-patched-setup.sh` once (sudo) for the pacman hook and
  the safe niri launcher.
