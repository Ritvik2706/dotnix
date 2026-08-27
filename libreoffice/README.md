# LUMEN · LibreOffice

The Lumen dusk-glass language carried into LibreOffice.

## What theming LibreOffice actually means

LibreOffice's chrome — menus, toolbars, dialogs, scrollbars, the sidebar frame
— is drawn by GTK through the `gtk3` VCL plugin, so it already inherits
`~/.config/gtk-3.0/gtk.css` and needs nothing from us.

What GTK **cannot** reach is everything LibreOffice paints onto its own canvas:
the page, the desk behind it, text boundaries, field shadings, non-printing
marks, proofing squiggles, comment/track-changes author colours, the Calc grid,
the Basic IDE. Those come from LibreOffice's own *Application Colors* scheme,
which is what `lumen.conf` defines.

So the split is: **GTK owns the chrome, this owns the canvas.** The chrome
groups LibreOffice's schema also exposes (`WindowColor`, `MenuColor`,
`ButtonColor`, `AccentColor`, …) are deliberately left unset — setting them
would make LibreOffice paint its own widgets and override the Lumen glass.

## Why this is a script and not a symlink

Everything else in this repo is symlinked into `~/.config` by `install.sh`.
LibreOffice is the exception. Its entire configuration lives in one generated
file, `~/.config/libreoffice/4/user/registrymodifications.xcu`, which the app
**rewrites wholesale every time it exits** — mixed in with recently-used file
lists, window geometry, and per-document state. Symlinking that into git would
mean a dirty tree after every launch, and a `git checkout` could hand
LibreOffice a file it is midway through rewriting.

Same reasoning as the Zen profile: the live profile stays out of the repo, and
the repo holds the *intent* plus a script that merges it in.

## Usage

```bash
./apply.sh              # apply — dark chrome, light page
./apply.sh --dark-page  # ... with the page dark too (see the tradeoff below)
./apply.sh --revert     # remove, back to LibreOffice defaults
```

**LibreOffice must be fully closed** — it rewrites the registry on exit, so a
change made while it is running is silently discarded. `apply.sh` checks for
this and refuses rather than losing your edit. Each run writes a timestamped
`registrymodifications.xcu.bak-*` next to the original.

The script is idempotent: it strips the entries a previous run wrote before
adding the current ones, so editing `lumen.conf` and re-running is the normal
workflow.

## Files

- `lumen.conf` — the palette, as `Key = #rrggbb [visible|hidden]`. The keys are
  LibreOffice's own Application Colors node names, verified against the schema
  in `/usr/lib/libreoffice/share/registry/main.xcd`.
- `lumen-light.conf` — a delta layered on top of `lumen.conf` by default,
  restating only what LibreOffice paints onto the page. `--dark-page` skips it.
- `apply.sh` — merges them into the live profile.

## Beyond colours

`apply.sh` also sets four things that colour alone can't carry:

| Setting | Value | Why |
| --- | --- | --- |
| `IsAutomaticFontColor` | `false`, or `true` under `--dark-page` | Forces every glyph to black or white by the window background. The dark page cannot be read without it; the light page must not have it. See below. |
| `SymbolStyle` | `sifr_dark` | Thin monochrome outline icons, the closest stock set to the feather glyphs in the waybar. |
| `Active{Writer,Calc,Impress,Draw}` | `Single` | One compact toolbar plus the sidebar, so the chrome reads as a single glass slab instead of two stacked bars. |
| GTK `font-name` | `SF Pro Text 10` | LibreOffice takes its UI font from GTK. `gtk-3.0/settings.ini` already asks for this, but gsettings can override it via the portal — this aligns the two. |

## The dark-page tradeoff

`IsAutomaticFontColor` is the whole story here. The switch repaints every glyph
black or white according to the **window** background — it is blind to the fill
behind the individual run, and it overrides explicit colours, not just
*Automatic* ones.

A dark page cannot do without it: ordinary documents leave their body text at
*Automatic*, which resolves to black and disappears on `#0f1119`. But with it
on, any document carrying its own light shading — table header rows, banded
tables, callout boxes, most things exported from Word — gets white text painted
onto a near-white cell and turns into unreadable white blocks.

There is no third setting. Legible documents that carry their own colours need
a light page, so that is the default: paper at `#f6f8fc` floating on the dark
`#0c0d14` desk, with the chrome, menus and sidebar still full Lumen glass. The
page then matches what prints and what exports to PDF.

`--dark-page` restores the dark sheet for prose you author yourself, where
nothing is shaded and WYSIWYG does not matter.
