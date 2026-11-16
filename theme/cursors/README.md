# Bibata Modern Ice — Middle Finger

The link pointer raises its middle finger, keeping Bibata's white fill, black
outline, and hand silhouette. The hotspot follows the raised fingertip. All
other cursors inherit the installed `Bibata-Modern-Ice` theme.

Run `bash theme/cursors/install.sh` from the repository root to link the bundled
theme into your user icons directory and set the desktop preference. Niri,
Hyprland, GTK and xsettingsd configs select this theme. Restart applications
that cache cursors; logging out and back in refreshes the whole session.

The compiled Xcursor includes sizes 16–96, including the configured size 21.
To rebuild after editing `hand2.svg`, run `python3 theme/cursors/build.py`
(requires Python, Pillow and `rsvg-convert`).

Artwork modified from [Bibata Cursor v2.0.6](https://github.com/ful1e5/Bibata_Cursor/tree/v2.0.6),
`svg/original/hand2.svg`, by Ful1e5 and contributors, under GPL-3.0 (see LICENSE).
The raised finger and its neighboring knuckle were changed in November 2026.

To revert, set the cursor theme back to `Bibata-Modern-Ice` in the compositor,
GTK and xsettingsd configs and with
`gsettings set org.gnome.desktop.interface cursor-theme Bibata-Modern-Ice`.
