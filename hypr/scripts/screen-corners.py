#!/usr/bin/env python3
"""
Fake rounded display corners, like a modern MacBook panel.

The corners are continuous, the way macOS draws them (and the same curve as
lumen's `corner: r continuous` and the patched niri's windows): a quarter
superellipse that comes in gradually from the straight edges, reaching
1.84 x RADIUS along each one, with its exponent chosen so it cuts in at the
diagonal exactly as deep as a quarter circle of RADIUS would.

Four tiny black corner masks per monitor, one in each corner, on the
layer-shell OVERLAY layer so they sit above windows, bars and fullscreen
apps. They take no input (empty input region) and no exclusive zone, so
clicks and the reserved bar area are untouched.

Four small surfaces rather than one fullscreen transparent one: the
compositor only ever blends 4 x (1.84 R)² pixels, which costs nothing at 240 Hz.

Usage: screen-corners.py [RADIUS]   (logical px, default 12)
Restart to apply a new radius:  pkill -f screen-corners.py
"""
import math
import os
import sys

# gtk4-layer-shell must be loaded before libwayland-client, which from Python
# means LD_PRELOAD — re-exec once with it set.
LIB = "libgtk4-layer-shell.so"
if LIB not in os.environ.get("LD_PRELOAD", ""):
    os.environ["LD_PRELOAD"] = (LIB + " " + os.environ.get("LD_PRELOAD", "")).strip()
    os.execv(sys.executable, [sys.executable] + sys.argv)

import cairo  # noqa: E402
import gi  # noqa: E402

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, Gtk  # noqa: E402
from gi.repository import Gtk4LayerShell as Layer  # noqa: E402

RADIUS = int(sys.argv[1]) if len(sys.argv) > 1 else 12
NAMESPACE = "screen-corners"

# lumen's continuous_corner (src/shapes.rs): how far the curve reaches along
# each edge, and the superellipse exponent that keeps the diagonal at R.
EXTENT = RADIUS * 1.84
POWER = -math.log(2) / math.log(1 - (1 - math.sqrt(0.5)) * RADIUS / EXTENT)
SIZE = math.ceil(EXTENT)

# (anchored edges, the side of the surface the curve curls around: 1 = far)
CORNERS = {
    "tl": ((Layer.Edge.TOP, Layer.Edge.LEFT), (1, 1)),
    "tr": ((Layer.Edge.TOP, Layer.Edge.RIGHT), (0, 1)),
    "bl": ((Layer.Edge.BOTTOM, Layer.Edge.LEFT), (1, 0)),
    "br": ((Layer.Edge.BOTTOM, Layer.Edge.RIGHT), (0, 0)),
}


def draw(_area, cr, w, h, centre):
    # Which way the screen's corner lies from the curve's inner point, and that
    # point: EXTENT in from the surface's corner that touches the screen's.
    dx, dy = 1 - 2 * centre[0], 1 - 2 * centre[1]
    cx = (1 - centre[0]) * w - dx * EXTENT
    cy = (1 - centre[1]) * h - dy * EXTENT
    cr.set_source_rgb(0, 0, 0)
    # The sliver between the screen's corner and the curve: from the corner,
    # along one edge to where the curve starts, round the quarter
    # superellipse |x|^n + |y|^n = E^n, and back along the other edge.
    cr.move_to(cx + dx * EXTENT, cy + dy * EXTENT)
    cr.line_to(cx + dx * EXTENT, cy)
    steps = 96
    for i in range(steps + 1):
        t = (math.pi / 2) * i / steps
        x = EXTENT * math.cos(t) ** (2 / POWER)
        y = EXTENT * math.sin(t) ** (2 / POWER)
        cr.line_to(cx + dx * x, cy + dy * y)
    cr.close_path()
    cr.fill()


def corner_window(app, monitor, edges, centre):
    win = Gtk.ApplicationWindow(application=app)
    Layer.init_for_window(win)
    Layer.set_namespace(win, NAMESPACE)
    Layer.set_layer(win, Layer.Layer.OVERLAY)
    Layer.set_monitor(win, monitor)
    Layer.set_exclusive_zone(win, -1)  # ignore the bar's reserved area
    Layer.set_keyboard_mode(win, Layer.KeyboardMode.NONE)
    for e in edges:
        Layer.set_anchor(win, e, True)

    area = Gtk.DrawingArea(content_width=SIZE, content_height=SIZE)
    area.set_draw_func(draw, centre)
    win.set_child(area)
    win.set_default_size(SIZE, SIZE)
    win.add_css_class("corner")

    win.present()
    # Click-through: an empty input region.
    surface = win.get_surface()
    surface.set_input_region(cairo.Region())
    return win


class Corners(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.ritvik.ScreenCorners")
        self.windows = {}  # monitor connector -> [windows]

    def do_activate(self):
        css = Gtk.CssProvider()
        css.load_from_string("window.corner, window.corner * { background: none; background-color: transparent; box-shadow: none; }")
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1  # beat ~/.config/gtk-4.0/gtk.css
        )
        self.hold()
        monitors = Gdk.Display.get_default().get_monitors()
        monitors.connect("items-changed", lambda m, *_: self.sync(m))
        self.sync(monitors)

    def sync(self, monitors):
        live = {}
        for i in range(monitors.get_n_items()):
            mon = monitors.get_item(i)
            live[mon.get_connector()] = mon
        for name in list(self.windows):
            if name not in live:
                for w in self.windows.pop(name):
                    w.destroy()
        for name, mon in live.items():
            if name not in self.windows:
                self.windows[name] = [
                    corner_window(self, mon, edges, centre)
                    for edges, centre in CORNERS.values()
                ]


if __name__ == "__main__":
    Corners().run([])
