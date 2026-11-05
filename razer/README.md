# Razer Blade 15 Advanced (Early 2022) — Lighting Setup

Custom keyboard lighting for the internal Razer Blade keyboard on Arch + Hyprland,
driven directly through OpenRazer instead of the (crashing) Polychromatic GUI.

- **Device:** Razer Blade 15 Advanced (Early 2022), VID:PID `1532:028A`
- **Matrix:** 6 rows × 16 columns, zones `main` (keyboard) + `logo` (lid)
- **Backend:** `openrazer-daemon` (always running; required)
- **Files:** [`razer-fx.py`](razer-fx.py) (the effect engine), [`reactive-test.py`](reactive-test.py) (input diagnostic)

---

## Background / why this exists

### Polychromatic editor crash
The Polychromatic **editor** crashes the whole app. Root cause (from the core dump):
the editor hosts a **QtWebEngine** webview inside a **Qt Quick scene graph**, and that
renderer segfaults in `libgallium` (Mesa) on this hybrid Intel/NVIDIA + Wayland setup.

```
#0 libgallium (Mesa)                ← actual SIGSEGV
#5 libQt6WebEngineCore
#6 RenderWidgetHostViewQtDelegateItem::updatePaintNode
#7 QQuickWindowPrivate::updateDirtyNode   ← Qt Quick scene graph
```

Workaround = force the Qt Quick scene graph to software rendering:
`QT_QUICK_BACKEND=software`. A desktop-file override applying this lives **outside this
repo** at `~/.local/share/applications/polychromatic.desktop` (not version-controlled).
*Note:* `--disable-gpu` and `QSG_RHI_BACKEND=software` do **not** fix it; only
`QT_QUICK_BACKEND=software` works.

We ultimately stopped using the GUI entirely in favour of `razer-fx.py`.

### Hardware effects vs. layered (software) effects
- **Hardware effects** (one at a time, rendered by the keyboard firmware): `static`,
  `spectrum`, `wave`, `reactive`, `breath`, `starlight`, `ripple`. Set via one command,
  cost **0% CPU**, persist until changed. Cannot be layered.
- **Layered effects** (e.g. an aurora wave + green keypress + twinkles all at once)
  are impossible in hardware — the firmware runs only one effect. Layering **requires**
  software compositing: render each frame on the CPU and stream it to the matrix.
  That is what `razer-fx.py` does.

---

## `razer-fx.py` — the layered effect engine

Renders a stack of **layers** (bottom → top) per frame and streams them to the
per-key matrix. Each layer returns an RGB grid + an alpha mask, so upper layers
blend over lower ones (gaps = transparent). All per-frame math is numpy-vectorised.

### Usage
```bash
cd ~/github/config/dotnix/razer
./razer-fx.py LAYER [LAYER ...] [--fps N]
```

### The configured look ("Aurora Borealis")
```bash
./razer-fx.py aurora reactive starlight:BFEFFF
```
Layer order bottom→top: **aurora** wave (mint green → violet → watermelon rose) →
**reactive** vivid green keypresses → **icy starlight**. Autostarts via
`../hypr/lua/execs.lua`.

### Available layers
| Layer | Effect | Arg |
|-------|--------|-----|
| `aurora` | slow wave: mint green → purple → pink (vivid, hard transitions) | — |
| `wave` | full rainbow diagonal scroll | — |
| `breath` | whole board pulses | — |
| `starlight` | random keys twinkle and fade | `:RRGGBB` color (e.g. `starlight:3EFFB3` mint) |
| `static` | solid color | `:RRGGBB` (default white) |
| `reactive` | keys light on press, fade over ~3s | `:RRGGBB` (default `44D62C` Razer green) |
| `bands` | **diagnostic**: shows the aurora palette as static side-by-side bands | — |

### Current tuning (edit in `razer-fx.py`)
- `AURORA_PALETTE`: mint green `#3CFF6E`, violet `#7A00FF`, watermelon rose `#FF3366`.
  Vivid because each keeps a low/zeroed channel (otherwise the LEDs wash to pastel —
  salmon/coral wash badly because all three channels stay high).
- `make_aurora(speed=0.24, spread=0.05, hold=0.25)`:
  - `speed` — scroll speed
  - `spread` — band width (smaller = wider bands / fewer colors visible at once)
  - `hold` — transition hardness (toward 0.5 = harder/poppier edges, toward 0 = smoother)
- `make_reactive(color="44FF00", life=3.0)` — vivid green keypress, 3s fade.
  Default green is `#44FF00` (no blue, so it stays saturated instead of washing white).
