# Bibata Ice Attitude

A separate, white-and-black Bibata Modern Ice variant. The original
`Bibata-Modern-Ice-MiddleFinger` pack is preserved byte for byte, including the
shortened thumb. Its saved hashes are in `previous-pack.sha256.json`.

From the dotnix repository:

```sh
# Install and activate the new pack:
python3 theme/cursors/switch-theme.py attitude

# Go back to the exact previous pack:
python3 theme/cursors/switch-theme.py previous
```

Both commands update the desktop preference and Niri, Hyprland, GTK 3/4 and
xsettingsd configs. Niri reloads its config automatically. Applications caching
cursors may need restarting; a new login refreshes all session environment
variables. Your existing cursor size is preserved. No system theme is changed.

The pack includes a bitten arrow, your existing link hand, an open grab hand and
thumb-peeking fist, animated drumming fingers and foot-tapping busy arrow, a
pinching forbidden hand, toothed text caret, stretchy resize arrows in every
direction, a soft-centered move arrow, skeptical question mark and fly crosshair.
The loading animations use six frames each. Grab states change when the app
changes from `grab` to `grabbing`; the cursor cannot detect mouse clicks itself.
Other roles inherit the installed `Bibata-Modern-Ice` theme.

`preview.png` shows enlarged artwork with a 21-pixel sample beneath each.
`preview.html` previews both animations. Sources are in `base/` and `build.py`;
the generated vectors are in `svg/`. To rebuild, run:

```sh
python3 theme/cursors/attitude/build.py
```

Requires Python, Pillow and `rsvg-convert`. Fifteen sizes from 16–96 pixels are
included, with native size 21. `manifest.json` records hotspots, sizes and timing.

Derived from [Bibata Cursor v2.0.6](https://github.com/ful1e5/Bibata_Cursor/tree/v2.0.6)
by Ful1e5 and contributors, GPL-3.0; see `../LICENSE`. Original vectors are in
`base/`, with the previously customized link hand. Artwork changes made in
November 2026. Generated theme assets are distributed under the same license.
