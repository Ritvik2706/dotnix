# Liquid Glass handoff — iOS 26 glass for the lumen island on niri

Written 2026-10-27 at the end of a Claude Code session, for whoever continues
(Codex). Read this whole file before changing anything.

## Readability control and rim correction (follow-up)

Implemented in niri patch 0007, commit `d75aeecd`; release build and GLSL
variants pass. Nested visual tests cover readability 0/60/100% over large text,
plus a bright/dark boundary at the top edge. Scene validation and numeric
sample-order checks pass. Test artifacts: `/tmp/liquid-readability/`.
The installed binary was built before committing (version ends `-modified`).


`glass.plm` now exposes `lg_readability` (0–100%, default 60%). It jointly
controls frost, expanded-card tint/smoke, and compositor luminance compression.
Resting capsules request less frost; expanded cards interpolate toward more.
Frost is still per surface, so the most frosted visible shape controls all its
shapes. No new client-side capture or protocol extension is involved.

Design reference: Apple's Regular Liquid Glass material (blur plus luminosity
adjustment for text-heavy controls), and iOS 27's more uniform refraction,
improved contrast, and clear-to-tinted control. This follows documented design
behaviour, not Apple's unpublished shader or an exact numerical mapping.
https://developer.apple.com/design/human-interface-guidelines/materials
https://www.apple.com/os/ios/

The rim uses a smoothstep profile with displacement capped at 20% of bevel
width, added to a restrained body lens. The old circular profile's unbounded
rim slope could reverse sample ordering and produce the folded upper band.
Highlights are narrower/quieter. Bright background areas are dimmed more than
dark areas as frost rises; this targets lumen's light foreground text.
Low frost now reduces blur pass count as well as offset. The implementation
still uses one blurred backdrop texture, not separate sharp/frosted textures.

## Follow-up correction (Codex, 2026-10-27)

The original handoff below predates this correction. The low-tint tuning exposed
an additional bug: lumen's `gpu.rs` requested glass only when glass amount ×
paint opacity exceeded 30%, even with the compositor protocol. Both Body and
Solid paths now use the ordinary 0.001 visibility threshold for protocol glass,
retaining 0.3 for legacy blur. Otherwise a clear tint silently disabled lensing.

The niri shader now adds smooth body magnification to the original rim mapping;
the previous mapping was exactly zero past the bevel. Dispersion remains confined
to the edge. This is an approximation, not Apple's complete adaptive material.
The exact optical centre remains stationary while its surroundings magnify.

Reference inspected: Apple's WWDC25 “Meet Liquid Glass”, including the expanded
menu over colourful content: https://developer.apple.com/videos/play/wwdc2025/219/
Temporary reference frames and nested grid tests: `/tmp/liquid-glass-review/`.

Validation: both release builds pass; lumen library tests: 95 passed, one
ignored; deployed scene compiles. Nested niri shows interior grid magnification
at 8% client tint, with both glass shapes confirmed in protocol logs. Niri patch
0006 is committed as `6f88a13c` and the tested binary is installed (previous
binary retained as `~/.local/bin/niri.prev`). Niri and lumen were restarted
successfully to activate it.
The binary was built before the commit, so its version includes the preceding
commit plus `-modified`; its shader matches patch 0006.

The current `glass.plm` uses zero frost to retain detail, with lighter overlays.
Nonzero frost still downsamples at the full configured pass count even when its
offset is small; a separate sharp/frosted blend remains future work. Do not try
to substitute more blur or opaque tint for missing optical displacement.