- `make_starlight(rate=5.0, life=2.8)` — sparse twinkles with a soft sine ease-in/out
  (gentle "breathing" instead of an instant pop), so it reads as calm not distracting (`:BFEFFF` icy).
- `--fps` default **15** (cost scales with fps; the cost is `draw()` I/O, not the math)

---

## Power / performance behaviour

Layered effects must render continuously, but the engine pauses to ~0% CPU when you
can't see the keyboard:

- **Lid closed** → blanks + idles automatically (reads `/proc/acpi/button/lid/LID0/state`).
  Self-contained, no dependencies.
- **SIGUSR1 = pause / SIGUSR2 = resume** → wired to hypridle's screen-off listener
  (see `../hypr/hypridle.conf`) so the backlight goes dark when the screen blanks.
- **SIGTERM** → clean shutdown (blanks keyboard), for a startup service.
- Writes its PID to `$XDG_RUNTIME_DIR/razer-fx.pid` so hypridle can signal it.

### Battery mode & event-driven idle (2026-11-03)

`--battery LAYERS…` picks a second stack while unplugged. Autostart uses
`aurora reactive starlight:BFEFFF --battery wallpaper reactive`
(`../niri/conf/startup.kdl`, `../hypr/lua/execs.lua`).

- **`wallpaper` layer**: the current wallpaper averaged to one colour per key and
  **flipped top-to-bottom** — a mirror lying below the screen (bottom of the
  wallpaper → top row nearest the screen). Saturation ×1.4, brightness floored and
  capped at 0.65. Path from `~/.cache/lumen/theme.json` (`source`), awww cache as fallback.
- **No polling, no timers.** A still stack (`wallpaper`/`static` + `reactive` with
  nothing fading) sleeps on an event until: a key press, the lid switch (evdev
  `SW_LID`), a udev `power_supply` change, or a signal. **SIGHUP = wallpaper changed**,
  sent by `../theme/wallpaper-theme.py` (`notify_keyboard()`) after it writes the theme.
  Unchanged frames are never re-sent. Animated layers (`wave`, `aurora`, `breath`,
  `starlight`) are marked `animated` and keep the fps loop.
- Measured: idle wallpaper+reactive = 0 wakeups / 0 CPU over 10 s (the old
  aurora stack: ~2.6 % CPU, ~37 wakeups/s, plus the daemon's work per frame).
- `openrazer-daemon` still spins on its own (KeyWatcher `sleep(0.01)` ≈ 100/s,
  battery notifier 10/s, ~1.8 % CPU) — upstream code, not patched.

## Known hardware fault: right-side second LEDs (2026-11-03, accepted)

Symptom: Enter, right Shift and the arrow keys look "partially pink" (two-tone).

Probed LED by LED via sysfs (`/sys/bus/hid/drivers/razerkbd/0003:1532:028A.0003`):
- The keys' **first** LEDs are matrix column 14, rows 2–5 (Enter = rows 2+3,
  RShift row 4, right arrow row 5) and behave normally. Column 15 only lights
  Power (row 0) and Backspace (row 1); its rows 2–5 drive nothing visible.
- Their **second** LEDs (right half of Enter, RShift, left/down/right arrows) are
  **not addressable**: they ignore every custom frame, keep a stale colour (pink
  from aurora → the two-tone), and ended up **blinking red even with
  `matrix_effect_none` + brightness 0**, with nothing writing to the device.
- Not software: pure static and per-key blue look clean on the addressable LEDs;
  re-sending frames changes nothing; the firmware rejects custom-frame columns
  > 15 (`Command not supported`, class 03 id 0b), so there's no hidden column.
- OpenRazer's `KEY_MAPPING` (full-size layout, e.g. Enter at (4,21)) is useless
  for locating keys on this 6×16 board — probe instead.
- Untried: a full cold power-off (charger out, 30 s) to reset the keyboard
  controller. If that doesn't help it's a backlight hardware fault (LED driver /
  keyboard connection) — repair only. The user chose to live with it.

### Measured cost (on this machine)
| State | CPU |
|-------|-----|
| Animating @15fps | ~3.5% of **one** core (≈0.3% of total 20-thread CPU) |
| Paused (lid shut / screen off) | **0%** |

Negligible for gaming/compiling (one light, mostly-I/O-bound thread). Minor battery
cost when animating (~1–2W, mostly from preventing deep CPU idle) — eliminated while
paused. The `reactive` layer adds almost nothing: its evdev reader sleeps until a
keypress. This is lighter than Synapse/Chroma on Windows (no background service stack).

