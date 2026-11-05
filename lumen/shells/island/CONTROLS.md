# Controls in the island are glass

Every control on the island is compositor liquid glass, made of the shared
materials in `glass.plm`. A control is anything you press or type in:
buttons, round buttons, pills, chips, segmented-control tracks and text fields.

```plm
body { material: control; ellipse { at: 16, 18; radius: 16 - 0.6 * z.pressed } }
body { material: control; opacity: lgc_fill + 7% * z.hover; box { from: 0, 0; size: 120, 34; corner: 17 continuous } }
body { material: field; box { … } }   // where text is typed
body { material: panel; box { … } }   // a tile or sheet on the card
```

- **Never** write `glass: 25%; blur: 0%`, `shadow:` or `light:` on a control.
  The material carries all of it. Only state the props that differ.
- **Hover and state**: `opacity: lgc_fill + N% * zone.hover`. For a control lit
  by state (on, selected, muted): `opacity: lgc_fill + 55% * state` with a
  `soft_l`/`soft_s` gradient.
- **Accent and destructive buttons** are tinted glass: the accent gradient, or
  `mix(rose, …)`, with `opacity: 45%`–`60%`.
- **Not glass**: content (messages, list rows, avatars, emoji cells), coloured
  live parts (switches, the selected segment's thumb, slider fills, the
  recording pill), and anything over a picture lumen draws itself (the camera
  viewfinder). Glass sits behind the surface's own drawing, so it would not
  show there.
- **The lens look**: `control` and `field` are `layer: 2`. niri bends the crisp
  backdrop behind the card for them, not the card's frost: a round button is
  clear all over, a pill or field is frosted toward its middle where its words
  are. `panel` stays `layer: 1` (frosted): tiles hold too much text for it.
  Needs niri patch 0028+ and lumen with layer 2; older ones draw it as layer 1.
- **Tuning**: the materials follow the Glass page's sliders (`lgc_*` in
  glass.plm come from `lg_*`). Change `material control` once and every
  control follows.