> **Update 2026-10-28 (Claude, after Codex's pass):** the shader optics were
> rewritten to the physically traced model used by the closest recreations
> (kube.io "Liquid Glass in CSS and SVG"): convex squircle bevel
> y = (1-(1-x)^4)^1/4, Snell's law at IOR 1.5, displacement h·tan(θ1−θ2)
> inward — 0 at the very edge, peaking within ~1 px, 0 where the glass is
> flat; the near-rim compression/mirroring is intended (it is the Apple rim).
> **`refraction` now means glass thickness (px)**, `bevel` the curved edge
> width (px, ≤ half the shape's height). Codex's body magnification and the
> `bevel × 0.2` cap are gone. The rim samples the **unblurred** backdrop
> (`tex_sharp`, texture unit 1, bound in framebuffer_effect.rs) easing into
> the frosted middle, so lensing stays crisp over frost. Dispersion = per-
> channel IOR spread (0.05 × dispersion). Light = broad top-left glint +
> opposite inner reflection on the curved band + hairline; 1.18× vibrancy.
> Codex's readability darkening (frost × luminance) is kept. Commit 4a892dc1
> on dotnix-patches (patches 0001–0008). glass.plm retuned: capsules
> 20/15, cards 36/26, dispersion 15%, specular 70%, card veil ~40%.

> **Update 2026-10-28 #2 — iOS 27 readability (commit e7d03a05):** the glass
> now adapts to what is behind it: "busy" = |crisp − frosted| luminance over
> 5 taps (centre ± 24 px); busy areas blend toward a wider frost built from
> those frosted taps (never a sharp/blurred half-mix — the user dislikes that
> ghosting), the rim keeps 70% of its clarity, and a busy backdrop gets an
> 18% deeper tint plus the frost×luminance darkening. The backdrop is always
> captured with window blur + 1 pass at full offset (frost no longer scales the blur; `MAX_PASSES` in liquid_glass.rs); busy areas show that capture directly — averaging spread taps over a light blur stacked copies of text (fixed in the next commit). Per-shape frost
> picks crisp (<8%) or frosted (>25%) — avoid values in between (that would
> half-mix and ghost). Separation: a 3.5 px darkened ring outside each shape
> (bbox padded 4 px, `EDGE_PAD`) and brighter glints. Not done: a lumen
> "content vs controls" role — glass controls *inside* a glass card can't be
> lensed separately yet (the renderer draws one union per surface from the
> backdrop; nesting needs a second pass).

> **Update 2026-10-28 #3 (commit d5d14d3b) — supersedes parts of #1/#2:**
> the strict Snell fold is GONE (it mirrored sharp edges into jagged
> polygons on small glass); lensing is a fold-free squeeze
> `D = min(thickness*(ior-1), 0.45*bevel) * (1-x)^2`, light still from the
> squircle slope. The busy-content measure is REMOVED (`busy = 0.0`): 5 taps
> of |crisp−frosted| painted shifted copies of every edge (and slid during
> the pill's expand animation). Doing adaptive diffusion right needs a
> blurred detail map: in framebuffer_effect.rs capture, render
> |sharp−blurred| into a texture, run Blur on it, bind as a third sampler.
> Capture is padded 28 px (`EDGE_PAD`); darkened outer edge 0.09 over 2.5 px.
> Debug approach that found it: replace the final colour with one term
> (`texture2D(tex_sharp, …)`, `vec3(busy)`, normals) and screenshot nested;
> validate the shader first with `glslangValidator -S frag` (niri only logs
> "error compiling liquid_glass shader").

> **Update 2026-10-28 #4:** user felt it wasn't iOS-like: a crisp lensed rim
> around a heavily frosted middle reads as a seam. Now ONE material — the rim
> bends the same backdrop the middle shows (`float c = clear;`, the sharp
> texture is only used for clear glass, frost < ~8%); frost = window blur
> passes, offset × (0.5 + 0.5·frost). glass.plm: capsules 14/10, cards 24/16.
> Apple's edge should be a subtle optical shift, not a different texture.
> **#5:** frost is a real blur dial: passes × (0.5 + 0.5·frost), offset ×
> (0.25 + 0.75·frost); sharp capture only at frost < 2%; lg_frost_strength 35%.

> **Update 2026-10-28 #6 — matched to the user's iOS reference screenshots
> (commit 382d5a8b):** references (dock over streaky wallpaper, Control Center
> flashlight panel over icons, media player over white rings) show: the
> middle CLEAR (no frost, content sharp and recognisable, slight dark tint),
> a strong edge band ≈ 1/5 of the shape's height where content bends/stretches
> toward the rim, visible rainbow fringes, a thin rim light. Shader:
> D = min(thickness·0.5, 0.85·bevel)·(1−x)^1.1 (LENS_CAP/LENS_POWER, fold-free),
> dispersion ±0.6·D per channel. glass.plm: frost 5%, cards 50/22, capsules
> 24/12, dispersion 40%, card veil card_alpha 10%+10%·read. Next tuning
> should be done side by side with such references, not from descriptions.

> **Update 2026-10-28 #8 (commit d51a217f) — supersedes the lensing notes above:**
> from an iOS reference (rings crossing a glass edge bend toward the INSIDE of
> the shape), the rim samples OUTWARD: it shows what lies just outside the
> glass, pulled in and squeezed (`vec2 dir = inv * (n / geo_size)`). Outward
> sampling only compresses, so it never folds; shift =
> min(thickness·0.5, LENS_CAP·bevel)·(1−x)^LENS_POWER with LENS_CAP 1.0,
> LENS_POWER 2.0 (LENS_TRACED 0 keeps the Snell variant available). The
> capture pad (28 px) provides the outside backdrop.
> Reading views: island.plm `on_read` (prop ~300ms, 1 while panel is wa,
> mailx, notes, clip or launch) blends the main card's frost/tint toward
> glass.plm `lg_read_frost` (50%) / `lg_read_alpha` (34%).

> **Update 2026-10-28 #9 — Glass page + protocol v2 (commit ae0f2787):**
> Control Center → Glass (`pages/glasstune.plm`, panel `gtune`, 19 sliders):
> each slider emits `gl_set(idx*10000 + pos)`; island.luau `GLASS_TUNE`
> (index → key, min, max) sets fact `lgo_<key>` (live override, -1 none);
> glass.plm's live `lg_*` = override else saved `lgs_*`. Save runs
> `scripts/glass-save.py key=value…` (rewrites only `let lgs_key` lines,
> atomic). Reset clears overrides. lumen-glass **v2**: 16 floats/shape
> (+ magnify, falloff, rim width); lumen sends 16 only when bound at v2
> (sending 16 to a v1 niri is a protocol error and kills the client — that
> crashed the island once). Rim light now tints with the backdrop colour.
> New glass props in lumen: `magnify`, `falloff`, `rim_width`; island
> defaults magnify 15% (fades out as the pill morphs into the card),
> falloff 1.4, rim width 3, capsule bevel 14; `lgs_milk` drives milk.

> **Update 2026-10-28 #10 — MacShell port (commit 130f2ecb), user's chosen
> target:** the user wants the exact look of https://github.com/0-ss/MacShell
> (MIT). niri's liquid_glass.frag main() is now a port of its
> `MacShell/liquidglass.frag` (attribution in the header): squircle slope
> (1-u)^3/(1-(1-u)^4)^0.75 capped 7 over 1.45×bezel, refract(n 1.5) sampled
> INWARD, thickness×1.35, dispersion ×0.6 per channel, vertical lens
> (1 − magnify×1.5), saturation 1.25, tintMix toward (0.09,0.09,0.10), +0.02
> milky lift, top sheen, lower inner edge, absorption, spec rim (L (−.55,−.83),
> hair exp(−t/1.1), wide exp(−t/5)), meniscus, grain, drop shadow. Not ported:
> their 24-tap mip disk blur (blurPx 1.5 residual) — our frosted capture is
> the pre-blur (their default glassBlur 5 px ≈ frost ~0.3). v2 slots 14/15 are
> now tint (default 0.23) and rim tint (0 white). lumen props renamed
> `glass_tint` / `rim_tint`. glass.plm uses MacShell's values: card 48/26
> (popovers), capsules 30/10 (Dock), dispersion 8%, specular(rim) 45%,
> magnify 8%, glass tint 23%, lumen veil 6%, prism/card rim 0, frost 34%.
> CAUTION: lumen re-execs itself when its binary changes; a startup compile
> error (e.g. renamed props before island.plm is updated) or a protocol
> mismatch kills the island — update scene files BEFORE rebuilding lumen,
> or set LUMEN_NO_RELAUNCH=1. Relaunch: `niri msg action spawn-sh --
> "~/.local/bin/lumen --scene ~/.config/lumen/shells/island/island.plm --no-hud --stall 0"`.

> **Update 2026-10-28 #11 — adaptive text, lumen-glass v3 (commit 83bdbd21):**
> niri reads back the frosted capture behind each shape (framebuffer_effect.rs
> `measure_glass`: 5 px per shape, ≤ every 200 ms, via glReadPixels through
> the output transform), decides light/dark per shape in liquid_glass.rs
> (`ShapeLight`: on > 0.56, off < 0.40, must hold 2 readings, 300 ms eased
> crossfade), packs it into the shape (s[2].x = corner + 2·(rim% + 128·light%))
> and sends `appearance(shape, light)` to v3 clients. lumen: glass prop
> `adapt: <fact>` → that fact gets 1/0 (platform/wayland.rs `GlassFor` →
> ToRender::ExternalFact). Island: facts gl_c (centre), gl_l (rail), gl_r
> (battery/date), smoothed gl_*s ~300ms; `ink = mix(ink_base, #161618, gl_cs)`,
> rail/right capsule texts use ink_l/ink_r; text shadows × (1 − gl_*s). The
> theme generator now emits `ink_base` (not `ink`).

## The goal

The user wants **Apple's iOS 26 "Liquid Glass" look** on their own desktop
shell (the *lumen island*, a dynamic-island bar) running on **niri**. The
target is visual parity with iOS 26 Liquid Glass:

- **edge refraction** (lensing): what is behind bends toward the curved rim,
  strongest at the very edge, flat (undistorted) in the middle — the hallmark;
- subtle **chromatic dispersion** at the rim (faint colour fringing, never rainbow);
- **little frost** on standard controls (clear-ish glass; the backdrop stays
  recognisable), more only where legibility needs it;
- a thin **specular rim light** that reads as a lit glass edge;
- nearby glass shapes **melting together** (smooth union) as they approach;
- legible content on top.

Hard constraint from the user: the glass must be drawn **by the compositor**
(niri), from the frame it is composing. NOT lumen's old approach of capturing
the screen itself ("took screenshots of the background and killed
performance"). Don't reintroduce any client-side capture.

The user tunes by eye. They currently **see no refraction at all** — see
"Why no refraction is visible yet" below; that is the first thing to fix.

## Status

| Piece | State |
|---|---|
| niri protocol + renderer + shader | done, committed (patch 0005), **installed and running** |
| lumen client (protocol, scene props, shape export) | done, builds, tests pass, **uncommitted**, running (`~/.local/bin/lumen` → `target/release/lumen`) |
| island opts in (all 5 glass bodies) | done, values in `glass.plm` |
| tuning to look like iOS 26 | **not done — this is your job** |
| lumen's own tint/rim drawn on top | still at the pre-glass look; likely needs toning down |

Verified: lumen sends 3 shapes for the resting island (centre pill, left
workspace capsule, right battery/date capsule) with frost 0.60 to the live
niri; a nested-niri test scene showed frost, rim lensing with fringes, and
two circles merging with a glass neck.

## Why no refraction is visible yet (start here)

1. **Frost too high.** `lg_frost = 60%` blurs the backdrop, so there is no
   detail left for refraction to visibly bend. iOS 26 standard glass is
   much clearer. Try `lg_frost` 0–25%.
2. **Flat backdrop.** The resting pill sits on the top strip of the wallpaper
   (often flat sky). Refraction over a flat colour changes nothing. Judge on
   the *open card* (hover the island / Super+D launcher / Super+C clipboard),
   which drops over windows and text, or over a detailed wallpaper.
3. **lumen paints over niri's glass.** Each glass body in `island.plm` also
   draws its own tint at `opacity: glass_alpha …` (38–58%, set per wallpaper by
   `theme/wallpaper-theme.py`), plus `milk`, `smoke`, `light`, and a separate
   "prism" rim body (cool→warm gradient stroke, `opacity: (55% + …)`). This
   veil washes out both the refraction and niri's specular rim. For iOS 26,
   the tint must be much lighter and the prism rim probably off or faint.
4. Refraction/bevel values are modest (14 px / 16 px) on a 34 px tall pill.
   Bevel can't usefully exceed ~half the shape's height (17 px for the pill).

## Where the values are

### 1. The tuning file (live reload, start here)

`dotnix/lumen/shells/island/glass.plm` (≡ `~/.config/lumen/shells/island/glass.plm`):

```
part Glass {
    let lg_frost      = 60%   // 0% clear … 100% compositor's full blur
    let lg_refraction = 14    // px: how far the backdrop shifts at the very rim
    let lg_bevel      = 16    // px: width of the curved edge (middle is flat)
    let lg_dispersion = 10%   // colour split at the rim
    let lg_specular   = 50%   // rim light
}
```

Save → the running island reloads within ~1 s (lumen watches every file the
last compile read). Used by 5 bodies in `island.plm` (search `lg_frost`):
the main pill/card body (~line 1244), the timer bubble (~1365), two bodies
around ~2654 and ~2682, the calendar/battery capsule (~2834).

Also available per body but not wired to glass.plm: **`merge:`** (px; shapes
closer than this melt together; currently 0).

### 2. lumen's own tint on top (likely needs changes for iOS look)

In `dotnix/lumen/shells/island/island.plm`:
- `let card_alpha = 82%`, `let glass_milk = 10%`, `let card_smoke = 28%` (~line 48)
- main body (~1240–1252): `gradient:` (pearl/lilac/sunset tint), `opacity:
  glass_alpha + (card_alpha - glass_alpha) * dark`, `milk:`, `smoke:`, `light:`
- the "prism" rim body right after it (~1255): coloured 1 px stroke ring.
- `glass_alpha` lives in `theme.plm` (generated — **don't edit theme.plm**;
  change `glass_alpha` logic in `dotnix/theme/wallpaper-theme.py` (`generate()`,
  `out["glass_alpha"] = …`) or override it in island.plm/glass.plm).
- `dark`, `km`, `bloom` = how open/dark the card is (animated).

Caution: the island's dark "smoked" card is for legibility over busy windows.
iOS 26 keeps text legible with *adaptive* tint, not a heavy veil; changing
these trades legibility, so check text on the open card over busy content.

### 3. The shader (if numbers alone can't reach iOS 26)

`~/github/projects/niri/src/render_helpers/shaders/liquid_glass.frag`:
- `shape_sdf()` — exact squircle signed distance (same math as
  `rounding_alpha.frag` / lumen's `continuous_corner`).
- `glass_sdf()` — smooth union (polynomial smin, k = `glass_merge`).
- bevel profile: `t = 1 - depth/bevel`, `bend = 1 - sqrt(1 - t²)` (circular);
  displacement `off = -n * refraction * bend` (samples **inward** — a convex
  edge magnifies). Real iOS glass may want a different profile / stronger
  near-edge magnification; this is the main knob for "looks like Apple".
- dispersion: R/B sampled at `dv*(1±dispersion)`.
- specular: key light from top-left `(-0.5547,-0.8321)`, thin rim
  (`smoothstep(0,1.6,depth)`), fainter back light, sheen over the bevel.
- frost: there is ONE backdrop texture, blurred with niri's dual-kawase blur
  whose offset is scaled by `frost` (`render_helpers/liquid_glass.rs`). There
  is no sharp+blurred mix; frost 0 = sharp texture.

Not implemented yet (candidates for iOS parity): adaptive tint/contrast from
backdrop luminance (shader could compute it), refraction of *sharp* content
under a frosted interior (needs two textures), light that moves with pointer.

## Architecture

```
lumen (client)                          niri (patched compositor)
island.plm  glass: 100%; blur: lg_frost;      resources/lumen-glass-v1.xml
            refraction/bevel/dispersion/       src/protocols/lumen_glass.rs
            specular/merge                     (global, per-surface Cacheable
  │                                             state, applied on commit)
gpu.rs  request_glass(): a rounded box          src/layer/mapped.rs → render()
  that is un-rotated, scale-only, unclipped     calls liquid_glass::render_for_surface
  → glass_box() → Draw.glass_shapes             (before the normal blur-region effect)
  anything else → blur strips as before         src/render_helpers/liquid_glass.rs
render.rs  per surface: shapes in surface       one FramebufferEffect capture over the
  coords → update_glass() when changed          shapes' bbox (+1 px), shapes packed as
platform/wayland.rs  lumen_glass_manager_v1     mat4 per shape → shaders/liquid_glass.frag
  get_glass / set_shapes / set_params           (framebuffer_effect.rs: GlassDraw,
                                                 compute_glass_uniforms)
```

### Protocol lumen-glass-v1 (private)

- `lumen_glass_manager_v1.get_glass(new_id, wl_surface)` — one per surface.
- `lumen_glass_surface_v1.set_shapes(array)` — native-endian f32, **13 per
  shape**, max 8: `x, y, w, h, r_tl, r_tr, r_br, r_bl, corner (1 =
  continuous/squircle, 0 = circular), refraction px, dispersion 0..1,
  bevel px, specular 0..1`. Surface-local logical px. Empty = no glass.
- `set_params(merge fixed, frost fixed, saturation fixed)` — per surface.
- All double-buffered on `wl_surface.commit`.
- **Frost is per surface**: lumen sends the max over the surface's shapes. If
  different parts need different frost, change the protocol/renderer (e.g.
  one capture per distinct frost value).
- XML lives in both repos: `niri/resources/lumen-glass-v1.xml` and
  `lumen/protocols/lumen-glass-v1.xml` — keep them identical.

### lumen changes (repo `~/github/projects/lumen`, user's own project, local only)

Files touched by this work (the repo ALSO has lots of unrelated, pre-existing
uncommitted changes — do not commit blindly; ask the user):
- `Cargo.toml` (+ `wayland-scanner = "0.31"`), `protocols/lumen-glass-v1.xml`
- `src/scene.rs` — `Glass` gained `refraction, dispersion, bevel, specular, merge`
- `src/language/compiler.rs` (`glass_spec`), `src/language/vocabulary.rs`
- `src/gpu.rs` — `Draw.glass_shapes`, `glass_protocol`, `glass_box()`,
  `liquid()`, `glass_wanted()` (with the protocol, any frost or liquid prop
  requests glass; without it, the old `blur > 50%` rule), `request_glass(…, spec)`
- `src/render.rs` — per-surface send + `LUMEN_GLASS=1` debug print
- `src/platform/mod.rs` (trait `glass_supported`, `update_glass`),
  `src/platform/wayland.rs` (generated client module, `GLASS` global, per-window glass object)

Build: `cd ~/github/projects/lumen && cargo build --release --offline`
(tests: `cargo test --release --offline`). `~/.local/bin/lumen` is a symlink to
`target/release/lumen`; the running island notices a new binary itself.

### niri changes (repo `~/github/projects/niri`)

Branch `dotnix-patches` = 5 commits on tag `v26.04`; patch 0005 is the glass.
Exported to `dotnix/niri/patches/*.patch`. After changing niri:

```
cd ~/github/projects/niri && cargo build --release   # check it compiles
git commit -am "..."                                  # keep patches committed!
rm dotnix/niri/patches/*.patch && git format-patch -q --no-signature \
   -o ~/github/config/dotnix/niri/patches v26.04..dotnix-patches
~/github/config/dotnix/niri/scripts/niri-patched.sh build        # verify+install (keeps niri.prev)
~/github/config/dotnix/niri/scripts/niri-patched.sh restart-niri # in-place restart, apps restored
```
Shader errors only appear at niri start (log: "error compiling liquid_glass
shader") — test nested first.

## How to test and tune

**Live**: edit `glass.plm`, save, look at the island; open the card over busy
content to judge refraction.

**See what is sent**: `LUMEN_GLASS=1 ~/.local/bin/lumen --scene
~/.config/lumen/shells/island/island.plm --no-hud --stall 0 --seconds 3 2>&1 | grep ^glass`
(starts a second island for 3 s).

**Nested test (safe, for shader work)** — never touches the live session:
```
S=<scratch dir>
cat > $S/n.kdl <<'EOF'
hotkey-overlay { skip-at-startup; }
screenshot-path "<scratch>/%H%M%S.png"
EOF
~/github/projects/niri/target/release/niri -c $S/n.kdl &      # opens a window, socket wayland-2
WAYLAND_DISPLAY=wayland-2 awww-daemon -n glasstest &
WAYLAND_DISPLAY=wayland-2 awww img -n glasstest -t none ~/github/config/dotnix/wallpapers/skyline.jpg
WAYLAND_DISPLAY=wayland-2 ~/github/projects/lumen/target/release/lumen --scene $S/glass-test.plm --no-hud --stall 0 &
NIRI_SOCKET=$(ls -t $XDG_RUNTIME_DIR/niri.wayland-2.*.sock | head -1) niri msg action screenshot-screen
```
Test scene (`glass-test.plm`):
```
language 0.4
scene GlassTest {
    surface { size: 900, 420; anchor: top; margin: 40 }
    body {
        color: #ffffff; glass: 100%; blur: 0%
        refraction: 28; dispersion: 50%; bevel: 26; specular: 70%; merge: 24
        box { from: 40, 40; size: 360, 64; corner: 32 continuous }
        box { from: 40, 140; size: 360, 230; corner: 34 continuous }
        box { from: 470, 60; size: 160, 160; corner: 80 }
        box { from: 640, 60; size: 160, 160; corner: 80 }
    }
}
```
With those values lensing + fringes are clearly visible (dispersion 50% is
too rainbow for Apple; ~5–15% is more like it). For iOS references, ask the
user for screenshots/recordings and compare side by side.

## Gotchas (learned the hard way)

- **Killing test processes**: never `pkill lumen` (kills the real island) and
  never `pkill -f <pattern>` where the pattern is in your own command line (it
  kills your shell). Kill by PID: `for p in $(pgrep -x lumen); do grep -qa
  glass-test /proc/$p/cmdline && kill $p; done`.
- `lumen --seconds N` on the real display briefly shows a second island.
- lumen's `blur:` used to be on/off (`> 50%` = on). With the protocol it's a
  frost amount; the request rule is in `gpu.rs glass_wanted()`.
- Frost is the MAX over a surface's shapes: one body left on default
  `blur` (100%) overrides everything (that bug was fixed by wiring all 5
  bodies to `lg_frost`).
- `island.luau`'s top-level chunk is at Luau's 200-local limit; a new
  top-level `local` silently kills the island logic. Use globals.
- `theme.plm` and `niri/theme.kdl` are generated by
  `theme/wallpaper-theme.py` on every wallpaper pick — edit the generator, not
  those files.
- Stock niri rejects the patched-only keys in `niri/theme.kdl`
  (`border-glass` etc.); the update/fallback system handles that
  (`niri/scripts/niri-launch.sh`, `niri-patched.sh`, see
  `system/niri-patched-setup.sh`; the setup script still has to be run once
  by the user with sudo).
- niri's window glass borders (patch 0004, `blur { border-glass … }`) are a
  separate feature; don't confuse them with this.

## Suggested next steps

1. `lg_frost` → ~15%, `lg_refraction` → ~12–16, `lg_bevel` → ~12–14 (pill is
   34 px tall), `lg_dispersion` → ~8%, `lg_specular` → ~60%; judge on the open
   card over busy windows.
2. Lighten lumen's veil for the glass bodies (lower `glass_alpha`/`milk`, fade
   or remove the prism rim) until niri's glass reads through, keeping text legible.
3. If it still doesn't read as Apple's: adjust the bevel profile / magnification
   in `liquid_glass.frag`, then consider adaptive tint from backdrop luminance.
4. Expose `merge` in `glass.plm` for the morph between pill and capsules.
5. Commit: niri changes on `dotnix-patches` (+ re-export patches); lumen
   glass files (ask the user first because of unrelated changes); dotnix
   (nothing from today's sessions is committed — ask the user).