### hypridle integration (`../hypr/hypridle.conf`, screen-off listener)
```ini
listener {
    timeout = 720  # 12 min  (bump to 1200 for 20 min)
    on-timeout = hyprctl dispatch dpms off; kill -USR1 $(cat $XDG_RUNTIME_DIR/razer-fx.pid) 2>/dev/null
    on-resume  = hyprctl dispatch dpms on; kill -USR2 $(cat $XDG_RUNTIME_DIR/razer-fx.pid) 2>/dev/null
}
```

---

## The reactive layer & the keyd problem (IMPORTANT)

Reactive needs to read physical keypresses and map each keycode to a matrix cell.

- **Keycode → matrix map**: reused directly from OpenRazer
  (`openrazer_daemon.keyboard.EVENT_MAPPING` + `KEY_MAPPING`) — 120 keys, exact for
  this board. No manual calibration needed.
- **Reading keys**: via `python-evdev`.

### The catch: keyd grabs the keyboard
This system runs **keyd** (keyboard remapper). keyd **exclusively grabs** the physical
Razer keyboard nodes (`event5`, `event24`) and re-emits all keystrokes through its own
virtual device **`keyd virtual keyboard` (event18)**. So:

- Reading the Razer nodes yields **0 events** (keyd consumed them).
- Real keystrokes come from **event18**, which is group **`input`**.

`razer-fx.py`'s `make_reactive` therefore prefers the keyd virtual device
(any keyboard whose name contains "keyd"), falling back to other keyboards.

### The catch #2: remapped keys light the wrong cell
keyd re-emits the *target* code, so a remapped key reads as a different key than
the one physically pressed. Worse, OpenRazer's `KEY_MAPPING` for the bottom row
doesn't match this board's physical LED layout (its labels are shifted; e.g. it
calls `(5,2)` "Super" but that LED is physically under Fn). Both are corrected by
`CELL_OVERRIDE` in `make_reactive`, which maps each *emitted* keycode straight to
the *physically verified* LED cell. Current swaps (per `/etc/keyd/default.conf`,
a 3-way rotation Win↔Ctrl↔Alt) and their real cells:

| Physical key pressed | keyd emits | Physical LED cell |
|----------------------|-----------|-------------------|
| Ctrl  | LeftAlt (56)   | `(5,1)` |
| Win   | LeftCtrl (29)  | `(5,3)` |
| Alt   | LeftMeta (125) | `(5,5)` |

Cells were found by probing LEDs one at a time (light a cell, see which key glows)
because guessing from labels was wrong repeatedly. If you change the keyd remap or
move to a different board, re-probe and update `CELL_OVERRIDE`.

### Required setup for reactive (one-time)
1. `sudo pacman -S --needed python-evdev`  ✅ done
2. `sudo usermod -aG input $USER`  ✅ done (user added to `input` group)
3. **Log out and back in** so the `input` group applies to the whole session
   (incl. autostart). Until re-login, launch via `sg input -c '…'` or `newgrp input`.

The `openrazer` group (already a member) covers the matrix/LED writes; the `input`
group is specifically for reading the keyd virtual keyboard.

### Verifying input capture
```bash
sg input -c '~/github/config/dotnix/razer/reactive-test.py'
```
Press keys for 8s. Working output looks like:
```
[/dev/input/event18] KEY_A (code 30) -> matrix (3, 2)
```

---

## Status (as of 2026-06-19)

- ✅ Aurora wave (mint/violet/rose) + icy starlight: working and tuned.
- ✅ Lid / screen-off pause (0% CPU): working; hypridle wired.
- ✅ Reactive: working live with vivid green keypresses (`input` group active after relogin).
- ✅ Remapped-key cells corrected via `CELL_OVERRIDE` (Ctrl/Win/Alt rotation; Alt LED `(5,5)`).
- ✅ Autostart: launched from `../hypr/lua/execs.lua`; Polychromatic autostart disabled via
  `~/.config/autostart/polychromatic-autostart.desktop` (`Hidden=true`).

### Quick reference
```bash
# the look (autostarted from niri startup.kdl and execs.lua)
./razer-fx.py aurora reactive starlight:BFEFFF --battery wallpaper reactive
# diagnostics
./razer-fx.py bands        # see palette colors as static bands
./reactive-test.py         # verify keypress capture (keyd/event18)
# one-shot hardware effects (0% CPU, no script) via deprecated CLI:
polychromatic-cli -d laptop -z main -o spectrum
```
